#!/bin/zsh
set -eu
setopt PIPE_FAIL
cd "${0:A:h:h}"

release_app="$PWD/SpatialUnlock Player.app"
output_dir="${1:-build/ci}"
mkdir -p "$output_dir"
output_dir="${output_dir:A}"

release_version="$(python3 - <<'PY'
from pathlib import Path
import plistlib
import re

source = plistlib.loads(Path('Resources/Info.plist').read_bytes())
built = plistlib.loads(Path('SpatialUnlock Player.app/Contents/Info.plist').read_bytes())
for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
    if source[key] != built[key]:
        raise SystemExit(f'{key} differs from source; rebuild the Release app before packaging')
version = built['CFBundleShortVersionString']
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
    raise SystemExit('Expected a three-part numeric release version')
print(version)
PY
)"
python3 Scripts/check_release.py "$release_app"
archive_name="SpatialUnlockPlayer-${release_version}-macos-arm64.zip"
release_tmpdir="$(mktemp -d "$output_dir/.package.XXXXXX")"
trap 'rm -rf "$release_tmpdir"' EXIT

# Keep the app bundle, metadata and executable permissions intact, then verify
# the exact archive that will be uploaded rather than only the source bundle.
ditto -c -k --sequesterRsrc --keepParent "$release_app" "$release_tmpdir/$archive_name"
mkdir "$release_tmpdir/unpacked"
ditto -x -k "$release_tmpdir/$archive_name" "$release_tmpdir/unpacked"
test -x "$release_tmpdir/unpacked/SpatialUnlock Player.app/Contents/MacOS/SpatialUnlockPlayer"
python3 Scripts/check_release.py "$release_tmpdir/unpacked/SpatialUnlock Player.app"
(
  cd "$release_tmpdir"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
  shasum -a 256 -c "$archive_name.sha256"
)
mv "$release_tmpdir/$archive_name" "$output_dir/$archive_name"
mv "$release_tmpdir/$archive_name.sha256" "$output_dir/$archive_name.sha256"
print "Packaged $output_dir/$archive_name"
