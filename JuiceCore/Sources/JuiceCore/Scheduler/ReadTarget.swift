import Foundation

/// What `RefreshScheduler` reads: one account, with the provider its floors come from. Juice Island schedules each
/// login a CLI reported (`LoginsStore`), whichever folders hold it, so two folders signed in to the same account are
/// read once; standalone Juice schedules each profile folder (`Account.target`).
public struct ReadTarget: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var provider: Provider
    /// A target that is not monitored is never read.
    public var monitored: Bool

    public init(id: String, provider: Provider, monitored: Bool = true) {
        self.id = id
        self.provider = provider
        self.monitored = monitored
    }
}

extension Account {
    /// The folder as the scheduler's unit (standalone Juice).
    public var target: ReadTarget { ReadTarget(id: id, provider: provider, monitored: monitored) }
}
