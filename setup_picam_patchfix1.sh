#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Recording Start Session Reset Fix (FIX-P14) - REVISED
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

log_section "Applying FIX-P14: Transcription State Reset"

# Create a backup before proceeding
cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path
import os

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# GUARD: Don't patch twice
if "# FIX-P14:" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# The exact block from your setup_picam_4.sh file
old = """        try:
            RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
            ts                   = datetime.now().strftime("%Y%m%d_%H%M%S")
            current_session_id   = f"session_{ts}\""""

# The new block with state reset and JSON cleanup
new = """        try:
            RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
            ts                   = datetime.now().strftime("%Y%m%d_%H%M%S")

            # FIX-P14: reset transcription state so no previous session data bleeds into
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

if old not in src:
    # Diagnostic: Print a bit of the file to help debug if it fails again
    print("DEBUG: Could not find anchor. Target script may be corrupted or different version.")
    import sys
    sys.exit(1)

src = src.replace(old, new, 1)
script.write_text(src, encoding="utf-8")
print("Patch applied successfully.")
PATCHER_EOF

log_success "Python patcher completed"

# Syntax check to ensure no indentation errors were introduced
python3 -m py_compile "$CAMERA_SCRIPT" && log_success "Syntax Check OK"

log_section "Restarting Service"
systemctl restart evvos-picam-tcp.service
log_success "Service restarted"
