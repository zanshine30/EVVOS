#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Revert Patch 8
#
# Reverts ALL speed-optimisation changes back to the original working code
# from setup_picam_4.sh.
#
# Flow after this patch (identical to the original):
#   1. STOP_RECORDING received
#   2. camera.stop_recording() + arecord stopped  →  .h264 + .wav on disk
#   3. ffmpeg: .h264 + .wav  →  .mp4  (libx264 ultrafast, setpts, cfr)
#   4. .wav sent to Groq (online) or whisper.cpp (offline)  →  transcript
#   5. recording_stopped response returned with transcript fields
#   6. TRANSFER_FILES: .mp4 (+ snapshots) sent to phone over TCP
#
# Changes reverted:
#   • H264Encoder bitrate: 1_500_000 → 2_500_000 (original)
#   • FFmpeg: stream-copy / genpts variants → original libx264 ultrafast
#   • Transcription: async _bg_transcribe thread → original synchronous call
#   • _transcript_state global dict removed (no longer needed)
#   • GET_TRANSCRIPT intent kept (harmless, used as fallback)
#   • transfer_files_handler sidecar wait loop kept (harmless)
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_revert_8.sh
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

log_section "EVVOS Pi Camera — Revert Patch 8"

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
# PATCH 1 — Revert H264Encoder bitrate to 2500000
# =============================================================================
if 'H264Encoder(bitrate=2500000' in src:
    print("PATCH 1 (bitrate): already 2500000 — skipping.")
elif 'H264Encoder(bitrate=1_500_000' in src:
    src = src.replace(
        'H264Encoder(bitrate=1_500_000, framerate=CAMERA_FPS)',
        'H264Encoder(bitrate=2500000, framerate=CAMERA_FPS)',
        1
    )
    print("PATCH 1 (bitrate): reverted 1_500_000 → 2500000.")
    patches_applied += 1
else:
    print("PATCH 1 (bitrate): WARNING — H264Encoder line not found.")

# =============================================================================
# PATCH 2 — Restore original ffmpeg + synchronous transcription block
#
# The section we replace runs from the line:
#   print(f"[CAMERA] Raw H264 size: ...")
# to just before:
#   except Exception as e:
#       print(f"[CAMERA] Stop Error: {e}")
#
# This covers every variant that may be on the Pi:
#   • Original setup_picam_4 (libx264, blocking transcription)      → already correct
#   • Opt patch (stream-copy -framerate)                            → reverted
#   • Bugfix 6 (stream-copy -fflags +genpts)                        → reverted
#   • Bugfix 7 (libx264 re-added but async _bg_transcribe)          → reverted
# =============================================================================

# ── The stable original block (exact text from setup_picam_4_ORIGINAL.sh) ────
ORIGINAL_BLOCK = '''\
            mp4_path = current_video_path.with_suffix(".mp4")
            raw_size = current_video_path.stat().st_size if current_video_path.exists() else 0
            print(f"[CAMERA] Raw H264 size: {raw_size / 1024 / 1024:.2f} MB")

            # ── SPEED FIX & AUDIO MUXING ──────────────────
            print("[FFMPEG] Muxing audio & fixing speed (Constant 24 FPS)...")
            has_audio = current_audio_path and current_audio_path.exists() and current_audio_path.stat().st_size > 1000
            
            cmd = [
                "ffmpeg", "-y",
                "-r", "24", "-i", str(current_video_path)
            ]
            
            if has_audio:
                cmd.extend(["-i", str(current_audio_path)])
                
            cmd.extend([
                "-vf", "setpts=N/(24*TB)",
                "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
                "-r", "24", "-fps_mode", "cfr"
            ])
            
            if has_audio:
                cmd.extend(["-c:a", "aac", "-b:a", "128k"])
            else:
                cmd.extend(["-an"])
                
            cmd.extend([
                "-movflags", "+faststart", "-loglevel", "warning",
                str(mp4_path)
            ])
            
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)

            if res.returncode == 0:
                size_mb = mp4_path.stat().st_size / 1024 / 1024
                print(f"[FFMPEG] \\u2713 Success: {mp4_path.name} ({size_mb:.2f} MB)")
                current_video_path.unlink(missing_ok=True)
                # NOTE: keep current_audio_path alive — whisper reads it next
            else:
                print(f"[FFMPEG] Error: {res.stderr}")
                size_mb = mp4_path.stat().st_size / 1024 / 1024 if mp4_path.exists() else 0

            # ── TRANSCRIPTION (online → offline fallback) ──────────────────
            # Run AFTER ffmpeg so audio is no longer being written to disk.
            # transcribe_best() checks internet first:
            #   \\u2022 Online  \\u2192 Groq Whisper large-v3-turbo (accurate, free API)
            #   \\u2022 Offline \\u2192 local whisper.cpp tiny.en (always available)
            # The raw WAV is kept until transcription finishes, then deleted.
            transcription = {"transcript": "", "driver_name": "", "plate_number": "", "violations": [], "engine": "none"}
            if current_audio_path and current_audio_path.exists():
                transcription = transcribe_best(current_audio_path)
                try:
                    current_audio_path.unlink(missing_ok=True)
                except Exception as _e:
                    print(f"[CAMERA] Could not delete audio file: {_e}")
            # ──────────────────────────────────────────────────────────────────

            return {
                "status":         "recording_stopped",
                "session_id":     current_session_id,
                "video_filename": mp4_path.name,
                "video_path":     str(mp4_path),
                "video_size_mb":  round(size_mb, 2),
                "video_url":      f"http://{get_pi_ip()}:{HTTP_PORT}/{mp4_path.name}",
                "pi_ip":          get_pi_ip(),
                "http_port":      HTTP_PORT,
                # ── Transcription fields (pre-fill IncidentSummaryScreen) ────
                "transcript":         transcription["transcript"],
                "driver_name":        transcription["driver_name"],
                "plate_number":       transcription["plate_number"],
                "violations":         transcription["violations"],
                "transcription_engine": transcription.get("engine", "none"),
            }
        except Exception as e:
            print(f"[CAMERA] Stop Error: {e}")
            return {"status": "error", "message": str(e)}'''

# ── Guard: already the exact original ─────────────────────────────────────────
if ORIGINAL_BLOCK in src:
    print("PATCH 2 (ffmpeg+transcription): already original — skipping.")
else:
    # Find the section to replace using stable start/end anchors present in
    # every patch state. Start = raw H264 size print, End = Stop Error handler.
    START_ANCHOR = '            mp4_path = current_video_path.with_suffix(".mp4")'
    END_ANCHOR   = ('        except Exception as e:\n'
                    '            print(f"[CAMERA] Stop Error: {e}")\n'
                    '            return {"status": "error", "message": str(e)}')

    start_idx = src.find(START_ANCHOR)
    end_idx   = src.find(END_ANCHOR)

    if start_idx == -1:
        print("PATCH 2: WARNING — start anchor not found. Is stop_recording_handler present?")
    elif end_idx == -1:
        print("PATCH 2: WARNING — end anchor not found.")
    else:
        # Replace from start anchor through to (and including) the end anchor
        src = src[:start_idx] + ORIGINAL_BLOCK + '\n' + src[end_idx + len(END_ANCHOR):]
        print("PATCH 2 (ffmpeg+transcription): reverted to original synchronous block.")
        patches_applied += 1

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
echo -e "${CYAN}  Revert Patch 8 — Summary${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}  Restored original flow:${NC}"
echo -e "${CYAN}    1. STOP_RECORDING → .h264 + .wav written to disk${NC}"
echo -e "${CYAN}    2. ffmpeg: .h264 + .wav → .mp4 (libx264 ultrafast)${NC}"
echo -e "${CYAN}    3. .wav → Groq (online) or whisper.cpp (offline)${NC}"
echo -e "${CYAN}    4. recording_stopped response with transcript fields${NC}"
echo -e "${CYAN}    5. TRANSFER_FILES: .mp4 + snapshots sent to phone${NC}"
echo ""
echo -e "${YELLOW}  Note: STOP_RECORDING will block for the full ffmpeg + Groq${NC}"
echo -e "${YELLOW}  duration before responding (~30-90 s on Pi Zero 2 W).${NC}"
echo -e "${YELLOW}  This is the original behaviour — it worked before.${NC}"
echo ""
log_success "Revert complete — re-test recording and transfer."
