#!/bin/zsh
set -euo pipefail
HARNESS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
HARNESS_ICON_TEMP="$(mktemp -d /private/tmp/harness-icon.XXXXXX)"
trap 'rm -rf -- "$HARNESS_ICON_TEMP"' EXIT
HARNESS_ICONSET="$HARNESS_ICON_TEMP/Harness.iconset"
mkdir -p "$HARNESS_ICONSET"
xcrun swift -module-cache-path "$HARNESS_ICON_TEMP/modules" "$HARNESS_ROOT/Resources/AppIcon/DrawIcon.swift" "$HARNESS_ROOT/Resources/AppIcon/preview.png"
for HARNESS_SIZE in 16 32 128 256 512; do
  sips -z "$HARNESS_SIZE" "$HARNESS_SIZE" "$HARNESS_ROOT/Resources/AppIcon/preview.png" --out "$HARNESS_ICONSET/icon_${HARNESS_SIZE}x${HARNESS_SIZE}.png" >/dev/null
  HARNESS_RETINA=$((HARNESS_SIZE * 2))
  sips -z "$HARNESS_RETINA" "$HARNESS_RETINA" "$HARNESS_ROOT/Resources/AppIcon/preview.png" --out "$HARNESS_ICONSET/icon_${HARNESS_SIZE}x${HARNESS_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$HARNESS_ICONSET" -o "$HARNESS_ROOT/Resources/AppIcon/Harness.icns"
print "Generated Resources/AppIcon/preview.png and Harness.icns from the vector design."
