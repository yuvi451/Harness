import XCTest
@testable import HarnessCore

final class MatrixTests: XCTestCase {
    private let session = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let experiment = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let capture = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let configuration = MatrixConfiguration(mode: .spaceBehaviorProbe, source: .full)

    func testLegacyOverlayPositionChangeDoesNotPoisonLaterConfigurationReads() throws {
        let coordinator = MatrixSessionCoordinator(emitterSessionID: session, experimentID: experiment)
        let position = record(.settingsChanged, sequence: 3, mode: 2,
            payload: ["status": .string("applied"), "changed_keys": .array([.string("overlayPosition")])])
        let changed = record(.settingsChanged, sequence: 4, mode: 2,
            payload: ["status": .string("applied"), "source": .string("sck_full"), "configuration_changed_ns": .integer(1_100_000_000)])
        let records = baseline() + [position, changed]
        let current = try coordinator.currentConfiguration(records: records)
        XCTAssertEqual(current.source, .full)
        XCTAssertEqual(current.changedNS, 1_100_000_000)
        XCTAssertEqual(current.latestSequence, 4)
        XCTAssertNoThrow(try coordinator.arm(configuration: configuration, records: records, nowMonotonicNS: 1_400_000_000))
    }

    func testPartialCaptureConfigurationChangesRemainMalformed() {
        let coordinator = MatrixSessionCoordinator(emitterSessionID: session, experimentID: experiment)
        let invalidPayloads: [[String: JSONValue]] = [
            ["status": .string("applied"), "changed_keys": .array([.string("captureSource")])],
            ["status": .string("applied"), "changed_keys": .array([.string("overlayPosition"), .string("captureSource")])],
            ["status": .string("applied"), "changed_keys": .array([.string("overlayPosition")]), "source": .string("sck_full")],
            ["status": .string("applied"), "changed_keys": .array([.string("overlayPosition")]), "configuration_changed_ns": .integer(1_000_000_000)]
        ]
        for payload in invalidPayloads {
            let partial = record(.settingsChanged, sequence: 3, mode: 2, payload: payload)
            XCTAssertThrowsError(try coordinator.currentConfiguration(records: baseline() + [partial])) {
                XCTAssertEqual($0 as? MatrixCoordinationError, .malformedRecord)
            }
        }
    }

    func testNineConfigurationsAndUntestedProjectionWithoutCaptureRecords() throws {
        let coordinator = MatrixSessionCoordinator(emitterSessionID: session, experimentID: experiment)
        XCTAssertEqual(MatrixConfiguration.all.count, 9)
        XCTAssertEqual(Set(MatrixConfiguration.all.map { "\($0.mode.rawValue)/\($0.source.rawValue)" }).count, 9)
        let rows = coordinator.project(results: [])
        XCTAssertEqual(rows.count, 9)
        XCTAssertTrue(rows.allSatisfy { $0.status == .notTested && $0.sampleCount == 0 })
        let arm = try coordinator.arm(configuration: configuration, records: baseline(), nowMonotonicNS: 1_400_000_000)
        XCTAssertNil(try coordinator.nextCaptureStart(arm: arm, records: baseline()))
    }

    func testCurrentConfigurationUsesChosenEmitterAppliedSettingsAndLatestSequence() throws {
        let coordinator = MatrixSessionCoordinator(emitterSessionID: session, experimentID: experiment)
        let unrelated = record(.appLaunch, sequence: 100, sessionID: UUID(), mode: 0,
            payload: ["source": .string("sck_selected_window"), "configuration_changed_ns": .integer(10)])
        let ignored = record(.settingsChanged, sequence: 3, mode: 2,
            payload: ["status": .string("account_disconnect"), "network_enabled": .bool(false)])
        let current = try coordinator.currentConfiguration(records: baseline() + [unrelated, ignored])
        XCTAssertEqual(current.sessionID, session)
        XCTAssertEqual(current.mode, .spaceBehaviorProbe)
        XCTAssertEqual(current.source, .full)
        XCTAssertEqual(current.changedNS, 1_000_000_000)
        XCTAssertEqual(current.latestSequence, 3)
    }

    func testArmingRejectsWrongConfigurationUnsettledClockAndMissingLaunch() throws {
        let coordinator = MatrixSessionCoordinator(emitterSessionID: session, experimentID: experiment)
        XCTAssertThrowsError(try coordinator.arm(configuration: .init(mode: .open, source: .full), records: baseline(), nowMonotonicNS: 1_400_000_000))
        XCTAssertThrowsError(try coordinator.arm(configuration: configuration, records: baseline(), nowMonotonicNS: 1_199_999_999))
        XCTAssertThrowsError(try coordinator.arm(configuration: configuration, records: baseline(), nowMonotonicNS: -1))
        XCTAssertThrowsError(try coordinator.arm(configuration: configuration, records: Array(baseline().dropFirst()), nowMonotonicNS: 1_400_000_000))
    }

    func testArmBindsNextUserCaptureAndFinishPreservesIndeterminateCalibration() throws {
        let coordinator = MatrixSessionCoordinator(emitterSessionID: session, experimentID: experiment)
        let before = baseline() + [start(sequence: 3, captureID: UUID(), monotonicNS: 1_300_000_000), completed(sequence: 4, captureID: UUID())]
        // Arming excludes every previously observed event by sequence, even recent captures.
        let arm = try coordinator.arm(configuration: configuration, records: before, nowMonotonicNS: 1_400_000_000)
        let actualStart = start(sequence: 5)
        let pending = before + [actualStart]
        let found = try XCTUnwrap(coordinator.nextCaptureStart(arm: arm, records: pending))
        XCTAssertEqual(found.eventID, actualStart.eventID)
        XCTAssertNil(try coordinator.finish(arm: arm, start: found, records: pending))
        let result = try XCTUnwrap(coordinator.finish(arm: arm, start: found, records: pending + [completed(sequence: 6)]))
        XCTAssertEqual(result.stepID, arm.stepID)
        XCTAssertEqual(result.experimentID, experiment)
        XCTAssertEqual(result.emitterSessionID, session)
        XCTAssertEqual(result.captureID, capture)
        XCTAssertEqual(result.windowID, 42); XCTAssertEqual(result.ownerPID, 123)
        XCTAssertEqual(result.mode, .spaceBehaviorProbe); XCTAssertEqual(result.source, .full)
        XCTAssertEqual(result.monotonicNS, 1_500_000_000)
        XCTAssertEqual(result.configurationChangedNS, 1_000_000_000)
        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(result.calibrationStatus, "indeterminate")
        XCTAssertNil(result.overlayInCapture)
        XCTAssertEqual(result.calibrationConfidence, 0)
        XCTAssertEqual(result.completion?.payload["bytes"], .integer(200))
        let decoded = try JSONDecoder().decode(MatrixStepCapture.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.captureID, capture)
        let rows = coordinator.project(results: [result])
        XCTAssertEqual(rows.filter { $0.status == .notTested }.count, 8)
        XCTAssertEqual(rows.first { $0.configuration == configuration }?.sampleCount, 1)
    }

    func testCaptureFailureNeedsOnlyCaptureIDAndEnvelopeIdentity() throws {
        let coordinator = MatrixSessionCoordinator(emitterSessionID: session, experimentID: experiment)
        let arm = try coordinator.arm(configuration: configuration, records: baseline(), nowMonotonicNS: 1_400_000_000)
        let actualStart = start()
        let failure = record(.captureFailed, sequence: 4, mode: 2,
            payload: ["capture_id": .string(capture.uuidString), "reason": .string("permission_denied")])
        let result = try XCTUnwrap(coordinator.finish(arm: arm, start: actualStart, records: baseline() + [actualStart, failure]))
        XCTAssertEqual(result.outcome, .failure)
        XCTAssertEqual(result.reason, "permission_denied")
        XCTAssertEqual(result.windowID, 42); XCTAssertEqual(result.ownerPID, 123)
        XCTAssertNil(result.overlayInCapture)
    }

    func testUnknownStartDisplayMayResolveAtCompletionButKnownDisplaysMustMatch() throws {
        let coordinator = MatrixSessionCoordinator(emitterSessionID: session, experimentID: experiment)
        let arm = try coordinator.arm(configuration: configuration, records: baseline(), nowMonotonicNS: 1_400_000_000)
        var unknownPayload = start().payload; unknownPayload["display_id"] = .null
        let unknown = record(.captureStarted, sequence: 3, mode: 2, payload: unknownPayload)
        var terminalPayload = completed().payload; terminalPayload["display_id"] = .integer(2)
        let resolved = record(.captureCompleted, sequence: 4, mode: 2, payload: terminalPayload)
        XCTAssertNotNil(try coordinator.finish(arm: arm, start: unknown, records: baseline() + [unknown, resolved]))
        let known = start()
        XCTAssertThrowsError(try coordinator.finish(arm: arm, start: known, records: baseline() + [known, resolved]))
    }

    func testLatePreArmCaptureAndConfigurationChangeCannotBecomeMeasurement() throws {
        let coordinator = MatrixSessionCoordinator(emitterSessionID: session, experimentID: experiment)
        let arm = try coordinator.arm(configuration: configuration, records: baseline(), nowMonotonicNS: 1_400_000_000)
        XCTAssertThrowsError(try coordinator.nextCaptureStart(arm: arm, records: baseline() + [start(monotonicNS: 1_399_999_999)]))
        let changed = record(.settingsChanged, sequence: 3, mode: 2, payload: ["status": .string("applied"), "source": .string("sck_full"), "configuration_changed_ns": .integer(1_450_000_000)])
        XCTAssertThrowsError(try coordinator.nextCaptureStart(arm: arm, records: baseline() + [changed, start(sequence: 4)]))
        XCTAssertThrowsError(try coordinator.nextCaptureStart(arm: arm, records: baseline() + [start(changedNS: 1_400_000_000)]))
    }

    func testDuplicatesAndConflictingCompletionIdentityAreRejected() throws {
        let coordinator = MatrixSessionCoordinator(emitterSessionID: session, experimentID: experiment)
        let arm = try coordinator.arm(configuration: configuration, records: baseline(), nowMonotonicNS: 1_400_000_000)
        let actualStart = start()
        XCTAssertThrowsError(try coordinator.nextCaptureStart(arm: arm, records: baseline() + [actualStart, actualStart]))
        XCTAssertThrowsError(try coordinator.nextCaptureStart(arm: arm, records: baseline() + [actualStart, start(sequence: 4)]))
        XCTAssertThrowsError(try coordinator.finish(arm: arm, start: actualStart, records: baseline() + [actualStart, completed(ownerPID: 999)]))
        XCTAssertThrowsError(try coordinator.finish(arm: arm, start: actualStart, records: baseline() + [actualStart, completed(windowID: 999)]))
        XCTAssertThrowsError(try coordinator.finish(arm: arm, start: actualStart, records: baseline() + [actualStart, completed(), completed(sequence: 5)]))
        let failed = record(.captureFailed, sequence: 5, mode: 2, payload: ["capture_id": .string(capture.uuidString), "reason": .string("failed")])
        XCTAssertThrowsError(try coordinator.finish(arm: arm, start: actualStart, records: baseline() + [actualStart, completed(), failed]))
    }

    func testModeSourceSessionAndStepExperimentConflictsDoNotCorrelate() throws {
        let coordinator = MatrixSessionCoordinator(emitterSessionID: session, experimentID: experiment)
        let arm = try coordinator.arm(configuration: configuration, records: baseline(), nowMonotonicNS: 1_400_000_000)
        XCTAssertThrowsError(try coordinator.nextCaptureStart(arm: arm, records: baseline() + [start(mode: 1)]))
        XCTAssertThrowsError(try coordinator.nextCaptureStart(arm: arm, records: baseline() + [start(source: .excludingSelf)]))
        let foreign = record(.captureStarted, sequence: 1, sessionID: UUID(), mode: 2, payload: start().payload)
        XCTAssertNil(try coordinator.nextCaptureStart(arm: arm, records: baseline() + [foreign]))
        let conflict = record(.captureStarted, sequence: 3, mode: 2, payload: start().payload, experimentID: UUID())
        XCTAssertThrowsError(try coordinator.nextCaptureStart(arm: arm, records: baseline() + [conflict]))
        var payload = start().payload; payload["step_id"] = .string(UUID().uuidString)
        XCTAssertThrowsError(try coordinator.nextCaptureStart(arm: arm, records: baseline() + [record(.captureStarted, sequence: 3, mode: 2, payload: payload)]))
    }

    func testAmbiguousEmitterSessionsRequireExplicitChoiceAndStrictRecords() throws {
        let other = record(.appLaunch, sequence: 1, sessionID: UUID(), mode: 0,
            payload: ["source": .string("sck_full"), "configuration_changed_ns": .integer(1_000_000_000)])
        XCTAssertThrowsError(try MatrixSessionCoordinator(experimentID: experiment).currentConfiguration(records: baseline() + [other]))
        XCTAssertThrowsError(try MatrixSessionCoordinator(emitterSessionID: session).currentConfiguration(records: Array(baseline().reversed())))
        let malformed = record(.settingsChanged, sequence: 3, mode: 2,
            payload: ["status": .string("applied"), "source": .string("unknown"), "configuration_changed_ns": .integer(-1)])
        XCTAssertThrowsError(try MatrixSessionCoordinator(emitterSessionID: session).currentConfiguration(records: baseline() + [malformed]))
    }

    private func baseline() -> [AuditRecord] {
        [record(.appLaunch, sequence: 1, mode: 0, payload: ["source": .string("sck_excluding_self"), "configuration_changed_ns": .integer(100)]),
         record(.settingsChanged, sequence: 2, mode: 2, payload: ["status": .string("applied"), "source": .string("sck_full"), "configuration_changed_ns": .integer(1_000_000_000)])]
    }
    private func start(sequence: Int = 3, captureID: UUID? = nil, monotonicNS: Int = 1_500_000_000,
                       changedNS: Int = 1_000_000_000, mode: Int = 2, source: CaptureSource = .full) -> AuditRecord {
        record(.captureStarted, sequence: sequence, mode: mode, payload: ["capture_id": .string((captureID ?? capture).uuidString), "source": .string(source.rawValue), "display_id": .integer(1), "window_id": .integer(42), "owner_pid": .integer(123), "monotonic_ns": .integer(monotonicNS), "configuration_changed_ns": .integer(changedNS)])
    }
    private func completed(sequence: Int = 4, captureID: UUID? = nil, ownerPID: Int = 123, windowID: Int = 42) -> AuditRecord {
        record(.captureCompleted, sequence: sequence, mode: 2, payload: ["capture_id": .string((captureID ?? capture).uuidString), "source": .string("sck_full"), "window_id": .integer(windowID), "owner_pid": .integer(ownerPID), "display_id": .integer(1), "bytes": .integer(200), "width": .integer(100), "height": .integer(100), "sha256": .string(String(repeating: "a", count: 64)), "overlay_in_capture": .null, "calibration_status": .string("indeterminate"), "calibration_reason": .string("occluded"), "confidence": .number(0), "latency_ms": .number(10)])
    }
    private func record(_ event: AuditEventName, sequence: Int, sessionID: UUID? = nil, mode: Int,
                        payload: [String: JSONValue], experimentID: UUID? = nil) -> AuditRecord {
        AuditRecord(schemaVersion: 1, ts: "2026-10-08T12:00:00.\(String(format: "%03d", sequence))Z", event: event,
            mode: mode, macos: "27.0", sessionID: sessionID ?? session, eventID: UUID(),
            experimentID: experimentID, sequence: sequence, payload: payload)
    }
}
