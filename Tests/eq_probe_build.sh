#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/tests/eq-probe
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -fblocks -dynamiclib \
  Sources/SpatialShim/SpatialShim.c Sources/SpatialShim/Equalizer.c Tests/eq_probe_shim.c \
  -framework AudioToolbox -framework CoreAudio \
  -install_name @rpath/libEQProbe.dylib -o build/tests/eq-probe/libEQProbe.dylib
xcrun clang -O2 -Wall -Wextra -fobjc-arc -fblocks Tests/eq_probe.m \
  -L build/tests/eq-probe -lEQProbe -Wl,-rpath,@executable_path \
  -framework AVFoundation -framework Foundation -framework AudioToolbox -framework MediaToolbox -framework CoreMedia -framework CoreAudio \
  -o build/tests/eq-probe/eq-probe
