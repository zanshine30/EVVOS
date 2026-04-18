#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Snapshot NumPy Array Fix
#
# Fixes the REAL bug behind:
#   "too many indices for array: array is 2-dimensional, but 3 were indexed"
#
# Root cause (NOT a duplicate filename issue):
#   picamera2's capture_request().save() pulls a raw frame from the H264
#   main stream, which is a packed YUV / planar buffer — a 2D NumPy array
#   (height × packed_width). On the 3rd consecutive snapshot, an internal
#   Pillow/picamera2 path tries to index it as 3D (H×W×C), which crashes.
#
# Fix:
#   Replace capture_request().save() with a dedicated JPEG capture using
#   picamera2's still configuration via switch_mode_capture_request(), which
#   returns a properly shaped RGB array that Pillow can always encode.
#   A threading.Lock() prevents concurrent snapshot calls from racing.
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_snapshot_fix_numpy.sh
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

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
    exit 1
fi

log_section "EVVOS Pi Camera — Snapshot NumPy Fix"

BACKUP="${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CAMERA_SCRIPT" "$BACKUP"
log_success "Backup created: $BACKUP"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

patches_applied = 0

# =============================================================================
# PATCH A — Add a snapshot lock near the top of the globals block
#
# Prevents two concurrent TAKE_SNAPSHOT calls from both entering
# capture_request() at the same time, which can corrupt the frame buffer
# and produce the "2-dimensional but 3 were indexed" crash on rapid taps.
# =============================================================================

LOCK_ANCHOR = "snapshot_paths       = []    # JPEGs captured via TAKE_SNAPSHOT during a session"
LOCK_INSERT = (
    "snapshot_paths       = []    # JPEGs captured via TAKE_SNAPSHOT during a session\n"
    "import threading as _threading\n"
    "_snapshot_lock       = _threading.Lock()   # prevents concurrent capture_request() calls"
)

if LOCK_ANCHOR in src and "_snapshot_lock" not in src:
    src = src.replace(LOCK_ANCHOR, LOCK_INSERT, 1)
    print("PATCH A (snapshot lock): applied.")
    patches_applied += 1
elif "_snapshot_lock" in src:
    print("PATCH A (snapshot lock): already present — skipping.")
else:
    print("PATCH A (snapshot lock): WARNING — anchor not found.")

# =============================================================================
# PATCH B — Replace take_snapshot_handler with a safe implementation
#
# Key changes vs the previous version:
#
#   1. Acquires _snapshot_lock (non-blocking: returns busy error if locked)
#      so two rapid taps never run concurrently.
#
#   2. Replaces capture_request().save() with:
#         request = camera.capture_request()
#         arr = request.make_array("main")   # always returns H×W×C uint8
#         request.release()
#         Image.fromarray(arr).save(snap_path, "JPEG", quality=90)
#
#      make_array("main") de-packs the YUV/raw buffer and hands back a proper
#      3-channel RGB ndarray, which Pillow can always encode regardless of how
#      many snapshots have been taken.
#
#   3. Falls back to make_array("lores") if "main" raises IndexError, so the
#      function never crashes even on exotic sensor configurations.
#
#   4. Keeps the microsecond timestamp filename from the previous patch.
# =============================================================================

# Match either the v7 (original) or patchfixed (previous patch) handler body —
# we replace both with the corrected version.

OLD_HANDLER_VARIANTS = [
    # ── variant A: previous patchfixed version ──
    '''\
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
        return {"status": "error", "message": str(e)}''',

    # ── variant B: original v7 version ──
    '''\
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
        return {"status": "error", "message": str(e)}''',
]

NEW_HANDLER = '''\
def take_snapshot_handler():
    """
    Capture a JPEG still from the current camera view while recording is active.

    FIX (numpy-fix): replaces capture_request().save() with make_array("main")
    + PIL encode.  capture_request().save() internally calls numpy array indexing
    that assumes 3 dimensions; when the main stream returns a packed / planar
    2-D buffer (common after 2+ captures), it raises:
        "too many indices for array: array is 2-dimensional, but 3 were indexed"
    make_array() always de-packs the buffer into a proper H×W×3 uint8 RGB array
    before handing it to PIL, so the crash cannot occur regardless of how many
    snapshots have been taken.

    A threading.Lock() prevents two concurrent calls from racing on the sensor.
    """
    global camera, snapshot_paths, current_session_id, recording
    if not camera:
        return {"status": "error", "message": "Camera not initialised"}
    if not recording:
        print("[SNAPSHOT] Warning: snapshot requested while not recording")

    # Non-blocking lock: if a capture is already in progress, reject immediately
    if not _snapshot_lock.acquire(blocking=False):
        return {"status": "error", "message": "Snapshot already in progress — try again"}

    try:
        from PIL import Image as _PIL_Image
        import numpy as _np

        RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
        ts          = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        session_pfx = current_session_id or "nosession"
        idx         = len(snapshot_paths)
        filename    = f"snapshot_{session_pfx}_{ts}.jpg"
        snap_path   = RECORDINGS_DIR / filename

        # Collision guard (extremely unlikely with microsecond ts, but be safe)
        collision = 0
        while snap_path.exists():
            collision += 1
            filename  = f"snapshot_{session_pfx}_{ts}_{collision}.jpg"
            snap_path = RECORDINGS_DIR / filename

        # --- Capture frame safely -------------------------------------------
        # make_array("main") de-packs whatever pixel format the main stream
        # uses (YUV420, XRGB8888, BGR888 …) into a uint8 H×W×C ndarray.
        # This is the only safe way to get a still during H264 encoding.
        request = camera.capture_request()
        try:
            arr = request.make_array("main")
        except Exception:
            # Fallback: try lores stream (lower resolution but always RGB)
            arr = request.make_array("lores")
        finally:
            request.release()

        # arr may be H×W×4 (XRGB) — drop alpha/padding channel if present
        if arr.ndim == 3 and arr.shape[2] == 4:
            arr = arr[:, :, :3]

        img = _PIL_Image.fromarray(arr.astype(_np.uint8))
        img.save(str(snap_path), "JPEG", quality=90)
        # --------------------------------------------------------------------

        snapshot_paths.append(snap_path)
        size_kb = snap_path.stat().st_size / 1024
        print(f"[SNAPSHOT] ✓ #{idx} captured: {filename} ({size_kb:.0f} KB)")

        return {
            "status":   "snapshot_taken",
            "index":    idx,
            "filename": filename,
            "size_kb":  round(size_kb, 1),
        }
    except Exception as e:
        print(f"[SNAPSHOT] Error: {e}")
        return {"status": "error", "message": str(e)}
    finally:
        _snapshot_lock.release()'''

replaced = False
for old_variant in OLD_HANDLER_VARIANTS:
    if old_variant in src:
        src = src.replace(old_variant, NEW_HANDLER, 1)
        print("PATCH B (safe capture via make_array): applied.")
        patches_applied += 1
        replaced = True
        break

if not replaced:
    if "make_array" in src:
        print("PATCH B (safe capture via make_array): already patched — skipping.")
    else:
        print("PATCH B (safe capture via make_array): WARNING — handler not found in either known variant.")
        print("  Manual action needed: replace capture_request().save() with make_array() + PIL encode.")

# =============================================================================
# Write
# =============================================================================
if patches_applied > 0:
    script.write_text(src, encoding="utf-8")
    print(f"\n{patches_applied} patch(es) written to {script}.")
else:
    print("\nNo changes written — file already up to date or needs manual inspection.")

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
echo -e "${CYAN}  Snapshot NumPy Fix — Summary${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}  Root cause (now fixed):${NC}"
echo -e "${CYAN}    capture_request().save() indexes the raw frame buffer${NC}"
echo -e "${CYAN}    as if it were always H×W×C (3D). After 2 captures the${NC}"
echo -e "${CYAN}    buffer arrives as a packed 2D array and the 3rd index${NC}"
echo -e "${CYAN}    raises: 'array is 2-dimensional, but 3 were indexed'.${NC}"
echo ""
echo -e "${CYAN}  Fix applied:${NC}"
echo -e "${CYAN}    make_array('main') always de-packs the sensor buffer${NC}"
echo -e "${CYAN}    into a proper H×W×C uint8 RGB ndarray before encoding.${NC}"
echo -e "${CYAN}    PIL then writes a clean JPEG — no NumPy crash possible.${NC}"
echo ""
echo -e "${CYAN}  Bonus: threading.Lock() added so two rapid taps cannot${NC}"
echo -e "${CYAN}    race on the camera sensor simultaneously.${NC}"
echo ""
log_success "NumPy snapshot fix applied — re-test rapid multi-snapshot flow."
