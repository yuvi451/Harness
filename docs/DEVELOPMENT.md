# Development and release

## Build and test

Open `Package.swift` in full Xcode, or use Make from the repository root. Swift 6.2+ and macOS SDK 14+ are required. Scripts default to `/Applications/Xcode.app/Contents/Developer` without changing global developer selection. SwiftPM resolves the pinned KeychainAccess dependency. See [BUILD_BLUEPRINT.md](BUILD_BLUEPRINT.md) for clean-source setup and a complete implementation/porting sequence.

| Command | Purpose |
| --- | --- |
| `make build` / `make check` | Debug compile / compile and synthetic tests |
| `make test` / `make test-native` | Synthetic suite / include generated AppKit integration windows |
| `make signing-tests` | Signing bootstrap, unsafe archives, atomic installation and rollback |
| `make preferences` | Eight independent raw/bundled preference restart reads |
| `make icon` | Regenerate PNG/ICNS from `Resources/AppIcon/DrawIcon.swift` |
| `make package` / `make install` | Signed release ZIP / canonical installation while Harness is closed |
| `make source` | Shareable source ZIP without Git, runtime data, build products or the restricted font binary |
| `make privacy` | Scan tracked source without printing matched credential values |

Use a dedicated `/private/tmp` scratch directory: `make SCRATCH=/private/tmp/harness-other test-native`. Never share a SwiftPM scratch directory between simultaneous commands. Finder metadata in synced Documents can invalidate loose app signatures; packaging uses temporary staging and keeps the app inside the ZIP.

For memory/concurrency changes, run `HARNESS_RUN_OVERLAY_GUI_TESTS=1 swift test --sanitize=address --scratch-path /private/tmp/harness-asan` or `--sanitize=thread --scratch-path /private/tmp/harness-tsan`, with `DEVELOPER_DIR` set. GUI suites run sequentially. Tests use generated images/windows, isolated preferences, mock HTTP/account/capture and private temporary files; they do not capture the screen or spend account allowance. Optional supplied-image tests use `HARNESS_PANE_REFERENCE_PATH` and `HARNESS_CROPPED_REFERENCE_PATH`.

`Harness.app/Contents/MacOS/Harness --check-chatgpt` is an explicit live diagnostic using a generated white JPEG. It consumes plan allowance, prints only outcome/count, and does not capture the screen. Do not run it as an ordinary test.

## Distribution

Local `make package` reuses the owned certificate-bound development identity. `make install` verifies archive paths/CRC, bundle ID, strict signatures and identical signing requirements, then atomically exchanges bundles; post-install failure rolls back. It deliberately refuses automatic migration to a different signing identity.

For public distribution, install your **Developer ID Application** certificate/private key and configure a notarytool Keychain profile yourself. Secrets never enter this repository. Then:

```sh
HARNESS_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' make package
./scripts/notarize.sh YOUR_NOTARY_PROFILE
```

The Developer ID path builds arm64 + x86_64, signs with hardened runtime/timestamp, and notarization verifies acceptance, staples the app and checks Gatekeeper. Those Apple-service steps require credentials and must actually succeed before calling an archive a notarized release. Moving from the local certificate to Developer ID is a one-time identity migration and may require fresh macOS permissions. Subsequent releases must preserve bundle ID/team identity. Never reset TCC, weaken Keychain protection or change system trust to suppress prompts.

`VERSION` is the release-version source. Bundle metadata records the source revision, dirty state, toolchain and architectures, without a developer home path or build-machine OS field. Release compilation remaps source/scratch paths; staged binaries have debugging information removed before signing. Source/binary archives pass the privacy scanner, which detects common credential signatures and absolute developer home paths. It is a release guard, not proof that arbitrary secrets cannot exist. Keep one canonical installed copy and only current generated distributions. Use a generic repository author identity when sharing Git history.

Satoshi is an unmodified official Fontshare font embedded for this app, with its FFL. A source recipient must obtain their own Satoshi Regular OTF from [Fontshare](https://www.fontshare.com/fonts/satoshi), place it at `Sources/HarnessEmitter/Resources/Fonts/Satoshi-Regular.otf`, and retain the accompanying license. The source archive excludes that binary; it is not offered as a reusable font library. Fonts register only in the running process.

## Acceptance and troubleshooting

Tested configuration: macOS 27.0.1 arm64/Xcode 27/Swift 6.4. macOS 14 is the deployment target; older OS versions, Intel runtime and Safari/Firefox have not been tested on real hardware. Universal compilation alone does not establish their runtime support. Windows/Linux are blueprint targets, not implementations in this repository.

After installation, verify Mode 2, saved keys, Screen Recording state and account status; quit/relaunch and repeat. Granted Screen Recording disables its request action. If macOS requests a restart, complete it. If a saved account is inaccessible, Continue with ChatGPT retries authorized recovery. Corrupt records are not overwritten. A local self-signed rebuild may need a new grant because the item's partition can be executable-hash bound, even after Always Allow; ordinary restarts are a separate check.

Physically test the controlled `fixtures/fullscreen.html` page in ordinary, native full-screen and HTML5 full-screen views. Capture once, cancel/recapture, scroll both ways, verify click-through/focus and persistent display. Repeat light/dark/colored panes, cropped/thick dividers, displays/Spaces and slow/offline requests. Record actual versions; do not save screenshots, response text or credentials as evidence. Third-party recorder behavior requires a separate observer test and never becomes a universal exclusion claim.

For shortcut conflicts, select unused function keys in Advanced. Audit/storage failures show a status or startup error; repair the underlying private-file problem and restart. Do not erase real audit records as a workaround. Network/model failures require manual retry and preserve valid credentials.
