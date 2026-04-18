#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Revert Emergency Chunk Splitter
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_revert_chunks.sh
#
# What this does:
#   Reverts the changes made by setup_picam_emergency_chunks.sh:
#     1. Removes the split_mp4_into_chunks() helper function
#     2. Restores the original single-file MP4 collection block inside
#        transfer_files_handler() (picks the newest .mp4 and sends it as-is)
#     3. Removes the MAX_CHUNK_MB constant
#
# Why revert?
#   Emergency recordings are now capped at 2 minutes on the mobile side —
#   the app auto-stops at the 120-second limit even during an active emergency
#   (after first marking the incident RESOLVED). 2-minute recordings never
#   approach Supabase's 50 MB object limit, so chunking is unnecessary.
#
# Safe to re-run — guard prevents errors if already reverted.
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
    exit 1
fi

log_section "Reverting Emergency Chunk Splitter Patch"

# ── Guard: skip if chunk splitter is not present ─────────────────────────────
if ! grep -q "split_mp4_into_chunks" "$CAMERA_SCRIPT"; then
    log_info "Chunk splitter not found in script — nothing to revert."
    exit 0
fi

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
import re
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD ─────────────────────────────────────────────────────────────────────
if "split_mp4_into_chunks" not in src:
    print("Chunk splitter not present — nothing to revert.")
    raise SystemExit(0)

patched = 0

# ─────────────────────────────────────────────────────────────────────────────
# REVERT 1: Remove MAX_CHUNK_MB constant + split_mp4_into_chunks() function
#
# The injected block starts just before transfer_files_handler() with:
#   \n# Maximum size (MB) per video segment ...
# and ends with the closing line of split_mp4_into_chunks(), just before:
#   def transfer_files_handler(conn):
#
# Strategy: use a regex to remove everything between the MAX_CHUNK_MB comment
# and the def transfer_files_handler line (exclusive).
# ─────────────────────────────────────────────────────────────────────────────
pattern = re.compile(
    r'\n# Maximum size \(MB\) per video segment.*?(?=\ndef transfer_files_handler\(conn\):)',
    re.DOTALL
)
if pattern.search(src):
    src = pattern.sub('', src, count=1)
    print("Revert 1 applied: split_mp4_into_chunks() and MAX_CHUNK_MB removed")
    patched += 1
else:
    print("ERROR: Could not locate split_mp4_into_chunks block. Manual removal required.")
    raise SystemExit(1)

# ─────────────────────────────────────────────────────────────────────────────
# REVERT 2: Restore the original simple MP4 collection block inside
#           transfer_files_handler()
#
# Current (chunked) block:
#     # 1. MP4 video — split into ≤20 MB chunks for long emergency recordings
#     # "Raw" files are those not already named video*.mp4 (pre-chunked).
#     all_mp4 = sorted(RECORDINGS_DIR.glob("*.mp4"), key=lambda f: f.stat().st_mtime, reverse=True)
#     raw_mp4s = [f for f in all_mp4 if not f.name.startswith("video")]
#     if raw_mp4s:
#         # Split (or rename) the newest raw recording
#         chunks = split_mp4_into_chunks(raw_mp4s[0])
#         for chunk in chunks:
#             files_to_send.append(chunk)
#             print(f"[TRANSFER] Chunk: {chunk.name} ({chunk.stat().st_size / 1024 / 1024:.2f} MB)")
#     else:
#         # Pick up already-named video*.mp4 files (split in a prior run)
#         pre_named = sorted(RECORDINGS_DIR.glob("video*.mp4"))
#         for c in pre_named:
#             files_to_send.append(c)
#             print(f"[TRANSFER] Pre-chunk: {c.name} ({c.stat().st_size / 1024 / 1024:.2f} MB)")
#
# Restored (original) block:
#     # 1. MP4 video
#     all_mp4 = sorted(RECORDINGS_DIR.glob("*.mp4"), key=lambda f: f.stat().st_mtime, reverse=True)
#     if all_mp4:
#         mp4 = all_mp4[0]
#         files_to_send.append(mp4)
#         print(f"[TRANSFER] Video: {mp4.name} ({mp4.stat().st_size / 1024 / 1024:.2f} MB)")
# ─────────────────────────────────────────────────────────────────────────────
old_video_section = (
    '    # 1. MP4 video — split into ≤20 MB chunks for long emergency recordings\n'
    '    # "Raw" files are those not already named video*.mp4 (pre-chunked).\n'
    '    all_mp4 = sorted(RECORDINGS_DIR.glob("*.mp4"), key=lambda f: f.stat().st_mtime, reverse=True)\n'
    '    raw_mp4s = [f for f in all_mp4 if not f.name.startswith("video")]\n'
    '    if raw_mp4s:\n'
    '        # Split (or rename) the newest raw recording\n'
    '        chunks = split_mp4_into_chunks(raw_mp4s[0])\n'
    '        for chunk in chunks:\n'
    '            files_to_send.append(chunk)\n'
    '            print(f"[TRANSFER] Chunk: {chunk.name} ({chunk.stat().st_size / 1024 / 1024:.2f} MB)")\n'
    '    else:\n'
    '        # Pick up already-named video*.mp4 files (split in a prior run)\n'
    '        pre_named = sorted(RECORDINGS_DIR.glob("video*.mp4"))\n'
    '        for c in pre_named:\n'
    '            files_to_send.append(c)\n'
    '            print(f"[TRANSFER] Pre-chunk: {c.name} ({c.stat().st_size / 1024 / 1024:.2f} MB)")'
)

new_video_section = (
    '    # 1. MP4 video\n'
    '    all_mp4 = sorted(RECORDINGS_DIR.glob("*.mp4"), key=lambda f: f.stat().st_mtime, reverse=True)\n'
    '    if all_mp4:\n'
    '        mp4 = all_mp4[0]\n'
    '        files_to_send.append(mp4)\n'
    '        print(f"[TRANSFER] Video: {mp4.name} ({mp4.stat().st_size / 1024 / 1024:.2f} MB)")'
)

if old_video_section in src:
    src = src.replace(old_video_section, new_video_section, 1)
    print("Revert 2 applied: transfer_files_handler video block restored to original")
    patched += 1
else:
    print("ERROR: Could not find chunked video section anchor. Manual revert required.")
    raise SystemExit(1)

script.write_text(src, encoding="utf-8")
print(f"\nDone — {patched} revert(s) applied.")
PATCHER_EOF

log_success "Python patcher completed"

log_section "Syntax check"
python3 -m py_compile "$CAMERA_SCRIPT" && log_success "Syntax OK" || {
    log_error "Syntax error — restoring backup..."
    LATEST=$(ls -t "${CAMERA_SCRIPT}".bak.* 2>/dev/null | head -1)
    [ -n "$LATEST" ] && cp "$LATEST" "$CAMERA_SCRIPT" && log_info "Restored: $LATEST"
    exit 1
}

log_section "Verifying revert"
python3 -c "
src = open('/usr/local/bin/evvos-picam-tcp.py').read()
checks = [
    ('split_mp4_into_chunks removed',  'split_mp4_into_chunks' not in src),
    ('MAX_CHUNK_MB removed',           'MAX_CHUNK_MB' not in src),
    ('Original single-file block back', '# 1. MP4 video\n    all_mp4 = sorted' in src),
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
echo -e "${CYAN}  Chunk Splitter Reverted Successfully${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  • split_mp4_into_chunks() removed${NC}"
echo -e "${CYAN}  • transfer_files_handler() restored to single-file behaviour${NC}"
echo -e "${CYAN}  • Pi will send the newest .mp4 as a single file (no splitting)${NC}"
echo ""
echo -e "${YELLOW}  NOTE: Emergency recordings are now capped at 2 minutes by the${NC}"
echo -e "${YELLOW}        mobile app. The recording auto-stops at the 120-second${NC}"
echo -e "${YELLOW}        limit (even during an active emergency alert), marking the${NC}"
echo -e "${YELLOW}        incident RESOLVED first, then stopping. 2-minute recordings${NC}"
echo -e "${YELLOW}        are well within Supabase's 50 MB limit — no chunking needed.${NC}"
echo ""
log_success "Revert complete!"
