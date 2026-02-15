#!/bin/bash
# Pi Camera Rev 1.3 Setup for Raspberry Pi Zero 2 W + TCP Socket Control
# Optimized for: Raspberry Pi OS (Legacy) Lite, 32-bit, Bookworm 12, Kernel 6.12
# Full-duplex TCP socket control from EVVOS React Native app
# Camera service starts on-demand when 'START_RECORDING' command received
#
# Usage: sudo bash setup_picam_recording_tcp.sh

set -e  # Exit on error

# ============================================================================
# CONFIGURATION & COLOR OUTPUT
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC}  $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }
log_section() { echo ""; echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}▶ $1${NC}"; echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"; }

# ============================================================================
# PREFLIGHT CHECKS
# ============================================================================

log_section "Preflight System Checks"

if [ "$EUID" -ne 0 ]; then 
    log_error "This script must be run as root"
    echo "Usage: sudo bash setup_picam_recording_tcp.sh"
    exit 1
fi
log_success "Running as root"

# Check Python3
if ! command -v python3 &> /dev/null; then
    log_error "Python3 not found"
    exit 1
fi
PYTHON_VERSION=$(python3 --version | awk '{print $2}')
log_success "Python3 detected: $PYTHON_VERSION"

# Check kernel version
KERNEL_VERSION=$(uname -r)
log_success "Kernel version: $KERNEL_VERSION"

# Detect config.txt location
CONFIG_FILE=""
if [ -f "/boot/firmware/config.txt" ]; then
    CONFIG_FILE="/boot/firmware/config.txt"
elif [ -f "/boot/config.txt" ]; then
    CONFIG_FILE="/boot/config.txt"
else
    log_error "config.txt not found"
    exit 1
fi
log_success "Config file: $CONFIG_FILE"

# ============================================================================
# STEP 1: ENABLE CAMERA INTERFACE
# ============================================================================

log_section "Step 1: Enabling Pi Camera Interface"

# Enable legacy camera support for Pi Camera Rev 1.3
if ! grep -q "^start_x=1" "$CONFIG_FILE"; then
    echo "start_x=1" >> "$CONFIG_FILE"
    log_success "Enabled camera firmware (start_x=1)"
else
    log_info "Camera firmware already enabled"
fi

# Allocate GPU memory for camera
if ! grep -q "^gpu_mem=" "$CONFIG_FILE"; then
    echo "gpu_mem=128" >> "$CONFIG_FILE"
    log_success "Set GPU memory to 128MB"
else
    log_info "GPU memory already configured"
fi

# Disable camera LED (optional - for covert recording)
if ! grep -q "^disable_camera_led=" "$CONFIG_FILE"; then
    echo "disable_camera_led=1" >> "$CONFIG_FILE"
    log_success "Camera LED disabled"
else
    log_info "Camera LED setting already configured"
fi

log_success "Camera interface enabled in $CONFIG_FILE"

# ============================================================================
# STEP 2: INSTALL CAMERA DEPENDENCIES
# ============================================================================

log_section "Step 2: Installing Camera Dependencies"

apt-get update -qq
apt-get install -y python3-picamera2 python3-opencv ffmpeg --no-install-recommends
log_success "Installed picamera2, opencv, and ffmpeg"

# ============================================================================
# STEP 3: CREATE TCP CAMERA SERVICE SCRIPT
# ============================================================================

log_section "Step 3: Creating TCP Camera Service Script"

CAMERA_SCRIPT="/usr/local/bin/evvos-picam-tcp.py"

cat > "$CAMERA_SCRIPT" << 'CAMERA_SCRIPT_EOF'
#!/usr/bin/env python3
"""
EVVOS Pi Camera TCP Control Service
Listens for START_RECORDING/STOP_RECORDING commands from React Native app
Records H.264 video + WAV audio to /home/pi/recordings/
Sends file paths back to app for Supabase upload
"""

import socket
import json
import os
import sys
import time
import threading
from datetime import datetime
from pathlib import Path

# Camera imports
try:
    from picamera2 import Picamera2
    from picamera2.encoders import H264Encoder
    from picamera2.outputs import FileOutput
except ImportError:
    print("[CAMERA] ERROR: picamera2 not installed", file=sys.stderr)
    sys.exit(1)

# Audio recording (using arecord for ReSpeaker)
import subprocess

# ============================================================================
# CONFIGURATION
# ============================================================================

TCP_HOST = "0.0.0.0"  # Listen on all interfaces
TCP_PORT = 3001       # Different port from voice service (3000)
RECORDINGS_DIR = Path("/home/pi/recordings")
CAMERA_RESOLUTION = (1920, 1080)  # Full HD
CAMERA_FPS = 30
HTTP_PORT = 8080      # HTTP server for file downloads

# ============================================================================
# GLOBAL STATE
# ============================================================================

camera = None
recording = False
current_video_path = None
current_audio_path = None
current_session_id = None
audio_process = None
recording_lock = threading.Lock()
pi_ip_address = None  # Will be auto-detected

# ============================================================================
# CAMERA SETUP
# ============================================================================

def get_pi_ip_address():
    """Get Pi's local IP address"""
    try:
        # Try to get IP from wlan0 first (most common for Pi Zero W)
        result = subprocess.run(['ip', 'addr', 'show', 'wlan0'], 
                              capture_output=True, text=True, timeout=2)
        for line in result.stdout.split('\n'):
            if 'inet ' in line and not '127.0.0.1' in line:
                ip = line.strip().split()[1].split('/')[0]
                print(f"[NETWORK] Detected Pi IP: {ip} (wlan0)")
                return ip
        
        # Fallback to eth0
        result = subprocess.run(['ip', 'addr', 'show', 'eth0'], 
                              capture_output=True, text=True, timeout=2)
        for line in result.stdout.split('\n'):
            if 'inet ' in line and not '127.0.0.1' in line:
                ip = line.strip().split()[1].split('/')[0]
                print(f"[NETWORK] Detected Pi IP: {ip} (eth0)")
                return ip
    except Exception as e:
        print(f"[NETWORK] Could not detect IP: {e}", file=sys.stderr)
    
    return None

def setup_camera():
    """Initialize Pi Camera"""
    global camera
    try:
        print("[CAMERA] Initializing Pi Camera Rev 1.3...")
        camera = Picamera2()
        
        # Configure for video recording
        video_config = camera.create_video_configuration(
            main={"size": CAMERA_RESOLUTION, "format": "RGB888"},
            controls={"FrameRate": CAMERA_FPS}
        )
        camera.configure(video_config)
        
        print(f"[CAMERA] Camera configured: {CAMERA_RESOLUTION[0]}x{CAMERA_RESOLUTION[1]} @ {CAMERA_FPS}fps")
        return True
    except Exception as e:
        print(f"[CAMERA] ERROR: Failed to initialize camera: {e}", file=sys.stderr)
        return False

# ============================================================================
# RECORDING FUNCTIONS
# ============================================================================

def start_recording_handler():
    """Start video + audio recording"""
    global recording, current_video_path, current_audio_path, current_session_id, audio_process
    
    with recording_lock:
        if recording:
            print("[CAMERA] Already recording, ignoring START_RECORDING")
            return {"status": "already_recording"}
        
        try:
            # Create recordings directory
            RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
            
            # Generate timestamped filename and session ID
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            current_session_id = f"session_{timestamp}"
            current_video_path = RECORDINGS_DIR / f"video_{timestamp}.h264"
            current_audio_path = RECORDINGS_DIR / f"audio_{timestamp}.wav"
            
            print(f"[CAMERA] Starting recording...")
            print(f"[CAMERA]   Session ID: {current_session_id}")
            print(f"[CAMERA]   Video: {current_video_path}")
            print(f"[CAMERA]   Audio: {current_audio_path}")
            
            # Start camera recording
            camera.start()
            encoder = H264Encoder(bitrate=10000000)  # 10 Mbps
            camera.start_recording(encoder, str(current_video_path))
            
            # Start audio recording (ReSpeaker HAT)
            # Using arecord with 48kHz (ReSpeaker native sample rate)
            audio_process = subprocess.Popen([
                "arecord",
                "-D", "plughw:seeed2micvoicec",  # ReSpeaker card
                "-f", "S16_LE",
                "-r", "48000",
                "-c", "2",  # Stereo
                str(current_audio_path)
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            recording = True
            print("[CAMERA] ✓ Recording started successfully")
            
            return {
                "status": "recording_started",
                "session_id": current_session_id,
                "video_path": str(current_video_path),
                "audio_path": str(current_audio_path),
                "timestamp": timestamp,
                "pi_ip": pi_ip_address,
                "http_port": HTTP_PORT
            }
            
        except Exception as e:
            print(f"[CAMERA] ERROR: Failed to start recording: {e}", file=sys.stderr)
            recording = False
            return {"status": "error", "message": str(e)}

def stop_recording_handler():
    """Stop video + audio recording"""
    global recording, audio_process, current_session_id
    
    with recording_lock:
        if not recording:
            print("[CAMERA] Not currently recording, ignoring STOP_RECORDING")
            return {"status": "not_recording"}
        
        try:
            print("[CAMERA] Stopping recording...")
            
            # Stop camera
            camera.stop_recording()
            camera.stop()
            
            # Stop audio
            if audio_process:
                audio_process.terminate()
                audio_process.wait(timeout=5)
                audio_process = None
            
            recording = False
            
            video_size = current_video_path.stat().st_size if current_video_path.exists() else 0
            audio_size = current_audio_path.stat().st_size if current_audio_path.exists() else 0
            
            print(f"[CAMERA] ✓ Recording stopped")
            print(f"[CAMERA]   Video size: {video_size / 1024 / 1024:.2f} MB")
            print(f"[CAMERA]   Audio size: {audio_size / 1024 / 1024:.2f} MB")
            
            # Return comprehensive recording info for app to upload to Supabase
            response = {
                "status": "recording_stopped",
                "session_id": current_session_id,
                "video_path": str(current_video_path),
                "audio_path": str(current_audio_path),
                "video_filename": current_video_path.name,
                "audio_filename": current_audio_path.name,
                "video_size_bytes": video_size,
                "audio_size_bytes": audio_size,
                "video_size_mb": round(video_size / 1024 / 1024, 2),
                "audio_size_mb": round(audio_size / 1024 / 1024, 2),
                "pi_ip": pi_ip_address,
                "http_port": HTTP_PORT,
                # URLs for direct download from Pi (if needed)
                "video_url": f"http://{pi_ip_address}:{HTTP_PORT}/{current_video_path.name}" if pi_ip_address else None,
                "audio_url": f"http://{pi_ip_address}:{HTTP_PORT}/{current_audio_path.name}" if pi_ip_address else None
            }
            
            print(f"[CAMERA] Session data ready for upload to Supabase")
            return response
            
        except Exception as e:
            print(f"[CAMERA] ERROR: Failed to stop recording: {e}", file=sys.stderr)
            recording = False
            return {"status": "error", "message": str(e)}

# ============================================================================
# HTTP FILE SERVER (for serving recordings to app)
# ============================================================================

from http.server import HTTPServer, SimpleHTTPRequestHandler
import urllib.parse

class RecordingFileHandler(SimpleHTTPRequestHandler):
    """Custom HTTP handler to serve recording files"""
    
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(RECORDINGS_DIR), **kwargs)
    
    def log_message(self, format, *args):
        """Suppress HTTP server logs (already logged by main service)"""
        pass
    
    def end_headers(self):
        # Add CORS headers for React Native
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')
        super().end_headers()
    
    def do_OPTIONS(self):
        self.send_response(200)
        self.end_headers()

def start_http_server():
    """Start HTTP server for serving recording files"""
    try:
        server = HTTPServer(('0.0.0.0', HTTP_PORT), RecordingFileHandler)
        print(f"[HTTP] File server listening on port {HTTP_PORT}")
        print(f"[HTTP] Serving files from: {RECORDINGS_DIR}")
        server.serve_forever()
    except Exception as e:
        print(f"[HTTP] ERROR: Failed to start HTTP server: {e}", file=sys.stderr)

# ============================================================================
# TCP SERVER
# ============================================================================

def get_recording_info_handler():
    """Get current recording session info (for reconnection scenarios)"""
    with recording_lock:
        if not recording or not current_session_id:
            return {
                "status": "no_active_recording",
                "session_id": None
            }
        
        return {
            "status": "recording_active",
            "session_id": current_session_id,
            "video_path": str(current_video_path),
            "audio_path": str(current_audio_path),
            "pi_ip": pi_ip_address,
            "http_port": HTTP_PORT
        }

def handle_client(conn, addr):
    """Handle incoming TCP commands from React Native app"""
    print(f"[TCP] Client connected: {addr}")
    buffer = ""
    
    try:
        while True:
            data = conn.recv(1024)
            if not data:
                break
            
            buffer += data.decode('utf-8')
            
            # Process complete messages (newline-delimited)
            while '\n' in buffer:
                line, buffer = buffer.split('\n', 1)
                line = line.strip()
                
                if not line:
                    continue
                
                try:
                    payload = json.loads(line)
                    intent = payload.get('intent', '').upper()
                    command_id = payload.get('id', 'unknown')
                    
                    print(f"[TCP] Received command: {intent} (ID: {command_id})")
                    
                    # Handle commands
                    if intent == "START_RECORDING":
                        result = start_recording_handler()
                        response = json.dumps(result) + "\n"
                        conn.sendall(response.encode('utf-8'))
                        
                    elif intent == "STOP_RECORDING":
                        result = stop_recording_handler()
                        response = json.dumps(result) + "\n"
                        conn.sendall(response.encode('utf-8'))
                    
                    elif intent == "GET_RECORDING":
                        # Get current recording info (useful for app reconnection)
                        result = get_recording_info_handler()
                        response = json.dumps(result) + "\n"
                        conn.sendall(response.encode('utf-8'))
                        
                    else:
                        print(f"[TCP] Unknown command: {intent}")
                        response = json.dumps({"status": "unknown_command", "intent": intent}) + "\n"
                        conn.sendall(response.encode('utf-8'))
                        
                except json.JSONDecodeError as e:
                    print(f"[TCP] JSON parse error: {e}", file=sys.stderr)
                    
    except Exception as e:
        print(f"[TCP] Connection error: {e}", file=sys.stderr)
    finally:
        conn.close()
        print(f"[TCP] Client disconnected: {addr}")

def start_tcp_server():
    """Start TCP server listening for camera commands"""
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((TCP_HOST, TCP_PORT))
    server.listen(5)
    
    print(f"[TCP] Camera service listening on {TCP_HOST}:{TCP_PORT}")
    print("[TCP] Waiting for commands from EVVOS app...")
    
    try:
        while True:
            conn, addr = server.accept()
            # Handle each client in a separate thread
            client_thread = threading.Thread(target=handle_client, args=(conn, addr))
            client_thread.daemon = True
            client_thread.start()
    except KeyboardInterrupt:
        print("\n[TCP] Server shutting down...")
    finally:
        if recording:
            stop_recording_handler()
        server.close()

# ============================================================================
# MAIN
# ============================================================================

if __name__ == "__main__":
    print("=" * 60)
    print("EVVOS Pi Camera TCP Control Service")
    print("=" * 60)
    
    # Detect Pi IP address
    global pi_ip_address
    pi_ip_address = get_pi_ip_address()
    if not pi_ip_address:
        print("[WARNING] Could not detect Pi IP address - file URLs will be unavailable")
    
    # Initialize camera
    if not setup_camera():
        print("[CAMERA] Failed to initialize camera, exiting...")
        sys.exit(1)
    
    # Start HTTP file server in background thread
    http_thread = threading.Thread(target=start_http_server, daemon=True)
    http_thread.start()
    
    # Start TCP command server (main thread)
    start_tcp_server()
CAMERA_SCRIPT_EOF

chmod +x "$CAMERA_SCRIPT"
log_success "Created camera service script: $CAMERA_SCRIPT"

# ============================================================================
# STEP 4: CREATE SYSTEMD SERVICE
# ============================================================================

log_section "Step 4: Creating Systemd Service"

SERVICE_FILE="/etc/systemd/system/evvos-picam-tcp.service"

cat > "$SERVICE_FILE" << SERVICE_EOF
[Unit]
Description=EVVOS Pi Camera TCP Control Service
After=network.target sound.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 $CAMERA_SCRIPT
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

# Environment
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
SERVICE_EOF

log_success "Created systemd service: $SERVICE_FILE"

# ============================================================================
# STEP 5: CREATE RECORDINGS DIRECTORY
# ============================================================================

log_section "Step 5: Creating Recordings Directory"

mkdir -p /home/pi/recordings
chown pi:pi /home/pi/recordings
chmod 755 /home/pi/recordings
log_success "Created /home/pi/recordings"

# ============================================================================
# STEP 6: ENABLE AND START SERVICE
# ============================================================================

log_section "Step 6: Enabling Service"

systemctl daemon-reload
systemctl enable evvos-picam-tcp.service
systemctl start evvos-picam-tcp.service
log_success "Service enabled and started"

sleep 2
echo ""
systemctl status evvos-picam-tcp --no-pager 2>&1 | head -15
echo ""

# ============================================================================
# SUMMARY
# ============================================================================

log_section "Pi Camera TCP Service Setup Complete!"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Pi Camera TCP Control Service Installed!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

log_info "Configuration Summary:"
echo "  • Hardware: Raspberry Pi Zero 2 W + Pi Camera Rev 1.3"
echo "  • Resolution: 1920x1080 @ 30fps"
echo "  • Audio: ReSpeaker 2-Mics HAT (48kHz stereo)"
echo "  • TCP Port: 3001 (command control)"
echo "  • HTTP Port: 8080 (file serving)"
echo "  • Service: evvos-picam-tcp.service"
echo "  • Recordings: /home/pi/recordings/"
echo "  • Supabase Bucket: incident-videos"
echo "  • File Size Limit: 50MB per file"
echo ""

log_info "Supported Commands (via TCP socket):"
echo "  • ${CYAN}START_RECORDING${NC}: Begin video + audio capture"
echo "  • ${CYAN}STOP_RECORDING${NC}: End recording and return file paths"
echo "  • ${CYAN}GET_RECORDING${NC}: Get current recording session info"
echo ""

log_info "Recording Flow:"
echo "  1. App sends START_RECORDING to Pi"
echo "  2. Pi starts camera + audio recording"
echo "  3. Pi responds with session_id, file paths, Pi IP"
echo "  4. User fills incident report in app"
echo "  5. App sends STOP_RECORDING to Pi"
echo "  6. Pi stops recording, returns file info"
echo "  7. User submits incident report"
echo "  8. App downloads files from Pi HTTP server"
echo "  9. App uploads to Supabase 'incident-videos' bucket"
echo "  10. App associates video with incident record"
echo ""

log_info "React Native App Integration:"
echo ""
echo "  ${CYAN}# Connect to Pi Camera Service${NC}"
echo "  const socket = TcpSocket.createConnection({ port: 3001, host: 'PI_IP' });"
echo ""
echo "  ${CYAN}# Start Recording${NC}"
echo "  socket.write(JSON.stringify({intent: 'START_RECORDING', id: '123'}) + '\n');"
echo "  // Pi responds: {status: 'recording_started', session_id: '...', video_path: '...', ...}"
echo ""
echo "  ${CYAN}# Stop Recording${NC}"
echo "  socket.write(JSON.stringify({intent: 'STOP_RECORDING', id: '124'}) + '\n');"
echo "  // Pi responds: {status: 'recording_stopped', video_url: 'http://...', ...}"
echo ""
echo "  ${CYAN}# Download and Upload to Supabase${NC}"
echo "  const videoBlob = await fetch(response.video_url).then(r => r.blob());"
echo "  const { data, error } = await supabase.storage"
echo "    .from('incident-videos')"
echo "    .upload(\`\${incidentId}/video.mp4\`, videoBlob, {"
echo "      contentType: 'video/mp4',"
echo "      cacheControl: '3600',"
echo "      upsert: false"
echo "    });"
echo ""

log_info "Service Management:"
echo ""
echo "  # View status:"
echo "  systemctl status evvos-picam-tcp"
echo ""
echo "  # View logs:"
echo "  sudo journalctl -u evvos-picam-tcp -f"
echo ""
echo "  # Restart service:"
echo "  sudo systemctl restart evvos-picam-tcp"
echo ""
echo "  # Stop service:"
echo "  sudo systemctl stop evvos-picam-tcp"
echo ""

log_info "Test Camera (without app):"
echo ""
echo "  # Test still image capture:"
echo "  libcamera-still -o test.jpg"
echo ""
echo "  # Test 10-second video recording:"
echo "  libcamera-vid -t 10000 -o test.h264"
echo ""
echo "  # Check camera detection:"
echo "  vcgencmd get_camera"
echo "  (Should show: supported=1 detected=1)"
echo ""

log_info "Testing with EVVOS App:"
echo ""
echo "  1. Ensure Pi and phone are on same network"
echo "  2. Get Pi IP address: ip addr show wlan0"
echo "  3. Open EVVOS app on phone"
echo "  4. Tap 'Start Recording' button OR"
echo "     Say voice command: 'start recording'"
echo "  5. Monitor logs: sudo journalctl -u evvos-picam-tcp -f"
echo ""

log_info "Troubleshooting:"
echo ""
echo "  Q: 'Camera not detected' error?"
echo "  A: Check camera connection and enable status:"
echo "     vcgencmd get_camera"
echo "     If not detected, check ribbon cable connection"
echo ""
echo "  Q: TCP connection refused?"
echo "  A: Check service is running and firewall allows ports:"
echo "     systemctl status evvos-picam-tcp"
echo "     sudo ufw allow 3001/tcp"
echo "     sudo ufw allow 8080/tcp"
echo ""
echo "  Q: HTTP file download fails?"
echo "  A: Verify HTTP server is running and files exist:"
echo "     curl http://PI_IP:8080/video_TIMESTAMP.h264"
echo "     ls -lh /home/pi/recordings/"
echo ""
echo "  Q: No audio in recordings?"
echo "  A: Verify ReSpeaker HAT is detected:"
echo "     arecord -l | grep seeed"
echo "     If not found, run setup_respeaker_enhanced.sh first"
echo ""
echo "  Q: Supabase upload fails with 'File too large'?"
echo "  A: Bucket limit is 50MB. Check recording duration:"
echo "     1080p @ 30fps ≈ 5-7 MB/min (10 Mbps bitrate)"
echo "     Max recording time: ~7-8 minutes for 50MB limit"
echo "     Consider lowering resolution or bitrate for longer recordings"
echo ""
echo "  Q: Service keeps restarting?"
echo "  A: Check for camera/audio initialization errors:"
echo "     sudo journalctl -u evvos-picam-tcp --no-pager"
echo ""

log_info "Supabase Bucket Configuration:"
echo ""
echo "  Bucket name: ${CYAN}incident-videos${NC}"
echo "  File size limit: ${CYAN}50MB${NC} per file"
echo "  Allowed MIME types: ${CYAN}video/mp4, video/quicktime${NC}"
echo ""
echo "  Note: H.264 (.h264) files from Pi Camera need conversion to MP4"
echo "  before uploading. Use ffmpeg in your app or convert on Pi:"
echo ""
echo "    ${CYAN}ffmpeg -i video.h264 -i audio.wav -c:v copy -c:a aac output.mp4${NC}"
echo ""

log_warning "IMPORTANT: Reboot required to enable camera!"
echo ""
echo "  ${CYAN}sudo reboot${NC}"
echo ""
echo "After reboot, the camera service will start automatically."
echo ""

log_success "Setup complete! Reboot to activate camera."
echo ""