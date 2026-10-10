import AppKit
import CoreGraphics
import ScreenCaptureKit
import HarnessCore

public enum CaptureError: Error, Equatable {
    case captureBusy, displayUnavailable, malformedDisplay, selfIdentityUnverified
    case windowUnavailable, windowChanged, captureFailed, permissionDenied
}

public struct CapturedFrame {
    public let image: CGImage
    public let displayID: UInt32
    /// Global Core Graphics bounds in logical points, with a top-left origin.
    public let displayFrame: CGRect
    public let displayScale: Double
    public let rotation: Double
    public let source: CaptureSource
    public let selectedWindowID: UInt32?
    /// Display bounds for display captures, or window bounds for window captures.
    public let capturedBounds: CGRect
    public init(image: CGImage, displayID: UInt32, displayFrame: CGRect, displayScale: Double,
                rotation: Double, source: CaptureSource, selectedWindowID: UInt32?, capturedBounds: CGRect) {
        self.image = image; self.displayID = displayID; self.displayFrame = displayFrame
        self.displayScale = displayScale; self.rotation = rotation; self.source = source
        self.selectedWindowID = selectedWindowID; self.capturedBounds = capturedBounds
    }
}

@MainActor public protocol CaptureEngineProtocol {
    func capture(settings: Settings) async throws -> CapturedFrame
}

/// Called only from the emitter's registered physical capture-hotkey path.
/// Construction, enumeration and permission requests never initiate a screenshot.
@MainActor public final class CaptureService {
    private let engine: any CaptureEngineProtocol
    public private(set) var isCapturing = false
    public init(engine: any CaptureEngineProtocol) { self.engine = engine }
    public func capture(settings: Settings) async throws -> CapturedFrame {
        guard !isCapturing else { throw CaptureError.captureBusy }
        try settings.validated()
        try Task.checkCancellation()
        isCapturing = true
        defer { isCapturing = false }
        let frame = try await engine.capture(settings: settings)
        try Task.checkCancellation()
        return frame
    }

    public static var screenRecordingPermissionGranted: Bool { CGPreflightScreenCaptureAccess() }
    /// Invoke only from an explicit Settings permission button.
    @discardableResult public static func requestScreenRecordingPermissionFromSettings() -> Bool {
        if screenRecordingPermissionGranted { return true }
        return CGRequestScreenCaptureAccess()
    }
}

public struct CaptureDisplay: Equatable {
    public var id: UInt32
    public var frame: CGRect
    public var appKitFrame: CGRect
    public var scale: Double
    public var rotation: Double
    public init(id: UInt32, frame: CGRect, appKitFrame: CGRect, scale: Double, rotation: Double) {
        self.id = id; self.frame = frame; self.appKitFrame = appKitFrame; self.scale = scale; self.rotation = rotation
    }
}
public struct CaptureApplication: Equatable {
    public var processID: Int32
    public var bundleIdentifier: String
    public init(processID: Int32, bundleIdentifier: String) { self.processID = processID; self.bundleIdentifier = bundleIdentifier }
}
public struct CaptureWindow: Equatable {
    public var id: UInt32
    public var frame: CGRect
    public var ownerPID: Int32
    public var ownerBundleIdentifier: String
    public var title: String
    public var ownerName: String
    public var onScreen: Bool
    public init(id: UInt32, frame: CGRect, ownerPID: Int32, ownerBundleIdentifier: String,
                title: String, ownerName: String, onScreen: Bool) {
        self.id = id; self.frame = frame; self.ownerPID = ownerPID; self.ownerBundleIdentifier = ownerBundleIdentifier
        self.title = title; self.ownerName = ownerName; self.onScreen = onScreen
    }
}
public struct CaptureContentSnapshot {
    public var displays: [CaptureDisplay]
    public var applications: [CaptureApplication]
    public var windows: [CaptureWindow]
    public init(displays: [CaptureDisplay], applications: [CaptureApplication], windows: [CaptureWindow]) {
        self.displays = displays; self.applications = applications; self.windows = windows
    }
}
public struct ShareableWindowChoice {
    public let id: UInt32
    /// UI-only metadata; never pass window titles to audit events.
    public let title: String
    public let owner: String
}
public struct CapturePlan {
    public let displayID: UInt32
    public let source: CaptureSource
    public let selectedWindowID: UInt32?
    public let excludedProcessID: Int32?
    public let excludedBundleIdentifier: String?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let cursorInDisplay: CGPoint
}

@MainActor public protocol ScreenshotBackend {
    /// Offscreen windows are needed to identify an application whose panels are hidden.
    /// This controls metadata enumeration, never the screenshot source or target.
    func shareableContent(includeOffscreenWindows: Bool) async throws -> CaptureContentSnapshot
    func screenshot(plan: CapturePlan) async throws -> CGImage
}

@MainActor public final class ScreenCaptureEngine: CaptureEngineProtocol {
    private let backend: any ScreenshotBackend
    private let cursor: @MainActor () -> CGPoint
    private let processID: Int32
    private let bundleIdentifier: String?
    private var captureInProgress = false
    public init(backend: any ScreenshotBackend, cursor: @escaping @MainActor () -> CGPoint,
                processID: Int32, bundleIdentifier: String?) {
        self.backend = backend; self.cursor = cursor; self.processID = processID; self.bundleIdentifier = bundleIdentifier
    }
    public convenience init() {
        self.init(backend: NativeScreenshotBackend(), cursor: { NSEvent.mouseLocation },
                  processID: ProcessInfo.processInfo.processIdentifier, bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    public func refreshShareableWindows() async throws -> [ShareableWindowChoice] {
        let content = try await backend.shareableContent(includeOffscreenWindows: false)
        try Task.checkCancellation()
        return content.windows.filter { $0.onScreen && Self.validRect($0.frame) }.map {
            ShareableWindowChoice(id: $0.id, title: $0.title, owner: $0.ownerName)
        }
    }

    public func capture(settings: Settings) async throws -> CapturedFrame {
        guard !captureInProgress else { throw CaptureError.captureBusy }
        try settings.validated()
        try Task.checkCancellation()
        captureInProgress = true
        defer { captureInProgress = false }
        // A visible-only query can omit Harness when its overlay is ordered out,
        // especially while another app occupies the active full-screen Space.
        let includeOffscreenWindows = settings.captureSource == .excludingSelf
        let content = try await backend.shareableContent(includeOffscreenWindows: includeOffscreenWindows)
        try Task.checkCancellation()
        let mouse = cursor()
        guard mouse.x.isFinite, mouse.y.isFinite else { throw CaptureError.displayUnavailable }
        let selectedWindow: CaptureWindow?
        let display: CaptureDisplay
        if settings.captureSource == .selectedWindow {
            guard let id = settings.selectedWindowID else { throw CaptureError.windowUnavailable }
            let matches = content.windows.filter { $0.id == id && $0.onScreen && Self.validRect($0.frame) }
            guard matches.count == 1, let window = matches.first, window.ownerPID > 0 else { throw CaptureError.windowUnavailable }
            selectedWindow = window
            // Independent-window capture must map to an unambiguous display for calibration.
            let candidates = content.displays.filter { $0.frame.contains(window.frame) }
            guard candidates.count == 1, let chosen = candidates.first else { throw CaptureError.displayUnavailable }
            display = chosen
        } else {
            selectedWindow = nil
            let candidates = content.displays.filter { $0.appKitFrame.contains(mouse) }
            guard candidates.count == 1, let chosen = candidates.first else { throw CaptureError.displayUnavailable }
            display = chosen
        }
        guard display.id != 0, Self.validRect(display.frame), Self.validRect(display.appKitFrame), display.scale.isFinite,
              (0.5...4).contains(display.scale), [0.0, 90, 180, 270].contains(display.rotation) else {
            throw CaptureError.malformedDisplay
        }
        let cursorCG = CGPoint(
            x: display.frame.minX + (mouse.x - display.appKitFrame.minX) * display.frame.width / display.appKitFrame.width,
            y: display.frame.minY + (display.appKitFrame.maxY - mouse.y) * display.frame.height / display.appKitFrame.height)
        guard cursorCG.x.isFinite, cursorCG.y.isFinite else { throw CaptureError.malformedDisplay }
        var excludedPID: Int32?
        var excludedBundle: String?
        if settings.captureSource == .excludingSelf {
            guard let bundleIdentifier, !bundleIdentifier.isEmpty,
                  content.applications.filter({ $0.processID == processID && $0.bundleIdentifier == bundleIdentifier }).count == 1 else {
                throw CaptureError.selfIdentityUnverified
            }
            excludedPID = processID; excludedBundle = bundleIdentifier
        }
        let bounds = selectedWindow?.frame ?? display.frame
        let pixelWidth = ceil(bounds.width * display.scale)
        let pixelHeight = ceil(bounds.height * display.scale)
        guard pixelWidth.isFinite, pixelHeight.isFinite, pixelWidth >= 1, pixelHeight >= 1,
              pixelWidth <= 16_384, pixelHeight <= 16_384, pixelWidth * pixelHeight <= 64_000_000 else {
            throw CaptureError.malformedDisplay
        }
        let plan = CapturePlan(displayID: display.id, source: settings.captureSource,
            selectedWindowID: selectedWindow?.id, excludedProcessID: excludedPID,
            excludedBundleIdentifier: excludedBundle, pixelWidth: Int(pixelWidth), pixelHeight: Int(pixelHeight), cursorInDisplay: cursorCG)
        let image = try await backend.screenshot(plan: plan)
        try Task.checkCancellation()
        guard image.width == plan.pixelWidth, image.height == plan.pixelHeight else { throw CaptureError.captureFailed }
        let after = try await backend.shareableContent(includeOffscreenWindows: includeOffscreenWindows)
        try Task.checkCancellation()
        guard after.displays.filter({ $0.id == display.id }).count == 1,
              after.displays.first(where: { $0.id == display.id }) == display else { throw CaptureError.displayUnavailable }
        if let before = selectedWindow {
            let matches = after.windows.filter { $0.id == before.id }
            guard matches.count == 1, let current = matches.first else { throw CaptureError.windowUnavailable }
            guard current.onScreen, current.frame == before.frame,
                  current.ownerPID == before.ownerPID, current.ownerBundleIdentifier == before.ownerBundleIdentifier else {
                throw CaptureError.windowChanged
            }
        }
        return CapturedFrame(image: image, displayID: display.id, displayFrame: display.frame,
            displayScale: display.scale, rotation: display.rotation, source: settings.captureSource,
            selectedWindowID: selectedWindow?.id, capturedBounds: bounds)
    }

    private static func validRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && [rect.origin.x, rect.origin.y, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
}

/// A one-shot SCScreenshotManager adapter. No SCStream, image files or persistent image caches.
@MainActor private final class NativeScreenshotBackend: ScreenshotBackend {
    private var displays: [UInt32: SCDisplay] = [:]
    private var applications: [SCRunningApplication] = []
    private var windows: [UInt32: SCWindow] = [:]

    func shareableContent(includeOffscreenWindows: Bool) async throws -> CaptureContentSnapshot {
        // Preflight first: enumeration must not become an implicit permission prompt.
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        try Task.checkCancellation()
        let content: SCShareableContent
        do {
            content = try await NativeCallbackGate.query { callback in
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: !includeOffscreenWindows) { content, error in
                    if let error { callback(.failure(error)) }
                    else if let content { callback(.success(content)) }
                    else { callback(.failure(CaptureError.captureFailed)) }
                }
            }
        }
        catch is CancellationError { throw CancellationError() }
        catch { throw CaptureError.captureFailed }
        try Task.checkCancellation()
        guard content.displays.count <= 64, content.windows.count <= 10_000, content.applications.count <= 10_000,
              Set(content.displays.map(\.displayID)).count == content.displays.count,
              Set(content.windows.map(\.windowID)).count == content.windows.count else { throw CaptureError.captureFailed }
        displays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        applications = content.applications
        windows = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        let mappedDisplays = content.displays.compactMap { display -> CaptureDisplay? in
            let matches = NSScreen.screens.filter {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }
            guard matches.count == 1, let screen = matches.first else { return nil }
            return CaptureDisplay(id: display.displayID, frame: CGDisplayBounds(display.displayID),
                appKitFrame: screen.frame, scale: Double(screen.backingScaleFactor), rotation: CGDisplayRotation(display.displayID))
        }
        return CaptureContentSnapshot(displays: mappedDisplays,
            applications: content.applications.map { CaptureApplication(processID: $0.processID, bundleIdentifier: $0.bundleIdentifier) },
            windows: content.windows.compactMap { window in
                guard let app = window.owningApplication else { return nil }
                return CaptureWindow(id: window.windowID, frame: window.frame, ownerPID: app.processID,
                    ownerBundleIdentifier: app.bundleIdentifier, title: String((window.title ?? "").prefix(512)),
                    ownerName: String(app.applicationName.prefix(256)), onScreen: window.isOnScreen)
            })
    }

    func screenshot(plan: CapturePlan) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        guard let display = displays[plan.displayID] else { throw CaptureError.displayUnavailable }
        let filter: SCContentFilter
        switch plan.source {
        case .full:
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .excludingSelf:
            let matches = applications.filter { $0.processID == plan.excludedProcessID && $0.bundleIdentifier == plan.excludedBundleIdentifier }
            guard matches.count == 1 else { throw CaptureError.selfIdentityUnverified }
            filter = SCContentFilter(display: display, excludingApplications: matches, exceptingWindows: [])
        case .selectedWindow:
            guard let id = plan.selectedWindowID, let window = windows[id], window.isOnScreen else { throw CaptureError.windowUnavailable }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }
        let config = SCStreamConfiguration()
        config.width = plan.pixelWidth; config.height = plan.pixelHeight
        config.preservesAspectRatio = true
        config.scalesToFit = false
        config.showsCursor = false
        config.capturesAudio = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.ignoreShadowsSingleWindow = true
        if #available(macOS 15.0, *) { config.captureMicrophone = false }
        try Task.checkCancellation()
        do {
            return try await NativeCallbackGate.query { callback in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                    if let error { callback(.failure(error)) }
                    else if let image { callback(.success(image)) }
                    else { callback(.failure(CaptureError.captureFailed)) }
                }
            }
        }
        catch is CancellationError { throw CancellationError() }
        catch { throw CaptureError.captureFailed }
    }
}
