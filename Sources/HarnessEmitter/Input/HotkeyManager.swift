import AppKit
import Carbon
import HarnessCore
public enum HotkeyAction: UInt32, Sendable { case capture = 1, dismiss = 2, scrollUp = 3, scrollDown = 4, queueCapture = 5, toggleVisibility = 6, toggleOverlayMode = 7 }
public enum HotkeyError: Error { case registration(OSStatus), handler(OSStatus), unsupported }
@MainActor public protocol HotkeyRegistering {
    func install(handler: @escaping (UInt32, Bool)->Void) throws
    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) throws
    func unregisterAll()
}
@MainActor public final class HotkeyManager {
    private let registry: any HotkeyRegistering
    private var actionHandler: ((HotkeyAction)->Void)?
    private var held: Set<UInt32> = []
    private var active = false
    private var registrationID = UUID()
    public static let modifiers = UInt32(optionKey | shiftKey)
    public init(registry: any HotkeyRegistering) { self.registry = registry }
    public convenience init() { self.init(registry: CarbonHotkeyRegistry()) }
    public func configure(settings: Settings, handler: @escaping (HotkeyAction)->Void) throws {
        try settings.validated()
        shutdown()
        let registrationID = self.registrationID
        do {
            try registry.install { [weak self] id, pressed in
                guard let self, self.registrationID == registrationID else { return }
                self.receive(id: id, pressed: pressed)
            }
            let keys = [settings.captureHotkey, settings.dismissHotkey, settings.scrollUpHotkey, settings.scrollDownHotkey, settings.queueCaptureHotkey, Settings.visibilityHotkey, Settings.overlayModeHotkey]
            for (index, shortcut) in keys.enumerated() {
                guard let keyCode = Self.keyCode(shortcut) else { throw HotkeyError.unsupported }
                try registry.register(keyCode: keyCode, modifiers: Self.modifiers, id: UInt32(index + 1))
            }
            actionHandler = handler; active = true
        } catch { shutdown(); throw error }
    }
    public func shutdown() { active = false; registrationID = UUID(); actionHandler = nil; held.removeAll(); registry.unregisterAll() }
    private func receive(id: UInt32, pressed: Bool) {
        guard active, let action = HotkeyAction(rawValue: id) else { return }
        if !pressed { held.remove(id); return }
        guard held.insert(id).inserted else { return }
        actionHandler?(action)
    }
    public static func keyCode(_ shortcut: Shortcut) -> UInt32? {
        let keys = [kVK_ANSI_0,kVK_ANSI_1,kVK_ANSI_2,kVK_ANSI_3,kVK_ANSI_4,kVK_ANSI_5,kVK_ANSI_6,kVK_ANSI_7,kVK_ANSI_8,kVK_ANSI_9]
        guard (0...9).contains(shortcut.digit) else { return nil }
        return UInt32(keys[shortcut.digit])
    }
}
@MainActor public final class SingleFlightCaptureGate {
    private var busy = false
    public init() {}
    public func acquire() -> Bool { guard !busy else { return false }; busy = true; return true }
    public func release() { busy = false }
}
/// Public Carbon registration reports OSStatus directly; no event tap or synthetic input.
@MainActor public final class CarbonHotkeyRegistry: HotkeyRegistering {
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    fileprivate var callback: ((UInt32, Bool)->Void)?
    public init() {}
    deinit {
        refs.forEach { UnregisterEventHotKey($0) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
    public func install(handler: @escaping (UInt32, Bool)->Void) throws {
        unregisterAll(); callback = handler
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetEventDispatcherTarget(), carbonHandler, types.count, &types,
                                        Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else { callback = nil; throw HotkeyError.handler(status) }
    }
    public func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) throws {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers,
            EventHotKeyID(signature: 0x48525632, id: id), GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { throw HotkeyError.registration(status) }
        refs.append(ref)
    }
    public func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil; callback = nil
    }
}
private func carbonHandler(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == 0x48525632 else { return OSStatus(eventNotHandledErr) }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    return MainActor.assumeIsolated {
        Unmanaged<CarbonHotkeyRegistry>.fromOpaque(userData).takeUnretainedValue().callback?(id.id, pressed)
        return noErr
    }
}
