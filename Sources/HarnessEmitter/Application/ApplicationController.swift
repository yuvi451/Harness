import AppKit
import HarnessCore

@MainActor public final class ApplicationController: NSObject, NSApplicationDelegate {
    private let store: SettingsStore
    private let audit: AuditLogger
    private let privacy: PrivacyController
    private let account: any ApplicationAccountManaging
    private let engine = ScreenCaptureEngine()
    private let capture: CaptureService
    private let hotkeys: HotkeyManager
    private let gate = SingleFlightCaptureGate()
    private let overlay = OverlayController()
    let settingsUI = SettingsWindowController()
    private let modelsLoader: @MainActor (String) async throws -> [String]
    private let windowsLoader: @MainActor () async throws -> [ShareableWindowChoice]
    private let screenPermissionGranted: @MainActor () -> Bool
    private let requestScreenPermission: @MainActor () -> Bool
    private var modes: VisibilityModeEngine?
    private var statusItem: NSStatusItem?
    private var operation: Task<Void,Never>?
    private var authentication: Task<Void,Never>?
    private var saveTask: Task<Void,Never>?
    private var modelTask: Task<Void,Never>?
    private var windowsTask: Task<Void,Never>?
    private var permissionTask: Task<Void,Never>?
    private var calibrationTask: Task<Void,Never>?
    private var modelGeneration: UInt64 = 0
    private var authenticationGeneration: UInt64 = 0
    private(set) var ready = false
    private var launching = true
    private(set) var blocked = false
    private var presentationGeneration: UInt64 = 0
    private var settingsApplying = false
    private var accountDisconnecting = false
    private var settingsRevision: UInt64 = 0
    private var configurationChangedNS = DispatchTime.now().uptimeNanoseconds
    public init(auditURL: URL = POSIXAuditSink.defaultURL, preferences: (any Preferences)? = nil,
                account: (any ApplicationAccountManaging)? = nil, hotkeys: HotkeyManager? = nil,
                privacy: PrivacyController = PrivacyController(),
                captureEngine: (any CaptureEngineProtocol)? = nil,
                modelsLoader: (@MainActor (String) async throws -> [String])? = nil,
                windowsLoader: (@MainActor () async throws -> [ShareableWindowChoice])? = nil,
                screenPermissionGranted: @escaping @MainActor () -> Bool = { CaptureService.screenRecordingPermissionGranted },
                requestScreenPermission: @escaping @MainActor () -> Bool = { CaptureService.requestScreenRecordingPermissionFromSettings() }) throws {
        store = SettingsStore(preferences: preferences ?? UserDefaultsPreferences())
        self.account = account ?? ChatGPTAccountController()
        self.privacy = privacy
        self.hotkeys = hotkeys ?? HotkeyManager()
        self.modelsLoader = modelsLoader ?? { try await ChatGPTProvider.availableModels(token: $0) }
        self.windowsLoader = windowsLoader ?? { [engine] in try await engine.refreshShareableWindows() }
        self.screenPermissionGranted = screenPermissionGranted; self.requestScreenPermission = requestScreenPermission
        audit = AuditLogger(sink: try POSIXAuditSink(url:auditURL))
        capture = CaptureService(engine:captureEngine ?? engine)
        super.init()
        modes = try VisibilityModeEngine(configurer:AppKitWindowConfigurer(window:overlay.panel))
    }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenus(); wireSettings()
        account.onStatusChanged = { [weak self] in guard let self else { return }; self.refreshAccountUI() }
        Task { await launch() }
    }
    func launch() async {
        defer { launching = false }
        settingsUI.allowModes()
        do {
            if account.isConnected && !store.settings.networkSubmissionEnabled {
                var settings = store.settings; settings.networkSubmissionEnabled = true; try store.save(settings)
            }
            try await audit.record(.init(.appLaunch,payload:["app_version":.string(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development"),"environment":.object(EnvironmentCapabilityProbe().snapshot()),"source":.string(store.settings.captureSource.rawValue),"load_issues":.array(store.loadIssues.map(JSONValue.string)),"configuration_changed_ns":.integer(Int(configurationChangedNS))]),mode:store.settings.visibilityMode.rawValue)
            try await audit.record(.init(.permissionStatus,payload:["permission":.string("screen_recording"),"status":.string(screenPermissionGranted() ? "granted":"not_granted")]),mode:store.settings.visibilityMode.rawValue)
            if store.settings.networkSubmissionEnabled { try await privacy.grantConsent(acknowledged:true) }
            try await privacy.applyHistoryLimit(store.settings.historyLength)
            try await registerHotkeys(settings:store.settings)
            ready = !blocked && !accountDisconnecting && !settingsApplying; settingsUI.allowModes(); settingsUI.load(store.settings); refreshAccountUI()
            updateStatus(account.isConnected ? "Ready. Press \(store.settings.captureHotkey.label) to analyze your screen." : "Continue with ChatGPT to get started.")
        } catch { if error is HotkeyError { ready = false; updateStatus(Self.safeMessage(error) + " Open Settings to choose other shortcuts.") } else { failClosed(error) } }
        showSettings()
        if !blocked && !screenPermissionGranted() { settingsUI.onPermission?() }
    }
    private func setupMenus() {
        let menu = NSMenu(); let appItem = NSMenuItem(); let appMenu = NSMenu(title:"Harness")
        let settings = NSMenuItem(title:"Settings…",action:#selector(showSettings),keyEquivalent:","); settings.target = self; appMenu.addItem(settings)
        appMenu.addItem(.separator()); let quitItem = NSMenuItem(title:"Quit Harness",action:#selector(quit),keyEquivalent:"q"); quitItem.target = self; appMenu.addItem(quitItem)
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength); statusItem?.button?.title = "HARNESS · 2"
        let statusMenu = NSMenu(); let statusSettings = NSMenuItem(title:"Settings…",action:#selector(showSettings),keyEquivalent:""); statusSettings.target = self; statusMenu.addItem(statusSettings)
        let statusQuit = NSMenuItem(title:"Quit Harness",action:#selector(quit),keyEquivalent:""); statusQuit.target = self; statusMenu.addItem(statusQuit); statusItem?.menu = statusMenu
    }
    func wireSettings() {
        settingsUI.onSave = { [weak self] value,ack in
            guard let self, self.saveTask == nil else { return }
            self.settingsUI.setBusy(true, for: .save)
            self.saveTask = Task { [weak self] in
                guard let self else { return }
                defer { self.saveTask = nil; self.settingsUI.setBusy(false, for: .save) }
                do { try await self.applyFromSettings(value,acknowledged:ack) }
                catch { if !self.blocked { self.updateStatus(Self.safeMessage(error)) } }
            }
        }
        settingsUI.onRefreshWindows = { [weak self] in
            guard let self, self.windowsTask == nil else { return }
            self.settingsUI.setBusy(true, for: .refreshWindows)
            self.windowsTask = Task { [weak self] in
                guard let self else { return }
                defer { self.windowsTask = nil; self.settingsUI.setBusy(false, for: .refreshWindows) }
                do { let choices = try await self.windowsLoader(); try Task.checkCancellation(); self.settingsUI.setWindows(choices) }
                catch { if !Task.isCancelled { self.updateStatus(Self.safeMessage(error)) } }
            }
        }
        settingsUI.onPermission = { [weak self] in
            guard let self, self.permissionTask == nil else { return }
            self.settingsUI.setBusy(true, for: .permission)
            let granted = self.screenPermissionGranted() || self.requestScreenPermission()
            self.settingsUI.setScreenRecordingPermission(granted:granted)
            self.permissionTask = Task {
                defer { self.permissionTask = nil; self.settingsUI.setBusy(false, for: .permission) }
                do { try await self.audit.record(.init(.permissionStatus,payload:["permission":.string("screen_recording"),"status":.string(granted ? "granted":"denied_or_restart_required")]),mode:self.store.settings.visibilityMode.rawValue); self.updateStatus(granted ? "Permission granted." : "Grant Harness in System Settings → Privacy & Security → Screen Recording; restart if required.") } catch { self.failClosed(error) }
            }
        }
        settingsUI.onShowCalibration = { [weak self] in
            guard let self, self.calibrationTask == nil else { return }
            self.settingsUI.setBusy(true, for: .calibration)
            self.calibrationTask = Task {
                defer { self.calibrationTask = nil; self.settingsUI.setBusy(false, for: .calibration) }
                await self.showCalibrationFromSettings()
            }
        }
        settingsUI.onChatGPTSignIn = { [weak self] in self?.beginSignIn() }
        settingsUI.onAddAccount = { [weak self] in self?.beginSignIn(newAccount:true) }
        settingsUI.onSelectAccount = { [weak self] id in self?.beginSignIn(selectedClientID:id) }
        settingsUI.onCancelSignIn = { [weak self] in
            guard let self else { return }
            self.authentication?.cancel(); self.account.cancelSignIn()
            self.updateStatus("Sign-in cancelled. Continue with ChatGPT to retry.")
        }
        settingsUI.onChatGPTSignOut = { [weak self] in
            guard let self, !self.accountDisconnecting else { return }
            self.accountDisconnecting = true
            self.settingsUI.setBusy(true, for: .signOut)
            self.authenticationGeneration &+= 1
            self.authentication?.cancel(); self.authentication = nil
            self.account.cancelSignIn(); self.settingsUI.setBusy(false, for: .signIn)
            self.cancelModelRefresh(); self.saveTask?.cancel()
            self.operation?.cancel(); self.presentationGeneration &+= 1
            self.settingsRevision &+= 1; self.ready = false; self.overlay.dismiss()
            var settings = self.store.settings; settings.networkSubmissionEnabled = false
            self.settingsUI.revokeConsent()
            do { try self.store.save(settings); self.settingsUI.load(settings, preservingDraft:true) }
            catch { self.accountDisconnecting = false; self.settingsUI.setBusy(false, for: .signOut); self.failClosed(error); return }
            Task {
                defer { self.accountDisconnecting = false; self.settingsUI.setBusy(false, for: .signOut); self.restoreReadiness() }
                await self.privacy.revokeConsent()
                do {
                    try await self.audit.record(.init(.overlayDismissed,payload:["reason":.string("account_disconnect")]),mode:settings.visibilityMode.rawValue)
                    try await self.audit.record(.init(.settingsChanged,payload:["status":.string("account_disconnect"),"network_enabled":.bool(false)]),mode:settings.visibilityMode.rawValue)
                    try self.account.signOut(); self.refreshAccountUI()
                    self.updateStatus("Disconnected. Remote submission is disabled.")
                } catch { if error is AuditError { self.failClosed(error) } else { self.updateStatus("Account disconnection failed. Remote submission is disabled; retry disconnection.") } }
            }
        }
        settingsUI.onRefreshModels = { [weak self] in self?.beginModelRefresh() }
    }
    private func refreshAccountUI() {
        settingsUI.setAccountStatus(account.accountStatus,connected:account.isConnected)
        settingsUI.setAccountChoices(account.accountChoices,selectedID:account.selectedAccountID)
    }
    private func beginSignIn(newAccount:Bool = false, selectedClientID:String? = nil) {
        guard authentication == nil, !settingsApplying, !accountDisconnecting else { return }
        if account.isConnected && !newAccount && selectedClientID == nil {
            updateStatus("ChatGPT is connected. Use \(store.settings.captureHotkey.label) to capture."); return
        }
        cancelModelRefresh(); operation?.cancel(); presentationGeneration &+= 1; overlay.dismiss()
        authenticationGeneration &+= 1; let generation = authenticationGeneration
        settingsUI.setBusy(true,for:.signIn)
        authentication = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.authenticationGeneration {
                    self.authentication = nil; self.settingsUI.setBusy(false,for:.signIn)
                    NSApp.activate(ignoringOtherApps:true); self.settingsUI.window?.makeKeyAndOrderFront(nil)
                }
            }
            do {
                if let current = self.operation { await current.value }
                try Task.checkCancellation()
                guard generation == self.authenticationGeneration else { return }
                if newAccount || selectedClientID != nil { await self.privacy.clear() }
                try Task.checkCancellation()
                if let selectedClientID { try self.account.selectAccount(selectedClientID) }
                if newAccount || !self.account.isConnected { try await self.account.signIn(newAccount:newAccount) }
                try Task.checkCancellation()
                guard generation == self.authenticationGeneration, !self.accountDisconnecting else { return }
                self.refreshAccountUI()
                if self.account.isConnected {
                    var settings = self.store.settings; settings.networkSubmissionEnabled = true
                    try await self.applyFromSettings(settings,acknowledged:true)
                    self.updateStatus("Ready. Press \(settings.captureHotkey.label) to analyze your screen.")
                    self.beginModelRefresh()
                } else { self.updateStatus(self.account.accountStatus) }
            } catch {
                if generation == self.authenticationGeneration, !Task.isCancelled {
                    self.refreshAccountUI(); self.updateStatus(Self.safeMessage(error))
                }
            }
        }
    }
    private func restoreReadiness() { ready = !blocked && !settingsApplying && !accountDisconnecting && !launching }
    private func cancelModelRefresh() {
        modelGeneration &+= 1; modelTask?.cancel(); modelTask = nil
        settingsUI.setBusy(false, for: .refreshModels)
    }
    private func beginModelRefresh() {
        guard modelTask == nil, !accountDisconnecting, !blocked else { return }
        modelGeneration &+= 1; let generation = modelGeneration
        settingsUI.setBusy(true, for: .refreshModels)
        modelTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.modelGeneration { self.modelTask = nil; self.settingsUI.setBusy(false, for: .refreshModels) } }
            do {
                let token = try await self.account.accessToken(); try Task.checkCancellation()
                let models = try await self.modelsLoader(token); try Task.checkCancellation()
                guard generation == self.modelGeneration, !self.accountDisconnecting else { return }
                self.settingsUI.setModels(models)
                self.updateStatus("Loaded \(models.count) account models. Your saved ChatGPT choice is unchanged.")
            } catch { if generation == self.modelGeneration, !Task.isCancelled { self.updateStatus("Could not retrieve account models. " + Self.safeMessage(error)) } }
        }
    }
    private func registerHotkeys(settings:Settings) async throws {
        do {
            try hotkeys.configure(settings:settings) { [weak self] action in self?.physicalHotkey(action) }
            for (action,key) in [("capture",settings.captureHotkey),("dismiss",settings.dismissHotkey),("scroll_up",settings.scrollUpHotkey),("scroll_down",settings.scrollDownHotkey)] {
                try await audit.record(.init(.hotkeyRegistered,payload:["action":.string(action),"shortcut":.string(key.label)]),mode:settings.visibilityMode.rawValue)
            }
        } catch {
            hotkeys.shutdown()
            try await audit.record(.init(.hotkeyRegistrationFailed,payload:["reason":.string(Self.safeMessage(error))]),mode:settings.visibilityMode.rawValue)
            throw error
        }
    }
    private func applyFromSettings(_ value:Settings, acknowledged:Bool) async throws {
        try Task.checkCancellation()
        guard !blocked else { throw AuditError.latchedFailure }
        guard !launching else { updateStatus("Harness is starting. Please wait before saving Settings."); return }
        guard !settingsApplying else { updateStatus("Settings are being applied. Please wait."); return }
        guard !accountDisconnecting else { updateStatus("Account disconnection is in progress. Please wait before saving Settings."); return }
        try value.validated()
        if value.networkSubmissionEnabled && !acknowledged { throw PrivacyError.consentRequired }
        settingsApplying = true; settingsRevision &+= 1
        let revision = settingsRevision; let previous = store.settings
        presentationGeneration &+= 1
        var transition: ModeTransition?
        defer { settingsApplying = false; restoreReadiness() }
        ready = false
        do {
            if let current = operation {
                current.cancel(); overlay.dismiss(); await privacy.clear()
                await current.value
                try Task.checkCancellation()
                guard revision == settingsRevision else { throw CancellationError() }
            }
            if value.networkSubmissionEnabled { try await privacy.grantConsent(acknowledged:acknowledged) } else { await privacy.revokeConsent() }
            guard revision == settingsRevision else { throw CancellationError() }
            try await registerHotkeys(settings:value)
            guard revision == settingsRevision else { throw CancellationError() }
            try await privacy.applyHistoryLimit(value.historyLength)
            guard revision == settingsRevision else { throw CancellationError() }
            if value.visibilityMode != previous.visibilityMode {
                try await audit.record(.init(.modeChanged,payload:["from":.integer(previous.visibilityMode.rawValue),"to":.integer(value.visibilityMode.rawValue),"status":.string("requested")]),mode:previous.visibilityMode.rawValue)
                guard revision == settingsRevision, let modes else { throw CancellationError() }
                transition = try modes.applyFromSettings(value.visibilityMode)
                if let transition { try await audit.record(transition.auditEvent,mode:value.visibilityMode.rawValue) }
                guard revision == settingsRevision else { throw CancellationError() }
            }
            // Stamp the completed synchronous preference commit, then audit it before
            // admitting a hotkey. Time spent writing the audit cannot shorten settling.
            try store.save(value)
            let changed = DispatchTime.now().uptimeNanoseconds
            configurationChangedNS = changed
            try await audit.record(.init(.settingsChanged,payload:["status":.string("applied"),"source":.string(value.captureSource.rawValue),"network_enabled":.bool(value.networkSubmissionEnabled),"configuration_changed_ns":.integer(Int(changed))]),mode:value.visibilityMode.rawValue)
            guard revision == settingsRevision else { throw CancellationError() }
            ready = true; settingsUI.load(value); updateStatus("Settings applied. Capture requires your physical \(value.captureHotkey.label) press.")
        } catch {
            if let transition { do { try modes?.rollback(transition) } catch { failClosed(error); throw error } }
            if value.visibilityMode != previous.visibilityMode, !(error is AuditError) {
                do { try await audit.record(.init(.modeChanged,payload:["from":.integer(previous.visibilityMode.rawValue),"to":.integer(value.visibilityMode.rawValue),"status":.string("failed"),"reason":.string("configuration_or_settings_failure")]),mode:previous.visibilityMode.rawValue) } catch { failClosed(error); throw error }
            }
            if !(error is AuditError), (error as? SettingsPersistenceError) != .rollbackFailed,
               revision != settingsRevision || error is HotkeyError || (error as? SettingsPersistenceError) == .saveFailed {
                await privacy.revokeConsent()
                var safe = previous
                if revision != settingsRevision { safe.networkSubmissionEnabled = false }
                do {
                    try await registerHotkeys(settings:safe)
                    if revision != settingsRevision { safe.networkSubmissionEnabled = false }
                    try store.save(safe)
                    if safe.networkSubmissionEnabled { try await privacy.grantConsent(acknowledged:true) }
                    else { settingsUI.revokeConsent() }
                    if revision != settingsRevision {
                        await privacy.revokeConsent(); safe.networkSubmissionEnabled = false
                        try store.save(safe); settingsUI.revokeConsent()
                    }
                    settingsUI.load(safe)
                } catch { failClosed(error); throw error }
                if revision != settingsRevision { return }
            } else {
                await privacy.revokeConsent()
                var safe = previous; safe.networkSubmissionEnabled = false
                do { try store.save(safe) } catch { failClosed(error); throw error }
                failClosed(error)
            }
            throw error
        }
    }
    /// This is the sole production capture entry, bound only to registered Carbon key events.
    private func physicalHotkey(_ action:HotkeyAction) {
        guard !blocked else { return }
        if case .dismiss = action { dismiss(reason:"hotkey"); return }
        guard ready else { return }
        switch action {
        case .capture:
            guard authentication == nil else { updateStatus("Finish ChatGPT sign-in, then press \(store.settings.captureHotkey.label). No restart is needed."); return }
            guard !store.settings.networkSubmissionEnabled || account.isConnected else { updateStatus("Continue with ChatGPT to get started."); return }
            guard gate.acquire() else { Task { do { try await audit.record(.init(.captureFailed,payload:["reason":.string("operation_busy")]),mode:store.settings.visibilityMode.rawValue) } catch { failClosed(error) } }; return }
            presentationGeneration &+= 1
            let settings = store.settings
            let cursor = NSEvent.mouseLocation
            operation = Task { [weak self] in
                guard let self else { return }
                defer { self.gate.release(); self.operation = nil }
                await self.captureFromHotkey(settings:settings,cursor:cursor)
            }
        case .dismiss: dismiss(reason:"hotkey")
        case .scrollUp: overlay.scroll(.up)
        case .scrollDown: overlay.scroll(.down)
        }
    }
    private func captureFromHotkey(settings:Settings,cursor:CGPoint) async {
        let captureID = UUID(); let started = DispatchTime.now().uptimeNanoseconds
        var captureFinished = false
        do {
            let displayID = Self.cursorDisplayID()
            try await audit.record(.init(.captureStarted,payload:["source":.string(settings.captureSource.rawValue),"display_id":.integer(Int(displayID)),"capture_id":.string(captureID.uuidString),"window_id":.integer(overlay.overlayWindowID),"owner_pid":.integer(Int(ProcessInfo.processInfo.processIdentifier)),"monotonic_ns":.integer(Int(started)),"configuration_changed_ns":.integer(Int(configurationChangedNS))]),mode:settings.visibilityMode.rawValue)
            // Original pixels are scoped to preparation and released before remote streaming.
            let prepared = try await prepareCapture(settings:settings,captureID:captureID,started:started,cursor:cursor)
            let image = prepared.image
            captureFinished = true
            overlay.dismiss()
            try Task.checkCancellation()
            if settings.networkSubmissionEnabled {
                let token: String
                do { token = try await account.accessToken() } catch {
                    try await audit.record(.init(.llmFailed,payload:["reason":.string("account_authentication_unavailable"),"capture_id":.string(captureID.uuidString)]),mode:settings.visibilityMode.rawValue); throw error
                }
                let service = RemoteSubmissionService(privacy:privacy,audit:audit)
                let result = try await service.submit(image:image,settings:settings,
                    prompt:"Answer the question shown in this capture.",
                    captureID:captureID,credential:token,source:settings.captureSource,
                    selectedWindowID:settings.captureSource == .selectedWindow ? settings.selectedWindowID : nil)
                try Task.checkCancellation()
                guard prepared.displayFrames == Self.displayFrames() else { throw CaptureError.displayUnavailable }
                try await showOverlay(settings:settings,text:result.response,
                                      pane:prepared.pane,cursor:cursor,style:prepared.style)
            } else {
                updateStatus("Capture complete. ChatGPT analysis is disabled in Settings.")
            }
        } catch is CancellationError {
            overlay.dismiss(); await privacy.clear()
            if !captureFinished {
                do { try await audit.record(.init(.captureFailed,payload:["reason":.string("cancelled"),"capture_id":.string(captureID.uuidString)]),mode:settings.visibilityMode.rawValue) }
                catch { failClosed(error) }
            }
        }
        catch {
            overlay.dismiss(); await privacy.clear()
            if error is AuditError { failClosed(error); return }
            if Task.isCancelled {
                if !captureFinished {
                    do { try await audit.record(.init(.captureFailed,payload:["reason":.string("cancelled"),"capture_id":.string(captureID.uuidString)]),mode:settings.visibilityMode.rawValue) }
                    catch { failClosed(error) }
                }
                return
            }
            do {
                if !captureFinished {
                    try await audit.record(.init(.captureFailed,payload:["reason":.string(Self.safeMessage(error)),"capture_id":.string(captureID.uuidString)]),mode:settings.visibilityMode.rawValue)
                }
                updateStatus(Self.safeMessage(error))
            } catch is CancellationError {} catch { failClosed(error) }
        }
    }
    private struct PreparedCapture {
        let image: ProcessedImage
        let pane: CGRect?
        let style: OverlayStyle
        let displayFrames: [UInt32:CGRect]
    }
    private func prepareCapture(settings:Settings,captureID:UUID,started:UInt64,cursor:CGPoint) async throws -> PreparedCapture {
        let visible = overlay.isVisible
        let panelRect = overlay.screenRect
        let patchRect = overlay.patchScreenRect
        let generation = presentationGeneration
        let displaysBefore = Self.displayFrames()
        let frame = try await capture.capture(settings:settings)
        try Task.checkCancellation()
        let displaysAfter = Self.displayFrames()
        let geometry = displaysBefore[frame.displayID].map {
            CalibrationGeometry(displayID:frame.displayID,appKitDisplayFrame:$0,cgDisplayFrame:frame.displayFrame,
                capturedBounds:frame.capturedBounds,displayScale:frame.displayScale,rotationDegrees:frame.rotation,
                screenshotOrientation:.displayOriented)
        }
        // Native visibility metadata cannot prove that every marker pixel is
        // unoccluded. Negative results therefore remain indeterminate here.
        let calibration: CalibrationResult
        if settings.calibrationEnabled {
            calibration = CalibrationAnalyzer().analyze(.init(image:frame.image,geometry:geometry,
                overlayScreenRect:panelRect,patchScreenRect:patchRect,captureSource:frame.source,
                overlayVisibility:visible ? .visible : .notVisible,visibilityEvidence:.unknown,
                geometryStable:generation == presentationGeneration && visible == overlay.isVisible &&
                    panelRect == overlay.screenRect && patchRect == overlay.patchScreenRect && displaysBefore == displaysAfter))
        } else {
            calibration = CalibrationResult(outcome:.indeterminate,confidence:0,reason:.calibrationDisabled,
                pixelPatchBounds:nil,referenceColorSpace:"sRGB",observedPixelFormat:"not_analyzed")
        }
        try await audit.record(.init(.calibrationCompleted,payload:["capture_id":.string(captureID.uuidString),
            "status":.string(calibration.outcome.rawValue),"reason":.string(calibration.reason.rawValue),
            "confidence":.number(calibration.confidence),"source":.string(frame.source.rawValue),
            "window_id":.integer(overlay.overlayWindowID),"owner_pid":.integer(Int(ProcessInfo.processInfo.processIdentifier)),
            "display_id":.integer(Int(frame.displayID))]),mode:settings.visibilityMode.rawValue)
        try Task.checkCancellation()
        let display = displaysBefore[frame.displayID] ?? .zero
        let cgY = frame.displayFrame.minY + (display.maxY-cursor.y) * frame.displayFrame.height / max(1,display.height)
        let cursorY = (cgY-frame.capturedBounds.minY) / max(1,frame.capturedBounds.height)
        let locator = Task.detached(priority:.userInitiated) {
            let pane = PaneLocator.locate(in:frame.image)
            let style = CapturedAppearance.analyze(image:frame.image,pane:pane ?? CGRect(x:0,y:0,width:1,height:1),
                                                  cursorY:cursorY)
            let image = try ImageProcessor().process(frame.image,settings:settings)
            return (pane,style,image)
        }
        let (normalizedPane,style,image) = try await withTaskCancellationHandler(operation: { try await locator.value }, onCancel: { locator.cancel() })
        try Task.checkCancellation()
        let pane = displaysBefore[frame.displayID].flatMap { display in
            normalizedPane.map {
                PaneLocator.screenRect($0, capturedBounds:frame.capturedBounds,
                                       displayCG:frame.displayFrame, displayAppKit:display)
            }
        }
        try await audit.record(.init(.captureCompleted,payload:["bytes":.integer(image.bytes.count),"width":.integer(image.width),"height":.integer(image.height),"sha256":.string(image.sha256),"overlay_in_capture":calibration.overlayInCapture.map(JSONValue.bool) ?? .null,"calibration_status":.string(calibration.outcome.rawValue),"calibration_reason":.string(calibration.reason.rawValue),"confidence":.number(calibration.confidence),"capture_id":.string(captureID.uuidString),"window_id":.integer(overlay.overlayWindowID),"owner_pid":.integer(Int(ProcessInfo.processInfo.processIdentifier)),"source":.string(settings.captureSource.rawValue),"display_id":.integer(Int(frame.displayID)),"latency_ms":.number(Double(DispatchTime.now().uptimeNanoseconds-started)/1_000_000)]),mode:settings.visibilityMode.rawValue)
        return PreparedCapture(image:image,pane:pane,style:style,displayFrames:displaysAfter)
    }
    private func showOverlay(settings:Settings,text:String,
                             pane:CGRect? = nil,cursor:CGPoint? = nil,calibrationMarker:Bool = false,style:OverlayStyle = .fallback) async throws {
        let expectedGeneration = presentationGeneration
        try await audit.record(.init(.capabilityCheck,payload:["capability":.string("overlay_presentation"),"status":.string("prepared")]),mode:settings.visibilityMode.rawValue)
        try Task.checkCancellation()
        guard !blocked, expectedGeneration == presentationGeneration else { throw CancellationError() }
        let rect = overlay.show(settings:settings,text:text,
                                pane:pane,cursor:cursor,calibrationMarker:calibrationMarker,style:style)
        try await audit.record(.init(.overlayShown,payload:["x":.number(rect.minX),"y":.number(rect.minY),"w":.number(rect.width),"h":.number(rect.height),"window_id":.integer(overlay.overlayWindowID),"owner_pid":.integer(Int(ProcessInfo.processInfo.processIdentifier)),"overlay_visibility":.string("not_tested")]),mode:settings.visibilityMode.rawValue)
    }
    private func showCalibrationFromSettings() async {
        guard ready,operation == nil else { return }
        do { try await showOverlay(settings:store.settings,text:"",calibrationMarker:true) }
        catch is CancellationError {} catch { failClosed(error) }
    }
    private func dismiss(reason:String) {
        presentationGeneration &+= 1; operation?.cancel(); overlay.dismiss()
        Task { await privacy.dismiss()
            do { try await audit.record(.init(.overlayDismissed,payload:["reason":.string(reason)]),mode:store.settings.visibilityMode.rawValue) } catch { failClosed(error) }
        }
    }
    private func failClosed(_ error:Error) {
        blocked = true; ready = false; presentationGeneration &+= 1; operation?.cancel(); hotkeys.shutdown(); overlay.dismiss()
        Task { await privacy.clear() }
        updateStatus("Sensitive actions stopped: \(Self.safeMessage(error)) Restart after resolving the error.")
    }
    private func updateStatus(_ text:String) { settingsUI.setStatus(text); statusItem?.button?.title = "HARNESS · \(store.settings.visibilityMode.rawValue)\(blocked ? " · STOPPED":"")" }
    private static func cursorDisplayID()->UInt32 {
        let cursor = NSEvent.mouseLocation
        return (NSScreen.screens.first(where:{$0.frame.contains(cursor)})?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    private static func displayFrames()->[UInt32:CGRect] {
        var result: [UInt32:CGRect] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                result[number.uint32Value] = screen.frame
            }
        }
        return result
    }
    private static func safeMessage(_ error:Error)->String {
        if let value = error as? CaptureError { return "Capture: \(value). Check permission, source and target availability." }
        if error is AuditError { return "Mandatory audit could not be recorded." }
        if error is ModeConfigurationError { return "Mode configuration could not be verified; the measurement was aborted." }
        if error is SettingsValidationError || error is SettingsInputError { return "Invalid settings." }
        if error is HotkeyError { return "Hotkey registration failed; adjust function-key settings or choose other shortcuts." }
        if let value = error as? ChatGPTProviderError { return value.localizedDescription }
        if let value = error as? ChatGPTAuthenticationError { return value.localizedDescription }
        if let value = error as? SettingsPersistenceError { return value.localizedDescription }
        if let value = error as? PrivacyError { return "Privacy validation: \(value)." }
        return "Operation failed (\(String(reflecting:type(of:error))))."
    }
    @objc private func showSettings() { settingsUI.load(store.settings, preservingDraft:true); settingsUI.setScreenRecordingPermission(granted:screenPermissionGranted()); settingsUI.showWindow(nil); NSApp.activate(ignoringOtherApps:true); settingsUI.window?.makeKeyAndOrderFront(nil) }
    public func applicationDidBecomeActive(_ notification: Notification) { settingsUI.setScreenRecordingPermission(granted:screenPermissionGranted()) }
    @objc private func quit() { NSApp.terminate(nil) }
    public func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool { showSettings(); return true }
    public func applicationWillTerminate(_ notification:Notification) { authentication?.cancel(); saveTask?.cancel(); modelTask?.cancel(); windowsTask?.cancel(); permissionTask?.cancel(); calibrationTask?.cancel(); account.cancelSignIn(); operation?.cancel(); hotkeys.shutdown(); overlay.dismiss(); Task { await privacy.terminate() } }
}
