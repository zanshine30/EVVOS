#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Complete All-in-One Setup
#
# Run on the Raspberry Pi as root AFTER setup_picam.sh + setup_picam_transfer.sh:
#   sudo bash setup_picam_complete.sh
#
# Replaces evvos-picam-tcp.py with a single complete service that includes:
#   • YUV420 format + relaxed FrameDurationLimits (fixes 0-byte .h264 files)
#   • FileOutput for reliable picamera2 recording
#   • 180° rotation via libcamera Transform (upside-down mount)
#   • Async transcription — STOP_RECORDING returns after ffmpeg, not Groq
#   • TRANSFER_FILES  — sends mp4 + jpg + transcript sidecar over TCP
#   • TAKE_SNAPSHOT   — JPEG still during active recording
#   • GET_TRANSCRIPT  — poll for background transcription result
#   • SHUTDOWN        — graceful OS shutdown from mobile app
#   • RESTART_DEVICE  — restart services + reboot from mobile app
#   • CLEAR_CACHE     — delete leftover recordings from mobile app
#   • GET_STATUS      — camera + recording status
#   • CAMERA_STATUS   — occlusion/brightness check (AEC warmup fix)
#   • Heartbeat       — sends battery="POWERED ON" to Supabase every 30s
# ============================================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_section() {
    echo -e "\n${CYAN}════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}▶ $1${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
}

if [ "$EUID" -ne 0 ]; then
    log_error "Run as root: sudo bash $0"
    exit 1
fi

CAMERA_SCRIPT="/usr/local/bin/evvos-picam-tcp.py"

if [ ! -f "$CAMERA_SCRIPT" ]; then
    log_error "Camera script not found: $CAMERA_SCRIPT"
    log_error "Run setup_picam.sh first (installs dependencies, systemd unit, etc)."
    exit 1
fi

log_section "EVVOS Pi Camera — Complete All-in-One Setup"

BACKUP="${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CAMERA_SCRIPT" "$BACKUP"
log_success "Backup: $BACKUP"

# ── Write the complete Python service ────────────────────────────────────────
cat > "$CAMERA_SCRIPT" << 'CAMERA_EOF'
#!/usr/bin/env python3
"""
EVVOS Pi Camera TCP Control Service — Complete All-in-One
  • 24 FPS, YUV420, FileOutput (fixes 0-byte recording bug on OV5647)
  • 180° rotation via libcamera Transform
  • Async transcription (Groq online → whisper.cpp offline fallback)
  • TRANSFER_FILES, TAKE_SNAPSHOT, GET_TRANSCRIPT
  • SHUTDOWN, RESTART_DEVICE, CLEAR_CACHE
  • CAMERA_STATUS occlusion check with AEC warmup fix
  • Heartbeat → Supabase (battery="POWERED ON")
"""
import socket, json, os, sys, time, threading, subprocess
from datetime import datetime
from pathlib import Path

try:
    from picamera2 import Picamera2
    from picamera2.encoders import H264Encoder
    from picamera2.outputs import FileOutput
except ImportError:
    print("[CAMERA] ERROR: picamera2 not installed", file=sys.stderr)
    sys.exit(1)

try:
    from libcamera import Transform
except ImportError:
    Transform = None   # rotation silently skipped if libcamera binding missing

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
TCP_HOST       = "0.0.0.0"
TCP_PORT       = 3001
HTTP_PORT      = 8080
RECORDINGS_DIR = Path("/home/pi/recordings")
CAMERA_RES     = (1280, 720)
CAMERA_FPS     = 24.0

# ── GLOBAL STATE ──────────────────────────────────────────────────────────────
camera               = None
recording            = False
recording_lock       = threading.Lock()
current_session_id   = None
current_video_path   = None
current_audio_path   = None
audio_process        = None
recording_start_time = None
snapshot_paths       = []   # JPEGs captured via TAKE_SNAPSHOT during a session

# Background transcription results keyed by session_id
_transcript_state = {}   # { session_id: {"status": "pending"|"complete", ...} }

# ── HELPERS ───────────────────────────────────────────────────────────────────

def get_pi_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        return "127.0.0.1"

def setup_camera():
    global camera
    try:
        camera = Picamera2()
        kwargs = dict(
            main={"size": CAMERA_RES, "format": "YUV420"},
            encode="main",
            # Relaxed FrameDurationLimits: pinning min==max==41666 causes a
            # dequeue timeout on OV5647 sensors (0-byte output). Allow a range
            # so the sensor can breathe while still targeting 24 FPS.
            controls={"FrameRate": CAMERA_FPS, "FrameDurationLimits": (33333, 66666)},
        )
        if Transform is not None:
            kwargs["transform"] = Transform(hflip=True, vflip=True)   # 180° mount
        config = camera.create_video_configuration(**kwargs)
        camera.configure(config)
        print(f"[CAMERA] ✓ Ready at {CAMERA_RES} @ {CAMERA_FPS} FPS"
              f"{' (180° rotation)' if Transform else ''}")
        return True
    except Exception as e:
        print(f"[CAMERA] ERROR: {e}")
        return False

# ── WHISPER / GROQ TRANSCRIPTION ──────────────────────────────────────────────
import re as _re

WHISPER_BIN   = os.environ.get("WHISPER_BIN",   "/opt/whisper.cpp/build/bin/whisper-cli")
WHISPER_MODEL = os.environ.get("WHISPER_MODEL",  "/opt/whisper.cpp/models/ggml-tiny.en.bin")


def _extract_plate_number(text):
    for pat in [r'\b([A-Z]{3})[\s\-]?(\d{4})\b', r'\b([A-Z]{3})[\s\-]?(\d{3})\b',
                r'\b(\d{4})[\s\-]?([A-Z]{2})\b']:
        m = _re.search(pat, text.upper())
        if m:
            return ' '.join(m.groups())
    return ''

def _extract_driver_name(text):
    for pat in [
        r"(?:driver(?:'s)?\s+(?:name\s+)?is|name\s*[:is]+)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3})",
        r"(?:apprehended|stopped)\s+(?:a\s+)?(?:driver\s+)?([A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3})",
    ]:
        m = _re.search(pat, text, _re.IGNORECASE)
        if m:
            return m.group(1).strip()
    return ''

_VIOLATION_KEYWORDS = {
    "beating the red light": "Beating Red Light",
    "ran a red light":       "Beating Red Light",
    "red light":             "Beating Red Light",
    "no helmet":             "No Helmet",
    "overspeeding":          "Overspeeding",
    "over speed":            "Overspeeding",
    "speeding":              "Overspeeding",
    "illegal parking":       "Illegal Parking",
    "no seatbelt":           "No Seatbelt",
    "seatbelt":              "No Seatbelt",
    "no license":            "No Driver's License",
    "no driver's license":   "No Driver's License",
    "expired license":       "Expired License",
    "expired registration":  "Expired Registration",
    "no registration":       "No Registration",
    "reckless driving":      "Reckless Driving",
    "counterflow":           "Counterflow",
    "counter flow":          "Counterflow",
    "obstruction":           "Obstruction",
    "loading":               "Illegal Loading/Unloading",
    "unloading":             "Illegal Loading/Unloading",
    "no or":                 "No Official Receipt",
    "no cr":                 "No Certificate of Registration",
    "smoke belching":        "Smoke Belching",
    "colorum":               "Colorum",
    "no franchise":          "No Franchise",
}

def _extract_violations(text):
    found, lower = [], text.lower()
    for kw, label in _VIOLATION_KEYWORDS.items():
        if kw in lower and label not in found:
            found.append(label)
    return found

def _has_internet(host="8.8.8.8", port=53, timeout=3):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False

def _transcribe_groq_online(audio_path):
    import requests as _req
    api_key = os.environ.get("GROQ_API_KEY", "").strip()
    if not api_key:
        print("[GROQ] GROQ_API_KEY not set — skipping")
        return None
    if not audio_path.exists() or audio_path.stat().st_size < 1000:
        print("[GROQ] Audio missing or too small")
        return None
    print(f"[GROQ] Uploading {audio_path.name} ({audio_path.stat().st_size/1024:.0f} KB)...")
    try:
        with open(audio_path, "rb") as fh:
            resp = _req.post(
                "https://api.groq.com/openai/v1/audio/transcriptions",
                headers={"Authorization": f"Bearer {api_key}"},
                files={"file": (audio_path.name, fh, "audio/wav")},
                data={"model": "whisper-large-v3-turbo", "response_format": "text", "language": "en"},
                timeout=60,
            )
        if resp.status_code != 200:
            print(f"[GROQ] API error {resp.status_code}: {resp.text[:200]}")
            return None
        transcript = resp.text.strip()
        if not transcript:
            return None
        print(f"[GROQ] ✓ ({len(transcript)} chars): {transcript[:120]}...")
        return {
            "transcript":   transcript,
            "driver_name":  _extract_driver_name(transcript),
            "plate_number": _extract_plate_number(transcript),
            "violations":   _extract_violations(transcript),
            "engine":       "groq-whisper-large-v3-turbo",
        }
    except Exception as e:
        print(f"[GROQ] Failed: {e}")
        return None

def _transcribe_whisper_offline(audio_path):
    empty = {"transcript": "", "driver_name": "", "plate_number": "", "violations": [], "engine": "whisper-tiny.en-offline"}
    if not Path(WHISPER_BIN).exists() or not Path(WHISPER_MODEL).exists():
        return empty
    if not audio_path.exists() or audio_path.stat().st_size < 1000:
        return empty
    print(f"[WHISPER] Offline transcription: {audio_path.name}...")
    txt_path = audio_path.with_suffix(audio_path.suffix + ".txt")
    try:
        result = subprocess.run(
            [WHISPER_BIN, "-m", WHISPER_MODEL, "-f", str(audio_path),
             "-otxt", "-nt", "-np", "-l", "en", "--threads", "2"],
            capture_output=True, text=True, timeout=300,
        )
        transcript = txt_path.read_text(encoding="utf-8", errors="replace").strip() if txt_path.exists() else result.stdout.strip()
        txt_path.unlink(missing_ok=True)
        if not transcript:
            return empty
        print(f"[WHISPER] ✓ ({len(transcript)} chars)")
        return {
            "transcript":   transcript,
            "driver_name":  _extract_driver_name(transcript),
            "plate_number": _extract_plate_number(transcript),
            "violations":   _extract_violations(transcript),
            "engine":       "whisper-tiny.en-offline",
        }
    except subprocess.TimeoutExpired:
        print("[WHISPER] Timed out")
        return empty
    except Exception as e:
        print(f"[WHISPER] Error: {e}")
        return empty

def transcribe_best(audio_path):
    empty = {"transcript": "", "driver_name": "", "plate_number": "", "violations": [], "engine": "none"}
    if not audio_path or not audio_path.exists() or audio_path.stat().st_size < 1000:
        return empty
    online = _has_internet()
    print(f"[TRANSCRIBE] Internet: {'✓' if online else '✗'}")
    if online:
        result = _transcribe_groq_online(audio_path)
        if result:
            return result
        print("[TRANSCRIBE] Groq failed — falling back to local Whisper")
    return _transcribe_whisper_offline(audio_path)

# ── COMMAND HANDLERS ──────────────────────────────────────────────────────────

def start_recording_handler():
    global recording, current_session_id, current_video_path, current_audio_path
    global audio_process, recording_start_time
    with recording_lock:
        if recording:
            return {
                "status": "recording_started", "session_id": current_session_id,
                "video_path": str(current_video_path), "pi_ip": get_pi_ip(),
                "http_port": HTTP_PORT, "already_running": True,
                "elapsed_seconds": int(time.time() - recording_start_time) if recording_start_time else 0,
            }
        try:
            RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
            snapshot_paths.clear()
            ts                   = datetime.now().strftime("%Y%m%d_%H%M%S")
            current_session_id   = f"session_{ts}"
            current_video_path   = RECORDINGS_DIR / f"video_{ts}.h264"
            current_audio_path   = RECORDINGS_DIR / f"audio_{ts}.wav"
            recording_start_time = time.time()

            print(f"[CAMERA] Starting: {current_session_id}")
            encoder = H264Encoder(bitrate=2500000, framerate=CAMERA_FPS)
            camera.start_recording(encoder, FileOutput(str(current_video_path)))

            audio_process = subprocess.Popen(
                ["arecord", "-D", "pulse", "-f", "S16_LE", "-r", "16000", "-c", "1",
                 str(current_audio_path)],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            )
            time.sleep(0.5)
            if audio_process.poll() is not None:
                err = audio_process.stderr.read().decode().strip()
                print(f"[CAMERA] Warning: arecord exited: {err}")
                audio_process = None
            else:
                print("[CAMERA] arecord started via PulseAudio")

            recording = True
            return {
                "status": "recording_started", "session_id": current_session_id,
                "video_path": str(current_video_path), "pi_ip": get_pi_ip(),
                "http_port": HTTP_PORT, "already_running": False, "elapsed_seconds": 0,
            }
        except Exception as e:
            print(f"[CAMERA] Start Error: {e}")
            return {"status": "error", "message": str(e)}


def stop_recording_handler():
    global recording, current_session_id, current_video_path, current_audio_path
    global audio_process, recording_start_time
    with recording_lock:
        if not recording:
            return {"status": "not_recording"}
        try:
            print("[CAMERA] Stopping...")
            camera.stop_recording()
            # stop_recording() already stops the camera — do NOT call camera.stop()

            if audio_process:
                audio_process.terminate()
                try:
                    audio_process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    audio_process.kill()
                audio_process = None

            recording            = False
            recording_start_time = None
            time.sleep(0.5)

            mp4_path = current_video_path.with_suffix(".mp4")
            raw_size = current_video_path.stat().st_size if current_video_path.exists() else 0
            print(f"[CAMERA] Raw H264 size: {raw_size/1024/1024:.2f} MB")

            has_audio = (current_audio_path is not None
                         and current_audio_path.exists()
                         and current_audio_path.stat().st_size > 1000)

            print("[FFMPEG] Encoding MP4 (libx264 ultrafast + timestamp fix)...")
            cmd = ["ffmpeg", "-y", "-r", "24", "-i", str(current_video_path)]
            if has_audio:
                cmd.extend(["-i", str(current_audio_path)])
            cmd.extend(["-vf", "setpts=N/(24*TB)", "-c:v", "libx264",
                        "-preset", "ultrafast", "-crf", "23", "-r", "24", "-fps_mode", "cfr"])
            if has_audio:
                cmd.extend(["-c:a", "aac", "-b:a", "128k"])
            else:
                cmd.extend(["-an"])
            cmd.extend(["-movflags", "+faststart", "-loglevel", "error", str(mp4_path)])

            res = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
            if res.returncode == 0:
                size_mb = mp4_path.stat().st_size / 1024 / 1024
                print(f"[FFMPEG] ✓ {mp4_path.name} ({size_mb:.2f} MB)")
                current_video_path.unlink(missing_ok=True)
            else:
                print(f"[FFMPEG] Error (exit {res.returncode}): {res.stderr[:400]}")
                size_mb = mp4_path.stat().st_size / 1024 / 1024 if mp4_path.exists() else 0.0

            # Kick off transcription in background — handler returns immediately
            # after ffmpeg. Phone polls GET_TRANSCRIPT or gets sidecar via TRANSFER_FILES.
            _sess = current_session_id
            _wav  = current_audio_path

            def _bg_transcribe(session_id, wav_path):
                _transcript_state[session_id] = {"status": "pending"}
                result = transcribe_best(wav_path) if (wav_path and wav_path.exists()) else \
                    {"transcript": "", "driver_name": "", "plate_number": "", "violations": [], "engine": "none"}
                result["status"] = "complete"
                _transcript_state[session_id] = result
                sidecar = RECORDINGS_DIR / f"transcript_{session_id}.json"
                try:
                    sidecar.write_text(json.dumps(result), encoding="utf-8")
                    print(f"[TRANSCRIBE] ✓ Sidecar: {sidecar.name}")
                except Exception as _e:
                    print(f"[TRANSCRIBE] Sidecar error: {_e}")
                try:
                    if wav_path:
                        wav_path.unlink(missing_ok=True)
                except Exception:
                    pass

            threading.Thread(target=_bg_transcribe, args=(_sess, _wav), daemon=True).start()

            return {
                "status":               "recording_stopped",
                "session_id":           current_session_id,
                "video_filename":       mp4_path.name,
                "video_path":           str(mp4_path),
                "video_size_mb":        round(size_mb, 2),
                "video_url":            f"http://{get_pi_ip()}:{HTTP_PORT}/{mp4_path.name}",
                "pi_ip":                get_pi_ip(),
                "http_port":            HTTP_PORT,
                "transcription_status": "pending",
                "transcript":           "",
                "driver_name":          "",
                "plate_number":         "",
                "violations":           [],
                "transcription_engine": "pending",
                "snapshot_count":       len(snapshot_paths),
                "snapshot_filenames":   [p.name for p in snapshot_paths if p.exists()],
            }
        except Exception as e:
            print(f"[CAMERA] Stop Error: {e}")
            return {"status": "error", "message": str(e)}


def take_snapshot_handler():
    """Capture a JPEG still during active recording using camera.capture_image()."""
    global snapshot_paths, current_session_id, recording
    if not camera:
        return {"status": "error", "message": "Camera not initialised"}
    if not recording:
        print("[SNAPSHOT] Warning: snapshot while not recording")
    try:
        RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
        idx       = len(snapshot_paths)
        pfx       = current_session_id or "nosession"
        filename  = f"snapshot_{pfx}_{idx:04d}.jpg"
        snap_path = RECORDINGS_DIR / filename

        image = camera.capture_image("main")
        image.save(str(snap_path), "JPEG", quality=85)

        snapshot_paths.append(snap_path)
        size_kb = snap_path.stat().st_size / 1024
        print(f"[SNAPSHOT] ✓ #{idx}: {filename} ({size_kb:.0f} KB)")
        return {"status": "snapshot_taken", "index": idx, "filename": filename,
                "size_kb": round(size_kb, 1)}
    except Exception as e:
        print(f"[SNAPSHOT] Error: {e}")
        return {"status": "error", "message": str(e)}


def camera_status_handler():
    """
    Check if the camera lens is occluded by analysing frame brightness.
    AEC warmup fix: discards the first frame after darkness (stale AEC)
    and analyses a second frame captured 0.4s later.
    """
    if not camera:
        return {"status": "error", "message": "Camera not initialised"}
    try:
        # Frame 1: discard — AEC may still be adapting after cover removal
        _warmup = camera.capture_request()
        _warmup.release()
        time.sleep(0.4)   # ~10 frames @ 24 FPS for AEC to settle

        # Frame 2: analyse
        request = camera.capture_request()
        frame   = request.make_array("main")   # shape (H, W, C)
        request.release()

        # Compute mean brightness (works for both YUV420 and RGB)
        brightness = float(frame[:, :, 0].mean())
        blocked    = brightness < 10.0

        print(f"[CAMERA_STATUS] brightness={brightness:.1f}  blocked={blocked}")
        return {
            "status":         "camera_status",
            "camera_blocked": blocked,
            "brightness":     round(brightness, 1),
        }
    except Exception as e:
        print(f"[CAMERA_STATUS] Error: {e}")
        return {"status": "error", "message": str(e)}


def get_transcript_handler(session_id):
    """Poll for background transcription result by session_id."""
    if not session_id:
        return {"status": "error", "message": "session_id required"}
    state = _transcript_state.get(session_id)
    if state is None:
        return {"status": "not_found", "session_id": session_id}
    return {"status": "transcript_result", **state}


def get_status_handler():
    with recording_lock:
        elapsed = int(time.time() - recording_start_time) if recording_start_time else 0
        return {
            "status":          "status_ok",
            "recording":       recording,
            "session_id":      current_session_id,
            "video_path":      str(current_video_path) if current_video_path else None,
            "pi_ip":           get_pi_ip(),
            "http_port":       HTTP_PORT,
            "elapsed_seconds": elapsed,
            "battery":         "POWERED ON",
        }


def transfer_files_handler(conn):
    """
    Send .mp4, .jpg, and transcript .json to the mobile app over TCP.
    Protocol: JSON header → (4-byte size + binary) per file → JSON footer.
    Waits up to 15s for transcript sidecar (Groq usually done in 5-10s).
    """
    import struct
    import json as _json
    import socket as _socket

    try:
        conn.setsockopt(_socket.IPPROTO_TCP, _socket.TCP_NODELAY, 1)
        conn.setsockopt(_socket.SOL_SOCKET,  _socket.SO_SNDBUF, 2 * 1024 * 1024)
    except Exception as _e:
        print(f"[TRANSFER] Socket tuning warning: {_e}")

    print("[TRANSFER] Building file list...")
    files_to_send = []

    all_mp4 = sorted(RECORDINGS_DIR.glob("*.mp4"), key=lambda f: f.stat().st_mtime, reverse=True)
    if all_mp4:
        files_to_send.append(all_mp4[0])
        print(f"[TRANSFER] Video: {all_mp4[0].name} ({all_mp4[0].stat().st_size/1024/1024:.2f} MB)")

    all_jpg = sorted(RECORDINGS_DIR.glob("snapshot_*.jpg"))
    files_to_send.extend(all_jpg)
    if all_jpg:
        print(f"[TRANSFER] Snapshots: {len(all_jpg)} file(s)")

    print("[TRANSFER] Waiting for transcript sidecar (up to 15s)...")
    for _w in range(15):
        all_json = sorted(RECORDINGS_DIR.glob("transcript_*.json"))
        if all_json:
            print(f"[TRANSFER] Sidecar ready after {_w}s")
            break
        time.sleep(1)
    else:
        all_json = []
        print("[TRANSFER] Sidecar not ready after 15s — proceeding without it")
    files_to_send.extend(all_json)
    if all_json:
        print(f"[TRANSFER] Transcript sidecar: {len(all_json)} file(s)")

    if not files_to_send:
        err = _json.dumps({"status": "error", "message": "No files found to transfer"}) + "\n"
        conn.sendall(err.encode("utf-8"))
        return

    file_meta = [{"name": f.name, "size": f.stat().st_size} for f in files_to_send]
    conn.sendall((_json.dumps({"status": "transfer_ready", "files": file_meta}) + "\n").encode("utf-8"))
    print(f"[TRANSFER] Header sent: {len(files_to_send)} file(s)")

    CHUNK = 256 * 1024
    transferred = []
    for fp in files_to_send:
        conn.sendall(struct.pack("<I", fp.stat().st_size))
        sent = 0
        with open(fp, "rb") as fh:
            while True:
                chunk = fh.read(CHUNK)
                if not chunk:
                    break
                conn.sendall(chunk)
                sent += len(chunk)
        print(f"[TRANSFER] ✓ {fp.name} ({sent/1024:.1f} KB)")
        transferred.append(fp)

    conn.sendall((_json.dumps({"status": "transfer_complete",
                               "file_count": len(transferred)}) + "\n").encode("utf-8"))
    print(f"[TRANSFER] ✓ Done — {len(transferred)} file(s) sent")

    for fp in transferred:
        try:
            fp.unlink(missing_ok=True)
            print(f"[TRANSFER] Deleted: {fp.name}")
        except Exception as _e:
            print(f"[TRANSFER] Could not delete {fp.name}: {_e}")


def upload_to_supabase_handler(incident_id, auth_token, video_filename=None):
    import requests
    print(f"[UPLOAD] Incident: {incident_id}")
    file_path = RECORDINGS_DIR / video_filename if video_filename else None
    if not file_path or not file_path.exists():
        all_v = list(RECORDINGS_DIR.glob("*.mp4"))
        if not all_v:
            return {"status": "error", "message": "No video found"}
        file_path = max(all_v, key=lambda f: f.stat().st_mtime)
    url          = os.environ.get("SUPABASE_URL", "").rstrip("/")
    anon         = os.environ.get("SUPABASE_ANON_KEY", "")
    storage_path = f"{incident_id}/video.mp4"
    upload_url   = f"{url}/storage/v1/object/incident-videos/{storage_path}"
    try:
        with open(file_path, "rb") as fh:
            resp = requests.post(upload_url, headers={
                "apikey": anon, "Authorization": f"Bearer {auth_token or anon}",
                "Content-Type": "video/mp4", "x-upsert": "true",
            }, data=fh, timeout=300)
        if resp.status_code in (200, 201):
            public_url = f"{url}/storage/v1/object/public/incident-videos/{storage_path}"
            requests.post(f"{url}/rest/v1/rpc/update_incident_video", headers={
                "apikey": anon, "Authorization": f"Bearer {anon}",
                "Content-Type": "application/json",
            }, json={"p_incident_id": incident_id, "p_video_url": public_url,
                     "p_storage_path": storage_path}, timeout=15)
            file_path.unlink()
            return {"status": "upload_complete", "video_url": public_url,
                    "storage_path": storage_path}
        return {"status": "error", "message": f"HTTP {resp.status_code}"}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def shutdown_handler():
    """Power off the Pi — sends ACK then issues sudo shutdown now after 1s drain."""
    def _do():
        time.sleep(1)
        print("[SHUTDOWN] Executing: sudo shutdown now")
        subprocess.run(["sudo", "shutdown", "now"], check=False)
    print("[SHUTDOWN] Shutdown command received.")
    threading.Thread(target=_do, daemon=True).start()
    return {"status": "shutdown_initiated", "message": "Raspberry Pi is shutting down"}


def restart_device_handler():
    """Restart camera + voice services then reboot."""
    def _do():
        time.sleep(1)
        subprocess.run(["systemctl", "restart", "evvos-picam-tcp"],  capture_output=True, timeout=15)
        subprocess.run(["systemctl", "restart", "evvos-pico-voice"], capture_output=True, timeout=15)
        print("[RESTART] Issuing reboot...")
        subprocess.run(["sudo", "reboot"], check=False)
    print("[RESTART] Restart command received.")
    threading.Thread(target=_do, daemon=True).start()
    return {"status": "restart_initiated",
            "services": ["evvos-picam-tcp", "evvos-pico-voice"]}


def clear_cache_handler():
    """Delete leftover .h264/.wav/.mp4 files from recordings dir."""
    deleted, freed_kb = 0, 0.0
    for pattern in ["*.h264", "*.wav", "*.mp4"]:
        for fp in RECORDINGS_DIR.glob(pattern):
            try:
                kb = fp.stat().st_size / 1024
                fp.unlink()
                freed_kb += kb
                deleted  += 1
                print(f"[CLEAR_CACHE] Deleted: {fp.name} ({kb:.0f} KB)")
            except Exception as err:
                print(f"[CLEAR_CACHE] Could not delete {fp.name}: {err}")
    print(f"[CLEAR_CACHE] ✓ {deleted} file(s), {freed_kb/1024:.2f} MB freed")
    return {"status": "cache_cleared", "deleted_count": deleted,
            "freed_kb": round(freed_kb, 1),
            "message": f"{deleted} file(s) removed ({freed_kb/1024:.2f} MB freed)"}


# ── HEARTBEAT ─────────────────────────────────────────────────────────────────

def _heartbeat_worker():
    """Send battery=POWERED ON + last_seen + ip_address to Supabase every 30s."""
    import requests as _req

    device_id = os.environ.get("DEVICE_ID", "").strip()
    url       = os.environ.get("SUPABASE_URL", "").rstrip("/")
    anon      = os.environ.get("SUPABASE_ANON_KEY", "").strip()

    if not device_id or not url or not anon:
        print("[HEARTBEAT] Missing DEVICE_ID / SUPABASE_URL / SUPABASE_ANON_KEY — disabled")
        return

    print(f"[HEARTBEAT] Started for device {device_id}")
    while True:
        try:
            pi_ip   = get_pi_ip()
            now_iso = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
            payload = {"battery": "POWERED ON", "last_seen": now_iso, "ip_address": pi_ip}
            resp = _req.patch(
                f"{url}/rest/v1/devices?device_id=eq.{device_id}",
                headers={"apikey": anon, "Authorization": f"Bearer {anon}",
                         "Content-Type": "application/json", "Prefer": "return=minimal"},
                json=payload, timeout=10,
            )
            status_code = resp.status_code
            print(f"[HEARTBEAT] ✓ battery=POWERED ON  ip={pi_ip}  last_seen={now_iso}  HTTP {status_code}")
        except Exception as hb_err:
            print(f"[HEARTBEAT] Error: {hb_err}")
        time.sleep(30)


# ── TCP CLIENT HANDLER ────────────────────────────────────────────────────────

def handle_client(conn, addr):
    print(f"[TCP] Client connected: {addr}")
    buffer = ""
    try:
        while True:
            try:
                data = conn.recv(1024)
            except (ConnectionResetError, BrokenPipeError, OSError) as e:
                print(f"[TCP] Client {addr} disconnected ({e.__class__.__name__}: {e}). Recording: {recording}")
                break
            if not data:
                print(f"[TCP] Client {addr} closed. Recording: {recording}")
                break

            buffer += data.decode("utf-8")
            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                    intent  = payload.get("intent", "").upper()
                    print(f"[TCP] ← {intent} from {addr}")

                    if   intent == "START_RECORDING":
                        res = start_recording_handler()
                    elif intent == "STOP_RECORDING":
                        res = stop_recording_handler()
                    elif intent == "TAKE_SNAPSHOT":
                        res = take_snapshot_handler()
                    elif intent == "TRANSFER_FILES":
                        transfer_files_handler(conn)
                        res = None   # response already sent inside handler
                    elif intent == "GET_TRANSCRIPT":
                        res = get_transcript_handler(payload.get("session_id"))
                    elif intent == "CAMERA_STATUS":
                        res = camera_status_handler()
                    elif intent == "GET_STATUS":
                        res = get_status_handler()
                    elif intent == "SHUTDOWN":
                        res = shutdown_handler()
                    elif intent == "RESTART_DEVICE":
                        res = restart_device_handler()
                    elif intent == "CLEAR_CACHE":
                        res = clear_cache_handler()
                    elif intent == "UPLOAD_TO_SUPABASE":
                        res = upload_to_supabase_handler(
                            payload.get("incident_id"),
                            payload.get("auth_token"),
                            payload.get("video_filename"),
                        )
                    else:
                        res = {"status": "unknown_intent", "intent": intent}

                    try:
                        if res is not None:   # None = TRANSFER_FILES already responded
                            conn.sendall((json.dumps(res) + "\n").encode("utf-8"))
                            print(f"[TCP] → {res.get('status')} to {addr}")
                    except (BrokenPipeError, OSError) as send_err:
                        print(f"[TCP] Send error to {addr}: {send_err}. Recording: {recording}")
                        return

                except json.JSONDecodeError as e:
                    print(f"[TCP] Bad JSON from {addr}: {e} — raw: {line!r}")
                except Exception as e:
                    print(f"[TCP] Handler error for {addr}: {e}")
    finally:
        try:
            conn.close()
        except Exception:
            pass
        print(f"[TCP] Thread for {addr} exited. Recording: {recording}")


if __name__ == "__main__":
    print(f"[EVVOS] Service starting — IP: {get_pi_ip()}")
    if setup_camera():
        threading.Thread(target=_heartbeat_worker, daemon=True).start()
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((TCP_HOST, TCP_PORT))
        server.listen(5)
        print(f"[TCP] Listening on {TCP_HOST}:{TCP_PORT}")
        while True:
            conn, addr = server.accept()
            threading.Thread(target=handle_client, args=(conn, addr), daemon=True).start()
CAMERA_EOF

chmod +x "$CAMERA_SCRIPT"
log_success "Service script written"

# ── Syntax check ─────────────────────────────────────────────────────────────
log_section "Syntax check"
if python3 -m py_compile "$CAMERA_SCRIPT" 2>&1; then
    log_success "Python syntax OK"
else
    log_error "Syntax error — restoring backup"
    cp "$BACKUP" "$CAMERA_SCRIPT"
    exit 1
fi

# ── Spot checks ───────────────────────────────────────────────────────────────
log_section "Verifying all features"
python3 - << 'VERIFY_EOF'
import sys
src = open("/usr/local/bin/evvos-picam-tcp.py").read()
checks = [
    ("YUV420 format",                    "YUV420"),
    ("FileOutput",                       "FileOutput"),
    ("Relaxed FrameDurationLimits",      "33333, 66666"),
    ("libcamera Transform import",       "from libcamera import Transform"),
    ("180° rotation in setup_camera",    "hflip=True, vflip=True"),
    ("libx264 encoding",                 "libx264"),
    ("setpts timestamp fix",             "setpts=N/(24*TB)"),
    ("Async _bg_transcribe",             "_bg_transcribe"),
    ("Transcript sidecar",               "transcript_{session_id}"),
    ("transfer_files_handler",           "transfer_files_handler"),
    ("take_snapshot_handler",            "take_snapshot_handler"),
    ("camera_status_handler (occlusion)","camera_status_handler"),
    ("AEC warmup fix",                   "_warmup = camera.capture_request()"),
    ("get_transcript_handler",           "get_transcript_handler"),
    ("TCP_NODELAY",                      "TCP_NODELAY"),
    ("256 KB chunks",                    "256 * 1024"),
    ("shutdown_handler",                 "shutdown_handler"),
    ("restart_device_handler",           "restart_device_handler"),
    ("clear_cache_handler",              "clear_cache_handler"),
    ("_heartbeat_worker",                "_heartbeat_worker"),
    ("battery=POWERED ON",               "POWERED ON"),
    ("res is not None guard",            "res is not None"),
    ("TRANSFER_FILES intent",            '"TRANSFER_FILES"'),
    ("TAKE_SNAPSHOT intent",             '"TAKE_SNAPSHOT"'),
    ("CAMERA_STATUS intent",             '"CAMERA_STATUS"'),
    ("SHUTDOWN intent",                  '"SHUTDOWN"'),
    ("RESTART_DEVICE intent",            '"RESTART_DEVICE"'),
    ("CLEAR_CACHE intent",               '"CLEAR_CACHE"'),
    ("GET_TRANSCRIPT intent",            '"GET_TRANSCRIPT"'),
]
all_ok = True
for label, needle in checks:
    ok = needle in src
    print(f"  {'✓' if ok else '✗ MISSING':<12} {label}")
    if not ok:
        all_ok = False
sys.exit(0 if all_ok else 1)
VERIFY_EOF

# ── sudoers for shutdown/reboot ───────────────────────────────────────────────
log_section "Verifying sudo permissions"
SERVICE_USER=$(systemctl show evvos-picam-tcp.service -p User --value 2>/dev/null || echo "root")
if [ "$SERVICE_USER" != "root" ] && [ -n "$SERVICE_USER" ]; then
    SUDOERS_FILE="/etc/sudoers.d/evvos-device-mgmt"
    cat > "$SUDOERS_FILE" << SUDOERS
${SERVICE_USER} ALL=(ALL) NOPASSWD: /sbin/shutdown
${SERVICE_USER} ALL=(ALL) NOPASSWD: /sbin/reboot
SUDOERS
    chmod 0440 "$SUDOERS_FILE"
    log_success "Sudoers: $SERVICE_USER can shutdown + reboot without password"
else
    log_success "Service runs as root — no sudoers needed"
fi

# ── Restart ───────────────────────────────────────────────────────────────────
log_section "Restarting evvos-picam-tcp service"
systemctl restart evvos-picam-tcp.service
sleep 2

if systemctl is-active --quiet evvos-picam-tcp.service; then
    log_success "Service running"
else
    log_error "Service failed to start"
    journalctl -u evvos-picam-tcp -n 40 --no-pager
    exit 1
fi

echo ""
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  All intents available:${NC}"
echo -e "${CYAN}    START_RECORDING    STOP_RECORDING    TAKE_SNAPSHOT${NC}"
echo -e "${CYAN}    TRANSFER_FILES     GET_TRANSCRIPT    CAMERA_STATUS${NC}"
echo -e "${CYAN}    GET_STATUS         SHUTDOWN          RESTART_DEVICE${NC}"
echo -e "${CYAN}    CLEAR_CACHE        UPLOAD_TO_SUPABASE${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Watch live: journalctl -u evvos-picam-tcp -f${NC}"
echo ""
log_success "Complete setup done!"
