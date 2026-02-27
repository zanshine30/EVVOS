#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Dynamic Mux Timeout Patch
#
# Problem:
#   Emergency recordings bypass the normal 2-minute cap. The resulting H264
#   file can be 3+ minutes long. The ffmpeg mux step (H264 + WAV → MP4)
#   inside stop_recording_handler() has a hardcoded timeout=120 seconds —
#   the same as the old recording limit. For a 3m 24s recording on a Pi Zero
#   2 W the mux itself takes >120 s, causing:
#
#     "Command '[ffmpeg, ...]' timed out after 120 seconds"
#
#   The chunk splitter (setup_picam_emergency_chunks.sh) never gets a chance
#   to run because the MP4 is never produced in the first place.
#
# Fix:
#   Replace the hardcoded timeout=120 with a dynamic value:
#
#     mux_timeout = max(180, int(raw_h264_size_bytes / (200 * 1024)))
#
#   Rationale:
#     • 200 KB/s is a conservative lower-bound encode rate on Pi Zero 2 W
#       with -preset ultrafast -crf 23.
#     • This gives ~1 second of timeout per ~200 KB of raw H264.
#     • A 3m 24s recording at ~24 FPS / 1080p produces ~40–80 MB of raw
#       H264 → timeout of 200–400 s, safely above the actual mux time.
#     • The 180 s floor ensures even tiny files always get a generous window.
#     • Normal 2-minute recordings produce ~20–30 MB → timeout of 100–150 s,
#       so the 180 s floor also protects them.
#
# Run on the Raspberry Pi as root AFTER setup_picam.sh:
#   sudo bash setup_picam_mux_timeout.sh
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

if ! grep -q "stop_recording_handler" "$CAMERA_SCRIPT"; then
    log_error "stop_recording_handler not found — run setup_picam.sh first."
    exit 1
fi

log_section "Patching stop_recording_handler — Dynamic Mux Timeout"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD ─────────────────────────────────────────────────────────────────────
if "mux_timeout" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# Replace the hardcoded timeout=120 with a dynamic value computed from
# the raw H264 file size on disk.
#
# Old:
#     res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
#
# New:
#     # Dynamic timeout: 1 second per ~200 KB of raw H264, minimum 180 s.
#     # Emergency recordings can be 3-5+ minutes; the mux scales with duration.
#     mux_timeout = max(180, int(raw_size / (200 * 1024)))
#     print(f"[FFMPEG] Mux timeout: {mux_timeout}s (raw H264: {raw_size / 1024 / 1024:.1f} MB)")
#     res = subprocess.run(cmd, capture_output=True, text=True, timeout=mux_timeout)
# ─────────────────────────────────────────────────────────────────────────────
old = "            res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)"
new = (
    "            # Dynamic mux timeout — scales with raw H264 size so that\n"
    "            # long emergency recordings don't time out before muxing completes.\n"
    "            # 200 KB/s is a conservative encode rate on Pi Zero 2 W (-preset ultrafast).\n"
    "            # Floor of 180 s protects normal 2-minute recordings as well.\n"
    "            mux_timeout = max(180, int(raw_size / (200 * 1024)))\n"
    "            print(f\"[FFMPEG] Mux timeout: {mux_timeout}s (raw H264: {raw_size / 1024 / 1024:.1f} MB)\")\n"
    "            res = subprocess.run(cmd, capture_output=True, text=True, timeout=mux_timeout)"
)

assert old in src, (
    "Anchor not found — the subprocess.run(cmd, ..., timeout=120) line may have changed.\n"
    "Check stop_recording_handler() in evvos-picam-tcp.py."
)
src = src.replace(old, new, 1)

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
checks = [
    ('mux_timeout variable',  'mux_timeout = max(180'),
    ('dynamic timeout in run', 'timeout=mux_timeout'),
    ('old hardcoded 120 gone', 'timeout=120' not in src),
]
all_ok = True
for label, check in checks:
    ok = check if isinstance(check, bool) else (check in src)
    print(f'  {chr(10003) if ok else chr(10007)+\" FAIL\"}  {label}')
    if not ok:
        all_ok = False
import sys; sys.exit(0 if all_ok else 1)
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
echo -e "${CYAN}  Dynamic Mux Timeout patch ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Old:  timeout=120 (hardcoded — always 2 minutes)${NC}"
echo -e "${CYAN}  New:  timeout=max(180, raw_h264_bytes / (200*1024))${NC}"
echo ""
echo -e "${CYAN}  Examples:${NC}"
echo -e "${CYAN}    20 MB H264 (2 min recording)  → 180 s timeout (floor)${NC}"
echo -e "${CYAN}    50 MB H264 (3-4 min emergency) → ~256 s timeout${NC}"
echo -e "${CYAN}    80 MB H264 (5+ min emergency)  → ~410 s timeout${NC}"
echo ""
echo -e "${YELLOW}  NOTE: The mux itself on Pi Zero 2 W typically takes 30–90 s${NC}"
echo -e "${YELLOW}        for a 3-minute recording. This patch gives it ample headroom.${NC}"
echo -e "${YELLOW}        After muxing succeeds, setup_picam_emergency_chunks.sh will${NC}"
echo -e "${YELLOW}        then correctly split the MP4 into ≤20 MB chunks.${NC}"
echo ""
log_success "Done."
