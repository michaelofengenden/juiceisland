import Foundation
import JuiceCore
import Observation

/// Per provider, the accounts the owner's sessions run in (P810), by their batteries' ids, in order: the accounts of the
/// sessions that run, wait on the owner or delegate first, then of the rest, each provider's most recently active
/// first. A session's account is the login whose folders hold its profile folder (`LoginIndex`: by the folder's account
/// id, else its spelling, as Open in finds it); a session whose folder no login holds (one not added to Accounts, a
/// remote one) has none, and a login no battery draws (not monitored) is never in use. Built only from what the island
/// lists and the batteries already know: nothing is read.
struct AccountsInUse: Equatable, Sendable {
    private var ids: [Provider: [String]] = [:]

    static let none = AccountsInUse()

    init() {}

    init(_ ids: [Provider: [String]]) {
        self.ids = ids.filter { !$0.value.isEmpty }
    }

    /// `provider`'s batteries in use, the first the one the owner is on.
    func ids(_ provider: Provider) -> [String] { ids[provider] ?? [] }

    func contains(_ batteryID: String) -> Bool { ids.values.contains { $0.contains(batteryID) } }

    var isEmpty: Bool { ids.isEmpty }

    /// From `rows` (the island's, in its order) and the batteries `logins` and `panel` draw. Each account is looked up
    /// once, however many of the rows run in it, so the cost follows the accounts, not the rows.
    static func make(rows: [SessionRow], logins: [ProviderLogins], panel: PanelModel) -> AccountsInUse {
        let ranked = rows.enumerated().filter { $0.element.account != nil }.sorted { a, b in
            let (liveA, liveB) = (a.element.bucket != .done, b.element.bucket != .done)
            if liveA != liveB { return liveA }
            if a.element.updatedAt != b.element.updatedAt { return a.element.updatedAt > b.element.updatedAt }
            return a.offset < b.offset
        }
        var seen: Set<RowAccount> = []
        var indexes: [Provider: LoginIndex] = [:]
        var ids: [Provider: [String]] = [:]
        for row in ranked.map(\.element) {
            guard let account = row.account, seen.insert(account).inserted else { continue }
            var index = indexes[account.provider] ?? LoginIndex(logins.first { $0.provider == account.provider }?.logins ?? [])
            let login = index.login(holding: account.folder, accountID: account.accountID)
            indexes[account.provider] = index
            guard let login, let id = batteryID(login, provider: account.provider, panel: panel),
                  ids[account.provider]?.contains(id) != true else { continue }
            ids[account.provider, default: []].append(id)
        }
        return AccountsInUse(ids)
    }

    /// `login`'s battery: its own (a battery by login), else one of its folders' (the demo's, by folder). nil when no
    /// battery draws it.
    private static func batteryID(_ login: LoginRow, provider: Provider, panel: PanelModel) -> String? {
        let keys = Set([login.id] + login.folders.map(\.id))
        return panel.rows.first { $0.provider == provider }?.batteries.first { keys.contains($0.id) }?.id
    }

    /// `row` as the island's usage draws it: under In use, the batteries in use first, in their order, then the rest as
    /// the account list has them; under Next, as it is.
    func arranged(_ row: ProviderRowModel, first: UsageFirst) -> ProviderRowModel {
        let lead = ids(row.provider)
        guard first == .inUse, !lead.isEmpty else { return row }
        var row = row
        row.batteries = lead.compactMap { id in row.batteries.first { $0.id == id } } + row.batteries.filter { !lead.contains($0.id) }
        return row
    }
}

/// The accounts in use now, for the desktop panel's marks (P814): made again after the rows or the batteries change, and
/// published only when it differs, so the panel never redraws for a row's new status word. It runs only while the
/// panel is on: `DesktopPanelController` starts it and stops it, never inside a view's body or another observation's
/// tracking (its first make would add the rows to what that tracking follows). Stopped, it holds none and nothing runs.
@MainActor
@Observable
final class AccountsInUseWatch {
    private(set) var current = AccountsInUse.none
    @ObservationIgnored private var make: (@MainActor () -> AccountsInUse)?
    @ObservationIgnored private var generation = 0

    var isRunning: Bool { make != nil }

    init() {}

    func start(_ make: @escaping @MainActor () -> AccountsInUse) {
        guard self.make == nil else { return }
        self.make = make
        generation &+= 1
        refresh(generation)
    }

    func stop() {
        guard make != nil else { return }
        make = nil
        generation &+= 1
        if current != .none { current = .none }
    }

    private func refresh(_ generation: Int) {
        guard let make, generation == self.generation else { return }
        let fresh = withObservationTracking { make() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.refresh(generation) }
        }
        if fresh != current { current = fresh }
    }
}
