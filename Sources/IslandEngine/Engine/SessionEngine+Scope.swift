import Foundation
import IslandHookNotes
import OpenIslandCore

/// Who started each session (`SessionScope`, P250-P257): only the owner's own top-level sessions tell of a finished
/// turn, and scripted runs leave the lists unless Settings › Island › Show scripted runs.
extension SessionEngine {
    /// A Claude subagent's transcript is a child; then what a context note or a rollout said; a Codex session its hooks
    /// report with no transcript is an ephemeral thread, which no one opens: the codex plugin's tasks, a
    /// `codex exec --ephemeral` (openai/codex `hook_transcript_path` is nil only without a rollout). Anything else is
    /// the owner's.
    public func scope(of session: AgentSession) -> SessionScope {
        if session.isSubagentSession { return .subagent }
        if let known = scopes[session.id] { return known }
        if session.tool == .codex, signals.hookedSessions.contains(session.id), (session.codexMetadata?.transcriptPath ?? "").isEmpty {
            return .scripted
        }
        return .owner
    }

    /// Whether a finished or failed turn of this session may reach the owner (the Done card, the Done sound, Turn
    /// failed): the owner's own sessions only. One gone from the state keeps what it was known as.
    func notifiesOfTurnEnd(_ sessionID: String) -> Bool {
        guard let session = state.session(id: sessionID) else { return scopes[sessionID] == nil }
        return scope(of: session) == .owner
    }

    /// A context note's word on who runs the session. A Claude root note: its `CLAUDE_CODE_ENTRYPOINT` (note v2); the
    /// latest wins, and a note with none says nothing. A Codex root note (upstream's installer gives Codex's helper no
    /// `--source`): only whether it ran outside Claude (`CodexHand`, P257), which weighs the rollout's verdict. A
    /// subagent's note speaks for the subagent.
    func noteScope(from note: HookContextNote) {
        guard note.agentID == nil else { return }
        if note.source == "claude" {
            if let scope = SessionScopeRules.claude(entrypoint: note.entrypoint) { setScope(scope, for: note.sessionID) }
            return
        }
        guard note.source == nil || note.source == "codex", (note.entrypoint ?? "").isEmpty else { return }
        let hand: CodexHand = note.event == "SessionStart" && note.sessionStartSource == "resume" ? .resumedOutsideClaude : .outsideClaude
        if let known = codexHands[note.sessionID], known >= hand { return }
        codexHands[note.sessionID] = hand
        if let state = codexAttention[note.sessionID] { noteRolloutScope(state, for: note.sessionID) }
    }

    /// A Codex rollout's first `session_meta` (read by the tracker beside the fold): a child thread, a scripted run or
    /// the owner's, as the thread's hooks weigh it. A review's thread that is a row of its own stands for the owner's
    /// chat, whose rollout Codex writes only when the review ends (P217): its Done is the owner's. Once its chat is a
    /// row, it is folded into it and is no session at all.
    func noteRolloutScope(_ state: CodexAttention, for sessionID: String) {
        guard let rollout = state.scope else { return }
        if state.threadKind?.review != nil, !codexThreads.isHidden(sessionID) {
            setScope(.owner, for: sessionID)
            return
        }
        setScope(SessionScopeRules.codex(rollout, originator: state.scopeOriginator, hand: codexHands[sessionID]), for: sessionID)
    }

    /// The owner went on with the session from its folded card (`SessionResumer`): it is theirs from now on, whatever
    /// the run's notes say of their entrypoint (`claude -p` says `sdk-cli`), and a scripted verdict it had before is
    /// dropped, as they chose to reply (P1327). While the run lasts, its approvals are held for the island (P1328).
    func islandRunStarted(_ sessionID: String) {
        islandResumes.start(sessionID)
        if scopes[sessionID] == .scripted { setScope(.owner, for: sessionID) }
    }

    /// The run's process exited: a reply the card held for it gets its check now (P1306), since a process's end is no
    /// event of the state's and a long run outlasts the held reply's own looks.
    /// `heldElsewhere`: Codex refused it, as another process still writes the thread (P1440).
    func islandRunEnded(_ sessionID: String, heldElsewhere: Bool = false) {
        islandResumes.end(sessionID)
        if heldElsewhere { foldResumeHeld(sessionID) }
        foldsFollowState()
    }

    /// Only a change is written: the lists observe `scopes`. A session the owner went on with from the island is never
    /// a scripted run again (P1327); a child stays a child.
    private func setScope(_ scope: SessionScope, for sessionID: String) {
        let scope = scope == .scripted && islandResumes.wasResumed(sessionID) ? .owner : scope
        let stored: SessionScope? = scope == .owner ? nil : scope
        guard scopes[sessionID] != stored else { return }
        scopes[sessionID] = stored
    }
}
