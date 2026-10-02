import Foundation
import OpenIslandCore

/// Where a Codex app thread's jump goes (P660). The Codex app, now the ChatGPT app, runs its app-server with neither
/// `__CFBundleIdentifier` nor `TERM_PROGRAM` in its environment, so upstream's hook names its host "Unknown" and gives
/// the thread no link, and a later hook's target replaces the Codex.app one the rescan gave it; upstream's jump then
/// opened the thread's folder in Finder. Here the jump takes the Codex app whenever the evidence says the thread is the
/// app's, and upstream's target only when a terminal, an IDE or another app is named.
extension SessionEngine {
    enum CodexAppJump: Equatable {
        /// The thread by its link (`codex://threads/<id>`).
        case thread(String)
        /// The app only: the thread's originator is one the island does not know, so its thread may not be the app's own.
        case app

        var threadID: String? {
            if case let .thread(id) = self { return id }
            return nil
        }
    }

    /// The target a jump uses: the notes' overlay (`effectiveJumpTarget`), or the Codex app for a Codex app thread.
    func jumpTarget(for session: AgentSession) -> JumpTarget? {
        let base = effectiveJumpTarget(for: session)
        guard let app = codexAppJump(for: session, base: base) else { return base }
        let folder = base?.workingDirectory ?? session.jumpTarget?.workingDirectory
        return JumpTarget(terminalApp: JumpHosts.name(forBundleID: ExactJump.codexBundleID),
                          workspaceName: base?.workspaceName ?? folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? session.title,
                          paneTitle: base?.paneTitle ?? session.title, workingDirectory: folder, codexThreadID: app.threadID)
    }

    /// Whether the session is a Codex app thread as its jump sees it: the Codex app flag, or the evidence below. Every
    /// reader of "a Codex app thread" asks this, not the flag alone: upstream never sets the flag for a thread its hooks
    /// made, since their target says "Unknown" (P665). The rows (Show Codex app threads), the Done sound, `deliver`'s
    /// frontmost check and a request's place.
    public func isCodexAppThread(_ session: AgentSession) -> Bool {
        if session.isCodexAppSession { return true }
        guard session.tool == .codex else { return false }
        return codexAppJump(for: session, base: effectiveJumpTarget(for: session)) != nil
    }

    /// The Codex app's jump for a Codex session, strongest evidence first; nil when a terminal, an IDE or another app is
    /// the host (upstream's target stands), or when nothing at all is known (upstream's folder, which Last jump names).
    /// 1. A tmux pane, or a note's host that is not the Codex app: that host.
    /// 2. A note's host that is the Codex app (or its CLI helper): the thread.
    /// 3. A tty: its terminal. An app thread taken up by `codex resume` in a terminal keeps the app's originator, since
    ///    Codex writes no new `session_meta` (P257); the app's app-server never has a tty (P666).
    /// 4. The rollout's originator names the Codex app (`CodexOriginator`): the thread, whatever a leaked `TERM_PROGRAM`
    ///    made the hook's target say.
    /// 5. A terminal named by the target, its terminal session or the note's `TERM_PROGRAM`: that terminal.
    /// 6. The Codex app flag, a thread id or a Codex.app target: the thread.
    /// 7. The agent's process belongs to the Codex app: the thread (a CLI thread the app took up keeps its originator).
    /// 8. A terminal or IDE originator: upstream's target. An originator the island does not know: the app, not a thread.
    func codexAppJump(for session: AgentSession, base: JumpTarget?) -> CodexAppJump? {
        guard session.tool == .codex else { return nil }
        let context = hookNotes.contexts[session.id]
        let codex = ExactJump.codexBundleID
        let thread = CodexAppJump.thread(ExactJump.nonEmpty(session.jumpTarget?.codexThreadID)
                                         ?? ExactJump.nonEmpty(codexAttention[session.id]?.threadID) ?? session.id)
        if context?.tmuxPane != nil, context?.tmuxSocketPath != nil { return nil }
        if let noted = context?.hostBundleID { return JumpHosts.canonical(bundleID: noted) == codex ? thread : nil }
        if ExactJump.nonEmpty(base?.terminalTTY) != nil { return nil }
        let rollout = codexAttention[session.id]
        let originator = rollout?.scopeOriginator ?? rollout?.originator
        let host = CodexOriginator.host(of: originator)
        if host == .codexApp { return thread }
        let named = base.flatMap { JumpHosts.bundleIdentifier(forTerminalApp: $0.terminalApp) }
        let terminal = (named != nil && named != codex) || ExactJump.nonEmpty(base?.terminalSessionID) != nil
            || ExactJump.nonEmpty(context?.termProgram) != nil
        if terminal { return nil }
        if session.isCodexAppSession || named == codex || ExactJump.nonEmpty(base?.codexThreadID) != nil { return thread }
        if let pid = context?.agentPID, dependencies.appForPID(pid).map(JumpHosts.canonical(bundleID:)) == codex { return thread }
        if host != nil { return nil }
        return originator == nil ? nil : .app
    }
}
