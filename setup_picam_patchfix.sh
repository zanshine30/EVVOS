#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Recording Start Session Reset Fix (FIX-P14)
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_session_reset_14.sh
#
# Or via curl from GitHub raw URL:
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/setup_picam_session_reset_14.sh | sudo bash
#
# Problem:
#   While FIX-P13 cleared the JSON payload sent to the mobile app, the Pi's
#   in-memory state and the on-disk JSON from the previous session were 
#   never touched, allowing stale data to bleed into subsequent sessions or 
#   be picked up by TRANSFER_FILES.
#
# Fix:
#   Injects a transcription state reset into start_recording_handler(),
#   immediately before the new current_session_id is generated. It zeroes out
#   the global state strings/lists and purges any stale transcript_*.json 
#   files from the recordings directory.
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

log_section "EVVOS Pi Camera — Recording Start Session Reset Fix"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD ─────────────────────────────────────────────────────────────────────
if "# FIX-P14: reset transcription state so no previous session" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH — Inject state reset & JSON cleanup right before current_session_id
# ─────────────────────────────────────────────────────────────────────────────
old = """            try:
                RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
                ts                   = datetime.now().strftime("%Y%m%d_%H%M%S")
                current_session_id   = f"session_{ts}\""""

new = """            try:
                RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
                ts                   = datetime.now().strftime("%Y%m%d_%H%M%S")

                # FIX-P14: reset transcription state so no previous session's data bleeds into
                # the new session's STOP_RECORDING response or transcript JSON file.
                global current_transcript, current_driver_name, current_plate_number, current_violations, transcription_engine_used
                current_transcript        = ""
                current_driver_name       = ""
                current_plate_number      = ""
                current_violations        = []
                transcription_engine_used = "none"

                # Also delete the previous session's JSON so TRANSFER_FILES can't pick it up:
                import glob, os
                for old_json in glob.glob(os.path.join(str(RECORDINGS_DIR), "transcript_*.json")):
                    try:
                        os.remove(old_json)
                        print(f"[Pi] Cleaned up stale transcript JSON: {old_json}")
                    except OSError:
                        pass

                current_session_id   = f"session_{ts}\""""

assert old in src, (
    "Anchor not found — the try block in start_recording_handler() may have been modified.\n"
    "Check start_recording_handler() in evvos-picam-tcp.py."
)

src = src.replace(old, new, 1)
script.write_text(src, encoding="utf-8")
print("Patch applied: Pi-side memory and stale JSONs are now cleared on start.")
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
    ('FIX-P14 patch marker',        '# FIX-P14: reset transcription state' in src),
    ('Global variables declared',   'global current_transcript, current_driver_name' in src),
    ('Variables zeroed out',        'current_violations        = []' in src),
    ('JSON cleanup loop present',   'for old_json in glob.glob' in src),
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
echo -e "${CYAN}  Session Reset & JSON Cleanup Fix ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Pi change: start_recording_handler() now resets:${NC}"
echo -e "${CYAN}    • current_transcript, current_driver_name, etc.${NC}"
echo -e "${CYAN}    • Deletes any 'transcript_*.json' found in the recordings folder.${NC}"
echo ""
log_success "Fix P14 complete!"
