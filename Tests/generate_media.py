"""Create small, deterministic playback fixtures without copying personal media."""
from pathlib import Path
import shutil
import subprocess
import wave

ARTIFACTS = Path(__file__).resolve().parent / "Artifacts"


def ensure_playback_media():
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    video = ARTIFACTS / "video-test.mp4"
    ffmpeg = shutil.which("ffmpeg")
    if not video.is_file() and ffmpeg is None:
        raise RuntimeError("Install ffmpeg to generate Tests/Artifacts/video-test.mp4")
    unsupported = ARTIFACTS / "unsupported.txt"
    if not unsupported.is_file():
        unsupported.write_text("Intentionally invalid media for playback error tests.\n", encoding="utf-8")
    for name, seconds in (("short-a.wav", 2), ("short-b.wav", 3), ("persistence-test.wav", 40)):
        path = ARTIFACTS / name
        if path.is_file():
            continue
        with wave.open(str(path), "wb") as output:
            output.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
            for _ in range(seconds):
                output.writeframes(b"\0\0" * 48000)
    if not video.is_file():
        subprocess.run([ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30",
                        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "12",
                        "-af", "volume=0.05", "-c:v", "libx264", "-preset", "veryfast", "-crf", "32", "-g", "30",
                        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "32k", str(video)], check=True)
    return ARTIFACTS


if __name__ == "__main__":
    print(ensure_playback_media())
