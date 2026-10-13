import CoreGraphics
import ImageIO
import XCTest
@testable import HarnessEmitter

final class PaneLocatorTests: XCTestCase {
    func testWindowColorEdgesWithoutInternalDividerRemainUncertain() throws {
        let context = try XCTUnwrap(CGContext(data:nil,width:1600,height:900,bitsPerComponent:8,bytesPerRow:6400,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:0,alpha:1));context.fill(CGRect(x:0,y:0,width:1600,height:900))
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:250,y:50,width:1000,height:800))
        XCTAssertNil(PaneLocator.locate(in:try XCTUnwrap(context.makeImage())),"A window outline is not evidence of left/right panes")
    }
    func testFaintPartialRailInsideWindowIsExcludedInBothThemesAndAtRetinaScale() throws {
        for dark in [false,true] {
            for scale in [1,2] {
                let context = CGContext(data:nil,width:1600*scale,height:900*scale,bitsPerComponent:8,
                    bytesPerRow:6400*scale,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                context.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
                context.setFillColor(CGColor(gray:dark ? 0.5 : 0.1,alpha:1)); context.fill(CGRect(x:0,y:0,width:1600,height:900))
                let body = dark ? 20.0 : 255.0
                context.setFillColor(CGColor(gray:body/255,alpha:1)); context.fill(CGRect(x:180,y:0,width:1420,height:800))
                // The navigation seam is only seven RGB levels away from the page;
                // its selected item continues across the seam in the lower half.
                context.setFillColor(CGColor(gray:(body + (dark ? 7 : -7))/255,alpha:1))
                context.fill(CGRect(x:330,y:480,width:1,height:320))
                context.setFillColor(CGColor(gray:0.5,alpha:1)); context.fill(CGRect(x:960,y:0,width:2,height:800))
                let pane = try XCTUnwrap(PaneLocator.locate(in:context.makeImage()!))
                XCTAssertEqual(pane.minX*1600,331,accuracy:3)
                XCTAssertEqual(pane.maxX*1600,959,accuracy:3)
            }
        }
    }

    func testWideRailInsideWindowCannotBeSelectedAsContent() throws {
        let context = CGContext(data:nil,width:1600,height:900,bitsPerComponent:8,bytesPerRow:6400,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(x:0,y:0,width:1600,height:900))
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:180,y:0,width:1420,height:800))
        context.setFillColor(CGColor(gray:0.75,alpha:1))
        context.fill(CGRect(x:460,y:480,width:1,height:320)); context.fill(CGRect(x:960,y:0,width:2,height:800))
        let pane = try XCTUnwrap(PaneLocator.locate(in:context.makeImage()!))
        XCTAssertEqual(pane.minX*1600,461,accuracy:3)
        XCTAssertEqual(pane.maxX*1600,959,accuracy:3)
    }
    func testColorOnlyFaintSidebarSeamIsLocatedAtItsActualEdge() throws {
        for dark in [false,true] {
            let context = CGContext(data:nil,width:1600,height:900,bitsPerComponent:8,bytesPerRow:6400,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            let body = dark ? 20.0 : 255.0
            context.setFillColor(CGColor(gray:body/255,alpha:1)); context.fill(CGRect(x:0,y:0,width:1600,height:900))
            context.setFillColor(CGColor(gray:(body + (dark ? 7 : -7))/255,alpha:1))
            context.fill(CGRect(x:0,y:480,width:130,height:320))
            context.setFillColor(CGColor(gray:0.5,alpha:1)); context.fill(CGRect(x:900,y:0,width:2,height:800))
            let pane = try XCTUnwrap(PaneLocator.locate(in:context.makeImage()!))
            XCTAssertEqual(pane.minX*1600,131,accuracy:2)
            XCTAssertEqual(pane.maxX*1600,899,accuracy:2)
        }
    }
    private func partialSidebar(split:Bool,dark:Bool,sidebar:Int = 130,retina:Int = 1) -> CGImage {
        let context = CGContext(data:nil,width:1600*retina,height:900*retina,bitsPerComponent:8,bytesPerRow:6400*retina,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.scaleBy(x:CGFloat(retina),y:CGFloat(retina))
        context.setFillColor(CGColor(gray:dark ? 0.05 : 1,alpha:1)); context.fill(CGRect(x:0,y:0,width:1600,height:900))
        context.setFillColor(CGColor(gray:dark ? 0.02 : 0.9,alpha:1)); context.fill(CGRect(x:0,y:500,width:sidebar,height:300))
        context.setFillColor(CGColor(gray:dark ? 0.2 : 0.75,alpha:1))
        context.fill(CGRect(x:sidebar,y:500,width:1,height:300))
        if split { context.fill(CGRect(x:900,y:0,width:2,height:800)) }
        return context.makeImage()!
    }
    func testShortSidebarBoundaryKeepsSplitPaneOutOfNavigationInBothThemes() throws {
        for dark in [false,true] {
            let pane = try XCTUnwrap(PaneLocator.locate(in:partialSidebar(split:true,dark:dark)))
            XCTAssertEqual(pane.minX*1600,131,accuracy:3)
            XCTAssertEqual(pane.maxX*1600,899,accuracy:3)
            XCTAssertEqual(pane.minY,100.0/900,accuracy:0.01)
            XCTAssertGreaterThan(pane.height,0.85)
        }
    }
    func testShortSidebarAndSinglePaneSurviveRetinaDownsampling() throws {
        for split in [false,true] {
            for dark in [false,true] {
                let pane = try XCTUnwrap(PaneLocator.locate(in:partialSidebar(split:split,dark:dark,retina:2)))
                XCTAssertEqual(pane.minX*1600,131,accuracy:3)
                XCTAssertEqual(pane.maxX*1600,split ? 899 : 1599,accuracy:3)
            }
        }
    }
    func testSingleContentPaneExtendsToRightEdgeAfterShortSidebarInBothThemes() throws {
        for dark in [false,true] {
            let pane = try XCTUnwrap(PaneLocator.locate(in:partialSidebar(split:false,dark:dark)))
            XCTAssertEqual(pane.minX*1600,131,accuracy:3)
            XCTAssertEqual(pane.maxX*1600,1599,accuracy:3)
            XCTAssertGreaterThan(pane.height,0.85)
        }
    }
    func testWideNavigationRailIsNotMistakenForCroppedContent() throws {
        let pane = try XCTUnwrap(PaneLocator.locate(in:partialSidebar(split:true,dark:false,sidebar:280)))
        XCTAssertEqual(pane.minX*1600,281,accuracy:3)
        XCTAssertEqual(pane.maxX*1600,899,accuracy:3)
    }
    func testStackedAnswerCardsCannotBecomePaneDividers() throws {
        for dark in [false,true] {
            let image = partialSidebar(split:true,dark:dark)
            let context = CGContext(data:nil,width:1600,height:900,bitsPerComponent:8,bytesPerRow:6400,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image,in:CGRect(x:0,y:0,width:1600,height:900))
            context.setFillColor(CGColor(gray:0.5,alpha:1))
            for y in stride(from:50,through:530,by:160) {
                for x in [300,700] { context.fill(CGRect(x:x,y:y,width:1,height:100)) }
            }
            let pane = try XCTUnwrap(PaneLocator.locate(in:context.makeImage()!))
            XCTAssertEqual(pane.minX*1600,131,accuracy:3)
            XCTAssertEqual(pane.maxX*1600,899,accuracy:3)
        }
    }
    private func fixture(width: Int = 1744, height: Int = 900, retina: Int = 1, dividers: Bool = true, background: CGColor = CGColor(gray:13.0 / 255,alpha:1), divider: CGColor = CGColor(gray:45.0 / 255,alpha:1)) -> CGImage {
        let context = CGContext(data:nil,width:width * retina,height:height * retina,bitsPerComponent:8,
            bytesPerRow:width * retina * 4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.scaleBy(x:CGFloat(retina),y:CGFloat(retina))
        context.setFillColor(background); context.fill(CGRect(x:0,y:0,width:width,height:height))
        if dividers {
            context.setFillColor(divider)
            let ratio = CGFloat(width) / 1744
            for x in [63.0,116.0,707.0,797.0,1427.0] {
                context.fill(CGRect(x:x * ratio,y:0,width:1,height:CGFloat(height) * 0.8))
            }
        }
        return context.makeImage()!
    }
    func testLocatesContentPaneAndSkipsNarrowNavigationAndEditorGutters() throws {
        for scale in [1,2] {
            let pane = try XCTUnwrap(PaneLocator.locate(in:fixture(retina:scale)))
            XCTAssertEqual(pane.minX * 1744,117,accuracy:3)
            XCTAssertEqual(pane.maxX * 1744,706,accuracy:3)
            XCTAssertEqual(pane.minY,0.2,accuracy:0.01)
            XCTAssertEqual(pane.height,0.8,accuracy:0.01)
        }
        let resized = try XCTUnwrap(PaneLocator.locate(in:fixture(width:1200,height:800)))
        XCTAssertEqual(resized.minX,117.0 / 1744,accuracy:0.003)
        XCTAssertEqual(resized.maxX,706.0 / 1744,accuracy:0.003)
    }
    func testLargeNonRetinaDisplayPreservesOnePixelDividers() throws {
        let pane = try XCTUnwrap(PaneLocator.locate(in:fixture(width:3840,height:2160)))
        XCTAssertEqual(pane.minX,117.0 / 1744,accuracy:0.003)
        XCTAssertEqual(pane.maxX,706.0 / 1744,accuracy:0.003)
    }
    func testLightAndColoredPanesKeepTheirDividerPlacement() throws {
        for (background, divider) in [
            (CGColor(gray:1,alpha:1), CGColor(gray:0.75,alpha:1)),
            (CGColor(srgbRed:0.1,green:0.2,blue:0.4,alpha:1), CGColor(srgbRed:0.3,green:0.45,blue:0.7,alpha:1)),
            (CGColor(srgbRed:1,green:0.95,blue:0.8,alpha:1), CGColor(srgbRed:0.6,green:0.5,blue:0.3,alpha:1))
        ] {
            let pane = try XCTUnwrap(PaneLocator.locate(in:fixture(background:background,divider:divider)))
            XCTAssertEqual(pane.minX,117.0 / 1744,accuracy:0.003)
            XCTAssertEqual(pane.maxX,706.0 / 1744,accuracy:0.003)
        }
    }

    func testDividerAlsoSeparatesPanesWithDifferentBackgrounds() throws {
        let image = fixture(background:CGColor(gray:1,alpha:1),divider:CGColor(gray:0.5,alpha:1))
        let context = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        context.setFillColor(CGColor(gray:0.85,alpha:1));context.fill(CGRect(x:708,y:0,width:86,height:720))
        let pane = try XCTUnwrap(PaneLocator.locate(in:context.makeImage()!))
        XCTAssertEqual(pane.minX,117.0/1744,accuracy:0.003)
        XCTAssertEqual(pane.maxX,706.0/1744,accuracy:0.003)
    }

    func testFlatPageCannotInventPaneBoundaries() {
        XCTAssertNil(PaneLocator.locate(in:fixture(dividers:false)))
    }
    func testSingleDividerUsesTheImageEdgeAndSkipsTheScrollbar() throws {
        for (scale,thickness) in [(1,1),(1,6),(2,2),(2,6)] {
            let context = CGContext(data:nil,width:1600*scale,height:900*scale,bitsPerComponent:8,
                bytesPerRow:1600*scale*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
            context.setFillColor(CGColor(gray:0,alpha:1));context.fill(CGRect(x:0,y:0,width:1600,height:900))
            context.setFillColor(CGColor(gray:0.05,alpha:1));context.fill(CGRect(x:0,y:50,width:1600,height:800))
            context.setFillColor(CGColor(gray:0.4,alpha:1));context.fill(CGRect(x:600,y:50,width:thickness,height:800))
            context.setFillColor(CGColor(gray:0.8,alpha:1));context.fill(CGRect(x:590,y:50,width:8,height:300))
            let pane = try XCTUnwrap(PaneLocator.locate(in:context.makeImage()!))
            XCTAssertEqual(pane.minX,0,accuracy:0.002)
            XCTAssertEqual(pane.maxX,600.0/1600,accuracy:0.003)
            XCTAssertEqual(pane.minY,50.0/900,accuracy:0.003)
            XCTAssertEqual(pane.height,800.0/900,accuracy:0.005)
        }
    }
    func testCroppedReferenceUsesLeftPaneInsteadOfTheCodeEditor() throws {
        guard let path = ProcessInfo.processInfo.environment["HARNESS_CROPPED_REFERENCE_PATH"] else { throw XCTSkip("Local cropped reference opt-in") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        let pane = try XCTUnwrap(PaneLocator.locate(in:image))
        XCTAssertEqual(pane.minX,0,accuracy:0.003)
        XCTAssertEqual(pane.maxX,792.0/2048,accuracy:0.005)
        XCTAssertEqual(pane.minY,52.0/1142,accuracy:0.005)
        XCTAssertGreaterThan(pane.height,0.85)
    }
    func testDesktopMarginCannotBecomeThePaneWhenAWindowHasAColorBoundary() throws {
        let context = CGContext(data:nil,width:1600,height:900,bitsPerComponent:8,bytesPerRow:1600*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.setFillColor(CGColor(gray:0,alpha:1));context.fill(CGRect(x:0,y:0,width:1600,height:900))
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:400,y:50,width:1000,height:800))
        context.setFillColor(CGColor(gray:0.5,alpha:1));context.fill(CGRect(x:900,y:50,width:2,height:800))
        let pane = try XCTUnwrap(PaneLocator.locate(in:context.makeImage()!))
        XCTAssertGreaterThan(pane.minX,0.24)
        XCTAssertEqual(pane.maxX,900.0/1600,accuracy:0.005)
    }
    func testSelectedWindowCoordinatesRespectRetinaAndNegativeDisplayOrigin() {
        let pane = CGRect(x:0.1,y:0.2,width:0.4,height:0.8)
        let result = PaneLocator.screenRect(pane,capturedBounds:CGRect(x:-1800,y:100,width:1200,height:800),
            displayCG:CGRect(x:-1920,y:0,width:1920,height:1080),
            displayAppKit:CGRect(x:-1920,y:-200,width:1920,height:1080))
        XCTAssertEqual(result,CGRect(x:-1680,y:-20,width:480,height:640))
        let roundTrip = PaneLocator.captureRect(result,capturedBounds:CGRect(x:-1800,y:100,width:1200,height:800),
            displayCG:CGRect(x:-1920,y:0,width:1920,height:1080),displayAppKit:CGRect(x:-1920,y:-200,width:1920,height:1080))
        XCTAssertEqual(roundTrip?.minX ?? 0,pane.minX,accuracy:0.0001)
        XCTAssertEqual(roundTrip?.minY ?? 0,pane.minY,accuracy:0.0001)
        XCTAssertEqual(roundTrip?.width ?? 0,pane.width,accuracy:0.0001)
        XCTAssertEqual(roundTrip?.height ?? 0,pane.height,accuracy:0.0001)
    }
    func testProvidedScreenshotPaneWhenExplicitlyOptedIn() throws {
        guard let path = ProcessInfo.processInfo.environment["HARNESS_PANE_REFERENCE_PATH"] else { throw XCTSkip("Local reference image opt-in") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        let pane = try XCTUnwrap(PaneLocator.locate(in:image))
        XCTAssertEqual(pane.minX,116.0 / 1744,accuracy:0.004)
        XCTAssertEqual(pane.maxX,707.0 / 1744,accuracy:0.004)
        XCTAssertGreaterThan(pane.height,0.7)
    }
}
