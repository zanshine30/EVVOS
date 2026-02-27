#!/bin/bash
# ============================================================================
# EVVOS Provisioning — Hotspot-after-disconnect Fix
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_hotspot_fix.sh
#
# Problem:
#   After disconnecting a device from the mobile app, the Pi restarts its
#   provisioning service but never broadcasts the EVVOS_0001 hotspot. The
#   journalctl shows "Waiting for web form submission" meaning the service
#   thinks the hotspot is up, but it isn't visible to any device.
#
# Root causes (two independent bugs):
#
#   1. TIMING REGRESSION (from evvos_provisioning_timing.sh):
#      asyncio.sleep after _setup_hotspot_interface() was cut from 3s → 1s.
#      The nl80211 kernel driver needs ~2s to fully release wlan0's socket
#      after nmcli disconnect + killall hostapd. At 1s, hostapd starts before
#      the socket is free, fails silently after the 2s proc.poll() check
#      window, and the service incorrectly proceeds as if the AP is up.
#      Fix: restore to asyncio.sleep(2) for this specific sleep only.
#
#   2. DIRTY STATE ON SERVICE RESTART:
#      _handle_disconnect() calls `systemctl restart evvos-provisioning`
#      from within the running service. systemd kills the process
#      mid-execution, leaving hostapd/dnsmasq processes alive and wlan0
#      in an indeterminate state. The new process then tries to start
#      hostapd on a still-occupied interface and fails.
#      Fix: explicitly kill hostapd, dnsmasq, and flush wlan0 BEFORE
#      issuing the systemctl restart.
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

SCRIPT="/usr/local/bin/evvos-provisioning"

if [ ! -f "$SCRIPT" ]; then
    log_error "Provisioning script not found: $SCRIPT"
    exit 1
fi

log_section "EVVOS Provisioning — Hotspot-after-disconnect Fix"

cp "$SCRIPT" "${SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
import re
from pathlib import Path

script = Path("/usr/local/bin/evvos-provisioning")
src = script.read_text(encoding="utf-8")

p1_done = "# FIX-P1: restored sleep(2) for nl80211 socket release" in src
p2_done = "# FIX-P2: full cleanup before restart" in src

if p1_done and p2_done:
    print("All patches already applied — skipping.")
    raise SystemExit(0)

print(f"Patch status: P1={'done' if p1_done else 'needed'}  P2={'done' if p2_done else 'needed'}")

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 1 — Restore asyncio.sleep(2) after _setup_hotspot_interface()
#
# The timing patch cut this from 3s → 1s. The nl80211 kernel driver needs
# ~2s to release wlan0's socket after nmcli disconnect + killall hostapd.
# At 1s, hostapd races for the interface, fails after the proc.poll() window,
# and the service incorrectly reports the hotspot as started.
# ─────────────────────────────────────────────────────────────────────────────
if not p1_done:
    old = (
        "            if not self._setup_hotspot_interface():\n"
        "                return False\n"
        "            \n"
        "            await asyncio.sleep(1)\n"
        "            \n"
        "            if not self._start_hostapd():"
    )
    new = (
        "            if not self._setup_hotspot_interface():\n"
        "                return False\n"
        "            \n"
        "            # FIX-P1: restored sleep(2) for nl80211 socket release\n"
        "            # nl80211 needs ~2s to free wlan0 after nmcli disconnect.\n"
        "            # At 1s hostapd races the interface and fails silently.\n"
        "            await asyncio.sleep(2)\n"
        "            \n"
        "            if not self._start_hostapd():"
    )
    assert old in src, f"Patch 1 anchor not found.\nContext: {src[src.find('_setup_hotspot_interface'):src.find('_setup_hotspot_interface')+300]!r}"
    src = src.replace(old, new, 1)
    print("Patch 1 applied: asyncio.sleep(1) → sleep(2) after _setup_hotspot_interface()")

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2 — Clean up hostapd/dnsmasq/wlan0 before systemctl restart
#
# systemctl restart kills the process immediately, leaving hostapd and
# dnsmasq alive and wlan0 in a dirty state. The new process then can't
# start hostapd because the interface/socket is still occupied.
# Fix: explicitly kill all hotspot processes and flush wlan0 first, then
# give the kernel 1s to settle before handing off to the new process.
# ─────────────────────────────────────────────────────────────────────────────
if not p2_done:
    old = (
        "            # Step 6: Restart the provisioning service\n"
        "            logger.warning(\"[DISCONNECT] Restarting provisioning service...\")\n"
        "            await asyncio.sleep(1)  # Brief delay to ensure cleanup is complete\n"
        "            try:\n"
        "                subprocess.run([\"systemctl\", \"restart\", \"evvos-provisioning\"], timeout=10, check=True)\n"
        "                logger.warning(\"[DISCONNECT] ✓ Service restart command sent successfully\")\n"
        "            except Exception as e:\n"
        "                logger.error(f\"[DISCONNECT] Failed to restart service: {e}\")\n"
        "                logger.warning(\"[DISCONNECT] Attempting alternative restart method...\")\n"
        "                logger.warning(\"[DISCONNECT] The script will continue and attempt to restart manually...\")"
    )
    new = (
        "            # Step 6: Full cleanup before restart so the new process\n"
        "            # inherits a clean wlan0 with no orphaned hostapd/dnsmasq.\n"
        "            # FIX-P2: full cleanup before restart\n"
        "            logger.warning(\"[DISCONNECT] Cleaning up hotspot processes before restart...\")\n"
        "            subprocess.run([\"killall\", \"-9\", \"hostapd\"],  capture_output=True)\n"
        "            subprocess.run([\"killall\", \"-9\", \"dnsmasq\"],  capture_output=True)\n"
        "            subprocess.run([\"killall\", \"-9\", \"wpa_supplicant\"], capture_output=True)\n"
        "            subprocess.run([\"systemctl\", \"stop\", \"hostapd\"],  capture_output=True, timeout=5)\n"
        "            subprocess.run([\"systemctl\", \"stop\", \"dnsmasq\"],  capture_output=True, timeout=5)\n"
        "            subprocess.run([\"ip\", \"addr\", \"flush\", \"dev\", \"wlan0\"], capture_output=True)\n"
        "            subprocess.run([\"ip\",  \"link\", \"set\", \"wlan0\", \"down\"],  capture_output=True)\n"
        "            time.sleep(1)  # Let the kernel settle before new process takes over\n"
        "            subprocess.run([\"ip\",  \"link\", \"set\", \"wlan0\", \"up\"],    capture_output=True)\n"
        "            logger.warning(\"[DISCONNECT] ✓ Interface reset. Restarting provisioning service...\")\n"
        "            try:\n"
        "                subprocess.run([\"systemctl\", \"restart\", \"evvos-provisioning\"], timeout=10, check=True)\n"
        "                logger.warning(\"[DISCONNECT] ✓ Service restart command sent successfully\")\n"
        "            except Exception as e:\n"
        "                logger.error(f\"[DISCONNECT] Failed to restart service: {e}\")\n"
        "                logger.warning(\"[DISCONNECT] Attempting alternative restart method...\")\n"
        "                logger.warning(\"[DISCONNECT] The script will continue and attempt to restart manually...\")"
    )
    assert old in src, f"Patch 2 anchor not found.\nContext: {src[src.find('Step 6'):src.find('Step 6')+400]!r}"
    src = src.replace(old, new, 1)
    print("Patch 2 applied: full hostapd/dnsmasq/wlan0 cleanup before service restart")

script.write_text(src, encoding="utf-8")
print("Done.")
PATCHER_EOF

log_success "Python patcher completed"

log_section "Verifying patches"
python3 -c "
src = open('/usr/local/bin/evvos-provisioning').read()
checks = [
    ('FIX-P1: restored sleep(2) for nl80211 socket release', 'P1 — asyncio.sleep(2) after interface setup'),
    ('FIX-P2: full cleanup before restart',                  'P2 — hostapd/dnsmasq cleanup before restart'),
    ('killall\", \"-9\", \"hostapd',                         'P2 — killall hostapd'),
    ('killall\", \"-9\", \"dnsmasq',                         'P2 — killall dnsmasq'),
    ('ip\",  \"link\", \"set\", \"wlan0\", \"down',           'P2 — wlan0 down before restart'),
]
all_ok = True
for token, label in checks:
    ok = token in src
    print(f'  {chr(10003) if ok else chr(10007)}  {label}')
    if not ok:
        all_ok = False
import sys; sys.exit(0 if all_ok else 1)
"

log_section "Restarting evvos-provisioning service"
systemctl daemon-reload
systemctl restart evvos-provisioning
sleep 2

if systemctl is-active --quiet evvos-provisioning; then
    log_success "Service restarted and running"
else
    log_error "Service failed to restart"
    log_error "Check logs: journalctl -u evvos-provisioning -n 30"
    exit 1
fi

echo ""
echo -e "${CYAN}  Hotspot-after-disconnect fix applied${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  P1: asyncio.sleep after interface setup: 1s → 2s${NC}"
echo -e "${CYAN}      (nl80211 needs ~2s to release wlan0 socket)${NC}"
echo -e "${CYAN}  P2: Full cleanup before systemctl restart:${NC}"
echo -e "${CYAN}      killall hostapd, dnsmasq, wpa_supplicant${NC}"
echo -e "${CYAN}      systemctl stop hostapd, dnsmasq${NC}"
echo -e "${CYAN}      ip addr flush + link down/up on wlan0${NC}"
echo -e "${CYAN}      1s settle time before new process takes over${NC}"
echo ""
echo -e "${YELLOW}  To test: disconnect device from mobile app, wait 10s,${NC}"
echo -e "${YELLOW}  then scan for EVVOS_0001 WiFi network.${NC}"
echo ""
log_success "Fix complete!"
