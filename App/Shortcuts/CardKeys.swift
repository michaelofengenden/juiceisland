import AppKit
import Carbon.HIToolbox

/// The one modifier every card key takes (Settings › Shortcuts › Modifier, P1025): Control, as ever, or Option. ⌘ stays
/// the menus'.
enum ShortcutModifier: String, CaseIterable, Sendable {
    case control, option

    var glyph: String { self == .control ? "⌃" : "⌥" }
    var title: String { self == .control ? "Control" : "Option" }
}

/// The keys Settings › Shortcuts lets the owner record, one each (P1026): the modifier, perhaps Shift, and one character.
/// The options of a question stay the modifier and 1 to 4.
enum CardKeyAction: String, CaseIterable, Sendable {
    case jump, allow, deny, denyAndStop, alwaysAllow, allowAll, denyAll

    var title: String {
        switch self {
        case .jump: "Jump to what needs you"
        case .allow: "Yes on an approval"
        case .deny: "No on an approval"
        case .denyAndStop: "No, and stop Claude's turn"
        case .alwaysAllow: "Always allow"
        case .allowAll: "Allow all approvals"
        case .denyAll: "Deny all approvals"
        }
    }

    /// The key until the owner records another: today's for the five that were there, so an owner who never opens the
    /// pane keeps every key they had (P1027). Allow all and Deny all both take Shift, so neither comes from a slip.
    var standard: CardKey {
        switch self {
        case .jump: CardKey("g")
        case .allow: CardKey("a")
        case .deny: CardKey("d")
        case .denyAndStop: CardKey("d", shift: true)
        case .alwaysAllow: CardKey("a", shift: true)
        case .allowAll: CardKey("y", shift: true)
        case .denyAll: CardKey("n", shift: true)
        }
    }

    /// It answers cards: a field being edited keeps it, so typing never answers anything (P138).
    var answers: Bool { self != .jump }
}

/// One recorded card key without its modifier: a character as `charactersIgnoringModifiers` gives it (lowercased; a
/// shifted sign stays the sign Shift types, as the key event will read it), and whether Shift is held. Characters, never
/// key codes (P40). Stored as `a` or `shift+a`.
struct CardKey: Hashable, Sendable {
    var character: String
    var shift: Bool

    init(_ character: String, shift: Bool = false) {
        self.character = character.lowercased()
        self.shift = shift
    }

    init?(storage: String) {
        let parts = storage.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1 where Self.takes(parts[0]): self.init(parts[0])
        case 2 where parts[0] == "shift" && Self.takes(parts[1]): self.init(parts[1], shift: true)
        // "+" itself, Shift or not.
        case 2 where parts == ["", ""]: self.init("+")
        case 3 where parts == ["shift", "", ""]: self.init("+", shift: true)
        default: return nil
        }
    }

    var storage: String { shift ? "shift+\(character)" : character }

    /// "⇧A": what follows the modifier.
    var display: String { (shift ? "⇧" : "") + character.uppercased() }

    /// One character a card key can be: a letter, a digit or a sign; never a space, Return, Tab, Esc, an arrow or a
    /// function key, which move, open and close everywhere.
    static func takes(_ character: String) -> Bool {
        guard character.count == 1, let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        if (0xE000...0xF8FF).contains(scalar.value) { return false }
        let properties = scalar.properties
        return properties.isAlphabetic || properties.numericType != nil
            || CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
    }
}

/// Settings › Shortcuts as the routers, the buttons' hints and the pane read it (P1025 to P1030): every key on or off,
/// the modifier, and the keys the owner recorded over the standard ones.
struct CardKeys: Equatable, Sendable {
    /// Keyboard shortcuts: off, no card key, no jump key, no Allow all, no U and no system-wide key; the arrows, Return,
    /// Esc and the ⌘ keys still work, as in any window.
    var enabled = true
    var modifier: ShortcutModifier = .control
    var recorded: [CardKeyAction: CardKey] = [:]

    /// Today's keys, on: renders, tests and an owner who never opens the pane.
    static let standard = CardKeys()

    init(enabled: Bool = true, modifier: ShortcutModifier = .control, recorded: [CardKeyAction: CardKey] = [:]) {
        self.enabled = enabled
        self.modifier = modifier
        self.recorded = recorded
    }

    /// Settings › Shortcuts' (`AppSettings.cardKeys`).
    @MainActor init(_ settings: AppSettings) {
        self.init(enabled: settings.shortcutsEnabled, modifier: settings.shortcutModifier, recorded: settings.recordedCardKeys)
    }

    /// The options of a question, by the character typed (AZERTY's shifted digits read as digits too).
    static let optionDigits = ["1", "2", "3", "4"]

    func key(_ action: CardKeyAction) -> CardKey { recorded[action] ?? action.standard }

    func isStandard(_ action: CardKeyAction) -> Bool { key(action) == action.standard }

    /// The whole key, as the system-wide key's recorder would have it.
    func combo(_ action: CardKeyAction) -> KeyCombo { combo(key(action)) }

    func combo(_ key: CardKey) -> KeyCombo {
        KeyCombo(control: modifier == .control, option: modifier == .option, shift: key.shift, key: key.character)
    }

    /// "⌃⇧A".
    func display(_ action: CardKeyAction) -> String { modifier.glyph + key(action).display }

    /// A button's key hint and tooltip: nil while the keys are off, so nothing shows a key that does nothing.
    func hint(_ action: CardKeyAction) -> String? { enabled ? display(action) : nil }

    /// An option's: "⌃1" for the first four; nil after them or while the keys are off.
    func optionHint(_ index: Int) -> String? { enabled && index < 4 ? "\(modifier.glyph)\(index + 1)" : nil }

    /// "⌃1 – ⌃4", the pane's row.
    var optionsDisplay: String { "\(modifier.glyph)1 – \(modifier.glyph)4" }

    /// The modifier is held, and neither ⌘ nor the other one (Shift may be).
    func holdsModifier(control: Bool, option: Bool, command: Bool) -> Bool {
        guard !command else { return false }
        return modifier == .control ? control && !option : option && !control
    }

    /// The action a character with the modifier asks for (Shift as pressed); nil for none.
    func action(_ character: String, shift: Bool) -> CardKeyAction? {
        let character = character.lowercased()
        return CardKeyAction.allCases.first { key($0) == CardKey(character, shift: shift) }
    }

    /// A field being edited keeps the answering keys; with Option every key, since ⌥ and a key type a character there.
    func takesWhileEditing(_ action: CardKeyAction?) -> Bool {
        modifier == .control && action?.answers != true
    }

    /// The recorded keys as the defaults keep them (`["allowAll": "shift+y"]`); nil when none, so nothing is stored.
    static func encode(_ recorded: [CardKeyAction: CardKey]) -> [String: String]? {
        recorded.isEmpty ? nil : Dictionary(uniqueKeysWithValues: recorded.map { ($0.key.rawValue, $0.value.storage) })
    }

    /// Back from the defaults: an action or a key this build does not know is dropped, and its standard key stands.
    static func decode(_ stored: [String: Any]?) -> [CardKeyAction: CardKey] {
        var recorded: [CardKeyAction: CardKey] = [:]
        for (name, value) in stored ?? [:] {
            guard let action = CardKeyAction(rawValue: name), let text = value as? String, let key = CardKey(storage: text) else { continue }
            recorded[action] = key
        }
        return recorded
    }
}

/// What may be recorded where (P1028): a card key that is one character and no other key of Juice's, and a system-wide
/// key that is no card key. Words for the line under the row. `back`: the way back in Switch sessions, the key from any
/// app with ⇧ (`GlobalKeyAction.backKey`, P1033), which the island and the window match before the card keys.
enum CardKeyCheck {
    /// Why `key` cannot be `action`'s, or nil: one of the question's options, another action's key, the key from any
    /// app (which would take it before the island or the window could), or the way back.
    static func refusal(_ key: CardKey, for action: CardKeyAction, keys: CardKeys, global: KeyCombo?,
                        back: KeyCombo? = nil) -> String? {
        let combo = keys.combo(key)
        if CardKeys.optionDigits.contains(key.character) {
            return "\(keys.modifier.glyph)1 to \(keys.modifier.glyph)4 pick a question's option."
        }
        if let other = CardKeyAction.allCases.first(where: { $0 != action && keys.key($0) == key }) {
            return "\(combo.display) is already \(other.title)."
        }
        if let global, global == combo, action != .jump { return "\(combo.display) is the key from any app." }
        if let back, back == combo { return "\(combo.display) goes back in Switch sessions." }
        return nil
    }

    /// Why a key pressed in a card key's recorder is not one: ⌘ (the menus'), or not one character.
    static func refusal(characters: String?, modifiers: NSEvent.ModifierFlags) -> String? {
        if modifiers.contains(.command) { return "⌘ keys belong to the menus." }
        guard let characters, CardKey.takes(characters.lowercased()) else { return "Pick a letter, a digit or a sign." }
        return nil
    }

    /// The card key a recorder's press records: its character and Shift; whichever modifier was held, the pane's is used.
    static func key(characters: String, modifiers: NSEvent.ModifierFlags) -> CardKey {
        CardKey(characters, shift: modifiers.contains(.shift))
    }

    /// The card action a system-wide key would take from the island and the window, or nil. The jump key may be the
    /// same: the key then jumps from anywhere (spec §4.4: ⌃G is allowed, with its warning).
    static func cardAction(for global: KeyCombo, keys: CardKeys) -> CardKeyAction? {
        CardKeyAction.allCases.first { $0 != .jump && keys.combo($0) == global }
    }

    /// The card action whose key is the way back, or nil (W3R-3): the key from any app recorded or the modifier changed
    /// after the card key was, or Switch sessions picked after both.
    static func backAction(_ back: KeyCombo?, keys: CardKeys) -> CardKeyAction? {
        guard let back else { return nil }
        return CardKeyAction.allCases.first { keys.combo($0) == back }
    }

    /// The line under the system-wide key's row when a card key is the same key (the modifier changed since), or is the
    /// same key with ⇧ in Switch sessions.
    static func globalClash(_ global: KeyCombo?, keys: CardKeys, back: KeyCombo? = nil) -> String? {
        guard let global else { return nil }
        if let action = cardAction(for: global, keys: keys) { return "Also \(action.title) in \(Product.name); this key wins." }
        guard let action = backAction(back, keys: keys) else { return nil }
        return "With ⇧ also \(action.title) in \(Product.name); going back wins."
    }

    /// The line under a card key's row when the key from any app is the same key, or the way back is: that one takes
    /// it first.
    static func cardClash(_ action: CardKeyAction, keys: CardKeys, global: KeyCombo?, back: KeyCombo? = nil) -> String? {
        if let global, action != .jump, keys.combo(action) == global { return "The key from any app takes it first." }
        if let back, keys.combo(action) == back { return "Going back in Switch sessions takes it first." }
        return nil
    }
}

/// The keys macOS takes itself (System Settings › Keyboard › Keyboard Shortcuts: Mission Control's ⌃1 to switch desktops,
/// ⌃Space for the input source), which then never reach Juice (P1029). Read from the owner's own shortcut list with
/// `CopySymbolicHotKeys`: no permission, nothing registered, nothing watched. Tests and renders give their own list.
struct SystemShortcuts: Sendable {
    /// The enabled ones, as key codes and Carbon modifiers.
    var taken: @Sendable () -> [HotKeyCode]
    /// The key code a combination is on this keyboard (`HotKeyCode(combo:layout:)`); nil when no key types it.
    var code: @Sendable (KeyCombo) -> HotKeyCode?

    static let none = SystemShortcuts(taken: { [] }, code: { _ in nil })

    static let live = SystemShortcuts(taken: { readSymbolicHotKeys() }, code: { combo in
        HotKeyCode(combo: combo, layout: HotKeyCode.currentLayout())
    })

    /// macOS uses `combo` for one of its own shortcuts.
    func uses(_ combo: KeyCombo) -> Bool {
        guard let code = code(combo) else { return false }
        return taken().contains { $0.keyCode == code.keyCode && $0.modifiers & Self.modifierMask == code.modifiers & Self.modifierMask }
    }

    /// The line under a row whose key macOS takes.
    static func line(_ combo: KeyCombo) -> String { "macOS already uses \(combo.display)." }

    static let modifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    private static func readSymbolicHotKeys() -> [HotKeyCode] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let list = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard item[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let code = item[kHISymbolicHotKeyCode as String] as? Int, (0..<128).contains(code),
                  let modifiers = item[kHISymbolicHotKeyModifiers as String] as? Int else { return nil }
            return HotKeyCode(keyCode: UInt32(code), modifiers: UInt32(modifiers) & modifierMask)
        }
    }
}
