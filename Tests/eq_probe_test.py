"""Research probe: same AVPlayer routing + shipping shim, no app/preferences edits.

Captures numeric spectra only, never stores user media or microphone input.
The optional local APAC/Atmos inputs come from existing regression scenario files.
"""
from pathlib import Path
import argparse
import array
import json
import math
import os
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "Tests/Artifacts/eq-probe"
parser = argparse.ArgumentParser()
parser.add_argument("--output", default="BuiltInHeadphoneOutputDevice")
parser.add_argument("--only", nargs="*", help="Run selected named cases")
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--analyze-only", action="store_true", help="Validate and summarize existing reports without playback")
args = parser.parse_args()
ARTIFACTS.mkdir(parents=True, exist_ok=True)
if not args.skip_build and not args.analyze_only:
    subprocess.run(["zsh", "Tests/eq_probe_build.sh"], cwd=ROOT, check=True)


def tone(channels):
    existing = ROOT / "Tests/Artifacts/posebridge-integration/center-5.1.wav"
    if channels == 6 and existing.exists():
        return existing
    path = ARTIFACTS / f"tones-{channels}ch.wav"
    if path.exists():
        return path
    rate = 48000
    block = array.array("h")
    for i in range(rate):
        sample = round(32767 * .045 * sum(math.sin(2 * math.pi * f * i / rate) for f in (900, 1800, 2700)))
        block.extend([sample, sample] if channels == 2 else [0, 0, sample, 0, 0, 0])
    if __import__("sys").byteorder != "little":
        block.byteswap()
    guid = struct.pack("<IHH8s", 1, 0, 0x10, b"\x80\x00\x00\xaa\x00\x38\x9b\x71")
    fmt = struct.pack("<HHIIHHHHI", 0xfffe, channels, rate, rate * channels * 2,
                      channels * 2, 16, 22, 16, 3 if channels == 2 else 0x3f) + guid
    payload = len(block) * 2 * 8
    with path.open("wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + payload) + b"WAVE")
        f.write(b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", payload))
        for _ in range(8):
            f.write(block.tobytes())
    return path


def local_media():
    files = {}
    for scenario in ("smoke", "regression"):
        source = ROOT / f"Tests/Artifacts/{scenario}.json"
        if not source.exists():
            continue
        for step in json.loads(source.read_text()):
            for name in step.get("paths", []):
                path = Path(name)
                key = "apac24" if "APAC_24ch" in path.name else "apac16" if path.name.startswith("APAC -") else "atmos" if "Dolby Atmos" in path.name else None
                if key and path.is_file():
                    files[key] = path
    return files


def db(a, b):
    return 20 * math.log10(a / b) if a > 0 and b > 0 else None


def summary(report, stationary):
    active = [r for r in report["records"] if r["callbacks"]]
    spatial = [r for r in active if r["kind"] == "spatial-postrender"]
    hal = [r for r in active if r["kind"] == "hal-output"]
    taps = [r for r in active if r["kind"] == "avplayer-tap"]
    compact = {k: report[k] for k in ("ready", "error", "position", "poseErrors", "poseApplied", "tapError", "tapCalls")}
    compact["stages"] = [{k: r[k] for k in ("kind", "sampleRate", "channels", "bits", "bufferChannels", "callbacks", "unsupported", "errors", "renderReturns", "matchingReturns")} for r in active]
    compact["spatialMixerPresent"] = bool(spatial)
    compact["halObserved"] = bool(hal)
    compact["stationaryTestSignal"] = stationary
    for label, candidates in (("spatial", spatial), ("tap", taps)):
        if candidates:
            r = candidates[-1]
            before = r["phases"][1]["before"]["rms"]
            after = r["phases"][1]["after"]["rms"]
            compact[label + "GainDB"] = [db(a, b) for a, b in zip(after, before)]
            if stationary:
                compact[label + "EQ1800DB"] = [db(a[1], b[1]) for a, b in zip(r["phases"][2]["after"]["toneAmplitudes"], r["phases"][2]["before"]["toneAmplitudes"])]
    if hal and stationary:
        r = hal[-1]
        compact["halGainDB"] = [db(a, b) for a, b in zip(r["phases"][1]["before"]["rms"], r["phases"][0]["before"]["rms"])]
        compact["halToneDeltaDB"] = [[db(a, b) for a, b in zip(ch, base)] for ch, base in zip(r["phases"][2]["before"]["toneAmplitudes"], r["phases"][0]["before"]["toneAmplitudes"])]
    return compact


def verify(report, name, mode, method):
    """Assert measured transport/DSP results, not a mirror of the filter code."""
    if mode == "off" and name in ("apac16", "apac24"):
        assert "1718449215" in report["error"], "Expected existing native APAC-off format limitation"
        return "expected-native-format-error"
    assert report["ready"] and not report["error"] and not report["poseErrors"] and not report["tapError"], "Playback/pose/tap failure"
    active = [r for r in report["records"] if r["callbacks"]]
    assert any(r["kind"] == "hal-output" and r["callbacks"] > 100 for r in active), "No independent HAL observation"
    spatial = [r for r in active if r["kind"] == "spatial-postrender"]
    if method == "notify":
        assert bool(spatial) == (mode == "on"), "Unexpected spatial route coverage"
        if mode == "on":
            r = spatial[-1]
            assert r["channels"] == 2 and r["bits"] == 32 and r["unsupported"] == r["errors"] == 0
            assert r["renderReturns"] > 100 and r["matchingReturns"] == r["renderReturns"], "Modified output did not survive render return"
            assert report["poseApplied"] >= 2, "External pose did not update with DSP active"
            for a, b in zip(r["phases"][1]["after"]["rms"], r["phases"][1]["before"]["rms"]):
                assert abs(db(a, b) + 6.020599913) < .001, "Wrong in-place attenuation"
            if name in ("pcm51", "stereo"):
                s = summary(report, True)
                assert all(abs(v + 12) < .1 for v in s["spatialEQ1800DB"]), "Wrong peaking response"
                assert all(abs(v + 6.020599913) < .1 for v in s["halGainDB"]), "HAL did not receive attenuation"
                assert all(abs(ch[1] + 12) < .1 for ch in s["halToneDeltaDB"]), "HAL did not receive EQ"
                if name == "pcm51":
                    phases = r["phases"]
                    ild = lambda p, stage: db(phases[p][stage]["toneAmplitudes"][0][1], phases[p][stage]["toneAmplitudes"][1][1])
                    assert abs(ild(3, "before") - ild(0, "before")) > 3, "Head rotation did not change binaural output"
                    assert abs(ild(3, "after") - ild(3, "before")) < .1, "Identical ear EQ altered the measured level difference"
        return "verified"
    taps = [r for r in active if r["kind"] == "avplayer-tap"]
    assert taps, "No tap callback"
    if method == "tap-mix":
        r = taps[-1]
        assert r["channels"] == 2 and r["unsupported"] == r["errors"] == 0
        assert all(p["before"]["frames"] > 10000 for p in r["phases"]), "Tap stopped receiving source data"
        for a, b in zip(r["phases"][1]["after"]["rms"], r["phases"][1]["before"]["rms"]):
            assert abs(db(a, b) + 6.020599913) < .001
        if mode == "on":
            assert spatial and report["poseApplied"] >= 2
            # Equal windows let us locate the tap relative to the spatial unit
            # and AVPlayer's .02 volume without assuming that "stereo" means post-spatial.
            aligned = [(a["before"], b["before"]) for a, b in zip(r["phases"], spatial[-1]["phases"])
                       if a["before"]["frames"] == b["before"]["frames"] and a["before"]["frames"] > 10000]
            assert len(aligned) >= 2, "Cannot establish tap/spatial ordering"
            for tap, mixer in aligned:
                assert all(abs(db(a, b) - 20 * math.log10(.02)) < .001 for a, b in zip(tap["rms"], mixer["rms"])), "Tap input differs from spatial output scaled by player volume"
        if name in ("pcm51", "stereo"):
            s = summary(report, True)
            assert all(abs(v + 6.020599913) < .1 for v in s["halGainDB"]), "Mixed tap gain did not reach HAL"
            assert all(abs(ch[1] + 12) < .1 for ch in s["halToneDeltaDB"]), "Mixed tap EQ did not reach HAL"
        return "verified-current-run-requires-head-tracking-latency-review"
    if name == "stereo" and mode == "off" and method == "tap-post":
        s = summary(report, True)
        assert all(abs(v + 6.020599913) < .1 for v in s["halGainDB"])
        assert all(abs(ch[1] + 12) < .1 for ch in s["halToneDeltaDB"])
        return "verified"
    return "format-and-route-observed"


media = {"pcm51": tone(6), "stereo": tone(2), **local_media()}
cases = [(name, mode, "notify") for name in media for mode in ("on", "off")]
cases += [(name, "on", method) for name in ("pcm51", "apac16", "apac24", "atmos") if name in media for method in ("tap-post", "tap-mix")]
cases += [("pcm51", "on", "tap-pre"), ("stereo", "off", "tap-post"), ("pcm51", "off", "tap-post")]
cases += [("pcm51", "off", "tap-mix"), ("stereo", "off", "tap-mix")]
results = {}
env = dict(os.environ)
env.pop("DYLD_INSERT_LIBRARIES", None)
for name, mode, method in cases:
    key = f"{name}-{mode}-{method}"
    if args.only and key not in args.only:
        continue
    destination = ARTIFACTS / f"{key}.json"
    if args.analyze_only and not destination.exists():
        continue
    if not args.analyze_only:
        destination.unlink(missing_ok=True)
        with (ARTIFACTS / f"{key}.log").open("w") as log:
            result = subprocess.run([str(ROOT / "build/tests/eq-probe/eq-probe"), str(media[name]), args.output,
                mode, method, "30" if name in ("apac16", "apac24", "atmos") else "0", str(destination)],
                cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=30)
    if not destination.exists():
        raise RuntimeError(f"{key} produced no report: {(ARTIFACTS / (key + '.log')).read_text()}")
    report = json.loads(destination.read_text())
    results[key] = summary(report, name in ("pcm51", "stereo"))
    results[key]["validation"] = verify(report, name, mode, method)
    print(key, json.dumps(results[key], ensure_ascii=False), flush=True)

summary_path = ARTIFACTS / "summary.json"
previous = json.loads(summary_path.read_text()) if summary_path.exists() else {}
previous.update(results)
summary_path.write_text(json.dumps(previous, indent=2, ensure_ascii=False))
