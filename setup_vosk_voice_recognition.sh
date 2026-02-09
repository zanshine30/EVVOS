#!/bin/bash
# Vosk Voice Recognition Setup for ReSpeaker 2-Mics HAT V2.0
# Detects 8 voice commands with RGB LED feedback and journalctl logging
#
# Tested on: Raspberry Pi Zero 2 W, Bookworm 12, Kernel 6.12
# Prerequisites: ReSpeaker HAT already configured (run setup_respeaker_enhanced.sh first)
#
# Usage: sudo bash setup_vosk_voice_recognition.sh

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
    echo "Usage: sudo bash setup_vosk_voice_recognition.sh"
    exit 1
fi
log_success "Running as root"

# Check if ALSA is configured
if ! aplay -l 2>/dev/null | grep -qi "seeed"; then
    log_warning "ReSpeaker HAT not detected. Please run setup_respeaker_enhanced.sh first."
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi
log_success "ReSpeaker HAT verified (or skipped)"

# Check Python3
if ! command -v python3 &> /dev/null; then
    log_error "Python3 not found"
    exit 1
fi
PYTHON_VERSION=$(python3 --version | awk '{print $2}')
log_success "Python3 detected: $PYTHON_VERSION"

# ============================================================================
# STEP 1: INSTALL SYSTEM DEPENDENCIES
# ============================================================================

log_section "Step 1: Install System Dependencies"

log_info "Updating package lists..."
apt-get update
log_success "Package lists updated"

log_info "Installing required packages..."
apt-get install -y \
    python3-pip \
    python3-dev \
    portaudio19-dev \
    libasound2 \
    libasound2-dev \
    libatlas-base-dev \
    libffi-dev \
    libssl-dev \
    libopenblas-dev \
    libsndfile1 \
    libjack-dev \
    python3-numpy \
    spidev \
    git \
    wget \
    curl || log_warning "Some packages may have failed"

log_success "System dependencies installed"

# ============================================================================
# STEP 2: ENSURE VIRTUAL ENVIRONMENT EXISTS
# ============================================================================

log_section "Step 2: Setup Python Virtual Environment"

VENV_PATH="/opt/evvos/venv"

if [ ! -d "$VENV_PATH" ]; then
    log_info "Creating virtual environment at $VENV_PATH..."
    python3 -m venv "$VENV_PATH"
    log_success "Virtual environment created"
else
    log_success "Virtual environment already exists"
fi

# Activate venv for package installation
source "$VENV_PATH/bin/activate"
log_success "Virtual environment activated"

# ============================================================================
# STEP 3: INSTALL PYTHON PACKAGES
# ============================================================================

log_section "Step 3: Install Python Voice Recognition Packages"

log_info "Upgrading pip, setuptools, wheel..."
pip install --upgrade pip setuptools wheel

log_info "Installing Vosk speech recognition library..."
if pip install --no-cache-dir vosk; then
    log_success "Vosk installed"
else
    log_warning "Vosk installation reported warnings (may still work)"
fi

log_info "Installing PyAudio for microphone access..."
if pip install --no-cache-dir pyaudio; then
    log_success "PyAudio installed"
else
    log_error "PyAudio installation failed. Attempting rebuild..."
    log_info "Rebuilding PyAudio with verbose output..."
    pip install --no-cache-dir --verbose pyaudio 2>&1 | tail -20 || log_warning "PyAudio rebuild reported issues"
fi

log_info "Installing additional audio and GPIO libraries..."
pip install --no-cache-dir \
    gpiozero \
    RPi.GPIO \
    spidev \
    numpy \
    requests

log_success "All Python packages installed"

# Verify PyAudio installation
log_info "Verifying PyAudio installation..."
python3 << 'PYAUDIO_VERIFICATION'
try:
    import pyaudio
    p = pyaudio.PyAudio()
    device_count = p.get_device_count()
    print(f"[PyAudio] ✓ Working correctly")
    print(f"[PyAudio] ✓ Found {device_count} audio devices")
    p.terminate()
except ImportError as e:
    print(f"[PyAudio] ✗ Import failed: {e}")
    print("[PyAudio] Attempting recovery...")
    exit(1)
except Exception as e:
    print(f"[PyAudio] ⚠ Warning: {e}")
PYAUDIO_VERIFICATION

# ============================================================================
# STEP 4: DOWNLOAD VOSK SPEECH RECOGNITION MODEL
# ============================================================================

log_section "Step 4: Download Vosk Speech Recognition Model"

MODEL_DIR="/opt/evvos/vosk_model"
mkdir -p "$MODEL_DIR"

# Use small English model (lightweight for Pi Zero 2 W)
MODEL_NAME="vosk-model-small-en-us-0.15"
MODEL_URL="https://alphacephei.com/vosk/models/$MODEL_NAME.zip"

if [ -d "$MODEL_DIR/$MODEL_NAME" ]; then
    log_success "Vosk model already installed"
else
    log_info "Downloading Vosk model ($MODEL_NAME)..."
    log_info "This is ~40 MB and may take 1-2 minutes..."
    
    cd "$MODEL_DIR"
    
    if wget -q --show-progress "$MODEL_URL"; then
        log_success "Model downloaded"
    else
        log_error "Failed to download Vosk model"
        exit 1
    fi
    
    log_info "Extracting model archive..."
    if unzip -q "$MODEL_NAME.zip"; then
        log_success "Model extracted"
    else
        log_error "Failed to extract model"
        exit 1
    fi
    
    # Clean up zip file
    rm "$MODEL_NAME.zip"
    log_info "Zip file removed (keeping extracted model)"
fi

# Create symlink for easy access
ln -sfn "$MODEL_DIR/$MODEL_NAME" "$MODEL_DIR/current"
log_success "Model available at: $MODEL_DIR/current"

# ============================================================================
# STEP 5: CREATE VOICE RECOGNITION SERVICE
# ============================================================================

log_section "Step 5: Create Voice Recognition Service Script"

cat > /usr/local/bin/evvos-voice-service.py << 'VOICE_SERVICE_EOF'
#!/usr/bin/env python3
"""
EVVOS Voice Recognition Service with LED Feedback
- Detects 8 voice commands using Vosk offline recognition
- Provides RGB LED feedback (listening/detected)
- Logs to journalctl and local files
- Integrates with ReSpeaker 2-Mics HAT V2.0

Tested on: Raspberry Pi Zero 2 W, Bookworm 12
"""

import sys
import os
import json
import logging
import subprocess
import time
import threading
from datetime import datetime, timezone, timedelta
from typing import Optional, Dict, List

try:
    import pyaudio
    from vosk import Model, KaldiRecognizer
except ImportError as e:
    print(f"ERROR: Missing package: {e}")
    print("Run: pip install vosk pyaudio")
    sys.exit(1)

try:
    import spidev
except ImportError:
    print("WARNING: spidev not found. LED feedback disabled.")
    spidev = None

# ============================================================================
# CONFIGURATION
# ============================================================================

# Voice recognition settings
VOSK_MODEL_PATH = "/opt/evvos/vosk_model/current"
SAMPLE_RATE = 16000
AUDIO_CHUNK_SIZE = 4000

# EVVOS command list (8 commands)
RECOGNIZED_COMMANDS = [
    "start recording",
    "stop recording",
    "emergency backup",
    "backup backup backup",
    "mark incident",
    "snapshot",
    "confirm",
    "cancel"
]

# LED configuration (ReSpeaker APA102)
LED_COUNT = 3  # ReSpeaker has 3 RGB LEDs

# LED Colors (RGB)
LED_COLORS = {
    "off": (0, 0, 0),
    "listening": (0, 150, 150),  # Cyan - listening for voice
    "recognized": (0, 255, 0),    # Green - command recognized
    "error": (255, 0, 0),         # Red - error occurred
}

# LED Brightness levels
LED_BRIGHTNESS = {
    "listening": 8,      # Dim cyan to indicate ready
    "recognized": 20,    # Bright green flash for command detection
    "error": 15,         # Bright red for errors
}

# Logging configuration
LOG_DIR = "/var/log/evvos"
LOG_FILE = f"{LOG_DIR}/evvos_voice_recognition.log"

os.makedirs(LOG_DIR, exist_ok=True)

# Setup logging (to file and syslog)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - [VOICE] - %(levelname)s - %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("EVVOS_Voice")

# ============================================================================
# RGB LED CONTROL (APA102 via SPI)
# ============================================================================

class PixelRing:
    """Controls ReSpeaker RGB LEDs via SPI"""
    
    def __init__(self, num_leds: int = 3):
        self.num_leds = num_leds
        self.spi = None
        self.enabled = False
        
        try:
            self.spi = spidev.SpiDev()
            self.spi.open(0, 0)  # SPI Bus 0, Chip Select 0
            self.spi.max_speed_hz = 8000000
            self.enabled = True
            logger.info(f"✓ RGB LED control initialized ({num_leds} LEDs)")
        except Exception as e:
            logger.warning(f"LED initialization failed: {e}")
            logger.warning("Voice commands will work, but LED feedback disabled")
            self.enabled = False

    def set_color(self, r: int, g: int, b: int, brightness: int = 5):
        """Set all LEDs to same color (non-blocking, fast)"""
        if not self.enabled:
            return
        
        try:
            data = [[r, g, b, brightness]] * self.num_leds
            self.show(data)
        except Exception as e:
            logger.debug(f"LED set_color error: {e}")

    def show(self, data: List[List[int]]):
        """Send LED frame data via SPI (optimized for speed)"""
        if not self.enabled or not self.spi:
            return
        
        try:
            # Pre-build the complete frame to minimize SPI calls
            frame_data = [0x00, 0x00, 0x00, 0x00]  # Start frame
            
            # Add LED frames
            for led in data:
                brightness = led[3] if len(led) > 3 else 5
                frame_data.extend([
                    0xE0 | (brightness & 0x1F),
                    led[2],  # Blue
                    led[1],  # Green
                    led[0],  # Red
                ])
            
            # Add end frame
            frame_data.extend([0xFF, 0xFF, 0xFF, 0xFF])
            
            # Single SPI transfer (faster than multiple transfers)
            self.spi.xfer2(frame_data)
        except Exception as e:
            logger.debug(f"LED show error: {e}")

    def off(self):
        """Turn off all LEDs"""
        if self.enabled:
            self.set_color(0, 0, 0, 0)

    def breathe(self, r: int, g: int, b: int, duration: float = 2.0, steps: int = 20):
        """
        Create a breathing (pulsing) effect
        duration: time for one full breath cycle (in/out)
        steps: number of brightness levels in the pulse
        """
        if not self.enabled:
            return
        
        try:
            min_brightness = 3
            max_brightness = 20
            
            # Fade in
            for i in range(steps):
                brightness = int(min_brightness + (max_brightness - min_brightness) * (i / steps))
                self.set_color(r, g, b, brightness)
                time.sleep(duration / (2 * steps))
            
            # Fade out
            for i in range(steps, 0, -1):
                brightness = int(min_brightness + (max_brightness - min_brightness) * (i / steps))
                self.set_color(r, g, b, brightness)
                time.sleep(duration / (2 * steps))
        except Exception as e:
            logger.debug(f"LED breathe error: {e}")

    def flash(self, r: int, g: int, b: int, times: int = 3, flash_duration: float = 0.15):
        """
        Flash a color multiple times
        times: number of flashes
        flash_duration: duration of each flash
        """
        if not self.enabled:
            return
        
        try:
            for i in range(times):
                # Flash on
                self.set_color(r, g, b, LED_BRIGHTNESS["recognized"])
                time.sleep(flash_duration)
                # Flash off
                self.set_color(0, 0, 0, 0)
                time.sleep(flash_duration * 0.5)
        except Exception as e:
            logger.debug(f"LED flash error: {e}")

    def close(self):
        """Cleanup SPI"""
        if self.enabled and self.spi:
            try:
                self.off()
                self.spi.close()
            except Exception as e:
                logger.debug(f"LED close error: {e}")

# ============================================================================
# VOICE RECOGNITION SERVICE
# ============================================================================

class VoiceRecognitionService:
    """Main voice recognition service"""
    
    def __init__(self):
        self.model = None
        self.recognizer = None
        self.audio_interface = None
        self.stream = None
        self.pixels = PixelRing(LED_COUNT)
        self.running = False
        self.device_index = None
        self.manila_tz = timezone(timedelta(hours=8))
        
        logger.info("=" * 70)
        logger.info("EVVOS Voice Recognition Service Starting")
        logger.info("=" * 70)

    def match_voice_command(self, text: str) -> str:
        """
        Intelligently match recognized text to a voice command
        Handles variations, partial matches, and key phrases
        Returns: command name if matched, None otherwise
        """
        text = text.lower().strip()
        words = text.split()
        
        # Define command matching patterns (keywords and phrases)
        command_patterns = {
            "start recording": ["start", "recording"],
            "stop recording": ["stop", "recording"],
            "emergency backup": ["emergency", "backup"],
            "backup backup backup": ["backup"],  # Check for "backup" word
            "mark incident": ["mark", "incident"],
            "snapshot": ["snapshot"],
            "confirm": ["confirm"],
            "cancel": ["cancel"],
        }
        
        # Priority ordering: longer/more specific commands first
        priority_order = [
            "emergency backup",
            "start recording",
            "stop recording",
            "mark incident",
            "backup backup backup",
            "snapshot",
            "confirm",
            "cancel",
        ]
        
        for cmd in priority_order:
            keywords = command_patterns[cmd]
            
            # Special case: "backup backup backup" - check for multiple "backup" words
            if cmd == "backup backup backup":
                backup_count = words.count("backup")
                if backup_count >= 2:  # At least 2 "backup" words
                    logger.debug(f"Command match: '{cmd}' (found {backup_count} 'backup' words in: '{text}')")
                    return cmd
            
            # Check if all keywords are present in the text (in order)
            elif all(keyword in text for keyword in keywords):
                logger.debug(f"Command match: '{cmd}' (keywords {keywords} in: '{text}')")
                return cmd
        
        return None

    def get_manila_time(self) -> str:
        """Get current time in Asia/Manila timezone"""
        return datetime.now(self.manila_tz).strftime("%Y-%m-%d %H:%M:%S PHT")

    def setup_vosk_model(self) -> bool:
        """Load Vosk speech recognition model"""
        logger.info("Loading Vosk speech recognition model...")
        
        if not os.path.exists(VOSK_MODEL_PATH):
            logger.error(f"Model not found at: {VOSK_MODEL_PATH}")
            logger.error("Run setup script to download model")
            return False
        
        try:
            self.model = Model(VOSK_MODEL_PATH)
            self.recognizer = KaldiRecognizer(self.model, SAMPLE_RATE)
            logger.info(f"✓ Vosk model loaded from: {VOSK_MODEL_PATH}")
            return True
        except Exception as e:
            logger.error(f"Failed to load Vosk model: {e}")
            return False

    def find_audio_device(self) -> Optional[int]:
        """Find ReSpeaker audio input device"""
        logger.info("Searching for ReSpeaker audio device...")
        
        try:
            p = pyaudio.PyAudio()
            device_count = p.get_device_count()
            logger.info(f"Found {device_count} audio devices")
            
            # Strategy 1: Look for device with "seeed" in name
            for i in range(device_count):
                info = p.get_device_info_by_index(i)
                name = info.get("name", "").lower()
                channels = info.get("maxInputChannels", 0)
                
                if channels > 0:
                    logger.debug(f"  Device [{i}] {info.get('name')} ({channels} input channels)")
                
                if any(keyword in name for keyword in ["seeed", "respeaker", "voicecard"]):
                    if channels > 0:
                        logger.info(f"✓ ReSpeaker found at device index {i}: {info.get('name')}")
                        p.terminate()
                        return i
            
            # Strategy 2: Use first device with input channels
            logger.warning("'seeed' device not found by name, using first available input device")
            for i in range(device_count):
                info = p.get_device_info_by_index(i)
                if info.get("maxInputChannels", 0) > 0:
                    logger.warning(f"Using device [{i}]: {info.get('name')}")
                    p.terminate()
                    return i
            
            logger.error("No audio input device found!")
            p.terminate()
            return None
            
        except Exception as e:
            logger.error(f"Error finding audio device: {e}")
            return None

    def setup_audio_stream(self) -> bool:
        """Open audio input stream"""
        logger.info("Setting up audio stream...")
        
        # Find audio device
        self.device_index = self.find_audio_device()
        if self.device_index is None:
            logger.error("Cannot setup audio stream without valid device")
            return False
        
        try:
            p = pyaudio.PyAudio()
            
            # Convert device index to integer
            device_idx = int(self.device_index)
            
            self.stream = p.open(
                format=pyaudio.paInt16,
                channels=1,
                rate=SAMPLE_RATE,
                input=True,
                frames_per_buffer=AUDIO_CHUNK_SIZE,
                input_device_index=device_idx
            )
            
            self.stream.start_stream()
            logger.info(f"✓ Audio stream opened on device {device_idx}")
            self.audio_interface = p
            return True
            
        except Exception as e:
            logger.error(f"Failed to open audio stream: {e}")
            return False

    def process_voice_input(self):
        """Main voice recognition loop"""
        logger.info("🎤 Listening for voice commands...")
        logger.info("=" * 70)
        logger.info("Recognized commands:")
        for i, cmd in enumerate(RECOGNIZED_COMMANDS, 1):
            logger.info(f"  {i}. {cmd}")
        logger.info("=" * 70)
        
        self.running = True
        consecutive_silence = 0
        max_silence_frames = 5  # ~1 second of silence
        
        # Breathing animation state (non-blocking, fast)
        breathing_step = 0
        breathing_max_steps = 50  # More steps = smoother & faster animation
        breathing_direction = 1  # 1 for fade in, -1 for fade out
        min_brightness = 3
        max_brightness = 20
        
        logger.info("Starting breathing cyan listening indicator...")
        
        try:
            while self.running:
                try:
                    # Update LED breathing effect (non-blocking, one step at a time)
                    brightness = int(min_brightness + (max_brightness - min_brightness) * (breathing_step / breathing_max_steps))
                    self.pixels.set_color(*LED_COLORS["listening"], brightness=brightness)
                    
                    # Update breathing animation state
                    breathing_step += breathing_direction
                    if breathing_step >= breathing_max_steps:
                        breathing_direction = -1
                    elif breathing_step <= 0:
                        breathing_direction = 1
                    
                    # Read audio chunk from microphone
                    data = self.stream.read(AUDIO_CHUNK_SIZE, exception_on_overflow=False)
                    
                    # Process audio with Vosk recognizer
                    if self.recognizer.AcceptWaveform(data):
                        # Final recognition result
                        result = json.loads(self.recognizer.Result())
                        text = result.get("text", "").strip().lower()
                        confidence = result.get("confidence", 0.0)
                        
                        if text:
                            consecutive_silence = 0
                            
                            # Use intelligent command matching
                            matched_command = self.match_voice_command(text)
                            if matched_command:
                                # Command detected!
                                self._on_command_detected(matched_command, text, confidence)
                            elif len(text) > 2:
                                logger.debug(f"No command matched in: '{text}' (confidence: {confidence})")
                    else:
                        # Partial result
                        partial = json.loads(self.recognizer.PartialResult())
                        partial_text = partial.get("partial", "").strip()
                        if partial_text:
                            logger.debug(f"Partial: '{partial_text}'")
                            consecutive_silence = 0
                        else:
                            consecutive_silence += 1
                
                except Exception as e:
                    logger.error(f"Error in voice loop: {e}")
                    time.sleep(0.5)
        
        except KeyboardInterrupt:
            logger.info("Voice recognition stopped by user")
        except Exception as e:
            logger.error(f"Fatal error in voice recognition: {e}")
        finally:
            self.shutdown()

    def _on_command_detected(self, command: str, full_text: str, confidence: float):
        """Handler for detected voice command"""
        
        # Flash green LED 3 times to indicate command recognized
        self.pixels.flash(*LED_COLORS["recognized"], times=3, flash_duration=0.2)
        
        # Log command detection
        timestamp = self.get_manila_time()
        log_message = f"🎤 [VOICE_COMMAND_DETECTED] '{command.upper()}' | Full: '{full_text}' | Confidence: {confidence:.2f}"
        
        # Log to both file and journalctl
        logger.warning(log_message)  # Use WARNING level for visibility
        
        # Also print to stdout (will be captured by journalctl)
        print(log_message)
        
        # Log to systemd journal with priority
        try:
            subprocess.run(
                ["systemd-cat", "-t", "evvos-voice", "-p", "warning"],
                input=log_message.encode(),
                timeout=1
            )
        except Exception as e:
            logger.debug(f"systemd-cat error: {e}")
        
        # TODO: Send command to mobile app or internal service
        # Example: POST to local API, write to pipe, etc.
        logger.info(f"Command '{command}' ready for processing")

    def shutdown(self):
        """Cleanup resources"""
        logger.info("Shutting down voice recognition service...")
        self.running = False
        
        try:
            if self.stream:
                self.stream.stop_stream()
                self.stream.close()
        except Exception as e:
            logger.debug(f"Error closing stream: {e}")
        
        try:
            if self.audio_interface:
                self.audio_interface.terminate()
        except Exception as e:
            logger.debug(f"Error terminating audio: {e}")
        
        try:
            self.pixels.off()
            self.pixels.close()
        except Exception as e:
            logger.debug(f"Error closing LEDs: {e}")
        
        logger.info("Voice recognition service shutdown complete")

    def run(self):
        """Main execution"""
        # Setup phase
        if not self.setup_vosk_model():
            logger.error("Failed to setup Vosk model")
            sys.exit(1)
        
        if not self.setup_audio_stream():
            logger.error("Failed to setup audio stream")
            sys.exit(1)
        
        # Show startup indicator
        self.pixels.set_color(0, 0, 255, brightness=8)  # Blue = starting
        time.sleep(1)
        
        # Main recognition loop
        self.process_voice_input()

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

def main():
    try:
        service = VoiceRecognitionService()
        service.run()
    except Exception as e:
        logger.error(f"Critical error: {e}", exc_info=True)
        sys.exit(1)

if __name__ == "__main__":
    main()
VOICE_SERVICE_EOF

chmod +x /usr/local/bin/evvos-voice-service.py
log_success "Voice recognition service script created"

# ============================================================================
# STEP 6: CREATE SYSTEMD SERVICE UNIT
# ============================================================================

log_section "Step 6: Create Systemd Service"

cat > /etc/systemd/system/evvos-voice.service << 'SERVICE_FILE'
[Unit]
Description=EVVOS Voice Recognition Service with RGB LED Feedback
Documentation=https://github.com/evvos
After=network.target sound.target alsa-restore.service
Requires=sound.target
Wants=alsa-restore.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/evvos
ExecStart=/opt/evvos/venv/bin/python3 /usr/local/bin/evvos-voice-service.py
Restart=always
RestartSec=10
StartLimitInterval=60
StartLimitBurst=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=evvos-voice
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

chmod 644 /etc/systemd/system/evvos-voice.service
log_success "Systemd service created"

# ============================================================================
# STEP 7: VERIFY VOSK MODEL
# ============================================================================

log_section "Step 7: Verify Vosk Model Installation"

if [ -d "$MODEL_DIR/current" ]; then
    CONF_FILE="$MODEL_DIR/current/conf/model.conf"
    if [ -f "$CONF_FILE" ]; then
        log_success "Vosk model verified"
        log_info "Model configuration:"
        head -5 "$CONF_FILE" | sed 's/^/  /'
    else
        log_warning "Model structure may be incomplete"
    fi
else
    log_error "Vosk model directory not found"
fi

# ============================================================================
# STEP 8: ENABLE AND START SERVICE
# ============================================================================

log_section "Step 8: Enable and Start Voice Recognition Service"

log_info "Reloading systemd daemon..."
systemctl daemon-reload

log_info "Enabling voice recognition service..."
systemctl enable evvos-voice
log_success "Service enabled (auto-start on boot)"

log_info "Starting voice recognition service..."
systemctl restart evvos-voice
sleep 2

log_success "Service started"

# ============================================================================
# STEP 9: VERIFY SERVICE STATUS
# ============================================================================

log_section "Step 9: Verify Service Status"

# Check if service is running
if systemctl is-active --quiet evvos-voice; then
    log_success "Voice recognition service is RUNNING"
else
    log_warning "Service may not be running. Check logs with:"
    log_warning "  sudo journalctl -u evvos-voice -n 20"
fi

# Show brief status
echo ""
systemctl status evvos-voice --no-pager | head -10
echo ""

# ============================================================================
# STEP 10: SUMMARY & NEXT STEPS
# ============================================================================

log_section "Vosk Voice Recognition Setup Complete!"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Voice Recognition Service Installed!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

log_info "Configuration Summary:"
echo "  • Vosk Model: $MODEL_DIR/current"
echo "  • Python Environment: $VENV_PATH"
echo "  • Service: evvos-voice.service"
echo "  • Log File: $LOG_FILE"
echo ""

log_info "Recognized Voice Commands (8 total):"
for cmd in "${RECOGNIZED_COMMANDS[@]}"; do
    echo "  • $cmd"
done
echo ""

log_info "LED Feedback Colors:"
echo "  • Cyan (listening): Waiting for voice input"
echo "  • Green (detected): Command recognized"
echo "  • Red (error): Service error occurred"
echo ""

log_info "IMPORTANT: WATCH LIVE LOGS while testing:"
echo ""
echo "  ${CYAN}sudo journalctl -u evvos-voice -f${NC}"
echo ""
echo "  When you speak a command, look for:"
echo "  ${GREEN}[VOICE_COMMAND_DETECTED]${NC} 'COMMAND_NAME' detected in: '...' | Confidence: 0.85"
echo ""

log_info "Service Management:"
echo ""
echo "  # View status:"
echo "  systemctl status evvos-voice"
echo ""
echo "  # View last 50 lines:"
echo "  sudo journalctl -u evvos-voice -n 50"
echo ""
echo "  # View logs since last reboot:"
echo "  sudo journalctl -u evvos-voice --since \"today\" -f"
echo ""
echo "  # Stop service:"
echo "  sudo systemctl stop evvos-voice"
echo ""
echo "  # Restart service:"
echo "  sudo systemctl restart evvos-voice"
echo ""
echo "  # View file logs:"
echo "  sudo tail -f $LOG_FILE"
echo ""

log_info "Audio Diagnostics (if commands not detected):"
echo ""
echo "  # Test microphone directly:"
echo "  arecord -f S16_LE -r 16000 -d 3 /tmp/test.wav && aplay /tmp/test.wav"
echo ""
echo "  # Adjust microphone gain (if too quiet/loud):"
echo "  sudo amixer -c seeed2micvoicec sset 'PGA' 25"
echo "  sudo alsactl store"
echo ""
echo "  # Check audio device:"
echo "  aplay -l && arecord -l"
echo ""

log_info "Troubleshooting:"
echo ""
echo "  Q: No commands detected?"
echo "  A: Check microphone gain and service logs"
echo ""
echo "  Q: Service keeps restarting?"
echo "  A: Check audio device is available (arecord -l)"
echo ""
echo "  Q: LED not showing?"
echo "  A: Check SPI is enabled (dtparam=spi=on in /boot/firmware/config.txt)"
echo ""

log_info "Next Steps:"
echo "  1. Run: ${CYAN}sudo journalctl -u evvos-voice -f${NC}"
echo "  2. Speak a command like: 'start recording' or 'snapshot'"
echo "  3. Watch for green LED flash and log message"
echo "  4. Adjust microphone gain if needed"
echo ""

log_info "Integration:"
echo "  • This service runs automatically on boot"
echo "  • Logs all detected commands to journalctl"
echo "  • Ready for integration with provisioning service"
echo ""

echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

log_success "Voice Recognition Service ready to use!"
echo ""
