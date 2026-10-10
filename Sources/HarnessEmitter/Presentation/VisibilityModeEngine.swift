import AppKit
import HarnessCore

/// Property values are window metadata, not evidence of exclusion from screen capture.
public struct WindowConfiguration: Codable, Equatable, Sendable {
    public let level: Int
    public let sharing: UInt
    public let collectionBehavior: UInt
    public init(level: Int, sharing: UInt, collectionBehavior: UInt) {
        self.level = level; self.sharing = sharing; self.collectionBehavior = collectionBehavior
    }
    var auditValue: JSONValue {
        .object(["level": .integer(level), "sharing": .integer(Int(clamping: sharing)),
                 "collection_behavior": .integer(Int(clamping: collectionBehavior))])
    }
}

@MainActor public protocol WindowConfiguring: AnyObject {
    var supportedCollectionBehaviorMask: UInt { get }
    var legacySharingAvailable: Bool { get }
    func snapshot() throws -> WindowConfiguration
    func apply(_ configuration: WindowConfiguration) throws
}

/// Public AppKit property adapter for this application's own overlay panel.
/// All selected flags are available before the macOS 14 deployment target.
@MainActor public final class AppKitWindowConfigurer: WindowConfiguring {
    private let window: NSWindow
    public let supportedCollectionBehaviorMask: UInt = NSWindow.CollectionBehavior([
        .canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle
    ]).rawValue
    public let legacySharingAvailable = true
    public init(window: NSWindow) { self.window = window }
    public func snapshot() throws -> WindowConfiguration {
        WindowConfiguration(level: window.level.rawValue, sharing: window.sharingType.rawValue,
                            collectionBehavior: window.collectionBehavior.rawValue)
    }
    public func apply(_ configuration: WindowConfiguration) throws {
        guard configuration.level == NSWindow.Level.floating.rawValue,
              configuration.collectionBehavior & ~supportedCollectionBehaviorMask == 0,
              let sharing = NSWindow.SharingType(rawValue: configuration.sharing),
              sharing == .none || sharing == .readOnly else { throw ModeConfigurationError.unsupportedConfiguration }
        window.level = .floating
        window.collectionBehavior = NSWindow.CollectionBehavior(rawValue: configuration.collectionBehavior)
        // SDK 27 declares both the property and these constants without deprecation.
        // .none remains a legacy probe: no capture-exclusion guarantee follows from its value.
        window.sharingType = sharing
    }
}

public enum ModeSupportState: String, Codable, Sendable {
    case apiSupportedVisibilityUnverified = "api_supported_visibility_unverified"
    case legacyIneffectual = "legacy_ineffectual"
    case legacySharingAndSpacesUnverified = "legacy_sharing_and_spaces_unverified"
}
public enum ModeConfigurationError: Error, Equatable, LocalizedError {
    case unsupportedConfiguration, verificationFailed, rollbackFailed, staleReceipt, unusable
    public var errorDescription: String? {
        switch self {
        case .unsupportedConfiguration: return "The requested window configuration is unsupported."
        case .verificationFailed: return "The observed window properties did not match the requested configuration."
        case .rollbackFailed: return "Window configuration rollback failed; stop this experiment."
        case .staleReceipt: return "The rollback receipt no longer identifies the current transition."
        case .unusable: return "Window configuration is uncertain; restart before further experiments."
        }
    }
}

/// An immutable engine-issued receipt. Callers cannot manufacture an arbitrary mode rollback.
public struct ModeTransition: Sendable {
    public let from: VisibilityMode
    public let to: VisibilityMode
    public let requested: WindowConfiguration
    public let observed: WindowConfiguration
    public let supportState: ModeSupportState
    public var changed: Bool { from != to }
    fileprivate let id: UUID
    fileprivate let previous: WindowConfiguration
    public var auditEvent: AuditEvent {
        AuditEvent(.modeChanged, payload: ["from": .integer(from.rawValue), "to": .integer(to.rawValue),
            "status": .string("applied"), "capability": .string(supportState.rawValue),
            "requested": requested.auditValue, "observed": observed.auditValue])
    }
}

/// Only the application's private Settings handler calls the transition entry point.
/// This component exposes no hotkeys, network listener, detector command or IPC interface.
@MainActor public final class VisibilityModeEngine {
    private let configurer: any WindowConfiguring
    private let refreshBadge: @MainActor (VisibilityMode) -> Void
    private var lastReceiptID: UUID?
    public private(set) var currentMode: VisibilityMode
    public private(set) var isUsable = true

    public init(configurer: any WindowConfiguring, initialMode: VisibilityMode = .spaceBehaviorProbe,
                refreshBadge: @escaping @MainActor (VisibilityMode) -> Void = { _ in }) throws {
        self.configurer = configurer; self.refreshBadge = refreshBadge; currentMode = initialMode
        let baseline = Self.configuration(for: initialMode)
        try validateSupport(baseline, mode: initialMode)
        let previous = try configurer.snapshot()
        do {
            try configurer.apply(baseline)
            let observed = try configurer.snapshot()
            guard observed.level == baseline.level, observed.collectionBehavior == baseline.collectionBehavior,
                  observed.sharing == baseline.sharing || (initialMode != .open && observed.sharing == NSWindow.SharingType.readOnly.rawValue)
            else { throw ModeConfigurationError.verificationFailed }
        } catch {
            do { try restore(previous) }
            catch { throw ModeConfigurationError.rollbackFailed }
            throw error
        }
        refreshBadge(initialMode)
    }

    public static func configuration(for mode: VisibilityMode) -> WindowConfiguration {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        if mode == .spaceBehaviorProbe { behavior.formUnion([.stationary, .ignoresCycle]) }
        return WindowConfiguration(level: NSWindow.Level.floating.rawValue,
            sharing: (mode != .open ? NSWindow.SharingType.none : .readOnly).rawValue,
            collectionBehavior: behavior.rawValue)
    }

    /// The caller must record the request first, then record this receipt and persist Settings.
    /// On post-apply audit or persistence failure it must roll back the returned receipt and abort.
    @discardableResult public func applyFromSettings(_ mode: VisibilityMode) throws -> ModeTransition {
        guard isUsable else { throw ModeConfigurationError.unusable }
        let requested = Self.configuration(for: mode)
        try validateSupport(requested, mode: mode)
        let previous = try configurer.snapshot()
        let observed: WindowConfiguration
        do {
            try configurer.apply(requested)
            observed = try configurer.snapshot()
            guard observed.level == requested.level,
                  observed.collectionBehavior == requested.collectionBehavior,
                  observed.sharing == requested.sharing ||
                    (mode != .open && observed.sharing == NSWindow.SharingType.readOnly.rawValue)
            else { throw ModeConfigurationError.verificationFailed }
        } catch {
            do { try restore(previous) }
            catch { isUsable = false; lastReceiptID = nil; throw ModeConfigurationError.rollbackFailed }
            throw error
        }
        let transition = ModeTransition(from: currentMode, to: mode, requested: requested, observed: observed,
            supportState: mode == .spaceBehaviorProbe ? .legacySharingAndSpacesUnverified :
                (mode == .legacySharingProbe ? .legacyIneffectual : .apiSupportedVisibilityUnverified),
            id: UUID(), previous: previous)
        currentMode = mode; lastReceiptID = transition.id
        refreshBadge(mode)
        return transition
    }

    public func rollback(_ receipt: ModeTransition) throws {
        guard isUsable else { throw ModeConfigurationError.unusable }
        guard lastReceiptID == receipt.id, currentMode == receipt.to else { throw ModeConfigurationError.staleReceipt }
        // Consume before attempting restoration, so a failed receipt cannot be retried as success.
        lastReceiptID = nil
        do { try restore(receipt.previous) }
        catch { isUsable = false; throw ModeConfigurationError.rollbackFailed }
        currentMode = receipt.from; refreshBadge(receipt.from)
    }

    private func validateSupport(_ configuration: WindowConfiguration, mode: VisibilityMode) throws {
        guard configuration.collectionBehavior & ~configurer.supportedCollectionBehaviorMask == 0,
              mode == .open || configurer.legacySharingAvailable else {
            throw ModeConfigurationError.unsupportedConfiguration
        }
    }
    private func restore(_ previous: WindowConfiguration) throws {
        try configurer.apply(previous)
        guard try configurer.snapshot() == previous else { throw ModeConfigurationError.verificationFailed }
    }
}
