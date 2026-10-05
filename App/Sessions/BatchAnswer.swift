import Foundation
import IslandEngine
import SwiftUI

/// Allow all and Deny all (P1031): while two or more approvals wait, one click or key answers each of them exactly as
/// its own Yes or No would, oldest first (P130), and says so in one line. They cover only approvals the island can
/// answer: never a question or a plan, never a read-only card or a notice, never one already on its way, and never an
/// agent marked Watch in Settings › Agents (the table's Watch agents, and Codex while the island does not answer it,
/// P947), even where its card could take a Yes. Each answer goes to the request its card was drawn with: one answered
/// elsewhere meanwhile, or replaced by its session's next, is left alone (P170). A press while a card it would answer
/// has just come in, from any session, is eaten (`press`, P1032): the line redraws with it in the same frame, so the
/// owner has not seen it, not even in the count.
@MainActor
enum BatchAnswer {
    /// Fewer, and there is nothing to batch: the card's own Yes and No do it.
    nonisolated static let minimum = 2

    /// The agents Allow all never covers.
    static func watchAgents(_ settings: AppSettings) -> Set<GlyphPalette.Agent> {
        var agents = Set(AgentHookTable.wave1.filter { $0.answers == .watch }.map { EngineSessionsModel.agent($0.kind) })
        if !LiveSessions.answersCodex(settings) { agents.insert(.codex) }
        return agents
    }

    static func covers(_ card: ApprovalCardModel, watch: Set<GlyphPalette.Agent>) -> Bool {
        card.isAnswerable && !card.isNotice && card.send != .sending && !watch.contains(card.agent)
    }

    /// Every approval Allow all covers now, each session's card, in the order they began to wait.
    static func targets(_ env: AppEnvironment) -> [ApprovalCardModel] {
        let watch = watchAgents(env.settings)
        return env.sessions.waiting.compactMap { row in
            guard case let .approval(card)? = env.sessions.card(for: row.id), covers(card, watch: watch) else { return nil }
            return card
        }
    }

    /// The island's: only from an approval card on show that Allow all covers, with that card as drawn (its exact request,
    /// P172); none over the list, on any other card, or while fewer than two would be answered.
    static func islandTargets(drawn: SessionCard?, env: AppEnvironment) -> [ApprovalCardModel] {
        guard case let .approval(shown)? = drawn, covers(shown, watch: watchAgents(env.settings)) else { return [] }
        let cards = targets(env).map { $0.sessionID == shown.sessionID ? shown : $0 }
        guard cards.contains(where: { $0.sessionID == shown.sessionID }), cards.count >= minimum else { return [] }
        return cards
    }

    /// True while one of `cards` began to wait less than `IslandMotion.cardSettle` ago (`SessionsModel.waitingSince`):
    /// another session's approval that came in as the owner pressed (P1032), as P138 keeps the card on show from a press.
    static func justArrived(_ cards: [ApprovalCardModel], env: AppEnvironment,
                            now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        cards.contains { card in
            guard let since = env.sessions.waitingSince(card.sessionID) else { return false }
            return now - since < IslandMotion.cardSettle
        }
    }

    /// A click on Deny all or Allow all, or their key: `answer`, unless a card it covers has just come in, when the press
    /// is eaten (nil) and nothing goes (P1032).
    @discardableResult
    static func press(_ decision: ApprovalDecision, _ cards: [ApprovalCardModel], env: AppEnvironment,
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AnswerAllNote? {
        guard !justArrived(cards, env: env, now: now) else { return nil }
        return answer(decision, cards, env: env)
    }

    /// Answers `cards` as drawn (P1032), in order, each as its own Yes (`.allowOnce`) or No (`.deny`) would; the line says
    /// how many went and how many had gone meanwhile, and shows for `AnswerAllNote.lifetime`.
    @discardableResult
    static func answer(_ decision: ApprovalDecision, _ cards: [ApprovalCardModel], env: AppEnvironment) -> AnswerAllNote {
        var answered: Set<String> = []
        var gone = 0
        for card in cards {
            guard case let .approval(now)? = env.sessions.card(for: card.sessionID), now.request?.id == card.request?.id,
                  now.isAnswerable, now.send != .sending else {
                gone += 1
                continue
            }
            env.sessions.approve(card.sessionID, decision, request: card.request?.id)
            answered.insert(key(card))
        }
        env.answeredByAll.formUnion(answered)
        let note = AnswerAllNote(text: report(decision, answered: answered.count, gone: gone))
        env.answerAllNote = note
        Task { @MainActor [weak env] in
            try? await Task.sleep(for: AnswerAllNote.lifetime)
            if env?.answerAllNote?.id == note.id { env?.answerAllNote = nil }
            env?.answeredByAll.subtract(answered)
        }
        return note
    }

    /// `waiting` less the cards Allow all or Deny all just answered and that have not gone yet: the island's next card
    /// after an answer comes from these, so it never shows one of them passing by while its answer is on its way (P1035).
    static func stillWaiting(_ waiting: [SessionRow], env: AppEnvironment) -> [SessionRow] {
        guard !env.answeredByAll.isEmpty else { return waiting }
        return waiting.filter { row in
            guard case let .approval(card)? = env.sessions.card(for: row.id) else { return true }
            return !env.answeredByAll.contains(key(card))
        }
    }

    /// A card's request, or its session for a card with no engine request behind it.
    private static func key(_ card: ApprovalCardModel) -> String { card.request?.id ?? "session:\(card.sessionID)" }

    /// "Allowed 3 approvals.", "Denied 2 approvals; 1 was already answered."
    static func report(_ decision: ApprovalDecision, answered: Int, gone: Int) -> String {
        let verb = decision == .deny ? "Denied" : "Allowed"
        let count = answered == 1 ? "1 approval" : "\(answered) approvals"
        guard gone > 0 else { return "\(verb) \(count)." }
        return "\(verb) \(count); \(gone) \(gone == 1 ? "was" : "were") already answered."
    }
}

/// Allow all's one line, under the island's header and on the window's Needs you line.
struct AnswerAllNote: Equatable, Sendable {
    var id = UUID()
    var text: String

    static let lifetime: Duration = .seconds(6)
}

/// Deny all and Allow all, small, after how many approvals they answer: under an island approval card's answers, and at
/// the end of the window's Needs you line (whose own count is every card that waits). Each answers `cards`, the approvals
/// as this view was drawn with them. The keys show while the modifier is held, as on the card's buttons.
struct AnswerAllButtons: View {
    let cards: [ApprovalCardModel]
    /// The island's card: the count at the left, the buttons at the right. The window's line: together at its end.
    var spreads = true
    @Environment(AppEnvironment.self) private var env
    @Environment(\.cardKeys) private var keys
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text("\(cards.count) approvals wait")
                .font(Fonts.sys(11))
                .foregroundStyle(theme.island.ink2)
                .lineLimit(1)
            if spreads { Spacer(minLength: 8) } else { Color.clear.frame(width: 4, height: 1) }
            CardActionButton(title: "Deny all", key: keys.hint(.denyAll), help: "No to each of the \(cards.count) approvals",
                             refuses: true, compact: true) {
                BatchAnswer.press(.deny, cards, env: env)
            }
            CardActionButton(title: "Allow all", key: keys.hint(.allowAll), help: "Yes to each of the \(cards.count) approvals",
                             compact: true) {
                BatchAnswer.press(.allowOnce, cards, env: env)
            }
        }
    }
}

/// The island card's row: only on an approval card Allow all covers, while two or more would be answered.
struct IslandAnswerAll: View {
    let card: ApprovalCardModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let cards = BatchAnswer.islandTargets(drawn: .approval(card), env: env)
        if !cards.isEmpty {
            AnswerAllButtons(cards: cards).padding(.top, 6)
        }
    }
}

/// The window's Needs you line, after its filter: Deny all and Allow all while two or more approvals wait (what the
/// window's keys answer), else Allow all's note while it shows.
struct WindowAnswerAll: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let cards = BatchAnswer.targets(env)
        if cards.count >= BatchAnswer.minimum {
            AnswerAllButtons(cards: cards, spreads: false)
        } else if let note = env.answerAllNote {
            AnswerAllNoteText(note: note)
        }
    }
}

/// The note itself: 11/18 `ink2`, one line, the whole of it on hover.
struct AnswerAllNoteText: View {
    let note: AnswerAllNote
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        Text(note.text)
            .font(Fonts.sys(11))
            .foregroundStyle(theme.island.ink2)
            .lineLimit(1).truncationMode(.tail)
            .lineBox(18)
            .help(note.text)
            .accessibilityLabel(note.text)
    }
}
