#!/usr/bin/env python3
"""Exercise saved sessions across real diagnostic app launches, with isolated preferences."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "Tests/Artifacts"
APP = ROOT / "SpatialPlayer.app/Contents/MacOS/SpatialPlayer"
DOMAIN = "local.sakuzy.SpatialPlayer.Regression"
VIDEO = ARTIFACTS / "video-test.mp4"
APAC = Path("Tests/Artifacts/persistence-test.m4a")
MISSING = ARTIFACTS / "persistence-removable.wav"
OFFLINE = MISSING.with_suffix(".offline")


def state():
    exported = subprocess.check_output(["/usr/bin/defaults", "export", DOMAIN, "-"])
    prefs = plistlib.loads(exported)
    return json.loads(prefs["playbackSession"]) if "playbackSession" in prefs else None


def run(name, steps, restore=True):
    script = ARTIFACTS / f"persistence-{name}.json"
    result = ARTIFACTS / f"persistence-{name}-result.json"
    script.write_text(json.dumps(steps, ensure_ascii=False, indent=2))
    result.unlink(missing_ok=True)
    env = os.environ.copy()
    env.pop("DYLD_INSERT_LIBRARIES", None)
    env.pop("SPATIALPLAYER_TEST_KEEP_OPEN", None)
    env.update(SPATIALPLAYER_TEST_SCRIPT=str(script), SPATIALPLAYER_TEST_RESULT=str(result),
               SPATIALPLAYER_TEST_RESTORE_SESSION="1" if restore else "0")
    with (ARTIFACTS / f"persistence-{name}.log").open("w") as log:
        subprocess.run([str(APP)], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=45, check=True)
    report = json.loads(result.read_text())
    assert report["passed"], report["failure"]
    print(f"PASS {name}: {len(report['steps'])} steps", flush=True)
    return state()


def check(**expect):
    return {"action": "assert", "expect": expect}


def ready():
    return {"action": "awaitReady"}


assert VIDEO.is_file() and APAC.is_file(), "Build the existing media fixtures first."
shutil.copyfile(ARTIFACTS / "short-a.wav", MISSING)
try:
    first = run("save", [
        {"action": "output", "value": "BuiltInHeadphoneOutputDevice"},
        {"action": "volume", "value": 0},
        {"action": "add", "paths": list(map(str, [VIDEO, APAC, VIDEO, MISSING]))},
        {"action": "select", "index": 1, "autoplay": False}, ready(),
        {"action": "seek", "value": 30}, ready(),
        check(playlistCount=4, wantsToPlay=False, playing=False, minPosition=29.9, maxPosition=30.1),
    ], restore=False)
    assert len(first["entries"]) == 4
    assert len({entry["id"] for entry in first["entries"]}) == 4
    assert first["entries"][0]["url"] == first["entries"][2]["url"], "Duplicate files must survive."
    assert first["currentID"] == first["entries"][1]["id"]
    MISSING.replace(OFFLINE)

    removed = run("restore-remove", [
        ready(), {"action": "wait", "seconds": 0.5},
        check(playlistCount=4, fileContains=APAC.name, wantsToPlay=False, playing=False,
              minPosition=29.9, maxPosition=30.1),
        {"action": "remove", "indices": [0]}, check(playlistCount=3),
    ])
    assert [entry["id"] for entry in removed["entries"]] == [entry["id"] for entry in first["entries"][1:]]
    assert removed["currentID"] == first["currentID"]

    unavailable = run("missing", [
        ready(), check(playlistCount=3),
        {"action": "select", "index": 2, "autoplay": False},
        {"action": "awaitError"}, check(playlistCount=3, wantsToPlay=False, playing=False, hasError=True),
    ])
    assert unavailable["currentID"] == removed["entries"][2]["id"]

    switched = run("missing-recover", [
        {"action": "awaitError"}, check(playlistCount=3, wantsToPlay=False, playing=False),
        {"action": "select", "index": 1, "autoplay": False}, ready(),
        {"action": "seek", "value": 6}, ready(),
        check(playlistCount=3, fileContains=VIDEO.name, minPosition=5.9, maxPosition=6.1, wantsToPlay=False),
    ])
    assert switched["currentID"] == removed["entries"][1]["id"]

    cleared = run("clear", [
        ready(), check(playlistCount=3, fileContains=VIDEO.name, minPosition=5.9, maxPosition=6.1,
                       wantsToPlay=False, playing=False),
        {"action": "clear"}, check(playlistCount=0),
    ])
    assert cleared is None
    assert run("empty", [check(playlistCount=0, ready=False, wantsToPlay=False, playing=False)]) is None
finally:
    MISSING.unlink(missing_ok=True)
    OFFLINE.unlink(missing_ok=True)
