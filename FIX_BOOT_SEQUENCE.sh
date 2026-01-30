#!/bin/bash
# Deploy fixed boot sequence that properly handles AP mode vs WiFi connection
# Usage: sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/your-org/EVVOS/main/FIX_BOOT_SEQUENCE.sh)"

echo "🔧 Updating EVVOS boot sequence..."

# Create fixed evvos_boot.sh
sudo tee /opt/evvos/scripts/evvos_boot.sh > /dev/null << 'EOF'
#!/bin/bash

# EVVOS Boot Sequence
# Decides whether to start AP mode (provisioning) or connect to saved WiFi

sleep 2  # Wait for system to stabilize

PROVISIONED_CONF="/etc/wpa_supplicant/wpa_provisioned.conf"

echo "[EVVOS] Boot sequence starting..."

# First, ensure we're not connected to any WiFi
echo "[EVVOS] Disconnecting from any existing WiFi..."
sudo killall wpa_supplicant 2>/dev/null || true
sudo systemctl stop wpa_supplicant@wlan0 2>/dev/null || true
sudo systemctl disable wpa_supplicant@wlan0 2>/dev/null || true
sudo systemctl stop networking 2>/dev/null || true
sudo systemctl disable networking 2>/dev/null || true

# Delete the active wpa_supplicant config to prevent auto-reconnect
sudo rm -f /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null || true

sleep 3

# Check if we have provisioned WiFi credentials
if [ -f "$PROVISIONED_CONF" ] && grep -q "ssid=" "$PROVISIONED_CONF"; then
    echo "[EVVOS] ✅ Found provisioned WiFi credentials"
    echo "[EVVOS] Attempting to connect to saved network..."
    
    # Copy provisioned config to active config
    sudo cp "$PROVISIONED_CONF" /etc/wpa_supplicant/wpa_supplicant.conf
    
    # Stop AP mode services
    sudo systemctl stop hostapd dnsmasq 2>/dev/null || true
    
    # Start WiFi connection
    sudo systemctl start wpa_supplicant@wlan0
    sudo systemctl start networking
    sleep 5
    
    # Check if connected
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "[EVVOS] ✅ Successfully connected to provisioned network"
        exit 0
    else
        echo "[EVVOS] ⚠️  Failed to connect to provisioned network, falling back to AP mode"
    fi
fi

# No provisioned credentials or connection failed - start AP mode for provisioning
echo "[EVVOS] 📡 Starting AP mode (EVVOS_0001)..."

# Bring down wlan0
sudo ip link set wlan0 down
sudo ip addr flush dev wlan0
sleep 1

# Bring it back up with AP IP
sudo ip addr add 192.168.4.1/24 dev wlan0
sudo ip link set wlan0 up
sleep 1

# Configure IP forwarding and NAT
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

# Start AP mode services
sudo systemctl start hostapd
sleep 1
sudo systemctl start dnsmasq
sleep 1

echo "[EVVOS] ✅ AP Mode started (EVVOS_0001 at 192.168.4.1)"
echo "[EVVOS] Ready for device provisioning!"

EOF

# Make sure the script is executable
sudo chmod +x /opt/evvos/scripts/evvos_boot.sh

echo "✅ Boot sequence updated"

# Verify the service is enabled
sudo systemctl enable evvos-boot.service

echo ""
echo "📋 Testing boot sequence now..."
sudo /opt/evvos/scripts/evvos_boot.sh

echo ""
echo "✨ Boot sequence fixed!"
echo ""
echo "Next steps:"
echo "1. Reboot your Pi: sudo reboot"
echo "2. After reboot, EVVOS_0001 AP should broadcast automatically"
echo "3. After provisioning, Pi will remember WiFi credentials and auto-connect on next boot"
