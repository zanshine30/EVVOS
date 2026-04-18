#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Graceful Shutdown Intent
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_shutdown_11.sh
#
# What this does:
#   Patches /usr/local/bin/evvos-picam-tcp.py to handle a SHUTDOWN intent
#   sent from the mobile app's Settings → "Shutdown Device" button.
#
#   When the intent is received the Pi:
#     1. Sends a JSON acknowledgement to the mobile app
#     2. Waits 1 second so the socket can drain
#     3. Runs `sudo shutdown now` via subprocess
#
#   The mobile app sends SHUTDOWN over a fresh TCP connection and expects
#   the socket to drop immediately after — no further response is required.
#
# Why not just SSH?
#   The mobile app has no SSH credentials. Using the existing TCP socket
#   keeps shutdown within the same trusted channel as all other intents.
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

log_section "Patching Pi Camera Service — SHUTDOWN Intent"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD ─────────────────────────────────────────────────────────────────────
if "shutdown_handler" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 1: Inject shutdown_handler() before get_status_handler()
#
# The handler:
#   1. Replies with an ACK so the mobile app knows the command was received.
#   2. Spawns `sudo shutdown now` in a thread so it doesn't block the reply.
#   3. The 1-second delay inside the thread gives the TCP stack time to
#      flush the ACK before the kernel tears down the network interfaces.
# ─────────────────────────────────────────────────────────────────────────────
shutdown_handler_code = '''
def shutdown_handler():
    """
    Gracefully power off the Raspberry Pi.

    Called by the SHUTDOWN intent from the mobile app Settings screen.
    Sends an acknowledgement JSON back to the client, then issues
    `sudo shutdown now` after a 1-second drain delay so the ACK can
    be delivered before the network stack goes down.
    """
    import threading

    def _do_shutdown():
        import time as _t
        _t.sleep(1)   # allow the ACK to drain over TCP before shutdown
        print("[SHUTDOWN] ⚡ Executing: sudo shutdown now")
        subprocess.run(["sudo", "shutdown", "now"], check=False)

    print("[SHUTDOWN] Shutdown command received from mobile app.")
    threading.Thread(target=_do_shutdown, daemon=True).start()

    return {"status": "shutdown_initiated", "message": "Raspberry Pi is shutting down"}

'''

old = "def get_status_handler():"
assert old in src, f"Anchor not found: {old!r}"
src = src.replace(old, shutdown_handler_code + old, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2: Register SHUTDOWN in the intent router (handle_client)
# Insert before the GET_STATUS branch so it is reached cleanly.
# ─────────────────────────────────────────────────────────────────────────────
old = '                    elif intent == "GET_STATUS":'
new = (
    '                    elif intent == "SHUTDOWN":\n'
    '                        res = shutdown_handler()\n'
    '                    elif intent == "GET_STATUS":'
)
assert old in src, f"Anchor not found (patch 2): {old!r}"
src = src.replace(old, new, 1)

script.write_text(src, encoding="utf-8")
print("Both patches applied successfully.")
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
    ('shutdown_handler() function present', 'shutdown_handler' in src),
    ('SHUTDOWN intent in router',           '\"SHUTDOWN\"' in src),
    ('subprocess shutdown call',            'shutdown now' in src),
]
ok = True
for label, result in checks:
    print(f'  {chr(10003) if result else chr(10007)+\" FAIL\"}  {label}')
    if not result: ok = False
import sys; sys.exit(0 if ok else 1)
"

log_section "Verifying sudo shutdown permission"
# Ensure the evvos service user can run shutdown without a password.
# If the service runs as root this block is a no-op.
SERVICE_USER=$(systemctl show evvos-picam-tcp.service -p User --value 2>/dev/null || echo "root")
if [ "$SERVICE_USER" != "root" ] && [ -n "$SERVICE_USER" ]; then
    SUDOERS_FILE="/etc/sudoers.d/evvos-shutdown"
    if [ ! -f "$SUDOERS_FILE" ]; then
        echo "${SERVICE_USER} ALL=(ALL) NOPASSWD: /sbin/shutdown" > "$SUDOERS_FILE"
        chmod 0440 "$SUDOERS_FILE"
        log_success "Sudoers rule added: ${SERVICE_USER} can run /sbin/shutdown without password"
    else
        log_info "Sudoers rule already present: $SUDOERS_FILE"
    fi
else
    log_info "Service runs as root — no sudoers rule needed"
fi

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
echo -e "${CYAN}  Graceful Shutdown intent ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  New TCP intent: SHUTDOWN${NC}"
echo -e "${CYAN}  Flow:  Mobile app → SHUTDOWN intent → Pi ACKs → sudo shutdown now${NC}"
echo -e "${CYAN}  Delay: 1 s before shutdown so the ACK drains over TCP${NC}"
echo -e "${CYAN}  Trigger: Settings → Shutdown Device button (requires paired device)${NC}"
echo ""
echo -e "${YELLOW}  To test manually:${NC}"
echo -e "${YELLOW}    echo '{\"intent\":\"SHUTDOWN\",\"id\":\"test\"}' | nc <pi-ip> 9000${NC}"
echo ""
log_success "Shutdown patch complete!"