import AppKit
import HarnessCore
public enum SettingsInputError: Error { case invalid }
public enum SettingsInputParser {
    public static func integer(_ text: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(value) else { throw SettingsInputError.invalid }
        return value
    }
    public static func masks(_ text: String) throws -> [MaskRegion] {
        guard text.utf8.count <= 8192 else { throw SettingsInputError.invalid }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count <= 32 else { throw SettingsInputError.invalid }
        return try lines.map { line in
            let values = line.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == 4, let x = values[0], let y = values[1], let w = values[2], let h = values[3] else { throw SettingsInputError.invalid }
            let mask = MaskRegion(x:x,y:y,width:w,height:h); guard mask.isValid else { throw SettingsInputError.invalid }; return mask
        }
    }
}
public enum SettingsAction: Hashable { case save, resetPrompt, refreshWindows, permission, calibration, signIn, cancelSignIn, signOut, refreshModels, addAccount, selectAccount }
@MainActor private final class SettingsForm: NSStackView {
    override var isFlipped: Bool { true }
}
@MainActor public final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    public var onSave: ((Settings,Bool)->Void)?
    public var onRefreshWindows: (()->Void)?
    public var onPermission: (()->Void)?
    public var onShowCalibration: (()->Void)?
    public var onChatGPTSignIn: (()->Void)?
    public var onCancelSignIn: (()->Void)?
    public var onAddAccount: (()->Void)?
    public var onSelectAccount: ((String)->Void)?
    public var onChatGPTSignOut: (()->Void)?
    public var onRefreshModels: (()->Void)?

    private var current = Settings()
    private var windowChoices: [ShareableWindowChoice] = []
    private var modelChoices: [String] = []
    private var busyActions: Set<SettingsAction> = []
    private var actionButtons: [SettingsAction: NSButton] = [:]
    private var modesAllowed = false
    private var accountConnected = false
    private var screenRecordingGranted = false
    private let source = NSPopUpButton(), mode = NSPopUpButton(), position = NSPopUpButton(), target = NSPopUpButton()
    private let captureKey = NSPopUpButton(), dismissKey = NSPopUpButton(), scrollKey = NSPopUpButton(), scrollDownKey = NSPopUpButton()
    private let queueKey = NSPopUpButton()
    private let queued = NSTextField(labelWithString:"Queued screenshots: 0 / 6")
    private let adaptiveTypography = NSButton(checkboxWithTitle:"Match captured text font, size and weight (experimental)",target:nil,action:nil)
    private let model = NSTextField(), history = NSTextField(), dimension = NSTextField(), bytes = NSTextField()
    private let masks = NSTextField()
    private let prompt = NSTextView()
    private let masking = NSButton(checkboxWithTitle:"Apply privacy masks",target:nil,action:nil)
    private let calibration = NSButton(checkboxWithTitle:"Analyze calibration marker",target:nil,action:nil)
    private let intro = NSTextField(wrappingLabelWithString: "")
    private let advanced = NSStackView()
    private let advancedToggle = NSButton(title:"Advanced…",target:nil,action:nil)
    private let account = NSTextField(wrappingLabelWithString:"ChatGPT account: not connected")
    private let models = NSPopUpButton()
    private let savedAccounts = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString:"Starting…")
    private let badge = NSTextField(labelWithString: VisibilityMode.spaceBehaviorProbe.badge)
    public init() {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:480),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "Harness"; window.minSize = NSSize(width:560,height:400); window.center()
        super.init(window:window)
        let scroll = NSScrollView(frame:window.contentView!.bounds); scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width,.height]
        let form = SettingsForm(); form.orientation = .vertical; form.alignment = .leading; form.spacing = 12; form.edgeInsets = NSEdgeInsets(top:24,left:24,bottom:24,right:24)
        form.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = form; window.contentView!.addSubview(scroll)
        // The clip view excludes any visible legacy scroller. Let the stack's
        // arranged contents determine document height while fixing its origin.
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor),
            form.topAnchor.constraint(equalTo:scroll.contentView.topAnchor),
            form.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor)
        ])
        let heading = NSTextField(labelWithString:"Harness"); heading.font = .systemFont(ofSize:26,weight:.semibold)
        queued.font = .systemFont(ofSize:12); queued.textColor = .secondaryLabelColor
        let headingRow = NSStackView(views:[heading,queued]); headingRow.alignment = .firstBaseline;headingRow.spacing = 16
        form.addArrangedSubview(headingRow)
        badge.font = .systemFont(ofSize:12,weight:.medium); badge.textColor = .secondaryLabelColor; form.addArrangedSubview(badge)
        form.addArrangedSubview(intro)
        form.addArrangedSubview(account)
        form.addArrangedSubview(NSStackView(views:[button("Continue with ChatGPT",#selector(signIn), .signIn),button("Cancel sign-in",#selector(cancelSignIn), .cancelSignIn),button("Disconnect account",#selector(signOut), .signOut)]))
        form.addArrangedSubview(status)
        status.font = .systemFont(ofSize:13); status.textColor = .secondaryLabelColor
        let permission = button("Request Screen Recording permission", #selector(requestPermission), .permission); form.addArrangedSubview(permission)
        let disclosure = NSTextField(wrappingLabelWithString:"Using Harness sends each keyboard-triggered screenshot and recent answer context to OpenAI through your ChatGPT plan. No capture runs at startup. Your sign-in stays in macOS Keychain.")
        disclosure.font = .systemFont(ofSize:12); disclosure.textColor = .secondaryLabelColor
        form.addArrangedSubview(disclosure)
        advancedToggle.target = self; advancedToggle.action = #selector(toggleAdvanced)
        form.addArrangedSubview(advancedToggle)
        advanced.orientation = .vertical; advanced.alignment = .leading; advanced.spacing = 10
        advanced.isHidden = true
        form.addArrangedSubview(advanced)
        advanced.widthAnchor.constraint(equalTo:form.widthAnchor,constant:-48).isActive = true
        addRow("Saved ChatGPT accounts",savedAccounts,to:advanced)
        advanced.addArrangedSubview(NSStackView(views:[button("Use saved account",#selector(useAccount),.selectAccount),button("Add account…",#selector(addAccount),.addAccount)]))
        mode.addItems(withTitles:VisibilityMode.allCases.map(\.badge)); mode.isEnabled = false
        source.addItems(withTitles:CaptureSource.allCases.map(\.rawValue)); position.addItems(withTitles:OverlayPosition.allCases.map(\.displayName))
        for field in [captureKey,scrollKey,scrollDownKey,queueKey] {
            for digit in 2...8 { field.addItem(withTitle:Shortcut(digit:digit).label);field.lastItem?.tag = digit }
        }
        dismissKey.addItem(withTitle:Shortcut(digit:9).label);dismissKey.lastItem?.tag = 9;dismissKey.isEnabled = false
        addRow("Experimental mode", mode, to:advanced); addRow("Capture source",source,to:advanced)
        let targets = NSStackView(views:[target,button("Refresh windows",#selector(refreshWindows), .refreshWindows)]); targets.orientation = .horizontal
        addRow("Selected window",targets,to:advanced)
        addRow("Capture / dismiss / up / down",NSStackView(views:[captureKey,dismissKey,scrollKey,scrollDownKey]),to:advanced)
        addRow("Queue screenshot",queueKey,to:advanced)
        addRow("Hide / show saved answer",NSTextField(labelWithString:Settings.visibilityHotkey.label),to:advanced)
        addRow("Switch overlay position",NSTextField(labelWithString:Settings.overlayModeHotkey.label),to:advanced)
        advanced.addArrangedSubview(adaptiveTypography)
        let typeHelp = NSTextField(wrappingLabelWithString:"Automatic placement can match body text locally. Bottom left uses compact 9-point text. Answers show up to three complete lines. Hide/show restores the same answer without a request. Clear the saved answer before requesting another.")
        typeHelp.font = .systemFont(ofSize:12); typeHelp.textColor = .secondaryLabelColor
        advanced.addArrangedSubview(typeHelp); typeHelp.widthAnchor.constraint(equalTo:advanced.widthAnchor).isActive = true
        addRow("Overlay position",position,to:advanced); addRow("ChatGPT model ID",model,to:advanced)
        addRow("Available account models",models,to:advanced)
        models.target = self; models.action = #selector(selectModel)
        model.delegate = self
        let promptScroll = NSScrollView(); promptScroll.hasVerticalScroller = true; promptScroll.borderType = .bezelBorder
        promptScroll.documentView = prompt; promptScroll.heightAnchor.constraint(equalToConstant:160).isActive = true
        prompt.isRichText = false; prompt.isAutomaticQuoteSubstitutionEnabled = false; prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.isVerticallyResizable = true; prompt.isHorizontallyResizable = false; prompt.autoresizingMask = [.width]
        prompt.textContainer?.widthTracksTextView = true; prompt.textContainer?.heightTracksTextView = false
        prompt.textContainerInset = NSSize(width:6,height:6); prompt.font = .systemFont(ofSize:13)
        prompt.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        addRow("System prompt",promptScroll,to:advanced)
        let promptHelp = NSTextField(wrappingLabelWithString:"Optional instructions sent with each image. Up to 16,000 characters / 64 KB. Save Settings to apply; do not put credentials here.")
        promptHelp.font = .systemFont(ofSize:12); promptHelp.textColor = .secondaryLabelColor
        advanced.addArrangedSubview(promptHelp); promptHelp.widthAnchor.constraint(equalTo:advanced.widthAnchor).isActive = true
        advanced.addArrangedSubview(button("Restore default prompt",#selector(resetPrompt),.resetPrompt))
        addRow("History (0–10)",history,to:advanced)
        addRow("Longest edge (64–1568)",dimension,to:advanced); addRow("JPEG limit (bytes)",bytes,to:advanced)
        advanced.addArrangedSubview(calibration); advanced.addArrangedSubview(masking)
        masks.placeholderString = "x,y,width,height; normalized top-left; one region per line"; masks.maximumNumberOfLines = 8; masks.lineBreakMode = .byWordWrapping
        addRow("Mask regions",masks,to:advanced)
        advanced.addArrangedSubview(NSStackView(views:[button("Refresh models",#selector(refreshModels), .refreshModels),button("Show calibration marker",#selector(showCalibration), .calibration)]))
        advanced.addArrangedSubview(button("Save Settings",#selector(save), .save))
        for view in form.arrangedSubviews {
            // Auto Layout uses alignment rectangles; include their insets when
            // bounding the actual control frame to the document's 24 pt margins.
            let insets = view.alignmentRectInsets
            let margin = 48 + insets.left + insets.right
            if let field = view as? NSTextField, field.cell?.wraps == true {
                field.widthAnchor.constraint(equalTo:form.widthAnchor,constant:-margin).isActive = true
            } else {
                view.widthAnchor.constraint(lessThanOrEqualTo:form.widthAnchor,constant:-margin).isActive = true
            }
        }
        load(Settings())
    }
    required init?(coder:NSCoder) { fatalError("No archived UI") }
    private func button(_ title:String,_ selector:Selector,_ action:SettingsAction)->NSButton {
        let button = NSButton(title:title,target:self,action:selector)
        actionButtons[action] = button
        return button
    }
    private func addRow(_ title:String,_ field:NSView,to form:NSStackView) {
        let label = NSTextField(labelWithString:title); label.widthAnchor.constraint(equalToConstant:180).isActive = true
        let row = NSStackView(views:[label,field]); row.orientation = .horizontal; row.spacing = 10
        form.addArrangedSubview(row); row.widthAnchor.constraint(equalTo:form.widthAnchor,constant:form === advanced ? 0 : -48).isActive = true
        field.setContentHuggingPriority(.defaultLow,for:.horizontal)
    }
    public func allowModes() { modesAllowed = true; updateEnabledState() }
    public func load(_ settings:Settings, preservingDraft: Bool = false) {
        intro.stringValue = "\(settings.queueCaptureHotkey.label) queues a screenshot (6 max, memory only, 5-minute expiry). \(settings.captureHotkey.label) sends the queue, or captures once if empty. \(settings.dismissHotkey.label) clears the answer and queue; \(settings.scrollUpHotkey.label) / \(settings.scrollDownHotkey.label) scroll. \(Settings.visibilityHotkey.label) hides/restores the answer; \(Settings.overlayModeHotkey.label) switches overlay position. Clear the saved answer before a new request. Answers show up to 3 lines."
        if preservingDraft {
            current = settings; badge.stringValue = settings.visibilityMode.badge
            return
        }
        current = settings; badge.stringValue = settings.visibilityMode.badge
        mode.selectItem(at:settings.visibilityMode.rawValue)
        source.selectItem(withTitle:settings.captureSource.rawValue); position.selectItem(withTitle:settings.overlayPosition.displayName)
        captureKey.selectItem(withTag:settings.captureHotkey.digit);dismissKey.selectItem(withTag:9);scrollKey.selectItem(withTag:settings.scrollUpHotkey.digit);scrollDownKey.selectItem(withTag:settings.scrollDownHotkey.digit)
        queueKey.selectItem(withTag:settings.queueCaptureHotkey.digit)
        adaptiveTypography.state = settings.adaptiveTypographyEnabled ? .on : .off
        model.stringValue = settings.model; history.stringValue = String(settings.historyLength)
        prompt.string = settings.effectiveSystemPrompt
        dimension.stringValue = String(settings.maxImageDimension); bytes.stringValue = String(settings.maxImageBytes)
        masking.state = settings.privacyMaskingEnabled ? .on : .off; calibration.state = settings.calibrationEnabled ? .on : .off
        masks.stringValue = settings.maskingRegions.map { "\($0.x),\($0.y),\($0.width),\($0.height)" }.joined(separator:"\n")
        rebuildWindows(selectedID: settings.selectedWindowID)
        updateModelSelection()
    }
    public func updateOverlayPosition(_ value:OverlayPosition) { current.overlayPosition = value;position.selectItem(withTitle:value.displayName) }
    public func setStatus(_ text:String) { status.stringValue = text }
    public func setQueuedCaptureCount(_ count:Int) { queued.stringValue = "Queued screenshots: \(count) / 6" }
    public func setScreenRecordingPermission(granted:Bool) {
        screenRecordingGranted = granted
        actionButtons[.permission]?.title = granted ? "Screen Recording granted" : "Request Screen Recording permission"
        updateEnabledState()
    }
    public func setWindows(_ choices:[ShareableWindowChoice]) {
        let selectedTag = target.selectedItem?.tag ?? 0
        let selectedID = selectedTag > 0 ? UInt32(selectedTag) : nil
        windowChoices = choices
        rebuildWindows(selectedID: selectedID)
    }
    private func rebuildWindows(selectedID: UInt32?) {
        target.removeAllItems(); target.addItem(withTitle:"Select a shareable window…"); target.lastItem?.tag = 0
        for choice in windowChoices {
            // Popup convenience insertion replaces an existing item with the
            // same title. Window identity must survive duplicated UI titles.
            let item = NSMenuItem(title:"\(choice.owner) · \(choice.title.isEmpty ? "Window \(choice.id)" : choice.title)", action:nil, keyEquivalent:"")
            item.tag = Int(choice.id); target.menu?.addItem(item)
        }
        if let id = selectedID {
            if !windowChoices.contains(where: { $0.id == id }) {
                target.addItem(withTitle: "Unavailable window · \(id) (refresh to retry)"); target.lastItem?.tag = Int(id)
            }
            target.selectItem(withTag: Int(id))
        } else { target.selectItem(withTag: 0) }
    }
    @objc private func save() {
        guard canPerform(.save) else { return }
        do {
            var value = current
            guard let chosenMode = VisibilityMode(rawValue:mode.indexOfSelectedItem), let chosenSource = CaptureSource(rawValue:source.titleOfSelectedItem ?? ""), let chosenPosition = OverlayPosition.allCases.first(where:{ $0.displayName == position.titleOfSelectedItem }) else { throw SettingsInputError.invalid }
            value.visibilityMode = chosenMode; value.captureSource = chosenSource; value.overlayPosition = chosenPosition
            let selectedTag = target.selectedItem?.tag ?? 0
            value.selectedWindowID = selectedTag > 0 ? UInt32(selectedTag) : nil
            value.captureHotkey = .init(digit:captureKey.selectedItem?.tag ?? -1);value.dismissHotkey = .init(digit:9);value.scrollUpHotkey = .init(digit:scrollKey.selectedItem?.tag ?? -1);value.scrollDownHotkey = .init(digit:scrollDownKey.selectedItem?.tag ?? -1)
            value.queueCaptureHotkey = .init(digit:queueKey.selectedItem?.tag ?? -1)
            value.adaptiveTypographyEnabled = adaptiveTypography.state == .on
            value.model = model.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            guard Settings.validSystemPrompt(prompt.string) else {
                setStatus("System prompt must be nonempty, within 16,000 characters / 64 KB, and contain no control characters."); return
            }
            value.systemPrompt = prompt.string == Settings.defaultSystemPrompt ? nil : prompt.string
            value.historyLength = try SettingsInputParser.integer(history.stringValue,range:0...10)
            value.maxImageDimension = try SettingsInputParser.integer(dimension.stringValue,range:64...1568); value.maxImageBytes = try SettingsInputParser.integer(bytes.stringValue,range:10_000...1_000_000)
            value.calibrationEnabled = calibration.state == .on; value.privacyMaskingEnabled = masking.state == .on; value.maskingRegions = try SettingsInputParser.masks(masks.stringValue)
            try value.validated(); onSave?(value,value.networkSubmissionEnabled)
        } catch { setStatus("Settings rejected: check shortcuts, numeric limits and mask regions.") }
    }
    @objc private func toggleAdvanced() {
        advanced.isHidden.toggle(); advancedToggle.title = advanced.isHidden ? "Advanced…" : "Hide advanced"
        window?.contentView?.layoutSubtreeIfNeeded()
    }
    @objc private func resetPrompt() { if canPerform(.resetPrompt) { prompt.string = Settings.defaultSystemPrompt } }
    @objc private func cancelSignIn() { if canPerform(.cancelSignIn) { onCancelSignIn?() } }
    @objc private func requestPermission() { if canPerform(.permission) { onPermission?() } }
    @objc private func refreshWindows() { if canPerform(.refreshWindows) { onRefreshWindows?() } }
    @objc private func showCalibration() { if canPerform(.calibration) { onShowCalibration?() } }
    @objc private func signIn() { if canPerform(.signIn) { onChatGPTSignIn?() } }
    @objc private func signOut() { if canPerform(.signOut) { onChatGPTSignOut?() } }
    @objc private func addAccount() { if canPerform(.addAccount) { onAddAccount?() } }
    @objc private func useAccount() {
        if canPerform(.selectAccount), let id = savedAccounts.selectedItem?.representedObject as? String { onSelectAccount?(id) }
    }
    public func setAccountChoices(_ choices:[ChatGPTAccountChoice],selectedID:String?) {
        savedAccounts.removeAllItems()
        for choice in choices {
            let item = NSMenuItem(title:choice.label, action:nil, keyEquivalent:"")
            item.representedObject = choice.id; savedAccounts.menu?.addItem(item)
        }
        if let index = choices.firstIndex(where:{ $0.id == selectedID }) { savedAccounts.selectItem(at:index) }
        updateEnabledState()
    }
    @objc private func refreshModels() { if canPerform(.refreshModels) { onRefreshModels?() } }
    @objc private func selectModel() { if models.isEnabled, let id = models.selectedItem?.representedObject as? String { model.stringValue = id } }
    public func setAccountStatus(_ text:String, connected:Bool = false) {
        account.stringValue = text; accountConnected = connected
        actionButtons[.signIn]?.title = accountConnected ? "ChatGPT connected" : "Continue with ChatGPT"
        updateEnabledState()
    }
    public func setModels(_ choices:[String]) {
        modelChoices = choices
        models.removeAllItems()
        models.addItem(withTitle: choices.isEmpty ? "Refresh models after connecting ChatGPT" : "Use the model ID entered above")
        for id in choices { models.addItem(withTitle:id); models.lastItem?.representedObject = id }
        updateModelSelection()
    }
    private func updateModelSelection() {
        if models.numberOfItems == 0 { models.addItem(withTitle: "Refresh models after connecting ChatGPT") }
        let id = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if modelChoices.contains(id) { models.selectItem(withTitle: id) } else { models.selectItem(at: 0) }
        updateEnabledState()
    }
    public func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === model { updateModelSelection() }
    }
    public func revokeConsent() { current.networkSubmissionEnabled = false; setModels([]) }
    public func setBusy(_ busy: Bool, for action: SettingsAction) {
        if busy { busyActions.insert(action) } else { busyActions.remove(action) }
        updateEnabledState()
    }
    private func canPerform(_ action: SettingsAction) -> Bool {
        !busyActions.contains(action) && actionButtons[action]?.isEnabled != false
    }
    private func updateEnabledState() {
        let draftLocked = busyActions.contains(.save)
        let accountBusy = !busyActions.isDisjoint(with: [.signIn, .signOut, .selectAccount, .addAccount])
        let controls: [NSControl] = [source, position, target, captureKey, dismissKey, scrollKey, scrollDownKey, queueKey,adaptiveTypography,model, history, dimension, bytes, masks, masking, calibration]
        controls.forEach { $0.isEnabled = !draftLocked }
        prompt.isEditable = !draftLocked
        mode.isEnabled = modesAllowed && !draftLocked
        models.isEnabled = !modelChoices.isEmpty && !draftLocked && !accountBusy
        for (action, button) in actionButtons { button.isEnabled = !busyActions.contains(action) }
        actionButtons[.cancelSignIn]?.isEnabled = busyActions.contains(.signIn)
        actionButtons[.cancelSignIn]?.isHidden = !busyActions.contains(.signIn)
        let accountLocked = draftLocked || accountBusy
        savedAccounts.isEnabled = savedAccounts.numberOfItems > 0 && !accountLocked
        actionButtons[.selectAccount]?.isEnabled = savedAccounts.isEnabled
        actionButtons[.addAccount]?.isEnabled = !accountLocked
        actionButtons[.signOut]?.isHidden = !accountConnected && !accountBusy
        actionButtons[.permission]?.isEnabled = !screenRecordingGranted && !busyActions.contains(.permission)
        actionButtons[.save]?.isEnabled = !draftLocked && !busyActions.contains(.signOut)
        actionButtons[.resetPrompt]?.isEnabled = !draftLocked
        actionButtons[.signIn]?.isEnabled = !accountConnected && !draftLocked && !accountBusy
        actionButtons[.refreshModels]?.isEnabled = !busyActions.contains(.refreshModels) && !accountBusy
        actionButtons[.refreshWindows]?.isEnabled = !draftLocked && !busyActions.contains(.refreshWindows)
        actionButtons[.calibration]?.isEnabled = !draftLocked && !busyActions.contains(.calibration)
        dismissKey.isEnabled = false
        // Disconnect stays available during sign-in and an awaited save so the
        // application can cancel those operations and revoke consent.
    }

}
