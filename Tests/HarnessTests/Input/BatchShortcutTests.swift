import XCTest
import Carbon
@testable import HarnessCore
@testable import HarnessEmitter

@MainActor final class BatchShortcutTests: XCTestCase {
    func testQueueShortcutUsesNumberFiveAndRepeatGuard() throws {
        let registry = BatchRegistry(); let keys = HotkeyManager(registry:registry)
        var actions:[UInt32] = []
        try keys.configure(settings:Settings()) { actions.append($0.rawValue) }
        XCTAssertEqual(registry.keys,[kVK_ANSI_8,kVK_ANSI_9,kVK_ANSI_7,kVK_ANSI_6,kVK_ANSI_5,kVK_ANSI_0,kVK_ANSI_1].map(UInt32.init))
        registry.handler?(5,true); registry.handler?(5,true)
        XCTAssertEqual(actions,[5])
        registry.handler?(5,false); registry.handler?(5,true)
        XCTAssertEqual(actions,[5,5])
    }
}
@MainActor private final class BatchRegistry: HotkeyRegistering {
    var keys:[UInt32] = []; var handler:((UInt32,Bool)->Void)?
    func install(handler:@escaping (UInt32,Bool)->Void) throws { self.handler = handler }
    func register(keyCode:UInt32,modifiers: UInt32, id:UInt32) throws { keys.append(keyCode) }
    func unregisterAll() { keys.removeAll(); handler = nil }
}
