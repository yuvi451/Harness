import AppKit
import CoreText

public enum OverlayStyle: Sendable, Equatable {
    case dark, light
    case sampled(red: UInt8, green: UInt8, blue: UInt8)
    public static let fallback = OverlayStyle.dark
    @MainActor var background: NSColor {
        switch self {
        case .dark: return .black
        case .light: return .white
        case let .sampled(r,g,b): return NSColor(srgbRed:CGFloat(r)/255,green:CGFloat(g)/255,blue:CGFloat(b)/255,alpha:1)
        }
    }
    @MainActor var foreground: NSColor {
        switch self {
        case .dark: return .white
        case .light: return .black
        case let .sampled(r,g,b): return Int(r)*2126 + Int(g)*7152 + Int(b)*722 > 127*10000 ? .black : .white
        }
    }
    @MainActor var font: NSFont { OverlayTypography.font }
}

enum OverlayTypography {
    static let features: [[NSFontDescriptor.FeatureKey:Int]] = [[
        .typeIdentifier:kStylisticAlternativesType, .selectorIdentifier:kStylisticAltThreeOnSelector
    ]]
    @MainActor static let font: NSFont = {
        // Register only in this process; no system font installation.
        if let url = Bundle.module.url(forResource:"Satoshi-Regular",withExtension:"otf",subdirectory:"Fonts") {
            CTFontManagerRegisterFontsForURL(url as CFURL,.process,nil)
        }
        let base = (["Satoshi-Regular","Satoshi Fallback","Open Sans","OpenSans","Arial","Helvetica"]
            .lazy.compactMap { NSFont(name:$0,size:14) }).first ?? .systemFont(ofSize:14,weight:.regular)
        return NSFont(descriptor:base.fontDescriptor.addingAttributes([.featureSettings:features]),size:14) ?? base
    }()
}
