import Foundation
import CoreFoundation

@MainActor public protocol Preferences {
    func object(forKey key: String) -> Any?
    func set(_ value: Any, forKey key: String)
    func removeObject(forKey key: String)
    /// Commits pending writes. In-memory adapters need no durable operation.
    func flush() throws
}

public extension Preferences {
    func flush() throws {}
}

public enum SettingsPersistenceError: Error, Equatable, LocalizedError {
    case saveFailed, rollbackFailed
    public var errorDescription: String? {
        switch self {
        case .saveFailed: return "Settings could not be saved. The previous settings were restored; retry saving."
        case .rollbackFailed: return "Settings storage could not be restored. Resolve the storage problem before restarting."
        }
    }
}

@MainActor public final class UserDefaultsPreferences: Preferences {
    public nonisolated static let applicationDomain = "org.harness.research"
    private let defaults: UserDefaults
    private let domain: String?
    /// Raw executables and the app bundle must share the same explicit identity.
    public init(domain: String = UserDefaultsPreferences.applicationDomain) {
        // Foundation rejects suiteName equal to the process's own bundle ID.
        // Its standard domain already has that exact identity in a bundled app.
        let adapter = domain == Bundle.main.bundleIdentifier ? UserDefaults.standard : UserDefaults(suiteName: domain)
        guard let defaults = adapter else {
            preconditionFailure("Cannot initialize preferences domain")
        }
        self.defaults = defaults; self.domain = domain
    }
    /// Explicit adapter injection preserves tests and callers with their own defaults.
    public init(_ defaults: UserDefaults) { self.defaults = defaults; domain = nil }
    public func object(forKey key: String) -> Any? {
        if let domain { return defaults.persistentDomain(forName: domain)?[key] }
        return defaults.object(forKey: key)
    }
    public func set(_ value: Any, forKey key: String) { defaults.set(value, forKey: key) }
    public func removeObject(forKey key: String) { defaults.removeObject(forKey: key) }
    public func flush() throws {
        guard defaults.synchronize() else { throw SettingsPersistenceError.saveFailed }
    }
}

@MainActor public final class SettingsStore {
    private let preferences: any Preferences
    public private(set) var settings = Settings()
    /// Diagnostics name fields only; raw stored values may contain private data.
    public private(set) var loadIssues: [String] = []

    public init(preferences: any Preferences) {
        self.preferences = preferences
        load()
    }

    public func save(_ candidate: Settings) throws {
        let validated = try candidate.validated()
        var values: [String: Any] = [
            "captureHotkey": validated.captureHotkey.functionKey,
            "dismissHotkey": validated.dismissHotkey.functionKey,
            "scrollUpHotkey": validated.scrollUpHotkey.functionKey,
            "scrollDownHotkey": validated.scrollDownHotkey.functionKey,
            "provider": validated.provider.rawValue,
            "model": validated.model,
            "overlayPosition": validated.overlayPosition.rawValue,
            "visibilityMode": validated.visibilityMode.rawValue,
            "captureSource": validated.captureSource.rawValue,
            "historyLength": validated.historyLength,
            "maxImageDimension": validated.maxImageDimension,
            "maxImageBytes": validated.maxImageBytes,
            "networkSubmissionEnabled": validated.networkSubmissionEnabled,
            "calibrationEnabled": validated.calibrationEnabled,
            "privacyMaskingEnabled": validated.privacyMaskingEnabled,
            "maskingRegions": validated.maskingRegions.map {
                ["x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height]
            }
        ]
        if let id = validated.selectedWindowID { values["selectedWindowID"] = Int64(id) }
        if let prompt = validated.systemPrompt { values["systemPrompt"] = prompt }
        let keys = Set(values.keys).union(["systemPrompt", "selectedWindowID", "toggleInteractivityHotkey", "idleDismissSeconds"])
        var previous: [String: Any] = [:]
        for key in keys { previous[key] = preferences.object(forKey: key) }
        write(values, keys: keys)
        do {
            try preferences.flush()
        } catch {
            // Restore only this store's keys, preserving unrelated preferences.
            write(previous, keys: keys)
            do { try preferences.flush() }
            catch { throw SettingsPersistenceError.rollbackFailed }
            throw SettingsPersistenceError.saveFailed
        }
        settings = validated
    }

    private func write(_ values: [String: Any], keys: Set<String>) {
        for key in keys {
            if let value = values[key] { preferences.set(value, forKey: key) }
            else { preferences.removeObject(forKey: key) }
        }
    }

    private func read<T>(_ key: String, parse: (Any) -> T?) -> T? {
        guard let raw = preferences.object(forKey: key) else { return nil }
        guard let result = parse(raw) else {
            loadIssues.append("Invalid preference: \(key)")
            return nil
        }
        return result
    }

    private static func number(_ raw: Any) -> NSNumber? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }

    private static func integer(_ raw: Any, range: ClosedRange<Int>) -> Int? {
        guard let n = number(raw), !["f", "d"].contains(String(cString: n.objCType)) else { return nil }
        let value = n.doubleValue
        guard value.isFinite, value >= Double(range.lowerBound), value <= Double(range.upperBound) else { return nil }
        return n.intValue
    }

    private static func boolean(_ raw: Any) -> Bool? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private func load() {
        if let n = read("captureHotkey", parse: { Self.integer($0, range: 1...20) }) { settings.captureHotkey = Shortcut(functionKey: n) }
        if let n = read("dismissHotkey", parse: { Self.integer($0, range: 1...20) }) { settings.dismissHotkey = Shortcut(functionKey: n) }
        if let n = read("scrollUpHotkey", parse: { Self.integer($0, range: 1...20) }) { settings.scrollUpHotkey = Shortcut(functionKey: n) }
        if let n = read("scrollDownHotkey", parse: { Self.integer($0, range: 1...20) }) { settings.scrollDownHotkey = Shortcut(functionKey: n) }
        sanitizeShortcutCollisions()
        if let value = read("provider", parse: { ($0 as? String).flatMap(Provider.init(rawValue:)) }) { settings.provider = value }
        if let value = read("model", parse: { raw -> String? in
            guard let s = raw as? String, Settings.validModel(s) else { return nil }; return s
        }) { settings.model = value }
        if let value = read("systemPrompt",parse: { raw -> String? in
            guard let text = raw as? String, Settings.validSystemPrompt(text) else { return nil }; return text
        }) { settings.systemPrompt = value }
        if let value = read("overlayPosition", parse: { ($0 as? String).flatMap(OverlayPosition.init(rawValue:)) }) { settings.overlayPosition = value }
        _ = read("visibilityMode", parse: { Self.integer($0, range: 0...2) })
        if let value = read("captureSource", parse: { ($0 as? String).flatMap(CaptureSource.init(rawValue:)) }) { settings.captureSource = value }
        if let value = read("historyLength", parse: { Self.integer($0, range: 0...10) }) { settings.historyLength = value }
        if let value = read("maxImageDimension", parse: { Self.integer($0, range: 64...1568) }) { settings.maxImageDimension = value }
        if let value = read("maxImageBytes", parse: { Self.integer($0, range: 10_000...1_000_000) }) { settings.maxImageBytes = value }
        if let value = read("networkSubmissionEnabled", parse: Self.boolean) { settings.networkSubmissionEnabled = value }
        if let value = read("calibrationEnabled", parse: Self.boolean) { settings.calibrationEnabled = value }
        if let value = read("privacyMaskingEnabled", parse: Self.boolean) { settings.privacyMaskingEnabled = value }
        if let value = read("selectedWindowID", parse: { Self.integer($0, range: 1...Int(UInt32.max)) }) { settings.selectedWindowID = UInt32(value) }
        if let value = read("maskingRegions", parse: Self.masks) { settings.maskingRegions = value }
    }

    private static func masks(_ raw: Any) -> [MaskRegion]? {
        guard let array = raw as? [[String: Any]], array.count <= 32 else { return nil }
        var result: [MaskRegion] = []
        for dict in array {
            guard Set(dict.keys) == Set(["x", "y", "width", "height"]),
                  let x = dict["x"].flatMap(number)?.doubleValue,
                  let y = dict["y"].flatMap(number)?.doubleValue,
                  let width = dict["width"].flatMap(number)?.doubleValue,
                  let height = dict["height"].flatMap(number)?.doubleValue else { return nil }
            let region = MaskRegion(x: x, y: y, width: width, height: height)
            guard region.isValid else { return nil }
            result.append(region)
        }
        return result
    }

    private func sanitizeShortcutCollisions() {
        var values = [settings.captureHotkey, settings.dismissHotkey, settings.scrollUpHotkey, settings.scrollDownHotkey]
        let defaults = [Shortcut(functionKey: 8), Shortcut(functionKey: 9), Shortcut(functionKey: 10), Shortcut(functionKey: 11)]
        let names = ["captureHotkey", "dismissHotkey", "scrollUpHotkey", "scrollDownHotkey"]
        for _ in 0..<4 {
            let duplicateIndices = values.indices.filter { i in values.indices.contains { $0 != i && values[$0] == values[i] } }
            guard !duplicateIndices.isEmpty else { break }
            for i in duplicateIndices {
                values[i] = defaults[i]
                let issue = "Duplicate shortcut preference: \(names[i])"
                if !loadIssues.contains(issue) { loadIssues.append(issue) }
            }
        }
        settings.captureHotkey = values[0]
        settings.dismissHotkey = values[1]
        settings.scrollUpHotkey = values[2]
        settings.scrollDownHotkey = values[3]
    }
}
