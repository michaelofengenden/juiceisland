import Carbon.HIToolbox
import Foundation
import Testing
@testable import JuiceIslandUI

/// Stands in for the system: records what would have been registered. No key is ever registered in a test.
@MainActor
final class RecordingHotKeys: HotKeyRegistering {
    enum Call: Equatable { case register(HotKeyCode), unregister }
    private(set) var calls: [Call] = []
    var refuses = false
    private(set) var pressed: (@MainActor () -> Void)?

    func register(_ key: HotKeyCode, pressed: @escaping @MainActor () -> Void) throws {
        if refuses { throw CarbonHotKey.Refused(status: OSStatus(eventHotKeyExistsErr)) }
        calls.append(.register(key))
        self.pressed = pressed
    }

    func unregister() {
        calls.append(.unregister)
        pressed = nil
    }
}

/// The system-wide jump key (spec §4.4, §7 amendment 2; P39, P40): nothing registered while off or unrecorded; the key
/// that types the recorded character on the keyboard's own layout; a press jumps.
@MainActor
struct GlobalJumpHotKeyTests {
    /// A keyboard layout's key table, read from the system's installed layouts (nothing is selected or changed).
    static func layout(_ id: String) throws -> Data {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let sources = try #require(TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])
        let source = try #require(sources.first, "no \(id) layout installed")
        let pointer = try #require(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData))
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    @Test
    func theRecordedCharacterIsTheKeyThatTypesItOnEachLayout() throws {
        let us = try Self.layout("com.apple.keylayout.US")
        let dvorak = try Self.layout("com.apple.keylayout.Dvorak")
        let azerty = try Self.layout("com.apple.keylayout.French")
        #expect(HotKeyCode.keyCode(typing: "g", layout: us) == UInt32(kVK_ANSI_G))
        #expect(HotKeyCode.keyCode(typing: "g", layout: dvorak) == UInt32(kVK_ANSI_U))
        #expect(HotKeyCode.keyCode(typing: "g", layout: azerty) == UInt32(kVK_ANSI_G))
        #expect(HotKeyCode.keyCode(typing: "a", layout: azerty) == UInt32(kVK_ANSI_Q))
        // The main row's digit, not the keypad's; a character only Shift types.
        #expect(HotKeyCode.keyCode(typing: "1", layout: us) == UInt32(kVK_ANSI_1))
        #expect(HotKeyCode.keyCode(typing: "!", layout: us) == UInt32(kVK_ANSI_1))

        let combo = try #require(KeyCombo(storage: "ctrl+opt+g"))
        #expect(HotKeyCode(combo: combo, layout: dvorak) == HotKeyCode(keyCode: UInt32(kVK_ANSI_U), modifiers: UInt32(controlKey | optionKey)))
        let f5 = try #require(KeyCombo(storage: "cmd+shift+f5"))
        #expect(HotKeyCode(combo: f5, layout: nil) == HotKeyCode(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey | shiftKey)))
        #expect(HotKeyCode(combo: KeyCombo(control: true, key: "é"), layout: us) == nil)
    }

    private func make(_ settings: AppSettings, _ keys: RecordingHotKeys, jumps: @escaping @MainActor () -> Void = {}) throws -> GlobalJumpHotKey {
        let us = try Self.layout("com.apple.keylayout.US")
        return GlobalJumpHotKey(settings: settings, registrar: keys, layout: { us }, jump: jumps)
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test
    func nothingIsRegisteredWhileOffOrUnrecorded() throws {
        let settings = AppSettings.ephemeral(), keys = RecordingHotKeys()
        let hotKey = try make(settings, keys)
        hotKey.start()
        settings.globalJumpKey = "ctrl+g"
        hotKey.apply()
        settings.globalJumpKey = nil
        settings.globalJumpEnabled = true
        hotKey.apply()
        #expect(keys.calls.isEmpty)
        #expect(!hotKey.isRegistered && hotKey.problem == nil)
    }

    @Test
    func onAndRecordedRegistersOneKeyThatJumpsAndOffLetsItGo() async throws {
        let settings = AppSettings.ephemeral(), keys = RecordingHotKeys()
        var jumps = 0
        let hotKey = try make(settings, keys) { jumps += 1 }
        hotKey.start()
        settings.globalJumpKey = "ctrl+opt+g"
        settings.globalJumpEnabled = true
        try await settle { hotKey.isRegistered }
        let g = HotKeyCode(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(controlKey | optionKey))
        #expect(keys.calls == [.register(g)])
        keys.pressed?()
        #expect(jumps == 1)

        // Another key: the old one goes first. Recording lets it go and takes it back.
        settings.globalJumpKey = "ctrl+opt+j"
        try await settle { keys.calls.count > 1 }
        let j = HotKeyCode(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey))
        #expect(keys.calls == [.register(g), .unregister, .register(j)])
        hotKey.suspend(true)
        #expect(!hotKey.isRegistered)
        hotKey.suspend(false)
        #expect(keys.calls == [.register(g), .unregister, .register(j), .unregister, .register(j)])

        settings.globalJumpEnabled = false
        try await settle { !hotKey.isRegistered }
        #expect(keys.calls.last == .unregister)
        #expect(keys.pressed == nil)
        hotKey.stop()
    }

    /// A key another app holds is not registered, and the Shortcuts row says so (and rows show no hint for it).
    @Test
    func aKeyTheSystemRefusesIsNamed() throws {
        let settings = AppSettings.ephemeral(), keys = RecordingHotKeys()
        keys.refuses = true
        settings.globalJumpKey = "ctrl+opt+g"
        settings.globalJumpEnabled = true
        let hotKey = try make(settings, keys)
        hotKey.start()
        #expect(!hotKey.isRegistered)
        #expect(hotKey.problem == "Another app uses ⌃⌥G.")
        hotKey.stop()
    }
}
