import Foundation
import JuiceCore
import Observation

/// Real batteries without a second reader: standalone Juice's `accounts.json` and `readings.json` (spec §5.3, §8
/// decision 10), read only, decoded with JuiceCore's own Codable models. Folders are grouped by the account their
/// readings name (`FolderLogins`), so there is one battery per account, named as the release build names it. It never
/// writes, never starts a reader and never touches the scheduler. A poll compares the files' bytes, so Juice's atomic
/// replace is picked up like any other write. A missing or unreadable `accounts.json` leaves the header empty; a missing
/// or unreadable `readings.json` shows the accounts the folders last belonged to, with no reading yet.
/// Money has no readers yet: every source is not connected (rails).
@MainActor
@Observable
final class JuiceReadingsUsageModel: UsageModel {
    /// `~/Library/Application Support/Juice`, where standalone Juice keeps both files.
    static var defaultDirectory: URL { AccountsStore.defaultFileURL.deletingLastPathComponent() }

    private(set) var panel: PanelModel
    private(set) var now: Date
    private(set) var accounts: [Account] = []
    private(set) var logins: [ProviderLogins] = []
    /// readings.json's records by folder id, and each account's by login id.
    private(set) var records: [String: AccountRecord] = [:]
    let moneyDetails: [String: MoneyDetail] = JuiceReadingsUsageModel.notConnectedDetails
    let signingIn: Set<String> = []
    let refreshProgress: Int? = nil
    let refreshUnavailableReason: String? = "Juice's readings: standalone Juice reads them"

    /// The readings seen while mirroring, in memory only (never written): run-outs, sparklines, quota notices (P125).
    let historyStore: UsageHistoryStore
    var history: UsageHistory { historyStore.history }
    var quotaNotice: QuotaNotice? { historyStore.notice }

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var accountsBytes: Data?
    @ObservationIgnored private var readingsBytes: Data?
    @ObservationIgnored private var folderRecords: [String: AccountRecord] = [:]

    var accountsURL: URL { directory.appendingPathComponent("accounts.json") }
    var readingsURL: URL { directory.appendingPathComponent("readings.json") }

    /// `pollInterval` nil polls only when `poll()` is called (tests).
    init(directory: URL = JuiceReadingsUsageModel.defaultDirectory, pollInterval: TimeInterval? = 5,
         clock: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.clock = clock
        historyStore = UsageHistoryStore(fileURL: nil, clock: clock)
        let start = clock()
        now = start
        panel = PanelModelBuilder.build(accounts: [], records: [:], signingIn: [], money: MoneyRowModel.notConnected, now: start)
        poll(force: true)
        if let pollInterval {
            // The main run loop's timer; it stops itself once the model is gone.
            Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                MainActor.assumeIsolated { self.poll() }
            }
        }
    }

    /// Juice refreshes; this only mirrors. Re-reads the files now.
    func refreshAll() { poll() }

    /// Re-reads both files; decodes only when their bytes changed, and publishes only when the panel changed
    /// (ages and refill labels count against the clock, so a tick can change the panel with unchanged files).
    func poll(force: Bool = false) {
        let newAccounts = try? Data(contentsOf: accountsURL)
        let newReadings = try? Data(contentsOf: readingsURL)
        let changed = force || newAccounts != accountsBytes || newReadings != readingsBytes
        if changed {
            accountsBytes = newAccounts
            readingsBytes = newReadings
            let decodedAccounts = newAccounts.flatMap { try? JSONDecoder.juice.decode(AccountsStore.File.self, from: $0) }?.accounts ?? []
            folderRecords = newReadings.flatMap { try? JSONDecoder.juice.decode(ReadingsFile.self, from: $0) }?.records ?? [:]
            if decodedAccounts != accounts { accounts = decodedAccounts }
        }
        let tick = clock()
        let built = FolderLogins.build(accounts: accounts, records: folderRecords, now: tick)
        let all = built.records.merging(folderRecords) { login, _ in login }
        if all != records { records = all }
        let providers = Dictionary(built.lists.flatMap(\.logins).map { ($0.id, $0.provider) }, uniquingKeysWith: { first, _ in first })
        historyStore.observe(built.records, providers: providers)
        let panel = FolderLogins.panel(built, money: MoneyRowModel.notConnected, now: tick, history: historyStore.history)
        if changed || panel != self.panel || built.lists != logins {
            now = tick
            self.panel = panel
            logins = built.lists
        }
    }

    /// `readings.json` as `ReadingsStore` writes it (its own `File` is private); only the records are needed.
    private struct ReadingsFile: Decodable {
        var records: [String: AccountRecord]
    }

    static let notConnectedDetails: [String: MoneyDetail] = Dictionary(uniqueKeysWithValues: MoneyRowModel.sourceNames.map {
        ($0, MoneyDetail(id: $0, parts: ["not connected"], shortParts: ["not connected"], runwayHours: nil, creditLeftShare: nil,
                         keyFile: "not connected", denominator: "—", lastRead: "never", isReadable: false))
    })
}
