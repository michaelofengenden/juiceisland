import Foundation

/// Which sessions are active: running, needing you (a failed turn included), or done or interrupted within
/// `recentWindow` of `now`. The pill counts these (and hides when idle without them), and every list shows them before
/// the older finished ones. The clock
/// is passed in, so the models' minute clock (`SessionsModel.now`) moves a finished session out without any event of
/// its own; a running or waiting one stays until it reports.
enum SessionActivity {
    /// How long a finished session stays active after its last update, on either side of the clock: a row stamped
    /// further ahead (the clock set back) reads as old, not as active for the whole jump.
    static let recentWindow: TimeInterval = 15 * 60

    static func isActive(_ row: SessionRow, now: Date) -> Bool {
        // A scripted run or a subagent's thread is never counted as active on its own (P254).
        guard row.tells else { return false }
        return row.bucket != .done || abs(now.timeIntervalSince(row.updatedAt)) <= recentWindow
    }

    /// What a list's footer counts among the rows it hides ("Show N more"): an active row, or a quiet one that runs (a
    /// scripted run shown on request), so the footer never reads "Earlier" over a running row. The pill never counts a
    /// quiet one (P254).
    static func isFooterActive(_ row: SessionRow, now: Date) -> Bool {
        isActive(row, now: now) || (row.isQuiet && row.bucket == .running)
    }

    /// No session is active: Hide the pill when idle tucks the closed pill away (P94). A stalled run is no activity
    /// (P312): it keeps the pill up no more than it ticks on it.
    static func isIdle(_ rows: [SessionRow], now: Date) -> Bool {
        !rows.contains { isActive($0, now: now) && !$0.isStalled }
    }

    /// The active rows, then the rest, each in the order they came.
    static func activeFirst(_ rows: [SessionRow], now: Date) -> [SessionRow] {
        rows.filter { isActive($0, now: now) } + rows.filter { !isActive($0, now: now) }
    }
}
