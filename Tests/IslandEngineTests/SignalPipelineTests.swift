import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Feeds events through upstream's reducer and the pipeline, the way SessionEngine does, on a clock the test moves.
private struct Harness {
    var state = SessionState()
    var pipeline = SignalPipeline()
    var now = EngineFixtures.now
    var resolving = false
    var signals: [EngineSignal] = []

    mutating func feed(_ id: String, _ event: AgentEvent, _ ingress: TrackedEventIngress = .bridge) {
        let before = state.session(id: id)
        let event = SignalPipeline.normalized(event, ingress: ingress, current: before)
        state.apply(event)
        signals += pipeline.process(event, sessionID: id, ingress: ingress, before: before, after: state.session(id: id),
                                    now: now, resolvingInitialSessions: resolving).map(\.signal)
    }

    mutating func feed(_ id: String, _ events: [AgentEvent], _ ingress: TrackedEventIngress = .bridge) {
        for event in events { feed(id, event, ingress) }
    }

    mutating func wait(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let current = state
        signals += pipeline.due(now: now) { current.session(id: $0) }.map(\.signal)
    }
}

struct SignalPipelineTests {
    private typealias F = EngineFixtures

    /// P4: one table for every event kind, with PermissionDenied told apart from Stop by the fixed summary upstream's
    /// bridge gives it. A StopFailure is the same completion as a Stop, and a Stop whatever its text. An approval or a
    /// question signals nothing here: the engine's request book sounds it once it is confirmed (C1, P162).
    @Test
    func theTableSignalsDoneOnly() throws {
        var h = Harness()
        h.feed("s1", F.started("s1"))
        h.feed("s1", F.prompt("s1"))
        h.feed("s1", F.running("s1"))
        h.feed("s1", F.running("s1", summary: "Bash hit a tool error."))
        h.feed("s1", F.running("s1", summary: "Started Explore subagent."))
        h.feed("s1", F.compacting("s1"))
        h.feed("s1", F.permissionDenied("s1"))
        h.feed("s1", F.permission("s1"))
        h.feed("s1", F.running("s1", summary: "Bash finished."))
        h.feed("s1", F.question("s1"))
        h.feed("s1", F.running("s1", summary: "Answered: main"))
        h.feed("s1", F.completed("s1"))
        h.feed("s1", .activityUpdated(SessionActivityUpdated(sessionID: "s1", summary: "Claude is waiting for your input",
                                                             phase: .completed, timestamp: h.now)))
        h.wait(1.5)
        h.feed("s1", F.prompt("s1", "again"))
        h.feed("s1", F.completed("s1", interrupted: true))
        h.feed("s1", F.sessionEnd("s1"))
        h.wait(2)
        h.feed("sub", F.started("sub", transcript: "/tmp/project/abc/subagents/agent-1.jsonl"))
        h.feed("sub", F.permission("sub", toolUseID: "toolu_9"))
        h.feed("sub", F.completed("sub"))
        h.wait(2)
        #expect(h.signals == [.done(sessionID: "s1")])

        // The hook as Claude Code sends it: PermissionDenied has `reason`, which upstream's payload does not read, so
        // its `error` is nil and the bridge's summary is the fixed text.
        let deniedHook = try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(#"""
        {"hook_event_name":"PermissionDenied","session_id":"d1","cwd":"/tmp/project","tool_name":"Bash","tool_input":{},
         "tool_use_id":"toolu_1","reason":"Auto mode denied this command."}
        """#.utf8))
        #expect(deniedHook.error == nil)
        #expect(deniedHook.toolName == "Bash")

        // Only a Claude-style hook completion from the bridge can be a PermissionDenied. Every other completion is a
        // Stop, whatever its text: one that reads like an API error value is still a Stop (M5 names a StopFailure).
        let denied = SessionCompleted(sessionID: "x", summary: "Claude Code permission was denied.", timestamp: F.now)
        let codexDenied = SessionCompleted(sessionID: "x", summary: "Codex permission was denied.", timestamp: F.now)
        #expect(SignalPipeline.completion(denied, tool: .claudeCode, ingress: .bridge) == .permissionDenied)
        #expect(SignalPipeline.completion(denied, tool: .claudeCode, ingress: .rollout) == .stop)
        #expect(SignalPipeline.completion(codexDenied, tool: .codex, ingress: .bridge) == .stop)
        for text in ["rate_limit", "overloaded", "Done."] {
            let stop = SessionCompleted(sessionID: "x", summary: text, timestamp: F.now)
            #expect(SignalPipeline.completion(stop, tool: .claudeCode, ingress: .bridge) == .stop)
        }
    }

    /// P2: Done waits 1.5 s, and the agent working on cancels it. A PermissionDenied is activity, never a Done.
    @Test
    func doneIsHeldAndWorkInTheHoldCancelsIt() throws {
        var alone = Harness()
        alone.feed("s1", F.started("s1"))
        alone.feed("s1", F.prompt("s1"))
        alone.feed("s1", F.completed("s1"))
        alone.wait(1.4)
        #expect(alone.signals.isEmpty)
        alone.wait(0.1)
        #expect(alone.signals == [.done(sessionID: "s1")])

        var denied = Harness()
        denied.feed("s1", F.started("s1"))
        denied.feed("s1", F.prompt("s1"))
        denied.feed("s1", F.permissionDenied("s1", tool: "Bash"))
        denied.wait(5)
        #expect(denied.signals.isEmpty)
        let session = try #require(denied.state.session(id: "s1"))
        #expect(session.phase == .running)
        #expect(StatusWord.of(session, interrupted: false) == .denied(tool: "Bash"))

        // PreToolUse, UserPromptSubmit or SubagentStart after a Stop.
        for next in [F.running("s1"), F.prompt("s1", "more"), F.running("s1", summary: "Started Plan subagent.")] {
            var h = Harness()
            h.feed("s1", F.started("s1"))
            h.feed("s1", F.prompt("s1"))
            h.feed("s1", F.completed("s1"))
            h.wait(0.5)
            h.feed("s1", next)
            h.wait(5)
            #expect(h.signals.isEmpty)
            #expect(h.state.session(id: "s1")?.phase == .running)
        }
    }

    /// P5: each alert has a key and goes out once; a confirmed request's key is its own id, so a replay of it never
    /// sounds again (P162), and its key is forgotten with its session.
    @Test
    func eachAlertIsKeyedAndSentOnce() {
        var h = Harness()
        h.feed("s1", F.started("s1"))
        h.feed("s1", F.prompt("s1"))
        h.feed("s1", F.completed("s1"))
        h.feed("s1", F.completed("s1"))
        h.wait(2)
        h.feed("s1", F.prompt("s1", "turn 2"))
        h.signals += [h.pipeline.needsYou(sessionID: "s1", requestID: "r7"), h.pipeline.needsYou(sessionID: "s1", requestID: "r7"),
                      h.pipeline.needsYou(sessionID: "s1", requestID: "r8")].compactMap { $0?.signal }
        h.feed("s1", F.running("s1", summary: "Bash finished."))
        h.feed("s1", F.completed("s1"))
        h.wait(2)
        #expect(h.signals == [.done(sessionID: "s1"), .needsYou(sessionID: "s1"), .needsYou(sessionID: "s1"), .done(sessionID: "s1")])
        #expect(h.pipeline.turn(for: "s1") == 2)
        #expect(SignalPipeline.requestID(fromKey: SignalPipeline.requestKey(sessionID: "s1", requestID: "bridge:s1:X")) == "bridge:s1:X")
        h.pipeline.forget("s1")
        #expect(h.pipeline.needsYou(sessionID: "s1", requestID: "r7") != nil)
    }

    /// P6: restored and discovered state is quiet until the first live event, and rollouts wait for the first scan.
    @Test
    func nothingSignalsBeforeTheFirstLiveEvent() {
        var h = Harness()
        h.feed("restored", F.started("restored", tool: .codex), .rollout)
        h.feed("restored", F.completed("restored"), .rollout)
        h.wait(2)
        h.resolving = true
        h.feed("live", F.started("live"))
        h.feed("codex-app", F.started("codex-app", tool: .codex), .rollout)
        h.feed("codex-app", F.completed("codex-app"), .rollout)
        h.wait(2)
        #expect(h.signals.isEmpty)

        h.resolving = false
        h.feed("codex-app", F.rolloutPrompt("codex-app", "next"), .rollout)
        h.feed("codex-app", F.running("codex-app"), .rollout)
        h.feed("codex-app", F.completed("codex-app"), .rollout)
        h.wait(2)
        #expect(h.signals == [.done(sessionID: "codex-app")])
    }

    /// P5: a rollout's late completion never sounds for a session whose Stop hook already reports.
    @Test
    func aRolloutCompletionNeverSignalsForAHookedSession() {
        var h = Harness()
        h.feed("s1", F.started("s1", tool: .codex))
        h.feed("s1", F.prompt("s1"))
        h.feed("s1", F.completed("s1"))
        h.wait(2)
        h.feed("s1", F.prompt("s1", "turn 2"))
        h.feed("s1", F.completed("s1"), .rollout)
        h.wait(2)
        #expect(h.signals == [.done(sessionID: "s1")])
    }

    /// P5: an alert goes out only under the key the session shows now: the same request, question or turn.
    @Test
    func anAlertGoesOutOnlyUnderTheKeyTheSessionShowsNow() {
        var h = Harness()
        h.feed("s1", F.started("s1"))
        h.feed("s1", F.prompt("s1"))
        h.feed("s1", F.permission("s1", toolUseID: "toolu_A"))
        let first = SignalPipeline.currentKey(.needsYou, session: h.state.session(id: "s1"), turn: 1)
        #expect(first == "s1|approval|toolu_A")
        h.feed("s1", F.permission("s1", toolUseID: "toolu_B"))
        #expect(SignalPipeline.currentKey(.needsYou, session: h.state.session(id: "s1"), turn: 1) == "s1|approval|toolu_B")
        h.feed("s1", F.question("s1"))
        #expect(SignalPipeline.currentKey(.needsYou, session: h.state.session(id: "s1"), turn: 1)?.hasPrefix("s1|question|") == true)
        #expect(SignalPipeline.currentKey(.done, session: h.state.session(id: "s1"), turn: 1) == nil)
        h.feed("s1", F.completed("s1"))
        #expect(SignalPipeline.currentKey(.done, session: h.state.session(id: "s1"), turn: 1) == "s1|done|1")
        #expect(SignalPipeline.currentKey(.needsYou, session: h.state.session(id: "s1"), turn: 1) == nil)
        h.feed("s1", F.prompt("s1", "turn 2"))
        h.feed("s1", F.completed("s1"))
        #expect(SignalPipeline.currentKey(.done, session: h.state.session(id: "s1"), turn: h.pipeline.turn(for: "s1")) == "s1|done|2")
        h.feed("s1", F.sessionEnd("s1"))
        #expect(SignalPipeline.currentKey(.done, session: h.state.session(id: "s1"), turn: 2) == nil)
    }

    /// P5: the state is checked again when a held Done falls due.
    @Test
    func aHeldDoneIsCheckedAgainWhenItFallsDue() {
        var ended = Harness()
        ended.feed("s1", F.started("s1"))
        ended.feed("s1", F.completed("s1"))
        ended.feed("s1", F.sessionEnd("s1"))
        ended.wait(2)
        var dismissed = Harness()
        dismissed.feed("s1", F.started("s1"))
        dismissed.feed("s1", F.completed("s1"))
        dismissed.state.dismissSession(id: "s1")
        dismissed.wait(2)
        #expect(ended.signals.isEmpty)
        #expect(dismissed.signals.isEmpty)
    }
}
