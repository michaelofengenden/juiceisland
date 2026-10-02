import Foundation

/// A counted window that, at the pace of its recent readings, is used up before it resets (P125).
public struct RunOut: Sendable, Equatable, Hashable {
    /// The window's name, as the hover names it ("5h", "week", "week · Opus").
    public var window: String
    /// When it reaches 100 % at the current pace.
    public var at: Date
    /// When the window resets.
    public var resetsAt: Date
    /// The pace, in percent of the window an hour.
    public var perHour: Double

    public init(window: String, at: Date, resetsAt: Date, perHour: Double) {
        self.window = window
        self.at = at
        self.resetsAt = resetsAt
        self.perHour = perHour
    }
}

/// When a window runs out at the current pace: the slope of its samples over the last `lookback`, fitted by least
/// squares, from its own readings only. Said only when it matters: the window is used up before it resets, the samples
/// span at least `minimumSpan`, and the pace is at least `minimumPace`. Nothing is read to make it.
public enum UsageForecast {
    public static let lookback: TimeInterval = 30 * 60
    public static let minimumSpan: TimeInterval = 10 * 60
    public static let minimumPace: Double = 1
    /// A run-out this close to the reset is the reset, not news.
    public static let resetMargin: TimeInterval = 60

    /// The window of `reading` that runs out first before its reset, if any.
    public static func runOut(_ reading: AccountReading, account: String, history: UsageHistory) -> RunOut? {
        Rules.countedWindows(reading)
            .compactMap { runOut($0, samples: history.current(account, $0, readAt: reading.readAt), readAt: reading.readAt) }
            .min { $0.at < $1.at }
    }

    /// `samples`: the window's, oldest first, ending with the reading at `readAt` (`UsageHistory.current`).
    public static func runOut(_ window: UsageWindow, samples: [UsageSample], readAt: Date) -> RunOut? {
        guard let resetsAt = window.resetsAt, window.usedPercent < 100 else { return nil }
        let recent = samples.filter { $0.at >= readAt.addingTimeInterval(-lookback) && $0.at <= readAt }
        guard recent.count >= 2, let first = recent.first, readAt.timeIntervalSince(first.at) >= minimumSpan else { return nil }
        guard let pace = slope(recent, to: readAt), pace >= minimumPace else { return nil }
        let at = readAt.addingTimeInterval((100 - window.usedPercent) / pace * 3_600)
        guard at < resetsAt.addingTimeInterval(-resetMargin) else { return nil }
        return RunOut(window: window.displayLabel, at: at, resetsAt: resetsAt, perHour: pace)
    }

    /// Percent an hour, by least squares over the samples (hours before `end`).
    static func slope(_ samples: [UsageSample], to end: Date) -> Double? {
        let xs = samples.map { $0.at.timeIntervalSince(end) / 3_600 }
        let ys = samples.map(\.used)
        let n = Double(samples.count)
        let meanX = xs.reduce(0, +) / n, meanY = ys.reduce(0, +) / n
        let spread = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard spread > 0 else { return nil }
        return zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) } / spread
    }

    // MARK: Words

    /// "~40m", "~1h 40m", "~3h": how far away `date` is, never under a minute.
    public static func approximately(_ date: Date, now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded()))
        guard minutes >= 60 else { return "~\(minutes)m" }
        // Over an hour the minutes round to five: the pace is an estimate.
        let rounded = Int((Double(minutes) / 5).rounded()) * 5
        return rounded % 60 == 0 ? "~\(rounded / 60)h" : "~\(rounded / 60)h \(rounded % 60)m"
    }

    /// A line of its own: "5h out in ~40m · resets in 1h 12m" (the notice), or "out in ~40m · resets in 1h 12m" beside
    /// a battery that already stands for that window (`namedWindow`, the account list's detail).
    public static func line(_ runOut: RunOut, now: Date, namedWindow: String? = nil) -> String {
        let name = runOut.window == namedWindow ? "" : runOut.window + " "
        return name + "out in \(approximately(runOut.at, now: now)) · resets " + Formatting.refillPhrase(runOut.resetsAt, now: now)
    }

    /// The hover's part: "out in ~40m" when the run-out is the window the label already names (its reset follows), else
    /// "5h out in ~40m, resets in 1h 12m".
    public static func part(_ runOut: RunOut, namedWindow: String?, now: Date) -> String {
        let out = "out in " + approximately(runOut.at, now: now)
        guard runOut.window != namedWindow else { return out }
        return "\(runOut.window) \(out), resets " + Formatting.refillPhrase(runOut.resetsAt, now: now)
    }
}

/// A sparkline of a window's use: points from the window's start (x 0) to its reset (x 1), use 0 to 100 % (y 0 to 1),
/// ending at the latest reading.
public struct UsageSparkline: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double
    }

    public var points: [Point]
    public var window: String
    /// The window runs out before its reset at the current pace: the line takes the warning colour.
    public var runsOut: Bool

    /// The run-out window when there is one, else the tightest counted window; nil with fewer than two samples in it.
    public static func make(_ reading: AccountReading, account: String, history: UsageHistory, runOut: RunOut?) -> UsageSparkline? {
        let counted = Rules.countedWindows(reading)
        guard let window = counted.first(where: { $0.displayLabel == runOut?.window }) ?? counted.min(by: { $0.percentLeft < $1.percentLeft })
        else { return nil }
        let samples = history.current(account, window, readAt: reading.readAt)
        guard samples.count >= 2, let first = samples.first else { return nil }
        let end = window.resetsAt ?? reading.readAt
        let start = window.seconds > 0 ? min(first.at, end.addingTimeInterval(-Double(window.seconds))) : first.at
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return nil }
        let points = samples.map {
            Point(x: min(1, max(0, $0.at.timeIntervalSince(start) / span)), y: min(1, max(0, $0.used / 100)))
        }
        return UsageSparkline(points: points, window: window.displayLabel, runsOut: runOut?.window == window.displayLabel)
    }
}
