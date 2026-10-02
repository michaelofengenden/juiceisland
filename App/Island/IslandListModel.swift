import AppKit
import JuiceCore

/// What changed between two row lists that the island reacts to.
enum IslandSignal: Equatable, Sendable {
    /// A session started waiting for you (question, approval, plan): open its card.
    case needsYou(String)
    /// A session finished its turn (not an interrupt): the Done card, or Glance's green dot.
    case finished(String)
    /// A running session of the owner's went quiet past Stalled after (P312): its one quiet notice, a brief card, as
    /// When a session finishes says (under Glance, the row's Stalled word alone).
    case stalled(String)
}

enum IslandAttention {
    static func signals(old: [SessionRow], new: [SessionRow]) -> [IslandSignal] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return new.compactMap { row in
            let previous = before[row.id]
            if row.bucket == .needsYou, previous?.bucket != .needsYou || previous?.status != row.status { return .needsYou(row.id) }
            // A Claude row that waited on its subagents and turned done with no turn of its main agent in between (their
            // SubagentStop, their lapse) is no finish: only the main agent's own turn end is (P372). A Codex chat can wait
            // on its subagents inside its own turn (P212), which the rows cannot tell from a wait after it (P513), so its
            // turning done still counts here; the live engine's Done decides for the island.
            let waitedOnly = previous?.glyphState == .delegating && previous?.agent != .codex
            if row.bucket == .done, !row.isInterrupted, let previous, previous.bucket != .done, !waitedOnly { return .finished(row.id) }
            // Once per stall: the row that turned stalled since the last batch, never one found stalled (a launch, P6).
            if row.isStalled, row.tells, let previous, !previous.isStalled { return .stalled(row.id) }
            return nil
        }
    }

    /// One batch as the island hears it from `source`. From the rows, a row that turned done is a finish. From the live
    /// engine, only its Done signal is (after the 1.5 s hold, once per turn, and none while the session's own tab is in
    /// front when No alerts for focused sessions is on): the row diff's finishes are dropped, and the engine's last Done
    /// counts once, when it is newer than `seen` and its row still shows the finished turn.
    static func signals(old: [SessionRow], new: [SessionRow], source: FinishSource, seen: ReleasedFinish?) -> [IslandSignal] {
        let fromRows = signals(old: old, new: new)
        guard case let .engine(last) = source else { return fromRows }
        var signals = fromRows.filter { if case .finished = $0 { false } else { true } }
        if let last, last != seen, let row = new.first(where: { $0.id == last.sessionID }), row.bucket == .done, !row.isInterrupted {
            signals.append(.finished(last.sessionID))
        }
        return signals
    }

    enum Outcome: Equatable, Sendable {
        case openCard(String), glance
        /// The island stays closed and the pill shows nothing new: the row says it.
        case rowOnly
    }

    /// Needs-you signals always open their card; a finish opens the Done card (Card) or lights the dot (Glance); a
    /// stall's notice follows the finish setting: its brief card (Card), or under Glance, whose island stays closed,
    /// nothing but the row's Stalled word (no dot: nothing finished; no sound either way).
    static func outcome(_ signal: IslandSignal, finish: FinishBehaviour) -> Outcome {
        switch signal {
        case let .needsYou(id): .openCard(id)
        case let .finished(id): finish == .card ? .openCard(id) : .glance
        case let .stalled(id): finish == .card ? .openCard(id) : .rowOnly
        }
    }

    /// What one batch of signals asks of the island.
    struct Response: Equatable, Sendable {
        /// The card to show: the last session that needs you, else the newest finish's Done card (Card).
        var card: String?
        /// That card is a finish's Done card: it closes by itself (`IslandHoverMachine.doneCardLife`).
        var brief = false
        /// Glance: the newest finish, for the pill's dot and check.
        var glance: String?
    }

    /// Something that needs you comes before a finish. Of several finishes together only the newest shows, so they never
    /// stack; and a finish never takes the place of the card the owner is at (`cardInUse`): one that waits for you, which
    /// would then close by itself (P95), or a Done card they are replying to, whose half-typed reply would go (P96).
    /// Something new that needs you never takes the place of a card that already waits on the open island
    /// (`waitingCardShows`): the owner may be reading it, or about to click Yes, which must answer what they read. It
    /// waits its turn, and the card's "· 1 more" counts it (P130).
    static func respond(to signals: [IslandSignal], rows: [SessionRow], finish: FinishBehaviour,
                        cardInUse: Bool, waitingCardShows: Bool = false) -> Response {
        let updated = Dictionary(rows.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
        var needsYou: String?
        var newest: (id: String, at: Date)?
        var stalled: String?
        for signal in signals {
            switch signal {
            case let .needsYou(id): needsYou = id
            case let .finished(id):
                let at = updated[id] ?? .distantPast
                if newest.map({ at >= $0.at }) ?? true { newest = (id, at) }
            case let .stalled(id): stalled = stalled ?? id
            }
        }
        var response = Response()
        if let needsYou {
            if !waitingCardShows { response.card = needsYou }
        } else if let newest, outcome(.finished(newest.id), finish: finish) == .openCard(newest.id), !cardInUse {
            response.card = newest.id
            response.brief = true
        } else if let stalled, outcome(.stalled(stalled), finish: finish) == .openCard(stalled), !cardInUse {
            // After what needs you and a finish's card, and never over a card the owner is at (P96, P312).
            response.card = stalled
            response.brief = true
        }
        if let newest, outcome(.finished(newest.id), finish: finish) == .glance { response.glance = newest.id }
        return response
    }

    /// P42: a card whose question or approval is gone (answered elsewhere, disconnected) falls back to the list.
    static func validated(_ presentation: IslandPresentation, cardExists: (String) -> Bool) -> IslandPresentation {
        if case let .card(id) = presentation, !cardExists(id) { return .list }
        return presentation
    }

    /// After a card that waited is answered (here or anywhere), the open island shows the next that waits, the one that
    /// has waited longest (`SessionsModel.waiting`); nil when none remain, and the island goes back to the list, or
    /// closes with the pointer away (P97, P130). A Done card that goes shows no other card.
    static func next(after gone: String, wasWaiting: Bool, waiting: [SessionRow]) -> String? {
        guard wasWaiting else { return nil }
        return waiting.first { $0.id != gone }?.id
    }

    /// What the open island does when the card it shows (as drawn, `drawn`) is now `current`, the same session's card
    /// for another request: the one the owner saw went (answered here or anywhere) and the session's next request, or
    /// its finished turn, took its place; or a Done card became a request. A question's next step, the same request
    /// drawn again, or a Done card of a later turn change nothing.
    enum ShownCardChange: Equatable, Sendable {
        case none
        /// The request the card showed went and another session's card waits: the one that has waited longest takes the
        /// card's place, with the swap, as after an answer (P130); the session's next request waits its turn at the back.
        case next(String)
        /// The session's new card stays in the same place, as a card that has just come in: it takes no click and no card
        /// key for `IslandMotion.cardSettle`, so the second click of a double-click on Yes, or a second ⌃A, never answers
        /// it unseen (P138, P172).
        case arrives
        /// The same request, no longer answerable here: a subagent's hold ran out and its No and Yes gave way to Open and
        /// ✕ where they were (P350). It settles as a card that has just come in, so a click meant for Yes never lands on
        /// Open or ✕ (P138, P172), and nothing new opens the island.
        case settles
    }

    static func shownCardChanged(drawn: SessionCard?, current: SessionCard?, waiting: [SessionRow]) -> ShownCardChange {
        guard let drawn, let current, drawn.sessionID == current.sessionID else { return .none }
        guard drawn.request?.id != current.request?.id else {
            return drawn.isAnswerable && current.request != nil && !current.isAnswerable ? .settles : .none
        }
        if let next = next(after: drawn.sessionID, wasWaiting: drawn.request != nil, waiting: waiting) { return .next(next) }
        return .arrives
    }

    /// The engine request whose card the owner sees on the island now, for the engine (`SessionsModel.islandShows`,
    /// P350): the card as drawn (`drawn`, the card layer's), while it is the one presented and the island is open
    /// (`open`: shown in Island mode, on a display, its machine open or in its leave grace). nil otherwise: the list, a
    /// fold, Window mode, no display.
    static func requestOnScreen(open: Bool, presentation: IslandPresentation, drawn: SessionCard?) -> String? {
        guard open, case let .card(id) = presentation, let drawn, drawn.sessionID == id else { return nil }
        return drawn.request?.id
    }

    /// `requestOnScreen`'s `open`: the island is shown on a display (`visible`), its machine is open or in its leave
    /// grace, and the owner has not gone to another app. P270 keeps the island open while the pointer rests on it after
    /// ⌘Tab or a click elsewhere (`focusAway`), until the pointer leaves; the owner looks at that other app, so a
    /// subagent's hold ends at once and its card settles read-only in place (P350, P353).
    static func ownerSees(_ machine: IslandHoverMachine, visible: Bool) -> Bool {
        visible && machine.isOpen && !machine.focusAway
    }

    /// The card to build ahead while the open island rests on `shown`: the one an answer would bring in its place
    /// (`next`), so that swap builds nothing in its frame (P133); nil on a card that does not wait (a Done card, a
    /// failed turn, a quota notice), or with none behind it.
    static func buildAhead(shown: String, waits: Bool, waiting: [SessionRow]) -> String? {
        next(after: shown, wasWaiting: waits, waiting: waiting)
    }
}

/// The opened list: the first four rows (needs you, running, done), what they hide, and Detailed's Codex group (the
/// hidden Codex sessions that are active). Rows come in `SessionListLayout.displayOrder`: the active sessions first
/// (needs you, running with Codex's running chats, then done with the Codex sessions idle at the prompt, P291), then the
/// older finished ones, as the window's Needs you, Running (its Codex group in it) and Done. The footer shows while the
/// rows hide one the Codex group does not show: it counts only the active rows it hides ("Show 2 more") and reads
/// "Earlier" when it hides only older finished ones (P94); Show all still shows every row.
struct IslandListLayout: Equatable {
    var shown: [SessionRow]
    var hidden: [SessionRow]
    var codexGroup: [SessionRow]
    var total: Int
    /// The active rows the footer hides (not those Detailed's Codex group shows).
    var hiddenActive: [SessionRow] = []
    /// The rows hide one the Codex group does not show: the footer shows.
    var showsFooter: Bool { hidden.count > codexGroup.count }

    static func make(rows: [SessionRow], style: IslandStyle, showAll: Bool, now: Date,
                     visible: Int = IslandTheme.Metrics.visibleRows) -> IslandListLayout {
        let rows = SessionListLayout.displayOrder(rows, now: now)
        let limit = showAll ? rows.count : visible
        let shown = Array(rows.prefix(limit))
        let hidden = Array(rows.dropFirst(limit))
        // Detailed's group lists the active Codex sessions the rows hide; the older ones wait behind "Earlier" (P94).
        let group = style == .detailed ? hidden.filter { $0.agent == .codex && SessionActivity.isActive($0, now: now) } : []
        let hiddenActive = hidden.filter { row in
            SessionActivity.isFooterActive(row, now: now) && !group.contains { $0.id == row.id }
        }
        return IslandListLayout(shown: shown, hidden: hidden, codexGroup: group, total: rows.count, hiddenActive: hiddenActive)
    }

    var footer: IslandFooterLabel { IslandFooterLabel(hiddenActive: hiddenActive.count) }

    /// Clean footer marks for the active rows it hides: an equalizer per running session, the delegate's glyph per one
    /// whose main agent waits on its subagents (P370), a hollow dot per other (max 4); none before "Earlier".
    enum Mark: Equatable { case running(GlyphPalette.Agent), delegating(GlyphPalette.Agent), idle }
    var footerMarks: [Mark] {
        hiddenActive.prefix(4).map { row in
            guard row.bucket == .running else { return .idle }
            return row.glyphState == .delegating ? .delegating(row.agent) : .running(row.agent)
        }
    }
}

/// The footer's words, never a total of history: "Show N more" for the active rows it hides (`SessionActivity`), or
/// "Earlier" when all it hides finished longer ago. Detailed words its footer the same way.
enum IslandFooterLabel: Equatable, Sendable {
    case more(Int)
    case earlier

    init(hiddenActive: Int) {
        self = hiddenActive > 0 ? .more(hiddenActive) : .earlier
    }

    /// Under a card (Detailed), the list is hidden: the footer counts the other active sessions.
    static func underCard(_ sessionID: String, rows: [SessionRow], now: Date) -> IslandFooterLabel {
        IslandFooterLabel(hiddenActive: rows.count { $0.id != sessionID && SessionActivity.isFooterActive($0, now: now) })
    }

    var text: String {
        switch self {
        case let .more(count): "Show \(count) more"
        case .earlier: "Earlier"
        }
    }

    /// What VoiceOver reads.
    var spoken: String {
        switch self {
        case let .more(count): "Show \(count) more active \(count == 1 ? "session" : "sessions")"
        case .earlier: "Show earlier sessions"
        }
    }
}

/// Clean money on one line under the battery rows (spec §4.2, compacted): configured sources with a reading, each
/// shown whole or not at all. When the line is too narrow, sources leave in a fixed order (Hetzner, OpenAI, then from
/// the end; a runway, RunPod's or Vast.ai's, stays while it is amber or red). A source's further keys leave where its
/// first does, just before it (P149).
enum CleanMoneyLayout {
    static let dropOrder = ["Hetzner", "OpenAI", "RunPod"]
    static let itemGap: CGFloat = 14
    static let nameGap: CGFloat = 4
    static let suffixGap: CGFloat = 4

    /// Drops sources until the row fits `width`. `dropOrder` names the sources that leave first, each with all its keys
    /// (`Hetzner 2` before `Hetzner`); the others leave from the end.
    static func fit(_ items: [MoneyRowModel], width: CGFloat, dropOrder: [String], measure: (MoneyRowModel) -> CGFloat) -> [MoneyRowModel] {
        var kept = items
        func total(_ list: [MoneyRowModel]) -> CGFloat {
            list.map(measure).reduce(0, +) + CGFloat(max(0, list.count - 1)) * itemGap
        }
        let ids = items.map(\.id)
        let ranked = dropOrder.flatMap { name in ids.filter { UsageLayout.sourceName($0) == name }.reversed() }
        let order = ranked + ids.reversed().filter { !dropOrder.contains(UsageLayout.sourceName($0)) }
        for id in order where total(kept) > width {
            guard let item = kept.first(where: { $0.id == id }) else { continue }
            if item.suffixIsRunway, item.emphasis != .normal, kept.count > 1 { continue }
            kept.removeAll { $0.id == id }
        }
        while total(kept) > width, !kept.isEmpty { kept.removeLast() }
        return kept
    }

    /// The Clean item's width: name 11 pt, amount 600 12 pt tabular (a runway 11 pt after it), or the rails.
    @MainActor static func measure(_ row: MoneyRowModel) -> CGFloat {
        let name = width(row.name, NSFont.systemFont(ofSize: 11))
        let amount = row.amount.map { width($0, monospacedDigits(12, .semibold)) } ?? 28
        let suffix = showsSuffix(row) ? suffixGap + width(row.suffix ?? "", NSFont.systemFont(ofSize: 11)) : 0
        return ceil(name + nameGap + amount + suffix)
    }

    /// Only a runway keeps its suffix in Clean (RunPod's, Vast.ai's); "spent", "/mo" and "this month" live in the hover
    /// details.
    static func showsSuffix(_ row: MoneyRowModel) -> Bool { row.suffixIsRunway && row.amount != nil && row.suffix != nil }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    private static func monospacedDigits(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

/// Maps the hover reporters' ids (`BatteryView` reports the account id, `MoneyRowsView` "money:<id>", the island's
/// marks "provider:<provider>") to hover targets.
enum IslandHoverIDs {
    static func provider(_ provider: Provider) -> String { "provider:\(provider.rawValue)" }
    static func money(_ id: String) -> String { "money:\(id)" }

    static func target(_ id: String) -> HoverTargetID {
        if id.hasPrefix("money:") { return .money(String(id.dropFirst(6))) }
        if id.hasPrefix("provider:"), let provider = Provider(rawValue: String(id.dropFirst(9))) { return .provider(provider) }
        return .account(id)
    }
}
