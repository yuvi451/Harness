import Foundation
import XCTest
@testable import HarnessCore

@MainActor private final class MemoryPreferences: Preferences {
    var values: [String: Any]
    var flushFailuresRemaining = 0
    init(_ values: [String: Any] = [:]) { self.values = values }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func flush() throws {
        if flushFailuresRemaining > 0 {
            flushFailuresRemaining -= 1
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

final class SettingsTests: XCTestCase {
    func testSystemPromptSurvivesCodableAndPreferenceRoundTrips() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(Settings())) as? [String:Any])
        let prompt = "Use concise answers.\nKeep Unicode: é🙂."
        object["systemPrompt"] = prompt
        let settings = try JSONDecoder().decode(Settings.self,from:JSONSerialization.data(withJSONObject:object))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(settings)) as? [String:Any])
        XCTAssertEqual(encoded["systemPrompt"] as? String,prompt)
        try await MainActor.run {
            let prefs = MemoryPreferences()
            let store = SettingsStore(preferences:prefs)
            try store.save(settings)
            XCTAssertEqual(prefs.values["systemPrompt"] as? String,prompt)
            let restored = SettingsStore(preferences:prefs)
            XCTAssertEqual(restored.settings,settings)
        }
    }
    func testInvalidStoredSystemPromptFallsBackAndReportsOnlyFieldName() async {
        await MainActor.run {
            for invalid:Any in [123,"   \n",String(repeating:"x",count:16_001),"secret\u{0}value"] {
                let store = SettingsStore(preferences:MemoryPreferences(["systemPrompt":invalid]))
                XCTAssertEqual(store.loadIssues,["Invalid preference: systemPrompt"])
            }
        }
    }
    func testPromptDefaultMigrationResetAndFailedSaveRetainPreviousValue() async throws {
        let legacy = try JSONEncoder().encode(Settings())
        XCTAssertEqual(try JSONDecoder().decode(Settings.self,from:legacy).effectiveSystemPrompt,Settings.defaultSystemPrompt)
        try await MainActor.run {
            let prefs = MemoryPreferences(["systemPrompt":"Original prompt"])
            let store = SettingsStore(preferences:prefs)
            var settings = store.settings; settings.systemPrompt = "Replacement prompt"
            prefs.flushFailuresRemaining = 1
            XCTAssertThrowsError(try store.save(settings))
            XCTAssertEqual(SettingsStore(preferences:prefs).settings.systemPrompt,"Original prompt")
            settings.systemPrompt = nil; try store.save(settings)
            XCTAssertNil(prefs.values["systemPrompt"])
            XCTAssertEqual(SettingsStore(preferences:prefs).settings.effectiveSystemPrompt,Settings.defaultSystemPrompt)
            for invalid in [String(repeating:"🙂",count:16_001),String(repeating:"a\u{301}",count:22_000)] {
                settings.systemPrompt = invalid; XCTAssertThrowsError(try store.save(settings))
            }
        }
    }
    func testStartupUsesModeTwoWithoutMutatingSavedPreferences() async {
        await MainActor.run {
            let prefs = MemoryPreferences(["visibilityMode": 0])
            let original = prefs.values as NSDictionary
            let store = SettingsStore(preferences: prefs)
            XCTAssertEqual(store.settings.visibilityMode, .spaceBehaviorProbe)
            XCTAssertEqual(prefs.values as NSDictionary, original)
            XCTAssertTrue(store.settings.networkSubmissionEnabled)
            XCTAssertFalse(store.settings.calibrationEnabled)
        }
    }
    func testAllOrdinaryPreferencesSurviveFreshUserDefaultsAdapter() async throws {
        try await MainActor.run {
            let domain = "HarnessSettingsTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let first = SettingsStore(preferences: UserDefaultsPreferences(domain: domain))
            var candidate = first.settings
            candidate.captureHotkey = Shortcut(functionKey: 11)
            candidate.dismissHotkey = Shortcut(functionKey: 12)
            candidate.scrollUpHotkey = Shortcut(functionKey: 13)
            candidate.scrollDownHotkey = Shortcut(functionKey: 14)
            candidate.model = "saved-custom-model"
            candidate.overlayPosition = .pinnedCorner
            candidate.visibilityMode = .legacySharingProbe
            candidate.captureSource = .selectedWindow
            candidate.selectedWindowID = 321
            candidate.historyLength = 4
            candidate.maxImageDimension = 1024
            candidate.maxImageBytes = 500_000
            candidate.networkSubmissionEnabled = true
            candidate.calibrationEnabled = false
            candidate.privacyMaskingEnabled = true
            candidate.maskingRegions = [MaskRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4)]
            try first.save(candidate)
            let restored = SettingsStore(preferences: UserDefaultsPreferences(domain: domain))
            candidate.visibilityMode = .spaceBehaviorProbe
            XCTAssertEqual(restored.settings, candidate)
            XCTAssertTrue(restored.loadIssues.isEmpty)
        }
    }

    func testFailedPersistenceDoesNotPublishOrRetainCandidateSettings() async throws {
        try await MainActor.run {
            let prefs = MemoryPreferences(["model": "previous-model", "unrelated": "keep"])
            let store = SettingsStore(preferences: prefs)
            let previous = store.settings
            let previousValues = prefs.values as NSDictionary
            var candidate = previous
            candidate.model = "new-model"
            candidate.selectedWindowID = 99
            prefs.flushFailuresRemaining = 1
            XCTAssertThrowsError(try store.save(candidate)) {
                XCTAssertEqual($0 as? SettingsPersistenceError, .saveFailed)
            }
            XCTAssertEqual(store.settings, previous)
            XCTAssertEqual(prefs.values as NSDictionary, previousValues)
            XCTAssertEqual(SettingsStore(preferences: prefs).settings.model, "previous-model")
        }
    }

    func testFailedRollbackIsDistinguishedFromRecoverableSaveFailure() async throws {
        try await MainActor.run {
            let prefs = MemoryPreferences(["model": "previous-model"])
            let store = SettingsStore(preferences: prefs)
            var candidate = store.settings
            candidate.model = "new-model"
            prefs.flushFailuresRemaining = 2
            XCTAssertThrowsError(try store.save(candidate)) {
                XCTAssertEqual($0 as? SettingsPersistenceError, .rollbackFailed)
            }
            XCTAssertEqual(store.settings.model, "previous-model")
        }
    }

    func testRetiredIdlePreferenceCannotChangeSettingsAndIsRemovedOnSave() async throws {
        try await MainActor.run {
            let prefs = MemoryPreferences(["idleDismissSeconds":Double.nan,"model":"saved-model"])
            let store = SettingsStore(preferences:prefs)
            XCTAssertTrue(store.loadIssues.isEmpty)
            try store.save(store.settings)
            XCTAssertNil(prefs.object(forKey:"idleDismissSeconds"))
            XCTAssertEqual(SettingsStore(preferences:prefs).settings.model,"saved-model")
        }
    }

    func testDefaultsAreSafeAndValid() async throws {
        try await MainActor.run {
            let store = SettingsStore(preferences: MemoryPreferences())
            let s = store.settings
            XCTAssertEqual(s.captureHotkey.label, "F8")
            XCTAssertEqual(s.dismissHotkey.label, "F9")
            XCTAssertEqual(s.scrollUpHotkey.label, "F10")
            XCTAssertEqual(s.scrollDownHotkey.label, "F11")
            XCTAssertEqual(s.provider.rawValue, "ChatGPT plan")
            XCTAssertEqual(s.model, "gpt-6.1-sol")
            XCTAssertEqual(s.overlayPosition, .nearCursor)
            XCTAssertEqual(s.visibilityMode, .spaceBehaviorProbe)
            XCTAssertEqual(s.captureSource, .excludingSelf)
            XCTAssertEqual(s.historyLength, 10)
            XCTAssertEqual(s.maxImageDimension, 1568)
            XCTAssertEqual(s.maxImageBytes, 1_000_000)
            XCTAssertTrue(s.networkSubmissionEnabled)
            XCTAssertFalse(s.calibrationEnabled)
            XCTAssertFalse(s.privacyMaskingEnabled)
            XCTAssertEqual(try s.validated(), s)
            XCTAssertTrue(store.loadIssues.isEmpty)
        }
    }

    func testLaunchStartsModeTwoAndRemembersSubmissionState() async throws {
        try await MainActor.run {
            let prefs = MemoryPreferences()
            let first = SettingsStore(preferences: prefs)
            var s = first.settings
            s.visibilityMode = .spaceBehaviorProbe
            s.networkSubmissionEnabled = true
            s.model = "chosen-model"
            try first.save(s)
            XCTAssertEqual(first.settings.visibilityMode, .spaceBehaviorProbe)
            XCTAssertTrue(first.settings.networkSubmissionEnabled)
            let second = SettingsStore(preferences: prefs)
            XCTAssertEqual(second.settings.visibilityMode, .spaceBehaviorProbe)
            XCTAssertTrue(second.settings.networkSubmissionEnabled)
            XCTAssertEqual(second.settings.model, "chosen-model")
            XCTAssertEqual(prefs.values["visibilityMode"] as? Int, 2)
            XCTAssertEqual(prefs.values["networkSubmissionEnabled"] as? Bool, true)
        }
    }

    func testMalformedFieldsAreSanitizedIndependently() async {
        await MainActor.run {
            let prefs = MemoryPreferences([
                "captureHotkey": true, "dismissHotkey": "9", "provider": "Other",
                "historyLength": 4.5, "idleDismissSeconds": Double.nan,
                "maxImageDimension": -1, "maxImageBytes": 1_000_001,
                "networkSubmissionEnabled": "true", "calibrationEnabled": 1,
                "privacyMaskingEnabled": "false", "visibilityMode": 999,
                "captureSource": "legacy", "overlayPosition": "hidden", "model": "valid-model"
            ])
            let store = SettingsStore(preferences: prefs)
            XCTAssertEqual(store.settings.model, "valid-model")
            XCTAssertEqual(store.settings.captureHotkey.functionKey, 8)
            XCTAssertEqual(store.settings.dismissHotkey.functionKey, 9)
            XCTAssertEqual(store.settings.historyLength, 10)
            XCTAssertFalse(store.settings.calibrationEnabled)
            XCTAssertTrue(store.settings.networkSubmissionEnabled)
            XCTAssertEqual(store.loadIssues.count, 12)
            XCTAssertFalse(store.loadIssues.contains { $0.contains("valid-model") })
        }
    }

    func testDuplicateShortcutsAreRejectedBeforeAnySave() async throws {
        try await MainActor.run {
            let prefs = MemoryPreferences()
            let store = SettingsStore(preferences: prefs)
            let original = store.settings
            let originalValues = prefs.values as NSDictionary
            var invalid = original
            invalid.dismissHotkey = invalid.captureHotkey
            XCTAssertThrowsError(try store.save(invalid))
            XCTAssertEqual(store.settings, original)
            XCTAssertEqual(prefs.values as NSDictionary, originalValues)
        }
    }

    func testLoadedShortcutCollisionPreservesDistinctDefaults() async {
        await MainActor.run {
            let store = SettingsStore(preferences: MemoryPreferences([
                "captureHotkey": 9, "dismissHotkey": 9, "scrollUpHotkey": 12
            ]))
            XCTAssertEqual(store.settings.captureHotkey.functionKey, 8)
            XCTAssertEqual(store.settings.dismissHotkey.functionKey, 9)
            XCTAssertEqual(store.settings.scrollUpHotkey.functionKey, 12)
            XCTAssertFalse(store.loadIssues.isEmpty)
        }
    }

    func testNumericAndModelValidation() {
        let invalidMutations: [(inout Settings) -> Void] = [
            { $0.captureHotkey = Shortcut(functionKey: 0) },
            { $0.dismissHotkey = Shortcut(functionKey: 21) },
            { $0.historyLength = -1 }, { $0.historyLength = 11 },
            { $0.maxImageDimension = 63 }, { $0.maxImageDimension = 1569 },
            { $0.maxImageBytes = 9_999 }, { $0.maxImageBytes = 1_000_001 },
            { $0.model = " \n" }, { $0.model = String(repeating: "x", count: 129) },
            { $0.model = "model\nsecret" }
        ]
        for mutation in invalidMutations {
            var s = Settings()
            mutation(&s)
            XCTAssertThrowsError(try s.validated())
        }
    }

    func testSelectedWindowSelectionAllowsLaterIdentityChoice() async throws {
        var s = Settings()
        s.captureSource = .selectedWindow
        XCTAssertNoThrow(try s.validated())
        s.selectedWindowID = 0
        XCTAssertThrowsError(try s.validated())
        s.selectedWindowID = 123
        XCTAssertNoThrow(try s.validated())
        await MainActor.run {
            let store = SettingsStore(preferences: MemoryPreferences(["captureSource": "sck_selected_window"]))
            XCTAssertEqual(store.settings.captureSource, .selectedWindow)
            XCTAssertTrue(store.loadIssues.isEmpty)
        }
    }

    func testMaskBoundsAreFinitePositiveAndContained() {
        XCTAssertTrue(MaskRegion(x: 0, y: 0, width: 1, height: 1).isValid)
        let invalid = [
            MaskRegion(x: .nan, y: 0, width: 0.2, height: 0.2),
            MaskRegion(x: 0, y: .infinity, width: 0.2, height: 0.2),
            MaskRegion(x: -0.1, y: 0, width: 0.2, height: 0.2),
            MaskRegion(x: 0.9, y: 0, width: 0.2, height: 0.2),
            MaskRegion(x: 0, y: 0.9, width: 0.2, height: 0.2),
            MaskRegion(x: 0, y: 0, width: 0, height: 0.2)
        ]
        for region in invalid {
            XCTAssertFalse(region.isValid)
            var s = Settings()
            s.maskingRegions = [region]
            XCTAssertThrowsError(try s.validated())
        }
        var s = Settings()
        s.maskingRegions = Array(repeating: MaskRegion(x: 0, y: 0, width: 1, height: 1), count: 33)
        XCTAssertThrowsError(try s.validated())
    }

    func testInvalidStoredMasksAreDroppedAndReported() async {
        await MainActor.run {
            let store = SettingsStore(preferences: MemoryPreferences([
                "maskingRegions": [["x": 0.9, "y": 0.0, "width": 0.2, "height": 0.2]],
                "privacyMaskingEnabled": true
            ]))
            XCTAssertTrue(store.settings.maskingRegions.isEmpty)
            XCTAssertTrue(store.settings.privacyMaskingEnabled)
            XCTAssertFalse(store.loadIssues.isEmpty)
        }
    }

    func testValidSettingsRoundTripPreservesScopeAndMasks() async throws {
        try await MainActor.run {
            let prefs = MemoryPreferences()
            let store = SettingsStore(preferences: prefs)
            var s = Settings()
            s.captureHotkey = Shortcut(functionKey: 12)
            s.overlayPosition = .pinnedCorner
            s.captureSource = .selectedWindow
            s.selectedWindowID = 321
            s.maskingRegions = [MaskRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4)]
            s.privacyMaskingEnabled = true
            s.historyLength = 0
            try store.save(s)
            XCTAssertEqual(SettingsStore(preferences: prefs).settings, s)
        }
    }

    func testBadSelectedWindowNumbersAreNotCoerced() async {
        await MainActor.run {
            for value: Any in [true, -1, 1.5, UInt64(UInt32.max) + 1, "12"] {
                let store = SettingsStore(preferences: MemoryPreferences(["selectedWindowID": value]))
                XCTAssertNil(store.settings.selectedWindowID)
                XCTAssertFalse(store.loadIssues.isEmpty)
            }
        }
    }

    func testModeBadgesRemainUnambiguous() {
        XCTAssertEqual(VisibilityMode.open.badge, "MODE 0 · OPEN")
        XCTAssertEqual(VisibilityMode.legacySharingProbe.badge, "MODE 1 · LEGACY-SHARING-PROBE")
        XCTAssertEqual(VisibilityMode.spaceBehaviorProbe.badge, "MODE 2 · COMBINED-EXCLUSION-PROBE")
    }

    func testClearingSelectedWindowRemovesStaleIdentity() async throws {
        try await MainActor.run {
            let prefs = MemoryPreferences(["selectedWindowID": 77])
            let store = SettingsStore(preferences: prefs)
            XCTAssertEqual(store.settings.selectedWindowID, 77)
            var s = store.settings
            s.selectedWindowID = nil
            try store.save(s)
            XCTAssertNil(prefs.object(forKey: "selectedWindowID"))
            XCTAssertNil(SettingsStore(preferences: prefs).settings.selectedWindowID)
        }
    }

    func testUserDefaultsAdapterPreservesTypedSettings() async throws {
        try await MainActor.run {
            let domain = "HarnessSettingsTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let store = SettingsStore(preferences: UserDefaultsPreferences(defaults))
            var s = store.settings
            s.historyLength = 2
            s.captureHotkey = Shortcut(functionKey: 20)
            s.selectedWindowID = UInt32.max
            s.privacyMaskingEnabled = true
            s.maskingRegions = [MaskRegion(x: 0, y: 0, width: 0.5, height: 0.5)]
            try store.save(s)
            let restored = SettingsStore(preferences: UserDefaultsPreferences(defaults))
            XCTAssertEqual(restored.settings, s)
            XCTAssertTrue(restored.loadIssues.isEmpty)
        }
    }
}
