# Harness — macOS 0.6.1

Harness is a native screenshot assistant. A physical global shortcut captures a selected scope, submits processed screenshots through the user's explicitly connected ChatGPT plan, and presents a completed plain-text answer in a small, nonactivating, click-through popup. Screenshots are never acquired continuously. The current implementation is macOS; the Windows document is a proposed reconstruction and parity contract, not a tested Windows release.

**Documentation baseline:** application version 0.6.1, audited implementation revision `6034926ff22b0e220af6560d1de1875874322f41`, documentation rewritten 2026-10-13. This documentation-only revision changes no application code, version, installed binary or runtime data. Prior signed release archives contain the documentation snapshot from their build; use this documentation set for the expanded guides.

## Start using the existing macOS app

The minimum deployment target is macOS 14. The existing local development package is Apple Silicon. Public universal distribution requires the publisher's Developer ID identity and successful notarization; an Intel build is not evidence of Intel runtime acceptance.

1. Extract `dist/Harness.zip`. Install the single `Harness.app` in `~/Applications`; do not run duplicate copies from build folders.
2. Open Harness. Its status/settings window appears; no screenshot or inference starts merely because it opened.
3. Grant Screen Recording when requested. Follow the operating system's restart instruction if permission is not immediately usable.
4. Choose **Continue with ChatGPT**. Complete browser authorization and any explicit protected Keychain recovery yourself. A saved but inaccessible account does not authorize submission.
5. Use the top-row number shortcuts below. Fn/Globe is unnecessary. All bindings use Option+Shift.

| Shortcut | Exact action |
| --- | --- |
| Option+Shift+8 | Send the entire screenshot queue as one question; if the queue is empty, capture one screenshot and request an answer |
| Option+Shift+5 | Capture and queue one processed screenshot without transmitting it |
| Option+Shift+9 | Cancel pending work, clear the answer, presentation metadata, screenshot queue and retained answer context |
| Option+Shift+0 | Hide or restore the same saved answer, preserving its frame and reading position; no capture or request |
| Option+Shift+1 | Switch **Automatic pane / cursor** and **Bottom left (small)**; reuse saved presentation metadata; no capture or request |
| Option+Shift+7 | Scroll up by complete text rows |
| Option+Shift+6 | Scroll down by complete text rows |

A saved answer blocks another capture or queue operation **even while hidden**. Clear it with 9 before starting the next question. Hide/show is not a new request. Position switching does not discard a pending screenshot queue. Capture/queue/scroll digits can be changed to distinct values 2–8 in Advanced; 0, 1 and 9 remain reserved. Legacy function-key preferences are repaired as a group while preserving usable numbers.

## What the popup does

Automatic placement uses a substantial detected content pane and the cursor position sampled for that capture. It does not follow the mouse continuously. When a pane cannot be established or cannot contain a complete rendered row, the answer uses compact bottom-left placement on the intended display. Bottom-left uses 9-point text and content-fitted width, normally between 96 and 420 points. Automatic placement normally uses bundled Satoshi Regular at 14 points, with the `ss03` stylistic alternate.

**Advanced → Match captured text font, size and weight (experimental)** enables bounded, local OCR and comparisons with installed fonts. It estimates the font face, size and weight; it cannot recover missing fonts, arbitrary variable axes or indistinguishable aliases. Uncertain estimates use the default. Bottom-left remains 9 points regardless of an adaptive estimate. Background sampling uses the existing screenshot and picks the higher-contrast black/white ink; it performs no extra capture.

The popup shows at most three complete wrapped rows. Longer answers scroll with 7/6; mixed emoji, CJK, Arabic, combining characters and blank lines must remain fully clipped to row boundaries. The popup does not accept focus, mouse input, selection, active links, Markdown, attachments or code execution. It has no idle dismissal. The former cursor-box mode is removed.

## Screenshot queue and retained content

At most six processed JPEGs are held in capture order in memory. Their five-minute lifetime starts with the first screenshot and does not reset when another is added. A successful send consumes the queue before submission, so failed/cancelled requests are never automatically replayed. Clear, relevant settings/account changes, failure and termination release application references. Queue expiration does not send anything.

Requested screenshots and recent answer context are transmitted to OpenAI using the connected ChatGPT plan. Credentials persist in macOS Keychain; ordinary preferences persist in an explicit UserDefaults domain. Images and response history are not written as content files. Reference release does not promise physical RAM erasure or control over OS swap, diagnostic copies or provider retention. Experimental window sharing flags do not guarantee exclusion from arbitrary recorders.

## Documentation map

| Document | Read it for |
| --- | --- |
| [Detailed behavior and algorithms](docs/SPEC.md) | Every current feature, default, resource limit, state transition, geometry, detector and presentation rule |
| [Architecture and ownership](docs/ARCHITECTURE.md) | Components, interfaces, task ownership, generations, transaction/rollback ordering and dependency boundaries |
| [Wire/storage protocols](docs/PROTOCOLS.md) | Exact preferences, OAuth/JWT, request/SSE, audit, detection and calibration schemas with synthetic examples |
| [Security and privacy](docs/SECURITY.md) | Content/credential boundaries, retention, consent, capture scope, file protection and release identity |
| [Shipping privacy](docs/SHIPPING_PRIVACY.md) | Personal-data cleanup, generic Git identity, safe export contents and verification limits |
| [Development and release reference](docs/DEVELOPMENT.md) | Toolchain, commands, source/export/signing behavior and troubleshooting |
| [Build the existing source step by step](docs/BUILD_FROM_SOURCE.md) | A clean machine, licensed resources, debug/test/release/install commands and expected outcomes |
| [Standalone macOS builder](docs/MACOS_BUILDER.md) | Reconstruct the complete product from an empty repository, with phase gates and native implementation contracts |
| [Standalone Windows builder](docs/WINDOWS_BUILDER.md) | Recommended Windows stack, native API equivalents, full implementation sequence, parity gates and platform limits |
| [Regression and edge-case catalog](docs/REGRESSION_CATALOG.md) | Reproduction conditions, intended outcomes, existing regression names and Windows acceptance requirements |
| [Verification evidence](docs/VERIFICATION.md) | What was actually executed for 0.6.1 and what remains unverified |

For an LLM reconstruction, provide the corresponding standalone builder first. Supply this whole documentation folder when possible so the precise protocol and regression references travel with it. The guides contain implementation instructions for future work; this documentation task did not execute those instructions or build either app.

## Developer entry points

Full Xcode, Swift 6.2+ and Python 3 are required. KeychainAccess is pinned to 4.2.2. Keep each concurrent build's scratch directory separate and outside synced Documents. Source exports omit the Satoshi font binary; obtain your own resource as described in the build guide and preserve its notice. Commands below are examples for a future authorized build:

```sh
make SCRATCH=/private/tmp/harness-dev test
# Quit the installed app before native hotkey tests:
make SCRATCH=/private/tmp/harness-native test-native
# Explicit selected-window native capture fixtures, with permission already granted:
make SCRATCH=/private/tmp/harness-capture test-capture
make signing-tests preferences
make SCRATCH=/private/tmp/harness-release package
make install
make source
```

`test` keeps GUI/capture fixtures gated. `test-native` creates generated windows and registers native hotkeys. `test-capture` additionally acquires the generated selected window; no test images are sent to a real provider. The explicit `--check-chatgpt` diagnostic is different: it uses a real account and consumes plan allowance, so it requires specific authorization.

The last code audit ran 375 Swift tests with zero failures and three optional image-reference skips, 17 packaging tests, and targeted Address/Thread Sanitizers with no findings. It verified installation, archive identity, preference persistence and Advanced controls. Physical Carbon shortcut dispatch and live-account inference remain unverified; the installed saved account required explicit recovery. No Windows runner was available. Consult the evidence ledger before treating a proposed acceptance step as a passed test.
# Harness
