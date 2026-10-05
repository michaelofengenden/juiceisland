import Foundation
import JuiceCore
import Observation

/// The fixed clock every demo model and render uses: Thursday 24 September 2026, 14:00 in Berlin.
enum DemoClock {
    static let now = Date(timeIntervalSince1970: 1_790_251_200)
}

/// Demo usage: six Claude and five Codex fictional accounts (one Codex home signed out, spec §4.6) with the
/// prototype's figures, and the five money sources. Reads nothing and writes nothing; `PanelModelBuilder` builds
/// every battery (P41).
@MainActor
@Observable
final class DemoUsageModel: UsageModel {
    /// Board levers the prototype renders (`?runway=`, `?hetzner=`), so streams can render the same states.
    enum Variant: Sendable, Equatable {
        case standard
        case runway60h
        case runway18h
        case hetznerNoKey
        /// Research's 5-hour window reset 3 minutes ago, after its last read (P460).
        case windowReset
        /// The README's shots: Main, Work and Home only, each with plenty left, and two money lines, so the shots read as
        /// a Mac in good health and not as one owner's setup (P991).
        case showcase
    }

    private(set) var panel: PanelModel
    private(set) var now: Date
    private(set) var accounts: [Account]
    /// Each folder's record, and each account's by login id (`FolderLogins`), as the other models keep them, so a row
    /// by login (Settings › Accounts, Diagnostics) finds its record.
    private(set) var records: [String: AccountRecord]
    private(set) var moneyDetails: [String: MoneyDetail]
    private(set) var signingIn: Set<String> = []
    private(set) var refreshProgress: Int?
    let refreshUnavailableReason: String? = "Demo data: nothing is read"
    /// The demo's readings over the current windows (P125): Lab and Team burn fast enough to run out before they reset.
    let history: UsageHistory
    var variant: Variant { didSet { rebuild() } }

    init(now: Date = DemoClock.now, variant: Variant = .standard) {
        let accounts = DemoUsageData.accounts.map { account in
            var account = account
            if variant == .showcase { account.monitored = DemoUsageData.showcase.contains(account.alias) }
            return account
        }
        let records = DemoUsageData.records(now: now, resetPassed: variant == .windowReset)
        let money = DemoUsageData.money(variant: variant)
        self.now = now
        self.variant = variant
        self.accounts = accounts
        self.records = records.merging(FolderLogins.build(accounts: accounts, records: records, now: now, knownEmails: true).records) { folder, _ in folder }
        history = DemoUsageData.history(records: records, now: now)
        moneyDetails = Dictionary(uniqueKeysWithValues: money.map { ($0.detail.id, $0.detail) })
        panel = PanelModelBuilder.build(accounts: accounts, records: records, signingIn: [], money: money.map(\.row), now: now,
                                        history: history)
    }

    func refreshAll() {}

    /// Settings › Accounts: the demo folders by account (`FolderLogins`), each with the demo's plan name.
    var logins: [ProviderLogins] {
        FolderLogins.build(accounts: accounts, records: records, now: now, knownEmails: true).lists.map { list in
            var list = list
            list.logins = list.logins.map { row in
                var row = row
                if let plan = row.folders.first.flatMap({ DemoUsageData.plans[$0.alias] }) { row.plan = plan }
                return row
            }
            return list
        }
    }

    /// Settings › Accounts › Monitor: an unmonitored account leaves every surface (P34).
    func setMonitored(_ id: String, _ monitored: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].monitored = monitored
        rebuild()
    }

    private func rebuild() {
        let money = DemoUsageData.money(variant: variant)
        moneyDetails = Dictionary(uniqueKeysWithValues: money.map { ($0.detail.id, $0.detail) })
        panel = PanelModelBuilder.build(accounts: accounts, records: records, signingIn: signingIn, money: money.map(\.row), now: now,
                                        history: history)
    }
}

/// The demo figures (prototype L855-905), fictional aliases and folders only (C22).
enum DemoUsageData {
    static let accounts: [Account] = [
        Account(provider: .claude, folder: "~/.claude", alias: "Main", knownEmail: "main@example.com"),
        Account(provider: .claude, folder: "~/.claude-work", alias: "Work", knownEmail: "work@example.com"),
        Account(provider: .claude, folder: "~/.claude-research", alias: "Research", knownEmail: "research@example.com"),
        Account(provider: .claude, folder: "~/.claude-lab", alias: "Lab", knownEmail: "lab@example.com"),
        Account(provider: .claude, folder: "~/.claude-studio", alias: "Studio", knownEmail: "studio@example.com"),
        Account(provider: .claude, folder: "~/.claude-alt", alias: "Alt"),
        Account(provider: .codex, folder: "~/.codex", alias: "Home", knownEmail: "home@example.com"),
        Account(provider: .codex, folder: "~/.codex-team", alias: "Team", knownEmail: "team@example.com"),
        Account(provider: .codex, folder: "~/.codex-night", alias: "Night", knownEmail: "night@example.com"),
        Account(provider: .codex, folder: "~/.codex-spare", alias: "Spare", knownEmail: "spare@example.com"),
        Account(provider: .codex, folder: "~/.codex-edge", alias: "Edge"),
    ]

    /// The accounts the README's shots show (`Variant.showcase`).
    static let showcase: Set<String> = ["Main", "Work", "Home"]

    /// Plan names as the account list shows them.
    static let plans: [String: String] = [
        "Main": "Max 20×", "Work": "Max 5×", "Research": "Max 5×", "Lab": "Pro", "Studio": "Pro", "Alt": "Pro",
        "Home": "Pro", "Team": "Plus", "Night": "Plus", "Spare": "Plus", "Edge": "Plus",
    ]

    private static func reading(_ account: Account, readAgo: TimeInterval, left: Double, resetIn: TimeInterval,
                                now: Date, plan: String) -> AccountRecord {
        let readAt = now - readAgo
        return AccountRecord(lastGood: AccountReading(accountID: account.id, readAt: readAt, plan: plan, windows: [
            UsageWindow(seconds: 18_000, usedPercent: 100 - left, resetsAt: now + resetIn),
            // The week is never tighter than the 5-hour window, so every battery shows the prototype's figure.
            UsageWindow(seconds: 604_800, usedPercent: (100 - left) / 2, resetsAt: now + 3 * 86_400),
        ]), lastAttemptAt: readAt)
    }

    /// `resetPassed`: Research's 5-hour window reset 3 minutes ago, a minute after its last read (P460).
    static func records(now: Date, resetPassed: Bool = false) -> [String: AccountRecord] {
        let a = accounts
        let minute: TimeInterval = 60
        return [
            // Claude: Main 82 (Next), Work 100, Research used up (back in 22m), Lab 37, Studio sign-in needed, Alt no reading.
            a[0].id: reading(a[0], readAgo: 1 * minute, left: 82, resetIn: 100 * minute, now: now, plan: "max"),
            a[1].id: reading(a[1], readAgo: 2 * minute, left: 100, resetIn: 5 * 3_600, now: now, plan: "max"),
            a[2].id: resetPassed ? reading(a[2], readAgo: 4 * minute, left: 0, resetIn: -3 * minute, now: now, plan: "max")
                : reading(a[2], readAgo: 2 * minute, left: 0, resetIn: 22 * minute, now: now, plan: "max"),
            a[3].id: reading(a[3], readAgo: 4 * minute, left: 37, resetIn: 125 * minute, now: now, plan: "pro"),
            a[4].id: AccountRecord(lastError: .signInRequired, lastErrorAt: now - 2 * 86_400, lastAttemptAt: now - 2 * 86_400),
            // Codex: Home 71 (Next), Team 12 (low), Night 55, Spare stale (last 60, read 3h ago), Edge signed out.
            a[6].id: reading(a[6], readAgo: 20, left: 71, resetIn: 58 * minute, now: now, plan: "pro"),
            a[7].id: reading(a[7], readAgo: 25, left: 12, resetIn: 62 * minute, now: now, plan: "plus"),
            a[8].id: reading(a[8], readAgo: 40, left: 55, resetIn: 44 * minute, now: now, plan: "plus"),
            a[9].id: reading(a[9], readAgo: 3 * 3_600, left: 60, resetIn: 30 * minute, now: now, plan: "plus"),
            a[10].id: AccountRecord(lastError: .signInRequired, lastErrorAt: now - 3_600, lastAttemptAt: now - 3_600),
        ]
    }

    /// Each reading's 5-hour window traced from its start: an even climb to where it is now, except Lab (a steep last half
    /// hour, out in about 45 minutes, before its reset in 2:05) and Team (out in about 20 minutes, before its 1:02).
    static func history(records: [String: AccountRecord], now: Date) -> UsageHistory {
        let burning: [String: Double] = ["~/.claude-lab": 22, "~/.codex-team": 16]
        var history = UsageHistory()
        for account in accounts {
            guard let reading = records[account.id]?.lastGood,
                  let window = reading.windows.first(where: { $0.seconds == 18_000 }), let reset = window.resetsAt else { continue }
            let start = reset.addingTimeInterval(-18_000)
            let span = reading.readAt.timeIntervalSince(start)
            guard span > 600 else { continue }
            let recent = burning[account.folder]
            var at = start
            while at < reading.readAt {
                let untilRead = reading.readAt.timeIntervalSince(at)
                let used: Double
                if let recent, untilRead <= 1_800 {
                    // The last half hour climbs `recent` points.
                    used = window.usedPercent - recent * untilRead / 1_800
                } else {
                    let base = window.usedPercent - (recent ?? 0)
                    used = base * at.timeIntervalSince(start) / max(1, span - (recent == nil ? 0 : 1_800))
                }
                let point = AccountReading(accountID: account.id, readAt: at, windows: [
                    UsageWindow(seconds: 18_000, usedPercent: max(0, min(100, used)), resetsAt: reset),
                ])
                history.record(point, for: account.id)
                at = at.addingTimeInterval(300)
            }
            history.record(reading, for: account.id)
        }
        return history
    }

    struct MoneySource { var row: MoneyRowModel; var detail: MoneyDetail }

    /// OpenRouter, Anthropic, OpenAI | RunPod, Hetzner: the panel's column-by-column reading order.
    static func money(variant: DemoUsageModel.Variant = .standard, amber: Int = 72, red: Int = 24) -> [MoneySource] {
        func source(_ name: String, amount: String?, suffix: String? = nil, spent: Bool = false, parts: [String],
                    short: [String], runway: Double? = nil, credit: Double? = nil, key: String, denominator: String,
                    read: String, word: String? = nil) -> MoneySource {
            let emphasis = MoneyDetail.tone(runwayHours: runway, amber: amber, red: red)
            let row = MoneyRowModel(id: name, name: name, amount: amount, suffix: suffix, isSpent: spent, emphasis: emphasis,
                                    hoverLabel: ([name] + parts).joined(separator: " · "), word: word)
            return MoneySource(row: row, detail: MoneyDetail(id: name, parts: parts, shortParts: short, runwayHours: runway,
                                                             creditLeftShare: credit, keyFile: key, denominator: denominator,
                                                             lastRead: amount == nil ? "never" : read, isReadable: amount != nil))
        }
        let runPod: MoneySource = switch variant {
        case .runway60h:
            source("RunPod", amount: "$110", suffix: "60h", parts: ["$110 balance", "$1.84/h", "about 60 hours"],
                   short: ["$1.84/h", "60 hours"], runway: 60, key: "~/.config/runpod/key", denominator: "$1.84/h", read: "2m ago")
        case .runway18h:
            source("RunPod", amount: "$33", suffix: "18h", parts: ["$33 balance", "$1.84/h", "about 18 hours"],
                   short: ["$1.84/h", "18 hours"], runway: 18, key: "~/.config/runpod/key", denominator: "$1.84/h", read: "2m ago")
        default:
            source("RunPod", amount: "$2,310", suffix: "52d", parts: ["$2,310 balance", "$1.84/h", "about 52 days"],
                   short: ["$1.84/h", "52 days"], runway: 52 * 24, key: "~/.config/runpod/key", denominator: "$1.84/h", read: "2m ago")
        }
        let hetzner: MoneySource = variant == .hetznerNoKey
            ? source("Hetzner", amount: nil, parts: ["no API token", "add one in Settings › Money"], short: ["no API token"],
                     key: "~/.config/hcloud/token", denominator: "—", read: "never", word: "No key")
            : source("Hetzner", amount: "€153", suffix: "/mo", parts: ["3 servers", "€0.21/h", "about €153 this month"],
                     short: ["this month", "3 servers"], key: "~/.config/hcloud/token", denominator: "3 servers · €0.21/h", read: "9m ago")
        let anthropic = source("Anthropic", amount: "$354", parts: ["$354 left of $1,400 since 7 Sep", "$61 today"],
                               short: ["left of $1,400", "$61 today"], credit: 0.25, key: "~/.config/anthropic/admin-key",
                               denominator: "of $1,400 · 7 Sep", read: "2m ago")
        let openAI = source("OpenAI", amount: "$212", spent: true, parts: ["$212 spent in September"], short: ["spent in September"],
                            key: "~/.config/openai/admin-key", denominator: "no credit set", read: "4m ago")
        if variant == .showcase { return [anthropic, openAI] }
        return [
            source("OpenRouter", amount: "$4,120", parts: ["$4,120 balance", "$38.20 today"], short: ["$38.20 today"],
                   key: "~/.config/openrouter/key", denominator: "balance", read: "2m ago"),
            anthropic,
            openAI,
            runPod,
            hetzner,
        ]
    }
}
