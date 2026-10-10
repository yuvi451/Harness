import AppKit
import XCTest
import ImageIO
@testable import HarnessEmitter

@MainActor final class AppearanceTests: XCTestCase {
    private let pane = CGRect(x:0.125,y:0,width:0.75,height:1)
    private func fixture(background: NSColor,ink: NSColor,font: String,size: CGFloat,scale: CGFloat = 1) -> CGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(800*scale),pixelsHigh:Int(500*scale),
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)!
        NSGraphicsContext.current!.cgContext.scaleBy(x:scale,y:scale)
        NSColor.magenta.setFill();NSRect(x:0,y:0,width:800,height:500).fill()
        background.setFill();NSRect(x:100,y:0,width:600,height:500).fill()
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont(name:font,size:size)!, .foregroundColor:ink]
        for y in stride(from:70,through:410,by:50) {
            ("Simple loops and arrays solve this problem." as NSString).draw(at:NSPoint(x:122,y:y),withAttributes:attrs)
        }
        NSGraphicsContext.restoreGraphicsState();return bitmap.cgImage!
    }
    private func assertBackground(_ style: OverlayStyle,_ expected: NSColor,file: StaticString = #filePath,line: UInt = #line) {
        let actual = style.background.usingColorSpace(.sRGB)!, expected = expected.usingColorSpace(.sRGB)!
        XCTAssertEqual(actual.redComponent,expected.redComponent,accuracy:0.015,file:file,line:line)
        XCTAssertEqual(actual.greenComponent,expected.greenComponent,accuracy:0.015,file:file,line:line)
        XCTAssertEqual(actual.blueComponent,expected.blueComponent,accuracy:0.015,file:file,line:line)
        XCTAssertEqual(actual.alphaComponent,1,file:file,line:line)
    }
    func testColoredCodeCannotTintTheBackgroundOrChangeTheFixedTypography() throws {
        let background = NSColor(srgbRed:0.08,green:0.13,blue:0.25,alpha:1)
        let image = fixture(background:background,ink:.red,font:"Georgia",size:24,scale:2)
        let style = CapturedAppearance.analyze(image:image,pane:pane,cursorY:0.4)
        assertBackground(style,background)
        let rendered = PlainTextRenderer().render("answer",style:style)
        let font = try XCTUnwrap(rendered.attribute(.font,at:0,effectiveRange:nil) as? NSFont)
        XCTAssertEqual(font.fontName,"Satoshi-Regular");XCTAssertEqual(font.pointSize,14)
        let ink = try XCTUnwrap((rendered.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertEqual(ink.redComponent,1);XCTAssertEqual(ink.greenComponent,1);XCTAssertEqual(ink.blueComponent,1)
    }
    func testBackgroundTracksPaneColorsWhileInkAndTypographyStayFixed() {
        for (background,ink,font,size,scale,expected) in [
            (NSColor.white,NSColor.red,"ArialMT",CGFloat(16),CGFloat(1),OverlayStyle.light),
            (NSColor(srgbRed:0.08,green:0.13,blue:0.25,alpha:1),NSColor.orange,"Georgia",CGFloat(24),CGFloat(2),.dark),
            (NSColor(srgbRed:1,green:0.95,blue:0.8,alpha:1),NSColor.blue,"Menlo-Regular",CGFloat(30),CGFloat(2),.light)
        ] {
            let style = CapturedAppearance.analyze(image:fixture(background:background,ink:ink,font:font,size:size,scale:scale),pane:pane,cursorY:0.4)
            assertBackground(style,background)
            XCTAssertEqual(style.font.fontName,"Satoshi-Regular");XCTAssertEqual(style.font.pointSize,14)
            XCTAssertEqual(style.foreground,expected.foreground)
        }
    }
    func testReferenceScreenshotsAlwaysUseWhiteTextAndTheFixedFont() throws {
        let paths = ["HARNESS_PANE_REFERENCE_PATH","HARNESS_CROPPED_REFERENCE_PATH"].compactMap { ProcessInfo.processInfo.environment[$0] }
        guard !paths.isEmpty else { throw XCTSkip("Local references opt-in") }
        for path in paths {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
            let area = try XCTUnwrap(PaneLocator.locate(in:image))
            let style = CapturedAppearance.analyze(image:image,pane:area,cursorY:0.6)
            XCTAssertEqual(style.foreground,NSColor.white)
            XCTAssertEqual(style.font.fontName,"Satoshi-Regular");XCTAssertEqual(style.font.pointSize,14)
        }
    }
    func testBlankPaneAndClampedCursorRemainReadable() {
        let image = fixture(background:.white,ink:.white,font:"ArialMT",size:16)
        for y: CGFloat in [-10,0.4,10] { XCTAssertEqual(CapturedAppearance.analyze(image:image,pane:pane,cursorY:y),.light) }
    }
    func testSamplingFollowsCursorBandAndIgnoresNeighboringPane() throws {
        let context = try XCTUnwrap(CGContext(data:nil,width:800,height:500,bitsPerComponent:8,bytesPerRow:800*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.magenta.cgColor);context.fill(CGRect(x:0,y:0,width:800,height:500))
        let navy = NSColor(srgbRed:0.08,green:0.13,blue:0.25,alpha:1)
        let cream = NSColor(srgbRed:1,green:0.95,blue:0.8,alpha:1)
        // CGContext drawing starts at the bottom; CGImage crop coordinates start at the top.
        context.setFillColor(navy.cgColor);context.fill(CGRect(x:100,y:250,width:600,height:250))
        context.setFillColor(cream.cgColor);context.fill(CGRect(x:100,y:0,width:600,height:250))
        let image = try XCTUnwrap(context.makeImage())
        assertBackground(CapturedAppearance.analyze(image:image,pane:pane,cursorY:0.1),navy)
        assertBackground(CapturedAppearance.analyze(image:image,pane:pane,cursorY:0.9),cream)
    }
    func testInvalidAndCancelledAnalysisDoesNotReadOutsideTheImage() async {
        let image = fixture(background:.white,ink:.black,font:"ArialMT",size:16)
        for (area,y) in [(CGRect.null,CGFloat(0.5)),(CGRect.zero,CGFloat(0.5)),(pane,CGFloat.nan),(CGRect(x:2,y:2,width:1,height:1),CGFloat(0.5))] {
            XCTAssertEqual(CapturedAppearance.analyze(image:image,pane:area,cursorY:y),.fallback)
        }
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return CapturedAppearance.analyze(image:image,pane:CGRect(x:0,y:0,width:1,height:1),cursorY:0.5)
        }
        let result = await task.value;XCTAssertEqual(result,.fallback)
    }
    func testNativePalettesKeepTheFixedFontPaneGeometryAndHostFocus() throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else { throw XCTSkip("Native overlay opt-in") }
        let controller = OverlayController();defer { controller.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let area = CGRect(x:screen.minX+100,y:screen.minY,width:600,height:screen.height)
        let sampled = CapturedAppearance.analyze(image:fixture(background:NSColor(srgbRed:0.08,green:0.13,blue:0.25,alpha:1),ink:.red,font:"Georgia",size:24),pane:pane,cursorY:0.4)
        for style in [OverlayStyle.dark,.light,sampled] {
            let rect = controller.show(settings:.init(),text:"Simple loops and arrays solve this problem.\nReturn the required answer.",pane:area,cursor:CGPoint(x:200,y:area.maxY-100),style:style)
            XCTAssertEqual(rect.width,600);XCTAssertEqual(rect.minX,area.minX)
            let background = NSColor(cgColor:try XCTUnwrap(controller.panel.contentView?.layer?.backgroundColor))!.usingColorSpace(.sRGB)!
            let expected = style.background.usingColorSpace(.sRGB)!
            XCTAssertEqual(background.redComponent,expected.redComponent,accuracy:0.001)
            XCTAssertEqual(background.greenComponent,expected.greenComponent,accuracy:0.001)
            XCTAssertEqual(background.blueComponent,expected.blueComponent,accuracy:0.001)
            let text = try XCTUnwrap(controller.textView.textStorage)
            XCTAssertEqual((text.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.fontName,"Satoshi-Regular")
            XCTAssertEqual((text.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.pointSize,14)
            XCTAssertEqual(text.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor,style.foreground)
            XCTAssertFalse(controller.panel.isKeyWindow);XCTAssertTrue(controller.panel.ignoresMouseEvents)
            if let path = ProcessInfo.processInfo.environment["HARNESS_MONOCHROME_PREVIEW_PATH"],style == .light {
                let root = try XCTUnwrap(controller.panel.contentView)
                root.displayIfNeeded();let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in:root.bounds))
                root.cacheDisplay(in:root.bounds,to:bitmap)
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path))
            }
            if let path = ProcessInfo.processInfo.environment["HARNESS_BACKGROUND_PREVIEW_PATH"],style == sampled {
                let root = try XCTUnwrap(controller.panel.contentView)
                root.displayIfNeeded();let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in:root.bounds))
                root.cacheDisplay(in:root.bounds,to:bitmap)
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path))
            }
        }
    }
}
