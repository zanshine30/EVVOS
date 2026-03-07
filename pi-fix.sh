#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Bug Fix Patch 6
#
# Fixes two regressions introduced by the speed-optimisation patch:
#
#   BUG 1 — Black video (audio present):
#     CAUSE:  Raw .h264 from picamera2 has no presentation timestamps (PTS).
#             "-c:v copy" pasted those missing timestamps into the MP4
#             container, causing video players to show a black screen.
#     FIX:    Add "-fflags +genpts -r 24" before the input so FFmpeg
#             generates valid PTS from the 24 fps rate — no decode/re-encode
#             needed, speed benefit is kept.
#
#   BUG 2 — No transcript transferred:
#     CAUSE:  The phone sends TRANSFER_FILES within seconds of STOP_RECORDING.
#             The background Groq thread (5–20 s) hasn't written its JSON
#             sidecar yet, so the glob found nothing and transfer completed
#             with no transcript.
#     FIX:    Poll for transcript_*.json up to 30 s before building the
#             file list. Groq almost always finishes within that window.
#             Offline Whisper (60–120 s) times out gracefully and the phone
#             can fall back to polling GET_TRANSCRIPT.
#
# Run on the Raspberry Pi as root:
#   sudo bash setup_picam_bugfix_6.sh
#
# What this does:
#   1. Backs up /usr/local/bin/evvos-picam-tcp.py
#   2. Applies PATCH 1 — FFmpeg -fflags +genpts fix  (in stop_recording_handler)
#   3. Applies PATCH 2 — 30 s sidecar wait loop      (in transfer_files_handler)
#   4. Restarts evvos-picam-tcp.service
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

log_section "EVVOS Pi Camera — Bug Fix Patch 6"

# ── Backup ────────────────────────────────────────────────────────────────────
cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created: ${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

patches_applied = 0

# =============================================================================
# PATCH 1 — FFmpeg: add -fflags +genpts to fix black video on stream copy
#
# Targets the ffmpeg command list built inside stop_recording_handler().
# We look for the current "-r", "24" / "-framerate", "24" opening line and
# replace the whole cmd initialisation block with the corrected version.
#
# Handles two possible states of the file:
#   (a) Already has "-fflags", "+genpts"  → already patched, skip
#   (b) Has "-framerate", "24"            → first optimisation patch applied,
#                                           needs genpts added
#   (c) Has "-r", "24", "-i"              → original setup_picam_4 code,
#                                           also needs genpts added
# =============================================================================

PATCH1_GUARD = '"-fflags", "+genpts"'

if PATCH1_GUARD in src:
    print("PATCH 1 (genpts): already applied — skipping.")
else:
    # ── Variant A: optimisation patch was applied ("-framerate" form) ─────────
    OLD_FFMPEG_A = (
        '            cmd = [\n'
        '                "ffmpeg", "-y",\n'
        '                "-framerate", "24",          # fix PTS without setpts\n'
        '                "-i", str(current_video_path),\n'
        '            ]'
    )
    # ── Variant B: original setup_picam_4 code ("-r" form) ───────────────────
    OLD_FFMPEG_B = (
        '            cmd = [\n'
        '                "ffmpeg", "-y",\n'
        '                "-r", "24", "-i", str(current_video_path)\n'
        '            ]'
    )

    NEW_FFMPEG = (
        '            cmd = [\n'
        '                "ffmpeg", "-y",\n'
        '                "-fflags", "+genpts",        # generate PTS — fixes black screen on stream copy\n'
        '                "-r", "24",                  # input frame rate used by genpts to compute timestamps\n'
        '                "-i", str(current_video_path),\n'
        '            ]'
    )

    if OLD_FFMPEG_A in src:
        src = src.replace(OLD_FFMPEG_A, NEW_FFMPEG, 1)
        print("PATCH 1 (genpts): applied (variant A — optimisation build).")
        patches_applied += 1
    elif OLD_FFMPEG_B in src:
        src = src.replace(OLD_FFMPEG_B, NEW_FFMPEG, 1)
        print("PATCH 1 (genpts): applied (variant B — original build).")
        patches_applied += 1
    else:
        print("PATCH 1 (genpts): WARNING — could not find ffmpeg cmd anchor. Skipping.")
        print("  Inspect stop_recording_handler() manually if video is still black.")

# =============================================================================
# PATCH 2 — Transfer handler: wait up to 30 s for transcript sidecar
#
# Replaces the naive one-shot glob for transcript_*.json with a 30 s
# polling loop so the Groq sidecar is almost always ready before transfer.
#
# Handles two possible states:
#   (a) Already has the wait loop   → already patched, skip
#   (b) Has the one-shot glob only  → needs the loop
# =============================================================================

PATCH2_GUARD = 'Waiting for transcript sidecar'

if PATCH2_GUARD in src:
    print("PATCH 2 (sidecar wait): already applied — skipping.")
else:
    NEW_SIDECAR = (
        '    # 3. Transcript JSON sidecar — written by the background transcription thread.\n'
        '    # The officer typically triggers TRANSFER_FILES within seconds of STOP_RECORDING,\n'
        '    # but Groq transcription takes 5-20 s and offline Whisper takes 60-120 s.\n'
        '    # We wait up to 30 s (polling every 1 s) so Groq almost always finishes in\n'
        '    # time and the sidecar is bundled with the video in the same transfer.\n'
        '    # If transcription has not finished within 30 s (offline Whisper scenario),\n'
        '    # we proceed without it — the phone can poll GET_TRANSCRIPT separately.\n'
        '    import time as _time\n'
        '    print("[TRANSFER] Waiting for transcript sidecar (up to 30 s)...")\n'
        '    for _wait in range(30):\n'
        '        all_json = sorted(RECORDINGS_DIR.glob("transcript_*.json"))\n'
        '        if all_json:\n'
        '            print(f"[TRANSFER] Sidecar ready after {_wait} s")\n'
        '            break\n'
        '        _time.sleep(1)\n'
        '    else:\n'
        '        all_json = []\n'
        '        print("[TRANSFER] Sidecar not ready after 30 s — proceeding without transcript")\n'
        '\n'
        '    for j in all_json:\n'
        '        files_to_send.append(j)\n'
        '    if all_json:\n'
        '        print(f"[TRANSFER] Transcript sidecars: {len(all_json)} JSON file(s)")'
    )

    # ── Variant A: one-shot glob already present (optimisation patch was run) ──
    OLD_SIDECAR_A = (
        '    # 3. Transcript JSON sidecar — written by background transcription thread.\n'
        '    # Include whichever sidecar files exist at this moment; if transcription is\n'
        '    # still running the phone will fall back to polling GET_TRANSCRIPT.\n'
        '    all_json = sorted(RECORDINGS_DIR.glob("transcript_*.json"))\n'
        '    for j in all_json:\n'
        '        files_to_send.append(j)\n'
        '    if all_json:\n'
        '        print(f"[TRANSFER] Transcript sidecars: {len(all_json)} JSON file(s)")'
    )

    # ── Variant B: original transfer script — no sidecar block at all ─────────
    # Anchor: the end of the JPEG section, just before "if not files_to_send:"
    OLD_SIDECAR_B = (
        '    if all_jpg:\n'
        '        print(f"[TRANSFER] Snapshots: {len(all_jpg)} JPEG file(s)")\n'
        '\n'
        '    if not files_to_send:'
    )
    NEW_SIDECAR_B_REPLACEMENT = (
        '    if all_jpg:\n'
        '        print(f"[TRANSFER] Snapshots: {len(all_jpg)} JPEG file(s)")\n'
        '\n'
        + NEW_SIDECAR + '\n'
        '\n'
        '    if not files_to_send:'
    )

    if OLD_SIDECAR_A in src:
        src = src.replace(OLD_SIDECAR_A, NEW_SIDECAR, 1)
        print("PATCH 2 (sidecar wait): applied (variant A — one-shot glob replaced).")
        patches_applied += 1
    elif OLD_SIDECAR_B in src:
        src = src.replace(OLD_SIDECAR_B, NEW_SIDECAR_B_REPLACEMENT, 1)
        print("PATCH 2 (sidecar wait): applied (variant B — inserted after JPEG section).")
        patches_applied += 1
    else:
        if 'transfer_files_handler' not in src:
            print("PATCH 2 (sidecar wait): transfer_files_handler not found.")
            print("  Run setup_picam_transfer_5.sh first, then re-run this patch.")
        else:
            print("PATCH 2 (sidecar wait): WARNING — could not find anchor. Skipping.")
            print("  Inspect transfer_files_handler() manually.")

# =============================================================================
# Write only if at least one patch was applied
# =============================================================================
if patches_applied > 0:
    script.write_text(src, encoding="utf-8")
    print(f"\nAll {patches_applied} patch(es) written to {script}.")
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
echo -e "${CYAN}  Bug Fix Patch 6 — Summary${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}  FIX 1 — Black video (audio present):${NC}"
echo -e "${CYAN}    Added -fflags +genpts to ffmpeg stream-copy command.${NC}"
echo -e "${CYAN}    FFmpeg now generates valid PTS from the 24 fps input rate${NC}"
echo -e "${CYAN}    so the MP4 container has correct timestamps.${NC}"
echo -e "${CYAN}    No re-encode — speed benefit from patch 5 is kept.${NC}"
echo ""
echo -e "${GREEN}  FIX 2 — No transcript transferred:${NC}"
echo -e "${CYAN}    TRANSFER_FILES now waits up to 30 s for transcript sidecar.${NC}"
echo -e "${CYAN}    Groq (5–20 s) will almost always finish within that window.${NC}"
echo -e "${CYAN}    Offline Whisper (60–120 s) times out gracefully — phone${NC}"
echo -e "${CYAN}    can poll GET_TRANSCRIPT as fallback.${NC}"
echo ""
log_success "Patch complete — re-test recording and transfer."
