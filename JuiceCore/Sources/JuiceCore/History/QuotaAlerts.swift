import Foundation

/// A quota notice for the island (P125): an account that is nearly out, or is back.
public struct QuotaNotice: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// A counted window crossed `QuotaAlerts.lowUsed` since the last reading (or ran out at once).
        case low(window: String, percentLeft: Int, resetsAt: Date?)
        /// At the current pace a window runs out within `QuotaAlerts.soon`, before its reset.
        case runningOut(RunOut)
        /// The account was used up and is available again.
        case back(percentLeft: Int)
    }

    public var account: String
    public var provider: Provider
    public var kind: Kind
    /// The reading that raised it.
    public var at: Date

    public init(account: String, provider: Provider, kind: Kind, at: Date) {
        self.account = account
        self.provider = provider
        self.kind = kind
        self.at = at
    }

    public var id: String { "\(account)@\(Int(at.timeIntervalSince1970))" }

    /// The notice's line under the account's name and battery, which already says how much is left, and for a used-up
    /// account the wait until it refills: "5h almost out · resets in 1h 12m", "5h used up", "5h out in ~25m · resets in
    /// 1h 12m", "back".
    public func text(now: Date) -> String {
        switch kind {
        case let .low(window, left, resetsAt):
            if left <= 0 { return "\(window) used up" }
            let reset = resetsAt.map { Formatting.refillPhrase($0, now: now) }
            return ["\(window) almost out", reset.map { "resets " + $0 }].compactMap { $0 }.joined(separator: " · ")
        case let .runningOut(runOut):
            return UsageForecast.line(runOut, now: now)
        case .back:
            return "back"
        }
    }
}

/// What has been said already, so nothing is said twice (kept with the history across relaunches): one low notice per
/// window per account (the 90 % crossing and the run-out share it, whichever comes first), one back per refill, and no
/// two notices for one account within `QuotaAlerts.cooldown`.
public struct QuotaAlertState: Sendable, Equatable, Codable {
    public struct Said: Sendable, Equatable, Codable {
        public var account: String
        /// The window's name, or "back".
        public var window: String
        /// The window's reset (for "back", the refill it waited for); nil when the vendor gave none.
        public var resetsAt: Date?
        public var at: Date
    }

    public var said: [Said] = []

    public init(said: [Said] = []) {
        self.said = said
    }

    /// The notices given for `old` count for `new` (a login that took its organization's id, P580).
    public mutating func rename(_ old: String, to new: String) {
        for index in said.indices where said[index].account == old { said[index].account = new }
    }

    /// A notice of this kind was given for this window: the same reset time, or, when the vendor gave none, within `span`.
    func hasSaid(_ account: String, _ window: String, resetsAt: Date?, now: Date, span: TimeInterval) -> Bool {
        said.contains { entry in
            guard entry.account == account, entry.window == window else { return false }
            switch (entry.resetsAt, resetsAt) {
            case let (a?, b?): return abs(a.timeIntervalSince(b)) < UsageHistory.resetTolerance
            case (nil, nil): return abs(now.timeIntervalSince(entry.at)) < span
            default: return false
            }
        }
    }

    func lastSaid(_ account: String) -> Date? { said.filter { $0.account == account }.map(\.at).max() }

    /// A window's reset time as a vendor reports it can drift a few seconds a read; what was said about the window
    /// follows it, so it stays the same window however long it lasts.
    mutating func follow(_ account: String, _ window: String, resetsAt: Date?) {
        guard let resetsAt else { return }
        for index in said.indices where said[index].account == account && said[index].window == window {
            if let old = said[index].resetsAt, abs(old.timeIntervalSince(resetsAt)) < UsageHistory.resetTolerance {
                said[index].resetsAt = resetsAt
            }
        }
    }

    /// Forgets what is older than any window it could still be about.
    public mutating func prune(now: Date) {
        said.removeAll { now.timeIntervalSince($0.at) > 8 * 86_400 || $0.at > now.addingTimeInterval(86_400) }
    }
}

/// The rules (P125). Only a new reading is judged, against the one before it: a crossing seen, never a level found, so
/// a launch, a relaunch or a reading restored from disk says nothing (as P6 for sounds).
public enum QuotaAlerts {
    public static let lowUsed: Double = 90
    public static let soon: TimeInterval = 30 * 60
    public static let cooldown: TimeInterval = 10 * 60
    public static let backSpacing: TimeInterval = 3_600

    public static func evaluate(account: String, provider: Provider, previous: AccountReading, current: AccountReading,
                                runOut: RunOut?, state: inout QuotaAlertState) -> QuotaNotice? {
        let now = current.readAt
        guard current.readAt > previous.readAt else { return nil }
        for window in Rules.countedWindows(current) { state.follow(account, window.displayLabel, resetsAt: window.resetsAt) }
        if let last = state.lastSaid(account), now.timeIntervalSince(last) < cooldown, now >= last { return nil }
        // Back: it was used up and is not now.
        if Rules.isExhausted(previous), !Rules.isExhausted(current), Rules.percentLeft(current) > 0 {
            let refill = Rules.refillDate(previous)
            // Once per refill, and at most once an hour: Codex's "not allowed" can come and go within one window.
            let lately = state.said.contains { $0.account == account && $0.window == "back" && abs(now.timeIntervalSince($0.at)) < backSpacing }
            guard !lately, !state.hasSaid(account, "back", resetsAt: refill, now: now, span: backSpacing) else { return nil }
            state.said.append(.init(account: account, window: "back", resetsAt: refill, at: now))
            return QuotaNotice(account: account, provider: provider, kind: .back(percentLeft: Rules.percentLeft(current)), at: now)
        }
        // Running out soon, before the reset.
        if let runOut, runOut.at.timeIntervalSince(now) <= soon,
           !state.hasSaid(account, runOut.window, resetsAt: runOut.resetsAt, now: now, span: window(runOut.window, in: current)) {
            state.said.append(.init(account: account, window: runOut.window, resetsAt: runOut.resetsAt, at: now))
            return QuotaNotice(account: account, provider: provider, kind: .runningOut(runOut), at: now)
        }
        // A counted window crossed 90 % since the last reading.
        for window in Rules.countedWindows(current) where window.usedPercent >= lowUsed {
            let before = previous.windows.first { $0.displayLabel == window.displayLabel && $0.isCounted }
            let wasLow = before.map { old in
                UsageHistory.sameWindow(UsageSample(at: previous.readAt, used: old.usedPercent, resetsAt: old.resetsAt),
                                        UsageSample(at: now, used: window.usedPercent, resetsAt: window.resetsAt))
                    && old.usedPercent >= lowUsed
            } ?? false
            guard !wasLow, before != nil,
                  !state.hasSaid(account, window.displayLabel, resetsAt: window.resetsAt, now: now, span: Double(max(window.seconds, 18_000)))
            else { continue }
            state.said.append(.init(account: account, window: window.displayLabel, resetsAt: window.resetsAt, at: now))
            return QuotaNotice(account: account, provider: provider,
                               kind: .low(window: window.displayLabel, percentLeft: window.percentLeft, resetsAt: window.resetsAt), at: now)
        }
        return nil
    }

    private static func window(_ label: String, in reading: AccountReading) -> TimeInterval {
        Double(max(reading.windows.first { $0.displayLabel == label }?.seconds ?? 0, 18_000))
    }
}
