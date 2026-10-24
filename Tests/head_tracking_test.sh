#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/tests
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -dynamiclib \
  Sources/SpatialShim/SpatialShim.c Sources/SpatialShim/HeadPose.c Sources/SpatialShim/Equalizer.c \
  -framework AudioToolbox -framework CoreAudio -o build/tests/libSpatialShim.dylib
xcrun clang -std=c11 -O2 Tests/head_pose_test.c \
  -L build/tests -lSpatialShim -framework AudioToolbox -framework CoreAudio \
  -Wl,-rpath,@executable_path -o build/tests/head-pose-test
python3 - <<'PY'
import subprocess
subprocess.run(["build/tests/head-pose-test"], timeout=30, check=True)
PY
xcrun swiftc -swift-version 6 \
  -module-cache-path "$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex" \
  Sources/HeadTracking/PoseQuaternion.swift Sources/HeadTracking/PoseBridgeProtocol.swift \
  Sources/HeadTracking/PoseBridgeConsumer.swift Tests/posebridge_protocol_test.swift \
  -o build/tests/posebridge-protocol-test
build/tests/posebridge-protocol-test
