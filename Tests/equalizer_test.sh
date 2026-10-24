#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/tests
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -dynamiclib \
  Sources/SpatialShim/SpatialShim.c Sources/SpatialShim/HeadPose.c Sources/SpatialShim/Equalizer.c Sources/SpatialShim/RenderConfiguration.c \
  -framework AudioToolbox -framework CoreAudio -o build/tests/libSpatialShim.dylib
xcrun swiftc -O -swift-version 6 -target arm64-apple-macos27.0 \
  -module-cache-path "$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex" \
  -import-objc-header Sources/SpatialShim/SpatialShim.h \
  Sources/EqualizerPreset.swift Sources/EqualizerModel.swift Tests/equalizer_parser_test.swift \
  -L build/tests -lSpatialShim -Xlinker -rpath -Xlinker @executable_path \
  -o build/tests/equalizer-parser-test
build/tests/equalizer-parser-test 'Tests/Fixtures/Sony MDR-MV1 ParametricEq.txt'
python3 Tests/equalizer_dsp_test.py
