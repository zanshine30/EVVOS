#!/bin/bash
# ============================================================================
# EVVOS Provisioning — Patch P12: Clean dual hold-time button logic
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_provision_complete_19.sh
#
# Safe to re-run — skips if already applied.
#
# ─────────────────────────────────────────────────────────────────────────────
# BEHAVIOUR (action decided on release):
#   Release before 5s   → nothing
#   Release at 5s-19s   → provisioning reset:
#                           sudo rm -f /etc/evvos/device_credentials.json
#                                      /tmp/evvos_ble_state.json
#                           && sudo systemctl restart evvos-provisioning
#   Release at 20s+     → hard reset:
#                           1. restart evvos-pico-voice
#                           2. restart evvos-picam-tcp
#                           3. rm recordings/*.h264 *.wav *.mp4
#                           4. truncate provisioning log
#                           5. rm WiFi fail counter
#                           6. sudo rm -f credentials + state files
#                           7. sync
#                           8. sudo systemctl restart evvos-provisioning
#                              (then reboot)
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

log_section "EVVOS Provisioning — Patch P12: Clean dual hold-time button logic"

cp "$SCRIPT" "${SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-provisioning")
src = script.read_text(encoding="utf-8")

MARKER = "# FIX-P12:"
if MARKER in src:
    print("P12 already applied — nothing to do.")
    raise SystemExit(0)

# ── ensure threading is imported ─────────────────────────────────────────────
if "import threading" not in src:
    src = src.replace(
        "import time\nimport uuid",
        "import threading\nimport time\nimport uuid",
        1
    )
    print("threading import added")

# ── new _setup_button_handler ─────────────────────────────────────────────────
new_setup = (
    "    def _setup_button_handler(self) -> None:\n"
    "        \"\"\"\n"
    "        Setup ReSpeaker HAT physical button handler (GPIO 17).\n"
    "        Action decided on RELEASE:\n"
    "          Release before 5s   → nothing\n"
    "          Release at 5s-19s   → provisioning reset\n"
    "          Release at 20s+     → hard reset (includes provisioning reset at end)\n"
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
    "            # FIX-P12: single Button, action decided on release.\n"
    "            self._press_time = None\n"
    "            self.button = Button(17, pull_up=True)\n"
    "            self.button.when_pressed  = self._on_button_pressed\n"
    "            self.button.when_released = self._on_button_released\n"
    "            logger.info(\"\u2713 Button handler initialized (GPIO 17)\")\n"
    "            logger.info(\"  Release at  5-19s \u2192 provisioning reset\")\n"
    "            logger.info(\"  Release at   20s+ \u2192 hard reset\")\n"
    "        except Exception as e:\n"
    "            logger.warning(f\"Failed to initialize button handler: {e}\")\n"
    "            logger.warning(\"Physical button reset feature disabled, but provisioning will continue\")"
)

# ── new button handlers ───────────────────────────────────────────────────────
new_handlers = (
    "    def _on_button_pressed(self) -> None:\n"
    "        \"\"\"Record the moment the button was pressed.\"\"\"\n"
    "        self._press_time = time.monotonic()\n"
    "        logger.info(\"[BUTTON] Pressed — release at 5s for prov reset, 20s for hard reset\")\n"
    "\n"
    "    def _on_button_released(self) -> None:\n"
    "        \"\"\"\n"
    "        Decide action on release.\n"
    "          < 5s  → nothing\n"
    "          5-19s → provisioning reset\n"
    "          20s+  → hard reset\n"
    "        \"\"\"\n"
    "        if self._press_time is None:\n"
    "            return\n"
    "        held = time.monotonic() - self._press_time\n"
    "        self._press_time = None\n"
    "        logger.info(\"[BUTTON] Released after %.1fs\", held)\n"
    "\n"
    "        if held >= 20:\n"
    "            threading.Thread(target=self._on_button_hard_reset, daemon=True).start()\n"
    "        elif held >= 5:\n"
    "            threading.Thread(target=self._on_button_held, daemon=True).start()\n"
    "        else:\n"
    "            logger.info(\"[BUTTON] Held %.1fs — too short, ignoring\", held)\n"
    "\n"
    "    def _on_button_held(self) -> None:\n"
    "        \"\"\"\n"
    "        Provisioning reset — released after 5-19s.\n"
    "        \"\"\"\n"
    "        logger.warning(\"=\" * 70)\n"
    "        logger.warning(\"\U0001f7e8 BUTTON RELEASED AFTER 5s - INITIATING PROVISIONING RESET\")\n"
    "        logger.warning(\"=\" * 70)\n"
    "        cmd = (\n"
    "            \"sudo rm -f /etc/evvos/device_credentials.json /tmp/evvos_ble_state.json\"\n"
    "            \" && sudo systemctl restart evvos-provisioning\"\n"
    "        )\n"
    "        logger.warning(\"[BUTTON] Running: %s\", cmd)\n"
    "        try:\n"
    "            result = subprocess.run(cmd, shell=True, timeout=20,\n"
    "                                    capture_output=True, text=True)\n"
    "            if result.returncode == 0:\n"
    "                logger.warning(\"[BUTTON] \u2713 Provisioning reset succeeded\")\n"
    "            else:\n"
    "                logger.error(\"[BUTTON] \u274c exited %s \u2014 %s\",\n"
    "                             result.returncode, result.stderr.strip())\n"
    "        except subprocess.TimeoutExpired:\n"
    "            logger.error(\"[BUTTON] \u274c Timed out\")\n"
    "        except Exception as e:\n"
    "            logger.error(\"[BUTTON] \u274c Error: %s\", e)\n"
    "\n"
    "    def _on_button_hard_reset(self) -> None:\n"
    "        \"\"\"\n"
    "        Hard reset — released after 20s+.\n"
    "        Runs all cleanup steps, then wipes provisioning files and restarts\n"
    "        the service (same command as provisioning reset) before rebooting.\n"
    "        \"\"\"\n"
    "        logger.warning(\"=\" * 70)\n"
    "        logger.warning(\"\U0001f534 BUTTON RELEASED AFTER 20s - INITIATING HARD RESET\")\n"
    "        logger.warning(\"=\" * 70)\n"
    "\n"
    "        def _run(cmd, label, timeout=15):\n"
    "            logger.warning(\"[HARD RESET] %s\", label)\n"
    "            try:\n"
    "                result = subprocess.run(cmd, shell=True, timeout=timeout,\n"
    "                                        capture_output=True, text=True)\n"
    "                if result.returncode == 0:\n"
    "                    logger.warning(\"[HARD RESET] \u2713 %s\", label)\n"
    "                else:\n"
    "                    logger.error(\"[HARD RESET] \u274c %s (exit %s) \u2014 %s\",\n"
    "                                 label, result.returncode, result.stderr.strip())\n"
    "            except subprocess.TimeoutExpired:\n"
    "                logger.error(\"[HARD RESET] \u274c %s timed out\", label)\n"
    "            except Exception as _e:\n"
    "                logger.error(\"[HARD RESET] \u274c %s error: %s\", label, _e)\n"
    "\n"
    "        _run(\"sudo systemctl restart evvos-pico-voice\",\n"
    "             \"Restart evvos-pico-voice\")\n"
    "        _run(\"sudo systemctl restart evvos-picam-tcp\",\n"
    "             \"Restart evvos-picam-tcp\")\n"
    "        _run(\"rm -f /home/pi/recordings/*.h264 \"\n"
    "             \"/home/pi/recordings/*.wav \"\n"
    "             \"/home/pi/recordings/*.mp4\",\n"
    "             \"Clear recording files\", timeout=10)\n"
    "        _run(\"truncate -s 0 /var/log/evvos/evvos_provisioning.log 2>/dev/null || true\",\n"
    "             \"Truncate provisioning log\")\n"
    "        _run(\"sudo rm -f /etc/evvos/.wifi_fail_count\",\n"
    "             \"Reset WiFi fail counter\")\n"
    "\n"
    "        # Wipe credentials + state files then restart service — same as\n"
    "        # provisioning reset, so the device comes up fresh after reboot.\n"
    "        _run(\n"
    "            \"sudo rm -f /etc/evvos/device_credentials.json /tmp/evvos_ble_state.json\"\n"
    "            \" && sudo systemctl restart evvos-provisioning\",\n"
    "            \"Wipe provisioning files + restart service\",\n"
    "            timeout=20,\n"
    "        )\n"
    "\n"
    "        logger.warning(\"[HARD RESET] Syncing filesystem...\")\n"
    "        try:\n"
    "            subprocess.run(\"sync\", shell=True, timeout=10)\n"
    "        except Exception:\n"
    "            pass\n"
    "\n"
    "        logger.warning(\"=\" * 70)\n"
    "        logger.warning(\"[HARD RESET] All steps complete \u2014 rebooting\")\n"
    "        logger.warning(\"=\" * 70)\n"
    "        _run(\"sudo reboot\", \"Reboot\", timeout=30)"
)

# replace _setup_button_handler
m_start = src.find("    def _setup_button_handler(self) -> None:")
assert m_start != -1, "_setup_button_handler not found"
m_end = src.find("\n    def ", m_start + 1)
src = src[:m_start] + new_setup + src[m_end:]

# replace all existing button handlers
BUTTON_METHODS = (
    "_on_button_pressed",
    "_on_button_released",
    "_on_button_held",
    "_on_button_hard_reset",
    "_run_provisioning_then_hard_reset",
    "_do_provisioning_reset",
    "_delete_provisioning_files",
)
h_start = None
for candidate in (
    "    def _on_button_pressed(self) -> None:",
    "    def _on_button_held(self) -> None:",
):
    idx = src.find(candidate)
    if idx != -1:
        h_start = idx
        break
assert h_start is not None, "no button handler found"

h_end = src.find("\n    def ", h_start + 1)
while h_end != -1:
    if any(n in src[h_end+1:h_end+80] for n in BUTTON_METHODS):
        h_end = src.find("\n    def ", h_end + 1)
    else:
        break
assert h_end != -1, "could not find end of button handler block"

src = src[:h_start] + new_handlers + src[h_end:]

script.write_text(src, encoding="utf-8")
print("P12 applied.")
PATCHER_EOF

log_success "Python patcher completed"

# ─────────────────────────────────────────────────────────────────────────────
# Verification
# ─────────────────────────────────────────────────────────────────────────────
log_section "Verifying patch P12"
python3 << 'VERIFY_EOF'
src = open('/usr/local/bin/evvos-provisioning', encoding='utf-8').read()
checks = [
    ('# FIX-P12:',                           'P12 — patch marker'),
    ('Button(17, pull_up=True)',              'P12 — single Button'),
    ('when_pressed',                          'P12 — when_pressed'),
    ('when_released',                         'P12 — when_released'),
    ('time.monotonic()',                      'P12 — monotonic timer'),
    ('held >= 20',                            'P12 — 20s threshold'),
    ('held >= 5',                             'P12 — 5s threshold'),
    ('def _on_button_held',                   'P12 — provisioning reset handler'),
    ('def _on_button_hard_reset',             'P12 — hard reset handler'),
    ('evvos-pico-voice',                      'P12 — voice restart'),
    ('evvos-picam-tcp',                       'P12 — camera restart'),
    ('/home/pi/recordings',                   'P12 — recordings cleanup'),
    ('Wipe provisioning files + restart',     'P12 — rm+restart in hard reset'),
    ('sudo reboot',                           'P12 — reboot'),
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
echo -e "${CYAN}  Patch P12 applied${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Release before 5s  → nothing${NC}"
echo -e "${CYAN}  Release at  5-19s  → provisioning reset:${NC}"
echo -e "${CYAN}    rm credentials + state files${NC}"
echo -e "${CYAN}    systemctl restart evvos-provisioning${NC}"
echo -e "${CYAN}  Release at   20s+  → hard reset:${NC}"
echo -e "${CYAN}    1. restart evvos-pico-voice${NC}"
echo -e "${CYAN}    2. restart evvos-picam-tcp${NC}"
echo -e "${CYAN}    3. rm recordings/*.h264 *.wav *.mp4${NC}"
echo -e "${CYAN}    4. truncate provisioning log${NC}"
echo -e "${CYAN}    5. rm WiFi fail counter${NC}"
echo -e "${CYAN}    6. rm credentials + state files${NC}"
echo -e "${CYAN}       && systemctl restart evvos-provisioning${NC}"
echo -e "${CYAN}    7. sync + reboot${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Verify: journalctl -u evvos-provisioning -f${NC}"
echo ""
log_success "Done!"
