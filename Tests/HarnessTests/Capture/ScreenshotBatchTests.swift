import XCTest
@testable import HarnessCore
@testable import HarnessEmitter

@MainActor final class ScreenshotBatchTests: XCTestCase {
    private func item(_ n:UInt8) -> QueuedScreenshot {
        QueuedScreenshot(id:UUID(),image:ProcessedImage(bytes:Data([n]),width:1,height:1,sha256:String(repeating:"a",count:64),masksApplied:false))
    }
    func testQueuePreservesOrderConsumesOnceAndBoundsMemory() throws {
        let queue = ScreenshotBatch(); let settings = Settings()
        for n in UInt8(1)...6 { try queue.append(item(n),settings:settings) }
        XCTAssertEqual(queue.count,6); XCTAssertEqual(queue.retainedByteCount,6)
        XCTAssertThrowsError(try queue.append(item(7),settings:settings))
        let sent = try queue.take(settings:settings)
        XCTAssertEqual(sent.map { $0.image.bytes },(UInt8(1)...6).map { Data([$0]) })
        XCTAssertEqual(queue.retainedByteCount,0)
        XCTAssertTrue(try queue.take(settings:settings).isEmpty)
    }
    func testDuplicateCaptureIdentityCannotBeQueuedTwice() throws {
        let queue = ScreenshotBatch(),settings = Settings(),entry = item(1)
        try queue.append(entry,settings:settings)
        XCTAssertThrowsError(try queue.append(entry,settings:settings))
        XCTAssertEqual(queue.count,1)
    }
    func testRepeatedBatchesReleaseMemoryAndSixMegabyteLimitIsEnforced() throws {
        let queue = ScreenshotBatch(),settings = Settings()
        for _ in 0..<1000 {
            for n in UInt8(1)...6 { try queue.append(item(n),settings:settings) }
            XCTAssertEqual(try queue.take(settings:settings).count,6)
            XCTAssertEqual(queue.retainedByteCount,0)
        }
        let image = ProcessedImage(bytes:Data(repeating:1,count:1_000_000),width:1,height:1,sha256:"",masksApplied:false)
        for _ in 0..<6 { try queue.append(.init(id:UUID(),image:image),settings:settings) }
        XCTAssertEqual(queue.retainedByteCount,6_000_000)
        XCTAssertThrowsError(try queue.append(.init(id:UUID(),image:image),settings:settings))
        queue.clear();XCTAssertEqual(queue.retainedByteCount,0)
    }
    func testExpiryAndConfigurationChangeDiscardEveryImage() throws {
        var now:UInt64 = 1
        let queue = ScreenshotBatch(clock:{ now })
        try queue.append(item(1),settings:Settings())
        now += 300_000_000_000
        XCTAssertTrue(queue.expireIfNeeded()); XCTAssertEqual(queue.count,0)
        try queue.append(item(2),settings:Settings())
        var changed = Settings(); changed.maskingRegions = [.init(x:0,y:0,width:1,height:1)]; changed.privacyMaskingEnabled = true
        XCTAssertThrowsError(try queue.take(settings:changed))
        XCTAssertEqual(queue.count,0); XCTAssertEqual(queue.retainedByteCount,0)
    }
    func testUnmaskedOrOversizedCapturesCannotEnterQueue() throws {
        let queue = ScreenshotBatch()
        var settings = Settings(); settings.privacyMaskingEnabled = true; settings.maskingRegions = [.init(x:0,y:0,width:1,height:1)]
        XCTAssertThrowsError(try queue.append(item(1),settings:settings))
        settings.privacyMaskingEnabled = false
        let big = QueuedScreenshot(id:UUID(),image:ProcessedImage(bytes:Data(repeating:1,count:1_000_001),width:1,height:1,sha256:"",masksApplied:false))
        XCTAssertThrowsError(try queue.append(big,settings:settings))
        XCTAssertEqual(queue.count,0)
        try queue.append(item(3),settings:settings); queue.clear()
        XCTAssertEqual(queue.count,0)
    }
}
