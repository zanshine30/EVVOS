#!/bin/bash
# EVVOS Voice & Hardware Extension (ReSpeaker 2-Mic HAT)
# Adds Voice Commands and Button Reset to existing EVVOS installation
# Usage: sudo bash setup_evvos_voice_addon.sh

set -e  # Exit on error

echo "🎤 EVVOS Voice & Hardware Extension Setup"
echo "=========================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
  echo "❌ This script must be run as root."
  exit 1
fi

echo ""
echo "📦 Step 1: Install Audio & Hardware Dependencies"
echo "================================================"
apt-get update
apt-get install -y \
  portaudio19-dev \
  libasound2-dev \
  libatlas-base-dev \
  i2c-tools \
  unzip \
  python3-pip \
  python3-dev \
  git \
  dkms

echo ""
echo "🔊 Step 2: Install ReSpeaker 2-Mics HAT Drivers"
echo "================================================="
# Seeed Studio Drivers are required for the HAT to function
if [ ! -d "/var/lib/dkms/seeed-voicecard" ]; then
    echo "Installing Seeed Voice Card drivers..."
    cd /usr/src
    if [ -d "seeed-voicecard" ]; then rm -rf seeed-voicecard; fi
    
    if ! git clone https://github.com/respeaker/seeed-voicecard; then
        echo "❌ Failed to clone seeed-voicecard repository"
        exit 1
    fi
    
    cd seeed-voicecard
    # Install with kernel compatibility
    if ! ./install.sh --compat-kernel; then
        echo "❌ ReSpeaker driver installation failed"
        exit 1
    fi
    echo "✓ ReSpeaker drivers installed."
else
    echo "✓ ReSpeaker drivers detected (skipping install)."
fi

echo ""
echo "🧠 Step 3: Install Vosk Offline Model"
echo "====================================="
# We use the small English model to save space and RAM on the Pi Zero 2
MODEL_DIR="/opt/evvos/model"
mkdir -p "$MODEL_DIR"

if [ ! -d "$MODEL_DIR/vosk-model-small-en-us-0.15" ]; then
    echo "Downloading lightweight English model..."
    cd "$MODEL_DIR"
    
    if ! wget -q https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip; then
        echo "❌ Failed to download Vosk model"
        exit 1
    fi
    
    if ! unzip -o vosk-model-small-en-us-0.15.zip; then
        echo "❌ Failed to extract Vosk model"
        exit 1
    fi
    
    rm vosk-model-small-en-us-0.15.zip
    # Symlink for easy access
    ln -sfn "$MODEL_DIR/vosk-model-small-en-us-0.15" "$MODEL_DIR/current"
    echo "✓ Model installed at $MODEL_DIR/current"
else
    echo "✓ Model already exists."
fi

echo ""
echo "🐍 Step 4: Install Python Voice Libraries"
echo "========================================="
# Installing into the EXISTING virtual environment if possible
VENV_PATH="/opt/evvos/venv"

if [ ! -d "$VENV_PATH" ]; then
    echo "⚠️  Warning: Existing venv not found at $VENV_PATH. Creating one..."
    python3 -m venv "$VENV_PATH"
fi

source "$VENV_PATH/bin/activate"

echo "Installing: vosk, pyaudio, gpiozero, spidev, numpy..."
pip install --upgrade pip setuptools wheel
# spidev handles the APA102 LEDs
# gpiozero handles the Button
# pyaudio/vosk handle the voice
pip install vosk pyaudio spidev gpiozero numpy

if [ $? -ne 0 ]; then
    echo "❌ Failed to install Python packages. Check pip output above."
    exit 1
fi
echo "✓ All Python packages installed successfully"

echo ""
echo "🤖 Step 5: Deploy Voice Agent Script"
echo "===================================="

cat > /usr/local/bin/evvos-voice.py << 'VOICE_SCRIPT_EOF'
#!/usr/bin/env python3
"""
EVVOS Voice Command & Hardware Agent
- Detects voice commands via Vosk
- Controls ReSpeaker LEDs
- Handles Physical Button Reset (Hold 5s)
"""

import sys
import os
import json
import pyaudio
import spidev
import logging
import subprocess
import time
from gpiozero import Button
from vosk import Model, KaldiRecognizer

# --- Configuration ---
CREDS_FILE = "/etc/evvos/device_credentials.json"
SERVICE_TO_RESTART = "evvos-provisioning"
LOGS_DIR = "/var/log/evvos"

# --- Logging ---
os.makedirs(LOGS_DIR, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - [Voice] - %(levelname)s - %(message)s",
    handlers=[logging.FileHandler(f"{LOGS_DIR}/evvos_voice.log"), logging.StreamHandler()]
)
logger = logging.getLogger("EVVOS_Voice")

# --- APA102 LED Control (SPI) ---
class PixelRing:
    def __init__(self, num_leds=3):
        self.num_leds = num_leds
        self.spi = spidev.SpiDev()
        self.spi.open(0, 0) # SPI Bus 0, Device 0
        self.spi.max_speed_hz = 8000000

    def show(self, data):
        # Start Frame
        self.spi.xfer2([0x00] * 4)
        # LED Frames
        for i in range(self.num_leds):
            led = data[i]
            # Brightness (0xE0 | 0-31) + B + G + R
            brightness = led[3] if len(led) > 3 else 5
            self.spi.xfer2([0xE0 | (brightness & 0x1F), led[2], led[1], led[0]])
        # End Frame
        self.spi.xfer2([0xFF] * 4)

    def set_color(self, r, g, b, brightness=5):
        data = [[r, g, b, brightness]] * self.num_leds
        self.show(data)
        
    def off(self):
        self.set_color(0, 0, 0, 0)

    def close(self):
        self.off()
        self.spi.close()

# --- Button Logic (Reset) ---
def handle_factory_reset():
    logger.warning("🔘 BUTTON HELD 5s: Initiating Credentials Reset...")
    
    # Visual Feedback: Red Alert Flash
    try:
        pixels = PixelRing(3)
        for _ in range(5):
            pixels.set_color(255, 0, 0, 20) # Red High Brightness
            time.sleep(0.2)
            pixels.off()
            time.sleep(0.2)
        pixels.close()
    except Exception as e:
        logger.error(f"LED Error during reset: {e}")

    # 1. Delete Credentials
    if os.path.exists(CREDS_FILE):
        try:
            os.remove(CREDS_FILE)
            logger.info("✓ Credentials file deleted.")
        except Exception as e:
            logger.error(f"Failed to delete credentials: {e}")
    else:
        logger.info("Credentials file already missing.")

    # 2. Restart Provisioning Service
    logger.info(f"Restarting {SERVICE_TO_RESTART} service...")
    try:
        subprocess.run(["systemctl", "restart", SERVICE_TO_RESTART], check=True)
        logger.info("✓ Service restart command sent.")
    except Exception as e:
        logger.error(f"Failed to restart service: {e}")

# --- Voice Logic ---
def main():
    logger.info("Starting EVVOS Voice Agent...")
    
    # 1. Setup Button (GPIO 17 is standard for ReSpeaker 2-Mic HAT v2.0)
    # Note: For ReSpeaker HAT v2.0, physical button uses GPIO 17
    try:
        button = Button(17, hold_time=5)
        button.when_held = handle_factory_reset
        logger.info("✓ Button listener active (GPIO 17)")
    except Exception as button_err:
        logger.error(f"⚠️  Button initialization failed: {button_err}")
        logger.warning("Button reset feature disabled, but voice commands will still work")

    # 2. Setup LEDs
    try:
        pixels = PixelRing(3)
        # Yellow = Loading
        pixels.set_color(100, 100, 0, 5)
    except Exception as led_err:
        logger.error(f"⚠️  LED initialization failed: {led_err}")
        logger.warning("LED feedback disabled, but voice commands will still work")
        pixels = None 

    # 3. Load Vosk Model
    model_path = "/opt/evvos/model/current"
    if not os.path.exists(model_path):
        logger.error("Model not found. Please run setup script.")
        sys.exit(1)
    
    try:
        model = Model(model_path)
        recognizer = KaldiRecognizer(model, 16000)
    except Exception as e:
        logger.error(f"Vosk init failed: {e}")
        sys.exit(1)

    # 4. Setup Audio Stream
    p = pyaudio.PyAudio()
    device_index = None
    # Find ReSpeaker
    for i in range(p.get_device_count()):
        info = p.get_device_info_by_index(i)
        if "seeed" in info.get("name", "").lower():
            device_index = i
            logger.info(f"✓ Found ReSpeaker mic at index {i}")
            break
    
    if device_index is None:
        logger.warning("⚠️  ReSpeaker not found in device list, using default audio device")
        logger.info("Available audio devices:")
        for i in range(p.get_device_count()):
            info = p.get_device_info_by_index(i)
            logger.info(f"  [{i}] {info.get('name', 'Unknown')}")
            
    stream = p.open(format=pyaudio.paInt16, channels=1, rate=16000, input=True, 
                    frames_per_buffer=8000, input_device_index=device_index)
    stream.start_stream()

    # Ready Indication: Cyan/Blue (Listening)
    logger.info("✓ Listening for commands...")
    pixels.set_color(0, 100, 100, 2) 

    # Command List
    COMMANDS = [
        "start recording", "stop recording", "emergency backup", 
        "backup backup backup", "snapshot", "mark incident", 
        "cancel", "confirm"
    ]

    try:
        while True:
            data = stream.read(4000, exception_on_overflow=False)
            if recognizer.AcceptWaveform(data):
                result = json.loads(recognizer.Result())
                text = result.get("text", "")
                
                if text:
                    # Simple keyword matching
                    for cmd in COMMANDS:
                        if cmd in text:
                            logger.info(f"⚡ COMMAND DETECTED: {cmd.upper()}")
                            
                            # Visual Feedback: Green Flash (if LEDs available)
                            if pixels:
                                pixels.set_color(0, 255, 0, 10)
                                time.sleep(0.5)
                                # Return to Listening Color
                                pixels.set_color(0, 100, 100, 2)
                            
                            # TODO: Insert logic to trigger these actions
                            # e.g. write to a pipe, socket, or call API
                            
    except KeyboardInterrupt:
        logger.info("Stopping...")
    finally:
        if pixels:
            pixels.off()
            pixels.close()
        stream.stop_stream()
        stream.close()
        p.terminate()

if __name__ == "__main__":
    main()
VOICE_SCRIPT_EOF

chmod +x /usr/local/bin/evvos-voice.py
echo "✓ Voice script created at /usr/local/bin/evvos-voice.py"

echo ""
echo "🔧 Step 6: Create & Start Systemd Service"
echo "========================================="

cat > /etc/systemd/system/evvos-voice.service << 'SERVICE_FILE'
[Unit]
Description=EVVOS Voice Command & Hardware Agent
After=network.target sound.target
Requires=sound.target

[Service]
Type=simple
User=root
# Use the same VENV as the main app
WorkingDirectory=/opt/evvos
ExecStart=/opt/evvos/venv/bin/python3 /usr/local/bin/evvos-voice.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=evvos-voice
# Allow access to GPIO and SPI without special permissions (User is root)
Environment="PATH=/opt/evvos/venv/bin:/usr/bin"
Environment="GPIOZERO_PIN_FACTORY=native"

[Install]
WantedBy=multi-user.target
SERVICE_FILE

systemctl daemon-reload
systemctl enable evvos-voice
systemctl restart evvos-voice

echo ""
echo "✅ Setup Complete!"
echo "=================="
echo "1. The ReSpeaker driver was installed (if not already there)."
echo "2. Vosk offline model downloaded."
echo "3. Voice Agent service is running."
echo ""
echo "⚠️  NOTE: If you just installed the ReSpeaker drivers for the first time,"
echo "   you MUST reboot the Raspberry Pi for audio to work."
echo "   Run: sudo reboot"
echo ""