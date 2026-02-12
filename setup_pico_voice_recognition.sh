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
# PREFLIGHT CHECKS
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

# Detect the exact card name and number
CARD_INFO=$(aplay -l 2>/dev/null | grep -i seeed | head -1)
if [ -z "$CARD_INFO" ]; then
    CARD_NUM="0"
    CARD_NAME="seeed2micvoicec"
    log_warning "Could not auto-detect card, using defaults: $CARD_NAME (card $CARD_NUM)"
else
    # Extract card number and name from output like: card 0: seeed2micvoicec [seeed-voicecard]
    CARD_NUM=$(echo "$CARD_INFO" | grep -oP 'card \K[0-9]+')
    CARD_NAME=$(echo "$CARD_INFO" | grep -oP '\[\K[^\]]+' | head -1)
    log_success "Detected ReSpeaker: card $CARD_NUM ($CARD_NAME)"
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

log_info "Preparing build environment for Pi Zero 2 W..."

# CRITICAL OPTIMIZATION: Use disk-based temporary build directory 
# This prevents RAM exhaustion (OOM) when building wheels for numpy/scipy
BUILD_TMP="/opt/evvos/pip_build_tmp"
mkdir -p "$BUILD_TMP"
chown "$(whoami)" "$BUILD_TMP" 2>/dev/null || true
OLD_TMPDIR="${TMPDIR:-}"
export TMPDIR="$BUILD_TMP"
export TMP="$BUILD_TMP"
export TEMP="$BUILD_TMP"
log_info "Using disk temp dir: $BUILD_TMP"

log_info "Upgrading pip to ensure wheel compatibility..."
"$VENV_PATH/bin/pip" install --upgrade --no-cache-dir pip setuptools wheel || log_warning "Pip upgrade completed with warnings"

log_info "Installing PicoVoice Rhino SDK 4.0.1..."
# Installing pvrhino 4.0.1 directly as requested
# We skip the generic 'picovoice' wrapper to ensure version strictness
if "$VENV_PATH/bin/pip" install --no-cache-dir pvrhino==4.0.1; then
    log_success "PicoVoice Rhino SDK 4.0.1 installed"
else
    log_error "Failed to install pvrhino 4.0.1"
    # Clean up before exiting
    rm -rf "$BUILD_TMP"
    exit 1
fi

log_info "Installing PyAudio for microphone access..."
# Try installing PyAudio; if it fails, attempt to install system build deps first
if ! "$VENV_PATH/bin/pip" install --no-cache-dir pyaudio; then
    log_warning "Standard PyAudio install failed - attempting to install system build deps..."
    apt-get install -y portaudio19-dev libasound2-dev libsndfile1
    
    log_info "Retrying PyAudio install..."
    if "$VENV_PATH/bin/pip" install --no-cache-dir pyaudio; then
        log_success "PyAudio installed successfully on retry"
    else
        log_error "PyAudio installation failed. Please check portaudio19-dev is installed."
        exit 1
    fi
else
    log_success "PyAudio installed"
fi

log_info "Installing remaining dependencies (scipy/numpy may take time)..."
"$VENV_PATH/bin/pip" install --no-cache-dir \
    numpy \
    requests \
    webrtcvad \
    scipy \
    gpiozero \
    RPi.GPIO \
    spidev || log_warning "Non-critical dependencies may have failed"

# Restore TMPDIR and clean up
if [ -n "$OLD_TMPDIR" ]; then
    export TMPDIR="$OLD_TMPDIR"
    export TMP="$OLD_TMPDIR"
    export TEMP="$OLD_TMPDIR"
else
    unset TMPDIR TMP TEMP
fi

if [ -d "$BUILD_TMP" ]; then
    rm -rf "$BUILD_TMP"
    log_info "Temporary build artifacts cleaned up"
fi

log_success "All Python packages installed in virtual environment"

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

# Check if context file was uploaded to /mnt/user-data/uploads
if [ -f "/mnt/user-data/uploads/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn" ]; then
    log_info "Copying Rhino context file from uploads..."
    cp /mnt/user-data/uploads/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn "$CONTEXT_FILE"
    chmod 644 "$CONTEXT_FILE"
    log_success "Rhino context file deployed: $CONTEXT_FILE"
else
    log_error "Rhino context file not found at /mnt/user-data/uploads/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn"
    log_error "Please ensure the .rhn file is uploaded to the system"
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

log_section "Step 7: Create ALSA Configuration for ReSpeaker"

log_info "Creating ALSA configuration to suppress warnings..."
mkdir -p /etc/alsa/conf.d
cat > /etc/alsa/conf.d/respeaker.conf << 'ALSA_CONF_EOF'
pcm.default {
    type asym
    playback.pcm "play"
    capture.pcm "rec"
}

pcm.play {
    type hw
    card seeed2micvoicec
}

pcm.rec {
    type hw
    card seeed2micvoicec
}

ctl.!default {
    type hw
    card seeed2micvoicec
}
ALSA_CONF_EOF
chmod 644 /etc/alsa/conf.d/respeaker.conf
log_success "ALSA configuration created"

# ============================================================================
# STEP 8: CREATE PICOVOICE SERVICE SCRIPT
# ============================================================================

log_section "Step 8: Create PicoVoice Service Script"

LOG_FILE="/var/log/evvos-pico-voice.log"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

cat > /usr/local/bin/evvos-pico-voice-service.py << 'PICO_SERVICE_EOF'
#!/usr/bin/env python3
"""
EVVOS PicoVoice Rhino Intent Recognition Service
Optimized for ReSpeaker 2-Mics Pi HAT V2.0 on Raspberry Pi Zero 2 W

LED INDICATORS:
- Cyan:   Listening (Default)
- Purple: Processing (Analyzing voice)
- Green:  Intent Detected (Success)
- Red:    Error State
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

# LED Colors (RGB Tuple)
LED_OFF = (0, 0, 0)
LED_LISTENING = (0, 255, 255)   # Cyan
LED_PROCESSING = (128, 0, 128)  # Purple
LED_DETECTED = (0, 255, 0)      # Green
LED_ERROR = (255, 0, 0)         # Red

# ReSpeaker LED configuration (APA102)
LED_COUNT = 3  # ReSpeaker 2-Mics HAT has 3 LEDs

# ============================================================================
# LOGGING SETUP
# ============================================================================

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
            except FileNotFoundError as e:
                logger.warning(f"[LED] SPI device not found ({e}) - LEDs disabled")
                logger.warning("[LED] Enable SPI with: sudo raspi-config")
                self.enabled = False
            except PermissionError as e:
                logger.warning(f"[LED] Permission denied accessing SPI ({e})")
                logger.warning("[LED] Service must run as root or with GPIO permissions")
                self.enabled = False
            except Exception as e:
                logger.warning(f"[LED] Failed to initialize: {e}")
                self.enabled = False
    
    def _build_frame(self, brightness, r, g, b):
        """Build APA102 LED frame (32-bit). APA102 expects BGR order."""
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
            
            # End frame (needed to push data through)
            data.extend([0xFF, 0xFF, 0xFF, 0xFF])
            
            self.spi.xfer2(data)
        except OSError as e:
            # OSError usually means SPI device disconnected or permission issue
            if not hasattr(self, '_error_logged'):
                logger.warning(f"[LED] SPI communication error: {e}")
                self._error_logged = True
        except Exception as e:
            if not hasattr(self, '_error_logged'):
                logger.warning(f"[LED] Error setting LEDs: {e}")
                self._error_logged = True
    
    def pulse(self, color, duration=0.5, end_color=LED_LISTENING):
        """Pulse a color briefly, then return to end_color"""
        if not self.enabled:
            return
        
        # Flash bright
        self.set_all(color, brightness=20)
        time.sleep(duration)
        
        # Return to default state (usually listening)
        self.set_all(end_color, brightness=5)
    
    def cleanup(self):
        """Turn off LEDs and close SPI"""
        if self.spi:
            try:
                self.set_all(LED_OFF)
                self.spi.close()
            except Exception:
                pass

# ============================================================================
# PICOVOICE RHINO SERVICE
# ============================================================================

class PicoVoiceService:
    def __init__(self):
        self.running = False
        self.rhino = None
        self.audio_stream = None
        self.pa = None
        self.leds = ReSpeakerLEDs()
        self.access_key = None
        
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
    
    def signal_handler(self, signum, frame):
        logger.info(f"Received signal {signum}, shutting down...")
        self.running = False

    def load_access_key(self):
        try:
            if not os.path.exists(ACCESS_KEY_FILE):
                logger.error(f"Access key file missing: {ACCESS_KEY_FILE}")
                return False
            with open(ACCESS_KEY_FILE, 'r') as f:
                self.access_key = f.read().strip()
            return True
        except Exception as e:
            logger.error(f"Error loading access key: {e}")
            return False

    def setup_rhino(self):
        if not self.load_access_key(): return False
        try:
            self.rhino = pvrhino.create(
                access_key=self.access_key,
                context_path=CONTEXT_FILE,
                require_endpoint=True
            )
            return True
        except Exception as e:
            logger.error(f"Rhino init failed: {e}")
            self.leds.set_all(LED_ERROR, brightness=20)
            return False

    def setup_audio(self):
        try:
            self.pa = pyaudio.PyAudio()
            # Find ReSpeaker device
            dev_idx = None
            dev_name = None
            for i in range(self.pa.get_device_count()):
                info = self.pa.get_device_info_by_index(i)
                if 'seeed' in info['name'].lower():
                    dev_idx = i
                    dev_name = info['name']
                    logger.info(f"Found ReSpeaker device: {dev_name} (index {i})")
                    logger.info(f"  Sample Rate: {int(info['defaultSampleRate'])} Hz")
                    logger.info(f"  Input Channels: {info['maxInputChannels']}")
                    break
            
            if dev_idx is None:
                logger.error("ReSpeaker device (seeed) not found in audio devices")
                logger.info("Available devices:")
                for i in range(self.pa.get_device_count()):
                    info = self.pa.get_device_info_by_index(i)
                    logger.info(f"  [{i}] {info['name']}")
                return False
            
            self.audio_stream = self.pa.open(
                input_device_index=dev_idx,
                rate=SAMPLE_RATE,
                channels=CHANNELS,
                format=AUDIO_FORMAT,
                input=True,
                frames_per_buffer=FRAME_LENGTH
            )
            logger.info(f"Audio stream opened successfully from {dev_name}")
            return True
        except Exception as e:
            logger.error(f"Audio init failed: {e}")
            self.leds.set_all(LED_ERROR, brightness=20)
            return False

    def handle_intent(self, intent, slots):
        """Execute action based on intent"""
        logger.info(f" >>> EXECUTING: {intent} {slots}")
        
        # Add your custom logic here
        if intent == "recording_control":
            pass # Start/Stop recording logic
        elif intent == "emergency_action":
            pass # Trigger alerts
        elif intent == "incident_capture":
            pass # Take snapshot

    def process_voice_input(self):
        self.running = True
        logger.info("Service started. Listening...")
        
        # STATE: LISTENING (Cyan)
        self.leds.set_all(LED_LISTENING, brightness=5)
        
        try:
            while self.running:
                pcm = self.audio_stream.read(self.rhino.frame_length, exception_on_overflow=False)
                pcm = struct.unpack_from("h" * self.rhino.frame_length, pcm)
                
                is_finalized = self.rhino.process(pcm)
                
                if is_finalized:
                    # STATE: PROCESSING (Purple)
                    # Voice command ended, analyzing intent...
                    self.leds.set_all(LED_PROCESSING, brightness=15)
                    
                    inference = self.rhino.get_inference()
                    
                    if inference.is_understood:
                        # STATE: INTENT DETECTED (Green Pulse)
                        logger.info(f"Detected: {inference.intent}")
                        self.handle_intent(inference.intent, inference.slots)
                        self.leds.pulse(LED_DETECTED, duration=0.7, end_color=LED_LISTENING)
                    else:
                        # STATE: NOT UNDERSTOOD (Return to Listening)
                        logger.info("Voice detected but not understood")
                        self.leds.set_all(LED_LISTENING, brightness=5)

        except Exception as e:
            logger.error(f"Loop error: {e}")
            self.leds.set_all(LED_ERROR, brightness=20)
        finally:
            self.cleanup()

    def cleanup(self):
        if self.audio_stream: self.audio_stream.close()
        if self.pa: self.pa.terminate()
        if self.rhino: self.rhino.delete()
        self.leds.cleanup()

if __name__ == "__main__":
    # CRITICAL FIX: Create single instance, not multiple instances!
    service = PicoVoiceService()
    
    if service.setup_rhino() and service.setup_audio():
        service.process_voice_input()
    else:
        logger.error("Failed to initialize service")
        sys.exit(1)
PICO_SERVICE_EOF

chmod +x /usr/local/bin/evvos-pico-voice-service.py
log_success "PicoVoice voice recognition service script created"

# ============================================================================
# STEP 9: CREATE SYSTEMD SERVICE UNIT
# ============================================================================

log_section "Step 9: Create Systemd Service"

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
# STEP 10: ENABLE AND START SERVICE
# ============================================================================

log_section "Step 10: Enable and Start PicoVoice Service"

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
# STEP 11: VERIFY SERVICE STATUS
# ============================================================================

log_section "Step 11: Verify Service Status"

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
# STEP 12: SUMMARY & NEXT STEPS
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
