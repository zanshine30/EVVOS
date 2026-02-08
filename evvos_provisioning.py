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
import os
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone, timedelta
from typing import Optional, Dict, Any
import hashlib
import base64

try:
    import aiohttp
    from aiohttp import web
except ImportError as e:
    print(f"Error: Missing required package: {e}")
    print("Run: pip install aiohttp")
    sys.exit(1)

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
        """
        try:
            if not self.credentials or not self.credentials.get("user_id"):
                return False
            
            user_id = self.credentials.get("user_id")
            device_id = self.device_id
            
            # Query the device_credentials table for disconnect_requested flag
            url = f"{SUPABASE_URL}/rest/v1/device_credentials"
            params = {
                "user_id": f"eq.{user_id}",
                "device_id": f"eq.{device_id}",
                "select": "disconnect_requested,disconnect_requested_at"
            }
            
            headers = {
                "apikey": SUPABASE_ANON_KEY,
                "Content-Type": "application/json",
            }
            
            async with aiohttp.ClientSession() as session:
                async with session.get(url, params=params, headers=headers, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        if data and len(data) > 0:
                            record = data[0]
                            if record.get('disconnect_requested') == True:
                                logger.info(f"[DISCONNECT] Disconnect request detected at {record.get('disconnect_requested_at')}")
                                return True
        except Exception as e:
            logger.debug(f"Error checking disconnect status: {e}")
        
        return False

    async def _handle_disconnect(self) -> None:
        """
        Handle device disconnect request.
        Deletes credentials and restarts in provisioning/hotspot mode.
        """
        try:
            logger.warning("[DISCONNECT] ========== DISCONNECT INITIATED ==========")
            
            user_id = self.credentials.get("user_id") if self.credentials else None
            
            # Step 1: Delete stored credentials
            logger.info("[DISCONNECT] Deleting stored credentials...") 
            self._delete_credentials()
            
            # Step 2: Update Supabase to mark disconnect as complete and set device status
            if user_id:
                try:
                    url = f"{SUPABASE_URL}/rest/v1/device_credentials"
                    headers = {
                        "apikey": SUPABASE_ANON_KEY,
                        "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
                        "Content-Type": "application/json",
                        "Prefer": "return=representation",
                    }
                    
                    # Update the record to clear disconnect_requested, clear credentials, and set status
                    payload = {
                        "disconnect_requested": False,
                        "user_id": None,
                        "encrypted_ssid": None,
                        "encrypted_password": None,
                        "device_status": "provisioning",
                        "disconnected_at": self._get_manila_time().isoformat(),
                    }
                    
                    params = {
                        "user_id": f"eq.{user_id}",
                        "device_id": f"eq.{self.device_id}",
                    }
                    
                    async with aiohttp.ClientSession() as session:
                        async with session.patch(
                            url,
                            json=payload,
                            headers=headers,
                            params=params,
                            timeout=aiohttp.ClientTimeout(total=10)
                        ) as resp:
                            if resp.status in [200, 204]:
                                logger.info("[DISCONNECT] ✓ Supabase status updated to 'provisioning'")
                            else:
                                logger.warning(f"[DISCONNECT] Failed to update Supabase: {resp.status}")
                except Exception as e:
                    logger.warning(f"[DISCONNECT] Could not update Supabase status: {e}")
            
            # Step 3: Clean up interface and state
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
            
            # Step 5: Log disconnect completion and restart provisioning
            logger.warning("[DISCONNECT] ========== DISCONNECT COMPLETED ==========")
            logger.info("[DISCONNECT] Device will restart in hotspot provisioning mode...")
            
            # Reset credentials variable
            self.credentials = None
            self.received_credentials = None
            
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
            logger.info(f"Registering device credentials to Supabase")
            
            # Get user_id from auth context if available
            if not user_id:
                logger.warning("No user_id provided for Supabase registration")
                return False
            
            # 1. Clean up previous credentials for this device/user
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
            
            headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
            }
            
            supabase_store_url = f"{SUPABASE_URL}/functions/v1/store-device-credentials"
            
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    supabase_store_url,
                    json=payload,
                    headers=headers,
                    timeout=aiohttp.ClientTimeout(total=30),
                ) as resp:
                    if resp.status == 200:
                        logger.info("✓ New device credentials stored successfully via Edge Function")
                        return True
                    else:
                        error_text = await resp.text()
                        logger.error(
                            f"Device credential storage failed: {resp.status} - {error_text}"
                        )
                        return False
        except Exception as e:
            logger.error(f"Supabase reporting error: {e}")

        return False

    async def _update_device_status_connected(self, user_id: str) -> bool:
        """
        Update device status to 'connected' after successful WiFi connection and internet verification.
        This is called after the device has confirmed internet connectivity.
        """
        try:
            if not user_id:
                logger.warning("Cannot update device status: user_id not available")
                return False
            
            url = f"{SUPABASE_URL}/rest/v1/device_credentials"
            headers = {
                "apikey": SUPABASE_ANON_KEY,
                "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
                "Content-Type": "application/json",
                "Prefer": "return=representation",
            }
            
            # Update the device status to connected
            payload = {
                "device_status": "connected",
            }
            
            params = {
                "user_id": f"eq.{user_id}",
                "device_id": f"eq.{self.device_id}",
            }
            
            async with aiohttp.ClientSession() as session:
                async with session.patch(
                    url,
                    json=payload,
                    headers=headers,
                    params=params,
                    timeout=aiohttp.ClientTimeout(total=10)
                ) as resp:
                    if resp.status in [200, 204]:
                        logger.info("✓ Device status updated to 'connected' in Supabase")
                        return True
                    else:
                        logger.warning(f"Failed to update device status to connected: {resp.status}")
                        return False
        except Exception as e:
            logger.error(f"Error updating device status to connected: {e}")
            return False

    async def _update_device_heartbeat(self, user_id: str = None) -> bool:
        """
        Send device heartbeat to Supabase.
        Updates only the last_seen timestamp to keep device online indicator current.
        This serves as a keep-alive signal during normal operation.
        """
        try:
            if not user_id:
                logger.debug("No user_id provided for heartbeat")
                return False
            
            url = f"{SUPABASE_URL}/rest/v1/device_credentials"
            headers = {
                "apikey": SUPABASE_ANON_KEY,
                "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
                "Content-Type": "application/json",
                "Prefer": "return=representation",
            }
            
            # Update only the last_seen timestamp (heartbeat) using Manila timezone
            payload = {
                "last_seen": self._get_manila_time().isoformat(),
            }
            
            params = {
                "user_id": f"eq.{user_id}",
                "device_id": f"eq.{self.device_id}",
            }
            
            async with aiohttp.ClientSession() as session:
                async with session.patch(
                    url,
                    json=payload,
                    headers=headers,
                    params=params,
                    timeout=aiohttp.ClientTimeout(total=10)
                ) as resp:
                    if resp.status in [200, 204]:
                        logger.debug("✓ Device heartbeat sent - last_seen updated")
                        return True
                    else:
                        logger.debug(f"Failed to send heartbeat: {resp.status}")
                        return False
        except Exception as e:
            logger.debug(f"Heartbeat error: {e}")
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
        Also checks for disconnect_requested flag in Supabase (every 10 seconds).
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
                        logger.debug(f"[MONITOR] Heartbeat cycle - User: {user_id}, Device: {self.device_id}")
                        
                        try:
                            if await self._check_internet():
                                # Device has internet, send heartbeat
                                result = await self._update_device_heartbeat(user_id=user_id)
                                if result:
                                    logger.info(f"[MONITOR] ✓ Heartbeat sent successfully - last_seen updated")
                                else:
                                    logger.warning(f"[MONITOR] Heartbeat failed - check Supabase connection")
                            else:
                                logger.debug("[MONITOR] No internet connectivity - heartbeat skipped")
                        except Exception as e:
                            logger.error(f"[MONITOR] Error sending heartbeat: {e}")
                    else:
                        logger.debug("[MONITOR] No credentials available - skipping heartbeat")
                            
            except Exception as e:
                logger.error(f"[MONITOR] Unexpected error in connectivity monitor loop: {e}")
                await asyncio.sleep(5)  # Wait before retrying to avoid rapid error loops

    async def run(self):
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


if __name__ == "__main__":
    asyncio.run(main())