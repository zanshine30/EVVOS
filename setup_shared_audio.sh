#!/bin/bash
# ============================================================================
# EVVOS Shared Audio Setup
# Enables simultaneous microphone use by:
#   - evvos-pico-voice  (PicoVoice Rhino voice command recognition)
#   - evvos-picam-tcp   (video + audio recording)
#
# Root cause: ALSA hardware PCM devices (hw:seeed2micvoicec,0) are exclusive.
# Only one process can open them at a time. This script configures ALSA's
# "dsnoop" plugin — a software capture multiplexer — which lets any number of
# processes read from the same physical microphone simultaneously.
#
# What this script does:
#   1. Auto-detects ReSpeaker card name and number
#   2. Writes /etc/asound.conf  — defines the shared virtual mic devices
#   3. Patches /usr/local/bin/evvos-pico-voice-service.py
#              → opens "mic_shared" (dsnoop) instead of the raw hw device
#   4. Patches /usr/local/bin/evvos-picam-tcp.py
#              → adds parallel arecord from "mic_shared" during recording
#              → muxes audio + video in ffmpeg (removes -an flag)
#   5. Restarts both systemd services
#
# Prerequisites:
#   setup_respeaker_enhanced.sh          must have been run (HAT configured)
#   setup_pico_voice_recognition_respeaker.sh  must have been run (voice service installed)
#   setup_picam.sh                       must have been run (camera service installed)
#
# Usage: sudo bash setup_shared_audio.sh
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ${NC}  $1"; }
log_success() { echo -e "${GREEN}✓${NC}  $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC}  $1"; }
log_error()   { echo -e "${RED}✗${NC}  $1"; }
log_section() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}▶ $1${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
}

# ── Root check ────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    log_error "Run as root: sudo bash setup_shared_audio.sh"
    exit 1
fi

# ── Verify prerequisite services exist ────────────────────────────────────────
log_section "Preflight Checks"

VOICE_SCRIPT="/usr/local/bin/evvos-pico-voice-service.py"
CAM_SCRIPT="/usr/local/bin/evvos-picam-tcp.py"

[ -f "$VOICE_SCRIPT" ] || { log_error "Voice service not found: $VOICE_SCRIPT — run setup_pico_voice_recognition_respeaker.sh first"; exit 1; }
[ -f "$CAM_SCRIPT"   ] || { log_error "Camera service not found: $CAM_SCRIPT — run setup_picam.sh first"; exit 1; }

log_success "Both service scripts found"

# ── Auto-detect ReSpeaker card ────────────────────────────────────────────────
CARD_INFO=$(aplay -l 2>/dev/null | grep -i seeed | head -1)
if [ -z "$CARD_INFO" ]; then
    log_error "ReSpeaker HAT not detected (aplay -l | grep seeed returned nothing)"
    log_error "Run setup_respeaker_enhanced.sh and reboot first"
    exit 1
fi

CARD_NUM=$(echo "$CARD_INFO" | grep -oP 'card \K[0-9]+')
CARD_HW_NAME=$(echo "$CARD_INFO" | grep -oP ': \K[^ ]+')   # e.g. seeed2micvoicec
log_success "Detected ReSpeaker: card $CARD_NUM  ($CARD_HW_NAME)"

# ── Backup original scripts ────────────────────────────────────────────────────
log_section "Backing Up Original Scripts"

BACKUP_DIR="/opt/evvos/backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$VOICE_SCRIPT" "$BACKUP_DIR/evvos-pico-voice-service.py.bak"
cp "$CAM_SCRIPT"   "$BACKUP_DIR/evvos-picam-tcp.py.bak"
log_success "Originals backed up to $BACKUP_DIR"

# ============================================================================
# STEP 1 — ALSA dsnoop configuration
# ============================================================================
log_section "Step 1: Configure ALSA dsnoop (Shared Mic)"

# dsnoop explanation:
#   - "mic_shared"   → stereo 16 kHz dsnoop device (multiple readers OK)
#   - "mic_mono"     → plug wrapper: stereo → mono, any-rate → 16 kHz
#   - pcm.!default   → keeps speaker output on the same card; capture → dsnoop
#
# Any process that opens "mic_shared" or "mic_mono" (or the default capture
# device) gets its own independent copy of the microphone audio stream.
# The kernel mixes them in software — no exclusive lock is held on the hw device.

cat > /etc/asound.conf << ASOUND_EOF
# ── EVVOS Shared Audio Configuration ──────────────────────────────────────────
# dsnoop: software capture multiplexer — allows multiple simultaneous readers
# ──────────────────────────────────────────────────────────────────────────────

# Primary shared capture device (stereo, 16 kHz)
pcm.mic_shared {
    type dsnoop
    ipc_key 2048
    ipc_key_add_uid false   # share across all users/daemons
    slave {
        pcm "hw:${CARD_NUM},0"
        channels 2
        rate 16000
        format S16_LE
        period_size 1024
        buffer_size 16384
    }
    bindings {
        0 0   # left mic  → channel 0
        1 1   # right mic → channel 1
    }
}

# Convenience wrapper: stereo dsnoop → mono 16 kHz (voice recognition format)
pcm.mic_mono {
    type plug
    slave {
        pcm "mic_shared"
        channels 1
        rate 16000
        format S16_LE
    }
    route_policy "average"   # average L+R into single mono channel
}

# System default: capture uses dsnoop, playback stays on the card speaker
pcm.!default {
    type asym
    playback.pcm {
        type plug
        slave.pcm "hw:${CARD_NUM},0"
    }
    capture.pcm "mic_shared"
}

ctl.!default {
    type hw
    card ${CARD_NUM}
}
ASOUND_EOF

log_success "/etc/asound.conf written"

# Verify dsnoop device is accessible
log_info "Testing dsnoop device (2-second capture test)..."
if timeout 4 arecord -D mic_shared -f S16_LE -r 16000 -c 2 -d 2 /tmp/dsnoop_test.wav 2>/dev/null; then
    TEST_SIZE=$(stat -c%s /tmp/dsnoop_test.wav 2>/dev/null || echo 0)
    rm -f /tmp/dsnoop_test.wav
    if [ "$TEST_SIZE" -gt 20000 ]; then
        log_success "dsnoop device working ($TEST_SIZE bytes captured)"
    else
        log_warning "dsnoop test file is small — audio may be silent but device opened OK"
    fi
else
    log_warning "dsnoop test did not complete cleanly — will still proceed"
    log_warning "If services fail, check: arecord -D mic_shared -d 2 /tmp/test.wav"
fi

# ============================================================================
# STEP 2 — Patch voice service to use mic_shared
# ============================================================================
log_section "Step 2: Patch Voice Service (evvos-pico-voice-service.py)"

# The current service scans PyAudio devices for 'seeed' in the name.
# After adding dsnoop, PyAudio will enumerate both the raw hw device (seeed)
# and the virtual devices (mic_shared, mic_mono).
# We update the search priority so it prefers "mic_shared" first,
# then falls back to "seeed" (raw hw), then to any input device.
#
# We also add a fallback to open by ALSA device name string if PyAudio
# index-based lookup fails — this covers some PortAudio/ALSA combinations
# where virtual devices enumerate with unexpected names.

python3 << 'VOICE_PATCH_EOF'
import re

path = "/usr/local/bin/evvos-pico-voice-service.py"
with open(path, "r") as f:
    src = f.read()

# ── Replace the audio setup method with the shared-device version ─────────────
old_setup = '''    def setup_audio(self):
        try:
            # CRITICAL: Suppress ALSA lib error messages BEFORE initializing PyAudio
            # This prevents the alsa_snd_config_update() errors from crashing the service
            import ctypes
            import os
            
            # Method 1: Use ctypes to suppress ALSA errors
            try:
                # Suppress ALSA config errors at the C library level
                ERRORFN = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p)
                def ignore_errors(filename, line, function, err, fmt):
                    pass
                error_handler = ERRORFN(ignore_errors)
                try:
                    asound = ctypes.cdll.LoadLibrary('libasound.so.2')
                    asound.snd_lib_error_set_handler(error_handler)
                    logger.debug("ALSA error handler installed via libasound.so.2")
                except:
                    # Try alternate library name
                    asound = ctypes.cdll.LoadLibrary('libasound.so')
                    asound.snd_lib_error_set_handler(error_handler)
                    logger.debug("ALSA error handler installed via libasound.so")
            except Exception as e:
                logger.debug(f"Could not install ALSA error handler (non-critical): {e}")
            
            # Method 2: Redirect stderr to suppress ALSA lib warnings
            try:
                import subprocess
                # Suppress ALSA lib messages at stderr level
                devnull = os.open(os.devnull, os.O_WRONLY)
                saved_stderr = os.dup(2)
                os.dup2(devnull, 2)
                logger.debug("ALSA stderr redirection enabled")
            except Exception as e:
                logger.debug(f"Could not redirect stderr (non-critical): {e}")
                saved_stderr = None
            
            try:
                # Initialize PyAudio (may trigger ALSA warnings, but they're now suppressed)
                self.pa = pyaudio.PyAudio()
                logger.info("PyAudio initialized successfully (ALSA warnings suppressed)")
            finally:
                # Restore stderr
                try:
                    if saved_stderr is not None:
                        os.dup2(saved_stderr, 2)
                        os.close(devnull)
                except:
                    pass
            
            # Find ReSpeaker device with fallback
            dev_idx = None
            dev_name = None
            
            # First try: Look for 'seeed' in device name
            for i in range(self.pa.get_device_count()):
                info = self.pa.get_device_info_by_index(i)
                if 'seeed' in info['name'].lower():
                    dev_idx = i
                    dev_name = info['name']
                    logger.info(f"Found ReSpeaker device: {dev_name} (index {i})")
                    logger.info(f"  Sample Rate: {int(info['defaultSampleRate'])} Hz")
                    logger.info(f"  Input Channels: {info['maxInputChannels']}")
                    break
            
            # Fallback: If no seeed device, use first device with input channels
            if dev_idx is None:
                logger.warning("ReSpeaker device (seeed) not found, trying fallback...")
                for i in range(self.pa.get_device_count()):
                    info = self.pa.get_device_info_by_index(i)
                    if info['maxInputChannels'] > 0:
                        dev_idx = i
                        dev_name = info['name']
                        logger.info(f"Using fallback audio device: {dev_name} (index {i})")
                        logger.info(f"  Sample Rate: {int(info['defaultSampleRate'])} Hz")
                        logger.info(f"  Input Channels: {info['maxInputChannels']}")
                        break
            
            if dev_idx is None:
                logger.error("No audio input device found!")
                logger.info("Available devices:")
                for i in range(self.pa.get_device_count()):
                    info = self.pa.get_device_info_by_index(i)
                    logger.info(f"  [{i}] {info['name']} (input: {info['maxInputChannels']}, output: {info['maxOutputChannels']})")
                return False
            
            self.audio_stream = self.pa.open(
                input_device_index=dev_idx,
                rate=SAMPLE_RATE,
                channels=CHANNELS,
                format=AUDIO_FORMAT,
                input=True,
                frames_per_buffer=FRAME_LENGTH
            )
            logger.info(f"Audio stream opened successfully from {dev_name}")
            return True
        except Exception as e:
            logger.error(f"Audio init failed: {e}")
            import traceback
            logger.debug(traceback.format_exc())
            self.leds.set_all(LED_ERROR, brightness=20)
            return False'''

new_setup = '''    def setup_audio(self):
        """
        Open audio stream from the ALSA dsnoop shared device so that
        voice recognition and video audio recording can run in parallel.

        Device priority:
          1. "mic_shared"  — ALSA dsnoop virtual device (preferred, allows sharing)
          2. "seeed..."    — raw ReSpeaker hw device (exclusive, falls back if dsnoop missing)
          3. first device with input channels (last resort)

        The dsnoop device is configured in /etc/asound.conf by setup_shared_audio.sh.
        Multiple processes (this service + arecord in the camera service) can all
        open "mic_shared" simultaneously without blocking each other.
        """
        import ctypes, os

        # ── Suppress ALSA lib C-level noise ───────────────────────────────────
        try:
            ERRORFN = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_int,
                                       ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p)
            def _noop(*a): pass
            _handler = ERRORFN(_noop)
            for lib in ('libasound.so.2', 'libasound.so'):
                try:
                    ctypes.cdll.LoadLibrary(lib).snd_lib_error_set_handler(_handler)
                    break
                except Exception:
                    pass
        except Exception as e:
            logger.debug(f"Could not install ALSA error handler: {e}")

        # ── Suppress ALSA stderr messages during PyAudio init ─────────────────
        devnull = saved_stderr = None
        try:
            devnull = os.open(os.devnull, os.O_WRONLY)
            saved_stderr = os.dup(2)
            os.dup2(devnull, 2)
        except Exception:
            pass

        try:
            self.pa = pyaudio.PyAudio()
            logger.info("[AUDIO] PyAudio initialized")
        finally:
            try:
                if saved_stderr is not None:
                    os.dup2(saved_stderr, 2)
                    os.close(saved_stderr)
                if devnull is not None:
                    os.close(devnull)
            except Exception:
                pass

        # ── Device selection — prefer dsnoop, fall back to raw hw ─────────────
        #
        # IMPORTANT: "mic_shared" is the ALSA dsnoop device defined in
        # /etc/asound.conf. Using it instead of the raw "seeed" hw device is
        # what allows the camera service to record audio at the same time.
        #
        dev_idx  = None
        dev_name = None

        logger.info("[AUDIO] Scanning for shared mic device (mic_shared / dsnoop)...")
        for i in range(self.pa.get_device_count()):
            info = self.pa.get_device_info_by_index(i)
            name = info['name'].lower()
            channels = info['maxInputChannels']
            logger.debug(f"  [{i}] {info['name']}  in={channels}")

            if 'mic_shared' in name and channels > 0:
                dev_idx  = i
                dev_name = info['name']
                logger.info(f"[AUDIO] ✓ Found dsnoop device: {dev_name} (index {i})")
                break

        # Fallback 1: raw ReSpeaker hw device (exclusive — means camera audio will fail)
        if dev_idx is None:
            logger.warning("[AUDIO] mic_shared not found — falling back to raw ReSpeaker hw device")
            logger.warning("[AUDIO]   Camera audio recording will NOT work simultaneously!")
            logger.warning("[AUDIO]   Re-run setup_shared_audio.sh to fix this.")
            for i in range(self.pa.get_device_count()):
                info = self.pa.get_device_info_by_index(i)
                if 'seeed' in info['name'].lower() and info['maxInputChannels'] > 0:
                    dev_idx  = i
                    dev_name = info['name']
                    logger.info(f"[AUDIO] Using raw hw fallback: {dev_name} (index {i})")
                    break

        # Fallback 2: first device with any input channels
        if dev_idx is None:
            logger.warning("[AUDIO] seeed device not found either — using first available input")
            for i in range(self.pa.get_device_count()):
                info = self.pa.get_device_info_by_index(i)
                if info['maxInputChannels'] > 0:
                    dev_idx  = i
                    dev_name = info['name']
                    logger.info(f"[AUDIO] Using last-resort device: {dev_name} (index {i})")
                    break

        if dev_idx is None:
            logger.error("[AUDIO] No audio input device found at all")
            logger.info("[AUDIO] Enumerated devices:")
            for i in range(self.pa.get_device_count()):
                info = self.pa.get_device_info_by_index(i)
                logger.info(f"  [{i}] {info['name']}  in={info['maxInputChannels']}")
            self.leds.set_all(LED_ERROR, brightness=20)
            return False

        # ── Open the stream ────────────────────────────────────────────────────
        try:
            self.audio_stream = self.pa.open(
                input_device_index=dev_idx,
                rate=SAMPLE_RATE,
                channels=CHANNELS,
                format=AUDIO_FORMAT,
                input=True,
                frames_per_buffer=FRAME_LENGTH,
            )
            logger.info(f"[AUDIO] Stream opened: {dev_name} @ {SAMPLE_RATE} Hz mono")
            return True
        except Exception as e:
            logger.error(f"[AUDIO] Failed to open stream on {dev_name}: {e}")
            import traceback
            logger.debug(traceback.format_exc())
            self.leds.set_all(LED_ERROR, brightness=20)
            return False'''

if old_setup in src:
    src = src.replace(old_setup, new_setup)
    print("✓ setup_audio method replaced successfully")
else:
    # Try a more resilient approach — replace just the device-selection block
    print("⚠ Exact match not found for setup_audio — attempting targeted replacement")
    # Replace the device search section
    old_search = '''            # Find ReSpeaker device with fallback
            dev_idx = None
            dev_name = None
            
            # First try: Look for 'seeed' in device name
            for i in range(self.pa.get_device_count()):
                info = self.pa.get_device_info_by_index(i)
                if 'seeed' in info['name'].lower():
                    dev_idx = i
                    dev_name = info['name']
                    logger.info(f"Found ReSpeaker device: {dev_name} (index {i})")
                    logger.info(f"  Sample Rate: {int(info['defaultSampleRate'])} Hz")
                    logger.info(f"  Input Channels: {info['maxInputChannels']}")
                    break
            
            # Fallback: If no seeed device, use first device with input channels
            if dev_idx is None:
                logger.warning("ReSpeaker device (seeed) not found, trying fallback...")
                for i in range(self.pa.get_device_count()):
                    info = self.pa.get_device_info_by_index(i)
                    if info['maxInputChannels'] > 0:
                        dev_idx = i
                        dev_name = info['name']
                        logger.info(f"Using fallback audio device: {dev_name} (index {i})")
                        logger.info(f"  Sample Rate: {int(info['defaultSampleRate'])} Hz")
                        logger.info(f"  Input Channels: {info['maxInputChannels']}")
                        break'''

    new_search = '''            # ── Device selection — prefer dsnoop, fall back to raw hw ─────────
            # "mic_shared" is the ALSA dsnoop device from /etc/asound.conf.
            # Using it allows the camera service to record audio simultaneously.
            dev_idx  = None
            dev_name = None

            for i in range(self.pa.get_device_count()):
                info = self.pa.get_device_info_by_index(i)
                if 'mic_shared' in info['name'].lower() and info['maxInputChannels'] > 0:
                    dev_idx, dev_name = i, info['name']
                    logger.info(f"[AUDIO] ✓ dsnoop device: {dev_name} (index {i})")
                    break

            if dev_idx is None:
                logger.warning("[AUDIO] mic_shared not found — falling back to raw seeed device (camera audio will be disabled)")
                for i in range(self.pa.get_device_count()):
                    info = self.pa.get_device_info_by_index(i)
                    if 'seeed' in info['name'].lower() and info['maxInputChannels'] > 0:
                        dev_idx, dev_name = i, info['name']
                        logger.info(f"[AUDIO] Using raw hw fallback: {dev_name} (index {i})")
                        break

            if dev_idx is None:
                logger.warning("[AUDIO] seeed not found — using first available input device")
                for i in range(self.pa.get_device_count()):
                    info = self.pa.get_device_info_by_index(i)
                    if info['maxInputChannels'] > 0:
                        dev_idx, dev_name = i, info['name']
                        logger.info(f"[AUDIO] Last resort device: {dev_name} (index {i})")
                        break'''

    if old_search in src:
        src = src.replace(old_search, new_search)
        print("✓ Device-search block replaced successfully (targeted patch)")
    else:
        print("✗ Could not patch setup_audio — manual intervention needed")
        print("  See: /opt/evvos/backups/ for original")
        import sys; sys.exit(1)

with open(path, "w") as f:
    f.write(src)

print("Voice service patched and saved.")
VOICE_PATCH_EOF

log_success "Voice service patched to use mic_shared (dsnoop)"

# ============================================================================
# STEP 3 — Patch camera service to add audio recording
# ============================================================================
log_section "Step 3: Patch Camera Service (evvos-picam-tcp.py)"

# What we're changing in the camera service:
#
#   • Add global audio_process / audio_path variables
#   • start_recording_handler  → also spawns arecord -D mic_shared
#   • stop_recording_handler   → kills arecord, then muxes audio+video
#     (the -an flag is removed from ffmpeg; -i audio.wav + -c:a aac is added)
#
# Audio is recorded as 16 kHz mono WAV alongside the H264 video, then both
# are merged into the final MP4 by ffmpeg. If arecord fails for any reason
# the recording falls back to video-only (silent MP4) to avoid data loss.

python3 << 'CAM_PATCH_EOF'
path = "/usr/local/bin/evvos-picam-tcp.py"
with open(path, "r") as f:
    src = f.read()

# ── 1. Add audio globals after existing globals ────────────────────────────────
old_globals = '''# ── GLOBAL STATE ──────────────────────────────────────────────────────────────
camera               = None
recording            = False
recording_lock       = threading.Lock()
current_session_id   = None
current_video_path   = None
recording_start_time = None   # tracks wall-clock start so elapsed seconds survive reconnects'''

new_globals = '''# ── GLOBAL STATE ──────────────────────────────────────────────────────────────
camera               = None
recording            = False
recording_lock       = threading.Lock()
current_session_id   = None
current_video_path   = None
current_audio_path   = None   # WAV recorded in parallel with H264 video
audio_process        = None   # subprocess handle for arecord
recording_start_time = None   # tracks wall-clock start so elapsed seconds survive reconnects'''

if old_globals in src:
    src = src.replace(old_globals, new_globals)
    print("✓ Audio globals added")
else:
    print("⚠ Could not find globals block — skipping globals patch (may already be patched)")

# ── 2. Replace start_recording_handler ────────────────────────────────────────
old_start = '''def start_recording_handler():
    global recording, current_session_id, current_video_path, recording_start_time
    with recording_lock:
        # ✅ IDEMPOTENT: if the phone reconnects and sends START_RECORDING again,
        #    return the existing session instead of trying to start a second one.
        if recording:
            print("[CAMERA] Already recording — returning existing session to reconnected client")
            return {
                "status":          "recording_started",   # same key the phone expects
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
            recording_start_time = time.time()

            print(f"[CAMERA] Starting: {current_session_id}")
            encoder = H264Encoder(bitrate=2500000, framerate=CAMERA_FPS)
            camera.start_recording(encoder, str(current_video_path))
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
            return {"status": "error", "message": str(e)}'''

new_start = '''def start_recording_handler():
    global recording, current_session_id, current_video_path, current_audio_path, \\
           audio_process, recording_start_time
    with recording_lock:
        # IDEMPOTENT: reconnecting phone gets the existing session back
        if recording:
            print("[CAMERA] Already recording — returning existing session to reconnected client")
            return {
                "status":          "recording_started",
                "session_id":      current_session_id,
                "video_path":      str(current_video_path),
                "audio_path":      str(current_audio_path) if current_audio_path else None,
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

            print(f"[CAMERA] Starting video: {current_session_id}")
            encoder = H264Encoder(bitrate=2500000, framerate=CAMERA_FPS)
            camera.start_recording(encoder, str(current_video_path))

            # ── Start parallel audio recording from shared dsnoop device ──────
            # "mic_shared" is the ALSA dsnoop virtual device defined in
            # /etc/asound.conf by setup_shared_audio.sh. It allows simultaneous
            # access alongside the voice recognition service (evvos-pico-voice).
            # Recording 16 kHz mono — matches voice recognition format.
            audio_cmd = [
                "arecord",
                "-D", "mic_shared",       # dsnoop shared device — not exclusive
                "-f", "S16_LE",           # 16-bit signed little-endian
                "-r", "16000",            # 16 kHz (shared with voice service)
                "-c", "1",                # mono
                str(current_audio_path),
            ]
            try:
                audio_process = subprocess.Popen(
                    audio_cmd,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                )
                print(f"[AUDIO] arecord started (PID {audio_process.pid}) → {current_audio_path.name}")
            except Exception as ae:
                print(f"[AUDIO] WARNING: Could not start arecord: {ae}")
                print(f"[AUDIO]   Recording will continue VIDEO-ONLY (silent)")
                audio_process    = None
                current_audio_path = None

            recording = True
            return {
                "status":          "recording_started",
                "session_id":      current_session_id,
                "video_path":      str(current_video_path),
                "audio_path":      str(current_audio_path) if current_audio_path else None,
                "pi_ip":           get_pi_ip(),
                "http_port":       HTTP_PORT,
                "already_running": False,
                "elapsed_seconds": 0,
            }
        except Exception as e:
            print(f"[CAMERA] Start Error: {e}")
            # Clean up audio process if camera failed to start
            if audio_process and audio_process.poll() is None:
                audio_process.terminate()
            return {"status": "error", "message": str(e)}'''

if old_start in src:
    src = src.replace(old_start, new_start)
    print("✓ start_recording_handler patched")
else:
    print("⚠ start_recording_handler exact match not found — may already be patched")

# ── 3. Replace stop_recording_handler ─────────────────────────────────────────
old_stop = '''def stop_recording_handler():
    global recording, current_session_id, current_video_path, recording_start_time
    with recording_lock:
        if not recording:
            return {"status": "not_recording"}
        try:
            print("[CAMERA] Stopping...")
            camera.stop_recording()
            camera.stop()
            recording            = False
            recording_start_time = None
            time.sleep(0.5)

            mp4_path = current_video_path.with_suffix(".mp4")
            raw_size = current_video_path.stat().st_size if current_video_path.exists() else 0
            print(f"[CAMERA] Raw H264 size: {raw_size / 1024 / 1024:.2f} MB")

            # ── SPEED FIX: Forced 24 FPS Constant Frame Rate ──────────────────
            print("[FFMPEG] Fixing speed (Constant 24 FPS CFR)...")
            cmd = [
                "ffmpeg", "-y",
                "-r", "24", "-i", str(current_video_path),
                "-vf", "setpts=N/(24*TB)",
                "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
                "-r", "24", "-fps_mode", "cfr", "-an",
                "-movflags", "+faststart", "-loglevel", "error",
                str(mp4_path)
            ]
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)

            if res.returncode == 0:
                size_mb = mp4_path.stat().st_size / 1024 / 1024
                print(f"[FFMPEG] ✓ Success: {mp4_path.name} ({size_mb:.2f} MB)")
                current_video_path.unlink(missing_ok=True)
            else:
                print(f"[FFMPEG] Error: {res.stderr}")
                size_mb = mp4_path.stat().st_size / 1024 / 1024 if mp4_path.exists() else 0

            return {
                "status":         "recording_stopped",
                "session_id":     current_session_id,
                "video_filename": mp4_path.name,
                "video_path":     str(mp4_path),
                "video_size_mb":  round(size_mb, 2),
                "video_url":      f"http://{get_pi_ip()}:{HTTP_PORT}/{mp4_path.name}",
                "pi_ip":          get_pi_ip(),
                "http_port":      HTTP_PORT,
            }
        except Exception as e:
            print(f"[CAMERA] Stop Error: {e}")
            return {"status": "error", "message": str(e)}'''

new_stop = '''def stop_recording_handler():
    global recording, current_session_id, current_video_path, current_audio_path, \\
           audio_process, recording_start_time
    with recording_lock:
        if not recording:
            return {"status": "not_recording"}
        try:
            print("[CAMERA] Stopping video...")
            camera.stop_recording()
            camera.stop()
            recording            = False
            recording_start_time = None
            time.sleep(0.5)

            # ── Stop arecord and wait for it to flush the WAV file ────────────
            has_audio = False
            if audio_process is not None:
                print(f"[AUDIO] Stopping arecord (PID {audio_process.pid})...")
                audio_process.terminate()
                try:
                    audio_process.wait(timeout=10)
                    print("[AUDIO] arecord stopped cleanly")
                except subprocess.TimeoutExpired:
                    audio_process.kill()
                    print("[AUDIO] arecord killed (did not stop within 10 s)")

                if current_audio_path and current_audio_path.exists():
                    audio_size = current_audio_path.stat().st_size
                    # A valid WAV with 1+ seconds of 16 kHz 16-bit mono audio
                    # will be at least ~32 000 bytes (16000 * 2 * 1)
                    if audio_size > 32000:
                        has_audio = True
                        print(f"[AUDIO] Audio file ready: {current_audio_path.name} "
                              f"({audio_size / 1024:.1f} KB)")
                    else:
                        print(f"[AUDIO] Audio file too small ({audio_size} bytes) — video-only fallback")
                else:
                    print("[AUDIO] Audio file missing — video-only fallback")

            mp4_path = current_video_path.with_suffix(".mp4")
            raw_size = current_video_path.stat().st_size if current_video_path.exists() else 0
            print(f"[CAMERA] Raw H264 size: {raw_size / 1024 / 1024:.2f} MB")

            # ── ffmpeg mux: video + audio → MP4 ──────────────────────────────
            # • has_audio=True  → merge H264 + WAV, encode audio as AAC 128k
            # • has_audio=False → video-only (original -an behaviour, safe fallback)
            #
            # -shortest ensures the output ends when the shorter stream ends
            # (handles any minor timing difference between camera stop and audio stop)
            print(f"[FFMPEG] Encoding MP4 (audio={'yes' if has_audio else 'no'})...")

            if has_audio:
                cmd = [
                    "ffmpeg", "-y",
                    "-r", "24", "-i", str(current_video_path),
                    "-i", str(current_audio_path),
                    "-vf", "setpts=N/(24*TB)",
                    "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
                    "-r", "24", "-fps_mode", "cfr",
                    "-c:a", "aac", "-b:a", "128k",
                    "-shortest",
                    "-movflags", "+faststart", "-loglevel", "error",
                    str(mp4_path)
                ]
            else:
                cmd = [
                    "ffmpeg", "-y",
                    "-r", "24", "-i", str(current_video_path),
                    "-vf", "setpts=N/(24*TB)",
                    "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
                    "-r", "24", "-fps_mode", "cfr", "-an",
                    "-movflags", "+faststart", "-loglevel", "error",
                    str(mp4_path)
                ]

            res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)

            if res.returncode == 0:
                size_mb = mp4_path.stat().st_size / 1024 / 1024
                print(f"[FFMPEG] ✓ {mp4_path.name} ({size_mb:.2f} MB, "
                      f"audio={'yes' if has_audio else 'no'})")
                current_video_path.unlink(missing_ok=True)
                if has_audio and current_audio_path:
                    current_audio_path.unlink(missing_ok=True)
            else:
                print(f"[FFMPEG] Error: {res.stderr}")
                size_mb = mp4_path.stat().st_size / 1024 / 1024 if mp4_path.exists() else 0

            return {
                "status":         "recording_stopped",
                "session_id":     current_session_id,
                "video_filename": mp4_path.name,
                "video_path":     str(mp4_path),
                "video_size_mb":  round(size_mb, 2),
                "has_audio":      has_audio,
                "video_url":      f"http://{get_pi_ip()}:{HTTP_PORT}/{mp4_path.name}",
                "pi_ip":          get_pi_ip(),
                "http_port":      HTTP_PORT,
            }
        except Exception as e:
            print(f"[CAMERA] Stop Error: {e}")
            return {"status": "error", "message": str(e)}'''

if old_stop in src:
    src = src.replace(old_stop, new_stop)
    print("✓ stop_recording_handler patched")
else:
    print("⚠ stop_recording_handler exact match not found — may already be patched")

with open(path, "w") as f:
    f.write(src)

print("Camera service patched and saved.")
CAM_PATCH_EOF

log_success "Camera service patched to record audio via mic_shared"

# ============================================================================
# STEP 4 — Verify Python syntax of patched files
# ============================================================================
log_section "Step 4: Syntax Check"

python3 -m py_compile "$VOICE_SCRIPT" && log_success "Voice service syntax OK" \
    || { log_error "Voice service has syntax errors — restoring backup"; cp "$BACKUP_DIR/evvos-pico-voice-service.py.bak" "$VOICE_SCRIPT"; exit 1; }

python3 -m py_compile "$CAM_SCRIPT" && log_success "Camera service syntax OK" \
    || { log_error "Camera service has syntax errors — restoring backup"; cp "$BACKUP_DIR/evvos-picam-tcp.py.bak" "$CAM_SCRIPT"; exit 1; }

# ============================================================================
# STEP 5 — Restart services
# ============================================================================
log_section "Step 5: Restart Services"

systemctl daemon-reload

log_info "Restarting evvos-pico-voice..."
systemctl restart evvos-pico-voice
sleep 3
if systemctl is-active --quiet evvos-pico-voice; then
    log_success "evvos-pico-voice  ✓ running"
else
    log_warning "evvos-pico-voice  did not start — check: sudo journalctl -u evvos-pico-voice -n 30"
fi

log_info "Restarting evvos-picam-tcp..."
systemctl restart evvos-picam-tcp
sleep 2
if systemctl is-active --quiet evvos-picam-tcp; then
    log_success "evvos-picam-tcp   ✓ running"
else
    log_warning "evvos-picam-tcp   did not start — check: sudo journalctl -u evvos-picam-tcp -n 30"
fi

# ============================================================================
# STEP 6 — Simultaneous access test
# ============================================================================
log_section "Step 6: Simultaneous Access Test"

log_info "Opening two arecord processes on mic_shared at the same time..."
arecord -D mic_shared -f S16_LE -r 16000 -c 1 -d 2 /tmp/test_reader1.wav 2>/dev/null &
PID1=$!
arecord -D mic_shared -f S16_LE -r 16000 -c 1 -d 2 /tmp/test_reader2.wav 2>/dev/null &
PID2=$!
wait $PID1 $PID2

SIZE1=$(stat -c%s /tmp/test_reader1.wav 2>/dev/null || echo 0)
SIZE2=$(stat -c%s /tmp/test_reader2.wav 2>/dev/null || echo 0)
rm -f /tmp/test_reader1.wav /tmp/test_reader2.wav

if [ "$SIZE1" -gt 20000 ] && [ "$SIZE2" -gt 20000 ]; then
    log_success "Simultaneous capture working! (reader1=${SIZE1}B, reader2=${SIZE2}B)"
else
    log_warning "One or both readers returned small/empty files:"
    log_warning "  reader1: $SIZE1 bytes   reader2: $SIZE2 bytes"
    log_warning "  The device opened OK (no 'device busy' error) but audio may be silent."
    log_warning "  Check microphone gain: sudo amixer -c seeed2micvoicec sset 'PGA' 25"
fi

# ============================================================================
# DONE
# ============================================================================
log_section "Setup Complete!"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Shared audio setup complete${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  ALSA dsnoop device:  mic_shared  (defined in /etc/asound.conf)"
echo "  Capture format:      16 kHz · 16-bit · mono (voice) / stereo (raw)"
echo ""
echo "  Voice recognition    → reads from mic_shared (non-exclusive)"
echo "  Video audio          → arecord -D mic_shared (runs in parallel)"
echo "  Final MP4            → video + AAC audio muxed by ffmpeg"
echo ""
echo -e "${CYAN}How it works:${NC}"
echo "  dsnoop is ALSA's software capture multiplexer. It holds a single"
echo "  hardware lock on hw:${CARD_NUM},0 and serves independent audio copies"
echo "  to every reader. Adding more readers has zero effect on the voice"
echo "  recognition service — it never knows another process is also listening."
echo ""
echo -e "${CYAN}Troubleshooting:${NC}"
echo ""
echo "  # Check dsnoop is accessible:"
echo "  arecord -D mic_shared -d 2 /tmp/test.wav && echo OK"
echo ""
echo "  # Watch voice service (should log 'dsnoop device' on startup):"
echo "  sudo journalctl -u evvos-pico-voice -f"
echo ""
echo "  # Watch camera service (should log 'arecord started' when recording):"
echo "  sudo journalctl -u evvos-picam-tcp -f"
echo ""
echo "  # If dsnoop fails with 'Device or resource busy':"
echo "  # Something is holding hw:${CARD_NUM},0 exclusively. Find it:"
echo "  fuser /dev/snd/pcmC${CARD_NUM}D0c"
echo ""
echo "  # Restore originals if something went wrong:"
echo "  cp $BACKUP_DIR/*.bak /usr/local/bin/"
echo "  sudo systemctl restart evvos-pico-voice evvos-picam-tcp"
echo ""
