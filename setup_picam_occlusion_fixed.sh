#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Occlusion Clear Fix
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_occlusion_fix.sh
#
# Problem:
#   After removing a cover from the lens, the camera keeps reporting
#   camera_blocked=true for 2-3 more polls. This is because the ISP
#   auto-exposure (AEC) was adapted to complete darkness and needs one
#   frame cycle to recover to a normal exposure level. During that
#   recovery window every brightness check still reads near-zero, so
#   the Pi keeps sending blocked=true even though the lens is clear.
#
# Fix:
#   Patch camera_status_handler() to capture TWO frames with a short
#   sleep between them and analyze only the second one. The first frame
#   after uncover is always stale AEC — discarding it gives the sensor
#   one full cycle to adapt before the brightness check runs.
#
#   Capture 1 → release → sleep 0.4 s → capture 2 → analyze
#
#   0.4 s is enough for the AEC to recover at 24 FPS (≈10 frames)
#   without adding meaningful latency to the 5-second poll cycle.
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
    exit 1
fi

if ! grep -q "camera_status_handler" "$CAMERA_SCRIPT"; then
    log_error "camera_status_handler not found — run setup_picam_occlusion.sh first."
    exit 1
fi

log_section "Patching camera_status_handler — AEC recovery fix"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD ─────────────────────────────────────────────────────────────────────
if "AEC recovery" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# Replace the single capture_request() call with a two-frame capture.
#
# Old — single frame, stale AEC on first poll after uncover:
#
#         request = camera.capture_request()
#         frame   = request.make_array("main")
#         request.release()
#
# New — discard first frame, analyze second after AEC recovery sleep:
#
#         # Frame 1: discard — AEC may still be adapting (e.g. after dark cover)
#         _warmup = camera.capture_request()
#         _warmup.release()
#         import time as _t; _t.sleep(0.4)   # ~10 frames @ 24 FPS to settle AEC
#         # Frame 2: analyze — AEC has had time to recover
#         request = camera.capture_request()
#         frame   = request.make_array("main")
#         request.release()
# ─────────────────────────────────────────────────────────────────────────────
old_capture = (
    '            # Grab latest ISP frame — safe during H264 recording\n'
    '            request = camera.capture_request()\n'
    '            frame   = request.make_array("main")   # shape (H, W, 3) RGB uint8\n'
    '            request.release()'
)
new_capture = (
    '            # AEC recovery: discard the first frame — if the lens was just\n'
    '            # uncovered the sensor is still adapting from darkness and will\n'
    '            # read near-zero brightness. Sleeping 0.4 s (~10 frames @ 24 FPS)\n'
    '            # gives the ISP auto-exposure one full cycle to recover before\n'
    '            # we run the brightness check on the second frame.\n'
    '            _warmup = camera.capture_request()  # AEC recovery\n'
    '            _warmup.release()\n'
    '            import time as _t; _t.sleep(0.4)    # let AEC settle\n'
    '            # Frame 2 — analyze this one\n'
    '            request = camera.capture_request()\n'
    '            frame   = request.make_array("main")   # shape (H, W, 3) RGB uint8\n'
    '            request.release()'
)

assert old_capture in src, (
    "Anchor not found — capture_request block may have changed.\n"
    "Check camera_status_handler() in evvos-picam-tcp.py."
)
src = src.replace(old_capture, new_capture, 1)

script.write_text(src, encoding="utf-8")
print("Patch applied successfully.")
PATCHER_EOF

log_success "Python patcher completed"

log_section "Syntax check"
python3 -m py_compile "$CAMERA_SCRIPT" && log_success "Syntax OK" || {
    log_error "Syntax error — restoring backup..."
    LATEST=$(ls -t "${CAMERA_SCRIPT}".bak.* 2>/dev/null | head -1)
    [ -n "$LATEST" ] && cp "$LATEST" "$CAMERA_SCRIPT" && log_info "Restored: $LATEST"
    exit 1
}

log_section "Verifying patch"
python3 -c "
src = open('/usr/local/bin/evvos-picam-tcp.py').read()
ok = 'AEC recovery' in src and '_warmup' in src and '_t.sleep(0.4)' in src
print(f'  {chr(10003) if ok else chr(10007)+\" FAIL\"}  Two-frame AEC recovery capture')
import sys; sys.exit(0 if ok else 1)
"

log_section "Restarting evvos-picam-tcp service"
systemctl restart evvos-picam-tcp.service
sleep 2

if systemctl is-active --quiet evvos-picam-tcp.service; then
    log_success "Service restarted and running"
else
    log_error "Service failed — check: journalctl -u evvos-picam-tcp -n 30"
    exit 1
fi

echo ""
echo -e "${CYAN}  Occlusion Clear Fix ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Fix:    Two-frame capture — first frame discarded (stale AEC)${NC}"
echo -e "${CYAN}  Sleep:  0.4 s between frames (~10 frames at 24 FPS)${NC}"
echo -e "${CYAN}  Result: Camera clears immediately after cover is removed${NC}"
echo -e "${CYAN}  No change to blocked detection — only affects recovery${NC}"
echo ""
log_success "Occlusion clear fix complete!"
