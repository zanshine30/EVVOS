#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Battery Heartbeat Patch
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_battery.sh
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
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
import re
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── Per-patch guards ──────────────────────────────────────────────────────────
p1_done = "get_battery_level" in src
p2_done = "get_battery_level()" in src and '"battery":' in src
p3_done = "_start_heartbeat_thread" in src

if p1_done and p2_done and p3_done:
    print("All patches already applied — skipping.")
    raise SystemExit(0)

print(f"Patch status: P1={'done' if p1_done else 'needed'}  P2={'done' if p2_done else 'needed'}  P3={'done' if p3_done else 'needed'}")

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 1 — Insert battery helper + heartbeat thread before get_status_handler
# ─────────────────────────────────────────────────────────────────────────────
battery_code = '''
# ── Battery & Heartbeat ───────────────────────────────────────────────────────

_BATTERY_PATHS = [
    "/sys/class/power_supply/axp20x-battery",
    "/sys/class/power_supply/battery",
    "/sys/class/power_supply/BAT0",
    "/sys/class/power_supply/BAT1",
]

DEVICE_ID = "EVVOS_0001"
HEARTBEAT_INTERVAL = 60


def get_battery_level() -> int:
    """
    Read battery percentage from the first recognised power_supply interface.
    Returns 0-100, or -1 if no battery hardware is detected.
    """
    for base in _BATTERY_PATHS:
        cap_file = Path(base) / "capacity"
        if cap_file.exists():
            try:
                val = int(cap_file.read_text().strip())
                return max(0, min(100, val))
            except (ValueError, OSError):
                continue
    return -1


def _heartbeat_worker():
    """
    Background daemon: push battery, ip_address, last_seen to Supabase
    every HEARTBEAT_INTERVAL seconds. Never raises — errors are logged only.
    """
    import time as _time
    import json as _json
    import urllib.request
    import urllib.error

    _time.sleep(5)

    while True:
        try:
            url  = os.environ.get("SUPABASE_URL", "").rstrip("/")
            anon = os.environ.get("SUPABASE_ANON_KEY", "")

            if url and anon:
                battery = get_battery_level()
                pi_ip   = get_pi_ip()
                now_iso = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

                payload = {"last_seen": now_iso, "ip_address": pi_ip}
                if battery >= 0:
                    payload["battery"] = battery

                body     = _json.dumps(payload).encode("utf-8")
                endpoint = f"{url}/rest/v1/device_credentials?device_id=eq.{DEVICE_ID}"
                req = urllib.request.Request(
                    endpoint, data=body, method="PATCH",
                    headers={
                        "Content-Type":  "application/json",
                        "apikey":        anon,
                        "Authorization": f"Bearer {anon}",
                        "Prefer":        "return=minimal",
                    },
                )
                with urllib.request.urlopen(req, timeout=10) as resp:
                    code = resp.getcode()

                batt_str = f"{battery}%" if battery >= 0 else "N/A"
                print(f"[HEARTBEAT] battery={batt_str}  ip={pi_ip}  HTTP {code}")
            else:
                print("[HEARTBEAT] SUPABASE_URL or SUPABASE_ANON_KEY not set — skipping")

        except urllib.error.URLError as e:
            print(f"[HEARTBEAT] Network error (non-fatal): {e.reason}")
        except Exception as e:
            print(f"[HEARTBEAT] Error (non-fatal): {e}")

        _time.sleep(HEARTBEAT_INTERVAL)


def _start_heartbeat_thread():
    t = threading.Thread(target=_heartbeat_worker, name="evvos-heartbeat", daemon=True)
    t.start()
    print(f"[HEARTBEAT] Started (interval={HEARTBEAT_INTERVAL}s, device={DEVICE_ID})")


'''

if not p1_done:
    anchor = "def get_status_handler():"
    assert anchor in src, "Anchor not found (patch 1): def get_status_handler():"
    src = src.replace(anchor, battery_code + anchor, 1)
    print("Patch 1 applied.")
else:
    print("Patch 1 already present — skipping.")

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2 — Add "battery" field to get_status_handler's return dict
#
# Strategy: find the closing } of the return dict inside get_status_handler
# by locating the first line that is ONLY whitespace + "}" after the function
# definition. Insert the battery line just before it.
# This is robust to any number of fields already in the dict.
# ─────────────────────────────────────────────────────────────────────────────
if not p2_done:
    func_start = src.find("def get_status_handler():")
    assert func_start != -1, "get_status_handler not found"

    # Work on just the function body (1200 chars covers any realistic variant)
    window_end = func_start + 1200
    window = src[func_start:window_end]

    # Find the closing brace of the return dict.
    # It's a line containing only whitespace + "}" with no trailing comma.
    # We match it as: newline, spaces, "}", newline (not "},")
    m = re.search(r'\n( +)\}\n', window)
    assert m, "Patch 2: could not find closing brace of return dict in get_status_handler"

    indent    = m.group(1)          # the spaces before }
    close_str = m.group(0)          # "\n        }\n"
    new_close = f'\n{indent}"battery":         get_battery_level(),\n{indent}}}\n'

    new_window = window.replace(close_str, new_close, 1)
    src = src[:func_start] + new_window + src[window_end:]
    print("Patch 2 applied.")
else:
    print("Patch 2 already present — skipping.")

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 3 — Call _start_heartbeat_thread() in __main__
# ─────────────────────────────────────────────────────────────────────────────
if not p3_done:
    anchor = 'if __name__ == "__main__":'
    assert anchor in src, "Anchor not found (patch 3): if __name__ == '__main__':"
    src = src.replace(
        anchor,
        'if __name__ == "__main__":\n    _start_heartbeat_thread()',
        1
    )
    print("Patch 3 applied.")
else:
    print("Patch 3 already present — skipping.")

script.write_text(src, encoding="utf-8")
print("Done.")
PATCHER_EOF

log_success "Python patcher completed"

log_section "Verifying patches"
python3 -c "
src = open('/usr/local/bin/evvos-picam-tcp.py').read()
checks = [
    ('get_battery_level',       'Battery reader function'),
    ('_heartbeat_worker',       'Heartbeat thread worker'),
    ('_start_heartbeat_thread', 'Heartbeat thread launcher'),
    ('HEARTBEAT_INTERVAL',      'Heartbeat interval constant'),
]
all_ok = True
for token, label in checks:
    ok = token in src
    print(f'  {chr(10003) if ok else chr(10007)}  {label}')
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
    log_error "Service failed to restart"
    log_error "Check logs: journalctl -u evvos-picam-tcp -n 30"
    exit 1
fi

echo ""
echo -e "${CYAN}  Battery Heartbeat ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Heartbeat rate:  every 60 seconds${NC}"
echo -e "${CYAN}  Supabase target: device_credentials WHERE device_id=EVVOS_0001${NC}"
echo -e "${CYAN}  Fields updated:  battery, ip_address, last_seen${NC}"
echo -e "${CYAN}  GET_STATUS:      now includes battery field${NC}"
echo -e "${CYAN}  No HAT fallback: battery=-1 shown as N/A in mobile app${NC}"
echo ""
echo -e "${YELLOW}  Compatible HATs: PiSugar 2/3, X-Power AXP, Waveshare UPS${NC}"
echo ""
log_success "Battery Heartbeat patch complete!"
