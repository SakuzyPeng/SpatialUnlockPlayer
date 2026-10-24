#!/bin/zsh
set -eu
cd "${0:A:h}"
if /usr/bin/pgrep -x SpatialPlayer >/dev/null 2>&1; then
  print -u2 '请先关闭 SpatialPlayer，再重新构建。'
  exit 1
fi
diagnostic=0
if [[ "${1:-}" == '--diagnostics' ]]; then diagnostic=1; fi
app="$PWD/SpatialPlayer.app"
module_cache="$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources" build "$module_cache"
c_flags=()
swift_flags=()
if (( diagnostic )); then c_flags+=(-DSPATIAL_DIAGNOSTICS); swift_flags+=(-D SPATIAL_DIAGNOSTICS); fi
/usr/bin/clang -std=c11 -O2 -Wall -Wextra -target arm64-apple-macos27.0 -dynamiclib \
  "${c_flags[@]}" Sources/SpatialShim/SpatialShim.c -framework CoreAudio -framework AudioToolbox \
  -Wl,-install_name,@rpath/libSpatialShim.dylib \
  -o "$app/Contents/Frameworks/libSpatialShim.dylib"
/usr/bin/xcrun swiftc -swift-version 6 -O -parse-as-library -target arm64-apple-macos27.0 \
  -module-cache-path "$module_cache" "${swift_flags[@]}" \
  -import-objc-header Sources/SpatialShim/SpatialShim.h \
  Sources/*.swift -L "$app/Contents/Frameworks" -lSpatialShim \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$app/Contents/MacOS/SpatialPlayer"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/libSpatialShim.dylib"
/usr/bin/codesign --force --sign - --timestamp=none "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
print "Built $app (diagnostics=$diagnostic)"
