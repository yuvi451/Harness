import XCTest
import Carbon
@testable import HarnessCore
@testable import HarnessEmitter
@MainActor final class HotkeyTests: XCTestCase {
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
        XCTAssertEqual(registry.keys, [kVK_F8, kVK_F9, kVK_F10, kVK_F11].map(UInt32.init))
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
        XCTAssertEqual(registry.keys.count, 4)
    }
    func testSingleFlightGate() {
        let gate = SingleFlightCaptureGate()
        XCTAssertTrue(gate.acquire()); XCTAssertFalse(gate.acquire()); gate.release(); XCTAssertTrue(gate.acquire())
    }
}
@MainActor private final class FakeHotkeyRegistry: HotkeyRegistering {
    var handler: ((UInt32, Bool)->Void)?
    var keys: [UInt32] = []; var failID: UInt32?
    func install(handler: @escaping (UInt32, Bool)->Void) throws { self.handler = handler }
    func register(keyCode: UInt32, id: UInt32) throws { if id == failID { throw HotkeyError.registration(-1) }; keys.append(keyCode) }
    func unregisterAll() { keys.removeAll(); handler = nil }
}
