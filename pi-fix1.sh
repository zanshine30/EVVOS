#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Video Fix Patch
#
# PROBLEM:  Blank video / very small MP4 after recording.
# ROOT CAUSE:
#   The stream-copy ffmpeg approach (-c:v copy) in stop_recording_handler
#   produces blank video because picamera2's raw H264 elementary stream has
#   no PTS values. "-fflags +genpts" is unreliable with stream-copy to MP4 —
#   frames end up with identical or wrong timestamps so the player renders
#   nothing.
#
# THIS FIX:
#   Replaces the entire stop_recording_handler with one that:
#     1. Uses libx264 re-encode + "-vf setpts=N/(24*TB)" to regenerate
#        correct sequential timestamps — guaranteed playable output.
#     2. Runs transcription SYNCHRONOUSLY (no async thread) so TRANSFER_FILES
#        always finds the transcript sidecar without any 30-second wait.
#     3. Logs H264 raw size + full ffmpeg stderr on failure so future
#        debugging is easy.
#     4. Uses "-vsync cfr" (not "-fps_mode cfr") for ffmpeg 4.x compatibility
#        on older Raspberry Pi OS images.
#
# WHY THE PREVIOUS REVERT PATCH DIDN'T WORK:
#   setup_picam_patch.sh used literal string anchors to find the block to
#   replace. If any earlier intermediate patch changed even one character
#   in those anchor strings, the patcher silently printed "No changes written"
#   and did nothing — even though the service was restarted and appeared fine.
#
# HOW THIS PATCH IS DIFFERENT:
#   Uses a regex to locate the complete stop_recording_handler function body
#   and replaces the whole thing in one shot, regardless of what intermediate
#   state the script is in.
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_video_fix.sh
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
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
    log_error "Run setup_picam_4.sh first, then re-run this script."
    exit 1
fi

log_section "EVVOS Pi Camera — Video Fix Patch"

# ── Backup ────────────────────────────────────────────────────────────────────
BACKUP="${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CAMERA_SCRIPT" "$BACKUP"
log_success "Backup: $BACKUP"

# ── Check ffmpeg version (determines which -vsync / -fps_mode flag to use) ────
FFMPEG_MAJOR=$(ffmpeg -version 2>&1 | awk '/^ffmpeg version/{split($3,a,"."); print a[1]+0}')
echo "ffmpeg major version: ${FFMPEG_MAJOR}"
if [ "${FFMPEG_MAJOR}" -ge 5 ]; then
    FPS_MODE_FLAG="-fps_mode cfr"
else
    FPS_MODE_FLAG="-vsync cfr"
fi
echo "Using ffmpeg fps flag: ${FPS_MODE_FLAG}"

# ── Apply Python patch ────────────────────────────────────────────────────────
python3 - "$CAMERA_SCRIPT" "$FPS_MODE_FLAG" << 'PATCHER_EOF'
import sys, re
from pathlib import Path

script   = Path(sys.argv[1])
fps_flag = sys.argv[2]   # "-fps_mode cfr"  or  "-vsync cfr"

src = script.read_text(encoding="utf-8")

# ── Guard: already patched? ───────────────────────────────────────────────────
PATCH_MARKER = "# EVVOS-VIDEO-FIX-PATCH-APPLIED"
if PATCH_MARKER in src:
    print("Guard: patch marker found — script already up to date. Nothing to do.")
    sys.exit(0)

# ── Build the fps_mode line for the ffmpeg cmd list ───────────────────────────
# fps_flag is "-fps_mode cfr" or "-vsync cfr" — both are one ffmpeg arg pair.
fps_parts = fps_flag.strip().split()   # ["-fps_mode", "cfr"] or ["-vsync", "cfr"]
fps_line  = f'                "{fps_parts[0]}", "{fps_parts[1]}",'

# ── New stop_recording_handler ────────────────────────────────────────────────
NEW_HANDLER = f'''def stop_recording_handler():
    {PATCH_MARKER}
    global recording, current_session_id, current_video_path, current_audio_path, audio_process, recording_start_time
    with recording_lock:
        if not recording:
            return {{"status": "not_recording"}}
        try:
            print("[CAMERA] Stopping recording...")
            camera.stop_recording()
            camera.stop()

            # Stop audio gracefully
            if audio_process:
                audio_process.terminate()
                try:
                    audio_process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    audio_process.kill()
                audio_process = None

            recording            = False
            recording_start_time = None
            time.sleep(1.0)   # let the OS flush file buffers fully

            mp4_path = current_video_path.with_suffix(".mp4")
            raw_size = current_video_path.stat().st_size if current_video_path.exists() else 0
            print(f"[CAMERA] Raw H264 size: {{raw_size / 1024 / 1024:.2f}} MB  ({{raw_size}} bytes)")

            if raw_size < 4096:
                print(f"[CAMERA] WARNING: H264 file is tiny ({{raw_size}} bytes) — "
                      "camera may not have recorded. Check picamera2 logs.")

            # ── FFMPEG: H264 → MP4 (libx264 re-encode — guaranteed timing fix) ──
            #
            # WHY NOT stream-copy (-c:v copy):
            #   picamera2 writes an H264 elementary stream with no PTS values.
            #   Stream-copying those frames into an MP4 container preserves the
            #   missing/zeroed timestamps — most players then show a blank screen
            #   because every frame has the same presentation time.
            #   Even -fflags +genpts is unreliable in this scenario.
            #
            # THE FIX — libx264 + setpts:
            #   -vf "setpts=N/(24*TB)" resets each decoded frame's timestamp to
            #   a clean sequential value (frame_number / fps).  libx264 ultrafast
            #   then re-encodes the video with those corrected timestamps embedded
            #   in the MP4 container.  This always produces a playable file.
            #   Trade-off: ~30–90 s on Pi Zero 2 W vs. ~5 s for stream-copy.
            #   That is acceptable — blank video is not.
            #
            print("[FFMPEG] Encoding MP4 (libx264 ultrafast + timestamp fix)...")
            has_audio = (
                current_audio_path is not None
                and current_audio_path.exists()
                and current_audio_path.stat().st_size > 1000
            )

            cmd = [
                "ffmpeg", "-y",
                "-r", "24",
                "-i", str(current_video_path),
            ]

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
                print(f"[FFMPEG] FAILED (exit code {{res.returncode}})")
                print(f"[FFMPEG] stdout: {{res.stdout[:500]}}")
                print(f"[FFMPEG] stderr: {{res.stderr[:500]}}")
                size_mb = mp4_path.stat().st_size / 1024 / 1024 if mp4_path.exists() else 0.0

            # ── TRANSCRIPTION (synchronous — completes before TRANSFER_FILES) ──
            #
            # Running synchronously means:
            #   - The transcript JSON sidecar is always written before TRANSFER_FILES
            #     runs, so the phone receives all three files in one transfer.
            #   - No 30-second wait loop in transfer_files_handler needed.
            #   - No _transcript_state race conditions.
            #
            # Trade-off: STOP_RECORDING response takes an extra 5–20 s (Groq) or
            # 60–120 s (offline whisper) longer than the async version.
            # This is the original behaviour — it worked correctly before.
            #
            transcription = {{
                "transcript": "", "driver_name": "", "plate_number": "",
                "violations": [], "engine": "none",
            }}
            if current_audio_path and current_audio_path.exists():
                transcription = transcribe_best(current_audio_path)
                try:
                    current_audio_path.unlink(missing_ok=True)
                except Exception as _del_err:
                    print(f"[CAMERA] Could not delete audio file: {{_del_err}}")

            # Write JSON sidecar for TRANSFER_FILES
            sidecar = RECORDINGS_DIR / f"transcript_{{current_session_id}}.json"
            try:
                sidecar_data = dict(transcription)
                sidecar_data["status"] = "complete"
                sidecar.write_text(json.dumps(sidecar_data), encoding="utf-8")
                print(f"[TRANSCRIBE] Sidecar written: {{sidecar.name}}")
            except Exception as _sid_err:
                print(f"[TRANSCRIBE] Could not write sidecar: {{_sid_err}}")

            return {{
                "status":                "recording_stopped",
                "session_id":            current_session_id,
                "video_filename":        mp4_path.name,
                "video_path":            str(mp4_path),
                "video_size_mb":         round(size_mb, 2),
                "video_url":             f"http://{{get_pi_ip()}}:{{HTTP_PORT}}/{{mp4_path.name}}",
                "pi_ip":                 get_pi_ip(),
                "http_port":             HTTP_PORT,
                # Transcription fields — pre-fill IncidentSummaryScreen
                "transcript":            transcription["transcript"],
                "driver_name":           transcription["driver_name"],
                "plate_number":          transcription["plate_number"],
                "violations":            transcription["violations"],
                "transcription_engine":  transcription.get("engine", "none"),
                "transcription_status":  "complete",
            }}
        except Exception as e:
            print(f"[CAMERA] Stop Error: {{e}}")
            import traceback; traceback.print_exc()
            return {{"status": "error", "message": str(e)}}

'''

# ── Regex: find the entire stop_recording_handler body ───────────────────────
#
# Pattern explanation:
#   def stop_recording_handler\(\):   — function signature (literal)
#   .*?                               — everything lazily (DOTALL)
#   (?=\ndef \w)                      — stop just before the NEXT top-level
#                                       function definition (newline + "def " +
#                                       word-char).  Indented nested defs have
#                                       spaces before "def" so they don't match.
#
pattern = re.compile(
    r'def stop_recording_handler\(\):.*?(?=\ndef \w)',
    re.DOTALL,
)

match = pattern.search(src)
if not match:
    print("ERROR: Could not locate stop_recording_handler in the script.")
    print("       Is the file heavily modified?  Check the script manually:")
    print(f"       grep -n 'def stop_recording_handler' {sys.argv[1]}")
    sys.exit(1)

old_body = match.group(0)
print(f"Found stop_recording_handler  ({len(old_body):,} chars, "
      f"lines {src[:match.start()].count(chr(10))+1}–"
      f"{src[:match.end()].count(chr(10))+1})")

# Quick sanity check — make sure we grabbed the right function
if 'stop_recording' not in old_body or 'camera.stop_recording' not in old_body:
    print("ERROR: Pattern matched an unexpected section — aborting.")
    print(f"First 200 chars of match: {old_body[:200]!r}")
    sys.exit(1)

# Report what we're replacing
if '-c:v copy' in old_body or 'stream.copy' in old_body.lower() or 'stream copy' in old_body.lower():
    print("Detected: stream-copy ffmpeg variant  ← this causes blank video")
elif 'libx264' in old_body and '_bg_transcribe' in old_body:
    print("Detected: libx264 + async transcription variant")
elif 'libx264' in old_body:
    print("Detected: libx264 + synchronous transcription (already correct?)")
else:
    print("Detected: unknown ffmpeg variant")

new_src = src[:match.start()] + NEW_HANDLER + src[match.end():]
script.write_text(new_src, encoding="utf-8")

print(f"\n✓ stop_recording_handler replaced.")
print(f"  Old: {len(old_body):,} chars")
print(f"  New: {len(NEW_HANDLER):,} chars")
print(f"  fps flag used: {fps_flag}")
PATCHER_EOF

log_success "Python patcher completed"

# ── Verify the patch marker is now present ────────────────────────────────────
if grep -q "EVVOS-VIDEO-FIX-PATCH-APPLIED" "$CAMERA_SCRIPT"; then
    log_success "Patch marker confirmed in script"
else
    log_error "Patch marker NOT found — patcher may have exited early. Check output above."
    exit 1
fi

# ── Verify no leftover stream-copy lines in stop_recording_handler ────────────
if grep -q '"-c:v", "copy"' "$CAMERA_SCRIPT"; then
    log_warn "Stream-copy line still present in script — check manually"
else
    log_success "Stream-copy removed from script"
fi

# ── Verify libx264 is now present ─────────────────────────────────────────────
if grep -q 'libx264' "$CAMERA_SCRIPT"; then
    log_success "libx264 confirmed in script"
else
    log_error "libx264 NOT found — patcher may have failed. Restoring backup..."
    cp "$BACKUP" "$CAMERA_SCRIPT"
    log_warn "Restored from backup: $BACKUP"
    exit 1
fi

log_section "Restarting evvos-picam-tcp service"
systemctl restart evvos-picam-tcp.service
sleep 2

if systemctl is-active --quiet evvos-picam-tcp.service; then
    log_success "Service restarted and running"
else
    log_error "Service failed to restart"
    echo ""
    echo "Last 30 log lines:"
    journalctl -u evvos-picam-tcp -n 30 --no-pager
    exit 1
fi

echo ""
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Video Fix Patch — Summary${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}  Root cause fixed:${NC}"
echo -e "${CYAN}    BEFORE: ffmpeg stream-copy (-c:v copy) → blank video${NC}"
echo -e "${CYAN}            picamera2 H264 has no PTS; -fflags +genpts${NC}"
echo -e "${CYAN}            unreliable → frames all get timestamp 0${NC}"
echo ""
echo -e "${CYAN}    AFTER:  libx264 + setpts=N/(24*TB)${NC}"
echo -e "${CYAN}            each frame gets a correct sequential PTS${NC}"
echo -e "${CYAN}            re-encoded into a guaranteed-playable MP4${NC}"
echo ""
echo -e "${CYAN}  Other changes:${NC}"
echo -e "${CYAN}    • Transcription now synchronous (no async thread)${NC}"
echo -e "${CYAN}      → transcript JSON sidecar always ready for TRANSFER_FILES${NC}"
echo -e "${CYAN}    • Raw H264 size logged with byte count (easier debugging)${NC}"
echo -e "${CYAN}    • Full ffmpeg stderr logged on failure${NC}"
echo -e "${CYAN}    • ffmpeg fps flag auto-detected (ffmpeg 4.x vs 5.x compat)${NC}"
echo -e "${CYAN}    • sleep(0.5) → sleep(1.0) for better buffer flush${NC}"
echo ""
echo -e "${YELLOW}  NOTE: STOP_RECORDING now blocks for ~30–90 s (Pi Zero 2 W)${NC}"
echo -e "${YELLOW}        while ffmpeg encodes + Groq transcribes.${NC}"
echo -e "${YELLOW}        The mobile app already has a 5-minute timeout — this is fine.${NC}"
echo ""
echo -e "${GREEN}  Test: record 10 seconds, stop, transfer — video should play correctly.${NC}"
echo -e "${GREEN}  Watch Pi logs live: journalctl -u evvos-picam-tcp -f${NC}"
echo ""
log_success "Done! Run a test recording to confirm the fix."
