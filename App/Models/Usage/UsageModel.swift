import Foundation
import JuiceCore
import Observation

/// What every usage surface (window header, island usage, header strip, desktop panel, Settings › Accounts and Money)
/// binds to. P34/P41: surfaces draw `panel`, which `PanelModelBuilder` builds from monitored accounts only; no view
/// computes a battery state itself.
@MainActor
protocol UsageModel: AnyObject, Observable {
    /// Batteries (Claude row, then Codex row) and the five money rows, in the panel's reading order.
    var panel: PanelModel { get }
    /// The clock the labels count against (used-up refill times, ages).
    var now: Date { get }
    /// Every profile folder in the user's order, monitored or not.
    var accounts: [Account] { get }
    /// Settings › Accounts: per provider, one row per account (the login its CLI reported), whichever folders hold it,
    /// then the folders signed out or not asked yet (`LoginList`).
    var logins: [ProviderLogins] { get }
    var records: [String: AccountRecord] { get }
    /// Details the money rows do not carry, keyed by `MoneyRowModel.id`.
    var moneyDetails: [String: MoneyDetail] { get }
    /// Ids of accounts that are signing in.
    var signingIn: Set<String> { get }
    /// "Refreshing n of 10…" while a Refresh all runs; nil otherwise.
    var refreshProgress: Int? { get }
    /// The m of "Refreshing n of m…": the reads in the running Refresh all. Defaults to the monitored accounts; the
    /// release build's readers leave out an account read too recently (P68), so theirs is the batch's own size.
    var refreshTotal: Int { get }
    /// Demo and mirror sources cannot read: Refresh all is disabled with this reason. nil when it can refresh.
    var refreshUnavailableReason: String? { get }
    func refreshAll()
    /// Refresh source (a money row's menu): reads that source now, within its floors. `canRefreshMoney` says whether
    /// this model reads money at all (the money readers' model does; demo and mirror models do not).
    func refreshMoney(_ id: String)
    func canRefreshMoney(_ id: String) -> Bool
    /// Each battery's recent readings by its id (P125): the account list's sparklines, and the run-outs `panel` carries.
    /// Empty for a model that keeps none.
    var history: UsageHistory { get }
    /// The newest quota notice (P125), which the island shows when Quota alerts is on; nil for a model that raises none.
    var quotaNotice: QuotaNotice? { get }
    /// Refresh account (a battery's menu, #12): reads that account now if its floor and any 429 pause allow, else only
    /// moves its next read up to where they end. `manualRead` says which, for the menu to say so.
    func refreshAccount(_ id: String)
    func manualRead(_ id: String) -> RefreshScheduler.ManualRead
    /// Refresh login, on a lapsed Codex login's battery or Accounts row (P1551): on the owner's click, a new window of their
    /// usual terminal running Codex in that login's folder, which refreshes the login. A model that reads nothing opens
    /// nothing.
    func refreshLogin(_ id: String)
    /// Diagnostics › Accounts: when a login's next read is due by its schedule, and whether one runs now. nil for a model
    /// that schedules nothing (the demo, Juice's readings), and while the readers wait.
    func schedule(of loginID: String) -> ReadSchedule?
    /// Diagnostics › Accounts: where a folder not placed yet stands; `.none` for a model that asks nothing.
    func question(forFolder id: String) -> FolderQuestion
}

/// A login's read as its scheduler has it (Diagnostics).
struct ReadSchedule: Equatable, Sendable {
    /// When the next read is due; nil when none is scheduled.
    var next: Date?
    /// A read of it runs now.
    var reading = false
}

/// A folder not placed yet (Diagnostics): being asked who is signed in, its question failed (asked again after its
/// backoff), its CLI not found, or nothing known.
enum FolderQuestion: Equatable, Sendable {
    case asking, unanswered, cliMissing, none
}

extension UsageModel {
    var refreshTotal: Int { accounts.filter(\.monitored).count }
    var logins: [ProviderLogins] { [] }
    /// Demo and mirror models read no money; the money readers' model (`MoneyUsageModel`) does.
    func refreshMoney(_ id: String) {}
    func canRefreshMoney(_ id: String) -> Bool { false }
    var history: UsageHistory { .empty }
    var quotaNotice: QuotaNotice? { nil }
    /// Demo and mirror models read nothing: their batteries' Refresh is `refreshUnavailableReason`.
    func refreshAccount(_ id: String) {}
    func manualRead(_ id: String) -> RefreshScheduler.ManualRead { .unavailable }
    func refreshLogin(_ id: String) {}
    func schedule(of loginID: String) -> ReadSchedule? { nil }
    func question(forFolder id: String) -> FolderQuestion { .none }

    /// A battery's sparkline (P125): its run-out window, else its tightest; nil without two readings in it.
    func sparkline(_ id: String) -> UsageSparkline? {
        guard let reading = records[id]?.lastGood else { return nil }
        return UsageSparkline.make(reading, account: id, history: history, runOut: battery(id: id)?.runOut)
    }

    func row(_ provider: Provider) -> ProviderRowModel? { panel.rows.first { $0.provider == provider } }
    var claudeRow: ProviderRowModel? { row(.claude) }
    var codexRow: ProviderRowModel? { row(.codex) }
    var allBatteries: [BatteryModel] { panel.rows.flatMap(\.batteries) }
    func account(id: String) -> Account? { accounts.first { $0.id == id } }
    func battery(id: String) -> BatteryModel? { allBatteries.first { $0.id == id } }
    /// The email of the account a battery draws (a battery's id is its login's, or in the demo its folder's); nil when
    /// no CLI has named one.
    func email(of batteryID: String) -> String? {
        logins.lazy.flatMap(\.logins).first { $0.id == batteryID || $0.folders.contains { $0.id == batteryID } }?.email
    }

    /// The money rows the owner left switched on (Settings › Money › Show).
    func shownMoney(_ settings: AppSettings) -> [MoneyRowModel] {
        panel.money.filter { row in
            MoneyAccount(rawValue: row.id).map { settings.moneyShown[$0] ?? true } ?? true
        }
    }
}

/// What a money source knows beyond its row: the hover parts, runway and the Money pane's columns.
struct MoneyDetail: Sendable, Equatable {
    var id: String
    /// Full hover parts after the name, e.g. `["$4,120 balance", "$38.20 today"]` (the row's `hoverLabel` joins them).
    var parts: [String]
    /// Clean header parts (≈190 pt slot), e.g. `["$38.20 today"]`; RunPod: burn and runway.
    var shortParts: [String]
    /// RunPod: hours of compute left. Tones the amount (amber/red) and drives `urgentMoney`.
    var runwayHours: Double?
    /// Share of a configured credit that is left (Anthropic `0.25`); nil without a real denominator.
    var creditLeftShare: Double?
    /// Settings › Money columns.
    var keyFile: String
    var denominator: String
    var lastRead: String
    var isReadable: Bool
    /// Settings › Money and Diagnostics: the status word (`Connected`, `Not available with this key`), when the next
    /// read is due, and the source's last requests (method, host, path, status). nil and empty for demo data.
    var status: String? = nil
    var nextRead: String? = nil
    var requests: [String] = []

    /// Amber under `amber` hours, red under `red` (Settings › Money › RunPod runway).
    static func tone(runwayHours: Double?, amber: Int, red: Int) -> MoneyRowModel.Emphasis {
        guard let runwayHours else { return .normal }
        if runwayHours < Double(red) { return .attention }
        if runwayHours < Double(amber) { return .warn }
        return .normal
    }

    /// The header strip's figure (prototype L917-920): unreadable, then red, amber, any runway, then the lowest share
    /// of a configured credit.
    static func urgent(_ rows: [MoneyRowModel], details: [String: MoneyDetail], amber: Int, red: Int) -> MoneyRowModel? {
        func severity(_ row: MoneyRowModel) -> Int {
            guard let detail = details[row.id] else { return 0 }
            if !detail.isReadable || row.amount == nil { return 4 }
            switch tone(runwayHours: detail.runwayHours, amber: amber, red: red) {
            case .attention: return 3
            case .warn: return 2
            case .normal: return detail.runwayHours == nil ? 0 : 1
            }
        }
        return rows.enumerated().sorted { a, b in
            let (sa, sb) = (severity(a.element), severity(b.element))
            if sa != sb { return sa > sb }
            let (la, lb) = (details[a.element.id]?.creditLeftShare ?? 2, details[b.element.id]?.creditLeftShare ?? 2)
            if la != lb { return la < lb }
            return a.offset < b.offset
        }.first?.element
    }
}
