import AppKit
import Carbon.HIToolbox
import Observation

/// The one system-wide key, "jump to what needs you" (spec §4.4, §7 amendment 2), and the only file that registers a
/// key with the system (guardrail check 4). It is registered only while Settings › Shortcuts has the switch on and a
/// key recorded; with either missing nothing is registered and nothing is watched. A press jumps to the first session
/// that needs you, from any app. No event monitor and no event tap: the system hands over this one key's presses and
/// no other key (a Carbon hot key and its handler on the app's own event target).
@MainActor
@Observable
final class GlobalJumpHotKey {
    /// Why the recorded key is not registered: another app holds it, or no key on this keyboard types it. nil while it
    /// is registered or off.
    private(set) var problem: String?
    private(set) var isRegistered = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let registrar: any HotKeyRegistering
    @ObservationIgnored private let layout: @MainActor () -> Data?
    @ObservationIgnored private let jump: @MainActor () -> Void
    @ObservationIgnored private var registered: HotKeyCode?
    @ObservationIgnored private var layoutObserver: NSObjectProtocol?
    @ObservationIgnored private var started = false
    /// While Settings › Shortcuts records a key, the registered one is let go, so pressing it again records it.
    @ObservationIgnored private var suspended = false

    /// `layout` is the keyboard layout keys are looked up in (the current one in the app); `jump` runs on each press.
    init(settings: AppSettings, registrar: any HotKeyRegistering, layout: @escaping @MainActor () -> Data? = { HotKeyCode.currentLayout() },
         jump: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.registrar = registrar
        self.layout = layout
        self.jump = jump
    }

    /// At launch: registers the key if it is on and recorded, and follows the two settings from then on.
    func start() {
        guard !started else { return }
        started = true
        observe()
    }

    /// At quit.
    func stop() {
        started = false
        release()
    }

    /// The key recorder starts or stops recording.
    func suspend(_ recording: Bool) {
        suspended = recording
        if recording { release(keepWatching: true) } else { apply() }
    }

    /// Brings the registration in line with the settings and the keyboard layout.
    func apply() {
        guard !suspended else { return }
        guard settings.globalJumpEnabled, let combo = settings.globalJumpKey.flatMap(KeyCombo.init(storage:)), combo.isAcceptable else {
            release()
            problem = nil
            return
        }
        watchLayout()
        guard let code = HotKeyCode(combo: combo, layout: layout()) else {
            release(keepWatching: true)
            problem = HotKeyText.noKey(combo)
            return
        }
        guard code != registered else { return }
        if registered != nil { registrar.unregister() }
        registered = nil
        do {
            try registrar.register(code) { [weak self] in self?.jump() }
            registered = code
            isRegistered = true
            problem = nil
        } catch {
            isRegistered = false
            problem = HotKeyText.taken(combo)
        }
    }

    private func observe() {
        guard started else { return }
        withObservationTracking {
            _ = settings.globalJumpEnabled
            _ = settings.globalJumpKey
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply()
    }

    /// While a key is wanted: another keyboard layout may put its character on another key (P40).
    private func watchLayout() {
        guard layoutObserver == nil else { return }
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        layoutObserver = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    private func release(keepWatching: Bool = false) {
        if registered != nil { registrar.unregister() }
        registered = nil
        isRegistered = false
        if !keepWatching, let layoutObserver {
            DistributedNotificationCenter.default().removeObserver(layoutObserver)
            self.layoutObserver = nil
        }
    }
}

/// The Shortcuts pane's words for a key that is not registered.
enum HotKeyText {
    static func taken(_ combo: KeyCombo) -> String { "Another app uses \(combo.display)." }
    static func noKey(_ combo: KeyCombo) -> String { "No key on this keyboard types \(combo.display)." }
}

/// A recorded key as the system registers it: the keyboard's key code and Carbon's modifier flags. A character is
/// found through the keyboard layout (`UCKeyTranslate`), so the key is the one that types it on Dvorak or AZERTY too,
/// never a fixed code (P40); named keys (Space, Return, Tab, F1 to F20) have fixed codes.
struct HotKeyCode: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(combo: KeyCombo, layout: Data?) {
        let modifiers = (combo.control ? UInt32(controlKey) : 0) | (combo.option ? UInt32(optionKey) : 0)
            | (combo.shift ? UInt32(shiftKey) : 0) | (combo.command ? UInt32(cmdKey) : 0)
        if let named = Self.named[combo.key] {
            self.init(keyCode: named, modifiers: modifiers)
            return
        }
        guard let layout, let code = Self.keyCode(typing: combo.key, layout: layout) else { return nil }
        self.init(keyCode: code, modifiers: modifiers)
    }

    static let named: [String: UInt32] = {
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                            kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        var keys: [String: UInt32] = ["space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "tab": UInt32(kVK_Tab)]
        for (index, code) in functionKeys.enumerated() { keys["f\(index + 1)"] = UInt32(code) }
        return keys
    }()

    /// The key that types `character` (lowercased) in `layout` (`kTISPropertyUnicodeKeyLayoutData`): first without
    /// Shift, then with it (a key recorded with ⇧ is stored as the character Shift types). The lowest key code wins, so a
    /// digit is the main row's, not the keypad's.
    static func keyCode(typing character: String, layout: Data) -> UInt32? {
        layout.withUnsafeBytes { raw -> UInt32? in
            guard let keyboard = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for shift in [UInt32(0), UInt32(shiftKey >> 8)] {
                for code in UInt16(0)..<128 {
                    var dead: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(keyboard, code, UInt16(kUCKeyActionDown), shift, UInt32(LMGetKbdType()),
                                                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, characters.count, &length, &characters)
                    guard status == noErr, length > 0 else { continue }
                    if String(utf16CodeUnits: characters, count: length).lowercased() == character { return UInt32(code) }
                }
            }
            return nil
        }
    }

    /// The keyboard layout in use now (an input method's own layout, else the last ASCII-capable one).
    static func currentLayout() -> Data? {
        let copies: [() -> Unmanaged<TISInputSource>?] = [TISCopyCurrentKeyboardLayoutInputSource,
                                                           TISCopyCurrentASCIICapableKeyboardLayoutInputSource]
        for copy in copies {
            guard let source = copy()?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        }
        return nil
    }
}

/// Registers one key with the system: Carbon in the app, a recorder in tests, which never register a key.
@MainActor
protocol HotKeyRegistering: AnyObject {
    /// `pressed` runs on the main thread at each press. Throws when the key cannot be had (another app holds it).
    func register(_ key: HotKeyCode, pressed: @escaping @MainActor () -> Void) throws
    func unregister()
}

/// `RegisterEventHotKey` on the app's event target, with a handler for that key's presses alone; both go at
/// `unregister`, so nothing of it stays while the key is off.
@MainActor
final class CarbonHotKey: HotKeyRegistering {
    struct Refused: Error { let status: OSStatus }

    /// "JIjk", and the one id.
    private nonisolated static let signature: OSType = 0x4A49_6A6B
    private nonisolated static let number: UInt32 = 1
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressed: (@MainActor () -> Void)?

    func register(_ key: HotKeyCode, pressed: @escaping @MainActor () -> Void) throws {
        unregister()
        self.pressed = pressed
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                         MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == CarbonHotKey.signature, id.id == CarbonHotKey.number else {
                return OSStatus(eventNotHandledErr)
            }
            let owner = Unmanaged<CarbonHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.pressed?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else {
            unregister()
            throw Refused(status: installed)
        }
        let id = EventHotKeyID(signature: Self.signature, id: Self.number)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else {
            unregister()
            throw Refused(status: status)
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        pressed = nil
    }
}
