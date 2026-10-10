import AppKit
import XCTest
@testable import HarnessCore
@testable import HarnessEmitter

private actor LifecycleAudit: AuditLogging {
    func record(_ event:AuditEvent,mode:Int,experimentID:UUID?) async throws { try event.validate() }
}

@MainActor private final class LifecyclePreferences: Preferences {
    var values: [String: Any] = [:]
    var failures = 0
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func flush() throws { if failures > 0 { failures -= 1; throw SettingsPersistenceError.saveFailed } }
}
@MainActor private final class LifecycleAccount: ApplicationAccountManaging {
    var accountStatus = "Test account"
    var isConnected = false
    var onStatusChanged: (() -> Void)?
    var disconnected = false
    var signInCalls = 0
    var newAccountCalls = 0
    func signIn() async throws { signInCalls += 1; isConnected = true }
    func signIn(newAccount:Bool) async throws { if newAccount { newAccountCalls += 1 }; try await signIn() }
    func signOut() throws { disconnected = true }
    func cancelSignIn() {}
    func accessToken() async throws -> String { "synthetic-token" }
}
@MainActor private final class LifecycleRegistry: HotkeyRegistering {
    var configurations = 0
    var onInstall: (() -> Void)?
    var handler: ((UInt32, Bool) -> Void)?
    func install(handler: @escaping (UInt32, Bool) -> Void) throws { configurations += 1; self.handler = handler; onInstall?() }
    func register(keyCode: UInt32, id: UInt32) throws {}
    func unregisterAll() {}
}

@MainActor private final class PendingSyntheticCapture: CaptureEngineProtocol {
    var calls = 0, cancellations = 0
    func capture(settings: Settings) async throws -> CapturedFrame {
        calls += 1
        do { try await Task.sleep(nanoseconds: 600_000_000_000) }
        catch { cancellations += 1; throw error }
        throw CaptureError.captureFailed
    }
}

@MainActor private final class FailingSyntheticCapture: CaptureEngineProtocol {
    var calls = 0
    func capture(settings: Settings) async throws -> CapturedFrame {
        calls += 1; throw CaptureError.displayUnavailable
    }
}

@MainActor final class ApplicationLifecycleTests: XCTestCase {
    func testAddingAccountClearsPreviousAccountContext() async throws {
        let privacy = PrivacyController()
        let account = LifecycleAccount(); account.isConnected = true
        let value = try await controller(preferences:LifecyclePreferences(),account:account,privacy:privacy)
        defer { value.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification)); value.settingsUI.close() }
        let id = try await privacy.beginSubmission(image:Data([1]),settings:Settings(),credentialPresent:true,
            source:.excludingSelf,selectedWindowID:nil,masksApplied:false,promptChars:1,audit:LifecycleAudit())
        try await privacy.completeSubmission(id:id,response:"previous account answer")
        let before = await privacy.history; XCTAssertFalse(before.isEmpty)
        value.settingsUI.onAddAccount?()
        try await settle { account.newAccountCalls == 1 }
        let after = await privacy.history; XCTAssertTrue(after.isEmpty)
    }
    func testAddingAccountCancelsCaptureAndRemainsReadyWithoutSaving() async throws {
        let account = LifecycleAccount(); account.isConnected = true
        let registry = LifecycleRegistry(), engine = PendingSyntheticCapture()
        let value = try await controller(preferences:LifecyclePreferences(),account:account,registry:registry,captureEngine:engine)
        defer { value.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification)); value.settingsUI.close() }
        registry.handler?(1,true)
        try await settle { engine.calls == 1 }
        value.settingsUI.onAddAccount?()
        try await settle { account.newAccountCalls == 1 && engine.cancellations == 1 && value.ready }
        XCTAssertFalse(value.blocked)
        registry.handler?(1,false); registry.handler?(1,true)
        try await settle { engine.calls == 2 }
    }
    func testSignInEnablesAnalysisWithoutAConsentCheckboxOrSave() async throws {
        let prefs = LifecyclePreferences(); prefs.values["networkSubmissionEnabled"] = false
        let account = LifecycleAccount()
        let value = try await controller(preferences: prefs, account: account, modelsLoader: { _ in ["gpt-6.1-sol"] })
        defer { value.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); value.settingsUI.close() }
        value.settingsUI.onChatGPTSignIn?()
        try await settle { account.signInCalls == 1 && value.ready }
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(prefs.values["networkSubmissionEnabled"] as? Bool, true)
        XCTAssertFalse(value.blocked)
    }
    private func controller(preferences: LifecyclePreferences, account: LifecycleAccount? = nil,
                            registry: LifecycleRegistry? = nil, captureEngine: (any CaptureEngineProtocol)? = nil,
                            privacy: PrivacyController = PrivacyController(),
                            modelsLoader: (@MainActor (String) async throws -> [String])? = nil) async throws -> ApplicationController {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else {
            throw XCTSkip("Native lifecycle integration requires GUI opt-in")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessLifecycle-\(UUID().uuidString).noindex")
        let value = try ApplicationController(auditURL: directory.appendingPathComponent("audit.jsonl"), preferences: preferences,
            account: account ?? { let value = LifecycleAccount(); value.isConnected = true; return value }(), hotkeys: HotkeyManager(registry: registry ?? LifecycleRegistry()), privacy:privacy, captureEngine:captureEngine, modelsLoader: modelsLoader ?? { _ in ["gpt-6.1-sol"] }, windowsLoader: { [] }, screenPermissionGranted: { true }, requestScreenPermission: { XCTFail("No real permission requests in lifecycle fixtures"); return false })
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        value.wireSettings(); await value.launch()
        XCTAssertTrue(value.ready)
        return value
    }
    private func settle(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Operation did not settle within one second")
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func modelChoices(_ controller: ApplicationController) throws -> NSPopUpButton {
        let all = views(try XCTUnwrap(controller.settingsUI.window?.contentView))
        return try XCTUnwrap(all.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Refresh models after connecting ChatGPT") || $0.itemTitles.contains("Use the model ID entered above") })
    }
    func testFailedCaptureClearsPreviousPanelWithoutShowingErrorPopup() async throws {
        let registry = LifecycleRegistry(), engine = FailingSyntheticCapture()
        let value = try await controller(preferences:LifecyclePreferences(),registry:registry,captureEngine:engine)
        defer { value.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification)); value.settingsUI.close() }
        func visiblePanel() -> Bool { NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.nonactivatingPanel) } }
        value.settingsUI.onShowCalibration?()
        try await settle { visiblePanel() }
        registry.handler?(1,true)
        try await settle { engine.calls == 1 && !visiblePanel() }
        XCTAssertTrue(value.ready); XCTAssertFalse(value.blocked)
    }

    func testSavingDuringCaptureCancelsItAndAllowsNextCaptureWithoutRestart() async throws {
        let prefs = LifecyclePreferences(), registry = LifecycleRegistry(), engine = PendingSyntheticCapture()
        let value = try await controller(preferences:prefs, registry:registry, captureEngine:engine)
        defer { value.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification)); value.settingsUI.close() }
        registry.handler?(1, true)
        try await settle { engine.calls == 1 }
        var candidate = Settings(); candidate.model = "saved-after-cancel"
        value.settingsUI.onSave?(candidate, true)
        try await settle { prefs.values["model"] as? String == "saved-after-cancel" && value.ready }
        XCTAssertEqual(engine.cancellations, 1)
        XCTAssertFalse(value.blocked)
        XCTAssertTrue(value.ready)
        registry.handler?(1, false); registry.handler?(1, true)
        try await settle { engine.calls == 2 }
    }

    func testRepeatedCaptureDismissCyclesRecoverWithoutRestart() async throws {
        let registry = LifecycleRegistry(), engine = PendingSyntheticCapture()
        let value = try await controller(preferences:LifecyclePreferences(),registry:registry,captureEngine:engine)
        defer { value.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification)); value.settingsUI.close() }
        for count in 1...20 {
            try await settle {
                if engine.calls == count { return true }
                registry.handler?(1,false); registry.handler?(1,true)
                return false
            }
            // Held-key repeats cannot create overlapping capture work.
            for _ in 0..<20 { registry.handler?(1,true) }
            XCTAssertEqual(engine.calls,count)
            registry.handler?(2,true); registry.handler?(2,false)
            try await settle { engine.cancellations == count }
            XCTAssertTrue(value.ready); XCTAssertFalse(value.blocked)
        }
    }

    func testAlreadyConnectedAccountDoesNotStartAnotherSignIn() async throws {
        let prefs = LifecyclePreferences(), account = LifecycleAccount()
        account.accountStatus = "Connected to ChatGPT"; account.isConnected = true
        let value = try await controller(preferences: prefs, account: account)
        defer { value.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); value.settingsUI.close() }
        value.settingsUI.onChatGPTSignIn?()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(account.signInCalls, 0, "Connected users must not accidentally start browser authorization while capturing")
        XCTAssertTrue(value.ready)
    }

    func testRejectedConsentDoesNotStopAppAndNextSaveSucceeds() async throws {
        let prefs = LifecyclePreferences()
        let value = try await controller(preferences: prefs)
        defer { value.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); value.settingsUI.close() }
        var invalid = Settings(); invalid.networkSubmissionEnabled = true
        value.settingsUI.onSave?(invalid, false)
        try await settle { value.blocked || value.ready }
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(value.blocked, "Missing consent is a rejected draft, not a fatal app failure")
        var next = Settings(); next.model = "corrected-model"
        value.settingsUI.onSave?(next, true)
        try await settle { prefs.values["model"] as? String == "corrected-model" && value.ready }
        XCTAssertTrue(value.ready)
    }
    func testRecoverableStorageFailureRestoresHotkeysAndAllowsRetry() async throws {
        let prefs = LifecyclePreferences(), registry = LifecycleRegistry()
        let value = try await controller(preferences: prefs, registry: registry)
        defer { value.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); value.settingsUI.close() }
        prefs.failures = 1
        var candidate = Settings(); candidate.model = "retry-model"
        value.settingsUI.onSave?(candidate, true)
        try await settle { registry.configurations >= 3 && value.ready }
        XCTAssertFalse(value.blocked)
        XCTAssertTrue(value.ready)
        XCTAssertGreaterThanOrEqual(registry.configurations, 3, "Previous hotkeys must be restored after the candidate fails to persist")
        XCTAssertEqual(prefs.values["networkSubmissionEnabled"] as? Bool, true,
                       "A rejected draft must not disconnect an already authorized account")
        value.settingsUI.onSave?(candidate, true)
        try await settle { prefs.values["model"] as? String == "retry-model" && value.ready }
        XCTAssertTrue(value.ready)
    }
    func testRepeatedSaveCallbacksApplyOneTransaction() async throws {
        let prefs = LifecyclePreferences(), registry = LifecycleRegistry()
        let value = try await controller(preferences: prefs, registry: registry)
        defer { value.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); value.settingsUI.close() }
        var candidate = Settings(); candidate.model = "single-model"
        value.settingsUI.onSave?(candidate, true); value.settingsUI.onSave?(candidate, true)
        try await settle { prefs.values["model"] as? String == "single-model" && value.ready }
        XCTAssertEqual(registry.configurations, 2, "Two clicks must cause only one new hotkey configuration")
    }
    func testUncertainStorageRollbackStopsActions() async throws {
        let prefs = LifecyclePreferences()
        let value = try await controller(preferences: prefs)
        defer { value.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); value.settingsUI.close() }
        prefs.failures = 2
        var candidate = Settings(); candidate.model = "unsafe-model"
        value.settingsUI.onSave?(candidate, true)
        try await settle { value.blocked }
        XCTAssertFalse(value.ready)
        XCTAssertNotEqual(prefs.values["model"] as? String, "unsafe-model")
    }
    func testDisconnectDuringSaveRestoresUsableSafeSettings() async throws {
        let prefs = LifecyclePreferences(), account = LifecycleAccount(), registry = LifecycleRegistry()
        let value = try await controller(preferences: prefs, account: account, registry: registry)
        defer { value.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); value.settingsUI.close() }
        registry.onInstall = { registry.onInstall = nil; value.settingsUI.onChatGPTSignOut?() }
        var candidate = Settings(); candidate.model = "interrupted-model"; candidate.networkSubmissionEnabled = true
        value.settingsUI.onSave?(candidate, true)
        try await settle { account.disconnected && value.ready }
        XCTAssertFalse(value.blocked)
        XCTAssertEqual(prefs.values["networkSubmissionEnabled"] as? Bool, false)
        XCTAssertNotEqual(prefs.values["model"] as? String, "interrupted-model")
    }
    func testLateModelRefreshCannotRestoreCatalogAfterDisconnect() async throws {
        let prefs = LifecyclePreferences(), account = LifecycleAccount()
        var completion: CheckedContinuation<[String], Error>?
        let value = try await controller(preferences: prefs, account: account, modelsLoader: { _ in
            try await withCheckedThrowingContinuation { completion = $0 }
        })
        defer { value.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); value.settingsUI.close() }
        value.settingsUI.onRefreshModels?()
        try await settle { completion != nil }
        value.settingsUI.onChatGPTSignOut?()
        try await settle { account.disconnected }
        completion?.resume(returning: ["stale-account-model"]); completion = nil
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(try modelChoices(value).itemTitles.contains("stale-account-model"))
        XCTAssertFalse(try modelChoices(value).isEnabled)
        XCTAssertTrue(value.ready)
    }
}
