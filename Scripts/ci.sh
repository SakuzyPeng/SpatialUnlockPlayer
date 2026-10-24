#!/bin/zsh
set -eu
setopt PIPE_FAIL
cd "${0:A:h:h}"
mkdir -p build/ci build/tests "$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex"

run_check() {
  local check_name="$1"
  shift
  print "Running $check_name"
  "$@" 2>&1 | tee "build/ci/$check_name.log"
}

python3 - <<'PY'
import platform
import subprocess
assert platform.system() == "Darwin", "CI requires macOS"
assert platform.machine() == "arm64", "CI requires Apple Silicon"
assert int(platform.mac_ver()[0].split('.')[0]) >= 27, "CI requires macOS 27 or newer"
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
assert int(sdk.split('.')[0]) >= 27, "CI requires the macOS 27 SDK or newer"
PY
run_check toolchain xcrun xcodebuild -version
run_check playback zsh Tests/playback_test.sh
run_check head-tracking zsh Tests/head_tracking_test.sh
run_check equalizer zsh Tests/equalizer_test.sh
run_check advanced-audio zsh Tests/advanced_audio_test.sh
run_check release zsh build.sh

# Verify that stripping and signing preserved the shipped interposing library.
xcrun clang -std=c11 -O2 Tests/head_pose_test.c \
  -L 'SpatialUnlock Player.app/Contents/Frameworks' -lSpatialShim \
  -framework AudioToolbox -framework CoreAudio \
  '-Wl,-rpath,@executable_path/../../SpatialUnlock Player.app/Contents/Frameworks' \
  -o build/tests/release-head-pose-test
run_check release-rendering build/tests/release-head-pose-test

# Build both conditional code paths without replacing the exported Release app.
run_check debug xcrun xcodebuild -quiet -project SpatialUnlockPlayer.xcodeproj \
  -scheme SpatialUnlockPlayer -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build
run_check diagnostics xcrun xcodebuild -quiet -project SpatialUnlockPlayer.xcodeproj \
  -scheme SpatialUnlockPlayer-Diagnostics -configuration Diagnostics \
  -destination 'platform=macOS,arch=arm64' build

# Local releases and CI use the same versioned, round-trip-checked archive.
run_check archive zsh Scripts/package_release.sh build/ci
