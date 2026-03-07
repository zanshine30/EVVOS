#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Comprehensive Fix (Video + Snapshot)
#
# Fixes TWO bugs in one pass:
#
# BUG 1 — Blank video / tiny MP4 after recording
#   Root cause: ffmpeg stream-copy (-c:v copy) is still active.
#   picamera2's raw H264 has no PTS values; stream-copying to MP4 makes every
#   frame show timestamp 0 → player renders black.
#   Fix: libx264 re-encode + "-vf setpts=N/(24*TB)" regenerates correct
#        sequential timestamps.
#
# BUG 2 — "Snapshot failed" error on mobile
#   Root cause: setup_picam_snapshot_7.sh partially applied.
#   PATCH 4 had wrong spacing in its anchor string
#   ("status":         vs "status":               ) causing AssertionError.
#   bash set -e killed the script there, so PATCH 7 (adding TAKE_SNAPSHOT to
#   the intent router) never ran. The function exists but is unreachable.
#   Fix: ensure TAKE_SNAPSHOT is in the intent router, and update
#        take_snapshot_handler to use camera.capture_image() — more robust
#        during active H264 recording than capture_request().
#
# WHY PREVIOUS PATCHES FAILED:
#   All previous patchers used literal string anchors. Any spacing mismatch
#   between the anchor and the actual file caused a silent no-op or a hard
#   exit mid-script, leaving the Pi in a partial state.
#
# THIS PATCH:
#   Uses regex to find and replace entire function bodies — robust to any
#   whitespace or intermediate-patch state. Writes a patch marker so it is
#   idempotent (safe to re-run).
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_fix_all.sh
# ============================================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_section() {
    echo -e "\n${CYAN}════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}▶ $1${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
}

if [ "$EUID" -ne 0 ]; then
    log_error "Run as root: sudo bash $0"
    exit 1
fi

CAMERA_SCRIPT="/usr/local/bin/evvos-picam-tcp.py"

if [ ! -f "$CAMERA_SCRIPT" ]; then
    log_error "Camera script not found: $CAMERA_SCRIPT"
    log_error "Run setup_picam_4.sh first."
    exit 1
fi

log_section "EVVOS Pi Camera — Comprehensive Fix (Video + Snapshot)"

# ── Backup ────────────────────────────────────────────────────────────────────
BACKUP="${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CAMERA_SCRIPT" "$BACKUP"
log_success "Backup: $BACKUP"

# ── Auto-detect ffmpeg fps flag ───────────────────────────────────────────────
FFMPEG_MAJOR=$(ffmpeg -version 2>&1 | awk '/^ffmpeg version/{split($3,a,"."); print a[1]+0}')
if [ "${FFMPEG_MAJOR:-0}" -ge 5 ]; then
    FPS_MODE_FLAG="-fps_mode cfr"
else
    FPS_MODE_FLAG="-vsync cfr"
fi
echo "ffmpeg version: ${FFMPEG_MAJOR}  →  using flag: ${FPS_MODE_FLAG}"

# ── Apply all fixes via Python ────────────────────────────────────────────────
python3 - "$CAMERA_SCRIPT" "$FPS_MODE_FLAG" << 'PATCHER_EOF'
import sys, re, json
from pathlib import Path

script   = Path(sys.argv[1])
fps_flag = sys.argv[2]
fps_parts = fps_flag.strip().split()   # ["-fps_mode","cfr"] or ["-vsync","cfr"]

MARKER = "# EVVOS-FIX-ALL-PATCH-v1"

src = script.read_text(encoding="utf-8")

if MARKER in src:
    print("Guard: patch already applied — nothing to do.")
    sys.exit(0)

applied = []

# =============================================================================
# HELPERS
# =============================================================================

def regex_replace_function(src, func_name, new_body):
    """
    Find the complete body of a top-level def <func_name>(): and replace it.
    Matches everything from 'def func_name():' up to (but not including) the
    next top-level 'def ' or end-of-string.
    Returns (new_src, True) on success, (src, False) if not found.
    """
    pattern = re.compile(
        rf'def {re.escape(func_name)}\(.*?\):.*?(?=\ndef \w|\Z)',
        re.DOTALL,
    )
    m = pattern.search(src)
    if not m:
        return src, False
    new_src = src[:m.start()] + new_body + src[m.end():]
    return new_src, True

def ensure_global(src, var_line, after_anchor):
    """Add var_line after after_anchor if var_line is not already in src."""
    if var_line in src:
        return src, False
    assert after_anchor in src, f"ensure_global anchor not found: {after_anchor!r}"
    return src.replace(after_anchor, after_anchor + "\n" + var_line, 1), True

def ensure_statement(src, statement, after_anchor):
    """Add statement after after_anchor if not already present."""
    if statement in src:
        return src, False
    assert after_anchor in src, f"ensure_statement anchor not found: {after_anchor!r}"
    return src.replace(after_anchor, after_anchor + "\n" + statement, 1), True

def ensure_intent_route(src, intent, handler_call, before_intent):
    """
    Add:
        elif intent == "<intent>":
            <handler_call>
    before the elif/else block for before_intent, if not already present.
    """
    new_block = f'                    elif intent == "{intent}":\n                        {handler_call}\n'
    if f'intent == "{intent}"' in src:
        return src, False   # already routed
    # Find before_intent (e.g. "GET_STATUS") and insert before it
    anchor = f'                    elif intent == "{before_intent}":'
    assert anchor in src, f"Intent router anchor not found: {anchor!r}"
    return src.replace(anchor, new_block + anchor, 1), True

# =============================================================================
# FIX 1 — Global: ensure snapshot_paths exists
# =============================================================================
src, changed = ensure_global(
    src,
    "snapshot_paths       = []    # JPEGs captured via TAKE_SNAPSHOT during a session",
    "audio_process        = None",
)
if changed:
    applied.append("Added snapshot_paths global")
else:
    print("snapshot_paths global: already present")

# =============================================================================
# FIX 2 — start_recording_handler: ensure snapshot_paths.clear()
# =============================================================================
src, changed = ensure_statement(
    src,
    "            snapshot_paths.clear()   # reset per-session snapshot list",
    "            RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)",
)
if changed:
    applied.append("Added snapshot_paths.clear() to start_recording_handler")
else:
    print("snapshot_paths.clear(): already present")

# =============================================================================
# FIX 3 — Replace take_snapshot_handler (or add it if missing)
#
# Uses camera.capture_image("main") instead of capture_request():
#   - capture_image() is the high-level API that returns a PIL Image safely
#     during active H264 recording.
#   - capture_request() is lower-level and requires manual request.release();
#     if the request is not released promptly it can stall the encoder.
# =============================================================================

SNAPSHOT_HANDLER = '''def take_snapshot_handler():
    """
    Capture a JPEG still from the current camera view while recording is active.
    Uses camera.capture_image("main") which is the safe high-level API for
    grabbing still frames from an ongoing video stream without stalling the encoder.
    The file is stored in snapshot_paths[] so TRANSFER_FILES bundles it with the video.
    """
    global snapshot_paths, current_session_id, recording
    if not camera:
        return {"status": "error", "message": "Camera not initialised"}
    if not recording:
        print("[SNAPSHOT] Warning: snapshot requested while not recording")

    try:
        RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
        idx      = len(snapshot_paths)
        pfx      = current_session_id or "nosession"
        filename = f"snapshot_{pfx}_{idx:04d}.jpg"
        snap_path = RECORDINGS_DIR / filename

        # capture_image() grabs the latest frame from the main stream and returns
        # a PIL Image — safe to call concurrently with an active H264 encoder.
        image = camera.capture_image("main")
        image.save(str(snap_path), "JPEG", quality=85)

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
        import traceback
        traceback.print_exc()
        print(f"[SNAPSHOT] Error: {e}")
        return {"status": "error", "message": str(e)}

'''

if "def take_snapshot_handler" in src:
    src, changed = regex_replace_function(src, "take_snapshot_handler", SNAPSHOT_HANDLER)
    if changed:
        applied.append("Replaced take_snapshot_handler (camera.capture_image fix)")
    else:
        print("WARNING: Could not replace take_snapshot_handler via regex")
else:
    # Not there at all — inject before get_status_handler
    anchor = "def get_status_handler():"
    assert anchor in src, f"Cannot find insertion point for take_snapshot_handler: {anchor!r}"
    src = src.replace(anchor, SNAPSHOT_HANDLER + anchor, 1)
    applied.append("Injected take_snapshot_handler (was missing entirely)")

# =============================================================================
# FIX 4 — Replace stop_recording_handler
#
# Fixes:
#   - libx264 + setpts=N/(24*TB)  → correct frame timestamps → playable video
#   - Synchronous transcription    → sidecar always written before TRANSFER_FILES
#   - snapshots_payload included   → stop response has snapshot data
# =============================================================================

fps_line = f'                "{fps_parts[0]}", "{fps_parts[1]}",'

STOP_HANDLER = f'''def stop_recording_handler():
    {MARKER}
    global recording, current_session_id, current_video_path, current_audio_path, audio_process, recording_start_time
    with recording_lock:
        if not recording:
            return {{"status": "not_recording"}}
        try:
            print("[CAMERA] Stopping recording...")
            camera.stop_recording()
            camera.stop()

            if audio_process:
                audio_process.terminate()
                try:
                    audio_process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    audio_process.kill()
                audio_process = None

            recording            = False
            recording_start_time = None
            time.sleep(1.0)   # let OS flush file buffers before ffmpeg reads them

            mp4_path = current_video_path.with_suffix(".mp4")
            raw_size = current_video_path.stat().st_size if current_video_path.exists() else 0
            print(f"[CAMERA] Raw H264 size: {{raw_size / 1024 / 1024:.2f}} MB ({{raw_size}} bytes)")

            if raw_size < 4096:
                print("[CAMERA] WARNING: H264 file is very small — camera may not have recorded")

            # ── FFMPEG: H264 → MP4 (libx264 re-encode — guaranteed correct timestamps) ──
            #
            # WHY NOT stream-copy (-c:v copy):
            #   picamera2's H264 elementary stream has no PTS values.
            #   Stream-copying to MP4 preserves those missing timestamps so every
            #   frame has PTS=0 — the player renders a black/blank screen.
            #   -fflags +genpts is unreliable with stream copy to MP4.
            #
            # THE FIX — libx264 + setpts=N/(24*TB):
            #   Each decoded frame gets a fresh sequential PTS:
            #     frame 0 → t=0s, frame 1 → t=1/24s, frame 2 → t=2/24s, …
            #   libx264 ultrafast re-encodes and embeds those correct timestamps.
            #   Trade-off: 30–90 s on Pi Zero 2 W vs ~5 s stream copy.
            #   Acceptable — a blank video is worse than a slow one.
            #
            print("[FFMPEG] Encoding MP4 with libx264 + timestamp fix (~30-90s on Pi Zero 2 W)...")
            has_audio = (
                current_audio_path is not None
                and current_audio_path.exists()
                and current_audio_path.stat().st_size > 1000
            )

            cmd = ["ffmpeg", "-y", "-r", "24", "-i", str(current_video_path)]

            if has_audio:
                cmd.extend(["-i", str(current_audio_path)])

            cmd.extend([
                "-vf", "setpts=N/(24*TB)",
                "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
                "-r", "24",
                {fps_line}
            ])

            if has_audio:
                cmd.extend(["-c:a", "aac", "-b:a", "128k"])
            else:
                cmd.extend(["-an"])

            cmd.extend(["-movflags", "+faststart", "-loglevel", "warning", str(mp4_path)])

            print(f"[FFMPEG] Command: {{' '.join(cmd)}}")
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=180)

            if res.returncode == 0:
                size_mb = mp4_path.stat().st_size / 1024 / 1024
                print(f"[FFMPEG] ✓ Success: {{mp4_path.name}} ({{size_mb:.2f}} MB)")
                current_video_path.unlink(missing_ok=True)
            else:
                print(f"[FFMPEG] FAILED (exit {{res.returncode}})")
                print(f"[FFMPEG] stderr: {{res.stderr[:600]}}")
                size_mb = mp4_path.stat().st_size / 1024 / 1024 if mp4_path.exists() else 0.0

            # ── TRANSCRIPTION (synchronous — ensures sidecar exists before TRANSFER_FILES) ──
            transcription = {{
                "transcript": "", "driver_name": "", "plate_number": "",
                "violations": [], "engine": "none",
            }}
            if current_audio_path and current_audio_path.exists():
                transcription = transcribe_best(current_audio_path)
                try:
                    current_audio_path.unlink(missing_ok=True)
                except Exception as _del_err:
                    print(f"[CAMERA] Could not delete audio: {{_del_err}}")

            sidecar = RECORDINGS_DIR / f"transcript_{{current_session_id}}.json"
            try:
                sidecar_data = dict(transcription)
                sidecar_data["status"] = "complete"
                sidecar.write_text(json.dumps(sidecar_data), encoding="utf-8")
                print(f"[TRANSCRIBE] Sidecar written: {{sidecar.name}}")
            except Exception as _sid_err:
                print(f"[TRANSCRIBE] Could not write sidecar: {{_sid_err}}")

            # ── SNAPSHOT PAYLOAD (base64 thumbnails for mobile preview) ──
            import base64 as _b64
            snapshots_payload = []
            for sp in snapshot_paths:
                if sp.exists():
                    try:
                        raw = sp.read_bytes()
                        snapshots_payload.append({{
                            "filename": sp.name,
                            "data":     _b64.b64encode(raw).decode(),
                            "size_kb":  round(len(raw) / 1024, 1),
                        }})
                    except Exception as snap_err:
                        print(f"[SNAPSHOT] Could not encode {{sp.name}}: {{snap_err}}")

            return {{
                "status":                "recording_stopped",
                "session_id":            current_session_id,
                "video_filename":        mp4_path.name,
                "video_path":            str(mp4_path),
                "video_size_mb":         round(size_mb, 2),
                "video_url":             f"http://{{get_pi_ip()}}:{{HTTP_PORT}}/{{mp4_path.name}}",
                "pi_ip":                 get_pi_ip(),
                "http_port":             HTTP_PORT,
                "transcript":            transcription["transcript"],
                "driver_name":           transcription["driver_name"],
                "plate_number":          transcription["plate_number"],
                "violations":            transcription["violations"],
                "transcription_engine":  transcription.get("engine", "none"),
                "transcription_status":  "complete",
                "snapshot_count":        len(snapshots_payload),
                "snapshot_filenames":    [s["filename"] for s in snapshots_payload],
                "snapshots":             snapshots_payload,
            }}
        except Exception as e:
            print(f"[CAMERA] Stop Error: {{e}}")
            import traceback; traceback.print_exc()
            return {{"status": "error", "message": str(e)}}

'''

src, changed = regex_replace_function(src, "stop_recording_handler", STOP_HANDLER)
if changed:
    applied.append("Replaced stop_recording_handler (libx264 + snapshots + sync transcription)")
else:
    print("ERROR: Could not locate stop_recording_handler — aborting.")
    sys.exit(1)

# =============================================================================
# FIX 5 — Intent router: ensure TAKE_SNAPSHOT is routed
# =============================================================================
src, changed = ensure_intent_route(
    src,
    intent="TAKE_SNAPSHOT",
    handler_call="res = take_snapshot_handler()",
    before_intent="GET_STATUS",
)
if changed:
    applied.append("Added TAKE_SNAPSHOT to intent router")
else:
    print("TAKE_SNAPSHOT intent route: already present")

# =============================================================================
# Write
# =============================================================================
script.write_text(src, encoding="utf-8")

print(f"\n{'='*52}")
print(f"Applied {len(applied)} change(s):")
for item in applied:
    print(f"  ✓ {item}")
print(f"{'='*52}")
PATCHER_EOF

log_success "Python patcher completed"

# ── Verify patch marker ───────────────────────────────────────────────────────
if grep -q "EVVOS-FIX-ALL-PATCH-v1" "$CAMERA_SCRIPT"; then
    log_success "Patch marker confirmed"
else
    log_error "Patch marker NOT found — patcher exited early. Check output above."
    log_warn "Restoring backup..."
    cp "$BACKUP" "$CAMERA_SCRIPT"
    exit 1
fi

# ── Verify no stream-copy remains in stop_recording_handler ──────────────────
if python3 -c "
import re, sys
src = open('$CAMERA_SCRIPT').read()
m = re.search(r'def stop_recording_handler\(\):.*?(?=\ndef \w)', src, re.DOTALL)
if m and '\"-c:v\", \"copy\"' in m.group(0):
    sys.exit(1)
sys.exit(0)
"; then
    log_success "Stream-copy removed from stop_recording_handler"
else
    log_error "Stream-copy still present — check script manually"
    exit 1
fi

# ── Verify libx264 present ────────────────────────────────────────────────────
if grep -q 'libx264' "$CAMERA_SCRIPT"; then
    log_success "libx264 confirmed"
else
    log_error "libx264 not found — restoring backup"
    cp "$BACKUP" "$CAMERA_SCRIPT"
    exit 1
fi

# ── Verify TAKE_SNAPSHOT is in the router ────────────────────────────────────
if grep -q 'intent == "TAKE_SNAPSHOT"' "$CAMERA_SCRIPT"; then
    log_success "TAKE_SNAPSHOT intent route confirmed"
else
    log_error "TAKE_SNAPSHOT still not in router — check patcher output"
    exit 1
fi

# ── Verify take_snapshot_handler uses capture_image ──────────────────────────
if grep -q 'capture_image' "$CAMERA_SCRIPT"; then
    log_success "take_snapshot_handler uses capture_image()"
else
    log_warn "capture_image not found — handler may be using old API"
fi

log_section "Restarting evvos-picam-tcp service"
systemctl restart evvos-picam-tcp.service
sleep 2

if systemctl is-active --quiet evvos-picam-tcp.service; then
    log_success "Service restarted and running"
else
    log_error "Service failed to restart"
    echo ""
    journalctl -u evvos-picam-tcp -n 40 --no-pager
    exit 1
fi

echo ""
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Fix Summary${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}  BUG 1 — Blank video:${NC}"
echo -e "${CYAN}    FIXED: ffmpeg now uses libx264 + setpts=N/(24*TB)${NC}"
echo -e "${CYAN}    Each frame gets a correct sequential timestamp${NC}"
echo -e "${CYAN}    Note: STOP_RECORDING will take 30–90 s on Pi Zero 2 W${NC}"
echo ""
echo -e "${GREEN}  BUG 2 — Snapshot failed:${NC}"
echo -e "${CYAN}    FIXED: TAKE_SNAPSHOT is now in the intent router${NC}"
echo -e "${CYAN}    take_snapshot_handler now uses camera.capture_image()${NC}"
echo -e "${CYAN}    (more reliable than capture_request during recording)${NC}"
echo ""
echo -e "${CYAN}  Also:${NC}"
echo -e "${CYAN}    • Transcription is synchronous — sidecar always ready${NC}"
echo -e "${CYAN}      for TRANSFER_FILES without the 30-second wait loop${NC}"
echo -e "${CYAN}    • snapshots[] included in STOP_RECORDING response${NC}"
echo -e "${CYAN}    • Full traceback logged on any handler exception${NC}"
echo ""
echo -e "${YELLOW}  Watch live logs: journalctl -u evvos-picam-tcp -f${NC}"
echo ""
log_success "Done. Test: record 10s → stop → transfer. Video should play."
