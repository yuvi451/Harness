import AppKit
import XCTest
@testable import HarnessCore
@testable import HarnessEmitter

@MainActor final class SettingsLayoutTests: XCTestCase {
    func testOnlyTwoOverlayChoicesRemain() throws {
        let controller = try makeSettingsController();defer { controller.close() }
        let position = try XCTUnwrap(field(named:"Overlay position",in:controller) as? NSPopUpButton)
        XCTAssertEqual(position.itemTitles,["Automatic pane / cursor","Bottom left (small)"])
    }
    func testAdaptiveTypographyToggleAndQueueShortcutSaveAndLockDuringCommit() throws {
        let controller = try makeSettingsController();defer { controller.close() }
        let toggle = try button(named:"Match captured text font, size and weight (experimental)",in:controller)
        let queue = try XCTUnwrap(field(named:"Queue screenshot",in:controller) as? NSPopUpButton)
        XCTAssertEqual(toggle.state,.off);XCTAssertEqual(queue.titleOfSelectedItem,"⌥⇧5")
        toggle.state = .on;queue.selectItem(withTitle:"⌥⇧2")
        var saved:Settings?
        controller.onSave = { value,_ in saved = value }
        try button(named:"Save Settings",in:controller).performClick(nil)
        XCTAssertEqual(saved?.adaptiveTypographyEnabled,true);XCTAssertEqual(saved?.queueCaptureHotkey.digit,2)
        controller.setBusy(true,for:.save)
        XCTAssertFalse(toggle.isEnabled);XCTAssertFalse(queue.isEnabled)
        controller.setBusy(false,for:.save)
        XCTAssertTrue(toggle.isEnabled);XCTAssertTrue(queue.isEnabled)
    }
    func testPromptEditorSupportsMultilineSaveResetDraftAndBusyState() throws {
        let controller = try makeSettingsController(); defer { controller.close() }
        let scroll = try XCTUnwrap(field(named:"System prompt",in:controller) as? NSScrollView)
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        controller.showWindow(nil)
        try button(named:"Advanced…",in:controller).performClick(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(editor.frame.width,100)
        XCTAssertLessThanOrEqual(editor.textContainer?.containerSize.width ?? .infinity,scroll.contentSize.width+1)
        if let path = ProcessInfo.processInfo.environment["HARNESS_PROMPT_PREVIEW_PATH"], let root = controller.window?.contentView {
            _ = scroll.scrollToVisible(scroll.bounds); root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in:root.bounds))
            root.cacheDisplay(in:root.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path))
        }
        let original = editor.string
        XCTAssertFalse(original.isEmpty)
        editor.string = "Custom instructions\né🙂"
        controller.load(Settings(),preservingDraft:true)
        XCTAssertEqual(editor.string,"Custom instructions\né🙂")
        var saved:Settings?
        controller.onSave = { value,_ in saved = value }
        try button(named:"Save Settings",in:controller).performClick(nil)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(try XCTUnwrap(saved))) as? [String:Any])
        XCTAssertEqual(encoded["systemPrompt"] as? String,editor.string)
        controller.setBusy(true,for:.save)
        XCTAssertFalse(editor.isEditable)
        XCTAssertFalse(try button(named:"Restore default prompt",in:controller).isEnabled)
        controller.setBusy(false,for:.save)
        try button(named:"Restore default prompt",in:controller).performClick(nil)
        XCTAssertEqual(editor.string,original)
        saved = nil; editor.string = "  \n"
        try button(named:"Save Settings",in:controller).performClick(nil)
        XCTAssertNil(saved)
    }
    func testSavedAccountsUseStableIdentityAndLockDuringAuthentication() throws {
        let controller = try makeSettingsController(); defer { controller.close() }
        controller.setAccountChoices([.init(id:"first",label:"Same email · first"),.init(id:"second",label:"Same email · second")],selectedID:"second")
        let choices = try XCTUnwrap(field(named:"Saved ChatGPT accounts",in:controller) as? NSPopUpButton)
        var selected:String?
        controller.onSelectAccount = { selected = $0 }
        try button(named:"Use saved account",in:controller).performClick(nil)
        XCTAssertEqual(selected,"second")
        controller.setBusy(true,for:.signIn)
        XCTAssertFalse(choices.isEnabled)
        XCTAssertFalse(try button(named:"Add account…",in:controller).isEnabled)
        controller.setBusy(false,for:.signIn)
        XCTAssertTrue(choices.isEnabled)
    }
    func testStartupHasNoSeparateTransmissionConsentCheckboxAndAdvancedStartsCollapsed() throws {
        let controller = try makeSettingsController(); defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        XCTAssertFalse(descendants(of: root).compactMap { $0 as? NSButton }.contains { $0.title.hasPrefix("Send my ") })
        let advanced = try button(named: "Advanced…", in: controller)
        XCTAssertTrue(advanced.isEnabled)
        let mode = try field(named: "Experimental mode", in: controller)
        XCTAssertTrue(mode.superview?.superview?.isHidden == true)
        controller.showWindow(nil); root.layoutSubtreeIfNeeded()
        let heading = try XCTUnwrap(descendants(of:root).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Harness" })
        XCTAssertLessThanOrEqual(root.bounds.maxY - heading.convert(heading.bounds,to:root).maxY,32,
                                 "Short forms should start at the top rather than leaving a blank upper half")
        if let path = ProcessInfo.processInfo.environment["HARNESS_SETTINGS_PREVIEW_PATH"] {
            controller.setScreenRecordingPermission(granted:true)
            controller.setAccountStatus("Signed out",connected:false)
            controller.setStatus("Continue with ChatGPT to get started.")
            controller.showWindow(nil); root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in:root.bounds))
            root.cacheDisplay(in:root.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path))
        }
    }
    func testShortcutInstructionsFollowSavedCustomKeys() throws {
        let controller = try makeSettingsController()
        defer { controller.close() }
        var settings = Settings()
        settings.captureHotkey.digit = 5
        settings.dismissHotkey.digit = 9
        settings.scrollUpHotkey.digit = 7
        settings.scrollDownHotkey.digit = 6
        settings.queueCaptureHotkey.digit = 3
        controller.load(settings)
        let content = try XCTUnwrap(controller.window?.contentView)
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        XCTAssertTrue(labels(content).contains { $0.contains("⌥⇧3 queues a screenshot") && $0.contains("⌥⇧5 sends the queue") && $0.contains("⌥⇧9 clears") && $0.contains("⌥⇧7 / ⌥⇧6 scroll") })
    }

    func testGrantedScreenPermissionCannotBeRequestedAgainAndRevocationRestoresAction() throws {
        let controller = try makeSettingsController()
        defer { controller.close() }
        var requests = 0
        controller.onPermission = { requests += 1 }
        controller.setScreenRecordingPermission(granted: true)
        let permission = try button(named: "Screen Recording granted", in: controller)
        XCTAssertFalse(permission.isEnabled)
        controller.setBusy(true, for: .save)
        controller.setBusy(false, for: .save)
        permission.performClick(nil)
        XCTAssertEqual(requests, 0, "Unrelated state updates must not restore the redundant permission request")
        controller.setScreenRecordingPermission(granted: false)
        XCTAssertEqual(permission.title, "Request Screen Recording permission")
        XCTAssertTrue(permission.isEnabled)
        permission.performClick(nil)
        XCTAssertEqual(requests, 1)
        controller.setBusy(true, for: .permission)
        controller.setScreenRecordingPermission(granted: false)
        XCTAssertFalse(permission.isEnabled)
    }

    func testNativeRefreshingWindowsPreservesDraftSelection() throws {
        let controller = try makeSettingsController()
        defer { controller.close() }
        var settings = Settings(); settings.selectedWindowID = 11
        controller.load(settings)
        let choices = [ShareableWindowChoice(id: 11, title: "One", owner: "Test"), ShareableWindowChoice(id: 22, title: "Two", owner: "Test")]
        controller.setWindows(choices)
        let popup = try field(named: "Selected window", in: controller) as? NSStackView
        let target = try XCTUnwrap(popup?.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first)
        target.selectItem(withTag: 22)
        controller.setWindows(Array(choices.reversed()))
        XCTAssertEqual(target.selectedItem?.tag, 22, "Refreshing the list must preserve an unsaved choice")
        var saved: Settings?
        controller.onSave = { value, _ in saved = value }
        try button(named: "Save Settings", in: controller).performClick(nil)
        XCTAssertEqual(saved?.selectedWindowID, 22)
    }

    func testWindowsWithIdenticalTitlesRemainIndividuallySelectable() throws {
        let controller = try makeSettingsController(); defer { controller.close() }
        controller.setWindows([.init(id: 11, title: "Untitled", owner: "Editor"),
                               .init(id: 22, title: "Untitled", owner: "Editor")])
        let row = try XCTUnwrap(field(named: "Selected window", in: controller) as? NSStackView)
        let choices = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual(choices.itemArray.map(\.tag), [0, 11, 22])
        var saved: Settings?
        controller.onSave = { value, _ in saved = value }
        for id in [11, 22] {
            choices.selectItem(withTag: id)
            try button(named: "Save Settings", in: controller).performClick(nil)
            XCTAssertEqual(saved?.selectedWindowID, UInt32(id))
        }
    }

    func testSavedAccountsWithIdenticalLabelsKeepStableSelection() throws {
        let controller = try makeSettingsController(); defer { controller.close() }
        controller.setAccountChoices([.init(id: "first", label: "same@example.test"),
                                      .init(id: "second", label: "same@example.test")], selectedID: "second")
        let choices = try XCTUnwrap(field(named: "Saved ChatGPT accounts", in: controller) as? NSPopUpButton)
        XCTAssertEqual(choices.itemArray.compactMap { $0.representedObject as? String }, ["first", "second"])
        var selected: String?
        controller.onSelectAccount = { selected = $0 }
        try button(named: "Use saved account", in: controller).performClick(nil)
        XCTAssertEqual(selected, "second")
    }

    func testPendingAccountSelectionLocksIdentityControlsButAllowsDisconnect() throws {
        let controller = try makeSettingsController(); defer { controller.close() }
        controller.setAccountChoices([.init(id: "first", label: "First")], selectedID: "first")
        controller.setModels(["gpt-6.1-sol"])
        controller.setBusy(true, for: .selectAccount)
        let choices = try XCTUnwrap(field(named: "Saved ChatGPT accounts", in: controller) as? NSPopUpButton)
        let models = try XCTUnwrap(field(named: "Available account models", in: controller) as? NSPopUpButton)
        XCTAssertFalse(choices.isEnabled)
        XCTAssertFalse(models.isEnabled)
        XCTAssertFalse(try button(named: "Use saved account", in: controller).isEnabled)
        XCTAssertFalse(try button(named: "Add account…", in: controller).isEnabled)
        XCTAssertFalse(try button(named: "Continue with ChatGPT", in: controller).isEnabled)
        XCTAssertFalse(try button(named: "Disconnect account", in: controller).isHidden)
        XCTAssertTrue(try button(named: "Disconnect account", in: controller).isEnabled)
        controller.setBusy(false, for: .selectAccount)
        XCTAssertTrue(choices.isEnabled)
    }

    func testNativeLoadingNoTargetClearsOldSelectionAndUnavailableTargetSurvivesOtherEdits() throws {
        let controller = try makeSettingsController()
        defer { controller.close() }
        controller.setWindows([ShareableWindowChoice(id: 11, title: "One", owner: "Test")])
        var settings = Settings(); settings.selectedWindowID = 11
        controller.load(settings)
        controller.load(Settings())
        var saved: Settings?
        controller.onSave = { value, _ in saved = value }
        try button(named: "Save Settings", in: controller).performClick(nil)
        XCTAssertNil(try XCTUnwrap(saved).selectedWindowID, "Loading nil must clear the previous target")
        settings.selectedWindowID = 99
        controller.load(settings)
        controller.setWindows([])
        saved = nil
        try button(named: "Save Settings", in: controller).performClick(nil)
        XCTAssertEqual(saved?.selectedWindowID, 99, "Unavailable persisted windows must not silently reset on an unrelated save")
    }

    func testNativeModelRefreshReflectsEditedModelAndUnknownModelsAreNotMisrepresented() throws {
        let controller = try makeSettingsController()
        defer { controller.close() }
        let model = try XCTUnwrap(field(named: "ChatGPT model ID", in: controller) as? NSTextField)
        let choices = try XCTUnwrap(field(named: "Available account models", in: controller) as? NSPopUpButton)
        model.stringValue = "edited-model"
        controller.setModels(["gpt-6.1-sol", "edited-model"])
        XCTAssertEqual(choices.titleOfSelectedItem, "edited-model")
        model.stringValue = "manual-model"
        controller.setModels(["gpt-6.1-sol"])
        XCTAssertNil(choices.selectedItem?.representedObject, "The first available model must not impersonate a manually entered model")
        controller.setModels([])
        XCTAssertFalse(choices.isEnabled, "An empty list needs a disabled explanation, not a blank active control")
    }

    func testNativeBusyActionsSuppressRepeatedCallbacksAndLockSaveDraft() throws {
        let controller = try makeSettingsController()
        defer { controller.close() }
        controller.allowModes()
        var saves = 0
        controller.onSave = { _, _ in saves += 1; controller.setBusy(true, for: .save) }
        let save = try button(named: "Save Settings", in: controller)
        save.performClick(nil); save.performClick(nil)
        XCTAssertEqual(saves, 1, "A second click must not enqueue an overlapping save")
        let model = try XCTUnwrap(field(named: "ChatGPT model ID", in: controller) as? NSTextField)
        XCTAssertFalse(model.isEnabled, "Editing must pause while its captured draft is being committed")
        controller.setBusy(false, for: .save)
        XCTAssertTrue(model.isEnabled)
        save.performClick(nil)
        XCTAssertEqual(saves, 2)
        controller.setBusy(false, for: .save)
        controller.setBusy(true, for: .signIn)
        XCTAssertFalse(try button(named: "Continue with ChatGPT", in: controller).isEnabled)
        XCTAssertTrue(try button(named: "Disconnect account", in: controller).isEnabled, "Disconnect remains available to cancel authentication")
        controller.setBusy(false, for: .signIn)
        var refreshes = 0
        controller.onRefreshModels = { refreshes += 1; controller.setBusy(true, for: .refreshModels) }
        let refresh = try button(named: "Refresh models", in: controller)
        refresh.performClick(nil); refresh.performClick(nil)
        XCTAssertEqual(refreshes, 1)
        controller.setBusy(false, for: .refreshModels)
    }

    func testNativeReopeningSettingsPreservesDraftAndRevokingConsentClearsOnlyConsentAndAccountControls() throws {
        let controller = try makeSettingsController()
        defer { controller.close() }
        controller.load(Settings())
        let model = try XCTUnwrap(field(named: "ChatGPT model ID", in: controller) as? NSTextField)
        model.stringValue = "draft-model"
        controller.load(Settings(), preservingDraft: true)
        XCTAssertEqual(model.stringValue, "draft-model")
        controller.setModels(["draft-model"])
        controller.revokeConsent()
        XCTAssertEqual(model.stringValue, "draft-model", "Disconnect must preserve unrelated unsaved edits")
        let choices = try XCTUnwrap(field(named: "Available account models", in: controller) as? NSPopUpButton)
        XCTAssertFalse(choices.isEnabled)
        XCTAssertFalse(choices.itemTitles.contains("draft-model"), "Disconnect must discard cached account models")
    }

    private func makeSettingsController() throws -> SettingsWindowController {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_OVERLAY_GUI_TESTS"] == "1" else {
            throw XCTSkip("Native Settings checks require authorized GUI integration opt-in")
        }
        _ = NSApplication.shared
        return SettingsWindowController()
    }
    private func descendants(of view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(of: $0) } }
    private func field(named name: String, in controller: SettingsWindowController) throws -> NSView {
        let root = try XCTUnwrap(controller.window?.contentView)
        let row = try XCTUnwrap(descendants(of: root).compactMap { $0 as? NSStackView }.first {
            ($0.arrangedSubviews.first as? NSTextField)?.stringValue == name
        })
        return try XCTUnwrap(row.arrangedSubviews.dropFirst().first)
    }
    private func button(named name: String, in controller: SettingsWindowController) throws -> NSButton {
        let root = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendants(of: root).compactMap { $0 as? NSButton }.first { $0.title == name })
    }

    func testSimpleStartupAndExpandedAdvancedFitBothScrollerStylesAndSmallWindows() throws {
        let controller = try makeSettingsController(); defer { controller.close() }
        let window = try XCTUnwrap(controller.window), content = try XCTUnwrap(window.contentView)
        let scroll = try XCTUnwrap(content.subviews.compactMap { $0 as? NSScrollView }.first)
        let form = try XCTUnwrap(scroll.documentView as? NSStackView)
        controller.setStatus("Ready. Press ⌥⇧8 to analyze your screen.")
        controller.setAccountStatus("Connected to ChatGPT", connected:true)
        controller.showWindow(nil); content.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(form.arrangedSubviews.count,10)
        let first = try XCTUnwrap(form.arrangedSubviews.first)
        XCTAssertTrue(scroll.documentVisibleRect.insetBy(dx:-1,dy:-1).contains(first.convert(first.bounds,to:form)))
        try button(named:"Advanced…",in:controller).performClick(nil)
        for style in [NSScroller.Style.overlay,.legacy] {
            scroll.scrollerStyle = style
            for width in [CGFloat(640),CGFloat(560)] {
                window.setContentSize(NSSize(width:width,height:400))
                content.layoutSubtreeIfNeeded(); scroll.layoutSubtreeIfNeeded(); form.layoutSubtreeIfNeeded()
                let available = scroll.contentView.bounds.width
                XCTAssertFalse(form.hasAmbiguousLayout)
                XCTAssertGreaterThan(form.frame.height,scroll.contentView.bounds.height)
                XCTAssertLessThanOrEqual(form.frame.width,available+1)
                for row in descendants(of:form).compactMap({ $0 as? NSStackView }) {
                    let rect = row.convert(row.bounds,to:form)
                    XCTAssertGreaterThan(rect.height,0)
                    XCTAssertGreaterThanOrEqual(rect.minX,-1)
                    XCTAssertLessThanOrEqual(rect.maxX,available+1)
                }
                let save = try button(named:"Save Settings",in:controller)
                _ = save.scrollToVisible(save.bounds); scroll.layoutSubtreeIfNeeded()
                XCTAssertTrue(scroll.documentVisibleRect.insetBy(dx:-1,dy:-1).contains(save.convert(save.bounds,to:form)))
            }
        }
    }
}
