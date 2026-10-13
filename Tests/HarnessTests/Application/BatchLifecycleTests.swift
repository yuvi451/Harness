import AppKit
import CoreGraphics
import XCTest
@testable import HarnessCore
@testable import HarnessEmitter

@MainActor final class BatchLifecycleTests: XCTestCase {
    func testHiddenAnswerCannotRestoreStaleDisplayGeometry() async throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else { throw XCTSkip("Native lifecycle opt-in") }
        let screen = try XCTUnwrap(NSScreen.main)
        let id = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).uint32Value
        var frames = [id:screen.frame]
        let fixture = try await makeFixture(displaySnapshot:{ frames });defer { fixture.close() }
        fixture.registry.press(1)
        try await waitForTest { NSApplication.shared.windows.contains { $0 is OverlayPanel && $0.isVisible } }
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? OverlayPanel }.first { $0.isVisible })
        fixture.registry.press(6)
        frames[id]?.origin.x += 1
        fixture.registry.press(6)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(fixture.engine.calls,1);XCTAssertEqual(fixture.provider.calls,1)
    }
    func testSavingOverlayPositionRepositionsHiddenAnswerWithoutAnotherRequest() async throws {
        let fixture = try await makeFixture();defer { fixture.close() }
        fixture.engine.drawPane = true
        fixture.registry.press(1)
        try await waitForTest { NSApplication.shared.windows.contains { $0 is OverlayPanel && $0.isVisible } }
        try await Task.sleep(nanoseconds:30_000_000)
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? OverlayPanel }.first { $0.isVisible })
        let scroll = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        let original = panel.frame,answer = text.string
        fixture.registry.press(6)
        var next = Settings();next.overlayPosition = .pinnedCorner
        fixture.app.settingsUI.onSave?(next,true)
        try await waitForTest { fixture.preferences.values["overlayPosition"] as? String == "pinnedCorner" && fixture.app.ready }
        XCTAssertFalse(panel.isVisible);XCTAssertEqual(text.string,answer)
        XCTAssertNotEqual(panel.frame,original)
        let font = try XCTUnwrap(text.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont)
        XCTAssertEqual(font.pointSize,9)
        XCTAssertEqual(fixture.engine.calls,1);XCTAssertEqual(fixture.provider.calls,1)
    }
    func testChangedDisplaySnapshotDuringCapturePreventsSubmission() async throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else { throw XCTSkip("Native lifecycle opt-in") }
        let screen = try XCTUnwrap(NSScreen.main)
        let id = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).uint32Value
        var frames = [id:screen.frame]
        let fixture = try await makeFixture(displaySnapshot:{ frames });defer { fixture.close() }
        fixture.engine.onCapture = { frames[id]?.origin.x += 1 }
        fixture.registry.press(1)
        try await waitForTest { fixture.engine.calls == 1 }
        try await waitForTest {
            let records = (try? Data(contentsOf:fixture.audit).split(separator:10).map { try AuditRecord.decode(Data($0)) }) ?? []
            return fixture.provider.calls > 0 || records.contains { $0.event == .captureFailed }
        }
        XCTAssertEqual(fixture.provider.calls,0,"Inconsistent display geometry must fail before any request")
        XCTAssertFalse(NSApplication.shared.windows.contains { $0 is OverlayPanel && $0.isVisible })
    }
    func testModeSelectedDuringPendingResponseIsUsedWithoutAnotherCapture() async throws {
        let fixture = try await makeFixture();defer { fixture.close() }
        fixture.provider.deferCompletion = true
        fixture.registry.press(1)
        try await waitForTest { fixture.provider.calls == 1 }
        fixture.registry.press(7)
        try await waitForTest { fixture.preferences.values["overlayPosition"] as? String == "pinnedCorner" && fixture.app.ready }
        XCTAssertFalse(NSApplication.shared.windows.contains { $0 is OverlayPanel && $0.isVisible })
        fixture.provider.complete()
        try await waitForTest { NSApplication.shared.windows.contains { $0 is OverlayPanel && $0.isVisible } }
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? OverlayPanel }.first { $0.isVisible })
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.frame.contains(CGPoint(x:panel.frame.midX,y:panel.frame.midY)) })
        XCTAssertEqual(panel.frame.minX,screen.visibleFrame.minX+16,accuracy:1)
        XCTAssertEqual(panel.frame.minY,screen.visibleFrame.minY+16,accuracy:1)
        XCTAssertEqual(fixture.engine.calls,1);XCTAssertEqual(fixture.provider.calls,1)
    }
    func testClearDuringPendingResponsePreventsLateAnswerAndAllowsNextRequest() async throws {
        let fixture = try await makeFixture();defer { fixture.close() }
        fixture.provider.deferCompletion = true
        fixture.registry.press(1)
        try await waitForTest { fixture.provider.calls == 1 }
        fixture.registry.press(2)
        fixture.provider.complete()
        try await Task.sleep(nanoseconds:60_000_000)
        XCTAssertFalse(NSApplication.shared.windows.contains { $0 is OverlayPanel && $0.isVisible })
        fixture.registry.press(6)
        XCTAssertFalse(NSApplication.shared.windows.contains { $0 is OverlayPanel && $0.isVisible })
        fixture.provider.deferCompletion = false
        fixture.registry.press(1)
        try await waitForTest { NSApplication.shared.windows.contains { $0 is OverlayPanel && $0.isVisible } }
        XCTAssertEqual(fixture.engine.calls,2);XCTAssertEqual(fixture.provider.calls,2)
    }
    func testVisibilityShortcutPreservesAnswerAndScrollWithoutCaptureOrRequest() async throws {
        let fixture = try await makeFixture();defer { fixture.close() }
        fixture.registry.press(1)
        try await waitForTest { NSApplication.shared.windows.contains { $0 is OverlayPanel && $0.isVisible } }
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? OverlayPanel }.first { $0.isVisible })
        let scroll = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        fixture.registry.press(4)
        let origin = scroll.contentView.bounds.origin,answer = text.string,frame = panel.frame
        XCTAssertGreaterThan(origin.y,0)
        fixture.registry.press(6)
        XCTAssertFalse(panel.isVisible)
        fixture.registry.press(3)
        XCTAssertEqual(scroll.contentView.bounds.origin,origin,"A hidden answer must retain its reading position")
        fixture.registry.press(6)
        XCTAssertTrue(panel.isVisible);XCTAssertEqual(panel.frame,frame)
        XCTAssertEqual(text.string,answer);XCTAssertEqual(scroll.contentView.bounds.origin,origin)
        XCTAssertEqual(fixture.engine.calls,1);XCTAssertEqual(fixture.provider.calls,1)
        fixture.registry.press(2);fixture.registry.press(6)
        XCTAssertFalse(panel.isVisible);XCTAssertEqual(text.string,"")
        XCTAssertEqual(fixture.engine.calls,1);XCTAssertEqual(fixture.provider.calls,1)
    }
    func testAnotherRequestRequiresClearEvenWhenSavedAnswerIsHidden() async throws {
        let fixture = try await makeFixture();defer { fixture.close() }
        fixture.registry.press(1)
        try await waitForTest { NSApplication.shared.windows.contains { $0 is OverlayPanel && $0.isVisible } }
        try await Task.sleep(nanoseconds:50_000_000)
        fixture.registry.press(6);fixture.registry.press(1);fixture.registry.press(5)
        try await Task.sleep(nanoseconds:80_000_000)
        XCTAssertEqual(fixture.engine.calls,1,"An existing answer blocks capture and screenshot queuing until clear")
        XCTAssertEqual(fixture.provider.calls,1)
        fixture.registry.press(2)
        try await Task.sleep(nanoseconds:50_000_000)
        fixture.registry.press(1)
        try await waitForTest { fixture.provider.calls >= 2 }
        XCTAssertEqual(fixture.engine.calls,2);XCTAssertEqual(fixture.provider.calls,2)
    }
    func testModeShortcutPreservesHiddenAnswerAndQueuedScreenshotsWithoutSending() async throws {
        let fixture = try await makeFixture();defer { fixture.close() }
        fixture.registry.press(5)
        try await waitForTest { fixture.app.queuedScreenshotCount == 1 }
        await Task.yield();fixture.registry.press(7)
        try await waitForTest { fixture.preferences.values["overlayPosition"] as? String == "pinnedCorner" && fixture.app.ready }
        XCTAssertEqual(fixture.app.queuedScreenshotCount,1);XCTAssertEqual(fixture.provider.calls,0)
        let records = try Data(contentsOf:fixture.audit).split(separator:10).map { try AuditRecord.decode(Data($0)) }
        let applied = try XCTUnwrap(records.last { $0.event == .settingsChanged })
        XCTAssertEqual(applied.payload["source"],.string(CaptureSource.excludingSelf.rawValue))
        XCTAssertNotNil(applied.payload["configuration_changed_ns"]?.int)
        let configuration = try MatrixSessionCoordinator().currentConfiguration(records:records)
        XCTAssertEqual(configuration.source,.excludingSelf)
        fixture.registry.press(1)
        try await waitForTest { NSApplication.shared.windows.contains { $0 is OverlayPanel && $0.isVisible } }
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? OverlayPanel }.first { $0.isVisible })
        fixture.registry.press(6);fixture.registry.press(7)
        try await waitForTest { fixture.preferences.values["overlayPosition"] as? String == "nearCursor" && fixture.app.ready }
        XCTAssertFalse(panel.isVisible)
        fixture.registry.press(6);XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(fixture.engine.calls,1);XCTAssertEqual(fixture.provider.calls,1)
    }
    func testAccountFailureReferencesQueuedCaptureAndCannotSendImages() async throws {
        let fixture = try await makeFixture();defer { fixture.close() }
        fixture.registry.press(5);try await waitForTest { fixture.app.queuedScreenshotCount == 1 }
        await Task.yield();fixture.account.failCredentials = true;fixture.registry.press(1)
        try await waitForTest { fixture.app.queuedScreenshotCount == 0 }
        try await Task.sleep(nanoseconds:30_000_000)
        let records = try Data(contentsOf:fixture.audit).split(separator:10).map { try AuditRecord.decode(Data($0)) }
        XCTAssertEqual(records.first { $0.event == .llmFailed }?.payload["capture_id"],
                       records.first { $0.event == .captureCompleted }?.payload["capture_id"])
        XCTAssertEqual(fixture.provider.calls,0)
    }
    func testQueueCapturesOnlyAndRequestSendsTogetherWithoutAnotherScreenshot() async throws {
        let fixture = try await makeFixture(); defer { fixture.close() }
        XCTAssertEqual(fixture.engine.calls,0)
        for n in 1...3 {
            fixture.registry.press(5)
            try await waitForTest { fixture.app.queuedScreenshotCount == n }
            await Task.yield()
        }
        XCTAssertEqual(fixture.provider.calls,0,"Queuing must never transmit")
        fixture.registry.press(1)
        try await waitForTest { fixture.provider.calls == 1 }
        XCTAssertEqual(fixture.engine.calls,3)
        XCTAssertEqual(fixture.provider.images.count,3)
        XCTAssertEqual(fixture.app.queuedScreenshotCount,0)
        XCTAssertEqual(Set(fixture.provider.images).count,3,"Capture order must contain the separate screenshots")
        try await Task.sleep(nanoseconds:30_000_000)
        let records = try Data(contentsOf:fixture.audit).split(separator:10).map { try AuditRecord.decode(Data($0)) }
        XCTAssertEqual(records.filter { $0.event == .captureCompleted }.count,3)
        XCTAssertEqual(records.filter { $0.event == .llmRequest }.count,1)
        XCTAssertEqual(records.first { $0.event == .llmRequest }?.payload["image_count"],.integer(3))
    }
    func testDismissSettingsAccountSwitchAndTerminationDiscardQueue() async throws {
        for trigger in 0..<4 {
            let fixture = try await makeFixture(); defer { fixture.close() }
            fixture.registry.press(5)
            try await waitForTest { fixture.app.queuedScreenshotCount == 1 }
            await Task.yield()
            switch trigger {
            case 0: fixture.registry.press(2)
            case 1: fixture.app.settingsUI.onSave?(Settings(),true)
            case 2: fixture.app.settingsUI.onAddAccount?()
            default: fixture.app.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
            }
            try await waitForTest { fixture.app.queuedScreenshotCount == 0 }
            XCTAssertEqual(fixture.provider.calls,0)
        }
    }
    func testEmptyQueueRequestCapturesAndCapacityCannotStartSeventhCapture() async throws {
        let fixture = try await makeFixture(); defer { fixture.close() }
        fixture.registry.press(1)
        try await waitForTest { fixture.provider.calls == 1 }
        try await Task.sleep(nanoseconds:30_000_000)
        XCTAssertEqual(fixture.engine.calls,1); XCTAssertEqual(fixture.provider.images.count,1)
        fixture.registry.press(2);try await Task.sleep(nanoseconds:30_000_000)
        for n in 1...6 {
            fixture.registry.press(5)
            try await waitForTest { fixture.app.queuedScreenshotCount == n }
            await Task.yield()
        }
        fixture.registry.press(5)
        try await Task.sleep(nanoseconds:30_000_000)
        XCTAssertEqual(fixture.engine.calls,7); XCTAssertEqual(fixture.app.queuedScreenshotCount,6)
    }
    func testCaptureFailureDropsPreviouslyQueuedImages() async throws {
        let fixture = try await makeFixture(); defer { fixture.close() }
        fixture.registry.press(5); try await waitForTest { fixture.app.queuedScreenshotCount == 1 }
        await Task.yield(); fixture.engine.fail = true; fixture.registry.press(5)
        try await waitForTest { fixture.engine.calls == 2 && fixture.app.queuedScreenshotCount == 0 }
        XCTAssertEqual(fixture.provider.calls,0); XCTAssertFalse(fixture.app.blocked)
    }
    private func makeFixture(position:OverlayPosition = .nearCursor,displaySnapshot:(@MainActor () -> [UInt32:CGRect])? = nil) async throws -> BatchFixture {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else { throw XCTSkip("Native lifecycle opt-in") }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessBatch-\(UUID().uuidString).noindex")
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        let audit = directory.appendingPathComponent("audit.jsonl")
        let registry = BatchLifecycleRegistry(),engine = BatchCaptureEngine(),provider = LifecycleBatchProvider(),account = BatchAccount()
        let preferences = BatchPreferences();preferences.values["overlayPosition"] = position.rawValue
        let app = try ApplicationController(auditURL:audit,preferences:preferences,account:account,
            hotkeys:HotkeyManager(registry:registry),captureEngine:engine,providerFactory:{ _,_ in provider },
            modelsLoader:{ _ in [] },windowsLoader:{ [] },screenPermissionGranted:{ true },requestScreenPermission:{ false },displaySnapshot:displaySnapshot)
        app.wireSettings(); await app.launch()
        XCTAssertTrue(app.ready)
        return BatchFixture(app:app,registry:registry,engine:engine,provider:provider,account:account,audit:audit,preferences:preferences)
    }
}
@MainActor private struct BatchFixture {
    let app:ApplicationController,registry:BatchLifecycleRegistry,engine:BatchCaptureEngine,provider:LifecycleBatchProvider,account:BatchAccount,audit:URL,preferences:BatchPreferences
    func close() { app.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification));app.settingsUI.close() }
}
@MainActor private final class BatchPreferences: Preferences {
    var values:[String:Any] = [:]
    func object(forKey key:String) -> Any? { values[key] }
    func set(_ value:Any,forKey key:String) { values[key] = value }
    func removeObject(forKey key:String) { values.removeValue(forKey:key) }
}
@MainActor private final class BatchLifecycleRegistry: HotkeyRegistering {
    var handler:((UInt32,Bool)->Void)?
    func install(handler:@escaping (UInt32,Bool)->Void) throws { self.handler = handler }
    func register(keyCode:UInt32,modifiers: UInt32, id:UInt32) throws {}
    func unregisterAll() { handler = nil }
    func press(_ id:UInt32) { handler?(id,false);handler?(id,true);handler?(id,false) }
}
@MainActor private final class BatchCaptureEngine: CaptureEngineProtocol {
    var calls = 0,fail = false
    var drawPane = false
    var onCapture:(() -> Void)?
    func capture(settings:Settings) async throws -> CapturedFrame {
        calls += 1
        onCapture?()
        if fail { throw CaptureError.captureFailed }
        let screen = try XCTUnwrap(NSScreen.main)
        let id = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).uint32Value
        let context = try XCTUnwrap(CGContext(data:nil,width:600,height:400,bitsPerComponent:8,bytesPerRow:2400,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:CGFloat(calls)/10,alpha:1));context.fill(CGRect(x:0,y:0,width:600,height:400))
        if drawPane {
            context.setFillColor(CGColor(gray:0,alpha:1))
            context.fill(CGRect(x:100,y:0,width:2,height:400));context.fill(CGRect(x:450,y:0,width:2,height:400))
        }
        return CapturedFrame(image:try XCTUnwrap(context.makeImage()),displayID:id,displayFrame:CGDisplayBounds(id),displayScale:1,
            rotation:0,source:settings.captureSource,selectedWindowID:settings.selectedWindowID,capturedBounds:CGDisplayBounds(id))
    }
}
private final class LifecycleBatchProvider: LLMProvider, @unchecked Sendable {
    var calls = 0,images:[Data] = []
    var deferCompletion = false
    private var pending:AsyncThrowingStream<String,Error>.Continuation?
    var completionSummary:LLMCompletion? { .init(stopReason:"completed",latencyMS:1) }
    func stream(prompt:String,image:Data,history:[LLMExchange]) -> AsyncThrowingStream<String,Error> { stream(prompt:prompt,images:[image],history:history) }
    func stream(prompt:String,images:[Data],history:[LLMExchange]) -> AsyncThrowingStream<String,Error> {
        calls += 1;self.images = images
        return AsyncThrowingStream { continuation in
            if deferCompletion { pending = continuation }
            else { continuation.yield("Answer\nSecond line\nThird line\nFourth line");continuation.finish() }
        }
    }
    func complete() { pending?.yield("Answer\nSecond line\nThird line\nFourth line");pending?.finish();pending = nil }
}
@MainActor private final class BatchAccount: ApplicationAccountManaging {
    var failCredentials = false
    var onStatusChanged:(() -> Void)?
    var accountStatus:String { "Synthetic" }
    var isConnected:Bool { true }
    var accountChoices:[ChatGPTAccountChoice] { [] }
    var selectedAccountID:String? { nil }
    func accessToken() async throws -> String { if failCredentials { throw ChatGPTAuthenticationError.notSignedIn };return "synthetic" }
    func signIn() async throws {}
    func signIn(newAccount:Bool) async throws {}
    func signOut() throws {}
    func selectAccount(_ id:String) throws {}
    func cancelSignIn() {}
}
