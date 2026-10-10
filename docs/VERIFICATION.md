# Verification — 0.3.0

This document records executed checks, not a guarantee of bug-free behavior. Tested configuration: macOS 27.0.1 arm64, Xcode 27, Swift 6.4, SDK 27. Production runtime preferences, accounts and audit records are kept outside the repository and preserved during updates.

## Review and fixes

The preceding complete audit read all 100 tracked owned text files at its baseline (11328 lines), including production Swift/C, tests, scripts, fixtures, configuration, documentation and license text. Changed/new logic is reviewed separately. Vendored dependencies/generated binaries are not counted as source-line review. Font identity/registration/rendering and icon structure are checked separately.

The current source retains the earlier fixes for Mode 2 defaults, simple onboarding, durable settings/rollback, cancellable worker-based Keychain recovery, callback validation, background JPEG/masking work, finite native/file-I/O deadlines, hotkey cleanup, single-instance startup, account-context isolation and safe installation. Its feature-matched tests preserve these regressions.

New 0.3.0 regressions reproduced navigation overlap in light/dark layouts with faint partial dividers, faint color-only seams, wide rails inside window/desktop margins and Retina sampling. The detector now retains sustained weak boundaries, snaps grouped transitions to their strongest immediate gradient, and rejects navigation-sized spans. Existing cropped/thick-divider/scrollbar/card cases still pass. Phone photos were inspected as evidence; they are not exact screen-coordinate fixtures. Native pane detection remains heuristic.

Advanced now contains a multiline system-prompt editor and Restore Default action. Tests verify Unicode/multiline save, old-field migration, reset, malformed/oversized/control input, failed-save rollback, draft/busy behavior, separate process restarts and outgoing request instructions. Custom prompt text remains absent from audit events. The immutable settings snapshot reaches the provider; response buffering is unchanged.

Release scanning found absolute developer paths in older compiled binaries, despite clean current source. Prefix remapping and removal of debugging information before signing address binary output. The release gate detects common secret signatures and developer paths without printing matched values. Historical personal metadata is excluded from the clean shareable snapshot; old recovery history belongs outside the shared project.

## Executed checks

| Check | Result |
| --- | --- |
| Complete normal native suite | **283 tests, zero failures, 3 optional-reference skips**, 77.634s |
| Independent extracted-source native suite | 283 tests, zero failures, 3 optional-reference skips, 78.255s; licensed font supplied locally as documented |
| Pane regressions after color-only seam correction | 18 tests, zero failures, 2 optional-reference skips, 27.321s |
| Integrated prompt/settings/provider regressions | 63 tests, zero failures, 3.830s |
| Address Sanitizer, changed pane/prompt/provider paths | 81 tests, zero failures, 2 optional-reference skips, 80.168s; no sanitizer findings |
| Thread Sanitizer, changed pane/prompt/provider paths | 81 tests, zero failures, 2 optional-reference skips, 124.099s; no sanitizer findings |
| Native prompt-editor layout and rendered preview | Pass; usable wrapped document width, multiline save/reset/draft/busy assertions |
| Packaging/signing/privacy unit tests | 13 tests, zero failures; deliberate duplicate-ZIP fixture emits a Python warning |
| Independent raw/bundled preferences | Eight restart reads pass, including custom prompt and Mode 2 |
| Static checks | Python AST, shell syntax, Git whitespace and local documentation links pass |
| Release privacy regression | Prior binary archive correctly rejected for embedded developer paths |
| Universal release compilation | arm64 and x86_64 pass, 31.84s; both slices retain macOS 14.0 minimum |
| Final local package and installation | Signed 0.3.0 package passes strict signature checks, ZIP CRCs and privacy scanning; installed executable matches the archive |
| Clean source snapshot | Generic-author history; ZIP exactly matches tracked files except the restricted font binary; no Git/runtime/build data |
| Final process/Spotlight inventory | One running process and one indexed Harness.app, the canonical installation |

The unavailable optional screenshots are explicitly skipped. Generated light/dark/faint-seam/Retina cases execute; skipped references are not counted as successful real-image comparisons. Automated tests use generated images/windows and mock transport; they do not acquire desktop content or spend plan allowance.

## Release acceptance

The final local executable was built from revision `890c3f5`. Its compiler prefix maps and stripped debugging data pass the release privacy gate, and the staged, archived and installed signatures verify. The package build emitted warnings about unavailable remapped module-cache paths while generating debugging data; that debugging output is excluded from the signed release. The installed Advanced UI exposes the system-prompt editor and existing Mode 2, shortcuts and Screen Recording permission load correctly. Saved-account recovery is awaiting a protected Keychain grant; startup alone did not trigger a dialog. Account readiness and repeated restarts of this final executable are not yet verified.

A clean source ZIP excludes Git/runtime/build output and the restricted font binary; source recipients obtain their own Satoshi Regular OTF. Recovery history is kept outside the shareable project. The build blueprint documents reconstruction and native port contracts; **Windows/Linux implementations are not delivered by this repository**.

Public distribution requires the publisher's stable Developer ID identity and successful notarization, stapling and Gatekeeper acceptance. The local development build does not satisfy that external signing gate. A local self-signed executable update can require a new protected Keychain grant even after Always Allow; quiet ordinary reads suppress dialogs and explicit recovery is responsive. App code cannot override native authorization or complete protected system prompts.

Fresh physical-key capture/scrolling, browser layouts/full-screen, third-party recorder behavior, older macOS and Intel runtime remain native acceptance checks in [DEVELOPMENT.md](DEVELOPMENT.md). Compilation, synthetic tests and window flags do not establish every-browser/every-recorder behavior. Future native ports need their own hardware/desktop/signing acceptance described in [BUILD_BLUEPRINT.md](BUILD_BLUEPRINT.md).
