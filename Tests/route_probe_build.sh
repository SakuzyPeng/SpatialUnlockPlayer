#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/tests/route-probe
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -fblocks -DSPATIAL_DIAGNOSTICS -DSPATIAL_RENDER_EXTERNAL_INTERPOSE -dynamiclib \
  Sources/SpatialShim/SpatialShim.c Sources/SpatialShim/Equalizer.c Sources/SpatialShim/RenderConfiguration.c Tests/route_probe_shim.c \
  -framework AudioToolbox -framework CoreAudio -framework CoreFoundation \
  -install_name @rpath/libRouteProbe.dylib -o build/tests/route-probe/libRouteProbe.dylib
xcrun clang -O2 -Wall -Wextra -Werror -fobjc-arc -fblocks -DSPATIAL_DIAGNOSTICS Tests/route_probe.m \
  -L build/tests/route-probe -lRouteProbe -Wl,-rpath,@executable_path \
  -framework AVFoundation -framework Foundation -framework AudioToolbox -framework CoreAudio -framework CoreMedia \
  -o build/tests/route-probe/route-probe
