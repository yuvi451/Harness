import XCTest
import Darwin
import LockTestSupport
@testable import HarnessCore

final class AuditTests: XCTestCase {
    func testCaptureDisplayMetadataAllowsUnknownStartAndValidatesKnownIDs() throws {
        XCTAssertNoThrow(try AuditEvent(.captureStarted, payload: ["source": .string("sck_full"), "display_id": .null]).validate())
        XCTAssertNoThrow(try AuditEvent(.captureStarted, payload: ["source": .string("sck_full"), "display_id": .integer(Int(UInt32.max))]).validate())
        let completion: [String: JSONValue] = ["bytes": .integer(1), "width": .integer(1), "height": .integer(1),
            "sha256": .string(String(repeating: "a", count: 64)), "overlay_in_capture": .null,
            "calibration_status": .string("indeterminate"), "calibration_reason": .string("geometry_unavailable")]
        for value: JSONValue in [.integer(0), .integer(-1), .integer(Int(UInt32.max) + 1), .bool(true), .string("1")] {
            XCTAssertThrowsError(try AuditEvent(.captureStarted, payload: ["source": .string("sck_full"), "display_id": value]).validate())
            var payload = completion; payload["display_id"] = value
            XCTAssertThrowsError(try AuditEvent(.captureCompleted, payload: payload).validate())
        }
    }

    func testSynchronizationRetriesInterruptionsButHasAFiniteLimit() throws {
        var calls = 0
        try CompleteWriter.synchronize { calls += 1; return calls < 3 ? EINTR : nil }
        XCTAssertEqual(calls, 3)
        calls = 0
        XCTAssertThrowsError(try CompleteWriter.synchronize { calls += 1; return EINTR })
        XCTAssertEqual(calls, 101)
        calls = 0
        XCTAssertThrowsError(try CompleteWriter.synchronize { calls += 1; return ENOSPC })
        XCTAssertEqual(calls, 1)
    }
    func testBriefAuditLockContentionAllowsAppendWithinBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audit.jsonl")
        let sink = try POSIXAuditSink(url: url, lockTimeoutSeconds: 1)
        let child = url.path.withCString { harness_fork_hold_lock($0, 50_000) }
        XCTAssertGreaterThan(child, 0)
        guard child > 0 else { return }
        defer { XCTAssertEqual(harness_wait_for_lock_child(child), 0) }
        try sink.append(Data("{}\n".utf8))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{}\n")
    }

    func testInvalidAuditLockBudgetsAreRejectedBeforeCreatingFiles() {
        for timeout in [Double.nan, Double.infinity, -1, 5.01] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("audit.jsonl")
            XCTAssertThrowsError(try POSIXAuditSink(url: url, lockTimeoutSeconds: timeout))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testExistingFIFORefusedWithoutWaitingForAnotherEndpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("audit.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { _ = try POSIXAuditSink(url: fifo); XCTFail("FIFO was accepted as an audit file") }
            catch {}
        }
        let initial = group.wait(timeout: .now() + 0.25)
        if initial == .timedOut {
            let reader = open(fifo.path, O_RDONLY | O_NONBLOCK)
            let writer = open(fifo.path, O_WRONLY | O_NONBLOCK)
            _ = group.wait(timeout: .now() + 2)
            if writer >= 0 { close(writer) }
            if reader >= 0 { close(reader) }
        }
        XCTAssertEqual(initial, .success, "Audit file validation must not wait on FIFO endpoints")
    }

    func testContendedAuditLockTimesOutWithoutAppending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audit.jsonl")
        let sink = try POSIXAuditSink(url: url, lockTimeoutSeconds: 0.05)
        try Data("{}\n".utf8).write(to: url)
        let child = url.path.withCString { harness_fork_hold_lock($0, 500_000) }
        XCTAssertGreaterThan(child, 0)
        guard child > 0 else { return }
        defer { XCTAssertEqual(harness_wait_for_lock_child(child), 0) }
        let started = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try sink.append(Data("{}\n".utf8))) { error in
            guard let auditError = error as? AuditError, case .io(let code) = auditError else {
                return XCTFail("Expected an audit lock timeout")
            }
            XCTAssertEqual(code, ETIMEDOUT)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        XCTAssertLessThan(elapsed, 0.3, "A stalled writer must not hold the app indefinitely")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{}\n")
    }

    func testCrossProcessLocking() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audit.jsonl")
        let sink = try POSIXAuditSink(url: url)
        let line = "{\"writer\":\"child\",\"padding\":\"abcdefghijk\"}\n"
        let children = Task.detached { url.path.withCString { path in
            line.withCString { bytes in harness_fork_append(path, bytes, UInt(line.utf8.count), 3, 50) }
        } }
        for _ in 0..<100 { try sink.append(Data("{\"writer\":\"parent\"}\n".utf8)) }
        let childStatus = await children.value
        XCTAssertEqual(childStatus, 0)
        let lines = try Data(contentsOf: url).split(separator: 10)
        XCTAssertEqual(lines.count, 250)
        for record in lines { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(record))) }
    }
    func testStrictSchemaAndTimestamp() async throws {
        let sink = MemoryAuditSink()
        let logger = AuditLogger(sink: sink, clock: FixedAuditClock(Date(timeIntervalSince1970: 0)), macOS: "test")
        try await logger.record(.init(.modeChanged, payload: ["from": .integer(0), "to": .integer(1)]), mode: 1, experimentID: nil)
        let raw = try XCTUnwrap(sink.lines.first)
        let record = try AuditRecord.decode(raw)
        XCTAssertEqual(record.ts, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(record.sequence, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertTrue(object["experiment_id"] is NSNull)
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        var broken = object; broken["unexpected"] = "x"
        XCTAssertThrowsError(try AuditRecord.decode(JSONSerialization.data(withJSONObject: broken)))
        XCTAssertThrowsError(try AuditEvent(.captureCompleted, payload: ["bytes": .integer(1)]).validate())
        XCTAssertThrowsError(try AuditEvent(.llmRequest, payload: ["provider": .string("ChatGPT plan"), "model": .string("m"), "prompt_chars": .integer(1), "api_key": .string("secret")]).validate())
    }
    func testConcurrentRecordsOrdered() async throws {
        let sink = MemoryAuditSink()
        let logger = AuditLogger(sink: sink, macOS: "test")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { try await logger.record(.init(.detectorScan, payload: ["n_windows": .integer(1), "n_flagged": .integer(0)]), mode: 0, experimentID: nil) } }
            try await group.waitForAll()
        }
        let records = try sink.lines.map(AuditRecord.decode)
        XCTAssertEqual(records.map(\.sequence), Array(1...100))
        XCTAssertEqual(Set(records.map(\.eventID)).count, 100)
    }
    func testFailureLatches() async throws {
        let sink = MemoryAuditSink(); sink.fail = true
        let logger = AuditLogger(sink: sink, macOS: "test")
        do { try await logger.record(.init(.detectorScan, payload: ["n_windows": .integer(0), "n_flagged": .integer(0)]), mode: 0, experimentID: nil); XCTFail() } catch {}
        sink.fail = false
        do { try await logger.record(.init(.detectorScan, payload: ["n_windows": .integer(0), "n_flagged": .integer(0)]), mode: 0, experimentID: nil); XCTFail() } catch {}
        XCTAssertEqual(sink.lines.count, 0)
    }
    func testInterruptedAndShortWrites() throws {
        var calls = 0; var result = Data()
        let bytes = Data("hello\n".utf8)
        try CompleteWriter.write(bytes) { pointer, count in
            calls += 1
            if calls == 1 { return .failure(EINTR) }
            let n = min(2, count); result.append(pointer.assumingMemoryBound(to: UInt8.self), count: n)
            return .success(n)
        }
        XCTAssertEqual(result, bytes)
        XCTAssertThrowsError(try CompleteWriter.write(bytes) { _, _ in .failure(ENOSPC) })
        XCTAssertThrowsError(try CompleteWriter.write(bytes) { _, _ in .success(0) })
    }
    func testFilePermissionsTailAndSymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audit.jsonl")
        let sink = try POSIXAuditSink(url: url)
        try sink.append(Data("{}\n".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("partial".utf8).write(to: url)
        XCTAssertThrowsError(try sink.append(Data("{}\n".utf8)))
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: url.path)
        XCTAssertThrowsError(try POSIXAuditSink(url: link))
    }

    func testHardLinkAddedAfterSinkInitializationBlocksFurtherAppend() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audit.jsonl")
        let sink = try POSIXAuditSink(url: url)
        try sink.append(Data("first\n".utf8))
        let alias = directory.appendingPathComponent("alias.jsonl")
        XCTAssertEqual(link(url.path, alias.path), 0)
        XCTAssertThrowsError(try sink.append(Data("second\n".utf8)))
        XCTAssertEqual(try String(contentsOf: alias, encoding: .utf8), "first\n")
    }
    func testMultipleIndependentWriters() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audit.jsonl")
        let a = AuditLogger(sink: try POSIXAuditSink(url: url), macOS: "test")
        let b = AuditLogger(sink: try POSIXAuditSink(url: url), macOS: "test")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<40 { let log = i % 2 == 0 ? a : b
                group.addTask { try await log.record(.init(.detectorScan, payload: ["n_windows": .integer(0), "n_flagged": .integer(0)]), mode: 0, experimentID: nil) }
            }
            try await group.waitForAll()
        }
        let lines = try Data(contentsOf: url).split(separator: 10)
        XCTAssertEqual(lines.count, 40)
        for line in lines { XCTAssertNoThrow(try AuditRecord.decode(Data(line))) }
    }
}
final class MemoryAuditSink: AuditSink, @unchecked Sendable {
    private let lock = NSLock()
    var lines: [Data] = []; var fail = false
    func append(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if fail { throw AuditError.io(ENOSPC) }
        lines.append(data)
    }
}
