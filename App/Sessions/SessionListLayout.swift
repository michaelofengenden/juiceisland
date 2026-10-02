import Foundation
import IslandEngine

/// The window list's layout rules as pure functions (prototype L487-516, L1422-1437). Owner: stream C.
enum SessionListLayout {
    // MARK: Grids

    /// CSS `repeat(auto-fit, minmax(min, 1fr))`: as many columns as fit, but never more than there are items
    /// (auto-fit collapses empty tracks, so one card takes the full width).
    static func autoFitColumns(width: CGFloat, count: Int, minColumn: CGFloat, gap: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        return min(autoFillColumns(width: width, minColumn: minColumn, gap: gap), count)
    }

    /// CSS `repeat(auto-fill, minmax(min, 1fr))`: as many columns as fit; empty tracks keep their room.
    static func autoFillColumns(width: CGFloat, minColumn: CGFloat, gap: CGFloat) -> Int {
        max(1, Int(((width + gap) / (minColumn + gap)).rounded(.down)))
    }

    static func columnWidth(width: CGFloat, columns: Int, gap: CGFloat) -> CGFloat {
        guard columns > 0 else { return width }
        return max(0, (width - gap * CGFloat(columns - 1)) / CGFloat(columns))
    }

    /// Running and Done sit side by side from 1000 pt (the window's width); under it, one column.
    static func stacksColumns(windowWidth: CGFloat) -> Bool { windowWidth < WindowTheme.Metrics.narrowBreakpoint }

    /// Where a masonry item goes: its column and its top.
    struct Placement: Equatable {
        var column: Int
        var y: CGFloat
    }

    /// Masonry: each item, in order, goes to the column that ends highest (the leftmost on a tie), so a short card
    /// never leaves black space beside a tall one. The first `columns` items take the top of each column.
    static func masonry(heights: [CGFloat], columns: Int, gap: CGFloat) -> (placements: [Placement], height: CGFloat) {
        let columns = max(1, columns)
        var bottoms = [CGFloat](repeating: 0, count: columns)
        var used = [Bool](repeating: false, count: columns)
        var placements: [Placement] = []
        for height in heights {
            var column = 0
            for index in bottoms.indices where bottoms[index] < bottoms[column] { column = index }
            let y = used[column] ? bottoms[column] + gap : 0
            placements.append(Placement(column: column, y: y))
            bottoms[column] = y + height
            used[column] = true
        }
        return (placements, bottoms.max() ?? 0)
    }

    /// Running and Done flow into the Needs you columns (each under the column that ends highest) when Needs you
    /// fills a row of two or more columns and the window is wide enough for Running and Done side by side; otherwise
    /// they sit in their own row below.
    static func flowsIntoNeedsColumns(needsColumns: Int, windowWidth: CGFloat) -> Bool {
        needsColumns >= 2 && !stacksColumns(windowWidth: windowWidth)
    }

    // MARK: Running | Done

    struct Columns: Equatable {
        /// Full rows in the Running card (Claude, and any agent that is not Codex).
        var running: [SessionRow] = []
        /// The Codex group at the bottom of the Running card: Codex sessions that run, then idle ones.
        var codexGroup: [SessionRow] = []
        var done: [SessionRow] = []
        /// The sessions at work: the Running card's rows and the Codex group's running ones. A Codex session idle at the
        /// prompt sits in the group but does not run, so it is never counted as running.
        var runningCount: Int { running.count + codexGroup.count { $0.bucket == .running } }
        /// The Running card shows: something runs, or a Codex session waits at the prompt. With nothing running it is
        /// the Codex group alone, titled "Codex N" (`SessionListView`), never "Running".
        var showsRunningCard: Bool { !running.isEmpty || !codexGroup.isEmpty }
    }

    /// Which session shows where in the window, in order (Needs you, Running, the Codex group, Done) and whether only
    /// what needs you shows: the list animates when this changes, and only then.
    static func arrangement(needsYou: [SessionRow], columns: Columns, needsOnly: Bool) -> [String] {
        [needsOnly ? "needs you" : "all"] + needsYou.map(\.id) + ["running"] + columns.running.map(\.id) + ["codex"]
            + columns.codexGroup.map(\.id) + ["done"] + columns.done.map(\.id)
    }

    /// Splits the rows that don't need you into the Running and Done cards. Codex sessions that run, and Codex
    /// sessions that finished with nothing to report (idle at the prompt), gather in the Codex group under Running,
    /// as in the prototype; a Codex turn that ended with a message is a Done row like any other. Each card keeps the
    /// rows' order: the window passes them active first (`SessionActivity.activeFirst`), so Done keeps its history
    /// under the recent ones.
    static func columns(_ rows: [SessionRow]) -> Columns {
        var columns = Columns()
        var idleCodex: [SessionRow] = []
        for row in rows {
            switch row.bucket {
            case .needsYou:
                continue
            case .running:
                if row.agent == .codex { columns.codexGroup.append(row) } else { columns.running.append(row) }
            case .done:
                if isIdleCodex(row) { idleCodex.append(row) } else { columns.done.append(row) }
            }
        }
        columns.codexGroup += idleCodex
        return columns
    }

    /// Every row in the order the island lists them: needs you, then everything at work (the Running card's rows, then
    /// the Codex group's running ones), then what finished (the Done card's rows, then the Codex sessions idle at the
    /// prompt); the active sessions in that order first, then the finished ones older than `SessionActivity.recentWindow`.
    /// A running chat, a Codex one too, always comes before a turn that finished minutes ago (P291), as the window's
    /// Running card, with its Codex group, comes before Done.
    static func displayOrder(_ rows: [SessionRow], now: Date) -> [SessionRow] {
        func order(_ rows: [SessionRow]) -> [SessionRow] {
            let split = columns(rows)
            let codexRunning = split.codexGroup.filter { $0.bucket == .running }
            let codexIdle = split.codexGroup.filter { $0.bucket != .running }
            return rows.filter { $0.bucket == .needsYou } + split.running + codexRunning + split.done + codexIdle
        }
        let active = rows.filter { SessionActivity.isActive($0, now: now) }
        return order(active) + order(rows.filter { !SessionActivity.isActive($0, now: now) })
    }

    /// A Codex session whose last turn ended without a message and was not interrupted: it waits at the prompt.
    static func isIdleCodex(_ row: SessionRow) -> Bool {
        row.agent == .codex && row.bucket == .done && row.status == .done && (row.detail ?? "").isEmpty
    }

    /// The Codex group's grey text: "Running tool · 93m", "Thinking · 1m", "Idle · 18m". A running row counts from
    /// when its tool (or turn) started, not from its last update; the others from their last update.
    static func groupStatus(_ row: SessionRow, now: Date) -> String {
        // "Limit reached · resets 15:00" says its own time (P700).
        if let limit = row.limit { return limit.line }
        let word: String = switch row.status {
        case .tool: "Running tool"
        case .thinking: "Thinking"
        case .compacting: "Compacting"
        case let .subagents(count, workflows): StatusWord.subagentsText(count, workflows: workflows)
        case .reviewing: "Reviewing"
        case .needsApproval: "Needs approval"
        case .question: "Question"
        case .denied: "Denied"
        case .working: "Running"
        case .done: row.bucket == .done && isIdleCodex(row) ? "Idle" : "Done"
        case .interrupted: "Interrupted"
        case .failed: "Turn failed"
        }
        guard row.bucket == .running else { return "\(word) · \(SessionRowText.age(row.updatedAt, now: now))" }
        return "\(word) · \(SessionRowText.runningTime(since: row.activeSince ?? row.updatedAt, now: now))"
    }

    // MARK: Footer

    /// Needs you only: "2 more running or done · Show all" for the other active sessions (`SessionActivity`), never a
    /// total of history; "Earlier" when all the others finished longer ago (P94); nil when nothing else is there.
    static func moreFooter(_ rows: [SessionRow], now: Date) -> String? {
        let others = rows.filter { $0.bucket != .needsYou }
        guard !others.isEmpty else { return nil }
        let active = others.count { SessionActivity.isFooterActive($0, now: now) }
        return active > 0 ? "\(active) more running or done · Show all" : "Earlier"
    }

    // MARK: Row tooltip

    /// Whose session a row is and where it runs, for the tooltip on its agent mark and age: "Claude · Terminal ·
    /// work", "Gemini · Ghostty". `naming`: the row does not show its repo (the island's Clean row), so the tooltip says
    /// it: "Claude · MarathonTrainingLog · Terminal · work".
    static func rowHelp(_ row: SessionRow, naming project: Bool = false) -> String {
        var parts = [row.agent.displayName]
        if project, row.titleSource != .repo, !row.project.isEmpty { parts.append(row.project) }
        if let host = row.host, !host.isEmpty { parts.append(host) }
        if let alias = row.accountAlias, !alias.isEmpty { parts.append(alias) }
        return parts.joined(separator: " · ")
    }

    /// The jump key's hint ("⌃G"), only while the system-wide key is on and one is recorded (spec §4.4, C1).
    static func jumpHint(enabled: Bool, key: String?) -> String? {
        guard enabled, let key, !key.isEmpty else { return nil }
        return KeyHint.display(key)
    }

    /// The row the jump key targets: the first that needs you.
    static func jumpTargetID(_ rows: [SessionRow]) -> String? { rows.first { $0.bucket == .needsYou }?.id }
}

/// Recorded keys ("ctrl+shift+g") as the symbols menus show ("⌃⇧G").
enum KeyHint {
    static func display(_ key: String) -> String {
        let parts = key.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last else { return "" }
        let symbols: [String: String] = ["ctrl": "⌃", "control": "⌃", "opt": "⌥", "option": "⌥", "alt": "⌥",
                                         "shift": "⇧", "cmd": "⌘", "command": "⌘"]
        let order = ["⌃", "⌥", "⇧", "⌘"]
        let modifiers = Set(parts.dropLast().compactMap { symbols[$0] })
        return order.filter(modifiers.contains).joined() + last.uppercased()
    }
}
