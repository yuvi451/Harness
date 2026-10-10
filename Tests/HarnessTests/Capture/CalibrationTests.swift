import Foundation
import CoreGraphics
import XCTest
@testable import HarnessCore

final class CalibrationTests: XCTestCase {
    func testReferencePatternMatchesAtOneFractionalAndRetinaScale() throws {
        for scale in [1.0, 1.5, 2.0] {
            let fixture = try CalibrationFixture(scale: scale)
            let result = CalibrationAnalyzer().analyze(fixture.input())
            XCTAssertEqual(result.outcome, .matched)
            XCTAssertEqual(result.overlayInCapture, true)
            XCTAssertGreaterThanOrEqual(result.confidence, 0.9)
            XCTAssertEqual(result.reason, .referenceMatched)
            XCTAssertEqual(result.referenceColorSpace, "sRGB")
        }
    }

    func testRGBToleranceIsInclusiveAndDoesNotAcceptBeyondTolerance() throws {
        let accepted = try CalibrationFixture(colorDelta: 24)
        XCTAssertEqual(CalibrationAnalyzer().analyze(accepted.input()).outcome, .matched)
        let rejected = try CalibrationFixture(colorDelta: 25)
        XCTAssertEqual(CalibrationAnalyzer().analyze(rejected.input(evidence: .confirmedUnoccluded)).outcome, .absent)
    }

    func testNegativeVirtualOriginsAndSelectedWindowBoundsMapToNativePixels() throws {
        let display = CGRect(x: -400, y: -200, width: 200, height: 100)
        let appKit = CGRect(x: -400, y: 100, width: 200, height: 100)
        let captured = CGRect(x: -380, y: -190, width: 120, height: 60)
        let fixture = try CalibrationFixture(scale: 1.5, appKitFrame: appKit, cgFrame: display, capturedBounds: captured,
            patch: CGRect(x: -360, y: 155, width: 16, height: 16), overlay: CGRect(x: -370, y: 140, width: 80, height: 40))
        let result = CalibrationAnalyzer().analyze(fixture.input(source: .selectedWindow))
        XCTAssertEqual(result.outcome, .matched)
        let bounds = try XCTUnwrap(result.pixelPatchBounds)
        XCTAssertEqual(bounds.minX, 30, accuracy: 0.001)
        XCTAssertEqual(bounds.minY, 28.5, accuracy: 0.001)
        XCTAssertEqual(bounds.width, 24, accuracy: 0.001)
        XCTAssertEqual(bounds.height, 24, accuracy: 0.001)
    }

    func testFractionalWindowBoundsAcceptNativeCeilingPixelDimensions() throws {
        let fixture = try CalibrationFixture(scale: 1.5, appKitFrame: CGRect(x: 0, y: 0, width: 121, height: 81),
            cgFrame: CGRect(x: 0, y: 0, width: 121, height: 81), capturedBounds: CGRect(x: 0, y: 0, width: 120.2, height: 80.2))
        XCTAssertEqual(CalibrationAnalyzer().analyze(fixture.input(source: .selectedWindow)).outcome, .matched)
    }

    func testRotationAlreadyAppliedByScreenshotIsNotAppliedTwice() throws {
        for rotation in [0.0, 90.0, 180.0, 270.0] {
            let fixture = try CalibrationFixture(rotation: rotation, orientation: .displayOriented)
            XCTAssertEqual(CalibrationAnalyzer().analyze(fixture.input()).outcome, .matched)
        }
    }

    func testExplicitUnrotatedNativeImagesSupportAllQuarterTurns() throws {
        for rotation in [0.0, 90.0, 180.0, 270.0] {
            let fixture = try CalibrationFixture(scale: 1.5, rotation: rotation, orientation: .unrotatedNative)
            XCTAssertEqual(CalibrationAnalyzer().analyze(fixture.input()).outcome, .matched)
        }
    }

    func testSameMagentaWithoutAsymmetricBlackAndWhiteCannotMatch() throws {
        for pattern in [CalibrationFixture.Pattern.magentaOnly, .reversedMarkers] {
            let fixture = try CalibrationFixture(pattern: pattern)
            let result = CalibrationAnalyzer().analyze(fixture.input(evidence: .confirmedUnoccluded))
            XCTAssertEqual(result.outcome, .absent)
            XCTAssertEqual(result.reason, .referenceNotObserved)
        }
    }

    func testMissingIndependentVisibilityEvidenceNeverProducesFalseNegative() throws {
        let fixture = try CalibrationFixture(pattern: .missing)
        for source in CaptureSource.allCases {
            let result = CalibrationAnalyzer().analyze(fixture.input(source: source))
            XCTAssertEqual(result.outcome, .indeterminate)
            XCTAssertNil(result.overlayInCapture)
            XCTAssertEqual(result.reason, .negativeEvidenceUnavailable)
        }
        let confirmed = CalibrationAnalyzer().analyze(fixture.input(evidence: .confirmedUnoccluded))
        XCTAssertEqual(confirmed.outcome, .absent)
        XCTAssertEqual(confirmed.overlayInCapture, false)
    }

    func testOcclusionAndInvisibleOverlayAreIndeterminateEvenWhenPixelColorsMatch() throws {
        let fixture = try CalibrationFixture()
        XCTAssertEqual(CalibrationAnalyzer().analyze(fixture.input(evidence: .knownOccluded)).reason, .patchOccluded)
        XCTAssertEqual(CalibrationAnalyzer().analyze(fixture.input(visibility: .notVisible)).reason, .overlayNotVisible)
        XCTAssertEqual(CalibrationAnalyzer().analyze(fixture.input(visibility: .unknown)).reason, .overlayVisibilityUnknown)
    }

    func testMissingOrUnstableGeometryIsIndeterminate() throws {
        let fixture = try CalibrationFixture()
        var input = fixture.input(); input.geometry = nil
        XCTAssertEqual(CalibrationAnalyzer().analyze(input).reason, .geometryUnavailable)
        input = fixture.input(); input.overlayScreenRect = nil
        XCTAssertEqual(CalibrationAnalyzer().analyze(input).reason, .geometryUnavailable)
        input = fixture.input(); input.geometryStable = false
        XCTAssertEqual(CalibrationAnalyzer().analyze(input).reason, .geometryChanged)
    }

    func testClippedPatchOffscreenAndPatchOutsideOverlayAreIndeterminate() throws {
        let fixture = try CalibrationFixture()
        var input = fixture.input()
        input.patchScreenRect = CGRect(x: -5, y: 30, width: 16, height: 16)
        XCTAssertEqual(CalibrationAnalyzer().analyze(input).reason, .patchOutsideDisplay)
        let clipped = try CalibrationFixture(capturedBounds: CGRect(x: 25, y: 0, width: 95, height: 80))
        XCTAssertEqual(CalibrationAnalyzer().analyze(clipped.input()).reason, .patchOutsideCapture)
        input = fixture.input(); input.overlayScreenRect = CGRect(x: 50, y: 50, width: 40, height: 20)
        XCTAssertEqual(CalibrationAnalyzer().analyze(input).reason, .patchOutsideOverlay)
        input = fixture.input(); input.patchScreenRect = CGRect(x: 20, y: 30, width: 8, height: 16)
        XCTAssertEqual(CalibrationAnalyzer().analyze(input).reason, .invalidPatchGeometry)
    }

    func testInvalidTransformsUnsupportedRotationAndDownscaledInputsAreIndeterminate() throws {
        let fixture = try CalibrationFixture()
        var input = fixture.input(); input.geometry!.displayScale = .nan
        XCTAssertEqual(CalibrationAnalyzer().analyze(input).reason, .invalidTransform)
        input = fixture.input(); input.geometry!.rotationDegrees = 45
        XCTAssertEqual(CalibrationAnalyzer().analyze(input).reason, .unsupportedRotation)
        input = fixture.input(); input.geometry!.displayScale = 2
        XCTAssertEqual(CalibrationAnalyzer().analyze(input).reason, .imageGeometryMismatch)
        input = fixture.input(); input.geometry!.displayID = 0
        XCTAssertEqual(CalibrationAnalyzer().analyze(input).reason, .invalidTransform)
    }

    func testUnsupportedColorSpaceAndPixelFormatAreIndeterminate() throws {
        let fixture = try CalibrationFixture()
        var input = fixture.input(); input.image = try grayImage()
        XCTAssertEqual(CalibrationAnalyzer().analyze(input).reason, .unsupportedPixelFormat)
        input = fixture.input(); input.image = try floatImage()
        XCTAssertEqual(CalibrationAnalyzer().analyze(input).reason, .unsupportedPixelFormat)
    }

    func testCalibrationResultRoundTripsWithoutImageOrScreenContent() throws {
        let fixture = try CalibrationFixture()
        let result = CalibrationAnalyzer().analyze(fixture.input())
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(CalibrationResult.self, from: data), result)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(keys["image"])
        XCTAssertNil(keys["pixels"])
        XCTAssertLessThan(data.count, 2048)
    }
}

private struct CalibrationFixture {
    enum Pattern { case correct, magentaOnly, reversedMarkers, missing }
    let image: CGImage
    let geometry: CalibrationGeometry
    let patch: CGRect
    let overlay: CGRect
    init(scale: Double = 1, rotation: Double = 0, orientation: NativeScreenshotOrientation = .displayOriented,
         appKitFrame: CGRect = CGRect(x: 0, y: 0, width: 120, height: 80),
         cgFrame: CGRect = CGRect(x: 0, y: 0, width: 120, height: 80), capturedBounds: CGRect? = nil,
         patch: CGRect = CGRect(x: 20, y: 30, width: 16, height: 16),
         overlay: CGRect = CGRect(x: 10, y: 20, width: 80, height: 50), pattern: Pattern = .correct, colorDelta: Int = 0) throws {
        self.patch = patch; self.overlay = overlay
        let captured = capturedBounds ?? cgFrame
        geometry = CalibrationGeometry(displayID: 7, appKitDisplayFrame: appKitFrame, cgDisplayFrame: cgFrame,
            capturedBounds: captured, displayScale: scale, rotationDegrees: rotation, screenshotOrientation: orientation)
        let swap = orientation == .unrotatedNative && (rotation == 90 || rotation == 270)
        let width = Int(ceil((swap ? captured.height : captured.width) * scale))
        let height = Int(ceil((swap ? captured.width : captured.height) * scale))
        var bytes = [UInt8](repeating: 60, count: width * height * 4)
        let cgPatch = CGRect(x: cgFrame.minX + patch.minX - appKitFrame.minX,
            y: cgFrame.minY + appKitFrame.maxY - patch.maxY, width: 16, height: 16)
        for y in 0..<height { for x in 0..<width {
            var u = (Double(x) + 0.5) / Double(width), v = (Double(y) + 0.5) / Double(height)
            if orientation == .unrotatedNative {
                switch rotation {
                case 90: (u, v) = (1 - v, u)
                case 180: (u, v) = (1 - u, 1 - v)
                case 270: (u, v) = (v, 1 - u)
                default: break
                }
            }
            let px = captured.minX + u * captured.width - cgPatch.minX
            let py = captured.minY + v * captured.height - cgPatch.minY
            var color = [60, 60, 60]
            if (0..<16).contains(px), (0..<16).contains(py), pattern != .missing {
                color = [255, 0, 127]
                if pattern == .correct {
                    if px < 4 && py < 4 { color = [0, 0, 0] }
                    if px >= 12 && py >= 8 { color = [255, 255, 255] }
                } else if pattern == .reversedMarkers {
                    if px >= 12 && py >= 12 { color = [0, 0, 0] }
                    if px < 4 && py < 8 { color = [255, 255, 255] }
                }
                color = color.map { $0 > 127 ? $0 - colorDelta : $0 + (colorDelta == 0 ? 0 : ($0 == 127 ? -colorDelta : colorDelta)) }
            }
            let offset = (y * width + x) * 4
            bytes[offset] = UInt8(color[0]); bytes[offset + 1] = UInt8(color[1]); bytes[offset + 2] = UInt8(color[2]); bytes[offset + 3] = 255
        }}
        image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    func input(source: CaptureSource = .full, evidence: CalibrationVisibilityEvidence = .unknown,
               visibility: CalibrationOverlayVisibility = .visible) -> CalibrationInput {
        CalibrationInput(image: image, geometry: geometry, overlayScreenRect: overlay, patchScreenRect: patch, captureSource: source,
            overlayVisibility: visibility, visibilityEvidence: evidence, geometryStable: true)
    }
}
private func grayImage() throws -> CGImage {
    try XCTUnwrap(CGImage(width: 120, height: 80, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 120,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: CGDataProvider(data: Data(repeating: 0, count: 120 * 80) as CFData)!,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}
private func floatImage() throws -> CGImage {
    let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 32, bytesPerRow: 120 * 16,
        space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
    return try XCTUnwrap(context.makeImage())
}
