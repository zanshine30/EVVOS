#!/bin/bash
# ============================================================================
# EVVOS Provisioning — Patch P7: Fix GPIO button on Bookworm
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_provision_complete_13.sh
#
# Safe to re-run — skips itself if the patch is already applied.
#
# ─────────────────────────────────────────────────────────────────────────────
# ROOT CAUSE — two separate problems:
#
# 1. "Failed to add edge detection" on Raspberry Pi OS Bookworm
#    RPi.GPIO (the pip package) is broken on Bookworm's kernel 6.6+.
#    It cannot register edge-detection interrupts at all.
#    Fix: replace it with rpi-lgpio (the apt package), which is the
#    official successor and works correctly on Bookworm.
#
# 2. Button held → nothing happens
#    Button(17) uses pull_up=True by default in gpiozero, which is
#    correct for this HAT. However the Seeed schematic shows the button
#    pulls GPIO 17 LOW when pressed, so the default active_high=True
#    is also correct. The real issue is (1) above: the button object
#    was never successfully initialised, so when_held never fired.
#    Once (1) is fixed the button works. We also add pull_up=True
#    explicitly so it is self-documenting and matches the Seeed wiki.
#
# Steps performed:
#   a) Remove pip RPi.GPIO from the venv (conflicts with lgpio)
#   b) apt-install python3-rpi-lgpio (system-wide, Bookworm package)
#   c) In the provisioning script: Button(17, hold_time=5, pull_up=True)
#   d) In setup_evvos.sh venv pip line: drop RPi.GPIO (informational only —
#      the installed venv is patched directly)
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_info()    { echo -e "\033[0;34mℹ${NC} $1"; }
log_section() { echo -e "\n${CYAN}════════════════════════════════════════════════════${NC}\n${CYAN}▶ $1${NC}\n${CYAN}════════════════════════════════════════════════════${NC}"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Run as root: sudo bash $0"
    exit 1
fi

SCRIPT="/usr/local/bin/evvos-provisioning"
VENV="/opt/evvos/venv"

if [ ! -f "$SCRIPT" ]; then
    log_error "Provisioning script not found: $SCRIPT"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — Replace broken RPi.GPIO with working rpi-lgpio
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 1: Replace RPi.GPIO with rpi-lgpio"

log_info "Installing python3-rpi-lgpio via apt..."
apt-get install -y python3-rpi-lgpio
log_success "python3-rpi-lgpio installed"

log_info "Removing broken pip RPi.GPIO from venv (if present)..."
"$VENV/bin/pip" uninstall -y RPi.GPIO 2>/dev/null && log_success "RPi.GPIO removed from venv" || log_info "RPi.GPIO was not in venv (OK)"

log_info "Installing rpi-lgpio into venv..."
"$VENV/bin/pip" install rpi-lgpio
log_success "rpi-lgpio installed in venv"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — Patch Button(17) to add explicit pull_up=True
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 2: Patch provisioning script"

cp "$SCRIPT" "${SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-provisioning")
src = script.read_text(encoding="utf-8")

MARKER = "# FIX-P7: explicit pull_up=True matches ReSpeaker HAT wiring"

if MARKER in src:
    print("P7 already applied — nothing to do.")
    raise SystemExit(0)

old = "            self.button = Button(17, hold_time=5)\n"
new = (
    "            # FIX-P7: explicit pull_up=True matches ReSpeaker HAT wiring\n"
    "            # (GPIO 17 is pulled HIGH at rest, goes LOW when button pressed)\n"
    "            self.button = Button(17, hold_time=5, pull_up=True)\n"
)

assert old in src, (
    "P7 anchor not found: Button(17, hold_time=5) line not matched.\n"
    "Check: grep -n 'Button(17' /usr/local/bin/evvos-provisioning"
)

src = src.replace(old, new, 1)
script.write_text(src, encoding="utf-8")
print("P7 applied: Button(17, hold_time=5) → Button(17, hold_time=5, pull_up=True)")
PATCHER_EOF

log_success "Provisioning script patched"

# ─────────────────────────────────────────────────────────────────────────────
# Verification
# ─────────────────────────────────────────────────────────────────────────────
log_section "Verifying"

log_info "Checking rpi-lgpio is available in venv..."
"$VENV/bin/python3" -c "import lgpio; print('  lgpio imported OK')" \
    && log_success "lgpio importable in venv" \
    || { log_error "lgpio not importable in venv"; exit 1; }

log_info "Checking RPi.GPIO is gone from venv..."
"$VENV/bin/python3" -c "import RPi.GPIO" 2>/dev/null \
    && log_error "RPi.GPIO still present in venv — may conflict" \
    || log_success "RPi.GPIO not in venv (correct)"

python3 << 'VERIFY_EOF'
src = open('/usr/local/bin/evvos-provisioning', encoding='utf-8').read()
checks = [
    ('# FIX-P7: explicit pull_up=True matches ReSpeaker HAT wiring',
     'P7 — patch marker present'),
    ('Button(17, hold_time=5, pull_up=True)',
     'P7 — pull_up=True added to Button constructor'),
]
all_ok = True
for token, label in checks:
    ok = token in src
    print(f'  {chr(10003) if ok else chr(10007)}  {label}')
    if not ok:
        all_ok = False
import sys; sys.exit(0 if all_ok else 1)
VERIFY_EOF

# ─────────────────────────────────────────────────────────────────────────────
# Restart service
# ─────────────────────────────────────────────────────────────────────────────
log_section "Restarting evvos-provisioning service"
systemctl daemon-reload
systemctl restart evvos-provisioning
sleep 3

if systemctl is-active --quiet evvos-provisioning; then
    log_success "Service restarted and running"
else
    log_error "Service failed to restart"
    log_error "Check logs: journalctl -u evvos-provisioning -n 30"
    exit 1
fi

echo ""
echo -e "${CYAN}  Patches applied${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Step 1  RPi.GPIO (broken on Bookworm) → rpi-lgpio${NC}"
echo -e "${CYAN}  Step 2  Button(17, hold_time=5, pull_up=True)${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Expected in logs after restart:${NC}"
echo -e "${YELLOW}  INFO - ✓ Button handler initialized (GPIO 17) - Hold 5s to factory reset${NC}"
echo -e "${YELLOW}  (no more 'Failed to add edge detection' warning)${NC}"
echo ""
echo -e "${YELLOW}  Verify: journalctl -u evvos-provisioning -n 20 --no-pager${NC}"
echo ""
log_success "Done!"
