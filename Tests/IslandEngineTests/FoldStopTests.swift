import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// A folded session whose window closes mid-turn (wave A7, P1415 to P1434): the fold knows its agent ended while its own
/// turn ran, tells that apart from a turn that finished or an agent quit at its prompt, offers Continue on the owner's
/// click only, and keeps its safety rules. Headless engines: every process, exit, tuck, reply and resume is a stand-in;
/// no terminal, process or CLI is touched.
@MainActor
struct FoldStopTests {
    typealias F = EngineFixtures
    typealias Box = EngineFixtures.Box
    typealias FakeResume = SessionFoldTests.FakeResume

    nonisolated static let agent: Int32 = 900
    nonisolated static let shell: Int32 = 899
    nonisolated static let tty = "/dev/ttys004"

    @MainActor
    struct Rig {
        let engine: SessionEngine
        let resume: FakeResume
        let typed: Box<[(ReplyRoute, String)]>
        let tucks: Box<[TerminalTuck.Move]>
        let scheduled: Box<[F.ScheduledCheck]>
        let clock: Box<Date>
        /// The pids that run: the agent and the shell it ran under, to start with.
        let alive: Box<Set<Int32>>
        /// Each exit watch the engine asked for, by pid: a test calls it as the kernel would.
        let watches: Box<[(Int32, @MainActor @Sendable () -> Void)]>
        let cancelled: Box<Int>
        /// Each running process's short name.
        let names: Box<[Int32: String]>

        func runChecks(_ seconds: TimeInterval = 2) { F.runScheduledChecks(scheduled, clock: clock, for: seconds) }

        /// The owner closes the window: its shell and its agent go, with no SessionEnd (Terminal hangs up the tab).
        func closeWindow() {
            alive.update { $0.subtract([FoldStopTests.agent, FoldStopTests.shell]) }
            for (pid, exited) in watches.current where pid == FoldStopTests.agent { exited() }
        }
    }

    /// `tuck`: what the window's script answers.
    static func rig(tuck: TuckOutcome = .tucked(TuckBounds(left: 100, top: 80, right: 900, bottom: 600)), watches: Bool = true) -> Rig {
        let typed = Box<[(ReplyRoute, String)]>([]), tucks = Box<[TerminalTuck.Move]>([])
        let scheduled = Box<[F.ScheduledCheck]>([]), clock = Box(F.now), alive = Box<Set<Int32>>([agent, shell])
        let watched = Box<[(Int32, @MainActor @Sendable () -> Void)]>([]), cancelled = Box(0)
        let names = Box<[Int32: String]>([agent: "claude", shell: "zsh"])
        let calls = ExactJumpTests.Calls()
        let runner = ExactJumpTests.runner(calls: calls, running: [ExactJumpTests.terminal], frontmost: ExactJumpTests.terminal,
                                           script: { _ in "matched\u{1f}\(FoldStopTests.tty)" })
        let engine = F.engine(clock: clock, scheduled: scheduled, replies: { route, text in
            typed.update { $0.append((route, text)) }
            return true
        }, atPrompt: { alive.current.contains($0) }) { dependencies in
            dependencies.ttyForPID = { alive.current.contains($0) ? FoldStopTests.tty : nil }
            dependencies.processExists = { alive.current.contains($0) }
            dependencies.parentPID = { $0 == FoldStopTests.agent ? FoldStopTests.shell : nil }
            dependencies.processName = { alive.current.contains($0) ? names.current[$0] : nil }
            dependencies.jumpRunner = runner
            dependencies.tuckWindow = { move, _ in
                tucks.update { $0.append(move) }
                return move == .untuck ? .restored : tuck
            }
            dependencies.scheduleFoldCheck = { delay, check in
                scheduled.update { $0.append(F.ScheduledCheck(at: clock.current.addingTimeInterval(delay), run: check)) }
            }
            if watches {
                dependencies.watchProcessExit = { pid, exited in
                    watched.update { $0.append((pid, exited)) }
                    return Token { cancelled.update { $0 += 1 } }
                }
            }
        }
        let resume = FakeResume()
        engine.conversationResume = resume
        return Rig(engine: engine, resume: resume, typed: typed, tucks: tucks, scheduled: scheduled, clock: clock, alive: alive,
                   watches: watched, cancelled: cancelled, names: names)
    }

    final class Token: HookWatchToken {
        let onCancel: () -> Void
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() { onCancel() }
    }

    /// A Claude Code session in a Terminal tab, its agent named by its note; working unless `finished`.
    static func session(_ engine: SessionEngine, _ id: String = "term", finished: Bool = false) {
        engine.ingest(F.started(id), ingress: .bridge)
        engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: agent, hostBundleID: ExactJumpTests.terminal))
        engine.ingest(F.prompt(id), ingress: .bridge)
        engine.ingest(F.running(id), ingress: .bridge)
        if finished { engine.ingest(F.completed(id), ingress: .bridge) }
    }

    /// Notification hooks as the bridge applies them: a non-idle one keeps the phase, an idle one reads it finished.
    static func notification(_ id: String, idle: Bool) -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: id, summary: idle ? "Claude is waiting for your input" : "Claude needs your permission",
                                                phase: idle ? .completed : .running, timestamp: F.now))
    }

    /// SubagentStop, as the bridge applies it to the parent: running activity.
    static func subagentStop(_ id: String) -> AgentEvent {
        F.running(id, summary: "Finished Explore subagent.")
    }

    /// One Claude hook of the tab's agent as the superset helper runs it: its note, then, for a PermissionRequest, its
    /// broker line, held as the broker holds it. Returns the brokered request's id.
    @discardableResult
    static func hook(_ engine: SessionEngine, _ broker: AttentionScene.StubBroker, _ object: [String: Any]) -> String? {
        let environment = ["CLAUDE_CODE_ENTRYPOINT": "cli", "__CFBundleIdentifier": ExactJumpTests.terminal]
        if let note = HookContextNote.make(object: object, environment: environment, agentPID: agent, source: "claude") {
            engine.ingest(note: note)
        }
        guard object["hook_event_name"] as? String == "PermissionRequest" else { return nil }
        let input = try! JSONSerialization.data(withJSONObject: object)
        let line = HookRequestLine(source: "claude", input: input, digest: object["tool_input"].flatMap(HookInputDigest.of),
                                   entrypoint: "cli", agentPID: agent, hostBundleID: ExactJumpTests.terminal, hasTerminal: true)
        let hold = AttentionPolicy.brokerHold(line, object, answersSubagents: engine.answersSubagents, answersCodex: engine.answersCodex)
        let id = UUID().uuidString
        if hold.held { broker.held.update { _ = $0.insert(id) } }
        engine.takeBrokeredRequest(BrokeredRequest(id: id, line: line, object: object, held: hold.held, at: engine.dependencies.now(),
                                                   bound: hold.bound))
        return id
    }

    /// A folded session working in its tab asks to run Bash; the island holds the request, and its notice confirms it.
    static func askBash(_ rig: Rig, _ broker: AttentionScene.StubBroker, _ id: String = "term") -> String? {
        typealias S = AttentionScene
        hook(rig.engine, broker, S.claude("PreToolUse", session: id, tool: "Bash", input: S.push, toolUseID: "U1"))
        rig.engine.ingest(F.running(id, summary: "Running Bash: git push origin main", at: rig.clock.current), ingress: .bridge)
        let request = hook(rig.engine, broker, S.claude("PermissionRequest", session: id, tool: "Bash", input: S.push))
        hook(rig.engine, broker, S.notification("permission_prompt", session: id))
        return request
    }

    /// Claude's idle notice ("Claude is waiting for your input", a minute after its prompt went quiet): its note, then
    /// the bridge's echo, which reads the phase finished.
    static func idleNotice(_ rig: Rig, _ broker: AttentionScene.StubBroker, _ id: String = "term") {
        hook(rig.engine, broker, AttentionScene.claude("Notification", session: id,
                                                       extra: ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"]))
        rig.engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: "Claude is waiting for your input",
                                                                  phase: .completed, timestamp: rig.clock.current)), ingress: .bridge)
    }

    // MARK: Knowing it happened (P1415, P1416)

    @Test
    func aWindowClosedMidTurnIsStoppedAndTheCardStays() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        let fold = rig.engine.folds["term"]
        #expect(fold?.turnOpen == true && fold?.agentPID == Self.agent && fold?.shellPID == Self.shell && fold?.agentName == "claude")
        #expect(rig.watches.current.map(\.0) == [Self.agent])
        rig.closeWindow()
        // The verdict waits a moment for the shell to go too, then says so; the card stays, whatever the clock does.
        #expect(rig.engine.folds["term"]?.stopped == nil)
        rig.runChecks(2)
        let stopped = rig.engine.folds["term"]?.stopped
        #expect(stopped?.windowClosed == true && stopped?.why == .processEnded)
        #expect(stopped?.words == "Stopped when its window closed")
        #expect(rig.engine.folds["term"]?.turnOpen == false)
        rig.runChecks(600)
        #expect(rig.engine.folds["term"] != nil)
        #expect(rig.engine.foldNotes.map(\.said).contains("stopped mid-turn · its window closed · its agent's process ended"))
    }

    @Test
    func anAgentThatEndsAloneMidTurnSaysSo() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        // It crashed (or was quit with Ctrl-C twice): its shell is still there.
        rig.alive.update { $0.remove(Self.agent) }
        for (_, exited) in rig.watches.current { exited() }
        rig.runChecks(2)
        #expect(rig.engine.folds["term"]?.stopped?.windowClosed == false)
        #expect(rig.engine.folds["term"]?.stopped?.words == "Stopped mid-turn")
    }

    @Test
    func aTurnThatFinishedOrAnAgentQuitAtItsPromptIsNoStop() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        rig.engine.ingest(F.completed("term"), ingress: .bridge)
        #expect(rig.engine.folds["term"]?.turnOpen == false)
        // Then the owner quit it at its prompt, or closed its window after the turn: its session ended, its agent went.
        rig.engine.ingest(F.sessionEnd("term"), ingress: .bridge)
        rig.closeWindow()
        rig.runChecks(5)
        #expect(rig.engine.folds["term"]?.stopped == nil && rig.engine.folds["term"] != nil)
        #expect(rig.engine.foldNotes.contains { $0.said.hasPrefix("tab gone") })
    }

    @Test
    func aSessionEndMidTurnIsAStopToo() async {
        let rig = Self.rig(watches: false)
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        // Claude Code's own SessionEnd as Terminal hangs it up, before the process is gone.
        rig.engine.ingest(F.sessionEnd("term"), ingress: .bridge)
        rig.alive.update { $0.subtract([Self.agent, Self.shell]) }
        rig.runChecks(2)
        #expect(rig.engine.folds["term"]?.stopped?.why == .sessionEnded)
        #expect(rig.engine.folds["term"]?.stopped?.windowClosed == true)
    }

    /// With no exit watch (it failed, or the process was already gone), the next change of the state finds the agent gone.
    @Test
    func withoutItsWatchTheNextChangeOfTheStateTellsIt() async {
        let rig = Self.rig(watches: false)
        Self.session(rig.engine)
        Self.session(rig.engine, "other", finished: true)
        _ = await rig.engine.fold(sessionID: "term")
        rig.alive.update { $0.subtract([Self.agent, Self.shell]) }
        rig.runChecks(5)
        #expect(rig.engine.folds["term"]?.stopped == nil)
        // Another session's event, or the process monitor's pass, changes the state.
        rig.engine.ingest(F.prompt("other", "next"), ingress: .bridge)
        rig.runChecks(2)
        #expect(rig.engine.folds["term"]?.stopped?.windowClosed == true)
    }

    /// An agent stopped with Ctrl-Z, or in the background, still runs: no stop, and no resume (P1420).
    @Test
    func anAgentThatLeftItsTerminalButRunsIsNoStop() async {
        let rig = Self.rig()
        let away = Box(false)
        let engine = F.engine(clock: rig.clock, scheduled: rig.scheduled, atPrompt: { _ in !away.current }) { dependencies in
            dependencies.ttyForPID = { _ in FoldStopTests.tty }
            dependencies.processExists = { _ in true }
            dependencies.scheduleFoldCheck = { delay, check in
                rig.scheduled.update { $0.append(F.ScheduledCheck(at: rig.clock.current.addingTimeInterval(delay), run: check)) }
            }
        }
        engine.conversationResume = rig.resume
        Self.session(engine)
        _ = await engine.fold(sessionID: "term")
        away.update { $0 = true }
        engine.ingest(F.running("term"), ingress: .bridge)
        rig.runChecks(5)
        #expect(engine.folds["term"]?.stopped == nil)
        #expect(engine.foldNotes.map(\.said).contains("tab gone · its agent left its terminal's controls"))
    }

    /// A new prompt in a tab (the owner resumed it there by hand) means it goes on: no longer stopped.
    @Test
    func aStoppedSessionThatGoesOnInATabIsStoppedNoLonger() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        rig.closeWindow()
        rig.runChecks(2)
        #expect(rig.engine.folds["term"]?.stopped != nil)
        rig.alive.update { $0.insert(901) }
        rig.engine.ingest(F.started("term", source: .resume), ingress: .bridge)
        rig.engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: "term", agentPID: 901, hostBundleID: ExactJumpTests.terminal))
        rig.engine.ingest(F.prompt("term", "go on"), ingress: .bridge)
        #expect(rig.engine.folds["term"]?.stopped == nil && rig.engine.folds["term"]?.turnOpen == true)
        #expect(rig.engine.folds["term"]?.agentPID == 901)
        #expect(rig.engine.foldReach("term") == .tab)
    }

    /// A pid the system gave another program since the agent ended is not the agent: the stop is said, and the resume
    /// is not held back by it (P1420).
    @Test
    func aReusedPidIsNotTheAgent() async {
        let rig = Self.rig(watches: false)
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        #expect(rig.engine.foldAgentRuns("term", pid: Self.agent))
        rig.alive.update { $0.remove(Self.shell) }
        rig.names.update { $0[Self.agent] = "Safari" }
        #expect(!rig.engine.foldAgentRuns("term", pid: Self.agent))
        rig.engine.ingest(F.running("term"), ingress: .bridge)
        rig.runChecks(2)
        #expect(rig.engine.folds["term"]?.stopped?.why == .processEnded)
        // A name that cannot be read is no proof either way: it counts as the agent while its pid runs.
        rig.names.update { $0[Self.agent] = nil }
        #expect(rig.engine.foldAgentRuns("term", pid: Self.agent))
    }

    // MARK: Continue (P1419)

    @Test
    func aStoppedSessionNeverContinuesByItself() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        rig.closeWindow()
        for _ in 0..<10 {
            rig.runChecks(60)
            rig.engine.ingest(F.prompt("someone-else", "next"), ingress: .bridge)
        }
        await SessionFoldTests.settle()
        #expect(rig.engine.folds["term"]?.stopped != nil)
        #expect(rig.resume.continued.isEmpty && rig.typed.current.isEmpty)
    }

    @Test
    func continueSendsTheWordsTheCardShowsThroughTheResume() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        rig.closeWindow()
        rig.runChecks(2)
        #expect(rig.engine.foldReach("term") == .resume(note: nil))
        await rig.engine.continueFolded(sessionID: "term")
        #expect(rig.resume.continued.map(\.1) == ["Continue where you left off."])
        #expect(SessionEngine.continuePrompt == "Continue where you left off.")
        // It went on: stopped no longer. Nothing was typed into a tab.
        #expect(rig.engine.folds["term"]?.stopped == nil && rig.typed.current.isEmpty)
        #expect(rig.engine.folds["term"]?.lastReply == "Continue where you left off." && rig.engine.folds["term"]?.lastWay == .resume)
        let said = rig.engine.foldNotes.map(\.said)
        #expect(said.contains("Continue") && said.contains("reply sent · the resume"))
        // A second click finds nothing stopped.
        await rig.engine.continueFolded(sessionID: "term")
        #expect(rig.resume.continued.count == 1)
    }

    @Test
    func continueIsOnlyWhereTheResumeCanCarryOn() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        // Not stopped: nothing.
        await rig.engine.continueFolded(sessionID: "term")
        rig.closeWindow()
        rig.runChecks(2)
        // Another agent, or none to resume: Open in terminal only.
        rig.resume.offer = .openOnly
        await rig.engine.continueFolded(sessionID: "term")
        // A reply held, or one on its way: nothing either.
        rig.resume.offer = .resume(note: nil)
        rig.engine.folds["term"]?.send = .sending
        await rig.engine.continueFolded(sessionID: "term")
        rig.engine.folds["term"]?.send = nil
        rig.resume.running = ["term"]
        await rig.engine.continueFolded(sessionID: "term")
        #expect(rig.resume.continued.isEmpty)
    }

    /// A Continue that could not start keeps the card stopped; Retry sends the same words the same way.
    @Test
    func aContinueThatDidNotGoStaysStoppedAndRetries() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        rig.closeWindow()
        rig.runChecks(2)
        rig.resume.outcome = .notSent
        await rig.engine.continueFolded(sessionID: "term")
        #expect(rig.engine.folds["term"]?.send == .notSent && rig.engine.folds["term"]?.stopped != nil)
        rig.resume.outcome = .sent
        await rig.engine.retryFolded(sessionID: "term")
        #expect(rig.resume.continued.map(\.1) == ["Continue where you left off.", "Continue where you left off."])
        #expect(rig.engine.folds["term"]?.stopped == nil)
    }

    // MARK: Safety (P1418, P1421, P1422)

    /// Held replies go only after the main agent's own turn end: never on a subagent's Stop, a Notification (an idle one
    /// reads the phase finished) or a PermissionDenied; and nothing is ever typed into the tab while the turn runs.
    @Test
    func aHeldReplyWaitsForTheMainAgentsOwnTurnEnd() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        await rig.engine.replyFolded(sessionID: "term", text: "then push")
        #expect(rig.engine.folds["term"]?.held == "then push")
        rig.engine.ingest(Self.subagentStop("term"), ingress: .bridge)
        rig.engine.ingest(Self.notification("term", idle: false), ingress: .bridge)
        rig.engine.ingest(Self.notification("term", idle: true), ingress: .bridge)
        #expect(rig.engine.state.session(id: "term")?.phase == .completed)
        for event in F.permissionDenied("term") { rig.engine.ingest(event, ingress: .bridge) }
        rig.engine.ingest(Self.notification("term", idle: true), ingress: .bridge)
        rig.runChecks(10)
        await SessionFoldTests.settle()
        #expect(rig.typed.current.isEmpty && rig.engine.folds["term"]?.held == "then push")
        #expect(rig.engine.foldTurnRuns("term"))
        // A Return typed now is held with it, never typed.
        await rig.engine.replyFolded(sessionID: "term", text: "and tag it")
        #expect(rig.typed.current.isEmpty && rig.engine.folds["term"]?.held == "then push and tag it")
        // The main agent's own Stop: then, a moment later, it goes once.
        rig.engine.ingest(F.completed("term"), ingress: .bridge)
        rig.runChecks(2)
        await SessionFoldTests.settle()
        #expect(rig.typed.current.map(\.1) == ["then push and tag it"])
    }

    /// An interrupt's completion is the agent's own turn end too: Codex's (`turn_aborted`, read from its rollout) and an
    /// agent's whose helper shapes its Interrupt as an interrupted Stop (Kimi). Claude sends none: see below.
    @Test
    func anInterruptEndsTheTurn() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        rig.engine.ingest(F.completed("term", interrupted: true), ingress: .bridge)
        #expect(rig.engine.folds["term"]?.turnOpen == false && !rig.engine.foldTurnRuns("term"))
    }

    // MARK: Turns Claude ends with no Stop (P1437, P1438)

    /// No and stop on the island ends Claude's turn, and Claude sends no Stop for it: the engine applies the interrupt
    /// itself, and the fold's own turn ends with it. The card no longer reads Working, and a reply goes into the tab.
    @Test
    func noAndStopOnTheIslandEndsTheFoldsTurn() async throws {
        let rig = Self.rig()
        let broker = AttentionScene.StubBroker()
        rig.engine.hookRequestBroker = broker
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        let request = try #require(Self.askBash(rig, broker))
        #expect(await rig.engine.approve(requestID: request, decision: .denyAndStop) == .sent)
        let session = try #require(rig.engine.state.session(id: "term"))
        #expect(session.phase == .completed && rig.engine.statusWord(for: session) == .interrupted)
        #expect(rig.engine.folds["term"]?.turnOpen == false && !rig.engine.foldTurnRuns("term"))
        #expect(rig.engine.foldReach("term") == .tab)
        await rig.engine.replyFolded(sessionID: "term", text: "try another way")
        await SessionFoldTests.settle()
        #expect(rig.typed.current.map(\.1) == ["try another way"] && rig.engine.folds["term"]?.held == nil)
    }

    /// A reply held before No and stop goes once the turn has ended that way, a moment later.
    @Test
    func aReplyHeldBeforeNoAndStopGoesAfterIt() async throws {
        let rig = Self.rig()
        let broker = AttentionScene.StubBroker()
        rig.engine.hookRequestBroker = broker
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        let request = try #require(Self.askBash(rig, broker))
        await rig.engine.replyFolded(sessionID: "term", text: "use the staging remote")
        #expect(rig.engine.folds["term"]?.held == "use the staging remote")
        #expect(await rig.engine.approve(requestID: request, decision: .denyAndStop) == .sent)
        rig.runChecks(2)
        await SessionFoldTests.settle()
        #expect(rig.typed.current.map(\.1) == ["use the staging remote"])
    }

    /// The owner stopped the turn: closing the idle window afterwards is no stop, and nothing offers to carry it on.
    @Test
    func closingTheWindowAfterNoAndStopIsNoStop() async throws {
        let rig = Self.rig()
        let broker = AttentionScene.StubBroker()
        rig.engine.hookRequestBroker = broker
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        let request = try #require(Self.askBash(rig, broker))
        #expect(await rig.engine.approve(requestID: request, decision: .denyAndStop) == .sent)
        rig.closeWindow()
        rig.runChecks(5)
        #expect(rig.engine.folds["term"] != nil && rig.engine.folds["term"]?.stopped == nil)
        let said = rig.engine.foldNotes.map(\.said)
        #expect(said.contains("tab gone · its agent's process ended") && !said.contains { $0.hasPrefix("stopped mid-turn") })
    }

    /// Esc in its tab ends Claude's turn with no Stop: about a minute later Claude says it waits at its prompt
    /// (`idle_prompt`), and that ends the fold's turn while its agent holds its terminal. A notice sooner than a minute
    /// after the turn began was sent before it began, and ends nothing.
    @Test
    func claudesIdleNoticeAfterAnEscEndsTheTurn() async {
        let rig = Self.rig()
        let broker = AttentionScene.StubBroker()
        rig.engine.hookRequestBroker = broker
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        await rig.engine.replyFolded(sessionID: "term", text: "then push")
        // A notice from before this turn, late.
        rig.clock.update { $0 += 20 }
        Self.idleNotice(rig, broker)
        rig.runChecks(5)
        await SessionFoldTests.settle()
        #expect(rig.engine.folds["term"]?.turnOpen == true && rig.engine.foldTurnRuns("term") && rig.typed.current.isEmpty)
        // Esc mid-reply: nothing comes, then the notice a minute later.
        rig.clock.update { $0 += 60 }
        Self.idleNotice(rig, broker)
        #expect(rig.engine.folds["term"]?.turnOpen == false && !rig.engine.foldTurnRuns("term"))
        rig.runChecks(2)
        await SessionFoldTests.settle()
        #expect(rig.typed.current.map(\.1) == ["then push"])
    }

    /// The notice ends nothing while the agent does not hold its terminal (stopped with Ctrl-Z, or in the background).
    @Test
    func anIdleNoticeEndsNoTurnItsAgentLeft() async {
        let rig = Self.rig()
        let broker = AttentionScene.StubBroker()
        let away = Box(false)
        let engine = F.engine(clock: rig.clock, scheduled: rig.scheduled, atPrompt: { _ in !away.current }) { dependencies in
            dependencies.ttyForPID = { _ in FoldStopTests.tty }
            dependencies.processExists = { _ in true }
            dependencies.scheduleFoldCheck = { delay, check in
                rig.scheduled.update { $0.append(F.ScheduledCheck(at: rig.clock.current.addingTimeInterval(delay), run: check)) }
            }
        }
        engine.hookRequestBroker = broker
        engine.conversationResume = rig.resume
        Self.session(engine)
        _ = await engine.fold(sessionID: "term")
        away.update { $0 = true }
        rig.clock.update { $0 += 90 }
        Self.hook(engine, broker, AttentionScene.claude("Notification", session: "term",
                                                        extra: ["notification_type": "idle_prompt", "message": "waiting"]))
        #expect(engine.folds["term"]?.turnOpen == true)
    }

    /// A held reply for the tab whose window closed mid-turn goes back to the field, never into a resume by itself.
    @Test
    func aHeldReplyWhenTheWindowClosesComesBack() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        await rig.engine.replyFolded(sessionID: "term", text: "then push")
        rig.closeWindow()
        rig.runChecks(5)
        await SessionFoldTests.settle()
        #expect(rig.engine.folds["term"]?.stopped != nil)
        #expect(rig.engine.folds["term"]?.returned == ReturnedReply(text: "then push", why: .wayChanged))
        #expect(rig.resume.continued.isEmpty && rig.typed.current.isEmpty)
    }

    @Test
    func nothingIsSentWithNoText() async {
        let rig = Self.rig()
        Self.session(rig.engine, finished: true)
        _ = await rig.engine.fold(sessionID: "term")
        for blank in ["", "   ", "\n\t", "\u{1b}"] {
            await rig.engine.replyFolded(sessionID: "term", text: blank)
        }
        #expect(rig.typed.current.isEmpty && rig.engine.folds["term"]?.held == nil && rig.engine.folds["term"]?.send == nil)
        rig.closeWindow()
        for blank in ["", "  "] { await rig.engine.replyFolded(sessionID: "term", text: blank) }
        #expect(rig.resume.continued.isEmpty)
    }

    /// Open in terminal brings a live tab's window out of the Dock whoever put it there: a window that was in the Dock
    /// already when it was sent ("kept"), and one that stayed (it has other tabs; the script leaves it as it is).
    @Test(arguments: [TuckOutcome.kept, .stayed(nil), .failed])
    func openInTerminalBringsBackALiveTabsWindow(tuck: TuckOutcome) async {
        let rig = Self.rig(tuck: tuck)
        Self.session(rig.engine, finished: true)
        _ = await rig.engine.fold(sessionID: "term")
        #expect(rig.engine.folds["term"]?.tucked == false)
        _ = await rig.engine.openFolded(sessionID: "term")
        #expect(rig.tucks.current == [.tuck, .untuck])
        #expect(rig.engine.folds["term"] == nil)
        #expect(rig.engine.foldNotes.last?.said == "opened · its tab")
        // Its watch on the agent went with the card.
        #expect(rig.cancelled.current == 1)
    }

    /// Mid-turn too: the agent still holds its tab, so its window comes back and the jump lands there.
    @Test
    func openInTerminalMidTurnFindsTheLiveTab() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        _ = await rig.engine.openFolded(sessionID: "term")
        #expect(rig.tucks.current == [.tuck, .untuck] && rig.resume.opened.isEmpty)
    }

    /// On a stopped card Open in terminal carries the turn on in the new window, with the words the card shows (P1439):
    /// on 0.7.0 the owner's own sequence (sent, window closed, Open in terminal) brought back an idle conversation. A
    /// card whose turn ended before its window closed opens the conversation alone.
    @Test
    func openInTerminalOnAStoppedCardCarriesTheTurnOn() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        rig.closeWindow()
        rig.runChecks(2)
        #expect(rig.engine.folds["term"]?.stopped != nil)
        _ = await rig.engine.openFolded(sessionID: "term")
        #expect(rig.resume.openedWith.map(\.0) == ["term"] && rig.resume.openedWith.map(\.1) == [SessionEngine.continuePrompt])
        #expect(rig.engine.folds["term"] == nil && rig.resume.continued.isEmpty && rig.typed.current.isEmpty)
        let ended = Self.rig()
        Self.session(ended.engine, finished: true)
        _ = await ended.engine.fold(sessionID: "term")
        ended.closeWindow()
        ended.runChecks(2)
        #expect(ended.engine.folds["term"]?.stopped == nil)
        _ = await ended.engine.openFolded(sessionID: "term")
        #expect(ended.resume.openedWith.map(\.1) == [nil])
        // With no resume to carry it on (another agent), nothing is asked to continue.
        let other = Self.rig()
        other.resume.offer = .openOnly
        Self.session(other.engine)
        _ = await other.engine.fold(sessionID: "term")
        other.closeWindow()
        other.runChecks(2)
        _ = await other.engine.openFolded(sessionID: "term")
        #expect(other.resume.openedWith.allSatisfy { $0.1 == nil })
    }

    // MARK: Working in Terminal (P1417)

    @Test
    func theFoldKnowsItsTerminal() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        #expect(rig.engine.folds["term"]?.host == "Terminal" && rig.engine.folds["term"]?.tucked == true)
        #expect(FoldedSession.hostWord(.iterm(sessionID: "x", tty: nil)) == "iTerm")
        #expect(FoldedSession.hostWord(.ghostty(terminalID: "x")) == "Ghostty")
        #expect(FoldedSession.hostWord(.tmux(pane: "%1", socket: "/tmp/s")) == nil)
    }

    // MARK: The log (P1429)

    /// One line per decision, ids and states only: no reply's text, no answer's.
    @Test
    func theLogSaysEachDecisionAndNoText() async {
        let rig = Self.rig()
        Self.session(rig.engine)
        _ = await rig.engine.fold(sessionID: "term")
        await rig.engine.replyFolded(sessionID: "term", text: "secret plan for the release")
        rig.closeWindow()
        rig.runChecks(5)
        await SessionFoldTests.settle()
        await rig.engine.continueFolded(sessionID: "term")
        let said = rig.engine.foldNotes.map(\.said)
        #expect(said == [
            "sent to the island · window into the Dock · turn running",
            "reply held · for its tab",
            "tab gone · its agent's process ended",
            "stopped mid-turn · its window closed · its agent's process ended",
            "held reply given back · its way changed",
            "Continue",
            "reply sent · the resume",
        ])
        #expect(rig.engine.foldNotes.allSatisfy { $0.sessionID == "term" })
        #expect(!said.joined().contains("secret") && !said.joined().contains("Done."))
    }

    @Test
    func theNotesKeepTheLastTwelve() async {
        let rig = Self.rig()
        Self.session(rig.engine, finished: true)
        for _ in 0..<10 {
            _ = await rig.engine.fold(sessionID: "term")
            rig.engine.unfold(sessionID: "term")
        }
        #expect(rig.engine.foldNotes.count == SessionEngine.foldNoteLimit)
        #expect(rig.engine.foldNotes.last?.said == "dismissed")
    }

    // MARK: The scan for agents naming the id (P1420)

    /// `KERN_PROCARGS2`'s answer read to argv only (the environment after it is never read), and the id matched as a word
    /// of its own, never inside a path.
    @Test
    func theScanReadsArgumentsAndMatchesTheIDAsAWordOfItsOwn() {
        let id = "8f2c3a1e-5b7d-4a6b-9c1d-2e3f4a5b6c7d"
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        bytes += Array("/opt/tools/claude".utf8) + [0, 0, 0]
        bytes += Array("claude".utf8) + [0] + Array("--resume".utf8) + [0] + Array(id.utf8) + [0]
        bytes += Array("NOT_AN_ARGUMENT=1".utf8) + [0]
        #expect(AgentProcessScan.parse(bytes) == ["claude", "--resume", id])
        #expect(AgentProcessScan.parse([1, 0]) == nil)
        #expect(AgentProcessScan.names(id.uppercased(), id) && AgentProcessScan.names("--resume=\(id)", id))
        #expect(!AgentProcessScan.names("/tmp/project/\(id).jsonl", id) && !AgentProcessScan.names("--resume", id))
        // The test's own process reads (its arguments are its own); no other process is looked at here.
        var buffer = [UInt8](repeating: 0, count: AgentProcessScan.argumentLimit())
        #expect(AgentProcessScan.arguments(of: getpid(), buffer: &buffer)?.isEmpty == false)
    }
}
