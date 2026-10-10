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
}

public enum Provider: String, Codable, CaseIterable, Sendable {
    case chatgpt = "ChatGPT plan"
}

public struct Shortcut: Codable, Equatable, Hashable, Sendable {
    public var functionKey: Int
    public init(functionKey: Int) { self.functionKey = functionKey }
    public var label: String { "F\(functionKey)" }
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
    public var systemPrompt: String?
    public var effectiveSystemPrompt: String { systemPrompt ?? Self.defaultSystemPrompt }
    public var captureHotkey = Shortcut(functionKey: 8)
    public var dismissHotkey = Shortcut(functionKey: 9)
    public var scrollUpHotkey = Shortcut(functionKey: 10)
    public var scrollDownHotkey = Shortcut(functionKey: 11)
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

    /// Validates configuration; operational capture validation requires a live selected window.
    @discardableResult public func validated() throws -> Settings {
        let shortcuts = [captureHotkey, dismissHotkey, scrollUpHotkey, scrollDownHotkey]
        for (key, shortcut) in zip(["captureHotkey", "dismissHotkey", "scrollUpHotkey", "scrollDownHotkey"], shortcuts) {
            guard (1...20).contains(shortcut.functionKey) else { throw SettingsValidationError.invalidField(key) }
        }
        guard Set(shortcuts).count == 4 else { throw SettingsValidationError.duplicateHotkeys }
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
