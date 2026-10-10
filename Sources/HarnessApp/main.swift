import AppKit
import HarnessEmitter
MainActor.assumeIsolated {
    let application = NSApplication.shared
    if Array(CommandLine.arguments.dropFirst()) == ["--check-chatgpt"] {
        // Explicit generated-image check, without screen access or hotkey registration.
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in exit(await SyntheticAccountDiagnostic.run()) }
        application.run()
        exit(1)
    }
    // Elect the oldest instance before creating windows, account stores or hotkeys.
    // A second bundle copy reopens the existing app instead of competing for them.
    let current = NSRunningApplication.current
    let instances = NSRunningApplication.runningApplications(withBundleIdentifier: "org.harness.research")
        .filter { !$0.isTerminated }
        .sorted {
            let left = $0.launchDate ?? .distantFuture, right = $1.launchDate ?? .distantFuture
            return left == right ? $0.processIdentifier < $1.processIdentifier : left < right
        }
    if let existing = instances.first, existing.processIdentifier != current.processIdentifier,
       let url = existing.bundleURL {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in exit(0) }
        existing.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline:.now() + 5) { exit(0) }
        application.run()
        exit(0)
    }
    application.setActivationPolicy(.regular)
    do {
        let controller = try ApplicationController()
        application.delegate = controller
        withExtendedLifetime(controller) { application.run() }
    } catch {
        fputs("Harness cannot start because mandatory audit storage is unavailable. No capture or network operation started.\n",stderr)
        let alert = NSAlert()
        alert.messageText = "Harness could not start"
        alert.informativeText = "Check that your Application Support folder is writable and the installed app is intact. No screenshot or network request was started."
        alert.addButton(withTitle:"Quit")
        application.activate(ignoringOtherApps:true); alert.runModal()
        exit(1)
    }
}
