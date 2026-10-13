import AppKit
import CoreText

/// A local screenshot estimate; no OCR text or font samples are persisted or transmitted.
public struct AdaptiveTypography: Sendable, Equatable {
    public let fontName: String
    public let pointSize: Double
    public let confidence: Double
    public init(fontName:String,pointSize:Double,confidence:Double) {
        self.fontName = fontName; self.pointSize = pointSize; self.confidence = confidence
    }
    @MainActor var font: NSFont? {
        guard pointSize.isFinite, (8...28).contains(pointSize), confidence.isFinite,
              (0.62...1).contains(confidence), fontName.utf8.count <= 128 else { return nil }
        return NSFont(name:fontName,size:pointSize)
    }
}

enum OverlayFontSelection {
    @MainActor static func font(adaptive:AdaptiveTypography?,enabled:Bool,fallbackPlacement:Bool) -> NSFont {
        if fallbackPlacement {
            return NSFont(descriptor:OverlayTypography.font.fontDescriptor,size:9) ?? .systemFont(ofSize:9)
        }
        if enabled, let font = adaptive?.font { return font }
        return OverlayTypography.font
    }
}
