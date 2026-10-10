import AppKit

/// No Markdown parsing, attachments, links, syntax colors or per-token styling.
@MainActor public struct PlainTextRenderer {
    public static let maximumLength = 100_000
    public init() {}
    public func render(_ text: String, style: OverlayStyle = .fallback) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 0; paragraph.paragraphSpacingBefore = 0
        paragraph.firstLineHeadIndent = 0; paragraph.headIndent = 0
        return NSAttributedString(string: Self.bounded(text, limit: Self.maximumLength), attributes: [
            .font: style.font, .foregroundColor: style.foreground, .paragraphStyle:paragraph
        ])
    }
    static func bounded(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        var units = Array(text.utf16.prefix(limit))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}
