#!/bin/bash

# ============================================================================
# EVVOS Raspberry Pi Setup - Complete Installation Script
# ============================================================================
#
# This is the PRODUCTION-READY setup script for Raspberry Pi Zero 2 W
# It handles the complete provisioning flow setup for the EVVOS mobile app
#
# HOW TO USE:
#
# 1. SSH into your Raspberry Pi:
#    ssh pi@<your-pi-ip>
#
# 2. Copy-paste this ENTIRE command into the Pi terminal:
#
#    sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/your-org/evvos/main/RaspberryPiZero2W/evvos_provision_setup.sh)"
#
#    OR if you have the script file locally, run it directly:
#
#    sudo bash /path/to/evvos_provision_setup.sh
#
# 3. Wait for completion (5-15 minutes)
#
# 4. Edit config with your Supabase URL:
#    sudo nano /etc/systemd/system/evvos-provisioning.service
#
# 5. Restart services:
#    sudo systemctl daemon-reload
#    sudo systemctl restart evvos-provisioning evvos-boot
#
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================================================
# 1. UPDATE SYSTEM
# ============================================================================
log_info "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq
log_success "System updated"

# ============================================================================
# 2. INSTALL DEPENDENCIES
# ============================================================================
log_info "Installing required packages..."

# Core networking tools
apt-get install -y -qq \
    hostapd \
    dnsmasq \
    iptables \
    iptables-persistent \
    net-tools \
    wireless-tools \
    wpasupplicant \
    curl \
    wget \
    git

# Python and development tools
apt-get install -y -qq \
    python3 \
    python3-pip \
    python3-dev \
    python3-venv \
    build-essential \
    libssl-dev

log_success "Dependencies installed"

# ============================================================================
# 3. CREATE APPLICATION DIRECTORY
# ============================================================================
EVVOS_DIR="/opt/evvos"
APP_DIR="$EVVOS_DIR/provisioning"
SCRIPTS_DIR="$EVVOS_DIR/scripts"
CONFIG_DIR="$EVVOS_DIR/config"

log_info "Creating application directories..."
mkdir -p "$APP_DIR" "$SCRIPTS_DIR" "$CONFIG_DIR"
chown -R pi:pi "$EVVOS_DIR"

log_success "Directories created at $EVVOS_DIR"

# ============================================================================
# 4. CREATE PYTHON VIRTUAL ENVIRONMENT
# ============================================================================
log_info "Creating Python virtual environment..."
cd "$APP_DIR"
sudo -u pi python3 -m venv venv
source venv/bin/activate

# Install Python dependencies
pip install --upgrade -q pip setuptools wheel
pip install -q \
    flask \
    requests \
    cryptography \
    python-dotenv

log_success "Python virtual environment ready"

# ============================================================================
# 5. CREATE PROVISIONING SERVER (Flask app)
# ============================================================================
log_info "Creating provisioning server..."

cat > "$APP_DIR/app.py" << 'FLASK_APP_EOF'
#!/usr/bin/env python3
"""
EVVOS Provisioning Server
Runs on http://192.168.4.1/provision to receive WiFi credentials from mobile app.
"""

import json
import os
import hashlib
import subprocess
import time
import threading
import requests
import logging
from pathlib import Path
from flask import Flask, request, jsonify
from datetime import datetime

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Configuration
PROVISIONING_TOKEN_FILE = "/tmp/evvos_prov_token.txt"
CREDENTIALS_FILE = "/etc/wpa_supplicant/wpa_provisioned.conf"
SUPABASE_URL = os.getenv("SUPABASE_URL", "https://your-supabase-url.supabase.co")
PROVISIONING_TIMEOUT = 300  # 5 minutes

# Store current provisioning context
current_provision = {
    "token": None,
    "ssid": None,
    "password": None,
    "device_name": None,
    "received_at": None,
}

def hash_token(token):
    """Hash token using SHA256 (matches mobile app and edge function)"""
    return hashlib.sha256(token.encode()).hexdigest()

def write_wpa_config(ssid, password):
    """Write WiFi credentials to wpa_supplicant config"""
    try:
        logger.info(f"Writing WiFi config for SSID: {ssid}")
        
        # Create network block
        network_block = f'''
network={{
	ssid="{ssid}"
	psk="{password}"
	priority=1
}}
'''
        
        # Create basic config if it doesn't exist
        config_path = "/etc/wpa_supplicant/wpa_supplicant.conf"
        if not Path(config_path).exists():
            basic_config = """ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US
"""
        else:
            with open(config_path, 'r') as f:
                basic_config = f.read()
        
        new_config = basic_config + network_block
        
        # Write with appropriate permissions
        with open('/tmp/wpa_temp.conf', 'w') as f:
            f.write(new_config)
        
        subprocess.run(['sudo', 'mv', '/tmp/wpa_temp.conf', config_path], check=True)
        subprocess.run(['sudo', 'chmod', '600', config_path], check=True)
        
        logger.info("WPA config written successfully")
        return True
        
    except Exception as e:
        logger.error(f"Failed to write WPA config: {e}")
        return False

def attempt_wifi_connection():
    """Attempt to connect to provisioned WiFi"""
    try:
        logger.info("Attempting to connect to provisioned WiFi...")
        
        # Reconfigure networking
        subprocess.run(['sudo', 'systemctl', 'restart', 'networking'], check=True)
        
        # Wait for connection
        for attempt in range(30):
            result = subprocess.run(
                ['ip', 'route', 'get', '8.8.8.8'],
                capture_output=True,
                text=True
            )
            
            if result.returncode == 0 and 'tun0' not in result.stdout and 'ap0' not in result.stdout:
                logger.info(f"✅ Connected to WiFi on attempt {attempt + 1}")
                return True
            
            time.sleep(1)
        
        logger.warning("Failed to connect to WiFi after 30 attempts")
        return False
        
    except Exception as e:
        logger.error(f"WiFi connection attempt failed: {e}")
        return False

def call_finish_provisioning():
    """Call Supabase finish_provisioning edge function"""
    try:
        if not current_provision["token"]:
            logger.error("No token available for finish_provisioning")
            return False
        
        logger.info("🚀 Calling finish_provisioning edge function...")
        
        url = f"{SUPABASE_URL}/functions/v1/finish_provisioning"
        payload = {
            "token": current_provision["token"],
            "ssid": current_provision["ssid"],
            "password": current_provision["password"],
            "device_name": current_provision["device_name"] or "EVVOS_0001"
        }
        
        logger.info(f"POST {url}")
        logger.info(f"Payload: {json.dumps({**payload, 'password': '***'})}")
        
        response = requests.post(
            url,
            json=payload,
            timeout=10
        )
        
        logger.info(f"Response: {response.status_code}")
        
        if response.status_code == 200:
            logger.info("✅ Provisioning completed in Supabase!")
            return True
        else:
            logger.warning(f"finish_provisioning returned {response.status_code}: {response.text}")
            return False
            
    except requests.exceptions.ConnectionError:
        logger.warning("No internet connection yet for finish_provisioning")
        return False
    except Exception as e:
        logger.error(f"finish_provisioning call failed: {e}")
        return False

def provision_complete_handler():
    """Background thread to handle post-provisioning tasks"""
    def handler():
        time.sleep(2)  # Give Pi time to switch networks
        
        # Attempt WiFi connection
        if attempt_wifi_connection():
            time.sleep(5)  # Wait for full connectivity
            
            # Retry finish_provisioning a few times
            for attempt in range(5):
                if call_finish_provisioning():
                    logger.info("🎉 Provisioning flow complete!")
                    break
                logger.warning(f"Retrying finish_provisioning (attempt {attempt + 1}/5)...")
                time.sleep(5)
    
    thread = threading.Thread(target=handler, daemon=True)
    thread.start()

# ============================================================================
# FLASK ROUTES
# ============================================================================

@app.route('/provision', methods=['POST', 'OPTIONS'])
def provision():
    """
    Receive provisioning credentials from mobile app
    Expected JSON: { token, ssid, password, device_name }
    """
    
    # Handle CORS preflight
    if request.method == 'OPTIONS':
        return '', 204, {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type',
        }
    
    try:
        logger.info("📡 Provision request received")
        
        # Parse JSON
        data = request.get_json() or {}
        logger.info(f"Received data keys: {list(data.keys())}")
        
        token = data.get('token')
        ssid = data.get('ssid')
        password = data.get('password')
        device_name = data.get('device_name', 'EVVOS_0001')
        
        # Validate required fields
        if not token or not ssid or not password:
            logger.error(f"Missing required fields: token={bool(token)}, ssid={bool(ssid)}, password={bool(password)}")
            return jsonify({'error': 'Missing required fields (token, ssid, password)'}), 400
        
        logger.info(f"✅ Validation passed")
        logger.info(f"   SSID: {ssid}")
        logger.info(f"   Device: {device_name}")
        logger.info(f"   Token: {token[:16]}...")
        
        # Store provisioning context
        current_provision["token"] = token
        current_provision["ssid"] = ssid
        current_provision["password"] = password
        current_provision["device_name"] = device_name
        current_provision["received_at"] = datetime.now().isoformat()
        
        # Write WiFi credentials
        if not write_wpa_config(ssid, password):
            logger.error("Failed to write WiFi config")
            return jsonify({'error': 'Failed to store credentials'}), 500
        
        logger.info("✅ Credentials stored")
        
        # Start background provisioning handler
        provision_complete_handler()
        
        return jsonify({
            'ok': True,
            'message': 'Credentials received. Please enable your hotspot now.',
            'status': 'waiting_for_hotspot'
        }), 200
        
    except Exception as e:
        logger.error(f"❌ Provision error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/status', methods=['GET'])
def status():
    """Check provisioning status"""
    return jsonify({
        'status': 'provisioning' if current_provision["token"] else 'idle',
        'current_provision': {
            'device_name': current_provision.get("device_name"),
            'ssid': current_provision.get("ssid"),
            'received_at': current_provision.get("received_at")
        }
    })

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({'status': 'ok'})

if __name__ == '__main__':
    logger.info("🟢 EVVOS Provisioning Server starting...")
    logger.info(f"Listening on 0.0.0.0:80")
    logger.info(f"Supabase URL: {SUPABASE_URL}")
    
    app.run(host='0.0.0.0', port=80, debug=False, threaded=True)

FLASK_APP_EOF

chmod +x "$APP_DIR/app.py"
chown pi:pi "$APP_DIR/app.py"
log_success "Provisioning server created"

# ============================================================================
# 6. CREATE HOTSPOT CONFIGURATION SCRIPTS
# ============================================================================
log_info "Creating hotspot scripts..."

# Script to enable AP mode
cat > "$SCRIPTS_DIR/start_ap.sh" << 'AP_START_EOF'
#!/bin/bash

# Enable forwarding and NAT
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT

# Save iptables rules
sh -c "iptables-save > /etc/iptables/rules.v4"

# Bring down wlan0 and configure AP
ip link set wlan0 down
ip addr flush dev wlan0
ip addr add 192.168.4.1/24 dev wlan0
ip link set wlan0 up

# Start hostapd and dnsmasq
systemctl start hostapd
systemctl start dnsmasq

echo "✅ AP Mode started (EVVOS_0001 at 192.168.4.1)"

AP_START_EOF

chmod +x "$SCRIPTS_DIR/start_ap.sh"
chown pi:pi "$SCRIPTS_DIR/start_ap.sh"

# Script to disable AP mode and connect to WiFi
cat > "$SCRIPTS_DIR/stop_ap.sh" << 'AP_STOP_EOF'
#!/bin/bash

# Stop AP services
systemctl stop hostapd
systemctl stop dnsmasq

# Reset wlan0
ip addr flush dev wlan0
ip link set wlan0 down

# Re-enable wpa_supplicant
systemctl restart wpa_supplicant
systemctl restart networking

echo "✅ AP Mode stopped, connecting to WiFi..."

AP_STOP_EOF

chmod +x "$SCRIPTS_DIR/stop_ap.sh"
chown pi:pi "$SCRIPTS_DIR/stop_ap.sh"

log_success "Hotspot scripts created"

# ============================================================================
# 7. CONFIGURE HOSTAPD
# ============================================================================
log_info "Configuring hostapd..."

cat > /etc/hostapd/hostapd.conf << 'HOSTAPD_EOF'
interface=wlan0
driver=nl80211
ssid=EVVOS_0001
hw_mode=g
channel=6
wmm_enabled=0
country_code=US
ieee80211n=1
ht_capab=[SHORT-GI-20]
HOSTAPD_EOF

chmod 644 /etc/hostapd/hostapd.conf

log_success "hostapd configured"

# ============================================================================
# 8. CONFIGURE DNSMASQ
# ============================================================================
log_info "Configuring dnsmasq..."

cat > /etc/dnsmasq.d/evvos.conf << 'DNSMASQ_EOF'
interface=wlan0
except-interface=lo
bind-interfaces
dhcp-range=192.168.4.50,192.168.4.150,12h
address=/#/192.168.4.1
DNSMASQ_EOF

log_success "dnsmasq configured"

# ============================================================================
# 9. CREATE SYSTEMD SERVICE FOR PROVISIONING SERVER
# ============================================================================
log_info "Creating systemd service for provisioning server..."

cat > /etc/systemd/system/evvos-provisioning.service << 'SYSTEMD_EOF'
[Unit]
Description=EVVOS Provisioning Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/opt/evvos/provisioning
Environment="PATH=/opt/evvos/provisioning/venv/bin"
Environment="SUPABASE_URL=https://your-supabase-url.supabase.co"
ExecStart=/opt/evvos/provisioning/venv/bin/python3 /opt/evvos/provisioning/app.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

systemctl daemon-reload
systemctl enable evvos-provisioning.service

log_success "Systemd service created"

# ============================================================================
# 10. CREATE BOOT SEQUENCE SCRIPT
# ============================================================================
log_info "Creating boot sequence script..."

cat > "$SCRIPTS_DIR/evvos_boot.sh" << 'BOOT_EOF'
#!/bin/bash

# EVVOS Boot Sequence
# This script runs on Pi startup to initialize AP mode

sleep 2  # Wait for system to stabilize

WIFI_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
PROVISIONED_CONF="/etc/wpa_supplicant/wpa_provisioned.conf"

# Check if we have provisioned WiFi credentials
if [ -f "$WIFI_CONF" ] && grep -q "ssid=" "$WIFI_CONF"; then
    echo "[EVVOS] Found provisioned WiFi, attempting connection..."
    
    # Try to connect to provisioned network
    systemctl restart networking
    sleep 10
    
    # Check if connected
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "[EVVOS] ✅ Connected to provisioned network"
        exit 0
    fi
fi

# If no provisioned network or connection failed, start AP mode
echo "[EVVOS] Starting AP mode (EVVOS_0001)..."
/opt/evvos/scripts/start_ap.sh

BOOT_EOF

chmod +x "$SCRIPTS_DIR/evvos_boot.sh"
chown pi:pi "$SCRIPTS_DIR/evvos_boot.sh"

# Create systemd service for boot sequence
cat > /etc/systemd/system/evvos-boot.service << 'BOOT_SERVICE_EOF'
[Unit]
Description=EVVOS Boot Sequence
After=network.target
Before=evvos-provisioning.service

[Service]
Type=oneshot
User=root
ExecStart=/opt/evvos/scripts/evvos_boot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BOOT_SERVICE_EOF

systemctl daemon-reload
systemctl enable evvos-boot.service

log_success "Boot sequence script created"

# ============================================================================
# 11. CONFIGURE NETWORK INTERFACES
# ============================================================================
log_info "Configuring network interfaces..."

cat >> /etc/dhcpcd.conf << 'DHCPCD_EOF'

# Configure wlan0 for AP mode
interface wlan0
static ip_address=192.168.4.1/24
nohook wpa_supplicant
DHCPCD_EOF

log_success "Network interfaces configured"

# ============================================================================
# 12. SUMMARY AND NEXT STEPS
# ============================================================================

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       EVVOS Pi Zero 2 W Setup Complete! ✅                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "📍 Installation Directory: $EVVOS_DIR"
echo "📍 Provisioning App: $APP_DIR/app.py"
echo ""
echo "🔧 IMPORTANT - Next Steps:"
echo ""
echo "1. Update Supabase URL:"
echo "   sudo nano /etc/systemd/system/evvos-provisioning.service"
echo "   → Replace 'https://your-supabase-url.supabase.co' with your URL"
echo ""
echo "2. Reload systemd:"
echo "   sudo systemctl daemon-reload"
echo ""
echo "3. Enable and start services:"
echo "   sudo systemctl enable evvos-provisioning"
echo "   sudo systemctl enable evvos-boot"
echo "   sudo systemctl start evvos-boot"
echo ""
echo "4. Verify services are running:"
echo "   sudo systemctl status evvos-provisioning"
echo "   sudo systemctl status evvos-boot"
echo ""
echo "5. Check logs:"
echo "   sudo journalctl -u evvos-provisioning -f"
echo ""
echo "🚀 The Pi is ready for provisioning!"
echo ""

log_success "Setup complete!"
