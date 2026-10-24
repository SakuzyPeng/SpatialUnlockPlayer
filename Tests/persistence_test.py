#!/usr/bin/env python3
"""Exercise saved sessions across real diagnostic app launches, with isolated preferences."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "Tests/Artifacts"
APP = ROOT / "SpatialUnlock Player.app/Contents/MacOS/SpatialUnlockPlayer"
DOMAIN = "local.sakuzy.SpatialUnlockPlayer.Regression"
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
    env.pop("SPATIALUNLOCKPLAYER_TEST_KEEP_OPEN", None)
    env.update(SPATIALUNLOCKPLAYER_TEST_SCRIPT=str(script), SPATIALUNLOCKPLAYER_TEST_RESULT=str(result),
               SPATIALUNLOCKPLAYER_TEST_RESTORE_SESSION="1" if restore else "0")
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


def entries(session, index=0):
    return session["playlists"][index]["entries"]


def main():
    assert VIDEO.is_file() and APAC.is_file(), "Build the existing media fixtures first."
    shutil.copyfile(ARTIFACTS / "short-a.wav", MISSING)
    try:
        exercise()
    finally:
        MISSING.unlink(missing_ok=True)
        OFFLINE.unlink(missing_ok=True)


def exercise():
    legacy_entries = [dict(id=str(uuid.uuid4()), url=VIDEO.as_uri(), title="视频") for _ in range(2)]
    legacy = dict(version=1, entries=legacy_entries, currentID=legacy_entries[1]["id"], position=6)
    subprocess.run(["/usr/bin/defaults", "import", DOMAIN, "-"],
                   input=plistlib.dumps({"playbackSession": json.dumps(legacy).encode(), "volume": 0}), check=True)
    migrated = run("v1-migration", [ready(), check(listCount=1, playlistCount=2, browsedPlaylistName="默认列表",
                    wantsToPlay=False, playing=False, minPosition=5.9, maxPosition=6.1)])
    assert migrated["version"] == 2
    assert [e["id"].lower() for e in entries(migrated)] == [e["id"] for e in legacy_entries]
    assert migrated["currentID"].lower() == legacy["currentID"]

    first = run("save", [
        {"action": "output", "value": "BuiltInHeadphoneOutputDevice"},
        {"action": "volume", "value": 0},
        {"action": "add", "paths": list(map(str, [VIDEO, APAC, VIDEO, MISSING]))},
        {"action": "select", "index": 1, "autoplay": False}, ready(),
        {"action": "seek", "value": 30}, ready(),
        check(playlistCount=4, wantsToPlay=False, playing=False, minPosition=29.9, maxPosition=30.1),
    ], restore=False)
    assert len(entries(first)) == 4
    assert len({entry["id"] for entry in entries(first)}) == 4
    assert entries(first)[0]["url"] == entries(first)[2]["url"], "Duplicate files must survive."
    assert first["currentID"] == entries(first)[1]["id"]
    MISSING.replace(OFFLINE)

    removed = run("restore-remove", [
        ready(), {"action": "wait", "seconds": 0.5},
        check(playlistCount=4, fileContains=APAC.name, wantsToPlay=False, playing=False,
              minPosition=29.9, maxPosition=30.1),
        {"action": "remove", "indices": [0]}, check(playlistCount=3),
    ])
    assert [entry["id"] for entry in entries(removed)] == [entry["id"] for entry in entries(first)[1:]]
    assert removed["currentID"] == first["currentID"]

    unavailable = run("missing", [
        ready(), check(playlistCount=3),
        {"action": "select", "index": 2, "autoplay": False},
        {"action": "awaitError"}, check(playlistCount=3, wantsToPlay=False, playing=False, hasError=True),
    ])
    assert unavailable["currentID"] == entries(removed)[2]["id"]

    switched = run("missing-recover", [
        {"action": "awaitError"}, check(playlistCount=3, wantsToPlay=False, playing=False),
        {"action": "select", "index": 1, "autoplay": False}, ready(),
        {"action": "seek", "value": 6}, ready(),
        check(playlistCount=3, fileContains=VIDEO.name, minPosition=5.9, maxPosition=6.1, wantsToPlay=False),
    ])
    assert switched["currentID"] == entries(removed)[1]["id"]

    cleared = run("clear", [
        ready(), check(playlistCount=3, fileContains=VIDEO.name, minPosition=5.9, maxPosition=6.1,
                       wantsToPlay=False, playing=False),
        {"action": "clear"}, check(playlistCount=0),
    ])
    assert entries(cleared) == [] and cleared.get("currentID") is None
    empty = run("empty", [check(playlistCount=0, ready=False, wantsToPlay=False, playing=False)])
    assert empty["playlists"] == cleared["playlists"]

    multiple = run("multiple-save", [
        {"action": "createPlaylist", "name": "音乐"},
        {"action": "add", "paths": [str(VIDEO), str(APAC)]},
        {"action": "select", "index": 1, "autoplay": False}, ready(),
        {"action": "seek", "value": 12}, ready(),
        {"action": "playbackMode", "value": "shuffle"},
        {"action": "createPlaylist", "name": "待整理"},
        {"action": "renamePlaylist", "name": "稍后播放"},
        check(listCount=3, playlistCount=0, playingPlaylistName="音乐", playbackMode="shuffle", wantsToPlay=False),
    ])
    restored = run("multiple-restore", [
        ready(), check(listCount=3, playlistCount=0, playingPlaylistCount=2,
            browsedPlaylistName="稍后播放", playingPlaylistName="音乐", playbackMode="shuffle",
            wantsToPlay=False, playing=False, minPosition=11.9, maxPosition=12.1, canGoPrevious=False),
    ])
    assert restored["playlists"] == multiple["playlists"]
    assert restored["currentID"] == multiple["currentID"]
    assert restored["browsedPlaylistID"] == multiple["browsedPlaylistID"]
    last = run("delete-lists", [
        ready(), {"action": "deletePlaylist"}, check(listCount=2, playingPlaylistName="音乐"),
        {"action": "deletePlaylist"}, check(listCount=1, playingPlaylistName="", ready=False, wantsToPlay=False),
        {"action": "deletePlaylist"}, check(listCount=1, playlistCount=0, browsedPlaylistName="默认列表"),
    ])
    assert len(last["playlists"]) == 1 and entries(last) == []
    run("last-empty-restore", [check(listCount=1, playlistCount=0, browsedPlaylistName="默认列表",
        playbackMode="shuffle", wantsToPlay=False, playing=False)])


if __name__ == "__main__":
    main()
