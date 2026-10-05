import SwiftUI

/// The one entry point for a card: its row header, then the body for the model. The window grid (C) and the island
/// (D) both draw cards only through this view. Every fact once: the title line, one short status line
/// (`CardText.status`: "Needs approval · Bash"), the content, the buttons. Owner: stream C.
/// - `.window`: a pure black card with the faintest edge (r14, padding 10 12 12), the Detailed row (agent mark and
///   age on the right), the body indented under the title.
/// - `.islandDetailed`: `.sess.lift` (padding 8, r14), the Detailed row at island sizes, the body full width.
/// - `.islandClean`: `.sess.lift.c` (padding 6 8, r12), the two-line Clean row, the body full width.
/// The island card has no background at rest and lifts (#191919, 0.5 pt #2B2B2B) under the pointer.
/// Keys (⌃A, ⌃D, ⌃⇧A, ⌃1-⌃4) show on the buttons only while ⌃ is held; they are always in the tooltips.
struct SessionCardView: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let card: SessionCard
    var style: CardStyle = .window
    /// The option drawn as selected before the pointer moves (renders use it to show the selected look).
    var highlightedOption: Int?
    @Environment(AppEnvironment.self) private var env
    @Environment(\.previewSelectedOption) private var previewOption
    /// In the live island: the header and the body come into focus on their own, the body hanging from the row that
    /// glides into the header's place. Elsewhere (the window, renders) nil, and the card is simply there.
    @Environment(\.cardReveal) private var reveal
    @Environment(\.previewCardHovered) private var previewHovered
    /// Settings › Island › Text size (P402); the standard size in the window.
    @Environment(\.islandSize) private var islandSize
    @State private var hovered = false

    var body: some View {
        // Each part reports its frame in a small modifier of its own (`CardPartReport`), so a layer that takes another
        // role (built ahead to showing, showing to leaving) re-evaluates that modifier, never this card (E4(c)).
        VStack(alignment: .leading, spacing: 0) {
            header
                .cardReveal(reveal, .cardHeader)
                .modifier(CardPartReport(part: .cardHeader))
            // A failed turn whose status line says it all, with no reply to offer, is its header alone.
            if !card.isHeaderOnly(replySetting: env.settings.replyFromCompletionCard,
                                  alternative: card.limitAlternative(env.usage.logins) != nil) {
                content.padding(style.bodyInsets)
                    .cardReveal(reveal, .cardBody)
                    .modifier(CardPartReport(part: .cardBody))
            }
        }
        // As tall as its content wherever it is placed (the island may offer more).
        .fixedSize(horizontal: false, vertical: true)
        .padding(style.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .onHover { hovered = $0 }
        .environment(\.cardHovered, style.isIsland && (hovered || previewHovered))
        .shortcutHintsWhileControlHeld()
    }

    @ViewBuilder private var header: some View {
        if case let .quota(model) = card {
            QuotaNoticeHeader(card: model)
        } else if let row = env.sessions.row(id: card.sessionID) {
            // The island shows one card at a time: one that waits says how many other requests wait after it (P130);
            // the window, which shows every session's card, those queued behind it in its own session.
            let queued = card.request?.more ?? 0
            let others = style.isIsland && card.waits
                ? env.sessions.waiting.filter { $0.id != card.sessionID }.reduce(0) { $0 + max(1, $1.waitingRequests) } : 0
            // A stalled turn's notice is its row as the list draws it, its own status line and all (P312).
            let status = card.isStalled ? nil : CardText.status(card, more: queued + others, host: row.host)
            // A brief Done card's header is the title line alone: the glyph says done.
            let brief = card.isBrief(in: style) && !card.isStalled
            Group {
                switch style {
                case .window: DetailedRowView(row: row, metrics: .window, jumpHint: jumpHint(for: row), status: status)
                case .islandDetailed:
                    DetailedRowView(row: row, metrics: DetailedRowMetrics.island.scaled(islandSize), showsStatus: !brief,
                                    jumpHint: jumpHint(for: row), status: status)
                case .islandClean: CleanRowView(row: row, oneLine: brief, jumpHint: jumpHint(for: row), cardStatus: status)
                }
            }
            .onTapGesture { env.sessions.jump(row.id) }
            .sessionMenu(row)
            JumpNoteLine(sessionID: row.id).padding(.leading, style == .window ? DetailedRowMetrics.window.leading : DetailedRowMetrics.island.leading)
        }
    }

    /// Keyed by its session: another session's card taking this one's place (the island swaps cards in place) starts
    /// afresh, so a half-typed answer or reply never moves onto it (P96).
    private var content: some View {
        Group {
            switch card {
            case let .question(model): QuestionCardView(card: model, style: style, highlightedOption: highlightedOption ?? previewOption)
            case let .approval(model): ApprovalCardView(card: model, style: style)
            case let .plan(model): PlanCardView(card: model, style: style)
            case let .done(model): DoneCardView(card: model, style: style)
            case let .quota(model): QuotaNoticeBody(card: model)
            }
        }
        .id(card.sessionID)
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: style.radius)
        switch style {
        case .window:
            WindowCardGround(id: card.sessionID, radius: style.radius)
        case .islandClean, .islandDetailed:
            if hovered || previewHovered {
                shape.fill(palette.rowHover).overlay(shape.strokeBorder(palette.rowHoverStroke, lineWidth: 0.5))
            }
        }
    }

    private func jumpHint(for row: SessionRow) -> String? {
        guard SessionListLayout.jumpTargetID(env.sessions.rows) == row.id else { return nil }
        return SessionListLayout.jumpHint(enabled: Self.showsJumpHint(env.settings, problem: env.globalJump?.problem),
                                          key: env.settings.globalJumpKey)
    }

    /// The system-wide key's hint shows on the row it jumps to: only while it is on, registered (a key the system would
    /// not give us is no hint) and set to jump, not to open the island (P323), and Keyboard shortcuts are on (P1030).
    static func showsJumpHint(_ settings: AppSettings, problem: String?) -> Bool {
        settings.shortcutsEnabled && settings.globalJumpEnabled && problem == nil && settings.globalKeyAction == .jump
    }
}

/// The live island whose channels bring a card's two parts into focus and hang the body from its gliding row
/// (`SessionCardView`). The card reads them in `IslandChannelReveal`, so a step of the choreography re-evaluates that
/// modifier, never the card's views (P102). A card `leaving` for another session's reads the leaving layer's channels
/// and rides no row: the same modifier, so the card's views stay as they are when it moves there (P133). The role is the
/// island's (`IslandCardLayer.role`), read only in the small modifiers that draw a part, report it or gate the layer
/// (`IslandCardPartReveal`, `IslandCardRole`, `IslandCardGate`): this value stays the same for the layer's life, so a
/// change of role never reaches the card's own views (E4(c)).
struct CardReveal: Equatable, Sendable {
    /// Where a card layer's card is in its life: showing (or about to), built ahead of showing (out of focus), or
    /// leaving for another session's card.
    enum Role: Equatable, Sendable { case live, ahead, leaving }

    let ui: IslandUIState
    /// The layer's session.
    let id: String

    /// The layer's role now, from the island's cards: read it only where a part is drawn, reported or gated.
    @MainActor var role: Role { IslandCardLayer.role(of: id, card: ui.card, leaving: ui.leavingCard) }

    /// The channel a card part reads in `role`: its own, none (a part the choreography never brings in), or the leaving
    /// layer's.
    static func part(_ part: PartID, role: Role) -> PartID {
        switch role {
        case .live: part
        case .ahead: .cardAhead
        case .leaving: part.leaving
        }
    }

    static func == (lhs: CardReveal, rhs: CardReveal) -> Bool { lhs.ui === rhs.ui && lhs.id == rhs.id }
}

extension View {
    /// The card's header or body (`.cardHeader`, `.cardBody`) as the live island's `reveal` has it; nil leaves it as it is.
    @ViewBuilder func cardReveal(_ reveal: CardReveal?, _ part: PartID) -> some View {
        if let reveal {
            modifier(IslandCardPartReveal(reveal: reveal, part: part))
        } else {
            self
        }
    }
}

/// A card part's focus and ride, on the channels of the layer's role, read here: the role is looked up where the part
/// is drawn. Its strings never animate (`stillText`).
struct IslandCardPartReveal: ViewModifier {
    let reveal: CardReveal
    let part: PartID

    func body(content: Content) -> some View {
        let role = reveal.role
        content
            .stillText()
            .modifier(IslandChannelReveal(ui: reveal.ui, part: CardReveal.part(part, role: role),
                                          motion: part == .cardBody && role == .live ? .ride : .none))
    }
}

/// A card part's frame, reported while its layer is the live one (`islandPartReporter`, set by the layer while it is):
/// a card built ahead or leaving reports nothing; one that takes the layer's place reports its frames then, even where
/// they are the same as before (the frame read is nil while it does not report, P133). Outside the live island there is
/// no reporter, and nothing is read.
private struct CardPartReport: ViewModifier {
    let part: PartID
    @Environment(\.islandPartReporter) private var report

    func body(content: Content) -> some View {
        let reporting = report != nil, report = report, part = part
        content
            .onGeometryChange(for: CGRect?.self) { reporting ? $0.frame(in: .named(OpenedIslandView.space)) : nil } action: { rect in
                if let rect { report?(part, rect) }
            }
            .onDisappear { report?(part, nil) }
    }
}

private struct CardRevealKey: EnvironmentKey {
    static let defaultValue: CardReveal? = nil
}

private struct IslandPartReporterKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (PartID, CGRect?) -> Void)? = nil
}

extension EnvironmentValues {
    /// nil outside the live island: the card is simply there.
    var cardReveal: CardReveal? {
        get { self[CardRevealKey.self] }
        set { self[CardRevealKey.self] = newValue }
    }

    /// Where the live island's card reports its header's and body's frames (nil once it unmounts, so the next card is
    /// never placed by this one's); nil elsewhere.
    var islandPartReporter: (@MainActor @Sendable (PartID, CGRect?) -> Void)? {
        get { self[IslandPartReporterKey.self] }
        set { self[IslandPartReporterKey.self] = newValue }
    }
}
