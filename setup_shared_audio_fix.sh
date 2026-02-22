#!/bin/bash
# ============================================================================
# EVVOS Shared Audio Setup — v3 (consolidated, all fixes included)
#
# Enables the ReSpeaker 2-Mics HAT to be used simultaneously by:
#   - evvos-pico-voice  (PicoVoice Rhino — voice command recognition)
#   - evvos-picam-tcp   (video + audio recording)
#
# Root cause of the conflict:
#   ALSA hardware PCM devices (hw:X,0) allow only ONE reader at a time.
#   The voice service holds an exclusive lock permanently, so arecord
#   cannot open the same device when a recording starts.
#
# Solution: ALSA dsnoop
#   dsnoop is a kernel-level software capture multiplexer. It holds a single
#   hardware lock and serves independent audio copies to unlimited readers.
#   Neither service ever knows the other is listening.
#
#   Two virtual devices are defined in /etc/asound.conf:
#     mic_shared  — stereo 16 kHz dsnoop  (raw multiplexed stream)
#     mic_mono    — plug wrapper around mic_shared → mono 16 kHz
#                   (what arecord uses; plug does the stereo→mono downmix
#                    because dsnoop itself cannot do channel conversion)
#
#   The voice service opens PyAudio with input_device_index=None so
#   PortAudio uses the ALSA 'default' device, which /etc/asound.conf
#   routes to mic_shared (dsnoop). This releases the exclusive hw lock.
#
# Prerequisites:
#   setup_respeaker_enhanced.sh              (HAT driver + ALSA configured)
#   setup_pico_voice_recognition_respeaker.sh (voice service installed)
#   setup_picam.sh                           (camera service installed)
#
# Usage: sudo bash setup_shared_audio.sh
# Safe to re-run — backs up originals before every change.
# ============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

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
[ "$EUID" -ne 0 ] && { log_error "Run as root: sudo bash setup_shared_audio.sh"; exit 1; }

# ── Paths ─────────────────────────────────────────────────────────────────────
VOICE_SCRIPT="/usr/local/bin/evvos-pico-voice-service.py"
CAM_SCRIPT="/usr/local/bin/evvos-picam-tcp.py"
VOICE_SERVICE="/etc/systemd/system/evvos-pico-voice.service"

# ============================================================================
# PREFLIGHT
# ============================================================================
log_section "Preflight Checks"

[ -f "$VOICE_SCRIPT"  ] || { log_error "Missing: $VOICE_SCRIPT  — run setup_pico_voice_recognition_respeaker.sh first"; exit 1; }
[ -f "$CAM_SCRIPT"    ] || { log_error "Missing: $CAM_SCRIPT   — run setup_picam.sh first"; exit 1; }
[ -f "$VOICE_SERVICE" ] || { log_error "Missing: $VOICE_SERVICE — run setup_pico_voice_recognition_respeaker.sh first"; exit 1; }

CARD_INFO=$(aplay -l 2>/dev/null | grep -i seeed | head -1)
[ -z "$CARD_INFO" ] && { log_error "ReSpeaker not detected — run setup_respeaker_enhanced.sh and reboot first"; exit 1; }
CARD_NUM=$(echo "$CARD_INFO" | grep -oP 'card \K[0-9]+')
CARD_HW=$(echo  "$CARD_INFO" | grep -oP ': \K[^ ]+')
log_success "ReSpeaker detected: card $CARD_NUM ($CARD_HW)"

BACKUP_DIR="/opt/evvos/backups/shared_audio_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$VOICE_SCRIPT"  "$BACKUP_DIR/"
cp "$CAM_SCRIPT"    "$BACKUP_DIR/"
cp "$VOICE_SERVICE" "$BACKUP_DIR/"
[ -f /etc/asound.conf ] && cp /etc/asound.conf "$BACKUP_DIR/asound.conf.bak"
log_success "Originals backed up → $BACKUP_DIR"

# ============================================================================
# STEP 1 — Stop services for clean setup
# ============================================================================
log_section "Step 1: Stop Services"

systemctl stop evvos-pico-voice evvos-picam-tcp 2>/dev/null || true
sleep 2
log_success "Services stopped"

# ============================================================================
# STEP 2 — Write /etc/asound.conf
# ============================================================================
log_section "Step 2: Configure ALSA dsnoop (/etc/asound.conf)"

# WHY three layers instead of one?
#   The TLV320AIC3104 codec on the ReSpeaker HAT runs at a fixed native rate
#   (usually 48000 Hz). Setting dsnoop's slave rate to 16000 Hz causes the
#   hardware to reject it ("Slave PCM not usable" / "no configurations available").
#
#   Fix — three-layer chain:
#     hw:X,0 (native rate, stereo)
#       └─ mic_dsnoop  [dsnoop at native rate — the shared IPC lock lives here]
#            ├─ mic_shared  [plug: native→16000, stereo — voice service default]
#            └─ mic_mono    [plug: native→16000, stereo→mono — arecord]
#
#   dsnoop only ever sees the native rate it can actually open.
#   The plug wrappers handle all resampling and channel conversion downstream.

# ── Auto-detect hardware native sample rate ───────────────────────────────────
log_info "Detecting hardware native sample rate..."
HW_RATE=$(arecord -D hw:${CARD_NUM},0 --dump-hw-params 2>&1 \
    | grep -oP '(?<=RATE: )\d+' | sort -n | tail -1)

if [ -z "$HW_RATE" ]; then
    HW_RATE=48000
    log_warning "Could not auto-detect rate — defaulting to 48000 Hz (most I2S codecs)"
else
    log_success "Hardware native rate: $HW_RATE Hz"
fi

cat > /etc/asound.conf << ASOUND_EOF
# ── EVVOS Shared Audio — generated by setup_shared_audio.sh ───────────────
# Hardware native rate: ${HW_RATE} Hz
# dsnoop runs at native rate; plug wrappers resample to 16000 Hz.
# This avoids "Slave PCM not usable" from the TLV320AIC3104 codec.

# ── Layer 1: raw dsnoop at hardware native rate (stereo) ─────────────────
pcm.mic_dsnoop {
    type dsnoop
    ipc_key 2048
    ipc_key_add_uid false
    ipc_perm 0666            # allow all users/daemons to share IPC segment
    slave {
        pcm "hw:${CARD_NUM},0"
        channels 2           # must match hardware (ReSpeaker is stereo)
        rate ${HW_RATE}      # must match hardware native rate
        format S16_LE
        period_size 1024
        buffer_size 16384
    }
}

# ── Layer 2a: stereo 16 kHz — used by voice service via default device ────
pcm.mic_shared {
    type plug
    slave {
        pcm "mic_dsnoop"
        channels 2
        rate 16000
        format S16_LE
    }
}

# ── Layer 2b: mono 16 kHz — used by arecord in the camera service ─────────
# dsnoop cannot do channel conversion; the plug layer handles stereo→mono.
pcm.mic_mono {
    type plug
    slave {
        pcm "mic_dsnoop"
        channels 1           # plug downmixes L+R → mono
        rate 16000
        format S16_LE
    }
    route_policy "average"
}

# ── System default ────────────────────────────────────────────────────────
# Capture → mic_shared (dsnoop); playback → card speaker.
# PyAudio opens this when input_device_index=None (no explicit device).
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

log_success "/etc/asound.conf written (dsnoop @ ${HW_RATE} Hz, plug resamples to 16000)"

# ── Test mic_shared ───────────────────────────────────────────────────────────
log_info "Testing mic_shared (stereo 16 kHz)..."
DSNOOP_ERR=$(mktemp)
if timeout 4 arecord -D mic_shared -f S16_LE -r 16000 -c 2 -d 2 /tmp/test_dsnoop.wav 2>"$DSNOOP_ERR"; then
    SIZE=$(stat -c%s /tmp/test_dsnoop.wav 2>/dev/null || echo 0)
    rm -f /tmp/test_dsnoop.wav
    [ "$SIZE" -gt 20000 ] \
        && log_success "mic_shared working ($SIZE bytes)" \
        || log_warning "mic_shared opened but file small (${SIZE}B) — mic may need gain adjustment"
else
    log_error "mic_shared failed: $(cat "$DSNOOP_ERR")"
    log_error "Detected rate was ${HW_RATE} Hz — try running: arecord -D hw:${CARD_NUM},0 --dump-hw-params"
    rm -f "$DSNOOP_ERR"
    exit 1
fi
rm -f "$DSNOOP_ERR"

# ── Test mic_mono ─────────────────────────────────────────────────────────────
log_info "Testing mic_mono (mono 16 kHz)..."
MONO_ERR=$(mktemp)
if timeout 4 arecord -D mic_mono -f S16_LE -r 16000 -c 1 -d 2 /tmp/test_mono.wav 2>"$MONO_ERR"; then
    SIZE=$(stat -c%s /tmp/test_mono.wav 2>/dev/null || echo 0)
    rm -f /tmp/test_mono.wav
    [ "$SIZE" -gt 20000 ] \
        && log_success "mic_mono working ($SIZE bytes)" \
        || log_warning "mic_mono opened but file small (${SIZE}B) — mic may need gain adjustment"
else
    log_error "mic_mono failed: $(cat "$MONO_ERR")"
    rm -f "$MONO_ERR"
    exit 1
fi
rm -f "$MONO_ERR"

# ============================================================================
# STEP 3 — Patch voice service
# ============================================================================
log_section "Step 3: Patch Voice Service (evvos-pico-voice-service.py)"

# Key change: open PyAudio with input_device_index=None (ALSA default device)
# instead of scanning for a device named 'seeed' (the raw hw device).
# /etc/asound.conf routes the default capture device to mic_shared (dsnoop),
# so the voice service gets its audio through dsnoop without an exclusive lock.

python3 << 'VOICE_PATCH_EOF'
import re, sys

path = "/usr/local/bin/evvos-pico-voice-service.py"
with open(path) as f:
    src = f.read()

NEW_SETUP_AUDIO = '''    def setup_audio(self):
        """
        Open the microphone via the ALSA default capture device.

        /etc/asound.conf maps the default capture device to mic_shared
        (an ALSA dsnoop virtual device). dsnoop holds a single hardware
        lock on hw:CARD,0 and serves independent audio copies to every
        reader, so the camera service can run arecord -D mic_mono at the
        same time with no conflict.

        WHY input_device_index=None?
          Searching by hardware name ('seeed') finds the raw hw device
          which holds an exclusive OS-level lock — nothing else can open
          the mic while the voice service is running. Using None lets
          PortAudio pick the ALSA default PCM, which /etc/asound.conf
          routes to mic_shared (dsnoop). The hardware lock is then shared.
        """
        import ctypes, os

        # ── Suppress ALSA C-level error noise ─────────────────────────────
        try:
            ERRORFN = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_int,
                                       ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p)
            _handler = ERRORFN(lambda *a: None)
            for lib in ('libasound.so.2', 'libasound.so'):
                try:
                    ctypes.cdll.LoadLibrary(lib).snd_lib_error_set_handler(_handler)
                    break
                except Exception:
                    pass
        except Exception:
            pass

        # ── Suppress ALSA stderr during PyAudio init ───────────────────────
        devnull = saved_stderr = None
        try:
            devnull      = os.open(os.devnull, os.O_WRONLY)
            saved_stderr = os.dup(2)
            os.dup2(devnull, 2)
        except Exception:
            pass
        try:
            self.pa = pyaudio.PyAudio()
        finally:
            try:
                if saved_stderr is not None:
                    os.dup2(saved_stderr, 2)
                    os.close(saved_stderr)
                if devnull is not None:
                    os.close(devnull)
            except Exception:
                pass

        # ── Log available input devices for diagnostics ────────────────────
        logger.info("[AUDIO] Available PyAudio input devices:")
        for i in range(self.pa.get_device_count()):
            info = self.pa.get_device_info_by_index(i)
            if info['maxInputChannels'] > 0:
                logger.info(f"  [{i}] {info['name']}  ch={info['maxInputChannels']}  rate={int(info['defaultSampleRate'])}")

        # ── Open default device (→ mic_shared/dsnoop via /etc/asound.conf) ─
        logger.info("[AUDIO] Opening default capture device (→ mic_shared/dsnoop)...")
        try:
            self.audio_stream = self.pa.open(
                input_device_index=None,   # ALSA default = mic_shared (dsnoop)
                rate=SAMPLE_RATE,
                channels=CHANNELS,
                format=AUDIO_FORMAT,
                input=True,
                frames_per_buffer=FRAME_LENGTH,
            )
            try:
                default_info = self.pa.get_default_input_device_info()
                logger.info(f"[AUDIO] ✓ Opened [{default_info['index']}] '{default_info['name']}' @ {SAMPLE_RATE} Hz")
            except Exception:
                logger.info(f"[AUDIO] ✓ Stream opened @ {SAMPLE_RATE} Hz mono")
            return True

        except Exception as e:
            logger.error(f"[AUDIO] Default device failed: {e}")
            logger.info("[AUDIO] Scanning for first available input device (fallback)...")

            for i in range(self.pa.get_device_count()):
                info = self.pa.get_device_info_by_index(i)
                if info['maxInputChannels'] < 1:
                    continue
                try:
                    self.audio_stream = self.pa.open(
                        input_device_index=i,
                        rate=SAMPLE_RATE,
                        channels=CHANNELS,
                        format=AUDIO_FORMAT,
                        input=True,
                        frames_per_buffer=FRAME_LENGTH,
                    )
                    logger.warning(f"[AUDIO] ⚠ Fallback device [{i}] \'{info['name']}\'")
                    logger.warning("[AUDIO]   This may be the raw hw device (exclusive lock).")
                    logger.warning("[AUDIO]   Camera audio recording may fail.")
                    return True
                except Exception:
                    continue

            logger.error("[AUDIO] No working input device found")
            self.leds.set_all(LED_ERROR, brightness=20)
            return False
'''

# Replace the entire setup_audio method using regex
pattern = r'(    def setup_audio\(self\):.*?)(?=\n    def )'
match = re.search(pattern, src, re.DOTALL)
if match:
    src = src[:match.start()] + NEW_SETUP_AUDIO + src[match.end():]
    print("✓ setup_audio replaced (regex)")
elif "    def setup_audio(self):" in src:
    start = src.index("    def setup_audio(self):")
    next_def = src.find("\n    def ", start + 1)
    if next_def != -1:
        src = src[:start] + NEW_SETUP_AUDIO + "\n" + src[next_def:]
        print("✓ setup_audio replaced (index search)")
    else:
        print("✗ Could not find end of setup_audio method"); sys.exit(1)
else:
    print("✗ setup_audio method not found in voice service"); sys.exit(1)

with open(path, "w") as f:
    f.write(src)
print("Voice service saved.")
VOICE_PATCH_EOF

log_success "Voice service patched"

# ============================================================================
# STEP 4 — Update voice service systemd unit
# ============================================================================
log_section "Step 4: Update Voice Service Systemd Unit"

# Remove any old AUDIODEV lines to avoid duplicates, then add a fresh one
sed -i '/AUDIODEV/d' "$VOICE_SERVICE"

if grep -q "^\[Service\]" "$VOICE_SERVICE"; then
    sed -i '/^\[Service\]/a Environment="AUDIODEV=mic_shared"' "$VOICE_SERVICE"
    log_success "AUDIODEV=mic_shared added to systemd unit"
else
    log_warning "Could not find [Service] section — skipping env var"
fi

# ============================================================================
# STEP 5 — Patch camera service
# ============================================================================
log_section "Step 5: Patch Camera Service (evvos-picam-tcp.py)"

# Changes vs original setup_picam.sh:
#   • Audio globals (current_audio_path, audio_process)
#   • start_recording_handler → spawns arecord -D mic_mono alongside picamera2
#       Uses mic_mono (NOT mic_shared) because:
#         dsnoop is a pass-through multiplexer — it rejects any channel count
#         that doesn't match its slave config (stereo). Requesting -c 1 gives:
#         "Channels count non available"
#         mic_mono wraps dsnoop in an ALSA plug that performs the stereo→mono
#         downmix, so arecord -c 1 works without error.
#   • arecord stderr captured; process polled after 1 s so failures are logged
#   • stop_recording_handler → stops arecord, validates WAV, muxes with ffmpeg
#       audio=yes: ffmpeg merges H264 + WAV → MP4 with AAC audio track
#       audio=no:  silent MP4 fallback (original behaviour preserved)

python3 << 'CAM_PATCH_EOF'
import re, sys

path = "/usr/local/bin/evvos-picam-tcp.py"
with open(path) as f:
    src = f.read()

# ── 1. Audio globals ──────────────────────────────────────────────────────────
OLD_GLOBALS = '''# ── GLOBAL STATE ──────────────────────────────────────────────────────────────
camera               = None
recording            = False
recording_lock       = threading.Lock()
current_session_id   = None
current_video_path   = None
recording_start_time = None   # tracks wall-clock start so elapsed seconds survive reconnects'''

NEW_GLOBALS = '''# ── GLOBAL STATE ──────────────────────────────────────────────────────────────
camera               = None
recording            = False
recording_lock       = threading.Lock()
current_session_id   = None
current_video_path   = None
current_audio_path   = None   # WAV recorded in parallel with H264 video
audio_process        = None   # subprocess handle for arecord
recording_start_time = None   # tracks wall-clock start so elapsed seconds survive reconnects'''

if OLD_GLOBALS in src:
    src = src.replace(OLD_GLOBALS, NEW_GLOBALS)
    print("✓ Audio globals added")
elif 'current_audio_path' in src:
    print("✓ Audio globals already present — skipping")
else:
    print("⚠ Globals block not matched — skipping")

# ── 2. start_recording_handler ────────────────────────────────────────────────
OLD_START = '''def start_recording_handler():
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

NEW_START = '''def start_recording_handler():
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

            # ── Parallel audio recording via ALSA dsnoop ──────────────────────
            # Device: mic_mono (NOT mic_shared)
            #   mic_shared is a raw stereo dsnoop — it rejects -c 1 with:
            #   "Channels count non available"
            #   mic_mono is a plug wrapper around mic_shared that downmixes
            #   stereo → mono, so arecord -c 1 works without error.
            # Both mic_mono and the voice service read from the same dsnoop
            # IPC segment, so neither holds an exclusive hw lock.
            audio_cmd = [
                "arecord",
                "-D", "mic_mono",    # plug: dsnoop stereo → mono 16 kHz
                "-f", "S16_LE",
                "-r", "16000",
                "-c", "1",           # mono — mic_mono handles the conversion
                str(current_audio_path),
            ]
            try:
                audio_process = subprocess.Popen(
                    audio_cmd,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,  # captured so failures are visible
                )
                # Poll after 1 s — if arecord exits that quickly it failed
                time.sleep(1.0)
                poll = audio_process.poll()
                if poll is not None:
                    stderr_out = audio_process.stderr.read().decode("utf-8", errors="replace").strip()
                    print(f"[AUDIO] ERROR: arecord exited immediately (code {poll})")
                    print(f"[AUDIO]   stderr:  {stderr_out}")
                    print(f"[AUDIO]   command: {' '.join(audio_cmd)}")
                    print(f"[AUDIO]   Recording continues VIDEO-ONLY (silent)")
                    audio_process      = None
                    current_audio_path = None
                else:
                    print(f"[AUDIO] ✓ arecord running (PID {audio_process.pid}) → {current_audio_path.name}")
            except Exception as ae:
                print(f"[AUDIO] WARNING: Could not start arecord: {ae}")
                print(f"[AUDIO]   command: {' '.join(audio_cmd)}")
                print(f"[AUDIO]   Recording continues VIDEO-ONLY (silent)")
                audio_process      = None
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
            if audio_process and audio_process.poll() is None:
                audio_process.terminate()
            return {"status": "error", "message": str(e)}'''

if OLD_START in src:
    src = src.replace(OLD_START, NEW_START)
    print("✓ start_recording_handler patched")
elif 'mic_mono' in src and 'audio_process' in src:
    print("✓ start_recording_handler already patched — skipping")
else:
    print("⚠ start_recording_handler not matched — may need manual inspection")

# ── 3. stop_recording_handler ─────────────────────────────────────────────────
OLD_STOP = '''def stop_recording_handler():
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

NEW_STOP = '''def stop_recording_handler():
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

            # ── Stop arecord and wait for WAV to flush ────────────────────────
            has_audio = False
            if audio_process is not None:
                print(f"[AUDIO] Stopping arecord (PID {audio_process.pid})...")
                audio_process.terminate()
                try:
                    audio_process.wait(timeout=10)
                    stderr_out = audio_process.stderr.read().decode("utf-8", errors="replace").strip()
                    if stderr_out:
                        print(f"[AUDIO] arecord stderr: {stderr_out}")
                    print("[AUDIO] arecord stopped cleanly")
                except subprocess.TimeoutExpired:
                    audio_process.kill()
                    print("[AUDIO] arecord killed (did not stop within 10 s)")

                if current_audio_path and current_audio_path.exists():
                    audio_size = current_audio_path.stat().st_size
                    # 16 kHz 16-bit mono = 32000 bytes/sec; require at least 1 s
                    if audio_size > 32000:
                        has_audio = True
                        print(f"[AUDIO] Audio file ready: {current_audio_path.name} "
                              f"({audio_size / 1024:.1f} KB)")
                    else:
                        print(f"[AUDIO] Audio file too small ({audio_size} B) — video-only fallback")
                else:
                    print("[AUDIO] Audio file missing — video-only fallback")

            mp4_path = current_video_path.with_suffix(".mp4")
            raw_size = current_video_path.stat().st_size if current_video_path.exists() else 0
            print(f"[CAMERA] Raw H264 size: {raw_size / 1024 / 1024:.2f} MB")

            # ── ffmpeg: mux video + audio (or video-only fallback) ────────────
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
                print(f"[FFMPEG] ✓ {mp4_path.name} ({size_mb:.2f} MB, audio={'yes' if has_audio else 'no'})")
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

if OLD_STOP in src:
    src = src.replace(OLD_STOP, NEW_STOP)
    print("✓ stop_recording_handler patched")
elif 'has_audio' in src and 'mic_mono' in src:
    print("✓ stop_recording_handler already patched — skipping")
else:
    print("⚠ stop_recording_handler not matched — may need manual inspection")

with open(path, "w") as f:
    f.write(src)
print("Camera service saved.")
CAM_PATCH_EOF

log_success "Camera service patched"

# ============================================================================
# STEP 6 — Syntax check (auto-restore on failure)
# ============================================================================
log_section "Step 6: Syntax Check"

python3 -m py_compile "$VOICE_SCRIPT" \
    && log_success "Voice service syntax OK" \
    || {
        log_error "Syntax error in voice service — restoring backup"
        cp "$BACKUP_DIR/evvos-pico-voice-service.py" "$VOICE_SCRIPT"
        exit 1
    }

python3 -m py_compile "$CAM_SCRIPT" \
    && log_success "Camera service syntax OK" \
    || {
        log_error "Syntax error in camera service — restoring backup"
        cp "$BACKUP_DIR/evvos-picam-tcp.py" "$CAM_SCRIPT"
        exit 1
    }

# ============================================================================
# STEP 7 — Restart services
# ============================================================================
log_section "Step 7: Restart Services"

systemctl daemon-reload

log_info "Starting evvos-pico-voice..."
systemctl start evvos-pico-voice
sleep 4   # give PyAudio time to open the dsnoop device

if systemctl is-active --quiet evvos-pico-voice; then
    log_success "evvos-pico-voice ✓ running"
    log_info "Device selection log:"
    journalctl -u evvos-pico-voice -n 20 --no-pager \
        | grep -i "AUDIO\|dsnoop\|default\|error\|opened\|seeed" || true
else
    log_error "evvos-pico-voice failed to start"
    journalctl -u evvos-pico-voice -n 30 --no-pager
    exit 1
fi

log_info "Starting evvos-picam-tcp..."
systemctl start evvos-picam-tcp
sleep 2

if systemctl is-active --quiet evvos-picam-tcp; then
    log_success "evvos-picam-tcp ✓ running"
else
    log_error "evvos-picam-tcp failed to start"
    journalctl -u evvos-picam-tcp -n 30 --no-pager
    exit 1
fi

# ============================================================================
# STEP 8 — Simultaneous capture test (voice service live)
# ============================================================================
log_section "Step 8: Simultaneous Capture Test (Voice Service Running)"

log_info "Running arecord -D mic_mono while evvos-pico-voice holds the device..."

ARECORD_ERR=$(mktemp)
if timeout 5 arecord -D mic_mono -f S16_LE -r 16000 -c 1 -d 3 /tmp/sim_test.wav 2>"$ARECORD_ERR"; then
    SIM_SIZE=$(stat -c%s /tmp/sim_test.wav 2>/dev/null || echo 0)
    rm -f /tmp/sim_test.wav
    if [ "$SIM_SIZE" -gt 32000 ]; then
        log_success "SUCCESS — simultaneous capture working! ($SIM_SIZE bytes)"
        log_success "Voice recognition and audio recording will now run in parallel."
    else
        log_warning "Device opened but audio is small (${SIM_SIZE}B) — mic may need gain:"
        log_warning "  sudo amixer -c $CARD_HW sset 'PGA' 25 && sudo alsactl store"
    fi
else
    STDERR_OUT=$(cat "$ARECORD_ERR")
    log_error "arecord STILL failing while voice service is running"
    log_error "Error: $STDERR_OUT"
    echo ""
    echo "  Diagnosis: check which device the voice service actually opened:"
    echo "    sudo journalctl -u evvos-pico-voice -n 30 --no-pager | grep AUDIO"
    echo ""
    echo "  If you see '[AUDIO] ⚠ Fallback device ... seeed...' the voice service"
    echo "  fell back to the raw hw device. Check /etc/asound.conf defines"
    echo "  pcm.!default correctly and that PyAudio enumerates a default device."
fi
rm -f "$ARECORD_ERR"

# ============================================================================
# DONE
# ============================================================================
log_section "Setup Complete"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Shared audio setup complete${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  ALSA devices:"
echo "    mic_shared  — stereo 16 kHz dsnoop  (voice service)"
echo "    mic_mono    — mono 16 kHz plug→dsnoop (arecord in camera service)"
echo ""
echo "  Expected log output when recording:"
echo "    START: [AUDIO] ✓ arecord running (PID XXXX) → audio_*.wav"
echo "    STOP:  [AUDIO] Audio file ready: audio_*.wav (XXXX KB)"
echo "           [FFMPEG] Encoding MP4 (audio=yes)"
echo "           [FFMPEG] ✓ video_*.mp4 (XX.XX MB, audio=yes)"
echo ""
echo -e "${CYAN}Useful commands:${NC}"
echo "  Watch camera logs:  sudo journalctl -u evvos-picam-tcp -f"
echo "  Watch voice logs:   sudo journalctl -u evvos-pico-voice -f"
echo "  Adjust mic gain:    sudo amixer -c $CARD_HW sset 'PGA' 25 && sudo alsactl store"
echo "  Test mic_mono:      arecord -D mic_mono -d 3 /tmp/test.wav && aplay /tmp/test.wav"
echo "  Restore originals:  cp $BACKUP_DIR/* /usr/local/bin/ && systemctl daemon-reload"
echo ""
