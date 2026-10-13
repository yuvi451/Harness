import XCTest
import Carbon
@testable import HarnessCore
@testable import HarnessEmitter
@MainActor final class HotkeyTests: XCTestCase {
    func testNativeCarbonRegistersAllOptionShiftNumberBindings() throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else {
            throw XCTSkip("Enable native GUI tests to register desktop hotkeys")
        }
        _ = NSApplication.shared
        let manager = HotkeyManager(registry:CarbonHotkeyRegistry())
        defer { manager.shutdown() }
        XCTAssertNoThrow(try manager.configure(settings:Settings()) { _ in })
    }
    func testNumberKeysRegisterSevenActionsAndSuppressRepeatsForBothToggles() throws {
        let registry = FakeHotkeyRegistry(),manager = HotkeyManager(registry:registry)
        var actions:[UInt32] = []
        try manager.configure(settings:Settings()) { actions.append($0.rawValue) }
        XCTAssertEqual(registry.keys,[kVK_ANSI_8,kVK_ANSI_9,kVK_ANSI_7,kVK_ANSI_6,kVK_ANSI_5,kVK_ANSI_0,kVK_ANSI_1].map(UInt32.init))
        registry.handler?(6,true);registry.handler?(6,true);registry.handler?(6,false);registry.handler?(6,true)
        registry.handler?(7,true);registry.handler?(7,true)
        XCTAssertEqual(actions,[6,6,7])
        XCTAssertEqual(registry.modifiers,Array(repeating:UInt32(optionKey | shiftKey),count:7))
    }
    func testOnlyRegisteredKeyPressDispatchesOnceUntilRelease() throws {
        let registry = FakeHotkeyRegistry(); let manager = HotkeyManager(registry: registry)
        var actions: [HotkeyAction] = []
        try manager.configure(settings: Settings()) { actions.append($0) }
        XCTAssertTrue(actions.isEmpty)
        registry.handler?(1, true); registry.handler?(1, true)
        XCTAssertEqual(actions, [.capture])
        registry.handler?(1, false); registry.handler?(1, true)
        registry.handler?(2, true); registry.handler?(3, true); registry.handler?(4, true); registry.handler?(99, true)
        XCTAssertEqual(actions, [.capture, .capture, .dismiss, .scrollUp, .scrollDown])
        XCTAssertEqual(registry.keys, [kVK_ANSI_8,kVK_ANSI_9,kVK_ANSI_7,kVK_ANSI_6,kVK_ANSI_5,kVK_ANSI_0,kVK_ANSI_1].map(UInt32.init))
        manager.shutdown(); registry.handler?(1, true)
        XCTAssertEqual(actions.count, 5)
    }
    func testRegistrationFailureAndDuplicates() throws {
        let registry = FakeHotkeyRegistry(); registry.failID = 2
        let manager = HotkeyManager(registry: registry)
        XCTAssertThrowsError(try manager.configure(settings: Settings()) { _ in })
        XCTAssertTrue(registry.keys.isEmpty)
        registry.failID = nil
        var invalid = Settings(); invalid.dismissHotkey = invalid.captureHotkey
        XCTAssertThrowsError(try manager.configure(settings: invalid) { _ in })
        XCTAssertTrue(registry.keys.isEmpty)
        XCTAssertNoThrow(try manager.configure(settings: Settings()) { _ in })
        XCTAssertEqual(registry.keys.count, 7)
    }
    func testSingleFlightGate() {
        let gate = SingleFlightCaptureGate()
        XCTAssertTrue(gate.acquire()); XCTAssertFalse(gate.acquire()); gate.release(); XCTAssertTrue(gate.acquire())
    }
    func testCallbacksFromPreviousRegistrationCannotDispatchAfterReconfiguration() throws {
        let registry = FakeHotkeyRegistry(); let manager = HotkeyManager(registry: registry)
        var oldActions: [HotkeyAction] = [], newActions: [HotkeyAction] = []
        try manager.configure(settings: Settings()) { oldActions.append($0) }
        let staleHandler = try XCTUnwrap(registry.handler)
        try manager.configure(settings: Settings()) { newActions.append($0) }
        staleHandler(1, true)
        XCTAssertTrue(oldActions.isEmpty)
        XCTAssertTrue(newActions.isEmpty, "An earlier registration must not initiate a capture under new settings")
        registry.handler?(1, true)
        XCTAssertEqual(newActions, [.capture], "A stale press must not poison the current held-key state")
    }
}
@MainActor private final class FakeHotkeyRegistry: HotkeyRegistering {
    var handler: ((UInt32, Bool)->Void)?
    var modifiers:[UInt32] = []
    var keys: [UInt32] = []; var failID: UInt32?
    func install(handler: @escaping (UInt32, Bool)->Void) throws { self.handler = handler }
    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) throws { if id == failID { throw HotkeyError.registration(-1) }; keys.append(keyCode);self.modifiers.append(modifiers) }
    func unregisterAll() { keys.removeAll();modifiers.removeAll(); handler = nil }
}
