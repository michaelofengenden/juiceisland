import AppKit
import IslandEngine

/// One key press as the island reads it: characters, never key codes (P40), so ⌃G is ⌃G under Dvorak or AZERTY.
struct IslandKeyPress: Equatable, Sendable {
    /// `charactersIgnoringModifiers` (Shift still applies, so ⌃⇧A reads "A" and AZERTY's ⌃⇧& reads "1").
    var characters: String
    var control = false
    var shift = false
    var command = false
    var option = false
    /// An input method is composing (CJK): every key belongs to it.
    var hasMarkedText = false
    /// A text field is being edited (a No's reason, an answer, a reply): ⌃A and ⌃D are its line-start and
    /// delete-forward keys.
    var editing = false
    /// The key's auto-repeat (`NSEvent.isARepeat`), not a press.
    var isRepeat = false

    @MainActor init(event: NSEvent, hasMarkedText: Bool, editing: Bool = false) {
        let flags = event.modifierFlags
        self.init(characters: event.charactersIgnoringModifiers ?? "", control: flags.contains(.control),
                  shift: flags.contains(.shift), command: flags.contains(.command), option: flags.contains(.option),
                  hasMarkedText: hasMarkedText, editing: editing,
                  isRepeat: event.type == .keyDown && event.isARepeat)
    }

    init(characters: String, control: Bool = false, shift: Bool = false, command: Bool = false, option: Bool = false,
         hasMarkedText: Bool = false, editing: Bool = false, isRepeat: Bool = false) {
        self.characters = characters
        self.control = control
        self.shift = shift
        self.command = command
        self.option = option
        self.hasMarkedText = hasMarkedText
        self.editing = editing
        self.isRepeat = isRepeat
    }
}

enum IslandKeyCommand: Equatable, Sendable {
    /// Esc: close the island (a close the pointer did not cause).
    case close
    /// ⌃G: jump to the first session that needs you (the panel gives up key first).
    case jumpToNextNeedsYou
    case approve(sessionID: String, ApprovalDecision)
    /// ⌃1-⌃4 on a question (0-based).
    case chooseOption(sessionID: String, index: Int)
    /// ⌘⇧I: Show as Window.
    case showAsWindow
    /// ⌘,: Settings.
    case openSettings
    /// ↑ (-1) or ↓ (+1) over the list: the keys' row moves (`RowSelection`, P321).
    case moveSelection(Int)
    /// Return over the list: the keys' row opens its card, or jumps, as a click on it does.
    case openSelection
    /// U over the list: the usage block's next battery (`UsageCycle`, P461).
    case cycleUsage
    /// S over the list: the keys' row goes to the island, as its Send to island does (P1300).
    case sendSelection
    /// Allow all (Yes) or Deny all (No) on an approval card while two or more wait: each approval `BatchAnswer` covers,
    /// as its own Yes or No would (P1031).
    case answerAll(ApprovalDecision)
    /// ⇧ and the system-wide key while it switches sessions: the ring goes back a row (P1033).
    case switchBack
    /// Eaten: ⌘Q never reaches the app menu, so it cannot quit from the island (P39); a card key's auto-repeat never
    /// answers the card that took the answered one's place, nor does any key a card that has just come in (P138); a
    /// held Return's repeats open nothing and submit no field (P322).
    case swallow

    /// The session a card key answers.
    var sessionID: String? {
        switch self {
        case let .approve(id, _), let .chooseOption(id, _): id
        case .close, .jumpToNextNeedsYou, .showAsWindow, .openSettings, .moveSelection, .openSelection, .cycleUsage, .answerAll,
             .switchBack, .sendSelection, .swallow: nil
        }
    }
}

/// The island's keys (spec §4.4, P39, P40). Only the panel's own `keyDown`/`performKeyEquivalent` call this; there is
/// no event monitor. A card key acts on one card, what the owner sees (`targetCard`, P351): the card on show, else the
/// keys' row's, else the first waiting row the list shows; never another one behind it. Over the list, ↑ and ↓ move the
/// keys' row and Return opens it, as a click on it does (P321), and U steps through the usage block's batteries (P461).
/// ⌃⇧D is No and stop, on a Claude approval or plan. A read-only card takes no card key. While a text field is edited,
/// ⌃A, ⌃⇧A, ⌃D and ⌃⇧D are the
/// field's, as in the window (P138): typing why the answer is No never turns it into a Yes. A held key's repeats
/// answer nothing, nor does any key a card that has just come in: the next card that waits takes the answered one's
/// place within tens of milliseconds (P130), so either would answer a card the owner never saw (P138); they are eaten.
/// The card keys are Settings › Shortcuts' (`CardKeys`, P1025 to P1030): one modifier, Control or Option, each action's
/// recorded or standard key, all of them off with Keyboard shortcuts; with Option a field being edited keeps every key.
enum IslandKeyRouter {
    /// `card`: the one card a card key acts on (`targetCard`); nil, and a card key does nothing.
    /// `arriving`: the card that has just come in (`IslandUIState.arrivingCard`), which no key answers yet (P138).
    /// `listing`: the island shows its list, where ↑, ↓ and Return move and open the keys' row (P321); over a card
    /// they are the card's.
    /// `keys`: Settings › Shortcuts (`AppSettings.cardKeys`). `switchBack`: the system-wide key with ⇧ while the island
    /// switches sessions (`GlobalKeyAction.backKey`), else nil. `batch`: how many approvals Allow all would answer from the
    /// card on show (`BatchAnswer.islandTargets`), 0 when it shows no Allow all; `batchArriving`: one of them has just
    /// come in (`BatchAnswer.justArrived`), and Allow all's key is eaten (P1032).
    static func command(for key: IslandKeyPress, card: SessionCard?, arriving: String? = nil, listing: Bool = false,
                        keys: CardKeys = .standard, switchBack: KeyCombo? = nil, batch: Int = 0,
                        batchArriving: Bool = false) -> IslandKeyCommand? {
        guard !key.hasMarkedText else { return nil }
        let character = key.characters.lowercased()

        if let switchBack, !key.editing, pressed(key) == switchBack { return key.isRepeat ? .swallow : .switchBack }
        if key.command {
            if character == "q" { return .swallow }
            if character == "i", key.shift, !key.control, !key.option { return .showAsWindow }
            if character == ",", !key.shift, !key.control, !key.option { return .openSettings }
            return nil
        }
        if key.characters == "\u{1b}", !key.control, !key.option { return .close }
        if let command = listCommand(key, listing: listing, keys: keys) { return command }
        guard keys.enabled, keys.holdsModifier(control: key.control, option: key.option, command: key.command) else { return nil }
        let action = keys.action(character, shift: key.shift)
        if key.editing, !keys.takesWhileEditing(action) { return nil }
        if action == .jump { return .jumpToNextNeedsYou }
        if action == .allowAll || action == .denyAll {
            guard batch >= BatchAnswer.minimum, case .approval? = card else { return nil }
            return key.isRepeat || card?.sessionID == arriving || batchArriving
                ? .swallow : .answerAll(action == .allowAll ? .allowOnce : .deny)
        }
        guard let card, let command = cardCommand(character, action: action, card: card) else { return nil }
        return key.isRepeat || command.sessionID == arriving ? .swallow : command
    }

    /// The press as the system-wide key's recorder would have it, to match a recorded key.
    static func pressed(_ key: IslandKeyPress) -> KeyCombo? {
        var flags: NSEvent.ModifierFlags = []
        if key.control { flags.insert(.control) }
        if key.option { flags.insert(.option) }
        if key.shift { flags.insert(.shift) }
        if key.command { flags.insert(.command) }
        return KeyCombo.from(characters: key.characters, modifiers: flags)
    }

    private static func cardCommand(_ character: String, action: CardKeyAction?, card: SessionCard) -> IslandKeyCommand? {
        // A read-only card answers nothing: its agent's own prompt is where it is answered.
        guard card.isAnswerable else { return nil }
        switch card {
        case let .approval(model):
            switch action {
            case .allow: return .approve(sessionID: model.sessionID, .allowOnce)
            case .alwaysAllow: return model.alwaysAllowLabel == nil ? nil : .approve(sessionID: model.sessionID, .alwaysAllow)
            case .deny: return .approve(sessionID: model.sessionID, .deny)
            case .denyAndStop: return model.canStop ? .approve(sessionID: model.sessionID, .denyAndStop) : nil
            default: return nil
            }
        case let .plan(model):
            switch action {
            case .allow: return .approve(sessionID: model.sessionID, .allowOnce)
            case .deny: return .approve(sessionID: model.sessionID, .deny)
            case .denyAndStop: return model.canStop ? .approve(sessionID: model.sessionID, .denyAndStop) : nil
            default: return nil
            }
        case let .question(model):
            if let digit = Int(character), (1...4).contains(digit), digit <= model.options.count {
                return .chooseOption(sessionID: model.sessionID, index: digit - 1)
            }
        case .done, .quota:
            break
        }
        return nil
    }

    static let upArrow = "\u{F700}"
    static let downArrow = "\u{F701}"
    /// Return, and the keypad's Enter.
    static let returnKeys: Set<String> = ["\r", "\u{3}"]
    /// Steps through the usage (P461), as the character typed, so it is the key that types U on any layout (P40).
    static let usageKey = "u"
    /// Sends the keys' row to the island (P1300), as the character typed.
    static let sendKey = "s"

    /// ↑, ↓ and Return with no modifier, over the list and outside a field being edited (P321). A held Return's
    /// repeats are eaten wherever they land: the first opens a row's card, and a repeat must not then submit the field
    /// that card focused, nor open the next row (P322). U (Shift or not) steps through the usage (P461); a held U's
    /// repeats are eaten, so the block does not flicker through every battery and fold.
    private static func listCommand(_ key: IslandKeyPress, listing: Bool, keys: CardKeys) -> IslandKeyCommand? {
        guard !key.control, !key.option, !key.command else { return nil }
        let isReturn = returnKeys.contains(key.characters)
        if isReturn, key.isRepeat { return .swallow }
        if keys.enabled, listing, !key.editing, key.characters.lowercased() == usageKey { return key.isRepeat ? .swallow : .cycleUsage }
        if keys.enabled, listing, !key.editing, key.characters.lowercased() == sendKey { return key.isRepeat ? .swallow : .sendSelection }
        guard listing, !key.editing, !key.shift else { return nil }
        if key.characters == upArrow { return .moveSelection(-1) }
        if key.characters == downArrow { return .moveSelection(1) }
        return isReturn ? .openSelection : nil
    }

    /// The one card a card key acts on: what the owner sees (P351), never another card behind it, so a key the card it
    /// lands on cannot take (a read-only card, or one of another kind) does nothing.
    /// - A card on show: that card, as drawn (`drawn`, the card layer's), so a key never reaches the request that took its
    ///   place before the island has drawn it (P172); the keys' row, whatever it is, does not count over a card.
    /// - Over the list, a row the keys rest on (`selected`, the ring, P321) among the rows the list shows: that row's
    ///   card, and nothing when it has none (a running row).
    /// - Over the list with none: the first waiting row the list shows (its top "!" or "?"), never one behind "Show N
    ///   more" (`showAll`: every row shows), which the owner cannot see (P173).
    @MainActor static func targetCard(presentation: IslandPresentation, sessions: any SessionsModel, showAll: Bool = false,
                                      drawn: SessionCard? = nil, selected: String? = nil) -> SessionCard? {
        if case let .card(id) = presentation {
            if let drawn, drawn.sessionID == id { return drawn }
            return sessions.card(for: id)
        }
        // Detailed's Codex group lists only sessions the rows hide; `shown` is the same in either style. A folded session is
        // not among them: its conversation card says it waits, and its own card shows the request (P1307).
        let shown = IslandListLayout.make(rows: sessions.rows, style: .clean, showAll: showAll, now: sessions.now).shown
        if let selected, shown.contains(where: { $0.id == selected }) { return sessions.card(for: selected) }
        return shown.first { $0.bucket == .needsYou }.flatMap { sessions.card(for: $0.id) }
    }
}

/// U over the island's list (P461): the batteries in the order the usage block draws them, Claude's row then Codex's,
/// the accounts in use first under In use (P812). Pure, so the order and the wrap are tested without a panel.
enum UsageCycle {
    @MainActor static func order(_ usage: any UsageModel, inUse: AccountsInUse = .none, first: UsageFirst = .next) -> [String] {
        IslandUsageRows.rows(usage, inUse: inUse, first: first).flatMap { $0.batteries.map(\.id) }
    }

    /// The battery after `current` (the one the pointer or the key rests on); the first when nothing, or no battery
    /// the block still draws, is; nil after the last, so the next U starts again from nothing.
    static func next(after current: HoverTargetID?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard case let .account(id)? = current, let index = ids.firstIndex(of: id) else { return ids.first }
        return index + 1 < ids.count ? ids[index + 1] : nil
    }
}
