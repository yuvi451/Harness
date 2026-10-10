import AppKit
import HarnessCore

/// Answers persist until the application explicitly dismisses or replaces them.
@MainActor final class OverlaySession {
    private(set) var text = ""
    private(set) var isVisible = false
    func show(text: String) { isVisible = true; self.text = PlainTextRenderer.bounded(text, limit: PlainTextRenderer.maximumLength) }
    func dismiss() { isVisible = false; text = "" }
}

enum OverlayGeometry {
    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
    static func frame(screen: CGRect, cursor: CGPoint, position: OverlayPosition,
                      pane: CGRect? = nil, contentHeight: CGFloat = 420) -> CGRect {
        guard valid(screen), cursor.x.isFinite, cursor.y.isFinite else { return .zero }
        let detected = pane.flatMap { valid($0) ? $0.intersection(screen) : nil }
        let insidePane = detected.map { !$0.isNull && $0.width > 44 && $0.height > 18 } ?? false
        let area = insidePane ? detected! : screen.insetBy(dx: min(16, screen.width / 4), dy: min(16, screen.height / 4))
        let width = insidePane ? area.width : min(600, area.width)
        let requestedTop = position == .pinnedCorner && !insidePane ? area.maxY : cursor.y
        let top = min(area.maxY, max(area.minY + min(18, area.height), requestedTop))
        let height = min(top - area.minY, max(18, min(420, contentHeight.isFinite ? contentHeight : 420)))
        let x = insidePane ? area.minX : (position == .pinnedCorner ? area.maxX - width : cursor.x + 16)
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
    private let session: OverlaySession
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
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = CGSize(width: 0, height: 0)
        scrollView.hasVerticalScroller = false; scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false; scrollView.documentView = textView
        [patch, scrollView].forEach { root.addSubview($0) }
        patch.isHidden = true
        layout()
    }

    @discardableResult public func show(settings: Settings, text: String,
                                         pane: CGRect? = nil, cursor: CGPoint? = nil, calibrationMarker: Bool = false, style: OverlayStyle = .fallback) -> CGRect {
        let cursor = cursor ?? NSEvent.mouseLocation
        let paneScreen = pane.flatMap { bounds in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x:bounds.midX,y:bounds.midY)) }
        }
        guard let screen = paneScreen ?? NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main else { return .zero }
        self.style = style
        session.show(text: text)
        let provisional = OverlayGeometry.frame(screen: screen.visibleFrame, cursor: cursor, position: settings.overlayPosition, pane: pane)
        guard provisional.width > 0, provisional.height > 0 else { dismiss(); return .zero }
        panel.setFrame(provisional, display: false)
        refreshPresentation()
        let contentHeight = textView.textContainer.flatMap { textView.layoutManager?.usedRect(for:$0).maxY }.map { ceil($0) } ?? 18
        var fitted = OverlayGeometry.frame(screen: screen.visibleFrame, cursor: cursor, position: settings.overlayPosition,
                                           pane: pane, contentHeight: contentHeight)
        if calibrationMarker { fitted = CGRect(x: fitted.minX, y: fitted.maxY - 16, width: 16, height: 16) }
        panel.setFrame(fitted, display: false)
        panel.contentView?.layer?.backgroundColor = calibrationMarker ? NSColor.clear.cgColor : style.background.cgColor
        patch.isHidden = !calibrationMarker; scrollView.isHidden = calibrationMarker
        layout(); resizeDocumentToContent(); scrollView.contentView.scroll(to: .zero)
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        return panel.frame
    }
    public func dismiss() {
        session.dismiss(); panel.orderOut(nil); panel.ignoresMouseEvents = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        patch.isHidden = true
        scrollView.contentView.scroll(to: .zero)
    }
    public func scroll(_ direction: OverlayScrollDirection) {
        guard session.isVisible else { return }
        let clip = scrollView.contentView
        let step = max(40, scrollView.contentSize.height * 0.7)
        let maximum = max(0, textView.frame.height - scrollView.contentSize.height)
        let proposed = clip.bounds.minY + (direction == .down ? step : -step)
        clip.scroll(to: CGPoint(x: 0, y: min(maximum, max(0, proposed))))
        scrollView.reflectScrolledClipView(clip)
    }
    private func refreshPresentation() {
        layout()
        textView.textStorage?.setAttributedString(renderer.render(session.text,style:style))
        resizeDocumentToContent()
    }
    private func resizeDocumentToContent() {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        let height = ceil(manager.usedRect(for: container).maxY + 2 * textView.textContainerInset.height)
        textView.setFrameSize(CGSize(width: scrollView.contentSize.width, height: max(scrollView.contentSize.height, height)))
        let origin = scrollView.contentView.bounds.origin
        let maxY = max(0, textView.frame.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, origin.y), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    private func layout() {
        guard let bounds = panel.contentView?.bounds else { return }
        patch.frame = CGRect(x: bounds.maxX - 16, y: bounds.maxY - 16, width: 16, height: 16)
        scrollView.frame = bounds
        textView.frame.size.width = scrollView.contentSize.width
    }
}
