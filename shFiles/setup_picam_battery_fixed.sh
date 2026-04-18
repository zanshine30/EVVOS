#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Battery Heartbeat Fix
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_battery_fix.sh
#
# What this does:
#   The original setup_picam_battery.sh installed a heartbeat that calls
#   get_battery_level(). With no UPS HAT present it returns -1, logs
#   "battery=N/A", and omits the battery field from the Supabase PATCH
#   entirely — so the column is never set to 'POWERED ON'.
#
#   This script patches the live evvos-picam-tcp.py to:
#     1. Replace the old numeric battery payload with battery="POWERED ON"
#     2. Fix the GET_STATUS handler to return "POWERED ON" as a string
#     3. Update the heartbeat log line to match
#
#   get_battery_level() and _BATTERY_PATHS are left in place (harmless).
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

log_section "Fixing Battery Heartbeat — replacing numeric value with 'POWERED ON'"

cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD ─────────────────────────────────────────────────────────────────────
if '"POWERED ON"' in src:
    print("Already patched to POWERED ON — skipping.")
    raise SystemExit(0)

if "_heartbeat_worker" not in src:
    print("ERROR: _heartbeat_worker not found. Run setup_picam_battery.sh first.")
    raise SystemExit(1)

patched = 0

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 1 — Replace the old battery-reading + conditional payload block
#           inside _heartbeat_worker() with a fixed "POWERED ON" payload.
#
# Old code (injected by setup_picam_battery.sh):
#
#                battery  = get_battery_level()
#                pi_ip    = get_pi_ip()
#                now_iso  = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
#
#                payload = {
#                    "last_seen":    now_iso,
#                    "ip_address":   pi_ip,
#                }
#                # Only include battery when hardware is present (avoid overwriting
#                # a valid reading with -1 if the HAT temporarily fails)
#                if battery >= 0:
#                    payload["battery"] = battery
# ─────────────────────────────────────────────────────────────────────────────
old_payload = (
    '                battery  = get_battery_level()\n'
    '                pi_ip    = get_pi_ip()\n'
    '                now_iso  = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")\n'
    '\n'
    '                payload = {\n'
    '                    "last_seen":    now_iso,\n'
    '                    "ip_address":   pi_ip,\n'
    '                }\n'
    '                # Only include battery when hardware is present (avoid overwriting\n'
    '                # a valid reading with -1 if the HAT temporarily fails)\n'
    '                if battery >= 0:\n'
    '                    payload["battery"] = battery'
)
new_payload = (
    '                pi_ip    = get_pi_ip()\n'
    '                now_iso  = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")\n'
    '\n'
    '                payload = {\n'
    '                    "battery":    "POWERED ON",\n'
    '                    "last_seen":  now_iso,\n'
    '                    "ip_address": pi_ip,\n'
    '                }'
)
if old_payload in src:
    src = src.replace(old_payload, new_payload, 1)
    print("Patch 1 applied: heartbeat payload now sends battery='POWERED ON'")
    patched += 1
else:
    print("WARNING: Patch 1 anchor not found — payload block may differ slightly.")
    print("         Trying fallback anchor...")

    # Fallback: narrower anchor — just the conditional block
    old_fallback = (
        '                if battery >= 0:\n'
        '                    payload["battery"] = battery'
    )
    new_fallback = '                payload["battery"] = "POWERED ON"'
    if old_fallback in src:
        # Also remove the get_battery_level() call line
        src = src.replace('                battery  = get_battery_level()\n', '', 1)
        src = src.replace(old_fallback, new_fallback, 1)
        print("Patch 1 applied via fallback anchor.")
        patched += 1
    else:
        print("ERROR: Could not find battery payload block. Manual edit required.")
        raise SystemExit(1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2 — Fix the heartbeat log line
#
# Old:  battery_str = f"{battery}%" if battery >= 0 else "N/A (no HAT)"
#       print(f"[HEARTBEAT] ✓ battery={battery_str}  ip={pi_ip}  ...")
#
# New:  print(f"[HEARTBEAT] ✓ battery=POWERED ON  ip={pi_ip}  ...")
# ─────────────────────────────────────────────────────────────────────────────
old_log = (
    '                battery_str = f"{battery}%" if battery >= 0 else "N/A (no HAT)"\n'
    '                print(\n'
    '                    f"[HEARTBEAT] ✓ battery={battery_str}  ip={pi_ip}  "\n'
    '                    f"last_seen={now_iso}  HTTP {status_code}"\n'
    '                )'
)
new_log = (
    '                print(\n'
    '                    f"[HEARTBEAT] ✓ battery=POWERED ON  ip={pi_ip}  "\n'
    '                    f"last_seen={now_iso}  HTTP {status_code}"\n'
    '                )'
)
if old_log in src:
    src = src.replace(old_log, new_log, 1)
    print("Patch 2 applied: log line updated")
    patched += 1
else:
    # Softer fallback — just remove the battery_str line if it exists
    old_bstr = '                battery_str = f"{battery}%" if battery >= 0 else "N/A (no HAT)"\n'
    if old_bstr in src:
        src = src.replace(old_bstr, '', 1)
        print("Patch 2 applied via fallback: battery_str line removed")
        patched += 1
    else:
        print("WARNING: Patch 2 log line not found — log will still show old format (non-fatal)")

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 3 — Fix GET_STATUS response: replace get_battery_level() with string
#
# Old:  "battery":         get_battery_level(),
# New:  "battery":         "POWERED ON",
# ─────────────────────────────────────────────────────────────────────────────
old_status = '            "battery":         get_battery_level(),\n'
new_status = '            "battery":         "POWERED ON",\n'
if old_status in src:
    src = src.replace(old_status, new_status, 1)
    print("Patch 3 applied: GET_STATUS battery field updated")
    patched += 1
else:
    print("WARNING: Patch 3 GET_STATUS anchor not found (non-fatal if GET_STATUS had no battery)")

script.write_text(src, encoding="utf-8")
print(f"\nDone — {patched} patch(es) applied.")
PATCHER_EOF

log_success "Python patcher completed"

log_section "Verifying patch"
python3 -c "
src = open('/usr/local/bin/evvos-picam-tcp.py').read()
checks = [
    ('battery=\"POWERED ON\" in payload',  '\"POWERED ON\"'     in src),
    ('old get_battery_level() removed from payload',
        'battery  = get_battery_level()' not in src),
    ('old conditional (battery >= 0) gone',
        'if battery >= 0:' not in src),
]
ok = True
for label, result in checks:
    print(f'  {chr(10003) if result else chr(10007)+\" FAIL\"}  {label}')
    if not result: ok = False
import sys; sys.exit(0 if ok else 1)
"

log_section "Syntax check"
python3 -m py_compile "$CAMERA_SCRIPT" && log_success "Syntax OK" || {
    log_error "Syntax error — restoring backup..."
    LATEST=$(ls -t "${CAMERA_SCRIPT}".bak.* 2>/dev/null | head -1)
    [ -n "$LATEST" ] && cp "$LATEST" "$CAMERA_SCRIPT" && log_info "Restored: $LATEST"
    exit 1
}

log_section "Restarting evvos-picam-tcp service"
systemctl restart evvos-picam-tcp.service
sleep 2

if systemctl is-active --quiet evvos-picam-tcp.service; then
    log_success "Service restarted and running"
    echo ""
    echo -e "${CYAN}  Watch the heartbeat — should now show:${NC}"
    echo -e "${CYAN}  [HEARTBEAT] ✓ battery=POWERED ON  ip=...${NC}"
    echo ""
    echo -e "${YELLOW}  Run: sudo journalctl -u evvos-picam-tcp -f${NC}"
else
    log_error "Service failed — check: journalctl -u evvos-picam-tcp -n 30"
    exit 1
fi

log_success "Battery heartbeat fix complete!"
