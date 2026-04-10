#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Occlusion Array Dimension Fix (Patch 14)
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
#   camera_status_handler() calls make_array("main") and then indexes the
#   result as a 3D array (H, W, C) — e.g. frame[:, :, 0] or frame.mean(axis=2).
#
#   During an active H264 recording the main stream is being consumed by the
#   encoder. make_array("main") in this state returns a 2D luma-only array
#   (H, W) with NO channel axis. Any 3-index operation on it raises:
#
#     IndexError: too many indices for array:
#     array is 2-dimensional, but 3 were indexed
#
#   This explains why the error fires on STOP_RECORDING (camera still encoding
#   when the status check runs) AND on consecutive TAKE_SNAPSHOT calls.
#
# Fix:
#   Replace the hardcoded 3D brightness calculation with a dimension-aware
#   one that works on both 2D (luma) and 3D (RGB/YUV) frames:
#
#     brightness = float(frame.mean())
#
#   np.ndarray.mean() with no arguments averages all elements regardless of
#   shape — a 2D luma frame and a 3D RGB frame both produce a valid 0-255
#   brightness value. The occlusion threshold logic is unchanged.
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

log_section "EVVOS Pi Camera — Occlusion Array Dimension Fix (Patch 14)"

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
# PATCH — Replace any 3D-assuming brightness calculation inside
#         camera_status_handler() with frame.mean().
#
# Common patterns written by earlier patches:
#   A)  brightness = frame.mean(axis=2).mean()
#   B)  brightness = frame[:, :, 0].mean()
#   C)  brightness = float(frame[:, :, :3].mean())
#   D)  brightness = np.mean(frame)          ← already safe, but guard anyway
#
# We do a targeted replacement inside the function body only, so we don't
# accidentally change anything else in the file.
# ─────────────────────────────────────────────────────────────────────────────

# Patterns to replace → all become: float(frame.mean())
PATTERNS = [
    r'brightness\s*=\s*frame\.mean\(axis=2\)\.mean\(\)',
    r'brightness\s*=\s*frame\[:, :, 0\]\.mean\(\)',
    r'brightness\s*=\s*float\(frame\[:, :, :3\]\.mean\(\)\)',
    r'brightness\s*=\s*float\(frame\.mean\(axis=2\)\.mean\(\)\)',
    r'brightness\s*=\s*np\.mean\(frame\)',
    r'brightness\s*=\s*float\(np\.mean\(frame\)\)',
]

REPLACEMENT = (
    "# FIX-P14: dimension-aware brightness — works for both 2D (luma, during\n"
    "            # H264 recording) and 3D (RGB/YUV, when camera is idle). Any\n"
    "            # 3D-specific indexing raises IndexError when the encoder is\n"
    "            # consuming the main stream and make_array() returns 2D.\n"
    "            brightness = float(frame.mean())"
)

patched = 0
for pattern in PATTERNS:
    new_src, count = re.subn(pattern, REPLACEMENT, src)
    if count:
        src = new_src
        patched += count
        print(f"Replaced pattern: {pattern}")

if patched == 0:
    # Last-resort: find any line assigning to `brightness` that contains
    # a bracket-index on `frame` and replace it.
    fallback_pattern = r'brightness\s*=\s*[^\n]*frame\[[^\n]+'
    new_src, count = re.subn(fallback_pattern, REPLACEMENT, src)
    if count:
        src = new_src
        patched += count
        print(f"Fallback replacement applied ({count} occurrence(s)).")
    else:
        print("ERROR: Could not find a brightness assignment to patch.")
        print("       Manually check camera_status_handler() in evvos-picam-tcp.py.")
        raise SystemExit(1)

script.write_text(src, encoding="utf-8")
print(f"Done — {patched} brightness expression(s) patched.")
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
    ('FIX-P14 patch marker present',      '# FIX-P14: dimension-aware brightness' in src),
    ('frame.mean() used for brightness',  'brightness = float(frame.mean())'      in src),
    ('no 3D axis=2 indexing',             'frame.mean(axis=2)' not in src),
    ('no 3D channel-0 indexing',          'frame[:, :, 0]'     not in src),
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
