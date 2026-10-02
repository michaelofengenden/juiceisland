import AppKit
import IslandEngine

/// Focus-local keys in the app window (P39, spec §4.4): ⌃G jump to what needs you, ⌃A / ⌃D / ⌃⇧A / ⌃⇧D (No and stop,
/// Claude only) on an approval (or plan) the island can answer, ⌃1-⌃4 on such a question, Esc; a card key acts on one
/// card, what the owner sees (`targetCard`, P351): the keys' row's, else the first card of Needs you, never another
/// behind it. ↑ and ↓ move the keys' row through the cards and rows in the order the list draws them, Return jumps to it,
/// and Esc lets it go before it leaves Needs you (P321). The window's own hosting view calls
/// this from `keyDown` before anything else; a handled key never reaches the app menu. Characters, not key codes, and
/// nothing while an input method has marked text (P40). A held card key's repeats are eaten and answer nothing: once
/// the first approval is answered the next is first, and a repeat would answer it unseen (P138). No event monitor
/// anywhere. Owner: stream C.
@MainActor
enum WindowKeyRouter {
    /// A key press reduced to what the router matches: the character without modifiers (Shift kept, as AppKit's
    /// `charactersIgnoringModifiers` does) and the modifier keys.
    struct KeyPress: Equatable {
        var character: String
        var control = false
        var shift = false
        var option = false
        var command = false
        /// The key's auto-repeat (`NSEvent.isARepeat`), not a press.
        var isRepeat = false

        init(character: String, control: Bool = false, shift: Bool = false, option: Bool = false, command: Bool = false,
             isRepeat: Bool = false) {
            self.character = character
            self.control = control
            self.shift = shift
            self.option = option
            self.command = command
            self.isRepeat = isRepeat
        }

        init?(_ event: NSEvent) {
            guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            self.init(character: characters, control: flags.contains(.control), shift: flags.contains(.shift),
                      option: flags.contains(.option), command: flags.contains(.command), isRepeat: event.isARepeat)
        }
    }

    enum Command: Equatable {
        case jumpToNeedsYou
        case decide(ApprovalDecision)
        /// ⌃1-⌃4, 0-based.
        case option(Int)
        case escape
        /// ↑ (-1) or ↓ (+1): the keys' row (`AppEnvironment.windowSelection`).
        case move(Int)
        /// Return: jump to the keys' row, as a click on it does.
        case open
    }

    static let escapeCharacter = "\u{1B}"

    /// The command a key press asks for, or nil when the router leaves it alone.
    static func command(for key: KeyPress) -> Command? {
        if key.character == escapeCharacter, !key.control, !key.option, !key.command, !key.shift { return .escape }
        if !key.control, !key.option, !key.command, !key.shift {
            if key.character == IslandKeyRouter.upArrow { return .move(-1) }
            if key.character == IslandKeyRouter.downArrow { return .move(1) }
            if IslandKeyRouter.returnKeys.contains(key.character) { return .open }
        }
        guard key.control, !key.option, !key.command else { return nil }
        switch key.character.lowercased() {
        case "g" where !key.shift: return .jumpToNeedsYou
        case "a": return .decide(key.shift ? .alwaysAllow : .allowOnce)
        case "d": return .decide(key.shift ? .denyAndStop : .deny)
        case "1" where !key.shift: return .option(0)
        case "2" where !key.shift: return .option(1)
        case "3" where !key.shift: return .option(2)
        case "4" where !key.shift: return .option(3)
        default: return nil
        }
    }

    /// Does what `command` asks on the first session it applies to. Returns false when nothing applied.
    static func perform(_ command: Command, env: AppEnvironment) -> Bool {
        let sessions = env.sessions
        switch command {
        case .jumpToNeedsYou:
            guard !sessions.needsYou.isEmpty else { return false }
            sessions.jumpToNextNeedsYou()
            return true
        case let .decide(decision):
            // A read-only card, or one of another kind, takes no card key; no other card takes it in its place.
            switch targetCard(env) {
            case let .approval(card)? where card.isAnswerable:
                if decision == .alwaysAllow, card.alwaysAllowLabel == nil { return false }
                if decision == .denyAndStop, !card.canStop { return false }
                sessions.approve(card.sessionID, decision, request: card.request?.id)
                return true
            case let .plan(card)? where card.isAnswerable:
                guard decision != .alwaysAllow, decision != .denyAndStop || card.canStop else { return false }
                sessions.approve(card.sessionID, decision, request: card.request?.id)
                return true
            default:
                return false
            }
        case let .option(index):
            guard case let .question(card)? = targetCard(env), card.isAnswerable, card.options.indices.contains(index) else { return false }
            sessions.answerQuestion(card.sessionID, .option(index), request: card.request?.id)
            return true
        case .escape:
            if env.windowSelection != nil {
                env.windowSelection = nil
                return true
            }
            guard env.windowFilter == .needsYou else { return false }
            env.windowFilter = .all
            return true
        case let .move(step):
            guard let next = RowSelection.moved(env.windowSelection, in: RowSelection.windowOrder(env), by: step) else { return false }
            if env.windowSelection != next { env.windowSelection = next }
            return true
        case .open:
            guard let id = env.windowSelection, RowSelection.windowOrder(env).contains(id) else { return false }
            sessions.jump(id)
            return true
        }
    }

    /// The one card a card key acts on, what the owner sees (P351): the keys' row's card when a row is selected among
    /// those the window lists, and nothing when that row has none; with none selected, the first card of Needs you.
    static func targetCard(_ env: AppEnvironment) -> SessionCard? {
        let sessions = env.sessions
        if let selected = env.windowSelection, RowSelection.windowOrder(env).contains(selected) { return sessions.card(for: selected) }
        return sessions.needsYou.lazy.compactMap { sessions.card(for: $0.id) }.first
    }

    /// While a text field is edited: only the keys that never mean text there (⌃G, ⌃1-⌃4); ⌃A, ⌃D and Esc stay the
    /// field's. Returns true when the key was handled.
    static func handleWhileEditing(_ event: NSEvent, env: AppEnvironment) -> Bool {
        if let client = event.window?.firstResponder as? NSTextInputClient, client.hasMarkedText() { return false }
        guard let key = KeyPress(event), let command = command(for: key), takesWhileEditing(command) else { return false }
        return handle(key, command, env: env)
    }

    /// ↑, ↓ and Return outside a field being edited, offered by the window before whichever view has the focus
    /// (`KeyRoutingWindow`). Returns true when the key was handled.
    static func handleListKey(_ event: NSEvent, env: AppEnvironment) -> Bool {
        if let client = event.window?.firstResponder as? NSTextInputClient, client.hasMarkedText() { return false }
        guard let key = KeyPress(event), let command = command(for: key), isListKey(command) else { return false }
        return handle(key, command, env: env)
    }

    static func isListKey(_ command: Command) -> Bool {
        switch command {
        case .move, .open: true
        case .jumpToNeedsYou, .decide, .option, .escape: false
        }
    }

    static func takesWhileEditing(_ command: Command) -> Bool {
        switch command {
        case .jumpToNeedsYou, .option: true
        case .decide, .escape, .move, .open: false
        }
    }

    /// Returns true when the key was handled.
    static func handle(_ event: NSEvent, env: AppEnvironment) -> Bool {
        if let client = event.window?.firstResponder as? NSTextInputClient, client.hasMarkedText() { return false }
        guard let key = KeyPress(event), let command = command(for: key) else { return false }
        return handle(key, command, env: env)
    }

    /// Performs `command`, unless it answers a card, or jumps on Return, and `key` is a repeat: that is eaten (true) and
    /// does nothing (P138, P322).
    static func handle(_ key: KeyPress, _ command: Command, env: AppEnvironment) -> Bool {
        if key.isRepeat, answersACard(command) || command == .open { return true }
        return perform(command, env: env)
    }

    static func answersACard(_ command: Command) -> Bool {
        switch command {
        case .decide, .option: true
        case .jumpToNeedsYou, .escape, .move, .open: false
        }
    }
}
