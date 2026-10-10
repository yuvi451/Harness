import AppKit
import XCTest
@testable import HarnessCore
@testable import HarnessEmitter

@MainActor final class ModeTests: XCTestCase {
    func testDefaultConstructorStartsCombinedModeIncludingIgnoredSharingFlag() throws {
        for ignored in [false, true] {
            let window = FakeModeWindow(); window.ignoreLegacyNone = ignored
            let engine = try VisibilityModeEngine(configurer: window)
            XCTAssertEqual(engine.currentMode, .spaceBehaviorProbe)
            XCTAssertEqual(window.configuration.collectionBehavior, 262481)
            XCTAssertEqual(window.configuration.sharing, ignored ? 1 : 0)
        }
    }
    func testConstructorResetsOwnedWindowToVerifiedOpenBaseline() throws {
        let window = FakeModeWindow(configuration: .init(level: 3, sharing: 0, collectionBehavior: 262481))
        var badges: [VisibilityMode] = []
        let engine = try VisibilityModeEngine(configurer: window, initialMode: .open, refreshBadge: { badges.append($0) })
        XCTAssertEqual(engine.currentMode, .open)
        XCTAssertEqual(window.configuration, .init(level: 3, sharing: 1, collectionBehavior: 262401))
        XCTAssertEqual(badges, [.open])
        XCTAssertTrue(engine.isUsable)
    }

    func testSettingsTransitionsKeepOrdinaryLevelAndExactDistinctFlags() throws {
        let window = FakeModeWindow()
        var badges: [VisibilityMode] = []
        let engine = try VisibilityModeEngine(configurer: window, initialMode: .open, refreshBadge: { badges.append($0) })
        let legacy = try engine.applyFromSettings(.legacySharingProbe)
        XCTAssertEqual(legacy.from, .open); XCTAssertEqual(legacy.to, .legacySharingProbe)
        XCTAssertEqual(legacy.requested, .init(level: 3, sharing: 0, collectionBehavior: 262401))
        XCTAssertEqual(legacy.observed, .init(level: 3, sharing: 0, collectionBehavior: 262401))
        XCTAssertEqual(legacy.supportState, .legacyIneffectual)
        XCTAssertTrue(legacy.changed)
        let spaces = try engine.applyFromSettings(.spaceBehaviorProbe)
        XCTAssertEqual(spaces.requested, .init(level: 3, sharing: 0, collectionBehavior: 262481))
        XCTAssertEqual(spaces.observed, .init(level: 3, sharing: 0, collectionBehavior: 262481))
        XCTAssertEqual(spaces.supportState.rawValue, "legacy_sharing_and_spaces_unverified")
        XCTAssertEqual(engine.currentMode, .spaceBehaviorProbe)
        XCTAssertEqual(badges, [.open, .legacySharingProbe, .spaceBehaviorProbe])
        let repeated = try engine.applyFromSettings(.spaceBehaviorProbe)
        XCTAssertFalse(repeated.changed)
        XCTAssertEqual(repeated.from, .spaceBehaviorProbe)
        XCTAssertEqual(window.configuration, .init(level: 3, sharing: 0, collectionBehavior: 262481))
    }

    func testCombinedProbeAllowsAnIgnoredLegacyFlagAndReportsExclusionUnverified() throws {
        let window = FakeModeWindow(); window.ignoreLegacyNone = true
        let engine = try VisibilityModeEngine(configurer: window, initialMode: .open)
        let result = try engine.applyFromSettings(.spaceBehaviorProbe)
        XCTAssertEqual(result.requested.sharing, NSWindow.SharingType.none.rawValue)
        XCTAssertEqual(result.observed.sharing, NSWindow.SharingType.readOnly.rawValue)
        XCTAssertEqual(result.supportState.rawValue, "legacy_sharing_and_spaces_unverified")
        XCTAssertNotEqual(result.requested.collectionBehavior & NSWindow.CollectionBehavior.canJoinAllApplications.rawValue, 0)
        try result.auditEvent.validate()
        try engine.rollback(result)
        XCTAssertEqual(window.configuration, VisibilityModeEngine.configuration(for: .open))
    }

    func testLegacyProbeRecordsReadOnlyObservationWithoutPretendingExclusion() throws {
        let window = FakeModeWindow(); window.ignoreLegacyNone = true
        let engine = try VisibilityModeEngine(configurer: window, initialMode: .open)
        let result = try engine.applyFromSettings(.legacySharingProbe)
        XCTAssertEqual(result.requested.sharing, 0)
        XCTAssertEqual(result.observed.sharing, 1)
        XCTAssertEqual(result.supportState, .legacyIneffectual)
        XCTAssertEqual(engine.currentMode, .legacySharingProbe)
        try result.auditEvent.validate()
        XCTAssertEqual(result.auditEvent.payload["from"], .integer(0))
        XCTAssertEqual(result.auditEvent.payload["to"], .integer(1))
        XCTAssertEqual(result.auditEvent.payload["requested"], .object(["level": .integer(3), "sharing": .integer(0), "collection_behavior": .integer(262401)]))
        XCTAssertEqual(result.auditEvent.payload["observed"], .object(["level": .integer(3), "sharing": .integer(1), "collection_behavior": .integer(262401)]))
        XCTAssertEqual(result.auditEvent.payload["capability"], .string("legacy_ineffectual"))
    }

    func testUnsupportedRequiredFlagsAndSharingFailWithoutChangingMode() throws {
        let window = FakeModeWindow()
        let engine = try VisibilityModeEngine(configurer: window, initialMode: .open)
        window.supportedCollectionBehaviorMask = 262401
        XCTAssertThrowsError(try engine.applyFromSettings(.spaceBehaviorProbe)) { error in
            XCTAssertEqual(error as? ModeConfigurationError, .unsupportedConfiguration)
        }
        window.supportedCollectionBehaviorMask = 262481
        window.legacySharingAvailable = false
        XCTAssertThrowsError(try engine.applyFromSettings(.legacySharingProbe)) { error in
            XCTAssertEqual(error as? ModeConfigurationError, .unsupportedConfiguration)
        }
        XCTAssertThrowsError(try engine.applyFromSettings(.spaceBehaviorProbe))
        XCTAssertEqual(engine.currentMode, .open)
        XCTAssertEqual(window.configuration, .init(level: 3, sharing: 1, collectionBehavior: 262401))
    }

    func testPartiallyAppliedFailureRestoresVerifiedPreviousConfigurationAndBadge() throws {
        let window = FakeModeWindow(); var badges: [VisibilityMode] = []
        let engine = try VisibilityModeEngine(configurer: window, initialMode: .open, refreshBadge: { badges.append($0) })
        window.failApplyCalls = [2]
        XCTAssertThrowsError(try engine.applyFromSettings(.spaceBehaviorProbe))
        XCTAssertEqual(window.configuration, .init(level: 3, sharing: 1, collectionBehavior: 262401))
        XCTAssertEqual(engine.currentMode, .open)
        XCTAssertEqual(badges, [.open])
        XCTAssertTrue(engine.isUsable)
    }

    func testObservedFlagMismatchFailsAndRollsBack() throws {
        let window = FakeModeWindow()
        let engine = try VisibilityModeEngine(configurer: window, initialMode: .open)
        window.driftApplyCalls = [2]
        XCTAssertThrowsError(try engine.applyFromSettings(.spaceBehaviorProbe)) { error in
            XCTAssertEqual(error as? ModeConfigurationError, .verificationFailed)
        }
        XCTAssertEqual(engine.currentMode, .open)
        XCTAssertEqual(window.configuration, .init(level: 3, sharing: 1, collectionBehavior: 262401))
    }

    func testFailedRollbackLatchesEngineUnusable() throws {
        let window = FakeModeWindow()
        let engine = try VisibilityModeEngine(configurer: window, initialMode: .open)
        window.failApplyCalls = [2, 3]
        XCTAssertThrowsError(try engine.applyFromSettings(.spaceBehaviorProbe)) { error in
            XCTAssertEqual(error as? ModeConfigurationError, .rollbackFailed)
        }
        XCTAssertFalse(engine.isUsable)
        XCTAssertThrowsError(try engine.applyFromSettings(.open)) { error in
            XCTAssertEqual(error as? ModeConfigurationError, .unusable)
        }
    }

    func testReceiptRollbackRestoresModeAfterPostApplyAuditFailureAndCannotBeReused() throws {
        let window = FakeModeWindow(); var badges: [VisibilityMode] = []
        let engine = try VisibilityModeEngine(configurer: window, initialMode: .open, refreshBadge: { badges.append($0) })
        let result = try engine.applyFromSettings(.spaceBehaviorProbe)
        try engine.rollback(result)
        XCTAssertEqual(engine.currentMode, .open)
        XCTAssertEqual(window.configuration, .init(level: 3, sharing: 1, collectionBehavior: 262401))
        XCTAssertEqual(badges, [.open, .spaceBehaviorProbe, .open])
        XCTAssertThrowsError(try engine.rollback(result)) { error in
            XCTAssertEqual(error as? ModeConfigurationError, .staleReceipt)
        }
        let stale = try engine.applyFromSettings(.legacySharingProbe)
        _ = try engine.applyFromSettings(.spaceBehaviorProbe)
        XCTAssertThrowsError(try engine.rollback(stale)) { error in
            XCTAssertEqual(error as? ModeConfigurationError, .staleReceipt)
        }
        XCTAssertEqual(engine.currentMode, .spaceBehaviorProbe)
    }

    func testDocumentedSDKConstantsMatchResearchConfiguration() {
        XCTAssertEqual(NSWindow.Level.floating.rawValue, 3)
        XCTAssertEqual(NSWindow.SharingType.none.rawValue, 0)
        XCTAssertEqual(NSWindow.SharingType.readOnly.rawValue, 1)
        XCTAssertEqual(NSWindow.CollectionBehavior.canJoinAllSpaces.rawValue, 1)
        XCTAssertEqual(NSWindow.CollectionBehavior.fullScreenAuxiliary.rawValue, 256)
        XCTAssertEqual(NSWindow.CollectionBehavior.canJoinAllApplications.rawValue, 262144)
        XCTAssertEqual(NSWindow.CollectionBehavior.stationary.rawValue, 16)
        XCTAssertEqual(NSWindow.CollectionBehavior.ignoresCycle.rawValue, 64)
    }
}

@MainActor private final class FakeModeWindow: WindowConfiguring {
    var configuration: WindowConfiguration
    var supportedCollectionBehaviorMask: UInt = 262481
    var legacySharingAvailable = true
    var ignoreLegacyNone = false
    var failApplyCalls: Set<Int> = []
    var driftApplyCalls: Set<Int> = []
    private var applyCalls = 0
    init(configuration: WindowConfiguration = .init(level: 3, sharing: 1, collectionBehavior: 262401)) {
        self.configuration = configuration
    }
    func snapshot() throws -> WindowConfiguration { configuration }
    func apply(_ configuration: WindowConfiguration) throws {
        applyCalls += 1
        self.configuration = .init(level: configuration.level,
            sharing: ignoreLegacyNone && configuration.sharing == 0 ? 1 : configuration.sharing,
            collectionBehavior: driftApplyCalls.contains(applyCalls) ? 0 : configuration.collectionBehavior)
        if failApplyCalls.contains(applyCalls) { throw ModeTestFailure.apply }
    }
}
private enum ModeTestFailure: Error { case apply }
