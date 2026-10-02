import Foundation

/// Spec §8.2. Pure functions; every decision the panel makes lives here.
public enum Rules {
    /// Under this many percent left a battery is amber.
    public static let lowThreshold = 15
    /// The hover's words for a window past its reset, until the next read replaces the reading (P460).
    public static let resetWord = "reset"
    public static let readingWord = "reading…"

    /// The windows that count toward the battery; the others show in the hover only.
    public static func countedWindows(_ reading: AccountReading) -> [UsageWindow] {
        reading.windows.filter(\.isCounted)
    }

    public static func percentLeft(_ reading: AccountReading) -> Int {
        countedWindows(reading).map(\.percentLeft).min() ?? 0
    }

    public static func isExhausted(_ reading: AccountReading) -> Bool {
        !reading.ordinaryUsageAllowed || countedWindows(reading).contains(where: \.isExhausted)
    }

    /// The latest reset among the blocking windows; when the vendor says "not allowed" without an exhausted window, the latest reset of all windows.
    public static func refillDate(_ reading: AccountReading) -> Date? {
        let counted = countedWindows(reading)
        let blocking = counted.filter(\.isExhausted)
        let candidates = blocking.isEmpty ? counted : blocking
        return candidates.compactMap(\.resetsAt).max()
    }

    public static func isFresh(_ reading: AccountReading, now: Date, limit: TimeInterval) -> Bool {
        now.timeIntervalSince(reading.readAt) <= limit
    }

    /// A window whose reset time has passed (P460).
    public static func hasReset(_ window: UsageWindow, now: Date) -> Bool {
        window.resetsAt.map { $0 <= now } ?? false
    }

    /// The counted windows that have reset since the reading (P460), in the reading's order.
    public static func resetWindows(_ reading: AccountReading, now: Date) -> [UsageWindow] {
        countedWindows(reading).filter { hasReset($0, now: now) }
    }

    /// The reading as it stands at `now` (P460): a window whose reset time has passed counts as refilled, its use 0 %,
    /// until the next read replaces the reading; and the vendor's "not allowed" ends once every window it could be
    /// waiting on has reset (`refillDate`). Nothing is read to make it: the stored reading, the scheduler's floors and
    /// the quota notices keep what the vendor said.
    public static func current(_ reading: AccountReading, now: Date) -> AccountReading {
        guard reading.windows.contains(where: { hasReset($0, now: now) }) else { return reading }
        var current = reading
        if !reading.ordinaryUsageAllowed, let refill = refillDate(reading), refill <= now { current.ordinaryUsageAllowed = true }
        current.windows = reading.windows.map { window in
            guard hasReset(window, now: now) else { return window }
            var refilled = window
            refilled.usedPercent = 0
            return refilled
        }
        return current
    }

    /// Precedence (spec §2.2): signing in, sign-in needed, no plan (P360; no limits when it is billed by usage, P581),
    /// unknown, stale, used up, low, available. A reading that came back with its login (`AccountRecord.restored`) is stale
    /// until the account is read again, however recent it is.
    public static func state(reading: AccountReading?, lastError: ReadError?, signingIn: Bool, provider: Provider, now: Date,
                             restored: Bool = false, noPlan: Bool = false, usageBased: Bool = false) -> AccountState {
        if signingIn { return .signingIn }
        if lastError == .signInRequired { return .signInNeeded }
        if noPlan { return usageBased ? .noLimits : .noPlan }
        guard let reading else { return .unknown }
        // The reading as it stands now: a window past its reset is full until the next read (P460).
        let present = current(reading, now: now)
        guard !restored, isFresh(reading, now: now, limit: provider.freshnessLimit) else {
            return .stale(lastPercentLeft: percentLeft(present))
        }
        if isExhausted(present) { return .usedUp(refill: refillDate(present)) }
        let left = percentLeft(present)
        return .available(percentLeft: left, isLow: left < lowThreshold)
    }

    /// The first monitored account in the user's order that is available.
    public static func next(in accounts: [Account], states: [String: AccountState]) -> Account? {
        accounts.first { $0.monitored && (states[$0.id] ?? .unknown).isAvailable }
    }

    public struct Availability: Sendable, Equatable {
        public var available: Int
        public var total: Int
        /// False when nothing is available and some readings are stale or missing: not knowing is not the same as being out.
        public var isKnown: Bool
    }

    public static func availability(accounts: [Account], states: [String: AccountState]) -> Availability {
        availability(states: accounts.filter(\.monitored).map { states[$0.id] ?? .unknown })
    }

    /// The same, over the states of the batteries a row shows. A No plan or No limits battery (P360, P581) is not one
    /// that could be available: it counts in neither the total nor the doubt.
    public static func availability(states all: [AccountState]) -> Availability {
        let s = all.filter { !$0.isPlanless }
        let available = s.filter(\.isAvailable).count
        let uncertain = s.contains { state in
            switch state {
            case .stale, .unknown, .signingIn: true
            default: false
            }
        }
        return Availability(available: available, total: s.count, isKnown: available > 0 || !uncertain)
    }
}
