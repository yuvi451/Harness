import AppKit
import XCTest
@testable import HarnessCore
@testable import HarnessEmitter

@MainActor final class CompactOverlayTests: XCTestCase {
    func testMixedPrimaryAndFallbackGlyphLinesRemainCompleteWhileScrolling() throws {
        let controller = try makeOverlayController();defer { controller.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let pane = CGRect(x:screen.minX+20,y:screen.minY+20,width:420,height:screen.height-40)
        var settings = Settings();settings.adaptiveTypographyEnabled = true
        let answers = [
            "One\nTwo\nThree\n😀你好 مرحبا\n😀你好 مرحبا\n😀你好 مرحبا\nSeven\nEight\nNine",
            "One\nTwo\nThree\n\n😀你好 مرحبا\n\ne\u{301} answer\n👨‍👩‍👧‍👦\nNine\n\n"
        ]
        for (font,size) in [("Satoshi-Regular",14.0),("Menlo-Regular",28.0),("Arial-BoldMT",28.0),("ArialMT",28.0)] {
            for answer in answers {
                controller.show(settings:settings,text:answer,pane:pane,cursor:CGPoint(x:pane.midX,y:pane.midY),
                    typography:.init(fontName:font,pointSize:size,confidence:1))
                let lines = try lineFragments(in:controller)
                let clip = try XCTUnwrap(controller.textView.enclosingScrollView).contentView
                for direction in [OverlayScrollDirection.down,.up] {
                    for _ in 0..<lines.count {
                        assertThreeCompleteLines(lines,in:clip.bounds)
                        controller.scroll(direction)
                    }
                }
            }
        }
    }
    func testPaneShorterThanMeasuredUnicodeLineUsesCompactFallback() throws {
        let controller = try makeOverlayController();defer { controller.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let pane = CGRect(x:screen.minX+100,y:screen.minY+100,width:420,height:35)
        var settings = Settings();settings.adaptiveTypographyEnabled = true
        let answer = "One\n😀你好 مرحبا\nThree"
        let rect = controller.show(settings:settings,text:answer,pane:pane,cursor:CGPoint(x:pane.midX,y:pane.midY),
            typography:.init(fontName:"Arial-BoldMT",pointSize:28,confidence:1))
        let font = try XCTUnwrap(controller.textView.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont)
        XCTAssertEqual(font.pointSize,9)
        XCTAssertEqual(controller.textView.textContainerInset.width,6)
        XCTAssertEqual(rect.minX,screen.minX+16,accuracy:0.5)
        XCTAssertEqual(rect.minY,screen.minY+16,accuracy:0.5)
        XCTAssertEqual(controller.textView.string,answer)
        let clip = try XCTUnwrap(controller.textView.enclosingScrollView).contentView
        assertThreeCompleteLines(try lineFragments(in:controller),in:clip.bounds)
    }
    func testRepositioningHiddenAnswerPreservesContentAndChangesOnlyPresentation() throws {
        let controller = try makeOverlayController();defer { controller.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let pane = CGRect(x:screen.minX+50,y:screen.minY+20,width:300,height:screen.height-40)
        let cursor = CGPoint(x:pane.midX,y:pane.midY)
        let answer = (1...20).map { "Line \($0)" }.joined(separator:"\n")
        var settings = Settings()
        controller.show(settings:settings,text:answer,pane:pane,cursor:cursor,style:.light)
        controller.scroll(.down);controller.toggleVisibility()
        XCTAssertTrue(controller.hasAnswer);XCTAssertFalse(controller.isVisible)
        settings.overlayPosition = .pinnedCorner
        controller.reposition(settings:settings,pane:pane,cursor:cursor,style:.sampled(red:31,green:34,blue:39),typography:nil,targetScreen:try XCTUnwrap(NSScreen.main).frame)
        XCTAssertFalse(controller.isVisible);XCTAssertEqual(controller.textView.string,answer)
        XCTAssertEqual(controller.screenRect.minX,screen.minX+16,accuracy:0.5)
        XCTAssertEqual(controller.screenRect.minY,screen.minY+16,accuracy:0.5)
        let font = try XCTUnwrap(controller.textView.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont)
        XCTAssertEqual(font.pointSize,9)
        controller.toggleVisibility();XCTAssertTrue(controller.isVisible)
        controller.dismiss();XCTAssertFalse(controller.hasAnswer)
        controller.toggleVisibility();XCTAssertFalse(controller.isVisible)
    }
    func testFractionalLineHeightsNeverExposePartOfFourthLine() throws {
        let controller = try makeOverlayController();defer { controller.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let pane = CGRect(x:screen.minX+20,y:screen.minY+20,width:420,height:screen.height-40)
        controller.show(settings:Settings(),text:"One\nTwo\nThree\nFour\nFive",pane:pane,cursor:CGPoint(x:pane.midX,y:pane.midY))
        let manager = try XCTUnwrap(controller.textView.layoutManager)
        let clip = try XCTUnwrap(controller.textView.enclosingScrollView).contentView
        var lines:[CGRect] = []
        manager.enumerateLineFragments(forGlyphRange:NSRange(location:0,length:manager.numberOfGlyphs)) { rect,_,_,_,_ in lines.append(rect) }
        for _ in 0..<4 {
            let visible = lines.filter { $0.maxY > clip.bounds.minY+0.1 && $0.minY < clip.bounds.maxY-0.1 }
            XCTAssertEqual(visible.count,3)
            for line in visible {
                XCTAssertGreaterThanOrEqual(line.minY,clip.bounds.minY-0.1)
                XCTAssertLessThanOrEqual(line.maxY,clip.bounds.maxY+0.1)
            }
            controller.scroll(.down)
        }
    }
    func testPinnedCornerOverridesDetectedPaneAndOversizedAdaptiveFont() throws {
        let controller = try makeOverlayController();defer { controller.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        var settings = Settings();settings.overlayPosition = .pinnedCorner;settings.adaptiveTypographyEnabled = true
        let pane = CGRect(x:screen.midX,y:screen.minY+100,width:screen.width/3,height:screen.height/2)
        let rect = controller.show(settings:settings,text:"YES",pane:pane,cursor:CGPoint(x:pane.midX,y:pane.midY),
            typography:.init(fontName:"Arial-BoldMT",pointSize:28,confidence:1))
        XCTAssertEqual(rect.minX,screen.minX+16,accuracy:0.5)
        XCTAssertEqual(rect.minY,screen.minY+16,accuracy:0.5)
        XCTAssertLessThanOrEqual(rect.width,120,"A short answer must not paint a pane-sized background")
        let font = try XCTUnwrap(controller.textView.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont)
        XCTAssertEqual(font.pointSize,9);XCTAssertEqual(controller.textView.textContainerInset.width,6)
    }
    func testFallbackOverrideIgnoresPaneOnNegativeOriginDisplay() {
        let screen = CGRect(x:-1920,y:-300,width:1920,height:1080)
        let pane = CGRect(x:-800,y:20,width:600,height:600)
        let rect = OverlayGeometry.frame(screen:screen,cursor:CGPoint(x:-50,y:400),position:.pinnedCorner,
            pane:pane,contentHeight:42,fallbackPlacement:true)
        XCTAssertEqual(rect.minX,screen.minX+16)
        XCTAssertEqual(rect.minY,screen.minY+16)
    }
    func testPlainTextLeftAlignmentAndTabIndentationFollowActualFont() throws {
        let font = try XCTUnwrap(NSFont(name:"Menlo-Regular",size:14))
        let text = PlainTextRenderer().render("مرحبا\n\treturn value;",font:font)
        let paragraph = try XCTUnwrap(text.attribute(.paragraphStyle,at:0,effectiveRange:nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.alignment,.left)
        let expected = ("    " as NSString).size(withAttributes:[.font:font]).width
        XCTAssertEqual(paragraph.defaultTabInterval,expected,accuracy:0.5)
        XCTAssertTrue(paragraph.tabStops.isEmpty)
    }
    func testUnicodeBlankLinesLongWordsAndLargeAdaptiveFontsStayFullyVisibleWhileScrolling() throws {
        let controller = try makeOverlayController();defer { controller.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let pane = CGRect(x:screen.minX+20,y:screen.minY+20,width:180,height:screen.height-40)
        var settings = Settings();settings.adaptiveTypographyEnabled = true
        for text in ["One", "One\nTwo", "One\nTwo\nThree", "One\n\nTwo\n\nThree\n",String(repeating:"longword",count:100),
                     "😀你好 مرحبا\ne\u{301} answer\n👨‍👩‍👧‍👦\nFourth\nFifth\n"] {
            for font in ["Arial-BoldMT","Menlo-Regular"] {
                _ = controller.show(settings:settings,text:text,pane:pane,cursor:CGPoint(x:pane.midX,y:pane.minY+1),
                    typography:.init(fontName:font,pointSize:28,confidence:1))
                let manager = try XCTUnwrap(controller.textView.layoutManager)
                let clip = try XCTUnwrap(controller.textView.enclosingScrollView).contentView
                var lines:[CGRect] = []
                manager.enumerateLineFragments(forGlyphRange:NSRange(location:0,length:manager.numberOfGlyphs)) { rect,used,_,_,_ in
                    lines.append(rect)
                    XCTAssertLessThanOrEqual(used.maxY,rect.maxY+0.5,"Tall fallback glyphs must fit their line")
                    XCTAssertGreaterThanOrEqual(used.minX,-0.5)
                    XCTAssertLessThanOrEqual(used.maxX,controller.textView.textContainer!.containerSize.width+0.5,
                        "Long tokens must wrap without clipping at the right edge")
                }
                if manager.extraLineFragmentTextContainer != nil { lines.append(manager.extraLineFragmentRect) }
                for _ in 0..<20 {
                    let visible = lines.filter { $0.maxY > clip.bounds.minY+0.5 && $0.minY < clip.bounds.maxY-0.5 }
                    XCTAssertLessThanOrEqual(visible.count,3)
                    for line in visible {
                        XCTAssertGreaterThanOrEqual(line.minY,clip.bounds.minY-0.5)
                        XCTAssertLessThanOrEqual(line.maxY,clip.bounds.maxY+0.5)
                    }
                    controller.scroll(.down)
                }
                XCTAssertTrue(pane.contains(controller.screenRect))
            }
        }
    }
    func testLongAnswersShowAtMostThreeCompleteLinesAndScrollOnLineBoundaries() throws {
        let controller = try makeOverlayController(); defer { controller.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let pane = CGRect(x:screen.minX + 40,y:screen.minY + 40,width:420,height:screen.height - 80)
        _ = controller.show(settings:Settings(),text:(1...30).map { "Line \($0)" }.joined(separator:"\n"),
                            pane:pane,cursor:CGPoint(x:pane.midX,y:pane.midY))
        let manager = try XCTUnwrap(controller.textView.layoutManager)
        var lines: [CGRect] = []
        manager.enumerateLineFragments(forGlyphRange:NSRange(location:0,length:manager.numberOfGlyphs)) { rect,_,_,_,_ in lines.append(rect) }
        let clip = try XCTUnwrap(controller.textView.enclosingScrollView).contentView
        XCTAssertEqual(clip.bounds.height,lines[2].maxY - lines[0].minY,accuracy:1)
        if let path = ProcessInfo.processInfo.environment["HARNESS_COMPACT_OVERLAY_PREVIEW_PATH"] {
            let root = try XCTUnwrap(controller.panel.contentView)
            root.displayIfNeeded();let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in:root.bounds))
            root.cacheDisplay(in:root.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path))
        }
        for _ in 0..<20 {
            controller.scroll(.down)
            XCTAssertTrue(lines.contains { abs($0.minY - clip.bounds.minY) < 1 })
            let visible = lines.filter { $0.minY >= clip.bounds.minY - 0.5 && $0.maxY <= clip.bounds.maxY + 0.5 }
            XCTAssertLessThanOrEqual(visible.count,3)
            XCTAssertEqual(visible.count,3)
        }
        for _ in 0..<20 { controller.scroll(.up) }
        XCTAssertEqual(clip.bounds.minY,0,accuracy:1)
    }

    func testUnknownPaneAlwaysUsesSmallBottomLeftFallback() throws {
        let controller = try makeOverlayController(); defer { controller.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        var settings = Settings(); settings.overlayPosition = .pinnedCorner
        let rect = controller.show(settings:settings,text:"Fallback answer",cursor:CGPoint(x:screen.midX,y:screen.midY),
                                   style:.sampled(red:31,green:34,blue:39))
        XCTAssertEqual(rect.minX,screen.minX + 16,accuracy:1)
        XCTAssertEqual(rect.minY,screen.minY + 16,accuracy:1)
        let font = try XCTUnwrap(controller.textView.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont)
        XCTAssertEqual(font.pointSize,9)
        let red = try XCTUnwrap(controller.panel.contentView?.layer?.backgroundColor?.components?.first)
        XCTAssertEqual(red,31.0/255,accuracy:0.01)
    }
    private func makeOverlayController() throws -> OverlayController {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else {
            throw XCTSkip("Native overlay checks require authorized GUI integration opt-in")
        }
        _ = NSApplication.shared
        return OverlayController()
    }
    private func lineFragments(in controller:OverlayController) throws -> [CGRect] {
        let manager = try XCTUnwrap(controller.textView.layoutManager)
        var lines:[CGRect] = []
        manager.enumerateLineFragments(forGlyphRange:NSRange(location:0,length:manager.numberOfGlyphs)) { rect,_,_,_,_ in lines.append(rect) }
        if manager.extraLineFragmentTextContainer != nil,manager.extraLineFragmentRect.height > 0 {
            lines.append(manager.extraLineFragmentRect)
        }
        return lines
    }
    private func assertThreeCompleteLines(_ lines:[CGRect],in viewport:CGRect,file:StaticString = #filePath,line:UInt = #line) {
        let visible = lines.filter { $0.maxY > viewport.minY+0.1 && $0.minY < viewport.maxY-0.1 }
        XCTAssertEqual(visible.count,3,file:file,line:line)
        for fragment in visible {
            XCTAssertGreaterThanOrEqual(fragment.minY,viewport.minY-0.1,file:file,line:line)
            XCTAssertLessThanOrEqual(fragment.maxY,viewport.maxY+0.1,file:file,line:line)
        }
    }
}
