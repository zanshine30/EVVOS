#!/bin/bash
# ============================================================================
# EVVOS Provisioning — Patch P13: Hotspot dropout auto-reconnect
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_provision_hotspot_dropout_17.sh
#
# Safe to re-run — skips if already applied.
#
# ─────────────────────────────────────────────────────────────────────────────
# PROBLEM
#   After a successful provisioning, the run() loop calls:
#       await asyncio.sleep(3600)   # sleep 1 hour
#
#   The background _monitor_connectivity() task only checks for intentional
#   unpair requests from Supabase — it does NOT detect accidental hotspot
#   dropout (e.g. user accidentally turns off their Phone's Mobile Hotspot).
#
#   Result: the Pi is "asleep" for up to 1 hour and cannot reconnect on its own
#   unless the user reboots or presses the physical button.
#
# FIX — Two complementary parts
#
# Part A — _monitor_connectivity() gains a WiFi watchdog
#   Every 30 seconds, after provisioning is confirmed successful (credentials
#   exist), the monitor also checks whether WiFi is actually connected.
#   If connectivity is lost, it tries to reconnect using stored credentials
#   via nmcli before allowing the normal loop to take over.
#
#   Reconnect strategy (runs inside the monitor, non-blocking to heartbeat):
#     1. Wait up to 60s for the SSID to re-appear in scan results.
#        (Covers the case where the user briefly toggled the hotspot.)
#     2. If SSID is visible, call nmcli connection up <ssid>.
#     3. Wait up to 30s for an IP to be assigned.
#     4. If successful, log and resume normal heartbeat/disconnect monitoring.
#     5. If SSID never reappears within 60s, log and let the main run() loop
#        handle it on its next iteration (it will retry after 10s).
#
# Part B — run() 1-hour sleep replaced with 30-second ticks
#   The `await asyncio.sleep(3600)` that follows a successful provision is
#   replaced with a loop of 30-second sleeps that exits early as soon as
#   credentials are gone (i.e. after a disconnect/reset) so the main loop
#   re-enters provisioning without waiting a full hour.
#
#   The WiFi watchdog in Part A handles reconnects transparently while this
#   tick loop is running, so the user experience is:
#     - Hotspot goes offline → Pi notices within 30s
#     - Hotspot comes back   → Pi reconnects within ~60s (scan) + ~10s (DHCP)
#     - Hotspot stays gone   → after 60s scan timeout, main loop retries every
#                              10s (existing behaviour) until credentials are
#                              wiped after 3 consecutive full-cycle failures
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

log_section "EVVOS Provisioning — Patch P13: Hotspot dropout auto-reconnect"

cp "$SCRIPT" "${SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-provisioning")
src = script.read_text(encoding="utf-8")

MARKER = "# FIX-P13:"
if MARKER in src:
    print("P13 already applied — nothing to do.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# Part A — Replace _monitor_connectivity() with a version that includes a
#          WiFi watchdog that attempts to reconnect on hotspot dropout.
# ─────────────────────────────────────────────────────────────────────────────

old_monitor = (
    "    async def _monitor_connectivity(self) -> None:\n"
    "        \"\"\"\n"
    "        Background task that monitors device connectivity and checks for disconnect requests.\n"
    "        Sends periodic heartbeats (every 1 minute) to keep last_seen timestamp updated.\n"
    "        Also checks for unpair_requested flag in Supabase (every 10 seconds).\n"
    "        \"\"\"\n"
    "        heartbeat_counter = 0\n"
    "        logger.info(\"[MONITOR] Connectivity monitor started - will check disconnects every 10s and send heartbeat every 60s\")\n"
    "        \n"
    "        while True:\n"
    "            try:\n"
    "                await asyncio.sleep(10)  # Check every 10 seconds\n"
    "                \n"
    "                # Check for disconnect request (every 10s)\n"
    "                try:\n"
    "                    if await self._check_disconnect_requested():\n"
    "                        logger.warning(\"[MONITOR] Disconnect request detected! Initiating disconnect...\")\n"
    "                        await self._handle_disconnect()\n"
    "                        # After disconnect, the main run() loop will detect credentials are deleted\n"
    "                        # and restart hotspot provisioning\n"
    "                        break\n"
    "                except Exception as e:\n"
    "                    logger.warning(f\"[MONITOR] Error checking disconnect status: {e}\")\n"
    "                \n"
    "                # Send heartbeat every 1 minute (heartbeat_counter = 6 iterations of 10s)\n"
    "                heartbeat_counter += 1\n"
    "                if heartbeat_counter >= 6:\n"
    "                    heartbeat_counter = 0\n"
    "                    \n"
    "                    if self.credentials and self.credentials.get(\"user_id\"):\n"
    "                        user_id = self.credentials.get(\"user_id\")\n"
    "                        logger.info(f\"[MONITOR] Heartbeat cycle - Updating last_seen for User: {user_id}, Device: {self.device_id}\")\n"
    "                        \n"
    "                        try:\n"
    "                            if await self._check_internet():\n"
    "                                # Device has internet, send heartbeat\n"
    "                                result = await self._update_device_heartbeat(user_id=user_id)\n"
    "                                if result:\n"
    "                                    logger.info(f\"[MONITOR] ✓ Heartbeat sent successfully - last_seen updated\")\n"
    "                                    # Refresh ip_address on every heartbeat so the mobile app\n"
    "                                    # always has the current IP even after DHCP lease renewal.\n"
    "                                    await self._patch_ip_address_direct(user_id)\n"
    "                                else:\n"
    "                                    logger.warning(f\"[MONITOR] ✗ Heartbeat failed - last_seen NOT updated. Check if device_credentials table has matching row\")\n"
    "                            else:\n"
    "                                logger.debug(\"[MONITOR] No internet connectivity - heartbeat skipped\")\n"
    "                        except Exception as e:\n"
    "                            logger.error(f\"[MONITOR] Error sending heartbeat: {e}\")\n"
    "                    else:\n"
    "                        logger.debug(\"[MONITOR] No credentials available - skipping heartbeat\")\n"
    "                            \n"
    "            except Exception as e:\n"
    "                logger.error(f\"[MONITOR] Unexpected error in connectivity monitor loop: {e}\")\n"
    "                await asyncio.sleep(5)  # Wait before retrying to avoid rapid error loops"
)

new_monitor = (
    "    async def _reconnect_to_hotspot(self) -> bool:\n"
    "        \"\"\"\n"
    "        FIX-P13: Attempt to reconnect to the stored hotspot SSID after dropout.\n"
    "\n"
    "        Strategy:\n"
    "          1. Scan for the SSID for up to 60 seconds (5s intervals).\n"
    "          2. Once visible, run `nmcli connection up <ssid>`.\n"
    "          3. Poll for an IP for up to 30 seconds.\n"
    "          4. Return True if we get an IP, False otherwise.\n"
    "        \"\"\"\n"
    "        if not self.credentials:\n"
    "            return False\n"
    "        ssid = self.credentials.get(\"ssid\", \"\")\n"
    "        if not ssid:\n"
    "            return False\n"
    "\n"
    "        logger.warning(\"[WATCHDOG] Hotspot dropout detected for SSID '%s' — starting reconnect\", ssid)\n"
    "\n"
    "        # Step 1: Wait for SSID to reappear (up to 60 s)\n"
    "        SCAN_TIMEOUT = 60\n"
    "        SCAN_INTERVAL = 5\n"
    "        elapsed = 0\n"
    "        ssid_found = False\n"
    "        while elapsed < SCAN_TIMEOUT:\n"
    "            try:\n"
    "                subprocess.run(\n"
    "                    [\"nmcli\", \"device\", \"wifi\", \"rescan\", \"ifname\", \"wlan0\"],\n"
    "                    capture_output=True, timeout=10\n"
    "                )\n"
    "                scan_result = subprocess.run(\n"
    "                    [\"nmcli\", \"-t\", \"-f\", \"SSID\", \"device\", \"wifi\", \"list\", \"ifname\", \"wlan0\"],\n"
    "                    capture_output=True, text=True, timeout=10\n"
    "                )\n"
    "                if ssid in [s.strip() for s in scan_result.stdout.splitlines()]:\n"
    "                    logger.info(\"[WATCHDOG] ✓ SSID '%s' is visible again after %ds\", ssid, elapsed)\n"
    "                    ssid_found = True\n"
    "                    break\n"
    "                else:\n"
    "                    logger.info(\"[WATCHDOG] SSID '%s' not yet visible (%ds/%ds)\", ssid, elapsed, SCAN_TIMEOUT)\n"
    "            except Exception as scan_err:\n"
    "                logger.warning(\"[WATCHDOG] Scan error: %s\", scan_err)\n"
    "            await asyncio.sleep(SCAN_INTERVAL)\n"
    "            elapsed += SCAN_INTERVAL\n"
    "\n"
    "        if not ssid_found:\n"
    "            logger.warning(\"[WATCHDOG] SSID '%s' did not reappear within %ds — giving up this cycle\", ssid, SCAN_TIMEOUT)\n"
    "            return False\n"
    "\n"
    "        # Step 2: Bring the saved NM profile up\n"
    "        try:\n"
    "            logger.info(\"[WATCHDOG] Running: nmcli connection up '%s'\", ssid)\n"
    "            subprocess.run(\n"
    "                [\"nmcli\", \"connection\", \"up\", ssid],\n"
    "                capture_output=True, timeout=20\n"
    "            )\n"
    "        except Exception as up_err:\n"
    "            logger.warning(\"[WATCHDOG] nmcli connection up error: %s\", up_err)\n"
    "\n"
    "        # Step 3: Poll for an IP (up to 30 s)\n"
    "        for _ in range(6):  # 6 × 5 s = 30 s\n"
    "            await asyncio.sleep(5)\n"
    "            if self._check_wifi_connected():\n"
    "                logger.info(\"[WATCHDOG] ✓ Reconnected to '%s' and got an IP\", ssid)\n"
    "                return True\n"
    "\n"
    "        logger.warning(\"[WATCHDOG] Could not obtain IP after nmcli up — reconnect failed\")\n"
    "        return False\n"
    "\n"
    "    async def _monitor_connectivity(self) -> None:\n"
    "        \"\"\"\n"
    "        FIX-P13: Background task that monitors connectivity and checks for\n"
    "        disconnect requests.  Now also includes a WiFi watchdog that detects\n"
    "        hotspot dropout and attempts to reconnect automatically.\n"
    "\n"
    "        Timing:\n"
    "          Every 10s  — check Supabase for intentional unpair request\n"
    "          Every 30s  — WiFi watchdog: if credentials exist and WiFi is gone,\n"
    "                       attempt reconnect (scan up to 60s + DHCP up to 30s)\n"
    "          Every 60s  — heartbeat: update last_seen + refresh IP in Supabase\n"
    "        \"\"\"\n"
    "        heartbeat_counter = 0   # increments every 10s tick; heartbeat at 6 (60s)\n"
    "        watchdog_counter  = 0   # increments every 10s tick; watchdog  at 3 (30s)\n"
    "        _reconnecting     = False  # guard: don't stack reconnect attempts\n"
    "\n"
    "        logger.info(\n"
    "            \"[MONITOR] Connectivity monitor started — \"\n"
    "            \"disconnect check every 10s | WiFi watchdog every 30s | heartbeat every 60s\"\n"
    "        )\n"
    "\n"
    "        while True:\n"
    "            try:\n"
    "                await asyncio.sleep(10)  # base tick\n"
    "\n"
    "                # ── 1. Check for intentional unpair request (every 10s) ────────\n"
    "                try:\n"
    "                    if await self._check_disconnect_requested():\n"
    "                        logger.warning(\"[MONITOR] Disconnect request detected! Initiating disconnect...\")\n"
    "                        await self._handle_disconnect()\n"
    "                        # credentials are now deleted; main run() loop will enter\n"
    "                        # hotspot mode on its next iteration.\n"
    "                        break\n"
    "                except Exception as e:\n"
    "                    logger.warning(f\"[MONITOR] Error checking disconnect status: {e}\")\n"
    "\n"
    "                # ── 2. WiFi watchdog (every 30s) ─────────────────────────────\n"
    "                watchdog_counter += 1\n"
    "                if watchdog_counter >= 3:\n"
    "                    watchdog_counter = 0\n"
    "\n"
    "                    # Only run watchdog when we have stored credentials (i.e. we\n"
    "                    # were provisioned successfully and are not in hotspot mode).\n"
    "                    if self.credentials and not _reconnecting:\n"
    "                        if not self._check_wifi_connected():\n"
    "                            logger.warning(\n"
    "                                \"[WATCHDOG] WiFi connection lost — attempting automatic reconnect...\"\n"
    "                            )\n"
    "                            _reconnecting = True\n"
    "                            try:\n"
    "                                reconnected = await self._reconnect_to_hotspot()\n"
    "                                if reconnected:\n"
    "                                    logger.info(\"[WATCHDOG] ✓ Auto-reconnect successful — resuming normal operation\")\n"
    "                                    # Immediately send a heartbeat so Supabase reflects\n"
    "                                    # the device is back online after the dropout.\n"
    "                                    user_id = self.credentials.get(\"user_id\", \"\")\n"
    "                                    if user_id:\n"
    "                                        await self._update_device_heartbeat(user_id=user_id)\n"
    "                                        await self._patch_ip_address_direct(user_id)\n"
    "                                else:\n"
    "                                    logger.warning(\n"
    "                                        \"[WATCHDOG] Auto-reconnect failed — main loop will retry on next iteration\"\n"
    "                                    )\n"
    "                            finally:\n"
    "                                _reconnecting = False\n"
    "                        else:\n"
    "                            logger.debug(\"[WATCHDOG] WiFi OK\")\n"
    "\n"
    "                # ── 3. Heartbeat (every 60s) ──────────────────────────────────\n"
    "                heartbeat_counter += 1\n"
    "                if heartbeat_counter >= 6:\n"
    "                    heartbeat_counter = 0\n"
    "\n"
    "                    if self.credentials and self.credentials.get(\"user_id\"):\n"
    "                        user_id = self.credentials.get(\"user_id\")\n"
    "                        logger.info(\n"
    "                            f\"[MONITOR] Heartbeat cycle - Updating last_seen for \"\n"
    "                            f\"User: {user_id}, Device: {self.device_id}\"\n"
    "                        )\n"
    "                        try:\n"
    "                            if await self._check_internet():\n"
    "                                result = await self._update_device_heartbeat(user_id=user_id)\n"
    "                                if result:\n"
    "                                    logger.info(\"[MONITOR] ✓ Heartbeat sent successfully - last_seen updated\")\n"
    "                                    await self._patch_ip_address_direct(user_id)\n"
    "                                else:\n"
    "                                    logger.warning(\n"
    "                                        \"[MONITOR] ✗ Heartbeat failed - last_seen NOT updated. \"\n"
    "                                        \"Check if device_credentials table has matching row\"\n"
    "                                    )\n"
    "                            else:\n"
    "                                logger.debug(\"[MONITOR] No internet connectivity - heartbeat skipped\")\n"
    "                        except Exception as e:\n"
    "                            logger.error(f\"[MONITOR] Error sending heartbeat: {e}\")\n"
    "                    else:\n"
    "                        logger.debug(\"[MONITOR] No credentials available - skipping heartbeat\")\n"
    "\n"
    "            except Exception as e:\n"
    "                logger.error(f\"[MONITOR] Unexpected error in connectivity monitor loop: {e}\")\n"
    "                await asyncio.sleep(5)  # brief back-off to avoid rapid error loops"
)

assert old_monitor in src, (
    "P13-A anchor not found: _monitor_connectivity body not matched.\n"
    "Check: grep -n '_monitor_connectivity' /usr/local/bin/evvos-provisioning"
)
src = src.replace(old_monitor, new_monitor, 1)
print("P13-A applied: _monitor_connectivity() now has WiFi watchdog (30s) + _reconnect_to_hotspot()")

# ─────────────────────────────────────────────────────────────────────────────
# Part B — Replace the 1-hour sleep in run() with a 30-second tick loop
#          so the main loop wakes up promptly when credentials disappear.
# ─────────────────────────────────────────────────────────────────────────────
old_sleep = (
    "                if success:\n"
    "                    logger.info(\"✓ Provisioning completed successfully!\")\n"
    "                    # Sleep for an hour before trying again (maintenance check)\n"
    "                    logger.info(\"Going to sleep for 1 hour...\")\n"
    "                    await asyncio.sleep(3600)"
)
new_sleep = (
    "                if success:\n"
    "                    logger.info(\"✓ Provisioning completed successfully!\")\n"
    "                    # FIX-P13: replaced single 1-hour sleep with 30s tick loop.\n"
    "                    # This lets the main loop react quickly when credentials are\n"
    "                    # wiped (e.g. after disconnect) without waiting a full hour.\n"
    "                    # The WiFi watchdog in _monitor_connectivity() handles\n"
    "                    # hotspot dropout reconnects while this loop is ticking.\n"
    "                    logger.info(\"[RUN] Provisioning complete — entering maintenance tick loop (30s intervals)\")\n"
    "                    while self.credentials:  # exit as soon as creds are gone\n"
    "                        await asyncio.sleep(30)"
)

assert old_sleep in src, (
    "P13-B anchor not found: 1-hour sleep block not matched.\n"
    "Check: grep -n 'asyncio.sleep(3600)' /usr/local/bin/evvos-provisioning"
)
src = src.replace(old_sleep, new_sleep, 1)
print("P13-B applied: 1-hour sleep → 30s tick loop (exits when credentials are cleared)")

script.write_text(src, encoding="utf-8")
print("\nP13 complete.")
PATCHER_EOF

log_success "Python patcher completed"

# ─────────────────────────────────────────────────────────────────────────────
# Verification
# ─────────────────────────────────────────────────────────────────────────────
log_section "Verifying patch P13"
python3 << 'VERIFY_EOF'
src = open('/usr/local/bin/evvos-provisioning', encoding='utf-8').read()
checks = [
    ('# FIX-P13:',                              'P13 — patch marker present'),
    ('async def _reconnect_to_hotspot',         'P13-A — _reconnect_to_hotspot() defined'),
    ('SSID_SCAN_TIMEOUT = 60' if False else
     'SCAN_TIMEOUT = 60',                       'P13-A — 60s SSID scan timeout'),
    ('nmcli\", \"connection\", \"up\", ssid',   'P13-A — nmcli connection up call'),
    ('[WATCHDOG]',                               'P13-A — watchdog log tag'),
    ('watchdog_counter',                         'P13-A — watchdog_counter in monitor'),
    ('WiFi watchdog every 30s',                  'P13-A — 30s watchdog doc string'),
    ('_reconnecting',                            'P13-A — reconnect guard'),
    ('Auto-reconnect successful',                'P13-A — success log'),
    ('# FIX-P13: replaced single 1-hour sleep', 'P13-B — tick loop comment'),
    ('while self.credentials:',                  'P13-B — tick loop guards on credentials'),
    ('asyncio.sleep(30)',                         'P13-B — 30s tick sleep'),
]
all_ok = True
for token, label in checks:
    ok = token in src
    print(f'  {chr(10003) if ok else chr(10007)}  {label}')
    if not ok:
        all_ok = False

# Confirm the old 1-hour sleep is gone
if 'asyncio.sleep(3600)' in src:
    print(f'  {chr(10007)}  P13-B — asyncio.sleep(3600) should be REMOVED')
    all_ok = False
else:
    print(f'  {chr(10003)}  P13-B — asyncio.sleep(3600) successfully removed')

import sys; sys.exit(0 if all_ok else 1)
VERIFY_EOF

# ─────────────────────────────────────────────────────────────────────────────
# Restart service
# ─────────────────────────────────────────────────────────────────────────────
log_section "Restarting evvos-provisioning service"
systemctl daemon-reload
systemctl restart evvos-provisioning
sleep 3

if systemctl is-active --quiet evvos-provisioning; then
    log_success "Service restarted and running"
else
    log_error "Service failed to restart"
    log_error "Check logs: journalctl -u evvos-provisioning -n 30"
    exit 1
fi

echo ""
echo -e "${CYAN}  Patch P13 applied${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  A  WiFi watchdog added to _monitor_connectivity()${NC}"
echo -e "${CYAN}     Every 30s: checks if WiFi is still connected${NC}"
echo -e "${CYAN}     If dropped → scans for SSID up to 60s${NC}"
echo -e "${CYAN}     → nmcli connection up <ssid>${NC}"
echo -e "${CYAN}     → polls for IP up to 30s${NC}"
echo -e "${CYAN}     → sends heartbeat + IP patch on success${NC}"
echo -e "${CYAN}  B  1-hour sleep replaced with 30s tick loop${NC}"
echo -e "${CYAN}     Loop exits immediately when credentials are cleared${NC}"
echo -e "${CYAN}     (e.g. after intentional unpair or button reset)${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Test checklist:${NC}"
echo -e "${YELLOW}  1. Provision device normally${NC}"
echo -e "${YELLOW}  2. Turn off phone hotspot${NC}"
echo -e "${YELLOW}  3. Watch logs — within 30s you should see:${NC}"
echo -e "${YELLOW}     [WATCHDOG] WiFi connection lost — attempting automatic reconnect...${NC}"
echo -e "${YELLOW}  4. Turn hotspot back on${NC}"
echo -e "${YELLOW}  5. Within ~70s you should see:${NC}"
echo -e "${YELLOW}     [WATCHDOG] ✓ Auto-reconnect successful — resuming normal operation${NC}"
echo -e "${YELLOW}  6. Confirm heartbeats resume normally${NC}"
echo ""
echo -e "${YELLOW}  Monitor live: journalctl -u evvos-provisioning -f${NC}"
echo ""
log_success "Done!"
