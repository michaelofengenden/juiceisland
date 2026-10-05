import Foundation

/// One money row on the panel. In this plan the rows come from fixtures (demo) or are "not connected".
public struct MoneyRowModel: Sendable, Equatable, Hashable, Identifiable {
    public enum Emphasis: Sendable, Hashable { case normal, warn, attention }

    public var id: String
    public var name: String
    /// nil draws `word` instead of an amount, or two open rails where there is none.
    public var amount: String?
    /// With no amount, what the row says in its place, one or two plain words in the suffix's grey (`No access`,
    /// `Stale`, `Offline`): the source exists but cannot be read now, the hover saying why (Juice Island P1213). nil
    /// keeps the rails.
    public var word: String?
    public var suffix: String?
    /// true draws the amount in ink2 and appends `spent`.
    public var isSpent: Bool
    public var emphasis: Emphasis
    public var hoverLabel: String
    /// The suffix is a runway (RunPod's, Vast.ai's `52d`): the one suffix the island's Clean style keeps.
    public var suffixIsRunway: Bool

    public init(id: String, name: String, amount: String?, suffix: String? = nil, isSpent: Bool = false,
                emphasis: Emphasis = .normal, hoverLabel: String, suffixIsRunway: Bool = false, word: String? = nil) {
        self.id = id
        self.name = name
        self.amount = amount
        self.word = word
        self.suffix = suffix
        self.isSpent = isSpent
        self.emphasis = emphasis
        self.hoverLabel = hoverLabel
        self.suffixIsRunway = suffixIsRunway
    }

    public static let sourceNames = ["OpenRouter", "Anthropic", "OpenAI", "RunPod", "Hetzner"]

    /// The five rows when nothing is connected yet.
    public static var notConnected: [MoneyRowModel] {
        sourceNames.map { MoneyRowModel(id: $0, name: $0, amount: nil, hoverLabel: "\($0) · not connected") }
    }
}
