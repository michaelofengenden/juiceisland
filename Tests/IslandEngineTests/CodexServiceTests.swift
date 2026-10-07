import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine

/// A Codex session that Codex's shared background service (its app-server daemon, on by default in 0.158) runs
/// (P1485 to P1509): its hooks name the daemon's pid, its window may close while the daemon goes on, and a reply goes to
/// the daemon's thread. Every seam is a stand-in: the daemon is `FakeDaemon` (its answers as Codex's JSON-RPC gives them,
/// read by `CodexDaemonLinkTests`), every run a `FakeRun`, every window a recorder. No socket, CLI or window is touched.
@MainActor
struct CodexServiceTests {
    typealias F = EngineFixtures
    typealias Rig = FoldResumeEndToEndTests.Rig

    static let id = SessionResumeTests.codexID
    nonisolated static let daemonPID: Int32 = 6060
    static let side = SessionResumeTests.side
    static let folder = SessionResumeTests.folder

    /// Codex's shared daemon as the resumer reaches it: what it says of the thread now (`status`, a test changes it),
    /// and every ask, turn and interrupt it was sent.
    final class FakeDaemon: CodexDaemonReaching, @unchecked Sendable {
        struct Turn: Equatable {
            var thread: String
            var home: String
            var text: String
        }

        let status: F.Box<CodexDaemonStatus>
        let start: F.Box<CodexDaemonStart>
        let asks = F.Box(0)
        let started = F.Box<[Turn]>([])
        let interrupts = F.Box<[String]>([])

        init(_ status: CodexDaemonStatus, start: CodexDaemonStart = .started(turnID: "turn-1")) {
            self.status = F.Box(status)
            self.start = F.Box(start)
        }

        func status(of threadID: String, home: String) async -> CodexDaemonStatus {
            asks.update { $0 += 1 }
            return status.current
        }

        func startTurn(on threadID: String, home: String, text: String) async -> CodexDaemonStart {
            started.update { $0.append(Turn(thread: threadID, home: home, text: text)) }
            let answer = start.current
            if case .started = answer { status.update { $0 = .active(waitsOnYou: false) } }
            return answer
        }

        func interrupt(turn turnID: String, on threadID: String, home: String) async -> Bool {
            interrupts.update { $0.append(turnID) }
            return true
        }
    }

    /// A Codex session its shared daemon runs, as its hooks tell it: the notes name the daemon's pid and the terminal the
    /// daemon was started from, and the client that started it still holds that terminal, so the daemon reads as at a
    /// prompt there with that tab's tty (`alive`): the hazard P1485 is about.
    static func daemonSession(_ rig: Rig, running: Bool = false) {
        rig.daemons.update { $0.insert(daemonPID) }
        rig.alive.update { $0.insert(daemonPID) }
        rig.engine.ingest(F.started(id, tool: .codex, transcript: "\(side)/sessions/2026/10/05/rollout-\(id).jsonl", cwd: folder,
                                    terminal: "Terminal"), ingress: .bridge)
        rig.engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: daemonPID,
                                                hostBundleID: ExactJumpTests.terminal, entrypoint: "cli", source: "codex"))
        rig.engine.ingest(F.prompt(id), ingress: .bridge)
        if !running { rig.engine.ingest(F.completed(id), ingress: .bridge) }
    }

    /// Folds the daemon's session once the service has said it holds it.
    static func folded(_ rig: Rig, _ daemon: FakeDaemon, running: Bool = false) async {
        daemonSession(rig, running: running)
        await rig.settle { rig.resumer.serviceStatus(id) != nil }
        _ = await rig.engine.fold(sessionID: id)
    }

    // MARK: Never a tab's agent (P1485, P1486)

    /// The daemon's parent is the client that started it, so while that client holds its terminal the daemon reads as at
    /// a prompt there, with that tab's tty: a reply would have been typed into another conversation's tab.
    @Test
    func theDaemonIsNeverATabsAgentWhileTheClientThatStartedItHoldsTheTerminal() async throws {
        let daemon = FakeDaemon(.idle)
        let rig = Rig(daemon: daemon)
        Self.daemonSession(rig)
        let session = try #require(rig.engine.state.session(id: Self.id))
        #expect(rig.engine.replyRoute(for: session) == nil)
        #expect(rig.engine.agentPID(awaitingReply: session) == nil && !rig.engine.canReply(sessionID: Self.id))
        #expect(await rig.engine.reply(sessionID: Self.id, text: "go on") == .nothingToSend)
        await rig.settle { rig.resumer.serviceStatus(Self.id) != nil }
        _ = await rig.engine.fold(sessionID: Self.id)
        #expect(rig.engine.folds[Self.id]?.agentPID == nil && rig.exits.current.isEmpty)
        #expect(rig.engine.foldReach(Self.id) != .tab)
        #expect(rig.scripts.current.isEmpty && rig.tucks.current.isEmpty)
    }

    /// Its notes' handles are the daemon's (the first client's tab): a jump takes none of them, nor its parent's tty.
    @Test
    func aJumpTakesNoneOfTheDaemonsHandles() throws {
        let rig = Rig(daemon: FakeDaemon(.idle))
        Self.daemonSession(rig)
        rig.engine.ingest(note: HookContextNote(event: "Stop", sessionID: Self.id, itermSessionID: "w0t1p0:4D2C", agentPID: Self.daemonPID,
                                                hostBundleID: ExactJump.itermBundleID, entrypoint: "cli", source: "codex"))
        let session = try #require(rig.engine.state.session(id: Self.id))
        let target = rig.engine.effectiveJumpTarget(for: session)
        #expect(target == session.jumpTarget)
        #expect(target?.terminalTTY != FoldResumeEndToEndTests.tty && target?.terminalSessionID != "4D2C")
        #expect(rig.engine.jumpContext(for: Self.id) == nil)
    }

    @Test
    func theProcessCheckReadsCodexsSubcommand() {
        #expect(CodexServerProcess.isAppServer(["/Users/x/.codex/packages/app-server-daemon/current/bin/codex", "app-server", "--listen", "unix://"]))
        #expect(CodexServerProcess.isAppServer(["codex", "-c", "model=\"o3\"", "app-server", "--remote-control", "--listen", "unix://"]))
        #expect(CodexServerProcess.isAppServer(["/opt/codex/codex-aarch64-apple-darwin", "--enable", "x", "app-server"]))
        #expect(!CodexServerProcess.isAppServer(["codex"]))
        #expect(!CodexServerProcess.isAppServer(["codex", "resume", Self.id]))
        #expect(!CodexServerProcess.isAppServer(["codex", "exec", "resume", "--json", Self.id, "-"]))
        #expect(!CodexServerProcess.isAppServer(["codex", "-m", "app-server"]))
        #expect(!CodexServerProcess.isAppServer(["node", "app-server"]))
        #expect(!CodexServerProcess.isAppServer([]))
    }

    // MARK: Folding (P1486, P1487)

    @Test
    func itFoldsOnlyOnceTheServiceSaysItHoldsTheThreadAndTucksNothing() async {
        let daemon = FakeDaemon(.idle)
        let rig = Rig(daemon: daemon)
        rig.daemons.update { $0.insert(Self.daemonPID) }
        rig.engine.ingest(F.started(Self.id, tool: .codex, transcript: "\(Self.side)/sessions/2026/10/05/rollout-\(Self.id).jsonl",
                                    cwd: Self.folder), ingress: .bridge)
        rig.engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: Self.id, agentPID: Self.daemonPID,
                                                hostBundleID: ExactJumpTests.terminal, entrypoint: "cli", source: "codex"))
        // Nobody said who holds it yet.
        #expect(!rig.engine.canFold(sessionID: Self.id))
        #expect(await rig.engine.fold(sessionID: Self.id) == .refused)
        await rig.resumer.lookAgain(Self.id)
        #expect(rig.engine.canFold(sessionID: Self.id))
        #expect(await rig.engine.fold(sessionID: Self.id) == .folded(bounds: nil))
        #expect(rig.tucks.current.isEmpty && rig.exits.current.isEmpty && rig.engine.folds[Self.id]?.tucked == false)
        #expect(rig.engine.foldReach(Self.id) == .daemon(note: SessionResumer.serviceNote))
        #expect(rig.engine.foldNotes.map(\.said).contains("sent to the island · no tuck · turn running"))
    }

    @Test
    func aThreadTheServiceDoesNotHoldDoesNotFold() async {
        let daemon = FakeDaemon(.notHeld)
        let rig = Rig(daemon: daemon)
        Self.daemonSession(rig)
        await rig.settle { rig.resumer.serviceStatus(Self.id) != nil }
        #expect(!rig.engine.canFold(sessionID: Self.id))
        daemon.status.update { $0 = .noDaemon }
        await rig.resumer.lookAgain(Self.id)
        #expect(!rig.engine.canFold(sessionID: Self.id))
    }

    // MARK: Its window closes, the turn goes on (P1487, P1488)

    @Test
    func closingItsWindowMidTurnStopsNothingAndAReplyWaitsThenGoesToTheServiceOnce() async throws {
        let daemon = FakeDaemon(.active(waitsOnYou: false))
        let rig = Rig(daemon: daemon)
        await Self.folded(rig, daemon, running: true)
        #expect(rig.engine.isFolded(Self.id))
        // The owner closes its window: its client goes, the daemon goes on. The client that started the daemon goes too.
        rig.alive.update { $0.remove(Self.daemonPID) }
        rig.runChecks(30)
        await rig.settle()
        #expect(rig.engine.folds[Self.id]?.stopped == nil && rig.engine.foldTurnRuns(Self.id))
        #expect(rig.resumer.serviceTurnRuns(Self.id) && !rig.resumer.isRunning(Self.id))
        await rig.engine.replyFolded(sessionID: Self.id, text: "then run the linter")
        #expect(rig.engine.folds[Self.id]?.held == "then run the linter" && rig.engine.folds[Self.id]?.heldWay == .daemon)
        #expect(daemon.started.current.isEmpty && rig.commands.current.isEmpty)
        // The turn ends there: its Stop comes from the daemon's hooks, and the service says so.
        daemon.status.update { $0 = .idle }
        rig.engine.ingest(F.completed(Self.id), ingress: .bridge)
        await rig.settle { rig.resumer.serviceStatus(Self.id) == .idle }
        rig.runChecks(2)
        await rig.settle { !daemon.started.current.isEmpty }
        #expect(daemon.started.current == [FakeDaemon.Turn(thread: Self.id, home: Self.side, text: "then run the linter")])
        #expect(rig.resumer.isRunning(Self.id) && rig.engine.foldTurnRuns(Self.id))
        #expect(rig.engine.folds[Self.id]?.held == nil)
        // It runs a while; then the service says no turn runs, past the settle: the run ended, nothing went twice.
        rig.runChecks(12)
        await rig.settle()
        daemon.status.update { $0 = .idle }
        rig.runChecks(12)
        await rig.settle { !rig.resumer.isRunning(Self.id) }
        #expect(!rig.resumer.isRunning(Self.id))
        rig.runChecks(120)
        await rig.settle()
        #expect(daemon.started.current.count == 1)
        #expect(rig.commands.current.isEmpty && rig.scripts.current.isEmpty && rig.windows.current.isEmpty)
    }

    @Test
    func aReplyAtIdleGoesToTheServiceNeverTheExecResumeAndADashStaysText() async {
        let daemon = FakeDaemon(.idle)
        let rig = Rig(daemon: daemon)
        await Self.folded(rig, daemon)
        await rig.engine.replyFolded(sessionID: Self.id, text: "-rf the build folder, then rebuild")
        #expect(daemon.started.current.map(\.text) == ["-rf the build folder, then rebuild"])
        #expect(rig.commands.current.isEmpty)
        #expect(rig.resumer.isRunning(Self.id) && rig.engine.folds[Self.id]?.resumed == true)
        // The note is said only before the first reply.
        #expect(rig.engine.foldReach(Self.id) == .daemon(note: nil))
        // A second Return while it runs is held, never a second turn.
        await rig.engine.replyFolded(sessionID: Self.id, text: "and push")
        #expect(daemon.started.current.count == 1 && rig.engine.folds[Self.id]?.held == "and push")
    }

    @Test
    func stopEndsOnlyTheIslandsOwnTurnThere() async {
        let daemon = FakeDaemon(.active(waitsOnYou: false))
        let rig = Rig(daemon: daemon)
        await Self.folded(rig, daemon, running: true)
        // A turn the island did not start: no Stop for it.
        rig.engine.stopFolded(sessionID: Self.id)
        await rig.settle()
        #expect(daemon.interrupts.current.isEmpty)
        daemon.status.update { $0 = .idle }
        rig.engine.ingest(F.completed(Self.id), ingress: .bridge)
        await rig.settle { rig.resumer.serviceStatus(Self.id) == .idle }
        await rig.engine.replyFolded(sessionID: Self.id, text: "rename it")
        #expect(rig.resumer.isRunning(Self.id))
        rig.engine.stopFolded(sessionID: Self.id)
        rig.engine.stopFolded(sessionID: Self.id)
        await rig.settle { !daemon.interrupts.current.isEmpty }
        #expect(daemon.interrupts.current == ["turn-1"])
        daemon.status.update { $0 = .idle }
        rig.runChecks(6)
        await rig.settle { !rig.resumer.isRunning(Self.id) }
        #expect(!rig.resumer.isRunning(Self.id))
        #expect(rig.engine.foldNotes.map(\.said).contains("background turn ended · stopped"))
    }

    @Test
    func quittingLeavesTheServicesTurnRunning() async {
        let daemon = FakeDaemon(.idle)
        let rig = Rig(daemon: daemon)
        await Self.folded(rig, daemon)
        await rig.engine.replyFolded(sessionID: Self.id, text: "rename it")
        rig.resumer.endAll()
        await rig.settle()
        #expect(daemon.interrupts.current.isEmpty)
    }

    // MARK: Open in terminal (P1489)

    @Test
    func openInTerminalJoinsTheServicesThreadInANewWindow() async {
        let daemon = FakeDaemon(.active(waitsOnYou: false))
        let rig = Rig(daemon: daemon)
        await Self.folded(rig, daemon, running: true)
        // A stopped card's words never go into a turn the service still runs; a client naming the id holds nothing back.
        rig.engine.folds[Self.id]?.stopped = FoldStop(at: F.now, windowClosed: true, why: .processEnded)
        rig.found.update { $0 = [5151] }
        _ = await rig.engine.openFolded(sessionID: Self.id)
        let line = ResumeCommand.terminalLine(provider: .codex, sessionID: Self.id, folder: Self.folder, profile: Self.side)
        #expect(rig.windows.current.map(\.line) == [line])
        #expect(line.hasSuffix("codex resume '\(Self.id)'"))
        // The owner's usual terminal: the notes' Terminal is the daemon's.
        #expect(rig.windows.current.first?.host == .ghostty)
        #expect(!rig.engine.isFolded(Self.id) && rig.scripts.current.isEmpty && rig.commands.current.isEmpty)
    }

    // MARK: A resume that meets the service (P1488)

    /// The tab's own Codex (no daemon) closed; the owner replied, the exec resume went, and Codex refused it because the
    /// service had taken the thread meanwhile: the service is asked, the reply waits for its turn and then goes there, once.
    @Test
    func anExecResumeTheWriterLockRefusedAsksTheServiceAndTheReplyGoesThere() async throws {
        let daemon = FakeDaemon(.notHeld)
        let rig = Rig(daemon: daemon)
        rig.codex()
        _ = await rig.engine.fold(sessionID: SessionResumeTests.codexID)
        rig.closeTab(SessionResumeTests.codexID)
        let id = SessionResumeTests.codexID
        await rig.engine.replyFolded(sessionID: id, text: "rename it")
        #expect(rig.commands.current.count == 1 && daemon.started.current.isEmpty)
        daemon.status.update { $0 = .active(waitsOnYou: false) }
        rig.runs.current[0].end(ResumeExit(status: 1, output: ResumeOutput(provider: .codex, lines: [
            #"{"type":"error","message":"thread already has an active writer"}"#,
        ])))
        await rig.settle { !rig.resumer.isRunning(id) }
        #expect(rig.engine.folds[id]?.held == "rename it" && rig.engine.folds[id]?.heldWay == .daemon)
        #expect(rig.resumer.problem(id) != ResumeExit.heldElsewhereWords)
        #expect(rig.engine.foldReach(id) == .daemon(note: nil))
        daemon.status.update { $0 = .idle }
        rig.runChecks(6)
        await rig.settle { rig.resumer.serviceStatus(id) == .idle }
        rig.runChecks(2)
        await rig.settle { !daemon.started.current.isEmpty }
        #expect(daemon.started.current.map(\.text) == ["rename it"] && rig.commands.current.count == 1)
    }

    /// Continue on a card whose window closed mid-turn, while the service now runs that thread's turn: nothing runs,
    /// the card is stopped no longer and says Codex is still finishing it.
    @Test
    func continueOnAThreadTheServiceRunsSaysItIsStillFinishing() async {
        let daemon = FakeDaemon(.notHeld)
        let rig = Rig(daemon: daemon)
        rig.codexWorking()
        let id = SessionResumeTests.codexID
        _ = await rig.engine.fold(sessionID: id)
        FoldContinueEndToEndTests.closeWindow(rig)
        rig.runChecks(2)
        #expect(rig.engine.folds[id]?.stopped != nil)
        daemon.status.update { $0 = .active(waitsOnYou: false) }
        await rig.engine.continueFolded(sessionID: id)
        #expect(rig.commands.current.isEmpty && daemon.started.current.isEmpty)
        #expect(rig.engine.folds[id]?.stopped == nil && rig.engine.folds[id]?.held == nil)
        #expect(rig.resumer.problem(id) == SessionResumer.finishingWords && rig.resumer.serviceTurnRuns(id))
        #expect(rig.engine.foldNotes.map(\.said).contains("resume held back · Codex is still finishing in the background"))
    }

    /// With no service, or one that does not hold the thread, wave 6 and 7's exec resume goes as before.
    @Test
    func withoutTheServiceHoldingItTheExecResumeGoesAsBefore() async {
        for status: CodexDaemonStatus in [.noDaemon, .notHeld, .failed("it did not answer")] {
            let daemon = FakeDaemon(status)
            let rig = Rig(daemon: daemon)
            rig.codex()
            let id = SessionResumeTests.codexID
            _ = await rig.engine.fold(sessionID: id)
            rig.closeTab(id)
            #expect(rig.engine.foldReach(id) == .resume(note: SessionResumer.codexNote))
            await rig.engine.replyFolded(sessionID: id, text: "rename it")
            #expect(rig.commands.current.map(\.arguments) == [["exec", "resume", "--json", id, "-"]], "\(status)")
            #expect(daemon.started.current.isEmpty && daemon.asks.current >= 1)
        }
    }

    // MARK: Asking, and how often (P1491)

    @Test
    func theServiceIsAskedAtATurnsEdgesAndPolledOnlyWhileFolded() async {
        let daemon = FakeDaemon(.idle)
        let rig = Rig(daemon: daemon)
        Self.daemonSession(rig)
        // The prompt and the turn's end (the start came before its note named the daemon).
        await rig.settle { daemon.asks.current >= 2 }
        #expect(daemon.asks.current == 2)
        rig.runChecks(600)
        await rig.settle()
        #expect(daemon.asks.current == 2)
        _ = await rig.engine.fold(sessionID: Self.id)
        await rig.settle { daemon.asks.current >= 3 }
        for expected in 4...5 {
            rig.runChecks(61)
            await rig.settle { daemon.asks.current >= expected }
        }
        #expect(daemon.asks.current == 5)
        rig.engine.unfold(sessionID: Self.id)
        rig.runChecks(600)
        await rig.settle()
        #expect(daemon.asks.current == 5)
    }

    /// The service's word that no turn runs ends the fold's turn begun before it was asked, never one begun since.
    @Test
    func theServicesIdleWordEndsAFoldsTurnBegunBeforeItWasAsked() async {
        let daemon = FakeDaemon(.active(waitsOnYou: false))
        let rig = Rig(daemon: daemon)
        await Self.folded(rig, daemon, running: true)
        rig.engine.folds[Self.id]?.turnOpen = true
        rig.engine.folds[Self.id]?.turnOpenedAt = F.now
        rig.engine.serviceAnswered(Self.id, .idle, changed: true, askedAt: F.now - 5)
        #expect(rig.engine.folds[Self.id]?.turnOpen == true)
        rig.engine.serviceAnswered(Self.id, .idle, changed: false, askedAt: F.now + 1)
        #expect(rig.engine.folds[Self.id]?.turnOpen == false)
    }

    /// A Stop its hooks lost leaves the session's phase running: once the service says no turn runs there, a reply goes at
    /// once instead of waiting for an end that never comes (P1491).
    @Test
    func aLostStopHoldsNoReplyOnceTheServiceSaysIdle() async {
        let daemon = FakeDaemon(.active(waitsOnYou: false))
        let rig = Rig(daemon: daemon)
        await Self.folded(rig, daemon, running: true)
        #expect(rig.engine.foldTurnRuns(Self.id))
        daemon.status.update { $0 = .idle }
        await rig.resumer.lookAgain(Self.id)
        #expect(rig.engine.state.session(id: Self.id)?.phase != .completed && rig.engine.folds[Self.id]?.turnOpen == false)
        #expect(!rig.engine.foldTurnRuns(Self.id))
        await rig.engine.replyFolded(sessionID: Self.id, text: "go on")
        await rig.settle { !daemon.started.current.isEmpty }
        #expect(daemon.started.current.map(\.text) == ["go on"] && rig.engine.folds[Self.id]?.held == nil)
    }

    @Test
    func theLogSaysTheServiceAndNoText() async {
        let daemon = FakeDaemon(.active(waitsOnYou: false))
        let rig = Rig(daemon: daemon)
        await Self.folded(rig, daemon, running: true)
        await rig.engine.replyFolded(sessionID: Self.id, text: "the secret plan")
        daemon.status.update { $0 = .idle }
        rig.engine.ingest(F.completed(Self.id), ingress: .bridge)
        await rig.settle { rig.resumer.serviceStatus(Self.id) == .idle }
        rig.runChecks(2)
        await rig.settle { !daemon.started.current.isEmpty }
        let said = rig.engine.foldNotes.map(\.said)
        #expect(said.contains("reply held · for Codex's background service"))
        #expect(said.contains("background service · holds it, idle"))
        #expect(said.contains("reply sent · Codex's background service"))
        #expect(!said.contains { $0.contains("secret") })
    }

    /// A test's engine may start its bridge, but the app's own resumer made in a test process never gets the live link,
    /// so no test reaches the owner's daemon through it (P929, P1496).
    @Test
    func aTestProcessNeverGetsTheLiveLink() async {
        #expect(CodexDaemonLink.runningUnderTests)
        var configuration = SessionEngine.Configuration.headless
        configuration.startBridge = true
        let engine = SessionEngine(configuration: configuration, dependencies: SessionEngine.Dependencies())
        let resumer = SessionResumer(engine: engine)
        #expect(await resumer.codexDaemonHolds(threadID: Self.id, profile: NSTemporaryDirectory()) == nil)
        #expect(resumer.serviceStatus(Self.id) == nil)
    }

    /// For Open in Codex (lane APPS): whether the service holds a thread, asked fresh.
    @Test
    func appsAskWhetherTheServiceHoldsAThread() async {
        let daemon = FakeDaemon(.idle)
        let rig = Rig(daemon: daemon)
        #expect(await rig.resumer.codexDaemonHolds(threadID: Self.id, profile: Self.side) == true)
        daemon.status.update { $0 = .notHeld }
        #expect(await rig.resumer.codexDaemonHolds(threadID: Self.id, profile: Self.side) == false)
        daemon.status.update { $0 = .noDaemon }
        #expect(await rig.resumer.codexDaemonHolds(threadID: Self.id, profile: Self.side) == nil)
        #expect(await Rig().resumer.codexDaemonHolds(threadID: Self.id, profile: Self.side) == nil)
    }
}
