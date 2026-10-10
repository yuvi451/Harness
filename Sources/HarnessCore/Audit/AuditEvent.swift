import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), integer(Int), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String:JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): guard v.isFinite else { throw AuditError.schema }; try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var int: Int? { if case .integer(let v) = self { return v }; return nil }
    public var boolean: Bool? { if case .bool(let v) = self { return v }; return nil }
}
public enum AuditEventName: String, Codable, Sendable, CaseIterable {
    case appLaunch = "app_launch", settingsChanged = "settings_changed", modeChanged = "mode_changed"
    case hotkeyRegistered = "hotkey_registered", hotkeyRegistrationFailed = "hotkey_registration_failed"
    case captureStarted = "capture_started", captureCompleted = "capture_completed", captureFailed = "capture_failed"
    case calibrationCompleted = "calibration_completed", llmRequest = "llm_request", llmCompleted = "llm_completed", llmFailed = "llm_failed"
    case overlayShown = "overlay_shown", overlayDismissed = "overlay_dismissed", detectorScan = "detector_scan"
    case permissionStatus = "permission_status", capabilityCheck = "capability_check", matrixStepCompleted = "matrix_step_completed", experimentFailed = "experiment_failed"
}
public struct AuditEvent: Codable, Equatable, Sendable {
    public let name: AuditEventName
    public let payload: [String: JSONValue]
    public init(_ name: AuditEventName, payload: [String: JSONValue]) { self.name = name; self.payload = payload }
    public func validate() throws {
        let required: [String: String]
        switch name {
        case .modeChanged: required = ["from":"mode", "to":"mode"]
        case .captureStarted: required = ["source":"source", "display_id":"int"]
        case .captureCompleted: required = ["bytes":"positive", "width":"positive", "height":"positive", "sha256":"hash", "overlay_in_capture":"nullableBool", "calibration_status":"string", "calibration_reason":"string"]
        case .llmRequest: required = ["provider":"string", "model":"string", "prompt_chars":"int"]
        case .llmCompleted: required = ["stop_reason":"string", "out_chars":"int", "latency_ms":"numeric"]
        case .overlayShown: required = ["x":"numeric", "y":"numeric", "w":"numeric", "h":"numeric"]
        case .overlayDismissed: required = ["reason":"dismiss"]
        case .detectorScan: required = ["n_windows":"int", "n_flagged":"int"]
        default: required = [:]
        }
        let extras: Set<String> = ["status", "reason", "code", "source", "capture_id", "window_id", "owner_pid", "scan_id", "step_id", "configuration_id", "latency_ms", "confidence", "calibration_status", "calibration_reason", "overlay_visibility", "changed_keys", "network_enabled", "consent", "scope", "shortcut", "action", "requested", "observed", "sharing", "level", "collection_behavior", "capability", "permission", "app_version", "environment", "load_issues", "monotonic_ns", "configuration_changed_ns", "bytes", "display_id", "supported_models", "browser", "browser_version", "message", "mask_count"]
        guard payload.count <= 40, Set(payload.keys).isSubset(of: Set(required.keys).union(extras)) else { throw AuditError.schema }
        for (key, type) in required {
            guard let value = payload[key] else { throw AuditError.schema }
            switch type {
            case "string": guard value.string != nil else { throw AuditError.schema }
            case "mode": guard let n = value.int, (0...2).contains(n) else { throw AuditError.schema }
            case "source": guard let s = value.string, ["sck_full", "sck_excluding_self", "sck_selected_window"].contains(s) else { throw AuditError.schema }
            case "hash": guard let s = value.string, s.count == 64, s.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw AuditError.schema }
            case "int", "positive": guard let n = value.int, n >= (type == "positive" ? 1 : 0) else { throw AuditError.schema }
            case "numeric": guard value.int != nil || { if case .number(let n) = value { return n.isFinite }; return false }() else { throw AuditError.schema }
            case "nullableBool": guard value == .null || value.boolean != nil else { throw AuditError.schema }
            case "dismiss": guard let s = value.string, ["hotkey", "timeout", "recapture", "account_disconnect"].contains(s) else { throw AuditError.schema }
            default: throw AuditError.schema
            }
        }
        func bounded(_ value: JSONValue, depth: Int = 0) -> Bool {
            guard depth < 5 else { return false }
            switch value {
            case .string(let s): return s.utf8.count <= 2048 && !s.contains("sk-ant-") && !s.lowercased().contains("bearer ") && !s.contains("data:image")
            case .number(let n): return n.isFinite
            case .array(let a): return a.count <= 100 && a.allSatisfy { bounded($0, depth: depth + 1) }
            case .object(let o): return o.count <= 40 && o.allSatisfy { !["api_key","authorization","image","base64","prompt","response","title"].contains($0.key.lowercased()) && bounded($0.value, depth: depth + 1) }
            default: return true
            }
        }
        guard payload.values.allSatisfy({ bounded($0) }) else { throw AuditError.schema }
    }
}
public enum AuditError: Error, LocalizedError {
    case schema, io(Int32), incompleteTail, unsafeFile, latchedFailure, recordTooLarge
    public var errorDescription: String? { switch self {
    case .io(let code): return "Audit I/O failure (errno \(code)); sensitive actions blocked."
    default: return "Audit validation/storage failure; sensitive actions blocked."
    } }
}
public struct AuditRecord: Codable, Sendable {
    public let schemaVersion: Int
    public let ts: String
    public let event: AuditEventName
    public let mode: Int
    public let macos: String
    public let sessionID, eventID: UUID
    public let experimentID: UUID?
    public let sequence: Int
    public let payload: [String:JSONValue]
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version", ts, event, mode, macos
        case sessionID = "session_id", eventID = "event_id", experimentID = "experiment_id", sequence, payload
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(ts, forKey: .ts)
        try c.encode(event, forKey: .event); try c.encode(mode, forKey: .mode); try c.encode(macos, forKey: .macos)
        try c.encode(sessionID, forKey: .sessionID); try c.encode(eventID, forKey: .eventID)
        if let experimentID { try c.encode(experimentID, forKey: .experimentID) } else { try c.encodeNil(forKey: .experimentID) }
        try c.encode(sequence, forKey: .sequence); try c.encode(payload, forKey: .payload)
    }
    public static func decode(_ data: Data) throws -> AuditRecord {
        guard data.count <= 65_536, let object = try JSONSerialization.jsonObject(with: data) as? [String:Any],
              Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)) else { throw AuditError.schema }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schemaVersion == 1, (0...2).contains(result.mode), result.sequence > 0,
              result.ts.count == 24, timestampFormatter().date(from: result.ts) != nil else { throw AuditError.schema }
        try AuditEvent(result.event, payload: result.payload).validate()
        return result
    }
    static func timestampFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }
}
