#!/bin/sh
# Regenerates the committed art in resources/art/:
#   empty-*.{kra,png}  empty-state illustrations (SVG -> Krita)
#   scan.mov           scan animation (Blender -> HEVC with alpha)
# Needs Krita, Blender and ffmpeg (Homebrew); the build itself needs none.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
art="$root/resources/art"
krita=${KRITA:-/Applications/Krita.app/Contents/MacOS/krita}
blender=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 -I "$art/illustrations.py" "$work/svg"
for svg in "$work"/svg/*.svg; do
    name=$(basename "$svg" .svg)
    # Krita's headless export renders SVG input but not a .kra's vector
    # layers, so both outputs come straight from the SVG.
    "$krita" "$svg" --export --export-filename "$art/$name.kra" >/dev/null 2>&1
    "$krita" "$svg" --export --export-filename "$art/$name.png" >/dev/null 2>&1
done

mkdir "$work/frames"
"$blender" -b --factory-startup -P "$art/scan_animation.py" -- "$work/frames" >/dev/null
ffmpeg -v error -y -framerate 24 -i "$work/frames/f_%04d.png" \
    -c:v hevc_videotoolbox -alpha_quality 0.9 -b:v 800k -tag:v hvc1 -allow_sw 1 "$art/scan.mov"
ls -l "$art"
