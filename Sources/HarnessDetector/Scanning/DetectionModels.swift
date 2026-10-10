import Foundation
import HarnessCore

public enum DetectorQueryStatus: String, Codable, Sendable { case success, permissionDenied = "permission_denied", failed, unsupported, notQueried = "not_queried" }
public enum ObservationClassification: String, Codable, Sendable {
    case observedShareable = "observed_shareable", observedNotShareable = "observed_not_shareable"
    case legacyNonsharingSignal = "legacy_nonsharing_signal", metadataIncomplete = "metadata_incomplete", unsupported, unknown
}
public enum IndependentTruthMethod: String, Codable, Sendable {
    case manualObservation = "manual_observation", controlledFixture = "controlled_fixture", independentExternalMeasurement = "independent_external_measurement"
}
public struct IndependentTruth: Codable, Equatable, Sendable {
    public let value: Bool
    public let method: IndependentTruthMethod
    public init(value: Bool, method: IndependentTruthMethod) { self.value = value; self.method = method }
}
public struct ScanContext: Codable, Equatable, Sendable {
    public let emitterSessionID: UUID
    public let experimentID: UUID?
    public let stepID: UUID?
    public let captureID: UUID
    public let targetWindowID: Int
    public let ownerPID: Int
    public let mode: VisibilityMode
    public let source: CaptureSource
    public let independentTruth: IndependentTruth?
    public let browser: String
    public let browserVersion: String
    public let captureMonotonicNS: Int?
    public let clockDomainID: String?
    public init(emitterSessionID: UUID, experimentID: UUID?, stepID: UUID?, captureID: UUID,
                targetWindowID: Int, ownerPID: Int, mode: VisibilityMode, source: CaptureSource,
                independentTruth: IndependentTruth? = nil, browser: String = "not_recorded", browserVersion: String = "not_recorded",
                captureMonotonicNS: Int? = nil, clockDomainID: String? = nil) {
        self.emitterSessionID = emitterSessionID; self.experimentID = experimentID; self.stepID = stepID; self.captureID = captureID
        self.targetWindowID = targetWindowID; self.ownerPID = ownerPID; self.mode = mode; self.source = source
        self.independentTruth = independentTruth; self.browser = browser; self.browserVersion = browserVersion
        self.captureMonotonicNS = captureMonotonicNS; self.clockDomainID = clockDomainID
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case emitterSessionID = "emitter_session_id", experimentID = "experiment_id", stepID = "step_id", captureID = "capture_id"
        case targetWindowID = "target_window_id", ownerPID = "owner_pid", mode, source, independentTruth = "independent_truth", browser
        case browserVersion = "browser_version", captureMonotonicNS = "capture_monotonic_ns", clockDomainID = "clock_domain_id"
    }
    func validate() throws {
        guard targetWindowID > 0, targetWindowID <= Int(UInt32.max), ownerPID > 0, ownerPID <= Int(Int32.max),
              safeMetadata(browser), safeMetadata(browserVersion), captureMonotonicNS.map({ $0 >= 0 }) ?? true,
              clockDomainID.map({ safeMetadata($0) }) ?? true else { throw DetectionSchemaError.invalid }
    }
}
public struct ObservationBounds: Codable, Equatable, Sendable {
    public let x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var isValid: Bool { [x,y,width,height].allSatisfy { $0.isFinite && abs($0) <= 1_000_000_000 } && width > 0 && height > 0 }
}
public struct WindowMetadata: Sendable {
    public let windowID: Int?, ownerPID: Int?, layer: Int?, sharingState: Int?
    public let ownerName: String?
    public let bounds: ObservationBounds?
    public let displayIDs: [UInt32]
    public init(windowID: Int?, ownerPID: Int?, ownerName: String?, bounds: ObservationBounds?, layer: Int?, sharingState: Int?, displayIDs: [UInt32] = []) {
        self.windowID = windowID; self.ownerPID = ownerPID; self.ownerName = ownerName; self.bounds = bounds
        self.layer = layer; self.sharingState = sharingState; self.displayIDs = displayIDs
    }
}
public struct ShareableWindowIdentity: Sendable {
    public let windowID: Int
    public let ownerPID: Int?
    public init(windowID: Int, ownerPID: Int?) { self.windowID = windowID; self.ownerPID = ownerPID }
}
public struct WindowObservation: Codable, Equatable, Sendable {
    public let windowID: Int?, ownerPID: Int?, layer: Int?, sharingState: Int?
    public let ownerName: String?
    public let bounds: ObservationBounds?
    public let sckEnumerated: Bool?
    public let classifications: [ObservationClassification]
    public let confidence: Double
    public let systemOwner: Bool
    public let displayIDs: [UInt32]
    public let spaceStatus: String
    public let errors: [String]
    public init(windowID: Int?, ownerPID: Int?, ownerName: String?, bounds: ObservationBounds?, layer: Int?, sharingState: Int?,
                sckEnumerated: Bool?, classifications: [ObservationClassification], confidence: Double,
                systemOwner: Bool, displayIDs: [UInt32] = [], spaceStatus: String = "unsupported", errors: [String] = []) {
        self.windowID = windowID; self.ownerPID = ownerPID; self.ownerName = ownerName; self.bounds = bounds; self.layer = layer
        self.sharingState = sharingState; self.sckEnumerated = sckEnumerated; self.classifications = classifications
        self.confidence = confidence; self.systemOwner = systemOwner; self.displayIDs = displayIDs; self.spaceStatus = spaceStatus; self.errors = errors
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case windowID = "window_id", ownerPID = "owner_pid", ownerName = "owner_name", bounds, layer, sharingState = "sharing_state"
        case sckEnumerated = "sck_enumerated", classifications, confidence, systemOwner = "system_owner", displayIDs = "display_ids", spaceStatus = "space_status", errors
    }
    func validate() throws {
        guard windowID.map({ $0 > 0 && $0 <= Int(UInt32.max) }) ?? true,
              ownerPID.map({ $0 > 0 && $0 <= Int(Int32.max) }) ?? true,
              ownerName.map({ safeMetadata($0) }) ?? true, bounds.map(\.isValid) ?? true,
              layer.map({ (-1_000_000...1_000_000).contains($0) }) ?? true,
              sharingState.map({ (0...2).contains($0) }) ?? true,
              !classifications.isEmpty, classifications.count <= 6, Set(classifications.map(\.rawValue)).count == classifications.count,
              confidence.isFinite, (0...1).contains(confidence), displayIDs.count <= 64,
              spaceStatus == "unsupported", errors.count <= 32, errors.allSatisfy({ safeMetadata($0) }) else { throw DetectionSchemaError.invalid }
    }
}
public enum DetectionRecordKind: String, Codable, Sendable { case scanSummary = "scan_summary", window }
public enum DetectionSchemaError: Error { case invalid, unsupportedVersion, tooLarge }

public struct DetectionRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let recordID, scanID, detectorSessionID: UUID
    public let kind: DetectionRecordKind
    public let ts: String
    public let monotonicNS: Int?
    public let clockDomainID: String?
    public let context: ScanContext?
    public let cgStatus, sckStatus: DetectorQueryStatus
    public let windowCount, flaggedCount: Int
    public let truncated: Bool
    public let latencyMS: Double
    public let sckTS: String?
    public let cgLatencyMS, sckLatencyMS: Double?
    public let observation: WindowObservation?
    public let errors: [String]
    public let cgFilters, sckFilters: [String]
    public init(schemaVersion: Int = 1, recordID: UUID = UUID(), scanID: UUID, detectorSessionID: UUID,
                kind: DetectionRecordKind, ts: String, monotonicNS: Int? = nil, clockDomainID: String? = nil,
                context: ScanContext? = nil, cgStatus: DetectorQueryStatus, sckStatus: DetectorQueryStatus,
                windowCount: Int, flaggedCount: Int, truncated: Bool = false, latencyMS: Double = 0,
                observation: WindowObservation? = nil, errors: [String] = [],
                cgFilters: [String] = ["on_screen_only", "exclude_desktop_elements"],
                sckFilters: [String] = ["on_screen_only", "include_desktop_windows"],
                sckTS: String? = nil, cgLatencyMS: Double? = nil, sckLatencyMS: Double? = nil) {
        self.schemaVersion = schemaVersion; self.recordID = recordID; self.scanID = scanID; self.detectorSessionID = detectorSessionID
        self.kind = kind; self.ts = ts; self.monotonicNS = monotonicNS; self.clockDomainID = clockDomainID; self.context = context
        self.cgStatus = cgStatus; self.sckStatus = sckStatus; self.windowCount = windowCount; self.flaggedCount = flaggedCount
        self.truncated = truncated; self.latencyMS = latencyMS; self.observation = observation; self.errors = errors
        self.cgFilters = cgFilters; self.sckFilters = sckFilters
        self.sckTS = sckTS; self.cgLatencyMS = cgLatencyMS; self.sckLatencyMS = sckLatencyMS
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version", recordID = "record_id", scanID = "scan_id", detectorSessionID = "detector_session_id", kind, ts
        case monotonicNS = "monotonic_ns", clockDomainID = "clock_domain_id", context, cgStatus = "cg_status", sckStatus = "sck_status"
        case windowCount = "window_count", flaggedCount = "flagged_count", truncated, latencyMS = "latency_ms", observation, errors
        case cgFilters = "cg_filters", sckFilters = "sck_filters"
        case sckTS = "sck_ts", cgLatencyMS = "cg_latency_ms", sckLatencyMS = "sck_latency_ms"
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw DetectionSchemaError.unsupportedVersion }
        guard parseTimestamp(ts) != nil, windowCount >= 0, windowCount <= 4096, flaggedCount >= 0, flaggedCount <= windowCount,
              monotonicNS.map({ $0 >= 0 }) ?? true, clockDomainID.map({ safeMetadata($0) }) ?? true,
              latencyMS.isFinite, latencyMS >= 0, latencyMS <= 86_400_000,
              sckTS.map({ parseTimestamp($0) != nil }) ?? true,
              cgLatencyMS.map({ $0.isFinite && (0...86_400_000).contains($0) }) ?? true,
              sckLatencyMS.map({ $0.isFinite && (0...86_400_000).contains($0) }) ?? true,
              errors.count <= 32, errors.allSatisfy({ safeMetadata($0) }),
              cgFilters == ["on_screen_only", "exclude_desktop_elements"],
              sckFilters == ["on_screen_only", "include_desktop_windows"],
              (kind == .window) == (observation != nil) else { throw DetectionSchemaError.invalid }
        try context?.validate(); try observation?.validate()
    }
    public func encodeLine() throws -> Data {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        guard data.count + 1 <= 16_384 else { throw DetectionSchemaError.tooLarge }
        _ = try Self.decode(data); data.append(10); return data
    }
    public static func decode(_ data: Data) throws -> DetectionRecord {
        guard data.count <= 16_384, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DetectionSchemaError.invalid }
        if let version = object["schema_version"] as? Int, version != 1 { throw DetectionSchemaError.unsupportedVersion }
        try checkKeys(object, allowed: CodingKeys.allCases.map(\.rawValue), required: ["schema_version","record_id","scan_id","detector_session_id","kind","ts","cg_status","sck_status","window_count","flagged_count","truncated","latency_ms","errors","cg_filters","sck_filters"])
        if let context = object["context"] as? [String: Any] {
            try checkKeys(context, allowed: ScanContext.CodingKeys.allCases.map(\.rawValue), required: ["emitter_session_id","capture_id","target_window_id","owner_pid","mode","source","browser","browser_version"])
            if let truth = context["independent_truth"] as? [String: Any] { try checkKeys(truth, allowed: ["value","method"], required: ["value","method"]) }
        }
        if let observation = object["observation"] as? [String: Any] {
            try checkKeys(observation, allowed: WindowObservation.CodingKeys.allCases.map(\.rawValue), required: ["classifications","confidence","system_owner","display_ids","space_status","errors"])
            if let bounds = observation["bounds"] as? [String: Any] { try checkKeys(bounds, allowed: ["x","y","width","height"], required: ["x","y","width","height"]) }
        }
        let result = try JSONDecoder().decode(Self.self, from: data); try result.validate(); return result
    }
}

public struct DetectorScan: Sendable {
    public let scanID, detectorSessionID: UUID
    public let ts: String
    public let monotonicNS: Int?
    public let clockDomainID: String?
    public let context: ScanContext?
    public let cgStatus, sckStatus: DetectorQueryStatus
    public let observations: [WindowObservation]
    public let truncated: Bool
    public let latencyMS: Double
    public let sckTS: String?
    public let cgLatencyMS, sckLatencyMS: Double?
    public let errors: [String]
    public let records: [DetectionRecord]
    public var flaggedCount: Int { observations.filter { $0.classifications.contains(where: { [.legacyNonsharingSignal,.metadataIncomplete,.unknown,.unsupported].contains($0) }) }.count }
    public init(scanID: UUID = UUID(), detectorSessionID: UUID, ts: String, monotonicNS: Int? = nil, clockDomainID: String? = nil,
                context: ScanContext? = nil, cgStatus: DetectorQueryStatus, sckStatus: DetectorQueryStatus,
                observations: [WindowObservation], truncated: Bool = false, latencyMS: Double = 0, errors: [String] = [],
                sckTS: String? = nil, cgLatencyMS: Double? = nil, sckLatencyMS: Double? = nil) {
        self.scanID = scanID; self.detectorSessionID = detectorSessionID; self.ts = ts; self.monotonicNS = monotonicNS
        self.clockDomainID = clockDomainID; self.context = context; self.cgStatus = cgStatus; self.sckStatus = sckStatus
        self.observations = observations; self.truncated = truncated; self.latencyMS = latencyMS; self.errors = errors
        self.sckTS = sckTS; self.cgLatencyMS = cgLatencyMS; self.sckLatencyMS = sckLatencyMS
        let flagged = observations.filter { $0.classifications.contains(where: { [.legacyNonsharingSignal,.metadataIncomplete,.unknown,.unsupported].contains($0) }) }.count
        func record(_ observation: WindowObservation?) -> DetectionRecord {
            DetectionRecord(scanID: scanID, detectorSessionID: detectorSessionID, kind: observation == nil ? .scanSummary : .window,
                ts: ts, monotonicNS: monotonicNS, clockDomainID: clockDomainID, context: context, cgStatus: cgStatus, sckStatus: sckStatus,
                windowCount: observations.count, flaggedCount: flagged, truncated: truncated, latencyMS: latencyMS, observation: observation, errors: errors,
                sckTS: sckTS, cgLatencyMS: cgLatencyMS, sckLatencyMS: sckLatencyMS)
        }
        records = [record(nil)] + observations.map { record($0) }
    }
}

func safeMetadata(_ value: String) -> Bool {
    value.utf8.count <= 256 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
    !value.lowercased().contains("bearer ") && !value.contains("sk-") && !value.contains("data:image")
}
func parseTimestamp(_ value: String) -> Date? {
    guard value.count == 24 else { return nil }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}
func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter.string(from: date)
}
private func checkKeys(_ object: [String: Any], allowed: [String], required: [String]) throws {
    let keys = Set(object.keys)
    guard keys.isSubset(of: Set(allowed)), Set(required).isSubset(of: keys) else { throw DetectionSchemaError.invalid }
}
