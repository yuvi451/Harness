import Foundation
import CoreGraphics

public enum NativeScreenshotOrientation: String, Codable, Sendable {
    /// ScreenCaptureKit screenshot pixels already follow the displayed orientation.
    case displayOriented
    /// Synthetic/native sensor pixels require the declared quarter-turn transform.
    case unrotatedNative
}
public enum CalibrationOverlayVisibility: String, Codable, Sendable { case visible, notVisible, unknown }
public enum CalibrationVisibilityEvidence: String, Codable, Sendable {
    case confirmedUnoccluded, unknown, knownOccluded
}
public enum CalibrationOutcome: String, Codable, Sendable { case matched, absent, indeterminate }
public enum CalibrationReason: String, Codable, Sendable {
    case calibrationDisabled, referenceMatched, referenceNotObserved, negativeEvidenceUnavailable
    case patchOccluded, overlayNotVisible, overlayVisibilityUnknown, geometryUnavailable, geometryChanged
    case patchOutsideDisplay, patchOutsideOverlay, patchOutsideCapture, invalidPatchGeometry
    case invalidTransform, unsupportedRotation, imageGeometryMismatch, unsupportedPixelFormat
    case unsupportedColorSpace, invalidImageDimensions, cropTooLarge, renderingFailed, insufficientSamples, analysisCancelled
}

public struct CalibrationGeometry: Codable, Equatable, Sendable {
    public var displayID: UInt32
    public var appKitDisplayFrame: CGRect
    public var cgDisplayFrame: CGRect
    public var capturedBounds: CGRect
    public var displayScale: Double
    public var rotationDegrees: Double
    public var screenshotOrientation: NativeScreenshotOrientation
    public init(displayID: UInt32, appKitDisplayFrame: CGRect, cgDisplayFrame: CGRect, capturedBounds: CGRect,
                displayScale: Double, rotationDegrees: Double, screenshotOrientation: NativeScreenshotOrientation) {
        self.displayID = displayID; self.appKitDisplayFrame = appKitDisplayFrame; self.cgDisplayFrame = cgDisplayFrame
        self.capturedBounds = capturedBounds; self.displayScale = displayScale; self.rotationDegrees = rotationDegrees
        self.screenshotOrientation = screenshotOrientation
    }
}

/// Screen rectangles use AppKit global bottom-left coordinates; geometry uses CG top-left coordinates.
/// Inputs are snapshots of the original image, before privacy masking or JPEG processing.
public struct CalibrationInput {
    public var image: CGImage
    public var geometry: CalibrationGeometry?
    public var overlayScreenRect: CGRect?
    public var patchScreenRect: CGRect?
    public var captureSource: CaptureSource
    public var overlayVisibility: CalibrationOverlayVisibility
    public var visibilityEvidence: CalibrationVisibilityEvidence
    public var geometryStable: Bool
    public init(image: CGImage, geometry: CalibrationGeometry?, overlayScreenRect: CGRect?, patchScreenRect: CGRect?,
                captureSource: CaptureSource, overlayVisibility: CalibrationOverlayVisibility = .unknown,
                visibilityEvidence: CalibrationVisibilityEvidence = .unknown, geometryStable: Bool = false) {
        self.image = image; self.geometry = geometry; self.overlayScreenRect = overlayScreenRect; self.patchScreenRect = patchScreenRect
        self.captureSource = captureSource; self.overlayVisibility = overlayVisibility; self.visibilityEvidence = visibilityEvidence
        self.geometryStable = geometryStable
    }
}

public struct CalibrationResult: Codable, Equatable, Sendable {
    public let outcome: CalibrationOutcome
    public let confidence: Double
    public let reason: CalibrationReason
    public let pixelPatchBounds: CGRect?
    public let referenceColorSpace: String
    public let observedPixelFormat: String
    public init(outcome: CalibrationOutcome, confidence: Double, reason: CalibrationReason, pixelPatchBounds: CGRect? = nil,
                referenceColorSpace: String = "sRGB", observedPixelFormat: String = "unknown") {
        self.outcome = outcome; self.confidence = confidence; self.reason = reason; self.pixelPatchBounds = pixelPatchBounds
        self.referenceColorSpace = referenceColorSpace; self.observedPixelFormat = observedPixelFormat
    }
    public var overlayInCapture: Bool? {
        switch outcome { case .matched: return true; case .absent: return false; case .indeterminate: return nil }
    }
}

/// Matches the 16-point marker: sRGB FF007F, black top-left 4x4, white lower-right 4x8.
/// Confidence is the minimum matching fraction across the three regions. Every region
/// needs >=90% of interior samples within an inclusive per-channel tolerance of 24/255.
/// Occlusion/visibility evidence comes from the caller; a capture filter supplies no such evidence.
public struct CalibrationAnalyzer {
    public static let rgbTolerance = 24
    public static let minimumRegionMatch = 0.90
    public init() {}

    public func analyze(_ input: CalibrationInput) -> CalibrationResult {
        var pixelBounds: CGRect?
        let image = input.image
        let format = "\(image.bitsPerComponent)-bit/\(image.bitsPerPixel)-bpp"
        func result(_ outcome: CalibrationOutcome, _ reason: CalibrationReason, _ confidence: Double = 0) -> CalibrationResult {
            CalibrationResult(outcome: outcome, confidence: confidence, reason: reason, pixelPatchBounds: pixelBounds,
                referenceColorSpace: "sRGB", observedPixelFormat: format)
        }
        if Task.isCancelled { return result(.indeterminate, .analysisCancelled) }
        guard image.width > 0, image.height > 0, image.width <= 16_384, image.height <= 16_384,
              image.width <= 64_000_000 / image.height else { return result(.indeterminate, .invalidImageDimensions) }
        guard image.bitsPerComponent == 8, [24, 32].contains(image.bitsPerPixel),
              !image.bitmapInfo.contains(.floatComponents), let sourceSpace = image.colorSpace, sourceSpace.model == .rgb else {
            return result(.indeterminate, .unsupportedPixelFormat)
        }
        // Untagged device RGB cannot establish the reference color reliably.
        guard !CFEqual(sourceSpace, CGColorSpaceCreateDeviceRGB()),
              sourceSpace.name != nil || sourceSpace.copyICCData() != nil else { return result(.indeterminate, .unsupportedColorSpace) }
        guard let geometry = input.geometry, let overlay = input.overlayScreenRect, let patch = input.patchScreenRect else {
            return result(.indeterminate, .geometryUnavailable)
        }
        guard input.geometryStable else { return result(.indeterminate, .geometryChanged) }
        guard input.overlayVisibility != .notVisible else { return result(.indeterminate, .overlayNotVisible) }
        guard input.overlayVisibility == .visible else { return result(.indeterminate, .overlayVisibilityUnknown) }
        guard input.visibilityEvidence != .knownOccluded else { return result(.indeterminate, .patchOccluded) }
        guard Self.valid(patch), abs(patch.width - 16) < 0.001, abs(patch.height - 16) < 0.001 else {
            return result(.indeterminate, .invalidPatchGeometry)
        }
        guard Self.valid(overlay), Self.valid(geometry.appKitDisplayFrame), Self.valid(geometry.cgDisplayFrame),
              Self.valid(geometry.capturedBounds), geometry.displayID != 0, geometry.displayScale.isFinite,
              geometry.displayScale > 0, geometry.displayScale <= 16,
              abs(geometry.appKitDisplayFrame.width - geometry.cgDisplayFrame.width) < 0.01,
              abs(geometry.appKitDisplayFrame.height - geometry.cgDisplayFrame.height) < 0.01 else {
            return result(.indeterminate, .invalidTransform)
        }
        guard [0.0, 90.0, 180.0, 270.0].contains(geometry.rotationDegrees) else { return result(.indeterminate, .unsupportedRotation) }
        guard Self.contains(geometry.appKitDisplayFrame, patch) else { return result(.indeterminate, .patchOutsideDisplay) }
        guard Self.contains(overlay, patch) else { return result(.indeterminate, .patchOutsideOverlay) }
        guard Self.contains(geometry.cgDisplayFrame, geometry.capturedBounds) else { return result(.indeterminate, .invalidTransform) }
        let cgPatch = CGRect(x: geometry.cgDisplayFrame.minX + patch.minX - geometry.appKitDisplayFrame.minX,
            y: geometry.cgDisplayFrame.minY + geometry.appKitDisplayFrame.maxY - patch.maxY, width: patch.width, height: patch.height)
        guard Self.contains(geometry.capturedBounds, cgPatch) else { return result(.indeterminate, .patchOutsideCapture) }
        let swap = geometry.screenshotOrientation == .unrotatedNative && (geometry.rotationDegrees == 90 || geometry.rotationDegrees == 270)
        let expectedWidth = (swap ? geometry.capturedBounds.height : geometry.capturedBounds.width) * geometry.displayScale
        let expectedHeight = (swap ? geometry.capturedBounds.width : geometry.capturedBounds.height) * geometry.displayScale
        // CaptureEngine configures SCK dimensions with ceil(points * scale).
        // Accept that exact native policy, including subpixel window bounds;
        // unrelated resizes remain a geometry mismatch.
        guard Double(image.width) == ceil(expectedWidth), Double(image.height) == ceil(expectedHeight) else {
            return result(.indeterminate, .imageGeometryMismatch)
        }
        let normalized = CGRect(x: (cgPatch.minX - geometry.capturedBounds.minX) / geometry.capturedBounds.width,
            y: (cgPatch.minY - geometry.capturedBounds.minY) / geometry.capturedBounds.height,
            width: cgPatch.width / geometry.capturedBounds.width, height: cgPatch.height / geometry.capturedBounds.height)
        let corners = [CGPoint(x: normalized.minX, y: normalized.minY), CGPoint(x: normalized.maxX, y: normalized.minY),
                       CGPoint(x: normalized.minX, y: normalized.maxY), CGPoint(x: normalized.maxX, y: normalized.maxY)]
            .map { Self.toNative($0, geometry: geometry) }
            .map { CGPoint(x: $0.x * Double(image.width), y: $0.y * Double(image.height)) }
        let x0 = corners.map(\.x).min()!, y0 = corners.map(\.y).min()!
        let x1 = corners.map(\.x).max()!, y1 = corners.map(\.y).max()!
        pixelBounds = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        let cropRect = pixelBounds!.integral
        guard cropRect.width > 0, cropRect.height > 0, cropRect.width <= 256, cropRect.height <= 256 else {
            return result(.indeterminate, .cropTooLarge)
        }
        guard Self.contains(CGRect(x: 0, y: 0, width: image.width, height: image.height), cropRect) else {
            return result(.indeterminate, .patchOutsideCapture)
        }
        guard let crop = image.cropping(to: cropRect), let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                bytesPerRow: crop.width * 4, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let memory = context.data?.assumingMemoryBound(to: UInt8.self) else { return result(.indeterminate, .renderingFailed) }
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        var counts = [0, 0, 0], matches = [0, 0, 0]
        // Skip an interior boundary margin, measured in source pixels, to avoid
        // antialiased edges at fractional scale while retaining all three regions.
        let margin = 0.75 / geometry.displayScale
        for y in 0..<crop.height {
            if Task.isCancelled { return result(.indeterminate, .analysisCancelled) }
            for x in 0..<crop.width {
                let native = CGPoint(x: (cropRect.minX + Double(x) + 0.5) / Double(image.width),
                    y: (cropRect.minY + Double(y) + 0.5) / Double(image.height))
                let displayed = Self.toDisplayed(native, geometry: geometry)
                let px = geometry.capturedBounds.minX + displayed.x * geometry.capturedBounds.width - cgPatch.minX
                let py = geometry.capturedBounds.minY + displayed.y * geometry.capturedBounds.height - cgPatch.minY
                guard px >= margin, py >= margin, px <= 16 - margin, py <= 16 - margin,
                      abs(px - 4) > margin, abs(py - 4) > margin, abs(px - 12) > margin, abs(py - 8) > margin else { continue }
                let region: Int
                let reference: [Int]
                if px < 4 && py < 4 { region = 0; reference = [0, 0, 0] }
                else if px >= 12 && py >= 8 { region = 1; reference = [255, 255, 255] }
                else { region = 2; reference = [255, 0, 127] }
                counts[region] += 1
                let offset = (y * crop.width + x) * 4
                if memory[offset + 3] >= 250 && (0..<3).allSatisfy({ abs(Int(memory[offset + $0]) - reference[$0]) <= Self.rgbTolerance }) {
                    matches[region] += 1
                }
            }
        }
        guard counts.allSatisfy({ $0 >= 4 }) else { return result(.indeterminate, .insufficientSamples) }
        let fractions = (0..<3).map { Double(matches[$0]) / Double(counts[$0]) }
        let confidence = fractions.min()!
        if confidence >= Self.minimumRegionMatch { return result(.matched, .referenceMatched, confidence) }
        guard input.visibilityEvidence == .confirmedUnoccluded else { return result(.indeterminate, .negativeEvidenceUnavailable) }
        return result(.absent, .referenceNotObserved, 1 - confidence)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
    private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        // Explicit edges include a rectangle touching the capture/display boundary.
        inner.minX >= outer.minX && inner.minY >= outer.minY && inner.maxX <= outer.maxX && inner.maxY <= outer.maxY
    }
    private static func toNative(_ point: CGPoint, geometry: CalibrationGeometry) -> CGPoint {
        guard geometry.screenshotOrientation == .unrotatedNative else { return point }
        switch geometry.rotationDegrees {
        case 90: return CGPoint(x: point.y, y: 1 - point.x)
        case 180: return CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 270: return CGPoint(x: 1 - point.y, y: point.x)
        default: return point
        }
    }
    private static func toDisplayed(_ point: CGPoint, geometry: CalibrationGeometry) -> CGPoint {
        guard geometry.screenshotOrientation == .unrotatedNative else { return point }
        switch geometry.rotationDegrees {
        case 90: return CGPoint(x: 1 - point.y, y: point.x)
        case 180: return CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 270: return CGPoint(x: point.y, y: 1 - point.x)
        default: return point
        }
    }
}
