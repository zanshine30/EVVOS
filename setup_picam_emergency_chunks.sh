#!/bin/bash
# ============================================================================
# EVVOS Pi Camera — Emergency Recording Chunk Splitter Patch
#
# Problem solved:
#   Emergency recordings can exceed 2 minutes (the normal limit is bypassed
#   while the officer is in danger). Long recordings produce files that exceed
#   Supabase Storage's 50 MB per-object limit.
#
# Solution:
#   Patch transfer_files_handler() to call split_mp4_into_chunks() before
#   sending. Large MP4s are split into ≤20 MB keyframe-aligned segments using
#   ffmpeg before they are sent over the TCP socket to the phone.
#
#   Segment naming: video1.mp4, video2.mp4, video3.mp4, …
#   Each segment is independently playable (starts on a keyframe).
#   Files ≤20 MB are simply renamed to video1.mp4 and sent as-is.
#
# Run on the Raspberry Pi as root AFTER setup_picam_transfer.sh:
#   sudo bash setup_picam_emergency_chunks.sh
#
# Prerequisite:
#   sudo apt-get install -y ffmpeg
#
# What this does:
#   1. Injects split_mp4_into_chunks() helper into evvos-picam-tcp.py
#   2. Patches transfer_files_handler() to split large files before sending
#   3. Restarts the evvos-picam-tcp.service
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

# ── Check ffmpeg is available ────────────────────────────────────────────────
if ! command -v ffmpeg &> /dev/null; then
    log_error "ffmpeg not found. Install it first:"
    echo "  sudo apt-get install -y ffmpeg"
    exit 1
fi
log_success "ffmpeg found: $(ffmpeg -version 2>&1 | head -1)"

CAMERA_SCRIPT="/usr/local/bin/evvos-picam-tcp.py"

if [ ! -f "$CAMERA_SCRIPT" ]; then
    log_error "Camera script not found: $CAMERA_SCRIPT"
    log_error "Run setup_picam.sh then setup_picam_transfer.sh first."
    exit 1
fi

# Also verify transfer patch was applied
if ! grep -q "transfer_files_handler" "$CAMERA_SCRIPT"; then
    log_error "TRANSFER_FILES not found in camera script."
    log_error "Run setup_picam_transfer.sh before this script."
    exit 1
fi

log_section "Patching Pi Camera Service — Emergency Chunk Splitter"

# Backup original
cp "$CAMERA_SCRIPT" "${CAMERA_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

python3 << 'PATCHER_EOF'
from pathlib import Path

script = Path("/usr/local/bin/evvos-picam-tcp.py")
src = script.read_text(encoding="utf-8")

# ── GUARD: skip if already patched ───────────────────────────────────────────
if "split_mp4_into_chunks" in src:
    print("Already patched — skipping.")
    raise SystemExit(0)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 1: Inject split_mp4_into_chunks() helper before transfer_files_handler
# ─────────────────────────────────────────────────────────────────────────────
chunk_helper = '''
# Maximum size (MB) per video segment sent to the mobile app.
# Supabase Storage has a 50 MB per-object hard limit; 20 MB gives a safe margin.
MAX_CHUNK_MB = 20

def split_mp4_into_chunks(mp4_path: Path, max_mb: int = MAX_CHUNK_MB) -> list:
    """
    Split mp4_path into independently-playable segments of <= max_mb MB each.
    Uses ffmpeg's segment muxer with -break_non_keyframes 0 so every segment
    starts on a keyframe (required for seek-less playback on the phone).

    Output files are named video1.mp4, video2.mp4, … in the same directory.
    The original file is deleted once splitting succeeds.

    If the file is already <= max_mb it is simply renamed to video1.mp4.
    Falls back gracefully (rename to video1.mp4) if ffmpeg is unavailable or
    if the split fails for any reason.

    Returns an ordered list of Path objects.
    """
    import subprocess
    import shutil

    size_mb = mp4_path.stat().st_size / (1024 * 1024)

    if size_mb <= max_mb:
        # File fits in a single segment — just normalise the name
        dest = mp4_path.parent / "video1.mp4"
        if mp4_path != dest:
            mp4_path.rename(dest)
        print(f"[CHUNKS] File is {size_mb:.1f} MB — fits in one part, renamed to {dest.name}")
        return [dest]

    if not shutil.which("ffmpeg"):
        print("[CHUNKS] ⚠ ffmpeg not found — sending unsplit video")
        dest = mp4_path.parent / "video1.mp4"
        if mp4_path != dest:
            mp4_path.rename(dest)
        return [dest]

    # ── Estimate segment duration from file duration + target size ────────────
    seg_secs = 60   # conservative fallback: 1-minute segments
    try:
        probe = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                str(mp4_path),
            ],
            capture_output=True, text=True, timeout=30,
        )
        duration_s = float(probe.stdout.strip())
        if duration_s > 0:
            bitrate_kbps = (size_mb * 8 * 1024) / duration_s
            estimated = int((max_mb * 8 * 1024) / bitrate_kbps)
            seg_secs = max(10, estimated)   # never shorter than 10 s
            print(f"[CHUNKS] Duration: {duration_s:.1f}s | Bitrate: {bitrate_kbps:.0f} kbps | Target segment: {seg_secs}s")
    except Exception as probe_err:
        print(f"[CHUNKS] ffprobe failed ({probe_err}) — using {seg_secs}s segments as fallback")

    # ── Run ffmpeg segment muxer ─────────────────────────────────────────────
    # video%d.mp4 → video0.mp4, video1.mp4, … (0-based from ffmpeg)
    out_pattern = str(mp4_path.parent / "video%d.mp4")
    cmd = [
        "ffmpeg", "-y",
        "-i", str(mp4_path),
        "-c", "copy",                   # no re-encode — fast and lossless
        "-f", "segment",
        "-segment_time", str(seg_secs),
        "-reset_timestamps", "1",
        "-break_non_keyframes", "0",    # always start on a keyframe
        out_pattern,
    ]

    print(f"[CHUNKS] Splitting {mp4_path.name} ({size_mb:.1f} MB) into ≤{max_mb} MB parts (~{seg_secs}s each)…")
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)

    if result.returncode != 0:
        print(f"[CHUNKS] ffmpeg error (rc={result.returncode}): {result.stderr[:400]}")
        # Fallback: rename unsplit file
        dest = mp4_path.parent / "video1.mp4"
        if mp4_path != dest:
            mp4_path.rename(dest)
        return [dest]

    # ── Rename 0-based → 1-based for clarity on the phone side ──────────────
    chunks = []
    idx = 0
    while True:
        src_path = mp4_path.parent / f"video{idx}.mp4"
        if not src_path.exists():
            break
        dest_path = mp4_path.parent / f"video{idx + 1}.mp4"
        src_path.rename(dest_path)
        chunks.append(dest_path)
        idx += 1

    # Delete the original unsplit file (now fully split)
    mp4_path.unlink(missing_ok=True)

    total_mb = sum(c.stat().st_size / (1024 * 1024) for c in chunks)
    print(f"[CHUNKS] ✓ Split into {len(chunks)} part(s) — {total_mb:.1f} MB total")
    for c in chunks:
        print(f"[CHUNKS]   {c.name}: {c.stat().st_size / (1024*1024):.1f} MB")

    return chunks

'''

# Insert before transfer_files_handler
old = "def transfer_files_handler(conn):"
assert old in src, f"Anchor not found: {old!r}"
src = src.replace(old, chunk_helper + old, 1)

# ─────────────────────────────────────────────────────────────────────────────
# PATCH 2: Replace the MP4 collection block inside transfer_files_handler
# to call split_mp4_into_chunks() before building the file list.
# ─────────────────────────────────────────────────────────────────────────────
old_video_section = (
    '    # 1. MP4 video\n'
    '    all_mp4 = sorted(RECORDINGS_DIR.glob("*.mp4"), key=lambda f: f.stat().st_mtime, reverse=True)\n'
    '    if all_mp4:\n'
    '        mp4 = all_mp4[0]\n'
    '        files_to_send.append(mp4)\n'
    '        print(f"[TRANSFER] Video: {mp4.name} ({mp4.stat().st_size / 1024 / 1024:.2f} MB)")'
)

new_video_section = (
    '    # 1. MP4 video — split into ≤20 MB chunks for long emergency recordings\n'
    '    # "Raw" files are those not already named video*.mp4 (pre-chunked).\n'
    '    all_mp4 = sorted(RECORDINGS_DIR.glob("*.mp4"), key=lambda f: f.stat().st_mtime, reverse=True)\n'
    '    raw_mp4s = [f for f in all_mp4 if not f.name.startswith("video")]\n'
    '    if raw_mp4s:\n'
    '        # Split (or rename) the newest raw recording\n'
    '        chunks = split_mp4_into_chunks(raw_mp4s[0])\n'
    '        for chunk in chunks:\n'
    '            files_to_send.append(chunk)\n'
    '            print(f"[TRANSFER] Chunk: {chunk.name} ({chunk.stat().st_size / 1024 / 1024:.2f} MB)")\n'
    '    else:\n'
    '        # Pick up already-named video*.mp4 files (split in a prior run)\n'
    '        pre_named = sorted(RECORDINGS_DIR.glob("video*.mp4"))\n'
    '        for c in pre_named:\n'
    '            files_to_send.append(c)\n'
    '            print(f"[TRANSFER] Pre-chunk: {c.name} ({c.stat().st_size / 1024 / 1024:.2f} MB)")'
)

assert old_video_section in src, "Anchor not found (video section)"
src = src.replace(old_video_section, new_video_section, 1)

script.write_text(src, encoding="utf-8")
print("Both patches applied successfully.")
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
echo -e "${CYAN}  Emergency Chunk Splitter patch complete!${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  When TRANSFER_FILES is called after a long recording:${NC}"
echo -e "${CYAN}    ≤20 MB  → renamed to video1.mp4, sent as single file${NC}"
echo -e "${CYAN}    >20 MB  → ffmpeg splits into video1.mp4, video2.mp4 …${NC}"
echo -e "${CYAN}    Each segment starts on a keyframe (independently playable)${NC}"
echo -e "${CYAN}    Original file is deleted after successful split${NC}"
echo ""
echo -e "${YELLOW}  NOTE: Recording time limit is bypassed by the mobile app${NC}"
echo -e "${YELLOW}        when the officer triggers Emergency Backup.${NC}"
echo -e "${YELLOW}        This patch handles the resulting large files on the Pi side.${NC}"
echo ""
log_success "Done."
