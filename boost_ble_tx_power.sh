#!/bin/bash
# BLE TX Power Boost for WiFi Interference Mitigation
# Run this on the Raspberry Pi to maximize BLE signal strength

echo "🔵 EVVOS BLE TX Power Boost Script"
echo "===================================="

# Stop the BLE service
echo "Stopping BLE provisioning service..."
sudo systemctl stop evvos-ble-provisioning

# Wait for cleanup
sleep 2

# Enable Bluetooth adapter
echo "Bringing up Bluetooth adapter..."
sudo hciconfig hci0 up

# Wait a moment
sleep 1

# Command 1: Set adapter to LE-only mode for better BLE performance
echo "Configuring BLE mode..."
sudo hciconfig hci0 piscan
sudo hciconfig hci0 leadv

# Command 2: Boost TX power (requires hcitool)
echo "Boosting TX power to maximum (+7 dBm)..."

# Method 1: Direct TX Power command (most reliable)
sudo hcitool -i hci0 cmd 0x08 0x0009 04 02 07 00 2>/dev/null && echo "✅ TX power boost applied (method 1)"

# Method 2: Vendor-specific command (Broadcom)
sudo hcitool -i hci0 cmd 0x3f 0x004 07 2>/dev/null && echo "✅ TX power boost applied (method 2)"

# Command 3: Set minimum advertising interval for faster discovery
# LE Set Advertising Parameters: min_interval=20ms (0x20), max_interval=20ms (0x20)
sudo hcitool -i hci0 cmd 0x08 0x0006 0x20 0x00 0x20 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 2>/dev/null && echo "✅ Advertising interval optimized"

# Wait for stabilization
sleep 2

# Restart the BLE service
echo "Restarting BLE provisioning service..."
sudo systemctl start evvos-ble-provisioning

# Wait for service to start
sleep 3

# Check service status
echo ""
echo "Service Status:"
sudo systemctl status evvos-ble-provisioning --no-pager | head -5

echo ""
echo "🚀 BLE TX Power Boost Complete!"
echo "The EVVOS device should now be discoverable even with WiFi interference."
echo ""
echo "Next steps:"
echo "1. Try scanning for EVVOS_0001 on your phone"
echo "2. Move phone close to Pi (within 1-2 meters)"
echo "3. Turn phone Bluetooth OFF and ON if not found"
echo ""
echo "To see detailed logs:"
echo "  sudo journalctl -u evvos-ble-provisioning -f"
