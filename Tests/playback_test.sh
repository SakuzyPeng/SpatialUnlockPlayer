#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/tests
xcrun swiftc -swift-version 6 \
  -module-cache-path "$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex" \
  Sources/Playlist.swift Sources/PlaybackOrder.swift Sources/PlaybackSession.swift \
  Tests/playback_order_test.swift -o build/tests/playback-test
build/tests/playback-test
