import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// The owner's report of 2026-09-28: a Claude session whose main turn had ended while one background agent still ran
/// ("Waiting for 1 background agent to finish" in Claude Code) showed the green Done check and gave a Done notice (P370-
/// P372). A main agent that waits on its subagents is not done: its word is `.subagents(n)`, it counts as running, and
/// only its own turn end notifies: the Stop of the turn their results wake. Driven as the superset helper and upstream's
/// bridge drive the engine (`AttentionScene`): each hook's note first, then what the bridge emits for it (nothing for a
/// SubagentStop once the parent's turn has ended, `BridgeServer.swift` `sessionWasAlreadyCompleted`). Stop's
/// `background_tasks` is Claude Code 2.1's field ("Empty array when nothing is in flight"); agent ids are fictional.
@MainActor
struct ClaudeSubagentWaitTests {
    typealias S = AttentionScene
    typealias F = EngineFixtures

    // MARK: Hooks

    /// The Agent tool starts a subagent: its SubagentStart, which the bridge applies as the parent's running activity.
    private func spawn(_ s: S, _ agent: String, type: String = "worker") {
        s.hook(S.claude("SubagentStart", agent: agent, agentType: type))
        s.bridge(F.running("s1", summary: "Started \(type) subagent.", at: s.clock.current))
    }

    /// The main agent's Stop: `background` names the work still in flight (nil: a Claude that sends no such field).
    private func stop(_ s: S, background: [String]? = []) {
        var extra: [String: Any] = ["stop_hook_active": false, "last_assistant_message": "Started the agent."]
        if let background {
            extra["background_tasks"] = background.map { ["id": $0, "type": "subagent", "status": "running", "description": "Map the parser"] }
        }
        s.hook(S.claude("Stop", extra: extra))
        s.bridge(.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "Started the agent.", timestamp: s.clock.current)))
    }

    /// A subagent finishes. Upstream's bridge emits the parent's running activity only while the parent's turn runs.
    private func finish(_ s: S, _ agent: String, type: String = "worker") {
        s.hook(S.claude("SubagentStop", agent: agent, agentType: type))
        if s.phase() != .completed { s.bridge(F.running("s1", summary: "Finished \(type) subagent.", at: s.clock.current)) }
    }

    /// The main agent woken by a finished agent's result: Claude's `<task-notification>` as a prompt (P155, P253).
    private func wake(_ s: S, _ agent: String) {
        s.hook(S.claude("UserPromptSubmit"))
        s.bridge(F.prompt("s1", "<task-notification>\n<task-id>\(agent)</task-id>\n<status>completed</status>\n</task-notification>",
                          at: s.clock.current))
    }

    private func word(_ s: S) -> StatusWord? { s.engine.state.session(id: "s1").map(s.engine.statusWord) }

    private func delegating(_ s: S) -> Bool { s.engine.state.session(id: "s1").map(s.engine.isDelegating) ?? false }

    private func needsAttention(_ s: S) -> Bool { s.engine.state.session(id: "s1").map(s.engine.needsAttention) ?? false }

    // MARK: The owner's report

    /// A background agent still runs at the main agent's Stop: the row waits on it (not done), counts as running, and no
    /// Done comes, however long it runs. Its own tools send notes, which change nothing the owner sees.
    @Test
    func aBackgroundAgentAtStopKeepsTheRowWaitingWithNoDone() throws {
        let s = S()
        s.begin()
        spawn(s, "a1")
        s.at(2)
        stop(s, background: ["a1"])
        #expect(word(s) == .subagents(1))
        #expect(delegating(s) && s.phase() == .completed)
        #expect(s.engine.runningCount == 1 && s.engine.rows.map(\.id) == ["s1"])
        s.at(10)
        #expect(s.dones.isEmpty && s.signals.isEmpty)
        // The agent at work: its tool calls reach only the notes.
        s.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: "UA1", agent: "a1"))
        s.hook(S.claude("PostToolUse", tool: "Read", input: S.read, toolUseID: "UA1", agent: "a1"))
        s.at(600)
        #expect(word(s) == .subagents(1) && s.phase() == .completed && s.signals.isEmpty)
    }

    /// The agent finishes: the row still waits for the main agent to take its result, which wakes it (running, blue), and
    /// that turn's Stop, with nothing left in flight, is the one Done.
    @Test
    func itsResultWakesTheMainAgentAndThatTurnsStopIsTheOneDone() throws {
        let s = S()
        s.begin()
        spawn(s, "a1")
        stop(s, background: ["a1"])
        s.at(60)
        finish(s, "a1")
        #expect(word(s) == .subagents(1) && s.dones.isEmpty)
        s.at(60.4)
        wake(s, "a1")
        #expect(s.phase() == .running && !delegating(s))
        s.at(70)
        stop(s)
        #expect(word(s) == .done)
        s.at(72)
        #expect(s.dones == [.done(sessionID: "s1")])
        s.at(200)
        #expect(s.dones.count == 1)
    }

    /// A wake-up that fires no prompt hook (the main agent's first tool, then its Stop, well within the grace): its Stop
    /// is still the one Done, as the first Stop's Done was never spent.
    @Test
    func aWakeUpWithNoPromptHookStillGivesTheOneDone() {
        let s = S()
        s.begin()
        spawn(s, "a1")
        stop(s, background: ["a1"])
        s.at(60)
        finish(s, "a1")
        s.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: "UM1"))
        s.bridge(F.running("s1", summary: "Running Read", at: s.clock.current))
        #expect(s.phase() == .running && !delegating(s))
        s.at(63)
        stop(s)
        #expect(word(s) == .done)
        s.at(65)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    /// Two background agents: each result wakes the main agent; only the Stop that leaves nothing running is Done.
    @Test
    func twoAgentsGiveOneDoneAtTheLastStop() throws {
        let s = S()
        s.begin()
        spawn(s, "a1")
        spawn(s, "a2", type: "Explore")
        stop(s, background: ["a1", "a2"])
        #expect(word(s) == .subagents(2))
        s.at(30)
        finish(s, "a1")
        wake(s, "a1")
        #expect(s.phase() == .running)
        s.at(40)
        stop(s, background: ["a2"])
        #expect(word(s) == .subagents(1))
        s.at(90)
        #expect(s.dones.isEmpty)
        finish(s, "a2", type: "Explore")
        wake(s, "a2")
        s.at(100)
        stop(s)
        s.at(102)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    /// A SubagentStop that never came (a hook that failed, a Claude that sends no `background_tasks`): the agent stops
    /// counting 30 minutes after its last note, with no Done, and nothing ticks for it but that one check.
    @Test
    func aMissedSubagentStopLapsesAfterThirtyQuietMinutes() throws {
        let s = S()
        s.begin()
        spawn(s, "a1")
        stop(s, background: nil)
        #expect(word(s) == .subagents(1))
        s.at(10 * 60)
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "UA2", agent: "a1"))
        s.at(10 * 60 + ClaudeSubagentBook.quietLimit - 5)
        #expect(word(s) == .subagents(1))
        s.at(10 * 60 + ClaudeSubagentBook.quietLimit + 2)
        #expect(word(s) == .done && s.engine.runningCount == 0)
        #expect(s.dones.isEmpty && s.scheduled.current.isEmpty)
    }

    /// A finished agent whose result wakes nothing (no wake-up within the grace): the row reads done, silently.
    @Test
    func aResultThatWakesNothingEndsTheWaitSilently() throws {
        let s = S()
        s.begin()
        spawn(s, "a1")
        stop(s, background: ["a1"])
        s.at(30)
        finish(s, "a1")
        s.at(30 + ClaudeSubagentBook.wakeGrace - 1)
        #expect(word(s) == .subagents(1))
        s.at(30 + ClaudeSubagentBook.wakeGrace + 2)
        #expect(word(s) == .done && s.dones.isEmpty)
    }

    /// The session ends mid-wait (the owner quits Claude): nothing waits and nothing is Done.
    @Test
    func aSessionEndMidWaitEndsTheWait() throws {
        let s = S()
        s.begin()
        spawn(s, "a1")
        stop(s, background: ["a1"])
        s.at(20)
        s.hook(S.claude("SessionEnd", extra: ["reason": "prompt_input_exit"]))
        s.bridge(F.sessionEnd("s1", at: s.clock.current))
        let ended = try #require(s.engine.state.session(id: "s1"))
        #expect(ended.isSessionEnded && s.engine.waitingSubagents(for: ended) == 0 && s.engine.claudeSubagentCounts.isEmpty)
        s.at(60)
        #expect(s.dones.isEmpty)
    }

    /// The agent's process gone (Claude crashed, no SessionEnd): the monitor's next pass ends the wait, its subagents
    /// gone with it, with no Done.
    @Test
    func aGoneProcessEndsTheWait() throws {
        let s = S()
        s.begin()
        spawn(s, "a1")
        stop(s, background: ["a1"])
        s.at(30)
        s.livenessPass()
        #expect(word(s) == .subagents(1))
        s.gone.update { $0.insert(900) }
        s.livenessPass()
        #expect(word(s) == .done && s.engine.claudeSubagentCounts.isEmpty)
        s.at(60)
        #expect(s.dones.isEmpty)
    }

    // MARK: The wake-up's one Done, however it comes (P375, P376)

    /// Probe A: the wake-up fires no prompt hook and uses no tool, so the bridge never shows the main agent at work; its
    /// own Stop, with nothing left in flight, is still the one Done.
    @Test
    func aWakeUpWithNoPromptAndNoToolStillGivesTheOneDone() {
        let s = S()
        s.begin()
        spawn(s, "a1")
        stop(s, background: ["a1"])
        #expect(word(s) == .subagents(1))
        s.at(60)
        finish(s, "a1")
        s.at(64)
        stop(s)
        #expect(word(s) == .done)
        s.at(66)
        #expect(s.dones == [.done(sessionID: "s1")])
        s.at(200)
        #expect(s.dones.count == 1)
    }

    /// As probe A, with the result's turn taking longer than the wake grace: the row reads done silently in between, and
    /// the wake-up's Stop is still the one Done.
    @Test
    func aLongWakeUpWithNoPromptAndNoToolStillGivesTheOneDone() {
        let s = S()
        s.begin()
        spawn(s, "a1")
        stop(s, background: ["a1"])
        s.at(60)
        finish(s, "a1")
        s.at(60 + ClaudeSubagentBook.wakeGrace + 30)
        #expect(word(s) == .done && s.dones.isEmpty)
        stop(s)
        s.at(60 + ClaudeSubagentBook.wakeGrace + 32)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    /// A Stop hook that blocks and lets the main agent go on, with nothing waited on: its second Stop is no second Done.
    @Test
    func aSecondStopWithNothingWaitedOnIsNoSecondDone() {
        let s = S()
        s.begin()
        s.at(5)
        stop(s)
        s.at(7)
        #expect(s.dones.count == 1)
        stop(s)
        s.at(20)
        #expect(s.dones.count == 1)
    }

    /// Probe B: the SubagentStart lands after the bridge's Stop, while that turn's Done is held. The Done is dropped, not
    /// spent, so the Stop of the turn the agent's result wakes (here with a tool and no prompt hook) is the one Done.
    @Test
    func aSubagentStartThatLandsAfterTheStopKeepsTheDoneForTheWakeUp() {
        let s = S()
        s.begin()
        s.at(1)
        stop(s, background: ["a1"])
        s.at(2.2)
        spawn(s, "a1")
        #expect(word(s) == .subagents(1))
        s.at(10)
        #expect(s.dones.isEmpty)
        s.at(60)
        finish(s, "a1")
        s.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: "UM1"))
        s.bridge(F.running("s1", summary: "Running Read", at: s.clock.current))
        s.at(63)
        stop(s)
        s.at(65)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    /// Probe C: a short agent's SubagentStop lands after the main agent's Stop note and before the bridge's Stop. The
    /// main turn had ended, so the agent's result still wakes it: no Done at the first Stop, one at the wake-up's.
    @Test
    func aSubagentStopBetweenTheStopNoteAndTheBridgesStopStillWaits() {
        let s = S()
        s.begin()
        spawn(s, "a1")
        s.at(10)
        s.hook(S.claude("Stop", extra: ["stop_hook_active": false, "last_assistant_message": "Started the agent.",
                                        "background_tasks": [["id": "a1", "type": "subagent", "status": "running", "description": "Map"]]]))
        s.hook(S.claude("SubagentStop", agent: "a1", agentType: "worker"))
        s.bridge(.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "Started the agent.", timestamp: s.clock.current)))
        #expect(word(s) == .subagents(1))
        s.at(12)
        #expect(s.dones.isEmpty)
        wake(s, "a1")
        s.at(20)
        stop(s)
        s.at(22)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    // MARK: A foreground agent (P377)

    /// The bridge's word that the main agent calls a tool (its metadata, then its activity).
    private func tool(_ s: S, _ name: String?, summary: String? = nil) {
        s.bridge(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: "s1", claudeMetadata: ClaudeSessionMetadata(
            transcriptPath: S.transcript("s1"), currentTool: name), timestamp: s.clock.current)),
                 F.running("s1", summary: summary ?? "Running \(name ?? "")", at: s.clock.current))
    }

    /// Probe D: the main agent blocked on its Agent calls while their subagents run is delegating, as a Codex chat that
    /// waits on its own; its own tool, or the calls' return, is work again. Its turn's Done comes as always.
    @Test
    func aMainAgentBlockedOnItsAgentCallsIsDelegating() {
        let s = S()
        s.begin()
        s.hook(S.claude("PreToolUse", tool: "Agent", input: ["description": "Map the parser"], toolUseID: "UA"))
        s.hook(S.claude("PreToolUse", tool: "Agent", input: ["description": "Map the lexer"], toolUseID: "UB"))
        tool(s, "Agent")
        #expect(word(s) == .tool(name: "Agent", detail: nil))
        spawn(s, "a1")
        spawn(s, "a2", type: "Explore")
        #expect(s.engine.claudeSubagentCounts == ["s1": 2])
        #expect(word(s) == .subagents(2) && delegating(s) && s.phase() == .running)
        s.at(120)
        // The first call returns: the main agent still waits on the second.
        finish(s, "a1")
        s.hook(S.claude("PostToolUse", tool: "Agent", input: ["description": "Map the parser"], toolUseID: "UA"))
        tool(s, nil, summary: "Finished Agent")
        #expect(word(s) == .subagents(1))
        s.at(180)
        finish(s, "a2", type: "Explore")
        s.hook(S.claude("PostToolUse", tool: "Agent", input: ["description": "Map the lexer"], toolUseID: "UB"))
        tool(s, nil, summary: "Finished Agent")
        #expect(!delegating(s))
        s.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: "UR"))
        tool(s, "Read")
        #expect(word(s) == .tool(name: "Read", detail: nil))
        s.at(190)
        stop(s)
        s.at(192)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    /// A background agent while the main agent works on: its own tools and its thinking are work, not waiting.
    @Test
    func aMainAgentAtWorkBesideABackgroundAgentIsWorking() {
        let s = S()
        s.begin()
        s.hook(S.claude("PreToolUse", tool: "Agent", input: ["description": "Map the parser", "run_in_background": true], toolUseID: "UA"))
        tool(s, "Agent")
        spawn(s, "a1")
        // A background call returns at once.
        s.hook(S.claude("PostToolUse", tool: "Agent", input: ["description": "Map the parser", "run_in_background": true], toolUseID: "UA"))
        tool(s, nil, summary: "Thinking.")
        #expect(!delegating(s) && word(s) == .thinking)
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "UB"))
        tool(s, "Bash")
        #expect(!delegating(s))
    }

    // MARK: What stays as it was

    /// A foreground agent (the main agent waits on its call, the usual Agent tool) finishes before the Stop: the turn's
    /// Done comes as always, whether or not Claude names its background work.
    @Test(arguments: [true, false])
    func aForegroundAgentsTurnStillGivesItsDone(_ namesBackground: Bool) throws {
        let s = S()
        s.begin()
        spawn(s, "a1")
        s.at(20)
        finish(s, "a1")
        stop(s, background: namesBackground ? [] : nil)
        #expect(word(s) == .done)
        s.at(22)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    /// A SubagentStop lost on the way, then a Stop whose `background_tasks` is empty: Claude says nothing is in flight, so
    /// nothing waits and the Done comes.
    @Test
    func aStopThatNamesNoBackgroundWorkEndsAMissedSubagentStop() throws {
        let s = S()
        s.begin()
        spawn(s, "a1")
        s.at(20)
        stop(s, background: [])
        #expect(word(s) == .done)
        s.at(22)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    /// A subagent a background agent (or a workflow) starts while the main turn has ended: upstream's bridge would apply
    /// its SubagentStart as the parent's running activity. It never wakes the row. With the helper before P510 the book
    /// counts it (one more agent); with Claude's own word the main agent waits on the agent its Stop named, whose
    /// subagent it is (a foreground one of that agent's is in no `background_tasks`).
    @Test(arguments: [true, false])
    func aSubagentStartedWhileTheMainTurnWaitsNeverWakesIt(_ countsKinds: Bool) throws {
        let s = S()
        s.begin()
        spawn(s, "a1")
        s.hook(S.claude("Stop", extra: ["stop_hook_active": false, "last_assistant_message": "Started the agent.",
                                        "background_tasks": [["id": "a1", "type": "subagent", "status": "running", "description": "Map"]]]),
               countsKinds: countsKinds)
        s.bridge(.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "Started the agent.", timestamp: s.clock.current)))
        s.at(30)
        spawn(s, "a2", type: "Explore")
        #expect(s.phase() == .completed && word(s) == .subagents(countsKinds ? 1 : 2))
        #expect(s.engine.state.session(id: "s1")?.summary == "Started the agent.")
        s.at(40)
        #expect(s.signals.isEmpty)
    }

    /// A late note of a subagent that already stopped never brings it back.
    @Test
    func aLateNoteOfAStoppedAgentAddsNothing() throws {
        let s = S()
        s.begin()
        spawn(s, "a1")
        s.at(5)
        finish(s, "a1")
        s.hook(S.claude("PostToolUse", tool: "Read", input: S.read, toolUseID: "UA1", agent: "a1"))
        stop(s)
        #expect(word(s) == .done)
        s.at(7)
        #expect(s.dones.count == 1)
    }

    /// A subagent's approval while the main turn waits on it: the request still surfaces (released, read-only, confirmed
    /// by Claude's own notice) with its sound, and once it closes the row waits on the agent again. No Done either way.
    @Test
    func aSubagentsApprovalWhileTheMainTurnWaitsStillAsks() throws {
        let s = S()
        s.begin()
        spawn(s, "a1")
        stop(s, background: ["a1"])
        s.at(30)
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "UW", agent: "a1"))
        let id = try #require(s.hook(S.claude("PermissionRequest", tool: "Bash", input: S.push, agent: "a1")))
        #expect(s.request(id)?.channel == .open && s.broker.held.current.isEmpty)
        s.at(36)
        s.hook(S.notification("permission_prompt", agent: "a1"))
        #expect(s.head()?.id == id && s.glyph() == "!" && s.needsYou.count == 1)
        #expect(needsAttention(s) && !delegating(s))
        s.hook(S.claude("PostToolUse", tool: "Bash", input: S.push, toolUseID: "UW", agent: "a1"))
        #expect(s.head() == nil && s.phase() == .completed && word(s) == .subagents(1))
        s.at(60)
        #expect(s.dones.isEmpty)
    }

    /// Codex's chats keep their own count (P212): a Codex hook's note with an agent id adds nothing here.
    @Test
    func aCodexNoteNeverCountsAClaudeSubagent() {
        let s = S()
        s.begin("c1", tool: .codex)
        s.hook(S.codex("SessionStart", agent: "x1"), source: "codex")
        s.hook(["hook_event_name": "SubagentStart", "session_id": "c1", "agent_id": "x2"], source: "codex")
        #expect(s.engine.claudeSubagentCounts.isEmpty)
    }
}

/// The book alone (P370): who counts, and when each stops.
struct ClaudeSubagentBookTests {
    let now = EngineFixtures.now

    @Test
    func startSeenStopAndLapse() {
        var book = ClaudeSubagentBook()
        book.seen("ghost", in: "s", at: now)
        #expect(book.count(in: "s", now: now) == 0)
        book.start("a", in: "s", at: now)
        book.start("b", in: "s", at: now)
        #expect(book.count(in: "s", now: now) == 2)
        book.stop("a", in: "s", at: now, mainTurnEnded: false)
        #expect(book.count(in: "s", now: now) == 1)
        book.seen("a", in: "s", at: now + 1)
        #expect(book.count(in: "s", now: now + 1) == 1)
        book.stop("b", in: "s", at: now + 5, mainTurnEnded: true)
        #expect(book.count(in: "s", now: now + 5) == 1)
        #expect(book.nextLapse(after: now + 5) == now + 5 + ClaudeSubagentBook.wakeGrace)
        book.mainTurnStarted("s")
        #expect(book.count(in: "s", now: now + 6) == 0 && book.nextLapse(after: now + 6) == nil)
    }

    @Test
    func aQuietAgentLapsesAndIsPruned() {
        var book = ClaudeSubagentBook()
        book.start("a", in: "s", at: now)
        book.seen("a", in: "s", at: now + 100)
        let lapse = now + 100 + ClaudeSubagentBook.quietLimit
        #expect(book.nextLapse(after: now) == lapse)
        #expect(book.count(in: "s", now: lapse - 1) == 1 && book.count(in: "s", now: lapse) == 0)
        book.prune(now: lapse)
        #expect(book.agents.isEmpty)
    }

    @Test
    func aSessionIsForgottenWhole() {
        var book = ClaudeSubagentBook()
        book.start("a", in: "s", at: now)
        book.start("b", in: "t", at: now)
        book.clear("t")
        #expect(book.sessionIDs == ["s"])
        book.forget("s")
        #expect(book.sessionIDs.isEmpty && book.nextLapse(after: now) == nil)
    }
}
