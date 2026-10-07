import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Send to island from end to end (wave 6, P1350 to P1354): a Terminal session folded, replied to in its tab and, once
/// the tab is gone, through the agent's own resume, with the real `SessionResumer` behind the engine's fold. Every seam
/// is a stand-in: the reply's osascript records its script, the tuck and the jump are fakes, every run is a
/// `SessionResumeTests.FakeRun` and every window a recorder. No terminal, no osascript, no CLI and no window is touched.
@MainActor
struct FoldResumeEndToEndTests {
    typealias F = EngineFixtures
    typealias Box = EngineFixtures.Box
    typealias Run = SessionResumeTests.FakeRun

    static let claudeID = SessionResumeTests.claudeID
    static let codexID = SessionResumeTests.codexID
    static let folder = SessionResumeTests.folder
    static let lab = SessionResumeTests.lab
    static let side = SessionResumeTests.side
    nonisolated static let tty = "/dev/ttys004"
    nonisolated static let agent: Int32 = 4242
    nonisolated static let shell: Int32 = 4241

    /// One engine with the resumer wired in as the app wires it (`LiveSessions.goLive`), and every seam recorded.
    @MainActor
    final class Rig {
        let engine: SessionEngine
        let resumer: SessionResumer
        /// Every script the reply route ran: each is one keystroke burst into a tab.
        let scripts = Box<[String]>([])
        let tucks = Box<[TerminalTuck.Move]>([])
        let scheduled = Box<[F.ScheduledCheck]>([])
        let clock = Box(F.now)
        /// The agents' pids that still run: a closed tab takes its agent with it.
        let alive = Box<Set<Int32>>([FoldResumeEndToEndTests.agent])
        /// Processes that run but hold no terminal (Codex's shared daemon): alive, never at a prompt, no tty.
        let daemons = Box<Set<Int32>>([])
        let commands = Box<[ResumeCommand]>([])
        let runs = Box<[Run]>([])
        let windows = Box<[FreshSessionLaunch]>([])
        /// The folded session's tab is the one in front (the check that keeps a focused session quiet, P17).
        let front = Box(false)
        /// What the scan for agents naming a session's id finds (P1420): none unless a test says so.
        let found = Box<[Int32]>([])
        /// Each exit watch the engine asked for: a test calls it as the kernel would (P1416).
        let exits = Box<[(Int32, @MainActor @Sendable () -> Void)]>([])
        let calls = ExactJumpTests.Calls()

        /// `daemon`: Codex's shared background service as the resumer reaches it (P1487); none unless a test gives one.
        init(exitOnInterrupt: ResumeExit? = nil, daemon: CodexServiceTests.FakeDaemon? = nil) {
            let scripts = scripts, tucks = tucks, scheduled = scheduled, clock = clock, alive = alive, daemons = daemons
            let commands = commands, runs = runs, windows = windows, front = front, found = found, exits = exits
            let runner = ExactJumpTests.runner(calls: calls, running: [ExactJumpTests.terminal], frontmost: ExactJumpTests.terminal,
                                               script: { _ in "matched\u{1f}\(FoldResumeEndToEndTests.tty)" })
            engine = F.engine(clock: clock, scheduled: scheduled, isFrontmost: { _ in front.current }, replies: { route, text in
                // The real scripted route, its osascript a recorder that answers as the script would.
                ReplySender.scripted(route, text) { script, _ in
                    scripts.update { $0.append(script) }
                    return "sent"
                }
            }, atPrompt: { alive.current.contains($0) }) { dependencies in
                dependencies.ttyForPID = { alive.current.contains($0) ? FoldResumeEndToEndTests.tty : nil }
                dependencies.processExists = { alive.current.contains($0) || daemons.current.contains($0) }
                // Codex's shared daemon is a Codex app-server (P1485).
                dependencies.isCodexServer = { daemons.current.contains($0) }
                // The agent ran under a shell that goes with its window (P1415).
                dependencies.parentPID = { $0 == FoldResumeEndToEndTests.agent ? FoldResumeEndToEndTests.shell : nil }
                dependencies.watchProcessExit = { pid, exited in
                    exits.update { $0.append((pid, exited)) }
                    return FoldStopTests.Token {}
                }
                dependencies.jumpRunner = runner
                dependencies.tuckWindow = { move, _ in
                    tucks.update { $0.append(move) }
                    return move == .untuck ? .restored : .tucked(TuckBounds(left: 100, top: 80, right: 900, bottom: 600))
                }
                dependencies.scheduleFoldCheck = { delay, check in
                    scheduled.update { $0.append(F.ScheduledCheck(at: clock.current.addingTimeInterval(delay), run: check)) }
                }
            }
            var dependencies = SessionResumer.Dependencies()
            dependencies.start = { command in
                commands.update { $0.append(command) }
                var made: Run!
                runs.update {
                    made = Run(pid: Int32(7000 + $0.count), exitOnInterrupt: exitOnInterrupt)
                    $0.append(made)
                }
                return made
            }
            dependencies.openWindow = { launch in
                windows.update { $0.append(launch) }
                return true
            }
            dependencies.isFolder = { SessionResumeTests.folders.contains($0) }
            dependencies.usualHost = { .ghostty }
            dependencies.findAgents = { _ in found.current }
            // The app's own environment, its skip switches set as `CLIEnvironment.make` sets them.
            dependencies.environment = {
                var app = ["SHELL": "/bin/zsh", "__CFBundleIdentifier": "com.ofengenden.juice"]
                for key in CLIEnvironment.islandSkipKeys { app[key] = "1" }
                return app
            }
            dependencies.sleep = { _ in }
            dependencies.quitGrace = 0
            dependencies.daemon = daemon
            resumer = SessionResumer(engine: engine, dependencies: dependencies)
            engine.conversationResume = resumer
        }

        /// A Claude Code session in a Terminal tab, its agent named by its note; its turn finished unless `running`.
        func claude(running: Bool = false) {
            let id = FoldResumeEndToEndTests.claudeID
            engine.ingest(F.started(id, transcript: "\(FoldResumeEndToEndTests.lab)/projects/-tmp-ji-resume-project/\(id).jsonl",
                                    cwd: FoldResumeEndToEndTests.folder), ingress: .bridge)
            engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: FoldResumeEndToEndTests.agent,
                                                hostBundleID: ExactJumpTests.terminal, entrypoint: "cli", source: "claude"))
            engine.ingest(F.prompt(id), ingress: .bridge)
            if !running { engine.ingest(F.completed(id), ingress: .bridge) }
        }

        /// A Codex CLI session in a Terminal tab, in its own home, its turn finished.
        func codex() {
            let id = FoldResumeEndToEndTests.codexID
            engine.ingest(F.started(id, tool: .codex, transcript: "\(FoldResumeEndToEndTests.side)/sessions/2026/10/05/rollout-\(id).jsonl",
                                    cwd: FoldResumeEndToEndTests.folder, terminal: "Terminal"), ingress: .bridge)
            engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: FoldResumeEndToEndTests.agent,
                                                hostBundleID: ExactJumpTests.terminal, entrypoint: "cli", source: "codex"))
            engine.ingest(F.prompt(id), ingress: .bridge)
            engine.ingest(F.completed(id), ingress: .bridge)
        }

        /// The owner closes the tab: the agent goes with it, and its SessionEnd comes.
        func closeTab(_ id: String) {
            alive.update { $0.remove(FoldResumeEndToEndTests.agent) }
            engine.ingest(F.sessionEnd(id), ingress: .bridge)
        }

        /// The island's run of `id` as its hooks tell it: a new process with no terminal, `sdk-cli`, a resume start,
        /// its prompt, then `completed` ends the turn.
        func runHooks(_ id: String, pid: Int32, completed: Bool = true) {
            engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: pid, entrypoint: "sdk-cli",
                                                source: "claude", sessionStartSource: "resume"))
            engine.ingest(F.prompt(id, "go on"), ingress: .bridge)
            engine.ingest(F.running(id), ingress: .bridge)
            if completed { engine.ingest(F.completed(id), ingress: .bridge) }
        }

        func runChecks(_ seconds: TimeInterval) { F.runScheduledChecks(scheduled, clock: clock, for: seconds) }

        /// One pass of upstream's process monitor as the app runs it (`ProcessMonitoringCoordinator`): liveness from
        /// process discovery (`alive`), the sessions no island shows removed, then the engine's own review (P7).
        func monitorPass(alive: Set<String> = []) {
            var local = engine.state
            local.markProcessLiveness(aliveSessionIDs: alive)
            local.removeInvisibleSessions()
            engine.applyMonitoredState(local)
        }

        /// A Codex CLI session in a Terminal tab, its turn under way.
        func codexWorking() {
            let id = FoldResumeEndToEndTests.codexID
            engine.ingest(F.started(id, tool: .codex, transcript: "\(FoldResumeEndToEndTests.side)/sessions/2026/10/05/rollout-\(id).jsonl",
                                    cwd: FoldResumeEndToEndTests.folder, terminal: "Terminal"), ingress: .bridge)
            engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: FoldResumeEndToEndTests.agent,
                                                hostBundleID: ExactJumpTests.terminal, entrypoint: "cli", source: "codex"))
            engine.ingest(F.prompt(id), ingress: .bridge)
        }

        /// Lets the main actor run what the checks and the runs' ends handed it.
        func settle(until condition: () -> Bool = { false }) async {
            for _ in 0..<200 where !condition() { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(20))
        }

        /// Ends the run `index` well, with `answer` as the CLI's final text.
        func endRun(_ index: Int, answer: String = "Done.") async {
            let object: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "result": answer]
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            runs.current[index].end(ResumeExit(status: 0, output: ResumeOutput(provider: .claude, lines: [line])))
            await settle { !resumer.isRunning(FoldResumeEndToEndTests.claudeID) && !resumer.isRunning(FoldResumeEndToEndTests.codexID) }
        }
    }

    // MARK: The tab still open (route a, P1354)

    @Test
    func aFoldedTerminalSessionsReplyWhileItWorksIsTypedOnceAtTheTurnsEnd() async {
        let rig = Rig()
        rig.claude(running: true)
        #expect(rig.engine.canFold(sessionID: Self.claudeID))
        #expect(await rig.engine.fold(sessionID: Self.claudeID) == .folded(bounds: TuckBounds(left: 100, top: 80, right: 900, bottom: 600)))
        #expect(rig.tucks.current == [.tuck] && rig.engine.foldReach(Self.claudeID) == .tab)
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "then run the tests")
        #expect(rig.engine.folds[Self.claudeID]?.held == "then run the tests")
        rig.runChecks(10)
        await rig.settle()
        #expect(rig.scripts.current.isEmpty)
        rig.engine.ingest(F.completed(Self.claudeID), ingress: .bridge)
        #expect(rig.scripts.current.isEmpty)
        rig.runChecks(2)
        await rig.settle { !rig.scripts.current.isEmpty }
        // One script, into the one tab whose tty is the agent's, with the standard submit.
        #expect(rig.scripts.current == [ReplySender.terminalScript("then run the tests", tty: Self.tty, submit: .standard)])
        #expect(rig.engine.folds[Self.claudeID]?.held == nil && rig.engine.folds[Self.claudeID]?.send == .sent)
        // More ends of turns and more checks never type it again; no run ever started.
        rig.engine.ingest(F.completed(Self.claudeID), ingress: .bridge)
        rig.runChecks(10)
        await rig.settle()
        #expect(rig.scripts.current.count == 1 && rig.commands.current.isEmpty)
    }

    @Test
    func aReplyAtThePromptIsTypedOnceNeverTwice() async {
        let rig = Rig()
        rig.claude()
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        // Two Returns in a row: the first leaves the card Sending… before its script runs, and the second, finding it on
        // its way, sends nothing.
        let first = Task { await rig.engine.replyFolded(sessionID: Self.claudeID, text: "ship it\nnow") }
        while rig.engine.folds[Self.claudeID]?.send == nil { await Task.yield() }
        #expect(rig.engine.folds[Self.claudeID]?.send == .sending)
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "ship it\nnow")
        await first.value
        #expect(rig.scripts.current == [ReplySender.terminalScript("ship it now", tty: Self.tty, submit: .standard)])
        #expect(rig.engine.folds[Self.claudeID]?.send == .sent)
        // Its turn runs and ends; the checks and the next events type nothing more.
        rig.engine.ingest(F.prompt(Self.claudeID, "ship it now"), ingress: .bridge)
        #expect(rig.engine.folds[Self.claudeID]?.send == nil && rig.engine.foldTurnRuns(Self.claudeID))
        rig.engine.ingest(F.completed(Self.claudeID), ingress: .bridge)
        rig.runChecks(10)
        await rig.settle()
        #expect(rig.scripts.current.count == 1 && rig.commands.current.isEmpty)
    }

    @Test
    func openInTerminalWithTheTabOpenBringsTheWindowBackAndJumps() async {
        let rig = Rig()
        rig.claude()
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        let outcome = await rig.engine.openFolded(sessionID: Self.claudeID)
        #expect(rig.tucks.current == [.tuck, .untuck])
        #expect(outcome?.sessionID == Self.claudeID)
        #expect(rig.calls.allScripts.contains { $0.contains(#"(tty of aTab as text) is "/dev/ttys004""#) })
        #expect(!rig.engine.isFolded(Self.claudeID))
        // Nothing typed, no run, no new window.
        #expect(rig.scripts.current.isEmpty && rig.commands.current.isEmpty && rig.windows.current.isEmpty)
    }

    // MARK: The tab closed (route b, P1351, P1354)

    @Test
    func aClosedTabsReplyResumesClaudeWithHooksOnAndAReplyMidRunGoesOnceAfter() async throws {
        let rig = Rig()
        rig.claude()
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        rig.closeTab(Self.claudeID)
        #expect(rig.engine.foldReach(Self.claudeID) == .resume(note: nil))
        // Closing the tab starts nothing.
        rig.runChecks(5)
        await rig.settle()
        #expect(rig.commands.current.isEmpty)

        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "now the docs")
        let command = try #require(rig.commands.current.first)
        #expect(rig.commands.current.count == 1)
        #expect(command.tool == "claude" && command.arguments == ["-p", "--resume", Self.claudeID, "--output-format", "json"])
        #expect(command.input == "now the docs" && command.folder == Self.folder)
        #expect(command.environment["CLAUDE_CONFIG_DIR"] == Self.lab)
        // Hooks on: none of the skip switches, though the app's own environment has them.
        for key in CLIEnvironment.islandSkipKeys { #expect(command.environment[key] == nil, "\(key)") }
        #expect(command.environment["__CFBundleIdentifier"] == nil)
        #expect(rig.scripts.current.isEmpty && rig.engine.foldTurnRuns(Self.claudeID))
        #expect(rig.engine.folds[Self.claudeID]?.send == nil)

        // A reply while the run works is held, through the run's own hooks and well past two minutes.
        rig.runHooks(Self.claudeID, pid: 7000)
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "and the tests")
        #expect(rig.engine.folds[Self.claudeID]?.held == "and the tests")
        rig.runChecks(200)
        await rig.settle()
        #expect(rig.commands.current.count == 1)
        // The run's process ends: the held reply goes once, a second later, as the next run.
        await rig.endRun(0, answer: "Docs updated.")
        #expect(rig.commands.current.count == 1)
        rig.runChecks(2)
        await rig.settle { rig.commands.current.count == 2 }
        #expect(rig.commands.current.map(\.input) == ["now the docs", "and the tests"])
        #expect(rig.engine.folds[Self.claudeID]?.held == nil)
        rig.runChecks(10)
        await rig.settle()
        #expect(rig.commands.current.count == 2 && rig.scripts.current.isEmpty)

        // Open in terminal waits for the run, then opens the conversation in a new window of the tab's own terminal.
        #expect(await rig.engine.openFolded(sessionID: Self.claudeID) == nil)
        #expect(rig.engine.folds[Self.claudeID]?.notOpened == true && rig.windows.current.isEmpty)
        await rig.endRun(1)
        _ = await rig.engine.openFolded(sessionID: Self.claudeID)
        #expect(rig.windows.current == [FreshSessionLaunch(
            host: .terminal, folder: Self.folder,
            line: "cd '\(Self.folder)' && CLAUDE_CONFIG_DIR='\(Self.lab)' claude --resume '\(Self.claudeID)'")])
        #expect(!rig.engine.isFolded(Self.claudeID))
        // The tab is gone: no window comes out of the Dock and no tab is jumped to.
        #expect(rig.tucks.current == [.tuck] && rig.calls.all.isEmpty)
    }

    @Test
    func aClosedCodexTabSaysItsLineBeforeTheFirstResumedReply() async throws {
        let rig = Rig()
        rig.codex()
        #expect(await rig.engine.fold(sessionID: Self.codexID) != .refused)
        #expect(rig.engine.foldReach(Self.codexID) == .tab)
        rig.closeTab(Self.codexID)
        #expect(rig.engine.foldReach(Self.codexID) == .resume(note: SessionResumer.codexNote))
        #expect(rig.commands.current.isEmpty)
        await rig.engine.replyFolded(sessionID: Self.codexID, text: "/review")
        let command = try #require(rig.commands.current.first)
        #expect(command.tool == "codex" && command.arguments == ["exec", "resume", "--json", Self.codexID, "-"])
        #expect(command.input == "/review" && command.environment["CODEX_HOME"] == Self.side)
        for key in CLIEnvironment.islandSkipKeys { #expect(command.environment[key] == nil, "\(key)") }
        // Said before the first resumed reply only.
        #expect(rig.engine.foldReach(Self.codexID) == .resume(note: nil))
        await rig.endRun(0)
        _ = await rig.engine.openFolded(sessionID: Self.codexID)
        #expect(rig.windows.current.map(\.line) == ["cd '\(Self.folder)' && CODEX_HOME='\(Self.side)' codex resume '\(Self.codexID)'"])
        #expect(rig.windows.current.map(\.host) == [.terminal])
    }

    @Test
    func stopEndsTheRunAndItsHeldReplyNeverGoes() async {
        let rig = Rig()
        rig.claude()
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        rig.closeTab(Self.claudeID)
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "go on")
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "and then this")
        #expect(rig.engine.folds[Self.claudeID]?.held == "and then this")
        rig.engine.stopFolded(sessionID: Self.claudeID)
        #expect(rig.runs.current.first?.interrupts.current == 1 && rig.engine.folds[Self.claudeID]?.held == nil)
        await rig.endRun(0)
        rig.runChecks(10)
        await rig.settle()
        #expect(rig.commands.current.count == 1 && rig.resumer.problem(Self.claudeID) == nil)
    }

    // MARK: ✕, the quit, and nothing without a Return (P1354)

    @Test
    func dismissUnfoldsWithoutOpeningAnything() async {
        let rig = Rig()
        rig.claude(running: true)
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "later")
        rig.engine.unfold(sessionID: Self.claudeID)
        rig.engine.ingest(F.completed(Self.claudeID), ingress: .bridge)
        rig.runChecks(5)
        await rig.settle()
        #expect(!rig.engine.isFolded(Self.claudeID))
        // The window stays in the Dock, nothing is jumped to, typed, run or opened.
        #expect(rig.tucks.current == [.tuck] && rig.calls.all.isEmpty)
        #expect(rig.scripts.current.isEmpty && rig.commands.current.isEmpty && rig.windows.current.isEmpty)
    }

    @Test
    func theAppQuittingEndsARun() async {
        let rig = Rig()
        rig.claude()
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        rig.closeTab(Self.claudeID)
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "go on")
        #expect(rig.resumer.isRunning(Self.claudeID))
        rig.resumer.endAll()
        #expect(rig.runs.current.map(\.interrupts.current) == [1] && rig.runs.current.map(\.terminates.current) == [1])
    }

    /// Folding, the tab closing, asking where a reply goes, the checks, ✕, Stop and the quit: none of it types a key or
    /// starts a run. Only a Return in the card does.
    @Test
    func nothingIsTypedOrRunWithoutAReturnInTheCard() async {
        let rig = Rig()
        rig.claude()
        rig.codex()
        for id in [Self.claudeID, Self.codexID] { _ = await rig.engine.fold(sessionID: id) }
        for id in [Self.claudeID, Self.codexID] {
            _ = rig.engine.foldReach(id)
            _ = rig.engine.foldTurnRuns(id)
            _ = rig.engine.canReply(sessionID: id)
            _ = rig.resumer.availability(for: id)
        }
        rig.closeTab(Self.claudeID)
        rig.engine.ingest(F.sessionEnd(Self.codexID), ingress: .bridge)
        rig.runChecks(30)
        await rig.settle()
        for id in [Self.claudeID, Self.codexID] {
            _ = rig.engine.foldReach(id)
            rig.engine.cancelHeldReply(sessionID: id)
            rig.engine.stopFolded(sessionID: id)
            await rig.engine.retryFolded(sessionID: id)
        }
        rig.resumer.endAll()
        rig.engine.unfold(sessionID: Self.codexID)
        rig.runChecks(30)
        await rig.settle()
        #expect(rig.scripts.current.isEmpty && rig.commands.current.isEmpty)
        // Then one Return: one run.
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "go on")
        #expect(rig.commands.current.count == 1 && rig.scripts.current.isEmpty)
    }

    // MARK: The review's findings (W6-R1, W6-R2, W6-R5, W6-R7; P1355 on)

    /// W6-R1: upstream's monitor drops an ended session on its next pass; the card stays, and a reply still goes on
    /// through the resume, a minute or ten minutes later.
    @Test
    func theCardOutlastsTheMonitorPassesAfterTheTabCloses() async throws {
        let rig = Rig()
        rig.claude()
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        rig.closeTab(Self.claudeID)
        rig.monitorPass()
        rig.clock.update { $0 = $0.addingTimeInterval(700) }
        rig.monitorPass()
        rig.monitorPass()
        #expect(rig.engine.state.session(id: Self.claudeID) == nil)
        #expect(rig.engine.isFolded(Self.claudeID))
        #expect(rig.engine.foldReach(Self.claudeID) == .resume(note: nil))
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "now the docs")
        let command = try #require(rig.commands.current.first)
        #expect(command.input == "now the docs" && command.folder == Self.folder && command.environment["CLAUDE_CONFIG_DIR"] == Self.lab)
        // The run's own hooks bring it back, its SessionEnd ends it, and the next pass drops it again: the card stays.
        rig.runHooks(Self.claudeID, pid: 7000)
        await rig.endRun(0, answer: "Docs updated.")
        rig.engine.ingest(F.sessionEnd(Self.claudeID), ingress: .bridge)
        rig.monitorPass()
        #expect(rig.engine.state.session(id: Self.claudeID) == nil && rig.engine.isFolded(Self.claudeID))
        #expect(rig.resumer.answer(Self.claudeID) == "Docs updated.")
        _ = await rig.engine.openFolded(sessionID: Self.claudeID)
        #expect(rig.windows.current.map(\.line) == ["cd '\(Self.folder)' && CLAUDE_CONFIG_DIR='\(Self.lab)' claude --resume '\(Self.claudeID)'"])
    }

    /// W6-R1: the tab closed with no SessionEnd (the agent died on SIGHUP): the monitor ends the session after its misses
    /// and drops it; the card stays and still goes on.
    @Test
    func theCardOutlastsTheMonitorWhenTheAgentDiedWithoutSessionEnd() async {
        let rig = Rig()
        rig.claude()
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        rig.alive.update { $0.remove(Self.agent) }
        for minute in 1...15 {
            rig.clock.update { $0 = F.now.addingTimeInterval(TimeInterval(minute * 60)) }
            rig.monitorPass()
        }
        #expect(rig.engine.state.session(id: Self.claudeID) == nil)
        #expect(rig.engine.isFolded(Self.claudeID) && rig.engine.foldReach(Self.claudeID) == .resume(note: nil))
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "go on")
        #expect(rig.commands.current.map(\.input) == ["go on"])
    }

    /// W6-R2: a reply held for the tab never becomes a resume run when the tab closes: it waits for a new Return, and
    /// Codex's line shows first.
    @Test
    func aReplyHeldForTheTabNeverRunsTheResumeWhenTheTabCloses() async {
        let rig = Rig()
        rig.codexWorking()
        _ = await rig.engine.fold(sessionID: Self.codexID)
        await rig.engine.replyFolded(sessionID: Self.codexID, text: "also delete the build folder")
        #expect(rig.engine.folds[Self.codexID]?.held == "also delete the build folder")
        rig.closeTab(Self.codexID)
        rig.runChecks(5)
        await rig.settle { !rig.commands.current.isEmpty }
        #expect(rig.commands.current.isEmpty && rig.scripts.current.isEmpty)
        #expect(rig.engine.foldReach(Self.codexID) == .resume(note: SessionResumer.codexNote))
        // It is back in the field, and the line says why; nothing more happens by itself.
        #expect(rig.engine.folds[Self.codexID]?.held == nil)
        #expect(rig.engine.folds[Self.codexID]?.returned == ReturnedReply(text: "also delete the build folder", why: .wayChanged))
        rig.runChecks(30)
        await rig.settle()
        #expect(rig.commands.current.isEmpty)
        // The owner reads Codex's line and presses Return on it: one run, with that text.
        await rig.engine.replyFolded(sessionID: Self.codexID, text: "also delete the build folder")
        #expect(rig.commands.current.map(\.input) == ["also delete the build folder"])
        #expect(rig.engine.folds[Self.codexID]?.returned == nil)
    }

    /// P1356: a reply held for the tab, and another typed after the tab closed, both go back to the field; a Retry
    /// that would go another way does too.
    @Test
    func aReplyTypedAfterTheTabClosedBringsTheHeldOneBackToo() async {
        let rig = Rig()
        rig.claude(running: true)
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "run the tests")
        rig.closeTab(Self.claudeID)
        // Before the held reply's check: a Return on new text sends neither.
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "and push")
        #expect(rig.commands.current.isEmpty && rig.scripts.current.isEmpty)
        #expect(rig.engine.folds[Self.claudeID]?.returned == ReturnedReply(text: "run the tests and push", why: .wayChanged))
        rig.runChecks(5)
        await rig.settle()
        #expect(rig.commands.current.isEmpty)

        // A reply typed into the tab that did not go, then the tab closed: Retry gives it back instead of resuming.
        let other = Rig()
        other.claude()
        _ = await other.engine.fold(sessionID: Self.claudeID)
        // As a reply into the tab leaves it when its script failed.
        other.engine.folds[Self.claudeID]?.lastReply = "ship it"
        other.engine.folds[Self.claudeID]?.lastWay = .tab
        other.engine.folds[Self.claudeID]?.send = .notSent
        other.closeTab(Self.claudeID)
        await other.engine.retryFolded(sessionID: Self.claudeID)
        #expect(other.commands.current.isEmpty)
        #expect(other.engine.folds[Self.claudeID]?.returned == ReturnedReply(text: "ship it", why: .wayChanged))
        #expect(other.engine.folds[Self.claudeID]?.send == nil)
    }

    /// W6-R5: a held reply is not typed into a tab that is in front, where the owner may be typing.
    @Test
    func aHeldReplyIsNotTypedIntoATabInFront() async {
        let rig = Rig()
        rig.claude(running: true)
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "then run the tests")
        rig.front.update { $0 = true }
        rig.engine.ingest(F.completed(Self.claudeID), ingress: .bridge)
        rig.runChecks(5)
        await rig.settle { !rig.scripts.current.isEmpty }
        #expect(rig.scripts.current.isEmpty)
        #expect(rig.engine.folds[Self.claudeID]?.returned == ReturnedReply(text: "then run the tests", why: .tabInFront))
        #expect(rig.engine.folds[Self.claudeID]?.held == nil)
        // The owner's own Return in the card is typed, tab in front or not: it is theirs.
        await rig.engine.replyFolded(sessionID: Self.claudeID, text: "then run the tests")
        #expect(rig.scripts.current == [ReplySender.terminalScript("then run the tests", tty: Self.tty, submit: .standard)])
        // A held reply whose tab is not in front goes as before.
        let behind = Rig()
        behind.claude(running: true)
        _ = await behind.engine.fold(sessionID: Self.claudeID)
        await behind.engine.replyFolded(sessionID: Self.claudeID, text: "then run the tests")
        behind.engine.ingest(F.completed(Self.claudeID), ingress: .bridge)
        behind.runChecks(5)
        await behind.settle { !behind.scripts.current.isEmpty }
        #expect(behind.scripts.current.count == 1 && behind.engine.folds[Self.claudeID]?.returned == nil)
    }

    /// W6-R7: Terminal's script outlasts AppleScript's own two-minute wait for an Apple event, so an Automation prompt
    /// the owner answers late never leaves the text typed and its Return unsent behind a "Not sent".
    @Test
    func terminalsScriptOutlastsAnAutomationPrompt() {
        let timeouts = Box<[TimeInterval]>([])
        _ = ReplySender.scripted(.terminal(tty: Self.tty), "go") { _, timeout in
            timeouts.update { $0.append(timeout) }
            return "sent"
        }
        #expect(timeouts.current.count == 1 && (timeouts.current.first ?? 0) > 120)
    }

    // MARK: The submit (P1301, P1353)

    /// The live sender types a Terminal reply with the standard submit through this one path; iTerm's script goes the
    /// same way; tmux and Ghostty are upstream's sender and never reach it.
    @Test
    func theScriptedRouteRunsOneScriptAndReadsItsAnswer() {
        let ran = Box<[String]>([])
        let answer = Box("sent")
        let timeouts = Box<[TimeInterval]>([])
        let osascript: JumpRunner.AppleScript = { script, timeout in
            timeouts.update { $0.append(timeout) }
            ran.update { $0.append(script) }
            return answer.current
        }
        #expect(ReplySender.scripted(.terminal(tty: Self.tty), "go", osascript: osascript))
        #expect(ran.current == [ReplySender.terminalScript("go", tty: Self.tty, submit: .standard)])
        #expect(ReplySender.scripted(.terminal(tty: Self.tty), "go", submit: .inOne, osascript: osascript))
        #expect(ran.current.last == ReplySender.terminalScript("go", tty: Self.tty, submit: .inOne))
        #expect(ReplySender.scripted(.iterm(sessionID: "UUID-A", tty: Self.tty), "go", osascript: osascript))
        #expect(ran.current.last == ReplySender.itermScript("go", sessionID: "UUID-A", tty: Self.tty))
        // Terminal's waits out an Automation prompt (P1361); iTerm's, with no pause between its writes, 5 s.
        #expect(timeouts.current == [ReplySender.terminalTimeout, ReplySender.terminalTimeout, 5])
        // A tab gone in the pause took the text with it: not sent.
        answer.update { $0 = "typed" }
        #expect(!ReplySender.scripted(.terminal(tty: Self.tty), "go", osascript: osascript))
        // No tab found (the script answers nothing), or the script failed: not sent.
        answer.update { $0 = "" }
        #expect(!ReplySender.scripted(.terminal(tty: Self.tty), "go", osascript: osascript))
        #expect(!ReplySender.scripted(.terminal(tty: Self.tty), "go") { _, _ in throw CocoaError(.featureUnsupported) })
        let before = ran.current.count
        #expect(!ReplySender.scripted(.tmux(pane: "%1", socket: "/tmp/ji-tmux"), "go", osascript: osascript))
        #expect(!ReplySender.scripted(.ghostty(terminalID: "T-1"), "go", osascript: osascript))
        #expect(ran.current.count == before)
    }
}

/// A folded session whose window closes mid-turn, from end to end (wave A7, P1415 to P1422), with the real resumer behind
/// the engine's fold: the agent goes with its window, the card says so and stays, nothing runs by itself, Continue runs
/// the resume with the words the card showed, the card reads Working then the answer, and Open in terminal afterwards
/// opens the conversation with its history. Every seam a stand-in, as above.
@MainActor
struct FoldContinueEndToEndTests {
    typealias F = EngineFixtures
    typealias Rig = FoldResumeEndToEndTests.Rig
    static let claudeID = FoldResumeEndToEndTests.claudeID
    static let codexID = FoldResumeEndToEndTests.codexID
    static let agent = FoldResumeEndToEndTests.agent

    /// The owner closes the folded window from the Dock: Terminal hangs up its shell and its agent, mid-turn, with no
    /// SessionEnd; the kernel says the agent exited.
    static func closeWindow(_ rig: Rig) {
        rig.alive.update { $0.remove(agent) }
        for (pid, exited) in rig.exits.current where pid == agent { exited() }
    }

    @Test
    func aWindowClosedMidTurnStopsAndContinueCarriesItOnOnTheClickOnly() async throws {
        let rig = Rig()
        rig.claude(running: true)
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        #expect(rig.engine.folds[Self.claudeID]?.turnOpen == true)
        Self.closeWindow(rig)
        rig.runChecks(2)
        let stopped = try #require(rig.engine.folds[Self.claudeID]?.stopped)
        #expect(stopped.windowClosed && stopped.words == "Stopped when its window closed")
        // Its turn reads interrupted now, not working.
        #expect(rig.engine.state.session(id: Self.claudeID)?.phase == .completed)
        #expect(rig.engine.interruptedSessionIDs.contains(Self.claudeID))
        #expect(rig.engine.foldReach(Self.claudeID) == .resume(note: nil))
        // Minutes pass and the monitor drops the session: the card stays, and nothing runs by itself.
        for _ in 0..<15 {
            rig.clock.update { $0 += 60 }
            rig.monitorPass()
            rig.runChecks(60)
        }
        await rig.settle()
        #expect(rig.commands.current.isEmpty && rig.windows.current.isEmpty && rig.scripts.current.isEmpty)
        #expect(rig.engine.folds[Self.claudeID]?.stopped != nil)

        await rig.engine.continueFolded(sessionID: Self.claudeID)
        let command = try #require(rig.commands.current.first)
        #expect(rig.commands.current.count == 1)
        #expect(command.arguments == ["-p", "--resume", Self.claudeID, "--output-format", "json"])
        #expect(command.input == SessionEngine.continuePrompt && command.folder == FoldResumeEndToEndTests.folder)
        #expect(rig.engine.folds[Self.claudeID]?.stopped == nil && rig.engine.foldTurnRuns(Self.claudeID))
        // Its hooks: the run's turn, approvals held for the island, then its answer.
        rig.runHooks(Self.claudeID, pid: rig.runs.current[0].pid)
        await rig.endRun(0, answer: "Finished the suite: 212 tests pass.")
        #expect(!rig.engine.foldTurnRuns(Self.claudeID) && rig.engine.folds[Self.claudeID]?.stopped == nil)
        #expect(rig.resumer.problem(Self.claudeID) == nil)
        // Open in terminal: the resumed conversation in a new window, with its history; the card goes.
        _ = await rig.engine.openFolded(sessionID: Self.claudeID)
        #expect(rig.windows.current.map(\.line).first?.contains("claude --resume '\(Self.claudeID)'") == true)
        #expect(!rig.engine.isFolded(Self.claudeID))
        let said = rig.engine.foldNotes.map(\.said)
        #expect(said.contains("Continue") && said.contains("resume started") && said.contains("resume exited · status 0"))
        #expect(said.last == "opened · a new window with the resume")
    }

    /// Codex too: `codex exec resume`, its note before the click.
    @Test
    func codexContinuesThroughItsExecResume() async throws {
        let rig = Rig()
        rig.codexWorking()
        _ = await rig.engine.fold(sessionID: Self.codexID)
        Self.closeWindow(rig)
        rig.runChecks(2)
        #expect(rig.engine.folds[Self.codexID]?.stopped != nil)
        #expect(rig.engine.foldReach(Self.codexID) == .resume(note: SessionResumer.codexNote))
        await rig.engine.continueFolded(sessionID: Self.codexID)
        let command = try #require(rig.commands.current.first)
        #expect(command.arguments == ["exec", "resume", "--json", Self.codexID, "-"] && command.input == SessionEngine.continuePrompt)
    }

    /// P1440: Codex's shared daemon may still hold the thread after its tab closed, and refuses a second writer. The card
    /// says so plainly, stays stopped, and keeps Continue for later; nothing runs again by itself.
    @Test
    func codexsWriterLockKeepsTheCardStoppedWithContinue() async throws {
        let rig = Rig()
        rig.codexWorking()
        _ = await rig.engine.fold(sessionID: Self.codexID)
        Self.closeWindow(rig)
        rig.runChecks(2)
        let stop = try #require(rig.engine.folds[Self.codexID]?.stopped)
        await rig.engine.continueFolded(sessionID: Self.codexID)
        #expect(rig.commands.current.count == 1 && rig.engine.folds[Self.codexID]?.stopped == nil)
        rig.runs.current[0].end(ResumeExit(status: 1, output: ResumeOutput(provider: .codex),
                                           errorTail: "Error: thread \(Self.codexID) already has an active writer\n"))
        await rig.settle { !rig.resumer.isRunning(Self.codexID) }
        #expect(rig.resumer.problem(Self.codexID) == "Codex still holds this conversation; try again later")
        #expect(rig.engine.folds[Self.codexID]?.stopped == stop)
        #expect(!rig.engine.foldTurnRuns(Self.codexID) && rig.engine.foldReach(Self.codexID) == .resume(note: nil))
        #expect(rig.engine.foldNotes.map(\.said).contains("resume refused · Codex still holds the conversation"))
        rig.runChecks(600)
        await rig.settle()
        #expect(rig.commands.current.count == 1)
        // Continue, later: it goes again, on the click.
        await rig.engine.continueFolded(sessionID: Self.codexID)
        #expect(rig.commands.current.count == 2)
    }

    /// Codex 0.158 runs a terminal session inside its shared daemon by default, so its hooks name the daemon, which holds
    /// no terminal of this session's and outlives the tab (the owner's answers, research note; P1442, P1485). The fold
    /// never takes that pid for its tab's agent and puts no exit watch on it. With no link to the daemon (every headless
    /// engine) such a session does not even fold: its tab is not known and nobody said who holds the thread; with one,
    /// `CodexServiceTests` covers what it does.
    @Test
    func codexsSharedDaemonIsNeverTakenForTheTabsAgent() async {
        let rig = Rig()
        let id = Self.codexID, daemon: Int32 = 6060
        rig.daemons.update { $0 = [daemon] }
        rig.engine.ingest(F.started(id, tool: .codex, transcript: "\(FoldResumeEndToEndTests.side)/sessions/2026/10/05/rollout-\(id).jsonl",
                                    cwd: FoldResumeEndToEndTests.folder, terminal: "iTerm2"), ingress: .bridge)
        rig.engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, itermSessionID: "w0t1p0:4D2C", agentPID: daemon,
                                                hostBundleID: ExactJump.itermBundleID, entrypoint: "cli", source: "codex"))
        rig.engine.ingest(F.prompt(id), ingress: .bridge)
        #expect(!rig.engine.canFold(sessionID: id))
        #expect(await rig.engine.fold(sessionID: id) == .refused)
        #expect(!rig.engine.isFolded(id) && rig.exits.current.isEmpty && rig.tucks.current.isEmpty)
        #expect(rig.resumer.availability(for: id) == .openOnly)
        await rig.engine.replyFolded(sessionID: id, text: "go on")
        #expect(rig.commands.current.isEmpty && rig.scripts.current.isEmpty && rig.windows.current.isEmpty)
    }

    /// A reply typed on the card that Codex's lock refused keeps its Retry.
    @Test
    func aReplyCodexsWriterLockRefusedKeepsItsRetry() async throws {
        let rig = Rig()
        rig.codex()
        _ = await rig.engine.fold(sessionID: Self.codexID)
        rig.closeTab(Self.codexID)
        await rig.engine.replyFolded(sessionID: Self.codexID, text: "rename it")
        #expect(rig.commands.current.count == 1)
        rig.runs.current[0].end(ResumeExit(status: 1, output: ResumeOutput(provider: .codex, lines: [
            #"{"type":"error","message":"thread already has an active writer"}"#,
        ])))
        await rig.settle { !rig.resumer.isRunning(Self.codexID) }
        #expect(rig.engine.folds[Self.codexID]?.send == .notSent && rig.engine.folds[Self.codexID]?.stopped == nil)
        await rig.engine.retryFolded(sessionID: Self.codexID)
        #expect(rig.commands.current.map(\.input) == ["rename it", "rename it"])
    }

    /// P1420: a resume never starts while the session's agent runs anywhere: its own process kept by the fold though its
    /// session ended, or another process whose arguments name its id (a `claude --resume` opened by hand).
    @Test
    func aResumeNeverStartsWhileItsAgentRunsAnywhere() async throws {
        let rig = Rig()
        rig.claude(running: true)
        _ = await rig.engine.fold(sessionID: Self.claudeID)
        // Its SessionEnd came, but its process is still there.
        rig.engine.ingest(F.sessionEnd(Self.claudeID), ingress: .bridge)
        rig.runChecks(2)
        #expect(rig.resumer.availability(for: Self.claudeID) == .openOnly)
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "go on") == .nothingToSend)
        // It ends; then another process names its id (the owner ran `claude --resume <id>` in another tab).
        Self.closeWindow(rig)
        rig.runChecks(2)
        rig.found.update { $0 = [5151] }
        #expect(rig.resumer.availability(for: Self.claudeID) == .resume(note: nil))
        await rig.engine.continueFolded(sessionID: Self.claudeID)
        #expect(rig.commands.current.isEmpty)
        #expect(rig.engine.folds[Self.claudeID]?.send == .notSent)
        #expect(rig.resumer.problem(Self.claudeID) == "Not sent · it still runs in a terminal")
        #expect(rig.engine.foldNotes.map(\.said).contains("resume refused · its agent still runs (pid 5151)"))
        // Open in terminal opens no second copy then: the plain jump.
        _ = await rig.engine.openFolded(sessionID: Self.claudeID)
        #expect(rig.windows.current.isEmpty)
        // Once it is gone, Retry goes.
        rig.found.update { $0 = [] }
        if rig.engine.isFolded(Self.claudeID) {
            await rig.engine.retryFolded(sessionID: Self.claudeID)
            #expect(rig.commands.current.count == 1)
        }
    }
}
