#!/bin/zsh
set -euo pipefail
umask 022
HARNESS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PYTHONDONTWRITEBYTECODE=1
HARNESS_STAGE="$(python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix="harness-package-stage-", suffix=".noindex", dir="/private/tmp"))')"
HARNESS_OWN_SCRATCH=false
if [[ -z "${HARNESS_PACKAGE_SCRATCH:-}" ]]; then
  HARNESS_PACKAGE_SCRATCH="$(python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix="harness-package-build-", suffix=".noindex", dir="/private/tmp"))')"
  HARNESS_OWN_SCRATCH=true
fi
cleanup() {
  rm -rf -- "$HARNESS_STAGE"
  if [[ "$HARNESS_OWN_SCRATCH" == true ]]; then rm -rf -- "$HARNESS_PACKAGE_SCRATCH"; fi
}
trap cleanup EXIT
case "$HARNESS_PACKAGE_SCRATCH" in
  /private/tmp/*|/tmp/*) ;;
  *) print -u2 "Packaging scratch must be a dedicated directory under /private/tmp or /tmp."; exit 1 ;;
esac
cd "$HARNESS_ROOT"
HARNESS_BUILD_ARGS=(-c release --scratch-path "$HARNESS_PACKAGE_SCRATCH"
  -Xswiftc -debug-prefix-map -Xswiftc "$HARNESS_ROOT=/src/Harness"
  -Xswiftc -file-prefix-map -Xswiftc "$HARNESS_ROOT=/src/Harness"
  -Xswiftc -debug-prefix-map -Xswiftc "$HARNESS_PACKAGE_SCRATCH=/build/Harness"
  -Xswiftc -file-prefix-map -Xswiftc "$HARNESS_PACKAGE_SCRATCH=/build/Harness"
  -Xcc "-ffile-prefix-map=$HARNESS_ROOT=/src/Harness"
  -Xcc "-ffile-prefix-map=$HARNESS_PACKAGE_SCRATCH=/build/Harness")
if [[ -n "${HARNESS_SIGNING_IDENTITY:-}" ]]; then
  [[ "$HARNESS_SIGNING_IDENTITY" == "Developer ID Application: "* ]] || { print -u2 "Use an Apple Developer ID Application identity for distribution."; exit 1; }
  HARNESS_BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
HARNESS_APP_VERSION="$(python3 -c 'from pathlib import Path; import re; v=Path("VERSION").read_text().strip(); assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+",v); print(v)')"
swift build "${HARNESS_BUILD_ARGS[@]}"
HARNESS_BIN="$(swift build "${HARNESS_BUILD_ARGS[@]}" --show-bin-path)"
[[ -x "$HARNESS_BIN/harness" && -x "$HARNESS_BIN/harness-detect" ]]
HARNESS_APP="$HARNESS_STAGE/Harness/Harness.app"
mkdir -p "$HARNESS_APP/Contents/MacOS" "$HARNESS_APP/Contents/Resources/ThirdPartyLicenses"
cp "$HARNESS_BIN/harness" "$HARNESS_APP/Contents/MacOS/Harness"
cp -R "$HARNESS_BIN/Harness_HarnessEmitter.bundle" "$HARNESS_APP/Contents/Resources/"
cp Resources/AppIcon/Harness.icns "$HARNESS_APP/Contents/Resources/Harness.icns"
cp "$HARNESS_BIN/harness-detect" "$HARNESS_STAGE/Harness/harness-detect"
xcrun strip -S "$HARNESS_APP/Contents/MacOS/Harness" "$HARNESS_STAGE/Harness/harness-detect"
python3 scripts/release_privacy.py "$HARNESS_APP/Contents/MacOS/Harness" "$HARNESS_STAGE/Harness/harness-detect"
cp README.md "$HARNESS_STAGE/Harness/README.md"
mkdir -p "$HARNESS_STAGE/Harness/docs" "$HARNESS_STAGE/Harness/fixtures"
cp -R docs/. "$HARNESS_STAGE/Harness/docs/"
cp fixtures/fullscreen.html "$HARNESS_STAGE/Harness/fixtures/"
cp docs/SECURITY.md "$HARNESS_APP/Contents/Resources/"
for HARNESS_DEP in KeychainAccess; do
  HARNESS_FOUND=false
  for HARNESS_LICENSE in LICENSE LICENSE.md LICENSE.txt COPYING; do
    HARNESS_FILE="$HARNESS_PACKAGE_SCRATCH/checkouts/$HARNESS_DEP/$HARNESS_LICENSE"
    if [[ -f "$HARNESS_FILE" ]]; then
      cp "$HARNESS_FILE" "$HARNESS_APP/Contents/Resources/ThirdPartyLicenses/$HARNESS_DEP.txt"
      chmod 644 "$HARNESS_APP/Contents/Resources/ThirdPartyLicenses/$HARNESS_DEP.txt"
      HARNESS_FOUND=true
      break
    fi
  done
  if [[ "$HARNESS_FOUND" != true ]]; then print -u2 "Missing license for $HARNESS_DEP; refusing incomplete package."; exit 1; fi
done
HARNESS_PLIST="$HARNESS_APP/Contents/Info.plist"
plutil -create xml1 "$HARNESS_PLIST"
plutil -insert CFBundleName -string Harness "$HARNESS_PLIST"
plutil -insert CFBundleDisplayName -string Harness "$HARNESS_PLIST"
plutil -insert CFBundleIdentifier -string org.harness.research "$HARNESS_PLIST"
plutil -insert CFBundleExecutable -string Harness "$HARNESS_PLIST"
plutil -insert CFBundleIconFile -string Harness "$HARNESS_PLIST"
plutil -insert CFBundlePackageType -string APPL "$HARNESS_PLIST"
plutil -insert CFBundleShortVersionString -string "$HARNESS_APP_VERSION" "$HARNESS_PLIST"
plutil -insert CFBundleVersion -string 1 "$HARNESS_PLIST"
plutil -insert LSMinimumSystemVersion -string 14.0 "$HARNESS_PLIST"
plutil -insert NSPrincipalClass -string NSApplication "$HARNESS_PLIST"
plutil -insert NSHighResolutionCapable -bool true "$HARNESS_PLIST"
plutil -insert NSScreenCaptureUsageDescription -string "Harness captures only when you press a capture shortcut. Queue up to six screenshots in memory and send them together through your ChatGPT plan." "$HARNESS_PLIST"
plutil -insert LSUIElement -bool false "$HARNESS_PLIST"
plutil -insert LSMultipleInstancesProhibited -bool true "$HARNESS_PLIST"
plutil -insert HarnessBuildDateUTC -string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$HARNESS_PLIST"
plutil -insert HarnessBuildArchitecture -string "$(lipo -archs "$HARNESS_BIN/harness")" "$HARNESS_PLIST"
plutil -insert HarnessSwiftVersion -string "$(xcrun swift --version | tr '\n' ' ')" "$HARNESS_PLIST"
plutil -insert HarnessXcodeVersion -string "$(xcodebuild -version | tr '\n' ' ')" "$HARNESS_PLIST"
plutil -insert HarnessSDKVersion -string "$(xcrun --sdk macosx --show-sdk-version)" "$HARNESS_PLIST"
HARNESS_DEPENDENCIES=""
for HARNESS_INDEX in {0..63}; do
  if ! HARNESS_IDENTITY="$(plutil -extract "pins.$HARNESS_INDEX.identity" raw -o - Package.resolved 2>/dev/null)"; then break; fi
  HARNESS_VERSION="$(plutil -extract "pins.$HARNESS_INDEX.state.version" raw -o - Package.resolved)"
  HARNESS_REVISION="$(plutil -extract "pins.$HARNESS_INDEX.state.revision" raw -o - Package.resolved)"
  HARNESS_DEPENDENCIES+="$HARNESS_IDENTITY@$HARNESS_VERSION#$HARNESS_REVISION;"
done
[[ -n "$HARNESS_DEPENDENCIES" && ${#HARNESS_DEPENDENCIES} -le 1800 ]]
plutil -insert HarnessDependencies -string "$HARNESS_DEPENDENCIES" "$HARNESS_PLIST"
plutil -insert HarnessSourceRevision -string "$(git rev-parse HEAD)" "$HARNESS_PLIST"
HARNESS_DIRTY=false
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then HARNESS_DIRTY=true; fi
plutil -insert HarnessSourceDirty -bool "$HARNESS_DIRTY" "$HARNESS_PLIST"
plutil -lint "$HARNESS_PLIST"
# Clear metadata only on the generated temporary products, before signing.
xattr -cr "$HARNESS_STAGE/Harness"
if [[ -n "${HARNESS_SIGNING_IDENTITY:-}" ]]; then
  HARNESS_SIGN_ARGS=(--sign "$HARNESS_SIGNING_IDENTITY" --options runtime --timestamp)
else
  HARNESS_SIGNING="$HARNESS_STAGE/signing.json"
  python3 scripts/signing.py > "$HARNESS_SIGNING"
  HARNESS_SIGN_ARGS=(--keychain "$(plutil -extract keychain raw -o - "$HARNESS_SIGNING")" --sign "$(plutil -extract fingerprint raw -o - "$HARNESS_SIGNING")" --timestamp=none)
fi
codesign --force "${HARNESS_SIGN_ARGS[@]}" --identifier org.harness.research "$HARNESS_APP"
codesign --force "${HARNESS_SIGN_ARGS[@]}" --identifier org.harness.research.detector "$HARNESS_STAGE/Harness/harness-detect"
codesign --verify --strict "$HARNESS_APP"
codesign --verify --strict "$HARNESS_STAGE/Harness/harness-detect"
HARNESS_DIST="$HARNESS_ROOT/dist"
[[ ! -L "$HARNESS_DIST" ]]
mkdir -p "$HARNESS_DIST"
for HARNESS_OUTPUT in harness-detect Harness.zip; do [[ ! -L "$HARNESS_DIST/$HARNESS_OUTPUT" ]]; done
# Store the app only inside the archive: synced Documents may inject FinderInfo
# into a raw bundle, invalidating it and exposing duplicate Spotlight results.
cp "$HARNESS_STAGE/Harness/harness-detect" "$HARNESS_DIST/harness-detect"
xattr -cr "$HARNESS_DIST/harness-detect"
codesign --verify --strict "$HARNESS_DIST/harness-detect"
ditto -c -k --keepParent --norsrc --noextattr "$HARNESS_STAGE/Harness" "$HARNESS_DIST/Harness.zip"
python3 scripts/release_privacy.py "$HARNESS_DIST/Harness.zip" "$HARNESS_DIST/harness-detect"
print "Packaged version $HARNESS_APP_VERSION: dist/Harness.zip and dist/harness-detect."
