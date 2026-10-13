# Harness 0.6.1 — detailed behavior and algorithms

This is the behavioral reference for implementation revision `6034926ff22b0e220af6560d1de1875874322f41`. It records the current macOS code, including deliberately constrained and heuristic behavior. It does not claim that every browser, recorder, account or operating-system version has been accepted. Windows must reproduce the product outcomes and pass its own native gates; see [WINDOWS_BUILDER.md](WINDOWS_BUILDER.md).

## 1. Product boundary

Harness obtains a one-shot screenshot only in response to a registered physical request/queue shortcut. It processes the image locally, optionally masks sensitive regions, transmits a bounded question through an explicitly connected ChatGPT plan and displays only a fully validated answer. It is not a continuous screen monitor, key logger, autonomous agent, clipboard reader, browser extension, recorder, Markdown editor or executable-code runner.

There are two independent kinds of mode: **overlay position** chooses answer geometry, and **experimental visibility mode** chooses requested native window properties. Do not merge those enums. A position switch is safe to apply during a pending request and preserves the queue; an ordinary settings transaction can change capture/model/privacy conditions and cancels pending work.

The bundle identity is `org.harness.research`; minimum deployment is macOS 14. Only one installed instance should own global shortcuts and the account store. Duplicate-launch handling opens the existing canonical instance rather than creating a second capture session. Mode 2 starts on every launch even if another experimental mode was saved; this is intentional. Valid ordinary preferences persist.

## 2. Startup and visible interface

Startup creates the controller, protected metadata sink, quiet account adapter, settings store, overlay and mode engine. It checks running/termination state between awaited steps. It records `app_launch` with source/configuration/environment and load-issue field names, records Screen Recording permission, restores acknowledged network consent/history limit and registers all seven shortcuts. Only successful initialization sets readiness. The settings/status window then opens.

Startup never takes a screenshot or submits inference. Missing Screen Recording can cause the explicit permission flow after the status window is shown. An inaccessible Keychain record is shown as an unavailable saved account; ordinary startup does not prompt to unlock it. A connected account with previously disabled network submission can restore the acknowledged enabled setting through the current onboarding behavior; builders must trace this account/consent transaction rather than add a separate hidden credentials source.

The normal window shows queue count, experimental mode, shortcut instructions, account status, Continue with ChatGPT/Disconnect and Screen Recording status. Advanced reveals saved account choices, Add account, mode/source/window selectors, configurable capture/queue/scroll digits, fixed 0/1/9 labels, adaptive typography, overlay position, model ID/catalog, custom system prompt, history/JPEG limits, calibration and mask controls. Main/menu-bar Settings and Quit actions are conventional app navigation; they do not request inference.

Busy states are owned separately for save, permission, sign-in, model refresh, window refresh and calibration. An action cannot start a duplicate task merely because another action's control is enabled. Refreshing a catalog uses the selected account token; refreshing shareable windows is metadata enumeration, not capture. Errors use bounded classified messages instead of raw network bodies or credentials. Draft text in settings is preserved where appropriate and is not silently applied before Save.

## 3. Keyboard controls and held-key behavior

| Action | Default digit | Fixed/configurable | Effect on request/content |
| --- | --- | --- | --- |
| Request/send | 8 | Configurable 2–8 | Send queue, otherwise acquire one frame |
| Queue screenshot | 5 | Configurable 2–8 | Acquire one frame, process/append; no provider |
| Clear/cancel | 9 | Fixed | Cancel operation; discard answer/presentation/queue/context |
| Hide/show | 0 | Fixed | Toggle saved answer visibility only |
| Position | 1 | Fixed | Toggle `nearCursor`/`pinnedCorner`, persist and re-render |
| Scroll up | 7 | Configurable 2–8 | Move to an earlier measured row boundary |
| Scroll down | 6 | Configurable 2–8 | Move to a later measured row boundary |

All modifiers are Option+Shift and all digits are top-row keys. Seven bindings must be distinct. `dismissHotkey` must be 9. Registration reserves all required native bindings transactionally; failure releases the replacement and restores the prior set or stops sensitive actions if restoration fails. Registration generations reject stale callbacks. Held-key repeat presses are coalesced until a corresponding release; a single physical hold must not fill the queue or submit repeatedly.

Before request/queue, readiness, termination, audit latch, account transition and one-workflow ownership are checked. A saved answer is an independent guard: **hidden text is still an answer** and blocks a new screenshot/request. A second request while work is busy produces an operation-busy outcome rather than another native capture. Scroll does nothing without a visible saved answer. Hide/show without an answer reports that there is nothing to restore.

Hide/show preserves text, exact frame and scroll offset. It does not clear privacy history or the saved presentation estimate. If the display layout changed while hidden, restoration is refused and the user must clear with 9 before a fresh request. Position switching preserves answer visibility; switching a hidden answer does not reveal it. It persists only position through a narrow transaction, does not recapture and does not cancel a pending response. The final presentation reads the latest committed position immediately before drawing.

## 4. Settings and migration

The in-memory defaults are: shortcut schema 1; digits 8/9/7/6/5; adaptive typography off; provider `ChatGPT plan`; model `gpt-6.1-sol`; automatic position `nearCursor`; visibility mode 2; source `sck_excluding_self`; history 10; longest image edge 1568; JPEG byte ceiling 1,000,000; network enabled; calibration/masking off; no selected window; no masks; system prompt override absent.

An absent prompt override follows the bundled default after an upgrade. Restore Default edits the draft; Save commits it. A custom override must contain non-whitespace text, at most 16,000 Swift characters and 64,000 UTF-8 bytes, and no control scalars except tab/newline/carriage return. Model IDs are nonempty ASCII alphanumeric/`-_.` and at most 128 UTF-8 bytes. Editing a model ID does not establish image support or account availability.

History is an integer 0–10, longest edge 64–1568, JPEG limit 10,000–1,000,000 bytes. Stored booleans must actually be booleans; a numeric 1 is not accepted as a boolean when using the native preferences adapter. Integer fields reject boolean objects and floating encodings. A selected-window ID, if present, must be nonzero; its liveness is checked at capture time. Up to 32 finite normalized masks are allowed, each with nonnegative origin, strictly positive size and edges inside [0,1].

Legacy serialized shortcuts use `{ "functionKey": N }`, while schema 1 uses `{ "digit": N }`; native preferences store integer digits directly. Group repair considers capture/up/down/queue in that order, reserves 0/1/9, keeps the first usable distinct requested digit in 2–8, then fills each missing value from its corresponding default (8/7/6/5) or the first available digit in 2–8. Dismiss becomes 9. Unknown retired position values become automatic; the removed cursor box is not recreated. Unsupported schema versions fail decoding instead of guessing.

Ordinary Save validates the complete candidate and acknowledged network setting before mutation. It advances settings/presentation generations, disables capture readiness, clears queued images, cancels/awaits pending work, updates consent/history, transitions native mode and shortcut registrations, durably saves preferences and audits applied configuration. It then re-renders an existing answer from metadata if display geometry is still valid. The answer's hidden state/reading character are retained; disabling adaptive typography can restore default text without another screenshot. Enabling it cannot recover an estimate that was never acquired: it affects subsequent captures.

Failures restore previous preferences/consent/history limits/registrations/window mode as applicable. Disconnect supersedes an awaited save; a stale save cannot re-enable submission. Failed or unverifiable rollback enters the application's blocked state. The settings store restores only its own changed keys, preserving unrelated preferences; it reports a separate rollback failure if the durable restoration also fails. Exact keys/serialization are in [PROTOCOLS.md](PROTOCOLS.md).

## 5. Screenshot queue

The queue holds 1–6 `QueuedScreenshot` values: unique capture UUID plus processed JPEG bytes, dimensions/hash and mask-applied evidence. It never retains a native frame or OCR string. App presentation metadata from the most recent queued capture is stored separately and contains no image bytes. The queue's immutable configuration snapshot includes all settings except overlay position, which is deliberately ignored for queue matching.

The first successful append sets a monotonic creation timestamp. Lifetime is 300,000,000,000ns. Later appends do not renew it. A backwards clock observation is treated as expired rather than underflowing. Expiration clears all entries/configuration/timestamp and updates the visible count; it never submits. Append/take also check expiry in case a timer did not run while the process was suspended.

Append validates configuration, capacity, unique UUID, nonempty JPEG within the configured byte ceiling, positive dimensions and required mask evidence. A settings mismatch clears the queue and fails; an attempted seventh entry cannot evict an earlier screenshot silently. A failed native capture/process discards queued captures through the application failure path.

Request/send consumes the entire valid queue in original capture order with no additional screenshot. Taking clears queue ownership before provider activity. All capture IDs are included in metadata for multi-image requests; the last capture provides the saved display/pane/style estimate for the answer. If no valid queued entries remain, the request performs one new capture. Clear, ordinary Save, account changes, cancellation, failure and termination clear the queue; position-only switching preserves it.

## 6. Exact capture scope and coordinates

| Raw source | Native scope | Required failure behavior |
| --- | --- | --- |
| `sck_full` | Display under the capture cursor | Missing/ambiguous display or malformed geometry fails |
| `sck_excluding_self` | Same display with the current verified application excluded | Missing bundle/process identity or failed exclusion fails; never substitute full capture |
| `sck_selected_window` | Explicit live selected window | Missing/closed/moved/spanning or changed target fails; never substitute display capture |

CaptureService and CaptureEngine each guard their own ownership boundary. They are not redundant: one protects the app workflow's acquisition while the other protects native backend queries/frames. Screen Recording preflight is quiet. Native shareable-content and image callbacks pass through one-shot cancellation/deadline gates (five seconds); a cancelled caller returns without waiting for an uncooperative callback. Late/repeated callbacks are ignored, not resumed twice.

Display coordinates can have negative origins. AppKit logical coordinates are bottom-left-oriented; captured pixel and normalized mask/pane coordinates are top-left-oriented. CoreGraphics display bounds, AppKit frame, capture bounds, backing scale and rotation travel together. A window capture's local origin must not be treated as a full-display origin. Pixel sizes use ceiling of validated logical/scale geometry and must exactly match the plan. Allowed scale is 0.5–4 and rotations are 0/90/180/270; dimensions remain bounded to 16,384 per edge and 64 million pixels using overflow-safe division.

The app snapshots the complete display-ID-to-frame map before and after native capture. They must agree and contain the captured display. The same snapshot is checked before final answer presentation and hidden-answer restoration. This stops common display disconnect/move races; a layout that changes and returns between observations cannot be detected by two snapshots. The unused capture-plan cursor conversion has been removed; actual pane/calibration transforms remain.

The cursor used to place the answer is sampled when the physical action begins, not continuously during network latency. The native CaptureEngine separately samples its display-selection cursor after shareable-content enumeration; if the pointer crosses monitors during that await, capture target and placement sample can differ, with the explicit target display taking precedence. Record this as a native timing acceptance case instead of claiming keyboard-instant display selection. Saved-answer metadata contains that cursor, target display frame, detected pane, normal/fallback style and optional typography. A saved estimate can become visually stale when a web page changes without the display map changing; the app cannot observe that without a new user-requested screenshot.

## 7. Pixel processing, masks and JPEG reduction

Validate all settings and cancellation before allocation. Reject empty dimensions, edges above 16,384 or `width > 64,000,000 / height`. Render into an explicit 8-bit sRGB RGBA context; flatten alpha onto white. Mask at **original resolution before any interpolation** so the resizing kernel never samples the original private region.

Masks use top-left scanline addressing. For each normalized rectangle, x0/y0 are floored, x1/y1 are ceiled and clipped to image bounds; every covered pixel becomes opaque black RGBA(0,0,0,255). Outward rounding protects boundary pixels. The loop checks cancellation between scanlines. Resize the redacted source with high interpolation and preserved aspect ratio; each dimension is rounded and at least one pixel.

At an initial longest edge `min(originalLongestEdge, configuredMaxDimension)`, try JPEG qualities 0.90, 0.80, 0.70, 0.60, 0.55 in that order. Return the first nonempty result at or below the configured byte ceiling. If every quality fails the budget, multiply the longest edge by 0.8 (integer floor), clamp to 64, and retry. Never go below quality 0.55 or continually retry at the 64-pixel floor. If it cannot fit, report `cannotMeetByteLimit` and send nothing. Compute SHA-256 of the final JPEG for metadata; the digest is not an image-content deletion guarantee.

Processing runs off the main actor. The native frame is short-lived; original pixels are not retained in history/queue/saved-answer metadata. Local pane/style/typography analysis uses the existing frame and does not add a capture. Privacy validation later verifies that the actual processed images match the current scope and required mask evidence before transmission.

## 8. Pane detection and coordinate transforms

Pane detection receives the original one-shot screenshot. It rejects sources smaller than 200×100 or larger than native image limits, then makes a high-interpolation sRGB copy with scale `min(1, 1800/sourceWidth, 1200/sourceHeight)`. Filtering while shrinking preserves faint one-pixel rails better than skipping samples.

For each candidate x column from 6 through width−7, compare its RGB channels with columns six pixels to each side. A thin divider differs from both neighbors in the same direction; its minimum two-sided contrast must be at least 3 channel values. Otherwise a sustained neighbor-to-neighbor contrast of at least 3 supplies an ordinary boundary candidate. The same column is also compared with its immediate neighbors to rank the strongest actual gradient.

Vertically adjacent observations tolerate gaps of up to three rows. A run contributes its span only when it has at least height/10 observations. A candidate needs total evidence and one longest run of at least height/4. Nearby x columns within six pixels are grouped as the same divider; representative choice favors thin-line evidence, then immediate-gradient strength, then sustained count. Grouped top/bottom extents are retained. This prevents snapping to a weak antialiased shoulder instead of the real rail.

Two special edge cases support cropped content: a first sufficiently internal divider (x≥width/5) with thin evidence over at least 35% of height can imply a content edge at x=0; a lone sidebar divider left of width/5 can pair with the right image edge. Ordinary window/background transitions alone do not establish a split pane.

Scan adjacent boundaries from left to right. At least one must contribute sustained thin evidence (combined ≥height/4). The width must be at least `max(160,width/5)` and generally at most 90% of the image unless the right edge is explicitly used. Their shared vertical extent must be at least height/4. The pane's bottom extends to the larger detected bottom so short sidebar seams do not truncate body content; its top uses the larger top. Insets avoid drawing on the divider itself. Narrow navigation rails, gutters, cards and unrelated desktop margins are skipped. If no pair satisfies the complete contract, return no pane and use the compact fallback.

The result is a normalized top-left rectangle. Convert to a logical screen rectangle using captured bounds and the two display coordinate systems:

```text
cgX = capturedBounds.minX + normalized.minX * capturedBounds.width
cgYBottom = capturedBounds.minY + normalized.maxY * capturedBounds.height
appX = appKit.minX + (cgX - displayCG.minX) * appKit.width / displayCG.width
appY = appKit.maxY - (cgYBottom - displayCG.minY) * appKit.height / displayCG.height
appWidth = normalized.width * capturedBounds.width * appKit.width / displayCG.width
appHeight = normalized.height * capturedBounds.height * appKit.height / displayCG.height
```

The reverse transform validates finite positive rectangles, converts a saved panel/patch to normalized captured coordinates and intersects with [0,1]². This is also how calibration and fallback-area sampling avoid treating selected-window pixels as full-display pixels. Every transform must be tested with negative origins, cropped windows, Retina scaling and non-primary monitors. Phone photos provide qualitative evidence, not native coordinate fixtures.

## 9. Background blending and contrast

A pane sample uses a horizontal band centered on captured cursor Y and clipped into the pane. Its height is the smaller of pane height and `max(24 pixels, 8% of image height)`. Remove 4% of pane width on each side to avoid divider tint. Sample the crop into a 128×32 sRGB RGBA buffer without interpolation. Count 4096 bins of high-nibble RGB colors and average actual channel values only within the dominant bin; text and antialiasing should not tint an otherwise solid background.

Compact fallback sampling targets the captured image region corresponding to the logical bottom-left area when that region exists. Without an explicit mapped area, use normalized width `min(0.95,96/logicalWidth)`, height `min(0.5,42/logicalHeight)` and a small left inset. Invalid/outside/too-small sample regions return the dark fallback. A window capture cannot truthfully sample unrelated desktop pixels outside its requested scope. The app takes no second image to fill that gap.

Pure black and white have canonical dark/light styles. Other dominant samples become an opaque sampled RGB background. For each channel c in [0,1], linearize using c/12.92 when c≤0.04045, otherwise `((c+0.055)/1.055)^2.4`. Relative luminance is `0.2126*r + 0.7152*g + 0.0722*b`. Compare black contrast `(L+0.05)/0.05` with white contrast `1.05/(L+0.05)` and choose the greater (black on a tie). A threshold on gamma-encoded channel averages is incorrect for many greens, blues and midtones; this was corrected in 0.6.1.

The sample is static metadata from that capture. It blends with the sampled color, not every background texture, animation or later page color. The setting is not a transparent-background promise. Reusing the saved answer with 0/1 does not refresh its background sample.

## 10. Adaptive family, size and weight estimation

This feature is off by default and explicitly experimental. It identifies a concrete installed PostScript face; weight comes from the selected face (regular/bold/etc.), not a separately guessed CSS weight field. Missing fonts, identical raster aliases, variable-font axes and non-English recognition can prevent an estimate. The bundled default remains the uncertainty behavior.

The bounded analysis copy fits 2048×1280 while retaining logical units through `logicalWidth / analysisPixelWidth`. Vision runs fast English (`en-US`) OCR with language correction off, minimum text height 0.008 and the detected pane as region of interest. Prefer a CPU compute device so older hardware does not depend on an unsupported accelerator compiler. A scheduled cancellation requests a three-second OCR deadline; it is cooperative framework cancellation, not proof the OS always stops at exactly three seconds. Font matching has a separate six-second monotonic budget and checks cancellation/deadline between candidates.

Take at most 300 recognized observations. Eligible top candidates have OCR confidence ≥0.45 and 8–2048 characters. Sort by line height, group heights within 15% of the first height in each group, select the largest group (smaller heights win count ties), then compare the three most confident lines. Body-text voting is essential: selecting only the largest headings produced the wrong family/size for the answer body.

Lines longer than 90 characters are shortened at a whitespace boundary within the first 90; the prefix must still contain at least eight characters and have a valid OCR subrange rectangle. Expand the crop by two pixels, round outward and intersect the bounded image. Font candidates prioritize Satoshi, Menlo, Monaco, Arial, Helvetica, TimesNewRoman, Georgia, Courier, Verdana, Inter, Roboto, OpenSans and SFPro prefixes, then installed non-emoji/non-symbol faces, up to 128.

Raster matching uses the entire text line width for less quantized size estimates. Render each exact PostScript face at a reference size of 100, measure glyph ink width, estimate crop-pixel size from width ratio, round to quarter-pixel units and convert to logical points. Accept only 8–28 points. Verify CoreText actually resolves the requested PostScript name, rather than silently substituting another face.

Build source/template ink masks by finding the dominant background bin, measuring maximum RGB contrast, rejecting peak contrast below 24, selecting the 95th percentile contrast peak and thresholding at `max(8,peak*0.12)`. Normalize/bilinearly sample the tight ink rectangle into a 160×32 mask. Source crops are limited to 8192×512. Reject logarithmic aspect error ≥0.24. Rank normalized ink difference plus `1.5*aspectError`; best score must be ≤0.38 and separation from the runner-up at least 0.012. Confidence is `1-score`, so accepted estimates are at least 0.62. Near-identical aliases deliberately yield uncertainty.

Across the sampled lines, choose the face with most matching votes (then highest confidence), its median point size and mean confidence. Store only face name, size and confidence, with name ≤128 UTF-8 bytes and finite bounded values. Do not store/upload recognized text, sample crops or candidate rasters. Bottom-left always resolves to 9-point default regardless of this estimate. Enabling after a non-adaptive capture cannot infer unavailable metadata retrospectively.

## 11. Complete-line text layout and scrolling

Register Satoshi Regular only in the process. Default resolution tries `Satoshi-Regular`, `Satoshi Fallback`, `Open Sans`, `OpenSans`, `Arial`, `Helvetica`, then system regular; use 14 points and the `ss03` feature. Compact fallback uses the same default descriptor at 9 points. Missing font resources must not crash; fallback text still obeys viewport bounds.

PlainTextRenderer limits native text to 100,000 UTF-16 code units and removes an ending high surrogate before decoding. This is separate from the provider/service limits of 100,000 Swift characters and 400,000 UTF-8 bytes: a single enormous grapheme cannot bypass a byte bound, and a valid large answer can be truncated for native layout. Use literal attributed text with one font/ink style, left alignment, no paragraph-before/after margins, no first/head indent, no active links/attachments and word wrapping. Tabs use the measured width of four spaces, not fixed arbitrary pixels.

Measure CoreText typographic bounds across the text, including fallback glyph fonts. The uniform line height is the ceiling of `max(base ascent−descent+leading, measured ascent+descent+leading) + 2`. Set paragraph minimum and maximum to that same height. TextKit's `usesFontLeading` must be false because the renderer already included leading. Otherwise Latin and fallback emoji/CJK/Arabic rows have different fragment heights and can reveal a partial fourth row when scrolling.

At a provisional pane width, force layout and enumerate all glyph line fragments plus the extra blank fragment when text ends with newline. Measure used content width. Automatic pane admission requires finite positive intersection, width greater than 44 points and height at least 18; after actual layout, if one rendered row is taller than the pane, rebuild using compact fallback font/insets/frame. Base-font metrics alone are insufficient for mixed glyphs.

Choose visible row count as `min(3,max(1,min(totalRows,floor(availableHeight/rowHeight))))`. Set the viewport to the exact maxY of that row boundary, not a rounded panel-height approximation. The native panel and NSScrollView can round to backing pixels; restore the precise clip frame/bounds after tiling so rounding never reveals another row or cuts descenders. The document still contains the whole bounded answer; only the clip viewport is small.

Scroll finds the measured row nearest the current clip origin, advances/retreats by `max(1,visibleRows−1)` (two rows for a three-row viewport) and clamps to `max(0,totalRows−visibleRows)`. It scrolls to the target row's minY. Hidden answers do not scroll. Position/font changes preserve the character at the old top row, re-layout and scroll to the row containing that character, clamped at the new end. A pixel offset would lose reading position after wrapping changes.

## 12. Popup geometry and native properties

Select an exact saved target display when still present; otherwise automatic placement can use the pane's display, then captured cursor display, then main display. Compare saved display snapshots before restoration/presentation. Intersect a pane with the selected display's visible frame. Automatic pane width is the full valid pane width; use a 22-point horizontal text inset. Anchor the popup's top near captured cursor Y and move it inside pane edges rather than clipping rows.

Compact fallback uses the visible display inset by up to 16 points (bounded to one quarter for tiny displays), x/y at the inset bottom-left and six-point horizontal text inset. Fit width to measured used content plus both insets, constrained to 96–420 points where available. It is not the removed fixed-width cursor box. Overall provisional geometric height is at most 420 points, then shrinks to the chosen complete-row height. Invalid NaN/infinite/null/empty geometry returns no native frame. Extremely small displays cannot promise physical space that does not exist; manual native acceptance must test the minimum supported desktop geometry.

OverlayPanel is borderless, nonactivating, floating, all-Spaces/full-screen auxiliary/all-applications, nonopaque with a clear host background, no shadow, not movable, no automatic animation and not released when closed. It refuses key/main status; text/scroll/marker views refuse first responder and mouse/scroll-wheel handling. `ignoresMouseEvents` stays true after showing, hiding, dismissing and repositioning. The answer background view itself is opaque sampled color. The app does not repeatedly force ordering or steal focus to simulate persistence.

| Experimental mode | Requested difference |
| --- | --- |
| 0 `open` | Floating panel, read-only sharing, all Spaces/applications/full-screen auxiliary |
| 1 `legacySharingProbe` | Mode 0 plus legacy sharing `.none` |
| 2 `spaceBehaviorProbe` | Mode 1 plus `stationary` and `ignoresCycle`; startup default |

The mode engine observes native properties after application, audits requested/observed outcomes and offers a receipt for rollback. Unsupported collection behavior or mismatched level/behavior fails. A non-open mode may observe read-only sharing when legacy `.none` is ignored; the engine accepts that narrow observation while labeling visibility unverified/legacy ineffectual. Other sharing mismatches fail, and an uncertain rollback blocks sensitive use. None of these flags guarantees exclusion from third-party recording. Mode 2's badge is a historical experimental label, not a security assurance. Windows has no literal AppKit Spaces/sharing equivalents; its guide must specify tested outcome mappings.

## 13. Account identity, sign-in, refresh and disconnect

The account controller loads only its own protected account record. It does not read Codex credentials, browser profiles, another app's tokens or an API-key environment variable. A single record contains at most eight unique issued client registrations, each with validated issuer/subject, optional email, token set/expiry and a credential-generation UUID. Registration ID, not email, is the primary key; two same-email registrations remain separate. Selecting a saved registration does not merge histories or token contexts.

The local host identifier is a generated `urn:uuid:…` persisted before use. It identifies the installation host, not a user secret bundled into the app. Failed preference flush must not authorize a request with an undurable replacement host identity.

An explicit sign-in reserves ownership before any await. If the record is inaccessible, it requests authorized read on a worker with a 180-second deadline. A cancelled result cannot later reconnect the app. Readable already-connected state can be recovered without opening another browser authorization. Corrupt protected data is not overwritten to make onboarding appear successful.

The sign-in flow verifies exact discovery endpoints, binds an IPv4 loopback listener at `127.0.0.1:<available port>/auth/callback` before opening the system browser, and creates fresh random state/nonce/PKCE verifier. New registration uses `dynamic_agent_client` only for registration; the callback must provide an issued `oaiapp_…` client ID. Returning sign-in uses the selected issued ID and optional retained ID-token hint; a callback supplying a different issued ID is rejected. Authorization denial is handled after validating state and never exchanges a code.

The authorization query contains identity and plan scopes, resource `https://api.openai.com/v1`, host identity, exact redirect URI, S256 challenge and nonce. Exchange uses that same redirect URI including its selected port. Callback scheme/host/port/path, unique fields, state and bounded code are checked. Listener header/connection/time limits prevent arbitrary local requests from keeping the flow alive indefinitely. It closes rejected connections and continues waiting for the legitimate callback within the original deadline.

Token parsing requires HTTP 200, bounded whitespace/control-free access/refresh/ID tokens, literal Bearer type, finite 1–86,400-second lifetime and bounded scopes. Sign-in requires ID-token signature validation against JWKS, exact issuer, issued-client audience, authorized-party rules, nonce and valid timing. A returning registration's validated subject/issuer must match its protected identity. Merely decoding JWT JSON does not validate it. Signing in successfully without both `resource.invoke` and `chatgpt.tokens.use.direct` remains a connected identity needing plan consent, not an inference-authorized session.

The current source uses the publicly documented open-source Sign in with ChatGPT flow. Its exact local validation/storage contracts are specified here and in [PROTOCOLS.md](PROTOCOLS.md); account eligibility and preview conditions remain external. See [OpenAI registration/sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in). A future builder must verify the provider's current contract before enabling real requests, rather than silently importing another app's session or changing the funding/authentication model.

### Refresh ownership and post-await validation

Every access-token request re-reads protected state before using a cached unexpired credential. A token more than 60 seconds from expiry can return without HTTP refresh. Near expiry, the first caller owns one refresh task; joined callers share it. Native per-client locks serialize rotating refresh across processes; the owner re-reads under the lock so another instance's newer token can be adopted without rotating the old refresh token again.

The rotating result must replace access token, refresh token, granted scopes, ID token and expiry together. Transaction closures cannot await or perform HTTP. They compare the expected registration/generation and preserve concurrent unrelated accounts/selection. A disconnect or rotation by another controller cannot be overwritten by an old refresh result. Recognized terminal refresh errors clear that matching registration's tokens; transport, rate-limit or server failures do not masquerade as confirmed remote sign-out.

A completed refresh task is not sufficient authority by itself. Another main-actor task can disconnect/rotate the account after the refresh finishes but before an awaiting caller resumes. Each waiter checks cancellation/local generation, re-reads the protected record and compares the selected entire registration, credential generation, returned access token and plan permission before returning. This is the 0.6.1 stale-credential correction.

Joined waiter cancellation resolves its own bounded wait immediately without cancelling an uncancelled owner. Owner cancellation/failure cancels the owned refresh task and releases ownership. Deadline gates ignore late completions. Changing the selected account while sign-in/refresh ownership is active is refused; application-level account changes clear pending capture/queue/context and increment generations before adopting new authorization.

### Local disconnect and remote revocation

Disconnect supersedes pending authentication/save/model/capture tasks, disables submission consent and clears content before asynchronous bookkeeping can resume. Local credential removal must still be attempted when preference/audit storage is unavailable. It clears tokens in a protected transaction and rotates credential generation; keeping the registration's issued identity supports later explicit reauthorization.

Remote revocation is separate from local disconnect. Up to eight per-client workers are retained. Each worker attempts revocation at most twice; retryable first failure waits one second. Distinct clients never cancel each other's revocations. If the same client disconnects again while a worker runs, keep one pending latest refresh token. Replacing an already pending token records an unconfirmed outcome rather than claiming the displaced token was revoked. Worker-cap overflow also records an unconfirmed outcome; local disconnect is not delayed.

Status appends remote-pending and unconfirmed warnings without replacing a newly connected account's base state. Completion must not overwrite the sign-in UI while it owns authentication. The warning remains during the current app run; it is not a durable remote-revocation queue. Closing the process can prevent a pending remote attempt. Provider Settings are the user's recovery path for remote authorization that cannot be confirmed locally.

## 14. Consent, privacy history and complete-response publication

`PrivacyController` is an actor separate from the UI. An image submission needs acknowledged session consent, network enabled, a present valid credential, exact configured source/selected-window identity, valid bounded masks and evidence those masks were applied. Every image in a batch must be nonempty and within the current byte ceiling; one unsafe image rejects the whole batch before provider creation.

`beginSubmission` reserves an operation UUID and image references before awaiting the mandatory `llm_request` audit. The request-active indicator becomes true only after that audit succeeds. Actor reentrancy is expected: consent revocation or cancellation during the await can clear the operation. After the await, check the same operation ID and consent again before authorizing transmission. An old cancellation cannot authorize itself or clear a new operation.

The provider buffers streamed deltas internally; the popup never receives partial content. The service requires a completed provider summary and a non-whitespace final string, writes `llm_completed`, checks cancellation, commits privacy history, checks cancellation again and only then returns/publishes final text. Completion audit failure cannot publish text or commit history. App presentation adds another audited capability/generation/display check before drawing. A late result after clear/disconnect/settings/termination is discarded.

History retains only bounded response text and non-content operation/provider/model/source/prompt-character metadata. It never holds screenshots or original prompts. Provider context uses a fixed task prompt with recent eligible complete responses. Context is isolated by account/application changes, and ordinary Save can retain prior response history when no operation is active; recent entries become the fixed history prompt `Previous capture discussion` rather than retaining original questions. History limit is 0–10; reducing it trims immediately and cannot be undone by a late completion with the old limit. A scoped `cancelSubmission(id:)` cleans just that operation, preserving unrelated history; app-level clear/disconnect/cancel-all explicitly clears history. Do not merge those two contracts.

### Provider request and stream rules

Account model discovery is a bounded separate GET, not evidence a screenshot was transmitted. Accept only valid visible `models[].slug` entries, unique and at most 500, from a ≤2 MiB document. This revision permits `gpt-6.1-sol` image input independently of catalog visibility; another selected ID fails capability checking instead of silently substituting a model.

The request is `POST /v1/responses` with Bearer token, `store:false`, `stream:true`, instructions and ordered input messages. Each image is a JPEG data URL; current images precede current task text. History stays chronological in complete user/assistant pairs. Effective instructions include the user-configured system prompt and a screenshot-as-untrusted-data boundary. Text/instructions/history share a 64,000-byte budget; choose recent pairs within that budget, then put them in chronological order. No arbitrary API tuning or server-persistence fields are added.

Transport is ephemeral with no cookies/persistent cache, no redirects and no automatic inference retry. Request/resource limits are 60/180 seconds. Present Content-Type must be `text/event-stream`; a missing advisory header is accepted only if the strict stream state machine fully succeeds. Parser limits are 1,048,576 bytes per event and 4,194,304 total, with a smaller 65,536-byte delta envelope. The stream-to-consumer queue contains at most 32 buffered deltas; a dropped yield fails with consumer-too-slow rather than growing without bound.

SSE handles incremental UTF-8 including split BOM, CR/LF framing, comments and multiline data. Known event names must agree with JSON `type`. Response ID/model/stage and content indexes are validated; unknown events do not become answer text. `done`/completed aggregate envelopes may repeat the final text and must not append it a second time. Failed/incomplete/error/early disconnect/mismatched model/malformed or oversized data stops the request. At most 100,000 Swift characters and 400,000 UTF-8 bytes are accepted across text. Empty/whitespace-only completion is rejected by the submission layer before history/publication.

These are deliberate restrictions of Harness, not a claim to support every Responses API modality/event. The provider has no native tools, file writes or code execution. See [OpenAI streaming documentation](https://developers.openai.com/api/docs/guides/streaming-responses) for the external transport family; [PROTOCOLS.md](PROTOCOLS.md) fixes the precise supported subset for this reconstruction.

## 15. Metadata audit, protected files and failure latch

AuditLogger serializes records as an actor. Each record has schema 1, UTC wall-clock timestamp, event, mode 0–2, OS description, logger-session UUID, event UUID, nullable experiment UUID, positive per-session sequence and allowlisted payload. Sequence is advanced only after a complete sink append succeeds. Encode sorted JSON, validate by decoding it again, append newline and enforce a 65,536-byte record bound. Wall-clock display timestamps and monotonic elapsed measurements serve different purposes; never subtract unrelated process clock domains as if they were identical.

Payloads exclude screenshots, JPEG/data URLs, system/task prompts, answer text, tokens, authorization callback URLs, browser history and window titles. Unknown/nested secret-content keys, excessive depth/arrays/maps, malformed types, invalid identifiers and nonfinite geometry are rejected. Ordinary classified metadata may include app/source/mode, capture/scan/window/process IDs, dimensions/bytes/hash, timing, counts, mask status, requested/observed window properties and configuration-change time. Exact required keys/event names are in [PROTOCOLS.md](PROTOCOLS.md).

The POSIX sink uses a private directory and an owned regular single-link file opened without following symlinks. Verify the descriptor's owner/type/link count before use and again under its lock. Use exclusive advisory locking with a finite budget (at most five seconds), bounded interrupted/short-write retries and durability sync. Lock deadlines use monotonic time; malformed timeout budgets fail before creating/truncating files. A FIFO/socket/device must not block the UI during open. Cooperating process appends must remain whole JSON lines; a crash can still leave a malformed final tail.

Any schema or I/O failure latches the logger. App code then cancels sensitive work, clears retained content, disables readiness and refuses capture/submission until underlying storage is repaired and the app restarted. An error UI may remain usable; it must not imply a provider request is still allowed. Logs are neither authenticated nor tamper-proof: another same-user process with access can alter them. The design protects safe operation and prevents accidental content logging, not a privileged forensic adversary.

Report writing is also protected but is not crash-atomic replacement. The writer creates/opens an owned regular single-link path, takes a bounded exclusive lock, **rechecks after the lock** and only then chmods/truncates/writes/syncs. A hard link introduced during lock wait must be refused before either alias is altered. CLI input/output alias checks resolve existing ancestors and compare device/inode so a report cannot overwrite its audit/detection input through direct, symlink or hard-link aliases.

JSONLReader opens no-follow, nonblocking regular descriptors, takes shared locks, checks size under lock and reads in bounded chunks. Limit each file to 64 MiB, each line to 65,536 bytes and line count to 100,000; finite EINTR retry protects responsiveness. Complete valid records can be returned alongside read issues, but any relevant issue blocks an accuracy claim. A partial final line is an explicit malformed-tail issue, never accepted as a completed event. Audit merge reads separate emitter/operator logs and retains both issue sets; canonical/same-inode aliases are read only once.

## 16. Independent detector and matrix workflow

`harness-detect` is an independent metadata CLI with `scan`, interactive `matrix`, `correlate` and help. It never tells the app to take a screenshot, change a mode or activate another capture scope. Scan combines public CoreGraphics window metadata and separately gated ScreenCaptureKit shareable metadata. It reports permission/unsupported/failed/partial outcomes rather than requesting authorization or inventing missing observations.

Observations retain bounded window/process identities, display/geometry/sharing/layer/system-owner/classification/confidence/filter/status metadata. They do not retain window titles or pixels. Legacy sharing `.none` is a classification signal, not pixel evidence. Public Space association remains unsupported. A metadata scan that did not list a window is not proof a recorder excluded it.

The research matrix is three experimental modes × three capture sources. The operator changes Settings and physically initiates the next capture for each cell. Arming binds a chosen emitter launch session, experiment/step IDs, configuration, cutoff sequence and monotonic times. Require strict original emitter order, unique event IDs, coherent mode/source and at least 200ms since the committed configuration-change timestamp. Readiness cannot be shortened by time spent awaiting its audit write.

After arm, a new mode/settings capture-configuration change invalidates the step. Start/completion/failure events must belong to the next physical capture and preserve capture/window/process/source identity. A null start display can resolve at completion; it cannot become conflicting identity. Missing captures time out with a classified failed attempt. Rejected/unattempted/completed/failed/partial cells remain distinct; the final report always shows all nine cells.

Version 0.6.0 emitted an exact position-only applied settings event with `changed_keys=["overlayPosition"]` and neither source nor configuration timestamp. The coordinator ignores only that legacy shape when reading capture configuration; any partly populated capture change stays malformed. Current position switching includes complete source/timestamp metadata so it cannot poison subsequent arming. A position switch after arm is still an applied settings change and invalidates the armed measurement under the current conservative contract.

When matrix uses an external emitter audit path, merge the operator audit in the output directory into final reporting. Otherwise failed/timed-out operator attempts vanish and the report becomes misleading. Keep both readers' diagnostics. Alias detection avoids reading the same file twice; identical records are also deduplicated during offline correlation.

### Calibration and independent truth

Explicit Settings calibration displays a 16-point asymmetric marker instead of answer text: sRGB magenta `FF007F`, black top-left 4×4 points, white lower-right 4×8. It does not request inference. Marker analysis uses original sRGB pixels before masks/JPEG and maps the saved panel/patch through exact capture/display geometry.

Within each region require at least four interior samples, channel tolerance 24 inclusive and at least 90% agreement. Confidence is the minimum regional match fraction. A match can establish marker inclusion. Absence is meaningful only with independently established visible, stable, unoccluded marker geometry; occlusion, movement, invalid format/color/rotation, clipping or missing evidence is indeterminate. SCK display-oriented pixels must not be rotated a second time. `overlay_in_capture` is true/false/null with corresponding calibration status/reason, not a guessed Boolean.

Offline correlation first validates/deduplicates records, then orders validated emitter events by per-session sequence. This is intentionally different from matrix's strict incoming-order requirement. Join on explicit session/capture/window/process/configuration identities and bounded timing; do not match solely by a nearby timestamp or substitute an unrelated window row for a missing target. Scan completeness, row counts/truncation, duplicate conflicts, clock-domain agreement and independent truth determine whether a sample supports metrics.

A fatal malformed-tail/schema/read/conflict issue makes identity-matched samples indeterminate and increments that count. Matched identity may remain counted separately from trusted accuracy. Missing independent truth yields N/A metrics, not assumed true/false positives. Completed attempts, failed captures, rejected labels and never-attempted cells remain in methodology. Reports escape/redact classified metadata and present uncertainty alongside the nine-cell projection.

## 17. Complete resource limits and deadline ledger

| Boundary | Current limit / behavior |
| --- | --- |
| Configurable shortcut digits | Four distinct values 2–8; fixed 0/1/9; seven total registrations |
| Original image | Positive; each edge ≤16,384; area ≤64,000,000 pixels |
| Display scale / rotation | Finite 0.5–4; 0/90/180/270 degrees |
| Mask regions | ≤32; finite normalized top-left rectangles wholly within image |
| Processed JPEG | Longest edge 64–1568 setting; 10,000–1,000,000-byte setting; five quality levels 0.90…0.55; resize factor 0.8 |
| Queue | Six entries; 300,000,000,000ns from first append; ≤6MB configured JPEG data plus bounded metadata |
| Protected account record | ≤2,097,152 encoded bytes; ≤8 distinct registrations |
| OAuth token strings / scope | ≤65,536 bytes each token; scope string ≤4096 bytes; ≤128 unique scopes, ≤256 bytes each |
| OAuth HTTP body | ≤262,144 response bytes; 30s request / 60s resource |
| Explicit Keychain recovery / OAuth callback / refresh wait | ≤180s caller gates; cooperative native work can finish later and be ignored |
| Loopback listener startup / requests | 10s startup; ≤10 concurrent connections; ≤16,384 request bytes; bounded callback lifetime |
| Native capture/enumeration callbacks | Five-second caller gates; late callback ignored |
| Pane analysis | Source ≥200×100; bounded copy ≤1800×1200; cancellation between columns |
| Typography | Copy ≤2048×1280; OCR cancel requested after3s; comparison budget6s; ≤300 observations/128 faces/3 sampled lines |
| Accepted adaptive estimate | Face name ≤128 bytes; finite 8–28pt; confidence0.62–1 |
| Provider credential validation | Access token ≤16,384 UTF-8 bytes and no whitespace/controls; stricter than stored OAuth string ceiling |
| Account catalog | ≤2,097,152 bytes; ≤500 valid catalog entries |
| Inference transport | 60s request / 180s resource; no redirects or replay |
| SSE / delta / buffer | 1,048,576-byte event; 4,194,304 total; 65,536-byte delta envelope; 32 queued deltas |
| Answer | ≤100,000 Swift characters and ≤400,000 UTF-8 bytes; native text ≤100,000 UTF-16 units |
| History / request text | 0–10 responses; instructions/current prompt/history share64,000 bytes with per-pair overhead |
| Custom prompt | ≤16,000 Swift characters /64,000 UTF-8 bytes; nonblank; permitted tab/LF/CR controls only |
| Popup | One to three complete rows; compact width96–420pt where space permits; geometric height≤420pt before fitting |
| Audit / file locks / report | Record≤65,536 bytes; lock≤5s; finite interruption/sync retries; report≤2,000,000 UTF-8 bytes |
| JSONL read | ≤64MiB per input; ≤100,000 lines; line≤65,536 bytes; partial tail reported |
| Detector records | Encoded line≤16,384 bytes; windows/counts≤4096; record errors≤32; bounded classified metadata |
| Matrix timing / CLI | Settle≥200ms; timeout default120s, configurable1–300; skew default500ms, configurable0–10,000 |
| CLI arguments | ≤25 arguments; each≤4096 bytes; no NUL; command-specific unique options |
| Installer archive | ≤2000 entries; ≤512MiB expanded; no unsafe path aliases/special files; strict CRC/signature/identity |

These are distinct bounds; never assume one replaces another. For example, a stored OAuth string can pass its storage limit but fail the provider's stricter access-token validation, or a valid long UTF-8 answer can be shortened for native UTF-16 layout. Errors send nothing and require manual retry where retry is meaningful.

## 18. Acceptance contract and intentional limits

A reconstruction must prove fake account/HTTP/pixel/clock tests before native integration. Physical keyboard dispatch, protected authorization, multiple displays, browser/full-screen/Spaces behavior, capture scope, fractional backing pixels, signing/installation and recorder observations require named native checks with evidence. The previous 0.6.1 audit's actual results are in [VERIFICATION.md](VERIFICATION.md), and the scenarios are in [REGRESSION_CATALOG.md](REGRESSION_CATALOG.md).

Do not recreate removed behavior: function-key bindings, cursor box, idle dismissal, partial streamed answers, hidden-answer recapture, silent source/model fallback or automatic replay. Do not claim exact font identity from pixels, guaranteed recorder invisibility, physical RAM erasure, trustworthy metrics without independent truth or Windows parity from macOS tests. Unsupported capabilities must have explicit classified outcomes and remain failed/unverified until their native gate passes.
