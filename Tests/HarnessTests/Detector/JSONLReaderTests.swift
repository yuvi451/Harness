import Foundation
import XCTest
import LockTestSupport
@testable import HarnessCore
@testable import HarnessDetector
final class JSONLReaderTests: XCTestCase {
    func testAdditionalAuditRetainsSeparateOperatorFailureInCorrelation() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let primary = dir.appendingPathComponent("emitter.jsonl")
        let additional = dir.appendingPathComponent("operator.jsonl")
        let emitter = DetectorFixture.audit()
        let operatorFailure = AuditRecord(schemaVersion: 1, ts: emitter[0].ts, event: .experimentFailed,
            mode: 0, macos: "synthetic", sessionID: UUID(), eventID: UUID(),
            experimentID: DetectorFixture.experiment, sequence: 1,
            payload: ["source": .string("sck_full"), "reason": .string("timed_out")])
        var bytes = Data()
        for record in emitter { bytes.append(try JSONEncoder().encode(record)); bytes.append(10) }
        try bytes.write(to: primary)
        var extra = try JSONEncoder().encode(operatorFailure); extra.append(10); try extra.write(to: additional)
        let result = JSONLReader.readAudit(url: primary, additionalURL: additional)
        XCTAssertEqual(result.records.map(\.eventID), emitter.map(\.eventID) + [operatorFailure.eventID])
        XCTAssertTrue(result.issues.isEmpty)
        let correlation = GroundTruthCorrelator.correlate(audit: result.records, detections: [])
        XCTAssertEqual(correlation.attempts.count, 1)
        XCTAssertEqual(correlation.attempts.first?.reason, "timed_out")
        XCTAssertEqual(correlation.attempts.first?.source, .full)
    }

    func testAdditionalAuditRetainsReadIssuesFromBothFiles() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let primary = dir.appendingPathComponent("emitter.jsonl")
        let additional = dir.appendingPathComponent("operator.jsonl")
        let records = DetectorFixture.audit()
        var bytes = try JSONEncoder().encode(records[0]); bytes.append(10)
        bytes.append(Data("partial".utf8)); try bytes.write(to: primary)
        var extra = try JSONEncoder().encode(records[1]); extra.append(10)
        extra.append(Data("{\"schema_version\":999}\n".utf8)); try extra.write(to: additional)
        let result = JSONLReader.readAudit(url: primary, additionalURL: additional)
        XCTAssertEqual(result.records.map(\.eventID), records.map(\.eventID))
        XCTAssertEqual(result.issues, [.init(code: .malformedTail, line: 2), .init(code: .unsupportedSchema, line: 2)])
    }

    func testAdditionalAuditSkipsCanonicalAndHardLinkAliasesWithoutDuplicatingRecords() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let primary = dir.appendingPathComponent("audit.jsonl")
        let record = DetectorFixture.audit()[0]
        var bytes = try JSONEncoder().encode(record); bytes.append(10); try bytes.write(to: primary)
        let hardLink = dir.appendingPathComponent("hard.jsonl")
        try FileManager.default.linkItem(at: primary, to: hardLink)
        let symbolic = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: dir)
        for additional: URL? in [nil, primary, hardLink, symbolic.appendingPathComponent("audit.jsonl")] {
            let result = JSONLReader.readAudit(url: primary, additionalURL: additional)
            XCTAssertEqual(result.records.map(\.eventID), [record.eventID])
            XCTAssertTrue(result.issues.isEmpty)
        }
    }

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
