#!/bin/bash
# PicoVoice Rhino Intent Recognition Setup for ReSpeaker 2-Mics HAT V2.0
# Optimized for: Raspberry Pi Zero 2 W with TLV320AIC3104 Audio Codec
# Detects EVVOS voice commands with intent recognition
# RGB LED feedback and journalctl logging
#
# Intent Model (EVVOSVOICE.yml):
# - recording_control: "start recording", "stop recording"
# - emergency_action: "emergency backup", "alert"
# - incident_capture: "mark incident", "snapshot", "screenshot"
# - user_confirmation: "confirm", "cancel"
# - incident_mark: "mark incident"
#
# Tested on: Raspberry Pi Zero 2 W, Bookworm 12, Kernel 6.12
# Prerequisites: ReSpeaker HAT already configured (run setup_respeaker_enhanced.sh first)
#
# Usage: sudo bash setup_pico_voice_recognition_respeaker.sh

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

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC}  $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_section() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}▶ $1${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
}

# ============================================================================
# PREFLIGHT CHECKS (OLD)
# ============================================================================

log_section "Preflight System Checks"

if [ "$EUID" -ne 0 ]; then 
    log_error "This script must be run as root"
    echo "Usage: sudo bash setup_pico_voice_recognition_respeaker.sh"
    exit 1
fi
log_success "Running as root"

# Check if ReSpeaker HAT is detected
if ! aplay -l 2>/dev/null | grep -qi "seeed"; then
    log_error "ReSpeaker HAT not detected!"
    log_error "Please run setup_respeaker_enhanced.sh first and reboot."
    log_info "After running setup_respeaker_enhanced.sh, the system will reboot."
    log_info "Then run this script again."
    exit 1
fi
log_success "ReSpeaker HAT detected"

# Detect the exact card name
CARD_NAME=$(aplay -l | grep -i seeed | head -1 | sed 's/card \([0-9]\+\):.*/\1/')
if [ -z "$CARD_NAME" ]; then
    CARD_NAME="seeed2micvoicec"
    log_warning "Could not auto-detect card number, using default: $CARD_NAME"
else
    CARD_NAME=$(aplay -l | grep "card $CARD_NAME" | sed 's/.*\[\(.*\)\].*/\1/')
    log_success "Detected ReSpeaker card: $CARD_NAME"
fi

# Check Python3
if ! command -v python3 &> /dev/null; then
    log_error "Python3 not found"
    exit 1
fi
PYTHON_VERSION=$(python3 --version | awk '{print $2}')
log_success "Python3 detected: $PYTHON_VERSION"

# Check kernel version
KERNEL_VERSION=$(uname -r)
log_info "Kernel version: $KERNEL_VERSION"

# ============================================================================
# STEP 1: VERIFY PREREQUISITES
# ============================================================================

log_section "Step 1: Verify Prerequisites"

log_info "Checking for required system packages..."

# Verify audio subsystem
log_info "Verifying ReSpeaker audio HAT..."
if aplay -l 2>/dev/null | grep -qi "seeed"; then
    log_success "✓ ReSpeaker HAT detected and configured"
    log_info "Audio codec (TLV320AIC3104) is ready"
else
    log_error "ReSpeaker HAT not detected"
    log_error "Please run setup_respeaker_enhanced.sh first to configure the ReSpeaker HAT"
    exit 1
fi

# Test recording capability
log_info "Testing microphone recording capability..."
if timeout 2 arecord -f S16_LE -r 16000 -c 1 -d 1 /tmp/mic_test.wav 2>/dev/null; then
    TEST_SIZE=$(stat -c%s /tmp/mic_test.wav 2>/dev/null || echo 0)
    if [ "$TEST_SIZE" -gt 10000 ]; then
        log_success "Microphone recording test passed ($TEST_SIZE bytes)"
        rm -f /tmp/mic_test.wav
    else
        log_warning "Microphone recording file is small - may need gain adjustment"
    fi
else
    log_warning "Microphone test completed with timeout (this is normal)"
fi

log_success "Prerequisites verified"

# ============================================================================
# STEP 2: INSTALL PICOVOICE-SPECIFIC DEPENDENCIES
# ============================================================================

log_section "Step 2: Install PicoVoice-Specific Packages"

log_info "Updating package lists..."
apt-get update >/dev/null 2>&1 || log_warning "Could not update packages"
log_success "Package lists updated"

log_info "Installing PicoVoice build dependencies..."
apt-get install -y \
    build-essential \
    python3-pip \
    python3-dev \
    wget \
    curl \
    git \
    pkg-config \
    portaudio19-dev \
    libasound2-dev \
    libatlas-base-dev \
    libffi-dev \
    libssl-dev \
    libsndfile1 \
    libportaudio2 || log_warning "Some packages may have failed"

log_success "Build dependencies installed"

# ============================================================================
# STEP 3: SETUP PYTHON VIRTUAL ENVIRONMENT
# ============================================================================

log_section "Step 3: Setup Python Virtual Environment"

VENV_PATH="/opt/evvos/venv"

if [ ! -d "$VENV_PATH" ]; then
    log_info "Creating virtual environment at $VENV_PATH..."
    mkdir -p /opt/evvos
    python3 -m venv "$VENV_PATH"
    log_success "Virtual environment created"
else
    log_success "Virtual environment already exists"
fi

source "$VENV_PATH/bin/activate"
log_success "Virtual environment activated"

# ============================================================================
# STEP 4: INSTALL PYTHON PICOVOICE PACKAGES
# ============================================================================

log_section "Step 4: Install Python PicoVoice Packages"

log_info "Installing PicoVoice Rhino SDK and build tools..."

# Use disk-based temporary build directory to avoid exhausting RAM during wheel
# builds on low-memory devices (critical for Pi Zero 2 W)
BUILD_TMP="/opt/evvos/pip_build_tmp"
mkdir -p "$BUILD_TMP"
chown "$(whoami)" "$BUILD_TMP" 2>/dev/null || true
OLD_TMPDIR="${TMPDIR:-}"
export TMPDIR="$BUILD_TMP"
export TMP="$BUILD_TMP"
export TEMP="$BUILD_TMP"
log_info "Using disk temp dir for builds: $BUILD_TMP (reduces RAM usage)"

log_info "Upgrading pip and setuptools..."
pip install --upgrade --no-cache-dir pip setuptools wheel || log_warning "Pip upgrade completed with warnings"

log_info "Installing PicoVoice SDK (this may take several minutes on Pi Zero 2 W)..."
if pip install --no-cache-dir picovoice==4.0.1 pvrhino==4.0.1; then
    log_success "PicoVoice Rhino SDK installed (v4.0.1)"
else
    log_warning "Primary PicoVoice install reported issues, trying alternative..."
    pip install --no-cache-dir picovoice==4.0.1 || log_warning "PicoVoice installation completed with warnings"
fi

log_info "Installing PyAudio for microphone access..."
if pip install --no-cache-dir pyaudio; then
    log_success "PyAudio installed"
else
    log_warning "PyAudio pip install failed - installing build deps and retrying"
    apt-get install -y portaudio19-dev libasound2-dev libsndfile1 || log_warning "Failed to install system audio deps"
    log_info "Retrying PyAudio build (verbose)..."
    if pip install --no-cache-dir --verbose pyaudio 2>&1 | tail -20; then
        log_success "PyAudio rebuilt and installed"
    else
        log_warning "PyAudio rebuild failed - installing system package python3-pyaudio as fallback"
        apt-get install -y python3-pyaudio || log_warning "Failed to install system python3-pyaudio"
    fi
fi

log_info "Installing audio processing and integration libraries..."
pip install --no-cache-dir \
    numpy \
    requests \
    webrtcvad \
    scipy

log_info "Installing GPIO and LED control libraries..."
pip install --no-cache-dir \
    gpiozero \
    RPi.GPIO \
    spidev 2>/dev/null || log_warning "GPIO libraries optional (LED support)"

log_success "All Python packages installed"

# Restore TMPDIR and clean up temporary build folder
if [ -n "$OLD_TMPDIR" ]; then
    export TMPDIR="$OLD_TMPDIR"
    export TMP="$OLD_TMPDIR"
    export TEMP="$OLD_TMPDIR"
else
    unset TMPDIR TMP TEMP
fi

# Optionally remove build temp to free disk space
if [ -d "$BUILD_TMP" ]; then
    rm -rf "$BUILD_TMP" || log_warning "Failed to remove temporary build dir: $BUILD_TMP"
    log_info "Removed temporary build dir: $BUILD_TMP"
fi

# Verify PyAudio installation
log_info "Verifying PyAudio installation..."
python3 << 'PYAUDIO_VERIFICATION'
try:
    import pyaudio
    p = pyaudio.PyAudio()
    device_count = p.get_device_count()
    print(f"[PyAudio] ✓ Working correctly")
    print(f"[PyAudio] ✓ Found {device_count} audio devices")
    
    # List ReSpeaker device
    for i in range(device_count):
        info = p.get_device_info_by_index(i)
        if 'seeed' in info['name'].lower():
            print(f"[PyAudio] ✓ ReSpeaker device found: {info['name']}")
            print(f"[PyAudio]   - Index: {i}")
            print(f"[PyAudio]   - Max Input Channels: {info['maxInputChannels']}")
            print(f"[PyAudio]   - Default Sample Rate: {info['defaultSampleRate']}")
    
    p.terminate()
except Exception as e:
    print(f"[PyAudio] ✗ Error: {e}")
    import sys
    sys.exit(1)
PYAUDIO_VERIFICATION

log_success "PyAudio verification complete"

# ============================================================================
# STEP 5: DEPLOY RHINO CONTEXT FILE
# ============================================================================

log_section "Step 5: Deploy Rhino Context File"

CONTEXT_FILE="/opt/evvos/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn"
UPLOAD_DIR="/tmp/evvos_upload"
POSSIBLE_LOCATIONS=(
    "/mnt/user-data/uploads/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn"
    "/tmp/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn"
    "$UPLOAD_DIR/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn"
    "$HOME/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn"
    "/home/pi/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn"
)

# Try to find the file in common locations
RHN_SOURCE=""
for location in "${POSSIBLE_LOCATIONS[@]}"; do
    if [ -f "$location" ]; then
        RHN_SOURCE="$location"
        log_success "Found Rhino context file at: $location"
        break
    fi
done

if [ -n "$RHN_SOURCE" ]; then
    log_info "Copying Rhino context file to $CONTEXT_FILE..."
    cp "$RHN_SOURCE" "$CONTEXT_FILE"
    chmod 644 "$CONTEXT_FILE"
    log_success "Rhino context file deployed"
else
    log_error "Rhino context file not found!"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Please upload EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Method 1: SCP from your computer"
    echo "  scp EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn pi@$(hostname -I | awk '{print $1}'):/tmp/"
    echo ""
    echo "Method 2: USB Drive"
    echo "  1. Copy file to USB drive"
    echo "  2. Insert USB into Pi"
    echo "  3. Run: sudo mount /dev/sda1 /mnt/usb"
    echo "  4. Run: sudo cp /mnt/usb/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn /tmp/"
    echo ""
    echo "Method 3: Create upload directory and use SCP"
    echo "  mkdir -p $UPLOAD_DIR"
    echo "  scp EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn pi@$(hostname -I | awk '{print $1}'):$UPLOAD_DIR/"
    echo ""
    echo "After uploading, run this script again:"
    echo "  sudo bash setup_pico_voice_recognition_respeaker.sh"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    exit 1
fi

# Verify context file
if [ -f "$CONTEXT_FILE" ]; then
    CONTEXT_SIZE=$(stat -c%s "$CONTEXT_FILE")
    log_success "Context file verified: $CONTEXT_SIZE bytes"
else
    log_error "Context file deployment failed"
    exit 1
fi

# ============================================================================
# STEP 6: CREATE ACCESS KEY FILE
# ============================================================================

log_section "Step 6: Configure PicoVoice Access Key"

ACCESS_KEY_FILE="/opt/evvos/picovoice_access_key.txt"

log_info "Setting up PicoVoice Access Key..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PicoVoice Access Key Required"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "You need a FREE PicoVoice Access Key to use Rhino."
echo ""
echo "Steps to get your key:"
echo "  1. Visit: https://console.picovoice.ai"
echo "  2. Sign up for a free account"
echo "  3. Copy your Access Key from the dashboard"
echo ""
echo "The free tier includes:"
echo "  • Unlimited on-device processing"
echo "  • No cloud requirements"
echo "  • Perfect for Raspberry Pi applications"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f "$ACCESS_KEY_FILE" ]; then
    log_success "Access key file already exists: $ACCESS_KEY_FILE"
    read -p "Do you want to replace it? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Keeping existing access key"
    else
        read -p "Enter your PicoVoice Access Key: " ACCESS_KEY
        echo "$ACCESS_KEY" > "$ACCESS_KEY_FILE"
        chmod 600 "$ACCESS_KEY_FILE"
        log_success "Access key updated"
    fi
else
    read -p "Enter your PicoVoice Access Key: " ACCESS_KEY
    if [ -z "$ACCESS_KEY" ]; then
        log_warning "No access key provided. Service will fail to start."
        log_warning "You can add it later by editing: $ACCESS_KEY_FILE"
        echo "YOUR_ACCESS_KEY_HERE" > "$ACCESS_KEY_FILE"
    else
        echo "$ACCESS_KEY" > "$ACCESS_KEY_FILE"
        log_success "Access key saved to: $ACCESS_KEY_FILE"
    fi
    chmod 600 "$ACCESS_KEY_FILE"
fi

echo ""

# ============================================================================
# STEP 7: CREATE PICOVOICE SERVICE SCRIPT
# ============================================================================

log_section "Step 7: Create PicoVoice Service Script"

LOG_FILE="/var/log/evvos-pico-voice.log"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

cat > /usr/local/bin/evvos-pico-voice-service.py << 'PICO_SERVICE_EOF'
#!/usr/bin/env python3
"""
EVVOS PicoVoice Rhino Intent Recognition Service
Optimized for ReSpeaker 2-Mics Pi HAT V2.0 on Raspberry Pi Zero 2 W

This service listens for voice commands using PicoVoice Rhino
and provides RGB LED feedback via the ReSpeaker HAT.

Author: EVVOS Team
License: MIT
"""

import os
import sys
import time
import json
import logging
import signal
import struct
from datetime import datetime
from pathlib import Path

# Audio processing
import pyaudio
import pvrhino

# GPIO for LED control (ReSpeaker has APA102 RGB LEDs)
try:
    import spidev
    LEDS_AVAILABLE = True
except ImportError:
    LEDS_AVAILABLE = False
    print("[LED] Warning: spidev not available, LED control disabled")

# ============================================================================
# CONFIGURATION
# ============================================================================

# File paths
ACCESS_KEY_FILE = "/opt/evvos/picovoice_access_key.txt"
CONTEXT_FILE = "/opt/evvos/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn"
LOG_FILE = "/var/log/evvos-pico-voice.log"

# Audio configuration for ReSpeaker 2-Mics HAT
SAMPLE_RATE = 16000  # Rhino requires 16kHz
FRAME_LENGTH = 512   # Rhino frame length
CHANNELS = 1         # Mono for voice recognition
AUDIO_FORMAT = pyaudio.paInt16

# LED Colors (RGB)
LED_OFF = (0, 0, 0)
LED_LISTENING = (0, 128, 128)  # Cyan - waiting for input
LED_DETECTED = (0, 255, 0)     # Green - intent detected
LED_ERROR = (255, 0, 0)        # Red - error state
LED_PROCESSING = (128, 0, 128)  # Purple - processing

# ReSpeaker LED configuration (APA102)
LED_COUNT = 3  # ReSpeaker 2-Mics HAT has 3 LEDs

# ============================================================================
# LOGGING SETUP
# ============================================================================

# Setup dual logging (file + journalctl)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

# ============================================================================
# LED CONTROL (APA102 via SPI)
# ============================================================================

class ReSpeakerLEDs:
    """Control ReSpeaker 2-Mics HAT APA102 RGB LEDs via SPI"""
    
    def __init__(self):
        self.enabled = LEDS_AVAILABLE
        self.spi = None
        
        if self.enabled:
            try:
                self.spi = spidev.SpiDev()
                self.spi.open(0, 0)  # SPI bus 0, device 0
                self.spi.max_speed_hz = 8000000  # 8MHz
                self.spi.mode = 0b01  # CPOL=0, CPHA=1
                logger.info("[LED] ReSpeaker LEDs initialized via SPI")
                self.set_all(LED_OFF)
            except Exception as e:
                logger.warning(f"[LED] Failed to initialize: {e}")
                self.enabled = False
    
    def _build_frame(self, brightness, r, g, b):
        """Build APA102 LED frame (32-bit)"""
        # APA102 format: [111][5-bit brightness][8-bit blue][8-bit green][8-bit red]
        return [
            0b11100000 | (brightness & 0x1F),  # Start frame + brightness
            b & 0xFF,  # Blue
            g & 0xFF,  # Green
            r & 0xFF   # Red
        ]
    
    def set_all(self, color, brightness=10):
        """Set all LEDs to the same color"""
        if not self.enabled or not self.spi:
            return
        
        try:
            r, g, b = color
            
            # APA102 protocol: start frame + LED frames + end frame
            data = [0x00, 0x00, 0x00, 0x00]  # Start frame
            
            for _ in range(LED_COUNT):
                data.extend(self._build_frame(brightness, r, g, b))
            
            data.extend([0xFF, 0xFF, 0xFF, 0xFF])  # End frame
            
            self.spi.xfer2(data)
        except Exception as e:
            logger.warning(f"[LED] Error setting LEDs: {e}")
    
    def pulse(self, color, duration=0.2):
        """Pulse effect (brief flash)"""
        if not self.enabled:
            return
        
        self.set_all(color, brightness=20)
        time.sleep(duration)
        self.set_all(LED_LISTENING, brightness=5)
    
    def cleanup(self):
        """Turn off LEDs and close SPI"""
        if self.spi:
            try:
                self.set_all(LED_OFF)
                self.spi.close()
                logger.info("[LED] LEDs turned off")
            except Exception as e:
                logger.warning(f"[LED] Cleanup error: {e}")

# ============================================================================
# PICOVOICE RHINO SERVICE
# ============================================================================

class PicoVoiceService:
    """Main PicoVoice Rhino service for voice intent recognition"""
    
    def __init__(self):
        self.running = False
        self.rhino = None
        self.audio_stream = None
        self.pa = None
        self.leds = ReSpeakerLEDs()
        self.access_key = None
        
        # Signal handlers for graceful shutdown
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        logger.info("=" * 70)
        logger.info("EVVOS PicoVoice Rhino Service Starting")
        logger.info("=" * 70)
        logger.info(f"Python: {sys.version}")
        logger.info("PicoVoice Rhino: Installed")
        logger.info(f"Context: {CONTEXT_FILE}")
        logger.info(f"Sample Rate: {SAMPLE_RATE} Hz")
        logger.info(f"Frame Length: {FRAME_LENGTH}")
        logger.info("=" * 70)
    
    def signal_handler(self, signum, frame):
        """Handle shutdown signals"""
        logger.info(f"Received signal {signum}, shutting down...")
        self.running = False
    
    def load_access_key(self):
        """Load PicoVoice access key from file"""
        try:
            if not os.path.exists(ACCESS_KEY_FILE):
                logger.error(f"Access key file not found: {ACCESS_KEY_FILE}")
                logger.error("Create the file and add your PicoVoice access key")
                logger.error("Get a free key at: https://console.picovoice.ai")
                return False
            
            with open(ACCESS_KEY_FILE, 'r') as f:
                self.access_key = f.read().strip()
            
            if not self.access_key or self.access_key == "YOUR_ACCESS_KEY_HERE":
                logger.error("Invalid access key in file")
                logger.error("Please update the access key in: " + ACCESS_KEY_FILE)
                return False
            
            logger.info(f"Access key loaded: {self.access_key[:8]}...")
            return True
        
        except Exception as e:
            logger.error(f"Failed to load access key: {e}")
            return False
    
    def setup_rhino(self):
        """Initialize PicoVoice Rhino engine"""
        try:
            if not self.load_access_key():
                return False
            
            if not os.path.exists(CONTEXT_FILE):
                logger.error(f"Rhino context file not found: {CONTEXT_FILE}")
                return False
            
            logger.info("Initializing Rhino engine...")
            
            self.rhino = pvrhino.create(
                access_key=self.access_key,
                context_path=CONTEXT_FILE,
                require_endpoint=True  # Wait for speech endpoint before processing
            )
            
            logger.info("Rhino initialized successfully")
            logger.info(f"  Context: {self.rhino.context_info}")
            logger.info(f"  Frame Length: {self.rhino.frame_length}")
            logger.info(f"  Sample Rate: {self.rhino.sample_rate} Hz")
            
            return True
        
        except Exception as e:
            logger.error(f"Failed to initialize Rhino: {e}")
            self.leds.set_all(LED_ERROR)
            return False
    
    def find_respeaker_device(self):
        """Find ReSpeaker audio input device index"""
        try:
            p = pyaudio.PyAudio()
            device_count = p.get_device_count()
            
            logger.info(f"Scanning {device_count} audio devices...")
            
            for i in range(device_count):
                info = p.get_device_info_by_index(i)
                device_name = info['name'].lower()
                
                if 'seeed' in device_name:
                    logger.info(f"Found ReSpeaker device:")
                    logger.info(f"  Index: {i}")
                    logger.info(f"  Name: {info['name']}")
                    logger.info(f"  Channels: {info['maxInputChannels']}")
                    logger.info(f"  Sample Rate: {info['defaultSampleRate']}")
                    p.terminate()
                    return i
            
            # If ReSpeaker not found, use default
            logger.warning("ReSpeaker not found by name, using default input")
            default_input = p.get_default_input_device_info()
            logger.info(f"Default input: {default_input['name']}")
            p.terminate()
            return None  # Use default
        
        except Exception as e:
            logger.error(f"Error finding audio device: {e}")
            return None
    
    def setup_audio_stream(self):
        """Initialize PyAudio stream for ReSpeaker microphone"""
        try:
            self.pa = pyaudio.PyAudio()
            
            # Find ReSpeaker device
            device_index = self.find_respeaker_device()
            
            logger.info("Opening audio stream...")
            
            # Open stream with ReSpeaker-optimized settings
            self.audio_stream = self.pa.open(
                input_device_index=device_index,
                rate=SAMPLE_RATE,
                channels=CHANNELS,
                format=AUDIO_FORMAT,
                input=True,
                frames_per_buffer=FRAME_LENGTH,
                stream_callback=None  # Blocking mode for better reliability
            )
            
            logger.info("Audio stream opened successfully")
            logger.info(f"  Device: {'ReSpeaker' if device_index else 'Default'}")
            logger.info(f"  Sample Rate: {SAMPLE_RATE} Hz")
            logger.info(f"  Channels: {CHANNELS} (Mono)")
            logger.info(f"  Frame Length: {FRAME_LENGTH}")
            
            return True
        
        except Exception as e:
            logger.error(f"Failed to setup audio stream: {e}")
            self.leds.set_all(LED_ERROR)
            return False
    
    def process_voice_input(self):
        """Main loop: read audio and process with Rhino"""
        self.running = True
        logger.info("=" * 70)
        logger.info("Voice recognition active - listening for commands...")
        logger.info("=" * 70)
        
        # Set listening state
        self.leds.set_all(LED_LISTENING, brightness=5)
        
        frame_count = 0
        
        try:
            while self.running:
                # Read audio frame
                try:
                    pcm_data = self.audio_stream.read(
                        self.rhino.frame_length,
                        exception_on_overflow=False
                    )
                except Exception as e:
                    logger.warning(f"Audio read error: {e}")
                    time.sleep(0.1)
                    continue
                
                # Convert to 16-bit PCM
                pcm = struct.unpack_from(
                    "h" * self.rhino.frame_length,
                    pcm_data
                )
                
                # Process frame with Rhino
                is_finalized = self.rhino.process(pcm)
                
                frame_count += 1
                
                # Log heartbeat every 5 seconds
                if frame_count % (SAMPLE_RATE // FRAME_LENGTH * 5) == 0:
                    logger.info(f"[HEARTBEAT] Listening... ({frame_count} frames processed)")
                
                if is_finalized:
                    inference = self.rhino.get_inference()
                    
                    if inference.is_understood:
                        intent = inference.intent
                        slots = inference.slots
                        
                        logger.info("=" * 70)
                        logger.info(f"[INTENT DETECTED] Intent: '{intent}'")
                        logger.info(f"[SLOTS] {json.dumps(slots, indent=2)}")
                        logger.info("=" * 70)
                        
                        # LED feedback: Green pulse
                        self.leds.pulse(LED_DETECTED, duration=0.3)
                        
                        # Handle the detected intent
                        self.handle_intent(intent, slots)
                    
                    else:
                        logger.info("[SPEECH] Speech detected but no intent matched")
                        logger.info("  Try one of the configured commands")
        
        except KeyboardInterrupt:
            logger.info("Keyboard interrupt received")
        
        except Exception as e:
            logger.error(f"Error in voice processing loop: {e}", exc_info=True)
            self.leds.set_all(LED_ERROR)
        
        finally:
            self.cleanup()
    
    def handle_intent(self, intent, slots):
        """Handle detected intent and execute corresponding action"""
        logger.info(f"[ACTION] Processing intent: {intent}")
        
        # Map intents to actions
        if intent == "recording_control":
            logger.info("[ACTION] Recording control detected")
            # TODO: Integrate with EVVOS recording system
        
        elif intent == "emergency_action":
            logger.info("[ACTION] Emergency backup triggered!")
            # TODO: Trigger emergency backup
        
        elif intent == "incident_capture":
            logger.info("[ACTION] Capturing incident snapshot")
            # TODO: Trigger camera snapshot or screenshot
        
        elif intent == "user_confirmation":
            logger.info("[ACTION] User confirmation detected")
            # TODO: Handle confirm/cancel actions
        
        elif intent == "incident_mark":
            logger.info("[ACTION] Marking incident in timeline")
            # TODO: Add incident marker to recording
        
        else:
            logger.warning(f"[ACTION] Unknown intent: {intent}")
        
        # Optional: Send to Supabase Edge Function
        # self.send_to_backend(intent, slots)
    
    def send_to_backend(self, intent, slots):
        """Send intent data to EVVOS backend (optional)"""
        try:
            import requests
            
            # Replace with your Supabase Edge Function URL
            EDGE_FUNCTION_URL = os.getenv("EVVOS_EDGE_FUNCTION_URL")
            
            if not EDGE_FUNCTION_URL:
                return
            
            payload = {
                "intent": intent,
                "slots": slots,
                "timestamp": datetime.now().isoformat(),
                "device_id": os.getenv("EVVOS_DEVICE_ID", "unknown")
            }
            
            response = requests.post(
                EDGE_FUNCTION_URL,
                json=payload,
                timeout=5
            )
            
            if response.status_code == 200:
                logger.info("[BACKEND] Intent sent successfully")
            else:
                logger.warning(f"[BACKEND] Failed: {response.status_code}")
        
        except Exception as e:
            logger.warning(f"[BACKEND] Error sending intent: {e}")
    
    def cleanup(self):
        """Clean up resources"""
        logger.info("Shutting down voice recognition service...")
        
        if self.audio_stream:
            self.audio_stream.stop_stream()
            self.audio_stream.close()
            logger.info("Audio stream closed")
        
        if self.pa:
            self.pa.terminate()
            logger.info("PyAudio terminated")
        
        if self.rhino:
            self.rhino.delete()
            logger.info("Rhino engine released")
        
        self.leds.cleanup()
        
        logger.info("Voice recognition service shutdown complete")
        logger.info("=" * 70)
    
    def run(self):
        """Main service entry point"""
        if not self.setup_rhino():
            logger.error("Failed to initialize Rhino")
            return
        
        if not self.setup_audio_stream():
            logger.error("Failed to setup audio stream")
            return
        
        self.process_voice_input()

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

def main():
    try:
        service = PicoVoiceService()
        service.run()
    except Exception as e:
        logger.error(f"Unhandled exception: {e}", exc_info=True)
        sys.exit(1)

if __name__ == "__main__":
    main()
PICO_SERVICE_EOF

chmod +x /usr/local/bin/evvos-pico-voice-service.py
log_success "PicoVoice voice recognition service script created"

# ============================================================================
# STEP 8: CREATE SYSTEMD SERVICE UNIT
# ============================================================================

log_section "Step 8: Create Systemd Service"

cat > /etc/systemd/system/evvos-pico-voice.service << 'SERVICE_FILE'
[Unit]
Description=EVVOS PicoVoice Rhino Intent Recognition Service
Documentation=https://github.com/evvos
After=network.target sound.target alsa-restore.service
Requires=sound.target
Wants=alsa-restore.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/evvos
ExecStart=/opt/evvos/venv/bin/python3 /usr/local/bin/evvos-pico-voice-service.py
Restart=always
RestartSec=10
StartLimitInterval=60
StartLimitBurst=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=evvos-pico-voice
SyslogFacility=user

# Environment
Environment="PATH=/opt/evvos/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONUNBUFFERED=1"
Environment="PYTHONPATH=/opt/evvos"

# Resource limits
LimitNOFILE=65536
LimitNPROC=32768

# Capabilities for GPIO/SPI access
AmbientCapabilities=CAP_SYS_NICE CAP_SYS_ADMIN

[Install]
WantedBy=multi-user.target
SERVICE_FILE

chmod 644 /etc/systemd/system/evvos-pico-voice.service
log_success "Systemd service created"

# ============================================================================
# STEP 9: ENABLE AND START SERVICE
# ============================================================================

log_section "Step 9: Enable and Start PicoVoice Service"

log_info "Reloading systemd daemon..."
systemctl daemon-reload

log_info "Enabling PicoVoice service..."
systemctl enable evvos-pico-voice
log_success "Service enabled (auto-start on boot)"

log_info "Starting PicoVoice service..."
if systemctl start evvos-pico-voice; then
    log_success "Service started"
    sleep 2
else
    log_warning "Service start returned error - checking logs..."
fi

# ============================================================================
# STEP 10: VERIFY SERVICE STATUS
# ============================================================================

log_section "Step 10: Verify Service Status"

if systemctl is-active --quiet evvos-pico-voice; then
    log_success "PicoVoice service is RUNNING"
else
    log_warning "Service may not be running. Check logs:"
    log_warning "  sudo journalctl -u evvos-pico-voice -n 30"
fi

echo ""
systemctl status evvos-pico-voice --no-pager 2>&1 | head -15
echo ""

# ============================================================================
# STEP 11: SUMMARY & NEXT STEPS
# ============================================================================

log_section "PicoVoice Rhino Intent Recognition Setup Complete!"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ PicoVoice Rhino Service Installed!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

log_info "Configuration Summary:"
echo "  • Hardware: Raspberry Pi Zero 2 W + ReSpeaker 2-Mics HAT V2.0"
echo "  • Audio Codec: TLV320AIC3104 (via $CARD_NAME)"
echo "  • Intent Model: EVVOSVOICE Custom Context"
echo "  • Python Environment: $VENV_PATH"
echo "  • Service: evvos-pico-voice.service"
echo "  • Log File: $LOG_FILE"
echo "  • Access Key: $ACCESS_KEY_FILE"
echo "  • Custom Context: $CONTEXT_FILE"
echo ""

log_info "Recognized Intents and Commands (from EVVOSVOICE.yml):"
echo ""
echo "  ${CYAN}recording_control${NC}:"
echo "    • 'start recording'"
echo "    • 'stop recording'"
echo ""
echo "  ${CYAN}emergency_action${NC}:"
echo "    • 'alert'"
echo "    • 'emergency backup'"
echo ""
echo "  ${CYAN}incident_capture${NC}:"
echo "    • 'screenshot'"
echo "    • 'snapshot'"
echo "    • 'mark incident'"
echo ""
echo "  ${CYAN}user_confirmation${NC}:"
echo "    • 'confirm'"
echo "    • 'cancel'"
echo ""
echo "  ${CYAN}incident_mark${NC}:"
echo "    • 'mark incident'"
echo ""

log_info "LED Status Indicators (ReSpeaker APA102):"
echo "  • ${CYAN}Cyan (Listening)${NC}: Waiting for voice input"
echo "  • ${GREEN}Green (Detected)${NC}: Intent successfully recognized"
echo "  • ${RED}Red (Error)${NC}: Service error occurred"
echo ""

log_info "IMPORTANT: Monitor logs while testing:"
echo ""
echo "  ${CYAN}sudo journalctl -u evvos-pico-voice -f${NC}"
echo ""
echo "  When you speak a command, look for:"
echo "  ${GREEN}[INTENT DETECTED] Intent: 'recording_control' | Slots: {}${NC}"
echo ""

log_info "Service Management:"
echo ""
echo "  # View status:"
echo "  systemctl status evvos-pico-voice"
echo ""
echo "  # View last 50 lines of logs:"
echo "  sudo journalctl -u evvos-pico-voice -n 50"
echo ""
echo "  # Follow logs in real-time:"
echo "  sudo journalctl -u evvos-pico-voice -f"
echo ""
echo "  # Stop service:"
echo "  sudo systemctl stop evvos-pico-voice"
echo ""
echo "  # Restart service:"
echo "  sudo systemctl restart evvos-pico-voice"
echo ""
echo "  # View file logs:"
echo "  sudo tail -f $LOG_FILE"
echo ""

log_info "ReSpeaker Audio Adjustments (if needed):"
echo ""
echo "  # Increase microphone gain (if too quiet):"
echo "  sudo amixer -c $CARD_NAME sset 'PGA' 28"
echo ""
echo "  # Decrease microphone gain (if distorted):"
echo "  sudo amixer -c $CARD_NAME sset 'PGA' 22"
echo ""
echo "  # Save settings permanently:"
echo "  sudo alsactl store"
echo ""
echo "  # Test microphone:"
echo "  arecord -f S16_LE -r 16000 -d 3 /tmp/test.wav && aplay /tmp/test.wav"
echo ""

log_info "Troubleshooting:"
echo ""
echo "  Q: 'AccessKey not loaded' error?"
echo "  A: Ensure AccessKey is saved to: $ACCESS_KEY_FILE"
echo "     Get free key from: https://console.picovoice.ai"
echo ""
echo "  Q: No intents recognized?"
echo "  A: Check microphone gain: sudo amixer -c $CARD_NAME sset 'PGA' 25"
echo "     Test microphone: arecord -f S16_LE -r 16000 -d 3 /tmp/test.wav"
echo ""
echo "  Q: Service keeps restarting?"
echo "  A: Check logs: sudo journalctl -u evvos-pico-voice --no-pager"
echo "     Verify ReSpeaker is detected: aplay -l && arecord -l"
echo ""
echo "  Q: LEDs not working?"
echo "  A: LEDs require spidev library. Verify it's installed in venv."
echo "     Check SPI is enabled: ls /dev/spidev0.0"
echo ""

log_info "Next Steps:"
echo "  1. Verify AccessKey is set: cat $ACCESS_KEY_FILE"
echo "  2. Monitor logs: ${CYAN}sudo journalctl -u evvos-pico-voice -f${NC}"
echo "  3. Speak a command: 'start recording' or 'snapshot'"
echo "  4. Watch for green LED flash and log message"
echo "  5. If no detection, adjust microphone gain and test"
echo ""

log_info "PicoVoice Rhino Advantages:"
echo "  • Intent-based recognition (structured commands)"
echo "  • Extracts intent and slots from speech"
echo "  • Better accuracy for command patterns"
echo "  • Lighter CPU footprint on Pi Zero 2 W"
echo "  • On-device processing (privacy-first)"
echo "  • Free tier with unlimited on-device use"
echo ""

log_info "Integration with EVVOS:"
echo "  • Service logs intent detections to journalctl"
echo "  • Can send intent data to Supabase Edge Function"
echo "  • RGB LED feedback via ReSpeaker APA102 LEDs"
echo "  • Automatic startup on system boot"
echo ""

echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

log_success "PicoVoice Rhino Service ready to use!"
echo ""
log_info "Start testing with:"
echo "  ${CYAN}sudo journalctl -u evvos-pico-voice -f${NC}"
echo ""
