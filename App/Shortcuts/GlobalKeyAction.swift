/// What the one system-wide key does (Settings › Shortcuts, P323): jump to what needs you (the default, as before), or
/// open Juice Island with the keys: in Island mode the island opens at once with its first row selected and takes the
/// keys without making the app active (↑ ↓, Return, the card keys, Esc; the key again closes it); in Window mode the
/// window comes forward. Or switch sessions (P462): the same, but the key again moves the ring to the next row (after
/// the last, the first again) and Return jumps to the ring's session, a waiting one too. Still the one hot key
/// `GlobalJumpHotKey` registers: no second key and no monitor.
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
        case .switcher: "Again for the next; Return jumps."
        }
    }
}
