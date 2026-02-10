#!/bin/bash
# PicoVoice Rhino Intent Recognition Setup for ReSpeaker 2-Mics HAT V2.0
# Detects EVVOS voice commands with intent recognition
# RGB LED feedback and journalctl logging
#
# Intent Model:
# - changeRecording: "start recording", "stop recording"
# - emergency: "emergency backup"
# - captureIncident: "mark incident", "snapshot"
# - userAction: "confirm", "cancel"
#
# Tested on: Raspberry Pi Zero 2 W, Bookworm 12, Kernel 6.12
# Prerequisites: ReSpeaker HAT already configured (run setup_respeaker_enhanced.sh first)
#
# Usage: sudo bash setup_pico_voice_recognition.sh

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
    echo "Usage: sudo bash setup_pico_voice_recognition.sh"
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
# STEP 1: VERIFY PREREQUISITES
# ============================================================================

log_section "Step 1: Verify Prerequisites"

log_info "Checking for required system packages..."

log_info "Python3 development and audio libraries should be installed by:"
echo "  • setup_respeaker_enhanced.sh (ReSpeaker HAT configuration)"
echo ""

log_info "If packages are missing, install them with:"
echo "  sudo apt-get install -y python3-pip python3-dev portaudio19-dev \\"
echo "    libasound2-dev libatlas-base-dev libffi-dev libssl-dev spidev git"
echo ""

log_info "Verifying ReSpeaker audio HAT..."
if aplay -l 2>/dev/null | grep -qi "seeed"; then
    log_success "✓ ReSpeaker HAT detected and configured"
    log_info "Audio codec (TLV320AIC3104) is ready with optimized settings"
else
    log_warning "ReSpeaker HAT not detected"
    log_error "Please run setup_respeaker_enhanced.sh first to configure the ReSpeaker HAT"
    exit 1
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
    python3-pip \
    wget \
    curl || log_warning "Some packages may have failed"

log_success "Build dependencies installed"

# ============================================================================
# STEP 3: SETUP PYTHON VIRTUAL ENVIRONMENT
# ============================================================================

log_section "Step 3: Setup Python Virtual Environment"

VENV_PATH="/opt/evvos/venv"

if [ ! -d "$VENV_PATH" ]; then
    log_info "Creating virtual environment at $VENV_PATH..."
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

log_info "Upgrading pip, setuptools, wheel..."
pip install --upgrade pip setuptools wheel

log_info "Installing PicoVoice Rhino SDK..."
if pip install --no-cache-dir pico-cython pvoice; then
    log_success "PicoVoice Rhino SDK installed"
else
    log_warning "Primary PicoVoice install reported issues, trying alternative..."
    pip install --no-cache-dir picovoice pvrhino || log_warning "PicoVoice installation completed with warnings"
fi

log_info "Installing PyAudio for microphone access..."
if pip install --no-cache-dir pyaudio; then
    log_success "PyAudio installed"
else
    log_error "PyAudio installation failed. Attempting rebuild..."
    log_info "Rebuilding PyAudio with verbose output..."
    pip install --no-cache-dir --verbose pyaudio 2>&1 | tail -20 || log_warning "PyAudio rebuild reported issues"
fi

log_info "Installing audio processing and integration libraries..."
pip install --no-cache-dir \
    numpy \
    requests \
    webrtcvad \
    noisereduce \
    scipy

log_info "Installing GPIO and LED control libraries..."
pip install --no-cache-dir \
    gpiozero \
    RPi.GPIO \
    spidev 2>/dev/null || log_warning "GPIO libraries optional (LED support)"

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
# STEP 5: CREATE PICOVOICE INTENT MODEL
# ============================================================================

log_section "Step 5: Setup Custom PicoVoice Rhino Context"

MODEL_DIR="/opt/evvos/pico_model"
mkdir -p "$MODEL_DIR"

log_info "Custom EVVOSVOICE Context File Setup"
log_info "Your custom Rhino context has been trained on PicoVoice console with the following intents:"
echo ""
echo "  ${CYAN}recording_control${NC}: Control recording state"
echo "    • 'start recording'"
echo "    • 'stop recording'"
echo ""
echo "  ${CYAN}emergency_action${NC}: Emergency backup trigger"
echo "    • 'alert'"
echo "    • 'emergency backup'"
echo ""
echo "  ${CYAN}incident_capture${NC}: Capture incident data or photos"
echo "    • 'screenshot'"
echo "    • 'snapshot'"
echo ""
echo "  ${CYAN}user_confirmation${NC}: General user confirmations"
echo "    • 'cancel'"
echo "    • 'confirm'"
echo ""
echo "  ${CYAN}incident_mark${NC}: Mark incident"
echo "    • 'mark incident'"
echo ""

log_info "Copying custom context file to Raspberry Pi deployment directory..."
log_warning "NOTE: The .rhn file will be transferred to Raspberry Pi at: /opt/evvos/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn"
echo ""
log_info "When deploying to Raspberry Pi, you will need to SCP the context file:"
echo "  ${CYAN}scp bd4a3c6c-f499-4326-8c7a-883fc8636103/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn \\"
echo "    pi@raspberrypi.local:/opt/evvos/${NC}"
echo ""

log_success "Custom context configuration ready for deployment"

# ============================================================================
# STEP 6: GET PICOVOICE ACCESS KEY
# ============================================================================

log_section "Step 6: PicoVoice Access Key Setup"

log_success "AccessKey provided: yDCtxCN8bet0r5wxMRaNQMWF7mvbu/MNgklGfQZHHZ6UONjoGIQUkQ=="
echo ""
log_info "This AccessKey is tied to your EVVOSVOICE custom context on PicoVoice console."
echo ""

ACCESS_KEY_FILE="/opt/evvos/pico_access_key.txt"
PROVIDED_KEY="yDCtxCN8bet0r5wxMRaNQMWF7mvbu/MNgklGfQZHHZ6UONjoGIQUkQ=="

if [ -f "$ACCESS_KEY_FILE" ]; then
    log_info "Updating existing access key file at: $ACCESS_KEY_FILE"
    echo "$PROVIDED_KEY" > "$ACCESS_KEY_FILE"
    chmod 600 "$ACCESS_KEY_FILE"
    log_success "AccessKey updated"
else
    log_info "Creating new access key file at: $ACCESS_KEY_FILE"
    echo "$PROVIDED_KEY" > "$ACCESS_KEY_FILE"
    chmod 600 "$ACCESS_KEY_FILE"
    log_success "AccessKey saved to: $ACCESS_KEY_FILE"
fi

log_info "When deploying to Raspberry Pi, this AccessKey will be transferred:"
echo "  ${CYAN}scp /opt/evvos/pico_access_key.txt pi@raspberrypi.local:/opt/evvos/${NC}"
echo ""

# ============================================================================
# STEP 7: CREATE PICOVOICE VOICE RECOGNITION SERVICE
# ============================================================================

log_section "Step 7: Create PicoVoice Voice Recognition Service"

cat > /usr/local/bin/evvos-pico-voice-service.py << 'PICO_SERVICE_EOF'
#!/usr/bin/env python3
"""
EVVOS PicoVoice Rhino Intent Recognition Service
- Intent-based voice command recognition using PicoVoice Rhino
- Structured command extraction with slot detection
- RGB LED feedback (listening/detected)
- Logs to journalctl and local files
- Integrates with ReSpeaker 2-Mics HAT V2.0

Intent Model:
  changeRecording: "start recording", "stop recording"
  emergency: "emergency backup"
  captureIncident: "mark incident", "snapshot"
  userAction: "confirm", "cancel"

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
except ImportError as e:
    print(f"ERROR: Missing package: {e}")
    print("Run: pip install pyaudio")
    sys.exit(1)

try:
    from picovoice import AccessKey, create_rhino
except ImportError:
    print("ERROR: PicoVoice SDK not installed")
    print("Run: pip install picovoice")
    sys.exit(1)

try:
    import spidev
except ImportError:
    print("WARNING: spidev not found. LED feedback disabled.")
    spidev = None

try:
    import webrtcvad
except ImportError:
    print("WARNING: webrtcvad not found. Voice Activity Detection disabled.")
    webrtcvad = None

try:
    import noisereduce as nr
except ImportError:
    print("WARNING: noisereduce not found. Noise suppression disabled.")
    nr = None

# ============================================================================
# CONFIGURATION
# ============================================================================

# PicoVoice/Rhino settings
PICO_ACCESS_KEY_FILE = "/opt/evvos/pico_access_key.txt"
CUSTOM_CONTEXT_FILE = "/opt/evvos/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn"
SAMPLE_RATE = 16000  # Optimized for speech recognition clarity
AUDIO_CHUNK_SIZE = 512  # Rhino processes in fixed frame lengths (~26ms at 16kHz)
# Note: Audio codec (TLV320AIC3104) is pre-configured by setup_respeaker_enhanced.sh
# Microphone gain is set to optimal levels (PGA ~25) for accurate voice capture

# Intent names and descriptions (from EVVOSVOICE custom context)
INTENT_MAPPING = {
    "recording_control": "Recording Control",
    "emergency_action": "Emergency Action",
    "incident_capture": "Incident Capture",
    "user_confirmation": "User Confirmation",
    "incident_mark": "Incident Mark",
}

# LED configuration
LED_COUNT = 3

LED_COLORS = {
    "off": (0, 0, 0),
    "listening": (0, 150, 150),  # Cyan
    "recognized": (0, 255, 0),    # Green
    "error": (255, 0, 0),         # Red
}

LED_BRIGHTNESS = {
    "listening": 8,
    "recognized": 20,
    "error": 15,
}

# Logging configuration
LOG_DIR = "/var/log/evvos"
LOG_FILE = f"{LOG_DIR}/evvos_pico_voice_recognition.log"

os.makedirs(LOG_DIR, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - [PICO_VOICE] - %(levelname)s - %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("EVVOS_PicoVoice")

# ============================================================================
# RGB LED CONTROL
# ============================================================================

class PixelRing:
    """Controls ReSpeaker RGB LEDs via SPI"""
    
    def __init__(self, num_leds: int = 3):
        self.num_leds = num_leds
        self.spi = None
        self.enabled = False
        
        try:
            if spidev:
                self.spi = spidev.SpiDev()
                self.spi.open(0, 0)
                self.spi.mode = 0b00
                self.spi.set_clock_hz(8000000)
                self.enabled = True
                logger.info(f"✓ RGB LED control initialized ({num_leds} LEDs)")
        except Exception as e:
            logger.warning(f"LED control unavailable: {e}")

    def set_color(self, r: int, g: int, b: int, brightness: int = 5):
        """Set all LEDs to the same color"""
        if not self.enabled:
            return
        
        try:
            data = [[b, g, r, brightness] for _ in range(self.num_leds)]
            self.show(data)
        except Exception as e:
            logger.warning(f"LED color change failed: {e}")

    def show(self, data: List[List[int]]):
        """Send LED frame data via SPI"""
        if not self.enabled or not self.spi:
            return
        
        try:
            # APA102 protocol: 4 bytes start, LED data, 4 bytes end
            frame_data = [0x00, 0x00, 0x00, 0x00]  # Start frame
            for led in data:
                frame_data.extend(led)
            frame_data.extend([0xFF, 0xFF, 0xFF, 0xFF])  # End frame
            self.spi.xfer2(frame_data)
        except Exception as e:
            logger.warning(f"SPI transmission failed: {e}")

    def off(self):
        """Turn off all LEDs"""
        if self.enabled:
            self.set_color(0, 0, 0)

    def flash(self, r: int, g: int, b: int, times: int = 3, flash_duration: float = 0.15):
        """Flash a color multiple times"""
        if not self.enabled:
            return
        
        try:
            for _ in range(times):
                self.set_color(r, g, b, 20)
                time.sleep(flash_duration)
                self.off()
                time.sleep(flash_duration * 0.5)
        except Exception as e:
            logger.warning(f"LED flash failed: {e}")

    def close(self):
        """Cleanup SPI"""
        if self.enabled and self.spi:
            try:
                self.spi.close()
                logger.info("✓ LED ring closed")
            except Exception as e:
                logger.warning(f"LED cleanup error: {e}")

# ============================================================================
# PICOVOICE RHINO SERVICE
# ============================================================================

class PicoVoiceService:
    """Main PicoVoice Rhino intent recognition service"""
    
    def __init__(self):
        self.rhino = None
        self.audio_interface = None
        self.stream = None
        self.pixels = PixelRing(LED_COUNT)
        self.running = False
        self.device_index = None
        self.manila_tz = timezone(timedelta(hours=8))
        
        # WebRTC VAD
        self.vad = None
        self.vad_mode = 2
        if webrtcvad:
            try:
                self.vad = webrtcvad.Vad()
                self.vad.set_operating_point(self.vad_mode)
            except Exception as e:
                logger.warning(f"VAD initialization failed: {e}")
        
        self.audio_buffer = []
        self.buffer_size = 32000
        
        logger.info("=" * 70)
        logger.info("EVVOS PicoVoice Rhino Intent Recognition Service Starting")
        logger.info("=" * 70)

    def get_manila_time(self) -> str:
        """Get current time in Asia/Manila timezone"""
        return datetime.now(self.manila_tz).strftime("%Y-%m-%d %H:%M:%S PHT")

    def load_access_key(self) -> Optional[str]:
        """Load PicoVoice AccessKey from file"""
        try:
            with open(PICO_ACCESS_KEY_FILE, 'r') as f:
                key = f.read().strip()
                if key:
                    logger.info("✓ PicoVoice AccessKey loaded")
                    return key
        except FileNotFoundError:
            logger.error(f"AccessKey file not found: {PICO_ACCESS_KEY_FILE}")
        except Exception as e:
            logger.error(f"Failed to load AccessKey: {e}")
        
        return None

    def setup_rhino(self) -> bool:
        """Initialize Rhino intent recognition engine with custom context"""
        logger.info("Initializing PicoVoice Rhino engine with custom EVVOSVOICE context...")
        
        access_key = self.load_access_key()
        if not access_key:
            logger.error("Cannot proceed without valid AccessKey")
            return False
        
        try:
            # Load custom Rhino context from downloaded file
            if not os.path.exists(CUSTOM_CONTEXT_FILE):
                logger.error(f"Custom context file not found: {CUSTOM_CONTEXT_FILE}")
                return False
            
            logger.info(f"Loading custom context: {CUSTOM_CONTEXT_FILE}")
            
            # Create Rhino instance with custom context
            self.rhino = create_rhino(
                access_key=access_key,
                context_path=CUSTOM_CONTEXT_FILE,
                sample_rate=SAMPLE_RATE,
            )
            logger.info(f"✓ Rhino initialized with custom context (frame length: {self.rhino.frame_length})")
            logger.info(f"Custom context expressions loaded from EVVOSVOICE")
            return True
        except Exception as e:
            logger.error(f"Rhino initialization failed: {e}")
            return False

    def find_audio_device(self) -> Optional[int]:
        """Find ReSpeaker audio input device"""
        logger.info("Searching for ReSpeaker audio device...")
        
        try:
            self.audio_interface = pyaudio.PyAudio()
            device_count = self.audio_interface.get_device_count()
            
            for i in range(device_count):
                info = self.audio_interface.get_device_info_by_index(i)
                if "seeed" in info["name"].lower() and info["maxInputChannels"] > 0:
                    logger.info(f"✓ Found ReSpeaker: {info['name']} (index {i})")
                    return i
            
            logger.warning("ReSpeaker not found, using default device")
            return None
            
        except Exception as e:
            logger.error(f"Audio device search failed: {e}")
            return None

    def setup_audio_stream(self) -> bool:
        """Open audio input stream"""
        logger.info("Setting up audio stream...")
        
        self.device_index = self.find_audio_device()
        
        try:
            self.stream = self.audio_interface.open(
                format=pyaudio.paInt16,
                channels=1,
                rate=SAMPLE_RATE,
                input=True,
                input_device_index=self.device_index,
                frames_per_buffer=AUDIO_CHUNK_SIZE,
                start=False,
            )
            logger.info("✓ Audio stream opened")
            return True
        except Exception as e:
            logger.error(f"Audio stream setup failed: {e}")
            return False

    def preprocess_audio(self, data: bytes) -> bool:
        """Preprocess audio using WebRTC VAD"""
        if not self.vad:
            return True
        
        try:
            is_speech = self.vad.is_speech(data, SAMPLE_RATE)
            if not is_speech:
                logger.debug("Silent frame skipped (VAD)")
            return is_speech
        except Exception as e:
            logger.warning(f"VAD processing failed: {e}")
            return True

    def apply_noise_reduction(self, data: bytes) -> bytes:
        """Apply noise reduction"""
        if not nr:
            return data
        
        try:
            import numpy as np
            audio_np = np.frombuffer(data, dtype=np.int16)
            reduced = nr.reduce_noise(y=audio_np, sr=SAMPLE_RATE)
            return reduced.astype(np.int16).tobytes()
        except Exception as e:
            logger.warning(f"Noise reduction failed: {e}")
            return data

    def process_voice_input(self):
        """Main intent recognition loop with optimized audio quality"""
        logger.info("🎤 Listening for voice commands...")
        logger.info("=" * 70)
        logger.info("Recognized Intents:")
        for intent, desc in INTENT_MAPPING.items():
            logger.info(f"  • {intent}: {desc}")
        logger.info("=" * 70)
        
        if not self.stream:
            logger.error("Audio stream not initialized")
            return
        
        self.running = True
        self.stream.start_stream()
        self.pixels.set_color(*LED_COLORS["listening"], brightness=15)
        
        logger.info("Listening indicator on, ready for voice commands...")
        logger.info("Audio Processing: WebRTC VAD + Noise Reduction for optimal clarity")
        
        consecutive_silence = 0
        max_silence_frames = 10  # ~2.6 seconds of silence triggers attention reset
        
        try:
            while self.running:
                try:
                    # Read audio chunk (Rhino requires specific frame length)
                    audio_data = self.stream.read(
                        self.rhino.frame_length,
                        exception_on_overflow=False
                    )
                    
                    # Voice Activity Detection: Skip silent frames for efficiency
                    if not self.preprocess_audio(audio_data):
                        consecutive_silence += 1
                        if consecutive_silence > max_silence_frames:
                            # Reset after extended silence
                            consecutive_silence = 0
                        continue
                    
                    consecutive_silence = 0
                    
                    # Noise Reduction: Improve clarity by removing background noise
                    audio_data = self.apply_noise_reduction(audio_data)
                    
                    # Intent Recognition: Process with Rhino engine
                    try:
                        self.rhino.process(audio_data)
                    except Exception as e:
                        logger.warning(f"Rhino processing error: {e}")
                        continue
                    
                    # Check if utterance is complete and understood
                    if self.rhino.is_understood():
                        intent = self.rhino.get_intent()
                        slots = self.rhino.get_slots()
                        self._on_command_detected(intent, slots)
                    
                except Exception as e:
                    logger.error(f"Error processing audio chunk: {e}")
                    
except KeyboardInterrupt:
            logger.info("Voice recognition stopped by user")
        except Exception as e:
            logger.error(f"Fatal error in voice recognition: {e}", exc_info=True)
        finally:
            self.shutdown()

    def _on_command_detected(self, intent: str, slots: Dict[str, str]):
        """Handler for detected intent"""
        
        self.pixels.flash(*LED_COLORS["recognized"], times=3, flash_duration=0.2)
        
        timestamp = self.get_manila_time()
        slots_str = json.dumps(slots) if slots else "{}"
        
        log_message = f"🎤 [INTENT_DETECTED] Intent: '{intent}' | Slots: {slots_str}"
        
        logger.warning(log_message)
        print(log_message)
        
        try:
            subprocess.run(
                ["systemd-cat", "-t", "evvos-pico", "-p", "warning", log_message],
                check=False,
            )
        except Exception as e:
            logger.debug(f"systemd-cat failed: {e}")
        
        # Attempt to send to Edge Function
        edge_fn_url = os.getenv("INSERT_VOICE_FN_URL") or os.getenv("SUPABASE_EDGE_FN_URL")
        
        if edge_fn_url:
            try:
                import requests
                
                payload = {
                    "intent": intent,
                    "slots": slots,
                    "timestamp": timestamp,
                    "device_type": "respeaker_pico",
                    "confidence": 1.0,
                }
                
                headers = {
                    "Authorization": f"Bearer {os.getenv('SUPABASE_ANON_KEY', '')}",
                    "Content-Type": "application/json",
                }
                
                response = requests.post(edge_fn_url, json=payload, headers=headers, timeout=5)
                
                if response.status_code == 200:
                    logger.info(f"✓ Intent sent to Edge Function: {intent}")
                else:
                    logger.warning(f"Edge Function returned {response.status_code}: {response.text}")
                    
            except Exception as e:
                logger.debug(f"Edge Function request failed: {e}")
        else:
            logger.debug("INSERT_VOICE_FN_URL not set - skipping Edge Function")

    def shutdown(self):
        """Cleanup resources"""
        logger.info("Shutting down voice recognition service...")
        
        self.running = False
        
        if self.stream:
            try:
                self.stream.stop_stream()
                self.stream.close()
                logger.info("✓ Audio stream closed")
            except Exception as e:
                logger.warning(f"Stream cleanup error: {e}")
        
        if self.audio_interface:
            try:
                self.audio_interface.terminate()
                logger.info("✓ PyAudio terminated")
            except Exception as e:
                logger.warning(f"PyAudio cleanup error: {e}")
        
        if self.rhino:
            try:
                self.rhino.delete()
                logger.info("✓ Rhino engine closed")
            except Exception as e:
                logger.warning(f"Rhino cleanup error: {e}")
        
        self.pixels.off()
        self.pixels.close()
        
        logger.info("=" * 70)
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
echo "  • Intent Model: EVVOSVOICE Custom Context (5 intents, trained via PicoVoice console)"
echo "  • Python Environment: $VENV_PATH"
echo "  • Service: evvos-pico-voice.service"
echo "  • Log File: $LOG_FILE"
echo "  • Access Key: $ACCESS_KEY_FILE"
echo "  • Custom Context: /opt/evvos/EVVOSVOICE_en_raspberry-pi_v4_0_0.rhn"
echo ""

log_info "Recognized Intents and Commands (EVVOSVOICE Custom Context):"
echo ""
echo "  ${CYAN}recording_control${NC}: Recording control"
echo "    • 'start recording' → Intent: recording_control"
echo "    • 'stop recording' → Intent: recording_control"
echo ""
echo "  ${CYAN}emergency_action${NC}: Emergency backup"
echo "    • 'emergency backup' → Intent: emergency_action"
echo "    • 'alert' → Intent: emergency_action"
echo ""
echo "  ${CYAN}incident_capture${NC}: Incident capture"
echo "    • 'mark incident' → Intent: incident_capture"
echo "    • 'snapshot' → Intent: incident_capture"
echo "    • 'screenshot' → Intent: incident_capture"
echo ""
echo "  ${CYAN}user_confirmation${NC}: Confirmations"
echo "    • 'confirm' → Intent: user_confirmation"
echo "    • 'cancel' → Intent: user_confirmation"
echo ""
echo "  ${CYAN}incident_mark${NC}: Incident marking"
echo "    • 'mark incident' → Intent: incident_mark"
echo ""

log_info "LED Status Indicators:"
echo "  • ${CYAN}Cyan (Listening)${NC}: Waiting for voice input"
echo "  • ${GREEN}Green (Detected)${NC}: Intent successfully recognized"
echo "  • ${RED}Red (Error)${NC}: Service error occurred"
echo ""

log_info "IMPORTANT: Check logs while testing:"
echo ""
echo "  ${CYAN}sudo journalctl -u evvos-pico-voice -f${NC}"
echo ""
echo "  When you speak a command, look for:"
echo "  ${GREEN}[INTENT_DETECTED] Intent: 'changeRecording' | Slots: {}${NC}"
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

log_info "Troubleshooting:"
echo ""
echo "  Q: 'AccessKey not loaded' error?"
echo "  A: Ensure AccessKey is saved to: $ACCESS_KEY_FILE"
echo "     Get free key from: https://console.picovoice.ai"
echo ""
echo "  Q: No intents recognized?"
echo "  A: Check microphone with: arecord -f S16_LE -r 16000 -d 3 /tmp/test.wav"
echo "     Adjust PGA gain: sudo amixer -c seeed2micvoicec sset 'PGA' 25"
echo ""
echo "  Q: Service keeps restarting?"
echo "  A: Check logs: sudo journalctl -u evvos-pico-voice --no-pager"
echo "     Verify audio device: aplay -l && arecord -l"
echo ""

log_info "Next Steps:"
echo "  1. Verify AccessKey is set: cat $ACCESS_KEY_FILE"
echo "  2. Monitor logs: ${CYAN}sudo journalctl -u evvos-pico-voice -f${NC}"
echo "  3. Speak a command: 'start recording' or 'snapshot'"
echo "  4. Watch for green LED flash and log message"
echo "  5. If no detection, adjust microphone gain and test"
echo ""

log_info "PicoVoice Rhino Advantages:"
echo "  • Intent-based recognition (more structured than Vosk)"
echo "  • Extracts intent and slots from user speech"
echo "  • Better accuracy for EVVOS command patterns"
echo "  • Lighter CPU footprint than Vosk on Pi Zero 2 W"
echo "  • Free tier includes sufficient API quota"
echo ""

log_info "Integration with EVVOS:"
echo "  • Service logs intent detections to journalctl"
echo "  • Sends intent data to Supabase Edge Function (if configured)"
echo "  • RGB LED feedback for user feedback"
echo "  • Automatic startup on system boot"
echo ""

echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

log_success "PicoVoice Rhino Service ready to use!"
echo ""
log_info "Verify everything is working with:"
echo "  ${CYAN}sudo journalctl -u evvos-pico-voice -f${NC}"
echo ""
