# Harness 0.6.1 development and release reference

This reference accompanies [BUILD_FROM_SOURCE.md](BUILD_FROM_SOURCE.md) (clean-machine commands) and [MACOS_BUILDER.md](MACOS_BUILDER.md) (standalone reconstruction). The current source baseline is `6034926`; the documentation rewrite changes no application code or executable. All build/test/install commands below are instructions for a future authorized developer, not commands executed by this documentation task.

## 1. Toolchain and project layout

Use full Xcode rather than Command Line Tools alone, Swift 6.2 or newer and Python3. The audited host used macOS27.0.1 arm64, Xcode27, Swift6.4 and SDK27. The deployment floor is macOS14. SwiftPM's manifest tools version is5.9; that manifest declaration is separate from the compiler version needed by the current source/framework APIs. Do not change the target or concurrency mode just to suppress diagnostics without reviewing the affected contracts.

The only package dependency is KeychainAccess4.2.2, with exact version and resolved revision in Package.resolved. AppKit/Carbon/SCK/Security/CoreText/Vision/CryptoKit/CoreGraphics/ImageIO are native frameworks. Products are GUI `harness` and CLI `harness-detect`. Test support C code is test-only. `VERSION` is the semantic-version source for packaging; runtime bundle metadata also records source revision, dirty state, architectures and toolchain/dependencies.

Resources include procedural icon source plus generated PNG/ICNS, Satoshi Regular OTF and its unchanged notice. Source ZIPs omit the OTF; recipients obtain their own Satoshi resource from [Fontshare](https://www.fontshare.com/fonts/satoshi) and place it at `Sources/HarnessEmitter/Resources/Fonts/Satoshi-Regular.otf`. Preserve notices and the resource's licensing conditions. Missing font fallback prevents a runtime crash but does not pass the branded-font identity acceptance. The font registers in the process, not system-wide.

Use one dedicated scratch directory per concurrent compiler/sanitizer/package command under `/private/tmp`. Synced Documents can inject Finder/file-provider metadata into bundles and invalidate otherwise correct signatures. Source can remain in Documents; signed staging and XCTest products should not. Scripts default DEVELOPER_DIR to `/Applications/Xcode.app/Contents/Developer` without changing global selection. A developer with another Xcode path must set that environment variable explicitly.

## 2. Existing checkout versus source ZIP

A verified Git checkout already supplies HEAD and tracked-file metadata. Before release, confirm `git rev-parse --show-toplevel` identifies this project, `git status --short` is understood and only the reviewed tree is committed. A parent directory's unrelated Git repository is not this project. Preserve the source's existing dependency pin and personal runtime data outside it.

An extracted verified source ZIP lacks `.git` deliberately. Debug SwiftPM compilation does not need Git, but `package.sh` calls `git rev-parse HEAD` and `source.py` requires a clean tracked tree. Initialize a local project repository, locally exclude the separately supplied OTF if appropriate, inspect all staged files and commit the reviewed import with a generic local author. This yields an honest new import revision; do not forge the original audited hash. Keep the verified archive SHA-256 and upstream baseline as separate provenance. Exact commands are in [BUILD_FROM_SOURCE.md](BUILD_FROM_SOURCE.md).

Do not use a source archive as a place for credentials/certificates/screenshots to simplify setup. Do not commit signing keychains, private keys, `.env` values, actual audit logs or test-account responses. The repo's ignore policy and release privacy scanner are guards; a builder still reviews the staged list.

## 3. Command reference

| Command | Operation and prerequisites |
| --- | --- |
| `make help` | Names supported developer targets |
| `make SCRATCH=/private/tmp/harness-debug build` | Debug compile, no app launch |
| `make SCRATCH=/private/tmp/harness-debug test` | Default Swift tests; native GUI/capture gates remain off |
| `make SCRATCH=/private/tmp/harness-debug check` | Debug build plus default tests via scripts/check.sh |
| `make SCRATCH=/private/tmp/harness-native test-native` | Enables generated AppKit/native input tests; quit installed Harness first |
| `make SCRATCH=/private/tmp/harness-capture test-capture` | Adds explicitly opted-in selected-window native capture fixtures; needs Screen Recording already granted to host |
| `make signing-tests` | Python synthetic signing/archive/installer/privacy tests in disposable fixtures |
| `make preferences` | Eight independent raw/bundled preference restart reads in temporary domains |
| `make icon` | Regenerates icon from procedural DrawIcon.swift; source asset, not runtime behavior |
| `make SCRATCH=/private/tmp/harness-release package` | Release compile, strip/remap/privacy scan, metadata, local/public signing and ZIP |
| `make install` | Verify and atomically replace canonical installed bundle while it is closed |
| `make source` | Export clean reviewed tracked source; excludes OTF/Git/runtime/build data |
| `make privacy` | Scan tracked/release content for supported credentials/developer paths without printing matched values |

Native flags are `HARNESS_RUN_OVERLAY_GUI_TESTS=1` and additionally `HARNESS_RUN_NATIVE_CAPTURE_TESTS=1`. Default suites must not display an overlay or acquire screenshots. Native GUI suites create generated windows and register actual global bindings, so run them sequentially and close the installed app to avoid registration conflicts. Native capture takes its generated selected window; no fixture is sent to a real provider. Missing permission/reference images stay skipped with a reason, not mislabeled as passing.

Optional `HARNESS_PANE_REFERENCE_PATH` and `HARNESS_CROPPED_REFERENCE_PATH` point to private local image fixtures; never commit them. A phone photo is not a native coordinate fixture. Use deterministic generated seams/light/dark/Retina/Unicode/font cases before private references.

For changed memory or concurrency boundaries, choose relevant suites and fresh separate scratch roots:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  HARNESS_RUN_OVERLAY_GUI_TESTS=1 swift test --sanitize=address \
  --scratch-path /private/tmp/harness-asan --filter 'CompactOverlayTests|BatchLifecycleTests|AppearanceTests|SubmissionTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --sanitize=thread --scratch-path /private/tmp/harness-tsan \
  --filter 'ChatGPTAuthenticationTests|NativeCaptureCallbackTests|AccountFileLockTests'
```

The sole `Harness.app/Contents/MacOS/Harness --check-chatgpt` diagnostic sends a generated white JPEG through a real connected account and consumes allowance. It is not part of default/native synthetic tests. Obtain explicit authorization and use a dedicated test account before invoking it. Never invoke real8/5 during automation merely to check a button label.

## 4. Packaging and local installation order

1. Review/commit the exact intended tree; `VERSION` and docs should match behavior. `HarnessSourceDirty` is evidence, not something to force false by hand.
2. Choose a dedicated temporary scratch directory. Release compilation remaps source/build prefixes to generic paths; strip debugging data before signing. Keep build errors/warnings separate from delivered runtime products.
3. Stage the GUI executable, SwiftPM resource bundle, icon, notices and Info.plist. Metadata includes bundle ID/executable, macOS14 floor, version, source revision/dirty state, architecture, toolchain/dependency versions and Screen Recording purpose text.
4. Preserve the existing owned local signing identity. Bootstrap a local development identity only on a clean first setup; partial/inconsistent identity state must fail instead of generating a new identity silently. Public builds take the explicit publisher Developer ID path.
5. Sign/strictly verify staged app and detector, create `dist/Harness.zip`, verify final archive/CLI and scan for supported private values/developer paths.
6. Close the canonical app. The installer validates bounded ZIP structure/CRC, safe normalized paths and aliases, expected bundle identity, strict signatures and unchanged update requirement before atomically exchanging bundles. A failed post-exchange check rolls back. Existing account/preferences/audit/TCC data stays outside this operation.
7. Confirm installed/archive executable and Info.plist bytes, version/revision/dirty metadata and strict signature. Reopen only the canonical `~/Applications/Harness.app`; verify Advanced controls/Mode2/preferences and a second ordinary restart.
8. Export committed source separately; verify ZIP membership/bytes and that OTF/runtime/Git/build data are excluded. Keep immutable delivered archive hashes and release receipt.

An unsigned raw bundle left in a synced folder is not the delivery product. Package the app once and install its verified archive. Do not modify resources/docs inside an installed signed app to update documentation: that invalidates the signature. A documentation-only update belongs in source/docs and a separate docs archive until a future authorized app build.

## 5. Public distribution

Public packaging uses an explicit `Developer ID Application: …` identity, compiles arm64+x86_64 and signs with hardened runtime/timestamp. Local packaging targets the current host architecture. Compilation for both slices is distinct from running on Intel and the oldest deployment OS.

```sh
HARNESS_SIGNING_IDENTITY='Developer ID Application: Publisher Name (TEAMID)' \
  make SCRATCH=/private/tmp/harness-public package
./scripts/notarize.sh YOUR_NOTARY_PROFILE
```

The notary profile and certificate/private key remain outside the repository. The script submits the signed product, requires accepted status, staples and checks Gatekeeper before final public acceptance. A Developer ID switch from the local certificate is an explicit identity migration with potential renewed OS authorization; it is not a routine same-identity local update. Do not reset TCC or alter trust/Keychain policy to hide prompts.

## 6. Troubleshooting without losing state

| Symptom | Investigate | Required handling |
| --- | --- | --- |
| SDK/framework symbols unavailable | Full Xcode path/compiler/SDK and macOS target | Use supported toolchain; no blind API deletion |
| XCTest signature invalid in synced Documents | Build scratch/staging metadata | Move generated products to dedicated temporary scratch; preserve source |
| Global shortcut registration fails | Running canonical app, duplicate test process, another app's binding | Release competing binding or choose unused mutable digits; all modifiers remain Option+Shift |
| Adaptive control missing | Running bundle path/version/revision; stale duplicate app | Open canonical installed verified version; do not assume source editing rebuilt it |
| Account unavailable after replacement | Protected Keychain authorization for new executable hash | Explicit Continue with ChatGPT recovery; preserve/cannot bypass record or OS prompt |
| Corrupt/unreadable account | Protected record/schema/authorization/storage | Fail closed; never overwrite corrupt data or use another app's tokens |
| No pane/font estimate | Bounded heuristic confidence, missing face, captured scope | Correct9pt fallback/default font; do not request an extra screenshot silently |
| Old answer after settings change | Transaction/re-render/generation/display snapshot | Reuse valid saved metadata; block stale geometry until9 |
| Mixed text clips/partial fourth row | Uniform fallback metrics, TextKit leading, precise clip bounds | Measure complete rows and retain exact viewport after native tiling |
| Queue sends another capture | Queue consumption branch/expiry/configuration | Send valid queue exactly once; no new acquisition in that branch |
| Empty/incomplete stream seems successful | Response stage/summary/nonblank/service audit | Do not publish/history; manual new request only |
| Report missing failed attempts | External emitter versus operator log | Merge both and retain diagnostics; no duplicate same-file read |
| Report corrupts input | Canonical/inode aliases or hard link during lock wait | Reject aliases before writing; recheck opened output under lock |
| Release contains home paths | Prefix maps, stripped debug/source metadata, final scanner | Correct generated release artifacts before signing/delivery |

Do not erase real logs, reset accounts, collect private screenshots or spend plan allowance as a shortcut around diagnosis. Root-cause fixtures in the regression catalog are the starting point.

## 7. Native acceptance after synthetic tests

Use the controlled [full-screen fixture](../fixtures/fullscreen.html) with a dedicated authorized account and generated task. Physically check8 request/send,5 queue,9 clear/cancel,0 same-answer hide/restore,1 both positions and7/6 complete-row scrolling. Assert no acquisition/inference for0/1, new request blocked while hidden, queue order/expiry/bounds and held-key coalescing.

Test ordinary/native full-screen/HTML5 full-screen separately; at least two displays with negative origins and different scales; mixed Unicode/trailing blanks; dark/light/colored panes; uncertain/tiny seams; adaptive on/off and absent/alias fonts; low/high JPEG limits and masks; offline/slow/late-cancelled responses; task cancellation during audit/Keychain/model refresh/save; duplicate launch and updated executable authorization. A synthetic press through app automation does not prove Carbon physical dispatch.

Recorder acceptance needs a separate named observer/OS/share scope and independent truth. Window properties/API success/metadata omission do not prove exclusion. Windows reconstruction needs its own native input/vault/capture/DPI/installer acceptance and cannot inherit macOS evidence. [VERIFICATION.md](VERIFICATION.md) is the executed ledger; [REGRESSION_CATALOG.md](REGRESSION_CATALOG.md) is the fixture contract.

## Source and release identity hygiene

The shipping policy is [SHIPPING_PRIVACY.md](SHIPPING_PRIVACY.md). Use a repository-local generic author/committer identity (`Harness Maintainers`, `maintainer@example.invalid`), and never inherit a developer's personal global identity for distributable history. Review local Git remotes, configuration, all reachable/unreachable objects and reflogs as well as the current files. Use a clean reviewed source export for handoff; exclude Git/build/editor/Finder metadata, logs, credential stores, private certificates, screenshots and licensed font binaries that require separate acquisition. Preserve upstream copyright/license attribution and public endpoint/client identifiers.

The release privacy guard detects the scanning machine's identity at runtime without storing it in the source, checks UTF-8 and both UTF-16 byte orders, and reports only entry numbers and issue classes. Check archive member names, comments and extra fields as well as file contents. Strip ZIP owner IDs and extended-attribute/resource-fork containers. Review opaque, encrypted and arbitrarily named private data manually; a pattern scanner cannot prove the absence of all secrets. Keep runtime login records and signing keys in their OS stores outside the product tree. Sanitizing a source export does not revoke keys, wipe runtime accounts, change a signed binary or establish notarization/Windows acceptance.
