# Build and port Harness, step by step

This is a reconstruction specification for an AI coding assistant and a human maintainer. The existing implementation is **native macOS**. Windows and Linux sections specify new adapters to build and test; they are not completed ports. Follow the phases in order, retain failing regression cases, and record actual validation. A prompt, test suite or operating-system flag cannot guarantee that nothing will ever fail.

## 1. Give the coding assistant this starting prompt

```text
Build a native desktop screenshot assistant using this blueprint and the
current SPEC, SECURITY, ARCHITECTURE and source files as reference. Target OS:
<macOS, Windows, or one named Linux desktop/session>. Implement that OS's native
adapters; do not pretend AppKit/ScreenCaptureKit/Carbon work elsewhere.

First read all owned source, tests, scripts and documentation. Inventory each
file and its responsibility. Keep source compact, feature-organized and typed.
Use one owner for application state, explicit cancellation and generation guards.
Write a failing regression before each behavioral fix. Run the full suite after
integration. Preserve real runtime credentials/preferences outside the repository.

Use supported Sign in with ChatGPT registration and OAuth, not credentials from
Codex, ChatGPT/browser cookies or another app. Fetch current official contracts
before implementing network or OS APIs. Never print tokens, callback URLs,
private signing material, screenshots, responses or custom instruction text.

Keep onboarding simple: Screen Recording authorization where the OS requires
it, Continue with ChatGPT, then keyboard capture. No required model/prompt setup.
Default to Mode 2 every launch, report capabilities honestly, and preserve other
settings. Do not promise universal recording exclusion or website invisibility.

After each phase, show changed files, meaningful test results, observed limits
and the next phase. Use generated fixtures for automated testing. Request human
interaction only for protected system prompts and real physical-key acceptance.
Finish a reviewed, signed package and clean source archive; do not declare a
public release before native signing/notarization/installer acceptance succeeds.
```

Replace the OS placeholder before starting. For Linux also specify X11 or Wayland, compositor, distribution, package format and minimum versions. For Windows specify supported OS builds, architecture and installer format. For macOS specify deployment target and supported hardware. The product requirements below stay constant; native capabilities may differ.

## 2. Rebuild the existing macOS source first

### Prerequisites

1. Install full Xcode, open it once, accept its license and let required components finish. Command Line Tools alone are insufficient for the native GUI/capture integration checks used here.
2. Have Git, Make, Python 3 and a Swift toolchain supporting this package's concurrency implementation; current development requires Swift 6.2 or later and a macOS 14+ SDK.
3. Obtain Satoshi Regular OTF yourself from [Fontshare](https://www.fontshare.com/fonts/satoshi). Preserve the FFL license. The source archive intentionally omits the restricted font binary; place it at `Sources/HarnessEmitter/Resources/Fonts/Satoshi-Regular.otf`. Do not substitute another file named Satoshi without checking its real font metadata.
4. For public distribution, obtain your own Apple Developer ID Application identity and configure a notarytool Keychain profile. These are maintainer credentials, not repository contents. A development certificate is sufficient only for a local build.
5. No OpenAI API key or embedded OAuth client secret is needed for the implemented public-client sign-in route. Each installation registers its own identity. Account eligibility, plan permission and model availability remain provider-controlled.

From an extracted source archive, use a folder of your choice. Run commands from its root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift --version
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
python3 --version
git init -b codex/harness
git config user.name 'developer'
git config user.email 'developer'
git add .
git commit -m 'Import reviewed Harness source'
make SCRATCH=/private/tmp/harness-clean build
make SCRATCH=/private/tmp/harness-clean test-native
make signing-tests preferences privacy
```

Skip `git init` if you already cloned a repository. Initialize/commit before packaging because release metadata and source export require Git. Never run two SwiftPM commands against one scratch directory simultaneously. The only pinned external package is KeychainAccess 4.2.2; resolve the exact `Package.resolved` revision. Generated build output stays out of the source tree.

```sh
make SCRATCH=/private/tmp/harness-clean package
# Close any installed Harness before an update.
make install
make source
python3 scripts/release_privacy.py dist/Harness.zip dist/Harness-source.zip dist/harness-detect
```

End users receive an app, not a compiler/toolchain. Keep one canonical installed app. A source ZIP is not a runnable application. The locally signed app is not a notarized public release. Follow [DEVELOPMENT.md](DEVELOPMENT.md) for the Developer ID and notarytool sequence.

## 3. Freeze the product contract

Implement these observable behaviors before refining appearance:

- Startup opens a small status/sign-in window. It discloses that physical-key screenshots and recent answer context are sent to OpenAI. It never captures merely because it launched, gained focus, changed settings or received a browser callback.
- Mode 2 starts every launch. Retain capture/dismiss/scroll keys and all ordinary settings. Defaults are F8/F9/F10/F11, four distinct F1–F20 keys. Existing valid custom keys survive updates. Hardware may require Fn/Globe.
- Screen permission preflight is quiet. Request missing permission at an appropriate explicit/startup point. Granted permission disables the request button. Recheck after returning from settings. Never loop permission requests, reset OS permission databases or expand capture scope when authorization fails.
- Continue with ChatGPT starts one sign-in. Cancel is available while it is active. Browser success is reflected in the app, with a useful bounded failure message otherwise. Signing in enables analysis without an additional checkbox/Save action.
- One capture workflow is active at a time. Held-key repeats coalesce. Dismiss, disconnect, account switching, settings replacement and termination cancel old work. A late native/network completion must not redisplay cancelled content.
- Capture one image from the requested source, verify its identity/geometry, process it in memory, and send it once. No automatic replay after errors, no continuous screenshot polling and no screenshot disk/clipboard files.
- Publish only a fully completed, validated and audited answer. Keep network deltas, loading indications and errors out of the answer panel. Errors belong in the main app.
- The answer persists until dismissed/replaced. It is literal text: no Markdown parser, HTML, executable links, images, syntax colors or attachments. Fixed 14-point Satoshi Regular, weight 400, `ss03`, zero paragraph spacing and 22-point horizontal inset. Use pure black/white ink based on background contrast. Only the sampled background adapts.
- Use a nonactivating, mouse-transparent answer surface and keyboard-only scrolling. Its width follows detected content-pane boundaries, its top follows capture-time pointer Y within the pane, and its height fits content up to 420 logical points. Clamp every frame and scroll offset.
- Advanced is collapsed initially. It contains saved-account selection/addition, keys, mode, source, optional target window, model, history/image limits, masks, system-prompt editor/reset and research tools. Users do not need to open it to begin.

Presentation is independent of model instructions. A custom system prompt may request an explanation, but cannot make the renderer stream or execute Markdown. Model adherence is not an application guarantee.

## 4. Keep modules and native seams explicit

The existing source tree is the reference mapping:

| Component | Reference | Port responsibility |
| --- | --- | --- |
| Entry/single instance | `Sources/HarnessApp/main.swift` | Native lifecycle, one owner, focus existing settings window |
| Workflow | `HarnessEmitter/Application` | Serialized tasks, generations, transactions, cancellation |
| Settings | `HarnessCore/Settings`, `HarnessEmitter/Settings` | Validation/persistence/drafts/native controls |
| Account | `HarnessEmitter/Account` | OAuth, JWT, account records, vault, locks |
| Capture | `HarnessEmitter/Capture` | Permission/scope/native image acquisition, masking/JPEG |
| Input | `HarnessEmitter/Input` | Native global shortcut registration/cleanup |
| Presentation | `HarnessEmitter/Presentation` | Window flags, geometry, text, pane/background processing |
| Provider | `HarnessEmitter/Providers` | Private HTTP, model access, SSE, completion contract |
| Privacy/audit | `HarnessCore/Privacy`, `HarnessCore/Audit` | Transmission gate, bounded retained context, allowlisted metadata |
| Research | `HarnessCore/Research`, `HarnessDetector`, `HarnessDetect` | Optional independent observations/reports, no capture control |
| Release | `scripts`, `Tests/PackagingTests` | Signing, source export, privacy gate, installer/rollback |

For a new OS, introduce equivalent interfaces rather than cloning macOS assumptions into a generic wrapper:

```text
CredentialStore: loadQuiet / saveAtomic / explicitUnlock / removeSelected
CaptureBackend: preflight / requestPermission / enumerate / captureOne
ShortcutRegistry: registerAllTransactionally / unregisterAll / physicalActivation
OverlayHost: capabilitySnapshot / showCompleted / scroll / dismiss
Preferences: readTyped / write / durableFlush
AuditSink: appendValidatedMetadata / flush
SingleInstance: acquireOrActivateExisting / release
BrowserSignIn: bindLoopback / openSystemBrowser / awaitValidatedCallback / cancel
```

Capture output must carry image pixels, source, display identity, capture bounds, display bounds, scale and orientation. Do not return a bare bitmap and later guess geometry. Distinguish unavailable capabilities, denied authorization, cancelled work, malformed data and ordinary transient failures. Never hide unsupported capture/exclusion behind a successful-looking result.

## 5. Phase A — state and durable settings

AI task:

```text
Implement the typed settings model, validation and private per-user persistence.
Start each launch in Mode 2 while retaining other values. Load malformed fields
independently and report field names only. Add the system-prompt override as an
optional field: absent means bundled default. Implement durable Save with rollback.
Do not implement capture yet. Prove persistence using separate writer/reader processes.
```

Use the bounds in [SPEC.md](SPEC.md). Reject NaN, infinity, booleans masquerading as numeric values, fractional integers, duplicate keys, invalid model IDs, target ID zero and masks outside the normalized image. A valid but currently unavailable target should remain selected with an explanation; unrelated saves must not silently erase it.

The system prompt permits newlines/tabs and Unicode, is nonempty after whitespace trimming, and is limited to 16,000 characters and 64,000 UTF-8 bytes. Reject other control characters. Do not confuse character count, UTF-8 bytes and UTF-16 display limits. Store a nil override when Restore Default is saved; upgrades may then improve the bundled default. Preserve the draft when merely reopening/refreshing settings. Disable editing/reset while a captured Save transaction is committing.

The main controller must validate before mutating native keys/mode. Cancel and await active work before replacing settings. If hotkey registration or durable persistence fails, restore the complete previous authorized state. If rollback itself cannot be confirmed, disable sensitive actions and show a repairable failure. Disconnect wins over an older save. Tests must prove recovery on the next attempt, not just rejection of the first attempt.

## 6. Phase B — metadata audit and privacy gate

AI task:

```text
Implement strict allowlisted audit schemas and the transmission state machine.
No provider may be created until authorization, image/scope validation and audit
have succeeded. Implement cancellation/cleanup, bounded answer-only history and
private durable files. Test storage failures and adversarial file paths first.
```

Create app-owned per-user storage, owner-only files and bounded locks. Refuse symlinks, unexpected owners, hard links where exclusivity is required, special files and oversized records. Handle short writes and EINTR, but cap repeated interruptions; an indefinitely interrupted `fsync` must not freeze the app. Release OS locks on all exits. Never unlink another process's lock to steal it. A lock timeout is a useful error, not a reason to ignore coordination.

Audit only approved metadata fields such as event name, identifiers, geometry, timing, byte counts/hash and classified failure. Do not pass arbitrary localized network errors or response bodies into logging. Exclude tokens, headers, codes, callback URLs, window titles, screenshot data, answers and custom prompts. Validate records before writing. A mandatory audit failure prevents the sensitive action or successful publication.

History contains at most ten answer exchanges. Images do not become history. Clear application-held screenshot/request/answer references when their lifecycle ends, including cancellation and account changes. This is reference cleanup, not a promise to erase OS swap or all framework copies. Provider retention is separate from local retention.

## 7. Phase C — supported ChatGPT sign-in

Read the current official [registration contract](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) and [accounts/sessions guidance](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions) before coding. This repository uses a public-client route; do not embed a developer's client registration or secret. Initial registration uses `dynamic_agent_client`, the installation's persisted host ID and the app's own name. Retain the issued client ID and verified account identity for future sign-in. Keep new registration separate from the active account. The same account email can have distinct registrations. These requirements come from OpenAI's registration contract.

AI task:

```text
Implement supported SIWC browser OAuth with a native loopback listener, PKCE,
state, nonce, signature-validated ID token and protected per-registration storage.
Use only documented endpoints/scopes. Reserve operation ownership before any await.
Make cancellation and wrong-state callbacks safe. Mock transport for automated tests.
Never read credentials from other apps or log protected inputs.
```

Reference implementation details to preserve:

1. Generate independent cryptographically random values per attempt; bind the listener before opening the browser. Use the exact IPv4 loopback callback URI consistently during the attempt.
2. Accept only the intended method/path and unique expected callback parameters. Wrong state, duplicated state/code, unrelated paths and malformed requests must not consume a legitimate pending attempt. Validate errors before exchanging a code.
3. Limit callback listener lifetime to 180 seconds, concurrent connections to ten and headers to 16 KB. Reject/truncate neither secretly nor indefinitely; close rejected connections. Cancellation releases listener/session resources.
4. Token exchange uses the pending issued registration, exact callback URI and PKCE verifier. Returning sign-in cannot replace the selected client ID with another registration's result.
5. Validate OpenAI ID-token signature using published keys, issuer, audience, expiry, nonce and subject. Tests must include forged/untrusted keys, malformed JWTs, wrong issuer/audience/nonce and expired claims.
6. Check plan-use permission independently from identity. Never treat a valid identity-only ID token as inference authorization.
7. Persist complete token sets and expiry atomically, with the registration mapping. Rotating refresh tokens must not be overwritten by another process's stale result. Serialize refresh with private bounded cross-process locks.
8. Transient/offline failures preserve valid saved credentials. Confirmed terminal refresh failures clear unusable credentials. Never automatically replay the screenshot after authentication changes.
9. Selecting another account cancels work and clears answer context **before** adopting the account. Lock selection while sign-in/refresh is active. Disconnect removes selected tokens and disables transmission; retain only the mapping needed for later sign-in.
10. Resolve every task completion once. Track a generation/attempt ID; discard late results after cancellation, disconnect or timeout. Reserve busy state before storage/network awaits, so fast repeated clicks cannot enter parallel sign-in.

### Avoid the recurring Keychain bug

On macOS, use Keychain for real tokens. Routine load/save must suppress both modern and legacy interaction UI. Explicit recovery may allow one protected prompt, on a worker thread with a deadline. The main UI must remain responsive. The process-wide legacy interaction policy requires synchronization and restoration; a concurrent quiet operation must fail promptly rather than enter a permitted prompt scope or block behind it. Cancellation cannot close SecurityAgent, but can prevent adopting its late result.

Stable app bundle/team identity is essential for updates. Recreating an ad-hoc/self-signed identity on each build changes OS trust; some local Keychain grants are tied to executable hashes even after Always Allow. Reuse the owned development identity, then ship with a stable Developer ID identity and notarization. Test ordinary restart separately from executable replacement. Do not disable Keychain controls, move tokens into a Git-ignored file, reset TCC or change global trust to conceal an identity problem.

## 8. Phase D — one-shot capture and processing

AI task:

```text
Implement native permission preflight and one-shot capture under the registered
physical shortcut. Validate exact scope, self/target identity and display geometry.
Add five-second once-only callback gates and cancellation. Redact before resizing,
encode bounded JPEG in memory off the UI thread, and never broaden failed scope.
```

Default scope excludes the app itself on the display under the pointer. Full-display and selected-window sources remain explicit alternatives. Self exclusion requires verified current process/bundle identity. Selected targets must still exist, belong to the expected source and have unambiguous display geometry. Do not silently capture the whole display when a window closes/moves/spans displays.

Native frameworks can fail to call back or call back after cancellation. A five-second deadline/cancellation gate returns independently and resolves once. Before and after capture, check display/window layout and identity. Reject stale results; snapshots cannot prove that every possible change-and-return race was absent.

Before allocating image buffers, reject zero/oversized dimensions, overflow and cancellation. Maximum original dimensions are 16,384 each and 64 million pixels. Masks are at most 32 normalized top-left rectangles; redact original pixels **before** resizing. Check cancellation between scanlines. JPEG must fit both the dimension and byte cap: longest edge at most 1568, payload at most 1 MB, quality floor 0.55 and dimension floor 64. If the limits cannot be met, fail with no upload. Test noisy worst-case images, extreme aspect ratios, boundary masks and cancellation.

Keep image, JPEG and request bytes in memory. An automated capture test uses an injected generated image; it must not reach the real desktop acquisition path. A separate explicit connection diagnostic may send a generated white JPEG through a real account, with disclosure that it consumes plan allowance.

## 9. Phase E — coordinates, pane boundaries and background

AI task:

```text
Implement pure geometry and image analysis using the existing capture only.
Add generated light/dark/colored, faint/partial/sidebar/card/scrollbar fixtures,
Retina/downsampling and negative-display-origin regressions before native rendering.
Do not tune only to one screenshot or assume phone-photo coordinates equal pixels.
```

Coordinate contracts:

- Pane and mask coordinates are normalized to the screenshot, origin at top-left.
- The captured bounds can be an entire display or a selected window inside it.
- macOS AppKit is bottom-left oriented; CoreGraphics capture metadata is top-left oriented. Convert using captured bounds plus the matched display's origins/extents. Do not merely flip against the main display or multiply everything by a guessed scale.
- Windows/Linux adapters must state their physical-pixel versus logical-coordinate contract. Apply per-monitor transforms exactly once. Reject invalid/nonfinite rectangles and arithmetic overflow before passing frames to native APIs.
- Clamp output to the intended display/pane. Handle negative display origins, rotated displays, pointer at every edge and a display removed while inference is pending. Recheck display layout before presenting.

Current detector algorithm, including the boundary repairs:

1. Validate the original image limits. Downsample proportionally to at most 1800×1200 sRGB RGBA with interpolation that preserves one-pixel dividers.
2. For each interior column, compare RGB with samples six pixels to either side. A center differing in the same direction from both neighbors identifies a thin line; neighbor differences identify a background transition. Consider sustained differences of at least three sRGB levels. Both dark and light themes need coverage.
3. Accumulate continuous vertical runs, tolerating only short gaps of three rows. Retain runs spanning at least one tenth of image height; require total and longest evidence of at least a quarter of height. Separate short card edges cannot substitute for one long divider.
4. Group candidate columns separated by no more than six pixels. Prefer thin-line evidence, then the strongest immediate pixel gradient, then coverage. **Do not use the stencil's outer comparison column as the real edge**; that places the answer inside a navigation rail.
5. Add a cropped left image edge only with a substantial verified thin separator; do not turn a desktop/window color boundary into a cropped pane. A single narrow-sidebar layout may extend to the image's right edge.
6. Examine adjacent boundaries. Skip spans narrower than max(160 sampled pixels, one fifth of image width), so a wide navigation rail inside a window is not chosen as answer content. Require sufficient common vertical evidence. Inset inside real borders.
7. Map the normalized rectangle using captured/display metadata. Width follows the content pane. Pointer Y sets the answer's top, clamped to its bounds. Measure text at that width before choosing final height.
8. If evidence is absent, use the documented display-bounded fallback and retain the heuristic limitation. This detector cannot infer arbitrary website semantics from pixels. A layout change while the model runs needs recapture; there is no hidden live tracking.

Mandatory regressions include faint seven-level one-pixel partial seams, seven-level **color-only** partial seams, a wide sidebar inside a window with desktop margins, short navigation separators, single-pane layouts, thick separators plus scrollbars, stacked cards, cropped content, 1×/2× sampling, 3840×2160 input and flat pages that must not invent dividers. Keep real authorized screenshots optional, never committed; phone photos are visual evidence, not exact screenshot-coordinate fixtures.

For background only, sample a bounded band around pointer Y inside the pane, skip outer margins, downsample to 128×32, group colors into 4096 RGB bins and average the dominant bin. Text and antialiasing must not tint a solid background. Select pure black/white text for contrast; retain fixed font/size/paragraph/inset. Test black, white, tinted surfaces, text-heavy bands and invalid/cancelled input. Do not perform extra capture, OCR or DOM inspection.

## 10. Phase F — model transport and complete-answer publication

AI task:

```text
Implement model-access preflight and a bounded Responses SSE decoder. Reserve
one request under a lock, release it on every exit, forbid redirects/replay,
and buffer the answer until identity, completion and audit are valid. Pass the
saved effective system prompt through the immutable settings snapshot.
```

The current [SIWC preview contract](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations) requires internal streaming and disabled storage. Supply context explicitly. Use `instructions`, rather than a system-role input item. Do not copy ordinary API tuning/persistence fields into this route. This app sends no tools. These request constraints are from the official preview documentation.

Reference limits/behavior:

1. Use an ephemeral HTTP session with no persistent cookies/cache and finite timeouts. Reject redirects before forwarding Authorization or image bodies. Never log HTTP bodies/headers.
2. Verify account-visible model IDs against a bounded catalog: 2 MiB and at most 500 IDs. Catalog metadata has a separate cap from answer events. Verify image support from the documented capability for the selected model; do not infer capability from a slug or silently pick another model.
3. Validate credentials, image and custom instructions before any request. Bound user task text and effective instructions/history together to 64 KB of UTF-8 text. Include at most ten recent exchanges, newest first within the budget; omit older context that cannot fit.
4. Encode exactly the supported request fields, one current JPEG data URL and explicit text history. The default answer instructions live in Settings, not duplicate literals scattered across provider/UI. Append the screenshot trust-boundary instruction; custom prompts do not grant native tools.
5. Parse byte streams across arbitrary chunks, including split UTF-8 and CRLF boundaries. Ignore appropriate unknown event types. Bound each event to 1 MiB, total stream to 4 MiB and text deltas to 64 KiB. Reject malformed lifecycle/identity and oversized envelopes distinctly.
6. Validate response-created identity/model/status, per-delta identity/indexes and completed identity/model/status. Done events repeat text and must not duplicate output. Missing Content-Type alone may be tolerated; a supplied incorrect type must be rejected, and JSON/incomplete streams must never count as success.
7. Bound accumulated output to 100,000 characters; native rendering separately caps 100,000 UTF-16 units without a dangling surrogate. Maintain running delta counts rather than repeatedly scanning an ever-growing answer. Stop a producer if its bounded continuation buffer drops data.
8. Publish only after the complete response and completion audit succeed, then commit bounded history and release image references. A partial answer followed by disconnect/error/cancel/audit failure never appears in the popup.
9. Clear active ownership on success, failure and cancellation. A manual retry must work after every failure class. Do not replay requests/images automatically on timeout, rate limits, expired access or malformed SSE.

Use mock HTTP to test the actual outgoing body, not just a provider factory call. Verify Unicode custom instructions replace the bundled style, trust-boundary text remains, no forbidden fields/system messages appear, and audits contain no prompt text.

## 11. Phase G — native UI and input

AI task:

```text
Build the compact sign-in/status window and optional Advanced form, then the
nonactivating completed-answer surface. Test actual native window/layout flags,
plain text/font registration, keyboard scrolling and save drafts in generated
integration windows. Keep protected OS prompts under human control.
```

On macOS, use a top-aligned flipped scroll document, minimum 560×400 window, flexible field widths and bounded margins. Test collapsed/expanded form at narrow/default sizes and overlay/legacy scrollbar styles. A short form must not appear anchored halfway down an empty window. Use a plain multiline scrollable prompt editor, show its bounds and reset action, and require explicit Save to apply it. Saved-account selection uses stable IDs, not email labels or popup index assumptions.

The answer panel uses borderless nonactivating NSPanel, refuses key/main status and first responder, ignores mouse events, has no shadow/movable surface and is not automatically hidden on deactivation. Render literal bounded NSAttributedString with one font/color. Register the real bundled font only in-process and verify its name/feature. Disable links/data detection/selection/editing. The scroll view receives no mouse wheel; registered up/down keys clamp its document offset. New answers start at the top; dismissal clears text/scroll state.

Register four global shortcuts transactionally. Remove old handlers/registrations during replacement and destruction; failed registration must not strand duplicate handlers. A function key may be reserved by hardware, OS or another app; expose a recoverable conflict. Do not synthesize a physical capture event to bypass the production entry rule in tests. Native/HTML full-screen and real key behavior require separate acceptance.

Modes request documented native properties and record requested/observed capability. macOS Mode 1 requests legacy sharing `.none`; Mode 2 adds stationary/cycle behavior. AppKit's [sharingType](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.property) is not a universal recording exclusion contract. Verify each recorder from another observer. Do not force Space changes or use private privileged window levels/order loops.

## 12. Windows implementation contract

A native Win32/C++20 implementation with C++/WinRT is one concrete port option. This is a design choice for the new port, not an existing build in this repository. Use a supported Windows SDK, MSVC, CMake and a native test runner; package for explicitly supported architectures and Windows releases.

| Concern | Adapter plan |
| --- | --- |
| Capture | Windows.Graphics.Capture; check support, get an authorized capture item, acquire/copy one frame and dispose native frame/session resources |
| Coordinates | Per-monitor DPI-aware process; record capture pixel bounds and monitor logical transform, including negative origins |
| Input | RegisterHotKey/WM_HOTKEY with no-repeat behavior; unregister on every lifecycle exit |
| Popup | Owned top-level layered/tool window with tested input transparency and no activation; bounded native text layout |
| Mode 2 | Request supported display affinity on the owned top-level overlay; read back/check success and report actual capability |
| Tokens | User-scoped protected storage; atomic encrypted records with restrictive file ACLs, no machine-shared credential scope |
| Single instance | User/session-scoped named mutex plus narrow activation IPC; validate incoming messages |
| Settings/audit | Per-user app data, typed versioned settings, durable replacement/rollback; Windows locking/flush equivalents |
| Release | Authenticode-signed installer/binaries, signature/identity verification, tested upgrade/rollback/uninstall |

[Windows capture documentation](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture) explains support checks, secure source selection and frame ownership. Copy only valid ContentSize pixels before disposing a frame; do not retain a recycled GPU surface. Account for resize/device loss/HDR with a tested SDR conversion. Stop after obtaining the requested image; do not quietly introduce continuous recording.

[RegisterHotKey](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey) has reserved/conflicting keys, including debugger-reserved F12. Preserve useful defaults, but the new port's validation must reject or explain unsupported selections. Position/show the popup without activation using documented [SetWindowPos](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos) flags and prove click-through to a separate test window; a style flag alone is not a cross-process input test.

[SetWindowDisplayAffinity](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity) applies to the calling process's top-level window. `WDA_EXCLUDEFROMCAPTURE` is supported starting with Windows 10 version 2004; older systems have different behavior. It is not a guarantee against all capture methods. Record the requested flag, return value, observed affinity, OS build and actual recorder test. Unsupported/failed affinity must remain visible as a capability limitation.

For potentially large account records, prefer user-scoped [DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata) encrypted storage with restrictive ACLs and atomic replacement. Avoid machine scope, which broadens who can decrypt. Free returned native buffers. If choosing [Credential Manager](https://learn.microsoft.com/en-us/windows/win32/api/wincred/nf-wincred-credwritew), verify its credential-blob capacity against bounded token records; do not silently truncate long JWTs or squeeze a 2 MiB catalog into a small vault entry.

AI phase prompt:

```text
Implement the Windows adapters above in isolated feature directories. First prove
capture support, generated one-frame acquisition, nonactivation, real cross-process
click-through and four hotkey lifecycle behaviors on named supported OS builds.
Port the shared state/settings/OAuth/SSE/geometry regressions. Use user-scoped DPAPI
records and signed updates. Report any native capability gap rather than copying
macOS flags or claiming that a passing affinity call proves all-recorder exclusion.
```

A CMake port should expose these commands once its targets are implemented:

```powershell
cmake -S . -B out -A x64
cmake --build out --config Release
ctest --test-dir out -C Release --output-on-failure
```

Use an independent build directory for ARM64 and run that architecture on real hardware before claiming support. A generated installer must be tested as a fresh install and upgrade under an ordinary account, not only launched from the IDE.

## 13. Linux implementation contract

Linux is several native environments. A Rust + GTK4/GIO frontend with explicit native adapters is a reasonable implementation option; pin actual library versions after verifying the chosen distribution/compositor. GTK alone does not guarantee arbitrary full-screen overlay positioning or input transparency across all Wayland compositors.

For **Wayland**, use the documented [ScreenCast portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html) and PipeWire for authorized frames. Probe interface versions and advertised source/cursor capabilities. Portal session restoration is provider-controlled: supported persist/restore options may reduce repeat selection, tokens rotate on use, and revocation/missing sources can trigger another dialog. Do not promise a permanent one-time grant. Keep any restore token in protected runtime storage. Copy one requested frame, close the capture session promptly, and never substitute a broader source when the selected target is unavailable.

Use the [GlobalShortcuts portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html) where implemented, and handle compositor-approved rebinding/cancellation. Missing interfaces are a supported-capability decision, not a reason to install unrestricted event interception. Do not assume a global mouse location or arbitrary window position is available to a Wayland client; design an explicit authorized placement fallback or narrow the supported compositor set.

Some compositors expose layer-shell surfaces for nonactivating overlays with empty input regions; verify the [native protocol specification](https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/master/unstable/wlr-layer-shell-unstable-v1.xml), registry availability and actual full-screen ordering before choosing that adapter. This extension is not a general GTK/Wayland guarantee. A compositor without the needed placement/input behavior requires a visible supported fallback or an unsupported-feature result. Do not label a topmost surface as recording-excluded.

For **X11**, build an explicitly separate adapter for window enumeration, image acquisition, passive key grabs and empty input shape/window-manager hints. Validate behavior against each supported window manager. X11 capture and Wayland portals are different authorization/security models; successful X11 tests do not validate Wayland. Avoid kernel/root helpers, display-server injection and secret-dependent shortcuts.

Store tokens using a supported [Secret Service](https://specifications.freedesktop.org/secret-service/latest/) implementation with private app-owned attributes and bounded records. Treat a missing/locked vault as an explicit recoverable state. Do not fall back silently to a plaintext settings file. Use XDG per-user configuration/state/cache directories, private permissions, no-follow access, bounded flock-equivalent coordination, durable atomic replacement and process-death lock release.

AI phase prompt:

```text
Build the Linux port for <distribution/version, X11 or Wayland, compositor/version>.
Probe portal/session/input/overlay/secret-service capabilities before enabling
features. Implement the state, settings, OAuth, transport and image contracts from
this blueprint. Use native portals for authorized capture/global shortcuts where
available. Document features that cannot satisfy the desktop contract. Add native
tests on that compositor and clean-install package tests. Do not claim Linux-wide
support from a single desktop, or universal recording exclusion from window flags.
```

For a Rust implementation, the generated project should provide:

```sh
pkg-config --modversion gtk4 gio-2.0 libpipewire-0.3
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test --locked
cargo build --release --locked
```

Install the named distro's supported compiler/toolchain and development libraries before building; do not guess package names across distributions. A Flatpak build needs the appropriate runtime/SDK and declared portal permissions. Test inside the actual package sandbox; an unconfined developer run is not packaging acceptance. Choose Flatpak, native distro package or another format deliberately, with verified provenance and upgrade behavior.

## 14. Phase H — research tools, if included

The detector is optional for a basic screenshot assistant, but part of the current macOS repository. Keep it independent: enumerate metadata, never capture pixels, change app modes or forge physical activation. Retain all window layers and annotate system owners rather than filtering inconvenient observations.

Matrix testing requires manual mode/source choices, settling time and the next physical capture for each cell. Failed/interrupted/unattempted cells stay explicit. Correlation requires compatible session/capture/window/process identities, bounded timing skew, no ambiguous reuse and strict schema. Accuracy requires independent ground truth. Calibration uses original asymmetric marker pixels and explicit geometry/visibility evidence; absent or uncertain evidence is not proof of invisibility. Port research probes only where native metadata is available and disclose gaps.

## 15. Regression catalogue — keep these failures fixed

Every row needs a meaningful production-path assertion and, where applicable, a native acceptance test. The existing feature-matched `Tests/HarnessTests` files are executable reference cases.

| Trigger/failure | Required repair and evidence |
| --- | --- |
| Save/restart loses settings | Typed per-user store, durable flush/rollback; independent processes and own-bundle-domain reads |
| Every launch asks consent again | Startup disclosure plus sign-in authorization; no redundant app checkbox; permission request disabled while granted |
| Every rebuild asks Keychain | Stable signing identity, quiet routine access, explicit worker recovery; test restart separately from update |
| Browser says success, app idle | Bind listener first, validate callback/state/registration, once-only delivery; return app status on success/failure |
| Wrong callback consumes sign-in | Reject without resolving the pending legitimate attempt; then prove correct callback still succeeds |
| Two sign-ins/refreshes active | Reserve before await, process/file serialization, generation guards; retry after cancellation |
| Permission/scope failure widens capture | No broader fallback; prove native capture adapter was never called with an unauthorized scope |
| Screenshot/JPEG freezes UI | Cancellable background work, allocation bounds, scanline cancellation; responsive main UI under timeout |
| Response exceeds old tiny limit | Separate catalog/event/delta/total/output caps; oversized classes still fail distinctly without partial text |
| Invalid response / missing header | Enforce stream lifecycle/identity, tolerate only absent advisory header, reject supplied invalid type and incomplete stream |
| Another operation stays active | Release provider/privacy/controller ownership on every exit; repeated failure/cancel/manual retry cycles |
| Streaming/loading/error in answer | Buffer in service, completion audit gate, publish once; failure/cancel after deltas yields no answer |
| Sidebar becomes answer background | Faint partial/color-only seam tests in light/dark; strongest edge snap, substantial content width, window margins |
| Scrollbar/card becomes splitter | Continuous-run evidence, nearby edge grouping and narrow-span rejection; cropped/thick/stacked-card fixtures |
| Font becomes red/adaptive | Fixed real Satoshi/14pt/ss03, one black/white ink, background-only sample; native attributed-text assertions |
| Popup disappears/focuses/clicks | No idle timer/deactivation dismissal, no activation/first responder, cross-process click-through, persistent session |
| Keyboard scrolling fails | Bound native document and clip offsets; prove down/up at both ends after resize/replace |
| Account switch retains prior context | Cancel/await/clear before adoption; distinct same-email registration IDs and no cross-account history |
| Settings failure revokes session | Transaction rollback restores previous authorized state; superseding disconnect remains authoritative |
| NaN/overflow/removed display | Finite/bounds validation before native calls; negative-origin/Retina/rotation/layout-change cases |
| File I/O hangs or leaks secrets | Bounded lock/write/sync retries, private/no-follow files, schema logging, failure propagation |
| Duplicate app/Spotlight copies | Single-instance before account/hotkeys; one canonical install, app only inside ZIP staging/output |
| Malicious/broken update archive | Limits/CRC/path/type/canonical-duplicate validation, strict signature/identity, atomic exchange and rollback |
| Private paths inside release binary | Compiler prefix maps, strip before signing, archive privacy scan; inspect actual shipped bytes |
| Prompt override ignored/lost | Draft/save/reset/migration/Unicode/bounds/rollback/process restart and outgoing HTTP body tests |

Do not delete a test because it exposed a real failure. Remove tests that only repeat implementation without observing a user contract. Test timing assumptions under realistic load and use finite condition waits; do not hide races with long arbitrary sleeps.

## 16. Verification order and evidence

1. Run pure settings/geometry/parser tests with generated fixtures. Record failing-before/passing-after evidence for each repair.
2. Run account/provider/integrated workflow tests with mock native/network boundaries and injected I/O faults. Exercise success, transient failure, terminal failure, cancellation, timeout and retry.
3. Run the full normal suite. Native UI tests require an actual interactive session and explicit opt-in. Avoid concurrent GUI suites fighting over window state.
4. Run Address Sanitizer for memory/native buffer changes and Thread Sanitizer for ownership/concurrency changes. Distinguish tool/platform limitations from a clean execution. Repeat only if another change or unresolved concern warrants it.
5. Run packaging/signing tests and separate preference-process restarts. Validate shell/Python syntax, source whitespace, documentation links, font identity and icon structure.
6. Build every promised architecture; verify minimum-OS metadata. Compilation is not runtime acceptance on another architecture/OS.
7. Extract the final app into temporary staging, verify signatures/identities/CRC and compare installed bytes with packaged bytes. Scan source and compiled archives for private data. Test fresh installation, same-identity update, failed update rollback and duplicate launch.
8. Visually inspect the actual compact/Advanced UI and generated answer surface. Test a real physical shortcut, dismiss/cancel, keyboard scrolling, pointer clicks to a separate application, ordinary/native/HTML full-screen and quit/relaunch.
9. Test recorder behavior from another observer for named browser/recorder/OS versions and share modes: browser tab, app window and entire display are different cases. Record only metadata/outcome, not private images or answers.
10. Run a real account request only with explicit authorization, using a generated image where possible. Automatic suites must not consume subscription allowance or capture the desktop.

Store concise current verification in `docs/VERIFICATION.md`. Keep temporary logs/phone photos/test domains/builds outside the repository. Missing optional reference images stay skipped; they are not successful image comparisons. Say exactly which checks passed, which require protected user interaction and which platforms remain untested.

## 17. Ship clean source and native packages

AI task:

```text
Prepare a shareable release with no personal computer paths, usernames, account
records, host IDs, OAuth tokens, issued registrations, environment secrets or
private signing material. Inspect Git history as well as tracked files and actual
binary/archive bytes. Preserve any necessary private recovery backup outside the
shareable repository. Exclude vendored/generated output and restricted assets from
source export. Use the publisher's own stable identity for signed native updates.
```

Generic protocol constants are necessary: provider URLs, app bundle/service identifiers, public first-registration entrypoint and synthetic tests are not user credentials. Each new user supplies authorization through the supported sign-in flow. Never distribute one account's registration/token records to bootstrap another user.

Use a generic Git author for a sanitized source release; do not include private historical commits, reflogs, local machine config or runtime logs in an archive. If history contains personal paths/identity, retain a private recovery backup outside the shared tree before replacing it with a clean reviewed snapshot. Scan the final source, not merely `.gitignore`. Ignore credential file formats, but understand that ignoring a file neither encrypts it nor removes an already committed secret. Any real exposed credential needs revocation outside the code cleanup.

Remap compiler source/scratch prefixes to generic virtual paths and remove debugging information from staged binaries **before** signing. Do not bundle private dSYM/PDB/debug artifacts. Keep useful public version/toolchain/dependency metadata without machine usernames/home paths. Test with an actual release scanner; a clean source tree can still produce binaries containing developer paths.

Current macOS release scripts refuse unsafe archives and signing-identity migration, validate the candidate before replacement, use atomic bundle exchange and roll back failed post-install checks. Keep runtime data separate so an update cannot remove saved accounts or permissions. Verify the expected certificate-bound identity on both old/new bundles. Never loosen the verifier to make an update pass.

Public macOS distribution needs Developer ID, hardened runtime, timestamp, accepted notarization, stapled ticket and Gatekeeper assessment. Windows requires the chosen publisher's Authenticode identity and actual installer/update testing. Linux requires the chosen package/provenance mechanism and sandbox/desktop acceptance. Signing private keys and service credentials remain in protected maintainer stores or CI secrets, never in source/release instructions.

## 18. Definition of done

The intended OS implementation, not merely this document, must have:

- A clean native build, full applicable tests and real installation/restart evidence.
- Simple sign-in, stable runtime storage, bounded cancellation/retry behavior and useful failures.
- Exact capture/scope/geometry/resource contracts, fixed text rendering and tested persistent keyboard-only scrolling.
- Current docs matching the delivered defaults, custom prompt behavior and actual native capability limits.
- Clean shareable source and scanned native artifacts with reviewed dependencies/licenses.
- Completed native release signing/distribution acceptance for every claimed target.
- A manual acceptance matrix naming browsers, full-screen modes, desktop environments, hardware and recorders actually tested.

Unverified ports, layouts, permissions or recorder behavior remain explicit. This blueprint transfers the implementation decisions and regressions; it does not override OS security or remove the need to test on the destination machine.
