import Foundation
import HarnessCore

public struct QueuedScreenshot {
    public let id:UUID
    public let image:ProcessedImage
    public init(id:UUID,image:ProcessedImage) { self.id = id; self.image = image }
}
public enum ScreenshotBatchError: Error { case full, invalidImage, configurationChanged }

/// Owns compressed/redacted JPEGs only. The native frame and OCR text never enter the queue.
@MainActor public final class ScreenshotBatch {
    public static let limit = 6
    private let clock:() -> UInt64
    private var entries:[QueuedScreenshot] = []
    private var configuration:Settings?
    private var createdAt:UInt64?
    public var count:Int { entries.count }
    public var retainedByteCount:Int { entries.reduce(0) { $0 + $1.image.bytes.count } }
    public var remainingLifetimeNS:UInt64 {
        guard let createdAt else { return 0 }
        let now = clock()
        guard now >= createdAt else { return 0 }
        let age = now - createdAt
        return age >= 300_000_000_000 ? 0 : 300_000_000_000 - age
    }
    public init(clock:@escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) { self.clock = clock }
    @discardableResult public func expireIfNeeded() -> Bool {
        guard !entries.isEmpty,remainingLifetimeNS == 0 else { return false }
        clear(); return true
    }
    public func append(_ entry:QueuedScreenshot,settings:Settings) throws {
        expireIfNeeded()
        try settings.validated()
        if let configuration, !matches(configuration,settings) { clear(); throw ScreenshotBatchError.configurationChanged }
        guard entries.count < Self.limit else { throw ScreenshotBatchError.full }
        guard !entries.contains(where:{ $0.id == entry.id }),
              !entry.image.bytes.isEmpty,entry.image.bytes.count <= settings.maxImageBytes,
              entry.image.width > 0,entry.image.height > 0,
              !settings.privacyMaskingEnabled || entry.image.masksApplied else { throw ScreenshotBatchError.invalidImage }
        if createdAt == nil { createdAt = clock(); configuration = settings }
        entries.append(entry)
    }
    public func take(settings:Settings) throws -> [QueuedScreenshot] {
        expireIfNeeded()
        if let configuration,!matches(configuration,settings) { clear(); throw ScreenshotBatchError.configurationChanged }
        let result = entries
        clear()
        return result
    }
    private func matches(_ stored:Settings,_ current:Settings) -> Bool {
        var compared = current
        compared.overlayPosition = stored.overlayPosition
        return compared == stored
    }
    public func clear() { entries.removeAll(keepingCapacity:false); configuration = nil; createdAt = nil }
}
