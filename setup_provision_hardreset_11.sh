#!/bin/bash
# ============================================================================
# EVVOS Provisioning — Patch P10: Single Button, timer-based dual hold times
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_provision_complete_17.sh
#
# Safe to re-run — skips if already applied.
#
# ─────────────────────────────────────────────────────────────────────────────
# ROOT CAUSE
#   Two gpiozero Button objects cannot share the same GPIO pin. The second
#   Button(17, hold_time=20) fails with:
#     "pin GPIO17 is already in use by <gpiozero.Button ...>"
#   This leaves the hard reset handler never registered.
#
# FIX
#   Use a single Button object with when_pressed / when_released.
#   A threading.Timer fires at 5s for provisioning reset.
#   If the button is still held at 20s a second timer fires for hard reset.
#   Both actions are fully independent — holding to 20s runs both.
#
#   Timeline:
#     t=0s   pressed  → start 5s timer, start 20s timer
#     t=5s   5s timer → run provisioning reset immediately
#     t=20s  20s timer → run hard reset (if still held)
#     release before 5s  → both timers cancelled, nothing runs
#     release 5s–19s     → 20s timer cancelled, only provisioning reset ran
#     release at/after 20s → both ran
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

if [ ! -f "$SCRIPT" ]; then
    log_error "Provisioning script not found: $SCRIPT"
    exit 1
fi

log_section "EVVOS Provisioning — Patch P10: Single Button dual hold-time"

cp "$SCRIPT" "${SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-provisioning")
src = script.read_text(encoding="utf-8")

MARKER = "# FIX-P10:"
if MARKER in src:
    print("P10 already applied — nothing to do.")
    raise SystemExit(0)

# ── Step 1: add threading import ─────────────────────────────────────────────
old_imports = "import time\nimport uuid"
new_imports  = "import threading\nimport time\nimport uuid"
assert old_imports in src, "imports anchor not found"
src = src.replace(old_imports, new_imports, 1)
print("Step 1: threading import added")

# ── Step 2: replace _setup_button_handler ────────────────────────────────────
new_setup = (
    "    def _setup_button_handler(self) -> None:\n"
    "        \"\"\"\n"
    "        Setup ReSpeaker HAT physical button handler (GPIO 17).\n"
    "        Uses a single Button object with when_pressed/when_released\n"
    "        and two threading.Timers to implement dual hold times:\n"
    "          Hold  5s  → provisioning reset (always fires at 5s)\n"
    "          Hold 20s  → hard reset + reboot (fires additionally at 20s)\n"
    "        \"\"\"\n"
    "        if Button is None:\n"
    "            logger.warning(\"gpiozero not available - button handler disabled\")\n"
    "            return\n"
    "\n"
    "        # FIX-P6: force-release GPIO 17 via sysfs before gpiozero claims it.\n"
    "        try:\n"
    "            if os.path.exists(\"/sys/class/gpio/gpio17\"):\n"
    "                with open(\"/sys/class/gpio/unexport\", \"w\") as _f:\n"
    "                    _f.write(\"17\")\n"
    "                logger.info(\"[BUTTON] GPIO 17 unexported via sysfs\")\n"
    "            time.sleep(0.1)\n"
    "        except Exception as _e:\n"
    "            logger.debug(\"[BUTTON] sysfs unexport skipped: %s\", _e)\n"
    "\n"
    "        try:\n"
    "            # FIX-P10: single Button object — gpiozero does not allow two\n"
    "            # Button objects on the same pin. Dual hold times are implemented\n"
    "            # via threading.Timer in when_pressed / when_released callbacks.\n"
    "            self._btn_timer_5s  = None\n"
    "            self._btn_timer_20s = None\n"
    "\n"
    "            self.button = Button(17, pull_up=True)\n"
    "            self.button.when_pressed  = self._on_button_pressed\n"
    "            self.button.when_released = self._on_button_released\n"
    "\n"
    "            logger.info(\"\u2713 Button handler initialized (GPIO 17)\")\n"
    "            logger.info(\"  Hold  5s  \u2192 provisioning reset (always)\")\n"
    "            logger.info(\"  Hold 20s  \u2192 hard reset + reboot (additionally)\")\n"
    "        except Exception as e:\n"
    "            logger.warning(f\"Failed to initialize button handler: {e}\")\n"
    "            logger.warning(\"Physical button reset feature disabled, but provisioning will continue\")"
)

m_start = src.find("    def _setup_button_handler(self) -> None:")
assert m_start != -1, "_setup_button_handler not found"
m_end = src.find("\n    def ", m_start + 1)
src = src[:m_start] + new_setup + src[m_end:]
print("Step 2: _setup_button_handler replaced")

# ── Step 3: replace _on_button_held + _on_button_hard_reset with
#            _on_button_pressed / _on_button_released / _on_button_held /
#            _on_button_hard_reset ──────────────────────────────────────────
new_handlers = (
    "    def _on_button_pressed(self) -> None:\n"
    "        \"\"\"\n"
    "        Fired the instant the button is pressed.\n"
    "        Starts two independent timers:\n"
    "          5s  timer → provisioning reset\n"
    "          20s timer → hard reset\n"
    "        Both are cancelled if the button is released before they fire.\n"
    "        \"\"\"\n"
    "        logger.info(\"[BUTTON] Pressed — starting 5s and 20s timers\")\n"
    "\n"
    "        self._btn_timer_5s = threading.Timer(5,  self._on_button_held)\n"
    "        self._btn_timer_20s = threading.Timer(20, self._on_button_hard_reset)\n"
    "        self._btn_timer_5s.daemon  = True\n"
    "        self._btn_timer_20s.daemon = True\n"
    "        self._btn_timer_5s.start()\n"
    "        self._btn_timer_20s.start()\n"
    "\n"
    "    def _on_button_released(self) -> None:\n"
    "        \"\"\"\n"
    "        Fired when the button is released.\n"
    "        Cancels whichever timers have not yet fired.\n"
    "        \"\"\"\n"
    "        for attr in ('_btn_timer_5s', '_btn_timer_20s'):\n"
    "            t = getattr(self, attr, None)\n"
    "            if t is not None:\n"
    "                t.cancel()\n"
    "        logger.info(\"[BUTTON] Released\")\n"
    "\n"
    "    def _on_button_held(self) -> None:\n"
    "        \"\"\"\n"
    "        Fires exactly 5 seconds after the button was pressed.\n"
    "        Always runs provisioning reset immediately.\n"
    "        \"\"\"\n"
    "        logger.warning(\"=\" * 70)\n"
    "        logger.warning(\"\U0001f7e8 BUTTON HELD 5 SECONDS - INITIATING PROVISIONING RESET\")\n"
    "        logger.warning(\"=\" * 70)\n"
    "\n"
    "        reset_cmd = (\n"
    "            \"sudo rm -f /etc/evvos/device_credentials.json /tmp/evvos_ble_state.json\"\n"
    "            \" && sudo systemctl restart evvos-provisioning\"\n"
    "        )\n"
    "        logger.warning(\"[BUTTON] Running: %s\", reset_cmd)\n"
    "        try:\n"
    "            result = subprocess.run(\n"
    "                reset_cmd,\n"
    "                shell=True,\n"
    "                timeout=20,\n"
    "                capture_output=True,\n"
    "                text=True,\n"
    "            )\n"
    "            if result.returncode == 0:\n"
    "                logger.warning(\"[BUTTON] \u2713 Provisioning reset succeeded\")\n"
    "            else:\n"
    "                logger.error(\n"
    "                    \"[BUTTON] \u274c Reset command exited %s \u2014 stderr: %s\",\n"
    "                    result.returncode, result.stderr.strip()\n"
    "                )\n"
    "        except subprocess.TimeoutExpired:\n"
    "            logger.error(\"[BUTTON] \u274c Reset command timed out\")\n"
    "        except Exception as e:\n"
    "            logger.error(\"[BUTTON] \u274c Unexpected error: %s\", e)\n"
    "\n"
    "        logger.warning(\"=\" * 70)\n"
    "        logger.warning(\"[BUTTON] Provisioning reset complete\")\n"
    "        logger.warning(\"=\" * 70)\n"
    "\n"
    "    def _on_button_hard_reset(self) -> None:\n"
    "        \"\"\"\n"
    "        Fires exactly 20 seconds after the button was pressed.\n"
    "        Always runs in addition to the 5s provisioning reset.\n"
    "        Hard reset order:\n"
    "          1. Restart evvos-pico-voice\n"
    "          2. Restart evvos-picam-tcp\n"
    "          3. Clear leftover recording files (.h264 / .wav / .mp4)\n"
    "          4. Truncate EVVOS provisioning log\n"
    "          5. Delete provisioning state files\n"
    "          6. Reset WiFi fail counter\n"
    "          7. Sync filesystem + sudo reboot\n"
    "        \"\"\"\n"
    "        logger.warning(\"=\" * 70)\n"
    "        logger.warning(\"\U0001f534 BUTTON HELD 20 SECONDS - INITIATING HARD RESET\")\n"
    "        logger.warning(\"=\" * 70)\n"
    "\n"
    "        def _run(cmd, label, timeout=15):\n"
    "            logger.warning(\"[HARD RESET] %s\", label)\n"
    "            try:\n"
    "                result = subprocess.run(\n"
    "                    cmd, shell=True, timeout=timeout,\n"
    "                    capture_output=True, text=True,\n"
    "                )\n"
    "                if result.returncode == 0:\n"
    "                    logger.warning(\"[HARD RESET] \u2713 %s\", label)\n"
    "                else:\n"
    "                    logger.error(\n"
    "                        \"[HARD RESET] \u274c %s (exit %s) \u2014 %s\",\n"
    "                        label, result.returncode, result.stderr.strip()\n"
    "                    )\n"
    "            except subprocess.TimeoutExpired:\n"
    "                logger.error(\"[HARD RESET] \u274c %s timed out\", label)\n"
    "            except Exception as _e:\n"
    "                logger.error(\"[HARD RESET] \u274c %s error: %s\", label, _e)\n"
    "\n"
    "        _run(\"sudo systemctl restart evvos-pico-voice\",\n"
    "             \"Restart evvos-pico-voice (voice recognition)\")\n"
    "        _run(\"sudo systemctl restart evvos-picam-tcp\",\n"
    "             \"Restart evvos-picam-tcp (camera)\")\n"
    "        _run(\"rm -f /home/pi/recordings/*.h264 \"\n"
    "             \"/home/pi/recordings/*.wav \"\n"
    "             \"/home/pi/recordings/*.mp4\",\n"
    "             \"Clear recording files (.h264 / .wav / .mp4)\", timeout=10)\n"
    "        _run(\"truncate -s 0 /var/log/evvos/evvos_provisioning.log 2>/dev/null || true\",\n"
    "             \"Truncate provisioning log\")\n"
    "        _run(\"sudo rm -f /etc/evvos/device_credentials.json \"\n"
    "             \"/tmp/evvos_ble_state.json\",\n"
    "             \"Delete provisioning state files\")\n"
    "        _run(\"sudo rm -f /etc/evvos/.wifi_fail_count\",\n"
    "             \"Reset WiFi fail counter\")\n"
    "\n"
    "        logger.warning(\"[HARD RESET] Syncing filesystem before reboot...\")\n"
    "        try:\n"
    "            subprocess.run(\"sync\", shell=True, timeout=10)\n"
    "        except Exception:\n"
    "            pass\n"
    "\n"
    "        logger.warning(\"=\" * 70)\n"
    "        logger.warning(\"[HARD RESET] All steps complete \u2014 rebooting now\")\n"
    "        logger.warning(\"=\" * 70)\n"
    "\n"
    "        _run(\"sudo reboot\", \"Reboot\", timeout=30)"
)

# Find _on_button_held (whatever version is on disk) and replace everything
# up through the end of _on_button_hard_reset (if present) or just _on_button_held
h_start = src.find("    def _on_button_held(self) -> None:")
assert h_start != -1, "_on_button_held not found"

# Find the next method after all button handlers
h_end = src.find("\n    def ", h_start + 1)
# If _on_button_hard_reset was already inserted, skip past it too
hard_idx = src.find("    def _on_button_hard_reset(self)", h_start)
if hard_idx != -1 and hard_idx < h_end + 200:
    h_end = src.find("\n    def ", hard_idx + 1)

assert h_end != -1, "Could not find end of button handler block"
src = src[:h_start] + new_handlers + src[h_end:]
print("Step 3: button handlers replaced")

script.write_text(src, encoding="utf-8")
print("\nP10 complete. Single Button, timer-based dual hold times.")
print("  Hold  5s  → provisioning reset (always)")
print("  Hold 20s  → hard reset + reboot (additionally)")
PATCHER_EOF

log_success "Python patcher completed"

# ─────────────────────────────────────────────────────────────────────────────
# Verification
# ─────────────────────────────────────────────────────────────────────────────
log_section "Verifying patch P10"
python3 << 'VERIFY_EOF'
src = open('/usr/local/bin/evvos-provisioning', encoding='utf-8').read()
checks = [
    ('import threading',                        'P10 — threading imported'),
    ('# FIX-P10: single Button object',         'P10 — patch marker'),
    ('Button(17, pull_up=True)',                 'P10 — single Button, no hold_time'),
    ('self.button.when_pressed',                 'P10 — when_pressed wired'),
    ('self.button.when_released',                'P10 — when_released wired'),
    ('def _on_button_pressed',                   'P10 — pressed handler'),
    ('def _on_button_released',                  'P10 — released handler'),
    ('threading.Timer(5,',                       'P10 — 5s timer'),
    ('threading.Timer(20,',                      'P10 — 20s timer'),
    ('def _on_button_held',                      'P10 — held handler'),
    ('def _on_button_hard_reset',                'P10 — hard reset handler'),
    ('evvos-pico-voice',                         'P10 — voice service restart'),
    ('evvos-picam-tcp',                          'P10 — camera service restart'),
    ('sudo reboot',                              'P10 — reboot'),
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
echo -e "${CYAN}  Patch P10 applied${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Single Button(17) with threading.Timer callbacks${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  press           → start 5s + 20s timers${NC}"
echo -e "${CYAN}  release <5s     → both timers cancelled${NC}"
echo -e "${CYAN}  release 5–19s   → 5s ran (prov reset), 20s cancelled${NC}"
echo -e "${CYAN}  release ≥20s    → both ran (prov reset + hard reset)${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Expected in logs on next button press:${NC}"
echo -e "${YELLOW}  INFO    - [BUTTON] Pressed — starting 5s and 20s timers${NC}"
echo -e "${YELLOW}  WARNING - 🔘 BUTTON HELD 5 SECONDS - INITIATING PROVISIONING RESET${NC}"
echo -e "${YELLOW}  WARNING - 🔴 BUTTON HELD 20 SECONDS - INITIATING HARD RESET${NC}"
echo ""
echo -e "${YELLOW}  Verify: journalctl -u evvos-provisioning -f${NC}"
echo ""
log_success "Done!"
