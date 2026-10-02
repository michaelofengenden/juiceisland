import Foundation

/// One money row on the panel. In this plan the rows come from fixtures (demo) or are "not connected".
public struct MoneyRowModel: Sendable, Equatable, Hashable, Identifiable {
    public enum Emphasis: Sendable, Hashable { case normal, warn, attention }

    public var id: String
    public var name: String
    /// nil draws two open rails instead of an amount.
    public var amount: String?
    public var suffix: String?
    /// true draws the amount in ink2 and appends `spent`.
    public var isSpent: Bool
    public var emphasis: Emphasis
    public var hoverLabel: String
    /// The suffix is a runway (RunPod's, Vast.ai's `52d`): the one suffix the island's Clean style keeps.
    public var suffixIsRunway: Bool

    public init(id: String, name: String, amount: String?, suffix: String? = nil, isSpent: Bool = false,
                emphasis: Emphasis = .normal, hoverLabel: String, suffixIsRunway: Bool = false) {
        self.id = id
        self.name = name
        self.amount = amount
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
