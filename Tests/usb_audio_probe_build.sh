#!/bin/zsh
set -eu
cd "${0:A:h:h}"
zsh Tests/route_probe_build.sh
xcrun clang -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations -fobjc-arc \
  Tests/usb_audio_metadata.m -framework Foundation -framework CoreAudio -framework IOKit \
  -o build/tests/route-probe/usb-audio-metadata
