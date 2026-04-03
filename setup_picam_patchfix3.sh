#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Session Transcription State Reset Fix
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_session_reset_14.sh
#
# Or via curl from GitHub raw URL:
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/setup_picam_session_reset_14.sh | sudo bash
#
# Problem:
#   When a new recording session starts, the Pi's in-memory transcription
#   state (current_transcript, current_driver_name, current_plate_number,
#   current_violations, transcription_engine_used) still holds values from
#   the previous session. Any STOP_RECORDING response or transcript JSON
#   produced in the new session can therefore contain stale data from the
#   session before it.
#
#   Additionally, old transcript_*.json files left on disk in RECORDINGS_DIR
#   can be picked up by TRANSFER_FILES before the new session's file is
#   written, causing the wrong JSON to be transferred.
#
# Root cause:
#   setup_picam_recording_clear_13.sh (Fix P13) only added empty
#   transcription fields to the recording_started *response payload*.
#   The Pi's actual in-memory state variables are never zeroed out, and the
#   previous session's JSON file is never deleted before the new session begins.
#
# Fix (applied inside start_recording_handler(), before current_session_id
#      is assigned):
#
#   # FIX-P14: reset transcription state so no previous session's data
#   # bleeds into the new session's STOP_RECORDING response or JSON file.
#   current_transcript        = ""
#   current_driver_name       = ""
#   current_plate_number      = ""
#   current_violations        = []
#   transcription_engine_used = "none"
#   # Also delete the previous session's JSON so TRANSFER_FILES can't pick it up:
#   import glob, os
#   for old_json in glob.glob(os.path.join(RECORDINGS_DIR, "transcript_*.json")):
#       try:
#           os.remove(old_json)
#           print(f"[Pi] Cleaned up stale transcript JSON: {old_json}")
#       except OSError:
#           pass
#
# Relationship to P13:
#   This patch is additive — P13 must already be applied (or be applied
#   alongside this script). P13 clears the *response payload* sent to the
#   mobile app; P14 clears the *server-side state* so that data never
#   enters the payload in the first place.
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

log_section "EVVOS Pi Camera — Session Transcription State Reset Fix"

# ── Backup ────────────────────────────────────────────────────────────────────
cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

# ── Python patcher ────────────────────────────────────────────────────────────
python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD ─────────────────────────────────────────────────────────────────────
if "# FIX-P14: reset transcription state so no previous session" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH — Insert transcription-state reset at the top of the
#         start_recording_handler() already_running=False path, right before
#         current_session_id is assigned.
#
# We anchor on the line that sets current_session_id because it is stable,
# unique, and immediately follows the "not already recording" guard.
# ─────────────────────────────────────────────────────────────────────────────

# The anchor is the `ts = datetime.now()...` line that opens the session
# variable block inside start_recording_handler()'s try: branch.
# In evvos-picam-tcp.py this looks exactly like:
#
#             ts                   = datetime.now().strftime("%Y%m%d_%H%M%S")
#             current_session_id   = f"session_{ts}"
#
# We insert the reset block immediately before `ts = ...`.

ANCHOR = (
    '            ts                   = datetime.now().strftime("%Y%m%d_%H%M%S")\n'
    '            current_session_id   = f"session_{ts}"'
)

RESET_BLOCK = (
    '            # FIX-P14: reset transcription state so no previous session\'s data bleeds\n'
    '            # into the new session\'s STOP_RECORDING response or transcript JSON file.\n'
    '            current_transcript        = ""\n'
    '            current_driver_name       = ""\n'
    '            current_plate_number      = ""\n'
    '            current_violations        = []\n'
    '            transcription_engine_used = "none"\n'
    '            # Delete any stale transcript JSON from the previous session so that\n'
    '            # TRANSFER_FILES cannot pick up the old file before the new one is written.\n'
    '            import glob as _glob\n'
    '            for _old_json in _glob.glob(\n'
    '                    __import__("os").path.join(RECORDINGS_DIR, "transcript_*.json")):\n'
    '                try:\n'
    '                    __import__("os").remove(_old_json)\n'
    '                    print(f"[Pi] Cleaned up stale transcript JSON: {_old_json}")\n'
    '                except OSError:\n'
    '                    pass\n'
)

assert ANCHOR in src, (
    "Anchor not found — the try block in start_recording_handler() may have been modified.\n"
    "Expected these two lines (exact spacing):\n"
    "    ts                   = datetime.now().strftime(\"%Y%m%d_%H%M%S\")\n"
    "    current_session_id   = f\"session_{ts}\"\n"
    "Check start_recording_handler() in evvos-picam-tcp.py."
)

# Insert the reset block immediately before the anchor lines.
src = src.replace(ANCHOR, RESET_BLOCK + ANCHOR, 1)
script.write_text(src, encoding="utf-8")
print("Patch applied: transcription state is now reset at the start of every new recording session.")
PATCHER_EOF

log_success "Python patcher completed"

# ── Syntax check ──────────────────────────────────────────────────────────────
log_section "Syntax check"
python3 -m py_compile "$CAMERA_SCRIPT" && log_success "Syntax OK" || {
    log_error "Syntax error — restoring latest backup..."
    LATEST=$(ls -t "${CAMERA_SCRIPT}".bak.* 2>/dev/null | head -1)
    [ -n "$LATEST" ] && cp "$LATEST" "$CAMERA_SCRIPT" && log_info "Restored: $LATEST"
    exit 1
}

# ── Verification ──────────────────────────────────────────────────────────────
log_section "Verifying patch"
python3 -c "
src = open('/usr/local/bin/evvos-picam-tcp.py').read()
checks = [
    ('FIX-P14 patch marker',                  '# FIX-P14: reset transcription state so no previous session' in src),
    ('current_transcript reset',              'current_transcript        = \"\"'  in src),
    ('current_driver_name reset',             'current_driver_name       = \"\"'  in src),
    ('current_plate_number reset',            'current_plate_number      = \"\"'  in src),
    ('current_violations reset',              'current_violations        = []'    in src),
    ('transcription_engine_used reset',       'transcription_engine_used = \"none\"' in src),
    ('stale JSON cleanup present',            'transcript_*.json' in src),
]
ok = True
for label, result in checks:
    print(f'  {chr(10003) if result else chr(10007)+\" FAIL\"}  {label}')
    if not result: ok = False
import sys; sys.exit(0 if ok else 1)
"

# ── Restart service ───────────────────────────────────────────────────────────
log_section "Restarting evvos-picam-tcp service"
systemctl restart evvos-picam-tcp.service
sleep 2

if systemctl is-active --quiet evvos-picam-tcp.service; then
    log_success "Service restarted and running"
else
    log_error "Service failed — check: journalctl -u evvos-picam-tcp -n 30"
    exit 1
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}  Session Transcription State Reset Fix ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Pi change: start_recording_handler() now resets before${NC}"
echo -e "${CYAN}  each new session:${NC}"
echo -e "${CYAN}    current_transcript        = \"\"${NC}"
echo -e "${CYAN}    current_driver_name       = \"\"${NC}"
echo -e "${CYAN}    current_plate_number      = \"\"${NC}"
echo -e "${CYAN}    current_violations        = []${NC}"
echo -e "${CYAN}    transcription_engine_used = \"none\"${NC}"
echo -e "${CYAN}    → stale transcript_*.json files deleted from RECORDINGS_DIR${NC}"
echo ""
echo -e "${YELLOW}  Relationship to P13:${NC}"
echo -e "${YELLOW}  P13 cleared the response *payload* (mobile app display).${NC}"
echo -e "${YELLOW}  P14 clears the server-side *state* (source of truth).${NC}"
echo -e "${YELLOW}  Both fixes should be applied together for full protection.${NC}"
echo ""
log_success "Fix complete!"
