import Foundation
import XCTest
@testable import HarnessCore
@testable import HarnessDetector

struct SyntheticWindowEnumerator: WindowEnumerating {
    let value: WindowEnumerationSnapshot
    func snapshot() async -> WindowEnumerationSnapshot { value }
}
enum DetectorFixture {
    static let session = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let capture = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let experiment = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static func context(truth: Bool? = nil, experimentID: UUID? = experiment, ownerPID: Int = 123) -> ScanContext {
        ScanContext(emitterSessionID: session, experimentID: experimentID, stepID: nil,
            captureID: capture, targetWindowID: 42, ownerPID: ownerPID, mode: .open,
            source: .full, independentTruth: truth.map { IndependentTruth(value: $0, method: .manualObservation) })
    }
    static func window(id: Int = 42, pid: Int = 123, layer: Int = 0, owner: String? = "Harness", sharing: Int? = 1) -> WindowMetadata {
        WindowMetadata(windowID: id, ownerPID: pid, ownerName: owner,
            bounds: ObservationBounds(x: -100, y: 20, width: 300, height: 200), layer: layer, sharingState: sharing)
    }
    static func scan(windows: [WindowMetadata] = [window()], context: ScanContext? = context(),
                     date: Date = date, cgStatus: DetectorQueryStatus = .success,
                     sckStatus: DetectorQueryStatus = .success) async -> DetectorScan {
        let snapshot = WindowEnumerationSnapshot(windows: windows,
            shareableWindows: windows.compactMap { w in w.windowID.map { ShareableWindowIdentity(windowID: $0, ownerPID: w.ownerPID) } },
            cgStatus: cgStatus, sckStatus: sckStatus, wallTime: date, monotonicNS: nil)
        return await DetectorProbe(enumerator: SyntheticWindowEnumerator(value: snapshot), sessionID: session).scan(context: context)
    }
    static func audit(windowID: Int = 42, ownerPID: Int = 123, experimentID: UUID? = experiment,
                      date: Date = date, completed: Bool = true) -> [AuditRecord] {
        let stamp = ISO8601DateFormatter(); stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload: [String: JSONValue] = ["capture_id": .string(capture.uuidString), "window_id": .integer(windowID),
            "owner_pid": .integer(ownerPID), "source": .string(CaptureSource.full.rawValue), "display_id": .integer(1)]
        var start = payload; start["monotonic_ns"] = .integer(1_000_000_000)
        var records = [AuditRecord(schemaVersion: 1, ts: stamp.string(from: date), event: .captureStarted,
            mode: 0, macos: "synthetic", sessionID: session, eventID: UUID(), experimentID: experimentID, sequence: 1, payload: start)]
        if completed {
            var finish = payload
            finish.merge(["bytes": .integer(100), "width": .integer(10), "height": .integer(10),
                "sha256": .string(String(repeating: "a", count: 64)), "overlay_in_capture": .bool(true),
                "calibration_status": .string("matched"), "calibration_reason": .string("synthetic")]) { _, new in new }
            records.append(AuditRecord(schemaVersion: 1, ts: stamp.string(from: date.addingTimeInterval(0.1)),
                event: .captureCompleted, mode: 0, macos: "synthetic", sessionID: session, eventID: UUID(),
                experimentID: experimentID, sequence: 2, payload: finish))
        }
        return records
    }
}
final class DetectorTests: XCTestCase {
    func testAllLayersAndSystemOwnersArePreservedAndOnlyAnnotated() async {
        let owners = ["Window Server", "Dock", "ControlCenter", "SystemUIServer", "Spotlight", "NotificationCenter"]
        let windows = owners.enumerated().map { DetectorFixture.window(id: $0.offset + 1, layer: $0.offset + 1, owner: $0.element) }
        let scan = await DetectorFixture.scan(windows: windows)
        XCTAssertEqual(scan.observations.count, 6)
        XCTAssertEqual(scan.observations.compactMap(\.layer), Array(1...6))
        XCTAssertTrue(scan.observations.allSatisfy(\.systemOwner))
        XCTAssertEqual(scan.records.count, 7)
    }
    func testSmallWindowIsRetainedAndMissingMetadataIsIndeterminate() async {
        let small = WindowMetadata(windowID: 1, ownerPID: 3, ownerName: nil,
            bounds: ObservationBounds(x: 0, y: 0, width: 1, height: 1), layer: 8, sharingState: nil)
        let invalid = WindowMetadata(windowID: nil, ownerPID: nil, ownerName: nil,
            bounds: ObservationBounds(x: 0, y: 0, width: -1, height: 0), layer: nil, sharingState: nil)
        let scan = await DetectorFixture.scan(windows: [small, invalid])
        XCTAssertEqual(scan.observations.count, 2)
        XCTAssertEqual(scan.observations[0].bounds?.width, 1)
        XCTAssertTrue(scan.observations[1].classifications.contains(.metadataIncomplete))
    }
    func testLegacySharingZeroNeverBecomesPixelExclusionTruth() async {
        let scan = await DetectorFixture.scan(windows: [DetectorFixture.window(sharing: 0)], context: nil)
        XCTAssertTrue(scan.observations[0].classifications.contains(.legacyNonsharingSignal))
        XCTAssertTrue(scan.observations[0].classifications.contains(.observedShareable))
        XCTAssertNil(scan.records.first?.context?.independentTruth)
    }
    func testPermissionDeniedSCKAndEmptyCGScanHaveExplicitSummary() async throws {
        let scan = await DetectorFixture.scan(windows: [], sckStatus: .permissionDenied)
        XCTAssertEqual(scan.sckStatus, .permissionDenied)
        XCTAssertEqual(scan.records.count, 1)
        XCTAssertEqual(scan.records[0].kind, .scanSummary)
        let line = try scan.records[0].encodeLine()
        XCTAssertEqual(line.last, 10)
        let decoded = try DetectionRecord.decode(Data(line.dropLast()))
        XCTAssertEqual(decoded.scanID, scan.scanID)
        XCTAssertEqual(decoded.windowCount, 0)
    }
    func testCallbackTimeoutAndCancellationReturnWithoutWaitingForLateNativeCallback() async throws {
        for cancel in [false, true] {
            let fixture = CallbackGateFixture()
            let task = Task {
                await ShareabilityCallbackGate.query(timeoutSeconds: 5,
                    operation: { callback in fixture.install(callback) },
                    scheduleTimeout: { _, action in fixture.installTimeout(action) })
            }
            try await fixture.waitUntilInstalled()
            if cancel { task.cancel() } else { fixture.timeout() }
            let outcome = await task.value
            XCTAssertEqual(outcome.status, cancel ? .cancelled : .timedOut)
            fixture.finish(.init(status: .success, windows: [.init(windowID: 42, ownerPID: 123)]))
            XCTAssertTrue(outcome.windows.isEmpty)
        }
    }
    func testSeparateQueryTimingSurvivesDetectionRoundTrip() async throws {
        let snapshot = WindowEnumerationSnapshot(windows: [], shareableWindows: [], cgStatus: .success,
            sckStatus: .failed, wallTime: DetectorFixture.date, monotonicNS: 1,
            sckWallTime: DetectorFixture.date.addingTimeInterval(0.1), cgLatencyMS: 2, sckLatencyMS: 5000)
        let scan = await DetectorProbe(enumerator: SyntheticWindowEnumerator(value: snapshot)).scan()
        let decoded = try DetectionRecord.decode(Data(try scan.records[0].encodeLine().dropLast()))
        XCTAssertEqual(decoded.sckTS, "2023-11-14T22:13:20.100Z")
        XCTAssertEqual(decoded.cgLatencyMS, 2)
        XCTAssertEqual(decoded.sckLatencyMS, 5000)
    }
}

private final class CallbackGateFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (ShareabilityQueryResult) -> Void)?
    private var timeoutAction: (@Sendable () -> Void)?
    func install(_ action: @escaping @Sendable (ShareabilityQueryResult) -> Void) { lock.withLock { callback = action } }
    func installTimeout(_ action: @escaping @Sendable () -> Void) { lock.withLock { timeoutAction = action } }
    func waitUntilInstalled() async throws {
        try await waitForTest { self.lock.withLock { self.callback != nil && self.timeoutAction != nil } }
    }
    func timeout() { lock.withLock { timeoutAction }?() }
    func finish(_ result: ShareabilityQueryResult) { lock.withLock { callback }?(result) }
}
