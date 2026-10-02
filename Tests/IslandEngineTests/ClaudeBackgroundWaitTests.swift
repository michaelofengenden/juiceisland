import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// The owner's report of 2026-09-28, after fc28c1e1 (P510-P512): a Claude session whose main turn had ended with
/// "Waiting for 1 dynamic workflow to finish" (a Workflow-tool run of background agents, 9 of 10 done) showed as a blue
/// running row with a reply as its detail, not teal, while a session waiting on one Agent-tool background agent read
/// "Waiting on 1 agent". The wait now follows Claude's own word: the kinds a Stop's `background_tasks` names (as the
/// helper counts them), background agents and workflows, never shells or monitors; and a workflow's agents, which fire
/// SubagentStart, their tools' hooks and SubagentStop in the parent's session with their own `agent_id`, never wake the
/// finished row, however their notes interleave. Shapes as Claude Code 2.1.280 builds them (its hook schema and
/// `background_tasks` builder: `id`, `type` from `local_agent` → `subagent`, `local_workflow` → `workflow`, `local_bash`
/// → `shell`, `monitor_mcp` → `monitor`, `status`, `description`, and per kind `command`, `agent_type`, `server`/`tool`,
/// `name`); ids and texts are fictional. Driven as `ClaudeSubagentWaitTests` drives the engine (`AttentionScene`).
@MainActor
struct ClaudeBackgroundWaitTests {
    typealias S = AttentionScene
    typealias F = EngineFixtures

    // MARK: Claude's background work

    static func agentTask(_ id: String) -> [String: Any] {
        ["id": id, "type": "subagent", "status": "running", "description": "Map the parser", "agent_type": "general-purpose"]
    }

    static func workflowTask(_ id: String = "w-review") -> [String: Any] {
        ["id": id, "type": "workflow", "status": "running", "description": "Review the branch", "name": "review"]
    }

    static let shellTask: [String: Any] = ["id": "b1", "type": "shell", "status": "running", "description": "Dev server",
                                           "command": "npm run dev"]
    static let monitorTask: [String: Any] = ["id": "m1", "type": "monitor", "status": "running", "description": "Watch the build",
                                             "server": "ci", "tool": "watch"]

    // MARK: Hooks

    /// The main agent's Stop: its note (`tasks` as `background_tasks`; nil: a Claude that names none), then the bridge's.
    private func stop(_ s: S, _ tasks: [[String: Any]]?, countsKinds: Bool = true) {
        var extra: [String: Any] = ["stop_hook_active": false, "last_assistant_message": "Started the review."]
        if let tasks { extra["background_tasks"] = tasks }
        s.hook(S.claude("Stop", extra: extra), countsKinds: countsKinds)
        s.bridge(.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "Started the review.", timestamp: s.clock.current)))
    }

    /// The Workflow tool: the main agent's own call, which returns at once with the run in the background.
    private func launchWorkflow(_ s: S) {
        s.hook(S.claude("PreToolUse", tool: "Workflow", input: ["description": "Review the branch"], toolUseID: "UWF"))
        s.bridge(F.running("s1", summary: "Running Workflow", at: s.clock.current))
        s.hook(S.claude("PostToolUse", tool: "Workflow", input: ["description": "Review the branch"], toolUseID: "UWF"))
        s.bridge(F.running("s1", summary: "Workflow finished.", at: s.clock.current))
    }

    /// An agent starts in the parent's session: its SubagentStart note; `echo`, then the bridge's running activity for it.
    private func starts(_ s: S, _ agent: String, echo: Bool = true) {
        s.hook(S.claude("SubagentStart", agent: agent, agentType: "general-purpose"))
        if echo { self.echo(s) }
    }

    /// Upstream's bridge applies a SubagentStart as the parent's running activity (`BridgeServer.swift`).
    private func echo(_ s: S) {
        s.bridge(F.running("s1", summary: "Started general-purpose subagent.", at: s.clock.current))
    }

    /// One tool call of an agent's: its notes only (upstream's bridge drops a hook with an `agent_id`).
    private func works(_ s: S, _ agent: String, _ call: String) {
        s.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: call, agent: agent, agentType: "general-purpose"))
        s.hook(S.claude("PostToolUse", tool: "Read", input: S.read, toolUseID: call, agent: agent, agentType: "general-purpose"))
    }

    /// An agent's SubagentStop: `listed` is the session's `background_tasks` as Claude builds it then (the stopping agent
    /// itself still listed when it is a background agent). The bridge emits nothing once the parent's turn has ended.
    private func stops(_ s: S, _ agent: String, listed: [[String: Any]]) {
        s.hook(S.claude("SubagentStop", agent: agent, agentType: "general-purpose",
                        extra: ["stop_hook_active": false, "last_assistant_message": "Checked section 3.", "background_tasks": listed]))
        if s.phase() != .completed { s.bridge(F.running("s1", summary: "Checked section 3.", at: s.clock.current)) }
    }

    /// The main agent woken by a finished run's result: Claude's `<task-notification>` as a prompt (P155, P253).
    private func wake(_ s: S, _ task: String) {
        s.hook(S.claude("UserPromptSubmit"))
        s.bridge(F.prompt("s1", "<task-notification>\n<task-id>\(task)</task-id>\n<status>completed</status>\n</task-notification>",
                          at: s.clock.current))
    }

    private func word(_ s: S) -> StatusWord? { s.engine.state.session(id: "s1").map(s.engine.statusWord) }

    private func delegating(_ s: S) -> Bool { s.engine.state.session(id: "s1").map(s.engine.isDelegating) ?? false }

    // MARK: The owner's report

    /// A workflow still runs at the main agent's Stop: the row waits on it in the teal ("Waiting on 1 workflow"), not
    /// on its agents one by one. Its next phase starts agents side by side, whose SubagentStart notes, tool notes and the
    /// bridge's echoes interleave: none wakes the row, gives it a reply, or makes a Done. Its result wakes the main
    /// agent (blue), and that turn's Stop, naming nothing, is the one Done.
    @Test
    func aWorkflowRunningAtStopIsTealAndItsAgentsNeverWakeTheRow() throws {
        let s = S()
        s.begin()
        launchWorkflow(s)
        for agent in ["w1", "w2", "w3"] { starts(s, agent) }
        s.at(20)
        stop(s, [Self.workflowTask()])
        #expect(word(s) == .subagents(0, workflows: 1) && delegating(s) && s.phase() == .completed)
        #expect(StatusWord.subagentsText(0, workflows: 1) == "Waiting on 1 workflow")
        #expect(s.engine.runningCount == 1)
        s.at(25)
        #expect(s.dones.isEmpty && s.signals.isEmpty)

        // The next phase: three agents start side by side while the first ones work.
        starts(s, "w4", echo: false)
        works(s, "w2", "U2")
        starts(s, "w5", echo: false)
        works(s, "w3", "U3")
        echo(s)
        starts(s, "w6", echo: false)
        echo(s)
        works(s, "w1", "U1")
        echo(s)
        let session = try #require(s.engine.state.session(id: "s1"))
        #expect(session.phase == .completed && session.summary == "Started the review.")
        #expect(session.claudeMetadata?.lastAssistantMessage != "Checked section 3.")
        #expect(word(s) == .subagents(0, workflows: 1))
        // An agent of the workflow finishes: Claude still lists the workflow, and no agent of its own: nothing changes.
        stops(s, "w1", listed: [Self.workflowTask()])
        #expect(word(s) == .subagents(0, workflows: 1))
        // Hours of work, a sign every 20 minutes.
        for step in 1...9 {
            s.at(25 + Double(step) * 20 * 60)
            works(s, "w4", "UW\(step)")
        }
        #expect(word(s) == .subagents(0, workflows: 1) && s.phase() == .completed && s.signals.isEmpty)

        // The workflow's result wakes the main agent: blue, then its Stop is the one Done.
        wake(s, "w-review")
        #expect(s.phase() == .running && !delegating(s))
        s.at(3 * 3600 + 60)
        stop(s, [])
        #expect(word(s) == .done)
        s.at(3 * 3600 + 62)
        #expect(s.dones == [.done(sessionID: "s1")])
        s.at(3 * 3600 + 600)
        #expect(s.dones.count == 1)
    }

    /// The same echoes, with the helper before P510 and no workflow in the Stop's count: each SubagentStart note still
    /// stands for its own echo, whatever notes come between, so the finished row is never woken (P511).
    @Test
    func interleavedEchoesNeverWakeAFinishedRowWhateverTheHelper() {
        let s = S()
        s.begin()
        starts(s, "a1")
        stop(s, [Self.agentTask("a1")], countsKinds: false)
        #expect(word(s) == .subagents(1))
        starts(s, "a2", echo: false)
        works(s, "a1", "U1")
        starts(s, "a3", echo: false)
        works(s, "a2", "U2")
        echo(s)
        works(s, "a3", "U3")
        echo(s)
        #expect(s.phase() == .completed && word(s) == .subagents(3))
        // An echo with no note of its own (a note lost on the way) is applied, as before.
        echo(s)
        #expect(s.phase() == .running)
    }

    /// Background agents and a workflow: both said, once each ("Waiting on 2 agents · 1 workflow"). Each agent's result
    /// wakes the main agent, whose Stop names what is left; only the Stop that names nothing is the Done.
    @Test
    func agentsAndAWorkflowAreBothSaidAndTheLastStopIsTheOneDone() {
        let s = S()
        s.begin()
        starts(s, "a1")
        starts(s, "a2")
        launchWorkflow(s)
        stop(s, [Self.agentTask("a1"), Self.agentTask("a2"), Self.workflowTask()])
        #expect(word(s) == .subagents(2, workflows: 1))
        #expect(StatusWord.subagentsText(2, workflows: 1) == "Waiting on 2 agents · 1 workflow")
        s.at(30)
        // a1 finishes (listed, as Claude lists it while its hook runs): it still counts until the wake-up.
        stops(s, "a1", listed: [Self.agentTask("a1"), Self.agentTask("a2"), Self.workflowTask()])
        #expect(word(s) == .subagents(2, workflows: 1))
        wake(s, "a1")
        #expect(s.phase() == .running)
        s.at(40)
        stop(s, [Self.agentTask("a2"), Self.workflowTask()])
        #expect(word(s) == .subagents(1, workflows: 1))
        #expect(StatusWord.subagentsText(1, workflows: 1) == "Waiting on 1 agent · 1 workflow")
        s.at(90)
        stops(s, "a2", listed: [Self.agentTask("a2"), Self.workflowTask()])
        wake(s, "a2")
        s.at(100)
        stop(s, [Self.workflowTask(), Self.shellTask])
        #expect(word(s) == .subagents(0, workflows: 1))
        s.at(2000)
        #expect(s.dones.isEmpty)
        wake(s, "w-review")
        s.at(2010)
        stop(s, [Self.shellTask])
        s.at(2012)
        #expect(word(s) == .done && s.dones == [.done(sessionID: "s1")])
    }

    // MARK: What never waits

    /// A dev server or a monitor left running is no wait: the turn is done, with its Done, as today.
    @Test(arguments: ["shell", "monitor", "both"])
    func aBackgroundShellOrMonitorAloneIsDoneAsToday(_ left: String) {
        let tasks = left == "shell" ? [Self.shellTask] : left == "monitor" ? [Self.monitorTask] : [Self.shellTask, Self.monitorTask]
        let s = S()
        s.begin()
        s.at(10)
        stop(s, tasks)
        #expect(word(s) == .done && !delegating(s))
        s.at(12)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    /// A background agent the book saw start, and a Stop that names only a shell: Claude says no agent is in flight, so
    /// nothing waits (its SubagentStop was lost), and the Done comes.
    @Test
    func aStopNamingOnlyAShellEndsAnAgentWhoseStopWasLost() {
        let s = S()
        s.begin()
        starts(s, "a1")
        s.at(10)
        stop(s, [Self.shellTask])
        #expect(word(s) == .done && s.engine.claudeSubagentCounts.isEmpty)
        s.at(12)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    // MARK: The helper before P510

    /// With the helper before P510 (its Stop note counts `background_tasks` but not by kind) the wait is today's: a
    /// workflow whose agents the book never saw start is no wait, and its Stop is a Done; an agent the book saw start is.
    @Test
    func theHelperBeforeP510KeepsTodaysWait() {
        let s = S()
        s.begin()
        s.at(10)
        stop(s, [Self.workflowTask()], countsKinds: false)
        #expect(word(s) == .done)
        s.at(12)
        #expect(s.dones == [.done(sessionID: "s1")])

        s.hook(S.claude("UserPromptSubmit"))
        s.bridge(F.prompt("s1", "and the lexer", at: s.clock.current))
        starts(s, "a1")
        s.at(20)
        stop(s, [Self.agentTask("a1"), Self.workflowTask()], countsKinds: false)
        #expect(word(s) == .subagents(1))
        s.at(40)
        #expect(s.dones.count == 1)
    }

    // MARK: Work that started before the app

    /// The app launched mid-workflow (the owner's Update): the workflow's agents started unseen, and only their tools'
    /// notes come. The main agent's Stop names the workflow: teal from that Stop, and the one Done at the wake-up's.
    @Test
    func anAppLaunchedMidWorkflowIsTealFromTheStop() {
        let s = S()
        // The session as the app finds it (its prompt came before the launch); the workflow's agents started unseen.
        s.begin()
        works(s, "w7", "U7")
        s.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: "UM"))
        s.bridge(F.running("s1", summary: "Running Read", at: s.clock.current))
        s.at(30)
        stop(s, [Self.workflowTask()])
        #expect(word(s) == .subagents(0, workflows: 1) && s.engine.claudeSubagentCounts.isEmpty)
        s.at(40)
        stops(s, "w7", listed: [Self.workflowTask()])
        #expect(word(s) == .subagents(0, workflows: 1) && s.dones.isEmpty)
        wake(s, "w-review")
        s.at(60)
        stop(s, [])
        s.at(62)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    /// A background agent started before the app: unknown to the book, named by the Stop ("Waiting on 1 agent"). Its
    /// SubagentStop no longer names it: it counts for the wake grace, the wake-up comes, and its Stop is the one Done.
    @Test
    func anAgentStartedBeforeTheAppWaitsFromTheStop() {
        let s = S()
        s.begin()
        s.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: "UM"))
        s.bridge(F.running("s1", summary: "Running Read", at: s.clock.current))
        s.at(10)
        stop(s, [Self.agentTask("a9")])
        #expect(word(s) == .subagents(1))
        s.at(40)
        stops(s, "a9", listed: [Self.agentTask("a9")])
        #expect(word(s) == .subagents(1))
        s.at(42)
        wake(s, "a9")
        s.at(50)
        stop(s, [])
        s.at(52)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    /// As above with no wake-up: the row reads done after the grace, silently.
    @Test
    func anAgentsResultThatWakesNothingEndsTheWaitSilently() {
        let s = S()
        s.begin()
        stop(s, [Self.agentTask("a9")])
        s.at(40)
        stops(s, "a9", listed: [Self.agentTask("a9")])
        s.at(40 + ClaudeSubagentBook.wakeGrace - 1)
        #expect(word(s) == .subagents(1))
        s.at(40 + ClaudeSubagentBook.wakeGrace + 2)
        #expect(word(s) == .done && s.dones.isEmpty)
        // The one check asked for at the Stop falls due and finds nothing: nothing is left to run.
        s.at(40 + ClaudeSubagentBook.quietLimit + 5)
        #expect(word(s) == .done && s.dones.isEmpty && s.scheduled.current.isEmpty)
    }

    // MARK: The end of a wait (P512)

    /// A workflow that shows no sign for `workflowQuietLimit` (its session killed with no SessionEnd, its process found
    /// alive) stops counting then, silently, with nothing scheduled after; a wait on an agent alone keeps the agents'
    /// 30 minutes.
    @Test
    func aQuietWaitLapsesAtItsLimitSilently() {
        let s = S()
        s.begin()
        stop(s, [Self.workflowTask()])
        s.at(ClaudeSubagentBook.workflowQuietLimit - 60)
        #expect(word(s) == .subagents(0, workflows: 1))
        s.at(ClaudeSubagentBook.workflowQuietLimit + 2)
        #expect(word(s) == .done && s.dones.isEmpty && s.scheduled.current.isEmpty)

        let t = S()
        t.begin()
        t.at(5)
        stop(t, [Self.agentTask("a9")])
        t.at(5 + ClaudeSubagentBook.quietLimit - 60)
        #expect(t.engine.state.session(id: "s1").map(t.engine.statusWord) == .subagents(1))
        t.at(5 + ClaudeSubagentBook.quietLimit + 2)
        #expect(t.engine.state.session(id: "s1").map(t.engine.statusWord) == .done && t.dones.isEmpty)
    }

    /// The session ends, or its process is gone, mid-workflow: nothing waits and nothing is Done.
    @Test(arguments: [true, false])
    func aSessionEndOrAGoneProcessEndsAWorkflowWait(_ sessionEnd: Bool) throws {
        let s = S()
        s.begin()
        launchWorkflow(s)
        stop(s, [Self.workflowTask()])
        s.at(20)
        if sessionEnd {
            s.hook(S.claude("SessionEnd", extra: ["reason": "prompt_input_exit"]))
            s.bridge(F.sessionEnd("s1", at: s.clock.current))
        } else {
            s.gone.update { $0.insert(900) }
            s.livenessPass()
        }
        let session = try #require(s.engine.state.session(id: "s1"))
        #expect(s.engine.waitingSubagents(for: session) == 0 && s.engine.claudeWaits.isEmpty)
        s.at(60)
        #expect(s.dones.isEmpty)
    }

    /// The wake-up after a workflow fires no prompt hook and uses no tool: its own Stop, naming nothing, is still the one
    /// Done (P375).
    @Test
    func aWakeUpWithNoPromptOrToolAfterAWorkflowIsTheOneDone() {
        let s = S()
        s.begin()
        launchWorkflow(s)
        stop(s, [Self.workflowTask()])
        s.at(600)
        #expect(s.dones.isEmpty)
        stop(s, [])
        #expect(word(s) == .done)
        s.at(602)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    // MARK: A wait lost and found again (P515)

    /// The owner clicks Update while the row reads "Waiting on 1 workflow": the relaunched app has the session as its
    /// store kept it (the turn over) and none of its notes. The workflow's next agent starts (the book's own count, as
    /// with the helper before P510), and its SubagentStop, whose list names the workflow, makes Claude's word the wait
    /// again; the agents after it change nothing, and the wake-up's Stop is the one Done.
    @Test
    func aRelaunchMidWorkflowWaitsOnTheWorkflowAgainFromItsAgentsNextStop() {
        let s = S()
        s.bridge(F.started("s1"), F.completed("s1", at: s.clock.current))
        s.at(10)
        let before = s.dones.count
        starts(s, "w5")
        works(s, "w5", "U1")
        s.at(300)
        stops(s, "w5", listed: [Self.workflowTask()])
        #expect(word(s) == .subagents(0, workflows: 1))
        s.at(320)
        #expect(word(s) == .subagents(0, workflows: 1) && s.phase() == .completed)
        starts(s, "w6")
        works(s, "w6", "U2")
        s.at(600)
        stops(s, "w6", listed: [Self.workflowTask()])
        s.at(620)
        #expect(word(s) == .subagents(0, workflows: 1) && s.dones.count == before)
        wake(s, "w-review")
        s.at(700)
        stop(s, [])
        s.at(702)
        #expect(s.dones.count == before + 1)
    }

    /// The Mac sleeps past the workflow's quiet limit mid-run (the lapse counts wall time, and Claude sends nothing while
    /// asleep): on the wake, the first note of one of its agents brings the wait back, and it holds through the run.
    @Test
    func aWaitThatLapsedWhileTheMacSleptComesBackAtItsAgentsNextNote() {
        let s = S()
        s.begin()
        launchWorkflow(s)
        starts(s, "w1")
        stop(s, [Self.workflowTask()])
        s.at(7 * 3600)
        #expect(word(s) == .done && s.dones.isEmpty)
        works(s, "w1", "U1")
        #expect(word(s) == .subagents(0, workflows: 1))
        s.at(7 * 3600 + 60)
        stops(s, "w1", listed: [Self.workflowTask()])
        starts(s, "w2")
        works(s, "w2", "U2")
        #expect(word(s) == .subagents(0, workflows: 1) && s.phase() == .completed && s.dones.isEmpty)
        wake(s, "w-review")
        s.at(7 * 3600 + 120)
        stop(s, [])
        s.at(7 * 3600 + 122)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    /// After a relaunch, a background agent the app never saw start stops. Claude still lists it while its hook runs,
    /// which the helper says (`agent_in_background`): its result is to wake the main agent, so the row waits for the
    /// wake grace and the wake-up's Stop, with no prompt hook and no tool, is the one Done.
    @Test
    func aBackgroundAgentsStopAfterARelaunchStillGivesAPromptlessWakeUpItsDone() {
        let s = S()
        s.bridge(F.started("s1"), F.completed("s1", at: s.clock.current))
        s.at(10)
        let before = s.dones.count
        works(s, "a9", "U9")
        s.at(200)
        stops(s, "a9", listed: [Self.agentTask("a9")])
        #expect(word(s) == .subagents(1))
        s.at(205)
        stop(s, [])
        s.at(207)
        #expect(s.dones.count == before + 1)
    }

    /// A background agent quiet past its 30 minutes (one long tool call) stops counting; its SubagentStop, naming it,
    /// then brings its wake back, and the wake-up's Stop, with no prompt hook and no tool, is the one Done.
    @Test
    func aQuietAgentPastItsLimitThenAPromptlessWakeUpGivesItsDone() {
        let s = S()
        s.begin()
        starts(s, "a1")
        s.at(5)
        stop(s, [Self.agentTask("a1")])
        s.at(ClaudeSubagentBook.quietLimit + 120)
        #expect(word(s) == .done && s.dones.isEmpty)
        stops(s, "a1", listed: [Self.agentTask("a1")])
        #expect(word(s) == .subagents(1))
        s.at(ClaudeSubagentBook.quietLimit + 125)
        stop(s, [])
        s.at(ClaudeSubagentBook.quietLimit + 140)
        #expect(s.dones == [.done(sessionID: "s1")])
    }

    // MARK: A SubagentStop's echo (P516)

    /// Upstream's echo of a SubagentStop (the agent's reply as running activity, with its metadata) reaches a finished
    /// row while the bridge's own copy of the state still reads running, after a SubagentStart echo the engine refused.
    /// Its note stands for it, as a SubagentStart's does: the row stays done and teal. The main agent's own tool, after
    /// it, is still its own work.
    @Test
    func aSubagentStopEchoNeverWakesAFinishedRow() {
        let s = S()
        s.begin()
        launchWorkflow(s)
        starts(s, "w1")
        stop(s, [Self.workflowTask()])
        s.at(60)
        starts(s, "w2")
        s.hook(S.claude("SubagentStop", agent: "w1", agentType: "general-purpose",
                        extra: ["stop_hook_active": false, "last_assistant_message": "Checked section 3.",
                                "background_tasks": [Self.workflowTask()]]))
        s.bridge(F.running("s1", summary: "Checked section 3.", at: s.clock.current))
        #expect(s.phase() == .completed && word(s) == .subagents(0, workflows: 1))
        #expect(s.engine.state.session(id: "s1")?.summary == "Started the review.")
        s.at(62)
        s.hook(S.claude("PreToolUse", tool: "Read", input: S.read, toolUseID: "UM"))
        s.bridge(F.running("s1", summary: "Running Read", at: s.clock.current))
        #expect(s.phase() == .running)
    }

    /// Upstream's copy of the state as the engine last sent it.
    private final class SnapshotBridge: EngineBridge, @unchecked Sendable {
        let snapshots = F.Box<[SessionState]>([])
        func updateStateSnapshot(_ snapshot: SessionState) { snapshots.update { $0.append(snapshot) } }
        func stop() {}
    }

    /// A refused echo sends the engine's state back to the bridge at once, so upstream's copy of the parent reads done
    /// again and its next SubagentStop is acknowledged with no echo at all (P516).
    @Test
    func aRefusedEchoSendsTheFinishedRowBackToTheBridge() {
        let s = S()
        let bridge = SnapshotBridge()
        s.engine.bridgeServer = bridge
        s.begin()
        stop(s, [Self.workflowTask()])
        let sent = bridge.snapshots.current.count
        s.at(30)
        starts(s, "w1")
        #expect(s.phase() == .completed && bridge.snapshots.current.count == sent + 1)
        #expect(bridge.snapshots.current.last?.session(id: "s1")?.phase == .completed)
    }
}

/// The note (P510): `background_tasks` counted by kind, its stopping agent left out of a SubagentStop's, never a text.
@MainActor
struct BackgroundTaskKindsTests {
    @Test
    func aStopCountsItsBackgroundWorkByKindAndCarriesNoText() throws {
        let input: [String: Any] = [
            "hook_event_name": "Stop", "session_id": "s", "stop_hook_active": false,
            "background_tasks": [ClaudeBackgroundWaitTests.agentTask("a1"), ClaudeBackgroundWaitTests.agentTask("a2"),
                                 ClaudeBackgroundWaitTests.workflowTask(), ClaudeBackgroundWaitTests.shellTask,
                                 ClaudeBackgroundWaitTests.monitorTask,
                                 ["id": "x", "type": "local_future", "status": "pending", "description": "Something new"]],
        ]
        let note = try #require(HookContextNote.make(object: input, environment: [:], agentPID: 900, source: "claude"))
        #expect(note.backgroundTaskCount == 6)
        #expect(note.backgroundTaskKinds == ["subagent": 2, "workflow": 1, "shell": 1, "monitor": 1, "other": 1])
        let text = String(decoding: try #require(note.encoded()), as: UTF8.self)
        for secret in ["npm run dev", "Map the parser", "Review the branch", "review", "general-purpose", "ci", "local_future"] {
            #expect(!text.contains("\"\(secret)\"") && !text.contains(secret + " "))
        }
        #expect(text.contains(#""background_task_kinds":{"#))
        #expect(HookContextNote.decode(try #require(note.encoded()))?.backgroundTaskKinds == note.backgroundTaskKinds)
    }

    @Test
    func aSubagentStopLeavesItsOwnAgentOutAndAnythingElseCountsNothing() throws {
        let stop: [String: Any] = ["hook_event_name": "SubagentStop", "session_id": "s", "agent_id": "a1", "agent_type": "general-purpose",
                                   "background_tasks": [ClaudeBackgroundWaitTests.agentTask("a1"), ClaudeBackgroundWaitTests.workflowTask()]]
        let note = try #require(HookContextNote.make(object: stop, environment: [:], agentPID: 900, source: "claude"))
        #expect(note.backgroundTaskKinds == ["workflow": 1] && note.backgroundTaskCount == nil)
        let empty: [String: Any] = ["hook_event_name": "Stop", "session_id": "s", "background_tasks": [Any]()]
        #expect(HookContextNote.make(object: empty, environment: [:], agentPID: 900)?.backgroundTaskKinds == [:])
        let none: [String: Any] = ["hook_event_name": "Stop", "session_id": "s"]
        #expect(HookContextNote.make(object: none, environment: [:], agentPID: 900)?.backgroundTaskKinds == nil)
        let other: [String: Any] = ["hook_event_name": "PreToolUse", "session_id": "s", "background_tasks": [ClaudeBackgroundWaitTests.shellTask]]
        #expect(HookContextNote.make(object: other, environment: [:], agentPID: 900)?.backgroundTaskKinds == nil)
    }

    /// Whether a SubagentStop's own agent is one of the background agents Claude lists (P515): a background agent's is,
    /// a workflow's agent's never is (its workflow is listed instead). A boolean only, and only on a SubagentStop with a
    /// list.
    @Test
    func aSubagentStopSaysWhetherClaudeListsItsOwnAgent() throws {
        func note(_ object: [String: Any]) throws -> HookContextNote {
            try #require(HookContextNote.make(object: object, environment: [:], agentPID: 900, source: "claude"))
        }
        let base: [String: Any] = ["hook_event_name": "SubagentStop", "session_id": "s", "agent_type": "general-purpose"]
        let background = try note(base.merging(["agent_id": "a1", "background_tasks": [ClaudeBackgroundWaitTests.agentTask("a1"),
                                                                                       ClaudeBackgroundWaitTests.workflowTask()]]) { $1 })
        #expect(background.agentInBackground == true && background.backgroundTaskKinds == ["workflow": 1])
        let text = String(decoding: try #require(background.encoded()), as: UTF8.self)
        #expect(text.contains(#""agent_in_background":true"#))
        #expect(HookContextNote.decode(try #require(background.encoded()))?.agentInBackground == true)
        let workflowAgent = try note(base.merging(["agent_id": "w1", "background_tasks": [ClaudeBackgroundWaitTests.workflowTask()]]) { $1 })
        #expect(workflowAgent.agentInBackground == false)
        // A shell that happens to share the id is no background agent.
        let shell = try note(base.merging(["agent_id": "b1", "background_tasks": [ClaudeBackgroundWaitTests.shellTask]]) { $1 })
        #expect(shell.agentInBackground == false)
        #expect(try note(base.merging(["agent_id": "a1"]) { $1 }).agentInBackground == nil)
        let stop = try note(["hook_event_name": "Stop", "session_id": "s", "background_tasks": [ClaudeBackgroundWaitTests.agentTask("a1")]])
        #expect(stop.agentInBackground == nil)
    }

    /// A note the helper before P510 sent (no kinds) decodes as it did; one from this helper decodes in an engine that
    /// ignores the field (JSON's unknown keys), so the two may be a build apart (P163).
    @Test
    func theNoteReadsAcrossTheHelperChange() throws {
        let old = Data(#"{"v":2,"event":"Stop","session_id":"s","source":"claude","background_task_count":1}"#.utf8)
        let decoded = try #require(HookContextNote.decode(old))
        #expect(decoded.backgroundTaskCount == 1 && decoded.backgroundTaskKinds == nil)
    }
}
