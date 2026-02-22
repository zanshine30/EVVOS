cat << 'EOF' > fix_shared_audio.sh
#!/bin/bash
# fix_shared_audio.sh
# Patches EVVOS services to share the ReSpeaker microphone using ALSA dsnoop.

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}▶ Stopping EVVOS services...${NC}"
sudo systemctl stop evvos-pico-voice evvos-picam-tcp || true

echo -e "${BLUE}▶ Applying patches for shared audio...${NC}"

# Using Python to safely find and replace exact code blocks
sudo python3 - << 'INLINE_PYTHON'
import os

PICAM_FILE = "/usr/local/bin/evvos-picam-tcp.py"
VOICE_FILE = "/usr/local/bin/evvos-pico-voice-service.py"

# --- 1. PATCH PICOVOICE (Switch to shared ALSA device) ---
if os.path.exists(VOICE_FILE):
    with open(VOICE_FILE, "r") as f:
        voice_code = f.read()

    old_voice_search = """            # First try: Look for 'seeed' in device name
            for i in range(self.pa.get_device_count()):
                info = self.pa.get_device_info_by_index(i)
                if 'seeed' in info['name'].lower():
                    dev_idx = i
                    dev_name = info['name']
                    logger.info(f"Found ReSpeaker device: {dev_name} (index {i})")
                    logger.info(f"  Sample Rate: {int(info['defaultSampleRate'])} Hz")
                    logger.info(f"  Input Channels: {info['maxInputChannels']}")
                    break"""

    new_voice_search = """            # FIX: Prioritize 'default' device to use ALSA dsnoop sharing
            for i in range(self.pa.get_device_count()):
                info = self.pa.get_device_info_by_index(i)
                if info['name'] == 'default':
                    dev_idx = i
                    dev_name = info['name']
                    logger.info(f"Found Shared ALSA device (dsnoop): {dev_name} (index {i})")
                    break
            
            # Fallback: Look for 'seeed' if 'default' isn't found
            if dev_idx is None:
                for i in range(self.pa.get_device_count()):
                    info = self.pa.get_device_info_by_index(i)
                    if 'seeed' in info['name'].lower():
                        dev_idx = i
                        dev_name = info['name']
                        logger.info(f"Fallback to ReSpeaker device: {dev_name} (index {i})")
                        break"""

    if "Found Shared ALSA device" not in voice_code:
        if old_voice_search in voice_code:
            voice_code = voice_code.replace(old_voice_search, new_voice_search)
            with open(VOICE_FILE, "w") as f:
                f.write(voice_code)
            print("✓ PicoVoice patched to use shared microphone.")
        else:
            print("⚠ PicoVoice device search block not found. May already be modified.")
else:
    print(f"⚠ PicoVoice file not found: {VOICE_FILE}")

# --- 2. PATCH PICAM (Add arecord and ffmpeg muxing) ---
if os.path.exists(PICAM_FILE):
    with open(PICAM_FILE, "r") as f:
        picam_code = f.read()

    if "current_audio_path   = None" not in picam_code:
        picam_code = picam_code.replace(
            "current_video_path   = None\nrecording_start_time = None",
            "current_video_path   = None\ncurrent_audio_path   = None\naudio_process        = None\nrecording_start_time = None"
        )

    old_start_global = "global recording, current_session_id, current_video_path, recording_start_time"
    new_start_global = "global recording, current_session_id, current_video_path, current_audio_path, audio_process, recording_start_time"
    picam_code = picam_code.replace(old_start_global, new_start_global)

    old_start_paths = """            current_session_id   = f"session_{ts}"
            current_video_path   = RECORDINGS_DIR / f"video_{ts}.h264"
            recording_start_time = time.time()"""
    new_start_paths = """            current_session_id   = f"session_{ts}"
            current_video_path   = RECORDINGS_DIR / f"video_{ts}.h264"
            current_audio_path   = RECORDINGS_DIR / f"audio_{ts}.wav"
            recording_start_time = time.time()"""
    picam_code = picam_code.replace(old_start_paths, new_start_paths)

    old_start_rec = """            camera.start_recording(encoder, str(current_video_path))
            recording = True"""
    new_start_rec = """            camera.start_recording(encoder, str(current_video_path))
            
            # Start background audio recording using shared ALSA device (dsnoop)
            audio_process = subprocess.Popen([
                "arecord", "-D", "default", "-f", "S16_LE", "-r", "48000", "-c", "2", str(current_audio_path)
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            recording = True"""
    if "arecord" not in picam_code:
        picam_code = picam_code.replace(old_start_rec, new_start_rec)

    old_stop_global = "global recording, current_session_id, current_video_path, recording_start_time"
    new_stop_global = "global recording, current_session_id, current_video_path, current_audio_path, audio_process, recording_start_time"
    picam_code = picam_code.replace(old_stop_global, new_stop_global)

    old_stop_rec = """            camera.stop_recording()
            camera.stop()
            recording            = False"""
    new_stop_rec = """            camera.stop_recording()
            camera.stop()
            
            # Stop audio recording gracefully
            if audio_process:
                audio_process.terminate()
                try:
                    audio_process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    audio_process.kill()
                    
            recording            = False"""
    if "audio_process.terminate()" not in picam_code:
        picam_code = picam_code.replace(old_stop_rec, new_stop_rec)

    old_ffmpeg = """            cmd = [
                "ffmpeg", "-y",
                "-r", "24", "-i", str(current_video_path),
                "-vf", "setpts=N/(24*TB)",
                "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
                "-r", "24", "-fps_mode", "cfr", "-an",
                "-movflags", "+faststart", "-loglevel", "error",
                str(mp4_path)
            ]"""
    new_ffmpeg = """            has_audio = current_audio_path and current_audio_path.exists() and current_audio_path.stat().st_size > 1000
            
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
                "-movflags", "+faststart", "-loglevel", "error",
                str(mp4_path)
            ])"""
    if "has_audio = current_audio_path" not in picam_code:
        picam_code = picam_code.replace(old_ffmpeg, new_ffmpeg)

    old_unlink = "current_video_path.unlink(missing_ok=True)"
    new_unlink = "current_video_path.unlink(missing_ok=True)\n                if current_audio_path:\n                    current_audio_path.unlink(missing_ok=True)"
    if "current_audio_path.unlink" not in picam_code:
        picam_code = picam_code.replace(old_unlink, new_unlink)

    with open(PICAM_FILE, "w") as f:
        f.write(picam_code)
    print("✓ PiCam Service patched to record and mux audio.")
else:
    print(f"⚠ PiCam file not found: {PICAM_FILE}")
INLINE_PYTHON

echo -e "${BLUE}▶ Restarting EVVOS services...${NC}"
sudo systemctl daemon-reload
sudo systemctl start evvos-pico-voice evvos-picam-tcp

echo -e "${GREEN}✓ All done!${NC}"
EOF

chmod +x fix_shared_audio.sh
bash fix_shared_audio.sh
