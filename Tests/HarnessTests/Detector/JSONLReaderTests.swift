import Foundation
import XCTest
import LockTestSupport
@testable import HarnessDetector
final class JSONLReaderTests: XCTestCase {
    func testHeldWriterLockTimesOutWithoutReadingUncommittedRecords() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audit.jsonl")
        var data = try JSONEncoder().encode(DetectorFixture.audit()[0]); data.append(10); try data.write(to: url)
        let child = url.path.withCString { harness_fork_hold_lock($0, 1_000_000) }
        XCTAssertGreaterThan(child, 0)
        guard child > 0 else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let result = JSONLReader.readAudit(url: url, lockTimeoutSeconds: 0.1)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.issues.first?.code.rawValue, "lock_timed_out")
        XCTAssertLessThan(elapsed, 0.5, "The reader must not wait for another process indefinitely")
        XCTAssertEqual(harness_wait_for_lock_child(child), 0)
        let released = JSONLReader.readAudit(url: url, lockTimeoutSeconds: 0.1)
        XCTAssertEqual(released.records.count, 1)
        XCTAssertTrue(released.issues.isEmpty)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testValidRecordsAndMalformedCrashTailAreExplicit() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("detections.jsonl")
        let scan = await DetectorFixture.scan()
        var data = try scan.records[0].encodeLine(); data.append(Data("{\"schema_version\":".utf8)); try data.write(to: url)
        let result = JSONLReader.readDetections(url: url)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertTrue(result.issues.contains { $0.code == .malformedTail })
    }
    func testMissingSymlinkAndOversizedLineDoNotInventRecords() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing")
        XCTAssertEqual(JSONLReader.readAudit(url: missing).issues.first?.code, .missingFile)
        let file = dir.appendingPathComponent("actual"); try Data("x\n".utf8).write(to: file)
        let link = dir.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(JSONLReader.readAudit(url: link).issues.first?.code, .unsafeFile)
        try Data((String(repeating: "x", count: 65_537) + "\n").utf8).write(to: file)
        XCTAssertEqual(JSONLReader.readAudit(url: file).issues.first?.code, .lineTooLarge)
    }
    func testAuditReaderUsesStrictEnvelopeAndRejectsInteriorGarbage() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audit.jsonl")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(DetectorFixture.audit()[0]); data.append(10)
        data.append(Data("{\"arbitrary\":true}\n".utf8)); try data.write(to: url)
        let result = JSONLReader.readAudit(url: url)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.issues.last?.code, .malformedRecord)
    }
    func testUnsupportedAuditVersionHasSpecificDiagnostic() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audit.jsonl")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DetectorFixture.audit()[0])) as? [String: Any])
        object["schema_version"] = 999
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10); try data.write(to: url)
        XCTAssertEqual(JSONLReader.readAudit(url: url).issues.first?.code, .unsupportedSchema)
    }
}
