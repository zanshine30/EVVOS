#!/bin/bash
# ============================================================================
# EVVOS Provisioning — All-in-One Fix
#
# Run on the Raspberry Pi as root:
#   sudo bash evvos_fix_all.sh
#
# Applies all 4 patches in one shot. Safe to re-run — each patch checks
# its own marker and skips itself if already applied.
#
# ─────────────────────────────────────────────────────────────────────────────
# P1 — TIMING REGRESSION (nl80211 socket release)
#      asyncio.sleep after _setup_hotspot_interface() was 1s — too short.
#      The nl80211 driver needs ~2s to release wlan0's socket after
#      nmcli disconnect + killall hostapd. At 1s, hostapd races the
#      interface, fails silently, and the service incorrectly reports
#      the hotspot as up.
#      Fix: restore asyncio.sleep(2) for this specific sleep.
#
# P2 — DIRTY STATE ON SERVICE RESTART
#      _handle_disconnect() calls `systemctl restart evvos-provisioning`
#      from within the running service. systemd kills the process
#      mid-execution, leaving hostapd/dnsmasq alive and wlan0 dirty.
#      The new process then can't start hostapd on the occupied interface.
#      Fix: explicitly kill hostapd, dnsmasq, flush wlan0 BEFORE restart.
#
# P3 — PI BOOTS BEFORE HOTSPOT IS BROADCASTING
#      When the Pi starts first, nmcli connection up fails immediately
#      because the SSID isn't in scan results yet. The Pi retries 5×,
#      burns failure counts, and never reconnects even when the hotspot
#      appears later.
#      Fix: scan for the SSID every 5s (up to 60s) before attempting
#      any connection. Reset fail counter when SSID becomes visible
#      (those misses were hotspot-offline, not bad credentials).
#
# P4 — RETRY TIMING TOO SLOW / CREDENTIAL WIPE TOO LATE
#      5 attempts × 45s = ~225s (~4 min) before declaring failure.
#      10 failure cycles before wiping credentials = ~37 min of grinding.
#      Fix: 2 attempts × 20s = ~40s max. Wipe credentials after 3
#      consecutive full-cycle failures (~3 min total).
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

log_section "EVVOS Provisioning — All-in-One Fix (P1 + P2 + P3 + P4)"

cp "$SCRIPT" "${SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

# ─────────────────────────────────────────────────────────────────────────────
# Single Python patcher — applies all 4 patches in order
# ─────────────────────────────────────────────────────────────────────────────
python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-provisioning")
src = script.read_text(encoding="utf-8")

p1_done = "# FIX-P1: restored sleep(2) for nl80211 socket release" in src
p2_done = "# FIX-P2: full cleanup before restart" in src
p3_done = "# FIX-P3: wait for SSID to appear before connecting" in src
p4_done = "# FIX-P4: shortened retry timing" in src

print(f"Patch status: P1={'done' if p1_done else 'needed'}  P2={'done' if p2_done else 'needed'}  P3={'done' if p3_done else 'needed'}  P4={'done' if p4_done else 'needed'}")

if p1_done and p2_done and p3_done and p4_done:
    print("All patches already applied — nothing to do.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 1 — Restore asyncio.sleep(2) after _setup_hotspot_interface()
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
    assert old in src, f"P1 anchor not found.\nContext: {src[src.find('_setup_hotspot_interface'):src.find('_setup_hotspot_interface')+300]!r}"
    src = src.replace(old, new, 1)
    print("P1 applied: asyncio.sleep(1) → sleep(2) after _setup_hotspot_interface()")

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2 — Full hostapd/dnsmasq/wlan0 cleanup before systemctl restart
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
    assert old in src, f"P2 anchor not found.\nContext: {src[src.find('Step 6'):src.find('Step 6')+400]!r}"
    src = src.replace(old, new, 1)
    print("P2 applied: full hostapd/dnsmasq/wlan0 cleanup before service restart")

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 3 — SSID presence scan loop before attempting _connect_to_wifi()
# ─────────────────────────────────────────────────────────────────────────────
if not p3_done:
    old = (
        "            if self._check_wifi_connected():\n"
        "                logger.info(\"✓ WiFi already connected (NM auto-connected on boot)\")\n"
        "                connection_established = True\n"
        "            else:\n"
        "                # Try to connect up to 5 times\n"
        "                connection_established = False\n"
        "                for connect_attempt in range(1, 6):\n"
        "                    logger.info(f\"WiFi connection attempt {connect_attempt}/5...\")\n"
        "                    if await self._connect_to_wifi(ssid, password):"
    )
    new = (
        "            if self._check_wifi_connected():\n"
        "                logger.info(\"✓ WiFi already connected (NM auto-connected on boot)\")\n"
        "                connection_established = True\n"
        "            else:\n"
        "                # FIX-P3: wait for SSID to appear before connecting\n"
        "                # If the Pi boots before the user's hotspot is broadcasting,\n"
        "                # nmcli connection up fails immediately. Scan for the SSID\n"
        "                # first — up to 60s — so the fail counter never increments\n"
        "                # just because the hotspot was slow to start.\n"
        "                SSID_SCAN_TIMEOUT_SECONDS = 60   # 1 minute\n"
        "                SSID_SCAN_INTERVAL = 5           # check every 5 seconds\n"
        "                ssid_found = False\n"
        "                scan_elapsed = 0\n"
        "                logger.info(f\"[SCAN] Waiting for SSID '{ssid}' to appear (up to {SSID_SCAN_TIMEOUT_SECONDS}s)...\")\n"
        "                while scan_elapsed < SSID_SCAN_TIMEOUT_SECONDS:\n"
        "                    try:\n"
        "                        subprocess.run(\n"
        "                            [\"nmcli\", \"device\", \"wifi\", \"rescan\", \"ifname\", \"wlan0\"],\n"
        "                            capture_output=True, timeout=10\n"
        "                        )\n"
        "                        scan_result = subprocess.run(\n"
        "                            [\"nmcli\", \"-t\", \"-f\", \"SSID\", \"device\", \"wifi\", \"list\", \"ifname\", \"wlan0\"],\n"
        "                            capture_output=True, text=True, timeout=10\n"
        "                        )\n"
        "                        visible_ssids = [line.strip() for line in scan_result.stdout.splitlines()]\n"
        "                        if ssid in visible_ssids:\n"
        "                            logger.info(f\"[SCAN] ✓ SSID '{ssid}' is now visible after {scan_elapsed}s — proceeding to connect\")\n"
        "                            ssid_found = True\n"
        "                            # Reset fail counter — previous misses were hotspot-offline, not bad creds\n"
        "                            fail_counter_file = \"/etc/evvos/.wifi_fail_count\"\n"
        "                            try:\n"
        "                                if os.path.exists(fail_counter_file):\n"
        "                                    os.remove(fail_counter_file)\n"
        "                                    logger.info(\"[SCAN] Fail counter reset (hotspot was offline, not bad credentials)\")\n"
        "                            except Exception:\n"
        "                                pass\n"
        "                            break\n"
        "                        else:\n"
        "                            logger.info(f\"[SCAN] SSID '{ssid}' not yet visible ({scan_elapsed}s elapsed, retrying in {SSID_SCAN_INTERVAL}s)...\")\n"
        "                    except Exception as scan_err:\n"
        "                        logger.warning(f\"[SCAN] Scan error: {scan_err}\")\n"
        "                    await asyncio.sleep(SSID_SCAN_INTERVAL)\n"
        "                    scan_elapsed += SSID_SCAN_INTERVAL\n"
        "\n"
        "                if not ssid_found:\n"
        "                    logger.warning(f\"[SCAN] SSID '{ssid}' did not appear within {SSID_SCAN_TIMEOUT_SECONDS}s — skipping connect attempt\")\n"
        "                    return False\n"
        "\n"
        "                # FIX-P4: shortened retry timing\n"
        "                # 2 attempts × 4 checks × 5s = ~40s max before failure.\n"
        "                # SSID is already confirmed visible by the scan loop above,\n"
        "                # so 2 honest attempts are sufficient.\n"
        "                connection_established = False\n"
        "                for connect_attempt in range(1, 3):\n"
        "                    logger.info(f\"WiFi connection attempt {connect_attempt}/2...\")\n"
        "                    if await self._connect_to_wifi(ssid, password):"
    )
    assert old in src, f"P3 anchor not found.\nContext: {src[src.find('NM auto-connected on boot'):src.find('NM auto-connected on boot')+400]!r}"
    src = src.replace(old, new, 1)
    print("P3 applied: SSID presence scan loop added (60s timeout, 5s interval)")

    # Now fix the inner wait loop and log messages to match P4 numbers
    # (only if P3 just inserted the old 5-attempt / 9-check text)
    old_inner = (
        "                    if await self._connect_to_wifi(ssid, password):\n"
        "                        logger.info(f\"Connection command sent, waiting for association and DHCP (up to 45 seconds)...\")\n"
        "                        for wait_attempt in range(1, 10):\n"
        "                            await asyncio.sleep(5)\n"
        "                            logger.info(f\"Checking WiFi connection status (attempt {wait_attempt}/9, {wait_attempt*5}s)...\")\n"
        "                            if self._check_wifi_connected():\n"
        "                                connection_established = True\n"
        "                                logger.info(f\"✓ Connection attempt {connect_attempt} succeeded - WiFi associated with IP\")\n"
        "                                break\n"
        "\n"
        "                        if connection_established:\n"
        "                            break\n"
        "                        else:\n"
        "                            logger.warning(f\"Connection attempt {connect_attempt}: WiFi not associated after 45 seconds\")\n"
        "                            await asyncio.sleep(2)\n"
        "                    else:\n"
        "                        logger.warning(f\"Connection attempt {connect_attempt} failed\")\n"
        "                        await asyncio.sleep(3)"
    )
    new_inner = (
        "                    if await self._connect_to_wifi(ssid, password):\n"
        "                        logger.info(f\"Connection command sent, waiting for association and DHCP (up to 20 seconds)...\")\n"
        "                        for wait_attempt in range(1, 5):\n"
        "                            await asyncio.sleep(5)\n"
        "                            logger.info(f\"Checking WiFi connection status (attempt {wait_attempt}/4, {wait_attempt*5}s)...\")\n"
        "                            if self._check_wifi_connected():\n"
        "                                connection_established = True\n"
        "                                logger.info(f\"✓ Connection attempt {connect_attempt} succeeded - WiFi associated with IP\")\n"
        "                                break\n"
        "\n"
        "                        if connection_established:\n"
        "                            break\n"
        "                        else:\n"
        "                            logger.warning(f\"Connection attempt {connect_attempt}: WiFi not associated after 20 seconds\")\n"
        "                            await asyncio.sleep(2)\n"
        "                    else:\n"
        "                        logger.warning(f\"Connection attempt {connect_attempt} failed\")\n"
        "                        await asyncio.sleep(3)"
    )
    if old_inner in src:
        src = src.replace(old_inner, new_inner, 1)
        print("P4a+b applied inline: connect attempts 2, wait checks 4 (20s per attempt)")

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 4d — Credential nuke threshold: 10 → 3
# (P4a+b are handled inside P3's block above; only the threshold is separate)
# ─────────────────────────────────────────────────────────────────────────────
if not p4_done:
    old_threshold = (
        "                logger.warning(f\"WiFi association failed (persistent failure #{count}/10)\")\n"
        "\n"
        "                if count >= 10:\n"
        "                    logger.error(\"WiFi connection with stored credentials failed 10 consecutive times.\")\n"
        "                    logger.warning(\"Deleting stored credentials and switching to hotspot provisioning...\")\n"
        "                    try:\n"
        "                        os.remove(fail_counter_file)\n"
        "                    except Exception:\n"
        "                        pass\n"
        "                    self._delete_credentials()\n"
        "                    return False  # Will trigger hotspot loop in run()\n"
        "                else:\n"
        "                    logger.warning(f\"Keeping credentials — will retry ({count}/10 failures so far)\")\n"
        "                    return False  # run() will retry after RestartSec"
    )
    new_threshold = (
        "                # FIX-P4d: nuke threshold 10 → 3\n"
        "                logger.warning(f\"WiFi association failed (persistent failure #{count}/3)\")\n"
        "\n"
        "                if count >= 3:\n"
        "                    logger.error(\"WiFi connection with stored credentials failed 3 consecutive times.\")\n"
        "                    logger.warning(\"Deleting stored credentials and switching to hotspot provisioning...\")\n"
        "                    try:\n"
        "                        os.remove(fail_counter_file)\n"
        "                    except Exception:\n"
        "                        pass\n"
        "                    self._delete_credentials()\n"
        "                    return False  # Will trigger hotspot loop in run()\n"
        "                else:\n"
        "                    logger.warning(f\"Keeping credentials — will retry ({count}/3 failures so far)\")\n"
        "                    return False  # run() will retry after RestartSec"
    )
    assert old_threshold in src, "P4d anchor not found — fail counter threshold block not matched"
    src = src.replace(old_threshold, new_threshold, 1)
    print("P4d applied: credential nuke threshold 10 → 3")

script.write_text(src, encoding="utf-8")
print("All patches written successfully.")
PATCHER_EOF

log_success "Python patcher completed"

# ─────────────────────────────────────────────────────────────────────────────
# Verification — check all patch markers are present
# ─────────────────────────────────────────────────────────────────────────────
log_section "Verifying all patches"
python3 -c "
src = open('/usr/local/bin/evvos-provisioning').read()
checks = [
    ('FIX-P1: restored sleep(2) for nl80211 socket release',  'P1 — asyncio.sleep(2) after interface setup'),
    ('FIX-P2: full cleanup before restart',                   'P2 — hostapd/dnsmasq cleanup before restart'),
    ('killall\", \"-9\", \"hostapd',                          'P2 — killall hostapd'),
    ('killall\", \"-9\", \"dnsmasq',                          'P2 — killall dnsmasq'),
    ('ip\",  \"link\", \"set\", \"wlan0\", \"down',            'P2 — wlan0 down before restart'),
    ('FIX-P3: wait for SSID to appear before connecting',     'P3 — SSID scan loop inserted'),
    ('SSID_SCAN_TIMEOUT_SECONDS = 60',                        'P3 — 60s scan timeout'),
    ('nmcli\", \"device\", \"wifi\", \"rescan',               'P3 — nmcli rescan call'),
    ('Fail counter reset (hotspot was offline',               'P3 — fail counter reset on SSID found'),
    ('FIX-P4: shortened retry timing',                        'P4a+b — 2 attempts × 4 checks (40s max)'),
    ('range(1, 3)',                                           'P4a — connect attempts reduced to 2'),
    ('range(1, 5)',                                           'P4b — wait checks reduced to 4 (20s)'),
    ('FIX-P4d: nuke threshold 10 → 3',                       'P4d — credential nuke threshold = 3'),
    ('count >= 3',                                           'P4d — count >= 3 check'),
]
all_ok = True
for token, label in checks:
    ok = token in src
    print(f'  {chr(10003) if ok else chr(10007)}  {label}')
    if not ok:
        all_ok = False
import sys; sys.exit(0 if all_ok else 1)
"

# ─────────────────────────────────────────────────────────────────────────────
# Restart service
# ─────────────────────────────────────────────────────────────────────────────
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
echo -e "${CYAN}  All fixes applied${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  P1  Hotspot interface sleep:    1s → 2s${NC}"
echo -e "${CYAN}      (nl80211 needs ~2s to release wlan0 socket)${NC}"
echo -e "${CYAN}  P2  Cleanup before restart:     killall hostapd/dnsmasq,${NC}"
echo -e "${CYAN}      systemctl stop, ip flush + link down/up${NC}"
echo -e "${CYAN}  P3  SSID scan loop:             wait up to 60s for hotspot${NC}"
echo -e "${CYAN}      to appear before attempting any connection${NC}"
echo -e "${CYAN}  P4  Retry timing:               2 attempts × 20s = ~40s max${NC}"
echo -e "${CYAN}      Cred wipe threshold:        10 failures → 3 (~3 min total)${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Test checklist:${NC}"
echo -e "${YELLOW}  1. Boot Pi first, THEN turn on hotspot → should connect within ~10s of hotspot appearing${NC}"
echo -e "${YELLOW}  2. Disconnect from mobile app → wait 10s → scan for EVVOS_0001 hotspot${NC}"
echo ""
log_success "Done!"
