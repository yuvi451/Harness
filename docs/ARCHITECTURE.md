# Architecture

| Directory | Responsibility |
| --- | --- |
| `Sources/HarnessApp` | GUI entry, single-instance election, explicit synthetic account diagnostic |
| `Sources/HarnessEmitter/Application` | Work ownership, startup, transactional settings, shared native callback gate |
| `Sources/HarnessEmitter/Account` | Account models/controller, JWT validation, Keychain storage, HTTP and loopback callbacks |
| `Sources/HarnessEmitter/Capture` | ScreenCaptureKit scope verification and in-memory masking/JPEG encoding |
| `Sources/HarnessEmitter/Input` | Carbon function keys and single active workflow |
| `Sources/HarnessEmitter/Presentation` | Nonactivating panel, fixed typography, pane/background sampling, mode configuration |
| `Sources/HarnessEmitter/Settings` | Simple onboarding/status window and optional Advanced controls |
| `Sources/HarnessCore` | Validated preferences, privacy gate, metadata audit and research coordination |
| `Sources/HarnessDetector` / `HarnessDetect` | Independent metadata scans, correlation, reports and CLI |
| `Sources/NativeKeychain` | Public legacy-Keychain interaction bridge |
| `Tests` | Feature-matched unit/native tests, process-lock fixtures, packaging and preference probes |
| `Resources`, `fixtures`, `scripts`, `docs` | Icon source/assets, controlled browser page, tooling and maintained documentation |

```text
startup → Mode 2 + saved preferences → quiet account load → audit → shortcuts
        → visible sign-in/status window → Screen Recording request only if missing
physical capture → verified scope → one screenshot → cancellable pane/background/JPEG worker
                 → account access/refresh → privacy/audit gate → Responses stream
                 → validated complete answer → plain-text overlay
scroll keys → bounded document; dismiss/disconnect → cancel + clear retained content
```

`ApplicationController` owns tasks and generation guards. Save validates first, cancels/awaits active work, commits preferences/hotkeys/mode, then admits capture. A rejected transaction restores previous authorized settings; disconnect supersedes it and keeps transmission disabled. Audit failure or uncertain rollback stops sensitive actions. Late results cannot restore dismissed content or disconnected accounts.

`ChatGPTAccountController` serializes sign-in/refresh and persists complete token sets. Quiet reads/writes never allow Keychain dialogs. Explicit storage recovery runs on a worker, with a finite deadline and cancellation gate. A process-wide recursive lock protects the legacy interaction policy; another thread's quiet access fails promptly rather than entering a dialog or freezing the UI. Private file locks serialize cross-process transactions/refresh and release on process death.

`NativeCallbackGate` resolves once, independently of an uncooperative framework callback. Capture uses five-second bounds; explicit account unlock uses 180 seconds. Cancellation returns without waiting for a protected OS dialog; late results are discarded.

Advanced account controls select saved registrations or start a separate registration for another account. Registrations retain distinct token sets even for identical emails. Account changes cancel active work and clear retained answer context before adoption; refresh/sign-in and account selection cannot race. Disconnect retains the registration mapping for later sign-in.

`ChatGPTProvider` validates model access and bounded SSE lifecycle/identity. `RemoteSubmissionService` buffers deltas, audits successful completion and only then returns text. No automatic image replay occurs. JPEG encoding and pane/background detection run off the main actor. Native display operations remain on it.

`Settings.systemPrompt` is an optional override; nil selects the bundled default and migrates old preferences without another setup step. Advanced edits a bounded plain-text draft. Save/reset participate in the existing settings transaction, and the provider factory receives that transaction's immutable settings snapshot. The provider sends effective instructions plus the screenshot trust boundary; audit records never receive instruction text. Invalid input is rejected before network access.

Pane detection accepts sustained faint lines and background transitions, groups neighboring edge columns at their strongest local gradient, and rejects narrow navigation spans before choosing content. Continuous evidence prevents unrelated stacked card borders from becoming a pane. Coordinates are derived from the original capture/display metadata, not from a phone photo or guessed display scale.

The detector observes metadata independently. Calibration inspects original marker pixels; accuracy metrics require independent truth and compatible session/capture/window/process identities. Missing evidence stays indeterminate/not tested.
