import XCTest
@testable import HarnessEmitter

final class NativeCaptureCallbackTests: XCTestCase {
    func testImmediateAndRepeatedCallbacksResolveOnlyFirstValue() async throws {
        let result: Int = try await NativeCallbackGate.query { callback in
            callback(.success(1)); callback(.success(2)); callback(.failure(CaptureError.captureFailed))
        }
        XCTAssertEqual(result, 1)
    }
    func testAlreadyCancelledTaskDoesNotStartNativeOperation() async throws {
        let pending = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let _: Int = try await NativeCallbackGate.query { _ in XCTFail("Native operation started after cancellation") }
        }
        do { try await pending.value; XCTFail("Cancelled operation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testStalledNativeCallbackTimesOutBeforeLateCompletion() async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let _: Int = try await NativeCallbackGate.query(timeoutSeconds: 0.02) { callback in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { callback(.success(42)) }
            }
            XCTFail("A stalled native capture/enumeration callback must time out")
        } catch { XCTAssertEqual(error as? CaptureError, .captureFailed) }
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start)/1_000_000_000, 0.1)
        try await Task.sleep(nanoseconds: 170_000_000)
    }
    func testCancellationDoesNotWaitForNativeCallback() async throws {
        let started = expectation(description: "Synthetic native call started")
        let pending = Task {
            let _: Int = try await NativeCallbackGate.query { callback in
                started.fulfill()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { callback(.success(42)) }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let start = DispatchTime.now().uptimeNanoseconds
        pending.cancel()
        do { try await pending.value; XCTFail("Cancelled native call returned a value") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start)/1_000_000_000, 0.1)
        try await Task.sleep(nanoseconds: 170_000_000)
    }
}
