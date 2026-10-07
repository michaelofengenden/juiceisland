import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Stands in for BridgeServer: no socket is opened.
private final class StubBridge: EngineBridge, @unchecked Sendable {
    func updateStateSnapshot(_ snapshot: SessionState) {}
    func stop() {}
}

/// Send to island as the app wires it (wave 6, P1350 to P1354): the Live sessions switch makes the resumer and hands it
/// to the engine, the folded card shows what the resume says (its Codex line, why a reply did not go, the run's own
/// answer), and quitting or the switch going off ends a run. The live engine's every seam is a stand-in (the bridge,
/// the reply's sender, the tuck, the jump, every run and window): no socket, terminal, osascript, CLI or window.
@MainActor
struct FoldWiringTests {
    static let codexID = "019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b"
    static let claudeID = "8f2c3a1e-5b7d-4a6b-9c1d-2e3f4a5b6c7d"
    static let folder = "/tmp/ji-wiring/project"
    static let side = "/tmp/ji-wiring/.codex-side"
    static let lab = "/tmp/ji-wiring/.claude-lab"
    nonisolated static let folders: Set<String> = ["/tmp/ji-wiring/project", "/tmp/ji-wiring/.codex-side", "/tmp/ji-wiring/.claude-lab"]
    nonisolated static let agent: Int32 = 4242

    final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
        var current: Value { lock.withLock { value } }
    }

    /// A run that ends when the test says so, and records its signals.
    final class Run: ResumeProcess, @unchecked Sendable {
        let pid: Int32
        let interrupts = Locked(0)
        let terminates = Locked(0)
        private let lock = NSLock()
        private var ended: ResumeExit?
        private var waiters: [CheckedContinuation<ResumeExit, Never>] = []

        init(pid: Int32) { self.pid = pid }
        var hasExited: Bool { lock.withLock { ended != nil } }
        func interrupt() { interrupts.update { $0 += 1 } }
        func terminate() { terminates.update { $0 += 1 } }

        func exit() async -> ResumeExit {
            await withCheckedContinuation { continuation in
                let done: ResumeExit? = lock.withLock {
                    if let ended { return ended }
                    waiters.append(continuation)
                    return nil
                }
                if let done { continuation.resume(returning: done) }
            }
        }

        func end(_ exit: ResumeExit) {
            let waiting: [CheckedContinuation<ResumeExit, Never>] = lock.withLock {
                guard ended == nil else { return [] }
                ended = exit
                defer { waiters = [] }
                return waiters
            }
            for waiter in waiting { waiter.resume(returning: exit) }
        }
    }

    /// Everything the live engine and its resumer reached for.
    final class Seams: @unchecked Sendable {
        let alive = Locked<Set<Int32>>([FoldWiringTests.agent])
        let typed = Locked<[String]>([])
        let tucks = Locked(0)
        let commands = Locked<[ResumeCommand]>([])
        let runs = Locked<[Run]>([])
        let windows = Locked<[FreshSessionLaunch]>([])
        let startError = Locked<ResumeStartError?>(nil)
    }

    private func makeLive(_ seams: Seams, settings: AppSettings) -> LiveSessions {
        LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .prototype).makeModel() }, engine: {
            var configuration = SessionEngine.Configuration.headless
            configuration.startBridge = true
            configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
            var dependencies = SessionEngine.Dependencies()
            dependencies.isOtherIslandRunning = { false }
            dependencies.socketHasOwner = { _ in false }
            dependencies.startBridge = { _ in StubBridge() }
            dependencies.startRuntime = { _ in }
            dependencies.updateProcessRoots = { _ in }
            dependencies.watchTranscript = { _, _, _ in nil }
            dependencies.readPeek = nil
            dependencies.readForkParent = { _ in nil }
            dependencies.readCodexSettings = { _ in nil }
            // The live engine's own seams would reach real terminals: every one is a recorder here.
            dependencies.sendReply = { _, text in
                seams.typed.update { $0.append(text) }
                return true
            }
            dependencies.tuckWindow = { move, _ in
                seams.tucks.update { $0 += 1 }
                return move == .untuck ? .restored : .kept
            }
            dependencies.openFresh = { _ in false }
            dependencies.agentAtPrompt = { seams.alive.current.contains($0) }
            // A made-up pid is never asked whether it is a Codex app-server (P1485).
            dependencies.isCodexServer = { _ in false }
            dependencies.ttyForPID = { seams.alive.current.contains($0) ? "/dev/ttys004" : nil }
            dependencies.appForPID = { _ in nil }
            dependencies.processExists = { seams.alive.current.contains($0) }
            // The process table's parent and name and the exit watch are stand-ins too: this engine is the app's kind
            // (`startBridge`), whose defaults read and watch real processes (P1435).
            dependencies.parentPID = { _ in nil }
            dependencies.processName = { _ in nil }
            dependencies.watchProcessExit = { _, _ in nil }
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
                if let error = seams.startError.current { throw error }
                seams.commands.update { $0.append(command) }
                var made: Run!
                seams.runs.update {
                    made = Run(pid: Int32(7000 + $0.count))
                    $0.append(made)
                }
                return made
            }
            dependencies.openWindow = { launch in
                seams.windows.update { $0.append(launch) }
                return true
            }
            dependencies.isFolder = { FoldWiringTests.folders.contains($0) }
            dependencies.usualHost = { .terminal }
            // No scan of this Mac's processes for an agent naming the id (P1420, P1435).
            dependencies.findAgents = { _ in [] }
            dependencies.environment = { [:] }
            dependencies.sleep = { _ in }
            dependencies.quitGrace = 0
            return SessionResumer(engine: engine, dependencies: dependencies)
        }, profiles: { LiveProfiles(accounts: [], discovered: []) })
    }

    /// The switch on, with a Codex session and a Claude session in Terminal tabs whose turns finished.
    private func live(_ seams: Seams) throws -> (LiveSessions, SessionEngine, SessionResumer) {
        let settings = AppSettings.ephemeral()
        settings.liveSessions = true
        settings.showAs = .island
        let live = makeLive(seams, settings: settings)
        live.apply()
        let engine = try #require(live.engine)
        let resumer = try #require(live.resumer)
        engine.ingest(.sessionStarted(SessionStarted(
            sessionID: Self.codexID, title: "Codex · project", tool: .codex, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: Date(), jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project", paneTitle: "codex",
                                                      workingDirectory: Self.folder),
            codexMetadata: CodexSessionMetadata(transcriptPath: "\(Self.side)/sessions/2026/10/05/rollout-\(Self.codexID).jsonl"))),
                      ingress: .bridge)
        engine.ingest(.sessionStarted(SessionStarted(
            sessionID: Self.claudeID, title: "Claude · project", tool: .claudeCode, origin: .live, initialPhase: .running,
            summary: "Started.", timestamp: Date(), jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project",
                                                                           paneTitle: "claude", workingDirectory: Self.folder),
            claudeMetadata: ClaudeSessionMetadata(transcriptPath: "\(Self.lab)/projects/-tmp-ji-wiring-project/\(Self.claudeID).jsonl"))),
                      ingress: .bridge)
        for id in [Self.codexID, Self.claudeID] {
            engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: Self.agent,
                                                hostBundleID: "com.apple.Terminal", entrypoint: "cli",
                                                source: id == Self.codexID ? "codex" : "claude"))
            engine.ingest(.sessionCompleted(SessionCompleted(sessionID: id, summary: "Done.", timestamp: Date())), ingress: .bridge)
        }
        return (live, engine, resumer)
    }

    /// The owner closes both tabs: the agent goes, and the SessionEnds come.
    private func closeTabs(_ seams: Seams, _ engine: SessionEngine) {
        seams.alive.update { $0.remove(Self.agent) }
        for id in [Self.codexID, Self.claudeID] {
            engine.ingest(.sessionCompleted(SessionCompleted(sessionID: id, summary: "Session ended.", timestamp: Date(),
                                                             isInterrupt: true, isSessionEnd: true)), ingress: .bridge)
        }
    }

    /// Waits for `condition`, for at most 2 s.
    private static func until(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    @Test
    func theSwitchGivesTheEngineItsResumer() throws {
        let (live, engine, resumer) = try live(Seams())
        #expect(engine.conversationResume === resumer)
        // Made once, with the engine: the switch going off and on again keeps both.
        live.settings.liveSessions = false
        live.apply()
        live.settings.liveSessions = true
        live.apply()
        #expect(live.resumer === resumer && live.engine === engine && engine.conversationResume === resumer)
    }

    @Test
    func aClosedCodexTabsCardSaysItsLineThenWhyItsRunFailedThenItsAnswer() async throws {
        let seams = Seams()
        let (live, engine, resumer) = try live(seams)
        #expect(await live.sendToIsland(Self.codexID) == nil)
        #expect(live.foldedCard(Self.codexID)?.reach == .tab)
        closeTabs(seams, engine)
        var card = try #require(live.foldedCard(Self.codexID))
        #expect(card.reach == .resume && card.note == SessionResumer.codexNote && card.problem == nil)
        #expect(FoldedCardView.showsField(card) && FoldedCardLine.left(card, row: card.row) == .note(SessionResumer.codexNote))
        #expect(seams.commands.current.isEmpty && seams.typed.current.isEmpty)

        // A Return: the run starts, the card reads Working with Stop, and the note is said no more.
        live.replyFolded(Self.codexID, text: "/review")
        try await Self.until { seams.commands.current.count == 1 }
        try await Self.until { live.foldedCard(Self.codexID)?.stoppable == true && live.foldedCard(Self.codexID)?.send == nil }
        card = try #require(live.foldedCard(Self.codexID))
        #expect(card.working && card.note == nil && card.problem == nil)
        #expect(seams.commands.current.first?.arguments == ["exec", "resume", "--json", Self.codexID, "-"])

        // It fails: the card says why, in the note's place, with no Retry (the reply went).
        let failed = ResumeOutput(provider: .codex, lines: [#"{"type":"turn.started"}"#,
                                                            #"{"type":"turn.failed","error":{"message":"usage limit reached"}}"#])
        seams.runs.current[0].end(ResumeExit(status: 1, output: failed))
        try await Self.until { !resumer.isRunning(Self.codexID) }
        card = try #require(live.foldedCard(Self.codexID))
        #expect(card.problem == "Failed · usage limit reached" && !card.working && !card.stoppable)
        #expect(FoldedCardLine.left(card, row: card.row) == .problem("Failed · usage limit reached", retry: false))

        // The next Return clears it; this run's hooks report no answer, so the card shows the run's own.
        live.replyFolded(Self.codexID, text: "try again")
        try await Self.until { seams.commands.current.count == 2 }
        try await Self.until { live.foldedCard(Self.codexID)?.stoppable == true }
        #expect(live.foldedCard(Self.codexID)?.problem == nil)
        let before = live.foldedCard(Self.codexID)?.message
        let done = ResumeOutput(provider: .codex, lines: [
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Reviewed: two nits."}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1}}"#,
        ])
        seams.runs.current[1].end(ResumeExit(status: 0, output: done))
        try await Self.until { !resumer.isRunning(Self.codexID) }
        card = try #require(live.foldedCard(Self.codexID))
        #expect(card.message == "Reviewed: two nits." && card.message != before && card.problem == nil)
        // A run whose hooks do report its answer (its prompt reopens the ended session first): theirs is shown.
        live.replyFolded(Self.codexID, text: "and fix them")
        try await Self.until { seams.commands.current.count == 3 && live.foldedCard(Self.codexID)?.stoppable == true }
        engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: Self.codexID, summary: FixtureSessionFeed.promptPrefix + "and fix them",
                                                              phase: .running, timestamp: Date())), ingress: .bridge)
        engine.ingest(.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: Self.codexID, codexMetadata: CodexSessionMetadata(
            transcriptPath: "\(Self.side)/sessions/2026/10/05/rollout-\(Self.codexID).jsonl", lastUserPrompt: "and fix them",
            lastAssistantMessage: "Two nits, both fixed."), timestamp: Date())), ingress: .bridge)
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: Self.codexID, summary: "Two nits, both fixed.", timestamp: Date())),
                      ingress: .bridge)
        let fixed = ResumeOutput(provider: .codex, lines: [
            #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Fixed both."}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1}}"#,
        ])
        seams.runs.current[2].end(ResumeExit(status: 0, output: fixed))
        try await Self.until { !resumer.isRunning(Self.codexID) }
        #expect(live.foldedCard(Self.codexID)?.message == "Two nits, both fixed.")
        #expect(seams.typed.current.isEmpty)
    }

    @Test
    func aReplyThatCouldNotStartSaysWhyAndKeepsItsRetry() async throws {
        let seams = Seams()
        let (live, engine, _) = try live(seams)
        _ = await live.sendToIsland(Self.claudeID)
        closeTabs(seams, engine)
        seams.startError.update { $0 = .toolMissing("claude") }
        live.replyFolded(Self.claudeID, text: "go on")
        try await Self.until { live.foldedCard(Self.claudeID)?.send == .notSent }
        let card = try #require(live.foldedCard(Self.claudeID))
        #expect(card.problem == "Not sent · Claude Code not found")
        #expect(FoldedCardLine.left(card, row: card.row) == .problem("Not sent · Claude Code not found", retry: true))
        // Retry, once the CLI is there: one run.
        seams.startError.update { $0 = nil }
        live.retryFolded(Self.claudeID)
        try await Self.until { seams.commands.current.count == 1 }
        try await Self.until { live.foldedCard(Self.claudeID)?.problem == nil }
        #expect(seams.commands.current.map(\.input) == ["go on"])
    }

    @Test
    func quittingAndTheSwitchGoingOffEndTheRun() async throws {
        let seams = Seams()
        let (live, engine, resumer) = try live(seams)
        _ = await live.sendToIsland(Self.claudeID)
        _ = await live.sendToIsland(Self.codexID)
        closeTabs(seams, engine)
        live.replyFolded(Self.claudeID, text: "go on")
        // Its process started (the Return's task has handed it to the resumer).
        try await Self.until { resumer.runs[Self.claudeID]?.pid != nil }
        live.settings.liveSessions = false
        live.apply()
        #expect(seams.runs.current[0].interrupts.current == 1 && seams.runs.current[0].terminates.current == 1)
        seams.runs.current[0].end(ResumeExit(status: 130, output: ResumeOutput(provider: .claude)))
        try await Self.until { !resumer.isRunning(Self.claudeID) }

        live.settings.liveSessions = true
        live.apply()
        #expect(live.foldedCard(Self.codexID)?.reach == .resume)
        live.replyFolded(Self.codexID, text: "go on")
        try await Self.until { resumer.runs[Self.codexID]?.pid != nil }
        live.shutdown()
        #expect(seams.runs.current[1].interrupts.current == 1 && seams.runs.current[1].terminates.current == 1)
        #expect(seams.typed.current.isEmpty && seams.windows.current.isEmpty)
    }
}
