#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Device Management Intents
# (Restart Device + Clear Cache)
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_device_mgmt_12.sh
#
# What this does:
#   Patches /usr/local/bin/evvos-picam-tcp.py with two new intents sent
#   from the mobile app's Settings screen:
#
#   ┌──────────────────────────────────────────────────────────────────┐
#   │ RESTART_DEVICE                                                   │
#   │   1. Restarts evvos-picam-tcp  (systemctl restart)              │
#   │   2. Restarts evvos-pico-voice (systemctl restart)              │
#   │   3. Reboots the OS            (sudo reboot)                    │
#   │   Provisioning service is NOT touched.                          │
#   │   Sends an ACK before rebooting. 1 s drain delay before reboot. │
#   ├──────────────────────────────────────────────────────────────────┤
#   │ CLEAR_CACHE                                                      │
#   │   Deletes leftover recording artefacts from /home/pi/recordings: │
#   │     • *.h264   (raw H.264 segments — never muxed to .mp4)       │
#   │     • *.wav    (raw audio — never processed)                    │
#   │     • *.mp4    (muxed video — never transferred/uploaded)       │
#   │   Returns { deleted_count, freed_kb } to the mobile app.        │
#   └──────────────────────────────────────────────────────────────────┘
#
# Safe to re-run — guards prevent double-patching.
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

log_section "Patching Pi Camera Service — RESTART_DEVICE + CLEAR_CACHE Intents"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

p1_done = "restart_device_handler" in src
p2_done = "clear_cache_handler"    in src

if p1_done and p2_done:
    print("Both patches already applied — skipping.")
    raise SystemExit(0)

print(f"Patch status: RESTART={'done' if p1_done else 'needed'}  CLEAR_CACHE={'done' if p2_done else 'needed'}")

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 1 — restart_device_handler()
#
# Restarts evvos-picam-tcp and evvos-pico-voice via systemctl, then
# issues `sudo reboot` in a background thread after a 1 s drain delay
# so the ACK JSON can leave the socket before the kernel resets.
# The provisioning service (evvos-provisioning) is explicitly left alone.
# ─────────────────────────────────────────────────────────────────────────────
if not p1_done:
    restart_handler_code = '''
def restart_device_handler():
    """
    Restart camera + voice services then reboot the Raspberry Pi.

    Services restarted (in order):
      1. evvos-picam-tcp    — camera TCP server (this process)
      2. evvos-pico-voice   — Pico voice recognition
    Then: sudo reboot

    evvos-provisioning is intentionally NOT restarted — it manages
    the WiFi hotspot and its state must survive across reboots.

    A 1-second thread delay allows the ACK to drain over TCP before
    the network stack is torn down by the reboot.
    """
    import threading

    def _do_restart():
        import time as _t
        _t.sleep(1)   # drain ACK before network goes down

        print("[RESTART] Restarting evvos-picam-tcp...")
        subprocess.run(["systemctl", "restart", "evvos-picam-tcp"],
                       capture_output=True, timeout=15)

        print("[RESTART] Restarting evvos-pico-voice...")
        subprocess.run(["systemctl", "restart", "evvos-pico-voice"],
                       capture_output=True, timeout=15)

        print("[RESTART] ⚡ Issuing reboot...")
        subprocess.run(["sudo", "reboot"], check=False)

    print("[RESTART] Restart command received from mobile app.")
    threading.Thread(target=_do_restart, daemon=True).start()

    return {
        "status":   "restart_initiated",
        "message":  "Services restarting and device rebooting",
        "services": ["evvos-picam-tcp", "evvos-pico-voice"],
    }

'''
    old = "def get_status_handler():"
    assert old in src, f"Anchor not found: {old!r}"
    src = src.replace(old, restart_handler_code + old, 1)
    print("Patch 1 applied: restart_device_handler()")

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2 — clear_cache_handler()
#
# Deletes all .h264, .wav, and .mp4 files from /home/pi/recordings.
# Returns deleted_count and freed_kb so the mobile app can show a summary.
# Uses glob() — safe when no files match (returns 0 deletions, no error).
# ─────────────────────────────────────────────────────────────────────────────
if not p2_done:
    clear_cache_handler_code = '''
def clear_cache_handler():
    """
    Delete leftover recording artefacts from /home/pi/recordings.

    Targets:
      *.h264  — raw H.264 segments left behind after a failed mux
      *.wav   — raw audio files left behind after a failed transcode
      *.mp4   — muxed video files that were never transferred/uploaded

    Returns the number of files deleted and approximate storage freed.
    This is safe to call at any time — active recordings use temp names
    and the camera service will recreate the directory if needed.
    """
    import glob as _glob

    recordings_dir = Path("/home/pi/recordings")
    patterns = ["*.h264", "*.wav", "*.mp4"]

    deleted  = 0
    freed_kb = 0.0

    for pattern in patterns:
        for fp in recordings_dir.glob(pattern):
            try:
                size_kb  = fp.stat().st_size / 1024
                fp.unlink()
                freed_kb += size_kb
                deleted  += 1
                print(f"[CLEAR_CACHE] Deleted: {fp.name} ({size_kb:.0f} KB)")
            except Exception as err:
                print(f"[CLEAR_CACHE] Could not delete {fp.name}: {err}")

    print(f"[CLEAR_CACHE] ✓ Done — {deleted} file(s) removed, {freed_kb / 1024:.2f} MB freed")

    return {
        "status":        "cache_cleared",
        "deleted_count": deleted,
        "freed_kb":      round(freed_kb, 1),
        "message":       f"{deleted} file(s) removed ({freed_kb / 1024:.2f} MB freed)",
    }

'''
    old = "def get_status_handler():"
    assert old in src, f"Anchor not found: {old!r}"
    src = src.replace(old, clear_cache_handler_code + old, 1)
    print("Patch 2 applied: clear_cache_handler()")

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 3 — Register both intents in the handle_client() router
# Insert before the GET_STATUS branch (same pattern as other intents).
# ─────────────────────────────────────────────────────────────────────────────
router_anchor = '                    elif intent == "GET_STATUS":'
new_router    = (
    '                    elif intent == "RESTART_DEVICE":\n'
    '                        res = restart_device_handler()\n'
    '                    elif intent == "CLEAR_CACHE":\n'
    '                        res = clear_cache_handler()\n'
    '                    elif intent == "GET_STATUS":'
)

if 'RESTART_DEVICE' not in src and 'CLEAR_CACHE' not in src:
    assert router_anchor in src, f"Router anchor not found: {router_anchor!r}"
    src = src.replace(router_anchor, new_router, 1)
    print("Patch 3 applied: RESTART_DEVICE + CLEAR_CACHE added to intent router")
elif 'RESTART_DEVICE' not in src:
    # Partial — only RESTART missing
    src = src.replace(router_anchor,
        '                    elif intent == "RESTART_DEVICE":\n'
        '                        res = restart_device_handler()\n'
        + router_anchor, 1)
    print("Patch 3 applied (partial): RESTART_DEVICE added to intent router")
elif 'CLEAR_CACHE' not in src:
    src = src.replace(router_anchor,
        '                    elif intent == "CLEAR_CACHE":\n'
        '                        res = clear_cache_handler()\n'
        + router_anchor, 1)
    print("Patch 3 applied (partial): CLEAR_CACHE added to intent router")
else:
    print("Patch 3 already applied — skipping router update")

script.write_text(src, encoding="utf-8")
print("\nAll patches written successfully.")
PATCHER_EOF

log_success "Python patcher completed"

log_section "Syntax check"
python3 -m py_compile "$CAMERA_SCRIPT" && log_success "Syntax OK" || {
    log_error "Syntax error — restoring backup..."
    LATEST=$(ls -t "${CAMERA_SCRIPT}".bak.* 2>/dev/null | head -1)
    [ -n "$LATEST" ] && cp "$LATEST" "$CAMERA_SCRIPT" && log_info "Restored: $LATEST"
    exit 1
}

log_section "Verifying patches"
python3 -c "
src = open('/usr/local/bin/evvos-picam-tcp.py').read()
checks = [
    ('restart_device_handler() function',   'restart_device_handler' in src),
    ('RESTART_DEVICE in router',            '\"RESTART_DEVICE\"'      in src),
    ('systemctl restart evvos-picam-tcp',   'evvos-picam-tcp'         in src),
    ('systemctl restart evvos-pico-voice',  'evvos-pico-voice'        in src),
    ('sudo reboot call',                    '\"reboot\"'              in src),
    ('clear_cache_handler() function',      'clear_cache_handler'     in src),
    ('CLEAR_CACHE in router',               '\"CLEAR_CACHE\"'         in src),
    ('*.h264 glob pattern',                 '*.h264'                  in src),
    ('*.wav glob pattern',                  '*.wav'                   in src),
    ('*.mp4 glob pattern',                  '*.mp4'                   in src),
]
ok = True
for label, result in checks:
    print(f'  {chr(10003) if result else chr(10007)+\" FAIL\"}  {label}')
    if not result: ok = False
import sys; sys.exit(0 if ok else 1)
"

log_section "Verifying sudo reboot permission"
SERVICE_USER=$(systemctl show evvos-picam-tcp.service -p User --value 2>/dev/null || echo "root")
if [ "$SERVICE_USER" != "root" ] && [ -n "$SERVICE_USER" ]; then
    SUDOERS_FILE="/etc/sudoers.d/evvos-device-mgmt"
    if [ ! -f "$SUDOERS_FILE" ]; then
        cat > "$SUDOERS_FILE" << SUDOERS
${SERVICE_USER} ALL=(ALL) NOPASSWD: /sbin/shutdown
${SERVICE_USER} ALL=(ALL) NOPASSWD: /sbin/reboot
SUDOERS
        chmod 0440 "$SUDOERS_FILE"
        log_success "Sudoers rules added for ${SERVICE_USER}: shutdown + reboot without password"
    else
        log_info "Sudoers file already present: $SUDOERS_FILE"
        # Ensure reboot is covered
        if ! grep -q "reboot" "$SUDOERS_FILE"; then
            echo "${SERVICE_USER} ALL=(ALL) NOPASSWD: /sbin/reboot" >> "$SUDOERS_FILE"
            log_success "Added reboot rule to existing sudoers file"
        fi
    fi
else
    log_info "Service runs as root — no sudoers rules needed"
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
echo -e "${CYAN}  Device Management intents ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}  RESTART_DEVICE${NC}"
echo -e "${CYAN}    1. systemctl restart evvos-picam-tcp${NC}"
echo -e "${CYAN}    2. systemctl restart evvos-pico-voice${NC}"
echo -e "${CYAN}    3. sudo reboot${NC}"
echo -e "${CYAN}    (evvos-provisioning is NOT touched)${NC}"
echo ""
echo -e "${CYAN}  CLEAR_CACHE${NC}"
echo -e "${CYAN}    rm /home/pi/recordings/*.h264${NC}"
echo -e "${CYAN}    rm /home/pi/recordings/*.wav${NC}"
echo -e "${CYAN}    rm /home/pi/recordings/*.mp4${NC}"
echo -e "${CYAN}    Returns: deleted_count + freed_kb${NC}"
echo ""
echo -e "${YELLOW}  To test manually:${NC}"
echo -e "${YELLOW}    echo '{\"intent\":\"RESTART_DEVICE\",\"id\":\"test\"}' | nc <pi-ip> 9000${NC}"
echo -e "${YELLOW}    echo '{\"intent\":\"CLEAR_CACHE\",\"id\":\"test\"}'    | nc <pi-ip> 9000${NC}"
echo ""
log_success "Device management patch complete!"
