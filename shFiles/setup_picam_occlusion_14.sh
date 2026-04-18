#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Occlusion Array Dimension Fix (Patch 14 rev2)
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_occlusion_fix_14.sh
#
# Or via curl from GitHub raw URL:
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/setup_picam_occlusion_fix_14.sh | sudo bash
#
# Error being fixed:
#   "too many indices for array: array is 2-dimensional, but 3 were indexed"
#
# Root cause:
#   camera_status_handler() calls make_array("main") and indexes the result
#   as a 3D array (H, W, C). During an active H264 recording the encoder
#   consumes the main stream so make_array() returns a 2D luma-only array
#   (H, W) with no channel axis — any 3-index operation crashes.
#
# Fix:
#   Replace the brightness calculation with frame.mean() which works on
#   both 2D and 3D arrays regardless of how many channels are present.
#   Indentation is detected dynamically from the original source line so
#   the replacement always matches the surrounding block.
#
# Safe to re-run — a guard prevents double-patching.
# Creates a timestamped backup before patching.
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

if ! grep -q "camera_status_handler" "$CAMERA_SCRIPT"; then
    log_error "camera_status_handler not found — run setup_picam_occlusion.sh first."
    exit 1
fi

log_section "EVVOS Pi Camera — Occlusion Array Dimension Fix (Patch 14 rev2)"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
import re
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD ─────────────────────────────────────────────────────────────────────
if "# FIX-P14: dimension-aware brightness" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# Find the brightness assignment line, capture its leading whitespace,
# then replace it with an indentation-matched fixed version.
#
# This approach is safe regardless of whether the surrounding code uses
# 8, 12, 16, or 20 spaces — the indent is read from the file itself.
# ─────────────────────────────────────────────────────────────────────────────

PATTERN = re.compile(
    r'^(?P<indent>[ \t]*)(?P<expr>brightness\s*=\s*(?:float\()?(?:np\.mean\(frame\)|frame[\[\.][^\n]+))$',
    re.MULTILINE
)

match = PATTERN.search(src)
if not match:
    print("ERROR: Could not find a brightness assignment to patch.")
    print("       Check camera_status_handler() in evvos-picam-tcp.py.")
    print("")
    print("       Printing all lines containing 'brightness' for diagnosis:")
    for i, line in enumerate(src.splitlines(), 1):
        if 'brightness' in line:
            print(f"       L{i}: {line!r}")
    raise SystemExit(1)

indent = match.group("indent")
old_line = match.group(0)

print(f"Found brightness line (indent={len(indent)} spaces): {old_line.strip()!r}")

new_lines = (
    f"{indent}# FIX-P14: dimension-aware brightness -- works for both 2D (luma, during\n"
    f"{indent}# H264 recording) and 3D (RGB, when camera is idle). Any 3D-specific\n"
    f"{indent}# indexing raises IndexError when make_array() returns 2D.\n"
    f"{indent}brightness = float(frame.mean())"
)

src = src.replace(old_line, new_lines, 1)
script.write_text(src, encoding="utf-8")
print("Done -- brightness expression patched with correct indentation.")
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
checks = [
    ('FIX-P14 patch marker present',    '# FIX-P14: dimension-aware brightness' in src),
    ('frame.mean() used',               'brightness = float(frame.mean())'       in src),
    ('no axis=2 indexing remaining',    'frame.mean(axis=2)'                not in src),
    ('no channel-0 indexing remaining', 'frame[:, :, 0]'                    not in src),
]
ok = True
for label, result in checks:
    print(f'  {chr(10003) if result else chr(10007)+\" FAIL\"}  {label}')
    if not result: ok = False
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
echo -e "${CYAN}  Occlusion Array Dimension Fix ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Root cause: make_array(\"main\") returns 2D during H264 encoding${NC}"
echo -e "${CYAN}  Fix:        brightness = float(frame.mean())${NC}"
echo -e "${CYAN}              works on both (H,W) and (H,W,C) arrays${NC}"
echo -e "${CYAN}  Affects:    STOP_RECORDING + consecutive TAKE_SNAPSHOT${NC}"
echo ""
log_success "Fix complete!"
