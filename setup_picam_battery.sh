#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Power Status Heartbeat Patch
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_battery.sh
#
# What this does:
#   Patches /usr/local/bin/evvos-picam-tcp.py to add a background heartbeat
#   thread that PATCHes the device_credentials Supabase table every 60 s,
#   writing:
#     • battery    = "POWERED ON"   (string — Pi is running, no HAT needed)
#     • ip_address = <Pi's LAN IP>
#     • last_seen  = <current UTC timestamp>
#
#   The Supabase pg_cron job (defined in device_credentials.sql) automatically
#   flips battery to "POWERED OFF" if no heartbeat arrives within 70 seconds,
#   so the mobile app always shows an accurate power state even when the Pi
#   is switched off or loses network.
#
# NOTE: Battery percentage is intentionally NOT tracked because the Pi Zero 2 W
#       is powered by a USB power bank with no HAT, so no capacity data is
#       available. "POWERED ON / POWERED OFF" is the correct model here.
#
# Supabase credentials are read from /etc/evvos/config.env (same as picam).
# The device_id is always EVVOS_0001 (matches setup_evvos.sh).
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

log_section "Patching Pi Camera Service — Power Status Heartbeat"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD ─────────────────────────────────────────────────────────────────────
if "_heartbeat_worker" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 1 — Add heartbeat constants + thread before get_status_handler()
# ─────────────────────────────────────────────────────────────────────────────
heartbeat_code = '''
# ── Power Status Heartbeat ─────────────────────────────────────────────────────

# Supabase device identifier — must match the value stored in device_credentials
DEVICE_ID = "EVVOS_0001"

# How often (seconds) the heartbeat thread posts to Supabase
HEARTBEAT_INTERVAL = 60


def _heartbeat_worker():
    """
    Background thread: push battery="POWERED ON", ip_address, and last_seen
    to Supabase every HEARTBEAT_INTERVAL seconds via a REST PATCH request.

    The Pi Zero 2 W is powered by a USB power bank with no HAT, so we cannot
    read a battery percentage.  Instead, the string "POWERED ON" is written
    while the Pi is running.  The Supabase pg_cron job defined in
    device_credentials.sql automatically flips the value to "POWERED OFF"
    if no heartbeat arrives within 70 seconds.

    Uses the same SUPABASE_URL / SUPABASE_ANON_KEY env vars as the rest of
    the service (loaded from /etc/evvos/config.env by the systemd unit).

    Failure is logged but never raises — the thread must stay alive.
    """
    import time as _time
    import json as _json
    import urllib.request
    import urllib.error

    # Give the service 5 s to fully start before first heartbeat
    _time.sleep(5)

    while True:
        try:
            url  = os.environ.get("SUPABASE_URL", "").rstrip("/")
            anon = os.environ.get("SUPABASE_ANON_KEY", "")

            if url and anon:
                pi_ip   = get_pi_ip()
                now_iso = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

                payload = {
                    "battery":    "POWERED ON",
                    "last_seen":  now_iso,
                    "ip_address": pi_ip,
                }

                body     = _json.dumps(payload).encode("utf-8")
                endpoint = (
                    f"{url}/rest/v1/device_credentials"
                    f"?device_id=eq.{DEVICE_ID}"
                )
                req = urllib.request.Request(
                    endpoint,
                    data=body,
                    method="PATCH",
                    headers={
                        "Content-Type":  "application/json",
                        "apikey":        anon,
                        "Authorization": f"Bearer {anon}",
                        "Prefer":        "return=minimal",
                    },
                )
                with urllib.request.urlopen(req, timeout=10) as resp:
                    status_code = resp.getcode()

                print(
                    f"[HEARTBEAT] ✓ battery=POWERED ON  ip={pi_ip}  "
                    f"last_seen={now_iso}  HTTP {status_code}"
                )
            else:
                print("[HEARTBEAT] ⚠ SUPABASE_URL or SUPABASE_ANON_KEY not set — skipping")

        except urllib.error.URLError as e:
            print(f"[HEARTBEAT] Network error (non-fatal): {e.reason}")
        except Exception as e:
            print(f"[HEARTBEAT] Unexpected error (non-fatal): {e}")

        _time.sleep(HEARTBEAT_INTERVAL)


def _start_heartbeat_thread():
    """Launch the heartbeat as a daemon thread so it exits when the process does."""
    t = threading.Thread(target=_heartbeat_worker, name="evvos-heartbeat", daemon=True)
    t.start()
    print(f"[HEARTBEAT] Thread started (interval: {HEARTBEAT_INTERVAL}s, device: {DEVICE_ID})")


'''

old = "def get_status_handler():"
assert old in src, "Anchor not found (patch 1)"
src = src.replace(old, heartbeat_code + old, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2 — Include power status in GET_STATUS responses
# ─────────────────────────────────────────────────────────────────────────────
old = (
    '            "elapsed_seconds\": elapsed,\n'
    '        }'
)
new = (
    '            "elapsed_seconds": elapsed,\n'
    '            "battery":         "POWERED ON",\n'
    '        }'
)
assert old in src, "Anchor not found (patch 2)"
src = src.replace(old, new, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 3 — Start the heartbeat thread in main() just before the server loop
# ─────────────────────────────────────────────────────────────────────────────
old = (
    'if __name__ == "__main__":\n'
    '    print(f"[EVVOS] Service starting — IP: {get_pi_ip()}")\n'
    '    if setup_camera():'
)
new = (
    'if __name__ == "__main__":\n'
    '    print(f"[EVVOS] Service starting — IP: {get_pi_ip()}")\n'
    '    _start_heartbeat_thread()\n'
    '    if setup_camera():'
)
assert old in src, "Anchor not found (patch 3)"
src = src.replace(old, new, 1)

script.write_text(src, encoding="utf-8")
print("All 3 patches applied successfully.")
PATCHER_EOF

log_success "Python patcher completed"

log_section "Verifying patch"
python3 -c "
src = open('/usr/local/bin/evvos-picam-tcp.py').read()
checks = ['_heartbeat_worker', '_start_heartbeat_thread', 'HEARTBEAT_INTERVAL', 'POWERED ON']
for c in checks:
    status = '✓' if c in src else '✗ MISSING'
    print(f'  {status}  {c}')
"

log_section "Restarting evvos-picam-tcp service"
systemctl restart evvos-picam-tcp.service
sleep 2

if systemctl is-active --quiet evvos-picam-tcp.service; then
    log_success "Service restarted and running"
else
    log_error "Service failed to restart — check: journalctl -u evvos-picam-tcp -n 30"
    exit 1
fi

echo ""
echo -e "${CYAN}  Power Status Heartbeat ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Device:          Pi Zero 2 W (USB power bank, no HAT)${NC}"
echo -e "${CYAN}  Heartbeat rate:  every 60 seconds${NC}"
echo -e "${CYAN}  Supabase target: device_credentials WHERE device_id=EVVOS_0001${NC}"
echo -e "${CYAN}  Fields updated:  battery='POWERED ON', ip_address, last_seen${NC}"
echo -e "${CYAN}  Auto-offline:    pg_cron flips battery to 'POWERED OFF' after 70 s${NC}"
echo -e "${CYAN}  GET_STATUS:      battery field now returns 'POWERED ON'${NC}"
echo ""
echo -e "${YELLOW}  NOTE: Battery percentage is not available (no UPS HAT).${NC}"
echo -e "${YELLOW}        Power state is inferred from heartbeat presence only.${NC}"
echo ""
log_success "Power Status Heartbeat patch complete!"
