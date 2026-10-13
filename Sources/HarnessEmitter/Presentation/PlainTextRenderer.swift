import AppKit
import CoreText

/// No Markdown parsing, attachments, links, syntax colors or per-token styling.
@MainActor public struct PlainTextRenderer {
    public static let maximumLength = 100_000
    public init() {}
    public func render(_ text: String, style: OverlayStyle = .fallback, font: NSFont? = nil) -> NSAttributedString {
        let font = font ?? style.font
        let bounded = Self.bounded(text, limit: Self.maximumLength)
        // Include fallback glyph fonts (emoji/CJK) in a uniform line height.
        let measured = CTLineCreateWithAttributedString(NSAttributedString(string:bounded,attributes:[.font:font]))
        var ascent:CGFloat = 0, descent:CGFloat = 0, leading:CGFloat = 0
        CTLineGetTypographicBounds(measured,&ascent,&descent,&leading)
        let lineHeight = ceil(max(font.ascender-font.descender+font.leading,ascent+descent+leading) + 2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 0; paragraph.paragraphSpacingBefore = 0
        paragraph.firstLineHeadIndent = 0; paragraph.headIndent = 0
        paragraph.alignment = .left
        paragraph.tabStops = []
        paragraph.defaultTabInterval = max(1,("    " as NSString).size(withAttributes:[.font:font]).width)
        paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: bounded, attributes: [
            .font: font, .foregroundColor: style.foreground, .paragraphStyle:paragraph
        ])
    }
    static func bounded(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        var units = Array(text.utf16.prefix(limit))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}
