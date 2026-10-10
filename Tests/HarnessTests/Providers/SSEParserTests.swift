import XCTest
@testable import HarnessEmitter

final class SSEParserTests: XCTestCase {
    func testConfiguredTotalLimitStopsBeforeUnboundedTraffic() throws {
        var parser = SSEParser(eventLimit: 100, totalLimit: 12)
        XCTAssertTrue(try parser.feed(Data(":1234567890\n".utf8)).isEmpty)
        XCTAssertThrowsError(try parser.feed(UInt8(10)))
    }

    func testByteAndChunkFeedsPreserveSplitUnicodeBOMAndMixedNewlines() throws {
        let input = Data("\u{feff}event: example\r\ndata: 界🙂\rdata: second\n\n".utf8)
        var byteParser = SSEParser(), chunkParser = SSEParser()
        let byteEvents = try input.compactMap { try byteParser.feed($0) }
        let chunkEvents = try chunkParser.feed(input)
        XCTAssertEqual(byteEvents.count, 1)
        XCTAssertEqual(byteEvents.first?.event, chunkEvents.first?.event)
        XCTAssertEqual(String(data: byteEvents[0].data, encoding: .utf8), "界🙂\nsecond")
        XCTAssertEqual(byteEvents[0].data, chunkEvents[0].data)
    }
    func testCommentTrafficAndMultilineEventsStayBounded() throws {
        var total = SSEParser()
        let comment = Data((":" + String(repeating: "x", count: 999) + "\n").utf8)
        for _ in 0..<1998 { _ = try total.feed(comment) }
        XCTAssertThrowsError(try total.feed(comment))
        var event = SSEParser(eventLimit: 20)
        XCTAssertThrowsError(try event.feed(Data("data: 12345\ndata: 67890\n\n".utf8)))
    }

    func testSSEFramingRejectsMalformedUTF8AndPreservesMultilineData() throws {
        var parser = SSEParser()
        let frames = try parser.feed(Data("event: future\r\ndata: first\r\ndata: second\r\n\r\n".utf8))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].event, "future")
        XCTAssertEqual(String(data: frames[0].data, encoding: .utf8), "first\nsecond")
        XCTAssertThrowsError(try parser.feed(Data([0xff, 0x0a])))
    }
}
