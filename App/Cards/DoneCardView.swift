import JuiceCore
import SwiftUI

/// The last message · a reply field only while General › Reply from completion card is on (C6) and the session's
/// terminal is known exactly (P128: a tmux pane, an iTerm session, a Ghostty terminal; never Terminal or Codex.app).
/// The reply is typed into that terminal with Return; the card then says "Sending…", "Sent", or "Not sent · Retry".
/// The header's status line says "Done" (or "Interrupted", or "Turn failed"). Owner: stream C.
///
/// In the island a finished turn's card is brief (P95): it opens by itself and folds away after a few seconds, so its
/// header is the title line alone and its message two lines, and the reply field shows only once the pointer has been
/// on the card, so a card that opened by itself holds nothing that could take the keys; once shown, the field stays
/// while the card does, so a pointer that drifts off the card but stays on the island keeps a half-typed reply, and a
/// finish never takes the place of a card whose field holds text (P96). A failed turn needs you: its card keeps its
/// status line, which says why in plain words ("Turn failed · Signed out", P132; a longer reason is its message),
/// six lines and its field. An interrupt opens no card by itself: opened from the list, an interrupted turn's card
/// keeps its status line ("Interrupted") too.
///
/// A turn that stopped on a limit or an API error says so on its status line ("Limit reached · resets 15:00", "API error
/// · overloaded", P700) and is never brief; for the account's own limit, the best other account of the provider from the
/// batteries ("lab has 71% left") and one button, "Open in lab", a new session there in this folder (P703, P704).
struct DoneCardView: View {
    let card: DoneCardModel
    var style: CardStyle = .window
    @Environment(AppEnvironment.self) private var env
    @Environment(\.cardHovered) private var cardHovered
    /// The pointer has been on the card, so its reply field shows (`SessionCardView` keys this view by its session).
    @State private var uncovered = false

    /// The brief card's message lines.
    nonisolated static let briefLines = 2

    nonisolated static func isBrief(_ card: DoneCardModel, style: CardStyle) -> Bool {
        style.isIsland && !card.failed && !card.interrupted && card.limit == nil
    }

    nonisolated static func lineLimit(_ card: DoneCardModel, style: CardStyle) -> Int? {
        isBrief(card, style: style) ? briefLines : style.isIsland ? 6 : nil
    }

    nonisolated static func showsReply(brief: Bool, setting: Bool, uncovered: Bool) -> Bool { setting && (!brief || uncovered) }

    /// The message box: the last message, or a failure's reason too long for the status line; none for a stalled turn,
    /// whose card is its row alone.
    nonisolated static func message(_ card: DoneCardModel) -> String? {
        guard !card.message.isEmpty, !card.stalled else { return nil }
        return card.failed && TurnFailure.fitsStatusLine(card.message) ? nil : card.message
    }

    var body: some View {
        let brief = Self.isBrief(card, style: style)
        let message = Self.message(card)
        let replies = card.canReply && Self.showsReply(brief: brief, setting: env.settings.replyFromCompletionCard,
                                                       uncovered: cardHovered || uncovered)
        let alternative = card.limit.flatMap { LimitAlternative.best(for: $0, logins: env.usage.logins) }
        VStack(alignment: .leading, spacing: 0) {
            if let message { DoneMessageView(text: message, lineLimit: Self.lineLimit(card, style: style)) }
            if let alternative { LimitAlternativeView(sessionID: card.sessionID, alternative: alternative, style: style) }
            if replies {
                if let send = card.send {
                    CardSendLine(state: send) { env.sessions.retry(card.sessionID) }.padding(.top, message == nil && alternative == nil ? 0 : 6)
                }
                // While a reply is on its way or went, the line alone; one that did not go keeps the field for another.
                if card.send == nil || card.send == .notSent {
                    AnswerFieldView(placeholder: "Reply to \(card.agent.displayName)…") { env.sessions.reply(card.sessionID, text: $0) }
                        .padding(.top, message == nil && alternative == nil && card.send == nil ? 0 : 8)
                }
            }
        }
        .onChange(of: cardHovered, initial: true) { _, hovered in
            if hovered, brief { uncovered = true }
        }
    }
}

extension SessionCard {
    /// A finished turn's brief card in the island (`DoneCardView`): the title line alone, two lines, no footer. A quota
    /// notice is always brief, and so is a stalled turn's notice, though its header keeps its status (`isStalled`).
    func isBrief(in style: CardStyle) -> Bool {
        switch self {
        case let .done(model): DoneCardView.isBrief(model, style: style)
        case .quota: true
        default: false
        }
    }

    /// A Done card with nothing under its header: no message (a failure's reason is on the status line), no other
    /// account to offer (`alternative`, P704) and no reply; a stalled turn's card, whose header is its row as the list
    /// draws it, status line and all (P312).
    func isHeaderOnly(replySetting: Bool, alternative: Bool = false) -> Bool {
        guard case let .done(model) = self else { return false }
        if model.stalled { return true }
        return DoneCardView.message(model) == nil && !alternative && !(replySetting && model.canReply)
    }

    /// The best other account a Done card of a session stopped on its usage limit offers (P704); nil for any other card.
    func limitAlternative(_ logins: [ProviderLogins]) -> LimitAlternative? {
        guard case let .done(model) = self, let limit = model.limit else { return nil }
        return LimitAlternative.best(for: limit, logins: logins)
    }
}

/// The other account a card offers for a usage limit (P704): "lab has 71% left" in the message's ink, then its one
/// button, "Open in lab", which opens a new terminal window in the session's folder running the agent's CLI under that
/// account, on the owner's click only (P703).
struct LimitAlternativeView: View {
    let sessionID: String
    let alternative: LimitAlternative
    let style: CardStyle
    @Environment(AppEnvironment.self) private var env
    @Environment(\.islandSize) private var islandSize
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        let size = islandSize.text(12)
        VStack(alignment: .leading, spacing: 0) {
            Text(alternative.line)
                .font(Fonts.sys(size))
                .foregroundStyle(theme.island.message)
                .lineLimit(1)
                .truncationMode(.middle)
                .cssLines(size: size, lineHeight: MessageTheme.lineHeight(size))
                .frame(maxWidth: .infinity, alignment: .leading)
            CardActionsRow(fills: style.buttonsFill) {
                CardActionButton(title: alternative.action,
                                 help: "A new \(alternative.provider.displayName) session in this folder, on \(alternative.name)'s account",
                                 primary: true, fills: style.buttonsFill) {
                    env.sessions.openFresh(sessionID, in: alternative)
                }
            }
        }
    }
}

extension SessionCard {
    /// A stalled turn's notice (P312): its header is the row as the list draws it, "Stalled" and what it was on.
    var isStalled: Bool {
        if case let .done(model) = self { model.stalled } else { false }
    }
}
