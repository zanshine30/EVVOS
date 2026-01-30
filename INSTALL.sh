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
    libssl-dev \
    libffi-dev \
    pkg-config

log_success "Dependencies installed"

# ============================================================================
# 3. CREATE APPLICATION DIRECTORY
# ============================================================================
EVVOS_DIR="/opt/evvos"
APP_DIR="$EVVOS_DIR/provisioning"
SCRIPTS_DIR="$EVVOS_DIR/scripts"
CONFIG_DIR="$EVVOS_DIR/config"

# Determine which user to use
if id "pi" &>/dev/null; then
    TARGET_USER="pi:pi"
else
    # Create pi user if it doesn't exist
    log_info "Creating 'pi' user..."
    useradd -m -s /bin/bash pi 2>/dev/null || true
    TARGET_USER="pi:pi"
fi

log_info "Creating application directories..."
mkdir -p "$APP_DIR" "$SCRIPTS_DIR" "$CONFIG_DIR"

log_success "Directories created at $EVVOS_DIR"

# ============================================================================
# 4. CREATE PYTHON VIRTUAL ENVIRONMENT
# ============================================================================
log_info "Creating Python virtual environment..."
cd "$APP_DIR"
python3 -m venv venv
source venv/bin/activate

# Install Python dependencies
pip install --upgrade -q pip setuptools wheel 2>/dev/null || pip install --upgrade pip setuptools wheel
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

def trigger_hotspot_connection(ssid, password):
    """Trigger hotspot connection script in background (20 retries with fallback to AP)"""
    def connect_thread():
        try:
            logger.info(f"🔄 Starting hotspot connection thread for SSID: {ssid}")
            
            # Check if script exists
            if not os.path.isfile('/opt/evvos/scripts/connect_to_hotspot.sh'):
                logger.error("❌ connect_to_hotspot.sh script not found!")
                return
            
            result = subprocess.run(
                ['/bin/bash', '/opt/evvos/scripts/connect_to_hotspot.sh', ssid, password],
                capture_output=True,
                text=True,
                timeout=600  # 10 minute timeout
            )
            
            if result.stdout:
                logger.info(f"Script output:\n{result.stdout}")
            if result.stderr:
                logger.warning(f"Script stderr: {result.stderr}")
            
            if result.returncode == 0:
                logger.info("✅ Connected to hotspot!")
                # Try to call finish_provisioning if connected
                call_finish_provisioning()
            else:
                logger.warning(f"⚠️ Hotspot connection script returned code {result.returncode}")
                
        except subprocess.TimeoutExpired:
            logger.error("❌ Hotspot connection timed out after 10 minutes")
        except FileNotFoundError as e:
            logger.error(f"❌ Script not found: {e}")
        except Exception as e:
            logger.error(f"❌ Error in hotspot connection: {e}")
    
    thread = threading.Thread(target=connect_thread, daemon=True)
    thread.start()

def attempt_wifi_connection():
    """Deprecated - replaced by trigger_hotspot_connection"""
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
    """Deprecated - replaced by trigger_hotspot_connection"""
    pass

# ============================================================================
# FLASK ROUTES
# ============================================================================

def add_cors_headers(response):
    """Add CORS headers to response"""
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS, GET'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type'
    return response

@app.route('/provision', methods=['POST', 'OPTIONS'])
def provision():
    """
    Receive provisioning credentials from mobile app
    Expected JSON: { token, ssid, password, device_name }
    
    Flow:
    1. Receives hotspot SSID and password from mobile app
    2. Stores credentials
    3. Triggers background script to:
       - Stop AP mode
       - Attempt to connect to hotspot (20 retries)
       - If succeeds: Pi connects to hotspot, mobile app can continue
       - If fails: Return to AP mode for new provisioning attempt
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
            response = jsonify({'error': 'Missing required fields (token, ssid, password)'})
            return add_cors_headers(response), 400
        
        logger.info(f"✅ Validation passed")
        logger.info(f"   SSID (Hotspot): {ssid}")
        logger.info(f"   Device: {device_name}")
        logger.info(f"   Token: {token[:16]}...")
        
        # Store provisioning context
        current_provision["token"] = token
        current_provision["ssid"] = ssid
        current_provision["password"] = password
        current_provision["device_name"] = device_name
        current_provision["received_at"] = datetime.now().isoformat()
        
        logger.info("✅ Credentials stored in memory")
        
        # Trigger hotspot connection (handles AP->WiFi switch, 20 retries, fallback)
        trigger_hotspot_connection(ssid, password)
        
        response = jsonify({
            'ok': True,
            'message': 'Credentials received. Pi is switching from AP mode to connect to your hotspot.',
            'status': 'switching_to_hotspot'
        })

        return add_cors_headers(response), 200
        
    except Exception as e:
        logger.error(f"❌ Provision error: {e}")
        response = jsonify({'error': str(e)})
        return add_cors_headers(response), 500

@app.route('/status', methods=['GET'])
def status():
    """Check provisioning status"""
    response = jsonify({
        'status': 'provisioning' if current_provision["token"] else 'idle',
        'current_provision': {
            'device_name': current_provision.get("device_name"),
            'ssid': current_provision.get("ssid"),
            'received_at': current_provision.get("received_at")
        }
    })
    return add_cors_headers(response)

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    response = jsonify({'status': 'ok'})
    return add_cors_headers(response)

if __name__ == '__main__':
    logger.info("🟢 EVVOS Provisioning Server starting...")
    logger.info(f"Listening on 0.0.0.0:5000")
    logger.info(f"Supabase URL: {SUPABASE_URL}")
    
    app.run(host='0.0.0.0', port=5000, debug=False, threaded=True)

FLASK_APP_EOF

chmod +x "$APP_DIR/app.py"
log_success "Provisioning server created"

# ============================================================================
# 6. CREATE HOTSPOT CONFIGURATION SCRIPTS
# ============================================================================
log_info "Creating hotspot scripts..."

# Script to enable AP mode
cat > "$SCRIPTS_DIR/start_ap.sh" << 'AP_START_EOF'
#!/bin/bash
set -e  # Exit on error

# Enable forwarding and NAT
sysctl -w net.ipv4.ip_forward=1 || true
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true
iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT 2>/dev/null || true

# Save iptables rules
mkdir -p /etc/iptables
sh -c "iptables-save > /etc/iptables/rules.v4" 2>/dev/null || true

# Bring down wlan0 and configure AP
ip link set wlan0 down 2>/dev/null || true
sleep 1
ip addr flush dev wlan0 2>/dev/null || true
ip addr add 192.168.4.1/24 dev wlan0 || true
ip link set wlan0 up || true

# Start hostapd and dnsmasq
systemctl start hostapd 2>/dev/null || echo "Warning: hostapd failed to start"
systemctl start dnsmasq 2>/dev/null || echo "Warning: dnsmasq failed to start"

echo "✅ AP Mode started (EVVOS_0001 at 192.168.4.1)"

AP_START_EOF

chmod +x "$SCRIPTS_DIR/start_ap.sh"

# Script to disable AP mode and connect to WiFi
cat > "$SCRIPTS_DIR/stop_ap.sh" << 'AP_STOP_EOF'
#!/bin/bash
set -e  # Exit on error

# Stop AP services
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

# Reset wlan0
ip addr flush dev wlan0 2>/dev/null || true
ip link set wlan0 down 2>/dev/null || true

# Re-enable wpa_supplicant
systemctl restart wpa_supplicant@wlan0 2>/dev/null || true
systemctl restart networking 2>/dev/null || true

echo "✅ AP Mode stopped, connecting to WiFi..."

AP_STOP_EOF

chmod +x "$SCRIPTS_DIR/stop_ap.sh"

log_success "Hotspot scripts created"

# Script to connect to hotspot (called after credentials received)
cat > "$SCRIPTS_DIR/connect_to_hotspot.sh" << 'HOTSPOT_CONNECT_EOF'
#!/bin/bash
set -e  # Exit on error

# Called after receiving WiFi/hotspot credentials from mobile device
# Attempts to connect to the hotspot SSID with max 20 retries
# If fails after 20 tries, goes back to AP mode

SSID="$1"
PASSWORD="$2"
MAX_RETRIES=20
RETRY_DELAY=5

if [ -z "$SSID" ] || [ -z "$PASSWORD" ]; then
    echo "[EVVOS] ❌ Error: SSID and PASSWORD required"
    exit 1
fi

echo "[EVVOS] 🔵 Switching from AP mode to WiFi mode..."
echo "[EVVOS] Target SSID: $SSID"

# Stop AP mode services
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
echo "[EVVOS] Stopped AP mode"

# Reset wlan0
ip addr flush dev wlan0 2>/dev/null || true
ip link set wlan0 down 2>/dev/null || true
sleep 2
ip link set wlan0 up 2>/dev/null || true
echo "[EVVOS] Reset wlan0"

# Write WiFi credentials to wpa_supplicant
echo "[EVVOS] 📝 Configuring WiFi credentials..."
mkdir -p /etc/wpa_supplicant
cat > /etc/wpa_supplicant/wpa_supplicant.conf << WPAEOF
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
    ssid="$SSID"
    psk="$PASSWORD"
    priority=1
}
WPAEOF

chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf

# Enable wpa_supplicant
systemctl enable wpa_supplicant@wlan0 2>/dev/null || true
systemctl start wpa_supplicant@wlan0 2>/dev/null || true
echo "[EVVOS] Started wpa_supplicant"

# Try to connect up to 20 times
echo "[EVVOS] 🔄 Attempting WiFi connection (max $MAX_RETRIES tries)..."

for ((i = 1; i <= MAX_RETRIES; i++)); do
    echo "[EVVOS] Attempt $i/$MAX_RETRIES..."
    
    sleep $RETRY_DELAY
    
    # Check if connected to SSID
    CURRENT_SSID=$(wpa_cli -i wlan0 status 2>/dev/null | grep "^ssid=" | cut -d'=' -f2 || echo "")
    
    if [ "$CURRENT_SSID" = "$SSID" ]; then
        echo "[EVVOS] ✅ Connected to hotspot: $SSID"
        
        # Check for internet connectivity
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            echo "[EVVOS] ✅ Internet connectivity confirmed!"
            echo "[EVVOS] 🎉 Provisioning successful!"
            exit 0
        else
            echo "[EVVOS] Connected to SSID but no internet yet (attempt $i)"
        fi
    else
        echo "[EVVOS] Not yet connected. Current SSID: ${CURRENT_SSID:-none}"
    fi
done

# If we get here, connection failed after 20 attempts
echo "[EVVOS] ❌ Failed to connect after $MAX_RETRIES attempts"
echo "[EVVOS] 🔴 Returning to AP mode..."

# Return to AP mode
systemctl stop wpa_supplicant@wlan0 2>/dev/null || true
systemctl disable wpa_supplicant@wlan0 2>/dev/null || true
ip addr flush dev wlan0 2>/dev/null || true
ip link set wlan0 down 2>/dev/null || true
sleep 2
ip link set wlan0 up 2>/dev/null || true
ip addr add 192.168.4.1/24 dev wlan0 || true

systemctl start hostapd 2>/dev/null || true
systemctl start dnsmasq 2>/dev/null || true

echo "[EVVOS] ✅ Back in AP mode. Waiting for new provisioning..."
exit 1

HOTSPOT_CONNECT_EOF

chmod +x "$SCRIPTS_DIR/connect_to_hotspot.sh"

log_success "Hotspot connection script created"

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
User=root
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
set -e  # Exit on error

# EVVOS Boot Sequence
# 1. Check for saved WiFi credentials
# 2. If credentials exist: Try to connect to saved WiFi
# 3. If no credentials: Start AP mode (EVVOS_0001) for new provisioning

sleep 2  # Wait for system to stabilize

WIFI_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"

echo "[EVVOS] 🔵 Checking for saved WiFi credentials..."

# Check if wpa_supplicant config exists and has network config
if [ -f "$WIFI_CONF" ] && grep -q "^network=" "$WIFI_CONF"; then
    echo "[EVVOS] ✅ Found saved WiFi credentials"
    echo "[EVVOS] 🔄 Attempting to connect to saved network..."
    
    # Enable wpa_supplicant
    systemctl enable wpa_supplicant@wlan0 2>/dev/null || true
    systemctl start wpa_supplicant@wlan0 2>/dev/null || true
    
    # Wait for connection (up to 30 seconds)
    for i in {1..30}; do
        STATE=$(wpa_cli -i wlan0 status 2>/dev/null | grep "^wpa_state=" | cut -d'=' -f2 || echo "")
        
        if [ "$STATE" = "COMPLETED" ]; then
            echo "[EVVOS] ✅ Connected to saved WiFi!"
            
            # Check for internet
            if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
                echo "[EVVOS] ✅ Internet connectivity confirmed!"
                exit 0
            fi
        fi
        
        sleep 1
    done
    
    echo "[EVVOS] ⚠️  Failed to connect to saved WiFi, falling back to AP mode..."
fi

# No saved credentials or connection failed: Start AP mode
echo "[EVVOS] 🔵 Starting AP mode (EVVOS_0001) for provisioning..."

# Disable WiFi client mode
systemctl stop wpa_supplicant@wlan0 2>/dev/null || true
systemctl disable wpa_supplicant@wlan0 2>/dev/null || true

# Start AP mode
/opt/evvos/scripts/start_ap.sh || echo "[EVVOS] Warning: AP mode script encountered errors"

echo "[EVVOS] ✅ AP mode started. Waiting for provisioning credentials..."

BOOT_EOF

chmod +x "$SCRIPTS_DIR/evvos_boot.sh"

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
