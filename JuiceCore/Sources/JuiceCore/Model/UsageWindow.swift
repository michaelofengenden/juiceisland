import Foundation

/// One rate-limit window of an account, for example the 5-hour or the weekly one.
public struct UsageWindow: Codable, Sendable, Equatable, Hashable {
    /// Window length in seconds (18 000 for 5 hours, 604 800 for a week). 0 when the vendor did not say and the
    /// length could not be inferred; such a window is labelled "window".
    public var seconds: Int
    /// 0…100 as reported; may exceed 100 on some responses.
    public var usedPercent: Double
    public var resetsAt: Date?
    /// A name for windows whose length does not tell them apart — Claude's Max plan reports an Opus week and a
    /// Sonnet week alongside the overall one. `nil` for every window the length already names. Optional so
    /// readings.json files written before this existed still decode.
    public var label: String?
    /// Whether the window counts toward the battery, Next and "used up". `false` for windows that only show in the
    /// hover and Diagnostics (Claude's OAuth-apps week, keys Juice does not know yet). `nil` in readings saved before
    /// this existed, which all counted.
    public var counted: Bool?

    public init(seconds: Int, usedPercent: Double, resetsAt: Date?, label: String? = nil, counted: Bool? = nil) {
        self.seconds = seconds
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.label = label
        self.counted = counted
    }

    /// Whole percent left, clamped to 0…100 and rounded down, because a battery never rounds up.
    public var percentLeft: Int { Int(max(0, min(100, 100 - usedPercent)).rounded(.down)) }
    public var isExhausted: Bool { usedPercent >= 100 }
    public var isCounted: Bool { counted ?? true }
    /// What the hover calls this window: its own name when it has one, else its length ("5h", "week").
    public var displayLabel: String { label ?? Formatting.windowLabel(seconds: seconds) }
}
