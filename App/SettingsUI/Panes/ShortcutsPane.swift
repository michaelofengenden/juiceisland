import SwiftUI

/// Settings › Shortcuts (spec §4.4, §4.5; P39, P40): the focus-local keys as a list, and the one system-wide key,
/// off with no key until one is recorded; it is registered only while it is on and recorded (`GlobalJumpHotKey`), and
/// the row says when it cannot be. Its action: Jump to what needs you (default), Open Juice Island with the keys
/// (P323), or Switch sessions (P462). Owner: stream A.
struct ShortcutsPane: View {
    @Environment(AppEnvironment.self) private var env

    static let localKeys: [(String, String)] = [
        ("Jump to what needs you", "⌃G"),
        ("Yes on an approval", "⌃A"),
        ("No on an approval", "⌃D"),
        ("No, and stop Claude's turn", "⌃⇧D"),
        ("Always allow", "⌃⇧A"),
        ("Pick a question's option", "⌃1 – ⌃4"),
        ("Move through sessions", "↑ ↓"),
        ("Open a card or jump", "Return"),
        ("Step through the island's usage", "U"),
        ("Switch Window and Island", "⌘⇧I"),
        ("Close a card or menu", "Esc"),
    ]

    /// The Action row shows only while a key is recorded and on: otherwise it changes nothing (as Quiet's rows follow
    /// their switch).
    static func showsAction(combo: KeyCombo?, enabled: Bool) -> Bool { combo != nil && enabled }

    var body: some View {
        @Bindable var settings = env.settings
        let combo = settings.globalJumpKey.flatMap(KeyCombo.init(storage:))
        FormPane {
            // Focus-local: they never take a key from the terminal.
            FormSection("In \(Product.name)") {
                ForEach(Self.localKeys, id: \.0) { item in
                    FormRow(item.0) { KeyCap(text: item.1) }
                }
            }
            // One row: the key, then the switch. Off with no key until one is recorded; nothing is registered while
            // it is off.
            FormSection("From any app") {
                FormRow("Key", subtitle: env.globalJump?.problem ?? combo?.warning) {
                    HStack(spacing: 12) {
                        KeyRecorder(storage: $settings.globalJumpKey) { env.globalJump?.suspend($0) }
                        SettingsSwitch(isOn: $settings.globalJumpEnabled, label: "System-wide key")
                    }
                }
                if Self.showsAction(combo: combo, enabled: settings.globalJumpEnabled) {
                    FormRow("Action", subtitle: settings.globalKeyAction.detail) {
                        SettingsSegmented(selection: $settings.globalKeyAction,
                                          options: GlobalKeyAction.allCases.map { ($0, $0.title) }, label: "System-wide key's action")
                    }
                }
            }
        }
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
