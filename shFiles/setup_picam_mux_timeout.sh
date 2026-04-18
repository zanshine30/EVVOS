#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Dynamic Mux Timeout Patch  (v2 — extended)
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
# Fix (v2 — extended):
#   Replace the hardcoded timeout=120 (or any prior mux_timeout formula)
#   with a much more generous dynamic value:
#
#     mux_timeout = max(600, int(raw_h264_size_bytes / (50 * 1024)))
#
#   Rationale:
#     • 50 KB/s is a very conservative encode rate — ~4× slower than the
#       Pi Zero 2 W actually achieves. This gives a large safety margin for
#       thermal throttling, SD-card slowdowns, or CPU contention.
#     • 600 s (10 min) floor means even a tiny file always has 10 minutes.
#     • A 3m 24s recording (~50–80 MB H264) → 1000–1600 s timeout.
#     • A 10-minute emergency (~200 MB H264) → ~4000 s timeout.
#     • ffmpeg on Pi Zero 2 W with -preset ultrafast typically completes
#       a 3-minute mux in 60–120 s — this gives it 10–25× headroom.
#
# v2 changes vs v1:
#   • Floor raised:  180 s  → 600 s  (10 minutes)
#   • Rate lowered:  200 KB/s → 50 KB/s  (4× more conservative scaling)
#   • Guard updated: also replaces an already-applied v1 patch
#
# Run on the Raspberry Pi as root AFTER setup_picam.sh:
#   sudo bash setup_picam_mux_timeout.sh
#
# Safe to re-run — replaces both unpatched (timeout=120) and v1-patched
# (mux_timeout = max(180, ...)) scripts.
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

log_section "Patching stop_recording_handler — Extended Dynamic Mux Timeout (v2)"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD: already on v2 ──────────────────────────────────────────────────────
if "mux_timeout = max(600" in src:
    print("Already on v2 — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# There are two possible states of the script:
#   A) Unpatched: contains the original hardcoded timeout=120 line
#   B) v1-patched: contains mux_timeout = max(180, ...) from the first patch
#
# We handle both by trying each anchor in order.
# ─────────────────────────────────────────────────────────────────────────────

NEW_LINES = (
    "            # Dynamic mux timeout (v2 — extended) — scales with raw H264 size.\n"
    "            # Floor of 600 s (10 min) + 1 s per 50 KB gives ample headroom even\n"
    "            # under thermal throttling or SD-card slowdowns on Pi Zero 2 W.\n"
    "            # A 3-min emergency recording (~50-80 MB) -> 1000-1600 s timeout.\n"
    "            mux_timeout = max(600, int(raw_size / (50 * 1024)))\n"
    "            print(f\"[FFMPEG] Mux timeout: {mux_timeout}s (raw H264: {raw_size / 1024 / 1024:.1f} MB)\")\n"
    "            res = subprocess.run(cmd, capture_output=True, text=True, timeout=mux_timeout)"
)

# Case A: original unpatched script
OLD_A = "            res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)"

# Case B: v1 dynamic timeout block
OLD_B = (
    "            # Dynamic mux timeout — scales with raw H264 size so that\n"
    "            # long emergency recordings don't time out before muxing completes.\n"
    "            # 200 KB/s is a conservative encode rate on Pi Zero 2 W (-preset ultrafast).\n"
    "            # Floor of 180 s protects normal 2-minute recordings as well.\n"
    "            mux_timeout = max(180, int(raw_size / (200 * 1024)))\n"
    "            print(f\"[FFMPEG] Mux timeout: {mux_timeout}s (raw H264: {raw_size / 1024 / 1024:.1f} MB)\")\n"
    "            res = subprocess.run(cmd, capture_output=True, text=True, timeout=mux_timeout)"
)

if OLD_A in src:
    src = src.replace(OLD_A, NEW_LINES, 1)
    print("Case A: replaced hardcoded timeout=120 with v2 dynamic timeout.")
elif OLD_B in src:
    src = src.replace(OLD_B, NEW_LINES, 1)
    print("Case B: upgraded v1 dynamic timeout to v2 (600 s floor, 50 KB/s rate).")
else:
    raise AssertionError(
        "Could not find a patchable timeout line in stop_recording_handler().\n"
        "Neither 'timeout=120' nor the v1 mux_timeout block were found.\n"
        "Check the script manually: /usr/local/bin/evvos-picam-tcp.py"
    )

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
    ('v2 floor (600 s)',       'mux_timeout = max(600'),
    ('v2 rate  (50 KB/s)',     '/ (50 * 1024)'),
    ('dynamic timeout in run', 'timeout=mux_timeout'),
    ('old hardcoded 120 gone', 'timeout=120' not in src),
    ('old v1 floor gone',      'max(180,' not in src),
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
echo -e "${CYAN}  Dynamic Mux Timeout v2 ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Formula:  timeout = max(600, raw_h264_bytes / (50*1024))${NC}"
echo -e "${CYAN}  Floor:    600 s (10 minutes — regardless of file size)${NC}"
echo -e "${CYAN}  Scaling:  +1 s per 50 KB of raw H264 (4x more conservative)${NC}"
echo ""
echo -e "${CYAN}  Examples:${NC}"
echo -e "${CYAN}    20 MB H264  (2 min recording)    →  600 s timeout (floor)${NC}"
echo -e "${CYAN}    50 MB H264  (3 min emergency)    → 1024 s timeout${NC}"
echo -e "${CYAN}    80 MB H264  (4-5 min emergency)  → 1638 s timeout${NC}"
echo -e "${CYAN}    200 MB H264 (10 min emergency)   → 4096 s timeout${NC}"
echo ""
echo -e "${YELLOW}  Actual mux time on Pi Zero 2 W (-preset ultrafast):${NC}"
echo -e "${YELLOW}    ~60-120 s for a 3-minute recording (10-25x headroom)${NC}"
echo -e "${YELLOW}  After mux succeeds, the chunk splitter splits into <=20 MB parts.${NC}"
echo ""
log_success "Done."
