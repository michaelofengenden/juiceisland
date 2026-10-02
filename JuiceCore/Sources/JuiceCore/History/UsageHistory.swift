import Foundation

/// One counted window as one reading saw it: when, how much of it was used, and when it resets.
public struct UsageSample: Sendable, Equatable {
    public var at: Date
    public var used: Double
    public var resetsAt: Date?

    public init(at: Date, used: Double, resetsAt: Date?) {
        self.at = at
        self.used = used
        self.resetsAt = resetsAt
    }
}

/// On disk a sample is `[t, used]` or `[t, used, reset]`: whole seconds and tenths of a percent, so fourteen days of
/// every account stay a few hundred kilobytes.
extension UsageSample: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        at = Date(timeIntervalSince1970: try container.decode(Double.self))
        used = try container.decode(Double.self)
        resetsAt = try container.decodeIfPresent(Double.self).map(Date.init(timeIntervalSince1970:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(at.timeIntervalSince1970.rounded())
        try container.encode((used * 10).rounded() / 10)
        if let resetsAt { try container.encode(resetsAt.timeIntervalSince1970.rounded()) }
    }
}

/// Each account's recent readings (P125): per account (a login id, or a folder id where folders are the unit) and per
/// counted window (`UsageWindow.displayLabel`: "5h", "week", "week · Opus"), the samples oldest first. It only ever
/// holds what the readings said; nothing here reads an account, so no read is added and no floor moves.
///
/// Bounded by rule, not by hope: a sample older than `keep` goes; within `fineSpan` of now samples of one window are at
/// least `fineSpacing` apart (the newest always stands for the latest reading, so a Codex account read every 15 s keeps
/// one sample per 5 minutes), and older ones at least `coarseSpacing` apart, a window's first and last samples kept
/// either way; at most `maxSamples` per window and `maxAccounts` accounts. A window is told apart from the one before
/// it by its reset time, or by its use falling back (`sameWindow`).
public struct UsageHistory: Sendable, Equatable, Codable {
    public static let keep: TimeInterval = 14 * 86_400
    public static let fineSpacing: TimeInterval = 5 * 60
    public static let fineSpan: TimeInterval = 6 * 3_600
    public static let coarseSpacing: TimeInterval = 3_600
    public static let maxSamples = 600
    public static let maxAccounts = 64
    /// Two reset times this close are one window (a vendor's reset time can move by a few seconds between reads).
    public static let resetTolerance: TimeInterval = 10 * 60
    /// Use that falls by more than this is a new window, whatever its reset time says.
    public static let resetDrop: Double = 5

    /// By account, then by window.
    public private(set) var accounts: [String: [String: [UsageSample]]]

    public init(accounts: [String: [String: [UsageSample]]] = [:]) {
        self.accounts = accounts
    }

    public static let empty = UsageHistory()

    /// Every sample held, for tests and Diagnostics.
    public var sampleCount: Int { accounts.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } }

    /// The newest sample of an account, any window.
    public func latest(_ account: String) -> Date? {
        accounts[account]?.values.compactMap(\.last?.at).max()
    }

    public func samples(_ account: String, window: String) -> [UsageSample] { accounts[account]?[window] ?? [] }

    /// Whether `newer` belongs to the same window as `older`.
    public static func sameWindow(_ older: UsageSample, _ newer: UsageSample) -> Bool {
        if newer.used + resetDrop < older.used { return false }
        guard let a = older.resetsAt, let b = newer.resetsAt else { return true }
        return abs(a.timeIntervalSince(b)) < resetTolerance
    }

    // MARK: Recording

    /// The account's samples go by `new` (P580), or join its own (P585): samples `new` already had are kept, the renamed
    /// ones added by time.
    public mutating func rename(_ old: String, to new: String) {
        guard old != new, let moved = accounts.removeValue(forKey: old) else { return }
        var windows = accounts[new] ?? [:]
        for (window, samples) in moved {
            windows[window] = (windows[window] ?? []).isEmpty ? samples : (samples + (windows[window] ?? [])).sorted { $0.at < $1.at }
        }
        accounts[new] = windows
    }

    /// Adds a reading's counted windows. A reading at a time already held replaces that sample; one earlier than the
    /// newest (the clock went back) replaces every sample after it, since the newest reading is what holds now.
    public mutating func record(_ reading: AccountReading, for account: String) {
        var windows = accounts[account] ?? [:]
        for window in Rules.countedWindows(reading) {
            let sample = UsageSample(at: reading.readAt, used: window.usedPercent, resetsAt: window.resetsAt)
            windows[window.displayLabel] = Self.appending(sample, to: windows[window.displayLabel] ?? [])
        }
        accounts[account] = windows
    }

    static func appending(_ sample: UsageSample, to samples: [UsageSample]) -> [UsageSample] {
        var list = samples
        while let last = list.last, last.at >= sample.at { list.removeLast() }
        let n = list.count
        // The newest sample stands in for the latest reading until it is `fineSpacing` past the one before it; a
        // window's first sample is never replaced.
        if n >= 2, sameWindow(list[n - 2], list[n - 1]), sameWindow(list[n - 1], sample),
           list[n - 1].at.timeIntervalSince(list[n - 2].at) < fineSpacing {
            list[n - 1] = sample
        } else {
            list.append(sample)
        }
        return list
    }

    // MARK: Bounds

    /// Drops what is older than `keep`, thins what is older than `fineSpan`, caps every window and the accounts.
    public mutating func prune(now: Date) {
        var kept: [String: [String: [UsageSample]]] = [:]
        for (account, windows) in accounts {
            var thinned: [String: [UsageSample]] = [:]
            for (window, samples) in windows {
                let list = Self.thin(samples, now: now)
                if !list.isEmpty { thinned[window] = list }
            }
            if !thinned.isEmpty { kept[account] = thinned }
        }
        if kept.count > Self.maxAccounts {
            let newest = kept.mapValues { $0.values.compactMap(\.last?.at).max() ?? .distantPast }
            let dropped = newest.sorted { $0.value > $1.value }.dropFirst(Self.maxAccounts).map(\.key)
            for account in dropped { kept[account] = nil }
        }
        accounts = kept
    }

    static func thin(_ samples: [UsageSample], now: Date) -> [UsageSample] {
        let oldest = now.addingTimeInterval(-keep)
        let fine = now.addingTimeInterval(-fineSpan)
        let recent = samples.filter { $0.at >= oldest }
        var list: [UsageSample] = []
        for (index, sample) in recent.enumerated() {
            let startsWindow = index == 0 || !sameWindow(recent[index - 1], sample)
            let endsWindow = index + 1 == recent.count || !sameWindow(sample, recent[index + 1])
            let spacing = sample.at < fine ? coarseSpacing : 0
            if startsWindow || endsWindow || spacing == 0 {
                list.append(sample)
            } else if let last = list.last, sample.at.timeIntervalSince(last.at) >= spacing {
                list.append(sample)
            }
        }
        return Array(list.suffix(maxSamples))
    }

    // MARK: The current window

    /// The samples of the window `window` is in, as a reading at `readAt` saw it, up to that reading, with the reading
    /// itself last: the history's samples, walked back while they belong to the same window.
    public func current(_ account: String, _ window: UsageWindow, readAt: Date) -> [UsageSample] {
        let now = UsageSample(at: readAt, used: window.usedPercent, resetsAt: window.resetsAt)
        var earlier = samples(account, window: window.displayLabel).filter { $0.at < readAt }
        var run = [now]
        while let last = earlier.popLast(), Self.sameWindow(last, run[run.count - 1]) { run.append(last) }
        return run.reversed()
    }
}
