import Foundation
import IslandHookNotes
import OpenIslandCore

/// A Claude session whose main turn has ended while background work it started still runs (P370-P372, P510): it is
/// not done. Its row says "Waiting on 1 agent" (or "Waiting on 1 workflow", "Waiting on 2 agents · 1 workflow") in the
/// delegate teal, sorts and counts with the running ones, and its Stop gives no Done; the Stop of the turn their results
/// wake is the one Done. Only the main agent's own turn end notifies. A Codex chat whose own turn ended while its
/// subagents run waits the same way (P513).
extension SessionEngine {
    /// What a session's main agent waits on once its own turn has ended (not failed, not the session's end): a Claude
    /// session's background agents and workflows (`claudeWaits`: Claude's own `background_tasks`, P510, or with an older
    /// helper the subagents the book saw start, P370), a Codex chat's running subagents (P513). nil when nothing.
    public func waitingOn(_ session: AgentSession) -> SubagentWait? {
        guard session.phase == .completed, !session.isSessionEnded, !hasFailedTurn(session) else { return nil }
        if session.tool == .codex {
            let running = runningSubagents(for: session.id)
            return running > 0 ? SubagentWait(agents: running) : nil
        }
        return claudeWaits[session.id]
    }

    /// How many things a session's main agent waits on once its own turn has ended (`waitingOn`): 0 when nothing.
    public func waitingSubagents(for session: AgentSession) -> Int { waitingOn(session)?.total ?? 0 }

    /// How many subagents a Claude main agent blocked on its Agent calls waits on (P377): its turn runs, it runs no tool
    /// of its own but those calls (its current tool is Agent or Task, or none while one of its Agent calls is still
    /// out), and subagents it started run. 0 otherwise. Unlike `waitingSubagents`, this holds no Done back: the turn
    /// runs, and its Stop is its Done as always.
    func blockedOnSubagents(for session: AgentSession) -> Int {
        guard session.tool != .codex, session.phase == .running, !session.isSessionEnded,
              let count = claudeSubagentCounts[session.id], count > 0 else { return 0 }
        let onAgents = session.currentToolName.map(ClaudeSubagentBook.agentTools.contains)
            ?? claudeSubagents.hasOpenAgentCall(session.id)
        return onAgents ? count : 0
    }

    /// The session's main agent waits on its subagents: a Claude session's (`waitingOn`, or `blockedOnSubagents`) or a
    /// Codex chat's (its turn waits on its running subagents, P212, P378, or ended while they run, P513). Its status word
    /// is `.subagents`; its glyph the delegate's.
    public func isDelegating(_ session: AgentSession) -> Bool {
        if case .subagents = statusWord(for: session) { return true }
        return false
    }

    /// What a context note says of a Claude session's subagents (note version 2 carries `agent_id`). A Codex hook's
    /// note says nothing here: a Codex chat's subagents are its thread book's (P212).
    func noteClaudeSubagents(_ note: HookContextNote, now: Date) {
        guard note.version >= 2, Self.claudeFormatSources.contains(note.agentSource ?? "claude") else { return }
        let sessionID = note.sessionID
        // Any note of a subagent's own is a sign the wait on Claude's word is alive (a workflow's agents at work, P512).
        if note.agentID != nil { claudeSubagents.backgroundSign(in: sessionID, at: now) }
        switch (note.event, note.agentID) {
        case let ("SubagentStart", agentID?):
            claudeSubagents.start(agentID, in: sessionID, at: now)
        case let ("SubagentStop", agentID?):
            // The main turn has ended by the bridge's Stop, or already by the main agent's own Stop note, which the
            // bridge's Stop follows (P376): the agent's result will wake it.
            let ended = (state.session(id: sessionID).map { $0.phase == .completed } ?? false)
                || claudeSubagents.hasMainStopped(sessionID)
            // Claude's list, less this agent, is what the main agent waits on now (P510), and begins the wait again when
            // none stands (P515); a workflow's agent is never in it, so its stop wakes nothing and changes no count.
            if ended {
                claudeSubagents.backgroundStopped(agentID, in: sessionID, kinds: note.backgroundTaskKinds,
                                                  listed: note.agentInBackground,
                                                  knownAgent: claudeSubagents.knows(agentID, in: sessionID), at: now)
            }
            claudeSubagents.stop(agentID, in: sessionID, at: now, mainTurnEnded: ended, wakesMain: note.agentInBackground != false)
        case let (_, agentID?):
            claudeSubagents.seen(agentID, in: sessionID, at: now)
        case ("SessionEnd", nil):
            claudeSubagents.forget(sessionID)
        case ("Stop", nil), ("StopFailure", nil):
            // A Stop of the main agent's while its row reads done, waiting on its agents or on a finished one's result,
            // ends a turn that result (or a teammate's message) woke, which no prompt hook or tool showed start: its
            // turn, so the bridge's Stop that follows is its Done (P375).
            if note.event == "Stop", let session = state.session(id: sessionID), session.phase == .completed,
               !session.isSessionEnded, claudeSubagents.awaitsWake(sessionID) || waitingSubagents(for: session) > 0 {
                signals.wokenTurnEnded(sessionID)
            }
            // The main agent took in the agents that finished, so that turn's Stop is never held back by them (P374);
            // with Claude's own word that nothing is in flight (`background_tasks: []`), a SubagentStop that never came
            // leaves nothing behind. A helper that counts that list by kind makes its agents and workflows the wait, and
            // anything else in it (a background shell, a monitor) nothing (P510).
            let stop = note.event == "Stop"
            claudeSubagents.mainTurnEnded(sessionID, nothingInFlight: stop && note.backgroundTaskCount == 0,
                                          kinds: stop ? note.backgroundTaskKinds : nil, at: now)
        case ("UserPromptSubmit", nil):
            // The main agent at work again: the agents that finished were taken in.
            claudeSubagents.mainTurnStarted(sessionID)
        case ("PreToolUse", nil):
            // Woken with or without a prompt hook (P374); an Agent call is one it may wait on (P377).
            claudeSubagents.mainTurnStarted(sessionID)
            if let tool = note.toolName, ClaudeSubagentBook.agentTools.contains(tool), let call = note.toolUseID {
                claudeSubagents.agentCallStarted(call, in: sessionID)
            }
        case ("PostToolUse", nil), ("PostToolUseFailure", nil), ("PermissionDenied", nil):
            guard let call = note.toolUseID, claudeSubagents.hasOpenAgentCall(sessionID) else { return }
            claudeSubagents.callEnded(call, in: sessionID)
        default:
            return
        }
        syncClaudeSubagents(now: now)
    }

    /// The bridge's word on a Claude session: a new turn of its main agent, or its end.
    func noteClaudeSubagents(_ event: AgentEvent, sessionID: String, ingress: TrackedEventIngress, before: AgentSession?, now: Date) {
        guard ingress == .bridge,
              claudeSubagents.sessionIDs.contains(sessionID) || claudeSubagentCounts[sessionID] != nil || claudeWaits[sessionID] != nil
        else { return }
        if SignalPipeline.isNewPrompt(event, ingress: ingress, before: before) {
            claudeSubagents.mainTurnStarted(sessionID)
        } else if case let .sessionCompleted(payload) = event, payload.isSessionEnd == true {
            claudeSubagents.forget(sessionID)
        } else {
            return
        }
        syncClaudeSubagents(now: now)
    }

    /// A subagent's start is never its parent's own activity once the parent's turn has ended (P371): upstream's bridge
    /// turns every SubagentStart into running activity on the parent ("Started <type> subagent."), so a subagent a
    /// background agent or a workflow starts would wake the finished row as if the main agent worked. Each SubagentStart
    /// note, sent just before its hook reaches the bridge, stands for one such echo, however many notes of other agents
    /// come between (a workflow's agents run side by side, P511): every echo takes one, applied or not, and one that
    /// finds its note while the parent's turn has ended is not applied.
    ///
    /// Upstream echoes a SubagentStop too (the agent's reply as running activity) while its own copy of the parent reads
    /// running, as it does after a SubagentStart echo the engine refused until the engine's state reaches it again
    /// (P516). On a finished parent, a running activity that is not the main agent's own (a prompt, a tool, a compaction)
    /// takes a SubagentStop note of the last 10 s and is not applied either. A refused echo sends the engine's state back
    /// to the bridge at once, so its copy reads done again and its next SubagentStop is no echo at all.
    func isSubagentLifecycleEcho(_ event: AgentEvent, sessionID: String, ingress: TrackedEventIngress, current: AgentSession?,
                                 now: Date) -> Bool {
        guard ingress == .bridge, case let .activityUpdated(payload) = event, payload.phase == .running,
              let current, current.tool != .codex else { return false }
        let finished = current.phase == .completed && !current.isSessionEnded
        let echo: Bool
        if Self.isSubagentStartSummary(payload.summary) {
            echo = hookNotes.takeSubagentStart(sessionID, now: now) && finished
        } else {
            echo = finished && !Self.isMainAgentActivity(payload.summary) && hookNotes.takeSubagentStop(sessionID, now: now)
        }
        if echo { bridgeServer?.updateStateSnapshot(state) }
        return echo
    }

    /// The bridge's summary for a SubagentStart (`BridgeServer.swift` `case .subagentStart`): "Started <type> subagent.".
    static func isSubagentStartSummary(_ summary: String) -> Bool {
        summary.hasPrefix("Started ") && summary.hasSuffix(" subagent.")
    }

    /// The bridge's running summaries for the main agent's own work (`BridgeServer.swift`): its prompt ("Prompt: …", or
    /// "… received a new prompt in …" with none), its tool ("Running <tool>…"), its compaction.
    static func isMainAgentActivity(_ summary: String) -> Bool {
        summary.hasPrefix(SignalPipeline.promptPrefix) || summary.hasPrefix("Running ")
            || summary.contains(" received a new prompt in ") || summary.hasSuffix(" is compacting the conversation.")
    }

    /// The counts the lists read, written only when one changes (a subagent's every tool note refreshes the book, never
    /// the lists), and a check for the next agent to lapse. A session that waits now holds no Done: one held from its
    /// Stop (a SubagentStart that landed after it) is dropped here, before its hold passes, so its key is never spent
    /// and the wake-up's Stop can still give it (P375).
    func syncClaudeSubagents(now: Date) {
        claudeSubagents.prune(now: now)
        var counts: [String: Int] = [:]
        var waits: [String: SubagentWait] = [:]
        for sessionID in claudeSubagents.sessionIDs {
            let count = claudeSubagents.count(in: sessionID, now: now)
            if count > 0 { counts[sessionID] = count }
            // Claude's own word when its helper gave it (P510), else the agents the book saw start.
            if claudeSubagents.waitsByClaudesWord(sessionID) {
                if let wait = claudeSubagents.backgroundWait(in: sessionID, now: now) { waits[sessionID] = wait }
            } else if count > 0 {
                waits[sessionID] = SubagentWait(agents: count)
            }
        }
        if counts != claudeSubagentCounts { claudeSubagentCounts = counts }
        if waits != claudeWaits { claudeWaits = waits }
        for sessionID in waits.keys where signals.dueAt(for: sessionID) != nil {
            if let session = state.session(id: sessionID), waitingSubagents(for: session) > 0 { signals.dropHeld(sessionID) }
        }
        scheduleClaudeSubagentLapse(claudeSubagents.nextLapse(after: now), now: now)
    }

    /// One check at the next lapse (a quiet limit or a wake grace): nothing runs while no subagent is known.
    private func scheduleClaudeSubagentLapse(_ due: Date?, now: Date) {
        guard let due, pendingClaudeSubagentChecks.allSatisfy({ $0 > due }) else { return }
        pendingClaudeSubagentChecks.insert(due)
        // A second past it, as a Codex subagent's lapse (P218): an agent counts up to its lapse itself.
        dependencies.scheduleSubagentCheck(max(0, due.timeIntervalSince(now)) + 1) { [weak self] in
            guard let self else { return }
            self.pendingClaudeSubagentChecks.remove(due)
            self.syncClaudeSubagents(now: self.dependencies.now())
        }
    }

    /// The process monitor's pass: a session whose agent's pid (its notes') is gone waits on nothing, as its subagents
    /// went with it (a crash sends no SessionEnd, C11).
    func endWaitsOfGoneAgents() {
        let exists = dependencies.processExists
        var changed = false
        for sessionID in Set(claudeSubagentCounts.keys).union(claudeWaits.keys) {
            guard let pid = hookNotes.contexts[sessionID]?.agentPID, pid > 1, !exists(pid) else { continue }
            claudeSubagents.forget(sessionID)
            changed = true
        }
        if changed { syncClaudeSubagents(now: dependencies.now()) }
    }

    /// A session left the state, or the owner archived it.
    func forgetClaudeSubagents(_ sessionID: String) {
        claudeSubagents.forget(sessionID)
        if claudeSubagentCounts[sessionID] != nil { claudeSubagentCounts[sessionID] = nil }
        if claudeWaits[sessionID] != nil { claudeWaits[sessionID] = nil }
    }
}
