#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Camera Occlusion Detection Patch
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_occlusion.sh
#
# What this does:
#   1. Patches /usr/local/bin/evvos-picam-tcp.py with:
#      - Background thread that checks for lens occlusion every 5 seconds
#      - Detection uses numpy brightness + variance analysis on a captured frame
#        (same capture_request() method used by TAKE_SNAPSHOT — safe during H264)
#      - camera_blocked flag exposed in GET_STATUS response
#      - New CAMERA_STATUS intent for a lightweight dedicated check
#   2. Restarts the evvos-picam-tcp.service
#
# Detection algorithm:
#   Every 5 s the thread grabs a frame via capture_request(), downsamples it
#   to 40×30 using numpy stride slicing (no OpenCV/MediaPipe needed), then:
#     • mean pixel brightness (0–255)
#     • pixel variance
#   A frame is BLOCKED when BOTH conditions are true:
#     • mean < 18   (pitch-black — hand/cap/tape over lens)
#       OR mean > 242 (pure white — paper or bright light flush on lens)
#     • variance < 40 (uniform — no scene detail)
#   3 consecutive blocked frames → camera_blocked = True
#   3 consecutive clear frames  → camera_blocked = False
#   Hysteresis prevents flickering alerts from brief partial occlusions.
#
# Why numpy instead of MediaPipe / OpenCV?
#   MediaPipe publishes no armhf (32-bit ARM) wheel — pip install fails on
#   Pi Zero 2 W. OpenCV works but adds ~80 MB via apt. numpy is already
#   a picamera2 dependency, so this patch has zero extra installs.
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "\033[0;34mℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_section() { echo -e "\n${CYAN}════════════════════════════════════════════════════${NC}\n${CYAN}▶ $1${NC}\n${CYAN}════════════════════════════════════════════════════${NC}"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Run as root: sudo bash $0"
    exit 1
fi

CAMERA_SCRIPT="/usr/local/bin/evvos-picam-tcp.py"

if [ ! -f "$CAMERA_SCRIPT" ]; then
    log_error "Camera script not found: $CAMERA_SCRIPT"
    log_error "Run setup_picam.sh first."
    exit 1
fi

log_section "Patching Pi Camera Service — Occlusion Detection"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD ─────────────────────────────────────────────────────────────────────
if "occlusion_thread" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 1: Add occlusion globals after recording_start_time
# ─────────────────────────────────────────────────────────────────────────────
old = "recording_start_time = None"
new = (
    "recording_start_time = None\n"
    "\n"
    "# ── Occlusion detection ────────────────────────────────────────────────────\n"
    "camera_blocked        = False   # True when lens appears covered\n"
    "blocked_streak        = 0       # consecutive blocked frames seen\n"
    "clear_streak          = 0       # consecutive clear frames seen\n"
    "occlusion_thread      = None\n"
    "occlusion_stop_event  = None\n"
    "\n"
    "OCCLUDE_BRIGHT_MIN  = 18    # mean brightness below this → too dark (covered)\n"
    "OCCLUDE_BRIGHT_MAX  = 242   # mean brightness above this → too bright (paper)\n"
    "OCCLUDE_VAR_MAX     = 40    # variance below this → uniform, no scene detail\n"
    "OCCLUDE_STREAK      = 3     # consecutive frames required to flip state\n"
    "OCCLUDE_INTERVAL    = 5     # seconds between checks"
)
assert old in src, f"Anchor not found (patch 1)"
src = src.replace(old, new, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2: Inject occlusion thread functions before get_status_handler()
# ─────────────────────────────────────────────────────────────────────────────
occlusion_funcs = '''
def _occlusion_loop(stop_event):
    """
    Background thread: grab a frame every OCCLUDE_INTERVAL seconds and update
    the global camera_blocked flag using brightness + variance analysis.

    Uses capture_request() — explicitly safe to call concurrently with an
    active H264 encoder (same method as TAKE_SNAPSHOT).

    Downsamples to 40x30 with numpy stride slicing — no OpenCV needed,
    negligible CPU impact on the Pi Zero 2 W.
    """
    import numpy as np
    import time as _time

    global camera_blocked, blocked_streak, clear_streak

    print("[OCCLUDE] Detection thread started")

    while not stop_event.is_set():
        _time.sleep(OCCLUDE_INTERVAL)

        if stop_event.is_set():
            break

        if not camera:
            blocked_streak = 0
            clear_streak   = 0
            continue

        try:
            # Grab latest frame — safe during H264 recording
            request = camera.capture_request()
            frame   = request.make_array("main")   # shape (H, W, 3) RGB uint8
            request.release()

            # Downsample to ~40x30 via numpy stride slicing (no OpenCV needed)
            h, w   = frame.shape[:2]
            sh, sw = max(1, h // 30), max(1, w // 40)
            small  = frame[::sh, ::sw, :].astype(np.float32)

            mean_brightness = float(small.mean())
            variance        = float(small.var())

            brightness_suspect = (
                mean_brightness < OCCLUDE_BRIGHT_MIN or
                mean_brightness > OCCLUDE_BRIGHT_MAX
            )
            low_detail = variance < OCCLUDE_VAR_MAX
            occluded   = brightness_suspect and low_detail

            if occluded:
                print(f"[OCCLUDE] Suspect — brightness={mean_brightness:.1f}  var={variance:.1f}")
                blocked_streak += 1
                clear_streak    = 0
                if blocked_streak >= OCCLUDE_STREAK and not camera_blocked:
                    camera_blocked = True
                    print("[OCCLUDE] ⚠️  BLOCKED — mobile will be notified via next CAMERA_STATUS poll")
            else:
                clear_streak   += 1
                blocked_streak  = 0
                if clear_streak >= OCCLUDE_STREAK and camera_blocked:
                    camera_blocked = False
                    print("[OCCLUDE] ✓ Camera clear")

        except Exception as e:
            print(f"[OCCLUDE] Frame check error (non-fatal): {e}")

    print("[OCCLUDE] Detection thread stopped")


def _start_occlusion_thread():
    global occlusion_thread, occlusion_stop_event, camera_blocked, blocked_streak, clear_streak
    if occlusion_thread and occlusion_thread.is_alive():
        return
    camera_blocked = False
    blocked_streak = 0
    clear_streak   = 0
    occlusion_stop_event = threading.Event()
    occlusion_thread = threading.Thread(
        target=_occlusion_loop,
        args=(occlusion_stop_event,),
        daemon=True,
        name="occlusion-detector",
    )
    occlusion_thread.start()
    print("[OCCLUDE] Thread launched")


def _stop_occlusion_thread():
    global occlusion_stop_event, camera_blocked, blocked_streak, clear_streak
    if occlusion_stop_event:
        occlusion_stop_event.set()
    camera_blocked = False
    blocked_streak = 0
    clear_streak   = 0
    print("[OCCLUDE] Thread stop requested")


'''

old = "def get_status_handler():"
assert old in src, f"Anchor not found (patch 2)"
src = src.replace(old, occlusion_funcs + old, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 3: Start occlusion thread when recording starts
#          Insert just after: recording = True
# ─────────────────────────────────────────────────────────────────────────────
old = (
    "            recording = True\n"
    "\n"
    "            return {\n"
    "                \"status\":          \"recording_started\","
)
new = (
    "            recording = True\n"
    "            _start_occlusion_thread()   # start lens-tamper detection\n"
    "\n"
    "            return {\n"
    "                \"status\":          \"recording_started\","
)
assert old in src, f"Anchor not found (patch 3)"
src = src.replace(old, new, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 4: Stop occlusion thread when recording stops
# ─────────────────────────────────────────────────────────────────────────────
old = (
    "            recording            = False\n"
    "            recording_start_time = None\n"
    "            time.sleep(0.5)"
)
new = (
    "            recording            = False\n"
    "            recording_start_time = None\n"
    "            _stop_occlusion_thread()   # stop lens-tamper detection\n"
    "            time.sleep(0.5)"
)
assert old in src, f"Anchor not found (patch 4)"
src = src.replace(old, new, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 5: Add camera_blocked to GET_STATUS response
# ─────────────────────────────────────────────────────────────────────────────
old = (
    '            "elapsed_seconds\": elapsed,\n'
    '        }'
)
new = (
    '            "elapsed_seconds": elapsed,\n'
    '            "camera_blocked":  camera_blocked,\n'
    '        }'
)
assert old in src, f"Anchor not found (patch 5)"
src = src.replace(old, new, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 6: Add CAMERA_STATUS intent to the intent router
# ─────────────────────────────────────────────────────────────────────────────
old = '                    elif intent == "GET_STATUS":'
new = (
    '                    elif intent == "CAMERA_STATUS":\n'
    '                        res = {\n'
    '                            "status":         "camera_status",\n'
    '                            "camera_blocked": camera_blocked,\n'
    '                            "recording":      recording,\n'
    '                        }\n'
    '                    elif intent == "GET_STATUS":'
)
assert old in src, f"Anchor not found (patch 6)"
src = src.replace(old, new, 1)

script.write_text(src, encoding="utf-8")
print("All 6 patches applied successfully.")
PATCHER_EOF

log_success "Python patcher completed"

log_section "Restarting evvos-picam-tcp service"
systemctl restart evvos-picam-tcp.service
sleep 2

if systemctl is-active --quiet evvos-picam-tcp.service; then
    log_success "Service restarted and running"
else
    log_error "Service failed to restart — check: journalctl -u evvos-picam-tcp -n 30"
    exit 1
fi

echo ""
echo -e "${CYAN}  Camera Occlusion Detection active${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Detection:  numpy brightness + variance (no extra installs)${NC}"
echo -e "${CYAN}  Capture:    capture_request() — safe during H264 encoding${NC}"
echo -e "${CYAN}  Interval:   every 5 s, 3-frame hysteresis before state flips${NC}"
echo -e "${CYAN}  New intent: CAMERA_STATUS → { status, camera_blocked, recording }${NC}"
echo -e "${CYAN}  GET_STATUS: now also returns camera_blocked field${NC}"
echo ""
log_success "Occlusion detection patch complete!"
