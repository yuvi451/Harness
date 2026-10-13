import Foundation

public enum VisibilityMode: Int, Codable, CaseIterable, Sendable {
    case open = 0, legacySharingProbe = 1, spaceBehaviorProbe = 2

    public var badge: String {
        switch self {
        case .open: return "MODE 0 · OPEN"
        case .legacySharingProbe: return "MODE 1 · LEGACY-SHARING-PROBE"
        case .spaceBehaviorProbe: return "MODE 2 · COMBINED-EXCLUSION-PROBE"
        }
    }
}

public enum CaptureSource: String, Codable, CaseIterable, Sendable {
    case full = "sck_full"
    case excludingSelf = "sck_excluding_self"
    case selectedWindow = "sck_selected_window"
}

public enum OverlayPosition: String, Codable, CaseIterable, Sendable {
    case nearCursor, pinnedCorner
    public var displayName:String {
        switch self {
        case .nearCursor: return "Automatic pane / cursor"
        case .pinnedCorner: return "Bottom left (small)"
        }
    }
}

public enum Provider: String, Codable, CaseIterable, Sendable {
    case chatgpt = "ChatGPT plan"
}

public struct Shortcut: Codable, Equatable, Hashable, Sendable {
    public var digit: Int
    public init(digit: Int) { self.digit = digit }
    public var label: String { "⌥⇧\(digit)" }
}

/// Rectangle in normalized image coordinates, with its origin at the top-left.
public struct MaskRegion: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) &&
        x >= 0 && y >= 0 && width > 0 && height > 0 &&
        x + width <= 1 && y + height <= 1
    }
}

public enum SettingsValidationError: Error, Equatable, Sendable {
    case invalidField(String)
    case duplicateHotkeys
}

public struct Settings: Codable, Equatable, Sendable {
    public static let defaultSystemPrompt = "Return only the final answer in plain text. No introduction, title, explanation, Markdown or code fences. For coding questions, return only the required code without comments. Use a straightforward college-student style: basic language features, simple loops, standard data structures and short, familiar variable names. Prefer direct solutions over unnecessary helper classes, abstraction layers or clever one-liners. Keep the solution correct and efficient enough for the stated constraints, and preserve the required language, function signature and input/output format."
    /// Nil follows the bundled default, including after an upgrade.
    public static let visibilityHotkey = Shortcut(digit:0)
    public static let overlayModeHotkey = Shortcut(digit:1)
    public var shortcutSchemaVersion = 1
    public var systemPrompt: String?
    public var effectiveSystemPrompt: String { systemPrompt ?? Self.defaultSystemPrompt }
    public var captureHotkey = Shortcut(digit: 8)
    public var dismissHotkey = Shortcut(digit: 9)
    public var scrollUpHotkey = Shortcut(digit: 7)
    public var scrollDownHotkey = Shortcut(digit: 6)
    public var queueCaptureHotkey = Shortcut(digit: 5)
    public var adaptiveTypographyEnabled = false
    public var provider: Provider = .chatgpt
    public var model = "gpt-6.1-sol"
    public var overlayPosition: OverlayPosition = .nearCursor
    public var visibilityMode: VisibilityMode = .spaceBehaviorProbe
    public var captureSource: CaptureSource = .excludingSelf
    public var historyLength = 10
    public var maxImageDimension = 1568
    public var maxImageBytes = 1_000_000
    public var networkSubmissionEnabled = true
    public var calibrationEnabled = false
    public var privacyMaskingEnabled = false
    public var selectedWindowID: UInt32?
    public var maskingRegions: [MaskRegion] = []

    public init() {}

    enum CodingKeys:String,CodingKey {
        case shortcutSchemaVersion,systemPrompt,captureHotkey,dismissHotkey,scrollUpHotkey,scrollDownHotkey,queueCaptureHotkey,adaptiveTypographyEnabled
        case provider,model,overlayPosition,visibilityMode,captureSource,historyLength,maxImageDimension,maxImageBytes
        case networkSubmissionEnabled,calibrationEnabled,privacyMaskingEnabled,selectedWindowID,maskingRegions
    }
    public init(from decoder:Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy:CodingKeys.self)
        systemPrompt = try values.decodeIfPresent(String.self,forKey:.systemPrompt)
        let version = try values.decodeIfPresent(Int.self,forKey:.shortcutSchemaVersion) ?? 0
        guard (0...1).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey:.shortcutSchemaVersion,in:values,debugDescription:"Unsupported shortcut schema")
        }
        if version == 1 {
            captureHotkey = try values.decodeIfPresent(Shortcut.self,forKey:.captureHotkey) ?? captureHotkey
            dismissHotkey = try values.decodeIfPresent(Shortcut.self,forKey:.dismissHotkey) ?? dismissHotkey
            scrollUpHotkey = try values.decodeIfPresent(Shortcut.self,forKey:.scrollUpHotkey) ?? scrollUpHotkey
            scrollDownHotkey = try values.decodeIfPresent(Shortcut.self,forKey:.scrollDownHotkey) ?? scrollDownHotkey
            queueCaptureHotkey = try values.decodeIfPresent(Shortcut.self,forKey:.queueCaptureHotkey) ?? queueCaptureHotkey
        } else {
            let legacy = try [CodingKeys.captureHotkey,.scrollUpHotkey,.scrollDownHotkey,.queueCaptureHotkey].map {
                try values.decodeIfPresent(LegacyShortcut.self,forKey:$0)?.number
            }
            applyShortcutDigits(Self.repairedShortcutDigits(legacy))
        }
        adaptiveTypographyEnabled = try values.decodeIfPresent(Bool.self,forKey:.adaptiveTypographyEnabled) ?? false
        provider = try values.decodeIfPresent(Provider.self,forKey:.provider) ?? provider
        model = try values.decodeIfPresent(String.self,forKey:.model) ?? model
        if let raw = try values.decodeIfPresent(String.self,forKey:.overlayPosition) {
            overlayPosition = OverlayPosition(rawValue:raw) ?? .nearCursor
        }
        visibilityMode = try values.decodeIfPresent(VisibilityMode.self,forKey:.visibilityMode) ?? visibilityMode
        captureSource = try values.decodeIfPresent(CaptureSource.self,forKey:.captureSource) ?? captureSource
        historyLength = try values.decodeIfPresent(Int.self,forKey:.historyLength) ?? historyLength
        maxImageDimension = try values.decodeIfPresent(Int.self,forKey:.maxImageDimension) ?? maxImageDimension
        maxImageBytes = try values.decodeIfPresent(Int.self,forKey:.maxImageBytes) ?? maxImageBytes
        networkSubmissionEnabled = try values.decodeIfPresent(Bool.self,forKey:.networkSubmissionEnabled) ?? networkSubmissionEnabled
        calibrationEnabled = try values.decodeIfPresent(Bool.self,forKey:.calibrationEnabled) ?? calibrationEnabled
        privacyMaskingEnabled = try values.decodeIfPresent(Bool.self,forKey:.privacyMaskingEnabled) ?? privacyMaskingEnabled
        selectedWindowID = try values.decodeIfPresent(UInt32.self,forKey:.selectedWindowID)
        maskingRegions = try values.decodeIfPresent([MaskRegion].self,forKey:.maskingRegions) ?? []
    }

    /// Validates configuration; operational capture validation requires a live selected window.
    @discardableResult public func validated() throws -> Settings {
        guard shortcutSchemaVersion == 1 else { throw SettingsValidationError.invalidField("shortcutSchemaVersion") }
        guard dismissHotkey.digit == 9 else { throw SettingsValidationError.invalidField("dismissHotkey") }
        let shortcuts = [captureHotkey, dismissHotkey, scrollUpHotkey, scrollDownHotkey, queueCaptureHotkey]
        for (key, shortcut) in zip(["captureHotkey", "dismissHotkey", "scrollUpHotkey", "scrollDownHotkey", "queueCaptureHotkey"], shortcuts) {
            guard (0...9).contains(shortcut.digit) else { throw SettingsValidationError.invalidField(key) }
        }
        guard Set(shortcuts + [Self.visibilityHotkey,Self.overlayModeHotkey]).count == 7 else { throw SettingsValidationError.duplicateHotkeys }
        guard Self.validModel(model) else { throw SettingsValidationError.invalidField("model") }
        if let systemPrompt, !Self.validSystemPrompt(systemPrompt) { throw SettingsValidationError.invalidField("systemPrompt") }
        guard (0...10).contains(historyLength) else { throw SettingsValidationError.invalidField("historyLength") }
        guard (64...1568).contains(maxImageDimension) else { throw SettingsValidationError.invalidField("maxImageDimension") }
        guard (10_000...1_000_000).contains(maxImageBytes) else { throw SettingsValidationError.invalidField("maxImageBytes") }
        guard selectedWindowID != 0 else { throw SettingsValidationError.invalidField("selectedWindowID") }
        guard maskingRegions.count <= 32, maskingRegions.allSatisfy(\.isValid) else {
            throw SettingsValidationError.invalidField("maskingRegions")
        }
        return self
    }

    /// Keep usable legacy numbers; repair obsolete or reserved bindings as a group.
    static func repairedShortcutDigits(_ requested:[Int?]) -> [Int] {
        let defaults = [8,7,6,5]
        var result = [Int?](repeating:nil,count:4),used:Set<Int> = [0,1,9]
        for i in 0..<4 {
            if let n = requested[i],(2...8).contains(n),used.insert(n).inserted { result[i] = n }
        }
        for i in 0..<4 where result[i] == nil {
            let n = ([defaults[i]] + Array(2...8)).first { !used.contains($0) }!
            result[i] = n;used.insert(n)
        }
        return result.map { $0! }
    }
    mutating func applyShortcutDigits(_ numbers:[Int]) {
        captureHotkey = .init(digit:numbers[0]);scrollUpHotkey = .init(digit:numbers[1])
        scrollDownHotkey = .init(digit:numbers[2]);queueCaptureHotkey = .init(digit:numbers[3])
        dismissHotkey = .init(digit:9)
    }
    private struct LegacyShortcut:Decodable {
        let number:Int
        private enum Keys:String,CodingKey { case number = "functionKey" }
        init(from decoder:Decoder) throws {
            number = try decoder.container(keyedBy:Keys.self).decode(Int.self,forKey:.number)
        }
    }

    static func validModel(_ model: String) -> Bool {
        !model.isEmpty && model.utf8.count <= 128 && model.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0)
        }
    }
    public static func validSystemPrompt(_ prompt: String) -> Bool {
        prompt.utf8.count <= 64_000 && prompt.count <= 16_000 &&
        !prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty &&
        !prompt.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && ![9,10,13].contains($0.value) }
    }
}
