import Foundation

public struct MatrixConfiguration: Codable, Equatable, Hashable, Sendable {
    public let mode: VisibilityMode
    public let source: CaptureSource
    public init(mode: VisibilityMode, source: CaptureSource) { self.mode = mode; self.source = source }
    public static var all: [MatrixConfiguration] {
        VisibilityMode.allCases.flatMap { mode in CaptureSource.allCases.map { .init(mode: mode, source: $0) } }
    }
}

public struct MatrixCurrentConfiguration: Sendable {
    public let sessionID: UUID
    public let mode: VisibilityMode
    public let source: CaptureSource
    public let changedNS: Int
    public let latestSequence: Int
}

/// An observation receipt only. It cannot trigger a capture or configure an emitter.
public struct MatrixArm: Codable, Sendable {
    public let stepID: UUID
    public let experimentID: UUID
    public let emitterSessionID: UUID
    public let configuration: MatrixConfiguration
    public let cutoffSequence: Int
    public let armedMonotonicNS: Int
    public let configurationChangedNS: Int
}

public enum MatrixStepOutcome: String, Codable, Sendable { case success, failure }
public struct MatrixStepCapture: Codable, Sendable {
    public let stepID: UUID
    public let experimentID: UUID
    public let emitterSessionID: UUID
    public let captureID: UUID
    public let windowID: Int
    public let ownerPID: Int
    public let mode: VisibilityMode
    public let source: CaptureSource
    public let wallTime: String
    public let monotonicNS: Int?
    public let configurationChangedNS: Int?
    public let completion: AuditRecord?
    public let calibrationStatus: String
    public let calibrationConfidence: Double?
    public let overlayInCapture: Bool?
    public let outcome: MatrixStepOutcome
    public let reason: String
}

public enum MatrixProjectionStatus: String, Codable, Sendable {
    case notTested = "not_tested", completed, failed, partial
}
public struct MatrixConfigurationResult: Codable, Sendable {
    public let configuration: MatrixConfiguration
    public let status: MatrixProjectionStatus
    public let sampleCount: Int
    public let captures: [MatrixStepCapture]
}
public enum MatrixCoordinationError: Error, Equatable, LocalizedError {
    case malformedRecord, duplicateRecord, unorderedRecords, emitterMissing, ambiguousEmitter
    case configurationMismatch, configurationChanged, notSettled, preArmCapture
    case conflictingCapture, conflictingExperiment, invalidArm
    public var errorDescription: String? {
        switch self {
        case .malformedRecord: return "Required matrix metadata is missing or invalid."
        case .duplicateRecord: return "Duplicate audit or capture records make this measurement ambiguous."
        case .unorderedRecords: return "Emitter audit sequences are not strictly ordered."
        case .emitterMissing: return "The selected emitter launch record is missing."
        case .ambiguousEmitter: return "Select one emitter session before arming a measurement."
        case .configurationMismatch: return "The emitter Settings do not match this matrix configuration."
        case .configurationChanged: return "The emitter configuration changed after this step was armed."
        case .notSettled: return "Wait at least 200 ms after the completed configuration change."
        case .preArmCapture: return "The capture started before this observation was armed."
        case .conflictingCapture: return "Capture metadata identities or terminal states conflict."
        case .conflictingExperiment: return "Capture metadata belongs to another step or experiment."
        case .invalidArm: return "This arm receipt does not belong to the current matrix session."
        }
    }
}

/// Pure metadata correlation. The caller supplies audited facts and a monotonic clock value.
/// No image, capture API, mode engine, network transport or IPC command is available here.
public struct MatrixSessionCoordinator: Sendable {
    public let experimentID: UUID
    private let emitterSessionID: UUID?
    private static let settleNS = 200_000_000
    public init(emitterSessionID: UUID? = nil, experimentID: UUID = UUID()) {
        self.emitterSessionID = emitterSessionID; self.experimentID = experimentID
    }

    public func currentConfiguration(records: [AuditRecord]) throws -> MatrixCurrentConfiguration {
        let selected = try emitterRecords(records)
        guard let launch = selected.first(where: { $0.event == .appLaunch }) else {
            throw MatrixCoordinationError.emitterMissing
        }
        guard selected.filter({ $0.event == .appLaunch }).count == 1,
              selected.first?.event == .appLaunch else { throw MatrixCoordinationError.conflictingCapture }
        var configuration = try activeConfiguration(launch)
        for record in selected where Self.isCaptureConfigurationChange(record) {
            let next = try activeConfiguration(record)
            guard next.changedNS >= configuration.changedNS else { throw MatrixCoordinationError.malformedRecord }
            configuration = next
        }
        return MatrixCurrentConfiguration(sessionID: launch.sessionID, mode: configuration.mode,
            source: configuration.source, changedNS: configuration.changedNS,
            latestSequence: selected.last?.sequence ?? launch.sequence)
    }

    public func arm(configuration: MatrixConfiguration, records: [AuditRecord], nowMonotonicNS: Int) throws -> MatrixArm {
        let current = try currentConfiguration(records: records)
        guard current.mode == configuration.mode, current.source == configuration.source else {
            throw MatrixCoordinationError.configurationMismatch
        }
        guard nowMonotonicNS >= 0, nowMonotonicNS >= current.changedNS,
              nowMonotonicNS - current.changedNS >= Self.settleNS else { throw MatrixCoordinationError.notSettled }
        return MatrixArm(stepID: UUID(), experimentID: experimentID, emitterSessionID: current.sessionID,
            configuration: configuration, cutoffSequence: current.latestSequence,
            armedMonotonicNS: nowMonotonicNS, configurationChangedNS: current.changedNS)
    }

    public func nextCaptureStart(arm: MatrixArm, records: [AuditRecord]) throws -> AuditRecord? {
        let selected = try recordsForArm(arm, records: records)
        let starts = selected.filter { $0.sequence > arm.cutoffSequence && $0.event == .captureStarted }
        guard let first = starts.first else { return nil }
        try validateStart(first, arm: arm)
        let captureID = try identity(first)
        guard selected.filter({ $0.event == .captureStarted && (try? identity($0)) == captureID }).count == 1 else {
            throw MatrixCoordinationError.duplicateRecord
        }
        // More than one start before the first terminal record violates the single-flight emitter boundary.
        let terminal = selected.first { $0.sequence > first.sequence &&
            ($0.event == .captureCompleted || $0.event == .captureFailed) && (try? identity($0)) == captureID }
        if starts.dropFirst().contains(where: { terminal == nil || $0.sequence < terminal!.sequence }) {
            throw MatrixCoordinationError.conflictingCapture
        }
        return first
    }

    public func finish(arm: MatrixArm, start: AuditRecord, records: [AuditRecord]) throws -> MatrixStepCapture? {
        let selected = try recordsForArm(arm, records: records)
        guard let bound = try nextCaptureStart(arm: arm, records: records),
              bound.eventID == start.eventID, bound.sequence == start.sequence,
              bound.sessionID == start.sessionID, bound.mode == start.mode, bound.payload == start.payload else {
            throw MatrixCoordinationError.conflictingCapture
        }
        let captureID = try identity(bound)
        let terminals = selected.filter { ($0.event == .captureCompleted || $0.event == .captureFailed) &&
            (try? identity($0)) == captureID }
        guard terminals.count <= 1 else { throw MatrixCoordinationError.duplicateRecord }
        guard let terminal = terminals.first else { return nil }
        guard terminal.sequence > bound.sequence, terminal.mode == bound.mode else {
            throw MatrixCoordinationError.conflictingCapture
        }
        try validateExperiment(terminal, arm: arm)
        for key in ["window_id", "owner_pid", "source"] {
            if let value = terminal.payload[key], value != bound.payload[key] { throw MatrixCoordinationError.conflictingCapture }
        }
        // The capture engine may only determine the source display after the start audit.
        // A null start is unknown; a recorded display still binds the terminal identity.
        if let startDisplay = bound.payload["display_id"]?.int,
           let terminalDisplay = terminal.payload["display_id"], terminalDisplay != .integer(startDisplay) {
            throw MatrixCoordinationError.conflictingCapture
        }
        let completed = terminal.event == .captureCompleted
        if completed {
            guard terminal.payload["window_id"] == bound.payload["window_id"],
                  terminal.payload["owner_pid"] == bound.payload["owner_pid"],
                  terminal.payload["source"] == bound.payload["source"] else {
                throw MatrixCoordinationError.conflictingCapture
            }
        }
        let confidence = try optionalConfidence(terminal.payload["confidence"])
        let calibrationStatus = completed ? terminal.payload["calibration_status"]?.string ?? "indeterminate" : "indeterminate"
        guard ["matched", "absent", "indeterminate"].contains(calibrationStatus) else { throw MatrixCoordinationError.malformedRecord }
        return MatrixStepCapture(stepID: arm.stepID, experimentID: arm.experimentID,
            emitterSessionID: arm.emitterSessionID, captureID: captureID,
            windowID: bound.payload["window_id"]!.int!, ownerPID: bound.payload["owner_pid"]!.int!,
            mode: arm.configuration.mode, source: arm.configuration.source, wallTime: bound.ts,
            monotonicNS: bound.payload["monotonic_ns"]?.int,
            configurationChangedNS: bound.payload["configuration_changed_ns"]?.int,
            completion: terminal, calibrationStatus: calibrationStatus, calibrationConfidence: confidence,
            overlayInCapture: completed ? terminal.payload["overlay_in_capture"]?.boolean : nil,
            outcome: completed ? .success : .failure,
            reason: completed ? terminal.payload["calibration_reason"]?.string ?? "capture_completed" : terminal.payload["reason"]?.string ?? "capture_failed")
    }

    public func project(results: [MatrixStepCapture]) -> [MatrixConfigurationResult] {
        let own = results.filter { $0.experimentID == experimentID &&
            (emitterSessionID == nil || $0.emitterSessionID == emitterSessionID) }
        return MatrixConfiguration.all.map { configuration in
            let captures = own.filter { $0.mode == configuration.mode && $0.source == configuration.source }
            let successes = captures.filter { $0.outcome == .success }.count
            let status: MatrixProjectionStatus = captures.isEmpty ? .notTested : successes == captures.count ? .completed : successes == 0 ? .failed : .partial
            return MatrixConfigurationResult(configuration: configuration, status: status,
                sampleCount: successes, captures: captures)
        }
    }

    private func emitterRecords(_ records: [AuditRecord], forcedSession: UUID? = nil) throws -> [AuditRecord] {
        guard records.count <= 100_000 else { throw MatrixCoordinationError.malformedRecord }
        var eventIDs: Set<UUID> = []
        for record in records {
            guard record.schemaVersion == 1, (0...2).contains(record.mode), record.sequence > 0,
                  record.ts.count == 24, AuditRecord.timestampFormatter().date(from: record.ts) != nil else {
                throw MatrixCoordinationError.malformedRecord
            }
            try AuditEvent(record.event, payload: record.payload).validate()
            guard eventIDs.insert(record.eventID).inserted else { throw MatrixCoordinationError.duplicateRecord }
        }
        let launches = records.filter { $0.event == .appLaunch }
        let session: UUID
        if let forcedSession = forcedSession ?? emitterSessionID { session = forcedSession }
        else {
            let sessions = Set(launches.map(\.sessionID))
            guard sessions.count == 1, let unique = sessions.first else {
                throw sessions.isEmpty ? MatrixCoordinationError.emitterMissing : .ambiguousEmitter
            }
            session = unique
        }
        let selected = records.filter { $0.sessionID == session }
        guard selected.contains(where: { $0.event == .appLaunch }) else { throw MatrixCoordinationError.emitterMissing }
        var previous = 0
        for record in selected {
            guard record.sequence > previous else { throw record.sequence == previous ? MatrixCoordinationError.duplicateRecord : .unorderedRecords }
            previous = record.sequence
        }
        return selected
    }

    private func activeConfiguration(_ record: AuditRecord) throws -> (mode: VisibilityMode, source: CaptureSource, changedNS: Int) {
        guard let mode = VisibilityMode(rawValue: record.mode),
              let raw = record.payload["source"]?.string, let source = CaptureSource(rawValue: raw),
              let changed = record.payload["configuration_changed_ns"]?.int, changed >= 0 else {
            throw MatrixCoordinationError.malformedRecord
        }
        return (mode, source, changed)
    }
    private static func isCaptureConfigurationChange(_ record:AuditRecord) -> Bool {
        guard record.event == .settingsChanged, record.payload["status"]?.string == "applied" else { return false }
        // Version 0.6.0 logged position-only switches without capture metadata.
        // Ignore only that exact legacy shape; malformed full saves must fail.
        return !(record.payload["changed_keys"] == .array([.string("overlayPosition")]) &&
            record.payload["source"] == nil && record.payload["configuration_changed_ns"] == nil)
    }
    private func recordsForArm(_ arm: MatrixArm, records: [AuditRecord]) throws -> [AuditRecord] {
        guard arm.experimentID == experimentID,
              emitterSessionID == nil || emitterSessionID == arm.emitterSessionID,
              arm.cutoffSequence > 0, arm.armedMonotonicNS >= arm.configurationChangedNS,
              arm.configurationChangedNS >= 0 else { throw MatrixCoordinationError.invalidArm }
        let selected = try emitterRecords(records, forcedSession: arm.emitterSessionID)
        let current = try currentConfiguration(records: selected)
        guard current.mode == arm.configuration.mode, current.source == arm.configuration.source,
              current.changedNS == arm.configurationChangedNS else { throw MatrixCoordinationError.configurationChanged }
        if selected.contains(where: { $0.sequence > arm.cutoffSequence &&
            (Self.isCaptureConfigurationChange($0) ||
             ($0.event == .modeChanged && $0.payload["status"]?.string == "applied")) }) {
            throw MatrixCoordinationError.configurationChanged
        }
        return selected
    }
    private func identity(_ record: AuditRecord) throws -> UUID {
        guard let value = record.payload["capture_id"]?.string, let id = UUID(uuidString: value) else {
            throw MatrixCoordinationError.malformedRecord
        }
        return id
    }
    private func validateStart(_ start: AuditRecord, arm: MatrixArm) throws {
        try validateExperiment(start, arm: arm)
        _ = try identity(start)
        guard start.mode == arm.configuration.mode.rawValue,
              start.payload["source"]?.string == arm.configuration.source.rawValue else {
            throw MatrixCoordinationError.configurationMismatch
        }
        guard let window = start.payload["window_id"]?.int, window > 0, window <= Int(UInt32.max),
              let pid = start.payload["owner_pid"]?.int, pid > 0, pid <= Int(Int32.max),
              let time = start.payload["monotonic_ns"]?.int, time >= 0,
              let changed = start.payload["configuration_changed_ns"]?.int, changed == arm.configurationChangedNS else {
            throw MatrixCoordinationError.malformedRecord
        }
        guard time >= arm.armedMonotonicNS else { throw MatrixCoordinationError.preArmCapture }
        guard time >= changed, time - changed >= Self.settleNS else { throw MatrixCoordinationError.notSettled }
    }
    private func validateExperiment(_ record: AuditRecord, arm: MatrixArm) throws {
        guard record.experimentID == nil || record.experimentID == arm.experimentID else {
            throw MatrixCoordinationError.conflictingExperiment
        }
        if let value = record.payload["step_id"] {
            guard let raw = value.string, UUID(uuidString: raw) == arm.stepID else { throw MatrixCoordinationError.conflictingExperiment }
        }
    }
    private func optionalConfidence(_ value: JSONValue?) throws -> Double? {
        guard let value, value != .null else { return nil }
        let result: Double
        switch value {
        case .number(let number): result = number
        case .integer(let integer): result = Double(integer)
        default: throw MatrixCoordinationError.malformedRecord
        }
        guard result.isFinite, (0...1).contains(result) else { throw MatrixCoordinationError.malformedRecord }
        return result
    }
}
