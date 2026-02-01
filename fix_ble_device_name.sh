#!/bin/bash
# Quick BLE Name Fix - Change advertising name from 'raspberrypi' to 'EVVOS_0001'

echo "🔵 Changing BLE Device Name to EVVOS_0001"
echo "========================================="

# Stop the service
echo "Stopping BLE service..."
sudo systemctl stop evvos-ble-provisioning
sleep 2

# Set BLE adapter name using bluetoothctl
echo "Setting device name..."
sudo bluetoothctl set-alias EVVOS_0001
sudo bluetoothctl system-alias EVVOS_0001

# Alternative: Using dbus directly
echo "Configuring via D-Bus..."
sudo dbus-send --print-reply --system \
  --dest=org.bluez /org/bluez/hci0 \
  org.freedesktop.DBus.Properties.Set \
  string:org.bluez.Adapter1 \
  string:Alias \
  variant:string:"EVVOS_0001" 2>/dev/null && echo "✅ D-Bus Alias set" || echo "⚠️  D-Bus Alias: attempt made"

# Restart service
echo "Restarting BLE service..."
sudo systemctl start evvos-ble-provisioning
sleep 3

echo ""
echo "Service Status:"
sudo systemctl status evvos-ble-provisioning --no-pager | grep -E "Active|Main PID"

echo ""
echo "🚀 Device name should now be EVVOS_0001"
echo ""
echo "Verify with:"
echo "  sudo bluetoothctl show"
echo "  sudo journalctl -u evvos-ble-provisioning -f"
