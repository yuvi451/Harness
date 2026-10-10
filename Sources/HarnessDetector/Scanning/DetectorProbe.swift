import Foundation
import CoreGraphics
import ScreenCaptureKit

public struct WindowEnumerationSnapshot: Sendable {
    public let windows: [WindowMetadata]
    public let shareableWindows: [ShareableWindowIdentity]
    public let cgStatus, sckStatus: DetectorQueryStatus
    public let wallTime: Date
    public let monotonicNS: Int?
    public let clockDomainID: String?
    public let truncated: Bool
    public let latencyMS: Double
    public let errors: [String]
    public let sckWallTime: Date?
    public let cgLatencyMS, sckLatencyMS: Double?
    public init(windows: [WindowMetadata], shareableWindows: [ShareableWindowIdentity], cgStatus: DetectorQueryStatus,
                sckStatus: DetectorQueryStatus, wallTime: Date, monotonicNS: Int?, clockDomainID: String? = nil,
                truncated: Bool = false, latencyMS: Double = 0, errors: [String] = [],
                sckWallTime: Date? = nil, cgLatencyMS: Double? = nil, sckLatencyMS: Double? = nil) {
        self.windows = windows; self.shareableWindows = shareableWindows; self.cgStatus = cgStatus; self.sckStatus = sckStatus
        self.wallTime = wallTime; self.monotonicNS = monotonicNS; self.clockDomainID = clockDomainID; self.truncated = truncated
        self.latencyMS = latencyMS; self.errors = errors
        self.sckWallTime = sckWallTime; self.cgLatencyMS = cgLatencyMS; self.sckLatencyMS = sckLatencyMS
    }
}
public protocol WindowEnumerating: Sendable { func snapshot() async -> WindowEnumerationSnapshot }

/// Metadata enumeration only. Never requests permission, captures pixels, or reads titles.
public struct NativeWindowEnumerator: WindowEnumerating {
    private let sckTimeoutSeconds: Double
    public init(sckTimeoutSeconds: Double = 5) {
        self.sckTimeoutSeconds = sckTimeoutSeconds.isFinite ? max(0.001, min(5, sckTimeoutSeconds)) : 5
    }
    public func snapshot() async -> WindowEnumerationSnapshot {
        let started = DispatchTime.now().uptimeNanoseconds, wallTime = Date()
        var errors: [String] = []
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        var displayCount: UInt32 = 0
        var displays: [CGDirectDisplayID] = []
        if CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount <= 64 {
            displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
            if CGGetActiveDisplayList(displayCount, &displays, &displayCount) != .success { displays = []; errors.append("display_query_failed") }
        } else { errors.append("display_association_unavailable") }
        let windows = (list ?? []).prefix(4096).map { dictionary -> WindowMetadata in
            let rect = (dictionary[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            let bounds = rect.map { ObservationBounds(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height) }
            let associations = rect.map { rect in displays.filter { !rect.intersection(CGDisplayBounds($0)).isEmpty } } ?? []
            return WindowMetadata(windowID: (dictionary[kCGWindowNumber as String] as? NSNumber)?.intValue,
                ownerPID: (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                ownerName: dictionary[kCGWindowOwnerName as String] as? String, bounds: bounds,
                layer: (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue,
                sharingState: (dictionary[kCGWindowSharingState as String] as? NSNumber)?.intValue, displayIDs: associations)
        }
        let cgLatency = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        var sckStatus: DetectorQueryStatus = .permissionDenied, shareable: [ShareableWindowIdentity] = []
        var sckWallTime: Date?, sckLatency: Double?
        // Preflight is nonprompting. Do not call SCShareableContent when access is absent.
        if CGPreflightScreenCaptureAccess() {
            sckWallTime = Date(); let sckStarted = DispatchTime.now().uptimeNanoseconds
            let query = await ShareabilityCallbackGate.query(timeoutSeconds: sckTimeoutSeconds, operation: { callback in
                // Keep desktop windows here: SCK's exclusion flag also removes Dock/Finder.
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                    guard error == nil, let content, content.windows.count <= 4096 else {
                        callback(.init(status: .failed)); return
                    }
                    let windows = content.windows.map { ShareableWindowIdentity(windowID: Int($0.windowID), ownerPID: $0.owningApplication.map { Int($0.processID) }) }
                    callback(.init(status: .success, windows: windows))
                }
            })
            sckLatency = Double(DispatchTime.now().uptimeNanoseconds - sckStarted) / 1_000_000
            switch query.status {
            case .success: sckStatus = .success; shareable = query.windows
            case .failed: sckStatus = .failed; errors.append("sck_query_failed")
            case .timedOut: sckStatus = .failed; errors.append("sck_timeout")
            case .cancelled: sckStatus = .failed; errors.append("scan_cancelled")
            }
        }
        if list == nil { errors.append("cg_query_failed") }
        let truncated = (list?.count ?? 0) > 4096
        if truncated { errors.append("window_limit") }
        return WindowEnumerationSnapshot(windows: windows, shareableWindows: shareable,
            cgStatus: list == nil ? .failed : .success, sckStatus: sckStatus, wallTime: wallTime,
            monotonicNS: started <= UInt64(Int.max) ? Int(started) : nil, truncated: truncated,
            latencyMS: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000, errors: errors,
            sckWallTime: sckWallTime, cgLatencyMS: cgLatency, sckLatencyMS: sckLatency)
    }
}

public struct DetectorProbe: Sendable {
    private let enumerator: any WindowEnumerating
    public let sessionID: UUID
    public init(enumerator: any WindowEnumerating = NativeWindowEnumerator(), sessionID: UUID = UUID()) {
        self.enumerator = enumerator; self.sessionID = sessionID
    }
    public func scan(context: ScanContext? = nil) async -> DetectorScan {
        let snapshot = await enumerator.snapshot()
        let truncated = snapshot.truncated || snapshot.windows.count > 4096 || snapshot.shareableWindows.count > 4096
        let observations = snapshot.windows.prefix(4096).map { classify($0, snapshot: snapshot) }
        var errors = Array(snapshot.errors.filter { safeMetadata($0) }.prefix(30))
        if truncated && !errors.contains("window_limit") { errors.append("window_limit") }
        if (try? context?.validate()) == nil, context != nil { errors.append("invalid_context") }
        return DetectorScan(detectorSessionID: sessionID, ts: timestamp(snapshot.wallTime), monotonicNS: snapshot.monotonicNS,
            clockDomainID: snapshot.clockDomainID, context: context, cgStatus: snapshot.cgStatus, sckStatus: snapshot.sckStatus,
            observations: observations, truncated: truncated, latencyMS: snapshot.latencyMS, errors: errors,
            sckTS: snapshot.sckWallTime.map(timestamp), cgLatencyMS: snapshot.cgLatencyMS, sckLatencyMS: snapshot.sckLatencyMS)
    }
    private func classify(_ raw: WindowMetadata, snapshot: WindowEnumerationSnapshot) -> WindowObservation {
        var classifications: [ObservationClassification] = [], errors: [String] = []
        let windowID = raw.windowID.flatMap { $0 > 0 && $0 <= Int(UInt32.max) ? $0 : nil }
        let ownerPID = raw.ownerPID.flatMap { $0 > 0 && $0 <= Int(Int32.max) ? $0 : nil }
        let name = raw.ownerName.flatMap { safeMetadata($0) ? $0 : nil }
        let bounds = raw.bounds.flatMap { $0.isValid ? $0 : nil }
        let layer = raw.layer.flatMap { (-1_000_000...1_000_000).contains($0) ? $0 : nil }
        let sharing = raw.sharingState.flatMap { (0...2).contains($0) ? $0 : nil }
        let complete = windowID != nil && ownerPID != nil && name != nil && bounds != nil && layer != nil && sharing != nil
        if !complete { classifications.append(.metadataIncomplete); errors.append("missing_or_invalid_metadata") }
        if sharing == 0 { classifications.append(.legacyNonsharingSignal) }
        var listed: Bool?
        if snapshot.sckStatus == .success, let id = windowID, let pid = ownerPID {
            let sameID = snapshot.shareableWindows.filter { $0.windowID == id }
            if sameID.isEmpty { listed = false }
            else if sameID.count == 1, sameID[0].ownerPID == pid { listed = true }
            else { errors.append("sck_owner_identity_ambiguous") }
        }
        if let listed { classifications.append(listed ? .observedShareable : .observedNotShareable) }
        else { classifications.append(snapshot.sckStatus == .unsupported ? .unsupported : .unknown) }
        let owners = Set(["window server", "dock", "controlcenter", "systemuiserver", "spotlight", "notificationcenter"])
        return WindowObservation(windowID: windowID, ownerPID: ownerPID, ownerName: name, bounds: bounds, layer: layer,
            sharingState: sharing, sckEnumerated: listed, classifications: classifications,
            confidence: complete && listed != nil ? 1 : complete ? 0.5 : 0,
            systemOwner: name.map { owners.contains($0.lowercased()) } ?? false,
            displayIDs: Array(raw.displayIDs.prefix(64)), errors: errors)
    }
}
