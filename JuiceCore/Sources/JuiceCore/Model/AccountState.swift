import Foundation

/// What one battery shows. Spec §2.2. Precedence is decided by `Rules.state`.
public enum AccountState: Sendable, Equatable, Hashable {
    case available(percentLeft: Int, isLow: Bool)
    case usedUp(refill: Date?)
    case signInNeeded
    case signingIn
    case stale(lastPercentLeft: Int?)
    case unknown
    /// A Claude login whose CLI says it has no plan limits, read so over a while (`NoPlanStreak`, P360): dimmed, never
    /// Next, never stale or retrying, never attention.
    case noPlan
    /// A Claude login billed by usage whose CLI reports no plan limits, read so over a while (P581: a Team or Enterprise
    /// organization with none, an Anthropic Console login): No plan's dimmed battery, waits and rules, in its own words
    /// ("No limits"), since nothing ended.
    case noLimits

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// No plan or No limits: no plan limits to show, never Next, never counted in a row's availability.
    public var isPlanless: Bool { self == .noPlan || self == .noLimits }
}
