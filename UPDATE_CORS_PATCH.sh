#!/bin/bash
# Minimal CORS patch - only updates app.py without reinstalling
# Usage: sudo bash UPDATE_CORS_PATCH.sh

echo "🔧 Patching Flask app with CORS headers fix..."

# Update app.py with CORS support
sudo tee /opt/evvos/provisioning/app.py > /dev/null << 'EOF'
#!/usr/bin/env python3
"""
EVVOS Provisioning Server
Runs on http://192.168.4.1:5000/provision to receive WiFi credentials from mobile app.
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

def add_cors_headers(response):
    """Add CORS headers to response"""
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS, GET'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type'
    return response

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
            response = jsonify({'error': 'Missing required fields (token, ssid, password)'})
            return add_cors_headers(response), 400
        
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
            response = jsonify({'error': 'Failed to store credentials'})
            return add_cors_headers(response), 500
        
        logger.info("✅ Credentials stored")
        
        # Start background provisioning handler
        provision_complete_handler()
        
        response = jsonify({
            'ok': True,
            'message': 'Credentials received. Please enable your hotspot now.',
            'status': 'waiting_for_hotspot'
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
EOF

echo "✅ app.py patched with CORS headers"
echo "🔄 Restarting provisioning service..."
sudo systemctl restart evvos-provisioning

sleep 2
echo "📡 Service status:"
sudo systemctl status evvos-provisioning --no-pager

echo ""
echo "✨ CORS patch complete! The server now accepts requests from the mobile app."
