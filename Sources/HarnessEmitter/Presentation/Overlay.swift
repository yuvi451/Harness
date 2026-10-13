import AppKit
import HarnessCore

/// Answers persist until the application explicitly dismisses or replaces them.
@MainActor final class OverlaySession {
    private(set) var text = ""
    private(set) var isVisible = false
    var hasAnswer:Bool { !text.isEmpty }
    func show(text:String,visible:Bool = true) { isVisible = visible;self.text = PlainTextRenderer.bounded(text,limit:PlainTextRenderer.maximumLength) }
    func toggleVisibility() { if hasAnswer { isVisible.toggle() } }
    func dismiss() { isVisible = false; text = "" }
}

enum OverlayGeometry {
    static let compactMinimumWidth:CGFloat = 96
    static let compactMaximumWidth:CGFloat = 420
    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
    static func frame(screen: CGRect, cursor: CGPoint, position: OverlayPosition,
                      pane: CGRect? = nil, contentHeight: CGFloat = 420, fallbackPlacement:Bool = false,
                      contentWidth:CGFloat? = nil) -> CGRect {
        guard valid(screen), cursor.x.isFinite, cursor.y.isFinite else { return .zero }
        let detected = pane.flatMap { valid($0) ? $0.intersection(screen) : nil }
        let bottomLeft = fallbackPlacement || position == .pinnedCorner
        let insidePane = position == .nearCursor && !bottomLeft && (detected.map { !$0.isNull && $0.width > 44 && $0.height > 18 } ?? false)
        let area = insidePane ? detected! : screen.insetBy(dx: min(16, screen.width / 4), dy: min(16, screen.height / 4))
        let limit:CGFloat = bottomLeft ? compactMaximumWidth : 600
        let requestedWidth = contentWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? limit
        let width = insidePane ? area.width : min(limit,area.width,requestedWidth)
        let height = min(area.height, max(1, min(420, contentHeight.isFinite ? contentHeight : 18)))
        if bottomLeft {
            return CGRect(x:area.minX,y:area.minY,width:width,height:height)
        }
        // Move upward near an edge rather than cutting through a text line.
        let top = min(area.maxY, max(area.minY + height, cursor.y))
        let x = insidePane ? area.minX : cursor.x + 16
        return CGRect(x: min(max(x, area.minX), area.maxX - width),
                      y: min(max(top - height, area.minY), area.maxY - height), width: width, height: height)
    }
}

/// Marker coordinates are top-left oriented inside a 16-point square.
enum CalibrationPatchGeometry {
    static let black = CGRect(x: 0, y: 0, width: 4, height: 4)
    static let white = CGRect(x: 12, y: 8, width: 4, height: 8)
}

@MainActor public final class OverlayPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
    public init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 600, height: 420), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        isFloatingPanel = true; hidesOnDeactivate = false; becomesKeyOnlyIfNeeded = true
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        isMovable = false; isMovableByWindowBackground = false
        ignoresMouseEvents = true; isReleasedWhenClosed = false
        animationBehavior = .none; appearance = NSAppearance(named: .darkAqua)
    }
}

@MainActor public final class OverlayTextView: NSTextView {
    public override var acceptsFirstResponder: Bool { false }
    public override var needsPanelToBecomeKey: Bool { false }
    public override func becomeFirstResponder() -> Bool { false }
    public override func mouseDown(with event: NSEvent) {}
    public override func menu(for event: NSEvent) -> NSMenu? { nil }
    public override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}
@MainActor private final class OverlayScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func scrollWheel(with event: NSEvent) {}
}
@MainActor private final class CalibrationPatchView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 0, blue: 127.0 / 255, alpha: 1).setFill(); bounds.fill()
        NSColor.black.setFill(); CalibrationPatchGeometry.black.fill()
        NSColor.white.setFill(); CalibrationPatchGeometry.white.fill()
    }
}

public enum OverlayScrollDirection { case up, down }

@MainActor public final class OverlayController {
    public let panel: OverlayPanel
    public let textView: OverlayTextView
    private let scrollView: OverlayScrollView
    private let patch = CalibrationPatchView(frame: .zero)
    private let renderer = PlainTextRenderer()
    private var style = OverlayStyle.fallback
    private var font = OverlayTypography.font
    private var lineRects:[CGRect] = []
    private var measuredContentWidth:CGFloat = 0
    private var viewportHeight:CGFloat?
    private var visibleLineCount = 1
    private let session: OverlaySession
    public var hasAnswer:Bool { session.hasAnswer }
    public var isVisible: Bool { session.isVisible && panel.isVisible }
    public var screenRect: CGRect { panel.frame }
    public var contentBounds: CGRect { panel.contentView?.bounds ?? .zero }
    public var overlayWindowID: Int { panel.windowNumber }
    public var patchScreenRect: CGRect? {
        guard isVisible, !patch.isHidden else { return nil }
        return panel.convertToScreen(patch.convert(patch.bounds, to: nil))
    }
    public init() {
        panel = OverlayPanel(); textView = OverlayTextView(frame: .zero)
        scrollView = OverlayScrollView(frame: .zero)
        session = OverlaySession()
        let root = NSView(frame: contentBounds)
        root.wantsLayer = true
        root.layer?.backgroundColor = style.background.cgColor
        panel.contentView = root
        textView.isEditable = false; textView.isSelectable = false; textView.isRichText = false
        textView.allowsUndo = false; textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.drawsBackground = false; textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.textContainerInset = CGSize(width: 22, height: 0)
        textView.autoresizingMask = [.width]
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        // The renderer includes leading in its uniform paragraph height.
        // Adding per-glyph leading again makes fallback-font rows taller or shorter.
        textView.layoutManager?.usesFontLeading = false
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = CGSize(width: 0, height: 0)
        scrollView.hasVerticalScroller = false; scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none; scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = false; scrollView.documentView = textView
        [patch, scrollView].forEach { root.addSubview($0) }
        patch.isHidden = true
        layout()
    }

    @discardableResult public func show(settings: Settings, text: String,
                                         pane: CGRect? = nil, cursor: CGPoint? = nil, calibrationMarker: Bool = false,
                                         style: OverlayStyle = .fallback, typography:AdaptiveTypography? = nil,
                                         targetScreen:CGRect? = nil,initiallyVisible:Bool = true) -> CGRect {
        let cursor = cursor ?? NSEvent.mouseLocation
        let paneScreen = pane.flatMap { bounds in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x:bounds.midX,y:bounds.midY)) }
        }
        let target = targetScreen.flatMap { bounds in NSScreen.screens.first { $0.frame == bounds } }
        let cursorScreen = NSScreen.screens.first { $0.frame.contains(cursor) }
        guard let screen = target ?? (settings.overlayPosition == .nearCursor ? paneScreen : nil) ?? cursorScreen ?? NSScreen.main else { return .zero }
        let intersection = pane?.intersection(screen.visibleFrame)
        var usablePane = settings.overlayPosition == .nearCursor ? intersection.flatMap { !$0.isNull && !$0.isInfinite && $0.width > 44 && $0.height >= 18 ? $0 : nil } : nil
        var fallbackPlacement = usablePane == nil && !calibrationMarker
        font = OverlayFontSelection.font(adaptive:typography,enabled:settings.adaptiveTypographyEnabled,fallbackPlacement:fallbackPlacement)
        self.style = style
        viewportHeight = nil
        textView.textContainerInset = CGSize(width:fallbackPlacement ? 6 : 22,height:0)
        session.show(text:text,visible:initiallyVisible)
        var provisional = OverlayGeometry.frame(screen: screen.visibleFrame, cursor: cursor, position: settings.overlayPosition,
                                                pane:usablePane,fallbackPlacement:fallbackPlacement)
        guard provisional.width > 0, provisional.height > 0 else { dismiss(); return .zero }
        panel.setFrame(provisional, display: false)
        refreshPresentation()
        // Fallback glyphs can need more height than the chosen font's own metrics.
        if let bounds = usablePane, let firstLine = lineRects.first, firstLine.height > bounds.height {
            usablePane = nil; fallbackPlacement = !calibrationMarker
            font = OverlayFontSelection.font(adaptive:nil,enabled:false,fallbackPlacement:fallbackPlacement)
            textView.textContainerInset = CGSize(width:fallbackPlacement ? 6 : 22,height:0)
            provisional = OverlayGeometry.frame(screen:screen.visibleFrame,cursor:cursor,position:settings.overlayPosition,
                fallbackPlacement:fallbackPlacement)
            panel.setFrame(provisional,display:false)
            refreshPresentation()
        }
        var fittedWidth = provisional.width
        if fallbackPlacement {
            fittedWidth = min(provisional.width,max(OverlayGeometry.compactMinimumWidth,ceil(measuredContentWidth)+2*textView.textContainerInset.width))
            panel.setFrame(OverlayGeometry.frame(screen:screen.visibleFrame,cursor:cursor,position:settings.overlayPosition,
                contentHeight:provisional.height,fallbackPlacement:true,contentWidth:fittedWidth),display:false)
            refreshPresentation()
        }
        let areaHeight = usablePane?.height ?? max(1,screen.visibleFrame.height - 32)
        let lineHeight = lineRects.first?.height ?? ceil(font.ascender-font.descender+font.leading+2)
        visibleLineCount = min(3,max(1,min(lineRects.count,Int(areaHeight/max(1,lineHeight)))))
        let contentHeight = lineRects.isEmpty ? lineHeight : lineRects[visibleLineCount - 1].maxY
        var fitted = OverlayGeometry.frame(screen: screen.visibleFrame, cursor: cursor, position: settings.overlayPosition,
                                           pane:usablePane,contentHeight:ceil(contentHeight),fallbackPlacement:fallbackPlacement,contentWidth:fittedWidth)
        // Native windows round their frames to display pixels. Keep the clip
        // view at the exact line boundary so that rounding cannot reveal a
        // fraction of the next line.
        viewportHeight = min(contentHeight,fitted.height)
        if calibrationMarker { fitted = CGRect(x: fitted.minX, y: fitted.maxY - 16, width: 16, height: 16) }
        panel.setFrame(fitted, display: false)
        panel.contentView?.layer?.backgroundColor = calibrationMarker ? NSColor.clear.cgColor : style.background.cgColor
        patch.isHidden = !calibrationMarker; scrollView.isHidden = calibrationMarker
        layout(); resizeDocumentToContent(); scrollView.contentView.scroll(to: .zero)
        panel.ignoresMouseEvents = true
        if initiallyVisible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        return panel.frame
    }
    public func toggleVisibility() {
        guard session.hasAnswer else { return }
        session.toggleVisibility()
        if session.isVisible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }
    public func reposition(settings:Settings,pane:CGRect?,cursor:CGPoint,style:OverlayStyle,
                           typography:AdaptiveTypography?,targetScreen:CGRect) {
        guard session.hasAnswer else { return }
        let answer = session.text,visible = session.isVisible
        var character = 0
        if let manager = textView.layoutManager {
            let y = scrollView.contentView.bounds.minY
            manager.enumerateLineFragments(forGlyphRange:NSRange(location:0,length:manager.numberOfGlyphs)) { rect,_,_,range,stop in
                if abs(rect.minY-y) < 1,range.length > 0 {
                    character = manager.characterIndexForGlyph(at:range.location);stop.pointee = true
                }
            }
        }
        show(settings:settings,text:answer,pane:pane,cursor:cursor,style:style,typography:typography,
             targetScreen:targetScreen,initiallyVisible:visible)
        if let manager = textView.layoutManager,manager.numberOfGlyphs > 0,!lineRects.isEmpty {
            let glyph = manager.glyphIndexForCharacter(at:min(character,max(0,textView.string.utf16.count-1)))
            let y = manager.lineFragmentRect(forGlyphAt:min(glyph,manager.numberOfGlyphs-1),effectiveRange:nil).minY
            let index = lineRects.indices.min { abs(lineRects[$0].minY-y) < abs(lineRects[$1].minY-y) } ?? 0
            let top = min(index,max(0,lineRects.count-visibleLineCount))
            scrollView.contentView.scroll(to:CGPoint(x:0,y:lineRects[top].minY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
    public func dismiss() {
        session.dismiss(); panel.orderOut(nil); panel.ignoresMouseEvents = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        lineRects.removeAll()
        viewportHeight = nil
        patch.isHidden = true
        scrollView.contentView.scroll(to: .zero)
    }
    public func scroll(_ direction: OverlayScrollDirection) {
        guard session.isVisible else { return }
        let clip = scrollView.contentView
        guard !lineRects.isEmpty else { return }
        let index = lineRects.indices.min { abs(lineRects[$0].minY-clip.bounds.minY) < abs(lineRects[$1].minY-clip.bounds.minY) } ?? 0
        let step = max(1,visibleLineCount - 1)
        let last = max(0,lineRects.count-visibleLineCount)
        let next = min(last,max(0,index + (direction == .down ? step : -step)))
        clip.scroll(to: CGPoint(x:0,y:lineRects[next].minY))
        scrollView.reflectScrolledClipView(clip)
    }
    private func refreshPresentation() {
        layout()
        textView.textStorage?.setAttributedString(renderer.render(session.text,style:style,font:font))
        resizeDocumentToContent()
    }
    private func resizeDocumentToContent() {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        lineRects.removeAll(keepingCapacity:true)
        measuredContentWidth = 0
        manager.enumerateLineFragments(forGlyphRange:NSRange(location:0,length:manager.numberOfGlyphs)) { rect,used,_,_,_ in
            self.lineRects.append(rect)
            self.measuredContentWidth = max(self.measuredContentWidth,used.maxX)
        }
        if manager.extraLineFragmentTextContainer != nil, manager.extraLineFragmentRect.height > 0 {
            lineRects.append(manager.extraLineFragmentRect)
        }
        let height = ceil(lineRects.last?.maxY ?? manager.usedRect(for:container).maxY)
        textView.setFrameSize(CGSize(width: scrollView.contentSize.width, height: max(scrollView.contentSize.height, height)))
        let origin = scrollView.contentView.bounds.origin
        let maxY = max(0, textView.frame.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, origin.y), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    private func layout() {
        guard let bounds = panel.contentView?.bounds else { return }
        patch.frame = CGRect(x: bounds.maxX - 16, y: bounds.maxY - 16, width: 16, height: 16)
        let height = min(bounds.height,viewportHeight ?? bounds.height)
        scrollView.frame = CGRect(x:bounds.minX,y:bounds.maxY-height,width:bounds.width,height:height)
        // NSScrollView's tiling also rounds its clip view; restore its precise
        // frame and bounds after tiling to preserve the final glyph descenders.
        let clipSize = CGSize(width:scrollView.contentView.frame.width,height:height)
        scrollView.contentView.setFrameSize(clipSize)
        scrollView.contentView.setBoundsSize(clipSize)
        textView.frame.size.width = scrollView.contentSize.width
    }
}
