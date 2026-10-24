#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/tests/advanced
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -DSPATIAL_RENDER_TESTING -dynamiclib \
  Sources/SpatialShim/SpatialShim.c Sources/SpatialShim/HeadPose.c Sources/SpatialShim/Equalizer.c Sources/SpatialShim/RenderConfiguration.c \
  -framework AudioToolbox -framework CoreAudio -o build/tests/advanced/libSpatialAdvancedTests.dylib
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -DSPATIAL_RENDER_TESTING Tests/advanced_render_test.c \
  -L build/tests/advanced -lSpatialAdvancedTests -framework AudioToolbox -framework CoreAudio \
  -Wl,-rpath,@executable_path -o build/tests/advanced/advanced-render-test
build/tests/advanced/advanced-render-test
xcrun swiftc -swift-version 6 -module-cache-path "$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex" \
  Sources/AdvancedAudioSettings.swift Tests/advanced_settings_test.swift -o build/tests/advanced/advanced-settings-test
build/tests/advanced/advanced-settings-test
