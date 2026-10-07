import Foundation
import OpenIslandCore

/// Codex's shared background service (P1485 to P1509). Codex 0.158 runs an interactive `codex` inside its app-server
/// daemon unless it was started with `--no-daemon`: the thread, its turns, its tools and its hooks run there, and the
/// terminal only shows a client. So a Codex session's hooks name the daemon's pid, and their terminal variables are those
/// the daemon was started with (the first client's tab), not this session's. Its window can close while the daemon goes
/// on with the turn.
extension SessionEngine {
    /// How long a pid's answer is kept: a pid the system gives another program later is asked again (P1485).
    nonisolated static let codexServerAnswerLife: TimeInterval = 60

    /// The pid is a Codex app-server's (the shared daemon, or the Codex app's or an editor's own): never a tab's agent,
    /// whatever terminal its parent holds (P1485). Asked once a minute at most per pid.
    func agentIsCodexServer(_ pid: Int32) -> Bool {
        let now = dependencies.now()
        if let known = codexServerAnswers[pid], now.timeIntervalSince(known.at) < Self.codexServerAnswerLife { return known.server }
        let server = dependencies.isCodexServer(pid)
        if codexServerAnswers.count > 64 {
            codexServerAnswers = codexServerAnswers.filter { now.timeIntervalSince($0.value.at) < Self.codexServerAnswerLife }
        }
        codexServerAnswers[pid] = (server, now)
        return server
    }

    /// A Codex CLI session whose notes' agent is a Codex app-server: the shared daemon runs it (P1486). Its tab is not
    /// known (the notes' handles are the daemon's), so it folds with no tuck, and a reply goes to the daemon's thread.
    public func runsInCodexService(_ sessionID: String) -> Bool {
        guard let session = state.session(id: sessionID) ?? folds[sessionID]?.session, session.tool == .codex,
              !session.isCodexAppSession, let pid = hookNotes.contexts[sessionID]?.agentPID else { return false }
        return agentIsCodexServer(pid)
    }

    /// The notes' agent of `sessionID` is a Codex app-server: its terminal handles are not the session's (P1486).
    func notesNameACodexServer(_ sessionID: String) -> Bool {
        hookNotes.contexts[sessionID]?.agentPID.map(agentIsCodexServer) ?? false
    }
}

extension SessionEngine {
    /// A reply or a Continue that met a turn Codex's background service still runs (P1488): nothing ran. The reply
    /// waits for that turn's end and then goes there, as a reply typed mid-turn waits (P1306); Continue's own words are
    /// not kept, since the turn they would carry on goes on there.
    func holdForService(_ sessionID: String, _ line: String) {
        guard let fold = folds[sessionID] else { return }
        folds[sessionID]?.send = nil
        if line == Self.continuePrompt {
            folds[sessionID]?.stopped = nil
            folds[sessionID]?.continuedFrom = nil
            noteFold(sessionID, .serviceFinishing)
            return
        }
        folds[sessionID]?.held = fold.held.map { $0 + " " + line } ?? line
        folds[sessionID]?.heldWay = .daemon
        noteFold(sessionID, .held(.daemon))
        scheduleHeldCheck(sessionID)
    }

    /// Codex's background service answered about a session's thread (`SessionResumer`), asked at `askedAt`: a folded card
    /// follows it. Its word that no turn runs ends the fold's own turn begun before it was asked (a Stop lost, or a turn
    /// whose hooks never reached the island), and a held reply gets its check (P1487). The log says each change.
    func serviceAnswered(_ sessionID: String, _ status: CodexDaemonStatus, changed: Bool, askedAt: Date) {
        guard let fold = folds[sessionID] else { return }
        if changed { noteFold(sessionID, .service(status)) }
        if status.holds, !status.turnRuns, fold.turnOpen, (fold.turnOpenedAt ?? .distantPast) <= askedAt,
           foldReach(sessionID).way == .daemon {
            folds[sessionID]?.turnOpen = false
        }
        // It goes on there: no longer stopped.
        if status.turnRuns, fold.stopped != nil { folds[sessionID]?.stopped = nil }
        foldsFollowState()
    }

    /// The events after which the service is asked again: a session's start, a prompt, a turn's end.
    nonisolated static func asksCodexService(_ event: AgentEvent, ingress: TrackedEventIngress, before: AgentSession?) -> Bool {
        switch event {
        case .sessionStarted, .sessionCompleted: true
        default: SignalPipeline.isNewPrompt(event, ingress: ingress, before: before)
        }
    }

    /// Asks Codex's background service again about a session it runs, off the main thread: as its notes start a session
    /// or a turn ends, so Send to island and a folded card know whether it holds the thread (P1487).
    func lookAtCodexService(_ sessionID: String) {
        guard let resume = conversationResume, runsInCodexService(sessionID) else { return }
        Task { await resume.lookAgain(sessionID) }
    }
}
