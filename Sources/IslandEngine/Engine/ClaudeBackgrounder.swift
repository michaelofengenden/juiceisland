import Foundation
import JuiceCore
import Observation

/// The app's side of Claude Code's background sessions (wave 8, P1450 to P1484): what `claude agents --json` last said
/// of them, by session, and the commands a background session's card runs, each on the owner's click: a reply typed
/// through `claude attach` in a pseudo-terminal of the app's (no window), Open in terminal as `claude attach <id>` in a
/// new window, Stop as `claude stop <id>`. The list itself is read on a fold, on Open in terminal, at launch (only for a
/// profile whose supervisor kept a roster), at most once a minute while a background session is on the island, and once
/// per session before a fold or a reply takes a tab only the notes' environment names (P1545); it reads, and changes
/// nothing. Nothing attaches while anything else holds the conversation (P1541).
///
/// A headless engine (tests, renders, the demo) has no live runner, attach, window or scan: only injected stand-ins
/// run, so no test starts a CLI, attaches, or opens a window.
@MainActor
@Observable
public final class ClaudeBackgrounder {
    struct Dependencies: Sendable {
        /// Runs a list, stop or start to its end; nil: the live run for the app's own engine, none for a headless one.
        var run: (@Sendable (ClaudeBackgroundCommand, TimeInterval) -> ClaudeCommandResult?)?
        /// Starts `claude attach <id>` in a pseudo-terminal; nil: the live one for the app's engine, none for a headless one.
        var attach: (@Sendable (ClaudeBackgroundCommand) throws -> any ClaudeAttachTerminal)?
        /// Opens Open in terminal's new window; nil: Open in's own (`FreshSessionLaunch.live`) for the app's engine.
        var openWindow: (@Sendable (FreshSessionLaunch) -> Bool)?
        /// This user's `claude attach <id>` processes; nil: the live scan for the app's engine, none for a headless one.
        var findAttached: (@Sendable (String) -> [Int32])?
        /// This user's processes whose arguments name a conversation's id (`claude --resume <id>`, P1420, P1541); nil:
        /// `AgentProcessScan` for the app's engine, none for a headless one.
        var findAgents: (@Sendable (String) -> [Int32])?
        var hasRoster: @Sendable (String) -> Bool = { ClaudeBackgroundCommand.hasRoster(profile: $0) }
        var usualHost: @Sendable () -> FreshSessionLaunch.Host = { FreshSessionLaunch.liveUsualHost() }
        /// The app's environment, from which only the ssh agent's socket and the shell are taken.
        var environment: @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
        var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        var attachTiming = AttachReply.Timing()
        var listTimeout: TimeInterval = 20
        var stopTimeout: TimeInterval = 30
    }

    /// A background session as its profile's last list showed it.
    public struct Known: Equatable, Sendable {
        public var entry: ClaudeBackgroundEntry
        /// The config folder whose supervisor runs it.
        public var profile: String
        public var seenAt: Date
    }

    @ObservationIgnored private weak var engine: SessionEngine?
    @ObservationIgnored let dependencies: Dependencies
    /// Background sessions by session id, as the last list of each profile showed them.
    public private(set) var known: [String: Known] = [:]
    /// Live rows of any other kind (an interactive copy: `claude --resume <id>` in a terminal), by session id, as the last
    /// list of each profile showed them (P1541).
    public private(set) var elsewhere: [String: Known] = [:]
    /// A terminal attached to a session (a `claude attach <id>` process), by session id, as last looked for.
    public private(set) var attached: [String: Int32] = [:]
    /// A reply through the attach is on its way, by session.
    public private(set) var replying: Set<String> = []
    /// The line for a reply or a Stop that did not go, by session, until the next one (`problem(_:)`).
    public private(set) var problems: [String: String] = [:]
    /// When each profile's list was last read.
    @ObservationIgnored private(set) var readAt: [String: Date] = [:]
    /// The list being read, per profile: a second ask while one runs waits for it.
    @ObservationIgnored private var reads: [String: Task<[ClaudeBackgroundEntry]?, Never>] = [:]
    /// Sessions whose tab the notes' environment alone names, looked for in the list once (P1545).
    @ObservationIgnored var lookedFor: Set<String> = []
    /// The app's own hidden attaches while a reply goes through them: never a window attached to the session.
    @ObservationIgnored private var ownAttaches: Set<Int32> = []

    public convenience init(engine: SessionEngine) {
        self.init(engine: engine, dependencies: Dependencies())
    }

    init(engine: SessionEngine, dependencies: Dependencies) {
        self.engine = engine
        self.dependencies = dependencies
    }

    /// The app's own engine in the app: never in a test process, whatever its engine's kind (P1475).
    private var live: Bool { engine?.configuration.startBridge == true && ClaudeLive.allowed }

    /// Whether it can read a list at all: the app's own engine, or a test's runner.
    public var canRun: Bool { dependencies.run != nil || live }

    // MARK: The list

    /// Reads `claude agents --json --all` in `profile` (one read at a time per profile, off the main thread), keeps its
    /// background rows, and answers every row; nil when it could not be read (no CLI, an older Claude Code, agent view
    /// turned off). Reads only.
    @discardableResult
    public func list(profile: String) async -> [ClaudeBackgroundEntry]? {
        let profile = ResumeCommand.expanded(profile)
        if let running = reads[profile] { return await running.value }
        guard let run = dependencies.run ?? (live ? ClaudeCommandRun.live : nil) else { return nil }
        let command = ClaudeBackgroundCommand.make(.list, profile: profile, inherited: dependencies.environment())
        let timeout = dependencies.listTimeout
        let task = Task.detached(priority: .utility) { () -> [ClaudeBackgroundEntry]? in
            guard let result = run(command, timeout), result.status == 0 else { return nil }
            return ClaudeBackgroundList.parse(output: result.output)
        }
        reads[profile] = task
        let rows = await task.value
        reads[profile] = nil
        if let rows { take(rows, profile: profile) }
        return rows
    }

    /// Keeps a profile's background rows: those its last list named, by session id. A session listed under no id is
    /// not kept.
    func take(_ rows: [ClaudeBackgroundEntry], profile: String) {
        let now = engine?.dependencies.now() ?? Date()
        readAt[profile] = now
        var next = known.filter { $0.value.profile != profile }
        var others = elsewhere.filter { $0.value.profile != profile }
        for row in rows {
            guard let id = row.sessionID else { continue }
            if !row.isBackground {
                if row.pid != nil { others[id] = Known(entry: row, profile: profile, seenAt: now) }
                continue
            }
            guard row.id.map(ClaudeBackgroundCommand.isShortID) == true else { continue }
            next[id] = Known(entry: row, profile: profile, seenAt: now)
        }
        if next != known { known = next }
        if others != elsewhere { elsewhere = others }
    }

    /// Reads the list of each profile whose supervisor kept a roster (at launch): only the file's presence is looked at.
    public func readKnownProfiles(_ profiles: [String]) async {
        for profile in Set(profiles.map(ResumeCommand.expanded)).sorted() where dependencies.hasRoster(profile) {
            await list(profile: profile)
        }
    }

    public func entry(for sessionID: String) -> ClaudeBackgroundEntry? { known[sessionID]?.entry }

    /// A background session whose process has not ended for good: a session the island can fold as one.
    public func isLiveBackground(_ sessionID: String) -> Bool {
        guard let entry = known[sessionID]?.entry else { return false }
        return entry.isBackground && !entry.hasEnded
    }

    /// The session runs in Claude Code's background, so it has no tab (P1545): its list names it as a live background
    /// session, or names `pid` (its hooks' agent) as a background session's process. Its notes then carry the environment
    /// of the terminal that started the supervisor (a tmux pane, an iTerm tab), which is another session's. A stopped
    /// copy's id alone says nothing: a terminal may run the conversation again since (`claude --resume <id>`).
    public func runsInBackground(_ sessionID: String, pid: Int32?) -> Bool {
        if let pid {
            if known.values.contains(where: { $0.entry.pid == pid }) { return true }
            if elsewhere.values.contains(where: { $0.entry.pid == pid }) { return false }
        }
        guard let entry = known[sessionID]?.entry else { return false }
        return entry.pid != nil && (pid == nil || entry.pid == pid)
    }

    /// Looks for a terminal attached to the session (`claude attach <id>`), off the main thread.
    @discardableResult
    public func lookForAttached(_ sessionID: String, shortID: String) async -> Int32? {
        guard let find = dependencies.findAttached ?? (live ? ClaudeAttachScan.live : nil) else { return attached[sessionID] }
        let own = ownAttaches
        let found = await Task.detached(priority: .utility) { find(shortID).first { !own.contains($0) } }.value
        if attached[sessionID] != found { attached[sessionID] = found }
        return found
    }

    public func problem(_ sessionID: String) -> String? { problems[sessionID] }

    func clearProblem(_ sessionID: String) {
        if problems[sessionID] != nil { problems[sessionID] = nil }
    }

    /// The card's line for a reply that did not go another way (into a window attached to it).
    func say(_ sessionID: String, _ words: String) {
        if problems[sessionID] != words { problems[sessionID] = words }
    }

    // MARK: The card's commands, each on the owner's click

    /// A reply through `claude attach <id>` in a pseudo-terminal of the app's (P1460): only while its row says it is at
    /// its prompt (not busy, not waiting on an answer: typing would answer a dialog), no terminal is attached to it
    /// (the reply then goes into that window's tab, which the engine routes), and nothing else holds the conversation
    /// (P1541). `.sent` once the line and its Return were typed and the attach let go; `.nothingToSend` while its turn
    /// runs (the card holds the reply) or one is on its way.
    func reply(sessionID: String, shortID: String, line: String, folder: String, profile: String) async -> SendOutcome {
        guard ClaudeBackgroundCommand.isShortID(shortID), replying.insert(sessionID).inserted else { return .nothingToSend }
        defer { replying.remove(sessionID) }
        problems[sessionID] = nil
        // Typed only while its own list says it is at its prompt (a stopped one, listed with no process, wakes for it).
        let rows = await list(profile: profile)
        guard let rows, let entry = rows.first(where: { $0.isBackground && $0.id == shortID }) else {
            problems[sessionID] = rows == nil ? "Not sent · Claude Code did not answer" : "Not sent · Claude did not list it"
            return .notSent
        }
        // The attach would wake a stopped copy, and type into one of two live ones, beside a terminal that runs it (P1541).
        if await heldElsewhere(sessionID, copy: entry, rows: rows) {
            problems[sessionID] = "Not sent · " + Self.elsewhereWords
            return .notSent
        }
        if entry.waitsOnSomeone {
            problems[sessionID] = Self.waitsWords
            return .notSent
        }
        if entry.isBusy { return .nothingToSend }
        guard let start = dependencies.attach ?? (live ? LiveAttachTerminal.start : nil) else {
            problems[sessionID] = "Not sent"
            return .notSent
        }
        let command = ClaudeBackgroundCommand.make(.attach(shortID), profile: profile, folder: folder,
                                                   inherited: dependencies.environment())
        let terminal: any ClaudeAttachTerminal
        do {
            terminal = try await Task.detached(priority: .userInitiated) { try start(command) }.value
        } catch {
            problems[sessionID] = (error as? ResumeStartError).map { if case .toolMissing = $0 { "Not sent · Claude Code not found" } else { "Not sent · it could not start" } }
                ?? "Not sent · it could not start"
            return .notSent
        }
        let timing = dependencies.attachTiming, sleep = dependencies.sleep
        ownAttaches.insert(terminal.pid)
        let outcome = await Task.detached(priority: .userInitiated) {
            await AttachReply.send(line, through: terminal, timing: timing, sleep: sleep)
        }.value
        ownAttaches.remove(terminal.pid)
        engine?.noteFold(sessionID, .backgroundReply(outcome))
        switch outcome {
        case .sent:
            return .sent
        case let .ended(tail), let .notReady(tail):
            problems[sessionID] = tail.map { "Not sent · " + ResumeExit.cut($0, limit: 100) } ?? "Not sent · Claude did not open it"
            return .notSent
        case .notWritten:
            problems[sessionID] = "Not sent"
            return .notSent
        }
    }

    /// The line while it waits on an answer only its own prompt takes (a permission, a question, a dialog).
    public static let waitsWords = "Not sent · it waits for an answer in Claude"

    /// Why a reply or an attach did not go while something else holds the conversation (P1541).
    public static let elsewhereWords = "it is open in a terminal"

    /// Something besides its background copy holds the conversation (P1541): a live row of its id that is not that copy
    /// (an interactive one, as `claude --resume <id>` in a terminal makes once the copy stopped), the island's own resume
    /// of it, a live agent its hooks name that is not the copy's process, or a process of this user's whose arguments
    /// name its id (the copy's own and the island's attaches aside). An attach then would wake the copy beside it, and a
    /// reply would go to one of two live copies, which lose turns (Claude Code has no lock). `rows`: its profile's list,
    /// read just now.
    func heldElsewhere(_ sessionID: String, copy: ClaudeBackgroundEntry, rows: [ClaudeBackgroundEntry]) async -> Bool {
        let id = sessionID.lowercased()
        if rows.contains(where: { row in
            row.sessionID?.lowercased() == id && row.isLive && !(row.isBackground && row.id == copy.id)
        }) { return true }
        guard let engine else { return true }
        if engine.conversationResume?.isRunning(sessionID) == true { return true }
        let own = ownAttaches.union(copy.pid.map { [$0] } ?? [])
        if let pid = engine.hookNotes.contexts[sessionID]?.agentPID, !own.contains(pid), !engine.agentIsCodexServer(pid),
           engine.dependencies.processExists(pid) { return true }
        guard let find = dependencies.findAgents ?? (live ? AgentProcessScan.live : nil) else { return false }
        // The copy's own children (a tool's command) are the copy's.
        let parent = engine.dependencies.parentPID, copyPID = copy.pid
        let found = await Task.detached(priority: .userInitiated) {
            find(sessionID).filter { pid in !own.contains(pid) && !Self.descends(pid, from: copyPID, parent: parent) }
        }.value
        return !found.isEmpty
    }

    /// `pid` runs under `ancestor`, a few parents up at most.
    nonisolated static func descends(_ pid: Int32, from ancestor: Int32?, parent: (Int32) -> Int32?) -> Bool {
        guard let ancestor else { return false }
        var current = pid
        for _ in 0..<6 {
            guard let up = parent(current), up > 1 else { return false }
            if up == ancestor { return true }
            current = up
        }
        return false
    }

    /// Open in terminal for a background session: a new window of `host` (else the owner's usual terminal) typing
    /// `claude attach '<id>'` in its folder and profile, through Open in's own path (P703, P1330). Closing that window
    /// detaches and leaves the session running; the card stays. True once it opened. Never while something else holds
    /// the conversation (`rows`: its profile's list, read just now; nil when it could not be read), as the attach would
    /// wake the copy beside it (P1541): the card says so.
    func open(sessionID: String, shortID: String, folder: String, profile: String, host: FreshSessionLaunch.Host?,
              rows: [ClaudeBackgroundEntry]?) async -> Bool {
        guard ClaudeBackgroundCommand.isShortID(shortID),
              let open = dependencies.openWindow ?? (live ? FreshSessionLaunch.live : nil) else { return false }
        problems[sessionID] = nil
        let copy = rows?.first { $0.isBackground && $0.id == shortID } ?? known[sessionID]?.entry
            ?? ClaudeBackgroundEntry(id: shortID, sessionID: sessionID, kind: .background)
        if await heldElsewhere(sessionID, copy: copy, rows: rows ?? []) {
            problems[sessionID] = "Not opened · " + Self.elsewhereWords
            return false
        }
        let launch = FreshSessionLaunch(host: host ?? dependencies.usualHost(), folder: folder,
                                        line: ClaudeBackgroundCommand.attachLine(shortID: shortID, folder: folder, profile: profile))
        let opened = await Task.detached(priority: .userInitiated) { open(launch) }.value
        if opened { await lookForAttached(sessionID, shortID: shortID) }
        return opened
    }

    /// Stop for a background session: `claude stop <id>` in its profile (its conversation is kept; a reply or an attach
    /// wakes it), then its list read again. True when Claude Code said it stopped.
    func stop(sessionID: String, shortID: String, profile: String) async -> Bool {
        guard ClaudeBackgroundCommand.isShortID(shortID), let run = dependencies.run ?? (live ? ClaudeCommandRun.live : nil) else {
            return false
        }
        problems[sessionID] = nil
        let command = ClaudeBackgroundCommand.make(.stop(shortID), profile: profile, inherited: dependencies.environment())
        let timeout = dependencies.stopTimeout
        let result = await Task.detached(priority: .userInitiated) { run(command, timeout) }.value
        let stopped = result?.status == 0
        if !stopped {
            let said = result.flatMap { ResumeExit.firstLine($0.errorTail) ?? ResumeExit.firstLine($0.output) }
            problems[sessionID] = said.map { "Not stopped · " + ResumeExit.cut($0, limit: 100) } ?? "Not stopped"
        }
        await list(profile: profile)
        return stopped
    }
}

/// A Claude Code session Juice starts (Open in <account>, the welcome's Start) as a background one, behind Settings ›
/// Agents › Keep Claude sessions running when their window closes (P1470): the app runs `claude --bg` in the folder and
/// profile (no prompt: the session waits for its first one), reads the short id it printed, and the new window types
/// `claude attach '<id>'`. Closing that window leaves the session running. When `--bg` does not say it backgrounded a
/// session (an older Claude Code, agent view turned off, a folder not trusted yet), nothing is left running and the
/// window types the plain line instead, as before.
public enum ClaudeBackgroundStart {
    /// The line the new window types: the attach for the session `--bg` started, or `fallback`.
    public static func line(folder: String, profile: String, fallback: String,
                            run: @Sendable (ClaudeBackgroundCommand, TimeInterval) -> ClaudeCommandResult?,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> (line: String, started: Bool) {
        let command = ClaudeBackgroundCommand.make(.start, profile: profile, folder: folder, inherited: environment)
        guard let result = run(command, 30), result.status == 0,
              let id = ClaudeBackgroundList.backgroundedID(in: result.output) else { return (fallback, false) }
        return (ClaudeBackgroundCommand.attachLine(shortID: id, folder: folder, profile: profile), true)
    }

    /// The live start, off the main thread: only on the owner's click.
    public static func liveLine(folder: String, profile: String, fallback: String) async -> String {
        await Task.detached(priority: .userInitiated) {
            line(folder: folder, profile: profile, fallback: fallback, run: ClaudeCommandRun.live).line
        }.value
    }
}
