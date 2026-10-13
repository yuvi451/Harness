# Harness 0.6.1 verification and evidence ledger

This ledger separates previously executed code checks from proposed acceptance and the current documentation-only rewrite. The implemented baseline is `6034926ff22b0e220af6560d1de1875874322f41`, version0.6.1. Historical tests ran on2026-10-13 with macOS27.0.1 arm64, Xcode27, Swift6.4 and SDK27. Deployment remains macOS14; a target declaration is not an older-OS runtime result.

## 1. What this documentation task did

The requested rewrite explains the current product, architecture, data/wire contracts, privacy boundaries, build/reconstruction processes and regression defenses, and supplies a proposed Windows equivalent. It reads source/tests/scripts and current primary API documentation. It updates Markdown and packages documentation.

**No application was built, tested, launched, installed or changed during this rewrite.** No dependencies were installed, credentials accessed, screenshots acquired or provider requests sent. Commands and test plans in the builder documents are instructions for future implementation; a reader must not treat their presence as executed evidence.

Documentation validation checks local links, referenced test names, baseline/default/limit consistency, prohibited stale-feature claims, Markdown structure and delivered archive membership/CRC. It also verifies only README/docs changed and application/source/script/version bytes remain at the code baseline. The documentation receipt travels with the delivery archive; the current Git documentation revision may differ from the application's tested code hash without changing code behavior.

## 2. Previous source audit scope

The0.6.1 code audit reviewed every owned production Swift/C file, GUI/CLI entry, test, packaging/build script, configuration, controlled fixture and maintained document. Independent account/provider, core/detector and capture/presentation reviews supplemented complete application review; changed callers/logic were reviewed again after implementation. The recorded final owned-text snapshot was115 files/14,706 lines; generated products, binary assets, third-party dependency internals and font-license legal interpretation were excluded. Notices stayed unchanged.

The old reconstruction/port blueprint was removed because it duplicated stale requirements. This rewrite replaces that missing builder role with detailed current standalone macOS/Windows guides, explicit protocols and a scenario catalog. It does not restore obsolete function keys, cursor box, idle dismissal or partial streamed popup text.

## 3. Reproduced0.6.1 defects and causal fixes

| Defect witnessed before correction | Trigger | Implemented defense | Regression evidence |
| --- | --- | --- | --- |
| Refresh returned stale credentials after HTTP completion | Local/other-controller disconnect or rotation runs before waiter resumes | Local generation plus reread/entire protected registration/token/permission comparison after await | New authentication waiter tests reject every fixture result |
| Joined caller cancellation waited for owner HTTP | Owner refresh deliberately suspended; secondary caller cancelled | Independent cancellable waiter gate; owner remains active | Cancellation completes before releasing owner; one refresh succeeds |
| Second disconnect aborted earlier remote revocation | Two selected registrations disconnect while first revoke is suspended | Bounded independent per-client workers; explicit unconfirmed/displaced warning | Both attempts retained; older failure cannot disappear behind newer connection |
| Partial fourth row after mixed-font scrolling | Latin rows followed by emoji/CJK/Arabic using fallback glyph fonts | Uniform paragraph line height and `usesFontLeading=false`; exact clip bounds | Native mixed-row scrolling fixtures count complete rows only |
| Tiny pane clipped its one visible row | Base font admitted35pt pane, actual fallback-glyph row43pt | Measure row, rebuild9pt bottom-left fallback before fitting | Native tiny-pane regression remains within complete-row geometry |
| Lower-contrast ink on sampled midtones | Gamma-average threshold on green/blue/gray backgrounds | Linear sRGB luminance and greater black/white contrast | Midtone arithmetic/appearance fixtures |
| Saved answer stayed at old position/font after Save | Hidden detected-pane answer then pinned-position Save | Metadata re-render preserving text/visibility/reading character | Frame/font updates with one capture/provider call total |
| Changed display geometry could reach submission/restoration | Display frame changes during capture or while answer hidden | Before/after capture and before presentation/restore map checks | No provider call for inconsistent capture; hidden answer stays hidden |
| Empty successful completion entered history | Provider summary exists with empty/whitespace text | Nonblank completion gate before history/publication; cancellation after commit | No history/publish; image references released |
| Position shortcut poisoned matrix config forever | Legacy applied settings event lacks source/timestamp | Exact legacy-shape exception plus complete current producer metadata | Valid later arm/config; malformed other partial events still fail |
| Matrix report overwrote its audit input | Input aliases `report.md` through path/inode | Same canonical/inode alias guard as correlate before writing | Matrix and correlation direct/ancestor/hard-link fixtures |
| Hard link introduced during report lock wait was truncated | Writer validates, waits, then alias created | Repeat type/owner/link-count validation after lock | Original and alias bytes preserved |
| Separate operator attempts vanished from report | Matrix emitter input differs from operator output audit | Merge both readers/results/issues; deduplicate same-file aliases | Failed attempt/read issue retained in correlation |
| Invalid matched sample undercounted indeterminate | Identity match plus fatal dataset read/schema issue | Increment indeterminate while retaining separate match count | Correlation fixture asserts invalid metrics/counts |
| Default tests unexpectedly displayed native windows | Ungated batch/compact-overlay fixtures | Existing native GUI opt-in helper applied | Default-gate run intentionally skips GUI fixtures |

These reproduce specific failures; they are not proof all future defects are known. The catalog marks new0.6.1 regression cases separately from preexisting tested guards rather than inventing historical versions for old tests. [REGRESSION_CATALOG.md](REGRESSION_CATALOG.md) provides exact test names and Windows requirements.

## 4. Previously executed code results

| Executed check | Exact result | Scope |
| --- | --- | --- |
| Final full suite with GUI/native selected-window capture enabled |375 tests,0 failures,3 optional-reference skips;109.247s test execution | Final0.6.1 production code after refresh cleanup review |
| Account/core/detector changed-path integration |83 tests,0 failures | Account refresh/revokes, report/matrix/CLI/correlation/JSONL |
| Presentation/application/capture/submission integration |61 tests,0 failures,2 optional-reference skips | Changed native presentation and lifecycle paths |
| Address Sanitizer |43 tests,0 failures,1 optional-reference skip; no sanitizer findings | Compact overlay, batch lifecycle, appearance, submission |
| Thread Sanitizer |47 tests,0 failures; no sanitizer findings | Authentication, account locks, native callbacks |
| Default GUI-gate acceptance |48 tests,0 failures,41 intentional GUI skips | Ordinary test mode does not show affected native fixtures |
| Packaging/signing/privacy synthetic unit tests |17 tests,0 failures | Archive structure, identity/bootstrap, atomic install/rollback, release privacy |
| Raw/bundled preference process restarts |Eight reads passed | Temporary domains, ordinary settings, raw executable versus own-bundle domain |
| Source/static validation |Python AST, shell syntax, whitespace/local links passed | Owned scripts/configuration/docs |

375 is total executed test cases, including three skipped cases;372 performed bodies. Address/Thread Sanitizer are targeted checks, not sanitization of every production path. Default-gate skips are intentional and must not be reported as native passes. The packaging suite's deliberately duplicated ZIP entry produces an expected Python warning.

The three optional references were absent local screenshot fixtures. Generated light/dark/seam/Retina/font/Unicode cases ran; skipped references are not successful actual-image comparisons. Native capture uses a generated selected window and tests use fake HTTP/account data; they do not upload desktop content or consume ChatGPT allowance.

## 5. Previous release, install and visual checks

The local0.6.1 release compiled arm64, remapped/stripped debug source paths, passed private-content scanning, strict app/detector signature verification and ZIP CRCs. Bundle metadata recorded the original clean source revision before local Git anonymization; its equivalent anonymized code baseline is `6034926`. The existing signed binary metadata was preserved because changing it would require rebuilding and resigning. The installer preserved the existing owned designated signing requirement and atomically updated the canonical installation.

The installed/archive app matched all nine app files byte for byte. The source archive had118 entries matching the119 tracked source entries except the intentionally omitted OTF. The original Documents/Harness tree matched all119 tracked bytes after sync; the obsolete blueprint was absent. Changed original files and the0.6.0 installed app were backed up before replacement. All ordinary preference-file bytes remained unchanged through installation and relaunch.

Actual Advanced UI checks observed the adaptive font/size/weight toggle, all uniform Option+Shift digits, Mode2, Screen Recording granted and exactly two position entries: automatic and small bottom-left. Duplicate-bundle test exited/reopened the same canonical instance without another audit launch/hotkey session. A second ordinary relaunch preserved preferences; its fresh startup session contained no capture/inference events.

These results belong to that immutable release/delivery receipt. A later documentation commit is not a new executable build. Do not edit installed signed resources or rewrite the old package's version/revision to imply otherwise.

## 6. Unverified and external gates

| Area | Current evidence / remaining acceptance |
| --- | --- |
| Physical Carbon shortcut dispatch | Native registration and fake lifecycle tests passed; synthetic app automation did not establish actual physical keyboard dispatch |
| Live-account inference | Not run for this release; saved account was inaccessible and needs explicit Continue with ChatGPT recovery |
| Protected recovery | Synthetic cancellation/policy tests passed; app cannot grant/bypass a user's native authorization dialog |
| Exact adaptive font identification | Generated installed-font/body-text fixtures pass; unknown/missing/alias/variable/non-English cases remain heuristic |
| Browser/native/HTML5 full-screen and all Spaces combinations | Native window property/layout checks exist; named browser/hardware combinations need direct acceptance |
| Third-party recording exclusion | No universal claim; public window flags/metadata alone are not pixel truth |
| Multiple displays under all hot-plug/change-and-return races | Snapshot/geometry fixtures pass; hardware and unobserved intermediate changes remain limits |
| Intel/oldest supported macOS runtime | Local release is arm64 on audited host; deployment declaration/previous compilation do not prove runtime acceptance |
| Developer ID/notarization/public distribution | Local owned development signing passed; publisher credentials/Apple acceptance/stapling/Gatekeeper remain external |
| Windows app | No implementation/build/tests/runner/hardware acceptance here; blueprint and native gates only |

## 7. How a future builder records evidence

Use synthetic isolated fixture data first. Record toolchain, source revision, dirty state, command, counts/skips/failures, sanitizer result and fixture scope. Preserve the before-fix failing test and after-fix result for causal bug fixes. Do not label compilation, metadata omission, unrun instructions or absent screenshots as acceptance.

Run native GUI suites sequentially with the installed app closed. Use actual physical keys for input acceptance and a specifically authorized test account/generated screenshot for live inference. Name each browser/recorder/OS/share scope, use independent truth and retain unsupported/indeterminate outcomes. Windows must record its own capture/window/DPI/vault/hotkey/filesystem/signing results. Every claimed parity cell requires a native receipt, not a macOS proxy.

The full future sequence is in [BUILD_FROM_SOURCE.md](BUILD_FROM_SOURCE.md), [MACOS_BUILDER.md](MACOS_BUILDER.md) and [WINDOWS_BUILDER.md](WINDOWS_BUILDER.md). No sequence is executed simply because this documentation describes it.

## Personal-data cleanup verification — 2026-10-13

The cleanup changes release tooling and documentation; application Swift/C behavior and existing signed binaries are unchanged. Nine new release-privacy regression methods extend the prior two, and all **26 packaging tests** pass. Those cases cover UTF-16 paths/tokens, personal identifiers in content/member names, local hostnames, additional provider-key signatures, Git/build/Finder entries, non-disclosing diagnostics, ZIP comments/owner fields, clean synthetic archives and repository metadata. The existing Swift/sanitizer results above are historical evidence; they were not rerun for this tooling-only cleanup.

Local macOS and legacy Windows repository histories were recreated with generic author/committer identities, personalized historical document text was replaced, and local remote paths were removed. Old unreachable objects and reflogs are not retained in the sanitized repositories. Commit IDs changed; document references now identify the equivalent anonymized source baseline. Public source exports omit Git, build/runtime data, private logs and the separately licensed OTF. Old exports are sanitized independently, and their previous ZIP hashes are superseded. See [SHIPPING_PRIVACY.md](SHIPPING_PRIVACY.md).
