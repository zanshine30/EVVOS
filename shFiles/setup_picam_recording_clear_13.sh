#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Recording Start Transcription Clear Fix
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_recording_clear_13.sh
#
# Or via curl from GitHub raw URL:
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/setup_picam_recording_clear_13.sh | sudo bash
#
# Problem:
#   Every time a new recording session starts, the mobile app keeps
#   displaying the transcription from the PREVIOUS recording session.
#
# Root cause:
#   start_recording_handler() never includes transcription fields in its
#   response. The mobile app has nothing telling it to clear the transcript,
#   driver name, plate number, and violations it stored from the last
#   STOP_RECORDING response — so stale data persists on screen.
#
# Fix:
#   Add empty transcription fields to the recording_started response:
#     • transcript          → ""
#     • driver_name         → ""
#     • plate_number        → ""
#     • violations          → []
#     • transcription_engine → "none"
#
#   The mobile app should read these fields on every recording_started
#   event and use them to reset its transcription display immediately.
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

log_section "EVVOS Pi Camera — Recording Start Transcription Clear Fix"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD ─────────────────────────────────────────────────────────────────────
if "# FIX-P13: clear transcription on new session start" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH — Add empty transcription fields to the recording_started response
#         returned by start_recording_handler() (the already_running=False path).
#
# The mobile app must read these fields on every recording_started event
# and use them to reset any transcription data from the previous session.
# ─────────────────────────────────────────────────────────────────────────────
old = (
    '            return {\n'
    '                "status":          "recording_started",\n'
    '                "session_id":      current_session_id,\n'
    '                "video_path":      str(current_video_path),\n'
    '                "pi_ip":           get_pi_ip(),\n'
    '                "http_port":       HTTP_PORT,\n'
    '                "already_running": False,\n'
    '                "elapsed_seconds": 0,\n'
    '            }'
)
new = (
    '            return {\n'
    '                "status":          "recording_started",\n'
    '                "session_id":      current_session_id,\n'
    '                "video_path":      str(current_video_path),\n'
    '                "pi_ip":           get_pi_ip(),\n'
    '                "http_port":       HTTP_PORT,\n'
    '                "already_running": False,\n'
    '                "elapsed_seconds": 0,\n'
    '                # FIX-P13: clear transcription on new session start\n'
    '                # Mobile app must reset its display when it sees these empty fields.\n'
    '                "transcript":           "",\n'
    '                "driver_name":          "",\n'
    '                "plate_number":         "",\n'
    '                "violations":           [],\n'
    '                "transcription_engine": "none",\n'
    '            }'
)

assert old in src, (
    "Anchor not found — the recording_started return block may have been modified.\n"
    "Check start_recording_handler() in evvos-picam-tcp.py."
)

src = src.replace(old, new, 1)
script.write_text(src, encoding="utf-8")
print("Patch applied: recording_started response now includes empty transcription fields.")
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
    ('FIX-P13 patch marker',                    '# FIX-P13: clear transcription on new session start' in src),
    ('transcript cleared on start',             '\"transcript\":           \"\"'  in src),
    ('driver_name cleared on start',            '\"driver_name\":          \"\"'  in src),
    ('plate_number cleared on start',           '\"plate_number\":         \"\"'  in src),
    ('violations cleared on start',             '\"violations\":           []'    in src),
    ('transcription_engine cleared on start',   '\"transcription_engine\": \"none\"' in src),
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
echo -e "${CYAN}  Recording Start Transcription Clear Fix ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Pi change: recording_started response now includes:${NC}"
echo -e "${CYAN}    transcript:           \"\"${NC}"
echo -e "${CYAN}    driver_name:          \"\"${NC}"
echo -e "${CYAN}    plate_number:         \"\"${NC}"
echo -e "${CYAN}    violations:           []${NC}"
echo -e "${CYAN}    transcription_engine: \"none\"${NC}"
echo ""
echo -e "${YELLOW}  Mobile app action required:${NC}"
echo -e "${YELLOW}  When recording_started is received, read these fields${NC}"
echo -e "${YELLOW}  and use them to clear any transcription shown on screen.${NC}"
echo ""
log_success "Fix complete!"
