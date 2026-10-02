import Foundation
import OpenIslandCore
import Testing
@testable import IslandEngine

/// A Codex chat whose own turn ended while its subagents still run (P513, changing P212's rule): it waits on them in the
/// teal ("Waiting on 2 agents"), as a Claude main agent does (P370), with no Done; the wake-up turn their results start
/// (Codex's `<subagent_notification>`, P253) is the one Done. Before, the chat read done and gave its Done at once, and
/// the wake-up gave a second. The subagents are the thread book's (`thread_spawn` rollouts, fictional ids), as a scan or
/// the watch of their rollouts hands them on; the chat's own hooks reach the engine as upstream's bridge emits them.
@MainActor
struct CodexSubagentWaitTests {
    typealias S = AttentionScene
    typealias F = EngineFixtures
    typealias T = CodexThreadFixtures

    private func subagents(_ s: S, _ count: Int) {
        s.engine.takeCodexChildren((1...count).map {
            CodexChildThread(id: T.subagentID($0), parentID: T.chatA, rootID: T.chatA, name: "worker", isRunning: true,
                             updatedAt: s.clock.current, transcriptPath: "")
        })
    }

    /// A subagent's own turn ends, as the watch of its rollout reads it.
    private func finishes(_ s: S, _ n: Int) {
        s.engine.ingestSubagentEvent(.sessionCompleted(SessionCompleted(sessionID: T.subagentID(n), summary: "Checked.",
                                                                        timestamp: s.clock.current)))
    }

    private func word(_ s: S) -> StatusWord? { s.engine.state.session(id: T.chatA).map(s.engine.statusWord) }

    /// The chat's Stop hook: its note (the superset helper runs every Codex hook), then the bridge's completion.
    private func stop(_ s: S) {
        s.hook(S.codex("Stop", session: T.chatA, turn: "turn-\(Int(s.t))"), source: "codex")
        s.bridge(F.completed(T.chatA, at: s.clock.current))
    }

    /// `hooked`: a prompt hook reports the wake-up (its `<subagent_notification>`); otherwise the wake-up shows the
    /// bridge nothing before its Stop hook (a rollout's read of it, after the bridge's Stop, is stale and dropped).
    @Test(arguments: [true, false])
    func aChatWhoseTurnEndedWhileItsSubagentsRunWaitsThenGivesOneDone(_ hooked: Bool) throws {
        let s = S()
        s.begin(T.chatA, tool: .codex, prompt: "check every section")
        subagents(s, 2)
        s.at(30)
        #expect(word(s) == .subagents(2))
        // Its own turn ends: it waits on them, at work, with no Done.
        stop(s)
        #expect(s.phase(T.chatA) == .completed && word(s) == .subagents(2))
        let chat = try #require(s.engine.state.session(id: T.chatA))
        #expect(s.engine.isDelegating(chat) && s.engine.waitingSubagents(for: chat) == 2 && s.engine.runningCount == 1)
        s.at(40)
        #expect(s.dones.isEmpty)
        finishes(s, 1)
        #expect(word(s) == .subagents(1))
        s.at(60)
        finishes(s, 2)
        // Their results wake it: blue, then its Stop is the one Done.
        #expect(word(s) == .done && s.dones.isEmpty)
        if hooked {
            s.bridge(F.prompt(T.chatA, "<subagent_notification>{\"agent_id\":\"\(T.subagentID(2))\",\"status\":\"completed\"}</subagent_notification>",
                              at: s.clock.current))
            #expect(s.phase(T.chatA) == .running && word(s) != .subagents(0))
        }
        s.at(70)
        stop(s)
        #expect(word(s) == .done)
        s.at(72)
        #expect(s.dones == [.done(sessionID: T.chatA)])
        s.at(300)
        #expect(s.dones.count == 1)
    }

    /// Its subagents gone quiet past their limit (a crash mid-turn, P218) with no wake-up: the chat reads done then,
    /// silently.
    @Test
    func aChatWhoseSubagentsLapseReadsDoneSilently() {
        let s = S()
        s.begin(T.chatA, tool: .codex, prompt: "check every section")
        subagents(s, 1)
        stop(s)
        #expect(word(s) == .subagents(1))
        s.at(CodexThreadBook.runningQuietLimit + 60)
        #expect(word(s) == .done && s.dones.isEmpty)
    }

    // MARK: A Stop that comes before the watch reads a subagent's end (P514)

    /// The usual pattern: the chat's `wait` returns with its subagent's result, and the chat answers and ends its turn
    /// within a second, before the watch's 3 s poll reads the subagent's end. That Stop's Done is the chat's own: it is
    /// held its 1.5 s, not dropped at once as a wait's, and comes once the end is read.
    @Test
    func aStopBeforeTheWatchReadsTheSubagentsEndStillGivesItsDone() {
        let s = S()
        s.begin(T.chatA, tool: .codex, prompt: "check every section")
        subagents(s, 1)
        s.at(30)
        stop(s)
        s.at(31)
        finishes(s, 1)
        #expect(word(s) == .done)
        s.at(32)
        #expect(s.dones == [.done(sessionID: T.chatA)])
        s.at(300)
        #expect(s.dones.count == 1)
    }

    /// The same race in a wake-up turn: the chat's turn ends while two subagents run; the first one's result wakes it,
    /// and that turn waits on the second, takes in its result and ends before the watch reads the second's end.
    @Test
    func aWakeUpThatTakesInTheLastResultBeforeTheWatchReadsItGivesItsDone() {
        let s = S()
        s.begin(T.chatA, tool: .codex, prompt: "check every section")
        subagents(s, 2)
        s.at(10)
        stop(s)
        #expect(word(s) == .subagents(2))
        s.at(40)
        finishes(s, 1)
        s.bridge(F.prompt(T.chatA, "<subagent_notification>{\"agent_id\":\"\(T.subagentID(1))\",\"status\":\"completed\"}</subagent_notification>",
                          at: s.clock.current))
        #expect(s.phase(T.chatA) == .running && s.dones.isEmpty)
        s.at(70)
        stop(s)
        s.at(71)
        finishes(s, 2)
        s.at(72)
        #expect(word(s) == .done && s.dones == [.done(sessionID: T.chatA)])
    }

    /// The chat's own Stop note reads its running subagents' rollouts at once (P514): a subagent whose turn ended just
    /// before the chat's is read within the Done's hold, not at the watch's next poll 3 s on. A real watch, on a
    /// subagent rollout in a temporary folder.
    @Test
    func theChatsStopNoteReadsItsRunningSubagentsAtOnce() async throws {
        typealias R = RolloutFixtures
        let root = R.sessionsFolder()
        defer { R.remove(root) }
        let s = S()
        s.begin(T.chatA, tool: .codex, prompt: "check every section")
        let url = T.write(T.subagent(T.subagentID(1), parent: T.chatA, running: true), id: T.subagentID(1), in: root, minutesAgo: 0)
        s.engine.takeCodexChildren([CodexChildThread(id: T.subagentID(1), parentID: T.chatA, rootID: T.chatA, name: "Hubble",
                                                     isRunning: true, updatedAt: s.clock.current, transcriptPath: url.path)])
        defer { s.engine.subagentRollouts?.stop() }
        s.engine.subagentRollouts?.waitUntilIdle()
        await s.settle()
        #expect(s.engine.runningSubagents(for: T.chatA) == 1)
        // The subagent's turn ends, the chat's `wait` returns with it, and the chat answers and stops.
        R.append(R.text([R.message("assistant", "Section checked.", at: 40),
                         R.event("task_complete", ["last_agent_message": "Section checked."], at: 41)]), to: url)
        s.at(42)
        stop(s)
        await s.settle {
            s.engine.subagentRollouts?.waitUntilIdle()
            return s.engine.runningSubagents(for: T.chatA) == 0
        }
        #expect(s.engine.runningSubagents(for: T.chatA) == 0 && word(s) == .done)
        s.at(44)
        #expect(s.dones == [.done(sessionID: T.chatA)])
    }

    /// A chat with no subagent running still gives its Done as before.
    @Test
    func aChatWithNoSubagentRunningIsDoneAsBefore() {
        let s = S()
        s.begin(T.chatA, tool: .codex, prompt: "check every section")
        subagents(s, 1)
        finishes(s, 1)
        stop(s)
        #expect(word(s) == .done)
        s.at(2)
        #expect(s.dones == [.done(sessionID: T.chatA)])
    }
}
