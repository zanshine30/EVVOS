#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Occlusion Clear Fix
# Fixes false-positive "still blocked" alerts after removing a cover.
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_section() { echo -e "\n${CYAN}════════════════════════════════════════════════════${NC}\n${CYAN}▶ $1${NC}\n${CYAN}════════════════════════════════════════════════════${NC}"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Run as root: sudo bash $0"
    exit 1
fi

CAMERA_SCRIPT="/usr/local/bin/evvos-picam-tcp.py"
[ ! -f "$CAMERA_SCRIPT" ] && { log_error "Script not found: $CAMERA_SCRIPT"; exit 1; }

log_section "Patching _occlusion_loop — AEC recovery fix"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

if "AEC recovery" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

old_capture = (
    '            # Grab latest frame — safe during H264 recording\n'
    '            request = camera.capture_request()\n'
    '            frame   = request.make_array("main")   # shape (H, W, 3) RGB uint8\n'
    '            request.release()'
)
new_capture = (
    '            # AEC recovery: discard the first frame — if the lens was just\n'
    '            # uncovered the sensor is still adapting from darkness and the\n'
    '            # first frame reads near-zero brightness. Sleeping 0.4 s\n'
    '            # (~10 frames @ 24 FPS) lets the ISP auto-exposure settle.\n'
    '            _warmup = camera.capture_request()  # AEC recovery — discard\n'
    '            _warmup.release()\n'
    '            _time.sleep(0.4)                    # let AEC settle\n'
    '            # Frame 2 — analyze this one\n'
    '            request = camera.capture_request()\n'
    '            frame   = request.make_array("main")   # shape (H, W, 3) RGB uint8\n'
    '            request.release()'
)

if old_capture not in src:
    print("ERROR: anchor not found. Dumping capture_request lines:")
    for i, l in enumerate(src.splitlines()):
        if "capture_request" in l or "make_array" in l:
            print(f"  {i+1}: {repr(l)}")
    raise SystemExit(1)

src = src.replace(old_capture, new_capture, 1)
script.write_text(src, encoding="utf-8")
print("Patch applied successfully.")
PATCHER_EOF

log_success "Patcher completed"

log_section "Syntax check"
python3 -m py_compile "$CAMERA_SCRIPT" && log_success "Syntax OK" || {
    log_error "Syntax error — restoring backup..."
    cp "$(ls -t ${CAMERA_SCRIPT}.bak.* | head -1)" "$CAMERA_SCRIPT"
    exit 1
}

log_section "Verifying"
python3 -c "
src = open('/usr/local/bin/evvos-picam-tcp.py').read()
ok = '_warmup' in src and 'AEC recovery' in src
print(f'  {chr(10003) if ok else chr(10007)+\" FAIL\"}  Two-frame AEC recovery in _occlusion_loop')
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
echo -e "${CYAN}  Fix:    Warmup frame discarded before each brightness check${NC}"
echo -e "${CYAN}  Sleep:  0.4 s between frames (~10 frames @ 24 FPS)${NC}"
echo -e "${CYAN}  Result: Camera clears on first clean poll after cover removed${NC}"
echo ""
log_success "Done!"
