import Foundation

/// The status file `scripts/update-app.sh` writes and the app reads (`~/Library/Application Support/Juice Island/
/// update-status`, passed to the script as `$JI_STATUS_FILE`). The script empties it when a run starts, writes the path
/// of the bundle it updates (`app:<path>`, which is no state), then appends one state per line, in this order:
///
///     pulling, building, verifying, ready, installing, restarting, done, failed:<reason>
///
/// The last complete line (ended by a newline) is the current state. `done` right after `pulling`: the running build
/// is already origin/main's commit. `ready`: the staged app is built and verified; the app quits itself so the script can swap
/// the bundle (`installing`, `restarting` and `done` follow while the app is gone; the script writes `done` once the
/// new build runs, so that build may see `restarting` or `done` at launch). `failed:<reason>`: nothing was swapped, or
/// the swap was undone and the previous app reopened; when it did not reopen, a second `failed:` line tells the owner
/// to open it from its folder, and shows when they do.
enum UpdateStatusLine: Equatable, Sendable {
    case pulling, building, verifying, ready, installing, restarting, done
    case failed(String)

    /// One line of the file.
    init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("failed:") || trimmed == "failed" {
            let reason = trimmed.dropFirst("failed".count).dropFirst().trimmingCharacters(in: .whitespaces)
            self = .failed(reason.isEmpty ? "see the log" : reason)
            return
        }
        switch trimmed {
        case "pulling": self = .pulling
        case "building": self = .building
        case "verifying": self = .verifying
        case "ready": self = .ready
        case "installing": self = .installing
        case "restarting": self = .restarting
        case "done": self = .done
        default: return nil
        }
    }

    /// The file's current state: its last complete line (a line still being written counts only once its newline is
    /// there); nil for an empty file or an unknown word.
    static func current(in text: String) -> UpdateStatusLine? {
        guard let end = text.lastIndex(of: "\n") else { return nil }
        let complete = text[..<end]
        guard let last = complete.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        return UpdateStatusLine(line: String(last))
    }

    /// The bundle the run updates, from its `app:` line; nil for a file an older script wrote.
    static func app(in text: String) -> String? {
        text.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("app:") }.map { String($0.dropFirst("app:".count)) }
    }

    /// The script swapped the bundle and opened the new build: its current state is `restarting` or `done`, after a
    /// `restarting` line (a `done` right after `pulling` swapped nothing).
    static func opensNewBuild(_ text: String) -> Bool {
        guard let current = current(in: text), current == .restarting || current == .done,
              let end = text.lastIndex(of: "\n") else { return false }
        return text[..<end].split(separator: "\n").contains { UpdateStatusLine(line: String($0)) == .restarting }
    }
}

/// How a background prepare ended (P710), from the status file `update-app.sh` writes in prepare mode
/// (`~/Library/Application Support/Juice Island/update-prepare`, `update-prepare-dev` for a dev build): `app:<path>`,
/// then pulling, building, verifying, and last `prepared:<commit>` (a verified app for that commit waits in the
/// updater's checkout), `done` (the running build is origin/main's already) or `failed:<reason>`. Its last complete
/// line counts, as in the update's file.
enum PrepareOutcome: Equatable, Sendable {
    case prepared(String)
    case done
    case failed(String)

    /// The failures that are the commit's own (P715), by how update-app.sh words them: its build failed or left no
    /// app, the new build failed a check (`ji_verify`), or origin/main's updater cannot prepare it. That commit is not
    /// prepared again while the app runs.
    static let ownReasonPrefixes = ["the build failed", "the build left no single app", "the new build",
                                    "origin/main has no scripts/update-app.sh", "origin/main's update-app.sh"]

    /// A failure that says nothing about the commit, so the next check prepares it again: the power, the app's quit, a
    /// stop, the time a busy machine took (the next try goes on from the build's caches), GitHub out of reach, git's
    /// locks, the updater's checkout, and any reason this build does not know.
    var isPassing: Bool {
        guard case let .failed(reason) = self else { return false }
        return !Self.ownReasonPrefixes.contains { reason.hasPrefix($0) }
    }

    /// The file's outcome; nil while the prepare runs, for an unknown last line, or a file with no ending yet.
    init?(text: String) {
        guard let end = text.lastIndex(of: "\n"),
              let last = text[..<end].split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        let line = last.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("prepared:") {
            let commit = String(line.dropFirst("prepared:".count)).lowercased()
            guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else { return nil }
            self = .prepared(commit)
        } else if line == "done" {
            self = .done
        } else if case let .failed(reason)? = UpdateStatusLine(line: line) {
            self = .failed(reason)
        } else {
            return nil
        }
    }
}

/// What changed between the build an update replaced and the one it opened (P716): `whats-new` beside the status file,
/// which update-app.sh writes from the updater's checkout just before the swap: `from:<commit>`, `to:<commit>`,
/// `count:<commits>`, then up to 30 commit subjects, newest first, merges left out. The build it names in `to` shows it
/// once as a small card (Settings › About keeps it); nothing when no commit is new or the build is the same.
struct WhatsNewNote: Equatable, Sendable {
    var from: String
    var to: String
    /// Every new commit, past the subjects listed too.
    var count: Int
    var subjects: [String]

    init(from: String, to: String, count: Int, subjects: [String]) {
        self.from = from
        self.to = to
        self.count = max(count, subjects.count)
        self.subjects = subjects
    }

    /// The file's note; nil when its three header lines are not there or it lists no subject.
    init?(text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 3, lines[0].hasPrefix("from:"), lines[1].hasPrefix("to:"), lines[2].hasPrefix("count:"),
              let count = Int(lines[2].dropFirst("count:".count)) else { return nil }
        let subjects = lines.dropFirst(3).map(Self.trimmed).filter { !$0.isEmpty }
        guard !subjects.isEmpty else { return nil }
        self.init(from: String(lines[0].dropFirst("from:".count)), to: String(lines[1].dropFirst("to:".count)), count: count,
                  subjects: subjects)
    }

    /// The note is this build's to show: it opened `to`, which is `commit`, and replaced another build.
    func belongs(to commit: String?) -> Bool {
        guard let commit, !commit.isEmpty else { return false }
        return to.lowercased() == commit.lowercased() && from.lowercased() != commit.lowercased()
    }

    /// The first `limit` subjects and how many commits the list leaves out ("and N more").
    func lines(limit: Int) -> (shown: [String], more: Int) {
        let shown = Array(subjects.prefix(limit))
        return (shown, count - shown.count)
    }

    /// A subject in plain words: spaces collapsed, no closing full stop.
    static func trimmed(_ subject: String) -> String {
        var text = subject.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// What the app shows while an update runs, and once after one.
enum UpdatePhase: Equatable, Sendable {
    case idle
    case pulling, building, installing, restarting
    /// Past ready, the app is still here after the controller's patience: the owner is asked to restart (P98).
    case restartNeeded
    /// The current app stays; About says why, with the log one click away.
    case failed(reason: String)
    /// This build is the one an update just opened (its short commit); shows once, after the relaunch.
    case updated(String)

    var isRunning: Bool {
        switch self {
        case .pulling, .building, .installing, .restarting, .restartNeeded: true
        case .idle, .failed, .updated: false
        }
    }

    /// "Fetching…" (the status file's `pulling`), "Building…", "Installing…", "Restarting…", "Restart to update",
    /// "Update failed: <reason>", "Updated to <commit>"; nil while idle.
    var text: String? {
        switch self {
        case .idle: nil
        case .pulling: "Fetching…"
        case .building: "Building…"
        case .installing: "Installing…"
        case .restarting: "Restarting…"
        case .restartNeeded: "Restart to update"
        case let .failed(reason): "Update failed: \(reason)"
        case let .updated(commit): "Updated to \(commit)"
        }
    }

    var isFailed: Bool { if case .failed = self { true } else { false } }
}

/// The words the toolbar, the island menu and About use (unit-tested).
enum UpdateText {
    /// "12 changes", "1 change".
    static func changes(_ count: Int) -> String { "\(count) change\(count == 1 ? "" : "s")" }

    /// What an offered update brings: its changes, or, when origin/main has none the build lacks, that the build is
    /// not origin/main's (uncommitted changes, another branch, commits never pushed).
    /// The public flavor's feed offers a version: "Version 1.2.0".
    static func offer(_ info: UpdateInfo) -> String {
        if let version = info.version { return "Version \(version)" }
        return info.newer > 0 ? changes(info.newer) : "Not built from origin/main"
    }

    /// The toolbar's help: what the click does. `prepared`: the update is built and verified, so the click restarts.
    static func toolbarHelp(_ info: UpdateInfo, prepared: Bool = false) -> String {
        "\(offer(info)) · click to \(prepared ? "restart" : "update")"
    }

    /// The Update control's words once the update waits built (P711): a restart installs it.
    static let restartToUpdate = "Restart to update"

    /// An update can start: one is offered, and none running (after a failure, the control's Retry).
    static func offersUpdate(available: UpdateInfo?, phase: UpdatePhase) -> Bool {
        available != nil && !phase.isRunning
    }

    /// The gear menu's line: the Update control's words while an update runs ("Updating: Building 63%"), Restart to
    /// Update once the owner is asked or the update waits built (`prepared`), the update while one is offered, and
    /// "Updated to <commit>" once after the relaunch. Choosing it opens the control in Settings › About (P807).
    static func menuTitle(available: UpdateInfo?, phase: UpdatePhase, prepared: Bool = false,
                          progress: UpdateProgress = .none) -> String? {
        if phase == .restartNeeded { return "Restart to Update" }
        if phase.isRunning, let words = runWords(phase, progress: progress) { return "Updating: \(words)" }
        if let available {
            let count = available.newer > 0 ? " (\(changes(available.newer)))" : ""
            return (prepared ? "Restart to Update" : "Update \(Product.name)") + count
        }
        if case .updated = phase { return phase.text }
        return nil
    }

    /// The menu line acts when it starts an update or restarts for one; the step and "Updated to" are greyed.
    static func menuEnabled(available: UpdateInfo?, phase: UpdatePhase) -> Bool {
        phase == .restartNeeded || offersUpdate(available: available, phase: phase)
    }

    /// About's Updates line, beside Check now (the build line is under the app's name). The check's time ends it, so
    /// Check now shows that it ran even when nothing changed. An offered update's changes have their own row, so the
    /// line gives only the time then.
    /// `today`: the feed's checks, once a day, say the day when it was not today ("checked Sep 30"); the hourly check
    /// passes none and keeps the time.
    static func status(_ state: UpdateCheckState, timeZone: TimeZone = .current, today: Date? = nil) -> String {
        switch state {
        case .idle: return "Not checked yet"
        case .checking: return "Checking…"
        case let .failed(reason, at): return reason + " · " + checked(at, timeZone: timeZone, today: today)
        case let .checked(info, at):
            let time = checked(at, timeZone: timeZone, today: today)
            return info.isAvailable ? time.prefix(1).uppercased() + time.dropFirst() : "Up to date · " + time
        }
    }

    /// "checked 14:05"; "checked Sep 30" when `today` is given and the check was another day.
    static func checked(_ date: Date, timeZone: TimeZone, today: Date? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        if let today {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            if !calendar.isDate(date, inSameDayAs: today) { formatter.dateFormat = "MMM d" }
        }
        return "checked " + formatter.string(from: date)
    }

    /// About's line in a public build made without the feed's key (P824).
    static let updatesOff = "Updates are off in this build"

    /// The Update control's words while a run goes (P803): "Fetching", "Building 63%" (the percent only while the
    /// estimate holds it, P802), "Installing" (the new build's check, and Restart to update's), "Restarting" (the menu's,
    /// past ready: the control says Updated); nil otherwise.
    static func runWords(_ phase: UpdatePhase, progress: UpdateProgress) -> String? {
        if phase.isRunning, phase != .restartNeeded, let words = progress.words { return words }
        return switch phase {
        case .pulling: "Fetching"
        case .building: progress.buildPercent.map { "Building \($0)%" } ?? "Building"
        case .installing: "Installing"
        case .restarting: "Restarting"
        case .restartNeeded: restartToUpdate
        case .idle, .failed, .updated: nil
        }
    }

    /// The time the estimate leaves the build, in plain words, only while it holds (P802): "About 3 min left", "About a
    /// minute left", "Less than a minute left"; past it, "Taking longer than last time"; nil without an estimate.
    static func timeLeft(_ progress: UpdateProgress) -> String? {
        if progress.overran { return "Taking longer than last time" }
        guard let seconds = progress.secondsLeft else { return nil }
        if seconds >= 90 { return "About \(Int((Double(seconds) / 60).rounded())) min left" }
        return seconds >= 45 ? "About a minute left" : "Less than a minute left"
    }

    /// A failure's reason in plain words (P809): the updater's own reasons are plain already, a sentence's first
    /// letter aside; the two that name the script say what they mean.
    static func plainReason(_ reason: String) -> String {
        var text = reason
        if text.hasPrefix("update-app.sh stopped") {
            text = "the updater stopped" + text.dropFirst("update-app.sh stopped".count)
        } else if text == "This build carries no update-app.sh" {
            text = "this build has no updater"
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "Updated to <commit>" shows (once, after the relaunch).
    static func isUpdated(_ phase: UpdatePhase) -> Bool { if case .updated = phase { true } else { false } }
}
