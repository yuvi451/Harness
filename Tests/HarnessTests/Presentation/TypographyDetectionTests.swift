import AppKit
import CoreText
import XCTest
@testable import HarnessCore
@testable import HarnessEmitter

@MainActor final class TypographyDetectionTests: XCTestCase {
    func testExpiredFontComparisonDoesNotReturnAPartiallyRankedGuess() throws {
        let text = "Simple loops and arrays solve this problem"
        let image = try XCTUnwrap(TypographyDetector.renderSample(text:text,font:CTFontCreateWithName("Menlo-Regular" as CFString,18,nil)))
        XCTAssertNil(TypographyDetector.match(text:text,image:image,logicalScale:1,candidates:["Menlo-Regular"],deadline:0))
    }
    func testGlyphMatchingDoesNotConfuseGrayTextWithLighterFontWeight() throws {
        let text = "Simple loops and arrays solve this problem"
        for name in ["Menlo-Regular","Arial-BoldMT"] {
            let original = try XCTUnwrap(TypographyDetector.renderSample(text:text,font:CTFontCreateWithName(name as CFString,18,nil)))
            for (background,foreground) in [(255,150),(20,190)] {
                let canvas = try XCTUnwrap(CGContext(data:nil,width:original.width,height:original.height,bitsPerComponent:8,
                    bytesPerRow:original.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                canvas.draw(original,in:CGRect(x:0,y:0,width:original.width,height:original.height))
                let bytes = try XCTUnwrap(canvas.data).assumingMemoryBound(to:UInt8.self)
                for i in stride(from:0,to:original.width*original.height*4,by:4) {
                    let coverage = 1-Double(bytes[i])/255
                    let value = UInt8((Double(background)+Double(foreground-background)*coverage).rounded())
                    bytes[i] = value;bytes[i+1] = value;bytes[i+2] = value
                }
                let image = try XCTUnwrap(canvas.makeImage())
                let match = try XCTUnwrap(TypographyDetector.match(text:text,image:image,logicalScale:1,
                    candidates:["ArialMT","Arial-BoldMT","Menlo-Regular","Menlo-Bold"]))
                XCTAssertEqual(match.fontName,name)
                XCTAssertEqual(match.pointSize,18,accuracy:1)
            }
        }
    }
    private func headedFixture(body:String,size:CGFloat,width:Int = 1100) throws -> CGImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:700,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.white.setFill();NSRect(x:0,y:0,width:width,height:700).fill()
        for y in [630,580,530] {
            ("Simple heading title and subtitle" as NSString).draw(at:NSPoint(x:40,y:y),
                withAttributes:[.font:try XCTUnwrap(NSFont(name:"Menlo-Bold",size:26)),.foregroundColor:NSColor.black])
        }
        for y in stride(from:450,through:100,by:-50) {
            (body as NSString).draw(at:NSPoint(x:40,y:y),
                withAttributes:[.font:try XCTUnwrap(NSFont(name:"Menlo-Regular",size:size)),.foregroundColor:NSColor.black])
        }
        return try XCTUnwrap(bitmap.cgImage)
    }
    func testRepeatedBodyTextWinsOverThreeLargeHeadings() async throws {
        let image = try headedFixture(body:"Simple loops and arrays solve this problem",size:20)
        let estimate = await Task.detached { TypographyDetector.analyze(image:image,pane:CGRect(x:0,y:0,width:1,height:1),logicalWidth:1100) }.value
        let result = try XCTUnwrap(estimate)
        XCTAssertEqual(result.fontName,"Menlo-Regular")
        XCTAssertEqual(result.pointSize,20,accuracy:1.5)
    }
    func testAmbiguousSmallBodyTextFallsBackWithoutPromotingHeadings() async throws {
        let image = try headedFixture(body:"Simple loops and arrays solve this problem",size:14)
        let estimate = await Task.detached { TypographyDetector.analyze(image:image,pane:CGRect(x:0,y:0,width:1,height:1),logicalWidth:1100) }.value
        // OCR can merge small adjacent glyphs. An uncertain font must use the
        // default body size rather than retrying a confidently read heading.
        let font = OverlayFontSelection.font(adaptive:estimate,enabled:true,fallbackPlacement:false)
        XCTAssertEqual(font.pointSize,14,accuracy:1.5)
    }
    func testLongBodyLinesRemainEligibleForFontSampling() async throws {
        let body = "Simple loops and arrays solve this problem. Return the required answer after checking all the input values."
        XCTAssertGreaterThan(body.count,90)
        let image = try headedFixture(body:body,size:20,width:1900)
        let estimate = await Task.detached { TypographyDetector.analyze(image:image,pane:CGRect(x:0,y:0,width:1,height:1),logicalWidth:1900) }.value
        let result = try XCTUnwrap(estimate)
        XCTAssertEqual(result.fontName,"Menlo-Regular")
        XCTAssertEqual(result.pointSize,20,accuracy:1.5)
    }
    func testToggleOffAndUncertainMatchesUseDefaultAndFallbackAlwaysUsesNinePoints() throws {
        let bold = AdaptiveTypography(fontName:"Arial-BoldMT",pointSize:20,confidence:0.95)
        XCTAssertEqual(OverlayFontSelection.font(adaptive:bold,enabled:false,fallbackPlacement:false).fontName,"Satoshi-Regular")
        XCTAssertEqual(OverlayFontSelection.font(adaptive:bold,enabled:true,fallbackPlacement:false).pointSize,20)
        XCTAssertTrue(OverlayFontSelection.font(adaptive:bold,enabled:true,fallbackPlacement:false).fontDescriptor.symbolicTraits.contains(.bold))
        for estimate in [AdaptiveTypography(fontName:"ArialMT",pointSize:.nan,confidence:1),
                         AdaptiveTypography(fontName:"ArialMT",pointSize:14,confidence:0.1),
                         AdaptiveTypography(fontName:"missing-font-1234",pointSize:14,confidence:1)] {
            XCTAssertEqual(OverlayFontSelection.font(adaptive:estimate,enabled:true,fallbackPlacement:false).fontName,"Satoshi-Regular")
        }
        XCTAssertEqual(OverlayFontSelection.font(adaptive:bold,enabled:true,fallbackPlacement:true).pointSize,9)
    }
    func testRasterMatcherIdentifiesFamilyWeightAndRetinaSize() throws {
        let text = "Simple loops and arrays solve this problem"
        for name in ["ArialMT","Arial-BoldMT","Menlo-Regular","TimesNewRomanPSMT"] {
            for scale in [1.0,2.0] {
                let font = CTFontCreateWithName(name as CFString,18*scale,nil)
                let rendered = try XCTUnwrap(TypographyDetector.renderSample(text:text,font:font))
                let match = try XCTUnwrap(TypographyDetector.match(text:text,image:rendered,logicalScale:1/scale,
                                                                  candidates:["ArialMT","Arial-BoldMT","Menlo-Regular","TimesNewRomanPSMT"]))
                XCTAssertEqual(match.fontName,name)
                XCTAssertEqual(match.pointSize,18,accuracy:1.5)
                XCTAssertGreaterThanOrEqual(match.confidence,0.62)
            }
        }
    }
    func testBlankCaptureHasNoTypographyAndLocalVisionRecognizesSyntheticText() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:900,pixelsHigh:300,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        NSColor.white.setFill(); NSRect(x:0,y:0,width:900,height:300).fill()
        ("Simple loops and arrays solve this problem" as NSString).draw(at:NSPoint(x:40,y:100),
            withAttributes:[.font:try XCTUnwrap(NSFont(name:"Menlo-Regular",size:20)),.foregroundColor:NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(bitmap.cgImage)
        let blankCanvas = try XCTUnwrap(CGContext(data:nil,width:900,height:300,bitsPerComponent:8,bytesPerRow:3600,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        blankCanvas.setFillColor(CGColor(gray:1,alpha:1));blankCanvas.fill(CGRect(x:0,y:0,width:900,height:300))
        let blank = try XCTUnwrap(blankCanvas.makeImage())
        let empty = await Task.detached { TypographyDetector.analyze(image:blank,pane:CGRect(x:0,y:0,width:1,height:1),logicalWidth:900) }.value
        XCTAssertNil(empty)
        let result = await Task.detached { TypographyDetector.analyze(image:image,pane:CGRect(x:0,y:0,width:1,height:1),logicalWidth:900) }.value
        let match = try XCTUnwrap(result)
        XCTAssertEqual(match.pointSize,20,accuracy:3)
        XCTAssertTrue(match.fontName.contains("Menlo"),"Detected \(match.fontName)")
    }
}
