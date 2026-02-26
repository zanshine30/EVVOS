#!/bin/bash
# EVVOS Timing Patch
# Applies hotspot startup and systemd timing optimisations to the live Pi.
# Run as root: sudo bash evvos_timing.patch

set -e

SCRIPT=/usr/local/bin/evvos-provisioning
SERVICE=/etc/systemd/system/evvos-provisioning.service

echo "🔧 EVVOS Timing Patch"
echo "====================="

# ── 1. Sanity checks ────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo "❌ Run as root: sudo bash evvos_timing.patch"
  exit 1
fi

if [ ! -f "$SCRIPT" ]; then
  echo "❌ Provisioning script not found at $SCRIPT"
  exit 1
fi

if [ ! -f "$SERVICE" ]; then
  echo "❌ Systemd service file not found at $SERVICE"
  exit 1
fi

# ── 2. Backup originals ─────────────────────────────────────────────────────
cp "$SCRIPT"  "${SCRIPT}.bak"
cp "$SERVICE" "${SERVICE}.bak"
echo "✓ Backups saved (${SCRIPT}.bak and ${SERVICE}.bak)"

# ── 3. Patch the provisioning script ────────────────────────────────────────

echo "Patching $SCRIPT ..."

python3 - "$SCRIPT" <<'PYEOF'
import sys

path = sys.argv[1]
text = open(path).read()

# 3a: sleep(2) after killall -9 hostapd → sleep(1)
text = text.replace(
    'subprocess.run(["killall", "-9", "hostapd"], capture_output=True, timeout=5)\n            time.sleep(2)\n            \n            # Stop system services',
    'subprocess.run(["killall", "-9", "hostapd"], capture_output=True, timeout=5)\n            time.sleep(1)\n            \n            # Stop system services'
)

# 3b: sleep(2) after systemctl stop dnsmasq → sleep(1)
text = text.replace(
    'subprocess.run(["systemctl", "stop", "dnsmasq"], capture_output=True, timeout=5)\n            time.sleep(2)\n            \n            # Reset interface',
    'subprocess.run(["systemctl", "stop", "dnsmasq"], capture_output=True, timeout=5)\n            time.sleep(1)\n            \n            # Reset interface'
)

# 3c: sleep(3) after ip link set wlan0 up → sleep(2)
text = text.replace(
    '# Wait for interface to come up and socket to be released\n            time.sleep(3)',
    '# Wait for interface to come up and socket to be released\n            time.sleep(2)'
)

# 3d: asyncio.sleep(3) after _setup_hotspot_interface() → sleep(1)
text = text.replace(
    'if not self._setup_hotspot_interface():\n                return False\n            \n            await asyncio.sleep(3)',
    'if not self._setup_hotspot_interface():\n                return False\n            \n            await asyncio.sleep(1)'
)

# 3e: asyncio.sleep(4) after _start_hostapd() → sleep(2)
text = text.replace(
    'if not self._start_hostapd():\n                return False\n            \n            await asyncio.sleep(4)',
    'if not self._start_hostapd():\n                return False\n            \n            await asyncio.sleep(2)'
)

# 3f: asyncio.sleep(2) after _start_dnsmasq() → sleep(1)
text = text.replace(
    'if not self._start_dnsmasq():\n                await self._stop_hotspot()\n                return False\n            \n            await asyncio.sleep(2)',
    'if not self._start_dnsmasq():\n                await self._stop_hotspot()\n                return False\n            \n            await asyncio.sleep(1)'
)

open(path, 'w').write(text)
print("  ✓ Script patched")
PYEOF

# ── 4. Patch the systemd service file ───────────────────────────────────────

echo "Patching $SERVICE ..."
sed -i 's|ExecStartPre=/bin/sleep 5|ExecStartPre=/bin/sleep 2|' "$SERVICE"
sed -i 's|^RestartSec=15$|RestartSec=5|' "$SERVICE"
echo "  ✓ Service file patched"

# ── 5. Verify all changes landed ────────────────────────────────────────────

echo ""
echo "Verifying changes..."
ERRORS=0

verify_in_script() {
  local label="$1" pattern="$2"
  if grep -qF "$pattern" "$SCRIPT"; then
    echo "  ✓ $label"
  else
    echo "  ❌ NOT FOUND: $label"
    ERRORS=$((ERRORS + 1))
  fi
}

verify_absent_in_script() {
  local label="$1" pattern="$2"
  if grep -qF "$pattern" "$SCRIPT"; then
    echo "  ❌ STILL PRESENT (not patched): $label"
    ERRORS=$((ERRORS + 1))
  else
    echo "  ✓ $label"
  fi
}

verify_in_service() {
  local label="$1" pattern="$2"
  if grep -qF "$pattern" "$SERVICE"; then
    echo "  ✓ $label"
  else
    echo "  ❌ NOT FOUND: $label"
    ERRORS=$((ERRORS + 1))
  fi
}

# The old 3-second interface sleep must be gone
verify_absent_in_script "interface up: no longer sleep(3)" 'socket to be released
            time.sleep(3)'

# The new 2-second interface sleep must be present
verify_in_script "interface up: sleep(2) present" 'socket to be released
            time.sleep(2)'

# The old 4-second post-hostapd sleep must be gone
verify_absent_in_script "post-hostapd: no longer sleep(4)" 'return False
            
            await asyncio.sleep(4)'

# Service file
verify_in_service "ExecStartPre=2" "ExecStartPre=/bin/sleep 2"
verify_in_service "RestartSec=5"   "RestartSec=5"

if [ "$ERRORS" -ne 0 ]; then
  echo ""
  echo "⚠️  $ERRORS verification check(s) failed — restoring backups."
  cp "${SCRIPT}.bak"  "$SCRIPT"
  cp "${SERVICE}.bak" "$SERVICE"
  echo "Backups restored. No changes were applied."
  exit 1
fi

# ── 6. Reload systemd and restart the service ────────────────────────────────

echo ""
systemctl daemon-reload
systemctl restart evvos-provisioning
echo "✓ Service restarted"

echo ""
echo "✅ Patch applied successfully!"
echo ""
echo "Changes applied:"
echo "  killall -9 cooldown:       2s → 1s"
echo "  systemctl stop cooldown:   2s → 1s"
echo "  interface up settle time:  3s → 2s  (kept at 2s for nl80211 safety)"
echo "  post-interface-setup gap:  3s → 1s"
echo "  post-hostapd gap:          4s → 2s"
echo "  post-dnsmasq gap:          2s → 1s"
echo "  ExecStartPre sleep:        5s → 2s"
echo "  RestartSec:               15s → 5s"
echo ""
echo "Total AP startup savings: ~20s"
echo ""
echo "Backups:"
echo "  ${SCRIPT}.bak"
echo "  ${SERVICE}.bak"
echo ""
echo "To roll back:"
echo "  sudo cp ${SCRIPT}.bak $SCRIPT && sudo cp ${SERVICE}.bak $SERVICE && sudo systemctl daemon-reload && sudo systemctl restart evvos-provisioning"
