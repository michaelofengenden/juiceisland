import SwiftUI

/// Settings › Shortcuts (spec §4.4, §4.5; P39, P40, P1025 to P1033): Keyboard shortcuts, every key of Juice's on or off,
/// and the card keys' one modifier, Control or Option; then the keys in Juice, each card key recordable with a Reset
/// back to its standard key, a line when it would clash with another of Juice's keys and when macOS takes it itself; the
/// fixed keys after them; and the one system-wide key, off with no key until one is recorded; it is registered only
/// while it is on and recorded (`GlobalJumpHotKey`), and the row says when it cannot be. Its action: Jump to what needs
/// you (default), Open Juice Island with the keys (P323), or Switch sessions (P462, ⇧ goes back, P1033).
/// Owner: stream A.
struct ShortcutsPane: View {
    @Environment(AppEnvironment.self) private var env
    /// Why the last key a recorder was given was refused, per card key, and the system-wide one's.
    @State private var refusals: [CardKeyAction: String] = [:]
    @State private var globalRefusal: String?

    /// The keys that are not recorded: the movement keys every list has, U, and the menus' ⌘ keys.
    static let localKeys: [(String, String)] = [
        ("Move through sessions", "↑ ↓"),
        ("Open a card or jump", "Return"),
        ("Step through the island's usage", "U"),
        ("Switch Window and Island", "⌘⇧I"),
        ("Close a card or menu", "Esc"),
    ]

    /// The Action row shows only while a key is recorded and on: otherwise it changes nothing (as Quiet's rows follow
    /// their switch).
    static func showsAction(combo: KeyCombo?, enabled: Bool) -> Bool { combo != nil && enabled }

    /// The line under a card key's row: why a key was just refused, the key from any app or its way back (`back`, in
    /// Switch sessions) taking it first, or macOS using it; nil for none.
    static func line(_ action: CardKeyAction, keys: CardKeys, global: KeyCombo?, system: SystemShortcuts,
                     refusal: String? = nil, back: KeyCombo? = nil) -> String? {
        if let refusal { return refusal }
        if let clash = CardKeyCheck.cardClash(action, keys: keys, global: global, back: back) { return clash }
        let combo = keys.combo(action)
        return system.uses(combo) ? SystemShortcuts.line(combo) : nil
    }

    /// The options' line: macOS using the modifier with one of 1 to 4 (Mission Control's desktops on ⌃1 to ⌃4). "⌃1 and
    /// ⌃2" for two, "⌃1 to ⌃3" for a run of three or more, each one named when there is a gap ("⌃1, ⌃2 and ⌃4").
    static func optionsLine(keys: CardKeys, system: SystemShortcuts) -> String? {
        let taken = CardKeys.optionDigits.indices.filter { system.uses(keys.combo(CardKey(CardKeys.optionDigits[$0]))) }
        let names = taken.map { keys.combo(CardKey(CardKeys.optionDigits[$0])).display }
        guard let first = names.first, let last = names.last, let low = taken.first, let high = taken.last else { return nil }
        let run = taken.count >= 3 && high - low == taken.count - 1
        let keysText = switch names.count {
        case 1: first
        case _ where run: "\(first) to \(last)"
        default: names.dropLast().joined(separator: ", ") + " and \(last)"
        }
        return "macOS already uses \(keysText)."
    }

    /// The system-wide key's line: why it was refused, Keyboard shortcuts off, why it is not registered, a card key it
    /// or its way back (`back`) takes, macOS using it, or ⌃G's warning.
    static func globalLine(_ combo: KeyCombo?, problem: String?, refusal: String?, keys: CardKeys, system: SystemShortcuts,
                           back: KeyCombo? = nil) -> String? {
        if let refusal { return refusal }
        guard let combo else { return nil }
        if !keys.enabled { return "Off with Keyboard shortcuts." }
        if let problem { return problem }
        if let clash = CardKeyCheck.globalClash(combo, keys: keys, back: back) { return clash }
        if system.uses(combo) { return SystemShortcuts.line(combo) }
        return combo.warning
    }

    var body: some View {
        @Bindable var settings = env.settings
        let keys = settings.cardKeys
        let combo = settings.globalJumpKey.flatMap(KeyCombo.init(storage:))
        let back = GlobalKeyAction.backKey(settings)
        let system = env.systemShortcuts
        FormPane {
            // Every key at once; what was recorded stays while they are off (P1030).
            FormSection {
                FormRow("Keyboard shortcuts", subtitle: keys.enabled ? nil : "Arrows, Return and Esc still work.") {
                    SettingsSwitch(isOn: $settings.shortcutsEnabled, label: "Keyboard shortcuts")
                }
                FormRow("Modifier", dimmed: !keys.enabled) {
                    SettingsSegmented(selection: $settings.shortcutModifier,
                                      options: ShortcutModifier.allCases.map { ($0, "\($0.title) \($0.glyph)") }, label: "Modifier")
                }
            }
            // Focus-local: they never take a key from the terminal.
            FormSection("In \(env.flavor.productName)") {
                ForEach(CardKeyAction.allCases, id: \.self) { action in
                    FormRow(action.title, subtitle: Self.line(action, keys: keys, global: combo, system: system, refusal: refusals[action],
                                                              back: back),
                            dimmed: !keys.enabled) {
                        CardKeyRecorder(action: action, keys: keys, record: { record($0, for: action, global: combo, back: back) },
                                        reset: { settings.recordedCardKeys[action] = nil }, refusal: refusal(action))
                    }
                }
                FormRow("Pick a question's option", subtitle: Self.optionsLine(keys: keys, system: system), dimmed: !keys.enabled) {
                    KeyCap(text: keys.optionsDisplay)
                }
                ForEach(Self.localKeys, id: \.0) { item in
                    FormRow(item.0, dimmed: !keys.enabled && item.1 == "U") { KeyCap(text: item.1) }
                }
            }
            // One row: the key, then the switch. Off with no key until one is recorded; nothing is registered while
            // it is off.
            FormSection("From any app") {
                FormRow("Key", subtitle: Self.globalLine(combo, problem: env.globalJump?.problem, refusal: globalRefusal, keys: keys,
                                                          system: system, back: back), dimmed: !keys.enabled) {
                    HStack(spacing: 12) {
                        KeyRecorder(storage: $settings.globalJumpKey, onRecording: { env.globalJump?.suspend($0) },
                                    refuse: { CardKeyCheck.cardAction(for: $0, keys: settings.cardKeys).map { "\($0.title) uses that key." } },
                                    onRejected: { globalRefusal = $0 })
                        SettingsSwitch(isOn: $settings.globalJumpEnabled, label: "System-wide key")
                    }
                }
                if Self.showsAction(combo: combo, enabled: settings.globalJumpEnabled) {
                    FormRow("Action", subtitle: settings.globalKeyAction.detail, dimmed: !keys.enabled) {
                        SettingsSegmented(selection: $settings.globalKeyAction,
                                          options: GlobalKeyAction.allCases.map { ($0, $0.title) }, label: "System-wide key's action")
                    }
                }
            }
        }
    }

    /// Takes `key` for `action` unless another of Juice's keys has it; the standard key is kept as no recording at all.
    private func record(_ key: CardKey, for action: CardKeyAction, global: KeyCombo?, back: KeyCombo?) -> String? {
        let settings = env.settings
        if let why = CardKeyCheck.refusal(key, for: action, keys: settings.cardKeys, global: global, back: back) { return why }
        settings.recordedCardKeys[action] = key == action.standard ? nil : key
        return nil
    }

    private func refusal(_ action: CardKeyAction) -> Binding<String?> {
        Binding(get: { refusals[action] }, set: { refusals[action] = $0 })
    }
}

/// A key hint as a small cap (12 pt, white 8 %, radius 5).
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Fonts.sys(12, .medium))
            .foregroundStyle(SettingsTheme.ink)
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(SettingsTheme.chip))
    }
}
