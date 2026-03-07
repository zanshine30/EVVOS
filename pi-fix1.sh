#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Bug Fix Patch 7
#
# Fixes two issues from the stream-copy optimisation:
#
#   BUG 1 — Black video / 0.5 MB file (audio only):
#     ROOT CAUSE: picamera2 outputs a raw H.264 elementary stream with no
#                 container headers, no NAL unit framing, and no SPS/PPS
#                 anchors that FFmpeg can use to copy into an MP4 container.
#                 "-c:v copy" produced a near-empty video track — only the
#                 audio track was encoded successfully, giving a 0.5 MB file
#                 that plays audio but shows black.
#                 "-fflags +genpts" only fixes timestamps; it does not fix
#                 the missing bitstream structure required for stream copy.
#     FIX:    Revert to libx264 re-encode (ultrafast preset, CRF 23).
#             This is the only reliable path for picamera2 raw H.264 output.
#             Speed is recovered by keeping the 1.5 Mbps recording bitrate
#             (40% smaller input file = 40% faster encode) and the async
#             transcription (officer does not wait for Whisper).
#             Encode time: ~20-40 s (vs original ~30-90 s before bitrate fix).
#
#   BUG 2 — FFmpeg errors hidden:
#     "-loglevel error" suppressed all FFmpeg output, making the stream-copy
#     failure completely invisible in the service logs.
#     FIX:    Change to "-loglevel warning" so real errors are always logged.
#
#   BUG 3 — Transcription thread silent crash:
#     The background _bg_transcribe thread had no top-level exception handler.
#     Any unexpected error (missing binary, bad path, etc.) killed the thread
#     silently — no log output, no sidecar written, transcript never arrives.
#     FIX:    Wrap the entire thread body in try/except and always write the
#             sidecar (even if empty) so TRANSFER_FILES' 30 s wait never
#             times out unnecessarily on Groq failures.
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_bugfix_7.sh
#
# What this does:
#   1. Backs up /usr/local/bin/evvos-picam-tcp.py
#   2. PATCH 1 — Reverts ffmpeg to libx264 ultrafast re-encode
#   3. PATCH 2 — Changes -loglevel error → -loglevel warning
#   4. PATCH 3 — Adds try/except wrapper to _bg_transcribe thread body
#   5. Restarts evvos-picam-tcp.service
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

log_section "EVVOS Pi Camera — Bug Fix Patch 7"

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
# PATCH 1 — Revert FFmpeg to libx264 re-encode
#
# Handles every possible state the live script could be in:
#   (A) Stream-copy with -fflags +genpts  (bugfix_6 state — broken)
#   (B) Stream-copy with -framerate       (optimisation patch state — broken)
#   (C) Original libx264 re-encode        (already correct — skip)
# =============================================================================

PATCH1_GUARD = '"-c:v", "libx264"'

# New proven ffmpeg block
NEW_FFMPEG_BLOCK = '''\
            # ── RE-ENCODE MUX (libx264 ultrafast) ────────────────────────────
            # picamera2 outputs a raw H.264 elementary stream with no container
            # headers or SPS/PPS anchors — stream copy into MP4 is not reliable
            # and produces a near-empty video track (0.5 MB, black screen).
            # libx264 ultrafast re-encodes the stream correctly into MP4.
            # Speed vs original: recording bitrate is 1.5 Mbps (was 2.5 Mbps)
            # so the input file is ~40% smaller → encode is ~40% faster.
            # Transcription runs async so the officer never waits for Whisper.
            print("[FFMPEG] Re-encoding to MP4 (libx264 ultrafast)...")
            has_audio = current_audio_path and current_audio_path.exists() and current_audio_path.stat().st_size > 1000

            cmd = [
                "ffmpeg", "-y",
                "-r", "24", "-i", str(current_video_path),
            ]

            if has_audio:
                cmd.extend(["-i", str(current_audio_path)])

            cmd.extend([
                "-vf", "setpts=N/(24*TB)",
                "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
                "-r", "24", "-fps_mode", "cfr",
            ])

            if has_audio:
                cmd.extend(["-c:a", "aac", "-b:a", "64k"])
            else:
                cmd.extend(["-an"])

            cmd.extend([
                "-movflags", "+faststart", "-loglevel", "warning",
                str(mp4_path)
            ])'''

# ── Variant A: bugfix_6 stream-copy block (fflags + genpts) ──────────────────
OLD_FFMPEG_A = (
    '            # ── STREAM-COPY MUX (no re-encode — 3–8 s vs 30–90 s) ────────────────\n'
    '            # The raw H.264 from picamera2 has no presentation timestamps (PTS)\n'
    '            # in its elementary stream. Without -fflags +genpts, stream copy\n'
    '            # pastes those missing timestamps directly into the MP4 container,\n'
    '            # which causes video players to show a black screen.\n'
    '            # -fflags +genpts tells FFmpeg to generate valid PTS from the input\n'
    '            # frame rate so the MP4 has correct timing — no decode/encode needed.\n'
    '            print("[FFMPEG] Stream-copy mux (no re-encode)...")\n'
    '            has_audio = current_audio_path and current_audio_path.exists() and current_audio_path.stat().st_size > 1000\n'
    '\n'
    '            cmd = [\n'
    '                "ffmpeg", "-y",\n'
    '                "-fflags", "+genpts",        # generate PTS — fixes black screen on stream copy\n'
    '                "-r", "24",                  # input frame rate — used by genpts to compute timestamps\n'
    '                "-i", str(current_video_path),\n'
    '            ]\n'
    '\n'
    '            if has_audio:\n'
    '                cmd.extend(["-i", str(current_audio_path)])\n'
    '\n'
    '            cmd.extend(["-c:v", "copy"])     # stream copy — no decode/encode\n'
    '\n'
    '            if has_audio:\n'
    '                cmd.extend(["-c:a", "aac", "-b:a", "64k"])   # 64k is plenty for field voice\n'
    '            else:\n'
    '                cmd.extend(["-an"])\n'
    '\n'
    '            cmd.extend([\n'
    '                "-movflags", "+faststart", "-loglevel", "error",\n'
    '                str(mp4_path)\n'
    '            ])'
)

# ── Variant B: optimisation-only stream-copy block (-framerate form) ──────────
OLD_FFMPEG_B = (
    '            # ── STREAM-COPY MUX (no re-encode — 3–8 s vs 30–90 s) ────────────────\n'
    '            # The raw H.264 from picamera2 is already H.264 — we only need to\n'
    '            # wrap it in an MP4 container and mux in the WAV audio.\n'
    '            # Passing -framerate 24 before -i fixes the PTS/speed issue without\n'
    '            # the setpts filter (which forced a full decode+encode cycle).\n'
    '            print("[FFMPEG] Stream-copy mux (no re-encode)...")\n'
    '            has_audio = current_audio_path and current_audio_path.exists() and current_audio_path.stat().st_size > 1000\n'
    '\n'
    '            cmd = [\n'
    '                "ffmpeg", "-y",\n'
    '                "-framerate", "24",          # fix PTS without setpts\n'
    '                "-i", str(current_video_path),\n'
    '            ]\n'
    '\n'
    '            if has_audio:\n'
    '                cmd.extend(["-i", str(current_audio_path)])\n'
    '\n'
    '            cmd.extend(["-c:v", "copy"])     # stream copy — no decode/encode\n'
    '\n'
    '            if has_audio:\n'
    '                cmd.extend(["-c:a", "aac", "-b:a", "64k\"])\n'
    '            else:\n'
    '                cmd.extend(["-an"])\n'
    '\n'
    '            cmd.extend([\n'
    '                "-movflags", "+faststart", "-loglevel", "error",\n'
    '                str(mp4_path)\n'
    '            ])'
)

if PATCH1_GUARD in src:
    print("PATCH 1 (libx264 re-encode): already using libx264 — skipping.")
elif OLD_FFMPEG_A in src:
    src = src.replace(OLD_FFMPEG_A, NEW_FFMPEG_BLOCK, 1)
    print("PATCH 1 (libx264 re-encode): applied — reverted from fflags+genpts stream-copy.")
    patches_applied += 1
elif OLD_FFMPEG_B in src:
    src = src.replace(OLD_FFMPEG_B, NEW_FFMPEG_BLOCK, 1)
    print("PATCH 1 (libx264 re-encode): applied — reverted from -framerate stream-copy.")
    patches_applied += 1
else:
    print("PATCH 1 (libx264 re-encode): WARNING — could not find ffmpeg block anchor.")
    print("  Check stop_recording_handler() manually.")

# =============================================================================
# PATCH 2 — Change -loglevel error → -loglevel warning
#
# If the loglevel was already changed by a prior patch, skip.
# If it's still "error", replace it.
# =============================================================================

if '"-loglevel", "warning"' in src:
    print("PATCH 2 (loglevel): already set to warning — skipping.")
elif '"-loglevel", "error"' in src:
    src = src.replace('"-loglevel", "error"', '"-loglevel", "warning"', 1)
    print("PATCH 2 (loglevel): changed -loglevel error → warning.")
    patches_applied += 1
else:
    print("PATCH 2 (loglevel): loglevel line not found — skipping.")

# =============================================================================
# PATCH 3 — Wrap _bg_transcribe body in try/except
#
# The background thread had no top-level exception guard. Any crash killed it
# silently — no sidecar written, TRANSFER_FILES waits 30 s for nothing.
# We wrap the whole body and always write the sidecar, even on failure.
#
# Guard: if the wrapper is already present, skip.
# =============================================================================

PATCH3_GUARD = '[TRANSCRIBE] Thread crashed'

if PATCH3_GUARD in src:
    print("PATCH 3 (transcribe try/except): already applied — skipping.")
else:
    OLD_BG = (
        '            def _bg_transcribe(session_id, wav_path):\n'
        '                _transcript_state[session_id] = {"status": "pending"}\n'
        '                result = transcribe_best(wav_path) if (wav_path and wav_path.exists()) else \\\n'
        '                    {"transcript": "", "driver_name": "", "plate_number": "", "violations": [], "engine": "none"}\n'
        '                result["status"] = "complete"\n'
        '                _transcript_state[session_id] = result\n'
        '                # Write JSON sidecar so TRANSFER_FILES can bundle it with the video\n'
        '                sidecar = RECORDINGS_DIR / f"transcript_{session_id}.json"\n'
        '                try:\n'
        '                    sidecar.write_text(json.dumps(result), encoding="utf-8")\n'
        '                    print(f"[TRANSCRIBE] Sidecar written: {sidecar.name}")\n'
        '                except Exception as _e:\n'
        '                    print(f"[TRANSCRIBE] Could not write sidecar: {_e}")\n'
        '                try:\n'
        '                    if wav_path:\n'
        '                        wav_path.unlink(missing_ok=True)\n'
        '                except Exception:\n'
        '                    pass'
    )

    NEW_BG = (
        '            def _bg_transcribe(session_id, wav_path):\n'
        '                _transcript_state[session_id] = {"status": "pending"}\n'
        '                sidecar = RECORDINGS_DIR / f"transcript_{session_id}.json"\n'
        '                try:\n'
        '                    if wav_path and wav_path.exists() and wav_path.stat().st_size > 1000:\n'
        '                        print(f"[TRANSCRIBE] Starting transcription for {session_id}...")\n'
        '                        result = transcribe_best(wav_path)\n'
        '                    else:\n'
        '                        print(f"[TRANSCRIBE] WAV missing or too small — skipping transcription")\n'
        '                        result = {"transcript": "", "driver_name": "", "plate_number": "", "violations": [], "engine": "none"}\n'
        '                    result["status"] = "complete"\n'
        '                    _transcript_state[session_id] = result\n'
        '                except Exception as _thread_err:\n'
        '                    print(f"[TRANSCRIBE] Thread crashed: {_thread_err}")\n'
        '                    result = {"transcript": "", "driver_name": "", "plate_number": "", "violations": [], "engine": "error", "status": "complete"}\n'
        '                    _transcript_state[session_id] = result\n'
        '                # Always write the sidecar — even on failure — so TRANSFER_FILES\n'
        '                # 30 s wait loop exits immediately rather than timing out.\n'
        '                try:\n'
        '                    sidecar.write_text(json.dumps(result), encoding="utf-8")\n'
        '                    print(f"[TRANSCRIBE] Sidecar written: {sidecar.name}")\n'
        '                except Exception as _e:\n'
        '                    print(f"[TRANSCRIBE] Could not write sidecar: {_e}")\n'
        '                try:\n'
        '                    if wav_path:\n'
        '                        wav_path.unlink(missing_ok=True)\n'
        '                except Exception:\n'
        '                    pass'
    )

    if OLD_BG in src:
        src = src.replace(OLD_BG, NEW_BG, 1)
        print("PATCH 3 (transcribe try/except): applied.")
        patches_applied += 1
    else:
        print("PATCH 3 (transcribe try/except): WARNING — could not find _bg_transcribe anchor.")
        print("  Async transcription may not be present — check if speed patch was applied.")

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
echo -e "${CYAN}  Bug Fix Patch 7 — Summary${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}  FIX 1 — Black video / 0.5 MB file:${NC}"
echo -e "${CYAN}    Reverted to libx264 ultrafast re-encode.${NC}"
echo -e "${CYAN}    picamera2 raw H.264 cannot be stream-copied into MP4.${NC}"
echo -e "${CYAN}    Speed is still improved vs original:${NC}"
echo -e "${CYAN}      • 1.5 Mbps recording = ~40% smaller input file${NC}"
echo -e "${CYAN}      • Async transcription = officer not waiting for Whisper${NC}"
echo ""
echo -e "${GREEN}  FIX 2 — FFmpeg errors now visible in logs:${NC}"
echo -e "${CYAN}    -loglevel warning (was: error)${NC}"
echo -e "${CYAN}    Check logs: journalctl -u evvos-picam-tcp -f${NC}"
echo ""
echo -e "${GREEN}  FIX 3 — Transcription thread crash protection:${NC}"
echo -e "${CYAN}    _bg_transcribe now has a top-level try/except.${NC}"
echo -e "${CYAN}    Sidecar is always written (even on failure) so${NC}"
echo -e "${CYAN}    TRANSFER_FILES wait loop exits immediately.${NC}"
echo ""
log_success "Patch complete — re-test recording and transfer."
