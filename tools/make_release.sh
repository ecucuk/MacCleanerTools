#!/bin/sh
# Builds the release packages: a universal (Apple silicon + Intel) app and
# CLI, packed as a .zip, a .dmg and a .pkg, plus the CLI alone as a .zip.
#
#   sh tools/make_release.sh [output-dir]      (default: build/release)
#
# Swift builds one architecture at a time, so each architecture is its own
# CMake build tree and lipo merges the executables. The result is ad-hoc
# signed: there is no Developer ID, so Gatekeeper asks the user to approve
# the first launch (see the release notes).
set -eu
cd "$(dirname "$0")/.."

out=${1:-build/release}
rm -rf "$out"
mkdir -p "$out"

for arch in arm64 x86_64; do
    cmake -S . -B "$out/$arch" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" >/dev/null
    cmake --build "$out/$arch"
done

# Tests run natively (this script expects an Apple silicon Mac), and under
# Rosetta for the Intel build when it is there.
"$out/arm64/tests/maccleaner_tests" >/dev/null
if arch -x86_64 /usr/bin/true 2>/dev/null; then
    arch -x86_64 "$out/x86_64/tests/maccleaner_tests" >/dev/null
else
    echo "warning: Rosetta is not installed; the x86_64 tests did not run" >&2
fi

version=$(sed -n 's/^CMAKE_PROJECT_VERSION:STATIC=//p' "$out/arm64/CMakeCache.txt")
stage="$out/stage"
mkdir -p "$stage"

# Universal binaries: the arm64 bundle is the template (resources are the
# same in both); only the executables differ.
app="$stage/MacCleaner.app"
ditto "$out/arm64/MacCleaner.app" "$app"
lipo -create "$out/arm64/MacCleaner.app/Contents/MacOS/MacCleaner" \
    "$out/x86_64/MacCleaner.app/Contents/MacOS/MacCleaner" -output "$app/Contents/MacOS/MacCleaner"
lipo -create "$out/arm64/mac_cleaner" "$out/x86_64/mac_cleaner" -output "$stage/mac_cleaner"
for binary in "$app/Contents/MacOS/MacCleaner" "$stage/mac_cleaner"; do
    [ "$(lipo -archs "$binary")" = "x86_64 arm64" ] || { echo "error: $binary is not universal" >&2; exit 1; }
done

# lipo invalidates the per-architecture signatures.
codesign --force --sign - "$stage/mac_cleaner"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

name="MacCleaner-$version"

# .zip of the app.
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$name.zip"

# .dmg: the app next to an Applications link, to drag it across.
dmgroot="$out/dmg"
mkdir -p "$dmgroot"
ditto "$app" "$dmgroot/MacCleaner.app"
ln -s /Applications "$dmgroot/Applications"
hdiutil create -quiet -volname "MacCleaner $version" -srcfolder "$dmgroot" -ov -format UDZO "$out/$name.dmg"

# .pkg: the app in /Applications and the CLI in /usr/local/bin.
pkgroot="$out/pkgroot"
mkdir -p "$pkgroot/Applications" "$pkgroot/usr/local/bin"
ditto "$app" "$pkgroot/Applications/MacCleaner.app"
cp "$stage/mac_cleaner" "$pkgroot/usr/local/bin/mac_cleaner"
pkgbuild --analyze --root "$pkgroot" "$out/components.plist" >/dev/null
# Install to /Applications even if a copy of the app lives elsewhere.
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$out/components.plist"
pkgbuild --quiet --root "$pkgroot" --component-plist "$out/components.plist" \
    --identifier com.maccleaner.app.pkg --version "$version" --install-location / "$out/component.pkg"
productbuild --quiet --package "$out/component.pkg" "$out/$name.pkg"

# The CLI alone.
ditto -c -k "$stage/mac_cleaner" "$out/mac_cleaner-$version.zip"

cd "$out"
shasum -a 256 "$name.zip" "$name.dmg" "$name.pkg" "mac_cleaner-$version.zip" | tee SHA256SUMS
