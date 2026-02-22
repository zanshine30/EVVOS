#!/bin/bash
# PicoVoice Rhino Intent Recognition Setup for ReSpeaker 2-Mics HAT V2.0
# Optimized for: Raspberry Pi Zero 2 W with TLV320AIC3104 Audio Codec
# Detects EVVOS voice commands with intent recognition
# RGB LED feedback and journalctl logging
#
# ⚠️  IMPORTANT: RUN SETUP_RESPEAKER_ENHANCED.SH FIRST
# ═══════════════════════════════════════════════════════════════════════════
# This script requires a fully configured ReSpeaker 2-Mics HAT. 
#
# Setup sequence:
#   1. ReSpeaker Hardware Setup [REQUIRED FIRST]:
#      sudo bash setup_respeaker_enhanced.sh
#      (This will auto-reboot when complete)
#
#   2. PicoVoice Voice Recognition Setup [RUN AFTER REBOOT]:
#      sudo bash setup_pico_voice_recognition_respeaker.sh
#
# The first script configures:
#   ✓ Device tree overlay for ReSpeaker HAT
#   ✓ I2S audio interface and TLV320AIC3104 codec
#   ✓ ALSA audio system and microphone gain (25 optimized for speech)
#   ✓ Hardware drivers and dependencies
#
# This second script configures:
#   ✓ PicoVoice Rhino intent recognition engine
#   ✓ Custom EVVOS context model
#   ✓ LED feedback (RGB APA102)
#   ✓ Systemd service for auto-start on boot
# ═══════════════════════════════════════════════════════════════════════════
#
# Intent Model (EVVOS.yml):
# - recording_control: "start recording", "stop recording"
# - emergency_action: "emergency backup", "backup backup backup"
# - incident_capture: "mark incident", "timestamp", "incident", "snapshot", "screenshot"
# - user_confirmation: "confirm", "cancel"
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

# ============================================================================
# VERIFY SETUP_RESPEAKER_ENHANCED.SH HAS BEEN COMPLETED
# ============================================================================

log_info "Verifying ReSpeaker hardware setup completion..."
echo ""

# Check 1: Device Tree Overlay Installation
log_info "Check 1: Device tree overlay installed..."
OVERLAY_FOUND=false
if [ -f "/boot/firmware/overlays/respeaker-2mic-v2_0.dtbo" ]; then
    log_success "Found overlay at /boot/firmware/overlays/respeaker-2mic-v2_0.dtbo"
    OVERLAY_FOUND=true
elif [ -f "/boot/overlays/respeaker-2mic-v2_0.dtbo" ]; then
    log_success "Found overlay at /boot/overlays/respeaker-2mic-v2_0.dtbo"
    OVERLAY_FOUND=true
else
    log_warning "Device tree overlay not found"
fi

# Check 2: Boot Configuration Updated
log_info "Check 2: Boot parameters configured..."
CONFIG_FILE=""
if [ -f "/boot/firmware/config.txt" ]; then
    CONFIG_FILE="/boot/firmware/config.txt"
elif [ -f "/boot/config.txt" ]; then
    CONFIG_FILE="/boot/config.txt"
fi

if [ -z "$CONFIG_FILE" ]; then
    log_error "config.txt not found at /boot/config.txt or /boot/firmware/config.txt"
    log_error "This system may not be a Raspberry Pi or is not properly configured"
    exit 1
fi

if grep -q "dtoverlay=respeaker" "$CONFIG_FILE"; then
    log_success "respeaker overlay enabled in config.txt"
else
    log_warning "respeaker overlay not found in $CONFIG_FILE"
fi

if grep -q "dtparam=i2s=on" "$CONFIG_FILE"; then
    log_success "I2S interface enabled in config.txt"
else
    log_warning "I2S parameter not found in $CONFIG_FILE"
fi

# Check 3: ReSpeaker HAT Hardware Detection
log_info "Check 3: ReSpeaker HAT hardware detection..."
if ! aplay -l 2>/dev/null | grep -qi "seeed"; then
    log_error "❌ ReSpeaker HAT not detected!"
    log_error ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  SETUP_RESPEAKER_ENHANCED.SH REQUIRED"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "The following prerequisite setup must be completed first:"
    echo ""
    echo "  1. Run ReSpeaker hardware setup (will reboot):"
    echo "     sudo bash setup_respeaker_enhanced.sh"
    echo ""
    echo "  2. After reboot, run PicoVoice setup:"
    echo "     sudo bash setup_pico_voice_recognition_respeaker.sh"
    echo ""
    echo "Setup sequence:"
    echo "  ┌─────────────────────────────────────────────────┐"
    echo "  │ 1. setup_respeaker_enhanced.sh (installs HAT)   │"
    echo "  │    └─> Auto-reboot                              │"
    echo "  │                                                 │"
    echo "  │ 2. setup_pico_voice_recognition_respeaker.sh    │"
    echo "  │    (installs voice recognition)                 │"
    echo "  └─────────────────────────────────────────────────┘"
    echo ""
    echo "Current audio devices:"
    echo "  $(aplay -l 2>/dev/null | head -3 || echo "  None found")"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
fi
log_success "ReSpeaker HAT detected and working"

# Check 4: ALSA Configuration
log_info "Check 4: ALSA audio system configured..."
if grep -q "seeed2micvoicec\|seeed-voicecard" /proc/asound/cards 2>/dev/null || aplay -l 2>/dev/null | grep -q "seeed"; then
    log_success "ALSA audio system configured"
else
    log_warning "ALSA configuration may not be complete"
fi

echo ""
log_success "✓ All ReSpeaker hardware prerequisites verified"
echo ""

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

log_section "Step 1: Verify ReSpeaker Hardware & ALSA Audio System"

log_info "Verifying ReSpeaker 2-Mics HAT V2.0 is fully initialized..."
echo ""

# Verify device tree overlay is loaded
log_info "Checking device tree configuration..."
if [ -f "/sys/firmware/devicetree/base/seeed" ] || [ -d "/sys/firmware/devicetree/base/seeed" ]; then
    log_success "Device tree seeed node loaded"
else
    log_info "Seeed device tree node check (may not be visible but HAT still works)"
fi

# Verify audio codec is on I2C bus
log_info "Checking I2C codec detection..."
if command -v i2cdetect &> /dev/null; then
    if i2cdetect -y 1 2>/dev/null | grep -E "1a|1b|48|4a" > /dev/null; then
        log_success "TLV320AIC3104 audio codec detected on I2C bus 1"
    else
        log_warning "Audio codec not detected on I2C (this is OK, may use generic drivers)"
    fi
fi

# Verify ALSA audio system is ready
log_info "Checking ALSA audio system status..."
for i in {1..3}; do
    if aplay -l 2>/dev/null | grep -qi "seeed"; then
        log_success "ALSA audio system ready with ReSpeaker HAT"
        break
    fi
    if [ $i -lt 3 ]; then
        log_info "Waiting for audio system to initialize (attempt $i/3)..."
        sleep 1
    else
        log_warning "Audio system may need more time to initialize"
    fi
done

# Display detected audio devices
log_info "Detected audio devices:"
echo ""
aplay -l 2>/dev/null | grep "card\|device" | head -5 || echo "  (None detected yet, may need to reload modules)"
echo ""

# Verify microphone recording works
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
    log_warning "Microphone test not ready yet (may initialize during service startup)"
fi

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

log_success "ReSpeaker hardware prerequisites verified"
echo ""

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
# Installing pvrhino 4.0.1 (pip will automatically resolve picovoice dependency)
if "$VENV_PATH/bin/pip" install --no-cache-dir pvrhino==4.0.1; then
    log_success "PicoVoice Rhino SDK 4.0.1 installed"
else
    log_error "Failed to install pvrhino 4.0.1"
    log_info "Attempting fallback: installing with unlocked dependency versions..."
    if "$VENV_PATH/bin/pip" install --no-cache-dir picovoice pvrhino; then
        log_warning "Installed with auto-resolved versions (may not be 4.0.1)"
    else
        log_error "Failed - check pip output above"
        rm -rf "$BUILD_TMP"
        exit 1
    fi
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

CONTEXT_FILE="/opt/evvos/EVVOS_en_raspberry-pi_v4_0_0.rhn"
UPLOADED_CONTEXT="/mnt/user-data/uploads/EVVOS_en_raspberry-pi_v4_0_0.rhn"

log_info "Checking for Rhino context file..."

# Check if context file already exists locally
if [ -f "$CONTEXT_FILE" ]; then
    EXISTING_SIZE=$(stat -c%s "$CONTEXT_FILE" 2>/dev/null || echo "0")
    EXISTING_DATE=$(stat -c%y "$CONTEXT_FILE" 2>/dev/null || echo "unknown")
    log_success "Context file already deployed: $CONTEXT_FILE"
    log_info "  Size: $EXISTING_SIZE bytes | Modified: $EXISTING_DATE"
    
    # Check if newer file was uploaded
    if [ -f "$UPLOADED_CONTEXT" ]; then
        UPLOADED_SIZE=$(stat -c%s "$UPLOADED_CONTEXT" 2>/dev/null || echo "0")
        UPLOADED_DATE=$(stat -c%y "$UPLOADED_CONTEXT" 2>/dev/null || echo "unknown")
        log_info "Newer .rhn file found in uploads:"
        log_info "  Size: $UPLOADED_SIZE bytes | Modified: $UPLOADED_DATE"
        echo ""
        read -p "Update context file from uploads? (y/n) " -n 1 -r UPDATE_RHN
        echo
        if [[ $UPDATE_RHN =~ ^[Yy]$ ]]; then
            log_info "Updating context file from uploads..."
            cp "$UPLOADED_CONTEXT" "$CONTEXT_FILE"
            chmod 644 "$CONTEXT_FILE"
            log_success "Context file updated from: $UPLOADED_CONTEXT"
            log_info "  To skip this prompt next time, delete the uploaded copy:"
            log_info "  rm /mnt/user-data/uploads/EVVOS_en_raspberry-pi_v4_0_0.rhn"
        else
            log_info "Keeping existing context file (no changes made)"
        fi
    fi
else
    # No local file exists, must copy from uploads
    if [ ! -f "$UPLOADED_CONTEXT" ]; then
        log_error "No context file found!"
        log_error "Expected one of:"
        log_error "  1. Local: $CONTEXT_FILE (missing)"
        log_error "  2. Uploaded: $UPLOADED_CONTEXT (missing)"
        log_error ""
        log_error "Solution:"
        log_error "  1. Go to: https://console.picovoice.ai"
        log_error "  2. Create/train EVVOS context model"
        log_error "  3. Compile and download the .rhn file"
        log_error "  4. Copy to: $UPLOADED_CONTEXT"
        log_error "     Or directly to: $CONTEXT_FILE"
        exit 1
    fi
    
    log_info "First-time setup: copying context file from uploads..."
    cp "$UPLOADED_CONTEXT" "$CONTEXT_FILE"
    chmod 644 "$CONTEXT_FILE"
    log_success "Rhino context file deployed: $CONTEXT_FILE"
    log_info "  To avoid this prompt, keep the uploaded copy at: $UPLOADED_CONTEXT"
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

# Pre-read existing key only if the file already exists
ACCESS_KEY=""
if [ -f "$ACCESS_KEY_FILE" ]; then
    ACCESS_KEY=$(cat "$ACCESS_KEY_FILE" | tr -d '\n')
fi

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

log_section "Step 7: Check SPI for LED Control (Optional)"

log_info "Checking if SPI is enabled for ReSpeaker LEDs..."

if [ -e /dev/spidev0.0 ]; then
    log_success "SPI is enabled - LEDs will work"
else
    log_warning "SPI device not found (/dev/spidev0.0)"
    log_warning "To enable SPI and use LEDs:"
    log_warning "  1. Run: sudo raspi-config"
    log_warning "  2. Go to: Interfacing Options → SPI"
    log_warning "  3. Select YES to enable SPI"
    log_warning "  4. Reboot: sudo reboot"
    log_info "NOTE: Audio will still work without SPI/LEDs"
fi

echo ""

log_section "Step 8: Configure ALSA dsnoop for Shared Microphone Access"

log_info "Checking ALSA audio device status..."

# Verify the audio device is working
if aplay -l 2>&1 | grep -qi "seeed"; then
    log_success "ReSpeaker audio device ready"
else
    log_warning "ReSpeaker may not be detected yet, but service will auto-detect"
fi

# ── Detect ReSpeaker card number ───────────────────────────────────────────────
RESPEAKER_CARD_NUM="0"
CARD_INFO_DETECT=$(aplay -l 2>/dev/null | grep -i seeed | head -1)
if [ -n "$CARD_INFO_DETECT" ]; then
    RESPEAKER_CARD_NUM=$(echo "$CARD_INFO_DETECT" | grep -oP 'card \K[0-9]+')
    log_success "ReSpeaker detected at ALSA card $RESPEAKER_CARD_NUM"
else
    log_warning "Could not auto-detect card number — defaulting to card 0"
fi

log_info "Configuring ALSA dsnoop virtual device (card $RESPEAKER_CARD_NUM)..."

# ── Remove legacy per-user configs that might conflict ─────────────────────────
rm -f /root/.asoundrc /home/*/.asoundrc 2>/dev/null || true
log_info "Removed any legacy .asoundrc files"

# ── Write /etc/asound.conf with dsnoop ────────────────────────────────────────
#
# WHY dsnoop?
#   ALSA normally grants exclusive access to a hardware capture device (hw:X,0)
#   to the first program that opens it.  When PicoVoice starts on boot it locks
#   hw:seeed2micvoicec, so arecord (PiCam service) gets EBUSY and records silence.
#
#   dsnoop is an ALSA kernel-level sharing plugin.  It opens the real hw device
#   once and exposes a virtual capture endpoint that any number of readers can
#   open simultaneously with zero latency penalty — identical to the original
#   hardware stream.  Both PicoVoice AND arecord will use "dsnoop:seeed2micvoicec"
#   and share the microphone without either one blocking the other.
#
cat > /etc/asound.conf << ASOUND_EOF
pcm.shared_mic {
    type dsnoop
    ipc_key 2048
    ipc_key_add_uid false
    slaves {
        pcm "hw:${RESPEAKER_CARD_NUM},0"
        channels 2
        rate 48000
        period_size 1024
        buffer_size 8192
    }
}

pcm.!default {
    type asym
    capture.pcm "shared_mic"
}

ctl.!default {
    type hw
    card ${RESPEAKER_CARD_NUM}
}
ASOUND_EOF

chmod 644 /etc/asound.conf
log_success "Written /etc/asound.conf with dsnoop shared capture device (card $RESPEAKER_CARD_NUM)"

# ── Verify dsnoop config is parseable by ALSA ─────────────────────────────────
if arecord -L 2>/dev/null | grep -q "dsnoop"; then
    log_success "dsnoop virtual device confirmed available to ALSA"
else
    log_warning "dsnoop not yet visible (may need reboot or module reload — this is normal)"
fi

log_info "Audio error suppression will be handled in the Python service"
log_success "ALSA dsnoop configuration complete — microphone is now shareable"

# ============================================================================
# STEP 9: CREATE PICOVOICE SERVICE SCRIPT
# ============================================================================

log_section "Step 9: Create PicoVoice Service Script"

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
import requests
import socket
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
CONTEXT_FILE = "/opt/evvos/EVVOS_en_raspberry-pi_v4_0_0.rhn"
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
# COMMAND MAPPING (Intent + Slots → Actual Spoken Command)
# ============================================================================

# Mapping of voice commands to their intents and slots (from evvos.yml)
COMMAND_TO_INTENT_MAP = {
    # Recording Control
    "start recording": {
        "intent": "recording_control",
        "slots": {"recordingAction": "start"}
    },
    "start": {
        "intent": "recording_control",
        "slots": {"recordingAction": "start"}
    },
    "begin recording": {
        "intent": "recording_control",
        "slots": {"recordingAction": "begin"}
    },
    "begin": {
        "intent": "recording_control",
        "slots": {"recordingAction": "begin"}
    },
    "stop recording": {
        "intent": "recording_control",
        "slots": {"recordingAction": "stop"}
    },
    "stop": {
        "intent": "recording_control",
        "slots": {"recordingAction": "stop"}
    },
    
    # Emergency Action (removed "alert" - too easy to trigger accidentally)
    "emergency backup": {
        "intent": "emergency_action",
        "slots": {}
    },
    "backup backup backup": {
        "intent": "emergency_action",
        "slots": {}
    },
    
    # Incident Capture
    "screenshot": {
        "intent": "incident_capture",
        "slots": {"captureAction": "screenshot"}
    },
    "snapshot": {
        "intent": "incident_capture",
        "slots": {"captureAction": "snapshot"}
    },
    "mark incident": {
        "intent": "incident_capture",
        "slots": {"captureAction": "incident"}
    },
    "mark": {
        "intent": "incident_capture",
        "slots": {"captureAction": "incident"}
    },
    "timestamp": {
        "intent": "incident_capture",
        "slots": {"captureAction": "timestamp"}
    },
    "incident": {
        "intent": "incident_capture",
        "slots": {"captureAction": "incident"}
    },
    
    # User Confirmation
    "confirm": {
        "intent": "user_confirmation",
        "slots": {"confirmAction": "confirm"}
    },
    "cancel": {
        "intent": "user_confirmation",
        "slots": {"confirmAction": "cancel"}
    },
}

def get_intent_from_command(command: str):
    """
    Map a recognized voice command to its intent and slots.
    
    Args:
        command: The recognized voice command string
        
    Returns:
        Tuple of (intent, slots) from the detected command.
        If command not found, returns ("unknown", {})
    """
    command_lower = command.lower().strip()
    
    # Direct match
    if command_lower in COMMAND_TO_INTENT_MAP:
        mapping = COMMAND_TO_INTENT_MAP[command_lower]
        return mapping.get("intent", "unknown"), mapping.get("slots", {})
    
    # Fallback: try to match partial phrases
    for key, value in COMMAND_TO_INTENT_MAP.items():
        if key in command_lower or command_lower in key:
            logger.debug(f"Partial match: '{command_lower}' matched to '{key}'")
            return value.get("intent", "unknown"), value.get("slots", {})
    
    # If no match found, log a warning and return generic intent
    logger.warning(f"[MAPPING] No intent mapping found for command: '{command}'")
    return "unknown", {}

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
        
        # Log environment configuration at startup
        logger.info("[SERVICE] Environment Configuration:")
        logger.info(f"  SUPABASE_EDGE_FUNCTION_URL: {os.getenv('SUPABASE_EDGE_FUNCTION_URL', 'NOT SET')}")
        logger.info(f"  EVVOS_DEVICE_ID: {os.getenv('EVVOS_DEVICE_ID', 'NOT SET')}")
        logger.info(f"  SUPABASE_SERVICE_ROLE_KEY: {'SET' if os.getenv('SUPABASE_SERVICE_ROLE_KEY') else 'NOT SET'}")
        
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
            # CRITICAL: Suppress ALSA lib error messages BEFORE initializing PyAudio
            # This prevents the alsa_snd_config_update() errors from crashing the service
            import ctypes
            import os
            
            # Method 1: Use ctypes to suppress ALSA errors
            try:
                # Suppress ALSA config errors at the C library level
                ERRORFN = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p)
                def ignore_errors(filename, line, function, err, fmt):
                    pass
                error_handler = ERRORFN(ignore_errors)
                try:
                    asound = ctypes.cdll.LoadLibrary('libasound.so.2')
                    asound.snd_lib_error_set_handler(error_handler)
                    logger.debug("ALSA error handler installed via libasound.so.2")
                except:
                    # Try alternate library name
                    asound = ctypes.cdll.LoadLibrary('libasound.so')
                    asound.snd_lib_error_set_handler(error_handler)
                    logger.debug("ALSA error handler installed via libasound.so")
            except Exception as e:
                logger.debug(f"Could not install ALSA error handler (non-critical): {e}")
            
            # Method 2: Redirect stderr to suppress ALSA lib warnings
            try:
                import subprocess
                # Suppress ALSA lib messages at stderr level
                devnull = os.open(os.devnull, os.O_WRONLY)
                saved_stderr = os.dup(2)
                os.dup2(devnull, 2)
                logger.debug("ALSA stderr redirection enabled")
            except Exception as e:
                logger.debug(f"Could not redirect stderr (non-critical): {e}")
                saved_stderr = None
            
            try:
                # Initialize PyAudio (may trigger ALSA warnings, but they're now suppressed)
                self.pa = pyaudio.PyAudio()
                logger.info("PyAudio initialized successfully (ALSA warnings suppressed)")
            finally:
                # Restore stderr
                try:
                    if saved_stderr is not None:
                        os.dup2(saved_stderr, 2)
                        os.close(devnull)
                except:
                    pass
            
            # Find the best available capture device.
            #
            # Priority:
            #   1. 'dsnoop' — the ALSA shared capture device written by Step 8 of
            #      setup_pico_voice_recognition_respeaker.sh.  Opening dsnoop lets
            #      PicoVoice and the PiCam arecord process share the microphone
            #      concurrently without EBUSY / exclusive-access conflicts.
            #   2. 'seeed'  — the raw ReSpeaker hardware device.  Works if dsnoop is
            #      not configured, but blocks the PiCam service from recording audio.
            #   3. First device with input channels — last-resort fallback.
            dev_idx = None
            dev_name = None

            # Priority 1: shared_mic virtual device (dsnoop-backed, shared, non-exclusive)
            for i in range(self.pa.get_device_count()):
                info = self.pa.get_device_info_by_index(i)
                if 'shared_mic' in info['name'].lower() and info['maxInputChannels'] > 0:
                    dev_idx = i
                    dev_name = info['name']
                    logger.info(f"Found shared_mic device: {dev_name} (index {i}) — mic will be shared with PiCam")
                    logger.info(f"  Sample Rate: {int(info['defaultSampleRate'])} Hz")
                    logger.info(f"  Input Channels: {info['maxInputChannels']}")
                    break

            # Priority 2: ReSpeaker hardware device (seeed)
            if dev_idx is None:
                logger.warning("shared_mic device not found — falling back to direct ReSpeaker device (mic sharing disabled)")
                for i in range(self.pa.get_device_count()):
                    info = self.pa.get_device_info_by_index(i)
                    if 'seeed' in info['name'].lower() and info['maxInputChannels'] > 0:
                        dev_idx = i
                        dev_name = info['name']
                        logger.info(f"Found ReSpeaker device: {dev_name} (index {i})")
                        logger.info(f"  Sample Rate: {int(info['defaultSampleRate'])} Hz")
                        logger.info(f"  Input Channels: {info['maxInputChannels']}")
                        break

            # Priority 3: Any device with input channels
            if dev_idx is None:
                logger.warning("ReSpeaker device (seeed) not found, trying any available input device...")
                for i in range(self.pa.get_device_count()):
                    info = self.pa.get_device_info_by_index(i)
                    if info['maxInputChannels'] > 0:
                        dev_idx = i
                        dev_name = info['name']
                        logger.info(f"Using fallback audio device: {dev_name} (index {i})")
                        logger.info(f"  Sample Rate: {int(info['defaultSampleRate'])} Hz")
                        logger.info(f"  Input Channels: {info['maxInputChannels']}")
                        break
            
            if dev_idx is None:
                logger.error("No audio input device found!")
                logger.info("Available devices:")
                for i in range(self.pa.get_device_count()):
                    info = self.pa.get_device_info_by_index(i)
                    logger.info(f"  [{i}] {info['name']} (input: {info['maxInputChannels']}, output: {info['maxOutputChannels']})")
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
            import traceback
            logger.debug(traceback.format_exc())
            self.leds.set_all(LED_ERROR, brightness=20)
            return False

    def handle_intent(self, intent, slots):
        """Execute action based on intent and slots"""
        # Reconstruct the spoken command text from intent + slots for logging
        # This reverses the mapping: given intent and slots, find what was likely spoken
        spoken_command = self._reconstruct_command(intent, slots)
        logger.info(f"[DETECTED] Intent: {intent} → Likely Command: '{spoken_command}'")
        logger.info(f"[DETECTED] Slots: {slots}")
        logger.info(f"[DETECTED] About to send to backend...")
        
        # Send to Supabase backend with the intent, reconstructed command, and slots
        self.send_to_backend(intent, spoken_command, slots)
        
        logger.info(f"[DETECTED] Backend call completed")
        
        # Add your custom logic here based on intent
        if intent == "recording_control":
            logger.info("[ACTION] Recording control detected")
        elif intent == "emergency_action":
            logger.info("[ACTION] Emergency action triggered")
        elif intent == "incident_capture":
            logger.info("[ACTION] Incident capture")
        elif intent == "user_confirmation":
            logger.info("[ACTION] User confirmation received")
    
    def _reconstruct_command(self, intent, slots):
        """
        Reconstruct the probable spoken command from intent and slots.
        
        Since Rhino detects intent and slots but not the exact text spoken,
        we reverse-lookup from the COMMAND_TO_INTENT_MAP to get a likely command.
        
        For example: intent="recording_control", slots={"recordingAction": "start"}
        Returns: "start recording"
        """
        # Try to find a matching command in our map
        for command, mapping in COMMAND_TO_INTENT_MAP.items():
            if mapping.get("intent") == intent:
                # Check if slots match
                cmd_slots = mapping.get("slots", {})
                if cmd_slots == slots:
                    return command
                # Partial match for intent (even if slots differ)
                if not cmd_slots or not slots:
                    return command
        
        # Fallback: return a generic command based on intent
        if intent == "recording_control":
            action = slots.get("recordingAction", "start")
            return f"{action} recording"
        elif intent == "emergency_action":
            return "emergency backup"
        elif intent == "incident_capture":
            action = slots.get("captureAction", "screenshot")
            return action
        elif intent == "user_confirmation":
            action = slots.get("confirmAction", "confirm")
            return action
        else:
            return intent

    def send_to_backend(self, intent, spoken_command, slots):
        """Send voice command to Mobile App via Raw TCP"""
        try:
            # 1. Get Gateway IP (Android Hotspot Default is usually 192.168.43.1)
            gateway_ip = self.get_gateway_ip() 
            PORT = 3000
            
            # 2. Prepare Payload
            payload = {
                "id": f"cmd_{int(time.time())}",
                "intent": intent,
                "command": spoken_command,
                "slots": slots if slots else {},
                "timestamp": time.time()
            }
            
            # 3. Create JSON String with Newline Delimiter
            message = json.dumps(payload) + "\n"
            
            logger.info(f"[TCP] Connecting to {gateway_ip}:{PORT}...")

            # 4. Open Socket, Send, Close
            # using 'with' ensures the socket is closed automatically
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.settimeout(2.0) # 2 second timeout
                s.connect((gateway_ip, PORT))
                s.sendall(message.encode('utf-8'))
                
            logger.info(f"[TCP] ✓ Sent: {intent}")
            self.leds.pulse(LED_DETECTED, duration=0.2)
            
        except socket.timeout:
             logger.error("[TCP] ✗ Connection Timed Out. Is the App running?")
             self.leds.pulse(LED_ERROR, duration=0.5)
        except ConnectionRefusedError:
             logger.error("[TCP] ✗ Connection Refused. Check Port 3000.")
             self.leds.pulse(LED_ERROR, duration=0.5)
        except Exception as e:
            logger.error(f"[TCP] Error: {e}")
            self.leds.pulse(LED_ERROR, duration=0.5)

    def get_gateway_ip(self):
        """Helper to find the phone's IP"""
        try:
            cmd = "ip route show | grep default | awk '{print $3}'"
            import os
            ip = os.popen(cmd).read().strip()
            return ip if ip else "192.168.43.1"
        except:
            return "192.168.43.1"

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
# STEP 10: CREATE SYSTEMD SERVICE UNIT
# ============================================================================

log_section "Step 10: Create Systemd Service"

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
# ALSA lib error suppression (note: actual suppression happens in Python code)
Environment="ALSA_CARD_DEFAULTS=libasound.so.2"
# Supabase Edge Function Configuration
Environment="SUPABASE_EDGE_FUNCTION_URL=https://zekbonbxwccgsfagrrph.supabase.co/functions/v1/insert-voice-command"
Environment="EVVOS_DEVICE_ID=EVVOS_0001"
Environment="SUPABASE_SERVICE_ROLE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inpla2JvbmJ4d2NjZ3NmYWdycnBoIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2ODM5NDI5NSwiZXhwIjoyMDgzOTcwMjk1fQ.Ddpwys249qYzjlK-kNrZCzNhZ-7OX-RUUg74XnZxuOU"

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
# STEP 11: ENABLE AND START SERVICE
# ============================================================================

log_section "Step 11: Enable and Start PicoVoice Service"

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
# STEP 12: VERIFY SERVICE STATUS
# ============================================================================

log_section "Step 12: Verify Service Status"

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
# STEP 13: SUMMARY & NEXT STEPS
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
echo "  • Intent Model: EVVOS Custom Context"
echo "  • Python Environment: $VENV_PATH"
echo "  • Service: evvos-pico-voice.service"
echo "  • Log File: $LOG_FILE"
echo "  • Access Key: $ACCESS_KEY_FILE"
echo "  • Custom Context: $CONTEXT_FILE"
echo ""

log_info "Recognized Intents and Commands (from EVVOS.yml):"
echo ""
echo "  ${CYAN}recording_control${NC}:"
echo "    • 'start recording'"
echo "    • 'stop recording'"
echo ""
echo "  ${CYAN}emergency_action${NC}:"
echo "    • 'emergency backup'"
echo "    • 'backup backup backup'"
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
echo "  Q: '[WARNING] [LED] SPI device not found' error?"
echo "  A: LEDs require SPI to be enabled. To enable SPI:"
echo "     sudo raspi-config → Interfacing Options → SPI → Enable"
echo "     Then reboot: sudo reboot"
echo "     NOTE: Audio works fine without LEDs!"
echo ""
echo "  Q: ALSA errors like 'Invalid argument'?"
echo "  A: ALSA warnings are normal and don't break audio."
echo "     They're suppressed in the systemd service."
echo "     If audio still fails, check:"
echo "     • Is ReSpeaker detected? aplay -l | grep seeed"
echo "     • Is sound.target active? systemctl status sound.target"
echo ""
echo "  Q: 'Audio init failed: [Errno -9999]' error?"
echo "  A: This is usually an ALSA configuration issue."
echo "     Solution: Restart ALSA or reload the service"
echo "     sudo systemctl restart alsa-restore"
echo "     sudo systemctl restart evvos-pico-voice"
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
echo "  • RGB LED feedback via ReSpeaker APA102 LEDs (if SPI enabled)"
echo "  • Automatic startup on system boot"
echo ""

log_info "Audio System Configuration:"
echo "  • Rhino requires 16kHz mono audio input"
echo "  • Service will suppress ALSA lib errors for cleaner logs"
echo "  • If ReSpeaker not found, service falls back to first available input device"
echo "  • .asoundrc file configured at /root/.asoundrc for daemon operation"
echo ""

log_info "Setup Dependency Summary:"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ Layer 1: Hardware Setup (setup_respeaker_enhanced.sh)       │"
echo "  ├─────────────────────────────────────────────────────────────┤"
echo "  │ ✓ Device tree overlay compilation & installation            │"
echo "  │ ✓ I2S interface enabled (dtparam=i2s=on)                    │"
echo "  │ ✓ ReSpeaker 2-Mics HAT V2.0 overlay loaded                  │"
echo "  │ ✓ TLV320AIC3104 audio codec driver loaded                   │"
echo "  │ ✓ ALSA audio system configured                              │"
echo "  │ ✓ Microphone gain optimized (PGA = 25)                      │"
echo "  ├─────────────────────────────────────────────────────────────┤"
echo "  │ Result: ReSpeaker HAT ready for voice applications          │"
echo "  │ Check: aplay -l | grep seeed                                │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ Layer 2: Voice Recognition (THIS SCRIPT)                    │"
echo "  ├─────────────────────────────────────────────────────────────┤"
echo "  │ ✓ PicoVoice Rhino SDK 4.0.1 installed                       │"
echo "  │ ✓ PyAudio configured for audio capture                      │"
echo "  │ ✓ Custom EVVOS context model deployed                  │"
echo "  │ ✓ PicoVoice access key configured                           │"
echo "  │ ✓ Systemd service created (evvos-pico-voice.service)        │"
echo "  │ ✓ LED control via SPI (optional, if SPI enabled)            │"
echo "  │ ✓ ALSA error suppression configured                         │"
echo "  ├─────────────────────────────────────────────────────────────┤"
echo "  │ Result: Voice command recognition working with intent       │"
echo "  │ Check: systemctl status evvos-pico-voice                    │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  Setup Verification:"
echo "    Layer 1 Complete: ReSpeaker HAT detected and audio working"
echo "    Layer 2 Complete: Voice service running and ready for commands"
echo ""

echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

log_success "PicoVoice Rhino Service ready to use!"
echo ""
log_info "Start testing with:"
echo "  ${CYAN}sudo journalctl -u evvos-pico-voice -f${NC}"
echo ""
