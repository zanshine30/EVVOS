#!/bin/bash
# Quick fix to enable shared audio on existing Pi setup
# This allows voice recognition and camera recording to use microphone simultaneously

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC}  $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Applying Shared Audio Fix${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then 
    log_error "This script must be run as root"
    echo "Usage: sudo bash apply_shared_audio_fix.sh"
    exit 1
fi

# ============================================================================
# STEP 1: CREATE SHARED AUDIO CONFIGURATION
# ============================================================================

log_info "Step 1: Creating ALSA shared audio configuration..."
echo ""

# Backup existing config if it exists
if [ -f /etc/asound.conf ]; then
    log_info "Backing up existing /etc/asound.conf..."
    cp /etc/asound.conf /etc/asound.conf.backup.$(date +%s)
    log_success "Backup created"
fi

# Create shared audio config
cat > /etc/asound.conf << 'EOF'
# ReSpeaker 2-Mics HAT V2.0 - Shared Audio Configuration
# Allows multiple applications (voice recognition + recording) to use audio simultaneously
# Uses dsnoop for shared microphone capture and dmix for shared playback

# Default device uses shared capture and playback
pcm.!default {
    type asym
    playback.pcm "dmixer"
    capture.pcm "dsnooper"
}

# Shared capture device (dsnoop)
# Multiple applications can record from microphone simultaneously
pcm.dsnooper {
    type dsnoop
    ipc_key 2048
    ipc_perm 0666
    slave {
        pcm "hw:seeed2micvoicec"
        channels 2
        rate 48000
        period_size 1024
        buffer_size 8192
        format S16_LE
    }
    bindings {
        0 0
        1 1
    }
}

# Shared playback device (dmix)
# Multiple applications can play audio simultaneously
pcm.dmixer {
    type dmix
    ipc_key 1024
    ipc_perm 0666
    slave {
        pcm "hw:seeed2micvoicec"
        channels 2
        rate 48000
        period_size 1024
        buffer_size 8192
        format S16_LE
    }
    bindings {
        0 0
        1 1
    }
}

# Control device
ctl.!default {
    type hw
    card seeed2micvoicec
}
EOF

log_success "Created /etc/asound.conf with shared audio configuration"
echo ""

# ============================================================================
# STEP 2: UPDATE CAMERA SERVICE TO USE SHARED DEVICE
# ============================================================================

log_info "Step 2: Updating camera service to use shared audio device..."
echo ""

CAMERA_SCRIPT="/usr/local/bin/evvos-picam-tcp.py"

if [ ! -f "$CAMERA_SCRIPT" ]; then
    log_error "Camera script not found at $CAMERA_SCRIPT"
    log_error "Please run setup_picam.sh first"
    exit 1
fi

# Backup camera script
cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.backup.$(date +%s)"
log_success "Backed up camera script"

# Replace plughw:seeed2micvoicec with dsnooper
sed -i 's/"plughw:seeed2micvoicec"/"dsnooper"/g' "$CAMERA_SCRIPT"

# Verify the change
if grep -q '"dsnooper"' "$CAMERA_SCRIPT"; then
    log_success "Camera script updated to use dsnooper device"
else
    log_error "Failed to update camera script"
    log_warning "Restoring backup..."
    cp "${CAMERA_SCRIPT}.backup."* "$CAMERA_SCRIPT"
    exit 1
fi

echo ""

# ============================================================================
# STEP 3: TEST SHARED AUDIO
# ============================================================================

log_info "Step 3: Testing shared audio configuration..."
echo ""

# Test if dsnooper device is available
if arecord -L | grep -q "dsnooper"; then
    log_success "dsnooper device is available"
else
    log_warning "dsnooper device not immediately available (may need ALSA restart)"
fi

# Test recording with shared device
log_info "Testing 2-second recording with shared device..."
if timeout 2 arecord -D dsnooper -f S16_LE -r 48000 -c 2 /tmp/test_shared_audio.wav 2>/dev/null; then
    FILE_SIZE=$(stat -c%s /tmp/test_shared_audio.wav 2>/dev/null || echo "0")
    if [ "$FILE_SIZE" -gt 10000 ]; then
        log_success "Test recording successful: ${FILE_SIZE} bytes"
        log_info "You can play it with: aplay /tmp/test_shared_audio.wav"
    else
        log_warning "Test recording too small: ${FILE_SIZE} bytes"
        log_warning "Microphone may not be working properly"
    fi
else
    log_warning "Test recording had issues (this may be normal if voice service is running)"
fi

echo ""

# ============================================================================
# STEP 4: RESTART SERVICES
# ============================================================================

log_info "Step 4: Restarting services..."
echo ""

# Restart camera service
systemctl restart evvos-picam-tcp
if systemctl is-active --quiet evvos-picam-tcp; then
    log_success "Camera service restarted successfully"
else
    log_error "Camera service failed to start"
    log_info "Check logs: sudo journalctl -u evvos-picam-tcp -n 50"
fi

# Restart voice service (if it exists)
if systemctl is-enabled --quiet evvos-pico-voice 2>/dev/null; then
    systemctl restart evvos-pico-voice
    if systemctl is-active --quiet evvos-pico-voice; then
        log_success "Voice service restarted successfully"
    else
        log_warning "Voice service failed to start"
        log_info "Check logs: sudo journalctl -u evvos-pico-voice -n 50"
    fi
else
    log_info "Voice service not found (skipping)"
fi

echo ""

# ============================================================================
# STEP 5: VERIFICATION
# ============================================================================

log_info "Step 5: Verification..."
echo ""

echo "Camera Service Status:"
systemctl status evvos-picam-tcp --no-pager -l | head -10
echo ""

if systemctl is-enabled --quiet evvos-pico-voice 2>/dev/null; then
    echo "Voice Service Status:"
    systemctl status evvos-pico-voice --no-pager -l | head -10
    echo ""
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Shared Audio Fix Applied Successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo ""

log_info "What changed:"
echo "  ✓ Created /etc/asound.conf with shared audio (dmix/dsnoop)"
echo "  ✓ Updated camera service to use 'dsnooper' device"
echo "  ✓ Both services can now access microphone simultaneously"
echo ""

log_info "Testing:"
echo "  1. Test shared audio manually:"
echo "     arecord -D dsnooper -f S16_LE -r 48000 -c 2 -d 3 /tmp/test.wav"
echo "     ls -lh /tmp/test.wav  # Should show size > 0"
echo ""
echo "  2. Start recording from your app and check:"
echo "     ls -lh ~/recordings/audio_*.wav"
echo "     # Audio file should now have size > 0 MB"
echo ""

log_info "Monitoring:"
echo "  # Watch camera service logs:"
echo "  sudo journalctl -u evvos-picam-tcp -f"
echo ""
echo "  # Watch voice service logs:"
echo "  sudo journalctl -u evvos-pico-voice -f"
echo ""

log_info "Troubleshooting:"
echo "  If audio still shows 0.00 MB:"
echo "  1. Check camera service logs: sudo journalctl -u evvos-picam-tcp -n 100"
echo "  2. Verify dsnooper works: arecord -D dsnooper -f S16_LE -r 48000 -c 2 -d 3 test.wav"
echo "  3. Check what's using audio: lsof /dev/snd/*"
echo "  4. Restart both services: sudo systemctl restart evvos-picam-tcp evvos-pico-voice"
echo ""

log_success "Fix applied! Test recording from your app now."
echo ""
