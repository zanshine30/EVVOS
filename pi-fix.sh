#!/bin/bash
# ============================================================================
# EVVOS Provisioning — Patch P9: Lock WiFi to device_credentials.json only
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_provision_complete_16.sh
#
# Safe to re-run — skips if already applied.
#
# ─────────────────────────────────────────────────────────────────────────────
# ROOT CAUSE
#   _connect_to_wifi() saves the provisioned SSID as a persistent NM profile
#   with autoconnect=yes and autoconnect-priority=10.  On the next boot NM
#   sees that saved profile (or any other saved home/office WiFi) and connects
#   to it immediately — before the provisioning script even runs.
#
# TWO-PART FIX
#
# Part A — autoconnect=no in _connect_to_wifi()
#   Change the saved NM profile to autoconnect=no so NM never auto-connects
#   on boot.  Only the provisioning script connects to WiFi explicitly.
#   autoconnect-priority is also removed (irrelevant when autoconnect=no).
#
# Part B — purge stale NM profiles on startup in _provision_wifi()
#   Before attempting any connection, delete every saved NM WiFi profile
#   whose SSID does NOT match what is in device_credentials.json.
#   This cleans up any home/office networks saved before this patch,
#   and prevents leftover profiles from being auto-connected in future.
#   If credentials are absent (hotspot mode), ALL WiFi profiles are purged.
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

log_section "EVVOS Provisioning — Patch P9: Lock WiFi to credentials file only"

cp "$SCRIPT" "${SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-provisioning")
src = script.read_text(encoding="utf-8")

MARKER = "# FIX-P9:"
if MARKER in src:
    print("P9 already applied — nothing to do.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# Part A — change autoconnect=yes → autoconnect=no in _connect_to_wifi()
# ─────────────────────────────────────────────────────────────────────────────
old_autoconnect = (
    '                        "connection.autoconnect", "yes",\n'
    '                        "connection.autoconnect-priority", "10",'
)
new_autoconnect = (
    '                        # FIX-P9: autoconnect=no — NM must never auto-connect\n'
    '                        # on boot. Only the provisioning script connects explicitly.\n'
    '                        "connection.autoconnect", "no",'
)

assert old_autoconnect in src, (
    "P9-A anchor not found: autoconnect block not matched.\n"
    "Check: grep -n 'autoconnect' /usr/local/bin/evvos-provisioning"
)
src = src.replace(old_autoconnect, new_autoconnect, 1)
print("P9-A applied: NM profile autoconnect set to no")

# ─────────────────────────────────────────────────────────────────────────────
# Part B — purge stale NM profiles at the top of _provision_wifi()
#           and remove the "NM auto-connected on boot" shortcut that bypasses
#           credential validation entirely.
# ─────────────────────────────────────────────────────────────────────────────
old_boot_check = (
    '            # ----------------------------------------------------------------\n'
    '            # On boot, NetworkManager may auto-connect before our script even\n'
    '            # runs.  Check first — if we already have an IP, skip the connect\n'
    '            # dance entirely and just verify internet.\n'
    '            # ----------------------------------------------------------------\n'
    '            if self._check_wifi_connected():\n'
    '                logger.info("✓ WiFi already connected (NM auto-connected on boot)")\n'
    '                connection_established = True'
)
new_boot_check = (
    '            # FIX-P9: purge every NM WiFi profile whose SSID does not match\n'
    '            # the one in device_credentials.json.  This prevents any previously\n'
    '            # saved home/office network from being auto-connected on boot.\n'
    '            self._purge_unrecognised_nm_profiles(ssid)\n'
    '\n'
    '            # With autoconnect=no on all profiles (P9-A), NM will never\n'
    '            # connect on its own — always go through our connect logic.\n'
    '            if False:  # placeholder so indentation below stays unchanged\n'
    '                connection_established = True'
)

assert old_boot_check in src, (
    "P9-B anchor not found: boot-check block not matched.\n"
    "Check: grep -n 'NM auto-connected on boot' /usr/local/bin/evvos-provisioning"
)
src = src.replace(old_boot_check, new_boot_check, 1)
print("P9-B applied: boot auto-connect shortcut replaced with profile purge")

# ─────────────────────────────────────────────────────────────────────────────
# Part C — insert _purge_unrecognised_nm_profiles() method before _provision_wifi
# ─────────────────────────────────────────────────────────────────────────────
purge_method = (
    "    def _purge_unrecognised_nm_profiles(self, allowed_ssid: str = None) -> None:\n"
    "        \"\"\"\n"
    "        FIX-P9: Delete every saved NM WiFi connection profile whose SSID\n"
    "        does not match allowed_ssid.  If allowed_ssid is None or empty,\n"
    "        ALL saved WiFi profiles are deleted.\n"
    "\n"
    "        This prevents any home/office network saved before this patch from\n"
    "        being auto-connected on boot by NetworkManager.\n"
    "        \"\"\"\n"
    "        try:\n"
    "            result = subprocess.run(\n"
    "                [\"nmcli\", \"-t\", \"-f\", \"NAME,TYPE\", \"connection\", \"show\"],\n"
    "                capture_output=True, text=True, timeout=10\n"
    "            )\n"
    "            for line in result.stdout.strip().splitlines():\n"
    "                parts = line.split(\":\")\n"
    "                if len(parts) < 2:\n"
    "                    continue\n"
    "                name, conn_type = parts[0], parts[1]\n"
    "                if \"wireless\" not in conn_type and \"wifi\" not in conn_type:\n"
    "                    continue  # skip ethernet, loopback, etc.\n"
    "                if allowed_ssid and name == allowed_ssid:\n"
    "                    logger.info(\"[P9] Keeping NM profile: %s\", name)\n"
    "                    continue\n"
    "                logger.warning(\"[P9] Deleting unrecognised NM WiFi profile: %s\", name)\n"
    "                subprocess.run(\n"
    "                    [\"nmcli\", \"connection\", \"delete\", name],\n"
    "                    capture_output=True, timeout=10\n"
    "                )\n"
    "        except Exception as e:\n"
    "            logger.warning(\"[P9] Could not purge NM profiles: %s\", e)\n"
    "\n"
)

insert_before = "    async def _provision_wifi(self):"
assert insert_before in src, "_provision_wifi method not found"
src = src.replace(insert_before, purge_method + insert_before, 1)
print("P9-C applied: _purge_unrecognised_nm_profiles() method inserted")

# ─────────────────────────────────────────────────────────────────────────────
# Part D — also call purge when entering hotspot mode (no credentials)
# ─────────────────────────────────────────────────────────────────────────────
old_no_creds = (
    "        # No stored credentials or they were just deleted\n"
    "        logger.info(\"No stored credentials. Starting hotspot provisioning...\")\n"
    "        return await self._provision_with_hotspot()"
)
new_no_creds = (
    "        # No stored credentials or they were just deleted\n"
    "        logger.info(\"No stored credentials. Starting hotspot provisioning...\")\n"
    "        # FIX-P9: purge ALL WiFi profiles so NM cannot auto-connect to anything\n"
    "        self._purge_unrecognised_nm_profiles(allowed_ssid=None)\n"
    "        return await self._provision_with_hotspot()"
)

assert old_no_creds in src, (
    "P9-D anchor not found: no-credentials block not matched."
)
src = src.replace(old_no_creds, new_no_creds, 1)
print("P9-D applied: purge all profiles when entering hotspot mode")

script.write_text(src, encoding="utf-8")
print("\nP9 complete.")
PATCHER_EOF

log_success "Python patcher completed"

# ─────────────────────────────────────────────────────────────────────────────
# Also immediately purge all saved WiFi profiles on the running system
# so the fix takes effect without waiting for the next provisioning cycle
# ─────────────────────────────────────────────────────────────────────────────
log_section "Purging stale NM WiFi profiles from running system"

CREDS_FILE="/etc/evvos/device_credentials.json"
if [ -f "$CREDS_FILE" ]; then
    ALLOWED_SSID=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d.get('ssid',''))" 2>/dev/null || echo "")
    if [ -n "$ALLOWED_SSID" ]; then
        log_info "Credentials found — keeping NM profile for SSID: $ALLOWED_SSID"
    else
        log_info "Credentials file exists but has no SSID — purging all WiFi profiles"
        ALLOWED_SSID=""
    fi
else
    log_info "No credentials file — purging all saved WiFi profiles"
    ALLOWED_SSID=""
fi

python3 << PURGE_EOF
import subprocess, sys

allowed = """$ALLOWED_SSID""".strip()

result = subprocess.run(
    ["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"],
    capture_output=True, text=True, timeout=10
)
deleted = 0
for line in result.stdout.strip().splitlines():
    parts = line.split(":")
    if len(parts) < 2:
        continue
    name, conn_type = parts[0], parts[1]
    if "wireless" not in conn_type and "wifi" not in conn_type:
        continue
    if allowed and name == allowed:
        print(f"  keeping  : {name}")
        continue
    print(f"  deleting : {name}")
    subprocess.run(["nmcli", "connection", "delete", name], capture_output=True, timeout=10)
    deleted += 1

print(f"\n  {deleted} profile(s) deleted.")
PURGE_EOF

log_success "Stale NM profiles purged"

# ─────────────────────────────────────────────────────────────────────────────
# Verification
# ─────────────────────────────────────────────────────────────────────────────
log_section "Verifying patch P9"
python3 << 'VERIFY_EOF'
src = open('/usr/local/bin/evvos-provisioning', encoding='utf-8').read()
checks = [
    ('# FIX-P9: autoconnect=no',
     'P9-A — autoconnect set to no in _connect_to_wifi'),
    ('"connection.autoconnect", "no"',
     'P9-A — autoconnect=no value'),
    ('_purge_unrecognised_nm_profiles',
     'P9-B/C — purge method exists and is called'),
    ('def _purge_unrecognised_nm_profiles',
     'P9-C — purge method defined'),
    ('FIX-P9: purge ALL WiFi profiles',
     'P9-D — purge called in hotspot fallback'),
]
all_ok = True
for token, label in checks:
    ok = token in src
    print(f'  {chr(10003) if ok else chr(10007)}  {label}')
    if not ok:
        all_ok = False
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
echo -e "${CYAN}  Patch P9 applied${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  A  NM WiFi profiles saved with autoconnect=no${NC}"
echo -e "${CYAN}     (NM will never auto-connect on boot anymore)${NC}"
echo -e "${CYAN}  B  Boot auto-connect shortcut removed${NC}"
echo -e "${CYAN}  C  _purge_unrecognised_nm_profiles() added${NC}"
echo -e "${CYAN}     Deletes any NM profile not in credentials file${NC}"
echo -e "${CYAN}  D  All profiles purged when entering hotspot mode${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  On every boot the Pi will now:${NC}"
echo -e "${YELLOW}  1. Read /etc/evvos/device_credentials.json${NC}"
echo -e "${YELLOW}  2. Delete any NM WiFi profile not matching that SSID${NC}"
echo -e "${YELLOW}  3a. Credentials present → connect to that SSID only${NC}"
echo -e "${YELLOW}  3b. No credentials      → start EVVOS_0001 hotspot${NC}"
echo ""
echo -e "${YELLOW}  Verify: journalctl -u evvos-provisioning -f${NC}"
echo ""
log_success "Done!"
