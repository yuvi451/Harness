# Build, verify and package Harness 0.6.1 from source on macOS

This is a clean-machine operational guide for the existing macOS implementation at code revision `6034926`. It provides commands to run **when a build is authorized**; none of them was executed for this documentation update. The app is a local screenshot assistant controlled by Option–Shift digit hotkeys and a separate read-only visibility detector. It uses the user's explicit ChatGPT sign-in, not an API key. The public [Sign in with ChatGPT flow](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) documents the dynamic client/issued `oaiapp_` client, loopback callback and scopes used here; preview/account availability remains an external gate. A successful compile, signed ZIP or synthetic test does not establish live account eligibility, physical keyboard dispatch, third-party recorder behavior, Intel runtime or macOS 14 runtime acceptance.

The repository should contain `Package.swift`, `Package.resolved`, `VERSION` (`0.6.1`), `Sources/`, `Tests/`, `Resources/`, `scripts/`, `fixtures/` and `Makefile`. The package has macOS 14 deployment target and exact `KeychainAccess` 4.2.2 dependency. `HarnessCore` owns settings/privacy/audit/research, `HarnessEmitter` owns app/account/capture/hotkey/presentation/provider, `HarnessDetector` owns scan/report, `HarnessApp` and `HarnessDetect` are executables, with C targets for Keychain policy and file-lock tests. For a from-empty-directory implementation that reproduces the source behavior, use [MACOS_BUILDER.md](MACOS_BUILDER.md); this guide assumes those files already exist. The full exact protocol and regression matrices are in [PROTOCOLS.md](PROTOCOLS.md) and [REGRESSION_CATALOG.md](REGRESSION_CATALOG.md), but the command sequence below is self-contained.

## 1. Prepare a clean Mac and source tree

Use full Xcode at `/Applications/Xcode.app`, not only Command Line Tools; Swift 6.2 or newer, Python 3, Git and the macOS SDK are required. The audited host used macOS 27.0.1 arm64, Xcode 27, Swift 6.4 and SDK 27, while the app's minimum deployment target stays macOS 14. A newer working toolchain is not proof that older target/runtime combinations were accepted. Select the full Xcode developer directory for this shell or allow `Makefile` and scripts to default to it. Do not change the global developer selection to make one repository work.

```zsh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
test -d "$DEVELOPER_DIR" || { print -u2 "Install full Xcode at this path or set DEVELOPER_DIR to its developer directory."; exit 1; }
xcodebuild -version
xcrun swift --version
xcrun --sdk macosx --show-sdk-version
python3 --version
git --version
```

Acquire source through the owner's Git remote or a reviewed clean source export; replace the placeholder with the actual approved URL/path. If using Git, check out the intended revision and inspect the worktree; for the specific 0.6.1 source baseline it is `6034926ff22b0e220af6560d1de1875874322f41`. A clean source export intentionally omits `.git` and the restricted OTF font binary. The current `scripts/package.sh` calls `git rev-parse HEAD`, so direct packaging of that extracted archive before Git initialization is unsupported. A builder may verify the supplied archive hash against its trusted receipt, review the contents, initialize a new local repository and commit the imported source; the package then records that **new import commit** as its build revision. Keep the original source-archive hash and claimed upstream revision as separate provenance evidence; never label the import commit as `6034926`. Do not run build scripts against an arbitrary unreviewed ZIP. The examples below assume the shell is in the repository root.

```zsh
# If Git source was supplied:
: "${HARNESS_REPOSITORY_URL:?Set HARNESS_REPOSITORY_URL to the approved source URL before this optional Git route.}"
git clone "$HARNESS_REPOSITORY_URL" Harness
cd Harness
: "${HARNESS_RELEASE_REF:?Set HARNESS_RELEASE_REF to the reviewed release ref from the source receipt.}"
git checkout "$HARNESS_RELEASE_REF"
test "$(git rev-parse --show-toplevel)" = "$PWD" || { print -u2 "This is not the project Git root."; exit 1; }
git status --short
cat VERSION

# If a clean source ZIP was supplied instead, extract it in a dedicated directory:
# ditto -x -k Harness-source.zip <clean-parent>
# cd <clean-parent>/Harness-source
```

For the source-ZIP route, compare `shasum -a 256 Harness-source.zip` with the sender's trusted receipt and inspect the extracted tree first. To enable the checked-in packaging script, initialize a local import commit in the extracted root **before** adding your separately licensed font. These commands configure a generic identity for this repository so later commits do not inherit a personal global Git identity. The private local exclude keeps the separately supplied OTF out of the import revision and source export; it does not change the tracked `.gitignore`:

```zsh
git init -b codex/harness-import
git config user.name 'Harness Maintainers'
git config user.email 'maintainer@example.invalid'
git add --all
git commit -m 'Import verified Harness source archive'
printf '%s\n' 'Sources/HarnessEmitter/Resources/Fonts/Satoshi-Regular.otf' >> .git/info/exclude
git status --short
```

Place the authorized OTF at the resource path after that import and verify `git status --short` is still clean. The package's `HarnessSourceRevision` now identifies the reviewed import commit. Retain the verified archive SHA-256 and upstream release identity alongside it in a separate build receipt; they are different identifiers.

The build requires `Sources/HarnessEmitter/Resources/Fonts/Satoshi-Regular.otf` and the corresponding `FFL.txt` notice. The source export omits the OTF deliberately, so obtain your own authorized copy and place it at that exact resource path before building. Preserve the license notice unchanged. The app registers the font only in its process with CoreText; do not install it globally. If the font is absent, the source has a fallback stack, but a font-fidelity claim cannot be made from that build. Keep reference screenshots, account records, `.env`, private certificates and real captures outside the source tree.

Use a unique scratch directory for each concurrent build under `/private/tmp`. Finder or file-provider metadata in synced Documents can invalidate ad-hoc signed XCTest bundles; the Makefile's default `/private/tmp/harness-build` and the packaging script's dedicated `.noindex` stage avoid that. Running multiple builds against one scratch directory also risks stale artifacts. The package lock file should resolve `KeychainAccess` 4.2.2 at its recorded revision; if resolution differs, investigate before treating the product as the audited baseline. Ordinary SwiftPM dependency download requires network access on a new machine; the app itself does not need to ship package-manager credentials.

## 2. Compile and run the fixture suites

Build and default tests use a scratch path outside synced Documents. `make check` runs `scripts/check.sh`, which does a debug `swift build` and `swift test`; it is a good first gate. `make test` alone uses synthetic fixtures and intentionally gates native AppKit windows and ScreenCaptureKit capture. Neither command is a live provider test. Each command below is a future instruction, not a result of this documentation task.

```zsh
make SCRATCH=/private/tmp/harness-clean check
make SCRATCH=/private/tmp/harness-test test
python3 -m unittest discover -s Tests/PackagingTests
make preferences
make privacy
```

Packaging tests exercise ZIP path traversal, duplicate/case/Unicode aliases and special entries; signed bundle identity, atomic installer swap and rollback; local signing reuse/partial-state refusal; and private-data scanning. The test suite intentionally constructs a duplicate ZIP entry, so its Python warning is expected if all assertions pass. `make preferences` compiles a tiny UUID-domain probe and checks raw executable and bundled app preference persistence across eight separate launches without touching production preferences. `make privacy` scans tracked content and reports only categories/file names of detected private material. Investigate any failure before release; do not print or copy matched secret bytes into a bug report.

For generated native window integration, first quit any installed Harness instance because Carbon shortcuts are global. Then opt in to native GUI fixtures. `test-capture` adds an actual ScreenCaptureKit frame of a generated selected window, requiring Screen Recording already granted to the test host; if permission is absent it may skip. These fixtures do not transmit images to a real provider. Run native suites sequentially, with their own scratch directory. A successful native registration fixture still does not establish a human pressing each physical shortcut.

```zsh
make SCRATCH=/private/tmp/harness-native test-native
make SCRATCH=/private/tmp/harness-capture test-capture

# Equivalent explicit flags if invoking SwiftPM directly:
HARNESS_RUN_OVERLAY_GUI_TESTS=1 swift test --scratch-path /private/tmp/harness-native-direct
HARNESS_RUN_OVERLAY_GUI_TESTS=1 HARNESS_RUN_NATIVE_CAPTURE_TESTS=1 \
  swift test --scratch-path /private/tmp/harness-capture-direct
```

Optional local screenshot-reference tests use `HARNESS_PANE_REFERENCE_PATH` and `HARNESS_CROPPED_REFERENCE_PATH`; absent files are skipped and are not passed comparisons. Never commit private screen images to satisfy them. The reference uses generated light/dark/seam/Unicode/font fixtures for ordinary tests. Targeted sanitizers can be run later with separate scratch paths; follow the selected toolchain's `swift test --sanitize=address` or `--sanitize=thread` support, and prefer test filters over running native GUI suites concurrently. The prior audit recorded 375 Swift tests, zero failures and three optional reference skips; 17 packaging tests; 47 Thread Sanitizer tests with no findings; 43 Address Sanitizer tests with one optional skip and no findings. Those figures are prior evidence for this code revision, **not** newly run results for this document.

The explicit `Harness.app/Contents/MacOS/Harness --check-chatgpt` mode is **not** part of the automated gate. It opens the saved account with explicit OS authorization if needed, sends a generated white JPEG through a real account and consumes plan allowance. Do it only when the human has authorized a live-account diagnostic. Default tests instead use fake account stores, synthetic OAuth/JWKS and fake HTTP responses; they cannot prove the account feature is currently offered to the user.

## 3. Produce a local signed ZIP without changing signing trust

The canonical local package command is below. It calls a release Swift build in a dedicated temporary stage; copies `harness` into `Harness.app/Contents/MacOS/Harness`, the SwiftPM resource bundle, icon, docs, fullscreen fixture, README, KeychainAccess license and separate `harness-detect`; strips symbols and remaps developer source/scratch paths before signing. It constructs an Info.plist with `CFBundleIdentifier=org.harness.research`, version from `VERSION`, `LSMinimumSystemVersion=14.0`, a screen capture usage description, `LSUIElement=false`, `LSMultipleInstancesProhibited=true`, build/toolchain/dependency metadata, Git revision and dirty flag. A Git checkout records its current commit; a reviewed source archive records the new local import commit created above. Keep the archive hash separately so those identities are not confused. Keep the stage outside synced Documents; the app is distributed inside `dist/Harness.zip`, not as a raw bundle in the synced repository.

```zsh
make SCRATCH=/private/tmp/harness-release package
python3 scripts/release_privacy.py dist/Harness.zip dist/harness-detect
```

Without `HARNESS_SIGNING_IDENTITY`, `scripts/signing.py` creates or reuses **one** local certificate-bound development identity in a dedicated Keychain, locked against concurrent bootstrap. It preserves its fingerprint and refuses partial state or silent rotation; it does not change certificate trust settings. A login-Keychain item holds the dedicated Keychain password; temporary private material is deleted. The package script strictly verifies signatures and writes `dist/Harness.zip` plus a signed `dist/harness-detect`. Never copy private signing material into the repo or paste its password/fingerprint output into a public issue. The local package is for local development; it does not establish public Gatekeeper acceptance.

The release privacy scan checks tracked bytes, all local Git objects/configuration/reflogs, release member names, comments and extra fields. It rejects local identity markers discovered at scan time, machine hostnames, developer home paths, private keys, supported provider/API/JWT signatures, credential files, Git/build/Finder metadata and ZIP owner fields. UTF-8 and both UTF-16 byte orders are checked. Diagnostics use entry numbers and labels, never filenames or matched values. Public endpoints, synthetic identities and required third-party notices remain intact. See [SHIPPING_PRIVACY.md](SHIPPING_PRIVACY.md) for the current release policy and limitations. If it fails, remove the offending build/source material and rebuild; do not bypass the scan for a real token. Prefix mapping, stripping, binary privacy scan and staged signing are part of the release mechanism, not optional documentation tidying.

Inspect actual archive and signature properties before installation:

```zsh
unzip -t dist/Harness.zip
HARNESS_INSPECT_DIR="$(mktemp -d /private/tmp/harness-inspect-XXXXXX.noindex)"
ditto -x -k --norsrc --noextattr dist/Harness.zip "$HARNESS_INSPECT_DIR"
plutil -p "$HARNESS_INSPECT_DIR/Harness/Harness.app/Contents/Info.plist"
codesign --verify --strict "$HARNESS_INSPECT_DIR/Harness/Harness.app"
codesign --verify --strict dist/harness-detect
lipo -archs "$HARNESS_INSPECT_DIR/Harness/Harness.app/Contents/MacOS/Harness"
```

Use the isolated, unique inspect directory and remove only that directory afterwards. Do not copy a staged app into a watched/synced folder before signature verification: extra FinderInfo/xattrs can invalidate a signed bundle. The archive's build metadata includes the actual architecture; the prior local development package was Apple Silicon only. Source `platforms: [.macOS(.v14)]` says minimum SDK target, not demonstrated macOS 14 runtime compatibility.

## 4. Install or update the canonical local app

Quit the running Harness first. `make install` invokes `scripts/install.py` against `dist/Harness.zip` and installs to `~/Applications/Harness.app`. The installer bounds archive entries (≤2,000) and decompressed total size (≤512 MiB), tests ZIP CRCs, rejects traversal, backslashes, duplicate/case/Unicode aliases and non-file/directory special entries, and extracts in a private temporary directory next to the destination. It requires the staged bundle ID `org.harness.research`, a strict valid code signature and a certificate-bound designated requirement. On update it also validates the existing app and requires the **same** signing requirement, then atomically exchanges bundles using macOS `renamex_np(RENAME_SWAP)`; if post-exchange validation fails, it exchanges back. A fresh install uses rename and also rolls back failed validation. The installer refuses to replace an unrelated app or proceed while `Harness` is running.

```zsh
make install
codesign --verify --strict "$HOME/Applications/Harness.app"
open "$HOME/Applications/Harness.app"
```

The installer preserves external runtime preferences, Keychain account records and TCC permissions by leaving them in their own OS locations; it does not force those grants to remain valid. A rebuild signed with a different certificate or executable hash can prompt for a new protected Keychain grant even if the app identity string is unchanged. If a saved account is inaccessible, use the app's explicit **Continue with ChatGPT** recovery control; do not erase the Keychain item, reset TCC, weaken Keychain UI policy or rotate the signing identity silently. First launch should show mode 2, settings, registered shortcuts and a clear account status. A second copied app bundle should activate/reopen the oldest running `org.harness.research` instance and exit before creating another account store or hotkey registration. That app singleton election uses `NSRunningApplication` launch date/PID; it is separate from cross-process account file locks. The optional `scripts/verify-single-instance.py` requires exactly one already Ready canonical app and its audit file; run it only under those preconditions.

## 5. Public Developer ID and notarization are separate gates

The local development certificate is not a public distribution identity. For distribution, the publisher supplies an Apple **Developer ID Application** certificate/private key and an existing `notarytool` Keychain profile, both outside the repository. `HARNESS_SIGNING_IDENTITY` must begin `Developer ID Application: `; the package script then builds **arm64 and x86_64**, signs with hardened runtime and timestamp, and verifies. `scripts/notarize.sh PROFILE` verifies that Developer ID/runtime signature, submits ZIP to Apple with a 20-minute bound, requires `Accepted`, staples/validates the app, runs Gatekeeper assessment and rearchives it. Never label a product notarized merely because signing or compilation succeeded.

```zsh
HARNESS_SIGNING_IDENTITY='Developer ID Application: Publisher Name (TEAMID)' \
  make SCRATCH=/private/tmp/harness-public package
./scripts/notarize.sh YOUR_EXISTING_NOTARY_PROFILE
```

Those commands are future publisher steps, not instructions to invent a credential. A move from a local certificate to Developer ID changes designated requirement and may require an explicit identity migration and renewed OS permissions; the installer refuses silent change. Universal binary architecture is a packaging result, not an Intel runtime test. Record actual `lipo`, signature, `spctl`, notarization and macOS 14/Intel physical acceptance outcomes separately. Run an end-to-end Screen Recording/Keychain check on each supported target only when authorized, with controlled synthetic content.

## 6. Produce a clean source artifact

`scripts/source.py` archives **reviewed committed tracked files only**, rejects a dirty Git worktree, scans every tracked file for private material, and omits every `.otf` binary. It writes `dist/Harness-source.zip` after using a private temporary archive. The receiver must obtain an authorized Satoshi OTF and put it back at the resource path, then run the same tests. The source ZIP excludes runtime accounts, audit logs, build products and Git metadata; retain a separate source revision/provenance receipt. Do not modify `.gitignore` to hide a dirty source tree before export.

```zsh
git status --short
python3 scripts/release_privacy.py
make source
python3 scripts/release_privacy.py dist/Harness-source.zip
unzip -t dist/Harness-source.zip
```

If documentation or other changes are still uncommitted during a future release, `make source` correctly refuses them. Commit reviewed changes first in the release workflow. Do not add a private OTF, account record, home path, screenshot or credential to the source archive.

## 7. Post-install acceptance and interpretation

Start with a generated or approved test window, an explicit connected test account only if available, and the controlled `fixtures/fullscreen.html`. Verify the *physical* Option–Shift–8 request/send, 5 queue, 9 clear/cancel, 0 saved-answer visibility, 1 position toggle and 7/6 line scroll with the actual keyboard layout. Check one-frame and ordered multi-frame behavior, queue capacity/expiry, clear-before-next-request even when hidden, no provider call for 0/1, three complete Unicode lines and no partial fourth row, adaptive font on/off and 9-point fallback, blank/colored/dark/light panes, click-through and focus, normal/OS fullscreen/HTML fullscreen separately, negative-origin and fractional-scale displays, selected-window movement, slow/offline stream and late cancellation. Record exact OS/browser/display/account/permission conditions. No automatic test can substitute for these physical cases.

For visibility research, use `harness-detect scan` to collect bounded metadata; `matrix` asks the operator to Save each of the nine mode/source combinations, wait ≥200 ms after configuration change and physically press the configured capture key. `correlate` produces a Markdown report with explicit `not_tested` and `N/A` where truth is absent. The CLI cannot press the key, capture, set a mode or establish third-party pixel invisibility. Its operator audit may be separate from the emitter audit, with identity and file-alias checks. Do not label a sharing-state-zero or missing SCK row as hidden pixels. Independent external/manual truth must be recorded before computing confusion counts.

If a shortcut conflicts, choose an unused mutable digit in Settings; 0/1/9 remain reserved. If audit/storage fails, sensitive actions stop until the underlying private-file/permission issue is fixed and the app restarts. If model/account/network fails, a new physical request is a manual retry after resolving the cause; partial streams are not auto-resubmitted. Missing optional screenshot references, unavailable live account, permission denial, unsupported model modality, Intel runtime, older OS runtime, physical keyboard and third-party recorder cases must be reported as **skipped/unverified**, never silently converted to a pass.
