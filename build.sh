#!/bin/zsh
set -eu
cd "${0:A:h}"

configuration=Release
scheme=SpatialUnlockPlayer
case "${1:-}" in
  '') ;;
  --debug) configuration=Debug ;;
  --diagnostics) configuration=Diagnostics; scheme=SpatialUnlockPlayer-Diagnostics ;;
  *) print -u2 '用法：zsh build.sh [--debug|--diagnostics]'; exit 2 ;;
esac
if (( $# > 1 )); then
  print -u2 '用法：zsh build.sh [--debug|--diagnostics]'
  exit 2
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  print -u2 '需要 XcodeGen 2.44.1 或更新版本，可使用 brew install xcodegen 安装。'
  exit 1
fi
# Match executable paths, not argv: a tool whose working-directory argument ends
# in /SpatialUnlockPlayer is not a running copy of the player.
if /bin/ps -axo comm= | /usr/bin/grep -Eq '(^|/)SpatialUnlockPlayer$'; then
  print -u2 '请先关闭 SpatialUnlock Player，再重新构建。'
  exit 1
fi

xcodegen generate --spec project.yml
/usr/bin/xcrun xcodebuild -quiet \
  -project SpatialUnlockPlayer.xcodeproj \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination 'platform=macOS,arch=arm64' \
  build

built_app="$PWD/build/Products/$configuration/SpatialUnlock Player.app"
/usr/bin/codesign --verify --deep --strict "$built_app"
app="$PWD/SpatialUnlock Player.app"
rm -rf "$app"
/usr/bin/ditto "$built_app" "$app"
if [[ "$configuration" == Release ]]; then
  # Finish mutations before signing, including the embedded interposing library.
  # Xcode's ordinary build products retain their symbols for local debugging.
  library="$app/Contents/Frameworks/libSpatialShim.dylib"
  /usr/bin/codesign --remove-signature "$app"
  /usr/bin/codesign --remove-signature "$library"
  /usr/bin/xcrun strip -S -x "$library" "$app/Contents/MacOS/SpatialUnlockPlayer"
  /usr/bin/codesign --force --sign - "$library"
  /usr/bin/codesign --force --sign - "$app"
fi
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
if [[ "$configuration" == Release ]]; then
  /usr/bin/python3 Scripts/check_release.py "$app"
fi
print "Built $app (configuration=$configuration)"
