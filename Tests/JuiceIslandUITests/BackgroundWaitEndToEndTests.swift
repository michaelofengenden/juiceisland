import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// The owner's report after fc28c1e1 (P510-P512), end to end: the **built helper** runs each hook with Claude Code
/// 2.1.280's input on stdin (a Stop's and a SubagentStop's `background_tasks` as its builder writes them), the engine's
/// real notes listener takes its note, a stand-in for upstream's bridge replays what upstream emits for the hook, and the
/// real engine and `EngineSessionsModel` draw the row (`AttentionRig`). The note of the helper before P510 (a count, no
/// kinds) is sent as that helper sent it, to the same listener. Fixtures are fictional.
@MainActor
@Suite(.serialized)
struct BackgroundWaitEndToEndTests {
    typealias E = AttentionEndToEndTests

    static let workflow: [String: Any] = ["id": "w-review", "type": "workflow", "status": "running", "description": "Review the branch",
                                          "name": "review"]
    static let shell: [String: Any] = ["id": "b1", "type": "shell", "status": "running", "description": "Dev server",
                                       "command": "npm run dev"]
    static func agent(_ id: String) -> [String: Any] {
        ["id": id, "type": "subagent", "status": "running", "description": "Map the parser", "agent_type": "general-purpose"]
    }

    private func begin(_ rig: AttentionRig) async {
        await rig.finished(E.claude(rig, "SessionStart", extra: ["source": "startup"]),
                           events: [E.started("s1", transcript: E.transcript(rig, "s1"))])
        await rig.finished(E.claude(rig, "UserPromptSubmit", extra: ["prompt": "review the branch"]),
                           events: E.prompt("s1", "review the branch", transcript: E.transcript(rig, "s1")))
    }

    private func stop(_ rig: AttentionRig, _ tasks: [[String: Any]]) async {
        await rig.finished(E.claude(rig, "Stop", extra: ["stop_hook_active": false, "last_assistant_message": "Started the review.",
                                                         "background_tasks": tasks]),
                           events: E.stop("s1", lastPrompt: "review the branch", message: "Started the review."))
    }

    private func wake(_ rig: AttentionRig, _ task: String) async {
        let text = "<task-notification>\n<task-id>\(task)</task-id>\n<status>completed</status>\n</task-notification>"
        await rig.finished(E.claude(rig, "UserPromptSubmit", extra: ["prompt": text]),
                           events: E.prompt("s1", text, transcript: E.transcript(rig, "s1")))
    }

    /// A workflow's agent's hook: its SubagentStart (echoed by upstream as the parent's activity), a tool call (dropped
    /// by upstream, whose helper still runs), or its SubagentStop (nothing from upstream once the parent's turn ended).
    private func agentHook(_ rig: AttentionRig, _ event: String, _ agent: String, extra: [String: Any] = [:]) -> HelperRun {
        let object = E.claude(rig, event, tool: event == "PreToolUse" ? "Read" : nil,
                              input: event == "PreToolUse" ? ["file_path": "/tmp/project/README.md"] : nil,
                              toolUseID: event == "PreToolUse" ? "U-\(agent)" : nil, agent: agent, extra: extra)
        let echo: [AgentEvent] = event == "SubagentStart" ? [E.running("s1", "Started worker subagent.")] : []
        return rig.hook(object, events: echo)
    }

    private func word(_ rig: AttentionRig) -> StatusWord? { rig.row("s1")?.status }

    /// A workflow at the Stop: teal, "Waiting on 1 workflow". Its next phase's agents start side by side (their helpers
    /// run at once, so notes and echoes interleave as they come) and work: still teal, no Done. Its result wakes the main
    /// agent (blue); the Stop that names only a shell is the one Done.
    @Test
    func aWorkflowAtStopWaitsThroughItsAgentsAndTheWakeUpIsTheOneDone() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        await stop(rig, [Self.workflow])
        rig.advance(3)
        #expect(word(rig) == .subagents(0, workflows: 1) && rig.row("s1")?.glyphState == .delegating)
        #expect(rig.row("s1").map { SessionRowText.cleanStatus($0) }?.text == "Waiting on 1 workflow" && rig.card("s1") == nil)
        #expect(rig.dones.isEmpty)

        let runs = ["w4", "w5", "w6"].flatMap { [agentHook(rig, "SubagentStart", $0), agentHook(rig, "PreToolUse", $0)] }
        for run in runs { _ = await run.result() }
        await rig.waitUntil { rig.notesHeard.current >= rig.notesSent }
        await rig.settle()
        _ = await agentHook(rig, "SubagentStop", "w4", extra: ["stop_hook_active": false, "last_assistant_message": "Checked.",
                                                               "background_tasks": [Self.workflow]]).result()
        await rig.waitUntil { rig.notesHeard.current >= rig.notesSent }
        await rig.settle()
        rig.advance(600)
        #expect(rig.engine.state.session(id: "s1")?.phase == .completed)
        #expect(word(rig) == .subagents(0, workflows: 1) && rig.dones.isEmpty)

        await wake(rig, "w-review")
        #expect(rig.row("s1")?.glyphState == .running)
        await stop(rig, [Self.shell])
        rig.advance(2)
        #expect(rig.row("s1")?.bucket == .done && rig.dones == [.done(sessionID: "s1")])
        rig.advance(60)
        #expect(rig.dones.count == 1)
    }

    /// Two agents and a workflow: said together; each agent's SubagentStop (Claude still lists its own agent while its
    /// hook runs, and the helper leaves it out) keeps the words until the wake-up.
    @Test
    func agentsAndAWorkflowAreSaidTogether() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        await stop(rig, [Self.agent("a1"), Self.agent("a2"), Self.workflow, Self.shell])
        rig.advance(3)
        #expect(word(rig) == .subagents(2, workflows: 1))
        #expect(rig.row("s1").map { SessionRowText.cleanStatus($0) }?.text == "Waiting on 2 agents · 1 workflow")
        _ = await agentHook(rig, "SubagentStop", "a1", extra: ["stop_hook_active": false, "last_assistant_message": "Mapped.",
                                                               "background_tasks": [Self.agent("a1"), Self.agent("a2"), Self.workflow]]).result()
        await rig.waitUntil { rig.notesHeard.current >= rig.notesSent }
        await rig.settle()
        #expect(word(rig) == .subagents(2, workflows: 1))
        await wake(rig, "a1")
        await stop(rig, [Self.agent("a2"), Self.workflow])
        rig.advance(3)
        #expect(word(rig) == .subagents(1, workflows: 1) && rig.dones.isEmpty)
    }

    /// A dev server alone: done, with its Done, as today.
    @Test
    func aBackgroundShellAloneIsDoneAsToday() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        await stop(rig, [Self.shell])
        rig.advance(2)
        #expect(word(rig) == .done && rig.dones == [.done(sessionID: "s1")])
    }

    /// The helper before P510 (its Stop note counts `background_tasks`, never by kind), with a workflow whose agents
    /// started before the app: no wait, and the Done, as today. The same Stop through this build's helper waits.
    @Test
    func theOldNoteKeepsTodaysBehaviourAndTheNewOneWaits() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig)
        let old = Data(#"{"v":2,"event":"Stop","session_id":"s1","source":"claude","entrypoint":"cli","stop_hook_active":false,"background_task_count":1}"#.utf8)
        #expect(HookContextNote.decode(old)?.backgroundTaskKinds == nil)
        let heard = rig.notesHeard.current
        #expect(HookNoteSender.send(old, to: rig.notesURL) == .sent)
        await rig.waitUntil { rig.notesHeard.current > heard }
        await rig.emit(E.stop("s1", lastPrompt: "review the branch", message: "Started the review.")[0],
                       E.stop("s1", lastPrompt: "review the branch", message: "Started the review.")[1])
        rig.advance(2)
        #expect(word(rig) == .done && rig.dones == [.done(sessionID: "s1")])

        // The next turn, and the same Stop through this build's helper: its kinds make the row wait (launched mid-run).
        await rig.finished(E.claude(rig, "UserPromptSubmit", extra: ["prompt": "and the docs"]),
                           events: E.prompt("s1", "and the docs", transcript: E.transcript(rig, "s1")))
        await stop(rig, [Self.workflow])
        rig.advance(3)
        #expect(word(rig) == .subagents(0, workflows: 1) && rig.dones.count == 1)
    }
}
