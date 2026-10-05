import Foundation

/// What the surfaces draw for one money source (Juice spec §2.3, §2.5, §6; Juice Island spec §7 amendments 6 and 11):
/// the row, its hover parts, the runway and credit share, and the Money pane's columns. Built from the saved record
/// and Settings with no clock of its own. A source with no key file has no presentation: it is hidden, never a
/// placeholder.
public struct MoneyPresentation: Sendable, Equatable {
    public var account: MoneyAccount
    public var source: MoneySource { account.source }
    public var row: MoneyRowModel
    /// Full hover parts after the name (`["$4,120 balance", "$38.20 today", "read 2m ago"]`).
    public var parts: [String]
    /// The Clean header's parts (at most two, no age unless staleness is the news).
    public var shortParts: [String]
    public var runwayHours: Double?
    /// The share left of a configured credit or top-up, or of a quota.
    public var creditLeftShare: Double?
    /// Settings › Money's grey measure: `balance`, `of $1,400 · 7 Sep`, `$1.84/h`, `3 servers · €0.21/h`.
    public var denominator: String
    /// `2m ago` or `never`.
    public var lastRead: String
    /// `Connected`, `Not available with this key`, `Reading…`, `Stale`, …
    public var status: String
    public var isReadable: Bool

    /// A source's first key (the account named like the source).
    public static func make(source: MoneySource, record: MoneySourceRecord?, settings: MoneySourceSettings, now: Date,
                            amber: Int, red: Int) -> MoneyPresentation? {
        make(account: MoneyAccount(source), record: record, settings: settings, now: now, amber: amber, red: red)
    }

    public static func make(account: MoneyAccount, record: MoneySourceRecord?, settings: MoneySourceSettings, now: Date,
                            amber: Int, red: Int) -> MoneyPresentation? {
        // Nothing read and nothing failed yet (a source before its first read): nothing to show.
        guard let record, record.lastGood != nil || record.lastError != nil else { return nil }
        let failure = record.isFailing ? record.lastError : nil
        if failure == .notConfigured { return nil }
        let name = settings.label.flatMap { $0.isEmpty ? nil : $0 } ?? account.defaultName
        let good = record.lastGood
        let stale = good.map { now.timeIntervalSince($0.readAt) > MoneyRules.freshness } ?? true
        let lastRead = good.map { Formatting.age(of: $0.readAt, now: now) } ?? "never"
        let readPart = good.map { "read " + Formatting.age(of: $0.readAt, now: now) }

        if let good, !stale, let figures = fresh(good.figures, settings: settings, now: now, amber: amber, red: red) {
            let parts = figures.parts + [readPart].compactMap { $0 }
            let row = MoneyRowModel(id: account.rawValue, name: name, amount: figures.amount, suffix: figures.suffix,
                                    isSpent: figures.isSpent, emphasis: figures.emphasis, hoverLabel: ([name] + parts).joined(separator: " · "),
                                    suffixIsRunway: figures.runwayHours != nil && figures.suffix != nil)
            return MoneyPresentation(account: account, row: row, parts: parts, shortParts: figures.shortParts,
                                     runwayHours: figures.runwayHours, creditLeftShare: figures.creditLeftShare,
                                     denominator: figures.denominator, lastRead: lastRead,
                                     status: failure?.statusWord(for: account.source) ?? figures.status ?? "Connected", isReadable: true)
        }

        // Rails: no key role, a failure past the freshness limit, or no reading yet. The hover says why.
        // A reading that does not reach back to a new credit date is not stale: the next read covers it.
        let reason = failure?.hoverReason ?? (good == nil || !stale ? "reading" : "stale")
        var parts = [reason]
        if let good, let last = lastFigure(good.figures, settings: settings, now: now) {
            parts.append("last " + last)
        }
        if let readPart { parts.append(readPart) }
        let status = failure?.statusWord(for: account.source) ?? (good == nil || !stale ? "Reading…" : "Stale")
        let word = failure?.rowWord ?? (good == nil || !stale ? "Reading" : "Stale")
        let row = MoneyRowModel(id: account.rawValue, name: name, amount: nil, hoverLabel: ([name] + parts).joined(separator: " · "),
                                word: word)
        return MoneyPresentation(account: account, row: row, parts: parts, shortParts: Array(parts.prefix(2)), runwayHours: nil,
                                 creditLeftShare: nil, denominator: "—", lastRead: lastRead, status: status, isReadable: false)
    }

    struct Figures {
        var amount: String
        var suffix: String?
        var isSpent = false
        var emphasis: MoneyRowModel.Emphasis = .normal
        var parts: [String]
        var shortParts: [String]
        var runwayHours: Double?
        var creditLeftShare: Double?
        var denominator: String
        /// Settings' and Diagnostics' word when the figure reads but something the source should say is missing
        /// (`Runway not read`); nil is `Connected`.
        var status: String?
    }

    static func fresh(_ figures: MoneyReading.Figures, settings: MoneySourceSettings, now: Date, amber: Int, red: Int) -> Figures? {
        switch figures {
        case .balance(let held): return balance(held, settings: settings, amber: amber, red: red)
        case .spend(let spent): return spend(spent, settings: settings, now: now)
        case .quota(let quota): return Self.quota(quota)
        }
    }

    /// A balance, toned by its runway when it burns (RunPod, Vast.ai); with no balance the key may see, the month's spend
    /// in grey (an OpenRouter key without a limit, `/credits` or a top-up).
    static func balance(_ held: BalanceFigures, settings: MoneySourceSettings, amber: Int, red: Int) -> Figures {
        func money(_ value: Double) -> String { MoneyRules.amount(value, held.currency) }
        let today = held.spentToday.map { money($0) + " today" }
        guard let balance = held.balance(topUp: settings.topUp) else {
            let month = held.spentThisMonth ?? held.spentTotal ?? 0
            return Figures(amount: money(month), isSpent: true, parts: [money(month) + " spent this month"] + [today].compactMap { $0 },
                           shortParts: ["spent this month"], denominator: "no balance with this key")
        }
        let runway = MoneyRules.runwayHours(balance: balance, burnPerHour: held.burnPerHour, stale: false)
        let gap: (word: String, part: String)? = switch held.runwayGap {
        case .notAllowed: ("No runway with this key", "no runway with this key")
        case .notRead: ("Runway not read", "runway not read")
        case nil: nil
        }
        var parts = [money(balance) + " balance"] + [today, gap?.part].compactMap { $0 }
        var short: [String] = []
        if let burn = held.burnPerHour {
            parts.append(MoneyRules.rate(burn, held.currency))
            short.append(MoneyRules.rate(burn, held.currency))
        }
        if let runway {
            parts.append(MoneyRules.runwayHover(hours: runway))
            short.append(MoneyRules.runwayHover(hours: runway).replacingOccurrences(of: "about ", with: ""))
        }
        let share = settings.topUp.flatMap { $0 > 0 ? min(1, max(0, balance / $0)) : nil }
        let measure = held.burnPerHour.map { MoneyRules.rate($0, held.currency) } ?? settings.topUp.map { "of \(money($0)) top-up" }
        return Figures(amount: money(balance), suffix: runway.map(MoneyRules.runwayLabel(hours:)),
                       emphasis: MoneyRules.runwayEmphasis(hours: runway, amber: amber, red: red), parts: parts,
                       shortParts: short.isEmpty ? [gap?.part ?? today ?? "balance"] : short, runwayHours: runway, creditLeftShare: share,
                       denominator: measure ?? "balance", status: gap?.word)
    }

    /// Spend: the month's estimate from what runs (Hetzner, `/mo`), the month so far as one total (DigitalOcean,
    /// Fireworks), or the cost reports' days: what is left of a credit since its date, else this month's spend in grey.
    static func spend(_ spent: SpendFigures, settings: MoneySourceSettings, now: Date) -> Figures? {
        func money(_ value: Double) -> String { MoneyRules.amount(value, spent.currency) }
        if spent.estimate != nil {
            let monthly = spent.monthlyEstimate
            let count = spent.serverCount
            let servers = "\(count) server\(count == 1 ? "" : "s")"
            let hourly = MoneyRules.rate(monthly / 730, spent.currency)
            return Figures(amount: money(monthly), suffix: "/mo", parts: [servers, hourly, "about \(money(monthly)) this month"],
                           shortParts: ["this month", servers], denominator: "\(servers) · \(hourly)")
        }
        let monthStart = MoneyRules.startOfMonth(now)
        let name = MoneyRules.monthName(now)
        if let total = spent.monthToDate {
            // Last month's total is not this month's: rails until the next read.
            guard spent.coveredFrom == monthStart else { return nil }
            return Figures(amount: money(total), isSpent: true, parts: ["\(money(total)) spent in \(name)"],
                           shortParts: ["spent in \(name)"], denominator: "month to date")
        }
        let today = money(spent.today(now)) + " today"
        if let credit = settings.credit {
            let since = MoneyRules.costsFrom(settings: settings, now: now)
            guard spent.coveredFrom <= since else { return nil }
            let left = credit - spent.spent(from: since)
            let date = MoneyRules.shortDate(since)
            return Figures(amount: money(left),
                           parts: ["\(money(left)) left of \(money(credit)) since \(date)", today],
                           shortParts: ["left of \(money(credit))", today],
                           creditLeftShare: credit > 0 ? min(1, max(0, left / credit)) : nil,
                           denominator: "of \(money(credit)) · \(date)")
        }
        guard spent.coveredFrom <= monthStart else { return nil }
        let month = spent.month(now)
        return Figures(amount: money(month), isSpent: true, parts: ["\(money(month)) spent in \(name)", today],
                       shortParts: ["spent in \(name)"], denominator: "no credit set")
    }

    /// A quota as the share left, like a battery (`74%`, amber under `Rules.lowThreshold` as drawn), with that it is
    /// what is left, what was used and when it resets in the hover.
    static func quota(_ quota: QuotaFigures) -> Figures {
        let left = quota.leftShare
        let percent = MoneyRules.percent(left)
        let low = (Int(percent.dropLast()) ?? 100) < Rules.lowThreshold
        var parts = ["\(percent) left", "\(MoneyRules.count(quota.used)) of \(MoneyRules.count(quota.limit)) \(quota.unit) used"]
        if let resetsAt = quota.resetsAt { parts.append("resets \(MoneyRules.shortDate(resetsAt))") }
        return Figures(amount: percent, emphasis: low ? .warn : .normal, parts: parts, shortParts: ["\(percent) left"], creditLeftShare: left,
                       denominator: "of \(MoneyRules.count(quota.limit)) \(quota.unit)")
    }

    /// The last figure for a stale or failing hover (`$4,120 balance`).
    static func lastFigure(_ figures: MoneyReading.Figures, settings: MoneySourceSettings, now: Date) -> String? {
        switch figures {
        case .balance(let held):
            return held.balance(topUp: settings.topUp).map { MoneyRules.amount($0, held.currency) + " balance" }
        case .spend(let spent):
            if spent.estimate != nil { return MoneyRules.amount(spent.monthlyEstimate, spent.currency) + "/mo" }
            if let total = spent.monthToDate {
                return spent.coveredFrom == MoneyRules.startOfMonth(now) ? MoneyRules.amount(total, spent.currency) + " spent this month" : nil
            }
            return MoneyRules.amount(spent.month(now), spent.currency) + " spent this month"
        case .quota(let quota):
            return MoneyRules.percent(quota.leftShare) + " left"
        }
    }
}
