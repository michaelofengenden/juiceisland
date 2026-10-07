import Foundation
import JuiceCore
import Observation

/// The money readers in the app (Juice Island spec §3.9): `MoneyScheduler` → readers → `MoneyHTTPClient`, with the
/// records saved between launches (never a key). One account per key: each source's first key, and the further keys
/// found beside it (`~/.config/openrouter/key-2`). Rows and details are built from the records and Settings on each
/// read of `rows`/`details`, so a threshold, credit or label change shows at once. Unconfigured accounts have no row.
/// Renders and tests never start it; `AppEnvironment.app` does, only while the usage source reads real data. Only the
/// release build reads (spec §5.3); a dev build's model is a read-only mirror of the release build's `money.json`: it
/// never starts a reader, opens or writes a key file or sends a request, and never writes the file. Settings › Money's
/// Add key, Replace and Remove go through the release build's model (`saveKey`, `removeKey`).
@MainActor
@Observable
final class LiveMoneyModel {
    private(set) var records: [MoneyAccount: MoneySourceRecord]
    /// The clock the ages count against; moved on every update and every 30 s.
    private(set) var now: Date
    /// Diagnostics › Money: the newest requests first (method, host, path, status).
    private(set) var requests: [MoneyRequestRecord] = []
    /// Each account's key file (`~` form) as the next read finds it: the picked file, or the first one under
    /// `~/.config/<provider>/`. Only whether a file is there is checked; nothing is opened (Settings › Money).
    private(set) var keyFiles: [MoneyAccount: String] = [:]
    /// The accounts read: every source's first key, then each further key whose key file is there, in the panel's order.
    private(set) var accounts: [MoneyAccount] = MoneyAccount.firsts

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let client: MoneyHTTPClient
    /// The dev build's mirror: `start()` reloads the store on the clock instead of starting the scheduler.
    @ObservationIgnored let mirrorsOnly: Bool
    @ObservationIgnored private let store: MoneyStore?
    @ObservationIgnored private let home: String
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var scheduler: MoneyScheduler?
    @ObservationIgnored private var timer: Timer?
    /// The monitored accounts' folders, refused as key file locations. Set by the usage model that wraps this one.
    @ObservationIgnored var accountFolders: @MainActor () -> [String] = { [] }

    init(settings: AppSettings, client: MoneyHTTPClient, store: MoneyStore?, home: String = NSHomeDirectory(),
         clock: @escaping @Sendable () -> Date = { Date() }, mirrorsOnly: Bool = false) {
        self.settings = settings
        self.client = client
        self.mirrorsOnly = mirrorsOnly
        self.store = store
        self.home = home
        self.clock = clock
        records = store?.load() ?? [:]
        now = clock()
        refreshKeyFiles()
        // A further key whose file went while the app was not running never leaves `accounts` here: what an earlier run
        // kept for it goes now, as it would have then.
        if editsKeys {
            for account in MoneyAccount.allCases where !account.isFirst && !accounts.contains(account) {
                settings.forgetMoney(account)
            }
        }
    }

    /// What this build does with money: the release build reads it, a dev build mirrors the release build's records,
    /// and anything else (tests, renders, a stray build) has no money model.
    enum Role: Equatable { case reads, mirrors }

    static func role(identity: AppIdentity) -> Role? {
        switch identity {
        case .production: .reads
        case .development: .mirrors
        case .other: nil
        }
    }

    /// The real client and `~/Library/Application Support/Juice Island/money.json`, per `role(identity:)`. nil for
    /// in-memory settings and in a test process, so no test and no render ever reaches a real key file or the network.
    static func app(settings: AppSettings, identity: AppIdentity = .current) -> LiveMoneyModel? {
        guard !settings.money.isEphemeral, !runningUnderTests, let role = role(identity: identity) else { return nil }
        let support = Product.supportFolder()
        return LiveMoneyModel(settings: settings, client: MoneyHTTPClient(), store: store(at: support.appendingPathComponent("money.json")),
                              mirrorsOnly: role == .mirrors)
    }

    /// The app's money.json, written as the other stores are (P113): through a `StoreWriter`, off the main thread, an
    /// account's changes within 1 s as one write. What waits is written when the readers stop and at quit (`flush`).
    static func store(at url: URL) -> MoneyStore { MoneyStore(url: url, writer: StoreWriter()) }

    static var runningUnderTests: Bool {
        let process = ProcessInfo.processInfo
        return process.processName == "xctest" || process.processName.hasPrefix("swiftpm-testing")
            || process.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    var isRunning: Bool { scheduler != nil }

    func start() {
        if mirrorsOnly { return startMirroring() }
        guard scheduler == nil else { return }
        let scheduler = MoneyScheduler(client: client, records: records, clock: clock,
                                       fence: { [weak self] in await self?.fence() ?? MoneyKeyFileGuard() },
                                       onUpdate: { [weak self] source, record in await self?.apply(source, record) })
        self.scheduler = scheduler
        let initial = settings.money.all(accounts)
        Task { await scheduler.start(settings: initial) }
        observeSettings()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        flush()
        guard let scheduler else { return }
        self.scheduler = nil
        Task { await scheduler.stop() }
    }

    /// Writes what waits for money.json now (another usage source, a quit), so the next launch finds this run's last
    /// readings and 429 pauses.
    func flush() {
        store?.writer?.flush()
    }

    /// The dev build: the release build's records now and on every tick, read only.
    private func startMirroring() {
        guard timer == nil else { return }
        reloadMirror()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated {
                self.reloadMirror()
                self.tick()
            }
        }
    }

    func reloadMirror() {
        guard mirrorsOnly, let store else { return }
        let loaded = store.load()
        if loaded != records { records = loaded }
    }

    func refresh(_ account: MoneyAccount) {
        guard let scheduler else { return }
        Task { await scheduler.refresh(account) }
    }

    func fence() -> MoneyKeyFileGuard { MoneyKeyFileGuard(home: home, accountFolders: accountFolders()) }

    func apply(_ account: MoneyAccount, _ record: MoneySourceRecord) {
        // A further key removed while its read ran is not brought back.
        guard account.isFirst || accounts.contains(account) else { return }
        records[account] = record
        tick()
        if !mirrorsOnly { store?.save(records) }
    }

    private func tick() {
        let time = clock()
        if Int(time.timeIntervalSince1970 / 30) != Int(now.timeIntervalSince1970 / 30) || time < now { now = time }
        let latest = client.recentRequests
        if latest != requests { requests = latest }
        refreshKeyFiles()
    }

    // MARK: Keys (Settings › Money)

    /// Settings › Money may add, replace and remove keys only in the build that reads money: a dev build's mirror never
    /// opens a key file, so it never writes or deletes one either.
    var editsKeys: Bool { !mirrorsOnly }

    /// Looks again for each account's key file (a file made or deleted by hand shows within 30 s), and for further
    /// keys beside each source's own. A further key found for the first time is read; one whose file went stops, with
    /// its settings and its record, but for a 429 pause still running, kept (and saved) until it ends so a key added in
    /// that place waits it out (P146).
    func refreshKeyFiles() {
        let fence = fence()
        let further = MoneySource.allCases.flatMap { MoneyKeyFile.furtherAccounts(of: $0, guard: fence) }
        let now = (MoneyAccount.firsts + further).sorted()
        let found = Dictionary(uniqueKeysWithValues: now.compactMap { account in
            MoneyKeyFile.path(for: account, picked: settings.money.source(account).keyPath, guard: fence).map { (account, $0) }
        })
        if found != keyFiles { keyFiles = found }
        var trimmed = false
        if !mirrorsOnly {
            let time = clock()
            for (account, record) in records where !now.contains(account) {
                let kept = record.pauseOnly(now: time)
                if kept != record {
                    records[account] = kept
                    trimmed = true
                }
            }
        }
        guard now != accounts else {
            if trimmed { store?.save(records) }
            return
        }
        let gone = Set(accounts).subtracting(now)
        accounts = now
        if editsKeys { gone.forEach(settings.forgetMoney) }
        if trimmed || !gone.isEmpty, !mirrorsOnly { store?.save(records) }
        if let scheduler {
            let current = settings.money.all(accounts)
            Task { await scheduler.update(settings: current) }
        }
    }

    /// The account Add another adds next for `source`, which already has a key: its first key again when that went and
    /// a further one stayed, else its first free further slot, or nil when it has every key it can.
    func nextAccount(for source: MoneySource) -> MoneyAccount? {
        let first = MoneyAccount(source)
        if keyFiles[first] == nil, accounts.contains(where: { $0.source == source && !$0.isFirst }) { return first }
        return (2...MoneyAccount.maximumSlots).map { MoneyAccount(source, slot: $0) }.first { !accounts.contains($0) }
    }

    /// Save in Settings › Money: writes `text` as the account's key file (`MoneyKeyFile.write`: 0600 in a 0700 folder;
    /// a further key beside the source's own), drops a picked file so the reads use the new one, and reads the account
    /// once, soon (`MoneyScheduler.keyChanged`). Returns why nothing was saved; a key another key of the source already
    /// is (`sameKey`) is not saved again. The text is neither kept nor logged; the pane empties its field.
    func saveKey(_ text: String, for account: MoneyAccount) -> MoneyKeyEditError? {
        guard editsKeys else { return .refused("this build does not read money") }
        let fence = fence()
        let others = accounts.filter { $0.source == account.source && $0 != account }.compactMap {
            MoneyKeyFile.path(for: $0, picked: settings.money.source($0).keyPath, guard: fence)
        }
        do throws(MoneyKeyEditError) {
            try MoneyKeyFile.write(text, for: account, notIn: others, guard: fence)
        } catch {
            return error
        }
        keyChanged(account)
        return nil
    }

    /// What Remove does for `account` (its confirmation line), or nil when it has no key file.
    func removal(for account: MoneyAccount) -> MoneyKeyRemoval? {
        MoneyKeyFile.removal(for: account, picked: settings.money.source(account).keyPath, guard: fence())
    }

    /// The key file the reads use once Remove has run, which its confirmation names: another file the lookup finds (one
    /// made by hand in a later place, Hetzner's in the hcloud folder), or nil when the account is left with no key.
    func keyAfterRemoval(for account: MoneyAccount) -> String? {
        guard let removal = removal(for: account) else { return nil }
        return MoneyKeyFile.next(after: removal.path, for: account, guard: fence())
    }

    /// Remove in Settings › Money, after its confirmation: deletes the account's own key file (or stops using a file
    /// picked elsewhere, which stays), and the account's figures go at once; a further key's row goes with them.
    func removeKey(for account: MoneyAccount) -> MoneyKeyEditError? {
        guard editsKeys else { return .refused("this build does not read money") }
        if case .delete(let path) = removal(for: account) {
            do throws(MoneyKeyEditError) {
                try MoneyKeyFile.delete(path, for: account, guard: fence())
            } catch {
                return error
            }
        }
        keyChanged(account)
        return nil
    }

    /// The key changed: the last reading was another key's, so the surfaces drop it now (the scheduler does the same
    /// and reads again), and a picked file gives way to the one the lookup finds. A further key saved for the first time
    /// starts, and one removed stops, with the list of accounts (`refreshKeyFiles`), so the scheduler is told only of an
    /// account it already reads and still does.
    private func keyChanged(_ account: MoneyAccount) {
        let known = accounts.contains(account)
        if let old = records[account] {
            records[account] = old.afterKeyChange(now: clock())
            store?.save(records)
        }
        var next = settings.money.source(account)
        next.keyPath = nil
        if settings.money.keyFiles[account] != nil { settings.money.keyFiles[account] = nil }
        refreshKeyFiles()
        if known, accounts.contains(account), let scheduler { Task { await scheduler.keyChanged(account, settings: next) } }
    }

    private func observeSettings() {
        withObservationTracking { _ = settings.money.all(accounts) } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let scheduler = self.scheduler else { return }
                let current = self.settings.money.all(self.accounts)
                await scheduler.update(settings: current)
                self.observeSettings()
            }
        }
    }

    // MARK: What the surfaces draw

    func presentations() -> [MoneyPresentation] {
        accounts.compactMap { account in
            MoneyPresentation.make(account: account, record: records[account], settings: settings.money.source(account), now: now,
                                   amber: settings.runwayAmberHours, red: settings.runwayRedHours)
        }
    }

    var rows: [MoneyRowModel] { presentations().map(\.row) }

    var details: [String: MoneyDetail] {
        Dictionary(uniqueKeysWithValues: presentations().map { presentation in
            let account = presentation.account
            let keyPath = settings.money.source(account).keyPath
            let next = records[account]?.nextReadAt.map { $0 <= now ? "now" : "in " + Formatting.duration($0.timeIntervalSince(now)) }
            let lines = requests.filter { ($0.account ?? MoneyAccount($0.source)) == account }.prefix(3).map(\.line)
            return (account.rawValue, MoneyDetail(
                id: account.rawValue, parts: presentation.parts, shortParts: presentation.shortParts, runwayHours: presentation.runwayHours,
                creditLeftShare: presentation.creditLeftShare, keyFile: records[account]?.keyFileName ?? keyPath.map(MoneyKeyFile.displayName) ?? "",
                denominator: presentation.denominator, lastRead: presentation.lastRead, isReadable: presentation.isReadable,
                status: presentation.status, nextRead: next, requests: Array(lines)))
        })
    }
}

/// Real batteries (or any usage model) with the money readers' rows in place of its own. Everything but money is the
/// base model's; Refresh all also refreshes money.
@MainActor
@Observable
final class MoneyUsageModel: UsageModel {
    let base: any UsageModel
    let money: LiveMoneyModel

    init(base: any UsageModel, money: LiveMoneyModel) {
        self.base = base
        self.money = money
        money.accountFolders = { [weak base] in base?.accounts.map(\.folder) ?? [] }
    }

    /// `base` with the money readers' rows when there are money readers (started here), else `base` as it is.
    static func wrap(_ base: any UsageModel, money: LiveMoneyModel?) -> any UsageModel {
        guard let money else { return base }
        money.start()
        return MoneyUsageModel(base: base, money: money)
    }

    var panel: PanelModel {
        var panel = base.panel
        panel.money = money.rows
        return panel
    }

    var now: Date { base.now }
    var accounts: [Account] { base.accounts }
    var logins: [ProviderLogins] { base.logins }
    var records: [String: AccountRecord] { base.records }
    var moneyDetails: [String: MoneyDetail] { money.details }
    var signingIn: Set<String> { base.signingIn }
    var refreshProgress: Int? { base.refreshProgress }
    var refreshTotal: Int { base.refreshTotal }
    var refreshUnavailableReason: String? { base.refreshUnavailableReason }
    var history: UsageHistory { base.history }
    var quotaNotice: QuotaNotice? { base.quotaNotice }
    func refreshAccount(_ id: String) { base.refreshAccount(id) }
    func manualRead(_ id: String) -> RefreshScheduler.ManualRead { base.manualRead(id) }
    func refreshLogin(_ id: String) { base.refreshLogin(id) }
    func schedule(of loginID: String) -> ReadSchedule? { base.schedule(of: loginID) }
    func question(forFolder id: String) -> FolderQuestion { base.question(forFolder: id) }

    func refreshAll() {
        base.refreshAll()
        money.accounts.forEach(money.refresh)
    }

    func refreshMoney(_ id: String) {
        guard let account = MoneyAccount(rawValue: id) else { return }
        money.refresh(account)
    }

    /// A connected account (one with a row) that is not paused by a 429.
    func canRefreshMoney(_ id: String) -> Bool {
        guard let account = MoneyAccount(rawValue: id), money.isRunning, money.rows.contains(where: { $0.id == id }) else { return false }
        if let paused = money.records[account]?.pausedUntil, paused > money.now { return false }
        return true
    }
}

extension AppEnvironment {
    /// The money readers behind `usage` while it is real data (Settings › Money's keys); nil for demo data.
    var liveMoney: LiveMoneyModel? { (usage as? MoneyUsageModel)?.money }

    /// The release build's own readers, whether or not the money readers wrap them (Settings › Accounts, quitting, a
    /// Usage source switch). nil for every other usage model.
    var liveUsage: LiveUsageModel? {
        (usage as? LiveUsageModel) ?? ((usage as? MoneyUsageModel)?.base as? LiveUsageModel)
    }
}
