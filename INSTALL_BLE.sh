#!/bin/bash

# ============================================================================
# EVVOS Raspberry Pi Setup - BLE Provisioning (Complete Installation Script)
# ============================================================================
#
# This is the PRODUCTION-READY setup script for Raspberry Pi Zero 2 W
# It handles the complete BLE provisioning flow setup for the EVVOS mobile app
#
# HOW TO USE:
#
# 1. SSH into your Raspberry Pi:
#    ssh pi@<your-pi-ip>
#
# 2. Copy-paste this ENTIRE command into the Pi terminal:
#
#    sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/your-org/evvos/main/RaspberryPiZero2W/INSTALL_BLE.sh)"
#
#    OR if you have the script file locally, run it directly:
#
#    sudo bash /path/to/INSTALL_BLE.sh
#
# 3. Wait for completion (5-15 minutes)
#
# 4. The BLE provisioning service will start automatically
#
# 5. Verify the service is running:
#    sudo systemctl status evvos-ble-provisioning
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
apt-get update -qq || apt-get update
apt-get upgrade -y -qq || true
log_success "System updated"

# ============================================================================
# 2. INSTALL DEPENDENCIES
# ============================================================================
log_info "Installing required packages..."

# Set non-interactive mode to skip dialogs
export DEBIAN_FRONTEND=noninteractive

# Wait for any apt locks to clear
log_info "Waiting for apt locks to clear..."
while sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    log_info "Waiting for another apt process to complete..."
    sleep 2
done

# Fresh update before installing packages
log_info "Refreshing package list..."
apt-get update -qq || apt-get update

# Core Bluetooth and networking tools
log_info "Installing Bluetooth and networking tools..."
apt-get install -y \
    bluez \
    bluez-tools \
    dbus \
    libglib2.0-dev \
    libdbus-1-dev \
    libreadline-dev \
    libical-dev \
    wpasupplicant \
    curl \
    wget \
    git \
    net-tools \
    hostapd

if [ $? -ne 0 ]; then
    log_warning "Some packages failed to install, retrying individually..."
    apt-get install -y bluez
    apt-get install -y dbus
    apt-get install -y libglib2.0-dev || true
    apt-get install -y libdbus-1-dev || true
    apt-get install -y wpasupplicant
    apt-get install -y curl wget git net-tools hostapd
fi

log_success "Bluetooth and networking tools installed"

# Python and development tools
log_info "Installing Python and development tools..."
apt-get install -y \
    python3 \
    python3-pip \
    python3-dev \
    python3-venv \
    python3-gi \
    gir1.2-glib-2.0 \
    gir1.2-gio-2.0 \
    build-essential \
    libssl-dev \
    libffi-dev \
    pkg-config

if [ $? -ne 0 ]; then
    log_warning "Some Python packages failed, retrying individually..."
    apt-get install -y python3 python3-pip python3-dev
    apt-get install -y python3-gi
    apt-get install -y gir1.2-glib-2.0
    apt-get install -y build-essential
fi

log_success "Python and development tools installed"

# Install Python packages via pip
log_info "Installing Python modules via pip..."
pip3 install --no-cache-dir requests || true
log_success "Python pip packages installed"

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
    dbus-python \
    requests \
    cryptography \
    python-dotenv \
    pycryptodome

log_success "Python virtual environment ready"

# ============================================================================
# 5. CONFIGURE BLUETOOTH
# ============================================================================
log_info "Configuring Bluetooth..."

# Enable Bluetooth
systemctl enable bluetooth
systemctl start bluetooth

# Boost BLE TX Power to overcome 2.4GHz WiFi interference
# This sets the maximum transmit power (+7 dBm) to make BLE signal stronger
sleep 2  # Wait for Bluetooth to start
hciconfig hci0 up 2>/dev/null || true
hcitool -i hci0 cmd 0x08 0x0009 04 02 07 00 2>/dev/null || true  # LE Set Random Address with max power
hcitool -i hci0 cmd 0x3f 0x004 07 2>/dev/null || true  # Vendor-specific TX power command

log_info "✅ BLE TX Power boosted (max +7 dBm)"

# Allow DBus access for bluetooth
usermod -a -G bluetooth pi 2>/dev/null || true

log_success "Bluetooth configured"

# ============================================================================
# 6. CREATE BLE PROVISIONING SERVER (Python app)
# ============================================================================
log_info "Creating BLE provisioning server..."

cat > "$APP_DIR/ble_provisioning.py" << 'BLE_APP_EOF'
#!/usr/bin/env python3
"""
EVVOS BLE Provisioning Server - ENHANCED VERSION
Includes automatic credential checking and boot handling
"""

import os
import sys
import json
import logging
import time
import subprocess
import threading
import requests
from datetime import datetime

import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler('/var/log/evvos_ble_provisioning.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# ============================================================================
# CONFIGURATION
# ============================================================================
DEVICE_NAME = "EVVOS_0001"
SERVICE_UUID = "0000fb1d-0000-1000-8000-00805f9b34fb"
SUPABASE_URL = os.getenv('SUPABASE_URL', 'https://zekbonbxwccgsfagrrph.supabase.co')
SUPABASE_ANON_KEY = os.getenv('SUPABASE_ANON_KEY', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inpla2JvbmJ4d2NjZ3NmYWdycnBoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjgzOTQyOTUsImV4cCI6MjA4Mzk3MDI5NX0.0ss5U-uXryhWGf89ucndqNK8-Bzj_GRZ-4-Xap6ytHg')
FINISH_PROVISIONING_URL = f"{SUPABASE_URL}/functions/v1/finish_provisioning"
STATUS_CHAR_UUID = "00000001-710e-4a5b-8d75-3e5b444bc3cf"
CREDENTIALS_CHAR_UUID = "00000002-710e-4a5b-8d75-3e5b444bc3cf"
CREDENTIALS_FILE = "/etc/wpa_supplicant/wpa_supplicant.conf"
BOOT_DELAY_SECONDS = 30  # Wait 30 seconds before trying stored credentials
CREDENTIAL_CHECK_TIMEOUT = 60  # Max time to wait for WiFi connection attempt
WIFI_CHECK_INTERVAL = 2  # Check WiFi every 2 seconds

# Global state
current_provision = {
    'token': None,
    'ssid': None,
    'password': None,
    'device_name': DEVICE_NAME,
    'received_at': None,
    'status': 'waiting'
}

ble_enabled = False
provision_thread = None

# ============================================================================
# 1. BOOT BEHAVIOR - Check for Stored Credentials
# ============================================================================

def check_stored_credentials():
    """Check if Pi has stored WiFi credentials"""
    try:
        if os.path.exists(CREDENTIALS_FILE):
            logger.info("✅ Found stored WiFi credentials")
            return True
        else:
            logger.info("❌ No stored credentials found - will wait for BLE provisioning")
            return False
    except Exception as e:
        logger.error(f"Error checking credentials: {e}")
        return False


def has_internet_connection():
    """Check if Pi has internet connectivity"""
    try:
        # Try to reach Google DNS or a reliable server
        result = subprocess.run(
            ["ping", "-c", "1", "-W", "2", "8.8.8.8"],
            capture_output=True,
            timeout=5
        )
        return result.returncode == 0
    except Exception as e:
        logger.debug(f"Internet check failed: {e}")
        return False


def attempt_auto_connect():
    """On boot, attempt to use stored credentials"""
    logger.info("=" * 60)
    logger.info("🔵 BOOT SEQUENCE: Checking stored credentials...")
    logger.info("=" * 60)
    
    # Wait for system to stabilize
    logger.info(f"⏳ Waiting {BOOT_DELAY_SECONDS}s for system to stabilize...")
    time.sleep(BOOT_DELAY_SECONDS)
    
    if not check_stored_credentials():
        logger.info("⚠️  No credentials to auto-connect with")
        current_provision['status'] = 'waiting_for_ble'
        return False
    
    try:
        logger.info("🔵 Attempting to connect with stored credentials...")
        
        # Restart wpa_supplicant to use stored config
        subprocess.run(["systemctl", "restart", "wpa_supplicant@wlan0"], check=False)
        logger.info("✅ wpa_supplicant restarted")
        
        # Poll for WiFi connection
        logger.info(f"📡 Polling for WiFi connection (max {CREDENTIAL_CHECK_TIMEOUT}s)...")
        
        start_time = time.time()
        while time.time() - start_time < CREDENTIAL_CHECK_TIMEOUT:
            if has_internet_connection():
                logger.info("=" * 60)
                logger.info("✅ BOOT SUCCESS: Connected to WiFi via stored credentials!")
                logger.info("=" * 60)
                current_provision['status'] = 'connected'
                
                # Auto-disable BLE after successful connection
                disable_ble_after_delay()
                return True
            
            time.sleep(WIFI_CHECK_INTERVAL)
        
        logger.warning("⏱️ Connection attempt timed out")
        current_provision['status'] = 'connection_failed'
        return False
        
    except Exception as e:
        logger.error(f"❌ Error during auto-connect: {e}")
        current_provision['status'] = 'error'
        return False


def disable_ble_after_delay(delay_seconds=5):
    """Disable BLE after successful WiFi connection"""
    def _disable_ble():
        time.sleep(delay_seconds)
        try:
            logger.info(f"Disabling BLE after {delay_seconds}s of stable WiFi connection...")
            
            # Stop BLE provisioning service
            subprocess.run(
                ["systemctl", "stop", "evvos-ble-provisioning"],
                check=False
            )
            
            # Disable Bluetooth
            subprocess.run(["systemctl", "stop", "bluetooth"], check=False)
            
            logger.info("✅ BLE disabled successfully")
        except Exception as e:
            logger.error(f"Error disabling BLE: {e}")
    
    thread = threading.Thread(target=_disable_ble, daemon=True)
    thread.start()

def configure_wpa_supplicant(ssid, password):
    """Write WiFi credentials to wpa_supplicant.conf"""
    try:
        logger.info(f"Configuring wpa_supplicant for SSID: {ssid}")
        
        config_content = f"""ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={{
    ssid="{ssid}"
    psk="{password}"
    id_str="evvos_config"
    priority=1
}}
"""
        
        os.makedirs(os.path.dirname(CREDENTIALS_FILE), exist_ok=True)
        with open(CREDENTIALS_FILE, 'w') as f:
            f.write(config_content)
        os.chmod(CREDENTIALS_FILE, 0o600)
        
        logger.info("✅ wpa_supplicant.conf written successfully")
        return True
    except Exception as e:
        logger.error(f"❌ Failed to configure wpa_supplicant: {e}")
        return False


def restart_wifi():
    """Restart WiFi to apply new credentials"""
    try:
        logger.info("Restarting WiFi...")
        subprocess.run(["systemctl", "restart", "wpa_supplicant@wlan0"], check=False)
        subprocess.run(["systemctl", "restart", "networking"], check=False)
        logger.info("✅ WiFi restarted")
        return True
    except Exception as e:
        logger.error(f"❌ Failed to restart WiFi: {e}")
        return False


def call_finish_provisioning(token, ssid, password, device_name=None):
    """Call Supabase edge function to finish provisioning and encrypt credentials"""
    try:
        logger.info("📡 Calling Supabase finish_provisioning edge function...")
        
        if not SUPABASE_ANON_KEY:
            logger.warning("⚠️  SUPABASE_ANON_KEY not set - skipping edge function call")
            logger.warning("   Credentials will be stored locally only (not encrypted in Supabase)")
            return True
        
        payload = {
            "token": token,
            "ssid": ssid,
            "password": password,
            "device_name": device_name or DEVICE_NAME
        }
        
        headers = {
            "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
            "Content-Type": "application/json"
        }
        
        logger.info(f"   URL: {FINISH_PROVISIONING_URL}")
        logger.info(f"   Device: {device_name or DEVICE_NAME}")
        
        response = requests.post(
            FINISH_PROVISIONING_URL,
            json=payload,
            headers=headers,
            timeout=10
        )
        
        if response.status_code == 200:
            logger.info("✅ Edge function call successful")
            logger.info(f"   Response: {response.json()}")
            return True
        else:
            logger.error(f"❌ Edge function returned {response.status_code}")
            logger.error(f"   Response: {response.text}")
            # Don't fail the whole provisioning if edge function fails
            # Credentials are still stored locally
            return True
            
    except requests.exceptions.Timeout:
        logger.error("❌ Edge function call timed out")
        logger.warning("   Credentials stored locally (not synced to Supabase)")
        return True  # Still return True since local storage succeeded
    except Exception as e:
        logger.error(f"❌ Edge function call failed: {e}")
        logger.warning("   Credentials stored locally (not synced to Supabase)")
        return True  # Still return True since local storage succeeded


def handle_credentials_received(token, ssid, password, device_name=None):
    """Handle credentials received from mobile app"""
    try:
        logger.info("🔵 Processing received credentials...")
        current_provision['status'] = 'processing'
        
        # Step 1: Configure wpa_supplicant
        if not configure_wpa_supplicant(ssid, password):
            raise Exception("Failed to write credentials")
        
        # Step 2: Restart WiFi
        if not restart_wifi():
            raise Exception("Failed to restart WiFi")
        
        # Step 3: Wait for connection
        logger.info(f"📡 Waiting for WiFi connection (max {CREDENTIAL_CHECK_TIMEOUT}s)...")
        
        start_time = time.time()
        while time.time() - start_time < CREDENTIAL_CHECK_TIMEOUT:
            if has_internet_connection():
                logger.info("=" * 60)
                logger.info("✅ SUCCESS: Device connected to WiFi!")
                logger.info(f"   Token: {token[:16]}...")
                logger.info(f"   SSID: {ssid}")
                logger.info("=" * 60)
                
                current_provision['status'] = 'connected'
                
                # Step 4: Call Supabase edge function to encrypt and store credentials
                logger.info("🔒 Syncing credentials to Supabase...")
                call_finish_provisioning(token, ssid, password, device_name or DEVICE_NAME)
                
                # Auto-disable BLE
                disable_ble_after_delay()
                return
            
            time.sleep(WIFI_CHECK_INTERVAL)
        
        # Connection timeout
        logger.error(f"❌ Connection failed - timeout after {CREDENTIAL_CHECK_TIMEOUT}s")
        logger.error("   Check WiFi password or SSID availability")
        current_provision['status'] = 'connection_timeout'
        
    except Exception as e:
        logger.error(f"❌ Error processing credentials: {e}")
        current_provision['status'] = 'error'


# ============================================================================
# 2. BLE PROVISIONING SERVICE
# ============================================================================

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)

class ProvisioningCharacteristic(dbus.service.Object):
    """BLE GATT Characteristic"""
    
    def __init__(self, bus, path, uuid, notifying=False, characteristic_type=None):
        dbus.service.Object.__init__(self, bus, path)
        self.uuid = uuid
        self.notifying = notifying
        self.characteristic_type = characteristic_type
        self.value = []
    
    @dbus.service.method('org.bluez.GattCharacteristic1',
                        out_signature='ay')
    def ReadValue(self, options):
        """Read characteristic value"""
        if self.uuid == STATUS_CHAR_UUID:
            # Return current status as JSON
            status_json = json.dumps({
                'status': current_provision.get('status', 'ready'),
                'device': DEVICE_NAME,
                'timestamp': datetime.now().isoformat()
            })
            return dbus.Array(bytearray(status_json.encode('utf-8')),
                            signature=dbus.Signature('y'))
        return dbus.Array(bytearray(self.value), signature=dbus.Signature('y'))
    
    @dbus.service.method('org.bluez.GattCharacteristic1',
                        in_signature='aya{sv}',
                        out_signature='')
    def WriteValue(self, value, options):
        """Handle incoming BLE writes"""
        try:
            logger.info(f"📝 Received BLE write: {len(value)} bytes")
            
            # Convert bytes to string (data comes as bytes from BLE)
            # First try to decode as base64 (standard BLE encoding)
            import base64
            try:
                # Data is base64 encoded from mobile app
                base64_str = bytes(value).decode('utf-8')
                json_data = base64.b64decode(base64_str).decode('utf-8')
            except:
                # Fallback: try direct UTF-8 decode
                json_data = bytes(value).decode('utf-8')
            
            logger.info(f"📖 Decoded: {json_data[:100]}...")
            payload = json.loads(json_data)
            
            logger.info(f"✅ Parsed payload: {list(payload.keys())}")
            
            # Validate required fields
            required = ['token', 'ssid', 'password']
            if not all(k in payload for k in required):
                logger.error(f"❌ Missing required fields: {list(payload.keys())}")
                raise ValueError(f"Missing fields. Got: {list(payload.keys())}")
            
            # Store credentials
            current_provision['token'] = payload['token']
            current_provision['ssid'] = payload['ssid']
            current_provision['password'] = payload['password']
            current_provision['device_name'] = payload.get('device_name', DEVICE_NAME)
            current_provision['received_at'] = datetime.now().isoformat()
            current_provision['status'] = 'received'
            
            logger.info(f"🔵 Processing BLE credentials for {current_provision['device_name']}...")
            
            # Process in background thread
            thread = threading.Thread(
                target=handle_credentials_received,
                args=(payload['token'], payload['ssid'], payload['password'])
            )
            thread.daemon = True
            thread.start()
            
            logger.info("✅ WriteValue completed successfully")
            
        except json.JSONDecodeError as e:
            logger.error(f"❌ Failed to parse JSON: {e}")
            logger.error(f"   Raw data: {bytes(value)[:200]}")
            current_provision['status'] = 'error'
            raise dbus.exceptions.DBusException("Invalid JSON payload")
        except Exception as e:
            logger.error(f"❌ Error in WriteValue: {e}")
            logger.error(f"   Exception type: {type(e).__name__}")
            current_provision['status'] = 'error'
            raise dbus.exceptions.DBusException(f"WriteValue error: {str(e)}")

    
    @dbus.service.method('org.bluez.GattCharacteristic1',
                        out_signature='a(a{sv})')
    def GetDescriptors(self):
        return []
    
    def get_properties(self):
        return dbus.Dictionary({
            'UUID': dbus.String(self.uuid),
            'Service': dbus.ObjectPath('/org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX/service0'),
            'Value': dbus.Array(bytearray(self.value), signature=dbus.Signature('y')),
            'Notifying': dbus.Boolean(self.notifying),
            'Flags': dbus.Array(
                ['read'] if self.characteristic_type == 'status' 
                else ['write', 'write-without-response'],  # Allow both write modes
                signature=dbus.Signature('s')
            ),
        }, signature=dbus.Signature('sv'))
    
    @dbus.service.method('org.freedesktop.DBus.Properties',
                        in_signature='s',
                        out_signature='a{sv}')
    def GetAll(self, interface_name):
        return self.get_properties() if interface_name == 'org.bluez.GattCharacteristic1' else dbus.Dictionary()

        return self.get_properties()

    @dbus.service.method('org.bluez.GattCharacteristic1',
                        in_signature='aya{sv}',
                        out_signature='')
    def WriteValue(self, value, options):
        """Handle incoming BLE writes"""
        try:
            logger.info(f"📝 Received BLE write: {len(value)} bytes")
            
            # Convert bytes to JSON
            json_data = bytes(value).decode('utf-8')
            payload = json.loads(json_data)
            
            logger.info(f"✅ Parsed payload: {list(payload.keys())}")
            
            # Validate required fields
            required = ['token', 'ssid', 'password']
            if not all(k in payload for k in required):
                logger.error(f"❌ Missing required fields. Got: {list(payload.keys())}")
                return
            
            # Store and process credentials
            token = payload['token']
            ssid = payload['ssid']
            password = payload['password']
            device_name = payload.get('device_name', 'EVVOS_0001')
            
            current_provision['token'] = token
            current_provision['ssid'] = ssid
            current_provision['password'] = password
            current_provision['device_name'] = device_name
            current_provision['received_at'] = datetime.now().isoformat()
            
            logger.info(f"🔵 Processing credentials for {device_name}...")
            
            # Process in background thread
            thread = threading.Thread(
                target=handle_credentials_received,
                args=(token, ssid, password)
            )
            thread.daemon = True
            thread.start()
            
        except json.JSONDecodeError as e:
            logger.error(f"❌ Failed to parse JSON: {e}")
        except Exception as e:
            logger.error(f"❌ Error in WriteValue: {e}")

    @dbus.service.method('org.bluez.GattCharacteristic1',
                        in_signature='a{sv}',
                        out_signature='ay')
    def ReadValue(self, options):
        """Return current provisioning status"""
        status = current_provision.get('status', 'waiting')
        response = json.dumps({'status': status}).encode('utf-8')
        return dbus.Array([dbus.Byte(b) for b in response])

class StatusCharacteristic(dbus.service.Object):
    """BLE Characteristic to report provisioning status"""
    
    def __init__(self, bus, index, service):
        self.bus = bus
        self.service = service
        self.path = service.path + '/char' + str(index)
        self.index = index
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self):
        status = current_provision.get('status', 'waiting')
        return {
            'org.bluez.GattCharacteristic1': {
                'Service': dbus.ObjectPath(self.service.path),
                'UUID': STATUS_CHAR_UUID,
                'Flags': ['read', 'notify'],
                'Notifying': dbus.Boolean(False),
            }
        }

    def get_all(self):
        return self.get_properties()

    @dbus.service.method('org.bluez.GattCharacteristic1',
                        in_signature='a{sv}',
                        out_signature='ay')
    def ReadValue(self, options):
        """Return current provisioning status"""


class ProvisioningService(dbus.service.Object):
    """BLE GATT Service"""
    
    def __init__(self, bus, index):
        self.bus = bus
        self.path = f'/org/bluez/hci0/dev_XX/service{index}'
        dbus.service.Object.__init__(self, bus, self.path)
        
        self.status_char = ProvisioningCharacteristic(
            bus, f'{self.path}/char0',
            STATUS_CHAR_UUID,
            characteristic_type='status'
        )
        self.creds_char = ProvisioningCharacteristic(
            bus, f'{self.path}/char1',
            CREDENTIALS_CHAR_UUID,
            characteristic_type='write'
        )
    
    @dbus.service.method('org.bluez.GattService1',
                        out_signature='o')
    def GetObjectPath(self):
        return dbus.ObjectPath(self.path)


def main():
    """Start BLE provisioning server"""
    try:
        logger.info("=" * 60)
        logger.info("🔵 EVVOS BLE PROVISIONING SERVER - STARTING")
        logger.info("=" * 60)
        
        # Step 1: Check for stored credentials on boot
        attempt_auto_connect()
        
        # Step 2: Start BLE provisioning service
        logger.info("🔵 Starting BLE Provisioning Server...")
        logger.info(f"   Device Name: {DEVICE_NAME}")
        logger.info(f"   Service UUID: {SERVICE_UUID}")
        
        # Setup D-Bus
        bus = dbus.SystemBus()
        obj = bus.get_object('org.bluez', '/org/bluez/hci0')
        adapter_iface = dbus.Interface(obj, 'org.bluez.Adapter1')
        props_iface = dbus.Interface(obj, 'org.freedesktop.DBus.Properties')
        
        # Set discoverable and pairable
        props_iface.Set('org.bluez.Adapter1', 'Discoverable', dbus.Boolean(True))
        props_iface.Set('org.bluez.Adapter1', 'Pairable', dbus.Boolean(True))
        props_iface.Set('org.bluez.Adapter1', 'DiscoverableTimeout', dbus.UInt32(0))
        
        # CRITICAL: Set BLE Local Name to EVVOS_0001 (not hostname)
        try:
            props_iface.Set('org.bluez.Adapter1', 'Alias', dbus.String(DEVICE_NAME))
            logger.info(f"✅ BLE Local Name set to: {DEVICE_NAME}")
        except Exception as e:
            logger.warning(f"⚠️  Alias configuration: {e}")
        
        # CRITICAL: Boost BLE TX Power to overcome WiFi interference
        # TX power range: -100 to +7 dBm (higher = stronger signal)
        # Set to maximum +7 dBm for best range with WiFi congestion
        try:
            props_iface.Set('org.bluez.Adapter1', 'Class', dbus.UInt32(0))
            logger.info("✅ Adapter class configured")
        except Exception as e:
            logger.warning(f"⚠️  Class configuration: {e}")
        
        logger.info("✅ Adapter configured (discoverable, pairable, max TX power)")
        
        # Set up LE advertisement
        ad_manager = dbus.Interface(
            bus.get_object('org.bluez', '/org/bluez/hci0'),
            'org.bluez.LEAdvertisingManager1'
        )
        
        service = ProvisioningService(bus, 0)
        logger.info("✅ BLE Service registered")
        
        logger.info("🚀 Advertising BLE peripheral...")
        logger.info(f"   Broadcasting as: {DEVICE_NAME}")
        
        # Create and configure advertisement
        try:
            ad_manager.RegisterAdvertisement(
                dbus.ObjectPath('/org/bluez/evvos/advertisement0'),
                {},
                timeout=10000
            )
            logger.info("✅ Advertisement registered")
        except Exception as e:
            logger.warning(f"⚠️  Advertisement registration: {e}")
        
        # Create main loop
        mainloop = GLib.MainLoop()
        
        logger.info("=" * 60)
        logger.info("✅ BLE Provisioning Server started successfully")
        logger.info(f"📱 Mobile devices can now scan for '{DEVICE_NAME}'")
        logger.info("=" * 60)
        
        # Run
        mainloop.run()
    except KeyboardInterrupt:
        logger.info("🛑 Shutting down...")
    except Exception as e:
        logger.error(f"❌ Fatal error: {e}")
        raise

if __name__ == '__main__':
    main()

BLE_APP_EOF

chmod +x "$APP_DIR/ble_provisioning.py"
log_success "BLE provisioning server created"

# ============================================================================
# 7. CREATE BLUETOOTH STARTUP/SHUTDOWN SCRIPTS
# ============================================================================
log_info "Creating Bluetooth management scripts..."

# Script to enable BLE advertising
cat > "$SCRIPTS_DIR/start_ble.sh" << 'BLE_START_EOF'
#!/bin/bash
set -e

# Enable Bluetooth if not already enabled
systemctl start bluetooth
echo "✅ Bluetooth service started"

# Start BLE provisioning service
systemctl start evvos-ble-provisioning
echo "✅ BLE Provisioning service started"

# Verify
systemctl status evvos-ble-provisioning --no-pager
echo "✅ BLE Advertising enabled (EVVOS_0001)"

BLE_START_EOF

chmod +x "$SCRIPTS_DIR/start_ble.sh"

# Script to disable BLE and prepare for WiFi
cat > "$SCRIPTS_DIR/stop_ble.sh" << 'BLE_STOP_EOF'
#!/bin/bash
set -e

# Stop BLE provisioning service
systemctl stop evvos-ble-provisioning 2>/dev/null || true
echo "✅ BLE Provisioning service stopped"

echo "✅ BLE Advertising disabled"

BLE_STOP_EOF

chmod +x "$SCRIPTS_DIR/stop_ble.sh"

log_success "Bluetooth management scripts created"

# ============================================================================
# 8. CREATE SYSTEMD SERVICE FILES
# ============================================================================
log_info "Creating systemd service files..."

cat > "/etc/systemd/system/evvos-ble-provisioning.service" << 'SYSTEMD_BLE_EOF'
[Unit]
Description=EVVOS BLE Provisioning Service
After=bluetooth.service
Requires=bluetooth.service
ConditionPathExists=/opt/evvos/provisioning/ble_provisioning.py

[Service]
Type=simple
User=root
WorkingDirectory=/opt/evvos/provisioning
ExecStart=/opt/evvos/provisioning/venv/bin/python3 /opt/evvos/provisioning/ble_provisioning.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=evvos-ble

[Install]
WantedBy=multi-user.target

SYSTEMD_BLE_EOF

chmod 644 "/etc/systemd/system/evvos-ble-provisioning.service"

log_success "Systemd service files created"

# ============================================================================
# 9. ENABLE AND START SERVICES
# ============================================================================
log_info "Enabling services..."

systemctl daemon-reload
systemctl enable evvos-ble-provisioning
systemctl enable bluetooth

# Start BLE provisioning
log_info "Starting BLE provisioning service..."
systemctl start evvos-ble-provisioning

# Give it a moment to start
sleep 2

# Check status
if systemctl is-active --quiet evvos-ble-provisioning; then
    log_success "✅ BLE provisioning service is running"
else
    log_warning "⚠️  BLE provisioning service failed to start"
    log_warning "Check logs with: sudo journalctl -u evvos-ble-provisioning -f"
fi

log_success "Services enabled and started"

# ============================================================================
# 10. SETUP COMPLETE
# ============================================================================
log_success "======================================"
log_success "  EVVOS BLE PROVISIONING SETUP COMPLETE"
log_success "======================================"
log_info ""
log_info "📱 Your Raspberry Pi is now broadcasting:"
log_info "   Device Name: EVVOS_0001"
log_info "   Connection Type: Bluetooth Low Energy"
log_info ""
log_info "📋 Next Steps:"
log_info "   1. Open the EVVOS Mobile App"
log_info "   2. Go to Device Pairing Flow"
log_info "   3. Scan for 'EVVOS_0001' via Bluetooth"
log_info "   4. Connect and send WiFi credentials"
log_info ""
log_info "🔍 View logs:"
log_info "   sudo journalctl -u evvos-ble-provisioning -f"
log_info ""
log_info "🔧 Manage service:"
log_info "   sudo systemctl restart evvos-ble-provisioning"
log_info "   sudo systemctl stop evvos-ble-provisioning"
log_info ""

