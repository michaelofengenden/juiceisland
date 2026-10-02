import SwiftUI

/// What the owner typed into an island card's field and has not sent (P273). The card's views go when the island folds
/// (at the fold's end the card layer is emptied), and with them the field's own text; this keeps it, so the field has
/// it again when the card shows next (a hover or a click after the island folded for another app). Keyed by the
/// card's session and the request it shows (a question by its step too) and the field, so text typed for one request
/// never shows on another's card (P96, P170). A draft goes when it is sent or emptied, and when its card is gone
/// (`prune`). The live island's only: the window's cards and renders keep their text in the field alone.
@MainActor
final class CardDrafts {
    private var texts: [String: [String: String]] = [:]

    var isEmpty: Bool { texts.isEmpty }

    /// Where a card's fields keep their drafts; nil for a card with no field (a quota notice).
    func slot(for card: SessionCard) -> CardDraftSlot? {
        Self.key(card).map { CardDraftSlot(key: $0, drafts: self) }
    }

    static func key(_ card: SessionCard) -> String? {
        switch card {
        case let .question(model): "question|\(model.sessionID)|\(model.request?.id ?? "-")|\(model.step)"
        case let .approval(model): "approval|\(model.sessionID)|\(model.request?.id ?? "-")"
        case let .plan(model): "plan|\(model.sessionID)|\(model.request?.id ?? "-")"
        case let .done(model): "done|\(model.sessionID)"
        case .quota: nil
        }
    }

    func text(_ card: String, field: String) -> String? { texts[card]?[field] }

    func keep(_ text: String, _ card: String, field: String) {
        if text.isEmpty {
            texts[card]?[field] = nil
            if texts[card]?.isEmpty == true { texts[card] = nil }
        } else {
            texts[card, default: [:]][field] = text
        }
    }

    /// Keeps only the drafts of `cards`, the cards there now.
    func prune(keeping cards: [SessionCard]) {
        guard !texts.isEmpty else { return }
        let live = Set(cards.compactMap(Self.key))
        texts = texts.filter { live.contains($0.key) }
    }
}

/// One card's drafts, handed to its fields in the environment (`cardDraftSlot`); a field is named by its placeholder.
struct CardDraftSlot: Equatable, Sendable {
    let key: String
    let drafts: CardDrafts

    @MainActor func text(for field: String) -> String? { drafts.text(key, field: field) }
    @MainActor func keep(_ text: String, for field: String) { drafts.keep(text, key, field: field) }

    static func == (a: CardDraftSlot, b: CardDraftSlot) -> Bool { a.key == b.key && a.drafts === b.drafts }
}

private struct CardDraftSlotKey: EnvironmentKey {
    static let defaultValue: CardDraftSlot? = nil
}

extension EnvironmentValues {
    /// The live island's card's drafts (`CardDrafts`); nil in the window and in renders.
    var cardDraftSlot: CardDraftSlot? {
        get { self[CardDraftSlotKey.self] }
        set { self[CardDraftSlotKey.self] = newValue }
    }
}
