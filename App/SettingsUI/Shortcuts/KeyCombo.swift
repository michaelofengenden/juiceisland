import AppKit

/// A recorded key for the system-wide jump (Settings › Shortcuts), stored as `ctrl+shift+g`. Keys are characters,
/// never key codes (P40). A combination needs ⌃, ⌥ or ⌘; ⌃G is allowed with a warning (spec §4.4, P39).
struct KeyCombo: Equatable, Sendable {
    var control = false
    var option = false
    var shift = false
    var command = false
    /// A lowercased character ("g", "1") or a named key ("space", "return", "f5").
    var key: String

    static let ctrlGWarning = "Claude Code and the shell lose ⌃G."

    init(control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false, key: String) {
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
        self.key = key.lowercased()
    }

    /// Parses `ctrl+shift+g`; nil for empty or malformed text.
    init?(storage: String) {
        let parts = storage.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last, !key.isEmpty else { return nil }
        self.key = key
        for part in parts.dropLast() {
            switch part {
            case "ctrl": control = true
            case "opt": option = true
            case "shift": shift = true
            case "cmd": command = true
            default: return nil
            }
        }
    }

    var storage: String {
        ([control ? "ctrl" : nil, option ? "opt" : nil, shift ? "shift" : nil, command ? "cmd" : nil].compactMap { $0 } + [key])
            .joined(separator: "+")
    }

    /// `⌃⇧G`, in the system's modifier order ⌃ ⌥ ⇧ ⌘.
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + Self.keyGlyph(key)
    }

    /// A system-wide key needs at least one of ⌃ ⌥ ⌘, or it would take a plain letter from every app.
    var isAcceptable: Bool { control || option || command }

    var warning: String? {
        control && !option && !shift && !command && key == "g" ? Self.ctrlGWarning : nil
    }

    /// From a key event's characters (ignoring modifiers) and its modifier flags. nil for a bare modifier press or
    /// a key with no character.
    static func from(characters: String?, modifiers: NSEvent.ModifierFlags) -> KeyCombo? {
        guard let characters, let first = characters.first else { return nil }
        let key = namedKey(first) ?? String(first).lowercased()
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key == "space" else { return nil }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        return KeyCombo(control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift),
                        command: flags.contains(.command), key: key)
    }

    private static func namedKey(_ character: Character) -> String? {
        switch character {
        case " ": return "space"
        case "\r": return "return"
        case "\t": return "tab"
        default: break
        }
        guard let scalar = character.unicodeScalars.first else { return nil }
        let value = Int(scalar.value)
        if (NSF1FunctionKey...NSF20FunctionKey).contains(value) { return "f\(value - NSF1FunctionKey + 1)" }
        return nil
    }

    private static func keyGlyph(_ key: String) -> String {
        switch key {
        case "space": "Space"
        case "return": "↩"
        case "tab": "⇥"
        default: key.count > 1 ? key.uppercased() : key.uppercased()
        }
    }
}
