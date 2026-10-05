import Foundation
import IslandEngine
import JuiceCore

/// The Diagnostics pane's words, as pure functions of the saved readings (unit-tested).
enum DiagnosticsText {
    enum Tone: Equatable { case normal, amber, red }

    struct AccountLine: Equatable {
        var lastRead: String
        var next: String
        var status: String
        var tone: Tone
    }

    /// Floors (spec §4.5 with C11): Claude 300 s (120 s boosted), Codex 60 s.
    static let claudeFloor: TimeInterval = 300
    static let codexFloor: TimeInterval = 60
    static let floorsLine = "Claude 300 s, 120 s boosted\nCodex 60/30/15 s · Retry-After + 900 s"
    /// Copy Report's first line: "Juice Island · Build 1a2b3c4 · 2026-09-24 14:05 · Open Island engine 1.2.1", the
    /// build's own stamp.
    static func buildLine(_ stamp: BuildStamp) -> String {
        "\(Product.name) · \(stamp.aboutLine()) · Open Island engine \(IslandEngineInfo.vendorVersion)"
    }

    /// The pane's last line, beside its buttons: "Build 1a2b3c4 · engine 1.2.1" (About has the date).
    static func shortBuildLine(_ stamp: BuildStamp) -> String {
        let build = stamp.shortCommit.map { "Build " + $0 + (stamp.dirty ? BuildStamp.dirtySuffix : "") } ?? BuildStamp.unknownText
        return "\(build) · engine \(IslandEngineInfo.vendorVersion)"
    }

    /// Diagnostics › Motion (recording, the 120 Hz vote, the outline, the last motions) is the owner's A/B tooling: the
    /// public flavor shows none of it and runs on its defaults (P1060).
    static func showsMotionTools(_ flavor: AppFlavor = .current) -> Bool { !flavor.isPublic }

    /// Report a Bug's repository: the public flavor's, when the build names one (P1065); the private app keeps Copy
    /// Report alone.
    static func reportBugRepo(_ flavor: AppFlavor = .current) -> String? { flavor.isPublic ? flavor.publicRepo : nil }

    /// Where Record island motion writes, under Diagnostics › Motion while it is on.
    static var motionFolder: String { "One JSON per motion in ~/Library/Logs/\(AppFlavor.current.logsFolderName)/motion." }

    /// A recorded motion's row in Diagnostics › Motion: its name, frames a second ("–" when no outline frame was owed:
    /// Reduce Motion's snaps, a swap that keeps the island's size), its jobs' median lateness ("–" with no jobs), and
    /// its hitches with Apple's hitch-time ratio, which tones the row (5 ms/s or more amber, over 10 red).
    static func motion(_ entry: MotionLog.Entry) -> (cells: [String], tone: Tone) {
        let late = entry.jobsLateMS.map { "\(Int($0.rounded())) ms" } ?? "–"
        // Core Animation's outline is drawn by the render server: the app sees none of its frames (judge it on the display).
        if entry.coreAnimation { return ([entry.name, "CA", late, "–"], .normal) }
        let tone: Tone = entry.hitchRatio > 10 ? .red : entry.hitchRatio >= 5 ? .amber : .normal
        let fps = entry.framesPerSecond > 0 ? "\(Int(entry.framesPerSecond.rounded()))" : "–"
        let hitches = entry.hitches == 0 ? "0" : "\(entry.hitches) · " + String(format: "%.1f ms/s", entry.hitchRatio)
        return ([entry.name, fps, late, hitches], tone)
    }

    /// "20s ago", "4m ago", "3h ago", "2d ago".
    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s ago" }
        if s < 3_600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3_600)h ago" }
        return "\(s / 86_400)d ago"
    }

    /// "in 40s", "in 4m", "in 6h".
    static func due(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s < 60 { return "in \(s)s" }
        if s < 3_600 { return "in \(Int((Double(s) / 60).rounded()))m" }
        return "in \(Int((Double(s) / 3_600).rounded()))h"
    }

    /// One row of Diagnostics › Accounts and of Copy Report: a login, exactly as its battery (`LoginList`), or a folder no
    /// login row lists (signed out, or holding no login the app knows).
    struct AccountEntry: Equatable, Identifiable {
        /// The login's id, or the folder's.
        var id: String
        var provider: Provider
        /// The login's folders' aliases ("Home + Side"), and its organization's name when it is not the personal one
        /// ("Home + Side · Research Lab", P580), or the folder's own; never an email or an organization's id.
        var label: String
        var line: AccountLine
    }

    /// Every row, per provider: its logins in the list's order, then its loose folders. A login's state is its battery's,
    /// its Monitor switch its own, its next read the scheduler's (`schedule`); a folder's, where its question stands.
    static func accounts(_ lists: [ProviderLogins], records: [String: AccountRecord], schedule: (String) -> ReadSchedule? = { _ in nil },
                         question: (String) -> FolderQuestion = { _ in .none }, now: Date, clock: (Date) -> String = hhmm) -> [AccountEntry] {
        lists.flatMap { list in
            list.logins.map { row in
                AccountEntry(id: row.id, provider: list.provider, label: label(row.folders) + (row.org.map { " · " + $0 } ?? ""),
                             line: login(row, record: records[row.id], schedule: schedule(row.id), now: now, clock: clock))
            } + list.folders.map { loose in
                AccountEntry(id: loose.id, provider: list.provider, label: label([loose.folder]),
                             line: folder(loose, record: records[loose.id], question: question(loose.id), now: now))
            }
        }
    }

    /// "Home + Side": the aliases of the folders that hold a login, each cut at an "@" should one look like an email.
    static func label(_ folders: [Account]) -> String {
        folders.map { $0.alias.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" }
            .joined(separator: " + ")
    }

    /// A login's row. Its switch first ("Not monitored" reads nothing), then its battery's state, with a 429's retry
    /// (Retry-After + 900 s, in Next only) and a No plan login's 6-hour wait (P360) from the schedule. Next is the scheduler's own due
    /// time; a model that schedules nothing counts the floor from the last reading.
    static func login(_ row: LoginRow, record: AccountRecord?, schedule: ReadSchedule?, now: Date,
                      clock: (Date) -> String = hhmm) -> AccountLine {
        let lastRead = lastRead(record, now: now)
        guard row.monitored else { return AccountLine(lastRead: lastRead, next: "off", status: "Not monitored", tone: .normal) }
        let floor = row.provider == .claude ? claudeFloor : codexFloor
        func next(fallback: Date?) -> String {
            if schedule?.reading == true { return "reading" }
            guard let at = schedule?.next ?? fallback else { return "now" }
            return at <= now ? "now" : due(at.timeIntervalSince(now))
        }
        switch row.battery.state {
        case .signingIn:
            return AccountLine(lastRead: lastRead, next: "paused", status: "Signing in", tone: .normal)
        case .signInNeeded:
            return AccountLine(lastRead: lastRead, next: "paused", status: "Sign-in required", tone: .red)
        default: break
        }
        if case let .rateLimited(retryAfter)? = record?.lastError {
            // The retry time once, in Next.
            let at = schedule?.next ?? (record?.lastErrorAt ?? now) + (retryAfter ?? 0) + 900
            return AccountLine(lastRead: lastRead, next: clock(at), status: "Rate limited", tone: .amber)
        }
        switch row.battery.state {
        case .noPlan, .noLimits:
            let fallback = record?.noPlan.map { $0.last + NoPlanStreak.interval }
            let status = row.battery.state == .noLimits ? "No limits" : "No plan"
            return AccountLine(lastRead: lastRead, next: next(fallback: fallback), status: status, tone: .normal)
        case .stale:
            return AccountLine(lastRead: lastRead, next: next(fallback: nil), status: "Stale · retrying", tone: .amber)
        case .unknown:
            if let error = record?.lastError {
                return AccountLine(lastRead: lastRead, next: next(fallback: nil), status: word(error), tone: .amber)
            }
            return AccountLine(lastRead: lastRead, next: next(fallback: nil), status: "New · first read due", tone: .normal)
        default:
            let fallback = record?.lastGood.map { $0.readAt + floor }
            return AccountLine(lastRead: lastRead, next: next(fallback: fallback), status: "OK", tone: .normal)
        }
    }

    /// A read's failure in fixed words: a failed read's own text (a CLI's stderr, which can name a path or an email) is
    /// never shown or copied (spec §4.5, P364).
    static func word(_ error: ReadError) -> String {
        if case .failed = error { return "Read failed" }
        return error.shortDescription
    }

    /// A folder no login row lists: signed out (asked again after the user-fixable hour, or by Sign In), or not placed
    /// yet, where its question stands.
    static func folder(_ loose: LooseFolder, record: AccountRecord?, question: FolderQuestion, now: Date) -> AccountLine {
        let lastRead = lastRead(record, now: now)
        if loose.state == .signedOut {
            return AccountLine(lastRead: lastRead, next: "paused", status: "Sign-in required", tone: .red)
        }
        switch question {
        case .unanswered:
            return AccountLine(lastRead: lastRead, next: "retrying", status: "Could not check who is signed in", tone: .amber)
        case .cliMissing:
            return AccountLine(lastRead: lastRead, next: "paused", status: "CLI not found", tone: .amber)
        case .asking, .none:
            return AccountLine(lastRead: lastRead, next: "now", status: "New · first read due", tone: .normal)
        }
    }

    /// "4m ago" from the last good reading, else from the last failure; "never".
    static func lastRead(_ record: AccountRecord?, now: Date) -> String {
        record?.lastGood.map { age(now.timeIntervalSince($0.readAt)) }
            ?? record?.lastErrorAt.map { age(now.timeIntervalSince($0)) } ?? "never"
    }

    /// The Bridge row: whether the hooks reach this app, in one line. Off with the switch; the refusal while it waits;
    /// "Live · 2 sockets" (and when a lost socket was taken back, and the context notes' socket when it failed) while
    /// live; the socket another app took.
    static func bridge(switchOn: Bool, live: Bool, refusal: String?, health: BridgeHealth, takenBackAt: Date?,
                       notesProblem: String?, now: Date) -> String {
        guard switchOn else { return "Off" }
        guard live else { return refusal ?? "Starting…" }
        switch health {
        case .taken:
            return "Another app took the hook socket · waiting for it to quit"
        case .off:
            return "Live"
        case .live(let sockets):
            var parts = ["Live · \(sockets) \(sockets == 1 ? "socket" : "sockets")"]
            if let takenBackAt { parts.append("taken back " + age(now.timeIntervalSince(takenBackAt))) }
            if notesProblem != nil { parts.append("context notes off") }
            return parts.joined(separator: " · ")
        }
    }

    /// The Last jump row: where it went, how it ended, how long ago ("Ghostty · exact tab · 4m ago").
    static func jump(_ outcome: JumpOutcome, now: Date) -> String {
        let result: String = switch outcome.result {
        case .matched: "exact tab"
        case .activatedOnly: "app only"
        case .fallbackActivated: "app, not the tab"
        case .noTarget: "no target"
        case .folderOpened: "no app or terminal, folder in Finder"
        case .failed: outcome.failure.map(failureWords) ?? "failed"
        }
        return [outcome.host, result, age(now.timeIntervalSince(outcome.startedAt))].joined(separator: " · ")
    }

    static func failureWords(_ failure: JumpFailure) -> String {
        switch failure {
        case .unknownHost: "unknown app"
        case .automationDenied: "automation denied"
        case .timedOut: "timed out"
        case .scriptFailed: "script failed"
        case .openFailed: "open failed"
        case .hostNotRunning: "app not running"
        case .cliMissing: "tool missing"
        case .detached: "tmux detached"
        case .ambiguous: "several matches"
        case .wrongTab: "wrong tab"
        case .threadLinkFailed: "thread link failed"
        case .threadUnknown: "thread unknown"
        }
    }

    static func hhmm(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Money: OK, or why it cannot read. OpenAI is read every 5 minutes (C10).
    static func money(id: String, readable: Bool) -> (next: String, status: String) {
        guard readable else {
            return ("off", id == MoneyAccount.hetzner.rawValue ? "No token · add in Money" : "Not connected · no key file")
        }
        return id == MoneyAccount.openAI.rawValue ? ("in 5m", "OK · usage API, every 5 min") : ("in 3m", "OK")
    }

    /// Copy Report: aliases and states only, never folders, emails or keys (spec §4.5).
    /// The Needs you row (C18): what the request book did since launch, in counts only. First line: requests asked,
    /// shown (confirmed), settled before the owner was asked, and the helper generation in effect, the last note's (v1:
    /// a helper not yet updated, P163; after Hook helper · Update it names the new one at the next hook, P176); second
    /// line: how they closed. nil before the first request or note.
    static func attention(_ tally: AttentionTally) -> String? {
        let asked = tally.opened.values.reduce(0, +)
        let notes = tally.noteVersions.values.reduce(0, +)
        guard asked > 0 || notes > 0 else { return nil }
        var first = ["\(asked) asked", "\(tally.confirmed.values.reduce(0, +)) shown", "\(tally.neverConfirmed) settled first"]
        let hidden = tally.notShown.values.reduce(0, +)
        if hidden > 0 { first.append("\(hidden) not shown") }
        if let helper = tally.lastNoteVersion ?? tally.noteVersions.keys.max() { first.append("helper v\(helper)") }
        let words: [String: String] = ["hookEnded": "hook ended", "islandAnswer": "island", "toolEvidence": "tool", "transcript": "transcript",
                                       "turnEnd": "turn end", "rolloutOutput": "output", "pidGone": "agent gone", "opened": "Open",
                                       "dismissed": "✕", "superseded": "replaced", "sessionGone": "session gone", "noticeCleared": "moved on"]
        let closes = tally.closes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.value) \(words[$0.key] ?? $0.key)" }
        return ([first.joined(separator: " · ")] + (closes.isEmpty ? [] : ["closed: " + closes.joined(separator: ", ")]))
            .joined(separator: "\n")
    }

    /// The rest of the book's counts, for the copied report only (C18): what the row leaves out, each part only when it
    /// happened.
    static func attentionDetails(_ tally: AttentionTally) -> String? {
        func listed(_ counts: [String: Int]) -> String {
            counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
        }
        var parts: [String] = []
        if !tally.opened.isEmpty { parts.append("opened: " + listed(tally.opened)) }
        if tally.held + tally.released > 0 { parts.append("broker: \(tally.held) held, \(tally.released) released") }
        if !tally.notShown.isEmpty { parts.append("not shown: " + listed(tally.notShown)) }
        if !tally.releasedByWindow.isEmpty { parts.append("released unconfirmed: " + listed(tally.releasedByWindow)) }
        if !tally.subagentHolds.isEmpty { parts.append("subagent holds ended: " + listed(tally.subagentHolds)) }
        if !tally.codexHolds.isEmpty { parts.append("Codex holds ended: " + listed(tally.codexHolds)) }
        let counts: [(String, Int)] = [("revived", tally.revivals), ("notices with no request", tally.noticesWithoutRequest),
                                       ("Codex unmatched", tally.codexUnmatched), ("Codex settled within 8 s", tally.codexClosedEarly),
                                       ("island answers that lost the race", tally.lostRaces), ("unreadable", tally.unreadable)]
        parts += counts.filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
        if tally.codexQuestionsOpened > 0 {
            let closed = tally.codexQuestionsClosed.isEmpty ? "" : " (closed: " + listed(tally.codexQuestionsClosed) + ")"
            parts.append("Codex questions \(tally.codexQuestionsOpened)" + closed)
        }
        if !tally.noteVersions.isEmpty {
            parts.append("notes: " + tally.noteVersions.sorted { $0.key < $1.key }.map { "v\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func report(lines: [(alias: String, provider: Provider, line: AccountLine)], money: [(name: String, status: String)],
                       bridge: String? = nil, attention: String? = nil, attentionDetails: String? = nil,
                       stamp: BuildStamp = BuildStamp(commit: nil, repoPath: nil)) -> String {
        var text = [buildLine(stamp)] + (bridge.map { ["Bridge: " + $0] } ?? [])
        text += attention.map { ["Needs you: " + $0.replacingOccurrences(of: "\n", with: " · ")] } ?? []
        text += attentionDetails.map { ["Needs you, in detail: " + $0] } ?? []
        text += ["Floors: " + floorsLine.replacingOccurrences(of: "\n", with: " · "), "", "Accounts"]
        text += lines.map { "  \($0.provider.displayName) \($0.alias): \($0.line.status) (read \($0.line.lastRead), next \($0.line.next))" }
        text += ["", "Money"] + money.map { "  \($0.name): \($0.status)" }
        return text.joined(separator: "\n")
    }
}
