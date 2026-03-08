#!/bin/bash
# ============================================================================
# EVVOS Provisioning — Combined Patch P7 + P8
#                      GPIO Button: lgpio fix + dual independent hold handlers
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_provision_complete_15.sh
#
# Safe to re-run — skips patches already applied.
#
# ─────────────────────────────────────────────────────────────────────────────
# P7 — Fix "Failed to add edge detection" on Raspberry Pi OS Bookworm
#      RPi.GPIO (pip) is broken on kernel 6.6+. Replace with rpi-lgpio.
#
# P6 — GPIO 17 sysfs unexport on startup (prevents stale fd on restart)
#
# P8 — Dual independent hold-time handlers on GPIO 17:
#
#   Hold  5s  → PROVISIONING RESET (always fires immediately at 5s)
#               sudo rm -f /etc/evvos/device_credentials.json
#                          /tmp/evvos_ble_state.json
#               sudo systemctl restart evvos-provisioning
#
#   Hold 20s  → HARD RESET (fires additionally and independently at 20s)
#               The provisioning reset already ran at 5s. Hard reset adds:
#               1. sudo systemctl restart evvos-pico-voice
#               2. sudo systemctl restart evvos-picam-tcp
#               3. rm /home/pi/recordings/*.h264 *.wav *.mp4
#               4. truncate provisioning log
#               5. rm credentials + BLE state files (again, clean slate)
#               6. rm WiFi fail counter
#               7. sync filesystem
#               8. sudo reboot
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
# P7 — Replace broken RPi.GPIO with working rpi-lgpio
# ─────────────────────────────────────────────────────────────────────────────
log_section "P7: Replace RPi.GPIO with rpi-lgpio (Bookworm fix)"

log_info "Installing python3-rpi-lgpio via apt..."
apt-get install -y python3-rpi-lgpio
log_success "python3-rpi-lgpio installed"

log_info "Removing broken pip RPi.GPIO from venv (if present)..."
"$VENV/bin/pip" uninstall -y RPi.GPIO 2>/dev/null \
    && log_success "RPi.GPIO removed from venv" \
    || log_info "RPi.GPIO was not in venv (OK)"

log_info "Installing rpi-lgpio into venv..."
"$VENV/bin/pip" install rpi-lgpio
log_success "rpi-lgpio installed in venv"

# ─────────────────────────────────────────────────────────────────────────────
# P6 + P7 + P8 — Patch provisioning script
# ─────────────────────────────────────────────────────────────────────────────
log_section "P6 + P7 + P8: Patch provisioning script"

cp "$SCRIPT" "${SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-provisioning")
src = script.read_text(encoding="utf-8")

MARKER_P8 = "# FIX-P8: second Button object on same pin for 20s hard reset."

if MARKER_P8 in src:
    print("P7+P8 already applied — nothing to do.")
    raise SystemExit(0)

new_setup = (
    "    def _setup_button_handler(self) -> None:\n"
    "        \"\"\"\n"
    "        Setup ReSpeaker HAT physical button handler.\n"
    "        Button is on GPIO 17.\n"
    "          Hold  5s  \u2192 provisioning reset (always fires immediately at 5s)\n"
    "          Hold 20s  \u2192 hard reset + reboot (fires additionally at 20s)\n"
    "        Both actions are independent — holding past 5s does not cancel\n"
    "        the provisioning reset; it just adds the hard reset at 20s.\n"
    "        \"\"\"\n"
    "        if Button is None:\n"
    "            logger.warning(\"gpiozero not available - button handler disabled\")\n"
    "            return\n"
    "        \n"
    "        # FIX-P6: force-release GPIO 17 via sysfs before gpiozero claims it.\n"
    "        # On service restart the previous process is killed mid-run, leaving\n"
    "        # the pin exported and its edge-detection fd still registered in the\n"
    "        # kernel. Writing to unexport clears it so Button() succeeds cleanly.\n"
    "        try:\n"
    "            if os.path.exists(\"/sys/class/gpio/gpio17\"):\n"
    "                with open(\"/sys/class/gpio/unexport\", \"w\") as _f:\n"
    "                    _f.write(\"17\")\n"
    "                logger.info(\"[BUTTON] GPIO 17 unexported via sysfs (was held by previous instance)\")\n"
    "            time.sleep(0.1)\n"
    "        except Exception as _e:\n"
    "            logger.debug(\"[BUTTON] sysfs unexport skipped: %s\", _e)\n"
    "        \n"
    "        try:\n"
    "            # ReSpeaker 2-Mics HAT V2.0 uses GPIO 17 for the button.\n"
    "            # FIX-P7: explicit pull_up=True matches ReSpeaker HAT wiring\n"
    "            # (GPIO 17 pulled HIGH at rest, goes LOW when pressed)\n"
    "            self.button = Button(17, hold_time=5, pull_up=True)\n"
    "            self.button.when_held = self._on_button_held\n"
    "\n"
    "            # FIX-P8: second Button object on same pin for 20s hard reset.\n"
    "            # Both fire independently — 5s resets provisioning, 20s also\n"
    "            # restarts all services and reboots on top of that.\n"
    "            self.button_hard = Button(17, hold_time=20, pull_up=True)\n"
    "            self.button_hard.when_held = self._on_button_hard_reset\n"
    "\n"
    "            logger.info(\"\u2713 Button handler initialized (GPIO 17)\")\n"
    "            logger.info(\"  Hold  5s \u2192 provisioning reset (always)\")\n"
    "            logger.info(\"  Hold 20s \u2192 hard reset + reboot (additionally)\")\n"
    "        except Exception as e:\n"
    "            logger.warning(f\"Failed to initialize button handler: {e}\")\n"
    "            logger.warning(\"Physical button reset feature disabled, but provisioning will continue\")"
)

new_held = (
    "    def _on_button_held(self) -> None:\n"
    "        \"\"\"\n"
    "        Fires at 5 seconds. Always runs provisioning reset immediately,\n"
    "        regardless of whether the button is still held or held longer.\n"
    "        If the button is held to 20s, _on_button_hard_reset fires\n"
    "        additionally and independently in its own thread.\n"
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
    "        logger.warning(\"=\" * 70)"
)

new_hard_reset = (
    "\n"
    "\n"
    "    def _on_button_hard_reset(self) -> None:\n"
    "        \"\"\"\n"
    "        Fires at 20 seconds. Always runs in addition to the 5s provisioning\n"
    "        reset (which already fired 15 seconds earlier).\n"
    "        Hard reset order:\n"
    "          1. Restart evvos-pico-voice  (voice recognition service)\n"
    "          2. Restart evvos-picam-tcp   (camera service)\n"
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
    "        # 1. Restart voice recognition service\n"
    "        _run(\"sudo systemctl restart evvos-pico-voice\",\n"
    "             \"Restart evvos-pico-voice (voice recognition)\")\n"
    "\n"
    "        # 2. Restart camera service\n"
    "        _run(\"sudo systemctl restart evvos-picam-tcp\",\n"
    "             \"Restart evvos-picam-tcp (camera)\")\n"
    "\n"
    "        # 3. Clear leftover recording files\n"
    "        _run(\"rm -f /home/pi/recordings/*.h264 \"\n"
    "             \"/home/pi/recordings/*.wav \"\n"
    "             \"/home/pi/recordings/*.mp4\",\n"
    "             \"Clear recording files (.h264 / .wav / .mp4)\", timeout=10)\n"
    "\n"
    "        # 4. Truncate EVVOS log (keeps the file, empties content;\n"
    "        #    avoids breaking open file handles in other services)\n"
    "        _run(\"truncate -s 0 /var/log/evvos/evvos_provisioning.log 2>/dev/null || true\",\n"
    "             \"Truncate provisioning log\")\n"
    "\n"
    "        # 5. Delete provisioning state files\n"
    "        _run(\"sudo rm -f /etc/evvos/device_credentials.json \"\n"
    "             \"/tmp/evvos_ble_state.json\",\n"
    "             \"Delete provisioning state files\")\n"
    "\n"
    "        # 6. Reset WiFi fail counter so the device doesn't jump straight\n"
    "        #    into hotspot mode on reboot due to stale failure counts\n"
    "        _run(\"sudo rm -f /etc/evvos/.wifi_fail_count\",\n"
    "             \"Reset WiFi fail counter\")\n"
    "\n"
    "        # 7. Sync filesystem so no writes are lost when reboot cuts power\n"
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
    "        # 8. Reboot\n"
    "        _run(\"sudo reboot\", \"Reboot\", timeout=30)"
)

# Replace _setup_button_handler using find() — handles any prior patch version
m_start = src.find("    def _setup_button_handler(self) -> None:")
assert m_start != -1, "_setup_button_handler not found in provisioning script"
m_end = src.find("\n    def ", m_start + 1)
assert m_end != -1, "Could not find end of _setup_button_handler"
src = src[:m_start] + new_setup + src[m_end:]
print("_setup_button_handler replaced")

# Replace _on_button_held + append _on_button_hard_reset after it
h_start = src.find("    def _on_button_held(self) -> None:")
assert h_start != -1, "_on_button_held not found"
h_end = src.find("\n    def ", h_start + 1)
assert h_end != -1, "Could not find end of _on_button_held"
src = src[:h_start] + new_held + new_hard_reset + src[h_end:]
print("_on_button_held replaced + _on_button_hard_reset inserted")

script.write_text(src, encoding="utf-8")
print("\nDone.")
print("  Hold  5s \u2192 provisioning reset (always, immediately at 5s)")
print("  Hold 20s \u2192 hard reset + reboot (additionally, independently at 20s)")
PATCHER_EOF

log_success "Python patcher completed"

# ─────────────────────────────────────────────────────────────────────────────
# Verification
# ─────────────────────────────────────────────────────────────────────────────
log_section "Verifying all patches"

log_info "Checking rpi-lgpio is importable in venv..."
"$VENV/bin/python3" -c "import lgpio; print('  lgpio imported OK')" \
    && log_success "lgpio importable in venv" \
    || { log_error "lgpio not importable in venv"; exit 1; }

log_info "Checking RPi.GPIO is absent from venv..."
"$VENV/bin/python3" -c "import RPi.GPIO" 2>/dev/null \
    && log_error "RPi.GPIO still present in venv — may conflict" \
    || log_success "RPi.GPIO not in venv (correct)"

python3 << 'VERIFY_EOF'
src = open('/usr/local/bin/evvos-provisioning', encoding='utf-8').read()
checks = [
    ('# FIX-P6: force-release GPIO 17 via sysfs',       'P6 — sysfs unexport on startup'),
    ('/sys/class/gpio/unexport',                         'P6 — unexport write'),
    ('# FIX-P7: explicit pull_up=True',                  'P7 — pull_up=True marker'),
    ('Button(17, hold_time=5, pull_up=True)',             'P7 — 5s Button with pull_up'),
    ('# FIX-P8: second Button object on same pin',       'P8 — 20s Button marker'),
    ('Button(17, hold_time=20, pull_up=True)',            'P8 — 20s Button object'),
    ('self.button_hard.when_held = self._on_button_hard_reset', 'P8 — hard reset wired'),
    ('def _on_button_hard_reset',                        'P8 — hard reset method'),
    ('evvos-pico-voice',                                 'P8 — voice service restart'),
    ('evvos-picam-tcp',                                  'P8 — camera service restart'),
    ('/home/pi/recordings',                              'P8 — recording file cleanup'),
    ('truncate -s 0',                                    'P8 — log truncation'),
    ('.wifi_fail_count',                                 'P8 — WiFi fail counter reset'),
    ('sudo reboot',                                      'P8 — reboot command'),
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
echo -e "${CYAN}  All patches applied${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  P7  RPi.GPIO (broken on Bookworm) → rpi-lgpio${NC}"
echo -e "${CYAN}  P6  GPIO 17 sysfs unexport on service startup${NC}"
echo -e "${CYAN}  P7  Button(17, hold_time=5,  pull_up=True)${NC}"
echo -e "${CYAN}  P8  Button(17, hold_time=20, pull_up=True)${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  GPIO 17 button behaviour:${NC}"
echo -e "${CYAN}    Hold  5s  → provisioning reset (always, immediately)${NC}"
echo -e "${CYAN}    Hold 20s  → hard reset + reboot (additionally):${NC}"
echo -e "${CYAN}               1. restart evvos-pico-voice${NC}"
echo -e "${CYAN}               2. restart evvos-picam-tcp${NC}"
echo -e "${CYAN}               3. rm recordings/*.h264 *.wav *.mp4${NC}"
echo -e "${CYAN}               4. truncate provisioning log${NC}"
echo -e "${CYAN}               5. rm credentials + ble state files${NC}"
echo -e "${CYAN}               6. rm WiFi fail counter${NC}"
echo -e "${CYAN}               7. sync + reboot${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Expected in logs after restart:${NC}"
echo -e "${YELLOW}  INFO - ✓ Button handler initialized (GPIO 17)${NC}"
echo -e "${YELLOW}  INFO -   Hold  5s → provisioning reset (always)${NC}"
echo -e "${YELLOW}  INFO -   Hold 20s → hard reset + reboot (additionally)${NC}"
echo ""
echo -e "${YELLOW}  Verify: journalctl -u evvos-provisioning -n 20 --no-pager${NC}"
echo ""
log_success "Done!"
