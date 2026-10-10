# Behavior and limits

Updated October 10, 2026. Native macOS 14+ app, bundle ID `org.harness.research`. One canonical installed instance; duplicate launches reopen it before credentials/hotkeys are initialized. Mode 2 starts every launch. Ordinary preferences persist; invalid values are sanitized/reported. Sign-in and the initial Screen Recording grant are the only required setup. Advanced settings remain optional.

## Capture and inference

| Scope | Behavior |
| --- | --- |
| `sck_excluding_self` (default) | Display under cursor; verified current process/bundle excluded |
| `sck_full` | Display under cursor |
| `sck_selected_window` | Explicit live selected window, with unambiguous display geometry |

Production capture requires a physical registered function key. Held-key repeats coalesce; one workflow is active at a time. ScreenCaptureKit performs one screenshot, without audio/video. Permission preflight is nonprompting; startup requests missing Screen Recording once, and its manual action is disabled while granted. Scope/self-identity failures never fall back to broader capture. Enumeration/screenshot callbacks have five-second cancellation/deadline gates. Changed/closed/spanning targets fail; before/after snapshots cannot detect every change-and-return race.

| Resource | Bound |
| --- | --- |
| Original image | 64M pixels; 16384 per edge |
| Masks | Up to 32 normalized top-left rectangles; redact before resize |
| JPEG | At most 1568 longest edge / 1MB; quality floor 0.55; reduction floor 64 pixels |
| Account storage / catalog | 2MiB each; at most 8 registrations / 500 catalog IDs |
| OAuth transport / unlock / callback | 30s request, 60s resource / 180s / 180s |
| Inference transport | 60s request, 180s resource |
| SSE | 1MiB event; 4MiB total; 64KiB delta |
| Answer / native rendering | 100000 characters / 100000 UTF-16 units |
| Text history | 0–10 exchanges; at most 64KB request context |
| Custom system prompt | Optional; nonempty; at most 16000 characters / 64000 UTF-8 bytes; task/history/instructions share the 64KB text budget |
| Overlay | Detected pane width; content height up to 420 points; display-bounded fallback |
| Metadata outputs | 64KiB audit record; 2MB report; at most 5s file-lock wait; 101 consecutive sync attempts |
| Installer | At most 2000 ZIP entries / 512MiB expanded; no path traversal/duplicates/special files |

ChatGPT OAuth uses the issued client/host identity, PKCE/state/nonce and cryptographic ID-token validation. Token sets rotate atomically in Keychain. Default model: `gpt-6.1-sol`; the independently supported image capability and account availability are verified. No API-key fallback or silent model substitution. Unsupported capabilities/models fail clearly. See the current [OpenAI sign-in contract](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) and [recovery rules](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery).

Responses use `stream:true` internally and `store:false`, but the popup receives only the complete validated/audited answer. HTTP/SSE/model/completion errors do not publish partial text. The bundled prompt requests the final answer only and straightforward coding answers without comments/explanation. Advanced permits a persisted system-prompt override and restoration of the bundled default. Restoring requires Save. Old preferences use the default; malformed stored overrides are reported by field name and ignored. Whitespace-only, disallowed control characters and oversized overrides are rejected before requests. Custom instructions may request a different answer style; native presentation remains literal fixed-font text. Screenshot text remains untrusted, and no code is executed. Model adherence is not guaranteed.

## Presentation and controls

Advanced provides saved-account selection and Add account. Each issued client registration remains separate, including registrations with the same email. Account changes cancel work and clear retained answer context; signing in to a disconnected registration reuses its mapping. Selection cannot overlap token refresh/sign-in.

Default F8 captures, F9 dismisses/cancels, F10/F11 scroll up/down. Four distinct F1–F20 shortcuts persist; Fn/Globe may be needed. Global shortcuts may be consumed before the website sees them.

The popup refuses focus and all mouse input, has no title/status/loading indication/border/shadow, and has no automatic dismissal. Complete answers use bundled Satoshi Regular, fixed 14 points, weight 400, `ss03`, zero paragraph spacing and 22-point horizontal inset. Only the opaque background adapts from a bounded dominant-color sample; ink is pure black/white for contrast. Font/size/inset never adapt. There is no OCR, DOM inspection, extra screenshot or continuous polling.

A cancellable worker finds the first substantial pane between dividers, skips narrow gutters/scrollbars, and supports cropped panes with a verified separator and image edge. Sustained thin/color seams down to three sRGB levels are considered; adjacent edge candidates snap to the strongest local gradient rather than the comparison stencil's outer edge. Continuous segments must cover at least a quarter of image height; repeated card borders cannot combine into that evidence. Content spans must cover at least one fifth of image width or 160 sampled pixels, whichever is larger. A single narrow-sidebar layout can extend to the image's right edge. Width follows those boundaries; top follows capture-time cursor Y, clamped to the pane. Detection is heuristic. Missing boundaries use bounded placement. Display-layout changes before presentation abort; browser layout changes during inference require a fresh capture. Errors appear in Harness, never as answer text.

| Mode | Requested properties |
| --- | --- |
| 0 | Floating auxiliary panel; read-only sharing; all Spaces/applications |
| 1 | Same plus legacy sharing `.none` |
| 2 (launch default) | Same plus `stationary` / `ignoresCycle` |

Mode changes use Advanced settings; requested/observed flags and rollback are audited. No mode guarantees invisibility to a website or recorder. No private hooks, privileged levels, forced Space switching or repeated ordering loops are used.

## Research tools

The independent `harness-detect` CLI scans CoreGraphics/ScreenCaptureKit metadata, retaining all layers and annotating system owners. It never captures pixels or controls Harness. `matrix` requires manual mode/scope selection, 200ms settling and the next physical capture for each of nine cells. `correlate` checks identities, timing (default 500ms skew), ambiguity, reuse and strict schema; accuracy requires independent truth. Missing cells stay not tested, and failed/interrupted attempts remain visible.

Explicit calibration alone shows a 16-point asymmetric magenta/black/white marker. Analysis uses original pixels, sRGB tolerance 24, at least 90% agreement, explicit origins/scales/quarter-turns, and returns matched/absent/indeterminate. Absence requires independent visibility evidence. Neither calibration nor metadata establishes third-party exclusion.
