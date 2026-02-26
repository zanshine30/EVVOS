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
# PATCH 1: Add "from libcamera import Transform" AFTER the try/except block
#
# The picamera2 import sits INSIDE a try/except (4-space indented). Inserting
# a new line there without matching indentation breaks the try/except and
# causes "SyntaxError: expected 'except' or 'finally' block".
#
# We anchor on the closing line of the except block ("    sys.exit(1)") plus
# the CONFIGURATION comment that immediately follows it — that is guaranteed
# module-level scope, safe to insert a top-level import.
# ─────────────────────────────────────────────────────────────────────────────
old_anchor = (
    "    sys.exit(1)\n"
    "\n"
    "# ── CONFIGURATION ─────────────────────────────────────────────────────────────"
)
new_anchor = (
    "    sys.exit(1)\n"
    "\n"
    "from libcamera import Transform  # 180° rotation — camera mounted upside-down\n"
    "\n"
    "# ── CONFIGURATION ─────────────────────────────────────────────────────────────"
)
assert old_anchor in src, (
    "Anchor not found (patch 1). "
    "Check /usr/local/bin/evvos-picam-tcp.py around the picamera2 import block."
)
src = src.replace(old_anchor, new_anchor, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2: Add transform= to create_video_configuration()
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
    '            transform=Transform(hflip=True, vflip=True)  # 180° — camera mounted upside-down\n'
    '        )'
)
assert old_config in src, (
    "Anchor not found (patch 2). "
    "create_video_configuration() may have already been modified by another patch."
)
src = src.replace(old_config, new_config, 1)

script.write_text(src, encoding="utf-8")
print("Both patches applied successfully.")
PATCHER_EOF

log_success "Python patcher completed"

log_section "Verifying patch"
python3 -c "
src = open('/usr/local/bin/evvos-picam-tcp.py').read()
exit_pos      = src.find('    sys.exit(1)')
transform_pos = src.find('from libcamera import Transform')
hflip_pos     = src.find('hflip=True, vflip=True')

ok = True
def chk(label, cond):
    global ok
    print(f'  {chr(10003) if cond else chr(10007)+\" FAIL\"}  {label}')
    if not cond: ok = False

chk('Transform imported',               transform_pos != -1)
chk('hflip+vflip in config',            hflip_pos     != -1)
chk('Transform import is at module level (after try/except)',
    transform_pos != -1 and exit_pos != -1 and transform_pos > exit_pos)

import sys; sys.exit(0 if ok else 1)
"

log_section "Syntax check"
python3 -m py_compile "$CAMERA_SCRIPT" && log_success "Syntax OK — no errors" || {
    log_error "Syntax error detected — restoring backup..."
    LATEST_BACKUP=$(ls -t "${CAMERA_SCRIPT}".bak.* 2>/dev/null | head -1)
    [ -n "$LATEST_BACKUP" ] && cp "$LATEST_BACKUP" "$CAMERA_SCRIPT" && log_info "Restored: $LATEST_BACKUP"
    exit 1
}

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
echo ""
echo -e "${YELLOW}  NOTE: If the image is mirrored instead of rotated, toggle just one flip:${NC}"
echo -e "${YELLOW}    sudo sed -i 's/hflip=True, vflip=True/hflip=False, vflip=True/' \\${NC}"
echo -e "${YELLOW}    /usr/local/bin/evvos-picam-tcp.py${NC}"
echo -e "${YELLOW}    sudo systemctl restart evvos-picam-tcp${NC}"
echo ""
log_success "Rotation patch complete!"
