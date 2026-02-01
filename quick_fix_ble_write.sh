#!/bin/bash
# Quick fix for BLE Write Characteristics Permissions

echo "🔧 Fixing BLE Characteristic Write Permissions"
echo "=============================================="

PYFILE="/opt/evvos/provisioning/ble_provisioning.py"

if [ ! -f "$PYFILE" ]; then
    echo "❌ Python file not found: $PYFILE"
    exit 1
fi

echo "Stopping BLE service..."
sudo systemctl stop evvos-ble-provisioning
sleep 2

echo "Backing up original file..."
sudo cp "$PYFILE" "${PYFILE}.backup.$(date +%s)"

echo "Applying fix..."
# Fix 1: Add 'write-without-response' to credentials characteristic
sudo sed -i "/characteristic_type == 'status' else 'write'/c\\                'read' if self.characteristic_type == 'status' else ['write', 'write-without-response']" "$PYFILE"

# Alternative: Use Python to make the fix more robust
sudo python3 << 'PYTHON_FIX'
import re

pyfile = "/opt/evvos/provisioning/ble_provisioning.py"

with open(pyfile, 'r') as f:
    content = f.read()

# Fix the Flags configuration
old_flags = """'Flags': dbus.Array([
                'read' if self.characteristic_type == 'status' else 'write'
            ], signature=dbus.Signature('s')),"""

new_flags = """'Flags': dbus.Array(
                ['read'] if self.characteristic_type == 'status' 
                else ['write', 'write-without-response'],
                signature=dbus.Signature('s')
            ),"""

content = content.replace(old_flags, new_flags)

with open(pyfile, 'w') as f:
    f.write(content)

print("✅ Flags fixed")
PYTHON_FIX

echo "Restarting service..."
sudo systemctl start evvos-ble-provisioning
sleep 3

echo ""
echo "Service status:"
sudo systemctl status evvos-ble-provisioning --no-pager | head -5

echo ""
echo "Recent logs:"
sudo journalctl -u evvos-ble-provisioning -n 5 --no-pager

echo ""
echo "✅ Fix applied! Try pairing again on your phone."
