#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Battery Heartbeat Patch
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_battery.sh
#
# What this does:
#   Patches /usr/local/bin/evvos-picam-tcp.py to:
#     1. Add get_battery_level() — reads the Pi UPS HAT or battery pack via
#        /sys/class/power_supply. Falls back gracefully if no HAT is present.
#     2. Add a background heartbeat thread that POSTs battery %, ip_address,
#        and last_seen to the device_credentials Supabase table every 60 s.
#     3. Includes battery in GET_STATUS responses so the mobile app always
#        gets fresh data on direct poll too.
#
# Battery source priority (first match wins):
#   1. /sys/class/power_supply/axp20x-battery   ← X-Power / PiSugar HAT
#   2. /sys/class/power_supply/battery          ← generic UPS HAT
#   3. /sys/class/power_supply/BAT0             ← some USB UPS dongles
#   4. vcgencmd measure_temp CPU proxy           ← Pi has no battery (returns -1)
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

log_section "Patching Pi Camera Service — Battery Heartbeat"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD ─────────────────────────────────────────────────────────────────────
if "get_battery_level" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 1 — Add battery helper + heartbeat thread before get_status_handler()
# ─────────────────────────────────────────────────────────────────────────────
battery_code = '''
# ── Battery & Heartbeat ────────────────────────────────────────────────────────

# Known power_supply paths for common Pi UPS / battery HATs (checked in order)
_BATTERY_PATHS = [
    "/sys/class/power_supply/axp20x-battery",   # X-Power AXP / PiSugar 2 Pro
    "/sys/class/power_supply/battery",           # generic UPS HAT
    "/sys/class/power_supply/BAT0",              # USB UPS dongles
    "/sys/class/power_supply/BAT1",              # some UPS HATs
]

# Supabase device identifier — must match the value stored in device_credentials
DEVICE_ID = "EVVOS_0001"

# How often (seconds) the heartbeat thread posts to Supabase
HEARTBEAT_INTERVAL = 60


def get_battery_level() -> int:
    """
    Read battery percentage from the first recognised power_supply interface.

    Returns:
        0–100  — battery percentage as an integer
        -1     — no battery hardware detected (Pi running on mains / no HAT)

    The function is intentionally non-fatal: any read error returns -1 so
    the heartbeat thread never crashes due to a missing HAT or kernel path.
    """
    for base in _BATTERY_PATHS:
        cap_file = Path(base) / "capacity"
        if cap_file.exists():
            try:
                val = int(cap_file.read_text().strip())
                # Clamp to 0-100 in case the driver reports out-of-range values
                return max(0, min(100, val))
            except (ValueError, OSError):
                continue

    # No HAT found — return sentinel so the UI knows battery is not available
    return -1


def _heartbeat_worker():
    """
    Background thread: push battery %, ip_address, and last_seen to Supabase
    every HEARTBEAT_INTERVAL seconds via the REST PATCH endpoint.

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
                battery  = get_battery_level()
                pi_ip    = get_pi_ip()
                now_iso  = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

                payload = {
                    "last_seen":    now_iso,
                    "ip_address":   pi_ip,
                }
                # Only include battery when hardware is present (avoid overwriting
                # a valid reading with -1 if the HAT temporarily fails)
                if battery >= 0:
                    payload["battery"] = battery

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

                battery_str = f"{battery}%" if battery >= 0 else "N/A (no HAT)"
                print(
                    f"[HEARTBEAT] ✓ battery={battery_str}  ip={pi_ip}  "
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
src = src.replace(old, battery_code + old, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2 — Include battery in GET_STATUS response
# ─────────────────────────────────────────────────────────────────────────────
old = (
    '            "elapsed_seconds": elapsed,\n'
    '        }'
)
new = (
    '            "elapsed_seconds": elapsed,\n'
    '            "battery":         get_battery_level(),\n'
    '        }'
)
assert old in src, "Anchor not found (patch 2)"
src = src.replace(old, new, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 3 — Start the heartbeat thread in main() just before the server loop
# ─────────────────────────────────────────────────────────────────────────────
old = 'if __name__ == "__main__":\n    print(f"[EVVOS] Service starting'
assert old in src, "Anchor not found (patch 3)"
idx = src.index(old)
src = src[:idx] + src[idx:].replace(
    'if __name__ == "__main__":',
    'if __name__ == "__main__":\n    _start_heartbeat_thread()',
    1
)

script.write_text(src, encoding="utf-8")
print("All 3 patches applied successfully.")
PATCHER_EOF

log_success "Python patcher completed"

log_section "Verifying patch"
python3 -c "
src = open('/usr/local/bin/evvos-picam-tcp.py').read()
checks = ['get_battery_level', '_heartbeat_worker', '_start_heartbeat_thread', 'HEARTBEAT_INTERVAL']
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
echo -e "${CYAN}  Battery Heartbeat ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Battery source:   /sys/class/power_supply/* (UPS HAT)${NC}"
echo -e "${CYAN}  Heartbeat rate:   every 60 seconds${NC}"
echo -e "${CYAN}  Supabase target:  device_credentials WHERE device_id=EVVOS_0001${NC}"
echo -e "${CYAN}  Fields updated:   battery, ip_address, last_seen${NC}"
echo -e "${CYAN}  GET_STATUS:       now includes 'battery' field${NC}"
echo -e "${CYAN}  No HAT fallback:  battery=-1 (reported as 'N/A' in mobile app)${NC}"
echo ""
echo -e "${YELLOW}  NOTE: If your Pi has no UPS HAT, battery will always show N/A.${NC}"
echo -e "${YELLOW}        Compatible HATs: PiSugar 2/3, X-Power, Waveshare UPS.${NC}"
echo ""
log_success "Battery Heartbeat patch complete!"
