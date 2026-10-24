"""Production EQ through AVPlayer/HAL, plus the actual application's state machine."""
from pathlib import Path
import argparse
import json
import math
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / "Tests/Artifacts/equalizer"
ART.mkdir(parents=True, exist_ok=True)
parser = argparse.ArgumentParser()
parser.add_argument("--app-only", action="store_true", help="Recheck app state/persistence without repeating HAL measurements")
parser.add_argument("--eq", type=Path, default=ROOT / "Tests/Fixtures/Sony MDR-MV1 ParametricEq.txt",
                    help="Path to a copy of the Sony MDR-MV1 AutoEq test fixture")
parser.add_argument("--output", default="BuiltInHeadphoneOutputDevice", help="UID of the stereo output under test")
args = parser.parse_args()
if not args.eq.is_file():
    parser.error("The --eq file does not exist")
env = dict(os.environ)
env.pop("DYLD_INSERT_LIBRARIES", None)
env["SPATIALEQ_PROBE_PRESET"] = str(ART / "sony-normalized.json")
if not args.app_only:
    subprocess.run(["zsh", "Tests/eq_probe_build.sh"], cwd=ROOT, check=True)
preset = json.loads((ART / "sony-normalized.json").read_text())


def response(frequency, rate=48000):
    value = 10 ** (preset["preamp"] / 20)
    for f in preset["filters"]:
        if not f["enabled"]:
            continue
        s = 1j * math.tan(math.pi * frequency / rate) / math.tan(math.pi * f["frequency"] / rate)
        a, q = 10 ** (f["gain"] / 40), f["q"]
        if f["type"] == "PK":
            value *= (s*s + a/q*s + 1) / (s*s + s/(a*q) + 1)
        elif f["type"] == "LSC":
            value *= a * (s*s + math.sqrt(a)/q*s + a) / (a*s*s + math.sqrt(a)/q*s + 1)
        else:
            value *= a * (a*s*s + math.sqrt(a)/q*s + 1) / (s*s + math.sqrt(a)/q*s + a)
    return 20 * math.log10(abs(value))


media = {"pcm51": ROOT / "Tests/Artifacts/posebridge-integration/center-5.1.wav",
         "stereo": ROOT / "Tests/Artifacts/eq-probe/tones-2ch.wav"}
for scenario in ("smoke", "regression"):
    path = ROOT / f"Tests/Artifacts/{scenario}.json"
    if not path.exists():
        continue
    for step in json.loads(path.read_text()):
        for name in step.get("paths", []):
            path = Path(name)
            key = "apac24" if "APAC_24ch" in path.name else "apac16" if path.name.startswith("APAC -") else "atmos" if "Dolby Atmos" in path.name else None
            if key and path.is_file():
                media[key] = path

previous = ART / "playback-result.json"
results = json.loads(previous.read_text()).get("cases", {}) if args.app_only and previous.exists() else {}
for name, path in (media.items() if not args.app_only else []):
    if not path.exists():
        raise RuntimeError("Generate the existing PCM fixtures with Tests/eq_probe_test.py first")
    for mode in (["on", "off"] if name in ("pcm51", "stereo") else ["on"]):
        key = name + "-" + mode + "-production-sony"
        destination = ART / (key + ".json")
        with (ART / (key + ".log")).open("w") as log:
            subprocess.run([str(ROOT / "build/tests/eq-probe/eq-probe"), str(path), args.output, mode,
                "production-sony", "30" if name in ("apac16", "apac24", "atmos") else "0", str(destination)],
                cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=30, check=True)
        report = json.loads(destination.read_text())
        assert report["ready"] and not report["error"] and not report["poseErrors"]
        eq = report["productionEQ"]
        hal = [r for r in report["records"] if r["kind"] == "hal-output" and r["callbacks"] > 100]
        assert hal
        if mode == "on":
            assert eq["active"] and eq["buffers"] > 100 and eq["error"] == 0
            assert eq["minFrames"] == eq["maxFrames"] == 512 and report["poseApplied"] >= 2
        else:
            assert eq["active"] == eq["buffers"] == 0
        if name in ("pcm51", "stereo"):
            phases = hal[-1]["phases"]
            for phase in (1, 2):
                for ch in range(2):
                    for k, frequency in enumerate((900, 1800, 2700)):
                        before, after = phases[0]["before"]["toneAmplitudes"][ch][k], phases[phase]["before"]["toneAmplitudes"][ch][k]
                        measured = 20 * math.log10(after / before)
                        expected = (20 * math.log10(.5) if phase == 1 else response(frequency)) if mode == "on" else 0
                        assert abs(measured - expected) < .1, (key, phase, frequency, measured, expected)
        results[key] = {"passed": True, "productionEQ": eq, "poseApplied": report["poseApplied"]}
        print("PASS", key, eq, flush=True)

binary = ROOT / "build/Products/Diagnostics/SpatialUnlock Player.app/Contents/MacOS/SpatialUnlockPlayer"
bad = ART / "invalid.txt"
bad.write_text("Filter 1: ON UNKNOWN Fc 100 Hz Gain 1 dB Q 1\n")
sony = args.eq.resolve()


def app_case(name, steps, restore=False):
    script, result = ART / (name + ".json"), ART / (name + "-result.json")
    script.write_text(json.dumps(steps, indent=2))
    result.unlink(missing_ok=True)
    settings = dict(env, SPATIALUNLOCKPLAYER_TEST_SCRIPT=str(script), SPATIALUNLOCKPLAYER_TEST_RESULT=str(result))
    settings.pop("SPATIALUNLOCKPLAYER_TEST_KEEP_OPEN", None)
    settings.pop("SPATIALUNLOCKPLAYER_TEST_RESTORE_SESSION", None)
    if restore:
        settings["SPATIALUNLOCKPLAYER_TEST_RESTORE_SESSION"] = "1"
    with (ART / (name + ".log")).open("w") as log:
        subprocess.run([str(binary)], cwd=ROOT, env=settings, stdout=log, stderr=subprocess.STDOUT, timeout=75, check=True)
    report = json.loads(result.read_text())
    assert report["passed"], (name, report["failure"])
    assert not report["injectedLibraries"]
    print("PASS", name, len(report["steps"]), "application steps", flush=True)
    return report


app_case("app-eq-transitions", [
    {"action": "output", "value": args.output},
    {"action": "mode", "value": "headphones"}, {"action": "volume", "value": .02},
    {"action": "eqImport", "path": str(sony)},
    {"action": "assert", "expect": {"eqEnabled": True, "eqFilterCount": 10, "eqPreamp": -3.12}},
    {"action": "add", "paths": [str(media["pcm51"]), str(media["pcm51"])]}, {"action": "awaitReady"},
    {"action": "awaitState", "expect": {"eqApplied": True, "eqError": 0, "eqMinFrames": 512, "eqMaxFrames": 512}},
    {"action": "eqImport", "path": str(bad), "expectFailure": True},
    {"action": "assert", "expect": {"eqFilterCount": 10, "eqPreamp": -3.12}},
    {"action": "eqEnabled", "value": False}, {"action": "assert", "expect": {"eqEnabled": False, "eqApplied": False}},
    {"action": "eqEnabled", "value": True}, {"action": "awaitState", "expect": {"eqApplied": True}},
    {"action": "pause"}, {"action": "seek", "value": 4}, {"action": "awaitReady"}, {"action": "play"},
    {"action": "awaitState", "expect": {"eqApplied": True, "eqError": 0}},
    {"action": "next"}, {"action": "awaitReady"}, {"action": "awaitState", "expect": {"eqApplied": True}},
    {"action": "previous"}, {"action": "awaitReady"},
    {"action": "mode", "value": "off"}, {"action": "awaitReady"},
    {"action": "assert", "expect": {"eqEnabled": True, "eqApplied": False}},
    {"action": "mode", "value": "headphones"}, {"action": "awaitReady"},
    {"action": "awaitState", "expect": {"eqApplied": True, "eqError": 0}},
    {"action": "deviceMissing", "value": args.output},
    {"action": "assert", "expect": {"playing": False, "eqApplied": False}},
    {"action": "refreshDevices"}, {"action": "awaitReady"}, {"action": "play"},
    {"action": "awaitState", "expect": {"eqApplied": True, "eqError": 0}}, {"action": "pause"}
])
app_case("app-eq-restore", [
    {"action": "awaitReady"},
    {"action": "assert", "expect": {"eqEnabled": True, "eqFilterCount": 10, "eqPreamp": -3.12, "playing": False}},
    {"action": "play"}, {"action": "awaitState", "expect": {"eqApplied": True, "eqError": 0}},
    {"action": "eqEnabled", "value": False}, {"action": "pause"}
], restore=True)
app_case("app-eq-restore-disabled", [
    {"action": "awaitReady"},
    {"action": "assert", "expect": {"eqEnabled": False, "eqApplied": False, "eqFilterCount": 10, "playing": False}}
], restore=True)
(ART / "playback-result.json").write_text(json.dumps({"passed": True, "cases": results}, indent=2))
