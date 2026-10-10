# Harness

A native macOS screenshot assistant using your ChatGPT account. No API key or browser extension is needed. Requires macOS 14 or later; the current local package is for Apple Silicon.

<img src="Resources/AppIcon/preview.png" width="96" height="96" alt="Harness icon">

## Start

Unzip `dist/Harness.zip`, move `Harness.app` into `~/Applications`, and open it. Keep one installed copy. End users do not need Xcode, Python or the source repository.

1. Grant Screen Recording when macOS requests it. Complete any restart instruction.
2. Click **Continue with ChatGPT** and finish browser sign-in. Harness returns to its window with the result.
3. Press the capture shortcut over the content you want analyzed. No additional configuration is required.

Launching Harness indicates agreement to send keyboard-triggered screenshots and recent answer context to OpenAI through the connected ChatGPT plan. Nothing is captured at startup. Sign-in remains in macOS Keychain. Ordinary launches/captures do not request Keychain authorization; an unavailable saved account can be recovered with Continue with ChatGPT.

| Default shortcut | Action |
| --- | --- |
| F8 | Capture and analyze once |
| F9 | Dismiss/cancel |
| F10 | Scroll answer up |
| F11 | Scroll answer down |

Apple keyboards may require Fn/Globe. Existing custom shortcuts survive upgrades. **Mode 2 starts every launch.** Advanced controls include saved accounts, shortcuts, capture scope, model, image limits, masks and research tools. To customize instructions, edit **Advanced → System prompt → Save Settings**. **Restore default prompt**, followed by Save, follows the bundled default again. Instructions persist across restarts; they do not change popup typography or enable streaming.

The popup shows only the completed plain-text answer, with fixed 14-point Satoshi Regular, `ss03`, and black/white text. Its background matches a local sample of the captured pane. It follows detected pane boundaries, stays until dismissed/replaced, ignores mouse input and refuses focus. Background and pane detection happen once per capture. There is no streamed text or loading/error popup; failures appear in Harness.

No mode guarantees exclusion from third-party screen recording. Browser layouts and full-screen behavior depend on the OS/browser. Uncertain pane detection uses a display-bounded fallback.

## Code and release

Source, tests and scripts are organized by feature. Build products use a temporary scratch directory. Only the latest distribution lives in ignored `dist/`. Share `Harness-source.zip` for development; it excludes Git history, runtime accounts, generated output and the restricted font binary. Source recipients must obtain Satoshi Regular as described in the development guide, initialize Git and commit before packaging.

```sh
make test-native signing-tests preferences
make package
# Quit Harness before an update:
make install
```

Developers need full Xcode and Swift 6.2+. Public distribution requires Developer ID signing and notarization; the locally signed ZIP is a development build. See [development and release](docs/DEVELOPMENT.md).

- [Architecture](docs/ARCHITECTURE.md): modules and ownership.
- [Specification](docs/SPEC.md): behavior and resource limits.
- [Security](docs/SECURITY.md): credentials, data and permissions.
- [Verification](docs/VERIFICATION.md): actual audit/test evidence and remaining release gates.
- [Build blueprint](docs/BUILD_BLUEPRINT.md): detailed implementation order, AI prompts, bug regressions and native Windows/Linux port contracts.
