import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Claude Code's own background sessions (wave 8, P1450 to P1484): Send to island types `/background` into a Claude tab, the
/// island sees the tab's agent go and the conversation listed in the background (under a new id, as Claude Code does
/// now, or the same), and the card replies through a hidden `claude attach`, opens it attached in a new window and stops
/// it with `claude stop`. Headless: every `claude` command, the attach's terminal, the window, the scan and every
/// process are stand-ins; nothing here starts a CLI, types into a terminal or opens a window.
@MainActor
struct ClaudeBackgroundTests {
    typealias F = EngineFixtures
    typealias Box = EngineFixtures.Box

    nonisolated static let id = "term"
    nonisolated static let newID = "6f1c2a9e-1b7d-4c3e-9a51-2d8e0b4f7c11"
    nonisolated static let short = "0ca371e5"
    nonisolated static let folder = "/tmp/project"
    nonisolated static let profile = NSTemporaryDirectory() + "juice-bg-fixture/.claude-work"

    /// The `claude` the backgrounder runs: each command recorded, each list answered in turn (the last one again and
    /// again), stop and start as set.
    final class FakeClaude: @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [ClaudeBackgroundCommand] = []
        private var _lists: [String]
        var stopStatus: Int32 = 0
        var startOutput = "backgrounded · 7c5dcf5d\n  claude agents             list sessions"
        var startStatus: Int32 = 0

        init(lists: [String]) { _lists = lists }

        var commands: [ClaudeBackgroundCommand] { lock.withLock { _commands } }
        var lists: [ClaudeBackgroundCommand] { commands.filter { $0.verb == .list } }
        func answer(_ lists: [String]) { lock.withLock { _lists = lists } }

        func run(_ command: ClaudeBackgroundCommand, _ timeout: TimeInterval) -> ClaudeCommandResult? {
            lock.withLock {
                _commands.append(command)
                switch command.verb {
                case .list:
                    let output = _lists.count > 1 ? _lists.removeFirst() : (_lists.first ?? "[]")
                    return output == "fail" ? ClaudeCommandResult(status: 1, output: "", errorTail: "unknown command") : ClaudeCommandResult(status: 0, output: output)
                case let .stop(id): return ClaudeCommandResult(status: stopStatus, output: stopStatus == 0 ? "stopped \(id)" : "", errorTail: stopStatus == 0 ? "" : "no such session")
                case .start: return ClaudeCommandResult(status: startStatus, output: startOutput)
                case .attach: return nil
                }
            }
        }
    }

    /// The attach's terminal: it has drawn itself (`drawn` bytes) and stays quiet; a Return makes it draw again; Ctrl+Z
    /// ends it, unless `holdsOn`.
    final class FakeTerminal: ClaudeAttachTerminal, @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int
        private var exited: Bool
        private var _writes: [[UInt8]] = []
        private var _hungUp = false
        private var _terminated = false
        private var _killed = false
        let holdsOn: Bool
        /// SIGTERM does not end it either: only SIGKILL does.
        let onlyKillEnds: Bool
        let tail: String
        let pid: Int32 = 7001

        init(drawn: Int = 4_096, endedAtStart: Bool = false, holdsOn: Bool = false, onlyKillEnds: Bool = false, tail: String = "") {
            bytes = drawn
            exited = endedAtStart
            self.holdsOn = holdsOn
            self.onlyKillEnds = onlyKillEnds
            self.tail = tail
        }

        var writes: [[UInt8]] { lock.withLock { _writes } }
        var hungUp: Bool { lock.withLock { _hungUp } }
        var terminated: Bool { lock.withLock { _terminated } }
        var killed: Bool { lock.withLock { _killed } }
        var typed: String { String(decoding: writes.first ?? [], as: UTF8.self) }

        var hasExited: Bool { lock.withLock { exited } }
        func seen() -> AttachSeen { lock.withLock { AttachSeen(bytes: bytes, tail: tail) } }
        func write(_ bytes: [UInt8]) -> Bool {
            lock.withLock {
                guard !exited else { return false }
                _writes.append(bytes)
                if bytes == [AttachReply.carriageReturn] { self.bytes += 64 }
                if bytes == [AttachReply.controlZ], !holdsOn { exited = true }
                return true
            }
        }
        func hangUp() { lock.withLock { _hungUp = true; if !holdsOn { exited = true } } }
        func terminate() { lock.withLock { _terminated = true; if !onlyKillEnds { exited = true } } }
        func kill() { lock.withLock { _killed = true; exited = true } }
    }

    @MainActor
    struct Rig {
        let base: FoldStopTests.Rig
        /// Whether the session's tab is the one in front (the frontmost check that keeps a focused session quiet).
        let inFront: Box<Bool>
        let claude: FakeClaude
        let terminals: Box<[FakeTerminal]>
        let attaches: Box<[ClaudeBackgroundCommand]>
        let windows: Box<[FreshSessionLaunch]>
        let attached: Box<[Int32]>
        let nextTerminal: Box<FakeTerminal>
        /// This user's processes whose arguments name the conversation's id (`claude --resume <id>`, P1541).
        let found: Box<[Int32]>
        var engine: SessionEngine { base.engine }
        var typed: [(ReplyRoute, String)] { base.typed.current }

        /// Each look of the move, as its clock and the list let it go, `looks` times.
        func look(_ looks: Int = 1, id: String = ClaudeBackgroundTests.id) async {
            for _ in 0..<looks {
                base.runChecks(2)
                await engine.backgroundMoveStarted(id)
            }
        }
    }

    /// FoldStopTests' rig (a Claude agent and its shell in a Terminal tab, every seam a stand-in), with the tab's
    /// frontmost check of its own.
    static func baseRig(inFront: Box<Bool>) -> FoldStopTests.Rig {
        typealias S = FoldStopTests
        let typed = Box<[(ReplyRoute, String)]>([]), tucks = Box<[TerminalTuck.Move]>([])
        let scheduled = Box<[F.ScheduledCheck]>([]), clock = Box(F.now), alive = Box<Set<Int32>>([S.agent, S.shell])
        let watched = Box<[(Int32, @MainActor @Sendable () -> Void)]>([]), cancelled = Box(0)
        let names = Box<[Int32: String]>([S.agent: "claude", S.shell: "zsh"])
        let calls = ExactJumpTests.Calls()
        let runner = ExactJumpTests.runner(calls: calls, running: [ExactJumpTests.terminal], frontmost: ExactJumpTests.terminal,
                                           script: { _ in "matched\u{1f}\(S.tty)" })
        let engine = F.engine(clock: clock, scheduled: scheduled, isFrontmost: { _ in inFront.current }, replies: { route, text in
            typed.update { $0.append((route, text)) }
            return true
        }, atPrompt: { alive.current.contains($0) }) { dependencies in
            dependencies.ttyForPID = { alive.current.contains($0) ? S.tty : nil }
            dependencies.processExists = { alive.current.contains($0) }
            dependencies.parentPID = { $0 == S.agent ? S.shell : nil }
            dependencies.processName = { alive.current.contains($0) ? names.current[$0] : nil }
            dependencies.jumpRunner = runner
            dependencies.tuckWindow = { move, _ in
                tucks.update { $0.append(move) }
                return move == .untuck ? .restored : .tucked(TuckBounds(left: 100, top: 80, right: 900, bottom: 600))
            }
            dependencies.scheduleFoldCheck = { delay, check in
                scheduled.update { $0.append(F.ScheduledCheck(at: clock.current.addingTimeInterval(delay), run: check)) }
            }
            dependencies.watchProcessExit = { pid, exited in
                watched.update { $0.append((pid, exited)) }
                return FoldStopTests.Token { cancelled.update { $0 += 1 } }
            }
        }
        let resume = SessionFoldTests.FakeResume()
        engine.conversationResume = resume
        return FoldStopTests.Rig(engine: engine, resume: resume, typed: typed, tucks: tucks, scheduled: scheduled, clock: clock,
                                 alive: alive, watches: watched, cancelled: cancelled, names: names)
    }

    static func rig(lists: [String], keepsRunning: Bool = true, attached: [Int32] = [], terminal: FakeTerminal = FakeTerminal()) -> Rig {
        let inFront = Box(false)
        let base = Self.baseRig(inFront: inFront)
        let claude = FakeClaude(lists: lists)
        let terminals = Box<[FakeTerminal]>([]), attaches = Box<[ClaudeBackgroundCommand]>([])
        let windows = Box<[FreshSessionLaunch]>([]), attachedBox = Box(attached), next = Box(terminal), found = Box<[Int32]>([])
        var dependencies = ClaudeBackgrounder.Dependencies()
        dependencies.run = { claude.run($0, $1) }
        dependencies.attach = { command in
            attaches.update { $0.append(command) }
            let terminal = next.current
            terminals.update { $0.append(terminal) }
            return terminal
        }
        dependencies.openWindow = { launch in
            windows.update { $0.append(launch) }
            return true
        }
        dependencies.findAttached = { _ in attachedBox.current }
        dependencies.findAgents = { _ in found.current }
        dependencies.hasRoster = { _ in false }
        dependencies.usualHost = { .terminal }
        dependencies.environment = { ["SHELL": "/bin/zsh", "OPEN_ISLAND_SKIP_HOOKS": "1", "__CFBundleIdentifier": "com.ofengenden.juice"] }
        dependencies.sleep = { _ in await Task.yield() }
        let engine = base.engine
        engine.claudeBackground = ClaudeBackgrounder(engine: engine, dependencies: dependencies)
        engine.keepsClaudeRunning = keepsRunning
        return Rig(base: base, inFront: inFront, claude: claude, terminals: terminals, attaches: attaches, windows: windows, attached: attachedBox,
                   nextTerminal: next, found: found)
    }

    /// A Claude Code session working in a Terminal tab, in the `.claude-work` profile (its transcript says so).
    static func session(_ engine: SessionEngine, finished: Bool = false) {
        FoldStopTests.session(engine, id, finished: finished)
        engine.ingest(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
            transcriptPath: profile + "/projects/-tmp-project/\(id).jsonl", lastAssistantMessage: "Split the retries out."), timestamp: F.now)),
            ingress: .bridge)
    }

    // MARK: The list (P1457)

    static func row(_ kind: String, id: String? = nil, session: String?, name: String? = "fix the flaky upload test",
                    state: String? = nil, status: String? = "busy", waitingFor: String? = nil, pid: Int? = 4242,
                    cwd: String = folder, startedAt: Double = 1_800_000_010_000) -> [String: Any] {
        var row: [String: Any] = ["kind": kind, "cwd": cwd, "startedAt": startedAt]
        if let id { row["id"] = id }
        if let session { row["sessionId"] = session }
        if let name { row["name"] = name }
        if let state { row["state"] = state }
        if let status { row["status"] = status }
        if let waitingFor { row["waitingFor"] = waitingFor }
        if let pid { row["pid"] = pid }
        return row
    }

    static func json(_ rows: [[String: Any]]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
    }

    /// The tab's own interactive row, before `/background`.
    static let before = json([row("interactive", session: id, pid: Int(FoldStopTests.agent)),
                              row("background", id: "a1b2c3d4", session: "11111111-2222-3333-4444-555555555555", name: "other work",
                                  state: "done", status: "idle")])
    /// After `/background`: the tab's row gone, the conversation's background row there under a new id.
    static let after = json([row("background", id: short, session: newID, state: "working", status: "busy"),
                             row("background", id: "a1b2c3d4", session: "11111111-2222-3333-4444-555555555555", name: "other work",
                                 state: "done", status: "idle")])

    @Test
    func theListReadsTheShapeSeenOnTheOwnersMac() throws {
        // As `claude agents --json` printed it: cwd, id, kind, name, pid, sessionId, startedAt, state, status.
        let output = "Starting background service…\n" + #"[{"cwd":"/tmp/project","id":"0ca371e5","kind":"background","name":"fix it","pid":4242,"sessionId":"6f1c2a9e-1b7d-4c3e-9a51-2d8e0b4f7c11","startedAt":1790000000000,"state":"working","status":"busy"},{"cwd":"/tmp","kind":"interactive","pid":900,"sessionId":"term","startedAt":1790000000000,"status":"waiting","waitingFor":"permission prompt"}]"#
        let rows = try #require(ClaudeBackgroundList.parse(output: output))
        #expect(rows.count == 2)
        #expect(rows[0] == ClaudeBackgroundEntry(id: "0ca371e5", sessionID: Self.newID, kind: .background, state: "working", status: "busy",
                                                 pid: 4242, cwd: "/tmp/project", name: "fix it", startedAt: Date(timeIntervalSince1970: 1_790_000_000)))
        #expect(rows[0].isBusy && !rows[0].waitsOnSomeone && !rows[0].hasEnded)
        #expect(rows[1].kind == .interactive && rows[1].waitsOnSomeone && rows[1].id == nil)
        #expect(ClaudeBackgroundList.parse(output: "error: unknown command 'agents'") == nil)
        #expect(ClaudeBackgroundList.parse(Data("{}".utf8)) == nil)
        #expect(ClaudeBackgroundList.backgroundedID(in: "backgrounded · 0ca371e5\n  claude agents") == "0ca371e5")
        #expect(ClaudeBackgroundList.backgroundedID(in: "Starting background service…\nbackgrounded · 7c5dcf5d · flaky-test-fix") == "7c5dcf5d")
        #expect(ClaudeBackgroundList.backgroundedID(in: "note: could not start") == nil)
        #expect(ClaudeBackgroundCommand.isShortID("0ca371e5") && !ClaudeBackgroundCommand.isShortID("0ca'; rm") && !ClaudeBackgroundCommand.isShortID(""))
    }

    /// Every command names only the short id, never the owner's text; none carries the island's skip switches or the
    /// app's own bundle id (the supervisor it may start would pass them to every background session); the profile's
    /// folder variable only for a folder that is not the default (P1457).
    @Test
    func theCommandsCarryNoTextNoSkipSwitchAndTheProfilesFolder() {
        // The island's own skip switches by their one list (`CLIEnvironment.islandSkipKeys`), never spelled here: the
        // public export's scan keeps the other island's name to the files that find its hooks.
        var inherited = ["SHELL": "/bin/zsh", "__CFBundleIdentifier": "com.ofengenden.juice", "CLAUDE_CODE_ENTRYPOINT": "cli",
                         "SSH_AUTH_SOCK": "/tmp/agent.sock"]
        for key in CLIEnvironment.islandSkipKeys { inherited[key] = "1" }
        let home = "/Users/someone"
        let list = ClaudeBackgroundCommand.make(.list, profile: home + "/.claude-work", inherited: inherited, home: home)
        #expect(list.arguments == ["agents", "--json", "--all"])
        #expect(list.environment["CLAUDE_CONFIG_DIR"] == home + "/.claude-work")
        for key in CLIEnvironment.islandSkipKeys + ["__CFBundleIdentifier", "CLAUDE_CODE_ENTRYPOINT"] {
            #expect(list.environment[key] == nil)
        }
        #expect(list.environment["TERM"] == "xterm-256color" && list.environment["SSH_AUTH_SOCK"] == "/tmp/agent.sock")
        let attach = ClaudeBackgroundCommand.make(.attach(Self.short), profile: home + "/.claude", folder: "/tmp/project", inherited: inherited, home: home)
        #expect(attach.arguments == ["attach", Self.short] && attach.environment["CLAUDE_CONFIG_DIR"] == nil && attach.folder == "/tmp/project")
        #expect(ClaudeBackgroundCommand.make(.stop(Self.short), profile: home + "/.claude", inherited: [:], home: home).arguments == ["stop", Self.short])
        let start = ClaudeBackgroundCommand.make(.start, profile: home + "/.claude", folder: "/tmp/project", inherited: [:], home: home)
        #expect(start.arguments == ["--bg", "--settings", #"{"worktree":{"bgIsolation":"none"}}"#])
        #expect(ClaudeBackgroundCommand.attachLine(shortID: Self.short, folder: "/tmp/my project", profile: home + "/.claude-work", home: home)
            == "cd '/tmp/my project' && CLAUDE_CONFIG_DIR='\(home)/.claude-work' claude attach '0ca371e5'")
        #expect(ClaudeBackgroundCommand.attachLine(shortID: Self.short, folder: "/tmp/p", profile: home + "/.claude", home: home)
            == "cd '/tmp/p' && claude attach '0ca371e5'")
    }

    // MARK: The move (P1450 to P1456)

    /// The owner's sequence: a working Claude session sent to the island; `/background` typed into its tab once, its tab's agent
    /// gone, the conversation listed in the background under a new id; the card follows it there, the old id's row stays
    /// out of the list, and closing the window afterwards is no stop.
    @Test
    func sendToIslandMovesAWorkingSessionIntoTheBackgroundAndFollowsItsNewID() async throws {
        let rig = Self.rig(lists: [Self.before, Self.after])
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        #expect(rig.typed.map(\.1) == ["/background"])
        #expect(rig.typed.first.map { $0.0 } == .terminal(tty: FoldStopTests.tty))
        #expect(rig.engine.foldBackground(Self.id)?.stage == .moving)
        // A reply meanwhile waits for the move: the tab holds a shell now, or soon.
        #expect(rig.engine.foldReach(Self.id) == .background && rig.engine.foldTurnRuns(Self.id))
        #expect(rig.claude.lists.first?.environment["CLAUDE_CONFIG_DIR"] == ResumeCommand.expanded(Self.profile))
        // While the tab's agent still runs, nothing is taken for moved.
        await rig.look(2)
        #expect(rig.engine.foldBackground(Self.id)?.stage == .moving)
        // Claude Code frees the tab: its agent exits, its shell stays.
        rig.base.alive.update { $0.remove(FoldStopTests.agent) }
        for (pid, exited) in rig.base.watches.current where pid == FoldStopTests.agent { exited() }
        await rig.look()
        #expect(rig.engine.folds[Self.id] == nil)
        let fold = try #require(rig.engine.folds[Self.newID])
        #expect(fold.background?.stage == .moved && fold.background?.shortID == Self.short && fold.background?.movedFrom == Self.id)
        #expect(fold.stopped == nil && fold.turnOpen)
        #expect(rig.engine.isFolded(Self.id) && rig.engine.movedConversation(from: Self.id) == Self.newID)
        #expect(rig.engine.foldReach(Self.newID) == .background)
        // The owner closes the window from the Dock: nothing stops.
        rig.base.closeWindow()
        rig.base.runChecks(5)
        #expect(rig.engine.folds[Self.newID]?.stopped == nil)
        #expect(rig.typed.map(\.1) == ["/background"])
        let said = rig.engine.foldNotes.map(\.said)
        #expect(said.contains("background · /background typed") && said.contains("background · moved, under a new id"))
        #expect(!said.contains { $0.hasPrefix("stopped mid-turn") })
    }

    @Test
    func aConversationKeptUnderItsOwnIDStaysUnderIt() async {
        let same = Self.json([Self.row("background", id: Self.short, session: Self.id, state: "working")])
        let rig = Self.rig(lists: [Self.before, same])
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        rig.base.alive.update { $0.remove(FoldStopTests.agent) }
        await rig.look()
        #expect(rig.engine.folds[Self.id]?.background?.stage == .moved)
        #expect(rig.engine.movedConversations.isEmpty)
        #expect(rig.engine.foldNotes.map(\.said).contains("background · moved"))
    }

    /// No list (an older Claude Code, agent view off): nothing is typed, and the card is a tab's card as before.
    @Test
    func withNoListNothingIsTyped() async {
        let rig = Self.rig(lists: ["fail"])
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        #expect(rig.typed.isEmpty)
        #expect(rig.engine.foldBackground(Self.id) == nil && rig.engine.foldReach(Self.id) == .tab)
        #expect(rig.engine.foldNotes.map(\.said).contains("background · not offered by this Claude Code"))
    }

    /// The switch off: no list is read and nothing is typed (P1450).
    @Test
    func withTheSwitchOffNothingRunsOrIsTyped() async {
        let rig = Self.rig(lists: [Self.before], keepsRunning: false)
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        #expect(rig.typed.isEmpty && rig.claude.commands.isEmpty && rig.engine.foldBackground(Self.id) == nil)
    }

    /// An approval waits in the tab: typing would answer it, so nothing is typed until the turn ends; then `/background`, a
    /// second after, unless the tab is in front (P1452, P1453).
    @Test(arguments: [false, true])
    func aWaitingRequestHoldsTheMoveUntilTheTurnEnds(inFront: Bool) async throws {
        let rig = Self.rig(lists: [Self.before, Self.after])
        let broker = AttentionScene.StubBroker()
        rig.engine.hookRequestBroker = broker
        Self.session(rig.engine)
        let request = try #require(FoldStopTests.askBash(rig.base, broker, Self.id))
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        #expect(rig.typed.isEmpty && rig.engine.foldBackground(Self.id)?.stage == .waitsForTurnEnd)
        #expect(rig.engine.foldReach(Self.id) == .tab)
        #expect(rig.engine.foldNotes.map(\.said).contains("background · moves when its turn ends"))
        // Its turn ends (No and stop here; a Stop does the same): `/background` goes a second later.
        rig.inFront.update { $0 = inFront }
        #expect(await rig.engine.approve(requestID: request, decision: .denyAndStop) == .sent)
        rig.base.runChecks(2)
        await rig.engine.backgroundMoveStarted(Self.id)
        if inFront {
            #expect(rig.typed.isEmpty)
            #expect(rig.engine.foldBackground(Self.id)?.stage == .notMoved(.tabInFront))
        } else {
            #expect(rig.typed.map(\.1) == ["/background"])
            #expect(rig.engine.foldBackground(Self.id)?.stage == .moving)
        }
    }

    /// The tab's agent never leaves (a dialog asks first in the tab, or the line sat unsent): while its turn runs the
    /// looks go on uncounted (Claude Code may hold a `/background` typed mid-turn until the turn ends, P1451); once it ended and
    /// the looks ran out, the card says so, nothing more is typed into the tab and no resume runs: Open in terminal
    /// shows the owner what is there (P1454, P1457).
    @Test
    func aMoveTheTabNeverLetGoOfSaysSoAndTypesNoMore() async {
        let rig = Self.rig(lists: [Self.before, Self.before])
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        await rig.look(SessionEngine.moveLooks + 2)
        #expect(rig.engine.foldBackground(Self.id)?.stage == .moving)
        rig.engine.ingest(F.completed(Self.id, at: rig.base.clock.current), ingress: .bridge)
        await rig.look(SessionEngine.moveLooks + 2)
        #expect(rig.engine.foldBackground(Self.id)?.stage == .notMoved(.stillInTab))
        #expect(rig.engine.foldReach(Self.id) == .openOnly)
        await rig.engine.replyFolded(sessionID: Self.id, text: "yes")
        #expect(rig.typed.map(\.1) == ["/background"])
        #expect(rig.base.resume.continued.isEmpty)
    }

    /// `/background` held by Claude Code until the turn's end: the agent leaves then, and the move is seen (P1451).
    @Test
    func aBgHeldUntilTheTurnsEndMovesThen() async {
        let rig = Self.rig(lists: [Self.before, Self.after])
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        await rig.look(SessionEngine.moveLooks * 3)
        #expect(rig.engine.foldBackground(Self.id)?.stage == .moving)
        rig.engine.ingest(F.completed(Self.id, at: rig.base.clock.current), ingress: .bridge)
        rig.base.alive.update { $0.remove(FoldStopTests.agent) }
        await rig.look()
        #expect(rig.engine.folds[Self.newID]?.background?.stage == .moved)
    }

    /// The tab's agent left (its window closed), but two new background rows could be it: the island never guesses,
    /// says no stop (it may run there), and Open in terminal never opens the resume, which would be a second live copy;
    /// once the list tells which it is, Open in terminal attaches to it (P1454, P1457).
    @Test
    func twoRowsThatCouldBeItAreNotGuessedBetween() async {
        let two = Self.json([Self.row("background", id: Self.short, session: Self.newID),
                             Self.row("background", id: "deadbeef", session: "99999999-2222-3333-4444-555555555555")])
        let rig = Self.rig(lists: [Self.before, two])
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        rig.base.closeWindow()
        await rig.look(SessionEngine.moveLooks + 2)
        #expect(rig.engine.foldBackground(Self.id)?.stage == .notMoved(.cannotTell))
        #expect(rig.engine.folds[Self.newID] == nil)
        #expect(rig.engine.foldReach(Self.id) == .openOnly)
        rig.base.runChecks(3)
        #expect(rig.engine.folds[Self.id]?.stopped == nil)
        _ = await rig.engine.openFolded(sessionID: Self.id)
        #expect(rig.base.resume.opened.isEmpty && rig.windows.current.isEmpty)
        #expect(rig.engine.folds[Self.id]?.notOpened == true)
        // Its list tells now: one new row.
        rig.claude.answer([Self.json([Self.row("background", id: Self.short, session: Self.newID)])])
        _ = await rig.engine.openFolded(sessionID: Self.id)
        #expect(rig.engine.folds[Self.newID]?.background?.stage == .moved && rig.engine.movedConversation(from: Self.id) == Self.newID)
        #expect(rig.windows.current.map(\.line).last?.hasSuffix("claude attach '0ca371e5'") == true)
        #expect(rig.base.resume.opened.isEmpty)
    }

    /// The tab's agent left with nothing new listed at all (its window closed right after the fold): it did not move,
    /// so the card is wave 7's: stopped when its window closed, with Continue through the resume (P1415, P1457).
    @Test
    func aTabWhoseAgentLeftWithNothingNewListedDidNotMove() async {
        let rig = Self.rig(lists: [Self.before, Self.before])
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        rig.base.closeWindow()
        await rig.look(SessionEngine.moveLooks + 2)
        #expect(rig.engine.foldBackground(Self.id)?.stage == .notMoved(.notListed))
        rig.base.runChecks(2)
        #expect(rig.engine.folds[Self.id]?.stopped?.windowClosed == true)
        #expect(rig.engine.foldReach(Self.id) == .resume(note: nil))
        await rig.engine.continueFolded(sessionID: Self.id)
        #expect(rig.base.resume.continued.map(\.1) == [SessionEngine.continuePrompt])
    }

    /// A move that did not show while its tab's agent stayed (a dialog asked first), whose agent then leaves: it is
    /// looked at again and seen in the background (P1457).
    @Test
    func aMoveThatDidNotShowIsLookedAtAgainWhenItsAgentLeaves() async {
        let rig = Self.rig(lists: [Self.before, Self.before])
        Self.session(rig.engine, finished: true)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        await rig.look(SessionEngine.moveLooks + 2)
        #expect(rig.engine.foldBackground(Self.id)?.stage == .notMoved(.stillInTab))
        // The owner answers the dialog in its tab: Claude Code moves it, and its agent leaves.
        rig.claude.answer([Self.after])
        rig.base.alive.update { $0.remove(FoldStopTests.agent) }
        for (pid, exited) in rig.base.watches.current where pid == FoldStopTests.agent { exited() }
        #expect(rig.engine.foldBackground(Self.id)?.stage == .moving)
        await rig.look()
        #expect(rig.engine.folds[Self.newID]?.background?.stage == .moved)
        #expect(rig.typed.map(\.1) == ["/background"])
        #expect(rig.engine.foldNotes.map(\.said).contains("background · its tab's agent ended · looking again"))
    }

    /// A dialog the owner has open in its tab (a picker, a setting) has no hook, but its own row says it waits: nothing
    /// is typed into it; the move waits, and goes after a turn that ends with that row at its prompt (P1453).
    @Test
    func aDialogOpenInTheTabAtTheFoldKeepsTheMoveWaiting() async throws {
        let open = Self.json([Self.row("interactive", session: Self.id, status: "waiting", waitingFor: "dialog open",
                                       pid: Int(FoldStopTests.agent))])
        let rig = Self.rig(lists: [open])
        Self.session(rig.engine, finished: true)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        #expect(rig.typed.isEmpty && rig.engine.foldBackground(Self.id)?.stage == .waitsForTurnEnd)
        // A turn ends while the dialog's row still waits: nothing typed.
        rig.engine.ingest(F.prompt(Self.id, at: rig.base.clock.current), ingress: .bridge)
        rig.engine.ingest(F.completed(Self.id, at: rig.base.clock.current), ingress: .bridge)
        rig.base.runChecks(2)
        await rig.engine.backgroundMoveStarted(Self.id)
        #expect(rig.typed.isEmpty)
        // The dialog closed: the next turn's end moves it.
        rig.claude.answer([Self.before])
        rig.engine.ingest(F.prompt(Self.id, at: rig.base.clock.current), ingress: .bridge)
        rig.engine.ingest(F.completed(Self.id, at: rig.base.clock.current), ingress: .bridge)
        rig.base.runChecks(2)
        try await Self.until { rig.typed.count == 1 }
        #expect(rig.typed.map(\.1) == ["/background"])
    }

    /// Claude Code asks first in the tab ("Background this session?"): its own row says a dialog is open, and the card
    /// says so within a few looks instead of "Moving…"; once the owner answers there and its agent leaves, the move is
    /// seen (P1457).
    @Test
    func aDialogClaudeOpensInTheTabSaysSoAndTheMoveIsSeenAfterIt() async {
        let asks = Self.json([Self.row("interactive", session: Self.id, status: "waiting", waitingFor: "dialog open",
                                       pid: Int(FoldStopTests.agent))])
        let rig = Self.rig(lists: [Self.before, asks])
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        await rig.look(SessionEngine.stayingListEvery + 1)
        #expect(rig.engine.foldBackground(Self.id)?.stage == .notMoved(.asksInItsTab))
        #expect(rig.engine.foldReach(Self.id) == .openOnly)
        rig.claude.answer([Self.after])
        rig.base.alive.update { $0.remove(FoldStopTests.agent) }
        for (pid, exited) in rig.base.watches.current where pid == FoldStopTests.agent { exited() }
        await rig.look()
        #expect(rig.engine.folds[Self.newID]?.background?.stage == .moved)
        #expect(rig.typed.map(\.1) == ["/background"])
    }

    /// Open in terminal while the move is under way and its agent still holds the tab: the tab comes back, the card
    /// stays, and the resume never opens (P1457).
    @Test
    func openInTerminalWhileItMovesBringsItsTabAndNeverTheResume() async {
        let rig = Self.rig(lists: [Self.before, Self.before])
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        _ = await rig.engine.openFolded(sessionID: Self.id)
        #expect(rig.base.tucks.current.contains(.untuck))
        #expect(rig.base.resume.opened.isEmpty && rig.windows.current.isEmpty)
        #expect(rig.engine.foldBackground(Self.id)?.stage == .moving)
    }

    /// A reply held for its tab while the move waits goes first, into the tab; the move then waits for the end of the
    /// turn that reply started, so the owner's text never lands in the shell the tab holds after the move.
    @Test
    func aReplyHeldForItsTabGoesBeforeTheMoveThatWaited() async throws {
        let rig = Self.rig(lists: [Self.before, Self.after])
        let broker = AttentionScene.StubBroker()
        rig.engine.hookRequestBroker = broker
        Self.session(rig.engine)
        let request = try #require(FoldStopTests.askBash(rig.base, broker, Self.id))
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        #expect(rig.engine.foldBackground(Self.id)?.stage == .waitsForTurnEnd)
        await rig.engine.replyFolded(sessionID: Self.id, text: "then run the tests")
        #expect(rig.engine.folds[Self.id]?.held == "then run the tests" && rig.engine.folds[Self.id]?.heldWay == .tab)
        #expect(await rig.engine.approve(requestID: request, decision: .denyAndStop) == .sent)
        rig.base.runChecks(2)
        // Typed, and its send come back: under load the send's answer reaches the engine well after the keys went, and
        // the move's look it schedules then would land after the test's own clock had moved on (P1547).
        try await Self.until { rig.typed.count == 1 && rig.engine.folds[Self.id]?.send != .sending }
        #expect(rig.typed.map(\.1) == ["then run the tests"])
        // The reply's own turn: the move waits for its end.
        rig.engine.ingest(F.prompt(Self.id, at: rig.base.clock.current), ingress: .bridge)
        rig.base.runChecks(2)
        await rig.engine.backgroundMoveStarted(Self.id)
        #expect(rig.typed.map(\.1) == ["then run the tests"])
        rig.engine.ingest(F.completed(Self.id, at: rig.base.clock.current), ingress: .bridge)
        rig.base.runChecks(2)
        try await Self.until { rig.typed.count == 2 }
        #expect(rig.typed.map(\.1) == ["then run the tests", "/background"])
        #expect(rig.engine.foldBackground(Self.id)?.stage == .moving)
    }

    @Test
    func theMovedRowIsTheNewOneOfItsNameThenOfItsFolder() {
        var background = FoldBackground(stage: .moving, profile: Self.profile, folder: Self.folder)
        background.before = ["a1b2c3d4"]
        background.name = "fix it"
        background.typedAt = F.now
        let after = F.now.addingTimeInterval(2)
        let old = ClaudeBackgroundEntry(id: "a1b2c3d4", sessionID: "x", kind: .background, cwd: Self.folder, name: "fix it")
        let renamed = ClaudeBackgroundEntry(id: Self.short, sessionID: Self.newID, kind: .background, cwd: Self.folder, name: "fix it (2)",
                                            startedAt: after)
        let elsewhere = ClaudeBackgroundEntry(id: "deadbeef", sessionID: "y", kind: .background, cwd: "/tmp/other", name: "fix it",
                                              startedAt: after)
        // Two of its name: the one in its folder.
        #expect(SessionEngine.movedRow([old, renamed, elsewhere], sessionID: Self.id, background: background) == renamed)
        // One of its name, in another folder (the copy may start in the tree it came from): that one.
        #expect(SessionEngine.movedRow([old, elsewhere], sessionID: Self.id, background: background) == elsewhere)
        // Its own id wins.
        let same = ClaudeBackgroundEntry(id: "c0ffee00", sessionID: Self.id, kind: .background, cwd: "/elsewhere")
        #expect(SessionEngine.movedRow([renamed, same], sessionID: Self.id, background: background) == same)
        // A row that started well before `/background` was typed is another session's.
        var older = renamed
        older.startedAt = F.now.addingTimeInterval(-60)
        #expect(SessionEngine.movedRow([old, older], sessionID: Self.id, background: background) == nil)
        // No name: the one new row of its folder, never one elsewhere.
        background.name = nil
        var unnamed = renamed
        unnamed.name = "something else"
        #expect(SessionEngine.movedRow([old, unnamed], sessionID: Self.id, background: background) == unnamed)
        #expect(SessionEngine.movedRow([old, elsewhere], sessionID: Self.id, background: background) == nil)
    }

    // MARK: The card of a background session (P1458 to P1465)

    /// A moved session's rig: in the background under its new id, its tab gone.
    static func moved(lists: [String] = [after], attached: [Int32] = [], terminal: FakeTerminal = FakeTerminal()) async -> Rig {
        let rig = Self.rig(lists: [Self.before] + lists, attached: attached, terminal: terminal)
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        rig.base.alive.update { $0.remove(FoldStopTests.agent) }
        await rig.look()
        return rig
    }

    /// The turn goes on in the background: Working from its row and its hooks; the row's `done` ends it for a session
    /// whose hooks said nothing; its list is read once a minute while the card shows (P1458, P1459).
    @Test
    func theCardFollowsItsRowOnceAMinute() async {
        let done = Self.json([Self.row("background", id: Self.short, session: Self.newID, state: "done", status: "idle")])
        let rig = await Self.moved(lists: [Self.after, done])
        #expect(rig.engine.foldTurnRuns(Self.newID))
        #expect(rig.base.scheduled.current.contains { abs($0.at.timeIntervalSince(rig.base.clock.current) - 60) < 2.5 })
        await rig.engine.readBackgroundLists()
        #expect(!rig.engine.foldTurnRuns(Self.newID))
        #expect(rig.engine.folds[Self.newID]?.background?.listed?.state == "done")
    }

    /// A reply at its prompt goes through `claude attach <id>` in a terminal of the app's: the line, then Return on its
    /// own, then Ctrl+Z; the owner's text is never an argument (P1460, P1325).
    @Test
    func aReplyGoesThroughAHiddenAttachAndLetsGo() async {
        let idle = Self.json([Self.row("background", id: Self.short, session: Self.newID, state: "done", status: "idle")])
        let rig = await Self.moved(lists: [idle])
        await rig.engine.readBackgroundLists()
        await rig.engine.replyFolded(sessionID: Self.newID, text: "-rf also run the linter\nplease")
        #expect(rig.attaches.current.map(\.arguments) == [["attach", Self.short]])
        #expect(rig.attaches.current.first?.environment["CLAUDE_CONFIG_DIR"] == ResumeCommand.expanded(Self.profile))
        #expect(rig.attaches.current.first?.folder == Self.folder)
        let terminal = rig.terminals.current.first
        #expect(terminal?.writes == [Array("-rf also run the linter please".utf8), [AttachReply.carriageReturn], [AttachReply.controlZ]])
        #expect(terminal?.terminated == false)
        #expect(rig.claude.commands.allSatisfy { !$0.arguments.contains { $0.contains("linter") } })
        #expect(rig.engine.folds[Self.newID]?.send == .sent)
        #expect(rig.engine.foldNotes.map(\.said).contains("background · reply typed through the attach"))
    }

    /// While its row says it waits on an answer only its own prompt takes, nothing is typed (P1460).
    @Test
    func aReplyToASessionThatWaitsOnAnAnswerIsNotTyped() async {
        let waiting = Self.json([Self.row("background", id: Self.short, session: Self.newID, state: "blocked", status: "waiting",
                                          waitingFor: "permission prompt")])
        let rig = await Self.moved(lists: [waiting])
        await rig.engine.readBackgroundLists()
        rig.engine.folds[Self.newID]?.turnOpen = false
        await rig.engine.replyFolded(sessionID: Self.newID, text: "yes")
        #expect(rig.attaches.current.isEmpty)
        #expect(rig.engine.folds[Self.newID]?.send == .notSent)
        #expect(rig.engine.claudeBackground?.problem(Self.newID) == ClaudeBackgrounder.waitsWords)
    }

    /// A reply while its turn runs waits for the turn's end, as every reply does (P1306).
    @Test
    func aReplyWhileItWorksInTheBackgroundIsHeld() async {
        let rig = await Self.moved()
        await rig.engine.replyFolded(sessionID: Self.newID, text: "then push")
        #expect(rig.engine.folds[Self.newID]?.held == "then push" && rig.engine.folds[Self.newID]?.heldWay == .background)
        #expect(rig.attaches.current.isEmpty)
    }

    /// A window attached to it: the reply goes into that window's tab, never through a second attach (P1461).
    @Test
    func aReplyToASessionAttachedInAWindowIsTypedThere() async {
        let idle = Self.json([Self.row("background", id: Self.short, session: Self.newID, state: "done", status: "idle")])
        let rig = await Self.moved(lists: [idle], attached: [5150])
        rig.engine.folds[Self.newID]?.turnOpen = false
        await rig.engine.readBackgroundLists()
        #expect(rig.engine.folds[Self.newID]?.background?.attachedIn != nil)
        // The attach runs in a Terminal tab: its tty, as the tab's route finds it.
        rig.base.alive.update { $0.insert(5150) }
        await rig.engine.replyFolded(sessionID: Self.newID, text: "ship it")
        #expect(rig.attaches.current.isEmpty)
        #expect(rig.typed.last.map { $0.0 } == .terminal(tty: FoldStopTests.tty) && rig.typed.last?.1 == "ship it")
    }

    /// The attach that never settles, or that Claude Code refuses, types nothing and says why.
    @Test
    func anAttachThatNeverSettlesOrEndsTypesNothing() async {
        var timing = AttachReply.Timing()
        timing.readyLimit = 40
        let silent = FakeTerminal(drawn: 0)
        #expect(await AttachReply.send("hi", through: silent, timing: timing, sleep: { _ in }) == .notReady(nil))
        #expect(silent.writes.isEmpty && silent.hungUp)
        let refused = FakeTerminal(endedAtStart: true, tail: "This session has no saved transcript")
        #expect(await AttachReply.send("hi", through: refused, sleep: { _ in }) == .ended("This session has no saved transcript"))
        #expect(refused.writes.isEmpty)
        // One that does not let go after Ctrl+Z is hung up, then ended: the session keeps running either way.
        let stubborn = FakeTerminal(holdsOn: true)
        #expect(await AttachReply.send("hi", through: stubborn, sleep: { _ in }) == .sent)
        #expect(stubborn.hungUp && stubborn.terminated && !stubborn.killed)
        // One that a SIGTERM does not end either (stopped): SIGKILL, the app's own child only.
        let stopped = FakeTerminal(holdsOn: true, onlyKillEnds: true)
        #expect(await AttachReply.send("hi", through: stopped, sleep: { _ in }) == .sent)
        #expect(stopped.terminated && stopped.killed && stopped.hasExited)
    }

    /// Open in terminal: a new window typing `claude attach '<id>'` in its folder and profile; the card stays and says
    /// it is attached (P1462).
    @Test
    func openInTerminalAttachesInANewWindowAndTheCardStays() async throws {
        let rig = await Self.moved()
        let outcome = await rig.engine.openFolded(sessionID: Self.newID)
        #expect(outcome == nil)
        let window = try #require(rig.windows.current.first)
        #expect(window.host == .terminal && window.folder == Self.folder)
        #expect(window.line == "cd '/tmp/project' && CLAUDE_CONFIG_DIR='\(ResumeCommand.expanded(Self.profile))' claude attach '0ca371e5'")
        #expect(rig.engine.folds[Self.newID] != nil && rig.engine.folds[Self.newID]?.background?.attachedIn == "Terminal")
        #expect(rig.base.tucks.current.filter { $0 == .untuck }.isEmpty)
    }

    /// Stop: `claude stop <id>`, its conversation kept; a held reply goes with it (P1463).
    @Test
    func stopRunsClaudeStopAndKeepsTheCard() async {
        let stopped = Self.json([Self.row("background", id: Self.short, session: Self.newID, state: "stopped", status: nil, pid: nil)])
        let rig = await Self.moved(lists: [Self.after, stopped])
        await rig.engine.replyFolded(sessionID: Self.newID, text: "and tag it")
        await rig.engine.stopBackground(Self.newID)
        #expect(rig.claude.commands.contains { $0.arguments == ["stop", Self.short] })
        #expect(rig.engine.folds[Self.newID]?.held == nil)
        #expect(rig.engine.folds[Self.newID]?.background?.stoppedByOwner == true)
        #expect(!rig.engine.foldTurnRuns(Self.newID))
        #expect(rig.engine.foldNotes.map(\.said).contains("background · stopped"))
    }

    /// A session the list knows as a background one (Juice started it, or it was moved before) folds as one: no tab,
    /// nothing tucked or typed (P1465).
    @Test
    func aKnownBackgroundSessionFoldsWithNoTab() async {
        let rig = Self.rig(lists: [Self.json([Self.row("background", id: Self.short, session: "bg", state: "done", status: "idle")])])
        rig.engine.ingest(F.started("bg"), ingress: .bridge)
        rig.engine.ingest(F.prompt("bg"), ingress: .bridge)
        rig.engine.ingest(F.completed("bg"), ingress: .bridge)
        #expect(!rig.engine.canFold(sessionID: "bg"))
        await rig.engine.claudeBackground?.list(profile: Self.profile)
        #expect(rig.engine.canFold(sessionID: "bg"))
        #expect(await rig.engine.fold(sessionID: "bg") == .folded(bounds: nil))
        #expect(rig.engine.folds["bg"]?.background?.stage == .moved && rig.engine.foldReach("bg") == .background)
        #expect(rig.base.tucks.current.isEmpty && rig.typed.isEmpty)
    }

    /// Its hooks said the turn was over, its own list says a turn runs: the reply waits for that turn as any held reply
    /// does, and goes through the attach once a later row says it is done; nothing runs the list every second (P1459).
    @Test
    func aReplyItsRowTurnsAwayAsBusyWaitsForTheTurnsEnd() async throws {
        let idle = Self.json([Self.row("background", id: Self.short, session: Self.newID, state: "done", status: "idle")])
        let busy = Self.json([Self.row("background", id: Self.short, session: Self.newID, state: "working", status: "busy")])
        let rig = await Self.moved(lists: [idle, busy, idle])
        rig.engine.folds[Self.newID]?.turnOpen = false
        #expect(!rig.engine.foldTurnRuns(Self.newID))
        await rig.engine.replyFolded(sessionID: Self.newID, text: "then push")
        let fold = try #require(rig.engine.folds[Self.newID])
        #expect(fold.held == "then push" && fold.heldWay == .background && fold.send == nil && fold.turnOpen)
        #expect(rig.attaches.current.isEmpty && rig.engine.foldTurnRuns(Self.newID))
        let reads = rig.claude.lists.count
        rig.base.runChecks(5)
        #expect(rig.claude.lists.count == reads)
        // The minute's read, after the hold: done.
        rig.base.clock.update { $0 = $0.addingTimeInterval(30) }
        await rig.engine.readBackgroundLists()
        #expect(!rig.engine.foldTurnRuns(Self.newID))
        rig.base.runChecks(2)
        try await Self.until { rig.terminals.current.first?.writes.count == 3 }
        #expect(rig.terminals.current.first?.typed == "then push")
        #expect(rig.engine.folds[Self.newID]?.held == nil)
    }

    /// A reply wakes a session Stop stopped: the card stops saying stopped once its turn shows, though the last list
    /// still says stopped (P1463).
    @Test
    func aReplyWakesAStoppedSessionAndItsTurnShows() async {
        let stopped = Self.json([Self.row("background", id: Self.short, session: Self.newID, state: "stopped", status: nil, pid: nil)])
        let rig = await Self.moved(lists: [Self.after, stopped])
        await rig.engine.stopBackground(Self.newID)
        #expect(rig.engine.folds[Self.newID]?.background?.stoppedByOwner == true && !rig.engine.foldTurnRuns(Self.newID))
        await rig.engine.replyFolded(sessionID: Self.newID, text: "carry on")
        #expect(rig.terminals.current.first?.typed == "carry on")
        #expect(rig.engine.folds[Self.newID]?.background?.stoppedByOwner == false)
        rig.engine.ingest(F.started(Self.newID, source: .resume), ingress: .bridge)
        rig.engine.ingest(F.prompt(Self.newID, "carry on", at: rig.base.clock.current), ingress: .bridge)
        #expect(rig.engine.foldTurnRuns(Self.newID))
    }

    /// No test reaches a real `claude`: an engine of the app's kind (several wiring rigs make one) gets no live list,
    /// attach, stop, start or scan from a backgrounder it did not give stand-ins (P1475). Only the guard is asked here,
    /// never the live closures themselves.
    @Test
    func anEngineOfTheAppsKindRunsNoLiveCommandInATest() {
        var configuration = SessionEngine.Configuration.headless
        configuration.startBridge = true
        let engine = SessionEngine(configuration: configuration, dependencies: SessionEngine.Dependencies())
        #expect(!ClaudeLive.allowed && TestProcess.isRunning)
        #expect(!ClaudeBackgrounder(engine: engine).canRun)
    }

    /// ✕ on a card that moved under a new id: the interactive session it stood for is no longer counted as folded.
    @Test
    func dismissingAMovedCardLetsItsOldRowBack() async {
        let rig = await Self.moved()
        #expect(rig.engine.isFolded(Self.id))
        rig.engine.unfold(sessionID: Self.newID)
        #expect(!rig.engine.isFolded(Self.id) && rig.engine.movedConversation(from: Self.id) == nil)
    }

    /// A move that waited for its turn's end, whose window closed first: wave 7's stopped card takes over, and nothing is
    /// typed (P1415, P1452).
    @Test
    func aWaitingMoveWhoseWindowClosedFirstIsAStoppedCard() async throws {
        let rig = Self.rig(lists: [Self.before])
        let broker = AttentionScene.StubBroker()
        rig.engine.hookRequestBroker = broker
        Self.session(rig.engine)
        _ = try #require(FoldStopTests.askBash(rig.base, broker, Self.id))
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.engine.backgroundMoveStarted(Self.id)
        #expect(rig.engine.foldBackground(Self.id)?.stage == .waitsForTurnEnd)
        rig.base.closeWindow()
        rig.base.runChecks(5)
        #expect(rig.engine.folds[Self.id]?.stopped?.windowClosed == true)
        #expect(rig.engine.foldBackground(Self.id) == nil)
        rig.base.runChecks(5)
        #expect(rig.typed.isEmpty)
        #expect(rig.engine.foldNotes.map(\.said).contains("background · not moved · it stopped first"))
    }

    /// A window attached to it whose tab the reply cannot find: it says to type it there.
    @Test
    func aReplyItsAttachedWindowDidNotTakeSaysWhere() async {
        let idle = Self.json([Self.row("background", id: Self.short, session: Self.newID, state: "done", status: "idle")])
        let rig = await Self.moved(lists: [idle], attached: [5150])
        rig.engine.folds[Self.newID]?.turnOpen = false
        await rig.engine.readBackgroundLists()
        // Its attach has no tty the island knows.
        await rig.engine.replyFolded(sessionID: Self.newID, text: "ship it")
        #expect(rig.attaches.current.isEmpty && rig.engine.folds[Self.newID]?.send == .notSent)
        #expect(rig.engine.claudeBackground?.problem(Self.newID) == SessionEngine.typeInItsWindow)
    }

    /// A reply when its own list does not name it, or could not be read: nothing is typed.
    @Test
    func aReplyItsListDoesNotNameIsNotTyped() async {
        let rig = await Self.moved(lists: [Self.json([Self.row("background", id: Self.short, session: Self.newID, state: "done", status: "idle")]),
                                           "[]"])
        rig.engine.folds[Self.newID]?.turnOpen = false
        await rig.engine.replyFolded(sessionID: Self.newID, text: "hello")
        #expect(rig.attaches.current.isEmpty && rig.engine.folds[Self.newID]?.send == .notSent)
        #expect(rig.engine.claudeBackground?.problem(Self.newID) == "Not sent · Claude did not list it")
    }

    /// Waits by counted looks (P293): 30 s worth of 10 ms looks, however late each comes.
    static func until(_ condition: @MainActor () -> Bool) async throws {
        var looks = 3_000
        while !condition(), looks > 0 {
            looks -= 1
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    // MARK: Sessions Juice starts (P1470)

    @Test
    func aClaudeSessionJuiceStartsBeginsInTheBackgroundAndTheWindowAttaches() {
        let claude = FakeClaude(lists: [])
        let started = ClaudeBackgroundStart.line(folder: "/tmp/project", profile: NSHomeDirectory() + "/.claude", fallback: "cd '/tmp/project' && claude",
                                                 run: { claude.run($0, $1) }, environment: [:])
        #expect(started.started && started.line == "cd '/tmp/project' && claude attach '7c5dcf5d'")
        #expect(claude.commands.map(\.arguments) == [["--bg", "--settings", ClaudeBackgroundCommand.startSettings]])
        #expect(claude.commands.first?.folder == "/tmp/project")
        claude.startOutput = "Error: workspace not trusted"
        let fallback = ClaudeBackgroundStart.line(folder: "/tmp/project", profile: NSHomeDirectory() + "/.claude", fallback: "cd '/tmp/project' && claude",
                                                  run: { claude.run($0, $1) }, environment: [:])
        #expect(!fallback.started && fallback.line == "cd '/tmp/project' && claude")
    }

    @Test
    func openInAnAccountStartsItInTheBackgroundOnlyWithTheSwitchOn() async {
        for keeps in [true, false] {
            let opened = Box<[FreshSessionLaunch]>([])
            let engine = F.engine(configure: { dependencies in
                dependencies.openFresh = { launch in
                    opened.update { $0.append(launch) }
                    return true
                }
            })
            let claude = FakeClaude(lists: [])
            var dependencies = ClaudeBackgrounder.Dependencies()
            dependencies.run = { claude.run($0, $1) }
            dependencies.environment = { [:] }
            engine.claudeBackground = ClaudeBackgrounder(engine: engine, dependencies: dependencies)
            engine.keepsClaudeRunning = keeps
            engine.ingest(F.started("limit"), ingress: .bridge)
            #expect(await engine.openFresh(sessionID: "limit", provider: .claude, profileFolder: Self.profile))
            let line = opened.current.first?.line ?? ""
            #expect(keeps == line.hasSuffix("claude attach '7c5dcf5d'"), "\(line)")
            #expect(keeps == !claude.commands.isEmpty)
        }
    }

    // MARK: The attach's scan and the live terminal

    @Test
    func theScanFindsAnAttachByItsWordsOnly() {
        #expect(ClaudeAttachScan.attaches(["/usr/local/bin/claude", "attach", "0ca371e5"], "0ca371e5"))
        #expect(!ClaudeAttachScan.attaches(["claude", "--resume", "0ca371e5"], "0ca371e5"))
        #expect(!ClaudeAttachScan.attaches(["claude", "attach", "0ca371e6"], "0ca371e5"))
        #expect(ClaudeAttachScan.pids(attaching: "x'; y").isEmpty)
    }

    @Test
    func theTailIsPlainText() {
        let bytes = Data("\u{1B}[2J\u{1B}[1;1HSession is starting\r\n\u{1B}]0;title\u{07}\u{1B}[32mThis session has no saved transcript\u{1B}[0m\r\n".utf8)
        #expect(AttachReply.plainTail(bytes) == "This session has no saved transcript")
    }

    /// The live terminal's plumbing, with `/bin/cat` (a process this test starts and ends itself), never `claude`: what
    /// is written reaches the child through the terminal, its echo comes back, and a hang-up ends it.
    @Test
    func theLiveTerminalEchoesAndHangsUp() async throws {
        let terminal = try LiveAttachTerminal(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: ["PATH": "/bin"], folder: "/tmp")
        #expect(terminal.write(Array("hello\r".utf8)))
        var looks = 0
        while terminal.seen().bytes == 0, looks < 500 {
            try await Task.sleep(for: .milliseconds(10))
            looks += 1
        }
        #expect(terminal.seen().bytes > 0)
        #expect(terminal.seen().tail.contains("hello"))
        terminal.hangUp()
        looks = 0
        while !terminal.hasExited, looks < 500 {
            try await Task.sleep(for: .milliseconds(10))
            looks += 1
        }
        if !terminal.hasExited { terminal.terminate() }
        #expect(terminal.hasExited || looks >= 500)
    }
}
