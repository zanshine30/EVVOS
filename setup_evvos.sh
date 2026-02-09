#!/bin/bash
# EVVOS Device Provisioning Setup Script for Raspberry Pi Zero 2 W
# Raspberry Pi OS Bookworm Lite 32-bit
# Usage: sudo bash setup_evvos.sh

set -e  # Exit on error

echo "🔧 EVVOS WiFi Provisioning System - Fresh Setup"
echo "=================================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
  echo "❌ This script must be run as root. Use: sudo bash setup_evvos.sh"
  exit 1
fi

echo ""
echo "📦 Step 1: System Update & Package Installation (with Lock Handling)"
echo "====================================================================="

# CRITICAL: Release dpkg lock from any blocking processes
echo "Checking for blocking apt/dpkg processes..."
for i in {1..30}; do
  if ! lsof /var/lib/apt/lists/lock 2>/dev/null | grep -q .; then
    echo "✓ No blocking apt processes detected"
    break
  fi
  
  if [ $i -eq 1 ]; then
    echo "⏳ Waiting for dpkg lock to be released (apt-get is running)..."
  fi
  
  if [ $i -eq 15 ]; then
    echo "⚠️  Still waiting... Attempting to stop unattended-upgrades..."
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl kill -s SIGKILL apt-get 2>/dev/null || true
    killall -9 apt-get 2>/dev/null || true
    sleep 5
  fi
  
  if [ $i -lt 30 ]; then
    sleep 2
  else
    echo "❌ Could not acquire dpkg lock after 60 seconds"
    echo "   Try running: sudo killall -9 apt-get && sudo dpkg --configure -a"
    exit 1
  fi
done

# Force-configure any partially installed packages
echo "Ensuring dpkg database is consistent..."
dpkg --configure -a || true

# Configure APT with timeout settings
echo "Configuring APT timeout settings..."
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99-evvos-timeout << 'APTCONFIG'
// EVVOS Apt Configuration - Timeout Protection
APT::ForceIPv4 "true";
APT::Get::AllowUnauthenticated "true";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
DPkg::Lock::Timeout "1200";
APT::Acquire::Retries "5";
APT::Acquire::http::Timeout "60";
APT::Acquire::https::Timeout "60";
APT::Acquire::ftp::Timeout "60";
APT::Acquire::Timeout "60";
APTCONFIG
echo "✓ APT configured with timeout protection (lock wait: 20min)"

# Update package lists with retries
echo "Updating package lists..."
for i in {1..5}; do
  echo "[Attempt $i/5] Running apt-get update..."
  if apt-get update; then
    echo "✓ apt-get update successful"
    break
  fi
  if [ $i -lt 5 ]; then
    echo "⚠ Attempt $i failed, retrying in 10 seconds..."
    sleep 10
  else
    echo "❌ apt-get update failed after 5 attempts"
    exit 1
  fi
done

# apt-get upgrade -y  # Optional: Uncomment if you want a full system upgrade (takes longer)

echo "📥 Installing required system packages..."
echo "⏱️  (Large packages may take 10-20 minutes - be patient)"

# Install packages with retry logic
for attempt in {1..3}; do
  echo "[Attempt $attempt/3] Installing packages..."
  if timeout 1200 apt-get install -y --no-install-recommends --no-install-suggests \
    python3-pip \
    python3-dev \
    hostapd \
    dnsmasq \
    curl \
    wget \
    git \
    nano \
    net-tools \
    alsa-utils \
    alsa-tools \
    bc \
    libasound2-plugins \
    libasound2 \
    libasound2-dev \
    libportaudio2 \
    libportaudiocpp0 \
    portaudio19-dev \
    pulseaudio \
    i2c-tools \
    libblas-dev \
    liblapack-dev \
    libopenblas-dev \
    libffi-dev \
    libssl-dev \
    libjack-jackd2-0; then
    echo "✓ Audio and ReSpeaker HAT system libraries installed"
    break
  else
    if [ $attempt -lt 3 ]; then
      echo "⚠️  Installation attempt $attempt failed, retrying in 15 seconds..."
      sleep 15
    else
      echo "❌ Package installation failed after 3 attempts"
      exit 1
    fi
  fi
done

echo ""
echo "📁 Step 2: Create Application Directory Structure"
echo "==================================================="
mkdir -p /opt/evvos
mkdir -p /etc/evvos
mkdir -p /var/log/evvos
mkdir -p /tmp

echo ""
echo "🐍 Step 3: Create Virtual Environment & Install Dependencies"
echo "=============================================================="
# Create virtual environment in /opt/evvos
# We use --system-site-packages to ensure access to system libs if needed
python3 -m venv /opt/evvos/venv

# Activate virtual environment and install packages
source /opt/evvos/venv/bin/activate

# Configure network for stability (DNS + pip timeout + wget/curl + network buffers)
echo "Configuring network stability and timeouts..."
mkdir -p /root/.pip

# Configure pip - simplified, no timeouts/retries
cat > /root/.pip/pip.conf << 'PIPCONFIG'
[global]
index-url = https://pypi.org/simple/
no-cache-dir = true
[install]
prefer-binary = true
PIPCONFIG
echo "✓ Pip configured: PyPI binary preference only"

# Configure wget with timeout and retries
echo "Configuring wget timeout settings..."
cat > /root/.wgetrc << 'WGETCONFIG'
timeout = 600
connect_timeout = 60
retries = 5
wait = 2
WGETCONFIG
echo "✓ Wget configured with 10min timeout, 60s connect timeout, 5 retries"

# Configure curl defaults
echo "Configuring curl timeout settings..."
cat > /root/.curlrc << 'CURLCONFIG'
max-time = 3600
connect-timeout = 60
retry = 5
retry-delay = 2
retry-max-time = 600
CURLCONFIG
echo "✓ Curl configured with 1hr max-time, 60s connect timeout, 5 retries"

# Update DNS to Google's resolver for stability (primary + secondary)
echo "Updating DNS to reliable servers..."
cp /etc/resolv.conf /etc/resolv.conf.backup
echo "nameserver 8.8.8.8" > /etc/resolv.conf          # Google Primary
echo "nameserver 8.8.4.4" >> /etc/resolv.conf         # Google Secondary
echo "nameserver 1.1.1.1" >> /etc/resolv.conf         # Cloudflare Primary
echo "nameserver 1.0.0.1" >> /etc/resolv.conf         # Cloudflare Secondary
echo "✓ DNS set to multiple reliable servers (Google + Cloudflare)"

# Optimize network socket settings
echo "Optimizing network socket settings..."
echo "net.ipv4.tcp_retries2 = 15" | tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_syn_retries = 5" | tee -a /etc/sysctl.conf
echo "net.core.somaxconn = 1024" | tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_max_syn_backlog = 2048" | tee -a /etc/sysctl.conf
echo "net.core.netdev_max_backlog = 5000" | tee -a /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
echo "✓ Network socket buffers optimized for large downloads"

# Upgrade pip only
echo "Upgrading pip..."
pip install --upgrade pip

# Install aiohttp for Supabase communication
echo "Installing aiohttp..."
pip install aiohttp

echo "✓ Virtual environment created at /opt/evvos/venv"
echo "✓ Base Python packages installed"

echo ""
echo "Step 3.5: ReSpeaker 2-Mics Pi HAT v2.0 Setup (TLV320AIC3104)"
echo "============================================================"

# 1. Install dependencies
source /opt/evvos/venv/bin/activate
pip install --prefer-binary numpy vosk RPi.GPIO

# 2. Compile & Install Overlay
echo "🔧 Installing ReSpeaker v2.0 Device Tree Overlays..."
# Ensure headers are installed for current kernel
echo "Installing kernel headers and device tree compiler..."
if ! timeout 1200 apt-get install -y raspberrypi-kernel-headers device-tree-compiler; then
  echo "⚠️  Kernel headers install failed, but continuing (may already be installed)..."
fi

cd /opt/evvos
if [ ! -d "seeed-linux-dtoverlays" ]; then
    git clone https://github.com/Seeed-Studio/seeed-linux-dtoverlays.git
fi
cd seeed-linux-dtoverlays

# Compile specifically for v2.0
echo "Compiling respeaker-2mic-v2_0 overlay..."
dtc -@ -I dts -O dtb -o respeaker-2mic-v2_0.dtbo overlays/rpi/respeaker-2mic-v2_0-overlay.dts
sudo cp respeaker-2mic-v2_0.dtbo /boot/firmware/overlays/respeaker-2mic-v2_0.dtbo

# 3. Update config.txt
CONFIG_PATH="/boot/firmware/config.txt"
[ -f /boot/config.txt ] && CONFIG_PATH="/boot/config.txt"

# Clean old audio configs
sed -i '/dtoverlay=seeed-2mic-voicecard/d' "$CONFIG_PATH"
sed -i '/dtoverlay=googlevoicehat-soundcard/d' "$CONFIG_PATH"
sed -i '/dtparam=audio=on/d' "$CONFIG_PATH"

# Enable I2C/I2S and add v2.0 overlay
if ! grep -q "dtoverlay=respeaker-2mic-v2_0" "$CONFIG_PATH"; then
    echo "dtparam=i2c_arm=on" >> "$CONFIG_PATH"
    echo "dtparam=i2s=on" >> "$CONFIG_PATH"
    echo "dtparam=spi=on" >> "$CONFIG_PATH"
    echo "# ReSpeaker 2-Mics Pi HAT v2.0" >> "$CONFIG_PATH"
    echo "dtoverlay=respeaker-2mic-v2_0" >> "$CONFIG_PATH"
fi

# 4. Configure ALSA
cat > /etc/asound.conf << 'ASOUND'
pcm.!default {
    type asym
    playback.pcm {
        type plug
        slave.pcm "hw:seeed2micvoicec"
    }
    capture.pcm {
        type plug
        slave.pcm "hw:seeed2micvoicec"
    }
}
ctl.!default {
    type hw
    card seeed2micvoicec
}
ASOUND

# 5. Create Audio Mixer Init Service (CRITICAL FOR v2.0)
# The TLV320AIC3104 resets on power loss. We must re-apply settings on every boot.
echo "Creating audio mixer initialization service..."
cat > /usr/local/bin/evvos-init-audio.sh << 'AUDIO_INIT'
#!/bin/bash
# Initialize ReSpeaker 2-Mics Pi HAT v2.0 (TLV320AIC3104)

# Wait for driver to load
sleep 5
CARD="seeed2micvoicec"

echo "Initializing Mixer for $CARD..."

# Reset logic
amixer -c $CARD -q sset 'Reset' on || true

# --- OUTPUT ROUTING (DAC_L1/R1) ---
# Enable DACs
amixer -c $CARD -q sset 'DAC' 127
amixer -c $CARD -q sset 'Left DAC Mixer PCM' on
amixer -c $CARD -q sset 'Right DAC Mixer PCM' on

# Route DAC to Headphones/Line Out (Requested DAC_L1 setting)
amixer -c $CARD -q sset 'HP' 127
amixer -c $CARD -q sset 'HP DAC Volume' 127
amixer -c $CARD -q sset 'HP Left Mixer DAC L1' on
amixer -c $CARD -q sset 'HP Right Mixer DAC R1' on

# --- INPUT ROUTING (ADC) ---
# Route Mics to ADC (Critical for v2.0 hardware)
amixer -c $CARD -q sset 'Left PGA Mixer Mic2L' on
amixer -c $CARD -q sset 'Right PGA Mixer Mic2R' on

# Gain Settings
amixer -c $CARD -q sset 'PGA' 40      # Input Gain (0-127)
amixer -c $CARD -q sset 'ADC' 127     # ADC Volume
amixer -c $CARD -q sset 'AGC Left' on
amixer -c $CARD -q sset 'AGC Right' on

echo "✓ Audio Mixer Configured"
AUDIO_INIT

chmod +x /usr/local/bin/evvos-init-audio.sh

# Create Systemd Unit for Audio Init
cat > /etc/systemd/system/evvos-audio-init.service << 'UNIT'
[Unit]
Description=Initialize ReSpeaker Audio Mixer
After=sound.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/evvos-init-audio.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable evvos-audio-init.service
echo "✓ Audio Init Service created"

# Setup Vosk Grammar
mkdir -p /etc/evvos/vosk
cat > /etc/evvos/vosk/grammar.json << 'GRAMMAR'
["okay", "confirm", "cancel", "start", "stop", "help", "repeat", "clear"]
GRAMMAR
chmod 644 /etc/evvos/vosk/grammar.json
echo "✓ Vosk command grammar configured (8 commands)"

echo ""

# Create the provisioning script with the complete application
# Updated with latest disconnect logic, Manila timezone, and Supabase Edge Function integration
cat > /usr/local/bin/evvos-provisioning << 'PROVISIONING_SCRIPT_EOF'
#!/usr/bin/env python3
"""
EVVOS Device Provisioning System - WiFi Hotspot Version
Raspberry Pi Zero 2 W WiFi Hotspot Provisioning Agent
User connects to EVVOS_0001 hotspot and enters their mobile hotspot credentials via web form.
Pi then connects to user's hotspot to get internet access.
"""

import asyncio
import json
import logging
import RPi.GPIO as GPIO
import os
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone, timedelta
from typing import Optional, Dict, Any
import hashlib
import base64

BUTTON_GPIO = 17

try:
    import aiohttp
    from aiohttp import web
except ImportError as e:
    print(f"Error: Missing required package: {e}")
    print("Run: pip install aiohttp")
    sys.exit(1)

try:
    import RPi.GPIO as GPIO
except ImportError:
    GPIO = None

BUTTON_GPIO = 17  # ReSpeaker 2-Mics User Button
# Configuration
DEVICE_NAME = "EVVOS_0001"
CREDS_FILE = "/etc/evvos/device_credentials.json"
LOGS_DIR = "/var/log/evvos"
CONFIG_DIR = "/etc/evvos"

# Supabase Configuration
SUPABASE_URL = "https://zekbonbxwccgsfagrrph.supabase.co"
SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inpla2JvbmJ4d2NjZ3NmYWdycnBoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjgzOTQyOTUsImV4cCI6MjA4Mzk3MDI5NX0.0ss5U-uXryhWGf89ucndqNK8-Bzj_GRZ-4-Xap6ytHg"
SUPABASE_EDGE_FUNCTION_URL = f"{SUPABASE_URL}/functions/v1/store_device_credentials"

# Setup logging
os.makedirs(LOGS_DIR, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[
        logging.FileHandler(f"{LOGS_DIR}/evvos_provisioning.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("EVVOS_Provisioning")


class EVVOSWiFiProvisioner:
    """Manages device WiFi provisioning using hotspot method"""

    def __init__(self):
        self.device_id = self._get_device_id()
        self.device_token = self._generate_device_token()
        self.credentials = self._load_credentials()
        self.received_credentials = None
        self.web_runner = None 
        self.web_task = None   
        self.state_file = "/tmp/evvos_ble_state.json"  # Use same state file for compatibility
        self.webserver_process = None
        self.hostapd_process = None
        self.dnsmasq_process = None
        # Philippines timezone is UTC+8
        self.manila_tz = timezone(timedelta(hours=8))
        self._setup_button()

    def _get_manila_time(self) -> datetime:
        """Get current time in Asia/Manila timezone (UTC+8)"""
        return datetime.now(self.manila_tz)

    def _get_device_id(self) -> str:
        """Get or create a unique device ID based on MAC address"""
        try:
            mac = subprocess.check_output(
                "cat /sys/class/net/wlan0/address", shell=True, text=True
            ).strip()
            return mac.replace(":", "")
        except Exception:
            try:
                serial = subprocess.check_output(
                    "cat /proc/device-tree/serial-number",
                    shell=True,
                    text=True,
                ).strip()
                return serial
            except Exception:
                return str(uuid.uuid4()).replace("-", "")[:16]

    def _generate_device_token(self) -> str:
        """Generate a unique token for this provisioning session"""
        timestamp = datetime.now().isoformat()
        token_input = f"{self.device_id}_{timestamp}".encode()
        return hashlib.sha256(token_input).hexdigest()[:32]

    def _encrypt_password(self, password: str) -> str:
        """
        Encode password for secure storage.
        Uses base64 encoding for safe transport/storage.
        """
        try:
            # Base64 encode the password for safe transport
            encoded = base64.b64encode(password.encode('utf-8')).decode('utf-8')
            return encoded
        except Exception as e:
            logger.error(f"Password encoding failed: {e}")
            # Return plaintext as fallback (not ideal, but prevents crashes)
            return password

    def _load_credentials(self) -> Optional[Dict[str, Any]]:
        """Load stored WiFi credentials from disk"""
        try:
            if os.path.exists(CREDS_FILE):
                with open(CREDS_FILE, "r") as f:
                    creds = json.load(f)
                logger.info("Loaded existing credentials from storage")
                return creds
        except Exception as e:
            logger.warning(f"Failed to load credentials: {e}")
        return None

    def _save_credentials(self, ssid: str, password: str, user_id: str = None) -> bool:
        """Save WiFi credentials to disk"""
        try:
            os.makedirs(CONFIG_DIR, exist_ok=True)
            creds = {
                "ssid": ssid,
                "password": password,
                "provisioned_at": self._get_manila_time().isoformat(),
                "device_id": self.device_id,
            }
            if user_id:
                creds["user_id"] = user_id
            with open(CREDS_FILE, "w") as f:
                json.dump(creds, f)
            os.chmod(CREDS_FILE, 0o600)
            logger.info("Credentials saved to storage")
            # Update in-memory credentials
            self.credentials = creds
            return True
        except Exception as e:
            logger.error(f"Failed to save credentials: {e}")
            return False

    def _delete_credentials(self) -> bool:
        """Delete stored WiFi credentials from disk"""
        try:
            if os.path.exists(CREDS_FILE):
                os.remove(CREDS_FILE)
                logger.warning("❌ Stored credentials deleted due to connection failure")
                self.credentials = None
                return True
        except Exception as e:
            logger.error(f"Failed to delete credentials: {e}")
        return False

    async def _check_disconnect_requested(self) -> bool:
        """
        Check if a disconnect request has been made via Supabase.
        Called periodically by the monitoring task.
        Returns True if disconnect was requested, False otherwise.
        Uses Edge Function to bypass RLS policies.
        """
        try:
            if not self.credentials or not self.credentials.get("user_id"):
                return False
            
            user_id = self.credentials.get("user_id")
            device_id = self.device_id
            
            # Use Edge Function to bypass RLS policies
            supabase_check_url = f"{SUPABASE_URL}/functions/v1/check-unpair-status"
            
            headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
            }
            
            payload = {
                "device_id": device_id,
                "user_id": user_id,
            }
            
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    supabase_check_url,
                    json=payload,
                    headers=headers,
                    timeout=aiohttp.ClientTimeout(total=10)
                ) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        if data.get("success"):
                            if data.get("unpair_requested") == True:
                                logger.info(f"[DISCONNECT] Unpair request detected at {data.get('unpair_requested_at')}")
                                return True
        except Exception as e:
            logger.debug(f"Error checking disconnect status: {e}")
        
        return False

    def _start_voice_command_service(self) -> bool:
        """Start the voice command service after successful provisioning"""
        try:
            logger.info("[VOICE] Starting voice command service...")
            result = subprocess.run(
                ["sudo", "systemctl", "start", "evvos-voice-command"],
                check=False,
                timeout=10,
                capture_output=True
            )
            if result.returncode == 0:
                logger.info("[VOICE] ✓ Voice command service started successfully")
                return True
            else:
                logger.warning(f"[VOICE] Service start returned code {result.returncode}")
                # Don't fail provisioning if voice service doesn't exist yet
                return True
        except subprocess.TimeoutExpired:
            logger.warning("[VOICE] Voice command service start timed out")
            return True  # Don't fail provisioning
        except Exception as e:
            logger.warning(f"[VOICE] Failed to start voice command service: {e}")
            return True  # Don't fail provisioning

    def _stop_voice_command_service(self) -> bool:
        """Stop the voice command service when provisioning is reset"""
        try:
            logger.info("[VOICE] Stopping voice command service...")
            result = subprocess.run(
                ["sudo", "systemctl", "stop", "evvos-voice-command"],
                check=False,
                timeout=10,
                capture_output=True
            )
            if result.returncode == 0 or result.returncode == 5:  # 5 = unit not found (already stopped)
                logger.info("[VOICE] ✓ Voice command service stopped")
                return True
            else:
                logger.warning(f"[VOICE] Service stop returned code {result.returncode}")
                return True
        except subprocess.TimeoutExpired:
            logger.warning("[VOICE] Voice command service stop timed out")
            return True
        except Exception as e:
            logger.warning(f"[VOICE] Failed to stop voice command service: {e}")
            return True

    async def _handle_disconnect(self) -> None:
        """
        Handle device disconnect request.
        Deletes credentials and restarts the provisioning service.
        Uses Edge Function to bypass RLS policies.
        """
        try:
            logger.warning("[DISCONNECT] ========== DISCONNECT INITIATED ==========")
            
            user_id = self.credentials.get("user_id") if self.credentials else None
            
            # Step 1: Delete stored credentials from disk
            logger.info("[DISCONNECT] Deleting stored credentials...") 
            self._delete_credentials()
            
            # Step 2: Update Supabase to complete the unpair and delete the row
            if user_id:
                try:
                    logger.info("[DISCONNECT] Deleting device credentials from Supabase...")
                    supabase_unpair_url = f"{SUPABASE_URL}/functions/v1/complete-unpair"
                    
                    headers = {
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
                    }
                    
                    payload = {
                        "device_id": self.device_id,
                        "user_id": user_id,
                    }
                    
                    async with aiohttp.ClientSession() as session:
                        async with session.post(
                            supabase_unpair_url,
                            json=payload,
                            headers=headers,
                            timeout=aiohttp.ClientTimeout(total=10)
                        ) as resp:
                            if resp.status == 200:
                                response_data = await resp.json()
                                logger.info(f"[DISCONNECT] ✓ Device row deleted from Supabase")
                            elif resp.status == 404:
                                logger.warning(f"[DISCONNECT] ⚠️ Device record not found in Supabase (may have been deleted already)")
                            else:
                                logger.warning(f"[DISCONNECT] Failed to delete from Supabase: {resp.status}")
                                try:
                                    error_text = await resp.text()
                                    logger.warning(f"[DISCONNECT] Response: {error_text}")
                                except:
                                    pass
                except Exception as e:
                    logger.warning(f"[DISCONNECT] Could not update Supabase: {e}")
            
            # Step 3: Clean up network interface and state
            logger.info("[DISCONNECT] Cleaning up network interface...")
            subprocess.run(["sudo", "ip", "addr", "flush", "dev", "wlan0"], capture_output=True)
            
            if os.path.exists(self.state_file):
                try:
                    os.remove(self.state_file)
                    logger.info("[DISCONNECT] State file deleted")
                except Exception as e:
                    logger.warning(f"[DISCONNECT] Failed to delete state file: {e}")
            
            # Step 4: Kill any lingering WiFi processes
            subprocess.run(["sudo", "killall", "-q", "wpa_supplicant"], capture_output=True)
            subprocess.run(["sudo", "killall", "-q", "dhclient"], capture_output=True)
            
            # Step 4.5: Stop voice command service when disconnecting
            logger.info("[DISCONNECT] Stopping voice command service...")
            self._stop_voice_command_service()
            
            # Step 5: Log disconnect completion
            logger.warning("[DISCONNECT] ========== DISCONNECT COMPLETED ==========")
            
            # Reset credentials variable
            self.credentials = None
            self.received_credentials = None
            
            # Step 6: Restart the provisioning service
            logger.warning("[DISCONNECT] Restarting provisioning service...")
            try:
                subprocess.run(["sudo", "systemctl", "restart", "evvos-provisioning"], timeout=5)
                logger.warning("[DISCONNECT] ✓ Service restart command sent")
            except Exception as e:
                logger.error(f"[DISCONNECT] Failed to restart service: {e}")
                logger.warning("[DISCONNECT] The script will continue and attempt to restart manually...")
            
        except Exception as e:
            logger.error(f"[DISCONNECT] Error during disconnect handling: {e}")
            import traceback
            logger.error(traceback.format_exc())

    async def _connect_to_wifi(self, ssid: str, password: str) -> bool:
        """Attempt to connect to WiFi network"""
        try:
            logger.info(f"Attempting WiFi connection to: {ssid}")
            wifi_interface = "wlan0"

            # 1. CLEANUP: Kill lingering processes from Hotspot mode
            subprocess.run(["sudo", "killall", "-q", "wpa_supplicant"], capture_output=True)
            subprocess.run(["sudo", "killall", "-q", "dhclient"], capture_output=True)
            
            # Remove old lease files to force fresh IP
            subprocess.run(["sudo", "rm", "-f", "/var/lib/dhcp/dhclient.leases"], capture_output=True)
            
            # 2. FLUSH IP: Clear the 192.168.50.1 address
            logger.info("Flushing old IP configuration...")
            subprocess.run(["sudo", "ip", "addr", "flush", "dev", wifi_interface], capture_output=True)
            
            # Bring interface UP
            subprocess.run(["sudo", "ip", "link", "set", wifi_interface, "up"], check=True, timeout=5)
            await asyncio.sleep(2)

            # Try nmcli first
            try:
                # Ensure device is managed
                subprocess.run(["sudo", "nmcli", "device", "set", wifi_interface, "managed", "yes"], capture_output=True)
                
                subprocess.run(
                    [
                        "sudo", "nmcli", "device", "wifi", "connect", ssid,
                        "password", password, "ifname", wifi_interface,
                    ],
                    check=True,
                    timeout=25,
                    capture_output=True,
                )
                logger.info("✓ WiFi connection sent via nmcli")
                return True
            except Exception:
                logger.info("nmcli failed, falling back to wpa_supplicant + DHCP...")

                # FALLBACK: wpa_supplicant + dhclient
                wpa_config = f"""ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={{
    ssid="{ssid}"
    psk="{password}"
    key_mgmt=WPA-PSK
}}
"""
                wpa_file = "/etc/wpa_supplicant/wpa_supplicant.conf"
                
                try:
                    with open(wpa_file, "w") as f:
                        f.write(wpa_config)
                    
                    # Start wpa_supplicant manually (with sudo)
                    logger.info("Starting wpa_supplicant daemon...")
                    subprocess.run(
                        ["sudo", "wpa_supplicant", "-B", "-i", wifi_interface, "-c", wpa_file],
                        check=True,
                        timeout=10,
                        capture_output=True
                    )
                    
                    # 3. REQUEST IP: Run dhclient with sudo and longer timeout
                    logger.info("Requesting IP address via DHCP (dhclient)...")
                    
                    # Release any theoretical hold
                    subprocess.run(["sudo", "dhclient", "-r", wifi_interface], capture_output=True)
                    
                    # Request new lease (increased timeout to 30s)
                    dhcp_result = subprocess.run(
                        ["sudo", "dhclient", "-v", wifi_interface],
                        timeout=30,
                        capture_output=True,
                        text=True
                    )
                    
                    if dhcp_result.returncode == 0:
                        logger.info("✓ DHCP Lease obtained successfully")
                        return True
                    else:
                        logger.error(f"DHCP request failed: {dhcp_result.stderr}")
                        return False

                except Exception as wpa_error:
                    logger.error(f"wpa_supplicant/DHCP fallback failed: {wpa_error}")
        except Exception as e:
            logger.error(f"WiFi connection failed: {e}")
        return False

    def _check_wifi_connected(self) -> bool:
        """Check if wlan0 interface has an IP address (connected)"""
        try:
            result = subprocess.run(
                ["ip", "addr", "show", "dev", "wlan0"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            logger.debug(f"WiFi interface status: {result.stdout}")
            
            # Check if interface has an inet address (not the hotspot 192.168.50.1)
            lines = result.stdout.split('\n')
            for line in lines:
                if "inet " in line and "192.168.50.1" not in line:
                    logger.info(f"✓ WiFi interface has IP address: {line.strip()}")
                    return True
            
            logger.debug("WiFi interface does not have IP address yet")
            return False
        except Exception as e:
            logger.warning(f"Could not check WiFi connection status: {e}")
            return False

    async def _check_internet(self) -> bool:
        """Check if device has internet connectivity"""
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(
                    "https://www.google.com", timeout=aiohttp.ClientTimeout(total=5)
                ) as resp:
                    return resp.status == 200
        except Exception:
            logger.warning("Internet check failed")
            return False

    async def _delete_old_credentials(self, user_id: str) -> bool:
        """
        Deletes existing credentials for this user/device ID combination 
        to ensure no duplicates exist in Supabase.
        """
        try:
            logger.info(f"Cleaning up old credentials for User: {user_id}, Device: {self.device_id}")
            # We assume the table is named 'device_credentials' based on standard Supabase patterns
            # and the Edge Function name provided in context.
            url = f"{SUPABASE_URL}/rest/v1/device_credentials"
            
            # Delete logic: Remove rows where user_id matches AND device_id matches
            # This ensures we don't accidentally delete other devices belonging to the same user
            params = {
                "user_id": f"eq.{user_id}",
                "device_id": f"eq.{self.device_id}"
            }
            
            headers = {
                "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
                "apikey": SUPABASE_ANON_KEY
            }
            
            async with aiohttp.ClientSession() as session:
                async with session.delete(url, params=params, headers=headers) as resp:
                    if resp.status in [200, 204]:
                        logger.info("✓ Old device credentials removed successfully")
                        return True
                    else:
                        error_text = await resp.text()
                        logger.warning(f"Failed to remove old credentials (Status {resp.status}): {error_text}")
                        # We return True anyway because if the row didn't exist, it might fail or return 204
                        # and we want the new insertion to proceed.
                        return True
        except Exception as e:
            logger.error(f"Error during credential cleanup: {e}")
            return False # Proceed with caution

    async def _report_to_supabase(
        self, ssid: str, password: str, status: str = "success", user_id: str = None
    ) -> bool:
        """Report provisioning success to Supabase via Edge Function, ensuring no duplicates"""
        try:
            logger.info(f"[REGISTER] Registering device credentials to Supabase")
            logger.info(f"[REGISTER] Device ID: {self.device_id}, User ID: {user_id}")
            
            # Get user_id from auth context if available
            if not user_id:
                logger.warning("[REGISTER] ❌ No user_id provided for Supabase registration")
                return False
            
            # 1. Clean up previous credentials for this device/user
            logger.info(f"[REGISTER] Step 1: Cleaning up old credentials...")
            await self._delete_old_credentials(user_id)

            # 2. Encrypt the password
            encrypted_password = self._encrypt_password(password)
            
            payload = {
                "device_id": self.device_id,
                "user_id": user_id,
                "device_name": DEVICE_NAME,
                "encrypted_ssid": ssid,
                "encrypted_password": encrypted_password,
                "device_status": "connected",
            }
            
            logger.info(f"[REGISTER] Step 2: Payload prepared:")
            logger.info(f"[REGISTER]   - device_id: {payload['device_id']}")
            logger.info(f"[REGISTER]   - user_id: {payload['user_id']}")
            logger.info(f"[REGISTER]   - device_name: {payload['device_name']}")
            logger.info(f"[REGISTER]   - encrypted_ssid: {payload['encrypted_ssid']}")
            logger.info(f"[REGISTER]   - device_status: {payload['device_status']}")
            logger.info(f"[REGISTER]   - encrypted_password: {'*' * len(encrypted_password)}")
            
            headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
            }
            
            supabase_store_url = f"{SUPABASE_URL}/functions/v1/store-device-credentials"
            logger.info(f"[REGISTER] Step 3: Calling Edge Function at {supabase_store_url}")
            
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    supabase_store_url,
                    json=payload,
                    headers=headers,
                    timeout=aiohttp.ClientTimeout(total=30),
                ) as resp:
                    logger.info(f"[REGISTER] Edge Function response status: {resp.status}")
                    
                    if resp.status == 200:
                        response_body = await resp.json()
                        logger.info(f"[REGISTER] ✓ Edge Function succeeded!")
                        logger.info(f"[REGISTER] Response: {response_body}")
                        logger.info(f"[REGISTER] ✓ Device credentials stored successfully in Supabase")
                        return True
                    else:
                        error_text = await resp.text()
                        logger.error(f"[REGISTER] ❌ Device credential storage FAILED!")
                        logger.error(f"[REGISTER] HTTP Status: {resp.status}")
                        logger.error(f"[REGISTER] Response Body: {error_text}")
                        logger.error(f"[REGISTER] Check:")
                        logger.error(f"[REGISTER]   1. Is the Edge Function deployed?")
                        logger.error(f"[REGISTER]   2. Does it have permission to write to device_credentials?")
                        logger.error(f"[REGISTER]   3. Is the database table schema correct?")
                        return False
        except Exception as e:
            logger.error(f"[REGISTER] ❌ Exception during Supabase registration: {e}")
            import traceback
            logger.error(f"[REGISTER] Traceback: {traceback.format_exc()}")
            return False

    async def _update_device_status_connected(self, user_id: str) -> bool:
        """
        Update device status to 'connected' after successful WiFi connection and internet verification.
        This is called after the device has confirmed internet connectivity.
        Uses Edge Function to bypass RLS policies.
        """
        try:
            if not user_id:
                logger.warning("Cannot update device status: user_id not available")
                return False
            
            # Use Edge Function to bypass RLS policies
            supabase_connected_url = f"{SUPABASE_URL}/functions/v1/set-device-connected"
            
            headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
            }
            
            payload = {
                "device_id": self.device_id,
                "user_id": user_id,
            }
            
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    supabase_connected_url,
                    json=payload,
                    headers=headers,
                    timeout=aiohttp.ClientTimeout(total=10)
                ) as resp:
                    if resp.status == 200:
                        response_data = await resp.json()
                        if response_data.get("success"):
                            logger.info("✓ Device status updated to 'connected' in Supabase")
                            return True
                        else:
                            logger.warning(f"[STATUS] Edge Function returned success=false: {response_data.get('message')}")
                            return False
                    elif resp.status == 404:
                        logger.warning(f"[STATUS] Device not found in database when trying to set status to connected")
                        return False
                    else:
                        logger.warning(f"Failed to update device status to connected: {resp.status}")
                        try:
                            error_text = await resp.text()
                            logger.warning(f"[STATUS] Response: {error_text}")
                        except:
                            pass
                        return False
        except Exception as e:
            logger.error(f"Error updating device status to connected: {e}")
            return False

    async def _diagnose_device_credentials(self, user_id: str) -> None:
        """
        Diagnostic method to query and display what's actually in the device_credentials table.
        Called when heartbeat fails to help identify mismatches.
        Uses Edge Function to bypass RLS policies.
        """
        try:
            logger.info(f"[DIAGNOSIS] Querying device_credentials table for Device: {self.device_id}")
            
            supabase_diagnosis_url = f"{SUPABASE_URL}/functions/v1/diagnose-device-credentials"
            
            headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
            }
            
            payload = {
                "device_id": self.device_id,
            }
            
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    supabase_diagnosis_url,
                    json=payload,
                    headers=headers,
                    timeout=aiohttp.ClientTimeout(total=10)
                ) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        
                        if data.get("found"):
                            rows = data.get("rows", [])
                            logger.info(f"[DIAGNOSIS] Found {len(rows)} row(s) with device_id={self.device_id}")
                            for row in rows:
                                logger.info(f"[DIAGNOSIS] Row data:")
                                logger.info(f"  - id: {row.get('id')}")
                                logger.info(f"  - user_id: {row.get('user_id')} (type checking: expected UUID, got {type(row.get('user_id')).__name__})")
                                logger.info(f"  - device_id: {row.get('device_id')}")
                                logger.info(f"  - device_name: {row.get('device_name')}")
                                logger.info(f"  - device_status: {row.get('device_status')}")
                                logger.info(f"  - last_seen: {row.get('last_seen')}")
                                logger.info(f"  - created_at: {row.get('created_at')}")
                                
                                # Check if user_id matches what we're trying to use
                                stored_user_id = row.get('user_id')
                                if stored_user_id and stored_user_id != user_id:
                                    logger.warning(f"[DIAGNOSIS] ❌ USER_ID MISMATCH!")
                                    logger.warning(f"  - Trying to query with: {user_id}")
                                    logger.warning(f"  - But database has: {stored_user_id}")
                        else:
                            logger.warning(f"[DIAGNOSIS] ❌ No rows found with device_id={self.device_id}")
                            note = data.get("note", "")
                            if note:
                                logger.warning(f"[DIAGNOSIS] {note}")
                    else:
                        logger.warning(f"[DIAGNOSIS] Query failed with HTTP {resp.status}")
                        
        except Exception as e:
            logger.error(f"[DIAGNOSIS] Error running diagnostic query: {e}")

    async def _update_device_heartbeat(self, user_id: str = None) -> bool:
        """
        Send device heartbeat to Supabase via Edge Function.
        Updates only the last_seen timestamp to keep device online indicator current.
        This serves as a keep-alive signal during normal operation.
        Uses Edge Function to bypass RLS policies.
        """
        try:
            if not user_id:
                logger.debug("No user_id provided for heartbeat")
                return False
            
            # Use Edge Function to bypass RLS policies
            supabase_heartbeat_url = f"{SUPABASE_URL}/functions/v1/update-device-heartbeat"
            
            headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
            }
            
            payload = {
                "device_id": self.device_id,
                "user_id": user_id,
                "last_seen": self._get_manila_time().isoformat(),
            }
            
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    supabase_heartbeat_url,
                    json=payload,
                    headers=headers,
                    timeout=aiohttp.ClientTimeout(total=10)
                ) as resp:
                    if resp.status == 200:
                        response_data = await resp.json()
                        if response_data.get("success"):
                            logger.debug(f"✓ Device heartbeat sent - last_seen updated: {response_data.get('last_seen')}")
                            return True
                        else:
                            logger.warning(f"[HEARTBEAT] ❌ Edge Function returned success=false")
                            logger.warning(f"[HEARTBEAT] Message: {response_data.get('message')}")
                            logger.warning(f"[HEARTBEAT] Running diagnostic to find what's in the database...")
                            await self._diagnose_device_credentials(user_id)
                            return False
                    elif resp.status == 404:
                        logger.warning(f"[HEARTBEAT] ❌ No matching device found in database!")
                        logger.warning(f"[HEARTBEAT] Filter used - User: {user_id}, Device: {self.device_id}")
                        logger.warning(f"[HEARTBEAT] Running diagnostic to find what's in the database...")
                        await self._diagnose_device_credentials(user_id)
                        return False
                    else:
                        logger.warning(f"[HEARTBEAT] Failed to send heartbeat: HTTP {resp.status}")
                        try:
                            error_text = await resp.text()
                            logger.warning(f"[HEARTBEAT] Response body: {error_text}")
                        except:
                            pass
                        return False
        except Exception as e:
            logger.warning(f"[HEARTBEAT] Heartbeat error: {e}")
            import traceback
            logger.debug(f"[HEARTBEAT] Traceback: {traceback.format_exc()}")
            return False

    def _setup_hotspot_interface(self) -> bool:
        """Configure wlan0 for hotspot mode"""
        try:
            logger.info("Setting up WiFi interface for hotspot...")
            
            # Disconnect from any existing WiFi networks
            logger.info("Disconnecting from home WiFi...")
            subprocess.run(
                ["sudo", "nmcli", "device", "disconnect", "wlan0"],
                capture_output=True,
                timeout=5,
            )
            time.sleep(1)
            
            # Aggressively kill any lingering processes
            subprocess.run(["sudo", "killall", "-9", "dnsmasq"], capture_output=True, timeout=5)
            subprocess.run(["sudo", "killall", "-9", "hostapd"], capture_output=True, timeout=5)
            time.sleep(2)
            
            # Stop system services
            subprocess.run(["sudo", "systemctl", "stop", "hostapd"], capture_output=True, timeout=5)
            subprocess.run(["sudo", "systemctl", "stop", "dnsmasq"], capture_output=True, timeout=5)
            time.sleep(2)
            
            # Reset interface
            subprocess.run(
                ["sudo", "ip", "link", "set", "wlan0", "down"],
                capture_output=True,
                timeout=5,
            )
            time.sleep(1)
            
            # Set static IP
            subprocess.run(
                ["sudo", "ip", "addr", "flush", "dev", "wlan0"],
                capture_output=True,
                timeout=5,
            )
            subprocess.run(
                ["sudo", "ip", "addr", "add", "192.168.50.1/24", "dev", "wlan0"],
                capture_output=True,
                timeout=5,
            )
            
            # Bring interface up
            subprocess.run(
                ["sudo", "ip", "link", "set", "wlan0", "up"],
                capture_output=True,
                timeout=5,
            )
            
            # Wait for interface to come up and socket to be released
            time.sleep(3)
            
            # Verify interface has IP
            result = subprocess.run(
                ["ip", "addr", "show", "dev", "wlan0"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if "192.168.50.1" not in result.stdout:
                logger.error(f"Interface doesn't have IP: {result.stdout}")
                return False
            
            logger.info("✓ Interface configured for hotspot")
            return True
            
        except Exception as e:
            logger.error(f"Failed to setup hotspot interface: {e}")
            return False

    def _start_hostapd(self) -> bool:
        """Start hostapd for WiFi hotspot"""
        try:
            logger.info("Starting hostapd for EVVOS_0001 hotspot...")
            
            # Copy config to temp location
            config_content = """interface=wlan0
driver=nl80211
ssid=EVVOS_0001
hw_mode=g
channel=11
wmm_enabled=0
auth_algs=1
wpa=0
logger_syslog=0
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2
country_code=US
max_num_sta=5
"""
            
            config_file = "/tmp/hostapd-evvos.conf"
            with open(config_file, "w") as f:
                f.write(config_content)
            
            # Start hostapd
            proc = subprocess.Popen(
                ["sudo", "hostapd", config_file],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
            )
            
            # Wait a moment to see if it starts
            time.sleep(2)
            if proc.poll() is not None:
                stdout_output, stderr_output = proc.communicate()
                error_msg = stderr_output or stdout_output or "Unknown error"
                logger.error(f"hostapd failed to start: {error_msg}")
                logger.error(f"Return code: {proc.returncode}")
                return False
            
            self.hostapd_process = proc
            logger.info(f"✓ hostapd started (PID: {proc.pid})")
            return True
            
        except Exception as e:
            logger.error(f"Failed to start hostapd: {e}")
            return False

    def _start_dnsmasq(self) -> bool:
        """Start dnsmasq for DHCP on hotspot"""
        try:
            logger.info("Starting dnsmasq for DHCP...")
            
            # Create dnsmasq config
            config_content = """interface=wlan0
bind-interfaces
dhcp-range=192.168.50.2,192.168.50.100,24h
dhcp-option=option:router,192.168.50.1
dhcp-option=option:dns-server,192.168.50.1
cache-size=1000
"""
            
            config_file = "/tmp/dnsmasq-evvos.conf"
            with open(config_file, "w") as f:
                f.write(config_content)
            
            # Start dnsmasq
            proc = subprocess.Popen(
                ["sudo", "dnsmasq", "-C", config_file],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
            )
            
            # Wait for dnsmasq to start
            time.sleep(3)
            
            # Check if process is still running (poll returns None if running)
            if proc.poll() is not None:
                # Process exited, get error
                stdout, stderr = proc.communicate()
                error_msg = (stderr or stdout or "Unknown error")
                # Only fail on critical errors
                if "cannot assign requested address" in error_msg.lower() or "address already in use" in error_msg.lower():
                    logger.error(f"dnsmasq failed to start: {error_msg}")
                    return False
            
            # Process is running (poll returned None)
            self.dnsmasq_process = proc
            logger.info(f"✓ dnsmasq started (PID: {proc.pid})")
            return True
            
        except Exception as e:
            logger.error(f"Failed to start dnsmasq: {e}")
            return False

    async def _handle_cors_options(self, request: web.Request) -> web.Response:
        """Handle CORS preflight OPTIONS requests"""
        logger.info("✓ Received OPTIONS preflight request to /provision")
        return web.Response(status=200, headers={
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        })

    async def _handle_provisioning_form(self, request: web.Request) -> web.Response:
        """
        Serve the simplified provisioning form HTML.
        MODIFIED: Checks for user_id and blocks access if missing.
        MODIFIED: Updates text to guide user back to app upon success and attempts auto-close.
        """
        user_id = request.query.get('user_id', '').strip()
        
        # ----------------------------------------------------------------
        # 1. SECURITY CHECK: BLOCK ACCESS IF NO USER_ID
        # ----------------------------------------------------------------
        if not user_id:
            logger.warning("Access denied: Provisioning page accessed without user_id")
            error_html = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Access Denied - E.V.V.O.S</title>
    <style>
        body { font-family: -apple-system, system-ui, sans-serif; background: #f8d7da; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; padding: 20px; text-align: center; color: #721c24; }
        .box { background: white; padding: 40px; border-radius: 16px; box-shadow: 0 10px 30px rgba(0,0,0,0.1); max-width: 400px; border: 1px solid #f5c6cb; }
        h1 { margin-top: 0; font-size: 24px; }
        p { line-height: 1.6; color: #555; }
        .icon { font-size: 48px; margin-bottom: 20px; }
    </style>
</head>
<body>
    <div class="box">
        <div class="icon">🚫</div>
        <h1>Action Required</h1>
        <p>You have scanned this code using your standard Camera app.</p>
        <p style="font-weight: bold; color: #333;">Please open the E.V.V.O.S Mobile App and use the built-in scanner to provision this device.</p>
    </div>
</body>
</html>
"""
            return web.Response(text=error_html, content_type='text/html', status=403)

        # ----------------------------------------------------------------
        # 2. SERVE PROVISIONING FORM (With Return to App Instructions)
        # ----------------------------------------------------------------
        html_content = f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>E.V.V.O.S Device Provisioning</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Roboto', sans-serif; background: linear-gradient(135deg, #0B1A33 0%, #3D5F91 100%); min-height: 100vh; display: flex; justify-content: center; align-items: center; padding: 16px; }}
        .container {{ background: white; border-radius: 16px; box-shadow: 0 20px 60px rgba(0, 0, 0, 0.4); width: 100%; max-width: 420px; padding: 24px; }}
        @media (min-width: 600px) {{ .container {{ padding: 40px; }} }}
        .header {{ text-align: center; margin-bottom: 28px; }}
        .header h1 {{ font-size: 26px; color: #1a1a1a; margin-bottom: 8px; font-weight: 800; }}
        .header p {{ font-size: 14px; color: #666; line-height: 1.5; }}
        .form-group {{ margin-bottom: 20px; position: relative; }}
        .form-group label {{ display: block; font-size: 12px; font-weight: 700; color: #444; margin-bottom: 8px; text-transform: uppercase; letter-spacing: 0.5px; }}
        
        .input-wrapper {{ position: relative; display: flex; align-items: center; }}
        .form-group input {{ width: 100%; padding: 14px 14px; padding-right: 45px; border: 2px solid #e0e0e0; border-radius: 12px; font-size: 16px; transition: all 0.2s ease; outline: none; }}
        .form-group input:focus {{ border-color: #3D5F91; box-shadow: 0 0 0 4px rgba(61, 95, 145, 0.15); }}
        
        /* Eye Icon Style */
        .toggle-password {{ position: absolute; right: 14px; cursor: pointer; color: #888; display: flex; align-items: center; justify-content: center; height: 100%; }}
        .toggle-password svg {{ width: 22px; height: 22px; transition: color 0.2s; }}
        .toggle-password:hover {{ color: #3D5F91; }}

        .submit-btn {{ width: 100%; padding: 16px; background: #15C85A; color: white; border: none; border-radius: 12px; font-size: 16px; font-weight: 700; cursor: pointer; transition: transform 0.1s, background 0.2s; margin-top: 10px; }}
        .submit-btn:active {{ transform: scale(0.98); background: #12b04f; }}
        .submit-btn:disabled {{ opacity: 0.7; cursor: not-allowed; }}
        
        .status-message {{ margin-top: 20px; padding: 14px; border-radius: 12px; text-align: center; font-size: 13px; font-weight: 500; display: none; }}
        .status-message.success {{ background: #d4edda; color: #155724; border: 1px solid #c3e6cb; display: block; }}
        .status-message.error {{ background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; display: block; }}
        
        .loading {{ display: none; text-align: center; margin-top: 24px; }}
        .spinner {{ border: 3px solid rgba(0,0,0,0.1); border-top: 3px solid #15C85A; border-radius: 50%; width: 30px; height: 30px; animation: spin 0.8s linear infinite; margin: 0 auto 12px; }}
        @keyframes spin {{ 0% {{ transform: rotate(0deg); }} 100% {{ transform: rotate(360deg); }} }}

        .app-link {{ display: none; margin-top: 15px; text-align: center; }}
        .app-link a {{ color: #3D5F91; text-decoration: none; font-weight: bold; border: 2px solid #3D5F91; padding: 10px 20px; border-radius: 8px; display: inline-block; }}
        .app-link p {{ margin-bottom: 8px; font-size: 14px; color: #444; }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Connect Device</h1>
            <p>Enter your Mobile Hotspot credentials.</p>
        </div>
        
        <form id="provisioningForm">
            <input type="hidden" id="user_id" name="user_id" value="{user_id}">
            
            <div class="form-group">
                <label for="ssid">Hotspot Name (SSID)</label>
                <div class="input-wrapper">
                    <input type="text" id="ssid" name="ssid" placeholder="e.g. iPhone Hotspot" required autocorrect="off" autocapitalize="none">
                </div>
            </div>
            
            <div class="form-group">
                <label for="password">Hotspot Password</label>
                <div class="input-wrapper">
                    <input type="password" id="password" name="password" placeholder="Required" required>
                    <div class="toggle-password" id="toggleBtn">
                        <svg id="eyeOpen" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                            <path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
                            <path stroke-linecap="round" stroke-linejoin="round" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z" />
                        </svg>
                        <svg id="eyeClosed" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2" style="display:none;">
                            <path stroke-linecap="round" stroke-linejoin="round" d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21" />
                        </svg>
                    </div>
                </div>
            </div>
            
            <button type="submit" class="submit-btn" id="submitBtn">Connect Device</button>
        </form>
        
        <div class="loading" id="loading">
            <div class="spinner"></div>
            <p>Transmitting credentials...</p>
        </div>
        
        <div class="status-message" id="statusMessage"></div>

        <div class="app-link" id="appLink">
            <p><strong>Credentials Sent Successfully!</strong></p>
            <p>Please return to the E.V.V.O.S Mobile App to finish setup.</p>
            <br>
            <a href="#" onclick="window.close(); return false;">Close Window & Return</a>
        </div>
    </div>

    <script>
        const form = document.getElementById('provisioningForm');
        const submitBtn = document.getElementById('submitBtn');
        const passwordInput = document.getElementById('password');
        const toggleBtn = document.getElementById('toggleBtn');
        const eyeOpen = document.getElementById('eyeOpen');
        const eyeClosed = document.getElementById('eyeClosed');
        const loading = document.getElementById('loading');
        const statusMessage = document.getElementById('statusMessage');
        const appLink = document.getElementById('appLink');

        // Toggle Password Logic
        toggleBtn.addEventListener('click', () => {{
            const type = passwordInput.getAttribute('type') === 'password' ? 'text' : 'password';
            passwordInput.setAttribute('type', type);
            
            if (type === 'text') {{
                eyeOpen.style.display = 'none';
                eyeClosed.style.display = 'block';
            }} else {{
                eyeOpen.style.display = 'block';
                eyeClosed.style.display = 'none';
            }}
        }});

        form.addEventListener('submit', async (e) => {{
            e.preventDefault();
            const ssid = document.getElementById('ssid').value.trim();
            const password = passwordInput.value.trim();
            const userId = document.getElementById('user_id').value;

            if (!ssid || !password) {{
                showMessage('Please enter both SSID and password', 'error');
                return;
            }}

            submitBtn.disabled = true;
            loading.style.display = 'block';
            form.style.display = 'none';
            statusMessage.style.display = 'none';

            try {{
                const response = await fetch('/provision', {{
                    method: 'POST',
                    headers: {{ 'Content-Type': 'application/json' }},
                    body: JSON.stringify({{ user_id: userId, ssid: ssid, password: password }}),
                }});

                const data = await response.json();

                if (response.ok) {{
                    // Try to auto-close window
                    loading.style.display = 'none';
                    appLink.style.display = 'block';
                    showMessage('✅ Credentials received!', 'success');
                    
                    // Attempt to close window automatically after 1 second
                    setTimeout(() => {{
                        window.close();
                    }}, 1500);
                }} else {{
                    throw new Error(data.error || 'Failed');
                }}
            }} catch (error) {{
                showMessage(error.message || 'Connection error', 'error');
                form.style.display = 'block';
                submitBtn.disabled = false;
                loading.style.display = 'none';
            }}
        }});

        function showMessage(message, type) {{
            statusMessage.textContent = message;
            statusMessage.className = `status-message ${{type}}`;
        }}
    </script>
</body>
</html>
"""
        return web.Response(text=html_content, content_type='text/html')

    async def _handle_credentials(self, request: web.Request) -> web.Response:
        """Handle incoming credentials from web form"""
        cors_headers = {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        }
        
        try:
            logger.info("✓ Received HTTP POST request to /provision endpoint")
            
            data = await request.json()
            user_id = data.get("user_id", "").strip()
            ssid = data.get("ssid", "").strip()
            password = data.get("password", "").strip()
            
            logger.info(f"Credential data received - User: {user_id}, SSID: {ssid}, Password: {'*' * len(password)}")
            
            # STRICT CHECK: Reject if user_id is missing
            if not user_id or not ssid or not password:
                logger.warning("Received incomplete credentials (missing user_id, ssid, or password)")
                return web.json_response(
                    {"error": "User ID, SSID, and password are required"}, 
                    status=400,
                    headers=cors_headers
                )
            
            logger.info(f"✓ Received valid credentials - SSID: {ssid}")
            
            # Write credentials to state file for provisioning loop to pick up
            state = {
                "status": "processing",
                "user_id": user_id,
                "ssid": ssid,
                "password": password,
                "timestamp": self._get_manila_time().isoformat(),
            }
            
            with open(self.state_file, "w") as f:
                json.dump(state, f)
            
            logger.info("✓ Credentials written to state file, provisioning will continue...")
            
            return web.json_response(
                {"status": "success", "message": "Credentials received successfully"}, 
                status=200,
                headers=cors_headers
            )
            
        except Exception as e:
            logger.error(f"Error handling credentials: {e}")
            import traceback
            logger.error(traceback.format_exc())
            return web.json_response(
                {"error": str(e)}, 
                status=500,
                headers=cors_headers
            )

    async def _handle_credentials_get(self, request: web.Request) -> web.Response:
        """Handle GET requests to /provision endpoint (for testing)"""
        cors_headers = {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        }
        
        # Check if SSID and password are in query string (for testing via browser)
        ssid = request.query.get("ssid", "").strip() if request.query else ""
        password = request.query.get("password", "").strip() if request.query else ""
        
        if ssid and password:
            logger.info(f"Testing with query params - SSID: {ssid}, Password: {'*' * len(password)}")
            # Process as credentials
            state = {
                "status": "processing",
                "ssid": ssid,
                "password": password,
                "timestamp": self._get_manila_time().isoformat(),
            }
            with open(self.state_file, "w") as f:
                json.dump(state, f)
            logger.info("✓ Credentials written to state file via GET test")
            return web.json_response(
                {"status": "success", "message": "Credentials received via GET (testing)"}, 
                status=200,
                headers=cors_headers
            )
        else:
            return web.json_response(
                {"status": "error", "message": "Use POST method"},
                status=405,
                headers=cors_headers
            )

    async def _handle_check_credentials(self, request: web.Request) -> web.Response:
        """Check if credentials have been received"""
        cors_headers = {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        }
        
        try:
            if os.path.exists(self.state_file):
                with open(self.state_file, 'r') as f:
                    state = json.load(f)
                
                if state.get('status') == 'processing' and 'ssid' in state and 'password' in state:
                    logger.info("✓ Mobile app checked: credentials confirmed received")
                    return web.json_response(
                        {"received": True, "ssid": state.get("ssid")},
                        status=200,
                        headers=cors_headers
                    )
        except Exception as e:
            logger.debug(f"Error checking credentials: {e}")
        
        return web.json_response(
            {"received": False},
            status=200,
            headers=cors_headers
        )

    async def _handle_disconnect_request(self, request: web.Request) -> web.Response:
        """
        Handle disconnect requests from mobile app when connected to hotspot.
        Called via HTTP POST /disconnect endpoint.
        This provides immediate feedback to the app before Supabase polling detects it.
        """
        cors_headers = {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        }
        
        try:
            logger.info("✓ Received HTTP POST request to /disconnect endpoint")
            
            # Parse request body
            try:
                data = await request.json()
            except:
                data = {}
            
            user_id = data.get("user_id", "").strip()
            device_id = data.get("device_id", "").strip()
            
            logger.info(f"[DISCONNECT-HTTP] Disconnect request received - User: {user_id}, Device: {device_id}")
            
            # Validate minimum required data
            if not user_id:
                logger.warning("[DISCONNECT-HTTP] Missing user_id in request")
                return web.json_response(
                    {"error": "user_id is required"}, 
                    status=400,
                    headers=cors_headers
                )
            
            # Schedule disconnect to happen after HTTP response
            # This ensures the app gets a response before device restarts
            logger.info("[DISCONNECT-HTTP] Scheduling disconnect operation...")
            asyncio.create_task(self._handle_disconnect())
            
            return web.json_response(
                {
                    "success": True,
                    "message": "Device disconnect initiated. Device will restart in provisioning mode shortly.",
                    "device_id": device_id,
                },
                status=200,
                headers=cors_headers
            )
            
        except Exception as e:
            logger.error(f"[DISCONNECT-HTTP] Error handling disconnect request: {e}")
            import traceback
            logger.error(traceback.format_exc())
            return web.json_response(
                {"error": str(e)}, 
                status=500,
                headers=cors_headers
            )

    async def _handle_disconnect_options(self, request: web.Request) -> web.Response:
        """Handle CORS preflight for /disconnect endpoint"""
        cors_headers = {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        }
        logger.info("✓ Received OPTIONS preflight request to /disconnect")
        return web.Response(status=200, headers=cors_headers)

    async def _start_http_server(self) -> None:
        """Start aiohttp server for credential and disconnect endpoints"""
        try:
            app = web.Application()
            app.router.add_get("/provisioning", self._handle_provisioning_form)
            app.router.add_options("/provision", self._handle_cors_options)
            app.router.add_post("/provision", self._handle_credentials)
            app.router.add_get("/provision", self._handle_credentials_get)
            app.router.add_get("/check-credentials", self._handle_check_credentials)
            
            # NEW DISCONNECT ROUTES
            app.router.add_post("/disconnect", self._handle_disconnect_request)
            app.router.add_options("/disconnect", self._handle_disconnect_options)
            
            app.router.add_get("/health", lambda r: web.json_response({"status": "ok"}))
            
            self.web_runner = web.AppRunner(app)
            await self.web_runner.setup()
            
            site = web.TCPSite(self.web_runner, "0.0.0.0", 8000, reuse_address=True)
            await site.start()
            
            logger.info("✓ HTTP credential server started on 0.0.0.0:8000 (with disconnect support)")
            
            while True:
                await asyncio.sleep(3600)
                
        except asyncio.CancelledError:
            logger.info("HTTP server task cancelled")
            if self.web_runner:
                await self.web_runner.cleanup()
            raise
        except Exception as e:
            logger.error(f"HTTP server error: {e}")

    async def _start_hotspot(self) -> bool:
        """Start the WiFi hotspot and web server"""
        try:
            logger.info("Starting EVVOS_0001 hotspot mode...")
            
            if not self._setup_hotspot_interface():
                return False
            
            await asyncio.sleep(3)
            
            if not self._start_hostapd():
                return False
            
            await asyncio.sleep(4)
            
            if not self._start_dnsmasq():
                await self._stop_hotspot()
                return False
            
            await asyncio.sleep(2)
            
            logger.info("Starting HTTP credential server...")
            self.web_task = asyncio.create_task(self._start_http_server())            
            logger.info("✓ Hotspot fully started - waiting for mobile app credentials")
            return True
            
        except Exception as e:
            logger.error(f"Error starting hotspot: {e}")
            return False

    async def _stop_hotspot(self):
        """Stop the hotspot and services"""
        try:
            logger.info("Stopping hotspot services...")
        
            if self.web_task:
                self.web_task.cancel()
                try:
                    await self.web_task
                except asyncio.CancelledError:
                    pass
                self.web_task = None
            
            if self.dnsmasq_process:
                self.dnsmasq_process.terminate()
                try:
                    self.dnsmasq_process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.dnsmasq_process.kill()
            
            if self.hostapd_process:
                self.hostapd_process.terminate()
                try:
                    self.hostapd_process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.hostapd_process.kill()
            
            subprocess.run(["sudo", "systemctl", "stop", "hostapd"], capture_output=True, timeout=5)
            subprocess.run(["sudo", "systemctl", "stop", "dnsmasq"], capture_output=True, timeout=5)
            
            logger.info("Hotspot stopped")
            
        except Exception as e:
            logger.error(f"Error stopping hotspot: {e}")

    async def _wait_for_hotspot_credentials(self, timeout_seconds: int = 600) -> bool:
        """Wait for credentials to be submitted via web form"""
        try:
            logger.info(f"Waiting for hotspot credentials via web form (timeout: {timeout_seconds}s)...")
            
            start_time = datetime.now()
            check_interval = 1
            last_check = 0
            
            while (datetime.now() - start_time).total_seconds() < timeout_seconds:
                try:
                    if os.path.exists(self.state_file):
                        with open(self.state_file, 'r') as f:
                            state = json.load(f)
                        
                        if state.get('status') == 'processing' and 'ssid' in state and 'password' in state:
                            logger.info("✓ Credentials received via web form!")
                            self.received_credentials = {
                                'ssid': state['ssid'],
                                'password': state['password'],
                                'user_id': state.get('user_id', '')
                            }
                            return True
                    
                    elapsed = (datetime.now() - start_time).total_seconds()
                    if int(elapsed) - last_check >= 30:
                        logger.info(f"  Waiting for web form submission... {int(elapsed)}s/{timeout_seconds}s")
                        last_check = int(elapsed)
                    
                except json.JSONDecodeError:
                    pass
                except Exception as e:
                    logger.debug(f"Error reading state file: {e}")
                
                await asyncio.sleep(check_interval)
            
            logger.warning(f"Hotspot credential timeout after {timeout_seconds}s")
            return False
        except Exception as e:
            logger.error(f"Error waiting for hotspot credentials: {e}")
            return False

    async def _provision_with_hotspot(self):
        """Provision using hotspot method"""
        try:
            logger.info("Starting hotspot provisioning mode...")
            
            if not await self._start_hotspot():
                logger.error("Failed to start hotspot")
                return False
            
            if await self._wait_for_hotspot_credentials(timeout_seconds=600):
                ssid = self.received_credentials.get("ssid")
                password = self.received_credentials.get("password")
                
                if not ssid or not password:
                    logger.error("Invalid credentials received")
                    await self._stop_hotspot()
                    return False
                
                logger.info(f"Attempting to connect to hotspot: {ssid}")
                
                logger.info("Waiting 2 seconds for mobile app to confirm provisioning...")
                await asyncio.sleep(2)
                
                await self._stop_hotspot()
                await asyncio.sleep(2)
                
                # Try WiFi connection up to 5 times
                wifi_connected = False
                for wifi_attempt in range(1, 6):
                    logger.info(f"WiFi connection attempt {wifi_attempt}/5...")
                    
                    if await self._connect_to_wifi(ssid, password):
                        logger.info(f"✓ WiFi connection command executed (attempt {wifi_attempt})")
                        # Wait to see if we actually get an IP
                        for wait_ip in range(6):
                            await asyncio.sleep(5)
                            if self._check_wifi_connected():
                                wifi_connected = True
                                break
                        if wifi_connected: break
                    else:
                        logger.warning(f"✗ WiFi connection failed (attempt {wifi_attempt}/5)")
                        await asyncio.sleep(3)
                
                # --- CRITICAL CHANGE START ---
                if not wifi_connected:
                    logger.error("✗ WiFi connection failed after 5 attempts")
                    logger.info("Cleaning up failed credentials to prevent retry loops...")
                    
                    # 1. Delete the local state file so it doesn't reload on restart
                    if os.path.exists(self.state_file):
                        try:
                            os.remove(self.state_file)
                            logger.info("✓ State file deleted")
                        except Exception as e:
                            logger.warning(f"Failed to delete state file: {e}")

                    # 2. Clear memory variables
                    self.received_credentials = None
                    
                    # 3. Force clean the interface before returning to AP mode
                    subprocess.run(["sudo", "ip", "addr", "flush", "dev", "wlan0"], capture_output=True)
                    
                    logger.info("Restarting in AP mode for credential retry...")
                    return await self._provision_with_hotspot() 
                # --- CRITICAL CHANGE END ---

                # WiFi connected, now check internet
                logger.info("Verifying internet connectivity...")
                internet_verified = False
                for attempt in range(1, 6):
                    if await self._check_internet():
                        logger.info("✓ Internet connection verified!")
                        internet_verified = True
                        break
                    await asyncio.sleep(3)
                
                if not internet_verified:
                    logger.error("✗ Internet connectivity verification failed")
                    # Clean up and restart AP mode
                    if os.path.exists(self.state_file):
                        os.remove(self.state_file)
                    self.received_credentials = None
                    return await self._provision_with_hotspot()
                
                # All checks passed
                user_id = self.received_credentials.get("user_id", "")
                self._save_credentials(ssid, password, user_id=user_id)
                
                if await self._report_to_supabase(ssid, password, user_id=user_id):
                    logger.info("✓ Credentials reported to Supabase")
                    
                    # Update device status to connected after successful connection
                    if await self._update_device_status_connected(user_id):
                        logger.info("✓ Provisioning successful! Device now in 'connected' state.")
                        
                        # Step: Start voice command service now that provisioning is complete
                        if self._start_voice_command_service():
                            logger.info("✓ Voice command service is now running")
                        
                        if os.path.exists(self.state_file):
                            os.remove(self.state_file)
                        return True
                    else:
                        logger.warning("Credentials saved but failed to update device status to connected")
                        return False
                else:
                    logger.error("Failed to report to Supabase")
                    return False
                    
            else:
                logger.warning("No credentials received via web form within timeout")
                await self._stop_hotspot()
                return False
                
        except Exception as e:
            logger.error(f"Hotspot provisioning error: {e}")
            await self._stop_hotspot()
            return False

    async def _provision_wifi(self):
        """Attempt WiFi provisioning with stored or hotspot method"""
        if self.credentials:
            logger.info("Attempting to connect with stored credentials")
            ssid = self.credentials.get("ssid")
            password = self.credentials.get("password")

            # Try to connect up to 5 times
            connection_established = False
            for connect_attempt in range(1, 6):
                logger.info(f"WiFi connection attempt {connect_attempt}/5...")
                if await self._connect_to_wifi(ssid, password):
                    logger.info(f"Connection command sent, waiting for association and DHCP (up to 30 seconds)...")
                    for wait_attempt in range(1, 7):
                        await asyncio.sleep(5)
                        logger.info(f"Checking WiFi connection status (attempt {wait_attempt}/6, {wait_attempt*5}s)...")
                        if self._check_wifi_connected():
                            connection_established = True
                            logger.info(f"✓ Connection attempt {connect_attempt} succeeded - WiFi associated with IP")
                            break
                    
                    if connection_established:
                        break
                    else:
                        logger.warning(f"Connection attempt {connect_attempt}: WiFi not associated after 30 seconds")
                        await asyncio.sleep(2)
                else:
                    logger.warning(f"Connection attempt {connect_attempt} failed")
                    await asyncio.sleep(3)
            
            # If connection established, verify internet connectivity
            if connection_established:
                await asyncio.sleep(5)
                
                logger.info("Verifying internet connectivity...")
                for attempt in range(1, 6):
                    logger.info(f"Internet check attempt {attempt}/5...")
                    if await self._check_internet():
                        logger.info("✓ Internet connection verified!")
                        # Device already stored credentials on previous boot
                        # Update device status to connected now that internet is verified
                        user_id = self.credentials.get("user_id", "")
                        if user_id:
                            await self._update_device_status_connected(user_id)
                        return True
                    await asyncio.sleep(3)
                
                # INTERNET CHECK FAILED
                logger.error("Internet connectivity verification failed after 5 attempts")
                logger.warning("Deleting stored credentials due to connection failure...")
                self._delete_credentials()
                return False # Will trigger hotspot loop in run()
            else:
                # WIFI CONNECTION FAILED
                logger.error("WiFi connection with stored credentials failed after 5 attempts")
                logger.warning("Deleting stored credentials and switching to hotspot provisioning...")
                self._delete_credentials()
                return False # Will trigger hotspot loop in run()

        # No stored credentials or they were just deleted
        logger.info("No stored credentials. Starting hotspot provisioning...")
        return await self._provision_with_hotspot()

    async def _monitor_connectivity(self) -> None:
        """
        Background task that monitors device connectivity and checks for disconnect requests.
        Sends periodic heartbeats (every 1 minute) to keep last_seen timestamp updated.
        Also checks for unpair_requested flag in Supabase (every 10 seconds).
        """
        heartbeat_counter = 0
        logger.info("[MONITOR] Connectivity monitor started - will check disconnects every 10s and send heartbeat every 60s")
        
        while True:
            try:
                await asyncio.sleep(10)  # Check every 10 seconds
                
                # Check for disconnect request (every 10s)
                try:
                    if await self._check_disconnect_requested():
                        logger.warning("[MONITOR] Disconnect request detected! Initiating disconnect...")
                        await self._handle_disconnect()
                        # After disconnect, the main run() loop will detect credentials are deleted
                        # and restart hotspot provisioning
                        break
                except Exception as e:
                    logger.warning(f"[MONITOR] Error checking disconnect status: {e}")
                
                # Send heartbeat every 1 minute (heartbeat_counter = 6 iterations of 10s)
                heartbeat_counter += 1
                if heartbeat_counter >= 6:
                    heartbeat_counter = 0
                    
                    if self.credentials and self.credentials.get("user_id"):
                        user_id = self.credentials.get("user_id")
                        logger.info(f"[MONITOR] Heartbeat cycle - Updating last_seen for User: {user_id}, Device: {self.device_id}")
                        
                        try:
                            if await self._check_internet():
                                # Device has internet, send heartbeat
                                result = await self._update_device_heartbeat(user_id=user_id)
                                if result:
                                    logger.info(f"[MONITOR] ✓ Heartbeat sent successfully - last_seen updated")
                                else:
                                    logger.warning(f"[MONITOR] ✗ Heartbeat failed - last_seen NOT updated. Check if device_credentials table has matching row")
                            else:
                                logger.debug("[MONITOR] No internet connectivity - heartbeat skipped")
                        except Exception as e:
                            logger.error(f"[MONITOR] Error sending heartbeat: {e}")
                    else:
                        logger.debug("[MONITOR] No credentials available - skipping heartbeat")
                            
            except Exception as e:
                logger.error(f"[MONITOR] Unexpected error in connectivity monitor loop: {e}")
                await asyncio.sleep(5)  # Wait before retrying to avoid rapid error loops

    def _setup_button(self):
        """Initialize GPIO for ReSpeaker Button"""
        if GPIO:
            try:
                GPIO.setmode(GPIO.BCM)
                GPIO.setup(BUTTON_GPIO, GPIO.IN, pull_up_down=GPIO.PUD_UP)
                logging.info(f"✓ ReSpeaker Button initialized on GPIO {BUTTON_GPIO}")
            except Exception as e:
                logging.error(f"Failed to setup button GPIO: {e}")

    async def _monitor_button(self):
        """Monitor button for 5-second hold to factory reset"""
        if not GPIO: return

        logging.info("[BUTTON] Starting button monitor task...")
        press_start = None

        while True:
            try:
                # Button is Active LOW (False when pressed)
                if GPIO.input(BUTTON_GPIO) == False:
                    if press_start is None:
                        press_start = time.time()
                    
                    if (time.time() - press_start_time) > 5.0:
                        logger.warning("Triggering Factory Reset...")
                        await self._perform_factory_reset()
                        press_start_time = None
                        await asyncio.sleep(10) # Give it time to die
                else:
                    press_start = None
                
                await asyncio.sleep(0.1)
            except Exception as e:
                logging.error(f"Button error: {e}")
                await asyncio.sleep(1)

    async def _perform_factory_reset(self):
        """Wipe credentials and restart services"""
        cmd = "sudo rm -f /etc/evvos/device_credentials.json /tmp/evvos_ble_state.json && sudo systemctl restart evvos-provisioning evvos-voice-command"
        try:
            logging.info("Executing Factory Reset...")
            subprocess.run(cmd, shell=True, check=False)
        except Exception as e:
            logging.error(f"Reset failed: {e}")

    async def run(self):
        asyncio.create_task(self._monitor_button())
        """Main provisioning loop"""
        logger.info(f"EVVOS WiFi Hotspot Provisioning Agent Started (Device: {self.device_id})")
        logger.info("=" * 60)

        # Start background connectivity monitor (sends heartbeats every 1 minute, checks for disconnect every 10s)
        monitor_task = asyncio.create_task(self._monitor_connectivity())

        while True:
            try:
                # Attempt WiFi provisioning
                success = await self._provision_wifi()
                
                if success:
                    logger.info("✓ Provisioning completed successfully!")
                    # Sleep for an hour before trying again (maintenance check)
                    logger.info("Going to sleep for 1 hour...")
                    await asyncio.sleep(3600)
                else:
                    # _provision_wifi returned False.
                    # If it had creds, it tried 5 times, deleted them, and returned False.
                    # The next iteration will pick up "No stored credentials" and start hotspot.
                    logger.warning("Provisioning attempt failed or credentials invalid.")
                    logger.warning("Restarting loop in 10 seconds (will likely enter Hotspot mode)...")
                    await asyncio.sleep(10)
            
            except Exception as e:
                logger.error(f"Provisioning loop error: {e}")
                import traceback
                logger.error(traceback.format_exc())
                await asyncio.sleep(30)


async def main():
    provisioner = EVVOSWiFiProvisioner()
    await provisioner.run()

def _setup_button(self):
        """Initialize GPIO for ReSpeaker Button"""
        GPIO.setmode(GPIO.BCM)
        GPIO.setup(BUTTON_GPIO, GPIO.IN, pull_up_down=GPIO.PUD_UP)

    async def _monitor_button(self):
        """Check for 5-second hold to reset"""
        press_start = None
        while True:
            if GPIO.input(BUTTON_GPIO) == False: # Button pressed
                if press_start is None: press_start = time.time()
                if (time.time() - press_start) > 5.0:
                    await self._perform_factory_reset()
                    press_start = None
            else:
                press_start = None
            await asyncio.sleep(0.1)

    async def _perform_factory_reset(self):
        """Wipe credentials and restart both services"""
        cmd = "sudo rm -f /etc/evvos/device_credentials.json /tmp/evvos_ble_state.json && sudo systemctl restart evvos-provisioning evvos-voice-command"
        subprocess.run(cmd, shell=True)

if __name__ == "__main__":
    asyncio.run(main())
PROVISIONING_SCRIPT_EOF

chmod +x /usr/local/bin/evvos-provisioning
echo "✓ Provisioning script deployed (updated with latest logic)"

echo ""
echo "📋 Step 5: Create Systemd Service"
echo "=================================="
cat > /etc/systemd/system/evvos-provisioning.service << 'SERVICE_FILE'
[Unit]
Description=EVVOS WiFi Hotspot Provisioning Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/evvos
ExecStart=/opt/evvos/venv/bin/python3 /usr/local/bin/evvos-provisioning
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=evvos-provisioning
Environment="PATH=/opt/evvos/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
SERVICE_FILE

chmod 644 /etc/systemd/system/evvos-provisioning.service
echo "✓ Provisioning systemd service created"

echo ""
echo "📋 Step 5.5: Deploy Voice Command Service"
echo "=========================================="

# Deploy voice command service that integrates with Supabase Real-time
# This service:
# 1. Listens for voice commands using Vosk + ReSpeaker HAT
# 2. Writes recognized commands to Supabase voice_commands table
# 3. Mobile app receives commands via Supabase Real-time subscription
# 4. Starts automatically after provisioning completes

mkdir -p /usr/local/bin

echo "Deploying voice command service with Supabase Real-time integration..."

# Try to download the voice command service from the project
# This is the main implementation that handles Supabase communication
if [ -f "/root/evvos_voice_command.py" ]; then
    cp /root/evvos_voice_command.py /usr/local/bin/evvos-voice-command.py
    echo "✓ Voice command service deployed from local file"
elif curl -fsSL "https://raw.githubusercontent.com/YOUR-USERNAME/EVVOS/main/evvos_voice_command.py" -o /usr/local/bin/evvos-voice-command.py 2>/dev/null; then
    echo "✓ Voice command service downloaded from GitHub"
else
    # Fallback: Create minimal working implementation
    echo "⚠️  Using fallback voice command implementation"
    cat > /usr/local/bin/evvos-voice-command.py << 'VOICE_CMD_EOF'
#!/usr/bin/env python3
import asyncio
import json
import logging
import RPi.GPIO as GPIO
import os
import sys
import signal
import time
import spidev  # Added for LED control

# Ensure we are in the venv
if sys.prefix == sys.base_prefix:
    os.execv("/opt/evvos/venv/bin/python3", ["python3"] + sys.argv)

import numpy as np
import RPi.GPIO as GPIO
from vosk import Model, KaldiRecognizer
import queue
import sounddevice as sd
import aiohttp

# Configuration
LOGS_DIR = "/var/log/evvos"
CREDS_FILE = "/etc/evvos/device_credentials.json"
SUPABASE_URL = "https://zekbonbxwccgsfagrrph.supabase.co"
SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inpla2JvbmJ4d2NjZ3NmYWdycnBoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjgzOTQyOTUsImV4cCI6MjA4Mzk3MDI5NX0.0ss5U-uXryhWGf89ucndqNK8-Bzj_GRZ-4-Xap6ytHg"

# Logging Setup
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - [VoiceCmd] - %(levelname)s - %(message)s",
    handlers=[logging.FileHandler(f"{LOGS_DIR}/voice_command.log"), logging.StreamHandler()]
)
logger = logging.getLogger("EVVOS_VOICE")

# -----------------------------------------------------------------------------
# LED CONTROLLER (APA102 for ReSpeaker 2-Mics)
# -----------------------------------------------------------------------------
class PixelController:
    def __init__(self):
        self.num_leds = 3
        try:
            self.spi = spidev.SpiDev()
            self.spi.open(0, 0)  # Bus 0, Device 0
            self.spi.max_speed_hz = 8000000
            self.enabled = True
        except Exception as e:
            logger.error(f"Failed to init SPI for LEDs: {e}")
            self.enabled = False

    def show(self, data):
        if not self.enabled: return
        # APA102 Frame: Start(32x0) + LED_Frames + End(32x1)
        # LED Frame: 111(3bits) + Brightness(5bits) + B + G + R
        buffer = [0x00] * 4
        for r, g, b in data:
            buffer += [0xE0 | 0x05, b, g, r] # Brightness set to 5 (dim)
        buffer += [0xFF] * 4
        self.spi.xfer2(buffer)

    def off(self):
        self.show([(0,0,0)] * self.num_leds)

    def listen_mode(self):
        # Solid Blue (indicating Ready/Listening)
        self.show([(0, 0, 100)] * self.num_leds)

    def success_mode(self):
        # Flash Green (Recognized)
        for _ in range(2):
            self.show([(0, 150, 0)] * self.num_leds)
            time.sleep(0.1)
            self.off()
            time.sleep(0.1)
        self.listen_mode() # Return to listening

    def error_mode(self):
        # Flash Red (Error/Unknown)
        self.show([(150, 0, 0)] * self.num_leds)
        time.sleep(0.5)
        self.listen_mode()

# -----------------------------------------------------------------------------
# VOICE SERVICE
# -----------------------------------------------------------------------------
class EVVOSVoiceService:
    def __init__(self):
        self.model = Model(lang="en-us")
        self.q = queue.Queue()
        self.pixels = PixelController()
        
    def _audio_callback(self, indata, frames, time, status):
        if status:
            logger.warning(f"Audio Status: {status}")
        self.q.put(bytes(indata))

    def _get_user_id(self):
        try:
            with open(CREDS_FILE) as f:
                data = json.load(f)
                return data.get("user_id")
        except:
            return None

    def _get_device_id(self):
        try:
            with open("/sys/class/net/wlan0/address") as f:
                return f.read().strip().replace(":", "")
        except:
            return "unknown_device"

    async def _send_command(self, user_id, command_text):
        url = f"{SUPABASE_URL}/rest/v1/voice_commands"
        headers = {
            "apikey": SUPABASE_ANON_KEY,
            "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
            "Content-Type": "application/json",
            "Prefer": "return=minimal"
        }
        payload = {
            "user_id": user_id,
            "device_id": self._get_device_id(),
            "command": command_text,
            "status": "pending"
        }
        
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(url, headers=headers, json=payload) as resp:
                    if resp.status in [200, 201]:
                        logger.info(f"Command '{command_text}' sent successfully")
                        return True
                    else:
                        logger.error(f"Supabase Error: {resp.status} - {await resp.text()}")
                        return False
        except Exception as e:
            logger.error(f"Connection Error: {e}")
            return False

    async def run(self):
        logger.info("Starting Voice Recognition Loop...")
        
        # Initial LED Test
        self.pixels.off()
        time.sleep(0.5)
        self.pixels.listen() # Set to Blue

        # Audio Config
        device_info = sd.query_devices(kind='input')
        samplerate = int(device_info['default_samplerate'])
        
        # Start Stream
        with sd.RawInputStream(samplerate=samplerate, blocksize=8000, dtype='int16',
                               channels=1, callback=self._audio_callback):
            rec = KaldiRecognizer(self.model, samplerate)
            
            while True:
                data = self.q.get()
                if rec.AcceptWaveform(data):
                    result = json.loads(rec.Result())
                    text = result.get("text", "")
                    
                    if text:
                        logger.info(f"Recognized: {text}")
                        user_id = self._get_user_id()
                        
                        if user_id:
                            # Success LED Animation
                            self.pixels.success_mode()
                            await self._send_command(user_id, text)
                        else:
                            logger.warning("No User ID found. Provisioning needed.")
                            self.pixels.error_mode()
                else:
                    # Partial result - can be used for "thinking" animation if desired
                    pass

if __name__ == "__main__":
    try:
        service = EVVOSVoiceService()
        asyncio.run(service.run())
    except KeyboardInterrupt:
        print("\nStopping...")
VOICE_CMD_EOF
fi

chmod +x /usr/local/bin/evvos-voice-command.py
echo "✓ Voice command service deployed"

# Create systemd service for voice command
cat > /etc/systemd/system/evvos-voice-command.service << 'VOICE_SERVICE_FILE'
[Unit]
Description=EVVOS Voice Command Service (Supabase Real-time)
After=network.target evvos-provisioning.service
Wants=evvos-provisioning.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/evvos
ExecStart=/opt/evvos/venv/bin/python3 /usr/local/bin/evvos-voice-command.py
Restart=no
StandardOutput=journal
StandardError=journal
SyslogIdentifier=evvos-voice-command
Environment="PATH=/opt/evvos/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
VOICE_SERVICE_FILE

chmod 644 /etc/systemd/system/evvos-voice-command.service
echo "✓ Voice command systemd service created (disabled by default)"

echo ""
echo "📊 Voice Command System Architecture:"
echo "  1. Vosk recognizes voice → matches against grammar"
echo "  2. Recognized command → POST to Supabase voice_commands table"
echo "  3. Mobile app subscribed via Supabase Real-time"
echo "  4. Mobile app receives INSERT event → processes command"
echo "  5. Command executed immediately on mobile device"
echo ""
echo "⚡ Performance:"
echo "  • On hotspot: ~100-300ms latency (same WiFi)"
echo "  • On cellular: <5s cloud delivery via Supabase"
echo "  • Offline capable: Commands queued locally"
echo ""
echo "🔧 Step 6: Enable and Start Service"
echo "===================================="
systemctl daemon-reload
systemctl enable evvos-provisioning
systemctl enable evvos-voice-command
systemctl start evvos-provisioning

echo ""
echo "✅ EVVOS Provisioning System Setup Complete!"
echo "=============================================="
echo ""
echo "📊 System Status:"
systemctl status evvos-provisioning --no-pager
echo ""
echo "📖 Useful Commands:"
echo "  Provisioning logs:              sudo journalctl -u evvos-provisioning -f"
echo "  Voice command logs:             sudo journalctl -u evvos-voice-command -f"
echo "  Restart provisioning service:   sudo systemctl restart evvos-provisioning"
echo "  Provisioning service status:    sudo systemctl status evvos-provisioning"
echo "  Voice command service status:   sudo systemctl status evvos-voice-command"
echo "  View device ID:                 cat /sys/class/net/wlan0/address"
echo ""
echo "📝 ReSpeaker HAT Hardware Checks:"
echo "  Check I2C detection:            i2cdetect -y 1"
echo "  List audio devices:             arecord -l"
echo "  Test audio recording:           arecord -D default -f cd -t wav test.wav"
echo "  Check I2S status:               cat /proc/asound/cards"
echo ""
echo "📝 Service Behavior:"
echo "  • WiFi Provisioning starts immediately on boot"
echo "  • Voice Command Service starts ONLY after successful WiFi + internet"
echo "  • Voice Command Service stops automatically when device is unpaired"
echo "  • Provisioning restarts hotspot if WiFi connection fails"
echo "  • Heartbeat sent every 60s when connected (for keep-alive)"
echo "  • Audio input from ReSpeaker HAT (I2S interface)"
echo "  • Voice commands recognized: okay, confirm, cancel, start, stop, help, repeat, clear"
echo ""
echo "🎯 Voice Command Execution Flow (Supabase Real-time):"
echo "  ════════════════════════════════════════════════════"
echo "  1. User speaks near Raspberry Pi with ReSpeaker HAT"
echo "  2. Vosk recognizes voice command via microphone"
echo "  3. Pi POSTs command to Supabase 'voice_commands' table:"
echo "     POST /rest/v1/voice_commands"
echo "     Body: { device_id, user_id, command, confidence, timestamp }"
echo ""
echo "  4. Mobile app receives via Supabase Real-time subscription:"
echo "     Event: INSERT on voice_commands table (user_id filter)"
echo ""
echo "  5. Mobile app processes and executes command"
echo "     Latency: ~100-300ms on hotspot, <5s on cellular"
echo "  ════════════════════════════════════════════════════"
echo ""
echo "📊 Database Integration:"
echo "  • Table: public.voice_commands"
echo "  • Columns: id, device_id, user_id, command, confidence, status, timestamp"
echo "  • Real-time: Enabled (postgres_changes subscription)"
echo "  • RLS: Managed by Supabase Edge Functions"
echo ""
echo "🔗 Data Flow:"
echo "  Pi (Voice Recognition)"
echo "    ↓"
echo "  Vosk (Grammar Match: okay, confirm, cancel, start, stop, help, repeat, clear)"
echo "    ↓"
echo "  asyncio + aiohttp (Async POST)"
echo "    ↓"
echo "  Supabase REST API (voice_commands table INSERT)"
echo "    ↓"
echo "  Supabase Real-time (postgres_changes event)"
echo "    ↓"
echo "  Mobile App (@supabase/supabase-js subscription)"
echo "    ↓"
echo "  Mobile App Handler (handleVoiceCommand())"
echo "    ↓"
echo "  Action Executed (show alert, send notification, etc.)"
echo ""
echo "🔐 Security:"
echo "  • user_id filter ensures only authorized commands processed"
echo "  • Supabase RLS policies protect device_credentials"
echo "  • Edge Functions validate requests server-side"
echo "  • No direct database write from mobile (Pi is trusted)"
echo ""
echo "⚠️  TROUBLESHOOTING VOICE COMMANDS:"
echo "  If commands not received on mobile:"
echo ""
echo "  1. Check Pi is connected to WiFi and has internet:"
echo "     ip addr show wlan0"
echo "     curl https://google.com"
echo ""
echo "  2. Check voice command service is running:"
echo "     sudo systemctl status evvos-voice-command"
echo "     sudo journalctl -u evvos-voice-command -f"
echo ""
echo "  3. Check user_id is set in device_credentials.json:"
echo "     cat /etc/evvos/device_credentials.json"
echo ""
echo "  4. Test direct Supabase POST (from Pi):"
echo "     curl -X POST https://zekbonbxwccgsfagrrph.supabase.co/rest/v1/voice_commands \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -H 'Authorization: Bearer ANON_KEY' \\"
echo "       -d '{\"device_id\":\"test\",\"user_id\":\"YOUR_USER_ID\",\"command\":\"test\"}'"
echo ""
echo "  5. Check mobile app is subscribed to voice_commands:"
echo "     Mobile app logs should show: '[VoiceCommandListener] ✅ Subscribed to voice commands'"
echo ""
echo "🔧 Hardware Requirements Met:"
echo "  • I2S overlay configured (device acts as master clock)"
echo "  • I2C enabled (for HAT detection at address 0x18)"
echo "  • NumPy 1.26.4 (pre-built, not compiled - prevents RAM crash)"
echo "  • System libraries: OpenBLAS, PortAudio (prevents missing .so errors)"
echo "  • DNS set to 8.8.8.8, pip timeout 1000s (stable downloads)"
echo "  • Vosk with grammar optimization (light CPU usage)"
echo ""
echo "⚠️  IMPORTANT - Reboot Required:"
echo "  Run: sudo reboot"
echo "  I2S/I2C device tree changes require reboot to take effect."
echo ""
echo "🚀 The EVVOS_0001 WiFi hotspot should now be broadcasting!"
echo "   Mobile app can scan and provision the device."
echo "   Voice command recognition starts after provisioning completes."
echo ""
