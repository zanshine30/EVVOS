#!/bin/bash
# ============================================================================
# EVVOS Provisioning — Patch P5: Button Reset via Shell Command
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_provision_complete_11.sh
#
# Safe to re-run — skips itself if the patch is already applied.
#
# ─────────────────────────────────────────────────────────────────────────────
# P5 — BUTTON RESET USES EXACT SHELL COMMAND
#      The previous _on_button_held() deleted only CREDS_FILE via Python's
#      os.remove() and called systemctl restart in a subprocess list.
#      This patch replaces the entire method body so the button runs:
#
#        sudo rm -f /etc/evvos/device_credentials.json \
#                   /tmp/evvos_ble_state.json \
#          && sudo systemctl restart evvos-provisioning
#
#      via subprocess shell=True — identical to typing that command manually.
#      This guarantees both state files are wiped atomically before the
#      service restarts, regardless of any Python-level state.
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

log_section "EVVOS Provisioning — Patch P5: Button Reset via Shell Command"

cp "$SCRIPT" "${SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

# ─────────────────────────────────────────────────────────────────────────────
# Write the Python patcher to a temp file and execute it.
# This avoids all heredoc/escaping issues with emoji and special characters.
# ─────────────────────────────────────────────────────────────────────────────
PATCHER_FILE=$(mktemp /tmp/evvos_p5_patcher_XXXXXX.py)
trap 'rm -f "$PATCHER_FILE"' EXIT

python3 - << 'WRITE_PATCHER_EOF'
import sys
from pathlib import Path
import os

patcher_dest = os.environ.get("PATCHER_FILE") or sys.argv[1] if len(sys.argv) > 1 else None

# Read the installed provisioning script to extract the exact old method
script_path = Path("/usr/local/bin/evvos-provisioning")
src = script_path.read_text(encoding="utf-8")

start = src.find("    def _on_button_held(self) -> None:")
if start == -1:
    print("ERROR: _on_button_held not found in provisioning script", file=sys.stderr)
    sys.exit(1)
end = src.find("\n    def ", start + 1)
old_method = src[start:end]

new_method = (
    "    def _on_button_held(self) -> None:\n"
    "        \"\"\"\n"
    "        Handler for button held event (5 seconds).\n"
    "        Runs the exact factory-reset shell command:\n"
    "          sudo rm -f /etc/evvos/device_credentials.json /tmp/evvos_ble_state.json\n"
    "            && sudo systemctl restart evvos-provisioning\n"
    "        \"\"\"\n"
    "        # FIX-P5: button reset via exact shell command\n"
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
    "                logger.warning(\"[BUTTON] \u2713 Reset command succeeded\")\n"
    "            else:\n"
    "                logger.error(\n"
    "                    \"[BUTTON] \u274c Reset command exited %s \u2014 stderr: %s\",\n"
    "                    result.returncode, result.stderr.strip()\n"
    "                )\n"
    "        except subprocess.TimeoutExpired:\n"
    "            logger.error(\"[BUTTON] \u274c Reset command timed out after 20s\")\n"
    "        except Exception as e:\n"
    "            logger.error(\"[BUTTON] \u274c Unexpected error running reset command: %s\", e)\n"
    "\n"
    "        logger.warning(\"=\" * 70)\n"
    "        logger.warning(\"[BUTTON] Provisioning reset complete - service is restarting\")\n"
    "        logger.warning(\"=\" * 70)"
)

patcher_code = f"""from pathlib import Path

script = Path("/usr/local/bin/evvos-provisioning")
src = script.read_text(encoding="utf-8")

MARKER = "# FIX-P5: button reset via exact shell command"

if MARKER in src:
    print("P5 already applied — nothing to do.")
    raise SystemExit(0)

old = {repr(old_method)}

new = {repr(new_method)}

assert old in src, (
    "P5 anchor not found — _on_button_held body did not match.\\n"
    "Inspect manually: grep -n '_on_button_held' /usr/local/bin/evvos-provisioning"
)

src = src.replace(old, new, 1)
script.write_text(src, encoding="utf-8")
print("P5 applied: _on_button_held now runs exact reset shell command via subprocess shell=True.")
"""

# Write patcher to the temp file path printed on stdout (shell reads it)
import tempfile, stat
tmp = tempfile.NamedTemporaryFile(
    mode="w", suffix=".py", prefix="evvos_p5_", delete=False, encoding="utf-8"
)
tmp.write(patcher_code)
tmp.flush()
tmp.close()
print(tmp.name)   # shell captures this
WRITE_PATCHER_EOF

# Capture the temp file path written by the patcher-writer
PATCHER_FILE=$(python3 - << 'WRITE_PATCHER_EOF'
import sys
from pathlib import Path

script_path = Path("/usr/local/bin/evvos-provisioning")
src = script_path.read_text(encoding="utf-8")

start = src.find("    def _on_button_held(self) -> None:")
if start == -1:
    print("ERROR: _on_button_held not found", file=sys.stderr)
    sys.exit(1)
end = src.find("\n    def ", start + 1)
old_method = src[start:end]

new_method = (
    "    def _on_button_held(self) -> None:\n"
    "        \"\"\"\n"
    "        Handler for button held event (5 seconds).\n"
    "        Runs the exact factory-reset shell command:\n"
    "          sudo rm -f /etc/evvos/device_credentials.json /tmp/evvos_ble_state.json\n"
    "            && sudo systemctl restart evvos-provisioning\n"
    "        \"\"\"\n"
    "        # FIX-P5: button reset via exact shell command\n"
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
    "                logger.warning(\"[BUTTON] \u2713 Reset command succeeded\")\n"
    "            else:\n"
    "                logger.error(\n"
    "                    \"[BUTTON] \u274c Reset command exited %s \u2014 stderr: %s\",\n"
    "                    result.returncode, result.stderr.strip()\n"
    "                )\n"
    "        except subprocess.TimeoutExpired:\n"
    "            logger.error(\"[BUTTON] \u274c Reset command timed out after 20s\")\n"
    "        except Exception as e:\n"
    "            logger.error(\"[BUTTON] \u274c Unexpected error running reset command: %s\", e)\n"
    "\n"
    "        logger.warning(\"=\" * 70)\n"
    "        logger.warning(\"[BUTTON] Provisioning reset complete - service is restarting\")\n"
    "        logger.warning(\"=\" * 70)"
)

import tempfile
tmp = tempfile.NamedTemporaryFile(
    mode="w", suffix=".py", prefix="evvos_p5_", delete=False, encoding="utf-8"
)
tmp.write(f"""from pathlib import Path

script = Path("/usr/local/bin/evvos-provisioning")
src = script.read_text(encoding="utf-8")

MARKER = "# FIX-P5: button reset via exact shell command"

if MARKER in src:
    print("P5 already applied — nothing to do.")
    raise SystemExit(0)

old = {repr(old_method)}

new = {repr(new_method)}

assert old in src, (
    "P5 anchor not found — _on_button_held body did not match.\\n"
    "Inspect manually: grep -n '_on_button_held' /usr/local/bin/evvos-provisioning"
)

src = src.replace(old, new, 1)
script.write_text(src, encoding="utf-8")
print("P5 applied: _on_button_held now runs exact reset shell command via subprocess shell=True.")
""")
tmp.flush(); tmp.close()
print(tmp.name)
WRITE_PATCHER_EOF
)

log_section "Applying patch P5"
python3 "$PATCHER_FILE"
rm -f "$PATCHER_FILE"
log_success "Python patcher completed"

# ─────────────────────────────────────────────────────────────────────────────
# Verification
# ─────────────────────────────────────────────────────────────────────────────
log_section "Verifying patch P5"
python3 << 'VERIFY_EOF'
src = open('/usr/local/bin/evvos-provisioning', encoding='utf-8').read()
checks = [
    ('# FIX-P5: button reset via exact shell command',
     'P5 — patch marker present'),
    ('sudo rm -f /etc/evvos/device_credentials.json /tmp/evvos_ble_state.json',
     'P5 — rm -f covers both state files'),
    ('&& sudo systemctl restart evvos-provisioning',
     'P5 — systemctl restart chained with &&'),
    ('shell=True',
     'P5 — subprocess called with shell=True'),
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
sleep 2

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
echo -e "${CYAN}  P5  Button reset command (GPIO 17, hold 5s):${NC}"
echo -e "${CYAN}      sudo rm -f /etc/evvos/device_credentials.json \\${NC}"
echo -e "${CYAN}                 /tmp/evvos_ble_state.json \\${NC}"
echo -e "${CYAN}        && sudo systemctl restart evvos-provisioning${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Test checklist:${NC}"
echo -e "${YELLOW}  1. Hold the ReSpeaker HAT button for 5 seconds${NC}"
echo -e "${YELLOW}  2. Watch logs: journalctl -u evvos-provisioning -f${NC}"
echo -e "${YELLOW}     You should see: 'BUTTON HELD 5 SECONDS - INITIATING PROVISIONING RESET'${NC}"
echo -e "${YELLOW}  3. Verify both files are gone:${NC}"
echo -e "${YELLOW}     ls -la /etc/evvos/device_credentials.json /tmp/evvos_ble_state.json${NC}"
echo -e "${YELLOW}  4. Confirm EVVOS_0001 hotspot reappears${NC}"
echo ""
log_success "Done!"
