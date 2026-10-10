import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import XCTest
@testable import HarnessCore
@testable import HarnessEmitter

final class CaptureTests: XCTestCase {
    @MainActor func testZeroDisplayIdentityAndOverflowingGeometryNeverCapture() async throws {
        for display in [CaptureDisplay(id:0, frame:CGRect(x:0,y:0,width:100,height:100), appKitFrame:CGRect(x:0,y:0,width:100,height:100), scale:1, rotation:0),
                        CaptureDisplay(id:1, frame:CGRect(x:1e308,y:0,width:1e308,height:100), appKitFrame:CGRect(x:0,y:0,width:100,height:100), scale:1, rotation:0)] {
            let backend = CaptureBackendStub(image:try syntheticImage())
            backend.content.displays = [display]
            let engine = ScreenCaptureEngine(backend:backend,cursor:{ CGPoint(x:20,y:30) },processID:42,bundleIdentifier:"org.harness.research")
            do { _ = try await engine.capture(settings:Settings()); XCTFail("Invalid native geometry accepted") }
            catch { XCTAssertEqual(error as? CaptureError,.malformedDisplay) }
            XCTAssertEqual(backend.screenshotCalls,0)
        }
    }
    func testCancelledRendererDoesNotAllocateOrPublishAnImage() async throws {
        let image = try syntheticImage()
        let pending = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MemoryImageRenderer().render(image,width:8000,height:8000,masks:[])
        }
        do { _ = try await pending.value; XCTFail("Cancelled renderer produced an image") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testNoCaptureOnConstructionAndOneCallCapturesOnce() async throws {
        try await MainActor.run {
            let backend = CaptureBackendStub(image: try syntheticImage())
            let engine = ScreenCaptureEngine(backend: backend, cursor: { CGPoint(x: 20, y: 30) }, processID: 42, bundleIdentifier: "org.harness.research")
            _ = CaptureService(engine: engine)
            XCTAssertEqual(backend.screenshotCalls, 0)
        }
        let result = try await MainActor.run { () -> (CaptureService, CaptureBackendStub) in
            let backend = CaptureBackendStub(image: try syntheticImage())
            return (CaptureService(engine: ScreenCaptureEngine(backend: backend, cursor: { CGPoint(x: 20, y: 30) }, processID: 42, bundleIdentifier: "org.harness.research")), backend)
        }
        let frame = try await result.0.capture(settings: Settings())
        XCTAssertEqual(frame.source, .excludingSelf)
        await MainActor.run {
            XCTAssertEqual(result.1.screenshotCalls, 1)
            XCTAssertEqual(result.1.plans.first?.excludedProcessID, 42)
        }
    }

    func testSelfExclusionWorksWithHiddenHarnessWindowsInAnotherAppsFullscreenSpace() async throws {
        let pair = try await MainActor.run { () -> (ScreenCaptureEngine, CaptureBackendStub) in
            let backend = CaptureBackendStub(image: try syntheticImage())
            // A visible-only SCK query can omit Harness while its panel is ordered out.
            backend.selfApplicationHasNoVisibleWindows = true
            return (ScreenCaptureEngine(backend: backend, cursor: { CGPoint(x: 20, y: 30) },
                processID: 42, bundleIdentifier: "org.harness.research"), backend)
        }
        let frame = try await pair.0.capture(settings: Settings())
        XCTAssertEqual(frame.source, .excludingSelf)
        await MainActor.run {
            XCTAssertEqual(pair.1.screenshotCalls, 1)
            XCTAssertEqual(pair.1.plans.first?.excludedProcessID, 42)
            XCTAssertEqual(pair.1.plans.first?.excludedBundleIdentifier, "org.harness.research")
        }
    }

    func testSelfExclusionCannotFallBackOrAcceptWrongIdentity() async throws {
        for apps in [[], [CaptureApplication(processID: 42, bundleIdentifier: "other")],
                     [CaptureApplication(processID: 42, bundleIdentifier: "org.harness.research"), CaptureApplication(processID: 42, bundleIdentifier: "org.harness.research")]] {
            let pair = try await MainActor.run { () -> (ScreenCaptureEngine, CaptureBackendStub) in
                let backend = CaptureBackendStub(image: try syntheticImage())
                backend.content.applications = apps
                return (ScreenCaptureEngine(backend: backend, cursor: { CGPoint(x: 20, y: 30) }, processID: 42, bundleIdentifier: "org.harness.research"), backend)
            }
            do { _ = try await pair.0.capture(settings: Settings()); XCTFail("Unverified identity captured") }
            catch { XCTAssertEqual(error as? CaptureError, .selfIdentityUnverified) }
            await MainActor.run { XCTAssertEqual(pair.1.screenshotCalls, 0) }
        }
    }

    func testFullCaptureDoesNotNeedSelfIdentity() async throws {
        let engine = try await MainActor.run { () -> ScreenCaptureEngine in
            let backend = CaptureBackendStub(image: try syntheticImage())
            backend.content.applications = []
            return ScreenCaptureEngine(backend: backend, cursor: { CGPoint(x: 20, y: 30) }, processID: 42, bundleIdentifier: nil)
        }
        var s = Settings(); s.captureSource = .full
        let frame = try await engine.capture(settings: s)
        XCTAssertEqual(frame.displayID, 1)
        XCTAssertEqual(frame.capturedBounds, CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testDisplaySelectionMapsNegativeOriginsAndRetinaWithoutAssumingTwoX() async throws {
        let pair = try await MainActor.run { () -> (ScreenCaptureEngine, CaptureBackendStub) in
            let backend = CaptureBackendStub(image: try syntheticImage())
            backend.content.displays = [
                CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2, rotation: 0),
                CaptureDisplay(id: 2, frame: CGRect(x: -200, y: -50, width: 200, height: 100), appKitFrame: CGRect(x: -200, y: 50, width: 200, height: 100), scale: 1.5, rotation: 90)
            ]
            return (ScreenCaptureEngine(backend: backend, cursor: { CGPoint(x: -100, y: 125) }, processID: 42, bundleIdentifier: "org.harness.research"), backend)
        }
        let frame = try await pair.0.capture(settings: Settings())
        XCTAssertEqual(frame.displayID, 2)
        XCTAssertEqual(frame.displayScale, 1.5)
        XCTAssertEqual(frame.rotation, 90)
        XCTAssertEqual(frame.displayFrame, CGRect(x: -200, y: -50, width: 200, height: 100))
        await MainActor.run {
            XCTAssertEqual(pair.1.plans.first?.cursorInDisplay, CGPoint(x: -100, y: -25))
            XCTAssertEqual(pair.1.plans.first?.pixelWidth, 300)
            XCTAssertEqual(pair.1.plans.first?.pixelHeight, 150)
        }
    }

    func testMissingDisplayAndBadScaleFailBeforeScreenshot() async throws {
        for displays in [[], [CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: .infinity, rotation: 0)]] {
            let pair = try await MainActor.run { () -> (ScreenCaptureEngine, CaptureBackendStub) in
                let backend = CaptureBackendStub(image: try syntheticImage()); backend.content.displays = displays
                return (ScreenCaptureEngine(backend: backend, cursor: { CGPoint(x: 20, y: 30) }, processID: 42, bundleIdentifier: "org.harness.research"), backend)
            }
            do { _ = try await pair.0.capture(settings: Settings()); XCTFail("Malformed display captured") } catch {}
            await MainActor.run { XCTAssertEqual(pair.1.screenshotCalls, 0) }
        }
    }

    func testSelectedWindowNeedsTargetAndRejectsMovedTarget() async throws {
        let pair = try await MainActor.run { () -> (ScreenCaptureEngine, CaptureBackendStub) in
            let backend = CaptureBackendStub(image: try syntheticImage())
            backend.content.windows = [CaptureWindow(id: 99, frame: CGRect(x: 10, y: 10, width: 80, height: 40), ownerPID: 75, ownerBundleIdentifier: "fixture", title: "Private UI title", ownerName: "Fixture", onScreen: true)]
            backend.changeWindowAfterScreenshot = true
            return (ScreenCaptureEngine(backend: backend, cursor: { CGPoint(x: 20, y: 30) }, processID: 42, bundleIdentifier: "org.harness.research"), backend)
        }
        var s = Settings(); s.captureSource = .selectedWindow
        do { _ = try await pair.0.capture(settings: s); XCTFail("Missing target accepted") }
        catch { XCTAssertEqual(error as? CaptureError, .windowUnavailable) }
        s.selectedWindowID = 99
        do { _ = try await pair.0.capture(settings: s); XCTFail("Moved target accepted") }
        catch { XCTAssertEqual(error as? CaptureError, .windowChanged) }
        await MainActor.run { XCTAssertEqual(pair.1.screenshotCalls, 1) }
    }

    func testSelectedWindowCarriesItsOwnBoundsAndRefreshIsMetadataOnly() async throws {
        let pair = try await MainActor.run { () -> (ScreenCaptureEngine, CaptureBackendStub) in
            let backend = CaptureBackendStub(image: try syntheticImage())
            backend.content.windows = [CaptureWindow(id: 99, frame: CGRect(x: 10, y: 10, width: 80, height: 40), ownerPID: 75, ownerBundleIdentifier: "fixture", title: "UI only", ownerName: "Fixture", onScreen: true)]
            return (ScreenCaptureEngine(backend: backend, cursor: { CGPoint(x: 20, y: 30) }, processID: 42, bundleIdentifier: "org.harness.research"), backend)
        }
        let choices = try await pair.0.refreshShareableWindows()
        XCTAssertEqual(choices.first?.id, 99)
        XCTAssertEqual(choices.first?.title, "UI only")
        await MainActor.run { XCTAssertEqual(pair.1.screenshotCalls, 0) }
        var s = Settings(); s.captureSource = .selectedWindow; s.selectedWindowID = 99
        let frame = try await pair.0.capture(settings: s)
        XCTAssertEqual(frame.capturedBounds, CGRect(x: 10, y: 10, width: 80, height: 40))
        XCTAssertEqual(frame.selectedWindowID, 99)
    }

    func testServiceRejectsConcurrentCaptureAndCleansUpAfterCancellation() async throws {
        let pair = try await MainActor.run { () -> (CaptureService, SuspendedCaptureEngine) in
            let engine = SuspendedCaptureEngine(image: try syntheticImage())
            return (CaptureService(engine: engine), engine)
        }
        let task = Task { try await pair.0.capture(settings: Settings()) }
        try await waitForTest { await pair.1.started }
        do { _ = try await pair.0.capture(settings: Settings()); XCTFail("Concurrent capture accepted") }
        catch { XCTAssertEqual(error as? CaptureError, .captureBusy) }
        task.cancel()
        await pair.1.release()
        do { _ = try await task.value; XCTFail("Cancelled capture returned frame") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error") }
        await MainActor.run { XCTAssertFalse(pair.0.isCapturing) }
    }

    func testProcessingPreservesAspectRatioAndHashesExactOutgoingBytes() throws {
        let input = try syntheticImage(width: 3200, height: 1600)
        let result = try ImageProcessor().process(input, settings: Settings())
        XCTAssertEqual(result.width, 1568); XCTAssertEqual(result.height, 784)
        XCTAssertLessThanOrEqual(result.bytes.count, 1_000_000)
        XCTAssertFalse(result.bytes.isEmpty)
        XCTAssertEqual(result.sha256, SHA256.hash(data: result.bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertFalse(result.masksApplied)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.bytes as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1568); XCTAssertEqual(image.height, 784)
    }

    func testNormalizedTopLeftMaskIsAppliedBeforeEncoding() throws {
        var s = Settings(); s.privacyMaskingEnabled = true
        s.maskingRegions = [MaskRegion(x: 0, y: 0, width: 1, height: 0.5)]
        let result = try ImageProcessor().process(syntheticImage(width: 100, height: 100), settings: s)
        XCTAssertTrue(result.masksApplied)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.bytes as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixels = try rgbaBytes(image)
        XCTAssertLessThan(Int(pixels[(10 * 100 + 50) * 4]), 20)
        XCTAssertGreaterThan(Int(pixels[(90 * 100 + 50) * 4]), 230)
    }

    func testInvalidMasksAndExcessiveInputAreRejected() throws {
        var s = Settings(); s.maskingRegions = [MaskRegion(x: -1, y: 0, width: 1, height: 1)]
        XCTAssertThrowsError(try ImageProcessor().process(syntheticImage(), settings: s))
        XCTAssertThrowsError(try ImageProcessor().process(syntheticImage(width: 16_385, height: 1), settings: Settings()))
    }

    func testMaskingPrecedesResizeSoSecretColorsCannotBleedOutsideMask() throws {
        let width = 257, height = 257
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        // A saturated red secret is fully inside the normalized mask. Its color
        // must never appear in any output pixel after reduction, including edges.
        for y in 0..<height {
            for x in 0..<129 {
                let offset = (y * width + x) * 4
                bytes[offset + 1] = 0; bytes[offset + 2] = 0
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        var settings = Settings(); settings.maxImageDimension = 64; settings.privacyMaskingEnabled = true
        settings.maskingRegions = [MaskRegion(x: 0, y: 0, width: 129.0 / 257.0, height: 1)]
        let encoder = InspectingJPEGEncoder()
        _ = try ImageProcessor(encoder: encoder).process(image, settings: settings)
        let outgoing = try XCTUnwrap(encoder.image)
        let pixels = try rgbaBytes(outgoing)
        let leakedPixels = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] != pixels[$0 + 1] || pixels[$0] != pixels[$0 + 2]
        }
        XCTAssertTrue(leakedPixels.isEmpty, "Secret color survived in \(leakedPixels.count) output pixels")
    }

    func testMaskingPolicyRedactsOriginalPixelsBeforeResizing() throws {
        let renderer = InspectingImageRenderer()
        var settings = Settings(); settings.maxImageDimension = 64; settings.privacyMaskingEnabled = true
        settings.maskingRegions = [MaskRegion(x: 0, y: 0, width: 0.5, height: 1)]
        _ = try ImageProcessor(renderer: renderer).process(syntheticImage(width: 256, height: 128), settings: settings)
        XCTAssertTrue(renderer.redactedAtOriginalSize, "The original pixels must be masked before any reduction")
    }

    func testEncodingNeverDropsBelowQualityFloorOrTransmitsOversizedData() throws {
        let encoder = OversizedJPEGEncoder()
        var s = Settings(); s.maxImageBytes = 10_000
        XCTAssertThrowsError(try ImageProcessor(encoder: encoder).process(syntheticImage(width: 256, height: 128), settings: s)) {
            XCTAssertEqual($0 as? ImageProcessingError, .cannotMeetByteLimit)
        }
        XCTAssertFalse(encoder.qualities.isEmpty)
        XCTAssertTrue(encoder.qualities.allSatisfy { $0 >= 0.55 })
    }
}

private func syntheticImage(width: Int = 100, height: Int = 100) throws -> CGImage {
    let bytes = Data(repeating: 255, count: width * height * 4)
    let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
    return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
}

@MainActor private final class CaptureBackendStub: ScreenshotBackend {
    var content = CaptureContentSnapshot(
        displays: [CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1, rotation: 0)],
        applications: [CaptureApplication(processID: 42, bundleIdentifier: "org.harness.research")], windows: [])
    let image: CGImage
    var screenshotCalls = 0
    var plans: [CapturePlan] = []
    var changeWindowAfterScreenshot = false
    var selfApplicationHasNoVisibleWindows = false
    init(image: CGImage) { self.image = image }
    func shareableContent(includeOffscreenWindows: Bool) async throws -> CaptureContentSnapshot {
        var snapshot = content
        if selfApplicationHasNoVisibleWindows && !includeOffscreenWindows {
            snapshot.applications.removeAll { $0.processID == 42 }
        }
        return snapshot
    }
    func screenshot(plan: CapturePlan) async throws -> CGImage {
        screenshotCalls += 1; plans.append(plan)
        if changeWindowAfterScreenshot { content.windows[0].frame.origin.x += 1 }
        return try syntheticImage(width: plan.pixelWidth, height: plan.pixelHeight)
    }
}

@MainActor private final class SuspendedCaptureEngine: CaptureEngineProtocol {
    let image: CGImage
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    init(image: CGImage) { self.image = image }
    func capture(settings: Settings) async throws -> CapturedFrame {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return CapturedFrame(image: image, displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), displayScale: 1, rotation: 0, source: .excludingSelf, selectedWindowID: nil, capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class OversizedJPEGEncoder: JPEGEncoding {
    var qualities: [Double] = []
    func encode(_ image: CGImage, quality: Double) throws -> Data {
        qualities.append(quality)
        return Data(repeating: 0, count: 10_001)
    }
}

private final class InspectingJPEGEncoder: JPEGEncoding {
    var image: CGImage?
    func encode(_ image: CGImage, quality: Double) throws -> Data {
        self.image = image
        return Data([1])
    }
}

private final class InspectingImageRenderer: ImageRendering {
    var redactedAtOriginalSize = false
    func render(_ image: CGImage, width: Int, height: Int, masks: [MaskRegion]) throws -> CGImage {
        let result = try MemoryImageRenderer().render(image, width: width, height: height, masks: masks)
        if !masks.isEmpty, width == image.width, height == image.height {
            let pixels = try rgbaBytes(result)
            redactedAtOriginalSize = pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 0
        }
        return result
    }
}
