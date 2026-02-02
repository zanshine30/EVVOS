#!/bin/bash
#
# EVVOS Device Provisioning Setup Script - Raspberry Pi Zero 2W
# Bluetooth Classic (RFCOMM) Receiver with Supabase Edge Function Integration
#
# Usage: sudo bash evvos_setup_fixed.sh
#

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DEVICE_NAME="EVVOS_0001"
LOG_FILE="/var/log/evvos_provision.log"
STATE_FILE="/etc/evvos/device_state.json"
CONFIG_DIR="/etc/evvos"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Setup directories
setup_directories() {
    log_info "Setting up directories..."
    mkdir -p "$CONFIG_DIR" /opt/evvos "$(dirname "$LOG_FILE")"
    chmod 755 "$CONFIG_DIR"
    log_success "Directories created"
}

# Install dependencies
install_dependencies() {
    log_info "Installing dependencies..."
    apt-get update
    apt-get install -y bluez bluez-tools python3 python3-pip curl jq rfcomm bluetooth > /dev/null 2>&1
    pip3 install pybluez requests --quiet
    log_success "Dependencies installed"
}

# Start Bluetooth
start_bluetooth_service() {
    log_info "Starting Bluetooth service..."
    systemctl enable bluetooth
    systemctl start bluetooth
    sleep 2
    if ! hciconfig hci0 | grep -q "UP RUNNING"; then
        hciconfig hci0 up
        sleep 2
    fi
    log_success "Bluetooth started"
}

# Get MAC address
get_device_mac() {
    log_info "Getting device MAC address..."
    DEVICE_MAC=$(hciconfig hci0 | grep "BD Address:" | awk '{print $3}')
    if [ -z "$DEVICE_MAC" ]; then
        log_error "Could not retrieve device MAC"
        exit 1
    fi
    log_success "Device MAC: $DEVICE_MAC"
}

# Configure Bluetooth
configure_bluetooth() {
    log_info "Configuring Bluetooth..."
    hciconfig hci0 name "$DEVICE_NAME"
    bluetoothctl <<EOF
power on
discoverable on
pairable on
EOF
    sleep 1
    log_success "Bluetooth configured"
}

# Create RFCOMM service
setup_rfcomm_service() {
    log_info "Creating RFCOMM systemd service..."
    
    # Get Supabase URL from user or environment
    if [ -z "$SUPABASE_URL" ]; then
        read -p "Enter Supabase URL (e.g., https://xxxxx.supabase.co): " SUPABASE_URL
    fi
    
    if [ -z "$SUPABASE_URL" ]; then
        log_error "SUPABASE_URL cannot be empty"
        exit 1
    fi
    
    cat > /etc/systemd/system/evvos-rfcomm.service << SVCEOF
[Unit]
Description=EVVOS Bluetooth RFCOMM Listener
After=bluetooth.service
Wants=bluetooth.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/evvos/rfcomm_listener.py
Restart=on-failure
RestartSec=10
User=root
Environment="SUPABASE_URL=${SUPABASE_URL}"
Environment="DEVICE_NAME=${DEVICE_NAME}"

[Install]
WantedBy=multi-user.target
SVCEOF
    chmod 644 /etc/systemd/system/evvos-rfcomm.service
    systemctl daemon-reload
    log_success "RFCOMM service created with SUPABASE_URL=${SUPABASE_URL}"
}

# Create RFCOMM listener Python script
create_rfcomm_listener() {
    log_info "Creating RFCOMM listener script..."
    cat > /opt/evvos/rfcomm_listener.py << 'PYEOF'
#!/usr/bin/env python3
import socket, base64, json, logging, subprocess, sys, os, time, requests
from datetime import datetime

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/evvos_rfcomm.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

PORT = 1
BACKLOG = 1
CONFIG_FILE = '/etc/evvos/device_credentials.json'
SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
DEVICE_NAME = os.environ.get('DEVICE_NAME', 'EVVOS_0001')

def listen_for_credentials():
    try:
        logger.info(f"RFCOMM listener starting on port {PORT}...")
        server_sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_sock.bind(('', PORT))
        server_sock.listen(BACKLOG)
        logger.info("✅ RFCOMM listener ready")
        
        while True:
            try:
                client_sock, client_info = server_sock.accept()
                logger.info(f"Client connected: {client_info}")
                data = b''
                client_sock.settimeout(30)
                
                while True:
                    try:
                        chunk = client_sock.recv(1024)
                        if not chunk:
                            break
                        data += chunk
                    except socket.timeout:
                        break
                
                client_sock.close()
                
                if data:
                    logger.info(f"Received {len(data)} bytes")
                    process_payload(data)
                    
            except Exception as e:
                logger.error(f"Connection error: {e}")
                time.sleep(5)
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        sys.exit(1)

def process_payload(data):
    try:
        try:
            decoded = base64.b64decode(data).decode('utf-8')
        except:
            decoded = data.decode('utf-8', errors='ignore')
        
        payload = json.loads(decoded)
        logger.info("✅ Payload parsed")
        
        creds_data = payload.get('data', {})
        ssid = creds_data.get('ssid', '')
        password = creds_data.get('password', '')
        device_name = creds_data.get('device_name', DEVICE_NAME)
        token = payload.get('token', '')
        
        if not all([ssid, password, token]):
            logger.error("Invalid payload: missing fields")
            return
        
        logger.info(f"SSID: {ssid}, Device: {device_name}")
        
        save_creds(ssid, password, device_name, token)
        
        if connect_wifi(ssid, password):
            logger.info("✅ WiFi connected")
            time.sleep(5)
            
            if call_finish_provisioning(token, ssid, password, device_name):
                logger.info("✅ Backend confirmed")
                report_status('online', token)
            else:
                logger.error("Backend confirmation failed")
                report_status('error', token, 'Backend failed')
        else:
            logger.error("WiFi connection failed")
            report_status('error', token, 'WiFi failed')
            
    except json.JSONDecodeError:
        logger.error("JSON parse error")
    except Exception as e:
        logger.error(f"Error: {e}")

def save_creds(ssid, password, device_name, token):
    try:
        with open(CONFIG_FILE, 'w') as f:
            json.dump({
                'ssid': ssid,
                'password': password,
                'device_name': device_name,
                'provisioning_token': token,
                'provisioned_at': datetime.now().isoformat()
            }, f, indent=2)
        os.chmod(CONFIG_FILE, 0o600)
        logger.info("✅ Credentials saved")
    except Exception as e:
        logger.error(f"Save error: {e}")

def connect_wifi(ssid, password):
    try:
        logger.info(f"Connecting to {ssid}...")
        config = f'network={{\n    ssid="{ssid}"\n    psk="{password}"\n    key_mgmt=WPA-PSK\n}}\n'
        
        with open('/etc/wpa_supplicant/wpa_supplicant.conf', 'a') as f:
            f.write(config)
        
        subprocess.run(['systemctl', 'restart', 'wpa_supplicant'], capture_output=True)
        subprocess.run(['dhclient', '-r', 'wlan0'], capture_output=True)
        subprocess.run(['dhclient', 'wlan0'], capture_output=True)
        
        time.sleep(5)
        result = subprocess.run(['ip', 'addr', 'show', 'wlan0'], capture_output=True, text=True)
        
        return 'inet ' in result.stdout
    except Exception as e:
        logger.error(f"WiFi error: {e}")
        return False

def call_finish_provisioning(token, ssid, password, device_name):
    try:
        if not SUPABASE_URL:
            logger.error("SUPABASE_URL not set")
            return False
        
        url = f"{SUPABASE_URL}/functions/v1/finish_provisioning"
        payload = {'token': token, 'ssid': ssid, 'password': password, 'device_name': device_name}
        response = requests.post(url, json=payload, headers={'Content-Type': 'application/json'}, timeout=10)
        
        return response.status_code == 200
    except Exception as e:
        logger.error(f"Finish provisioning error: {e}")
        return False

def report_status(status, token, error_msg=None):
    try:
        if not SUPABASE_URL:
            return
        
        ip_result = subprocess.run(['hostname', '-I'], capture_output=True, text=True)
        ip_address = ip_result.stdout.strip().split()[0] if ip_result.stdout else None
        
        payload = {
            'provisioning_token': token,
            'status': status,
            'ip_address': ip_address,
            'signal_strength': None
        }
        
        if error_msg:
            payload['error_message'] = error_msg
        
        url = f"{SUPABASE_URL}/functions/v1/update_device_status"
        response = requests.post(url, json=payload, headers={'Content-Type': 'application/json'}, timeout=10)
        
        if response.status_code in [200, 201]:
            logger.info(f"✅ Status reported: {status}")
        else:
            logger.error(f"Status report failed: {response.status_code}")
    except Exception as e:
        logger.error(f"Report error: {e}")

if __name__ == '__main__':
    try:
        listen_for_credentials()
    except KeyboardInterrupt:
        logger.info("Shutdown")
    except Exception as e:
        logger.error(f"Fatal: {e}")
        sys.exit(1)
PYEOF
    chmod +x /opt/evvos/rfcomm_listener.py
    log_success "RFCOMM listener created"
}

# Create heartbeat service
create_heartbeat_service() {
    log_info "Creating heartbeat systemd service..."
    
    # Get Supabase URL from user or environment
    if [ -z "$SUPABASE_URL" ]; then
        read -p "Enter Supabase URL (e.g., https://xxxxx.supabase.co): " SUPABASE_URL
    fi
    
    if [ -z "$SUPABASE_URL" ]; then
        log_error "SUPABASE_URL cannot be empty"
        exit 1
    fi
    
    cat > /etc/systemd/system/evvos-heartbeat.service << SVCEOF
[Unit]
Description=EVVOS Device Heartbeat
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/evvos/heartbeat.py
Restart=on-failure
RestartSec=10
User=root
Environment="SUPABASE_URL=${SUPABASE_URL}"
Environment="DEVICE_NAME=${DEVICE_NAME}"

[Install]
WantedBy=multi-user.target
SVCEOF
    chmod 644 /etc/systemd/system/evvos-heartbeat.service
    systemctl daemon-reload
    log_success "Heartbeat service created with SUPABASE_URL=${SUPABASE_URL}"
}

# Create heartbeat Python script
create_heartbeat_script() {
    log_info "Creating heartbeat script..."
    cat > /opt/evvos/heartbeat.py << 'PYEOF'
#!/usr/bin/env python3
import os, subprocess, json, requests, time, logging, re

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[logging.FileHandler('/var/log/evvos_heartbeat.log')]
)
logger = logging.getLogger(__name__)

SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
CONFIG_FILE = '/etc/evvos/device_credentials.json'

def get_token():
    try:
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, 'r') as f:
                return json.load(f).get('provisioning_token')
    except:
        pass
    return None

def get_info():
    try:
        ip_result = subprocess.run(['hostname', '-I'], capture_output=True, text=True)
        ip = ip_result.stdout.strip().split()[0] if ip_result.stdout else None
        
        signal = None
        try:
            iwconfig = subprocess.run(['iwconfig', 'wlan0'], capture_output=True, text=True)
            if 'Signal level' in iwconfig.stdout:
                match = re.search(r'Signal level[^0-9-]*(-?\d+)', iwconfig.stdout)
                if match:
                    signal = int(match.group(1))
        except:
            pass
        
        return {'ip': ip, 'signal': signal}
    except:
        return {}

def send_heartbeat():
    if not SUPABASE_URL:
        return
    
    token = get_token()
    if not token:
        logger.warn("No token found")
        return
    
    try:
        info = get_info()
        payload = {
            'provisioning_token': token,
            'status': 'online',
            'ip_address': info.get('ip'),
            'signal_strength': info.get('signal')
        }
        
        url = f"{SUPABASE_URL}/functions/v1/update_device_status"
        response = requests.post(url, json=payload, headers={'Content-Type': 'application/json'}, timeout=10)
        
        if response.status_code in [200, 201]:
            logger.info(f"✅ Heartbeat: ip={info.get('ip')}")
        else:
            logger.error(f"Heartbeat failed: {response.status_code}")
    except Exception as e:
        logger.error(f"Error: {e}")

if __name__ == '__main__':
    logger.info("Heartbeat service started")
    while True:
        send_heartbeat()
        time.sleep(30)
PYEOF
    chmod +x /opt/evvos/heartbeat.py
    log_success "Heartbeat script created"
}

# Create state file
create_state_file() {
    log_info "Creating state file..."
    cat > "$STATE_FILE" << EOF
{
  "device_name": "$DEVICE_NAME",
  "status": "ready",
  "provisioned": false
}
EOF
    log_success "State file created"
}

# Display summary
display_summary() {
    cat << EOF

${GREEN}╔════════════════════════════════════════════════════════════╗${NC}
${GREEN}║          ✅ EVVOS Setup Complete!                          ║${NC}
${GREEN}╚════════════════════════════════════════════════════════════╝${NC}

${BLUE}Device Configuration:${NC}
  • Device Name: ${DEVICE_NAME}
  • Supabase URL: ${SUPABASE_URL}
  • Log Files: /var/log/evvos_rfcomm.log, /var/log/evvos_heartbeat.log

${BLUE}Next Steps:${NC}

1. Start services automatically:
   ${YELLOW}sudo systemctl daemon-reload${NC}
   ${YELLOW}sudo systemctl enable --now evvos-rfcomm${NC}
   ${YELLOW}sudo systemctl enable --now evvos-heartbeat${NC}

2. Verify services are running:
   ${YELLOW}sudo systemctl status evvos-rfcomm${NC}
   ${YELLOW}sudo systemctl status evvos-heartbeat${NC}

3. Monitor RFCOMM listener:
   ${YELLOW}tail -f /var/log/evvos_rfcomm.log${NC}

4. Verify Bluetooth is ready:
   ${YELLOW}bluetoothctl show${NC}
   ${YELLOW}hciconfig${NC}

${GREEN}✅ Device is ready for Bluetooth provisioning!${NC}
${YELLOW}The RFCOMM listener is waiting for connections on port 1.${NC}

EOF
}

# Main
main() {
    echo -e "${GREEN}EVVOS Device Setup - Raspberry Pi Zero 2W${NC}\n"
    check_root
    setup_directories
    install_dependencies
    start_bluetooth_service
    get_device_mac
    configure_bluetooth
    setup_rfcomm_service
    create_rfcomm_listener
    create_heartbeat_service
    create_heartbeat_script
    create_state_file
    display_summary
}

main
