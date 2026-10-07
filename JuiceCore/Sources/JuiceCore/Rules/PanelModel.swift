import Foundation

/// One battery on the panel.
public struct BatteryModel: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var alias: String
    public var state: AccountState
    public var isNext: Bool
    public var hoverLabel: String
    /// A counted window that runs out before its reset at the current pace (P125); only while the battery is available.
    public var runOut: RunOut?
    /// A Codex login over 8 days old whose reads still work (`Rules.loginAging`, P1553): its hover ends with the early word.
    public var loginAging: Bool

    public init(id: String, alias: String, state: AccountState, isNext: Bool, hoverLabel: String, runOut: RunOut? = nil,
                loginAging: Bool = false) {
        self.id = id
        self.alias = alias
        self.state = state
        self.isNext = isNext
        self.hoverLabel = hoverLabel
        self.runOut = runOut
        self.loginAging = loginAging
    }
}

/// One provider row: the mark and its batteries in the user's order.
public struct ProviderRowModel: Sendable, Equatable, Identifiable {
    public var provider: Provider
    public var batteries: [BatteryModel]
    public var availability: Rules.Availability
    public var nextAlias: String?
    public var oldestReadingAge: String?
    public var hoverLabel: String

    public var id: String { provider.rawValue }

    /// `hoverLabel`'s parts after the provider's name, each whole (P584: the Next login's name can hold " · ").
    public var labelParts: [String] {
        PanelModelBuilder.providerParts(availability: availability, nextAlias: nextAlias, oldestAge: oldestReadingAge)
    }

    public init(provider: Provider, batteries: [BatteryModel], availability: Rules.Availability, nextAlias: String?, oldestReadingAge: String?, hoverLabel: String) {
        self.provider = provider
        self.batteries = batteries
        self.availability = availability
        self.nextAlias = nextAlias
        self.oldestReadingAge = oldestReadingAge
        self.hoverLabel = hoverLabel
    }
}

/// Everything the panel draws. Built by `PanelModelBuilder`, never by views.
public struct PanelModel: Sendable, Equatable {
    public var rows: [ProviderRowModel]
    public var money: [MoneyRowModel]
    /// True when any battery needs a sign-in: drives the menu bar badge (spec §2.7).
    public var attentionNeeded: Bool

    public init(rows: [ProviderRowModel], money: [MoneyRowModel], attentionNeeded: Bool) {
        self.rows = rows
        self.money = money
        self.attentionNeeded = attentionNeeded
    }

    public static let empty = PanelModel(rows: [], money: MoneyRowModel.notConnected, attentionNeeded: false)
}
