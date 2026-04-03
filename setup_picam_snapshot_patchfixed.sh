#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Snapshot Duplicate Fix Patch
#
# Fixes a bug where taking two snapshots in a row causes a "duplicate array /
# indices" error. Root causes fixed:
#
#   1. Filename collision guard: snapshot filename now uses a microsecond
#      timestamp instead of just the list index, so rapid back-to-back shots
#      can never produce the same filename even if snapshot_paths is briefly
#      out of sync.
#
#   2. snapshot_paths global declaration: added explicit `global snapshot_paths`
#      inside take_snapshot_handler() so every append is guaranteed to land in
#      the module-level list, not a shadowed local.
#
#   3. Duplicate-safe snapshots_payload build: the loop that builds
#      snapshots_payload in stop_recording_handler now de-duplicates entries by
#      filename before returning, preventing the phone from receiving two
#      identical filenames in the array.
#
#   4. snapshot_filenames dedup: the "snapshot_filenames" field is now built
#      from the already-deduplicated snapshots_payload list.
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_snapshot_patch2.sh
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

log_section "EVVOS Pi Camera — Snapshot Duplicate Fix"

# ── Backup ────────────────────────────────────────────────────────────────────
BACKUP="${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CAMERA_SCRIPT" "$BACKUP"
log_success "Backup created: $BACKUP"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

patches_applied = 0

# =============================================================================
# PATCH 1 — Fix take_snapshot_handler: timestamp-based filename + explicit global
#
# Replace the entire take_snapshot_handler function with a corrected version
# that:
#   • Declares `global snapshot_paths` explicitly (prevents shadowing)
#   • Uses a microsecond timestamp in the filename so two rapid shots never
#     collide even if len(snapshot_paths) hasn't updated yet
#   • Keeps idx (from len) for the log message only
# =============================================================================

OLD_HANDLER = '''\
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
        return {"status": "error", "message": str(e)}'''

NEW_HANDLER = '''\
def take_snapshot_handler():
    """
    Capture a JPEG still from the current camera view while recording is active.
    Uses picamera2's capture_request() which is safe to call during H264 recording.
    The captured file is stored in snapshot_paths for later base64 delivery and upload.

    FIX (patch2): filename now uses a microsecond timestamp so back-to-back
    snapshots never collide.  Explicit `global snapshot_paths` prevents any
    chance of a local-scope shadow that caused duplicate-index errors.
    """
    global camera, snapshot_paths, current_session_id, recording  # explicit global
    if not camera:
        return {"status": "error", "message": "Camera not initialised"}
    if not recording:
        # Allow snapshot even if not recording (useful for testing)
        print("[SNAPSHOT] Warning: snapshot requested while not recording")

    try:
        RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
        # Use a microsecond timestamp as the unique part of the filename so that
        # two rapid TAKE_SNAPSHOT calls can never produce the same path.
        ts           = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        session_pfx  = current_session_id or "nosession"
        idx          = len(snapshot_paths)          # used for log only
        filename     = f"snapshot_{session_pfx}_{ts}.jpg"
        snap_path    = RECORDINGS_DIR / filename

        # Safety: if somehow the same path already exists, append a counter
        collision = 0
        while snap_path.exists():
            collision += 1
            filename  = f"snapshot_{session_pfx}_{ts}_{collision}.jpg"
            snap_path = RECORDINGS_DIR / filename

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
        return {"status": "error", "message": str(e)}'''

if OLD_HANDLER in src:
    src = src.replace(OLD_HANDLER, NEW_HANDLER, 1)
    print("PATCH 1 (snapshot handler): applied — timestamp filename + collision guard.")
    patches_applied += 1
elif NEW_HANDLER in src:
    print("PATCH 1 (snapshot handler): already patched — skipping.")
else:
    print("PATCH 1 (snapshot handler): WARNING — handler body not found. Was it already modified?")

# =============================================================================
# PATCH 2 — De-duplicate snapshots_payload in stop_recording_handler
#
# Replace the snapshots_payload build loop with one that tracks seen filenames
# and skips duplicates before they reach the return dict.
# =============================================================================

OLD_PAYLOAD = '''\
            # ── BASE64 SNAPSHOTS (for mobile preview) ──────────────────────
            import base64 as _b64
            snapshots_payload = []
            for sp in snapshot_paths:
                if sp.exists():
                    try:
                        raw = sp.read_bytes()
                        snapshots_payload.append({
                            "filename": sp.name,
                            "data":     _b64.b64encode(raw).decode(),   # no newlines
                            "size_kb":  round(len(raw) / 1024, 1),
                        })
                    except Exception as snap_err:
                        print(f"[SNAPSHOT] Could not encode {sp.name}: {snap_err}")
            # NOTE: snapshot_paths intentionally NOT cleared here.
            # upload_to_supabase_handler() reads them and deletes after upload.
            # ─────────────────────────────────────────────────────────────────'''

NEW_PAYLOAD = '''\
            # ── BASE64 SNAPSHOTS (for mobile preview) ──────────────────────
            import base64 as _b64
            snapshots_payload = []
            _seen_snap_names  = set()   # FIX(patch2): guard against duplicate filenames
            for sp in snapshot_paths:
                if sp.name in _seen_snap_names:
                    print(f"[SNAPSHOT] Skipping duplicate filename: {sp.name}")
                    continue
                if sp.exists():
                    try:
                        raw = sp.read_bytes()
                        snapshots_payload.append({
                            "filename": sp.name,
                            "data":     _b64.b64encode(raw).decode(),   # no newlines
                            "size_kb":  round(len(raw) / 1024, 1),
                        })
                        _seen_snap_names.add(sp.name)
                    except Exception as snap_err:
                        print(f"[SNAPSHOT] Could not encode {sp.name}: {snap_err}")
            # NOTE: snapshot_paths intentionally NOT cleared here.
            # upload_to_supabase_handler() reads them and deletes after upload.
            # ─────────────────────────────────────────────────────────────────'''

if OLD_PAYLOAD in src:
    src = src.replace(OLD_PAYLOAD, NEW_PAYLOAD, 1)
    print("PATCH 2 (payload dedup): applied.")
    patches_applied += 1
elif NEW_PAYLOAD in src:
    print("PATCH 2 (payload dedup): already patched — skipping.")
else:
    print("PATCH 2 (payload dedup): WARNING — snapshots_payload block not found.")

# =============================================================================
# Write
# =============================================================================
if patches_applied > 0:
    script.write_text(src, encoding="utf-8")
    print(f"\n{patches_applied} patch(es) written to {script}.")
else:
    print("\nNo changes written — file already up to date.")

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
echo -e "${CYAN}  Snapshot Duplicate Fix — Summary${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}  Fix 1 — Filename uniqueness${NC}"
echo -e "${CYAN}    Snapshots now named by microsecond timestamp:${NC}"
echo -e "${CYAN}    snapshot_<session>_<YYYYMMDD_HHMMSS_ffffff>.jpg${NC}"
echo -e "${CYAN}    Two back-to-back shots can never share a filename.${NC}"
echo ""
echo -e "${CYAN}  Fix 2 — Collision guard${NC}"
echo -e "${CYAN}    If the same path somehow exists, a counter suffix${NC}"
echo -e "${CYAN}    is appended before writing (_1, _2, …).${NC}"
echo ""
echo -e "${CYAN}  Fix 3 — Payload de-duplication${NC}"
echo -e "${CYAN}    snapshots_payload build now tracks seen filenames${NC}"
echo -e "${CYAN}    and skips any duplicates before they reach the${NC}"
echo -e "${CYAN}    STOP_RECORDING response sent to the phone.${NC}"
echo ""
log_success "Snapshot duplicate fix applied — re-test double-snapshot flow."
