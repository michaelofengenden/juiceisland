import Foundation

/// A Claude session's subagents as the context notes tell of them (P370): what the session's row waits on once its main
/// turn has ended. Upstream's bridge keeps its own list (`claudeMetadata.activeSubagents`), but clears it at every Stop,
/// StopFailure and SessionEnd and 3 minutes after each subagent started (`BridgeServer.swift` `clearAllActiveSubagents`,
/// `cleanUpStaleSubagents`, P10), so a background agent still at work after its parent's Stop was gone from it, and the
/// parent read as done. Pure; `SessionEngine` owns one.
///
/// A subagent starts with its SubagentStart note, stays while any note of its own (its tools, its requests) comes
/// within `quietLimit`, and ends with its SubagentStop, its session's SessionEnd, or a Stop whose `background_tasks` is
/// empty (Claude's own word that nothing is in flight). Only a SubagentStart adds one: a stray note of an agent the book
/// never saw start, or one that already stopped, adds nothing, so no late note brings a finished subagent back. A
/// SubagentStop that comes while the main turn has ended keeps its agent for `wakeGrace`, until the main agent wakes
/// on its result (its prompt, or its own first tool or Stop), so the row does not read as done for the moment between.
///
/// The main turn has ended by the notes once the main agent's own Stop note came, which is before the bridge applies
/// the Stop (P376). The book also keeps which sessions a finished agent's result is to wake (`awaitsWake`), so the
/// wake-up's Stop is the one Done even when no prompt hook or tool showed it start (P375), and the main agent's open
/// Agent calls (`hasOpenAgentCall`), whose subagents it is blocked on (P377).
///
/// With a helper that counts `background_tasks` by kind (P510), Claude's own word replaces the agents the book saw
/// start: a root Stop that names background agents or workflows in flight is what its main agent waits on
/// (`Background`), however they started (a workflow's agents, an agent started before the app ran), and a SubagentStop
/// that names them again keeps the count current. Background shells, monitors and every other kind wake nothing the
/// owner waits on and are never counted. With an older helper the book's own agents are the wait, as before.
///
/// A wait on Claude's word lost in the app is found again (P515): a SubagentStop that comes while the main turn has
/// ended begins one from its own list when none stands (the app relaunched after the Stop, by the owner's Update), and
/// a wait that lapsed with no sign (the Mac asleep past the limit) is kept, counting nothing, until the next note of
/// one of the session's subagents brings it back. A SubagentStop whose agent Claude lists as a background agent marks
/// the wake awaited, whether or not the book saw it start.
struct ClaudeSubagentBook: Equatable, Sendable {
    /// A subagent that sends nothing for this long stops counting, so a missed SubagentStop never leaves its parent
    /// waiting for good (a tuning constant).
    static let quietLimit: TimeInterval = 30 * 60
    /// How long a subagent that finished while its parent's turn had ended still counts, for the parent's wake-up turn
    /// to start.
    static let wakeGrace: TimeInterval = 10
    /// How long a wait on a workflow may go with no sign of it before it stops counting (P512): a workflow runs its
    /// agents for hours, and one waiting out a rate limit shows nothing until its usage window (5 hours at most) resets,
    /// so the limit is longer than that window. Its agents' every note is a sign, so a workflow at work never lapses; a
    /// wait on agents alone keeps `quietLimit`, as an agent the book saw start does.
    static let workflowQuietLimit: TimeInterval = 6 * 3600
    struct Agent: Equatable, Sendable {
        var lastSeen: Date
        /// Its SubagentStop, while its parent's wake-up is awaited.
        var stoppedAt: Date?
    }

    /// What the main agent waits on by Claude's own word (P510): the background agents (`subagent`) and workflows a
    /// root Stop's `background_tasks` named, as a later SubagentStop's names them again.
    struct Background: Equatable, Sendable {
        var agents: Int
        var workflows: Int
        /// The last sign of the wait: its Stop, a SubagentStop that named it again, any note of the session's subagents.
        var lastSign: Date
        /// Agents a SubagentStop's list no longer names (they finished) whose result is to wake the main agent: they
        /// still count until `finishedUntil` (P374's grace), or until the main agent is at work.
        var finished = 0
        var finishedUntil: Date?

        var quietLimit: TimeInterval { workflows > 0 ? ClaudeSubagentBook.workflowQuietLimit : ClaudeSubagentBook.quietLimit }

        /// When it stops counting by itself (its finished agents' grace ends apart, `finishedUntil`).
        var lapse: Date { lastSign.addingTimeInterval(quietLimit) }

        func wait(now: Date) -> SubagentWait? {
            guard now < lastSign.addingTimeInterval(quietLimit) else { return nil }
            let graced = finishedUntil.map { now < $0 } == true ? finished : 0
            let wait = SubagentWait(agents: agents + graced, workflows: workflows)
            return wait.total > 0 ? wait : nil
        }
    }

    /// By session, then by agent id.
    private(set) var agents: [String: [String: Agent]] = [:]
    /// Sessions whose main agent's own Stop (or StopFailure) note came since it was last at work.
    private(set) var mainStopped: Set<String> = []
    /// Sessions a finished agent's result is to wake, from when that agent stopped: until the main agent is at work
    /// again, or for `quietLimit`.
    private(set) var wakes: [String: Date] = [:]
    /// The main agent's Agent (Task) calls not yet returned, by session: a foreground agent's call returns with its
    /// agent, a background agent's at once.
    private(set) var agentCalls: [String: Set<String>] = [:]
    /// Claude's own word on what each session's main agent waits on, by session (P510).
    private(set) var background: [String: Background] = [:]
    /// Sessions whose last main Stop named its background work by kind (P510): Claude's word, not the book's agents,
    /// is their wait until the main agent is at work again.
    private(set) var claudesWord: Set<String> = []
    /// The main agent's tools that start subagents.
    static let agentTools: Set<String> = ["Agent", "Task"]
    /// `background_tasks` kinds a main agent is woken by and waits on (P510): never a background shell or a monitor.
    static let agentKind = "subagent"
    static let workflowKind = "workflow"

    mutating func start(_ agentID: String, in sessionID: String, at now: Date) {
        agents[sessionID, default: [:]][agentID] = Agent(lastSeen: now)
    }

    /// Any other note of the subagent's own: it is still at work. Only a subagent the book knows, and that has not
    /// stopped.
    mutating func seen(_ agentID: String, in sessionID: String, at now: Date) {
        guard var agent = agents[sessionID]?[agentID], agent.stoppedAt == nil else { return }
        agent.lastSeen = max(agent.lastSeen, now)
        agents[sessionID]?[agentID] = agent
    }

    /// Its SubagentStop. `mainTurnEnded`: the parent's turn had ended, so the agent's result will wake it; the agent
    /// counts until then (`mainTurnStarted`) or for `wakeGrace`. `wakesMain` false: Claude's list says it was no
    /// background agent of the main agent's (a workflow's agent, P515), whose result wakes nothing, so it ends at once.
    mutating func stop(_ agentID: String, in sessionID: String, at now: Date, mainTurnEnded: Bool, wakesMain: Bool = true) {
        if mainTurnEnded, wakesMain, var agent = agents[sessionID]?[agentID] {
            agent.stoppedAt = now
            agents[sessionID]?[agentID] = agent
            wakes[sessionID] = now
        } else {
            remove(agentID, from: sessionID)
        }
    }

    /// The main agent is at work again (the owner's prompt, the turn a finished agent's result woke, its own tool): the
    /// agents that finished are done with.
    mutating func mainTurnStarted(_ sessionID: String) {
        dropStopped(sessionID)
        wakes[sessionID] = nil
        mainStopped.remove(sessionID)
        background[sessionID] = nil
        claudesWord.remove(sessionID)
    }

    /// The main agent's own Stop or StopFailure note: it took in the agents that finished, and its turn has ended.
    /// `nothingInFlight`: Claude's word that no background work runs (`background_tasks: []`). `kinds`: its
    /// `background_tasks` by kind, from a helper that counts them (P510): the agents and workflows in it are what the main
    /// agent waits on now; with none, nothing it waits on runs, whatever the book saw start. nil (an older helper, a
    /// StopFailure) leaves the wait to the book's own agents.
    mutating func mainTurnEnded(_ sessionID: String, nothingInFlight: Bool, kinds: [String: Int]?, at now: Date) {
        if nothingInFlight { agents[sessionID] = nil } else { dropStopped(sessionID) }
        wakes[sessionID] = nil
        agentCalls[sessionID] = nil
        mainStopped.insert(sessionID)
        background[sessionID] = nil
        guard let kinds else {
            claudesWord.remove(sessionID)
            return
        }
        claudesWord.insert(sessionID)
        let waited = Background(agents: kinds[Self.agentKind] ?? 0, workflows: kinds[Self.workflowKind] ?? 0, lastSign: now)
        if waited.agents + waited.workflows > 0 { background[sessionID] = waited } else { agents[sessionID] = nil }
    }

    /// A SubagentStop while the session's main turn has ended (P510): `kinds` is what its list names now, less the
    /// stopping agent itself, and `listed` whether Claude listed that agent as a background agent. Agents it no longer
    /// names finished; their result is to wake the main agent, so they count for the wake grace (P374) and the wake is
    /// awaited (P375). A workflow's agent is never in the list, so its stop changes no count and wakes nothing. With no
    /// wait standing, `kinds` begins one (P515: the app relaunched after the Stop, or a wait was lost), as a Stop's would,
    /// the stopping agent counting for the grace when it was listed. With no `kinds` (an older helper, or a Claude whose
    /// SubagentStop names none), only a wait that stands is kept current: a known agent's stop is a listed agent's while
    /// no workflow runs.
    mutating func backgroundStopped(_ agentID: String, in sessionID: String, kinds: [String: Int]?, listed: Bool?,
                                    knownAgent: Bool, at now: Date) {
        guard var waited = background[sessionID] else {
            guard let kinds else { return }
            claudesWord.insert(sessionID)
            var begun = Background(agents: kinds[Self.agentKind] ?? 0, workflows: kinds[Self.workflowKind] ?? 0, lastSign: now)
            if listed == true {
                begun.finished = 1
                begun.finishedUntil = now.addingTimeInterval(Self.wakeGrace)
                wakes[sessionID] = now
            }
            if begun.agents + begun.workflows + begun.finished > 0 { background[sessionID] = begun }
            return
        }
        let agentsNow: Int
        if let kinds {
            agentsNow = kinds[Self.agentKind] ?? 0
            waited.workflows = kinds[Self.workflowKind] ?? 0
        } else {
            agentsNow = knownAgent && waited.workflows == 0 ? max(0, waited.agents - 1) : waited.agents
        }
        let finished = max(waited.agents - agentsNow, listed == true ? 1 : 0)
        if finished > 0 {
            let graced = waited.finishedUntil.map { now < $0 } == true ? waited.finished : 0
            waited.finished = graced + finished
            waited.finishedUntil = now.addingTimeInterval(Self.wakeGrace)
            wakes[sessionID] = now
        }
        waited.agents = agentsNow
        waited.lastSign = max(waited.lastSign, now)
        background[sessionID] = waited
    }

    /// A note of one of the session's subagents: the wait on Claude's word is alive (P512), and one that lapsed with no
    /// sign (the Mac asleep past its limit) counts again (P515).
    mutating func backgroundSign(in sessionID: String, at now: Date) {
        guard var waited = background[sessionID], waited.lastSign < now else { return }
        waited.lastSign = now
        background[sessionID] = waited
    }

    /// What the session's main agent waits on by Claude's word, if it waits on anything (P510).
    func backgroundWait(in sessionID: String, now: Date) -> SubagentWait? { background[sessionID]?.wait(now: now) }

    /// Whether Claude's own word decides the session's wait (P510): its last Stop named its background work by kind.
    func waitsByClaudesWord(_ sessionID: String) -> Bool { claudesWord.contains(sessionID) }

    /// Whether the main agent's turn has ended by its own Stop note.
    func hasMainStopped(_ sessionID: String) -> Bool { mainStopped.contains(sessionID) }

    /// Whether a finished agent's result is to wake the session's main agent.
    func awaitsWake(_ sessionID: String) -> Bool { wakes[sessionID] != nil }

    /// The main agent called Agent (or Task).
    mutating func agentCallStarted(_ toolUseID: String, in sessionID: String) {
        agentCalls[sessionID, default: []].insert(toolUseID)
    }

    /// A call of the main agent's returned (PostToolUse, PostToolUseFailure, PermissionDenied).
    mutating func callEnded(_ toolUseID: String, in sessionID: String) {
        guard agentCalls[sessionID]?.remove(toolUseID) != nil, agentCalls[sessionID]?.isEmpty == true else { return }
        agentCalls[sessionID] = nil
    }

    /// Whether the main agent waits on one of its Agent calls.
    func hasOpenAgentCall(_ sessionID: String) -> Bool { agentCalls[sessionID] != nil }

    /// Nothing of the session runs any more: its SessionEnd, or its agent's process gone.
    mutating func clear(_ sessionID: String) {
        agents[sessionID] = nil
        wakes[sessionID] = nil
        agentCalls[sessionID] = nil
        background[sessionID] = nil
        claudesWord.remove(sessionID)
    }

    /// How many of the session's subagents count now.
    func count(in sessionID: String, now: Date) -> Int {
        agents[sessionID]?.values.count { Self.counts($0, now: now) } ?? 0
    }

    /// When the next agent, or wait on Claude's word, stops counting by itself (its quiet limit or its wake grace), if
    /// any will.
    func nextLapse(after now: Date) -> Date? {
        let waits = background.values.flatMap { waited in [waited.lapse] + (waited.finishedUntil.map { [$0] } ?? []) }
        return (agents.values.flatMap(\.values).map(Self.lapse) + waits).filter { $0 > now }.min()
    }

    /// Drops the agents that no longer count, the finished agents' grace once it ran out and waits on Claude's word
    /// with nothing left in them, and wakes older than `quietLimit`. A wait that lapsed with no sign is kept, counting
    /// nothing, for a later sign to bring back (P515); the main agent's next turn, a Stop or the session's end drops it.
    mutating func prune(now: Date) {
        for (sessionID, known) in agents {
            let left = known.filter { Self.counts($0.value, now: now) }
            if left.count != known.count { agents[sessionID] = left.isEmpty ? nil : left }
        }
        for (sessionID, var waited) in background {
            if let until = waited.finishedUntil, until <= now {
                waited.finished = 0
                waited.finishedUntil = nil
            }
            if waited.agents + waited.workflows + waited.finished == 0 {
                background[sessionID] = nil
            } else if waited != background[sessionID] {
                background[sessionID] = waited
            }
        }
        let wakes = wakes.filter { now < $0.value.addingTimeInterval(Self.quietLimit) }
        if wakes.count != self.wakes.count { self.wakes = wakes }
    }

    mutating func forget(_ sessionID: String) {
        clear(sessionID)
        mainStopped.remove(sessionID)
    }

    var sessionIDs: Set<String> {
        Set(agents.keys).union(mainStopped).union(wakes.keys).union(agentCalls.keys).union(background.keys).union(claudesWord)
    }

    /// Whether the book saw this agent start and it has not stopped.
    func knows(_ agentID: String, in sessionID: String) -> Bool { agents[sessionID]?[agentID].map { $0.stoppedAt == nil } ?? false }

    private static func counts(_ agent: Agent, now: Date) -> Bool { now < lapse(agent) }

    private static func lapse(_ agent: Agent) -> Date {
        agent.stoppedAt.map { $0.addingTimeInterval(wakeGrace) } ?? agent.lastSeen.addingTimeInterval(quietLimit)
    }

    private mutating func dropStopped(_ sessionID: String) {
        guard let known = agents[sessionID] else { return }
        let left = known.filter { $0.value.stoppedAt == nil }
        if left.count != known.count { agents[sessionID] = left.isEmpty ? nil : left }
    }

    private mutating func remove(_ agentID: String, from sessionID: String) {
        agents[sessionID]?[agentID] = nil
        if agents[sessionID]?.isEmpty == true { agents[sessionID] = nil }
    }
}
