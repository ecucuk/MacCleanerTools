#!/bin/sh
# Regenerates resources/MacCleaner.icns from tools/make_icon.m.
# Run after changing the icon design; the .icns is committed so a normal
# build never needs to run this.
#
# Honours $CC and $CFLAGS so a non-Apple clang can be pointed at the
# Command Line Tools SDK (CFLAGS="-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk").
set -eu
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
iconset="$work/MacCleaner.iconset"
mkdir -p "$iconset"

"${CC:-cc}" ${CFLAGS:-} -fobjc-arc -framework AppKit tools/make_icon.m -o "$work/make_icon"
"$work/make_icon" "$work/icon_1024.png"

# The ten sizes iconutil expects: 16/32/128/256/512 at 1x and 2x.
for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size"     "$work/icon_1024.png" --out "$iconset/icon_${size}x${size}.png"    >/dev/null
    sips -z "$double" "$double" "$work/icon_1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o resources/MacCleaner.icns
cp "$work/icon_1024.png" resources/icon_preview_1024.png
echo "wrote resources/MacCleaner.icns"
