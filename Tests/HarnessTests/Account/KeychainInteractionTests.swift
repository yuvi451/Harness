import XCTest
import NativeKeychain
@testable import HarnessEmitter

@MainActor final class KeychainInteractionTests: XCTestCase {
    func testQuietAccessFailsImmediatelyWhileAnotherThreadAuthorizes() async throws {
        let entered = expectation(description:"Authorization policy held")
        let completed = expectation(description:"Authorization policy restored")
        let release = DispatchSemaphore(value:0)
        DispatchQueue.global().async {
            defer { completed.fulfill() }
            do { try KeychainInteraction.withAllowed(true) { entered.fulfill(); _ = release.wait(timeout:.now() + 2) } }
            catch { XCTFail("Authorization scope failed") }
        }
        defer { release.signal() }
        await fulfillment(of:[entered],timeout:1)
        let started = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try KeychainInteraction.withAllowed(false) { XCTFail("Quiet operation entered while UI allowed") })
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - started,100_000_000)
        release.signal()
        await fulfillment(of:[completed],timeout:1)
    }
    private enum Failure: Error { case expected }
    private func current() throws -> Bool {
        var allowed = false
        XCTAssertEqual(HarnessKeychainInteractionGet(&allowed),0)
        return allowed
    }
    func testQuietScopeAndExplicitNestedAuthorizationRestorePreviousPolicy() throws {
        let original = try current()
        defer { _ = HarnessKeychainInteractionSet(original) }
        XCTAssertEqual(HarnessKeychainInteractionSet(true),0)
        try KeychainInteraction.withAllowed(false) {
            XCTAssertFalse(try current())
            try KeychainInteraction.withAllowed(true) { XCTAssertTrue(try current()) }
            XCTAssertFalse(try current())
        }
        XCTAssertTrue(try current())
    }
    func testThrowingOperationRestoresDisabledPolicy() throws {
        let original = try current()
        defer { _ = HarnessKeychainInteractionSet(original) }
        XCTAssertEqual(HarnessKeychainInteractionSet(false),0)
        XCTAssertThrowsError(try KeychainInteraction.withAllowed(true) {
            XCTAssertTrue(try current()); throw Failure.expected
        })
        XCTAssertFalse(try current())
    }
}
