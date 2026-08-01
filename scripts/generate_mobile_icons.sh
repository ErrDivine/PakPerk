#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_svg="$project_dir/mobile/assets/brand/pakperk_app_icon.svg"
master_png="$project_dir/mobile/assets/brand/pakperk_app_icon.png"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-mobile-icons.XXXXXX")"
cleanup() {
  rm -rf "$temporary_dir"
}
trap cleanup EXIT INT TERM

for command_name in magick rsvg-convert; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Mobile icon generation requires $command_name." >&2
    exit 2
  fi
done
if [[ ! -f "$source_svg" || -L "$source_svg" || ! -s "$source_svg" ]]; then
  echo "The canonical app-icon SVG must be a non-symlink, non-empty file." >&2
  exit 1
fi

rsvg-convert --width 1024 --height 1024 --output "$temporary_dir/master.png" "$source_svg"
magick "$temporary_dir/master.png" \
  -alpha off -colorspace sRGB -strip "PNG24:$master_png"

while read -r filename pixels; do
  magick "$master_png" -filter Lanczos -resize "${pixels}x${pixels}!" \
    -alpha off -colorspace sRGB -strip \
    "PNG24:$project_dir/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/$filename"
done <<'SIZES'
Icon-App-20x20@1x.png 20
Icon-App-20x20@2x.png 40
Icon-App-20x20@3x.png 60
Icon-App-29x29@1x.png 29
Icon-App-29x29@2x.png 58
Icon-App-29x29@3x.png 87
Icon-App-40x40@1x.png 40
Icon-App-40x40@2x.png 80
Icon-App-40x40@3x.png 120
Icon-App-60x60@2x.png 120
Icon-App-60x60@3x.png 180
Icon-App-76x76@1x.png 76
Icon-App-76x76@2x.png 152
Icon-App-83.5x83.5@2x.png 167
Icon-App-1024x1024@1x.png 1024
SIZES

while read -r density pixels; do
  for filename in ic_launcher.png ic_launcher_round.png; do
    magick "$master_png" -filter Lanczos -resize "${pixels}x${pixels}!" \
      -alpha off -colorspace sRGB -strip \
      "PNG24:$project_dir/mobile/android/app/src/main/res/mipmap-$density/$filename"
  done
done <<'SIZES'
mdpi 48
hdpi 72
xhdpi 96
xxhdpi 144
xxxhdpi 192
SIZES

while read -r asset_file expected_width expected_height; do
  dimensions="$(magick identify -format '%w %h' "$asset_file")"
  if [[ "$dimensions" != "$expected_width $expected_height" ]]; then
    echo "Generated icon has unexpected dimensions: $asset_file ($dimensions)" >&2
    exit 1
  fi
  channels="$(magick identify -format '%[channels]' "$asset_file")"
  if [[ "$channels" == *a* ]]; then
    echo "Generated store icon unexpectedly contains alpha: $asset_file" >&2
    exit 1
  fi
done <<SIZES
$master_png 1024 1024
$project_dir/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png 1024 1024
$project_dir/mobile/android/app/src/main/res/mipmap-mdpi/ic_launcher.png 48 48
$project_dir/mobile/android/app/src/main/res/mipmap-mdpi/ic_launcher_round.png 48 48
SIZES

echo "Generated opaque Pakperk iOS, Android legacy, round, and master app icons."
