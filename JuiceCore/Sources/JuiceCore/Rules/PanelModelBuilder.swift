import Foundation

/// One battery's account: a profile folder (standalone Juice, the demo and the mirror), or a login (Juice Island's
/// readers, `LoginsStore`).
public struct PanelEntry: Sendable, Equatable {
    public var id: String
    public var alias: String
    public var provider: Provider

    public init(id: String, alias: String, provider: Provider) {
        self.id = id
        self.alias = alias
        self.provider = provider
    }
}

public enum PanelModelBuilder {
    /// Batteries for the monitored folders, one per login (`AccountIdentity.uniqueAccounts`).
    public static func build(accounts: [Account], records: [String: AccountRecord], signingIn: Set<String>,
                             money: [MoneyRowModel], now: Date, history: UsageHistory = .empty) -> PanelModel {
        let entries = Provider.allCases.flatMap { provider in
            AccountIdentity.uniqueAccounts(accounts.filter { $0.provider == provider && $0.monitored }, records: records)
                .map { PanelEntry(id: $0.id, alias: $0.alias, provider: $0.provider) }
        }
        return build(entries: entries, records: records, signingIn: signingIn, money: money, now: now, history: history)
    }

    /// Batteries for `entries`, in their order within each provider. `attention` raises the sign-in badge whatever the
    /// batteries say (a signed-out folder that no battery stands for). `history` (by the entries' ids) gives an available
    /// battery its run-out, when a window runs out before its reset at the current pace (P125).
    public static func build(entries: [PanelEntry], records: [String: AccountRecord], signingIn: Set<String>, attention: Bool = false,
                             money: [MoneyRowModel], now: Date, history: UsageHistory = .empty) -> PanelModel {
        var rows: [ProviderRowModel] = []
        var attention = attention
        for provider in Provider.allCases {
            let group = entries.filter { $0.provider == provider }
            guard !group.isEmpty else { continue }
            var states: [String: AccountState] = [:]
            for entry in group {
                states[entry.id] = state(of: entry.id, records: records, signingIn: signingIn, provider: provider, now: now)
            }
            let next = group.first { (states[$0.id] ?? .unknown).isAvailable }
            let availability = Rules.availability(states: group.map { states[$0.id] ?? .unknown })
            let batteries = group.map { entry -> BatteryModel in
                let state = states[entry.id] ?? .unknown
                if state == .signInNeeded { attention = true }
                // A window past its reset runs out of nothing (P460).
                let runOut = state.isAvailable
                    ? records[entry.id]?.lastGood.flatMap { UsageForecast.runOut($0, account: entry.id, history: history) }
                        .flatMap { $0.resetsAt > now ? $0 : nil } : nil
                return BatteryModel(id: entry.id, alias: entry.alias, state: state, isNext: entry.id == next?.id,
                                    hoverLabel: batteryLabel(alias: entry.alias, state: state, record: records[entry.id], now: now,
                                                             runOut: runOut),
                                    runOut: runOut)
            }
            let oldest = group.compactMap { records[$0.id]?.lastGood?.readAt }.min().map { Formatting.age(of: $0, now: now) }
            rows.append(ProviderRowModel(provider: provider, batteries: batteries, availability: availability, nextAlias: next?.alias,
                                         oldestReadingAge: oldest,
                                         hoverLabel: providerLabel(provider: provider, availability: availability, nextAlias: next?.alias, oldestAge: oldest)))
        }
        return PanelModel(rows: rows, money: money, attentionNeeded: attention)
    }

    /// One account's battery state from its record (`Rules.state`).
    public static func state(of id: String, records: [String: AccountRecord], signingIn: Set<String>, provider: Provider, now: Date) -> AccountState {
        let record = records[id]
        return Rules.state(reading: record?.lastGood, lastError: record?.lastError, signingIn: signingIn.contains(id), provider: provider,
                           now: now, restored: record?.restored == true, noPlan: record?.isNoPlan == true,
                           usageBased: record?.isNoLimits == true)
    }

    /// Spec §2.5, battery column. Windows that do not count toward the battery are appended by name, then a Codex
    /// account's credits and reset credits (#22), only in the states that show usage and its read age; sign-in needed
    /// and signing in have no current reading to show. A run-out (P125) follows the window it is about.
    public static func batteryLabel(alias: String, state: AccountState, record: AccountRecord?, now: Date, runOut: RunOut? = nil) -> String {
        let label = countedBatteryLabel(alias: alias, state: state, record: record, now: now, runOut: runOut)
        switch state {
        case .available, .usedUp, .stale: break
        case .signInNeeded, .signingIn, .unknown, .noPlan, .noLimits: return label
        }
        let current = record?.lastGood.map { Rules.current($0, now: now) }
        let extra = (current?.windows ?? []).filter { !$0.isCounted }.map { "\($0.displayLabel) \($0.percentLeft)% left" }
        return ([label] + extra + (record?.lastGood.map(creditParts) ?? [])).joined(separator: " · ")
    }

    /// "579 credits", "2 reset credits, first until 3 Oct": what a Codex reading says beyond its windows, when it has any.
    public static func creditParts(_ reading: AccountReading) -> [String] {
        var parts: [String] = []
        if let balance = reading.creditsBalance, balance >= 1 {
            let whole = Int(balance.rounded(.down))
            parts.append(MoneyRules.grouped(whole) + (whole == 1 ? " credit" : " credits"))
        }
        if let count = reading.resetCredits, count > 0 {
            var text = count == 1 ? "1 reset credit" : "\(count) reset credits"
            if let expires = reading.resetCreditExpires {
                text += (count == 1 ? " until " : ", first until ") + dayMonth(expires)
            }
            parts.append(text)
        }
        return parts
    }

    /// "3 Oct", on this Mac's calendar.
    static func dayMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    /// The reading as it stands at `now` (`Rules.current`, P460): a window past its reset is full, and named so ("reset",
    /// or "5h reset" beside another window's percent) until the next read, which the label awaits ("reading…") in place
    /// of the old read's age while the reading is fresh.
    static func countedBatteryLabel(alias: String, state: AccountState, record: AccountRecord?, now: Date, runOut: RunOut? = nil) -> String {
        let reading = record?.lastGood.map { Rules.current($0, now: now) }
        let tightest = reading.map(Rules.countedWindows)?.min { $0.percentLeft < $1.percentLeft }
        let read = reading.map { "read " + Formatting.age(of: $0.readAt, now: now) }
        let reset = resetPart(reading, tightest: tightest, now: now)
        switch state {
        case .available(let percentLeft, _):
            guard let tightest, let read else { return "\(alias) · \(percentLeft)% left" }
            let out = runOut.map { UsageForecast.part($0, namedWindow: tightest.displayLabel, now: now) }
            let resets = Rules.hasReset(tightest, now: now) ? [] : ["resets " + Formatting.refillPhrase(tightest.resetsAt, now: now)]
            let tail = reset.map { [$0, Rules.readingWord] } ?? [read]
            return ([alias, "\(percentLeft)% left, \(tightest.displayLabel)"] + [out].compactMap { $0 } + resets + tail)
                .joined(separator: " · ")
        case .usedUp(let refill):
            let window = tightest?.displayLabel ?? "window"
            return [alias, "0% left, \(window)", "back " + Formatting.refillPhrase(refill, now: now), read ?? "read ?"].joined(separator: " · ")
        case .stale(let last):
            let percent = last.map { "\($0)% left" } ?? "?"
            // A full battery whose window reset since the read is not what the last read said.
            let said = tightest.map { Rules.hasReset($0, now: now) } == true ? percent : "last \(percent)"
            return ([alias, "\(said), \(tightest?.displayLabel ?? "?")"] + [reset].compactMap { $0 } + [read ?? "read ?"])
                .joined(separator: " · ")
        case .signInNeeded:
            return "\(alias) · sign-in needed"
        case .signingIn:
            return "\(alias) · signing in…"
        case .noPlan:
            return "\(alias) · \(NoPlanStreak.hover)"
        case .noLimits:
            return "\(alias) · \(NoPlanStreak.usageHover)"
        case .unknown:
            if let error = record?.lastError { return "\(alias) · no reading yet · \(error.shortDescription)" }
            return "\(alias) · no reading yet"
        }
    }

    /// P460: "reset" when the window the battery stands for (`tightest`) is past its reset, else the windows that are, by
    /// name ("5h reset"); nil when none is.
    public static func resetPart(_ reading: AccountReading?, tightest: UsageWindow?, now: Date) -> String? {
        guard let reading else { return nil }
        let reset = Rules.resetWindows(reading, now: now)
        guard !reset.isEmpty else { return nil }
        if let tightest, Rules.hasReset(tightest, now: now) { return Rules.resetWord }
        return reset.map(\.displayLabel).joined(separator: ", ") + " " + Rules.resetWord
    }

    /// Spec §2.5, provider mark: `Claude · 4 of 6 available · next blue-heron · oldest reading 8m ago`.
    public static func providerLabel(provider: Provider, availability: Rules.Availability, nextAlias: String?, oldestAge: String?) -> String {
        ([provider.displayName] + providerParts(availability: availability, nextAlias: nextAlias, oldestAge: oldestAge))
            .joined(separator: " · ")
    }

    /// The provider label's parts after its name, each whole: a Next login's name can hold " · " itself ("sam · Research
    /// Lab", P580), so a reader takes these from the row (`ProviderRowModel`), never by splitting the joined label (P584).
    public static func providerParts(availability: Rules.Availability, nextAlias: String?, oldestAge: String?) -> [String] {
        var parts = [availability.isKnown ? "\(availability.available) of \(availability.total) available" : "availability unknown"]
        if let nextAlias { parts.append("next \(nextAlias)") }
        if let oldestAge, availability.isKnown { parts.append("oldest reading \(oldestAge)") }
        return parts
    }
}
