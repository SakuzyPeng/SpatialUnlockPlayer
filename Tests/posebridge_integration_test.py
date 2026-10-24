"""Run the real PoseBridge OSC sender through the Diagnostics player and Apple mixer."""
from pathlib import Path
import argparse
import array
import json
import math
import os
import socket
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, default=ROOT / "build/Products/Diagnostics/SpatialUnlock Player.app")
parser.add_argument("--posebridge", type=Path, default=ROOT.parents[1] / "rust/PoseBridge/target/release/posebridge")
parser.add_argument("--output", default="BuiltInHeadphoneOutputDevice")
parser.add_argument("--eq", type=Path, help="Also verify spatial EQ while receiving real OSC poses")
parser.add_argument("--headroom", type=float, help="Also verify advanced processing headroom during real OSC poses")
args = parser.parse_args()
binary = args.app / "Contents/MacOS/SpatialUnlockPlayer"
artifacts = ROOT / ("Tests/Artifacts/posebridge-integration-advanced" if args.headroom is not None else
                    "Tests/Artifacts/posebridge-integration-eq" if args.eq else "Tests/Artifacts/posebridge-integration")
artifacts.mkdir(parents=True, exist_ok=True)

def tone():
    existing = ROOT / "Tests/Artifacts/posebridge-integration/center-5.1.wav"
    if args.eq and existing.exists():
        return existing
    path = artifacts / "center-5.1.wav"
    sr = 48000
    block = array.array("h")
    for i in range(sr):
        sample = round(32767 * .045 * sum(math.sin(2 * math.pi * f * i / sr) for f in [900, 1800, 2700]))
        block.extend([0, 0, sample, 0, 0, 0])
    if __import__("sys").byteorder != "little":
        block.byteswap()
    guid = struct.pack("<IHH8s", 1, 0, 0x10, b"\x80\x00\x00\xaa\x00\x38\x9b\x71")
    fmt = struct.pack("<HHIIHHHHI", 0xfffe, 6, sr, sr * 12, 12, 16, 22, 16, 0x3f) + guid
    payload_size = len(block) * 2 * 14
    with path.open("wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + payload_size) + b"WAVE")
        f.write(b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", payload_size))
        for _ in range(14):
            f.write(block.tobytes())
    return path

def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

def terminate(p):
    if p is not None and p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(timeout=5)

def run(name, steps, port, fmt=None):
    script = artifacts / (name + ".json")
    result = artifacts / (name + "-result.json")
    log = artifacts / (name + ".log")
    result.unlink(missing_ok=True)
    script.write_text(json.dumps(steps, indent=2))
    env = os.environ.copy()
    for key in ["DYLD_INSERT_LIBRARIES", "SPATIALUNLOCKPLAYER_TEST_KEEP_OPEN", "SPATIALUNLOCKPLAYER_TEST_RESTORE_SESSION"]:
        env.pop(key, None)
    env["SPATIALUNLOCKPLAYER_TEST_SCRIPT"] = str(script)
    env["SPATIALUNLOCKPLAYER_TEST_RESULT"] = str(result)
    sender = player = None
    with log.open("w") as output, (artifacts / (name + "-sender.log")).open("w") as sender_log:
        try:
            player = subprocess.Popen([str(binary)], env=env, stdout=output, stderr=subprocess.STDOUT)
            if fmt:
                deadline = time.monotonic() + 8
                while '"poseListening":true' not in log.read_text():
                    if player.poll() is not None or time.monotonic() >= deadline:
                        raise AssertionError("Receiver did not start: " + log.read_text()[-3000:])
                    time.sleep(.05)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as bad:
                    bad.sendto(b"not-osc", ("127.0.0.1", port))
                    bad.sendto(b"x" * 8193, ("127.0.0.1", port))
                sender = subprocess.Popen([str(args.posebridge), "simulate", "--source-id", "spatial-test",
                    "--pattern", "yaw", "--sample-rate-hz", "100", "--osc-rate-hz", "100",
                    "--format", fmt, "--sample-clock", "--duration", "6",
                    "--osc-target", f"127.0.0.1:{port}", "--json"], stdout=sender_log, stderr=subprocess.STDOUT)
            player.wait(timeout=25)
            if sender is not None:
                sender.wait(timeout=10)
                assert sender.returncode == 0, "PoseBridge sender failed"
            assert result.exists(), "No diagnostic result: " + log.read_text()[-3000:]
            report = json.loads(result.read_text())
            assert report["passed"], report["failure"] + "\n" + log.read_text()[-3000:]
            assert report["injectedLibraries"] == "", "Must use normally linked shipping shim"
            states = [s["state"] for s in report["steps"]]
            print(f"PASS {name}: {len(steps)} steps, {max(s['poseAccepted'] for s in states)} received, "
                  f"{max(s['poseApplied'] for s in states)} applied, {max(s['poseFailures'] for s in states)} renderer errors", flush=True)
            return report
        finally:
            terminate(sender)
            terminate(player)

media = tone()
reports = []
for fmt in ["quaternion", "euler"]:
    port = free_port()
    steps = [
        {"action": "poseStart", "port": port, "source": "spatial-test"},
        {"action": "wait", "seconds": .3},
        {"action": "assert", "expect": {"poseListening": True, "hasPoseError": False}},
        {"action": "output", "value": args.output},
        {"action": "volume", "value": .02},
        {"action": "mode", "value": "headphones"},
        {"action": "add", "paths": [str(media)]},
        {"action": "awaitReady"},
        {"action": "awaitPose"},
        {"action": "awaitPoseApplied", "minimum": 10},
        {"action": "assert", "expect": {"poseFresh": True, "poseSource": "spatial-test", "poseEnabled": True,
            "poseFailures": 0, "poseInvalid": 2, "minPoseAccepted": 2, "minPoseRenderCallbacks": 2}},
        {"action": "poseRecenter"},
        {"action": "wait", "seconds": .2},
        {"action": "assert", "expect": {"minPoseRecenters": 1}},
        {"action": "mode", "value": "off"},
        {"action": "awaitReady"},
        {"action": "assert", "expect": {"poseEnabled": False, "poseListening": True}},
        {"action": "mode", "value": "headphones"},
        {"action": "awaitReady"},
        {"action": "awaitPoseApplied", "minimum": 20},
        {"action": "poseStop"},
        {"action": "wait", "seconds": .2},
        {"action": "assert", "expect": {"poseEnabled": False, "poseListening": False, "minPoseRestored": 1}},
        # Immediate same-port restart exercises dispatch-source cancellation ordering.
        {"action": "poseStart", "port": port, "source": "spatial-test"},
        {"action": "awaitPose"},
        {"action": "assert", "expect": {"poseFresh": True, "poseFailures": 0}},
        {"action": "awaitPoseStale", "timeout": 12},
        {"action": "assert", "expect": {"poseFresh": False, "poseEnabled": True, "poseFailures": 0}},
        {"action": "poseStop"},
        {"action": "clear"}
    ]
    if args.eq:
        steps.insert(0, {"action": "eqImport", "path": str(args.eq.resolve())})
        for step in steps:
            if step.get("action") == "assert" and step.get("expect", {}).get("poseFresh") is True:
                step["expect"].update(eqApplied=True, eqError=0)
            if step.get("action") == "assert" and step.get("expect", {}).get("poseListening") is False and step.get("expect", {}).get("minPoseRestored"):
                step["expect"].update(eqApplied=True, eqError=0)
    if args.headroom is not None:
        steps.insert(5, {"action": "advancedHeadroomDB", "value": args.headroom})
        for step in steps:
            if step.get("action") == "assert" and (step.get("expect", {}).get("poseFresh") is True or
                    step.get("expect", {}).get("minPoseRestored")):
                step["expect"].update(advancedHeadroomState=2, advancedHeadroomError=0)
    reports.append(run(fmt, steps, port, fmt))

with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as occupied:
    occupied.bind(("127.0.0.1", 0))
    port = occupied.getsockname()[1]
    run("port-conflict", [
        {"action": "poseStart", "port": port},
        {"action": "wait", "seconds": .3},
        {"action": "assert", "expect": {"poseListening": False, "poseEnabled": False, "hasPoseError": True}},
        {"action": "poseStop"}
    ], port)
print("PASS: real OSC 3 sender -> receiver -> Apple render callback; both formats, malformed datagrams, recenter, mode changes, same-port restart, stale/stop and bind failure")
