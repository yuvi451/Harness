import XCTest
import Darwin
import LockTestSupport
@testable import HarnessCore

final class ReportWriterTests: XCTestCase {
    func testInvalidReportLockBudgetsAreRejectedBeforeCreatingFiles() {
        for timeout in [Double.nan, Double.infinity, -1, 5.01] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("report.md")
            XCTAssertThrowsError(try ProtectedReportWriter.write("report", to: url, lockTimeoutSeconds: timeout))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testContendedReportLockTimesOutBeforeTruncating() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("report.md")
        try Data("preserve this report\n".utf8).write(to: url)
        let child = url.path.withCString { harness_fork_hold_lock($0, 500_000) }
        XCTAssertGreaterThan(child, 0)
        guard child > 0 else { return }
        defer { XCTAssertEqual(harness_wait_for_lock_child(child), 0) }
        let started = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try ProtectedReportWriter.write("replacement", to: url, lockTimeoutSeconds: 0.05)) { error in
            guard let auditError = error as? AuditError, case .io(let code) = auditError else {
                return XCTFail("Expected a report lock timeout")
            }
            XCTAssertEqual(code, ETIMEDOUT)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        XCTAssertLessThan(elapsed, 0.3, "A stalled writer must not hold report generation indefinitely")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "preserve this report\n")
    }

    func testCreatesPrivateReportAndReplacesContentWithoutTrailingBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("report.md")
        try ProtectedReportWriter.write("A longer measurement report\n", to:url)
        try ProtectedReportWriter.write("short\n", to:url)
        XCTAssertEqual(try String(contentsOf:url,encoding:.utf8), "short\n")
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testSymbolicAndHardLinksRefusedBeforeTruncatingAnyTarget() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let original = dir.appendingPathComponent("original.md")
        try Data("preserve\n".utf8).write(to:original)
        let symbolic = dir.appendingPathComponent("symbolic.md")
        try FileManager.default.createSymbolicLink(atPath:symbolic.path,withDestinationPath:original.path)
        XCTAssertThrowsError(try ProtectedReportWriter.write("unsafe",to:symbolic))
        let hard = dir.appendingPathComponent("hard.md")
        XCTAssertEqual(link(original.path,hard.path),0)
        XCTAssertThrowsError(try ProtectedReportWriter.write("unsafe",to:hard))
        XCTAssertEqual(try String(contentsOf:original,encoding:.utf8),"preserve\n")
    }
    func testOversizedReportRefusedWithoutCreatingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("report.md")
        XCTAssertThrowsError(try ProtectedReportWriter.write(String(repeating:"a",count:2_000_001),to:url))
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    }
    func testExistingFIFORefusedWithoutWaitingForAReader() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fifo = directory.appendingPathComponent("report.md")
        XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { try ProtectedReportWriter.write("metadata",to:fifo); XCTFail("FIFO was accepted as a report") }
            catch {}
        }
        let initial = group.wait(timeout:.now() + 0.25)
        // Release an unsafe pre-fix open so the RED run never leaves a hung worker.
        if initial == .timedOut {
            let reader = open(fifo.path,O_RDONLY | O_NONBLOCK)
            _ = group.wait(timeout:.now() + 2)
            if reader >= 0 { close(reader) }
        }
        XCTAssertEqual(initial,.success,"Unsafe FIFO opens must be rejected without blocking")
    }
}
