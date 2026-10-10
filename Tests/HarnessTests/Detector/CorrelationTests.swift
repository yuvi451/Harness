import Foundation
import XCTest
@testable import HarnessCore
@testable import HarnessDetector
final class CorrelationTests: XCTestCase {
    func testExplicitTruthProducesAllFourConfusionCounts() async {
        let positive = await DetectorFixture.scan(context: DetectorFixture.context(truth: true))
        let negative = await DetectorFixture.scan(windows: [], context: DetectorFixture.context(truth: true))
        let falsePositive = await DetectorFixture.scan(context: DetectorFixture.context(truth: false))
        let trueNegative = await DetectorFixture.scan(windows: [], context: DetectorFixture.context(truth: false))
        for (scan, counts) in [(positive, [1,0,0,0]), (falsePositive, [0,1,0,0]), (trueNegative, [0,0,1,0]), (negative, [0,0,0,1])] {
            let result = GroundTruthCorrelator.correlate(audit: DetectorFixture.audit(), detections: scan.records)
            let m = result.metrics[0]
            XCTAssertEqual([m.truePositives,m.falsePositives,m.trueNegatives,m.falseNegatives], counts)
            XCTAssertEqual(m.sampleCount, 1)
        }
    }
    func testCalibrationAndSharingAreNeverImplicitAccuracyTruth() async {
        let scan = await DetectorFixture.scan(context: DetectorFixture.context())
        let result = GroundTruthCorrelator.correlate(audit: DetectorFixture.audit(), detections: scan.records)
        XCTAssertEqual(result.matchedCount, 1)
        XCTAssertEqual(result.metrics[0].sampleCount, 0)
        XCTAssertNil(result.metrics[0].recall)
        XCTAssertTrue(result.issues.contains { $0.code == .missingTruth })
    }
    func testStrongIdentitiesRejectExperimentPIDAndTimestampConflicts() async {
        for (context, date, expected) in [
            (DetectorFixture.context(truth: true, experimentID: UUID()), DetectorFixture.date, CorrelationIssue.Code.experimentConflict),
            (DetectorFixture.context(truth: true, ownerPID: 999), DetectorFixture.date, .identityConflict),
            (DetectorFixture.context(truth: true), DetectorFixture.date.addingTimeInterval(0.501), .timestampSkew)
        ] {
            let scan = await DetectorFixture.scan(context: context, date: date)
            let result = GroundTruthCorrelator.correlate(audit: DetectorFixture.audit(), detections: scan.records)
            XCTAssertEqual(result.metrics[0].sampleCount, 0)
            XCTAssertTrue(result.issues.contains { $0.code == expected })
        }
    }
    func testMultipleScansForOneCaptureAreAmbiguousAndInterruptedCaptureIsInvalid() async {
        let a = await DetectorFixture.scan(context: DetectorFixture.context(truth: true))
        let b = await DetectorFixture.scan(context: DetectorFixture.context(truth: true))
        let ambiguous = GroundTruthCorrelator.correlate(audit: DetectorFixture.audit(), detections: a.records + b.records)
        XCTAssertTrue(ambiguous.issues.contains { $0.code == .ambiguous })
        XCTAssertEqual(ambiguous.metrics[0].sampleCount, 0)
        let interrupted = GroundTruthCorrelator.correlate(audit: DetectorFixture.audit(completed: false), detections: a.records)
        XCTAssertTrue(interrupted.issues.contains { $0.code == .interruptedCapture })
    }
    func testDuplicatesDeduplicateButMalformedTailBlocksMetrics() async {
        let scan = await DetectorFixture.scan(context: DetectorFixture.context(truth: true))
        let deduplicated = GroundTruthCorrelator.correlate(audit: DetectorFixture.audit(), detections: scan.records + scan.records)
        XCTAssertEqual(deduplicated.metrics[0].sampleCount, 1)
        XCTAssertTrue(deduplicated.issues.contains { $0.code == .duplicateRecord })
        let issue = JSONLReadIssue(code: .malformedTail, line: 3)
        let invalid = GroundTruthCorrelator.correlate(audit: DetectorFixture.audit(), detections: scan.records, readIssues: [issue])
        XCTAssertEqual(invalid.metrics[0].sampleCount, 0)
        XCTAssertTrue(invalid.issues.contains { $0.code == .readIssue })
    }
    func testFailedEnumerationAndWindowIDReuseRemainIndeterminate() async {
        let scan = await DetectorFixture.scan(windows: [], context: DetectorFixture.context(truth: true), cgStatus: .failed)
        let failure = GroundTruthCorrelator.correlate(audit: DetectorFixture.audit(), detections: scan.records)
        XCTAssertEqual(failure.metrics[0].sampleCount, 0)
        let collision = await DetectorFixture.scan(windows: [DetectorFixture.window(pid: 999)], context: DetectorFixture.context(truth: true))
        let reused = GroundTruthCorrelator.correlate(audit: DetectorFixture.audit(), detections: collision.records)
        XCTAssertTrue(reused.issues.contains { $0.code == .windowIDReuse })
        XCTAssertEqual(reused.metrics[0].sampleCount, 0)
    }
    func testBusyAttemptWithoutCaptureIDDoesNotSuppressIndependentTruthMetrics() async {
        let scan = await DetectorFixture.scan(context: DetectorFixture.context(truth: true))
        var records = DetectorFixture.audit()
        records.append(AuditRecord(schemaVersion: 1, ts: records[1].ts, event: .captureFailed, mode: 0, macos: "synthetic",
            sessionID: DetectorFixture.session, eventID: UUID(), experimentID: nil, sequence: 3, payload: ["reason": .string("operation_busy")]))
        let result = GroundTruthCorrelator.correlate(audit: records, detections: scan.records)
        XCTAssertEqual(result.metrics[0].sampleCount, 1)
        XCTAssertEqual(result.attempts.count, 1)
        XCTAssertEqual(result.attempts.first?.reason, "operation_busy")
    }
    func testIncompleteRowsAndInconsistentFlaggedCountCannotBecomeNegativeMeasurement() async {
        let scan = await DetectorFixture.scan(context: DetectorFixture.context(truth: true))
        let summary = scan.records[0]
        let forged = DetectionRecord(scanID: summary.scanID, detectorSessionID: summary.detectorSessionID,
            kind: .scanSummary, ts: summary.ts, context: summary.context, cgStatus: .success, sckStatus: .success,
            windowCount: summary.windowCount, flaggedCount: 1)
        for rows in [[summary], [forged] + Array(scan.records.dropFirst())] {
            let result = GroundTruthCorrelator.correlate(audit: DetectorFixture.audit(), detections: rows)
            XCTAssertEqual(result.metrics[0].sampleCount, 0)
            XCTAssertTrue(result.issues.contains { $0.code == .incompleteScan })
        }
    }
    func testCrossProcessClockEvidenceMustMatchAuditedStartAndDetectWallJump() async {
        let audit = DetectorFixture.audit()
        for (contextMono, expected) in [(2_000_000_000, CorrelationIssue.Code.identityConflict), (1_000_000_000, .clockChange)] {
            let context = ScanContext(emitterSessionID: DetectorFixture.session, experimentID: DetectorFixture.experiment, stepID: nil,
                captureID: DetectorFixture.capture, targetWindowID: 42, ownerPID: 123, mode: .open, source: .full,
                independentTruth: .init(value: true, method: .manualObservation), captureMonotonicNS: contextMono, clockDomainID: "synthetic-boot")
            let snapshot = WindowEnumerationSnapshot(windows: [DetectorFixture.window()], shareableWindows: [], cgStatus: .success,
                sckStatus: .success, wallTime: DetectorFixture.date, monotonicNS: 2_000_000_000, clockDomainID: "synthetic-boot")
            let scan = await DetectorProbe(enumerator: SyntheticWindowEnumerator(value: snapshot)).scan(context: context)
            let result = GroundTruthCorrelator.correlate(audit: audit, detections: scan.records)
            XCTAssertEqual(result.metrics[0].sampleCount, 0)
            XCTAssertTrue(result.issues.contains { $0.code == expected })
        }
    }
}
