#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Complete Service Rewrite
#
# This script completely overwrites /usr/local/bin/evvos-picam-tcp.py.
# No patching, no anchor strings — just writes the full working service.
#
# Based exactly on: setup_picam_4.sh + setup_picam_transfer_5.sh
#
# Speed optimisation added on top:
#   BEFORE: STOP_RECORDING blocks for ffmpeg (~30-90s) THEN transcription
#           (~5-120s) before responding. Phone waits up to 3-4 minutes.
#
#   AFTER:  STOP_RECORDING blocks for ffmpeg only (~30-90s), then returns.
#           Transcription runs in a background thread simultaneously.
#           TRANSFER_FILES waits up to 15s for the transcript sidecar
#           (Groq usually finishes in 5-10s so it's almost always ready).
#           Saves 5-120s of dead wait time before the phone can proceed.
#
# Also includes (done correctly, no partial-patch issues):
#   • TAKE_SNAPSHOT  — camera.capture_image() during active recording
#   • TRANSFER_FILES — TCP_NODELAY + 256 KB chunks for fastest transfer
#   • GET_TRANSCRIPT — fallback poll if sidecar wasn't ready at transfer time
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_complete.sh
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
    log_error "Run setup_picam_4.sh first (installs dependencies, whisper, systemd unit)."
    exit 1
fi

log_section "EVVOS Pi Camera — Complete Service Rewrite"

BACKUP="${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CAMERA_SCRIPT" "$BACKUP"
log_success "Backup: $BACKUP"

# Write the complete Python service in one shot
cat > "$CAMERA_SCRIPT" << 'CAMERA_EOF'
#!/usr/bin/env python3
"""
EVVOS Pi Camera TCP Control Service
  - 24 FPS Speed Fixed
  - Resilient to phone disconnect
  - Muxes shared audio (PulseAudio) with ffmpeg
  - TRANSFER_FILES: sends .mp4 + .jpg + transcript to phone over TCP
  - TAKE_SNAPSHOT:  captures JPEG still during active recording
  - Async transcription: STOP_RECORDING returns after ffmpeg, not after Groq/Whisper
"""
import socket, json, os, sys, time, threading, subprocess
from datetime import datetime
from pathlib import Path

try:
    from picamera2 import Picamera2
    from picamera2.encoders import H264Encoder
except ImportError:
    print("[CAMERA] ERROR: picamera2 not installed", file=sys.stderr)
    sys.exit(1)

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

# Background transcription results keyed by session_id.
# Populated by _bg_transcribe() after STOP_RECORDING; read by GET_TRANSCRIPT.
_transcript_state = {}  # { session_id: {"status": "pending"|"complete", ...} }

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
        config = camera.create_video_configuration(
            main={"size": CAMERA_RES, "format": "RGB888"},
            encode="main",
            controls={"FrameRate": CAMERA_FPS, "FrameDurationLimits": (41666, 41666)}
        )
        camera.configure(config)
        camera.set_controls({"FrameDurationLimits": (41666, 41666)})
        print(f"[CAMERA] ✓ Ready at {CAMERA_RES} @ {CAMERA_FPS} FPS")
        return True
    except Exception as e:
        print(f"[CAMERA] ERROR: {e}")
        return False

# ── WHISPER TRANSCRIPTION ─────────────────────────────────────────────────────
import re as _re, os as _os

WHISPER_BIN   = _os.environ.get("WHISPER_BIN",   "/opt/whisper.cpp/build/bin/whisper-cli")
WHISPER_MODEL = _os.environ.get("WHISPER_MODEL",  "/opt/whisper.cpp/models/ggml-tiny.en.bin")


def _extract_plate_number(text: str) -> str:
    patterns = [
        r'\b([A-Z]{3})[\s\-]?(\d{4})\b',
        r'\b([A-Z]{3})[\s\-]?(\d{3})\b',
        r'\b(\d{4})[\s\-]?([A-Z]{2})\b',
    ]
    for pat in patterns:
        m = _re.search(pat, text.upper())
        if m:
            return ' '.join(m.groups())
    return ''


def _extract_driver_name(text: str) -> str:
    patterns = [
        r"(?:driver(?:'s)?\s+(?:name\s+)?is|name\s*[:is]+)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3})",
        r"(?:apprehended|stopped)\s+(?:a\s+)?(?:driver\s+)?([A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3})",
    ]
    for pat in patterns:
        m = _re.search(pat, text, _re.IGNORECASE)
        if m:
            return m.group(1).strip()
    return ''


_VIOLATION_KEYWORDS = {
    "beating the red light":      "Beating Red Light",
    "ran a red light":            "Beating Red Light",
    "red light":                  "Beating Red Light",
    "no helmet":                  "No Helmet",
    "overspeeding":               "Overspeeding",
    "over speed":                 "Overspeeding",
    "speeding":                   "Overspeeding",
    "illegal parking":            "Illegal Parking",
    "no seatbelt":                "No Seatbelt",
    "seatbelt":                   "No Seatbelt",
    "no license":                 "No Driver's License",
    "no driver's license":        "No Driver's License",
    "expired license":            "Expired License",
    "expired registration":       "Expired Registration",
    "no registration":            "No Registration",
    "reckless driving":           "Reckless Driving",
    "counterflow":                "Counterflow",
    "counter flow":               "Counterflow",
    "obstruction":                "Obstruction",
    "loading":                    "Illegal Loading/Unloading",
    "unloading":                  "Illegal Loading/Unloading",
    "no or":                      "No Official Receipt",
    "no cr":                      "No Certificate of Registration",
    "smoke belching":             "Smoke Belching",
    "colorum":                    "Colorum",
    "no franchise":               "No Franchise",
}


def _extract_violations(text: str) -> list:
    found = []
    lower = text.lower()
    for keyword, label in _VIOLATION_KEYWORDS.items():
        if keyword in lower and label not in found:
            found.append(label)
    return found


def _has_internet(host="8.8.8.8", port=53, timeout=3) -> bool:
    import socket as _socket
    try:
        with _socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _transcribe_groq_online(audio_path: Path) -> dict:
    import requests as _req, os as _os

    api_key = _os.environ.get("GROQ_API_KEY", "").strip()
    if not api_key:
        print("[GROQ] GROQ_API_KEY not set — skipping online STT")
        return None

    if not audio_path.exists() or audio_path.stat().st_size < 1000:
        print("[GROQ] Audio file missing or too small")
        return None

    print(f"[GROQ] Uploading {audio_path.name} ({audio_path.stat().st_size / 1024:.0f} KB)...")
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
            print("[GROQ] API returned empty transcript")
            return None

        print(f"[GROQ] ✓ Transcript ({len(transcript)} chars): {transcript[:120]}...")
        driver_name  = _extract_driver_name(transcript)
        plate_number = _extract_plate_number(transcript)
        violations   = _extract_violations(transcript)
        print(f"[GROQ] Driver: {driver_name!r}  Plate: {plate_number!r}  Violations: {violations}")
        return {
            "transcript":   transcript,
            "driver_name":  driver_name,
            "plate_number": plate_number,
            "violations":   violations,
            "engine":       "groq-whisper-large-v3-turbo",
        }
    except Exception as e:
        print(f"[GROQ] Request failed: {e}")
        return None


def _transcribe_whisper_offline(audio_path: Path) -> dict:
    empty = {"transcript": "", "driver_name": "", "plate_number": "", "violations": [], "engine": "whisper-tiny.en-offline"}

    if not Path(WHISPER_BIN).exists():
        print(f"[WHISPER] Binary not found: {WHISPER_BIN}")
        return empty
    if not Path(WHISPER_MODEL).exists():
        print(f"[WHISPER] Model not found: {WHISPER_MODEL}")
        return empty
    if not audio_path.exists() or audio_path.stat().st_size < 1000:
        print("[WHISPER] Audio file missing or too small")
        return empty

    print(f"[WHISPER] Offline transcription: {audio_path.name} (60-120s on Pi Zero 2 W)...")
    txt_path = audio_path.with_suffix(audio_path.suffix + ".txt")

    try:
        result = subprocess.run(
            [WHISPER_BIN, "-m", WHISPER_MODEL, "-f", str(audio_path),
             "-otxt", "-nt", "-np", "-l", "en", "--threads", "2"],
            capture_output=True, text=True, timeout=300,
        )
        if result.returncode != 0:
            print(f"[WHISPER] Non-zero exit {result.returncode}: {result.stderr[:200]}")

        if txt_path.exists():
            transcript = txt_path.read_text(encoding="utf-8", errors="replace").strip()
            txt_path.unlink(missing_ok=True)
        else:
            transcript = result.stdout.strip()

        if not transcript:
            print("[WHISPER] No output produced")
            return empty

        print(f"[WHISPER] ✓ Transcript ({len(transcript)} chars): {transcript[:120]}...")
        driver_name  = _extract_driver_name(transcript)
        plate_number = _extract_plate_number(transcript)
        violations   = _extract_violations(transcript)
        return {
            "transcript":   transcript,
            "driver_name":  driver_name,
            "plate_number": plate_number,
            "violations":   violations,
            "engine":       "whisper-tiny.en-offline",
        }
    except subprocess.TimeoutExpired:
        print("[WHISPER] Timed out after 5 min")
        return empty
    except Exception as e:
        print(f"[WHISPER] Unexpected error: {e}")
        return empty


def transcribe_best(audio_path: Path) -> dict:
    empty = {"transcript": "", "driver_name": "", "plate_number": "", "violations": [], "engine": "none"}
    if not audio_path or not audio_path.exists() or audio_path.stat().st_size < 1000:
        print("[TRANSCRIBE] Audio file missing or too small — skipping")
        return empty
    internet = _has_internet()
    print(f"[TRANSCRIBE] Internet: {'✓ online' if internet else '✗ offline'}")
    if internet:
        result = _transcribe_groq_online(audio_path)
        if result:
            print("[TRANSCRIBE] ✓ Used Groq (whisper-large-v3-turbo)")
            return result
        print("[TRANSCRIBE] Groq failed — falling back to local Whisper")
    result = _transcribe_whisper_offline(audio_path)
    print("[TRANSCRIBE] ✓ Used local whisper.cpp (tiny.en, offline)")
    return result

# ── COMMAND HANDLERS ──────────────────────────────────────────────────────────

def start_recording_handler():
    global recording, current_session_id, current_video_path, current_audio_path, audio_process, recording_start_time
    with recording_lock:
        if recording:
            print("[CAMERA] Already recording — returning existing session")
            return {
                "status":          "recording_started",
                "session_id":      current_session_id,
                "video_path":      str(current_video_path),
                "pi_ip":           get_pi_ip(),
                "http_port":       HTTP_PORT,
                "already_running": True,
                "elapsed_seconds": int(time.time() - recording_start_time) if recording_start_time else 0,
            }
        try:
            RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
            snapshot_paths.clear()   # reset per-session snapshot list
            ts                   = datetime.now().strftime("%Y%m%d_%H%M%S")
            current_session_id   = f"session_{ts}"
            current_video_path   = RECORDINGS_DIR / f"video_{ts}.h264"
            current_audio_path   = RECORDINGS_DIR / f"audio_{ts}.wav"
            recording_start_time = time.time()

            print(f"[CAMERA] Starting: {current_session_id}")
            encoder = H264Encoder(bitrate=2500000, framerate=CAMERA_FPS)
            camera.start_recording(encoder, str(current_video_path))

            audio_process = subprocess.Popen(
                ["arecord", "-D", "pulse", "-f", "S16_LE", "-r", "16000", "-c", "1", str(current_audio_path)],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE
            )
            time.sleep(0.5)
            if audio_process.poll() is not None:
                err = audio_process.stderr.read().decode().strip()
                print(f"[CAMERA] Warning: arecord exited immediately: {err}")
                audio_process = None
            else:
                print("[CAMERA] arecord started via PulseAudio")

            recording = True
            return {
                "status":          "recording_started",
                "session_id":      current_session_id,
                "video_path":      str(current_video_path),
                "pi_ip":           get_pi_ip(),
                "http_port":       HTTP_PORT,
                "already_running": False,
                "elapsed_seconds": 0,
            }
        except Exception as e:
            print(f"[CAMERA] Start Error: {e}")
            return {"status": "error", "message": str(e)}


def stop_recording_handler():
    global recording, current_session_id, current_video_path, current_audio_path, audio_process, recording_start_time
    with recording_lock:
        if not recording:
            return {"status": "not_recording"}
        try:
            print("[CAMERA] Stopping...")
            camera.stop_recording()
            camera.stop()

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
            print(f"[CAMERA] Raw H264 size: {raw_size / 1024 / 1024:.2f} MB")

            # ── FFMPEG: H264 + WAV → MP4 ──────────────────────────────────────
            # libx264 + setpts=N/(24*TB): regenerates correct sequential frame
            # timestamps — guarantees a playable MP4 regardless of whether the
            # raw H264 stream had valid PTS values (picamera2's stream does not).
            print("[FFMPEG] Encoding MP4 (libx264 ultrafast + timestamp fix)...")
            has_audio = (
                current_audio_path is not None
                and current_audio_path.exists()
                and current_audio_path.stat().st_size > 1000
            )

            cmd = ["ffmpeg", "-y", "-r", "24", "-i", str(current_video_path)]
            if has_audio:
                cmd.extend(["-i", str(current_audio_path)])
            cmd.extend(["-vf", "setpts=N/(24*TB)",
                        "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
                        "-r", "24", "-fps_mode", "cfr"])
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

            # ── ASYNC TRANSCRIPTION ───────────────────────────────────────────
            # Kick off transcription in a background thread so this handler
            # returns immediately after ffmpeg (~30-90s total) instead of
            # blocking an extra 5-120s for Groq/Whisper.
            #
            # The phone receives "transcription_status": "pending" and can:
            #   1. Call GET_TRANSCRIPT to poll for the result, OR
            #   2. Receive the transcript JSON sidecar bundled inside
            #      TRANSFER_FILES (transfer_files_handler waits up to 15s —
            #      Groq usually finishes in 5-10s so the sidecar is ready).
            _sess = current_session_id
            _wav  = current_audio_path

            def _bg_transcribe(session_id, wav_path):
                _transcript_state[session_id] = {"status": "pending"}
                if wav_path and wav_path.exists():
                    result = transcribe_best(wav_path)
                else:
                    result = {"transcript": "", "driver_name": "", "plate_number": "",
                              "violations": [], "engine": "none"}
                result["status"] = "complete"
                _transcript_state[session_id] = result

                # Write JSON sidecar so TRANSFER_FILES can bundle it with the video
                sidecar = RECORDINGS_DIR / f"transcript_{session_id}.json"
                try:
                    sidecar.write_text(json.dumps(result), encoding="utf-8")
                    print(f"[TRANSCRIBE] ✓ Sidecar written: {sidecar.name}")
                except Exception as _e:
                    print(f"[TRANSCRIBE] Could not write sidecar: {_e}")
                try:
                    if wav_path:
                        wav_path.unlink(missing_ok=True)
                except Exception:
                    pass

            threading.Thread(target=_bg_transcribe, args=(_sess, _wav), daemon=True).start()
            # ──────────────────────────────────────────────────────────────────

            return {
                "status":                "recording_stopped",
                "session_id":            current_session_id,
                "video_filename":        mp4_path.name,
                "video_path":            str(mp4_path),
                "video_size_mb":         round(size_mb, 2),
                "video_url":             f"http://{get_pi_ip()}:{HTTP_PORT}/{mp4_path.name}",
                "pi_ip":                 get_pi_ip(),
                "http_port":             HTTP_PORT,
                # Transcription runs in background — phone receives sidecar via
                # TRANSFER_FILES, or polls GET_TRANSCRIPT directly.
                "transcription_status":  "pending",
                "transcript":            "",
                "driver_name":           "",
                "plate_number":          "",
                "violations":            [],
                "transcription_engine":  "pending",
                # Snapshot summary
                "snapshot_count":        len(snapshot_paths),
                "snapshot_filenames":    [p.name for p in snapshot_paths if p.exists()],
            }
        except Exception as e:
            print(f"[CAMERA] Stop Error: {e}")
            return {"status": "error", "message": str(e)}


def take_snapshot_handler():
    """
    Capture a JPEG still from the current camera view during active recording.
    Uses camera.capture_image("main") — the safe high-level API for grabbing
    still frames without stalling the H264 encoder.
    """
    global snapshot_paths, current_session_id, recording
    if not camera:
        return {"status": "error", "message": "Camera not initialised"}
    if not recording:
        print("[SNAPSHOT] Warning: snapshot requested while not recording")
    try:
        RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
        idx      = len(snapshot_paths)
        pfx      = current_session_id or "nosession"
        filename = f"snapshot_{pfx}_{idx:04d}.jpg"
        snap_path = RECORDINGS_DIR / filename

        image = camera.capture_image("main")
        image.save(str(snap_path), "JPEG", quality=85)

        snapshot_paths.append(snap_path)
        size_kb = snap_path.stat().st_size / 1024
        print(f"[SNAPSHOT] ✓ #{idx}: {filename} ({size_kb:.0f} KB)")
        return {
            "status":   "snapshot_taken",
            "index":    idx,
            "filename": filename,
            "size_kb":  round(size_kb, 1),
        }
    except Exception as e:
        print(f"[SNAPSHOT] Error: {e}")
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
        }


def transfer_files_handler(conn):
    """
    Send .mp4, .jpg, and transcript .json files to the mobile app over TCP.

    Protocol (mirrors receiveFilesFromPi in PiCameraIntegration.jsx):
      1. JSON header line:
         { "status": "transfer_ready", "files": [{"name","size"}, ...] }
      2. For each file: 4-byte LE uint32 size prefix + raw binary bytes
      3. JSON footer line: { "status": "transfer_complete" }

    Speed optimisations vs the original transfer_5 patch:
      • TCP_NODELAY   — flushes JSON header/footer immediately (no Nagle delay)
      • SO_SNDBUF 2MB — larger kernel send buffer, fewer kernel round-trips
      • 256 KB chunks — 4× the original 64 KB, reduces syscall overhead on LAN
      • Waits up to 15s for transcript sidecar — Groq finishes in 5-10s so
        the sidecar is almost always ready; phone gets all three files at once.
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

    # 1. Most recent MP4
    all_mp4 = sorted(RECORDINGS_DIR.glob("*.mp4"), key=lambda f: f.stat().st_mtime, reverse=True)
    if all_mp4:
        mp4 = all_mp4[0]
        files_to_send.append(mp4)
        print(f"[TRANSFER] Video: {mp4.name} ({mp4.stat().st_size / 1024 / 1024:.2f} MB)")

    # 2. JPEG snapshots
    all_jpg = sorted(RECORDINGS_DIR.glob("snapshot_*.jpg"))
    files_to_send.extend(all_jpg)
    if all_jpg:
        print(f"[TRANSFER] Snapshots: {len(all_jpg)} file(s)")

    # 3. Transcript JSON sidecar — wait up to 15s for background transcription.
    #    Groq typically finishes in 5-10s so this almost always succeeds,
    #    bundling all three file types in one transfer.
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
    header = _json.dumps({"status": "transfer_ready", "files": file_meta}) + "\n"
    conn.sendall(header.encode("utf-8"))
    print(f"[TRANSFER] Header sent: {len(files_to_send)} file(s)")

    CHUNK = 256 * 1024  # 256 KB
    transferred = []

    for fp in files_to_send:
        size = fp.stat().st_size
        conn.sendall(struct.pack("<I", size))
        sent = 0
        with open(fp, "rb") as fh:
            while True:
                chunk = fh.read(CHUNK)
                if not chunk:
                    break
                conn.sendall(chunk)
                sent += len(chunk)
        print(f"[TRANSFER] ✓ {fp.name} ({sent / 1024:.1f} KB)")
        transferred.append(fp)

    footer = _json.dumps({"status": "transfer_complete", "file_count": len(transferred)}) + "\n"
    conn.sendall(footer.encode("utf-8"))
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
                "apikey":        anon,
                "Authorization": f"Bearer {auth_token or anon}",
                "Content-Type":  "video/mp4",
                "x-upsert":      "true",
            }, data=fh, timeout=300)

        if resp.status_code in (200, 201):
            print("[UPLOAD] ✓ Storage success")
            public_url = f"{url}/storage/v1/object/public/incident-videos/{storage_path}"
            rpc_url    = f"{url}/rest/v1/rpc/update_incident_video"
            requests.post(rpc_url, headers={
                "apikey":        anon,
                "Authorization": f"Bearer {anon}",
                "Content-Type":  "application/json",
            }, json={
                "p_incident_id":  incident_id,
                "p_video_url":    public_url,
                "p_storage_path": storage_path,
            }, timeout=15)
            file_path.unlink()
            return {"status": "upload_complete", "video_url": public_url, "storage_path": storage_path}
        else:
            print(f"[UPLOAD] HTTP error: {resp.status_code}")
            return {"status": "error", "message": f"HTTP {resp.status_code}"}
    except Exception as e:
        print(f"[UPLOAD] Exception: {e}")
        return {"status": "error", "message": str(e)}

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
                        # Sends binary directly to conn — skips normal JSON path.
                        transfer_files_handler(conn)
                        res = None
                    elif intent == "GET_TRANSCRIPT":
                        res = get_transcript_handler(payload.get("session_id"))
                    elif intent == "GET_STATUS":
                        res = get_status_handler()
                    elif intent == "UPLOAD_TO_SUPABASE":
                        res = upload_to_supabase_handler(
                            payload.get("incident_id"),
                            payload.get("auth_token"),
                            payload.get("video_filename"),
                        )
                    else:
                        res = {"status": "unknown_intent", "intent": intent}

                    try:
                        if res is not None:  # None = TRANSFER_FILES (already responded)
                            conn.sendall((json.dumps(res) + "\n").encode("utf-8"))
                            print(f"[TCP] → {res.get('status')} to {addr}")
                    except (BrokenPipeError, OSError) as send_err:
                        print(f"[TCP] Could not send to {addr}: {send_err}. Recording: {recording}")
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

# ── Quick syntax check ────────────────────────────────────────────────────────
if python3 -m py_compile "$CAMERA_SCRIPT" 2>&1; then
    log_success "Python syntax check passed"
else
    log_error "Syntax error in service script — restoring backup"
    cp "$BACKUP" "$CAMERA_SCRIPT"
    exit 1
fi

# ── Spot-check key features are present ──────────────────────────────────────
CHECKS=(
    "libx264"
    "setpts=N/(24*TB)"
    "_bg_transcribe"
    "transfer_files_handler"
    "take_snapshot_handler"
    "capture_image"
    "TRANSFER_FILES"
    "TAKE_SNAPSHOT"
    "GET_TRANSCRIPT"
    "TCP_NODELAY"
    "256 * 1024"
    "res is not None"
)
all_ok=1
for check in "${CHECKS[@]}"; do
    if grep -qF "$check" "$CAMERA_SCRIPT"; then
        echo -e "  ${GREEN}✓${NC}  $check"
    else
        echo -e "  ${RED}✗${NC}  $check — MISSING"
        all_ok=0
    fi
done

if [ "$all_ok" -eq 0 ]; then
    log_error "One or more expected strings missing — restoring backup"
    cp "$BACKUP" "$CAMERA_SCRIPT"
    exit 1
fi

log_section "Restarting evvos-picam-tcp service"
systemctl restart evvos-picam-tcp.service
sleep 2

if systemctl is-active --quiet evvos-picam-tcp.service; then
    log_success "Service restarted and running"
else
    log_error "Service failed to restart"
    journalctl -u evvos-picam-tcp -n 40 --no-pager
    exit 1
fi

echo ""
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  What changed from the original setup_picam_4.sh${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}  Speed improvement:${NC}"
echo -e "${CYAN}    BEFORE  STOP_RECORDING blocks for ffmpeg (~30-90s)${NC}"
echo -e "${CYAN}            THEN transcription (~5-120s) = up to 3+ min wait${NC}"
echo -e "${CYAN}    AFTER   STOP_RECORDING blocks for ffmpeg only (~30-90s)${NC}"
echo -e "${CYAN}            Transcription runs in background simultaneously${NC}"
echo -e "${CYAN}            TRANSFER_FILES waits max 15s for sidecar${NC}"
echo -e "${CYAN}            (Groq finishes in 5-10s — almost always ready)${NC}"
echo ""
echo -e "${GREEN}  Intents now available:${NC}"
echo -e "${CYAN}    START_RECORDING   — unchanged${NC}"
echo -e "${CYAN}    STOP_RECORDING    — returns after ffmpeg, not after Groq/Whisper${NC}"
echo -e "${CYAN}    TAKE_SNAPSHOT     — captures JPEG during active recording${NC}"
echo -e "${CYAN}    TRANSFER_FILES    — sends mp4 + jpg + transcript sidecar${NC}"
echo -e "${CYAN}    GET_TRANSCRIPT    — poll for transcript if sidecar was missing${NC}"
echo -e "${CYAN}    GET_STATUS        — unchanged${NC}"
echo -e "${CYAN}    UPLOAD_TO_SUPABASE— unchanged (kept for compatibility)${NC}"
echo ""
echo -e "${YELLOW}  Watch live: journalctl -u evvos-picam-tcp -f${NC}"
echo ""
log_success "Done. Record 10s → stop → transfer to confirm."
