import AppKit
import CoreText
import XCTest
@testable import HarnessCore
@testable import HarnessEmitter

@MainActor final class OverlayTests: XCTestCase {
    func testMalformedGeometryCannotReachNativeWindowFrames() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        for bad in [CGRect.null, CGRect.infinite, CGRect.zero,
                    CGRect(x: 1e308, y: 0, width: 1e308, height: 100)] {
            XCTAssertEqual(OverlayGeometry.frame(screen: bad, cursor: .zero, position: .nearCursor), .zero)
        }
        XCTAssertEqual(OverlayGeometry.frame(screen: screen, cursor: CGPoint(x: Double.nan, y: 0), position: .nearCursor), .zero)
        let result = OverlayGeometry.frame(screen: screen, cursor: CGPoint(x: 100, y: 400), position: .nearCursor, pane: .infinite)
        XCTAssertTrue(screen.contains(result))
        XCTAssertLessThanOrEqual(result.width, 600)
    }
    func testAnswerRemainsVisibleUntilExplicitDismissal() {
        let session = OverlaySession()
        session.show(text: "answer")
        session.show(text: "new answer")
        XCTAssertEqual(session.text, "new answer")
        XCTAssertTrue(session.isVisible)
        session.dismiss()
        XCTAssertFalse(session.isVisible)
        XCTAssertEqual(session.text, "")
    }

    func testNativeAnswerSurvivesTheFormerIdleDeadline() async throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else { throw XCTSkip("Native overlay opt-in") }
        _ = NSApplication.shared
        let controller = OverlayController(); defer { controller.dismiss() }
        _ = controller.show(settings:Settings(),text:"Persistent answer")
        try await Task.sleep(nanoseconds:31_000_000_000)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.textView.string,"Persistent answer")
        controller.dismiss()
        XCTAssertFalse(controller.isVisible)
    }

    func testPlainTextUsesOnlyWhiteRegularBodyFont() {
        let input = "Answer\n  indented code\nhttps://example.com <script>plain text</script>"
        let rendered = PlainTextRenderer().render(input)
        XCTAssertEqual(rendered.string, input)
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attrs, _, _ in
            let font = attrs[.font] as! NSFont
            let ink = (attrs[.foregroundColor] as! NSColor).usingColorSpace(.sRGB)!
            XCTAssertEqual(font.pointSize, 14)
            XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.bold))
            XCTAssertEqual(ink.redComponent, 1); XCTAssertEqual(ink.greenComponent, 1); XCTAssertEqual(ink.blueComponent, 1)
            XCTAssertNil(attrs[.link]); XCTAssertNil(attrs[.attachment]); XCTAssertNil(attrs[.backgroundColor])
        }
        let bounded = PlainTextRenderer().render(String(repeating: "😀", count: 100_001))
        XCTAssertEqual(bounded.length, 100_000)
        XCTAssertFalse(bounded.string.contains("�"))
    }

    func testCSSParagraphDefaultsUseRegularWeightWithoutParagraphMargins() throws {
        let style = OverlayStyle.light
        let rendered = PlainTextRenderer().render("First paragraph\nSecond paragraph",style:style)
        let font = try XCTUnwrap(rendered.attribute(.font,at:0,effectiveRange:nil) as? NSFont)
        XCTAssertEqual(font.familyName,"Satoshi")
        XCTAssertEqual(font.pointSize,14)
        XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.bold))
        let paragraph = try XCTUnwrap(rendered.attribute(.paragraphStyle,at:0,effectiveRange:nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.paragraphSpacing,0)
        XCTAssertEqual(paragraph.paragraphSpacingBefore,0)
        XCTAssertEqual(paragraph.firstLineHeadIndent,0)
        XCTAssertEqual(paragraph.headIndent,0)
    }

    func testBothPalettesUseFixedSatoshiAndStylisticSetThree() throws {
        func glyphs(_ font: NSFont) -> [CGGlyph] {
            let text = NSAttributedString(string:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",attributes:[.font:font])
            let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(text)) as! [CTRun]
            return runs.flatMap { run -> [CGGlyph] in
                var glyphs = [CGGlyph](repeating:0,count:CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs)
                return glyphs
            }
        }
        for style in [OverlayStyle.dark, .light] {
            let font = style.font
            XCTAssertEqual(font.familyName,"Satoshi")
            XCTAssertEqual(font.fontName,"Satoshi-Regular")
            XCTAssertEqual(font.pointSize,14)
            XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.bold))
            let settings = try XCTUnwrap(font.fontDescriptor.object(forKey:.featureSettings) as? [[NSFontDescriptor.FeatureKey:Int]])
            XCTAssertTrue(settings.contains { $0[.typeIdentifier] == kStylisticAlternativesType && $0[.selectorIdentifier] == kStylisticAltThreeOnSelector })
            let features = try XCTUnwrap(CTFontCopyFeatures(font as CTFont) as? [[String:Any]])
            let alternates = try XCTUnwrap(features.first { ($0[kCTFontFeatureTypeIdentifierKey as String] as? Int) == kStylisticAlternativesType })
            let selectors = try XCTUnwrap(alternates[kCTFontFeatureTypeSelectorsKey as String] as? [[String:Any]])
            XCTAssertTrue(selectors.contains { ($0[kCTFontFeatureSelectorIdentifierKey as String] as? Int) == kStylisticAltThreeOnSelector })
            XCTAssertNotEqual(glyphs(font),glyphs(try XCTUnwrap(NSFont(name:"Satoshi-Regular",size:14))))
        }
    }

    func testPlacementClampsToCursorDisplay() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let near = OverlayGeometry.frame(screen: screen, cursor: CGPoint(x: -3, y: -190), position: .nearCursor)
        XCTAssertTrue(screen.contains(near))
        let pinned = OverlayGeometry.frame(screen: screen, cursor: .zero, position: .pinnedCorner)
        XCTAssertEqual(pinned.maxX, screen.maxX - 16)
        XCTAssertEqual(pinned.maxY, screen.maxY - 16)
        XCTAssertEqual(CalibrationPatchGeometry.black, CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertEqual(CalibrationPatchGeometry.white, CGRect(x: 12, y: 8, width: 4, height: 8))
    }

    func testPanePlacementUsesFullPaneWidthCursorHeightAndContentHeight() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let pane = CGRect(x: -1800, y: -200, width: 590, height: 720)
        let cursor = CGPoint(x: -500, y: 350)
        let frame = OverlayGeometry.frame(screen: screen, cursor: cursor, position: .nearCursor, pane: pane, contentHeight: 50)
        XCTAssertEqual(frame.minX, pane.minX); XCTAssertEqual(frame.width, pane.width)
        XCTAssertEqual(frame.maxY, cursor.y); XCTAssertEqual(frame.height, 50)
        let low = OverlayGeometry.frame(screen:screen,cursor:CGPoint(x:0,y:-150),position:.nearCursor,pane:pane)
        XCTAssertEqual(low.maxY,-150); XCTAssertEqual(low.height,50)
        for y in [-300.0, 950.0] {
            XCTAssertTrue(pane.contains(OverlayGeometry.frame(screen:screen,cursor:CGPoint(x:0,y:y),position:.nearCursor,pane:pane)))
        }
        let fallback = OverlayGeometry.frame(screen:screen,cursor:cursor,position:.nearCursor,pane:.null)
        XCTAssertTrue(screen.contains(fallback))
    }

    func testNativePopupLabelsUseWhiteInkAndTheBodyFontSize() throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else { throw XCTSkip("Native overlay opt-in") }
        _ = NSApplication.shared
        let controller = OverlayController(); defer { controller.dismiss() }
        _ = controller.show(settings: Settings(), text: "Simple loops and arrays solve this problem.\nReturn the required answer.")
        XCTAssertEqual((controller.textView.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.fontName,"Satoshi-Regular")
        if let path = ProcessInfo.processInfo.environment["HARNESS_CSS_PREVIEW_PATH"] {
            let root = try XCTUnwrap(controller.panel.contentView)
            root.displayIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in:root.bounds))
            root.cacheDisplay(in:root.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path))
        }
        let labels = try XCTUnwrap(controller.panel.contentView).subviews.compactMap { $0 as? NSTextField }
        XCTAssertEqual(labels.count, 0, "Answer popup has no labels or controls")
        XCTAssertEqual(controller.panel.contentView?.layer?.borderWidth, 0)
        XCTAssertNil(controller.patchScreenRect, "Answer popup has no calibration marker")
        for label in labels {
            XCTAssertEqual(label.font?.pointSize, 14)
            let ink = try XCTUnwrap(label.textColor?.usingColorSpace(.sRGB))
            XCTAssertEqual(ink.redComponent, 1, accuracy: 0.001)
            XCTAssertEqual(ink.greenComponent, 1, accuracy: 0.001)
            XCTAssertEqual(ink.blueComponent, 1, accuracy: 0.001)
        }
    }

    func testTemplateSurfaceDoesNotLetTheUnderlyingPageBleedThrough() throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else { throw XCTSkip("Native overlay opt-in") }
        _ = NSApplication.shared
        let controller = OverlayController(); defer { controller.dismiss() }
        _ = controller.show(settings: Settings(), text: "char* findNumber(int arr_count, int* arr, int k) {\n    for (int i = 0; i < arr_count; i++) {\n        if (arr[i] == k) return \"YES\";\n    }\n    return \"NO\";\n}")
        let surface = try XCTUnwrap(controller.panel.contentView?.layer?.backgroundColor)
        XCTAssertEqual(surface.alpha, 1, accuracy: 0.001)
        XCTAssertTrue(controller.panel.ignoresMouseEvents)
        XCTAssertFalse(controller.panel.isKeyWindow)
        // Optional export renders this generated view only; it never reads the screen.
        if let path = ProcessInfo.processInfo.environment["HARNESS_OVERLAY_PREVIEW_PATH"] {
            let root = try XCTUnwrap(controller.panel.contentView)
            root.displayIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    func testCalibrationMarkerAppearsOnlyWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else { throw XCTSkip("Native overlay opt-in") }
        _ = NSApplication.shared
        let controller = OverlayController(); defer { controller.dismiss() }
        _ = controller.show(settings:Settings(),text:"",calibrationMarker:true)
        XCTAssertNotNil(controller.patchScreenRect)
        XCTAssertEqual(controller.screenRect.size, CGSize(width:16,height:16))
        _ = controller.show(settings:Settings(),text:"Answer")
        XCTAssertNil(controller.patchScreenRect)
    }

    func testFunctionKeyScrollingMovesBothWaysAndNeverAcceptsMouse() throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else { throw XCTSkip("Native overlay opt-in") }
        _ = NSApplication.shared
        let controller = OverlayController(); defer { controller.dismiss() }
        let text = (1...150).map { "Line \($0)" }.joined(separator: "\n\n")
        _ = controller.show(settings: Settings(), text: text)
        let scroll = try XCTUnwrap(controller.textView.enclosingScrollView)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        controller.scroll(.down)
        let moved = scroll.documentVisibleRect.minY
        XCTAssertGreaterThan(moved, 0)
        controller.scroll(.up)
        XCTAssertEqual(scroll.documentVisibleRect.minY, 0, accuracy: 1)
        for _ in 0..<100 { controller.scroll(.down) }
        XCTAssertLessThanOrEqual(scroll.documentVisibleRect.maxY, controller.textView.frame.maxY + 1)
        for _ in 0..<100 { controller.scroll(.up) }
        XCTAssertEqual(scroll.documentVisibleRect.minY, 0, accuracy: 1)
        XCTAssertTrue(controller.panel.ignoresMouseEvents)
        XCTAssertFalse(controller.panel.isKeyWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
        controller.dismiss(); controller.scroll(.down)
        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(controller.panel.ignoresMouseEvents)
    }

    func testNativeLongResponsesHaveScrollableHeightAndStartAtTop() throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else {
            throw XCTSkip("Native overlay layout requires authorized GUI integration opt-in")
        }
        _ = NSApplication.shared
        let controller = OverlayController()
        defer { controller.dismiss() }
        let response = (1...150).map { "Line \($0): readable response content." }.joined(separator: "\n\n")
        _ = controller.show(settings: Settings(), text: response)
        let scroll = try XCTUnwrap(controller.textView.enclosingScrollView)
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.textView.frame.height, scroll.contentSize.height * 3, "Long responses must contribute their full layout height")
        XCTAssertEqual(scroll.documentVisibleRect.minY, 0, accuracy: 1, "A new response starts at its first line")
        let tail = CGRect(x: 0, y: controller.textView.frame.height - 30, width: 20, height: 20)
        XCTAssertTrue(controller.textView.scrollToVisible(tail))
        XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 0)
        _ = controller.show(settings:Settings(),text: "Short response")
        XCTAssertLessThanOrEqual(controller.textView.frame.height, scroll.contentSize.height + 1, "Replacing a long response must remove stale document height")
        XCTAssertEqual(scroll.documentVisibleRect.minY, 0, accuracy: 1)
    }

    func testShortAnswerFitsWithoutReservedHeaderSpace() throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else { throw XCTSkip("Native overlay opt-in") }
        _ = NSApplication.shared
        let controller = OverlayController(); defer { controller.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let pane = CGRect(x:screen.minX + 116,y:screen.minY,width:590,height:min(720,screen.height))
        let cursor = CGPoint(x:screen.maxX - 30,y:pane.maxY - 100)
        let rect = controller.show(settings:Settings(),text:"YES",pane:pane,cursor:cursor)
        XCTAssertEqual(rect.minX,pane.minX); XCTAssertEqual(rect.width,pane.width)
        XCTAssertEqual(rect.maxY,cursor.y)
        XCTAssertEqual(controller.textView.string, "YES")
        XCTAssertLessThan(controller.screenRect.height, 35)
        let scroll = try XCTUnwrap(controller.textView.enclosingScrollView)
        XCTAssertEqual(scroll.frame, controller.contentBounds)
        XCTAssertEqual(controller.panel.contentView?.subviews.compactMap { $0 as? NSTextField }.count, 0)
        XCTAssertEqual(controller.panel.contentView?.layer?.cornerRadius, 0)
        XCTAssertFalse(controller.panel.hasShadow)
    }

    func testNativePanelInvariantsOnlyWhenExplicitlyOptedIn() throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else {
            throw XCTSkip("Native NSPanel checks require authorized GUI integration opt-in")
        }
        _ = NSApplication.shared
        let hostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let keyWindow = NSApplication.shared.keyWindow
        let mainWindow = NSApplication.shared.mainWindow
        let controller = OverlayController()
        XCTAssertFalse(controller.panel.canBecomeKey)
        XCTAssertFalse(controller.panel.canBecomeMain)
        XCTAssertTrue(controller.panel.ignoresMouseEvents)
        XCTAssertEqual(controller.panel.level, .floating)
        XCTAssertTrue(controller.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(controller.textView.acceptsFirstResponder)
        XCTAssertFalse(controller.textView.becomeFirstResponder())
        _ = controller.show(settings: Settings(), text: "Test")
        XCTAssertTrue(controller.textView.string.contains("Test"))
        controller.scroll(.down)
        XCTAssertFalse(controller.panel.isKeyWindow); XCTAssertFalse(controller.panel.isMainWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, hostPID)
        XCTAssertTrue(NSApplication.shared.keyWindow === keyWindow)
        XCTAssertTrue(NSApplication.shared.mainWindow === mainWindow)
        XCTAssertFalse(controller.textView.isSelectable)
        XCTAssertNil(controller.patchScreenRect)
        let configurer = AppKitWindowConfigurer(window:controller.panel)
        let modes = try VisibilityModeEngine(configurer:configurer)
        for mode in VisibilityMode.allCases {
            let transition = try modes.applyFromSettings(mode)
            XCTAssertEqual(modes.currentMode,mode)
            XCTAssertEqual(transition.observed.level,NSWindow.Level.floating.rawValue)
            XCTAssertEqual(transition.observed.collectionBehavior,VisibilityModeEngine.configuration(for:mode).collectionBehavior)
            XCTAssertFalse(controller.panel.isKeyWindow); XCTAssertFalse(controller.panel.isMainWindow)
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier,hostPID)
        }
        controller.dismiss()
        XCTAssertEqual(controller.textView.string, "")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, hostPID)
        XCTAssertTrue(NSApplication.shared.keyWindow === keyWindow)
    }
}
