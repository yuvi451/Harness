import Foundation

/// Isolated CLI writer/reader used by the audit; never touches the app's live domain.
@main struct SettingsRestartProbe {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw CocoaError(.fileReadCorruptFile) }
        let action = CommandLine.arguments[1]
        let domain = CommandLine.arguments[2]
        guard domain.hasPrefix("HarnessRestartProbe.") else { throw CocoaError(.fileReadCorruptFile) }
        let store = SettingsStore(preferences: UserDefaultsPreferences(domain: domain))
        if action == "write" {
            var settings = store.settings
            settings.captureHotkey = Shortcut(functionKey: 11)
            settings.dismissHotkey = Shortcut(functionKey: 12)
            settings.scrollUpHotkey = Shortcut(functionKey: 13)
            settings.scrollDownHotkey = Shortcut(functionKey: 14)
            settings.model = "saved-custom-model"
            settings.systemPrompt = "Saved custom instructions\né🙂"
            settings.overlayPosition = .pinnedCorner
            settings.visibilityMode = .spaceBehaviorProbe
            settings.captureSource = .selectedWindow
            settings.selectedWindowID = 321
            settings.historyLength = 4
            settings.maxImageDimension = 1024
            settings.maxImageBytes = 500_000
            settings.networkSubmissionEnabled = true
            settings.calibrationEnabled = false
            settings.privacyMaskingEnabled = true
            settings.maskingRegions = [MaskRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4)]
            try store.save(settings)
            print("saved")
        } else if action == "read" {
            let settings = store.settings
            guard settings.captureHotkey.functionKey == 11, settings.dismissHotkey.functionKey == 12,
                  settings.scrollUpHotkey.functionKey == 13, settings.scrollDownHotkey.functionKey == 14, settings.model == "saved-custom-model",
                  settings.systemPrompt == "Saved custom instructions\né🙂",
                  settings.overlayPosition == .pinnedCorner, settings.visibilityMode == .spaceBehaviorProbe,
                  settings.captureSource == .selectedWindow, settings.selectedWindowID == 321,
                  settings.historyLength == 4,
                  settings.maxImageDimension == 1024, settings.maxImageBytes == 500_000,
                  settings.networkSubmissionEnabled, !settings.calibrationEnabled,
                  settings.privacyMaskingEnabled,
                  settings.maskingRegions == [MaskRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4)],
                  store.loadIssues.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            print("restart preserved all ordinary settings; Mode 2 starts and the saved ChatGPT state persists")
        } else if action == "cleanup" {
            let defaults = UserDefaults(suiteName: domain)!
            defaults.removePersistentDomain(forName: domain)
            guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
        } else { throw CocoaError(.fileReadCorruptFile) }
    }
}
