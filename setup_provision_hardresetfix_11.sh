#!/bin/bash
# ============================================================================
# EVVOS Provisioning — Patch P11: Release-based hold time detection
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_provision_complete_18.sh
#
# Safe to re-run — skips if already applied.
#
# ─────────────────────────────────────────────────────────────────────────────
# BEHAVIOUR (action decided on release):
#   Release before 5s   → nothing
#   Release at 5–19s    → provisioning reset only
#   Release at 20s+     → provisioning reset THEN hard reset + reboot
#
# HOW IT WORKS
#   when_pressed  → record press timestamp (time.monotonic)
#   when_released → calculate hold duration, run action in daemon thread
#   Single Button object — no gpiozero pin conflict
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

log_section "EVVOS Provisioning — Patch P11: Release-based hold detection"

cp "$SCRIPT" "${SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-provisioning")
src = script.read_text(encoding="utf-8")

MARKER = "# FIX-P11:"
if MARKER in src:
    print("P11 already applied — nothing to do.")
    raise SystemExit(0)

# ── Step 1: ensure threading is imported ─────────────────────────────────────
if "import threading" not in src:
    src = src.replace(
        "import time\nimport uuid",
        "import threading\nimport time\nimport uuid",
        1
    )
    print("Step 1: threading import added")
else:
    print("Step 1: threading already imported")

# ── Step 2: replace _setup_button_handler ────────────────────────────────────
new_setup = (
    "    def _setup_button_handler(self) -> None:\n"
    "        \"\"\"\n"
    "        Setup ReSpeaker HAT physical button handler (GPIO 17).\n"
    "        Action is decided on RELEASE based on how long the button was held:\n"
    "          Release before 5s   → nothing\n"
    "          Release at 5s-19s   → provisioning reset\n"
    "          Release at 20s+     → provisioning reset + hard reset + reboot\n"
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
    "            # FIX-P11: single Button object, action decided on release.\n"
    "            self._press_time = None\n"
    "\n"
    "            self.button = Button(17, pull_up=True)\n"
    "            self.button.when_pressed  = self._on_button_pressed\n"
    "            self.button.when_released = self._on_button_released\n"
    "\n"
    "            logger.info(\"\u2713 Button handler initialized (GPIO 17)\")\n"
    "            logger.info(\"  Release at  5-19s \u2192 provisioning reset\")\n"
    "            logger.info(\"  Release at   20s+ \u2192 provisioning reset + hard reset\")\n"
    "        except Exception as e:\n"
    "            logger.warning(f\"Failed to initialize button handler: {e}\")\n"
    "            logger.warning(\"Physical button reset feature disabled, but provisioning will continue\")"
)

m_start = src.find("    def _setup_button_handler(self) -> None:")
assert m_start != -1, "_setup_button_handler not found"
m_end = src.find("\n    def ", m_start + 1)
src = src[:m_start] + new_setup + src[m_end:]
print("Step 2: _setup_button_handler replaced")

# ── Step 3: replace all button handlers ──────────────────────────────────────
new_handlers = (
    "    def _on_button_pressed(self) -> None:\n"
    "        \"\"\"Record the moment the button was pressed.\"\"\"\n"
    "        self._press_time = time.monotonic()\n"
    "        logger.info(\"[BUTTON] Pressed — hold then release: 5s=prov reset, 20s=+hard reset\")\n"
    "\n"
    "    def _on_button_released(self) -> None:\n"
    "        \"\"\"\n"
    "        Calculate hold duration on release and dispatch the right action\n"
    "        in a daemon thread so gpiozero's event loop is not blocked.\n"
    "          < 5s  → nothing\n"
    "          5-19s → provisioning reset\n"
    "          20s+  → provisioning reset + hard reset + reboot\n"
    "        \"\"\"\n"
    "        if self._press_time is None:\n"
    "            return\n"
    "        held = time.monotonic() - self._press_time\n"
    "        self._press_time = None\n"
    "        logger.info(\"[BUTTON] Released after %.1fs\", held)\n"
    "\n"
    "        if held >= 20:\n"
    "            threading.Thread(\n"
    "                target=self._run_provisioning_then_hard_reset,\n"
    "                daemon=True\n"
    "            ).start()\n"
    "        elif held >= 5:\n"
    "            threading.Thread(\n"
    "                target=self._on_button_held,\n"
    "                daemon=True\n"
    "            ).start()\n"
    "        else:\n"
    "            logger.info(\"[BUTTON] Held %.1fs — too short, ignoring\", held)\n"
    "\n"
    "    def _do_provisioning_reset(self) -> None:\n"
    "        \"\"\"Run the provisioning reset command. Called by both hold handlers.\"\"\"\n"
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
    "    def _on_button_held(self) -> None:\n"
    "        \"\"\"\n"
    "        Provisioning reset — released after 5-19s.\n"
    "        \"\"\"\n"
    "        logger.warning(\"=\" * 70)\n"
    "        logger.warning(\"\U0001f7e8 BUTTON RELEASED AFTER 5s - INITIATING PROVISIONING RESET\")\n"
    "        logger.warning(\"=\" * 70)\n"
    "        self._do_provisioning_reset()\n"
    "        logger.warning(\"=\" * 70)\n"
    "        logger.warning(\"[BUTTON] Provisioning reset complete\")\n"
    "        logger.warning(\"=\" * 70)\n"
    "\n"
    "    def _run_provisioning_then_hard_reset(self) -> None:\n"
    "        \"\"\"\n"
    "        Released after 20s+ — run provisioning reset first, then hard reset.\n"
    "        \"\"\"\n"
    "        logger.warning(\"=\" * 70)\n"
    "        logger.warning(\"\U0001f534 BUTTON RELEASED AFTER 20s - PROVISIONING RESET + HARD RESET\")\n"
    "        logger.warning(\"=\" * 70)\n"
    "\n"
    "        logger.warning(\"[BUTTON] Step 1/2: Provisioning reset...\")\n"
    "        self._do_provisioning_reset()\n"
    "\n"
    "        logger.warning(\"[BUTTON] Step 2/2: Hard reset...\")\n"
    "        self._on_button_hard_reset()\n"
    "\n"
    "    def _on_button_hard_reset(self) -> None:\n"
    "        \"\"\"\n"
    "        Hard reset steps:\n"
    "          1. Restart evvos-pico-voice\n"
    "          2. Restart evvos-picam-tcp\n"
    "          3. Clear recording files (.h264 / .wav / .mp4)\n"
    "          4. Truncate provisioning log\n"
    "          5. Delete provisioning state files\n"
    "          6. Reset WiFi fail counter\n"
    "          7. Sync + reboot\n"
    "        \"\"\"\n"
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

# Find the start of the first button handler (any version previously patched)
h_start = None
for candidate in (
    "    def _on_button_pressed(self) -> None:",
    "    def _on_button_held(self) -> None:",
):
    idx = src.find(candidate)
    if idx != -1:
        h_start = idx
        break
assert h_start is not None, "no button handler found to replace"

# Walk forward past all consecutive button-related methods
BUTTON_METHODS = (
    "_on_button_pressed",
    "_on_button_released",
    "_on_button_held",
    "_on_button_hard_reset",
    "_run_provisioning_then_hard_reset",
    "_do_provisioning_reset",
)
h_end = src.find("\n    def ", h_start + 1)
while h_end != -1:
    snippet = src[h_end + 1: h_end + 80]
    if any(name in snippet for name in BUTTON_METHODS):
        h_end = src.find("\n    def ", h_end + 1)
    else:
        break
assert h_end != -1, "could not find end of button handler block"

src = src[:h_start] + new_handlers + src[h_end:]
print("Step 3: all button handlers replaced")

script.write_text(src, encoding="utf-8")
print("\nP11 complete.")
print("  Release at  5-19s → provisioning reset")
print("  Release at   20s+ → provisioning reset + hard reset + reboot")
PATCHER_EOF

log_success "Python patcher completed"

# ─────────────────────────────────────────────────────────────────────────────
# Verification
# ─────────────────────────────────────────────────────────────────────────────
log_section "Verifying patch P11"
python3 << 'VERIFY_EOF'
src = open('/usr/local/bin/evvos-provisioning', encoding='utf-8').read()
checks = [
    ('# FIX-P11:',                              'P11 — patch marker'),
    ('Button(17, pull_up=True)',                 'P11 — single Button'),
    ('self.button.when_pressed',                 'P11 — when_pressed wired'),
    ('self.button.when_released',                'P11 — when_released wired'),
    ('def _on_button_pressed',                   'P11 — pressed handler'),
    ('def _on_button_released',                  'P11 — released handler'),
    ('def _do_provisioning_reset',               'P11 — shared reset helper'),
    ('def _on_button_held',                      'P11 — 5s handler'),
    ('def _run_provisioning_then_hard_reset',    'P11 — 20s combined handler'),
    ('def _on_button_hard_reset',                'P11 — hard reset steps'),
    ('time.monotonic()',                         'P11 — monotonic timer'),
    ('held >= 20',                               'P11 — 20s threshold'),
    ('held >= 5',                                'P11 — 5s threshold'),
    ('evvos-pico-voice',                         'P11 — voice service restart'),
    ('evvos-picam-tcp',                          'P11 — camera service restart'),
    ('sudo reboot',                              'P11 — reboot'),
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
echo -e "${CYAN}  Patch P11 applied${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  GPIO 17 button — action decided on RELEASE:${NC}"
echo -e "${CYAN}    Release before 5s  → nothing${NC}"
echo -e "${CYAN}    Release at  5-19s  → provisioning reset${NC}"
echo -e "${CYAN}    Release at   20s+  → provisioning reset + hard reset${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Expected in logs (5s release example):${NC}"
echo -e "${YELLOW}  INFO    - [BUTTON] Pressed — hold then release: 5s=prov reset, 20s=+hard reset${NC}"
echo -e "${YELLOW}  INFO    - [BUTTON] Released after 7.3s${NC}"
echo -e "${YELLOW}  WARNING - 🔘 BUTTON RELEASED AFTER 5s - INITIATING PROVISIONING RESET${NC}"
echo ""
echo -e "${YELLOW}  Expected in logs (20s release example):${NC}"
echo -e "${YELLOW}  INFO    - [BUTTON] Released after 21.1s${NC}"
echo -e "${YELLOW}  WARNING - 🔴 BUTTON RELEASED AFTER 20s - PROVISIONING RESET + HARD RESET${NC}"
echo -e "${YELLOW}  WARNING - [BUTTON] Step 1/2: Provisioning reset...${NC}"
echo -e "${YELLOW}  WARNING - [BUTTON] Step 2/2: Hard reset...${NC}"
echo ""
echo -e "${YELLOW}  Verify: journalctl -u evvos-provisioning -f${NC}"
echo ""
log_success "Done!"
