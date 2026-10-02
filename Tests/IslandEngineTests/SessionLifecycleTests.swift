import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Upstream's reducer and liveness rules with the lifecycle around them, the way SessionEngine runs them.
private struct Harness {
    var state = SessionState()
    var lifecycle = SessionLifecycle()
    var now = EngineFixtures.now

    @discardableResult
    mutating func feed(_ id: String, _ event: AgentEvent, _ ingress: TrackedEventIngress = .bridge) -> SessionLifecycle.Gate {
        let before = state.session(id: id)
        let gate = lifecycle.gate(event, sessionID: id, ingress: ingress, current: before, now: now)
        switch gate {
        case .drop:
            return gate
        case .apply:
            state.apply(event)
        case let .merge(session):
            state = SessionState(sessions: state.sessions.filter { $0.id != id } + [session])
        case let .revive(prefix):
            for start in prefix { state.apply(start) }
            if var session = state.session(id: id), session.isSessionEnded {
                session.isSessionEnded = false
                state = SessionState(sessions: state.sessions.filter { $0.id != id } + [session])
            }
            state.apply(event)
        }
        lifecycle.noteApplied(event, sessionID: id, ingress: ingress, before: before, now: now)
        return gate
    }

    /// One pass of upstream's process monitor that finds only `alive`, then the review.
    mutating func poll(alive: Set<String> = []) {
        var local = state
        local.markProcessLiveness(aliveSessionIDs: alive)
        local.removeInvisibleSessions()
        state = lifecycle.review(old: state, new: local, now: now) { _ in true }
    }

    mutating func wait(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

struct SessionLifecycleTests {
    private typealias F = EngineFixtures

    @Test
    func pollingNeverEndsASessionThatWaitsOnYou() {
        var h = Harness()
        h.feed("s1", F.started("s1"))
        h.feed("s1", F.permission("s1"))
        h.wait(3_600)
        for _ in 0..<5 { h.poll() }
        #expect(h.state.session(id: "s1")?.phase == .waitingForApproval)
        #expect(h.lifecycle.tombstones.isEmpty)
    }

    @Test
    func pollingSparesASessionWithAHookEventInTheLastTenMinutes() {
        var h = Harness()
        h.feed("s1", F.started("s1"))
        h.feed("s1", F.prompt("s1"))
        for _ in 0..<5 {
            h.wait(60)
            h.poll()
        }
        #expect(h.state.session(id: "s1")?.phase == .running)
        h.wait(6 * 60)
        h.poll()
        #expect(h.state.session(id: "s1") != nil)
        h.poll()
        #expect(h.state.session(id: "s1") == nil)
        #expect(h.lifecycle.tombstones["s1"] != nil)
    }

    /// Upstream alone ends an idle session on its 2nd missed poll; with the review it takes a 3rd.
    @Test
    func anIdleSessionEndsOnTheThirdMissNotTheSecond() {
        var upstream = SessionState()
        upstream.apply(F.started("s1"))
        var polls = 0
        while upstream.session(id: "s1") != nil {
            upstream.markProcessLiveness(aliveSessionIDs: [])
            upstream.removeInvisibleSessions()
            polls += 1
        }
        #expect(polls == 2)

        var h = Harness()
        h.feed("s1", F.started("s1"))
        h.wait(11 * 60)
        h.poll()
        h.poll()
        #expect(h.state.session(id: "s1") != nil)
        h.poll()
        #expect(h.state.session(id: "s1") == nil)
    }

    @Test
    func aFoundProcessStartsTheCountAgain() {
        var h = Harness()
        h.feed("s1", F.started("s1"))
        h.wait(11 * 60)
        h.poll()
        h.poll()
        h.poll(alive: ["s1"])
        h.poll()
        h.poll()
        #expect(h.state.session(id: "s1") != nil)
        h.poll()
        #expect(h.state.session(id: "s1") == nil)
    }

    /// P5: [SessionEnd, late Stop] brings no row back; after 10 minutes the id is free again.
    @Test
    func lateEventsForAnEndedSessionAreDroppedForTenMinutes() {
        var h = Harness()
        h.feed("s1", F.started("s1"))
        h.feed("s1", F.prompt("s1"))
        h.feed("s1", F.sessionEnd("s1"))
        #expect(h.feed("s1", F.started("s1", source: nil, phase: .completed)) == .drop)
        #expect(h.feed("s1", F.completed("s1")) == .drop)
        #expect(h.feed("s1", F.running("s1")) == .drop)
        #expect(h.feed("s1", F.started("s1", tool: .claudeCode, source: .startup), .rollout) == .drop)
        #expect(h.state.session(id: "s1")?.isSessionEnded == true)
        #expect(h.state.session(id: "s1")?.isVisibleInIsland == false)

        h.wait(599)
        #expect(h.lifecycle.expire(now: h.now).isEmpty)
        h.wait(1)
        #expect(h.lifecycle.expire(now: h.now) == ["s1"])
        #expect(h.feed("s1", F.completed("s1")) == .apply)
    }

    /// Only a real SessionStart (resume) or a new prompt reopens an ended session.
    @Test
    func onlyARealSessionStartOrANewPromptRevives() {
        var resumed = Harness()
        resumed.feed("s1", F.started("s1"))
        resumed.feed("s1", F.sessionEnd("s1"))
        #expect(resumed.feed("s1", F.started("s1", source: .resume)) == .apply)
        #expect(resumed.state.session(id: "s1")?.isSessionEnded == false)

        var prompted = Harness()
        prompted.feed("s1", F.started("s1"))
        prompted.feed("s1", F.sessionEnd("s1"))
        prompted.poll()
        #expect(prompted.state.session(id: "s1") == nil)
        let lateStart = F.started("s1", source: nil, phase: .completed)
        #expect(prompted.feed("s1", lateStart) == .drop)
        #expect(prompted.feed("s1", F.prompt("s1", "back again")) == .revive(prefix: [lateStart]))
        #expect(prompted.state.session(id: "s1")?.phase == .running)
        #expect(prompted.state.session(id: "s1")?.isVisibleInIsland == true)
    }

    /// P3: compaction or resume of a live session keeps what the row shows.
    @Test
    func sessionStartForALiveSessionKeepsPhaseTitleAndChildren() throws {
        var h = Harness()
        h.feed("s1", F.started("s1", transcript: "/Users/test/.claude-work/projects/-p/s1.jsonl", title: "Fix the tests"))
        h.feed("s1", F.prompt("s1"))
        let child = ClaudeSubagentInfo(agentID: "a1", agentType: "Explore", startedAt: h.now)
        h.feed("s1", .claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: "s1", claudeMetadata: ClaudeSessionMetadata(
            transcriptPath: "/Users/test/.claude-work/projects/-p/s1.jsonl", lastUserPrompt: "fix the tests",
            activeSubagents: [child], activeTasks: [ClaudeTaskInfo(id: "t1", title: "Run the suite")]), timestamp: h.now)))
        h.feed("s1", F.compacting("s1"))

        var start = SessionStarted(sessionID: "s1", title: "Claude · project", tool: .claudeCode, origin: .live,
                                   initialPhase: .completed, summary: "Compacted Claude Code context in project.", timestamp: h.now,
                                   claudeMetadata: ClaudeSessionMetadata(transcriptPath: "/Users/test/.claude-work/projects/-p/s2.jsonl",
                                                                         model: "claude-opus", startupSource: .compact))
        start.timestamp = h.now.addingTimeInterval(5)
        let gate = h.feed("s1", .sessionStarted(start))
        guard case .merge = gate else { Issue.record("expected a merge, got \(gate)"); return }
        let session = try #require(h.state.session(id: "s1"))
        #expect(session.phase == .running)
        #expect(session.title == "Fix the tests")
        #expect(session.summary == "Claude Code is compacting the conversation.")
        #expect(StatusWord.of(session, interrupted: false) == .compacting)
        #expect(session.claudeMetadata?.activeSubagents == [child])
        #expect(session.claudeMetadata?.activeTasks.map(\.id) == ["t1"])
        #expect(session.claudeMetadata?.transcriptPath == "/Users/test/.claude-work/projects/-p/s2.jsonl")
        #expect(session.claudeMetadata?.model == "claude-opus")
        #expect(session.claudeMetadata?.lastUserPrompt == "fix the tests")
    }

    /// Upstream's guard, kept where the race is: a rollout's stale read cannot reopen a turn the bridge's Stop
    /// finished. A rollout-only session's next turn reopens it, even when its prompt repeats the last one.
    @Test
    func aRolloutCannotReopenATurnTheBridgeFinished() {
        var h = Harness()
        h.feed("c1", F.started("c1", tool: .codex))
        h.feed("c1", F.prompt("c1", "run the tests"))
        h.feed("c1", F.completed("c1"))
        #expect(h.feed("c1", F.running("c1"), .rollout) == .drop)
        #expect(h.state.session(id: "c1")?.phase == .completed)
        h.feed("c1", F.prompt("c1", "run the tests"))
        #expect(h.feed("c1", F.running("c1"), .rollout) == .apply)
        #expect(h.state.session(id: "c1")?.phase == .running)

        var rollout = Harness()
        rollout.feed("r1", F.started("r1", tool: .codex), .rollout)
        for event in F.rolloutPrompt("r1", "run the tests") { rollout.feed("r1", event, .rollout) }
        rollout.feed("r1", F.completed("r1"), .rollout)
        for event in F.rolloutPrompt("r1", "run the tests") { #expect(rollout.feed("r1", event, .rollout) == .apply) }
        #expect(rollout.state.session(id: "r1")?.phase == .running)
    }

    /// A session first found in a transcript (not hook-managed), then started live (resume), follows its hooks from
    /// then on: the merge takes the flags upstream's reducer gives the live start, and keeps the row.
    @Test
    func aLiveStartOfAFoundSessionTakesUpstreamsHookFlags() throws {
        var h = Harness()
        let found = AgentSession(id: "s1", title: "Fix the tests", tool: .claudeCode, phase: .running, summary: "Working.",
                                 updatedAt: h.now, claudeMetadata: ClaudeSessionMetadata(lastUserPrompt: "fix the tests"))
        h.state = SessionState(sessions: [found])
        #expect(h.state.session(id: "s1")?.isHookManaged == false)
        let start = SessionStarted(sessionID: "s1", title: "Claude · project", tool: .claudeCode, origin: .live,
                                   initialPhase: .completed, summary: "Resumed.", timestamp: h.now,
                                   claudeMetadata: ClaudeSessionMetadata(startupSource: .resume), isRemote: true)
        let gate = h.feed("s1", .sessionStarted(start))
        guard case .merge = gate else { Issue.record("expected a merge, got \(gate)"); return }
        let session = try #require(h.state.session(id: "s1"))
        #expect(session.isHookManaged)
        #expect(session.isRemote)
        #expect(!session.isCodexAppSession)
        #expect(session.phase == .running)
        #expect(session.title == "Fix the tests")
    }
}
