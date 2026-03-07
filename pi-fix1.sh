#!/bin/bash
# ============================================================================
# EVVOS Provisioning — Patch P6: GPIO 17 sysfs unexport on startup
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_provision_complete_12.sh
#
# Safe to re-run — skips itself if the patch is already applied.
#
# ─────────────────────────────────────────────────────────────────────────────
# P6 — FIX "Failed to add edge detection" ON SERVICE RESTART
#
#      When systemd restarts evvos-provisioning, the previous process is
#      killed mid-run. The kernel is left with GPIO 17 still exported and
#      its edge-detection file descriptor still registered. When gpiozero's
#      Button(17) tries to set up a new interrupt on the same pin it hits
#      EBUSY and falls through to the warning:
#
#        WARNING - Failed to initialize button handler: Failed to add edge detection
#        WARNING - Physical button reset feature disabled, but provisioning will continue
#
#      Fix: before calling Button(17), write "17" to
#      /sys/class/gpio/unexport (only if /sys/class/gpio/gpio17 exists).
#      This releases the fd and clears the interrupt registration so the
#      new Button() call succeeds cleanly. A 100 ms sleep lets the kernel
#      finish the release before gpiozero re-exports the pin.
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_section() { echo -e "\n${CYAN}════════════════════════════════════════════════════${NC}\n${CYAN}▶ $1${NC}\n${CYAN}════════════════════════════════════════════════════${NC}"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Run as root: sudo bash $0"
    exit 1
fi

SCRIPT="/usr/local/bin/evvos-provisioning"

if [ ! -f "$SCRIPT" ]; then
    log_error "Provisioning script not found: $SCRIPT"
    exit 1
fi

log_section "EVVOS Provisioning — Patch P6: GPIO 17 sysfs unexport on startup"

cp "$SCRIPT" "${SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

# ─────────────────────────────────────────────────────────────────────────────
# Python patcher — generates itself from the live script so the anchor is
# always exact, then applies the replacement.
# ─────────────────────────────────────────────────────────────────────────────
python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-provisioning")
src = script.read_text(encoding="utf-8")

MARKER = "# FIX-P6: force-release GPIO 17 via sysfs before gpiozero claims it."

if MARKER in src:
    print("P6 already applied — nothing to do.")
    raise SystemExit(0)

# ── locate old method ────────────────────────────────────────────────────────
m_start = src.find("    def _setup_button_handler(self) -> None:")
assert m_start != -1, "_setup_button_handler not found in provisioning script"
m_end = src.find("\n    def ", m_start + 1)
old = src[m_start:m_end]

# ── replacement ─────────────────────────────────────────────────────────────
new = (
    "    def _setup_button_handler(self) -> None:\n"
    "        \"\"\"\n"
    "        Setup ReSpeaker HAT physical button handler.\n"
    "        Button is on GPIO 17. Hold for 5 seconds to trigger factory reset.\n"
    "        \"\"\"\n"
    "        if Button is None:\n"
    "            logger.warning(\"gpiozero not available - button handler disabled\")\n"
    "            return\n"
    "        \n"
    "        # FIX-P6: force-release GPIO 17 via sysfs before gpiozero claims it.\n"
    "        # On service restart the previous process is killed mid-run, leaving\n"
    "        # the pin exported and its edge-detection fd still registered in the\n"
    "        # kernel. gpiozero then hits EBUSY / 'Failed to add edge detection'.\n"
    "        # Writing to /sys/class/gpio/unexport closes the fd and clears the\n"
    "        # interrupt registration so the new Button() call succeeds cleanly.\n"
    "        try:\n"
    "            if os.path.exists(\"/sys/class/gpio/gpio17\"):\n"
    "                with open(\"/sys/class/gpio/unexport\", \"w\") as _f:\n"
    "                    _f.write(\"17\")\n"
    "                logger.info(\"[BUTTON] GPIO 17 unexported via sysfs (was held by previous instance)\")\n"
    "            time.sleep(0.1)  # let the kernel finish releasing the pin\n"
    "        except Exception as _e:\n"
    "            logger.debug(\"[BUTTON] sysfs unexport skipped: %s\", _e)\n"
    "        \n"
    "        try:\n"
    "            # ReSpeaker 2-Mics HAT V2.0 uses GPIO 17 for the button\n"
    "            self.button = Button(17, hold_time=5)\n"
    "            self.button.when_held = self._on_button_held\n"
    "            logger.info(\"\u2713 Button handler initialized (GPIO 17) - Hold 5s to factory reset\")\n"
    "        except Exception as e:\n"
    "            logger.warning(f\"Failed to initialize button handler: {e}\")\n"
    "            logger.warning(\"Physical button reset feature disabled, but provisioning will continue\")"
)

assert old in src, (
    "P6 anchor not found — _setup_button_handler body did not match.\n"
    "Inspect manually: grep -n '_setup_button_handler' /usr/local/bin/evvos-provisioning"
)

src = src.replace(old, new, 1)
script.write_text(src, encoding="utf-8")
print("P6 applied: GPIO 17 sysfs unexport added to _setup_button_handler.")
PATCHER_EOF

log_success "Python patcher completed"

# ─────────────────────────────────────────────────────────────────────────────
# Verification
# ─────────────────────────────────────────────────────────────────────────────
log_section "Verifying patch P6"
python3 << 'VERIFY_EOF'
src = open('/usr/local/bin/evvos-provisioning', encoding='utf-8').read()
checks = [
    ('# FIX-P6: force-release GPIO 17 via sysfs before gpiozero claims it.',
     'P6 — patch marker present'),
    ('/sys/class/gpio/gpio17',
     'P6 — gpio17 existence check'),
    ('/sys/class/gpio/unexport',
     'P6 — unexport write'),
    ('time.sleep(0.1)',
     'P6 — 100ms settle delay'),
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
echo -e "${CYAN}  Patch applied${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  P6  GPIO 17 edge-detection fix:${NC}"
echo -e "${CYAN}      Before Button(17): check /sys/class/gpio/gpio17${NC}"
echo -e "${CYAN}      If exported → write '17' to unexport, sleep 100ms${NC}"
echo -e "${CYAN}      Clears stale fd left by killed previous instance${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Expected in logs after restart:${NC}"
echo -e "${YELLOW}  INFO - [BUTTON] GPIO 17 unexported via sysfs (was held by previous instance)${NC}"
echo -e "${YELLOW}  INFO - ✓ Button handler initialized (GPIO 17) - Hold 5s to factory reset${NC}"
echo -e "${YELLOW}${NC}"
echo -e "${YELLOW}  Verify: journalctl -u evvos-provisioning -n 20 --no-pager${NC}"
echo ""
log_success "Done!"
