#!/usr/bin/env python3
"""Real AVPlayer completion, list ownership, asynchronous import, and shuffle history."""
import json
from persistence_test import ARTIFACTS, VIDEO, check, ready, run


def action(operation, **values):
    return dict(action=operation, **values)


def report(name):
    return json.loads((ARTIFACTS / f"persistence-{name}-result.json").read_text())


def main():
    assert VIDEO.is_file()
    setup = [action("volume", value=0), action("mode", value="off")]
    run("playback-modes", setup + [
        action("add", paths=[str(VIDEO)] * 4), ready(),
        action("select", index=3), ready(), action("finish"),
        check(currentIndex=3, wantsToPlay=False, canGoNext=False),
        action("playbackMode", value="repeatAll"), action("finish"), ready(),
        check(currentIndex=0, wantsToPlay=True, canGoPrevious=True),
        action("previous"), ready(), check(currentIndex=3),
        action("next"), ready(), check(currentIndex=0),
        action("playbackMode", value="repeatOne"), action("finish"), ready(),
        check(currentIndex=0, wantsToPlay=True, maxPosition=1),
        action("next"), ready(), check(currentIndex=1),
        action("pause"), action("seek", value=4), ready(),
        action("playbackMode", value="shuffle"),
        check(currentIndex=1, wantsToPlay=False, minPosition=3.9, maxPosition=4.1, canGoPrevious=False),
        action("next"), ready(), action("previous"), ready(), check(currentIndex=1),
        action("next"), ready(), action("clear"),
        action("add", paths=[str(VIDEO)]), ready(),
        check(canGoPrevious=False, canGoNext=False), action("finish"), ready(),
        check(currentIndex=0, wantsToPlay=True, maxPosition=1),
        action("playbackMode", value="repeatAll"), action("finish"), ready(),
        check(currentIndex=0, wantsToPlay=True, maxPosition=1),
        action("playbackMode", value="repeatOne"), action("finish"), ready(),
        check(currentIndex=0, wantsToPlay=True, maxPosition=1),
    ], restore=False)
    records = report("playback-modes")["steps"]
    random_nexts = [s["state"]["currentID"] for s in records
                    if s["action"] == "next" and s["state"]["playbackMode"] == "shuffle"]
    assert len(random_nexts) == 2 and random_nexts[0] == random_nexts[1]

    # All items refer to the same video: uniqueness must be by entry ID, not file path.
    steps = setup + [action("add", paths=[str(VIDEO)] * 4), ready(), action("playbackMode", value="shuffle")]
    for _ in range(11):
        steps.extend([action("next"), ready()])
    run("shuffle-rounds", steps, restore=False)
    records = report("shuffle-rounds")["steps"]
    ids = [s["state"]["currentID"] for s in records if s["action"] in ("playbackMode", "next")]
    assert len(ids) == 12
    for offset in range(0, 12, 4):
        assert len(set(ids[offset:offset + 4])) == 4
    assert all(a != b for a, b in zip(ids, ids[1:]))

    run("list-ownership", setup + [
        action("add", paths=[str(VIDEO)] * 2), ready(),
        action("createPlaylist", name="浏览列表"),
        check(playingPlaylistName="默认列表", playlistCount=0, wantsToPlay=True),
        action("add", paths=[str(ARTIFACTS / "short-a.wav")]),
        check(playingPlaylistName="默认列表", playlistCount=1, currentIndex=0),
        action("finish"), ready(), check(playingPlaylistName="默认列表", currentIndex=1),
        action("previous"), ready(), check(playingPlaylistName="默认列表", currentIndex=0),
        action("clear"), check(playingPlaylistName="默认列表", wantsToPlay=True),
        action("drop", paths=[str(VIDEO)]), action("browsePlaylist", index=0),
        action("wait", seconds=0.5), check(playlistCount=2, playingPlaylistName="默认列表"),
        action("browsePlaylist", index=1), check(playlistCount=1),
        action("select", index=0), ready(), check(playingPlaylistName="浏览列表"),
        action("browsePlaylist", index=0), action("remove", indices=[0]),
        check(playingPlaylistName="浏览列表", wantsToPlay=True),
        action("browsePlaylist", index=1), action("pause"), action("remove", indices=[0]),
        check(playingPlaylistName="", wantsToPlay=False, ready=False),
        action("browsePlaylist", index=0), action("select", index=0),
        action("createPlaylist", name="快速切换"), action("add", paths=[str(VIDEO)]),
        action("select", index=0), action("browsePlaylist", index=0),
        action("select", index=0), action("browsePlaylist", index=2),
        action("deletePlaylist"), ready(),
        check(playingPlaylistName="默认列表", hasError=False),
        action("browsePlaylist", index=0), action("deletePlaylist"),
        check(playingPlaylistName="", wantsToPlay=False, ready=False),
    ], restore=False)

    # Direct point selection and removal of the current item preserve the paused intent.
    run("remove-and-failure", setup + [
        action("add", paths=[str(VIDEO)] * 3), ready(), action("pause"),
        action("select", index=1, autoplay=False), ready(),
        action("remove", indices=[1]), ready(), check(currentIndex=1, wantsToPlay=False),
        action("remove", indices=[1]), ready(), check(currentIndex=0, wantsToPlay=False),
        action("playbackMode", value="repeatAll"),
        action("add", paths=[str(ARTIFACTS / "unsupported.txt")]),
        action("select", index=1), action("awaitError"),
        check(wantsToPlay=False, hasError=True, playlistCount=2),
        action("wait", seconds=0.4), check(wantsToPlay=False, currentIndex=1),
        action("remove", indices=[1]), ready(), check(wantsToPlay=False, hasError=False),
        action("clear"), action("add", paths=[str(VIDEO)] * 4),
        action("select", index=1, autoplay=False), ready(),
        action("remove", indices=[0, 1]), ready(), check(currentIndex=0, playlistCount=2, wantsToPlay=False),
    ], restore=False)


if __name__ == "__main__":
    main()
