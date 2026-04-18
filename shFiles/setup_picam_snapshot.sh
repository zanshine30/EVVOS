#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Snapshot Feature Patch
# Adds TAKE_SNAPSHOT intent + base64 delivery + Supabase picture upload
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_snapshot_patch.sh
#
# What this does:
#   1. Patches /usr/local/bin/evvos-picam-tcp.py with snapshot support
#   2. Restarts the evvos-picam-tcp.service
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

log_section "Patching Pi Camera Service — Snapshot Support"

# Backup original
cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

# Apply patch via Python (more reliable than sed for multi-line insertions)
python3 << 'PATCHER_EOF'
import re
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD: skip if already patched ───────────────────────────────────────────
if "take_snapshot_handler" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 1: Add snapshot_paths to global state block
# Insert after: audio_process        = None
# ─────────────────────────────────────────────────────────────────────────────
old = "audio_process        = None"
new = (
    "audio_process        = None\n"
    "snapshot_paths       = []    # JPEGs captured via TAKE_SNAPSHOT during a session"
)
assert old in src, f"Anchor not found: {old!r}"
src = src.replace(old, new, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2: Reset snapshot_paths at the start of each recording session
# Insert inside start_recording_handler() just before: current_session_id = ...
# ─────────────────────────────────────────────────────────────────────────────
old = (
    "            RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)\n"
    "            ts                   = datetime.now().strftime(\"%Y%m%d_%H%M%S\")"
)
new = (
    "            RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)\n"
    "            snapshot_paths.clear()   # reset per-session snapshot list\n"
    "            ts                   = datetime.now().strftime(\"%Y%m%d_%H%M%S\")"
)
assert old in src, f"Anchor not found (patch 2)"
src = src.replace(old, new, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 3: Inject take_snapshot_handler() before get_status_handler()
# ─────────────────────────────────────────────────────────────────────────────
snapshot_handler_code = '''
def take_snapshot_handler():
    """
    Capture a JPEG still from the current camera view while recording is active.
    Uses picamera2's capture_request() which is safe to call during H264 recording.
    The captured file is stored in snapshot_paths for later base64 delivery and upload.
    """
    global camera, snapshot_paths, current_session_id, recording
    if not camera:
        return {"status": "error", "message": "Camera not initialised"}
    if not recording:
        # Allow snapshot even if not recording (useful for testing)
        print("[SNAPSHOT] Warning: snapshot requested while not recording")

    try:
        RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
        ts           = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        session_pfx  = current_session_id or "nosession"
        idx          = len(snapshot_paths)
        filename     = f"snapshot_{session_pfx}_{idx:04d}.jpg"
        snap_path    = RECORDINGS_DIR / filename

        # capture_request() captures the latest frame from the main stream.
        # It is explicitly designed to be called concurrently with an active encoder.
        request = camera.capture_request()
        request.save("main", str(snap_path))
        request.release()

        snapshot_paths.append(snap_path)
        size_kb = snap_path.stat().st_size / 1024
        print(f"[SNAPSHOT] ✓ #{idx} captured: {filename} ({size_kb:.0f} KB)")

        return {
            "status":    "snapshot_taken",
            "index":     idx,
            "filename":  filename,
            "size_kb":   round(size_kb, 1),
        }
    except Exception as e:
        print(f"[SNAPSHOT] Error: {e}")
        return {"status": "error", "message": str(e)}

'''

old = "def get_status_handler():"
assert old in src, "Anchor not found (patch 3)"
src = src.replace(old, snapshot_handler_code + old, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 4: Add base64 snapshots to the STOP_RECORDING response
# Insert just before the final return statement inside stop_recording_handler
# ─────────────────────────────────────────────────────────────────────────────
old = (
    '            return {\n'
    '                "status":         "recording_stopped",\n'
    '                "session_id":     current_session_id,'
)
new = (
    '            # ── BASE64 SNAPSHOTS (for mobile preview) ──────────────────────\n'
    '            import base64 as _b64\n'
    '            snapshots_payload = []\n'
    '            for sp in snapshot_paths:\n'
    '                if sp.exists():\n'
    '                    try:\n'
    '                        raw = sp.read_bytes()\n'
    '                        snapshots_payload.append({\n'
    '                            "filename": sp.name,\n'
    '                            "data":     _b64.b64encode(raw).decode(),   # no newlines\n'
    '                            "size_kb":  round(len(raw) / 1024, 1),\n'
    '                        })\n'
    '                    except Exception as snap_err:\n'
    '                        print(f"[SNAPSHOT] Could not encode {sp.name}: {snap_err}")\n'
    '            # NOTE: snapshot_paths intentionally NOT cleared here.\n'
    '            # upload_to_supabase_handler() reads them and deletes after upload.\n'
    '            # ─────────────────────────────────────────────────────────────────\n'
    '\n'
    '            return {\n'
    '                "status":         "recording_stopped",\n'
    '                "session_id":     current_session_id,'
)
assert old in src, "Anchor not found (patch 4)"
src = src.replace(old, new, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 5: Include snapshots_payload and snapshot_count in the return dict
# We need to find the end of the return dict in stop_recording_handler and
# add the new fields just before the closing brace.
# Anchor: the last field before the closing } of that return statement
# ─────────────────────────────────────────────────────────────────────────────
old = (
    '                "transcription_engine": transcription.get("engine", "none"),\n'
    '            }'
)
new = (
    '                "transcription_engine": transcription.get("engine", "none"),\n'
    '                # ── Snapshot fields ──────────────────────────────────────\n'
    '                "snapshot_count":    len(snapshots_payload),\n'
    '                "snapshot_filenames": [s["filename"] for s in snapshots_payload],\n'
    '                "snapshots":         snapshots_payload,   # [{filename, data, size_kb}]\n'
    '            }'
)
assert old in src, "Anchor not found (patch 5)"
src = src.replace(old, new, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 6: Upload snapshots to incident-pictures in upload_to_supabase_handler
# Insert just before: file_path.unlink() in the upload success block
# ─────────────────────────────────────────────────────────────────────────────
old = (
    '            file_path.unlink()\n'
    '            return {"status": "upload_complete", "video_url": public_url, "storage_path": storage_path}'
)
new = (
    '            # ── Upload snapshots to incident-pictures bucket ─────────────\n'
    '            picture_urls = []\n'
    '            for sp in list(snapshot_paths):   # iterate copy; we mutate inside\n'
    '                if not sp.exists():\n'
    '                    continue\n'
    '                pic_storage_path = f"{incident_id}/{sp.name}"\n'
    '                pic_url_endpoint = f"{url}/storage/v1/object/incident-pictures/{pic_storage_path}"\n'
    '                try:\n'
    '                    with open(sp, "rb") as pic_fh:\n'
    '                        pic_resp = requests.post(pic_url_endpoint, headers={\n'
    '                            "apikey":        anon,\n'
    '                            "Authorization": f"Bearer {auth_token or anon}",\n'
    '                            "Content-Type":  "image/jpeg",\n'
    '                            "x-upsert":      "true",\n'
    '                        }, data=pic_fh, timeout=60)\n'
    '                    if pic_resp.status_code in (200, 201):\n'
    '                        pub = f"{url}/storage/v1/object/public/incident-pictures/{pic_storage_path}"\n'
    '                        picture_urls.append(pub)\n'
    '                        sp.unlink(missing_ok=True)\n'
    '                        print(f"[UPLOAD] ✓ Picture uploaded: {sp.name}")\n'
    '                    else:\n'
    '                        print(f"[UPLOAD] ⚠ Picture upload failed {sp.name}: HTTP {pic_resp.status_code}")\n'
    '                except Exception as pic_err:\n'
    '                    print(f"[UPLOAD] ⚠ Picture upload error {sp.name}: {pic_err}")\n'
    '            snapshot_paths.clear()  # clear after upload attempt\n'
    '            # ─────────────────────────────────────────────────────────────\n'
    '\n'
    '            file_path.unlink()\n'
    '            return {\n'
    '                "status":        "upload_complete",\n'
    '                "video_url":     public_url,\n'
    '                "storage_path":  storage_path,\n'
    '                "picture_urls":  picture_urls,\n'
    '                "picture_count": len(picture_urls),\n'
    '            }'
)
assert old in src, "Anchor not found (patch 6)"
src = src.replace(old, new, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 7: Add TAKE_SNAPSHOT to the handle_client intent router
# ─────────────────────────────────────────────────────────────────────────────
old = '                    elif intent == "GET_STATUS":'
new = (
    '                    elif intent == "TAKE_SNAPSHOT":\n'
    '                        res = take_snapshot_handler()\n'
    '                    elif intent == "GET_STATUS":'
)
assert old in src, "Anchor not found (patch 7)"
src = src.replace(old, new, 1)

script.write_text(src, encoding="utf-8")
print("All 7 patches applied successfully.")
PATCHER_EOF

log_success "Python patcher completed"

# Restart the service to load changes
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
echo -e "${CYAN}  New TCP intent added: TAKE_SNAPSHOT${NC}"
echo -e "${CYAN}  • Triggers a JPEG still capture from the current camera view${NC}"
echo -e "${CYAN}  • Safe to call during active H264 recording (uses capture_request)${NC}"
echo -e "${CYAN}  • STOP_RECORDING response now includes 'snapshots' array (base64 JPEG)${NC}"
echo -e "${CYAN}  • UPLOAD_TO_SUPABASE now uploads JPEGs to 'incident-pictures' bucket${NC}"
echo ""
log_success "Snapshot patch complete!"
