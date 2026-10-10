import Foundation
import XCTest
@testable import HarnessCore
@testable import HarnessDetector
final class ReportTests: XCTestCase {
    func testReportIsDeterministicContainsNineCellsAndNoInventedPercentages() {
        let result = GroundTruthCorrelator.correlate(audit: [], detections: [])
        let environment = ReportEnvironment(metadata: ["macos": .string("synthetic"), "sdk": .string("fixture")])
        let report = ReportGenerator.render(result: result, environment: environment)
        XCTAssertEqual(report, ReportGenerator.render(result: result, environment: environment))
        XCTAssertEqual(report.components(separatedBy: "not_tested").count - 1, 9)
        for mode in 0...2 { for source in CaptureSource.allCases { XCTAssertTrue(report.contains("| \(mode) | \(source.rawValue) |")) } }
        XCTAssertFalse(report.contains("100%")); XCTAssertFalse(report.lowercased().contains("evasion rate"))
        XCTAssertTrue(report.contains("independent truth"))
    }
    func testReportEscapesMetadataAndIncludesCounts() async {
        let scan = await DetectorFixture.scan(context: DetectorFixture.context(truth: true))
        let result = GroundTruthCorrelator.correlate(audit: DetectorFixture.audit(), detections: scan.records)
        let report = ReportGenerator.render(result: result, environment: .init(metadata: ["browser": .string("a|b\nunsafe")]))
        XCTAssertTrue(report.contains("a\\|b unsafe"))
        XCTAssertTrue(report.contains("| 0 | sck_full | observed | 1 |"))
        XCTAssertTrue(report.contains("Unmatched records: 0"))
    }
    func testFailedInterruptedIndeterminateAndRejectedAttemptsRemainVisible() async {
        let scan = await DetectorFixture.scan()
        var failed = DetectorFixture.audit(completed: false)
        failed.append(AuditRecord(schemaVersion: 1, ts: failed[0].ts, event: .captureFailed, mode: 0, macos: "synthetic",
            sessionID: DetectorFixture.session, eventID: UUID(), experimentID: DetectorFixture.experiment, sequence: 2,
            payload: ["capture_id": .string(DetectorFixture.capture.uuidString), "reason": .string("capture_permission_denied")]))
        let stepID = UUID()
        let rejected = AuditRecord(schemaVersion: 1, ts: failed[0].ts, event: .experimentFailed, mode: 2, macos: "synthetic",
            sessionID: DetectorFixture.session, eventID: UUID(), experimentID: DetectorFixture.experiment, sequence: 3,
            payload: ["source": .string(CaptureSource.selectedWindow.rawValue), "step_id": .string(stepID.uuidString), "reason": .string("timed_out")])
        for (audit, rows, status) in [(failed + [rejected], scan.records, "failed"),
                                     (DetectorFixture.audit(completed: false), scan.records, "interrupted"),
                                     (DetectorFixture.audit(), scan.records, "observed_without_truth")] {
            let result = GroundTruthCorrelator.correlate(audit: audit, detections: rows)
            let report = ReportGenerator.render(result: result, environment: .init(metadata: [:]))
            XCTAssertTrue(report.contains("| 0 | sck_full | \(status) |"))
            if status == "failed" { XCTAssertTrue(report.contains("timed_out")); XCTAssertTrue(report.contains(stepID.uuidString)); XCTAssertTrue(report.contains("| 2 | sck_selected_window | failed |")) }
        }
    }
}
