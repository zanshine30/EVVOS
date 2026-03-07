#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Snapshot YUV420 Fix
#
# Problem:
#   camera.capture_image("main") returns a YUV420 PIL image because the
#   camera is configured with format="YUV420".  PIL cannot save YUV420
#   images as JPEG, causing:
#     "Stream format YUV420 not supported for PIL images"
#
# Fix:
#   Replace capture_image() with capture_array() and perform a manual
#   YUV420 → RGB conversion (using numpy) before saving the JPEG.
#
# Run on the Raspberry Pi as root:
#   sudo bash fix_snapshot_yuv.sh
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

if [ ! -f "$CAMERA_SCRIPT" ]; then
    log_error "Camera script not found: $CAMERA_SCRIPT"
    log_error "Run setup_picam.sh first."
    exit 1
fi

log_section "Patching snapshot handler — YUV420 → RGB fix"

# Backup
cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# Guard: skip if already patched
if "capture_array_yuv_fix" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

old = '''        image = camera.capture_image("main")
        image.save(str(snap_path), "JPEG", quality=85)'''

new = '''        # capture_array_yuv_fix: camera runs YUV420; PIL cannot save that format
        # directly.  Use capture_array() + manual YUV→RGB conversion instead.
        import numpy as np
        yuv = camera.capture_array("main")          # shape: (H*3//2, W), dtype uint8
        h, w = yuv.shape[0] * 2 // 3, yuv.shape[1]

        # Split Y / U / V planes from YUV420 (I420 layout)
        Y = yuv[:h,        :].astype(np.float32)
        U = yuv[h:h+h//4,  :].reshape(h//2, w//2).repeat(2, axis=0).repeat(2, axis=1).astype(np.float32) - 128
        V = yuv[h+h//4:,   :].reshape(h//2, w//2).repeat(2, axis=0).repeat(2, axis=1).astype(np.float32) - 128

        R = np.clip(Y + 1.402    * V,               0, 255).astype(np.uint8)
        G = np.clip(Y - 0.344136 * U - 0.714136 * V, 0, 255).astype(np.uint8)
        B = np.clip(Y + 1.772    * U,               0, 255).astype(np.uint8)

        rgb   = np.stack([R, G, B], axis=2)
        from PIL import Image as _PILImage
        image = _PILImage.fromarray(rgb, "RGB")
        image.save(str(snap_path), "JPEG", quality=85)'''

assert old in src, (
    "Anchor not found in camera script.\\n"
    "Has take_snapshot_handler() already been modified?\\n"
    "Check the script manually: /usr/local/bin/evvos-picam-tcp.py"
)

src = src.replace(old, new, 1)
script.write_text(src, encoding="utf-8")
print("Patch applied successfully.")
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
echo -e "${CYAN}  Fix summary:${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  OLD: camera.capture_image(\"main\")  ← PIL YUV420 object, can't JPEG-save${NC}"
echo -e "${CYAN}  NEW: camera.capture_array(\"main\")  ← numpy array, converted to RGB first${NC}"
echo ""
log_success "Snapshot YUV420 fix complete!"
