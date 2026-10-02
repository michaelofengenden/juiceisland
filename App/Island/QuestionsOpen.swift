import Foundation

/// Settings › Island › Questions open the island (P411). On (the default): a question, or a form, opens its card by
/// itself, as an approval does. Off: it shows only as "?" on the pill, and the island opens for it only on hover or a
/// click: the island puts it away as it does a request it folded away from (P272), so it never opens the island by
/// itself later either (a Live restart, quiet ending). An approval, a plan and a failed turn open as ever; a question
/// that comes once the switch is back on opens its card. No banner tells of a question held on the pill (P412); its
/// sound plays as Settings › Sound says, and a reminder may still come (P410).
enum QuestionsOpen {
    struct Held: Equatable, Sendable {
        /// The batch without the questions held on the pill.
        var signals: [IslandSignal]
        /// The sessions whose question is held: the island puts them away.
        var sessions: Set<String>
    }

    /// A row that waits on a question or a form: its "?" leads the pill after any "!".
    static func isQuestion(_ row: SessionRow) -> Bool { row.bucket == .needsYou && row.glyph == .ques }

    static func held(_ signals: [IslandSignal], rows: [SessionRow], opens: Bool) -> Held {
        guard !opens else { return Held(signals: signals, sessions: []) }
        let questions = Set(rows.filter(isQuestion).map(\.id))
        var held = Set<String>()
        let kept = signals.filter { signal in
            guard case let .needsYou(id) = signal, questions.contains(id) else { return true }
            held.insert(id)
            return false
        }
        return Held(signals: kept, sessions: held)
    }
}
