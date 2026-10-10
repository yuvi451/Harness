#!/bin/zsh
set -euo pipefail
HARNESS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ $# == 1 && -n "$1" ]] || { print -u2 "Usage: scripts/notarize.sh KEYCHAIN_PROFILE"; exit 1; }
HARNESS_STAGE="$(mktemp -d /private/tmp/harness-notary-XXXXXX.noindex)"
trap 'rm -rf -- "$HARNESS_STAGE"' EXIT
cd "$HARNESS_ROOT"
python3 -c 'import runpy; m=runpy.run_path("scripts/install.py"); m["validate_archive"](m["SOURCE"])'
ditto -x -k --norsrc --noextattr dist/Harness.zip "$HARNESS_STAGE"
HARNESS_APP="$HARNESS_STAGE/Harness/Harness.app"
codesign --verify --strict "$HARNESS_APP"
HARNESS_SIGNATURE="$(codesign -d --verbose=2 "$HARNESS_APP" 2>&1)"
[[ "$HARNESS_SIGNATURE" == *"Authority=Developer ID Application:"* && "$HARNESS_SIGNATURE" == *"(runtime)"* ]] || { print -u2 "Notarization requires a Developer ID build with hardened runtime."; exit 1; }
xcrun notarytool submit dist/Harness.zip --keychain-profile "$1" --wait --timeout 20m --output-format json > "$HARNESS_STAGE/result.json"
[[ "$(plutil -extract status raw -o - "$HARNESS_STAGE/result.json")" == Accepted ]] || { print -u2 "Notarization failed; use notarytool log for submission $(plutil -extract id raw -o - "$HARNESS_STAGE/result.json")."; exit 1; }
xcrun stapler staple "$HARNESS_APP"
xcrun stapler validate "$HARNESS_APP"
spctl --assess --type execute "$HARNESS_APP"
ditto -c -k --keepParent --norsrc --noextattr "$HARNESS_STAGE/Harness" "$HARNESS_STAGE/Harness.zip"
cp "$HARNESS_STAGE/Harness.zip" dist/Harness.zip
print "Notarized and stapled dist/Harness.zip."
