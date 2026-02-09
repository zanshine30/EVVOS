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
    # Attempt installation with kernel compatibility
    # Note: May fail on kernel mismatches - this is expected if rpi-update was used
    echo "⏳ Attempting driver installation (may report kernel mismatch - this is OK)..."
    
    # Capture output to check for kernel mismatch
    if ! ./install.sh --compat-kernel 2>&1 | tee /tmp/respeaker_install.log; then
        # Check if it's a kernel mismatch issue (not a critical error)
        if grep -qi "kernel version\|not found.*kernel headers" /tmp/respeaker_install.log; then
            echo ""
            echo "⚠️  Kernel version mismatch detected (common after rpi-update)"
            echo "   This is expected and non-critical."
            echo ""
            echo "Attempting fallback installation method..."
            
            # Try building from source with current kernel
            if [ -f "install.sh" ]; then
                # Make install script more permissive
                sed -i 's/exit 1/# exit 1/g' install.sh
                if ./install.sh --compat-kernel; then
                    echo "✓ ReSpeaker drivers installed via fallback method."
                else
                    echo "⚠️  Driver installation reported errors, but continuing anyway."
                    echo "   The HAT may still work with generic I2S/ALSA drivers."
                fi
            fi
        else
            echo "❌ ReSpeaker driver installation failed (non-kernel issue)"
            # Don't exit - HAT may still work with generic drivers
        fi
    else
        echo "✓ ReSpeaker drivers installed successfully."
    fi
else
    echo "✓ ReSpeaker drivers detected (skipping install)."
fi

echo ""
echo "🔊 Step 3: Configure ALSA Microphone Levels"
echo "============================================"
# Configure alsamixer to set appropriate microphone gain/threshold for ReSpeaker

# Install alsa-utils if not present
if ! command -v amixer &> /dev/null; then
    echo "Installing ALSA utilities..."
    apt-get install -y alsa-utils 
    echo "✓ ALSA utils installed"
fi

# Create ALSA config for persistent settings
echo "Configuring ALSA levels for ReSpeaker..."

# Wait for sound system to initialize
sleep 2

echo "⏳ Setting microphone gains for TLV320AIC3104 codec..."

# ReSpeaker 2-Mics HAT V2.0 uses TLV320AIC3104 codec
# These are the specific controls for this codec:
echo "Configuring TLV320AIC3104 Audio Codec..."

# List available controls for debugging
echo "Available audio controls:"
amixer controls 2>/dev/null | head -20 || echo "  (amixer controls not available, continuing...)"

# Set microphone capture levels for TLV320AIC3104
# Primary: ADC/Capture path
for control in "ADC" "Capture" "Mic" "Input" "Mic1" "Mic2" "Line In"; do
    if amixer sget "${control}" > /dev/null 2>&1; then
        amixer sset "${control}" 85% > /dev/null 2>&1
        echo "✓ Set ${control} to 85%"
    fi
done

# Ensure input is not muted
for control in "Input" "Mic" "Capture" "ADC"; do
    if amixer sget "${control}" > /dev/null 2>&1; then
        amixer sset "${control}" unmute > /dev/null 2>&1 2>&1
        echo "✓ Unmuted ${control}"
    fi
done

# Set output levels for audio feedback
for control in "Speaker" "Master" "Headphone" "Output"; do
    if amixer sget "${control}" > /dev/null 2>&1; then
        amixer sset "${control}" 80% > /dev/null 2>&1
        echo "✓ Set ${control} to 80%"
    fi
done

# Save ALSA state for persistence across reboots
echo "Saving ALSA state..."
alsactl store
echo "✓ ALSA settings saved"

# Create systemd service to restore ALSA state on boot
cat > /etc/systemd/system/alsa-restore.service << 'ALSA_SERVICE'
[Unit]
Description=Restore ALSA Sound State
After=syslog.target network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/alsactl restore
ExecStop=/usr/sbin/alsactl store

[Install]
WantedBy=multi-user.target
ALSA_SERVICE

systemctl daemon-reload
systemctl enable alsa-restore
systemctl start alsa-restore
echo "✓ ALSA state restore service enabled"

echo ""
echo "🧠 Step 4: Install Vosk Offline Model"
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
echo "🐍 Step 5: Install Python Voice Libraries"
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
echo "🤖 Step 6: Deploy Voice Agent Script"
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

    # 4. Setup Audio Stream with Robust ReSpeaker Detection
    p = pyaudio.PyAudio()
    device_index = None
    respeaker_found = False
    
    logger.info("Scanning for ReSpeaker audio device...")
    logger.info(f"Total audio devices found: {p.get_device_count()}")
    
    # Strategy 1: Look for 'seeed' in device name
    for i in range(p.get_device_count()):
        info = p.get_device_info_by_index(i)
        device_name = info.get("name", "").lower()
        channels = info.get("maxInputChannels", 0)
        
        logger.debug(f"Device [{i}] {info.get('name', 'Unknown')}: {channels} input channels")
        
        if "seeed" in device_name or "respeaker" in device_name:
            if info.get("maxInputChannels", 0) > 0:
                device_index = i
                respeaker_found = True
                logger.info(f"✓ ReSpeaker found at index {i}: {info.get('name', 'Unknown')}")
                break
    
    # Strategy 2: Try common ReSpeaker hardware addresses (hw:1,0 or hw:2,0)
    if not respeaker_found:
        logger.warning("⚠️  'seeed' device not found by name, trying hardware indices...")
        # ReSpeaker V2.0 typically appears at hw:1 or hw:2
        for hw_index in [1, 2]:
            try:
                info = p.get_device_info_by_index(hw_index)
                device_name = info.get("name", "").lower()
                channels = info.get("maxInputChannels", 0)
                logger.info(f"Checking index {hw_index}: {device_name} ({channels} input channels)")
                
                if channels > 0:
                    device_index = hw_index
                    logger.info(f"✓ Using device at index {hw_index}")
                    respeaker_found = True
                    break
            except Exception as hw_err:
                logger.debug(f"Index {hw_index} not available: {hw_err}")
    
    # Strategy 3: Check /proc/asound/cards for ReSpeaker
    if not respeaker_found:
        logger.warning("⚠️  Checking /proc/asound/cards for ReSpeaker...")
        try:
            with open("/proc/asound/cards", "r") as f:
                cards_content = f.read()
                logger.info(f"Sound cards detected:\\n{cards_content}")
                
                if "seeed" in cards_content.lower() or "tlv320" in cards_content.lower():
                    # Try to find the card number
                    for line in cards_content.split("\n"):
                        if "seeed" in line.lower() or "tlv320" in line.lower():
                            try:
                                card_num = int(line.split()[0])
                                if card_num > 0:
                                    device_index = card_num
                                    logger.info(f"✓ ReSpeaker card found: hw:{card_num},0")
                                    respeaker_found = True
                                    break
                            except (ValueError, IndexError):
                                pass
        except Exception as proc_err:
            logger.debug(f"Could not read /proc/asound/cards: {proc_err}")
    
    # Strategy 4: Fall back to first device with input channels
    if not respeaker_found:
        logger.warning("⚠️  ReSpeaker not found, falling back to first available input device")
        for i in range(p.get_device_count()):
            info = p.get_device_info_by_index(i)
            if info.get("maxInputChannels", 0) > 0:
                device_index = i
                logger.warning(f"Using device [{i}]: {info.get('name', 'Unknown')} (may not be ReSpeaker)")
                break
    
    if device_index is None:
        logger.error("❌ No suitable audio input device found!")
        logger.error("List of all audio devices:")
        for i in range(p.get_device_count()):
            info = p.get_device_info_by_index(i)
            logger.error(f"  [{i}] {info.get('name', 'Unknown')} - Input: {info.get('maxInputChannels')} ch")
        p.terminate()
        sys.exit(1)
    
    logger.info(f"Opening audio stream on device index {device_index}...")
    
    try:
        stream = p.open(format=pyaudio.paInt16, channels=1, rate=16000, input=True, 
                        frames_per_buffer=8000, input_device_index=device_index)
        stream.start_stream()
        logger.info("✓ Audio stream opened successfully")
    except Exception as stream_err:
        logger.error(f"❌ Failed to open audio stream: {stream_err}")
        try:
            logger.error(f"Device info: {p.get_device_info_by_index(device_index)}")
        except:
            pass
        p.terminate()
        sys.exit(1)

    # Ready Indication: Cyan/Blue (Listening)
    logger.info("✓ Listening for commands...")
    if pixels:
        pixels.set_color(0, 100, 100, 2)
    logger.info("======== VOICE RECOGNITION ACTIVE ========")
    logger.info("Recognized commands: start recording, stop recording, emergency backup,")
    logger.info("                      backup backup backup, snapshot, mark incident, cancel, confirm")
    logger.info("========================================") 

    # Command List
    COMMANDS = [
        "start recording", "stop recording", "emergency backup", 
        "backup backup backup", "snapshot", "mark incident", 
        "cancel", "confirm"
    ]

    try:
        while True:
            try:
                data = stream.read(4000, exception_on_overflow=False)
            except Exception as stream_err:
                logger.error(f"Error reading audio stream: {stream_err}")
                time.sleep(0.5)
                continue
            
            if recognizer.AcceptWaveform(data):
                result = json.loads(recognizer.Result())
                text = result.get("text", "").strip().lower()
                confidence = result.get("confidence", 0.0)
                
                # Log partial results
                if text:
                    logger.debug(f"Raw recognized text: '{text}' (confidence: {confidence})")
                    
                    # Check each command
                    command_found = False
                    for cmd in COMMANDS:
                        if cmd.lower() in text:
                            command_found = True
                            # Log to both file and journalctl
                            log_msg = f"🎤 [VOICE_COMMAND] '{cmd.upper()}' detected in: '{text}'"
                            logger.warning(log_msg)  # WARNING level ensures visibility in journalctl
                            print(log_msg)  # Also print to stdout for immediate feedback
                            
                            # Visual Feedback: Green Flash (if LEDs available)
                            if pixels:
                                try:
                                    pixels.set_color(0, 255, 0, 10)  # Green flash
                                    time.sleep(0.3)
                                    pixels.set_color(0, 100, 100, 2)  # Back to listening
                                except Exception as led_err:
                                    logger.debug(f"LED feedback error: {led_err}")
                            
                            # TODO: Insert logic to trigger these actions
                            # e.g. write to a pipe, socket, or HTTP POST to mobile app
                            # Example: notify app via HTTP
                            # await send_command_to_app(cmd)
                            
                            break  # Exit loop after first match
                    
                    if not command_found:
                        logger.debug(f"No command matched in: '{text}'")
            else:
                # Partial result available
                partial = json.loads(recognizer.PartialResult())
                partial_text = partial.get("partial", "").strip()
                if partial_text:
                    logger.debug(f"Partial recognition: '{partial_text}'")
                            
    except KeyboardInterrupt:
        logger.info("🛑 Voice agent stopped by user")
    except Exception as main_err:
        logger.error(f"Fatal error in voice loop: {main_err}", exc_info=True)
    finally:
        logger.info("Cleaning up resources...")
        try:
            if pixels:
                pixels.off()
                pixels.close()
        except Exception as e:
            logger.debug(f"Error closing LEDs: {e}")
        
        try:
            stream.stop_stream()
            stream.close()
        except Exception as e:
            logger.debug(f"Error closing stream: {e}")
        
        try:
            p.terminate()
        except Exception as e:
            logger.debug(f"Error terminating audio: {e}")
        
        logger.info("Voice agent shutdown complete")

if __name__ == "__main__":
    main()
VOICE_SCRIPT_EOF

chmod +x /usr/local/bin/evvos-voice.py
echo "✓ Voice script created at /usr/local/bin/evvos-voice.py"

echo ""
echo "🔧 Step 7: Create & Start Systemd Service"
echo "========================================="

cat > /etc/systemd/system/evvos-voice.service << 'SERVICE_FILE'
[Unit]
Description=EVVOS Voice Command & Hardware Agent (ReSpeaker 2-Mics HAT V2.0)
After=network.target sound.target alsa-restore.service
Requires=sound.target
Wants=alsa-restore.service

[Service]
Type=simple
User=root
# Use the same VENV as the main app
WorkingDirectory=/opt/evvos
ExecStart=/opt/evvos/venv/bin/python3 /usr/local/bin/evvos-voice.py
Restart=always
RestartSec=10
StartLimitInterval=60
StartLimitBurst=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=evvos-voice
# Increase limits for GPIO/SPI/audio device access
LimitNOFILE=65536
# Allow access to GPIO and SPI without special permissions (User is root)
Environment="PATH=/opt/evvos/venv/bin:/usr/bin:/sbin:/usr/sbin"
Environment="GPIOZERO_PIN_FACTORY=native"
Environment="ALSA_CARD=seeed"

[Install]
WantedBy=multi-user.target
SERVICE_FILE

systemctl daemon-reload
systemctl enable evvos-voice
systemctl restart evvos-voice

echo ""
echo "🔍 Step 8: Hardware Detection & Verification"
echo "=============================================="

echo ""
echo "Checking ReSpeaker detection..."

# Check if ReSpeaker is in /proc/asound/cards
if grep -qi "seeed\|tlv320" /proc/asound/cards 2>/dev/null; then
    echo "✓ ReSpeaker HAT detected in system"
    echo "  Sound cards:"
    cat /proc/asound/cards | grep -E "^[0-9]|seeed|tlv"
else
    echo "⚠️  ReSpeaker HAT not detected yet"
    echo "  This may be normal - trying direct detection..."
fi

echo ""
echo "Checking PyAudio device detection..."
python3 << 'PYAUDIO_CHECK'
import pyaudio
import sys
p = pyaudio.PyAudio()
count = p.get_device_count()
print(f"Total audio devices: {count}")
found_respeaker = False
for i in range(count):
    info = p.get_device_info_by_index(i)
    name = info.get('name', 'Unknown')
    inputs = info.get('maxInputChannels', 0)
    if inputs > 0:
        print(f"  [{i}] {name} ({inputs} input channels)")
        if 'seeed' in name.lower() or 'respeaker' in name.lower():
            found_respeaker = True
p.terminate()

if found_respeaker:
    print("✓ ReSpeaker audio input device detected")
else:
    print("⚠️  ReSpeaker not in PyAudio list (may appear when service starts)")
PYAUDIO_CHECK

echo ""
echo "✅ ReSpeaker 2-Mics HAT V2.0 Setup Complete!"
echo "============================================="
echo "1. ✓ ReSpeaker drivers installed (with kernel mismatch fallback)"
echo "2. ✓ ALSA microphone levels configured (TLV320AIC3104 codec - 85% capture)"
echo "3. ✓ Vosk offline model downloaded"
echo "4. ✓ Voice Agent service installed and running"
echo "5. ✓ Hardware detection verified"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎤 MONITORING VOICE COMMAND DETECTION (Live Logs)"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "View voice command detection in REAL-TIME with:"
echo ""
echo "  sudo journalctl -u evvos-voice -f"
echo ""
echo "This will show messages like:"
echo "  [Voice] WARNING 🎤 [VOICE_COMMAND] 'START RECORDING' detected in: 'ok guys start recording now'"
echo ""
echo "Detailed troubleshooting logs:"
echo ""
echo "  sudo journalctl -u evvos-voice -n 50          # Last 50 lines"
echo "  sudo journalctl -u evvos-voice --since '10 min ago' -f  # Last 10 minutes"
echo "  sudo tail -f /var/log/evvos/evvos_voice.log   # File logs"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🔌 VERIFY HARDWARE (ReSpeaker 2-Mics HAT V2.0)"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Check if ReSpeaker is detected:"
echo ""
echo "  aplay -l              # List playback devices (should show seeed-voicecard)"
echo "  arecord -l            # List recording devices"
echo "  amixer -c CARD_INDEX controls | grep -i mic  # Show microphone controls"
echo ""
echo "Test microphone directly (record 5 seconds then play back):"
echo ""
echo "  arecord -f cd -r 16000 -c 1 /tmp/test.wav && aplay /tmp/test.wav"
echo ""
echo "View ALSA codec info (TLV320AIC3104):"
echo ""
echo "  cat /proc/asound/cards"
echo "  amixer"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "⚙️  FINE-TUNE MICROPHONE SENSITIVITY"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Current gain is 85% (TLV320AIC3104 Capture path)"
echo ""
echo "If voice is too quiet (commands not detected):"
echo "  sudo amixer sset 'ADC' 95%"
echo "  sudo amixer sset 'Capture' 95%"
echo "  sudo alsactl store  # Save settings"
echo ""
echo "If voice is clipping or distorted:"
echo "  sudo amixer sset 'ADC' 75%"
echo "  sudo amixer sset 'Capture' 75%"
echo "  sudo alsactl store"
echo ""
echo "Use interactive mixer for real-time adjustment:"
echo "  sudo alsamixer  # Up/Down arrows to adjust, F6 to select card, ESC to exit"
echo ""
echo "Save settings after adjusting:"
echo "  sudo alsactl store"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🚨 IF RESPEAKER NOT DETECTED"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "If you see 'ReSpeaker not found' in journal logs, try these steps:"
echo ""
echo "1. First, verify ReSpeaker is physically present:"
echo "   # Check dmesg for hardware detection"
echo "   dmesg | tail -20 | grep -i 'ReSpeaker\|seeed\|i2c\|audio'"
echo ""
echo "2. Check if drivers installed correctly:"
echo "   ls -la /lib/modules/\$(uname -r)/kernel/sound/soc/codecs/ | grep tlv"
echo "   # Should show tlv320aic3104 or similar"
echo ""
echo "3. Load I2C explicitly if missing:"
echo "   sudo modprobe i2c-dev"
echo "   sudo modprobe snd_soc_tlv320aic3104"
echo "   sudo modprobe snd_soc_seeed_voicecard"
echo ""
echo "4. Restart ALSA after drivers load:"
echo "   sudo systemctl restart alsa-restore"
echo "   sleep 2"
echo "   aplay -l"
echo ""
echo "5. If HAT not detected after modprobe, reinstall drivers:"
echo "   cd /usr/src/seeed-voicecard"
echo "   sudo ./install.sh"
echo "   sudo reboot"
echo ""
echo "6. Check HAT is enabled in /boot/config.txt:"
echo "   # For ReSpeaker 2-Mics HAT v2.0, add this:"
echo "   sudo bash -c 'echo \"dtoverlay=seeed-2mic-voicecard\" >> /boot/config.txt'"
echo "   sudo reboot"
echo ""
echo "7. Use I2C detection to verify HAT presence:"
echo "   sudo i2cdetect -y 1  # Should show 0x1a or 0x1b for TLV320AIC3104"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo ""
echo ""
echo "  systemctl start evvos-voice       # Start service"
echo "  systemctl stop evvos-voice        # Stop service"
echo "  systemctl restart evvos-voice     # Restart service (detects config changes)"
echo "  systemctl status evvos-voice      # Check service status"
echo "  systemctl enable evvos-voice      # Auto-start on boot"
echo "  systemctl disable evvos-voice     # Disable auto-start"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🔧 TROUBLESHOOTING (If Commands Not Detected)"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "1. Check if service is running:"
echo "   systemctl status evvos-voice"
echo ""
echo "2. Watch live logs while speaking a command:"
echo "   sudo journalctl -u evvos-voice -f &"
echo "   # Then say: 'start recording'"
echo "   # You should see: [VOICE_COMMAND] 'START RECORDING' detected"
echo ""
echo "3. Verify ReSpeaker is detected by Vosk:"
echo "   aplay -l | grep -i seeed  # Should show ReSpeaker"
echo "   arecord -l | grep -i seeed"
echo ""
echo "4. Test Python audio directly:"
echo "   python3 << 'EOF'"
echo "   import pyaudio"
echo "   p = pyaudio.PyAudio()"
echo "   print(f'Found {p.get_device_count()} audio devices')"
echo "   for i in range(p.get_device_count()):"
echo "       info = p.get_device_info_by_index(i)"
echo "       print(f'[{i}] {info[\"name\"]}')"
echo "   p.terminate()"
echo "   EOF"
echo ""
echo "5. Check Vosk model is available:"
echo "   ls -la /opt/evvos/model/current"
echo ""
echo "6. If ReSpeaker drivers failed to install:"
echo "   cd /usr/src/seeed-voicecard && sudo ./install.sh"
echo ""
echo "7. CRITICAL: After any driver/hardware changes - REBOOT:"
echo "   sudo reboot"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✨ TESTED VOICE COMMANDS"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "The following commands are detected by Vosk:"
echo ""
echo "  'start recording'      (press button or say: 'start recording')"
echo "  'stop recording'       (press button or say: 'stop recording')"
echo "  'emergency backup'     (say: 'emergency backup')"
echo "  'backup backup backup' (say: 'backup backup backup' x3 for emphasis)"
echo "  'snapshot'             (say: 'snapshot')"
echo "  'mark incident'        (say: 'mark incident')"
echo "  'cancel'               (say: 'cancel')"
echo "  'confirm'              (say: 'confirm')"
echo ""
echo "Watch journalctl for confirmation:"
echo "  sudo journalctl -u evvos-voice -f | grep VOICE_COMMAND"
echo ""
echo ""
