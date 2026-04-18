#!/usr/bin/env python3
"""
Minimal picamera2 recording test — run directly on the Pi:
  sudo python3 test_camera.py

Tests each layer independently so you can see exactly where it breaks.
"""
import time, sys, subprocess
from pathlib import Path

OUT = Path("/home/pi/recordings")
OUT.mkdir(parents=True, exist_ok=True)

# ── TEST 1: Can we import and open picamera2? ─────────────────────────────────
print("\n[1] Importing picamera2...")
try:
    from picamera2 import Picamera2
    from picamera2.encoders import H264Encoder
    from picamera2.outputs import FileOutput
    print("    ✓ Import OK")
except ImportError as e:
    print(f"    ✗ Import FAILED: {e}")
    sys.exit(1)

# ── TEST 2: Can we open the camera? ──────────────────────────────────────────
print("\n[2] Opening camera...")
try:
    cam = Picamera2()
    print("    ✓ Picamera2() OK")
except Exception as e:
    print(f"    ✗ FAILED: {e}")
    sys.exit(1)

# ── TEST 3: libcamera-hello smoke test ───────────────────────────────────────
print("\n[3] libcamera-hello (2s preview, no display)...")
r = subprocess.run(
    ["libcamera-hello", "--nopreview", "--timeout", "2000"],
    capture_output=True, text=True
)
if r.returncode == 0:
    print("    ✓ libcamera-hello OK")
else:
    print(f"    ✗ Exit {r.returncode}")
    print(f"    stderr: {r.stderr.strip()[:300]}")

# ── TEST 4: libcamera-vid writes real bytes ───────────────────────────────────
print("\n[4] libcamera-vid 3s clip...")
vid_path = OUT / "test_libcam.h264"
r = subprocess.run(
    ["libcamera-vid", "--nopreview", "--timeout", "3000",
     "--width", "1280", "--height", "720", "--framerate", "24",
     "-o", str(vid_path)],
    capture_output=True, text=True
)
size = vid_path.stat().st_size if vid_path.exists() else 0
if size > 0:
    print(f"    ✓ libcamera-vid wrote {size / 1024:.0f} KB  → hardware is fine")
else:
    print(f"    ✗ 0 bytes — camera hardware or driver problem")
    print(f"    stderr: {r.stderr.strip()[:300]}")
    print("\n    >>> Hardware/driver issue confirmed. Check:")
    print("        vcgencmd get_camera")
    print("        dmesg | grep -i cam")
    sys.exit(1)

# ── TEST 5: picamera2 FileOutput records real bytes ───────────────────────────
print("\n[5] picamera2 FileOutput 3s recording...")
p2_path = OUT / "test_picam2.h264"
try:
    config = cam.create_video_configuration(
        main={"size": (1280, 720), "format": "YUV420"},
        encode="main",
        controls={"FrameRate": 24.0, "FrameDurationLimits": (41666, 41666)}
    )
    cam.configure(config)
    encoder = H264Encoder(bitrate=2500000, framerate=24)
    cam.start_recording(encoder, FileOutput(str(p2_path)))
    print("    Recording 3s...")
    time.sleep(3)
    cam.stop_recording()
    size = p2_path.stat().st_size if p2_path.exists() else 0
    if size > 0:
        print(f"    ✓ picamera2 wrote {size / 1024:.0f} KB")
    else:
        print("    ✗ 0 bytes from picamera2 FileOutput")
        print("\n    >>> libcamera-vid works but picamera2 FileOutput doesn't.")
        print("        Try YUV420 format fix — see output below.")
except Exception as e:
    print(f"    ✗ Exception: {e}")
finally:
    try:
        cam.close()
    except Exception:
        pass

# ── TEST 6: ffmpeg can mux the h264 if we got data ───────────────────────────
if p2_path.exists() and p2_path.stat().st_size > 0:
    print("\n[6] ffmpeg mux to MP4...")
    mp4 = OUT / "test_picam2.mp4"
    r = subprocess.run(
        ["ffmpeg", "-y", "-r", "24", "-i", str(p2_path),
         "-vf", "setpts=N/(24*TB)", "-c:v", "libx264",
         "-preset", "ultrafast", "-crf", "23", "-r", "24",
         "-fps_mode", "cfr", "-an", "-movflags", "+faststart",
         "-loglevel", "error", str(mp4)],
        capture_output=True, text=True
    )
    mp4_size = mp4.stat().st_size if mp4.exists() else 0
    if mp4_size > 0:
        print(f"    ✓ MP4 written: {mp4_size / 1024:.0f} KB")
    else:
        print(f"    ✗ ffmpeg failed: {r.stderr.strip()[:300]}")

print("\n── Summary ─────────────────────────────────────────────")
print(f"   libcamera-vid:  {OUT / 'test_libcam.h264'}")
print(f"   picamera2:      {OUT / 'test_picam2.h264'}")
print(f"   ffmpeg MP4:     {OUT / 'test_picam2.mp4'}")
print("─────────────────────────────────────────────────────────\n")
