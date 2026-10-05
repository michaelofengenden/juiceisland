import Foundation
import IslandHookNotes
import OpenIslandCore

/// The context notes in the engine (spec §3.4, §3.8): the second socket, the exact jump handles laid over upstream's
/// jump targets, and StopFailure, which only the note's raw event name can tell from a Stop.
extension SessionEngine {
    static let stopFailureEvent = "StopFailure"

    // MARK: The second socket

    /// Starts receiving notes, with the bridge (live mode only). A failure leaves everything else running: jumps use
    /// upstream's handles and a StopFailure stays a Done, as before the notes.
    func startHookNotes() {
        guard hookNoteListener == nil, let url = configuration.hookNotesSocketURL else { return }
        let start = dependencies.startHookNotes ?? Self.startHookNoteListener
        do {
            hookNoteListener = try start(url) { [weak self] note in
                Task { @MainActor [weak self] in self?.ingest(note: note) }
            }
            hookNotesProblem = nil
        } catch {
            hookNotesProblem = error.localizedDescription
        }
    }

    func stopHookNotes() {
        hookNoteListener?.stop()
        hookNoteListener = nil
    }

    nonisolated static func startHookNoteListener(at url: URL,
                                                  handler: @escaping @Sendable (HookContextNote) -> Void) throws -> any HookNoteReceiving {
        let listener = HookNoteListener(url: url, handler: handler)
        try listener.start()
        return listener
    }

    // MARK: Notes

    /// Merges one note. A StopFailure marks its turn failed once the bridge's completion for it is in, whichever of
    /// the two arrives first.
    func ingest(note: HookContextNote) {
        guard ignoredSessionIDs[note.sessionID] == nil else { return }
        let now = dependencies.now()
        let turnBegins = Self.beginsUnpromptedTurn(note, lastEvent: hookNotes.contexts[note.sessionID]?.lastEvent)
        hookNotes.record(note, at: now)
        // A fork (`/branch`) goes on in the same process under a new id; its parent is left there with no SessionEnd (P441).
        if note.event == "SessionStart", note.sessionStartSource == Self.forkSource, note.agentID == nil, let pid = note.agentPID {
            noteForkStart(note.sessionID, pid: pid)
        }
        toolFlights.record(note, at: now)
        noteScope(from: note)
        attentionEvidence(note: note, now: now)
        noteAgentLabel(note)
        if turnBegins {
            promptedSessionIDs.insert(note.sessionID)
            signals.turnBegan(note.sessionID)
        }
        if note.agentID == nil { keepLabels(note.sessionID) }
        noteClaudeSubagents(note, now: now)
        noteCodexWake(note, now: now)
        guard note.event == Self.stopFailureEvent else { return }
        if let session = state.session(id: note.sessionID), session.phase == .completed,
           hookNotes.completedRecently(note.sessionID, now: now) {
            markTurnFailed(note.sessionID)
        } else {
            hookNotes.notePendingFailure(note.sessionID, at: now)
        }
    }

    /// Called by `ingest(_:ingress:)` for every event it applied: a new prompt ends a failed turn, and a Stop from
    /// the bridge that a StopFailure note announced is that failure.
    func noteAppliedForHookNotes(_ event: AgentEvent, sessionID: String, ingress: TrackedEventIngress,
                                 before: AgentSession?, now: Date) {
        if SignalPipeline.isNewPrompt(event, ingress: ingress, before: before) {
            failedTurns[sessionID] = nil
            if turnLimits[sessionID] != nil { turnLimits[sessionID] = nil }
            hookNotes.clearPendingFailure(sessionID)
        }
        guard ingress == .bridge else { return }
        if case let .sessionCompleted(payload) = event,
           SignalPipeline.completion(payload, tool: state.session(id: sessionID)?.tool, ingress: ingress) == .stop,
           hookNotes.noteCompletion(sessionID, at: now) {
            markTurnFailed(sessionID)
            return
        }
        // Any later activity of the session ends a failed turn, not only a new prompt: Claude may carry on by itself
        // and end normally, and the failure must not come back with that Stop (P159). A Notification's echo is not
        // activity: `idle_prompt` a minute later, or a usage-limit notice, leaves the turn failed (P181).
        switch event {
        case .activityUpdated where isNotificationEcho(sessionID, now: now):
            break
        case .activityUpdated, .sessionCompleted, .sessionStarted:
            if failedTurns[sessionID] != nil { failedTurns[sessionID] = nil }
            // The session works again: its limit no longer says why it stopped (P702).
            if turnLimits[sessionID] != nil { turnLimits[sessionID] = nil }
        default:
            break
        }
    }

    /// Upstream's bridge echoes every Claude Notification as activity carrying its own current phase
    /// (`BridgeServer.swift` `handleClaudeHook`); the prelude sends the Notification's note first, so an activity whose
    /// session's last note, just now, was a Notification is that echo.
    func isNotificationEcho(_ sessionID: String, now: Date) -> Bool {
        guard let context = hookNotes.contexts[sessionID], context.lastEvent == "Notification" else { return false }
        return now.timeIntervalSince(context.updatedAt) <= HookNoteBook.failureWindow
    }

    /// P4 from M5: the turn failed. It needs you at once ("Turn failed"), drops the held Done, and counts as
    /// attention everywhere until a new prompt, a dismiss or a jump to that session.
    func markTurnFailed(_ sessionID: String) {
        guard let session = state.session(id: sessionID), session.phase == .completed, !session.isSessionEnded,
              !session.isSubagentSession else { return }
        let turn = signals.turn(for: sessionID)
        // Read once, now: the CLI's "resets 3pm" counts from when it failed (P701).
        let limit = LimitText.claude(error: session.summary, message: session.claudeMetadata?.lastAssistantMessage, at: dependencies.now())
        if turnLimits[sessionID] != limit { turnLimits[sessionID] = limit }
        failedTurns[sessionID] = turn
        if let alert = signals.turnFailed(sessionID: sessionID, turn: turn) { deliver(alert) }
    }

    /// The owner opened or dismissed the session: its failed turn no longer needs them.
    func clearTurnFailure(_ sessionID: String) {
        if failedTurns[sessionID] != nil { failedTurns[sessionID] = nil }
    }

    /// A tombstoned session expired: its context, its waiting StopFailure, its last Stop and its failed turn go too,
    /// so nothing of it builds up over a long run.
    func forgetHookNotes(_ sessionID: String) {
        hookNotes.forget(sessionID)
        if agentLabels[sessionID] != nil { agentLabels[sessionID] = nil }
        toolFlights.forget(sessionID)
        clearTurnFailure(sessionID)
        if turnLimits[sessionID] != nil { turnLimits[sessionID] = nil }
    }

    // MARK: Agents (P913)

    /// The note names the session's real agent: Copilot and Devin, whose hooks the bridge files under a Claude-format
    /// fork's tool, and an agent behind Claude's hooks (`HookCaller`). Claude's and Codex's own words say nothing more
    /// than their tool does.
    func noteAgentLabel(_ note: HookContextNote) {
        guard note.agentID == nil, let kind = AgentKind(source: note.agentSource), kind != .claude, kind != .codex,
              agentLabels[note.sessionID] != kind else { return }
        agentLabels[note.sessionID] = kind
    }

    /// The session's own agent: a label its notes gave (kept across a relaunch with its other labels), Kilo by its session
    /// id, else its tool. A label is taken only where it fits the session's tool (its own carrier, or the Claude-format
    /// fork's the helper files other agents under), so no note ever turns a Claude Code or Codex session into another.
    public func agent(of session: AgentSession) -> AgentKind {
        let label = agentLabels[session.id] ?? labelBook.labels(for: session.id)?.agent.flatMap(AgentKind.init(rawValue:))
        if let label, label.carrierTool == session.tool || session.tool == .codebuddy { return label }
        if session.tool == .openCode, let kind = AgentKind.fromSessionID(session.id) { return kind }
        return AgentKind(tool: session.tool)
    }

    /// Antigravity CLI's hooks carry no prompt (P1107): its first model call since its last Stop (or its first ever)
    /// begins the owner's turn, as a prompt would. The session then shows (P155), and the turn is counted, so each
    /// turn's Done is its own (P5). Read from its notes alone, which come in the order agy runs its hooks.
    static func beginsUnpromptedTurn(_ note: HookContextNote, lastEvent: String?) -> Bool {
        guard note.agentID == nil, note.agentSource == AgentKind.antigravity.rawValue,
              note.event == AntigravityHooks.Event.preInvocation.rawValue else { return false }
        return lastEvent == nil || lastEvent == AntigravityHooks.Event.stop.rawValue
    }

    // MARK: Reading

    /// Whether the session's current turn ended in a StopFailure (spec §3.4). A normal Stop never is one.
    ///
    /// A turn that failed on the account's usage limit no longer needs the owner once that limit's reset has passed
    /// (P702): the limit lifted, and the session waits at its prompt as any finished one does. Read at every mapping,
    /// which the minute clock repeats, so no timer of its own.
    public func hasFailedTurn(_ session: AgentSession) -> Bool {
        guard let turn = failedTurns[session.id] else { return false }
        guard turn == signals.turn(for: session.id), session.phase == .completed, !session.isSessionEnded else { return false }
        return turnLimits[session.id]?.hasReset(at: dependencies.now()) != true
    }

    /// Why the session's last turn stopped, when that was a limit or an API error (P700): a Claude turn that failed on one
    /// (kept from its failure until the session works again, a dismiss or an open included, so the row still says why),
    /// or a Codex turn whose rollout says so. nil while the session runs.
    public func limit(for session: AgentSession) -> SessionLimit? {
        guard session.phase == .completed else { return nil }
        if let limit = turnLimits[session.id] { return limit }
        return session.tool == .codex ? codexAttention[session.id]?.limit : nil
    }

    /// Has a confirmed request (an approval, a plan, a question) or its turn failed: what every count, ranking, jump
    /// target and the survival rule treat as needing the owner. A phase alone never does (P161).
    public func needsAttention(_ session: AgentSession) -> Bool {
        attention.head(of: session.id) != nil || hasFailedTurn(session)
    }

    /// What the notes have told the engine about the session; nil before its first note.
    public func hookContext(for sessionID: String) -> HookContext? { hookNotes.contexts[sessionID] }

    // MARK: Jump targets

    /// The session's jump target with the notes' exact handles laid over upstream's: iTerm's session UUID from the
    /// hook's own environment (P17), the tty found from the agent's pid (P18), the tmux pane. Upstream's own target
    /// is left as it is in `state`, so its reducer never fights the overlay.
    func effectiveJumpTarget(for session: AgentSession) -> JumpTarget? {
        guard let context = hookNotes.contexts[session.id] else { return session.jumpTarget }
        // Notes that name neither the host nor a tmux pane give nothing to jump to: still "no target".
        if session.jumpTarget == nil, context.hostBundleID == nil, context.tmuxPane == nil || context.tmuxSocketPath == nil {
            return nil
        }
        let workingDirectory = session.jumpTarget?.workingDirectory
        var target = session.jumpTarget ?? JumpTarget(
            terminalApp: context.hostBundleID.map(JumpHosts.name(forBundleID:)) ?? "Unknown",
            workspaceName: workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? session.title,
            paneTitle: session.title, workingDirectory: workingDirectory)
        if let pane = context.tmuxPane, let socket = context.tmuxSocketPath {
            target.tmuxTarget = pane
            target.tmuxSocketPath = socket
            return target
        }
        let isITerm = context.hostBundleID.map { $0 == ExactJump.itermBundleID }
            ?? (JumpHosts.bundleIdentifier(forTerminalApp: target.terminalApp) == ExactJump.itermBundleID)
        if isITerm, let uuid = context.itermSessionID { target.terminalSessionID = uuid }
        if let pid = context.agentPID, let tty = dependencies.ttyForPID(pid) { target.terminalTTY = tty }
        return target
    }

    func jumpContext(for sessionID: String) -> JumpContext? { hookNotes.contexts[sessionID]?.jumpContext }

    /// The session as the frontmost check should see it: with the exact handles, so a background split or pane is
    /// not taken for the tab in front (P17).
    func withEffectiveJumpTarget(_ session: AgentSession) -> AgentSession {
        guard hookNotes.contexts[session.id] != nil else { return session }
        var copy = session
        copy.jumpTarget = effectiveJumpTarget(for: session)
        return copy
    }
}
