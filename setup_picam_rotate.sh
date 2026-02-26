#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — 180° Rotation Patch
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_rotate.sh
#
# What this does:
#   Patches /usr/local/bin/evvos-picam-tcp.py to rotate the camera image
#   180° by adding Transform(hflip=True, vflip=True) to the picamera2
#   create_video_configuration() call.
#
# Why hflip + vflip instead of rotation=180?
#   picamera2 uses a libcamera Transform object. Combining horizontal and
#   vertical flip is mathematically equivalent to a 180° rotation and is
#   the correct picamera2 API — there is no direct "rotation=180" argument
#   on create_video_configuration().
#
# When to use this:
#   Your Pi Camera module is physically mounted upside-down (e.g. screwed
#   to a body-worn housing with the ribbon cable facing up). Both the live
#   H264 video stream and TAKE_SNAPSHOT still-frames are rotated correctly
#   because the Transform is applied at the ISP level before any encoder
#   or capture_request() sees the frame.
#
# Safe to re-run — a guard prevents double-patching.
# Creates a timestamped backup of the original script before patching.
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_info()    { echo -e "\033[0;34mℹ${NC} $1"; }
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

log_section "Patching Pi Camera Service — 180° Rotation (upside-down mount)"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD ─────────────────────────────────────────────────────────────────────
if "hflip=True, vflip=True" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 1: Add Transform import to the picamera2 import line
#
# Before: from picamera2 import Picamera2
# After:  from picamera2 import Picamera2
#         from libcamera import Transform
#
# Transform comes from libcamera (bundled with picamera2) — it must be
# imported separately from the main Picamera2 class.
# ─────────────────────────────────────────────────────────────────────────────
old_import = "from picamera2 import Picamera2"
new_import = (
    "from picamera2 import Picamera2\n"
    "from libcamera import Transform   # used for 180° rotation (hflip + vflip)"
)
assert old_import in src, f"Anchor not found: {old_import!r}"
src = src.replace(old_import, new_import, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2: Add transform=Transform(hflip=True, vflip=True) to
#          create_video_configuration()
#
# Target:
#   config = camera.create_video_configuration(
#       main={"size": CAMERA_RES, "format": "RGB888"},
#       encode="main",
#       controls={"FrameRate": CAMERA_FPS, "FrameDurationLimits": (41666, 41666)}
#   )
#
# Result:
#   config = camera.create_video_configuration(
#       main={"size": CAMERA_RES, "format": "RGB888"},
#       encode="main",
#       controls={"FrameRate": CAMERA_FPS, "FrameDurationLimits": (41666, 41666)},
#       transform=Transform(hflip=True, vflip=True)   # 180° — camera mounted upside-down
#   )
# ─────────────────────────────────────────────────────────────────────────────
old_config = (
    '        config = camera.create_video_configuration(\n'
    '            main={"size": CAMERA_RES, "format": "RGB888"},\n'
    '            encode="main",\n'
    '            controls={"FrameRate": CAMERA_FPS, "FrameDurationLimits": (41666, 41666)}\n'
    '        )'
)
new_config = (
    '        config = camera.create_video_configuration(\n'
    '            main={"size": CAMERA_RES, "format": "RGB888"},\n'
    '            encode="main",\n'
    '            controls={"FrameRate": CAMERA_FPS, "FrameDurationLimits": (41666, 41666)},\n'
    '            transform=Transform(hflip=True, vflip=True)   # 180° — camera mounted upside-down\n'
    '        )'
)
assert old_config in src, "Anchor not found (patch 2) — create_video_configuration block"
src = src.replace(old_config, new_config, 1)

script.write_text(src, encoding="utf-8")
print("Both patches applied successfully.")
PATCHER_EOF

log_success "Python patcher completed"

log_section "Verifying patch"
python3 -c "
src = open('/usr/local/bin/evvos-picam-tcp.py').read()
checks = [
    ('Transform import',  'from libcamera import Transform'),
    ('hflip + vflip',     'hflip=True, vflip=True'),
]
all_ok = True
for label, needle in checks:
    ok = needle in src
    print(f'  {\"✓\" if ok else \"✗ MISSING\"}  {label}')
    if not ok:
        all_ok = False
import sys
sys.exit(0 if all_ok else 1)
"

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
echo -e "${CYAN}  Camera Rotation patch ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Rotation:    180° (hflip=True + vflip=True via libcamera Transform)${NC}"
echo -e "${CYAN}  Applied to:  create_video_configuration() — ISP-level, before encoder${NC}"
echo -e "${CYAN}  Affects:     H264 video stream + TAKE_SNAPSHOT still-frames${NC}"
echo -e "${CYAN}  Mount:       Camera physically upside-down on body-worn housing${NC}"
echo ""
echo -e "${YELLOW}  NOTE: If the image is now mirrored (not rotated), the ribbon cable${NC}"
echo -e "${YELLOW}        faces a different direction than expected. In that case replace${NC}"
echo -e "${YELLOW}        Transform(hflip=True, vflip=True) with Transform(rotation=180)${NC}"
echo -e "${YELLOW}        — both are equivalent on most Pi Camera modules.${NC}"
echo ""
log_success "Rotation patch complete!"
