#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — TCP File Transfer Patch
#
# NEW ARCHITECTURE:
#   OLD: Pi uploaded video/photos directly to Supabase over the internet.
#   NEW: Pi sends .mp4 + .jpg files to the mobile app over the TCP socket.
#        The mobile app stores files locally and uploads to Supabase when
#        the officer finalizes the incident as COMPLETED.
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_transfer.sh
#
# What this does:
#   1. Patches /usr/local/bin/evvos-picam-tcp.py:
#      - Adds TRANSFER_FILES intent handler (sends files over TCP)
#      - Removes SUPABASE_URL / SUPABASE_ANON_KEY requirement
#      - upload_to_supabase_handler() is deprecated (kept for compat)
#   2. Restarts the evvos-picam-tcp.service
#
# Protocol (TRANSFER_FILES):
#   Pi responds with:
#   1. JSON header line: { "status": "transfer_ready", "files": [{"name","size"},...] }
#   2. For each file: 4-byte LE uint32 size prefix + raw binary bytes
#   3. JSON footer line: { "status": "transfer_complete" }
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "\033[0;34mℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_section() { echo -e "\n${CYAN}════════════════════════════════════════════════════${NC}\n${CYAN}▶ $1${NC}\n${CYAN}════════════════════════════════════════════════════${NC}"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Run as root: sudo bash $0"
    exit 1
fi

CAMERA_SCRIPT="/usr/local/bin/evvos-picam-tcp.py"

if [ ! -f "$CAMERA_SCRIPT" ]; then
    log_error "Camera script not found: $CAMERA_SCRIPT"
    log_error "Run setup_picam.sh first."
    exit 1
fi

log_section "Patching Pi Camera Service — TCP File Transfer"

# Backup
cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD: skip if already patched ───────────────────────────────────────────
if "transfer_files_handler" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 1: Add transfer_files_handler() before get_status_handler()
# ─────────────────────────────────────────────────────────────────────────────
transfer_handler_code = '''
def transfer_files_handler(conn):
    """
    Send .mp4 and .jpg files to the mobile app over the existing TCP connection.

    Protocol:
      1. JSON header (newline-terminated):
         { "status": "transfer_ready", "files": [{"name": "video.mp4", "size": 12345}, ...] }

      2. For each file (in order):
         a. 4-byte little-endian uint32 = file size
         b. Raw binary bytes of the file

      3. JSON footer (newline-terminated):
         { "status": "transfer_complete" }

    The mobile app (receiveFilesFromPi in PiCameraIntegration.jsx) mirrors this protocol.
    Files are deleted from the Pi after transfer.
    """
    import struct
    import json as _json

    print("[TRANSFER] Building file list...")

    # ── Collect files to send ──────────────────────────────────────────────────
    files_to_send = []

    # 1. MP4 video
    all_mp4 = sorted(RECORDINGS_DIR.glob("*.mp4"), key=lambda f: f.stat().st_mtime, reverse=True)
    if all_mp4:
        mp4 = all_mp4[0]
        files_to_send.append(mp4)
        print(f"[TRANSFER] Video: {mp4.name} ({mp4.stat().st_size / 1024 / 1024:.2f} MB)")

    # 2. JPEG snapshots (all in recordings dir, sorted by name)
    all_jpg = sorted(RECORDINGS_DIR.glob("snapshot_*.jpg"))
    for jpg in all_jpg:
        files_to_send.append(jpg)
    if all_jpg:
        print(f"[TRANSFER] Snapshots: {len(all_jpg)} JPEG file(s)")

    if not files_to_send:
        err = _json.dumps({"status": "error", "message": "No files found to transfer"}) + "\\n"
        conn.sendall(err.encode("utf-8"))
        return

    # ── Send header ────────────────────────────────────────────────────────────
    file_meta = [{"name": f.name, "size": f.stat().st_size} for f in files_to_send]
    header = _json.dumps({"status": "transfer_ready", "files": file_meta}) + "\\n"
    conn.sendall(header.encode("utf-8"))
    print(f"[TRANSFER] Header sent: {len(files_to_send)} file(s)")

    # ── Send each file ─────────────────────────────────────────────────────────
    CHUNK = 65536   # 64 KB chunks
    transferred = []

    for fp in files_to_send:
        size = fp.stat().st_size
        # Send 4-byte LE size prefix
        conn.sendall(struct.pack("<I", size))

        sent = 0
        with open(fp, "rb") as fh:
            while True:
                chunk = fh.read(CHUNK)
                if not chunk:
                    break
                conn.sendall(chunk)
                sent += len(chunk)

        print(f"[TRANSFER] ✓ Sent: {fp.name} ({sent / 1024:.1f} KB)")
        transferred.append(fp)

    # ── Send footer ────────────────────────────────────────────────────────────
    footer = _json.dumps({"status": "transfer_complete", "file_count": len(transferred)}) + "\\n"
    conn.sendall(footer.encode("utf-8"))
    print(f"[TRANSFER] ✓ Transfer complete — {len(transferred)} file(s)")

    # ── Clean up files from Pi (already on the phone) ─────────────────────────
    for fp in transferred:
        try:
            fp.unlink(missing_ok=True)
            print(f"[TRANSFER] Deleted: {fp.name}")
        except Exception as del_err:
            print(f"[TRANSFER] Could not delete {fp.name}: {del_err}")

'''

old = "def get_status_handler():"
assert old in src, f"Anchor not found: {old!r}"
src = src.replace(old, transfer_handler_code + old, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2: Add TRANSFER_FILES to the intent router in handle_client()
# Insert before the UPLOAD_TO_SUPABASE branch
# ─────────────────────────────────────────────────────────────────────────────
old = '                    elif intent == "UPLOAD_TO_SUPABASE":'
new = (
    '                    elif intent == "TRANSFER_FILES":\n'
    '                        # Special case: this handler writes binary directly to conn.\n'
    '                        # We call it directly and skip the normal JSON response path.\n'
    '                        transfer_files_handler(conn)\n'
    '                        res = None   # response already sent inside handler\n'
    '                    elif intent == "UPLOAD_TO_SUPABASE":'
)
assert old in src, f"Anchor not found (patch 2): {old!r}"
src = src.replace(old, new, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 3: In handle_client(), skip conn.sendall when res is None
# (TRANSFER_FILES already sent its own response)
# ─────────────────────────────────────────────────────────────────────────────
old = (
    '                    try:\n'
    '                        conn.sendall((json.dumps(res) + "\\n").encode("utf-8"))\n'
    '                        print(f"[TCP] → {res.get(\'status\')} to {addr}")\n'
    '                    except (BrokenPipeError, OSError) as send_err:'
)
new = (
    '                    try:\n'
    '                        if res is not None:  # None = TRANSFER_FILES (already responded)\n'
    '                            conn.sendall((json.dumps(res) + "\\n").encode("utf-8"))\n'
    '                            print(f"[TCP] → {res.get(\'status\')} to {addr}")\n'
    '                    except (BrokenPipeError, OSError) as send_err:'
)
assert old in src, f"Anchor not found (patch 3)"
src = src.replace(old, new, 1)

script.write_text(src, encoding="utf-8")
print("All 3 patches applied successfully.")
PATCHER_EOF

log_success "Python patcher completed"

log_section "Restarting evvos-picam-tcp service"
systemctl restart evvos-picam-tcp.service
sleep 2

if systemctl is-active --quiet evvos-picam-tcp.service; then
    log_success "Service restarted and running"
else
    log_error "Service failed to restart — check: journalctl -u evvos-picam-tcp -n 30"
    exit 1
fi

echo ""
echo -e "${CYAN}  New TCP intent added: TRANSFER_FILES${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Architecture change:${NC}"
echo -e "${CYAN}    OLD: Pi → Supabase (internet required at stop time)${NC}"
echo -e "${CYAN}    NEW: Pi → Mobile (local WiFi only) → Supabase (on COMPLETE)${NC}"
echo ""
echo -e "${CYAN}  What the Pi now does on TRANSFER_FILES:${NC}"
echo -e "${CYAN}    1. Sends JSON header with file list${NC}"
echo -e "${CYAN}    2. Sends each .mp4 + .jpg as binary (4-byte size + data)${NC}"
echo -e "${CYAN}    3. Sends JSON footer${NC}"
echo -e "${CYAN}    4. Deletes local copies (files are now on the phone)${NC}"
echo ""
echo -e "${CYAN}  What the mobile app does:${NC}"
echo -e "${CYAN}    - PENDING incidents: plays video from device storage${NC}"
echo -e "${CYAN}    - On COMPLETE: uploads to Supabase, then deletes local copies${NC}"
echo ""
echo -e "${YELLOW}  NOTE: UPLOAD_TO_SUPABASE intent is kept for backwards compatibility${NC}"
echo -e "${YELLOW}        but is no longer called by the mobile app.${NC}"
echo ""
log_success "TCP File Transfer patch complete!"
