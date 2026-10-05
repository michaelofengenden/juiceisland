/// What the one system-wide key does (Settings › Shortcuts, P323): jump to what needs you (the default, as before), or
/// open Juice Island with the keys: in Island mode the island opens at once with its first row selected and takes the
/// keys without making the app active (↑ ↓, Return, the card keys, Esc; the key again closes it); in Window mode the
/// window comes forward. Or switch sessions (P462): the same, but the key again moves the ring to the next row (after
/// the last, the first again) and Return jumps to the ring's session, a waiting one too; with ⇧ it goes back a row
/// (P1033). Still the one hot key `GlobalJumpHotKey` registers: no second key and no monitor.
enum GlobalKeyAction: String, CaseIterable, Sendable {
    case jump, open, switcher

    var title: String {
        switch self {
        case .jump: "Jump to what needs you"
        case .open: "Open \(Product.name)"
        case .switcher: "Switch sessions"
        }
    }

    /// One line under the Action, where the action is not plain from its name; nil otherwise.
    var detail: String? {
        switch self {
        case .jump, .open: nil
        case .switcher: "Again for the next, ⇧ goes back; Return jumps."
        }
    }

    /// Switch sessions' way back (P1033): the system-wide key with ⇧ added, while it is on, recorded and set to switch,
    /// and every shortcut is on. It is never registered: Carbon hands over only the exact key, so this one reaches
    /// whichever of the island and the window has the keys while the switcher shows, through its own key path. nil for a
    /// key recorded with ⇧ already, which has no Shift to add.
    @MainActor static func backKey(_ settings: AppSettings) -> KeyCombo? {
        guard settings.shortcutsEnabled, settings.globalJumpEnabled, settings.globalKeyAction == .switcher,
              var combo = settings.globalJumpKey.flatMap(KeyCombo.init(storage:)), combo.isAcceptable, !combo.shift else { return nil }
        combo.shift = true
        return combo
    }
}
