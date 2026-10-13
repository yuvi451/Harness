# Harness 0.6.1 security and privacy boundaries

This document describes implemented controls and their limits at code revision `6034926`. It is an engineering threat model, not a guarantee of universal recording exclusion, forensic deletion or provider availability. [SPEC.md](SPEC.md) defines exact product limits; [PROTOCOLS.md](PROTOCOLS.md) defines allowed data; [REGRESSION_CATALOG.md](REGRESSION_CATALOG.md) identifies tested scenarios.

## 1. Capabilities and explicit user actions

Harness uses public AppKit, Carbon, ScreenCaptureKit, Security, Vision/CoreText and OAuth APIs. It has no login item, privileged helper, kernel component, event tap, continuous capture, microphone/audio capture, browser-profile credential discovery or model-controlled native tools. Native window sharing properties are experimental metadata, not an evasion guarantee.

A physical registered request/queue shortcut is the acquisition boundary. Startup, Settings navigation, hide/show, position switching and metadata/window refresh do not acquire an image. Screen Recording must be granted and exact scope must validate. Onboarding discloses that requested screenshots and recent answer context go to OpenAI through the connected ChatGPT plan. Sign-in and acknowledgment enable analysis; local disconnect disables it and cancels sensitive work. A stored preference or decodable ID token alone is not submission authority.

Hide/show intentionally retains the answer/reading position. It must not be described as deleting private content. Clear/cancel, relevant account/settings transitions, failure latch and termination release application references as their scope requires. The fixed 0/1 actions never cause another capture/provider request, including while a response is pending. A hidden saved answer still blocks a new request until 9.

## 2. Data inventory and lifetime

| Data | Where it exists | Lifetime / boundary |
| --- | --- | --- |
| Original native screenshot | One native frame and local processing workers | Until processing/analysis completes or cancellation cleanup; never history/queue/disk content |
| Redacted/resized JPEG | Prepared result, queue, authorized in-memory operation/request body | At most six queued; five minutes from first append; released on take/success/failure/cancel/clear/termination |
| JPEG data URL / HTTP body | Provider request object/framework memory | One authorized request; body reference removed in cleanup; framework copies not under app erasure control |
| Recognized OCR strings/raster font samples | Local bounded analysis | Not persisted, audited or separately uploaded; discarded when worker completes |
| Pane/color/font/cursor/display estimate | Saved answer presentation metadata | Until answer is cleared/discarded; no screenshot pixels included |
| Visible/hidden answer | OverlaySession/TextKit and response-only history | Answer until explicit clear; history within0–10 runtime bound; no answer text in audit |
| Task/system prompt | Settings draft/ordinary preferences and request | Custom override persists as ordinary local preference; transmitted only as request instructions, not secret vault data |
| Account issued identity/tokens/expiry | Own protected Keychain record | Persist across restart; whole-record atomic rotation; tokens cleared on disconnect |
| Host UUID / nonsecret preferences | Explicit UserDefaults domain | Durable installation/configuration state; not authentication secret |
| Audit/detection/report | Private per-user Application Support metadata files | Persist independently; content-free allowlisted records; no automated deletion on app update |
| Signing identity | Owned local signing keychain/private configuration or publisher keychain | Outside source/archive; stable across updates; not runtime account authorization |

Clearing references does not promise overwriting physical RAM, encrypted/unencrypted swap, kernel/framework copies, GPU surfaces, crash diagnostics or provider-retained content. The app does not save screenshots/answers for convenience or enable external tracing to debug sensitive paths. Synthetic fixtures and opt-in private image references stay outside shareable source.

## 3. Capture scope and local redaction

`excludingSelf` verifies current process plus bundle identity in native shareable application metadata, including offscreen own windows when needed for full-screen Spaces. It fails when that identity cannot be established; it does not broaden to `full`. Selected-window capture requires the exact live window and unambiguous current display geometry. Display snapshots and post-capture target checks reject observed movement/removal; they cannot detect every change-and-return between observations.

Masks are validated normalized top-left rectangles. Redact original-resolution pixels before resampling; use outward floor/ceil bounds and opaque black. Resizing before masking can mix private pixels into neighboring JPEG samples and is prohibited. A masking-enabled request must include valid nonempty regions and processed `masksApplied` evidence for every image. One failed/unsafe image rejects the whole batch.

Local appearance/font analysis uses the existing frame. It has no extra screenshot or network call and cannot inspect pixels outside a selected-window scope to sample unrelated desktop background. OCR results are task-local, not cached metadata. Confidence/fallback behavior bounds inference from pixels and avoids pretending exact typography was identified.

## 4. Consent, audit and publication gates

PrivacyController reserves an operation UUID/images before awaiting `llm_request`. No provider is created until that metadata write succeeds and the same operation/consent still exists afterward. Cancellation/revocation can happen during actor suspension, so checking once before the await is insufficient. Request-active status reflects the completed audit gate.

The provider has no file/process/capture tools. Screenshot text is untrusted model input; appended instructions tell it not to alter app settings, acquire screens, reveal credentials or execute commands. This prompt boundary complements native absence of tools; it is not a guarantee the model follows every instruction or returns correct code.

Partial streams are held internally. Complete response ID/model/stage, bounds, nonblank final text and completion audit must all pass before privacy history/publication. Final UI presentation checks current generation and display geometry again. Raw HTTP/error bodies are not shown/audited; errors are classified with bounded messages. Automatic inference retry is disabled to avoid retransmission/spending without another user action.

Scoped operation cleanup is deliberate. `cancelSubmission(id:)` cannot clear a newer operation and need not erase unrelated history. App-wide clear/disconnect/cancel-all explicitly clears retained history. Confusing these paths can either leak retained context or let stale cleanup erase new work; regression tests cover both sides.

## 5. OAuth and registration identity

The controller uses an explicitly authorized public-client loopback flow with random state, nonce and PKCE S256; no client secret is bundled. Listener binds IPv4 loopback only before browser launch, limits callback time/connections/header bytes, rejects unrelated path/duplicate fields/wrong state and closes rejected connections. It never uses `localhost` as an interchangeable callback host or accepts a different redirect path/port within an attempt.

New registration must retain the issued `oaiapp_…` client ID from its validated callback. `dynamic_agent_client` is a registration marker, not a durable account identity. Same-email registrations remain distinct. Returning authorization must preserve selected client and verified issuer/subject. JWKS/RS256 signature, issuer/audience/authorized-party/nonce/timing checks precede credential adoption. JSON-decoding a JWT payload is insufficient.

Discovery endpoints are compared with compiled HTTPS constants, transport is bounded/ephemeral and redirects are rejected. Whole access/refresh/ID/scopes/expiry sets rotate together in protected transactions. Plan permission checks require the granted scopes; a verified identity without them cannot submit images. Current provider eligibility/preview restrictions remain external; see [OpenAI's sign-in contract](https://developers.openai.com/siwc/token-sharing-open-source/sign-in).

## 6. Keychain authorization and concurrent rotation

The app's Keychain service is `org.harness.research.chatgpt`, account `accounts`; record ≤2MiB, eight registrations maximum. It does not read another app's account store or inherit browser tokens. Routine reads/writes suppress modern authorization UI and legacy interaction policy. Only an explicit Settings recovery allows a protected native prompt, on a worker with a deadline. Cancellation prevents adopting its late result but cannot override OS authorization or guarantee the protected UI immediately disappears.

The C bridge serializes process-wide legacy interaction-policy changes with a recursive lock and restores prior policy in cleanup. A quiet operation encountering an ongoing protected interaction fails promptly instead of waiting on the UI actor. Private process/file locks serialize whole-record transactions and per-client rotating refresh across controllers/processes. Transactions do not await network work.

Every access-token request rereads protected state. After an awaited refresh, compare local operation generation, selected full registration/credential-generation UUID, access token and plan scopes again. A disconnect in another controller must be visible even after the owner finished HTTP. A cancelled joined caller leaves an uncancelled owner running; owner failure/cancellation cancels its task. Storage failure blocks account use instead of silently replacing a corrupt record.

## 7. Disconnect and revocation limitations

Local disconnect immediately stops consent/content operations, cancels pending tasks and removes local token fields with a new credential generation. It remains necessary even if metadata or preference persistence fails. Remote revocation is a separate bounded attempt, not evidence local credentials remained active.

Per-client workers avoid cancelling another account's disconnect. At most eight workers and one pending replacement token per client are held. Failed, overflowed or displaced pending tokens leave an unconfirmed warning in the current run; successful work does not erase an older unconfirmed outcome. Warnings compose with a new connected/signed-out state rather than overwriting it. If the process exits, a pending remote request may not finish; no persistent credential-bearing retry queue is written. The user's provider account Settings are the manual remote-revocation recovery path.

## 8. Metadata storage and report integrity

Audit accepts only event-specific bounded keys/types and classified metadata. No image pixels/base64, custom/task prompts, answers, tokens, callback URLs or window titles belong in payloads, including nested environment/error objects. Schema validation precedes encoding and re-decoding; size/depth/collection limits prevent unbounded data. Failure latches the logger and stops sensitive actions.

Private/no-follow regular single-link descriptors, owner checks, bounded advisory locks, complete writes and finite EINTR/sync retries protect cooperating operations. Recheck file metadata under the lock; an attacker/other process can add a hard link during the wait. Report output rechecks before truncation. CLI canonical-path and inode checks prevent report output from aliasing either input. Reader diagnostics retain unsafe/missing/oversized/partial/schema/lock failures and invalidate accuracy.

These controls do not authenticate records or stop a privileged/same-user adversary with legitimate write access from fabricating metadata. Locking is cooperative. Report replacement is not crash-atomic. The detector's classifications and a legacy sharing flag never prove pixel invisibility; independent truth and completeness/timing/identity evidence are required. Do not turn missing data into a successful security claim.

## 9. Installation, signing and source export

Account/preferences/audit storage is outside source and app bundle; an update preserves it. Packaging uses dedicated temporary scratch/staging so synced-folder Finder metadata does not invalidate a bundle. Strip debug information and remap source/build paths before signing. Scan release content for supported credential patterns/developer paths without echoing matched secret values. This scanner is a guard, not detection of every possible private string.

The installer enforces bounded ZIP entries/expanded bytes, canonical safe paths, case/Unicode aliases, CRCs, expected bundle identity, strict signatures and the same designated signing requirement before atomic exchange/rollback. It refuses a running app and silent identity migration. Do not reset TCC, change trust, disable SIP, weaken Keychain policy or delete account records to make installation seem quiet. A new self-signed executable hash may still need explicit protected recovery despite the same certificate.

Public distribution requires an owned Developer ID identity, hardened-runtime/timestamp signing, accepted notarization, stapling and Gatekeeper checks. Local signing is a local development result. Source export includes reviewed tracked text/resources/notices but omits Git/runtime/build data and the separately supplied OTF; preserved notices are not rewritten. Archive verification/provenance precede initializing Git on an extracted source snapshot. Signing keys, certificates with private keys, API credentials and actual screenshots never travel with builder docs.

## 10. Windows parity boundary

Windows must retain the same explicit-action, content, scope, ownership and publication boundaries, while implementing native storage/input/capture/window/file-handle controls. Credential Manager blob limits do not fit the current whole-record ceiling; a bounded DPAPI-protected, per-user ACL-restricted atomic record is specified in the Windows builder. Protect reparse points/hard links using opened-handle metadata, not path strings alone.

Windows Graphics Capture has no literal ScreenCaptureKit process-exclusion filter. Window display affinity is limited to owned top-level windows and supported capture paths; it is not per-caller filtering or DRM. Spaces/full-screen behavior also lacks literal AppKit equivalence. The blueprint makes strict parity measurable and fails unsupported scope instead of silently widening capture. No Windows native test was executed for this documentation; a proposed implementation is not a security acceptance result.

## Source and release identity hygiene

The shipping policy is [SHIPPING_PRIVACY.md](SHIPPING_PRIVACY.md). Use a repository-local generic author/committer identity (`Harness Maintainers`, `maintainer@example.invalid`), and never inherit a developer's personal global identity for distributable history. Review local Git remotes, configuration, all reachable/unreachable objects and reflogs as well as the current files. Use a clean reviewed source export for handoff; exclude Git/build/editor/Finder metadata, logs, credential stores, private certificates, screenshots and licensed font binaries that require separate acquisition. Preserve upstream copyright/license attribution and public endpoint/client identifiers.

The release privacy guard detects the scanning machine's identity at runtime without storing it in the source, checks UTF-8 and both UTF-16 byte orders, and reports only entry numbers and issue classes. Check archive member names, comments and extra fields as well as file contents. Strip ZIP owner IDs and extended-attribute/resource-fork containers. Review opaque, encrypted and arbitrarily named private data manually; a pattern scanner cannot prove the absence of all secrets. Keep runtime login records and signing keys in their OS stores outside the product tree. Sanitizing a source export does not revoke keys, wipe runtime accounts, change a signed binary or establish notarization/Windows acceptance.
