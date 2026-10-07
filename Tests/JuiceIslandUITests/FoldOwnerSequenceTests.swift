import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Stands in for BridgeServer: no socket is opened.
private final class SilentBridge: EngineBridge, @unchecked Sendable {
    func updateStateSnapshot(_ snapshot: SessionState) {}
    func stop() {}
}

/// The owner's own sequence after 0.7.0 (wave A7, P1435), from end to end, as the app wires it (`LiveSessions` with the
/// real `SessionResumer` behind the engine): Claude Code works in a Terminal.app tab; Send to island puts its window in
/// the Dock and the card reads Working in Terminal; nothing is typed in the card; the window is closed from the Dock,
/// which ends Claude mid-turn with no hook; the card says it stopped when its window closed, keeps the last answer and
/// offers Continue; nothing runs by itself; Continue, clicked twice, runs the resume once with hooks on; the answer
/// comes; Open in terminal then opens the resumed conversation in a new Terminal window.
///
/// Every seam is a stand-in: the reply's sender, the tuck, the jump, the process table (alive, parent, name), the exit
/// watch, the scan for agents naming the id, every run and window, the fold's checks (on the test's own clock). No
/// socket, terminal, osascript, CLI, window or real process is touched or read.
@MainActor
struct FoldOwnerSequenceTests {
    typealias Locked = FoldWiringTests.Locked
    typealias Run = FoldWiringTests.Run

    static let id = "6d1e2f3a-4b5c-4d6e-8f70-81a2b3c4d5e6"
    static let folder = "/tmp/ji-owner/project"
    static let lab = "/tmp/ji-owner/.claude-lab"
    nonisolated static let folders: Set<String> = ["/tmp/ji-owner/project", "/tmp/ji-owner/.claude-lab"]
    nonisolated static let agent: Int32 = 5252
    nonisolated static let shell: Int32 = 5251
    nonisolated static let tty = "/dev/ttys021"
    static let lastAnswer = "Running the whole suite now; 212 tests so far."
    static let resumedAnswer = "Finished the suite: 212 tests pass."

    /// Everything the live engine and its resumer reached for.
    final class Seams: @unchecked Sendable {
        /// The tab's processes: Claude and the shell it runs under. Closing the window takes both.
        let alive = Locked<Set<Int32>>([FoldOwnerSequenceTests.agent, FoldOwnerSequenceTests.shell])
        let typed = Locked<[String]>([])
        let moves = Locked<[TerminalTuck.Move]>([])
        let commands = Locked<[ResumeCommand]>([])
        let runs = Locked<[Run]>([])
        let windows = Locked<[FreshSessionLaunch]>([])
        /// The ids the scan for running agents was asked about, and what it finds (none).
        let scanned = Locked<[String]>([])
        /// Each exit watch the engine asked for; the test fires it as the kernel would.
        let watched = Locked<[Int32]>([])
        let clock = Locked<TimeInterval>(0)
    }

    /// The fold's checks, run on the test's own clock rather than after real seconds.
    @MainActor
    final class Checks {
        var pending: [(at: TimeInterval, run: @MainActor @Sendable () -> Void)] = []
        var exits: [(pid: Int32, exited: @MainActor @Sendable () -> Void)] = []
        let seams: Seams
        init(_ seams: Seams) { self.seams = seams }

        /// Moves the clock on by `seconds`, a second at a time, running each check that falls due.
        func advance(_ seconds: Int) {
            for _ in 0..<seconds {
                seams.clock.update { $0 += 1 }
                let now = seams.clock.current
                let due = pending.filter { $0.at <= now }
                pending.removeAll { $0.at <= now }
                for check in due { check.run() }
            }
        }
    }

    final class Token: HookWatchToken {
        func cancel() {}
    }

    private func makeLive(_ seams: Seams, _ checks: Checks) -> LiveSessions {
        let settings = AppSettings.ephemeral()
        settings.liveSessions = true
        settings.showAs = .island
        return LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .prototype).makeModel() }, engine: {
            var configuration = SessionEngine.Configuration.headless
            configuration.startBridge = true
            configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
            var dependencies = SessionEngine.Dependencies()
            dependencies.isOtherIslandRunning = { false }
            dependencies.socketHasOwner = { _ in false }
            dependencies.startBridge = { _ in SilentBridge() }
            dependencies.startRuntime = { _ in }
            dependencies.updateProcessRoots = { _ in }
            dependencies.watchTranscript = { _, _, _ in nil }
            dependencies.readPeek = nil
            dependencies.readForkParent = { _ in nil }
            dependencies.readCodexSettings = { _ in nil }
            dependencies.sendReply = { _, text in
                seams.typed.update { $0.append(text) }
                return true
            }
            // Send to island puts the window in the Dock (the owner's case), and gives its bounds.
            dependencies.tuckWindow = { move, _ in
                seams.moves.update { $0.append(move) }
                return move == .untuck ? .restored : .tucked(TuckBounds(left: 120, top: 90, right: 920, bottom: 640))
            }
            dependencies.openFresh = { _ in false }
            // The process table, as the tab's processes stand.
            dependencies.agentAtPrompt = { $0 == FoldOwnerSequenceTests.agent && seams.alive.current.contains($0) }
            // A made-up pid is never asked whether it is a Codex app-server (P1485).
            dependencies.isCodexServer = { _ in false }
            dependencies.ttyForPID = { seams.alive.current.contains($0) ? FoldOwnerSequenceTests.tty : nil }
            dependencies.processExists = { seams.alive.current.contains($0) }
            dependencies.parentPID = { $0 == FoldOwnerSequenceTests.agent ? FoldOwnerSequenceTests.shell : nil }
            dependencies.processName = { pid in
                guard seams.alive.current.contains(pid) else { return nil }
                return pid == FoldOwnerSequenceTests.agent ? "claude" : "zsh"
            }
            dependencies.watchProcessExit = { pid, exited in
                seams.watched.update { $0.append(pid) }
                checks.exits.append((pid, exited))
                return Token()
            }
            dependencies.scheduleFoldCheck = { delay, check in
                checks.pending.append((seams.clock.current + delay, check))
            }
            dependencies.appForPID = { _ in nil }
            dependencies.isSessionFrontmost = { _ in false }
            dependencies.frontmostBundleID = { nil }
            var runner = JumpRunner()
            runner.appURL = { _ in nil }
            runner.isAppRunning = { _ in false }
            runner.appleScript = { _, _ in throw CocoaError(.featureUnsupported) }
            runner.open = { _, _ in throw CocoaError(.featureUnsupported) }
            runner.command = { _, _, _ in false }
            runner.capture = { _, _, _ in throw CocoaError(.featureUnsupported) }
            runner.isExecutable = { _ in false }
            runner.frontmostBundleID = { nil }
            runner.appForPID = { _ in nil }
            dependencies.jumpRunner = runner
            return SessionEngine(configuration: configuration, dependencies: dependencies)
        }, resumer: { engine in
            var dependencies = SessionResumer.Dependencies()
            dependencies.start = { command in
                seams.commands.update { $0.append(command) }
                var made: Run!
                seams.runs.update {
                    made = Run(pid: Int32(7100 + $0.count))
                    $0.append(made)
                }
                return made
            }
            dependencies.openWindow = { launch in
                seams.windows.update { $0.append(launch) }
                return true
            }
            dependencies.isFolder = { FoldOwnerSequenceTests.folders.contains($0) }
            // Not the tab's terminal: the new window must still be Terminal's, the one the session was in.
            dependencies.usualHost = { .ghostty }
            dependencies.findAgents = { id in
                seams.scanned.update { $0.append(id) }
                return []
            }
            // The app's own environment, its skip switches set as `CLIEnvironment.make` sets them.
            dependencies.environment = {
                var app = ["SHELL": "/bin/zsh", "__CFBundleIdentifier": "com.ofengenden.juice"]
                for key in CLIEnvironment.islandSkipKeys { app[key] = "1" }
                return app
            }
            dependencies.sleep = { _ in }
            dependencies.quitGrace = 0
            return SessionResumer(engine: engine, dependencies: dependencies)
        }, profiles: { LiveProfiles(accounts: [], discovered: []) })
    }

    private static func until(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(await Looks.until(5, condition), sourceLocation: sourceLocation)
    }

    private static func prompt(_ text: String) -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: id, summary: FixtureSessionFeed.promptPrefix + text, phase: .running,
                                                timestamp: Date()))
    }

    private static func answer(_ text: String, prompt: String) -> AgentEvent {
        .claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
            transcriptPath: "\(lab)/projects/-tmp-ji-owner-project/\(id).jsonl", lastUserPrompt: prompt,
            lastAssistantMessage: text, currentTool: "Bash", currentToolInputPreview: "swift test"), timestamp: Date()))
    }

    @Test
    func theOwnersSequenceStopsSaysSoAndContinuesOnceThenOpensTheResumedConversation() async throws {
        let seams = Seams()
        let checks = Checks(seams)
        let live = makeLive(seams, checks)
        live.apply()
        let engine = try #require(live.engine)
        let resumer = try #require(live.resumer)
        #expect(engine.conversationResume === resumer)

        // 1. Claude Code works in a Terminal.app tab.
        engine.ingest(.sessionStarted(SessionStarted(
            sessionID: Self.id, title: "Claude · project", tool: .claudeCode, origin: .live, initialPhase: .running,
            summary: "Started.", timestamp: Date(), jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project",
                                                                           paneTitle: "claude", workingDirectory: Self.folder),
            claudeMetadata: ClaudeSessionMetadata(transcriptPath: "\(Self.lab)/projects/-tmp-ji-owner-project/\(Self.id).jsonl"))),
                      ingress: .bridge)
        engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: Self.id, agentPID: Self.agent,
                                            hostBundleID: "com.apple.Terminal", entrypoint: "cli", source: "claude"))
        engine.ingest(Self.prompt("run the whole suite and fix what fails"), ingress: .bridge)
        engine.ingest(Self.answer(Self.lastAnswer, prompt: "run the whole suite and fix what fails"), ingress: .bridge)

        // 2. Send to island: the window goes into the Dock and the card reads Working in Terminal.
        #expect(await live.sendToIsland(Self.id) == TuckBounds(left: 120, top: 90, right: 920, bottom: 640))
        #expect(seams.moves.current == [.tuck])
        #expect(engine.folds[Self.id]?.turnOpen == true && engine.folds[Self.id]?.agentPID == Self.agent)
        #expect(seams.watched.current == [Self.agent])
        var card = try #require(live.foldedCard(Self.id))
        #expect(card.reach == .tab && card.working && card.inTerminal == "Terminal" && card.continuePrompt == nil)
        #expect(FoldedCardLine.left(card, row: card.row) == .working(inTerminal: "Terminal"))
        #expect(card.message == Self.lastAnswer)

        // 3. Nothing is typed in the card. The owner closes the window from the Dock: Terminal hangs up the shell and
        // Claude mid-turn, with no hook; the kernel says the agent exited.
        seams.alive.update { $0.subtract([Self.agent, Self.shell]) }
        for exit in checks.exits where exit.pid == Self.agent { exit.exited() }
        checks.advance(2)
        card = try #require(live.foldedCard(Self.id))
        #expect(card.stopped == "Stopped when its window closed")
        #expect(FoldedCardLine.left(card, row: card.row) == .stopped("Stopped when its window closed"))
        #expect(card.continuePrompt == SessionEngine.continuePrompt && card.continuePrompt == "Continue where you left off.")
        #expect(card.reach == .resume && !card.working && !card.stoppable && card.inTerminal == nil)
        #expect(FoldedCardLine.openTitle(card) == "Continue in terminal")
        // It keeps Claude's last answer, and its turn reads interrupted, not working.
        #expect(card.message == Self.lastAnswer)
        #expect(engine.state.session(id: Self.id)?.phase == .completed && engine.interruptedSessionIDs.contains(Self.id))

        // Minutes pass: nothing runs, opens or is typed by itself.
        checks.advance(600)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(seams.commands.current.isEmpty && seams.windows.current.isEmpty && seams.typed.current.isEmpty)
        #expect(seams.scanned.current.isEmpty)
        #expect(live.foldedCard(Self.id)?.stopped == "Stopped when its window closed")

        // 4. Continue, clicked twice: one run, Claude's own resume with the words the card showed, hooks on.
        live.continueFolded(Self.id)
        live.continueFolded(Self.id)
        await Self.until { seams.commands.current.count == 1 && resumer.runs[Self.id]?.pid != nil }
        let command = try #require(seams.commands.current.first)
        #expect(command.tool == "claude" && command.arguments == ["-p", "--resume", Self.id, "--output-format", "json"])
        #expect(command.input == "Continue where you left off." && command.folder == Self.folder)
        #expect(command.environment["CLAUDE_CONFIG_DIR"] == Self.lab)
        for key in CLIEnvironment.islandSkipKeys { #expect(command.environment[key] == nil, "\(key)") }
        #expect(command.environment["__CFBundleIdentifier"] == nil)
        // The scan for any agent still running the conversation looked once, just before the run.
        #expect(seams.scanned.current == [Self.id])
        await Self.until { live.foldedCard(Self.id)?.stoppable == true }
        card = try #require(live.foldedCard(Self.id))
        #expect(card.working && card.stopped == nil && card.continuePrompt == nil)
        #expect(FoldedCardLine.left(card, row: card.row) == .working(inTerminal: nil))
        live.continueFolded(Self.id)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(seams.commands.current.count == 1)

        // The run's hooks: a new process with no terminal, its prompt, its answer, the turn's end. None of them is
        // taken for the tab's agent.
        let run = seams.runs.current[0]
        engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: Self.id, agentPID: run.pid, entrypoint: "sdk-cli",
                                            source: "claude", sessionStartSource: "resume"))
        engine.ingest(Self.prompt("Continue where you left off."), ingress: .bridge)
        engine.ingest(Self.answer(Self.resumedAnswer, prompt: "Continue where you left off."), ingress: .bridge)
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: Self.id, summary: Self.resumedAnswer, timestamp: Date())),
                      ingress: .bridge)
        #expect(engine.folds[Self.id]?.agentPID == Self.agent)
        let result = ["type": "result", "subtype": "success", "is_error": false, "result": Self.resumedAnswer] as [String: Any]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        run.end(ResumeExit(status: 0, output: ResumeOutput(provider: .claude, lines: [line])))
        await Self.until { !resumer.isRunning(Self.id) }
        card = try #require(live.foldedCard(Self.id))
        #expect(card.message == Self.resumedAnswer && !card.working && !card.stoppable)
        #expect(card.stopped == nil && card.continuePrompt == nil && resumer.problem(Self.id) == nil)
        checks.advance(30)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(seams.commands.current.count == 1 && seams.typed.current.isEmpty && seams.windows.current.isEmpty)

        // 5. Open in terminal: the resumed conversation, with the turn Continue carried on, in a new window of the tab's
        // own terminal. No window comes out of the Dock (it is gone) and the card goes.
        live.openFolded(Self.id)
        await Self.until { !seams.windows.current.isEmpty && live.foldedCard(Self.id) == nil }
        #expect(seams.windows.current == [FreshSessionLaunch(
            host: .terminal, folder: Self.folder,
            line: "cd '\(Self.folder)' && CLAUDE_CONFIG_DIR='\(Self.lab)' claude --resume '\(Self.id)'")])
        #expect(seams.scanned.current == [Self.id, Self.id])
        #expect(seams.moves.current == [.tuck] && seams.typed.current.isEmpty && seams.commands.current.count == 1)
        #expect(!engine.isFolded(Self.id))

        // The fold's log says each step, ids and states only.
        let said = engine.foldNotes.map(\.said)
        #expect(said.first == "sent to the island · window into the Dock · turn running")
        #expect(said.contains("stopped mid-turn · its window closed · its agent's process ended"))
        #expect(said.filter { $0 == "Continue" }.count == 1 && said.filter { $0 == "resume started" }.count == 1)
        #expect(said.contains("resume exited · status 0"))
        #expect(said.last == "opened · a new window with the resume")
        #expect(!said.joined().contains("suite"))
        live.shutdown()
    }

    /// The owner's sequence on 0.7.0 exactly, Continue never clicked (P1439): Send to island, the window closed from the
    /// Dock, then the card's Open in terminal. On 0.7.0 that brought back an idle conversation ("when I re-opened it, it
    /// stopped?"). Now the card's link says Continue in terminal, and the new Terminal window's resume carries the cut
    /// turn on with the words the card shows; no run starts on the island, and nothing is typed anywhere else.
    @Test
    func theOwnersSequenceWithoutContinueOpensAWindowThatCarriesTheTurnOn() async throws {
        let seams = Seams()
        let checks = Checks(seams)
        let live = makeLive(seams, checks)
        live.apply()
        let engine = try #require(live.engine)
        engine.ingest(.sessionStarted(SessionStarted(
            sessionID: Self.id, title: "Claude · project", tool: .claudeCode, origin: .live, initialPhase: .running,
            summary: "Started.", timestamp: Date(), jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project",
                                                                           paneTitle: "claude", workingDirectory: Self.folder),
            claudeMetadata: ClaudeSessionMetadata(transcriptPath: "\(Self.lab)/projects/-tmp-ji-owner-project/\(Self.id).jsonl"))),
                      ingress: .bridge)
        engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: Self.id, agentPID: Self.agent,
                                            hostBundleID: "com.apple.Terminal", entrypoint: "cli", source: "claude"))
        engine.ingest(Self.prompt("run the whole suite and fix what fails"), ingress: .bridge)
        engine.ingest(Self.answer(Self.lastAnswer, prompt: "run the whole suite and fix what fails"), ingress: .bridge)
        #expect(await live.sendToIsland(Self.id) != nil)
        #expect(live.foldedCard(Self.id)?.inTerminal == "Terminal")

        // The window closed from the Dock, mid-turn.
        seams.alive.update { $0.subtract([Self.agent, Self.shell]) }
        for exit in checks.exits where exit.pid == Self.agent { exit.exited() }
        checks.advance(2)
        let card = try #require(live.foldedCard(Self.id))
        #expect(card.stopped == "Stopped when its window closed" && card.reach == .resume)
        #expect(FoldedCardLine.openTitle(card) == "Continue in terminal")

        // Open in terminal, as the owner clicked it: the conversation in a new Terminal window, the turn carried on.
        live.openFolded(Self.id)
        await Self.until { !seams.windows.current.isEmpty && live.foldedCard(Self.id) == nil }
        #expect(seams.windows.current == [FreshSessionLaunch(
            host: .terminal, folder: Self.folder,
            line: "cd '\(Self.folder)' && CLAUDE_CONFIG_DIR='\(Self.lab)' claude --resume '\(Self.id)' 'Continue where you left off.'")])
        #expect(seams.commands.current.isEmpty && seams.typed.current.isEmpty && seams.moves.current == [.tuck])
        #expect(seams.scanned.current == [Self.id] && !engine.isFolded(Self.id))
        let said = engine.foldNotes.map(\.said)
        #expect(said.contains("stopped mid-turn · its window closed · its agent's process ended"))
        #expect(said.last == "opened · a new window with the resume, carrying the turn on")
        #expect(!said.joined().contains("suite"))
        live.shutdown()
    }
}
