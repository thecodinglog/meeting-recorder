#!/bin/bash
# tools/make_icon.swift 로 그린 그림을 Resources/AppIcon.icns 로 만든다.
set -euo pipefail
cd "$(dirname "$0")"

WORK="build/icon"
ICONSET="$WORK/AppIcon.iconset"
rm -rf "$WORK"
mkdir -p "$ICONSET" Resources

swift tools/make_icon.swift "$WORK/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$WORK/icon_1024.png" Resources/AppIcon.png

echo "완료: Resources/AppIcon.icns"
