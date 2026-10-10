import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import HarnessCore

public enum ImageProcessingError: Error, Equatable {
    case invalidDimensions, allocationFailed, encodingFailed, cannotMeetByteLimit, maskingRegionsRequired
}

public struct ProcessedImage {
    public let bytes: Data
    public let width: Int
    public let height: Int
    public let sha256: String
    public let masksApplied: Bool
}

public protocol JPEGEncoding {
    func encode(_ image: CGImage, quality: Double) throws -> Data
}

public struct MemoryJPEGEncoder: JPEGEncoding {
    public init() {}
    public func encode(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageProcessingError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { throw ImageProcessingError.encodingFailed }
        return data as Data
    }
}

public protocol ImageRendering {
    func render(_ image: CGImage, width: Int, height: Int, masks: [MaskRegion]) throws -> CGImage
}

public struct ImageProcessor {
    private let encoder: any JPEGEncoding
    private let renderer: any ImageRendering
    public init(encoder: any JPEGEncoding = MemoryJPEGEncoder(), renderer: any ImageRendering = MemoryImageRenderer()) {
        self.encoder = encoder; self.renderer = renderer
    }

    public func process(_ image: CGImage, settings: Settings) throws -> ProcessedImage {
        try settings.validated()
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0, image.width <= 16_384, image.height <= 16_384,
              image.width <= 64_000_000 / image.height else { throw ImageProcessingError.invalidDimensions }
        if settings.privacyMaskingEnabled && settings.maskingRegions.isEmpty { throw ImageProcessingError.maskingRegionsRequired }
        // Redact native-resolution pixels before interpolation, so resampling can
        // never consume the original content of a masked region.
        let safeSource: CGImage
        if settings.privacyMaskingEnabled {
            safeSource = try renderer.render(image, width: image.width, height: image.height, masks: settings.maskingRegions)
        } else {
            safeSource = image
        }
        let originalLongestEdge = max(image.width, image.height)
        var longestEdge = min(originalLongestEdge, settings.maxImageDimension)
        // Quality below 0.55 is not permitted. Smaller images are attempted only down to
        // 64 pixels on their longest edge; inability to fit produces an explicit error.
        let qualityLevels = [0.90, 0.80, 0.70, 0.60, 0.55]
        while true {
            try Task.checkCancellation()
            let ratio = Double(longestEdge) / Double(originalLongestEdge)
            let width = max(1, Int((Double(image.width) * ratio).rounded()))
            let height = max(1, Int((Double(image.height) * ratio).rounded()))
            let rendered = try renderer.render(safeSource, width: width, height: height, masks: [])
            for quality in qualityLevels {
                try Task.checkCancellation()
                let encoded = try encoder.encode(rendered, quality: quality)
                guard !encoded.isEmpty else { throw ImageProcessingError.encodingFailed }
                if encoded.count <= settings.maxImageBytes {
                    let hash = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
                    return ProcessedImage(bytes: encoded, width: width, height: height,
                        sha256: hash, masksApplied: settings.privacyMaskingEnabled)
                }
            }
            guard longestEdge > 64 else { throw ImageProcessingError.cannotMeetByteLimit }
            longestEdge = max(64, Int(Double(longestEdge) * 0.8))
        }
    }

}

public struct MemoryImageRenderer: ImageRendering {
    public init() {}
    public func render(_ image: CGImage, width: Int, height: Int, masks: [MaskRegion]) throws -> CGImage {
        try Task.checkCancellation()
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= 64_000_000 / height else { throw ImageProcessingError.invalidDimensions }
        guard masks.count <= 32, masks.allSatisfy(\.isValid) else {
            throw SettingsValidationError.invalidField("maskingRegions")
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let memory = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ImageProcessingError.allocationFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Explicit scanline addressing makes normalized masks refer to the JPEG's
        // top-left pixel origin, without relying on AppKit/Quartz view transforms.
        for mask in masks {
            let x0 = max(0, Int(floor(mask.x * Double(width))))
            let y0 = max(0, Int(floor(mask.y * Double(height))))
            let x1 = min(width, Int(ceil((mask.x + mask.width) * Double(width))))
            let y1 = min(height, Int(ceil((mask.y + mask.height) * Double(height))))
            for y in y0..<y1 {
                try Task.checkCancellation()
                for x in x0..<x1 {
                    let offset = (y * width + x) * 4
                    memory[offset] = 0; memory[offset + 1] = 0; memory[offset + 2] = 0; memory[offset + 3] = 255
                }
            }
        }
        try Task.checkCancellation()
        guard let result = context.makeImage() else { throw ImageProcessingError.allocationFailed }
        return result
    }
}
