#!/bin/bash
# EVVOS Pi Camera Setup - 24 FPS Speed Fix + Resilient Disconnect + Supabase Upload + Shared Audio
# Optimized for: Raspberry Pi Zero 2 W

set -e  # Exit on error

# ============================================================================
# CONFIGURATION & COLOR OUTPUT
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_section() { echo -e "\n${CYAN}════════════════════════════════════════════════════════${NC}\n${CYAN}▶ $1${NC}\n${CYAN}════════════════════════════════════════════════════════${NC}"; }

# ============================================================================
# PREFLIGHT CHECKS & USER DETECTION
# ============================================================================
log_section "Preflight System Checks"

if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

if [ -n "$SUDO_USER" ]; then
    ACTUAL_USER="$SUDO_USER"
else
    ACTUAL_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' /etc/passwd)
fi

ACTUAL_HOME=$(eval echo ~$ACTUAL_USER)
RECORDINGS_DIR="$ACTUAL_HOME/recordings"

log_success "Detected user: $ACTUAL_USER"
log_success "Recordings directory: $RECORDINGS_DIR"

CONFIG_FILE="/boot/firmware/config.txt"
[ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="/boot/config.txt"

# ============================================================================
# STEP 1: ENABLE CAMERA & INSTALL DEPENDENCIES
# ============================================================================
log_section "Step 1 & 2: System Config and Dependencies"

grep -q "^start_x=1" "$CONFIG_FILE" || echo "start_x=1" >> "$CONFIG_FILE"
grep -q "^gpu_mem="   "$CONFIG_FILE" || echo "gpu_mem=128" >> "$CONFIG_FILE"

apt-get update -qq
apt-get install -y \
    python3-picamera2 python3-requests ffmpeg \
    pulseaudio pulseaudio-utils \
    git cmake build-essential \
    libopenblas-dev \
    --no-install-recommends
log_success "Camera firmware and dependencies ready"

# ============================================================================
# STEP 2.5: INSTALL WHISPER.CPP  (32-bit ARM / armhf — Bookworm compatible)
# ============================================================================
# WHY whisper.cpp instead of faster-whisper / whisper-ctranslate2:
#
#   • ctranslate2 (required by both faster-whisper and whisper-ctranslate2)
#     publishes NO pre-built armhf wheel on PyPI.  `pip install ctranslate2`
#     fails immediately on any 32-bit Raspberry Pi OS.
#
#   • openai-whisper requires PyTorch.  The official torch project stopped
#     publishing armhf wheels; the Debian package (python3-torch in Bookworm)
#     is built without Metal/CUDA and peaks at ~470 MB RSS on tiny — leaving
#     virtually zero headroom on the Pi Zero 2 W's 512 MB.
#
#   • whisper.cpp is pure C++17, compiles cleanly on armhf Bookworm, links
#     against OpenBLAS for BLAS-accelerated matrix ops, and uses only ~75 MB
#     RSS with the tiny.en GGML model.  Inference time: 60–120 s on Pi Zero 2 W.
# ============================================================================
log_section "Step 2.5: Building whisper.cpp (32-bit ARM, OpenBLAS, swap-assisted)"

WHISPER_DIR="/opt/whisper.cpp"
WHISPER_MODEL_NAME="tiny.en"
WHISPER_MODEL_FILE="${WHISPER_DIR}/models/ggml-${WHISPER_MODEL_NAME}.bin"
WHISPER_BIN="${WHISPER_DIR}/build/bin/whisper-cli"

# ── Clone (or update) ─────────────────────────────────────────────────────────
if [ -d "$WHISPER_DIR/.git" ]; then
    log_info "whisper.cpp already cloned — pulling latest..."
    git -C "$WHISPER_DIR" pull --ff-only || true
else
    log_info "Cloning whisper.cpp..."
    git clone --depth=1 https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR"
fi

# ── Patch CMakeLists.txt to link libatomic on every target ────────────────────
# On 32-bit ARM (armhf), 64-bit atomic operations are not native CPU instructions.
# GCC emits calls to libgcc_s/libatomic helpers (__atomic_load_8 etc.) for any
# 64-bit std::atomic usage — which miniaudio inside common-whisper.cpp requires.
#
# cmake's LDFLAGS env var and CMAKE_EXE_LINKER_FLAGS are both unreliable here:
# cmake 3.25 reads LDFLAGS only during compiler probe, not during target linking;
# CMAKE_EXE_LINKER_FLAGS set via -D gets overridden by the project per-target.
#
# The only guaranteed mechanism is link_libraries(atomic) in CMakeLists.txt itself,
# which cmake propagates to every target in the project unconditionally.
# We inject it right after cmake_minimum_required so it applies globally.
CMAKELISTS="${WHISPER_DIR}/CMakeLists.txt"
ATOMIC_INJECT="link_libraries(atomic)  # armhf 32-bit: supply __atomic_load_8 etc."

if grep -q "link_libraries(atomic)" "$CMAKELISTS" 2>/dev/null; then
    log_info "CMakeLists.txt already patched for libatomic — skipping"
else
    # Insert after the first cmake_minimum_required(...) line
    sed -i "/^cmake_minimum_required/a ${ATOMIC_INJECT}" "$CMAKELISTS"
    log_success "Patched CMakeLists.txt: injected link_libraries(atomic)"
fi

# ── Swap file (REQUIRED on Pi Zero 2 W — 512 MB RAM is not enough to compile) ─
# The C++ compiler peaks at ~480 MB RSS on the heaviest whisper.cpp translation
# units.  Without extra swap the kernel OOM-kills the compiler at ~84% and the
# build exits silently.  We create a 1 GB swapfile, build, then remove it.
SWAP_FILE="/swapfile_whisper_build"
SWAP_CREATED=0

if [ ! -f "$SWAP_FILE" ]; then
    log_info "Creating temporary 1 GB swapfile for compilation..."
    # fallocate is fastest; fall back to dd if the filesystem doesn't support it
    if fallocate -l 1G "$SWAP_FILE" 2>/dev/null; then
        log_success "Swapfile allocated with fallocate"
    else
        log_info "fallocate failed — using dd (slower, ~30 s)..."
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count=1024 status=progress
    fi
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    SWAP_CREATED=1
    log_success "Swapfile active — $(free -h | awk '/^Swap/{print $2}') swap available"
else
    log_info "Swapfile already exists — skipping creation"
    swapon "$SWAP_FILE" 2>/dev/null || true
    SWAP_CREATED=1
fi

# ── CMake build with OpenBLAS ─────────────────────────────────────────────────
# Flag name changed in whisper.cpp ≥ 1.7: WHISPER_BLAS → GGML_BLAS.
# We detect which one cmake accepts and use the correct one automatically.
# -j1 (single job) is mandatory — parallel compile OOMs the Pi Zero 2 W.
# Build takes 30–45 min on Pi Zero 2 W with a single core — this is expected.
log_info "Configuring whisper.cpp (detecting BLAS cmake flag)..."

BLAS_FLAG="-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS"
# Try the new flag first; fall back to the old name for older checkouts
if ! cmake -B "${WHISPER_DIR}/build_flagtest" \
           -S "${WHISPER_DIR}" \
           -DGGML_BLAS=ON \
           -DCMAKE_BUILD_TYPE=Release \
           -DWHISPER_NO_AVX=ON \
           -DWHISPER_NO_AVX2=ON \
           -DWHISPER_NO_F16C=ON \
           -DWHISPER_NO_FMA=ON \
           --log-level=WARNING \
           -Wno-dev \
           > /dev/null 2>&1; then
    BLAS_FLAG="-DWHISPER_BLAS=ON -DWHISPER_BLAS_VENDOR=OpenBLAS"
    log_info "Using legacy WHISPER_BLAS flag"
else
    log_info "Using GGML_BLAS flag (whisper.cpp ≥ 1.7)"
fi
rm -rf "${WHISPER_DIR}/build_flagtest"

log_info "Building whisper.cpp — single core, ~30–45 min on Pi Zero 2 W. Do not interrupt..."

# Always wipe the build directory — cmake caches broken state from prior failures.
if [ -d "${WHISPER_DIR}/build" ]; then
    log_info "Removing stale build directory..."
    rm -rf "${WHISPER_DIR}/build"
fi

# WHY -DWHISPER_BUILD_TESTS=OFF:
# test-vad is the first executable cmake links after building libcommon.a, and
# it's the only target failing. We only need whisper-cli — disabling tests
# skips test-vad entirely and proceeds directly to the binary we need.
cmake -B "${WHISPER_DIR}/build" \
      -S "${WHISPER_DIR}" \
      $BLAS_FLAG \
      -DWHISPER_NO_AVX=ON \
      -DWHISPER_NO_AVX2=ON \
      -DWHISPER_NO_F16C=ON \
      -DWHISPER_NO_FMA=ON \
      -DCMAKE_BUILD_TYPE=Release \
      -DWHISPER_BUILD_TESTS=OFF \
      -Wno-dev

# -j1: one compiler process at a time — prevents OOM on 512 MB + 1 GB swap
cmake --build "${WHISPER_DIR}/build" --config Release -j1

# ── Remove temporary swapfile now that the build is done ──────────────────────
if [ "$SWAP_CREATED" -eq 1 ] && [ -f "$SWAP_FILE" ]; then
    swapoff "$SWAP_FILE" 2>/dev/null || true
    rm -f "$SWAP_FILE"
    log_success "Temporary swapfile removed"
fi

# Confirm binary exists (name changed from `main` → `whisper-cli` in 1.6+)
if [ ! -f "$WHISPER_BIN" ]; then
    WHISPER_BIN_LEGACY="${WHISPER_DIR}/build/bin/main"
    if [ -f "$WHISPER_BIN_LEGACY" ]; then
        ln -sf "$WHISPER_BIN_LEGACY" "$WHISPER_BIN"
        log_info "Symlinked legacy 'main' binary → whisper-cli"
    else
        log_error "whisper-cli binary not found after build — check cmake output"
        exit 1
    fi
fi
log_success "whisper.cpp built: $WHISPER_BIN"

# ── Download tiny.en GGML model ───────────────────────────────────────────────
# tiny.en: 77 MB, English-only, fastest on CPU, sufficient for field audio.
# For multilingual support swap to 'tiny' (same size, slightly lower accuracy).
if [ -f "$WHISPER_MODEL_FILE" ]; then
    log_info "Model already downloaded: $WHISPER_MODEL_FILE"
else
    log_info "Downloading ggml-${WHISPER_MODEL_NAME}.bin (~77 MB)..."
    bash "${WHISPER_DIR}/models/download-ggml-model.sh" "$WHISPER_MODEL_NAME"
    if [ ! -f "$WHISPER_MODEL_FILE" ]; then
        log_error "Model download failed — check internet access and try again"
        exit 1
    fi
fi
log_success "Model ready: $WHISPER_MODEL_FILE"

# ── Smoke-test ────────────────────────────────────────────────────────────────
if "$WHISPER_BIN" --help >/dev/null 2>&1; then
    log_success "whisper-cli smoke-test passed"
else
    log_error "whisper-cli --help failed — binary may be corrupt"
    exit 1
fi

# ── Write config file for the Python service ──────────────────────────────────
mkdir -p /etc/evvos
cat > /etc/evvos/whisper.env << WENV_EOF
WHISPER_BIN=${WHISPER_BIN}
WHISPER_MODEL=${WHISPER_MODEL_FILE}
WENV_EOF
log_success "Whisper config written to /etc/evvos/whisper.env"

# ============================================================================
# STEP 3: CREATE ENHANCED TCP CAMERA SERVICE SCRIPT
# ============================================================================
log_section "Step 3: Creating Enhanced Python Service"

CAMERA_SCRIPT="/usr/local/bin/evvos-picam-tcp.py"

cat > "$CAMERA_SCRIPT" << 'CAMERA_SCRIPT_EOF'
#!/usr/bin/env python3
"""
EVVOS Pi Camera TCP Control Service
  - 24 FPS Speed Fixed
  - Resilient to phone disconnect
  - Muxes shared audio (dsnoop) with ffmpeg
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
TCP_HOST      = "0.0.0.0"
TCP_PORT      = 3001
HTTP_PORT     = 8080
RECORDINGS_DIR = Path("/home/pi/recordings")
CAMERA_RES    = (1280, 720)   # Optimized for Pi Zero 2 W stability
CAMERA_FPS    = 24.0

# ── GLOBAL STATE ──────────────────────────────────────────────────────────────
camera               = None
recording            = False
recording_lock       = threading.Lock()
current_session_id   = None
current_video_path   = None
current_audio_path   = None
audio_process        = None
recording_start_time = None

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
    """
    Match Philippine LTO plate formats in the transcript.
    Common formats:
      Private vehicles  : ABC 1234  or  ABC-1234  (3 alpha + 4 digits)
      Motorcycles       : 1234 AB   or  1234-AB   (4 digits + 2 alpha)
      Government/PNP    : SFX 123   (3 alpha + 3 digits, rare but possible)
    """
    patterns = [
        r'\b([A-Z]{3})[\s\-]?(\d{4})\b',   # ABC 1234 — most common private
        r'\b([A-Z]{3})[\s\-]?(\d{3})\b',    # ABC 123  — gov/special series
        r'\b(\d{4})[\s\-]?([A-Z]{2})\b',    # 1234 AB  — motorcycle
    ]
    for pat in patterns:
        m = _re.search(pat, text.upper())
        if m:
            return ' '.join(m.groups())
    return ''


def _extract_driver_name(text: str) -> str:
    """
    Heuristic: look for common name-announcing phrases spoken by the officer.
    Works best when the officer says "Driver is Juan dela Cruz" or
    "name: Juan dela Cruz" into the mic.  Falls back to empty string.
    """
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


def transcribe_audio(audio_path: Path) -> dict:
    """
    Run whisper.cpp on the recorded WAV, return:
      { transcript, driver_name, plate_number, violations }

    whisper-cli flags used:
      -m  model path
      -f  input audio (WAV / any FFmpeg-readable format)
      -otxt          write transcript to <audio>.txt
      -nt            no timestamps (cleaner output)
      -np            no progress bar
      -l  en         force English (tiny.en model is English-only)
      --threads 2    use both cores on Pi Zero 2 W
    """
    empty = {"transcript": "", "driver_name": "", "plate_number": "", "violations": []}

    if not Path(WHISPER_BIN).exists():
        print(f"[WHISPER] Binary not found: {WHISPER_BIN} — skipping transcription")
        return empty
    if not Path(WHISPER_MODEL).exists():
        print(f"[WHISPER] Model not found: {WHISPER_MODEL} — skipping transcription")
        return empty
    if not audio_path.exists() or audio_path.stat().st_size < 1000:
        print("[WHISPER] Audio file missing or too small — skipping transcription")
        return empty

    print(f"[WHISPER] Transcribing {audio_path.name} (60–120 s on Pi Zero 2 W)...")
    txt_path = audio_path.with_suffix(audio_path.suffix + ".txt")  # e.g. audio_*.wav.txt

    try:
        result = subprocess.run(
            [
                WHISPER_BIN,
                "-m",  WHISPER_MODEL,
                "-f",  str(audio_path),
                "-otxt",          # write <audio>.txt
                "-nt",            # no timestamps
                "-np",            # no progress
                "-l",  "en",      # force English
                "--threads", "2", # use both A53 cores
            ],
            capture_output=True,
            text=True,
            timeout=300,          # 5 min absolute hard limit
        )

        if result.returncode != 0:
            print(f"[WHISPER] Non-zero exit {result.returncode}: {result.stderr[:200]}")
            # Still try to read partial output if the txt was written
        
        # Prefer the .txt sidecar file (most reliable)
        if txt_path.exists():
            transcript = txt_path.read_text(encoding="utf-8", errors="replace").strip()
            txt_path.unlink(missing_ok=True)  # clean up
        else:
            transcript = result.stdout.strip()

        if not transcript:
            print("[WHISPER] Transcription produced no output")
            return empty

        print(f"[WHISPER] ✓ Transcript ({len(transcript)} chars): {transcript[:120]}...")

        driver_name  = _extract_driver_name(transcript)
        plate_number = _extract_plate_number(transcript)
        violations   = _extract_violations(transcript)

        print(f"[WHISPER] Driver: {driver_name!r}  Plate: {plate_number!r}  Violations: {violations}")
        return {
            "transcript":   transcript,
            "driver_name":  driver_name,
            "plate_number": plate_number,
            "violations":   violations,
        }

    except subprocess.TimeoutExpired:
        print("[WHISPER] Transcription timed out after 5 min — returning empty")
        return empty
    except Exception as e:
        print(f"[WHISPER] Unexpected error: {e}")
        return empty

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
            ts                   = datetime.now().strftime("%Y%m%d_%H%M%S")
            current_session_id   = f"session_{ts}"
            current_video_path   = RECORDINGS_DIR / f"video_{ts}.h264"
            current_audio_path   = RECORDINGS_DIR / f"audio_{ts}.wav"
            recording_start_time = time.time()

            print(f"[CAMERA] Starting: {current_session_id}")
            encoder = H264Encoder(bitrate=2500000, framerate=CAMERA_FPS)
            camera.start_recording(encoder, str(current_video_path))

            # Record audio via PulseAudio — allows concurrent access with PicoVoice.
            # PulseAudio runs as a system daemon (started before both services) and
            # acts as a hardware abstraction layer, so multiple clients can capture
            # from the ReSpeaker simultaneously without EBUSY conflicts.
            audio_process = subprocess.Popen([
                "arecord", "-D", "pulse", "-f", "S16_LE", "-r", "16000", "-c", "1", str(current_audio_path)
            ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

            # Give arecord a moment to open and verify it started cleanly
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


def get_status_handler():
    with recording_lock:
        elapsed = int(time.time() - recording_start_time) if recording_start_time else 0
        return {
            "status":       "status_ok",
            "recording":    recording,
            "session_id":   current_session_id,
            "video_path":   str(current_video_path) if current_video_path else None,
            "pi_ip":        get_pi_ip(),
            "http_port":    HTTP_PORT,
            "elapsed_seconds": elapsed,
        }


def stop_recording_handler():
    global recording, current_session_id, current_video_path, current_audio_path, audio_process, recording_start_time
    with recording_lock:
        if not recording:
            return {"status": "not_recording"}
        try:
            print("[CAMERA] Stopping...")
            camera.stop_recording()
            camera.stop()
            
            # Stop audio gracefully
            if audio_process:
                audio_process.terminate()
                try:
                    audio_process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    audio_process.kill()

            recording            = False
            recording_start_time = None
            time.sleep(0.5)

            mp4_path = current_video_path.with_suffix(".mp4")
            raw_size = current_video_path.stat().st_size if current_video_path.exists() else 0
            print(f"[CAMERA] Raw H264 size: {raw_size / 1024 / 1024:.2f} MB")

            # ── SPEED FIX & AUDIO MUXING ──────────────────
            print("[FFMPEG] Muxing audio & fixing speed (Constant 24 FPS)...")
            has_audio = current_audio_path and current_audio_path.exists() and current_audio_path.stat().st_size > 1000
            
            cmd = [
                "ffmpeg", "-y",
                "-r", "24", "-i", str(current_video_path)
            ]
            
            if has_audio:
                cmd.extend(["-i", str(current_audio_path)])
                
            cmd.extend([
                "-vf", "setpts=N/(24*TB)",
                "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
                "-r", "24", "-fps_mode", "cfr"
            ])
            
            if has_audio:
                cmd.extend(["-c:a", "aac", "-b:a", "128k"])
            else:
                cmd.extend(["-an"])
                
            cmd.extend([
                "-movflags", "+faststart", "-loglevel", "error",
                str(mp4_path)
            ])
            
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)

            if res.returncode == 0:
                size_mb = mp4_path.stat().st_size / 1024 / 1024
                print(f"[FFMPEG] ✓ Success: {mp4_path.name} ({size_mb:.2f} MB)")
                current_video_path.unlink(missing_ok=True)
                # NOTE: keep current_audio_path alive — whisper reads it next
            else:
                print(f"[FFMPEG] Error: {res.stderr}")
                size_mb = mp4_path.stat().st_size / 1024 / 1024 if mp4_path.exists() else 0

            # ── WHISPER TRANSCRIPTION ──────────────────────────────────────────
            # Run AFTER ffmpeg so audio is no longer being written.
            # The raw WAV is kept until transcription completes, then deleted.
            transcription = {"transcript": "", "driver_name": "", "plate_number": "", "violations": []}
            if current_audio_path and current_audio_path.exists():
                transcription = transcribe_audio(current_audio_path)
                # Now safe to clean up the raw WAV
                try:
                    current_audio_path.unlink(missing_ok=True)
                except Exception as _e:
                    print(f"[CAMERA] Could not delete audio file: {_e}")
            # ──────────────────────────────────────────────────────────────────

            return {
                "status":         "recording_stopped",
                "session_id":     current_session_id,
                "video_filename": mp4_path.name,
                "video_path":     str(mp4_path),
                "video_size_mb":  round(size_mb, 2),
                "video_url":      f"http://{get_pi_ip()}:{HTTP_PORT}/{mp4_path.name}",
                "pi_ip":          get_pi_ip(),
                "http_port":      HTTP_PORT,
                # ── Transcription fields (pre-fill IncidentSummaryScreen) ────
                "transcript":   transcription["transcript"],
                "driver_name":  transcription["driver_name"],
                "plate_number": transcription["plate_number"],
                "violations":   transcription["violations"],
            }
        except Exception as e:
            print(f"[CAMERA] Stop Error: {e}")
            return {"status": "error", "message": str(e)}


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
            # ── Audio stream verification (logged before file is deleted) ──────
            try:
                probe = subprocess.run(
                    ["ffprobe", "-v", "quiet", "-show_streams", "-select_streams", "a", str(file_path)],
                    capture_output=True, text=True
                )
                if probe.stdout.strip():
                    print(f"[UPLOAD] ✓ Audio stream confirmed in uploaded file")
                else:
                    print(f"[UPLOAD] ⚠ No audio stream found in uploaded file — check arecord/dsnoop")
            except Exception as probe_err:
                print(f"[UPLOAD] ffprobe check failed: {probe_err}")
            # ────────────────────────────────────────────────────────────────────
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
                print(f"[TCP] Client {addr} disconnected ({e.__class__.__name__}: {e}). Recording active: {recording}")
                break

            if not data:
                print(f"[TCP] Client {addr} closed connection. Recording active: {recording}")
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
                    elif intent == "UPLOAD_TO_SUPABASE":
                        res = upload_to_supabase_handler(
                            payload.get("incident_id"),
                            payload.get("auth_token"),
                            payload.get("video_filename"),
                        )
                    elif intent == "GET_STATUS":
                        res = get_status_handler()
                    else:
                        res = {"status": "unknown_intent", "intent": intent}

                    try:
                        conn.sendall((json.dumps(res) + "\n").encode("utf-8"))
                        print(f"[TCP] → {res.get('status')} to {addr}")
                    except (BrokenPipeError, OSError) as send_err:
                        print(f"[TCP] Could not send response to {addr}: {send_err}. Recording active: {recording}")
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
        print(f"[TCP] Thread for {addr} exited. Recording active: {recording}")

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
            threading.Thread(
                target=handle_client,
                args=(conn, addr),
                daemon=True,
            ).start()
CAMERA_SCRIPT_EOF

chmod +x "$CAMERA_SCRIPT"
log_success "Service script created with PulseAudio shared audio"

# ============================================================================
# STEP 4: PULSEAUDIO SYSTEM SERVICE
# ============================================================================
log_section "Step 4: PulseAudio System Service"

# Add users to pulse-access group so services can connect to PulseAudio
usermod -aG pulse-access root
usermod -aG pulse-access "$ACTUAL_USER"
log_success "Added root and $ACTUAL_USER to pulse-access group"

# Create PulseAudio system service
cat > /etc/systemd/system/pulseaudio-system.service << 'PULSE_SERVICE_EOF'
[Unit]
Description=PulseAudio System-Wide Daemon
Before=evvos-picam-tcp.service evvos-pico-voice.service

[Service]
Type=notify
ExecStart=/usr/bin/pulseaudio --system --daemonize=no --disallow-exit --disallow-module-loading --log-target=journal
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
PULSE_SERVICE_EOF

systemctl daemon-reload
systemctl enable pulseaudio-system.service

# Kill any existing PulseAudio instance cleanly before starting the service
pkill -u pulse pulseaudio 2>/dev/null || true
sleep 1

systemctl restart pulseaudio-system.service
sleep 2

if systemctl is-active --quiet pulseaudio-system.service; then
    log_success "PulseAudio system service running"
    pactl list sources short 2>/dev/null | grep -v monitor | head -5 || true
else
    log_error "PulseAudio failed to start — check: journalctl -u pulseaudio-system -n 20"
fi

# ============================================================================
# STEP 5: SYSTEMD SERVICE & DIRECTORIES
# ============================================================================
log_section "Step 5: Camera Service and Permissions"

SERVICE_FILE="/etc/systemd/system/evvos-picam-tcp.service"
cat > "$SERVICE_FILE" << SERVICE_EOF
[Unit]
Description=EVVOS Pi Camera TCP Service
After=network.target pulseaudio-system.service
Requires=pulseaudio-system.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 $CAMERA_SCRIPT
Restart=always
RestartSec=5
Environment="PYTHONUNBUFFERED=1"
EnvironmentFile=-/etc/evvos/config.env
EnvironmentFile=-/etc/evvos/whisper.env

[Install]
WantedBy=multi-user.target
SERVICE_EOF

mkdir -p "$RECORDINGS_DIR"
chown "$ACTUAL_USER:$ACTUAL_USER" "$RECORDINGS_DIR"
chmod 755 "$RECORDINGS_DIR"

systemctl daemon-reload
systemctl enable evvos-picam-tcp.service
systemctl restart evvos-picam-tcp.service

log_success "Service installed and started"
log_success "Setup complete!"
echo ""
echo -e "${CYAN}  Whisper binary : ${WHISPER_BIN}${NC}"
echo -e "${CYAN}  Whisper model  : ${WHISPER_MODEL_FILE}${NC}"
echo -e "${CYAN}  Transcription  : ~60–120 s per recording on Pi Zero 2 W (tiny.en, CPU)${NC}"
echo -e "${CYAN}  To swap model  : edit /etc/evvos/whisper.env and restart evvos-picam-tcp${NC}"
echo ""
log_success "Camera records via PulseAudio. Whisper transcription runs after each stop."
