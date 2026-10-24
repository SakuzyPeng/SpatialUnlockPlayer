"""Check the exported ad hoc Release app before sharing it."""
from pathlib import Path
import argparse
import plistlib
import subprocess


def check(app):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    binaries = [app / "Contents/MacOS/SpatialUnlockPlayer",
                app / "Contents/Frameworks/libSpatialShim.dylib"]
    for binary in binaries:
        signature = subprocess.run(["/usr/bin/codesign", "-dv", str(binary)], check=True,
                                   capture_output=True, text=True)
        if "Signature=adhoc" not in signature.stderr:
            raise ValueError(f"Expected ad hoc signing: {binary.name}")
        result = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", str(binary)],
                                check=True, capture_output=True)
        entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
        if entitlements.get("com.apple.security.get-task-allow"):
            raise ValueError(f"Debugging entitlement remains: {binary.name}")
        data = binary.read_bytes()
        for marker in (b"/Users/", b"/Volumes/", b"/home/", b"SPATIALUNLOCKPLAYER_TEST_",
                       b"DiagnosticRunner", b"diagnosticQueueSet", b"SpatialRenderCopyNodes",
                       b"SpatialRenderTestFailGainWrites"):
            if marker in data:
                raise ValueError(f"Private build path or diagnostic marker in {binary.name}: {marker!r}")
    if not (app / "Contents/Resources/LICENSE").is_file():
        raise ValueError("The app is missing its MIT license")
    print("PASS: ad hoc Release signatures, no debugging entitlement, build paths or diagnostic hooks, MIT license bundled")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    check(args.app.resolve())
