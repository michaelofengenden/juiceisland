import Foundation
import IslandHookNotes
import OpenIslandCore

/// What came of sending an answer, a decision or a reply (`SessionEngine.approve`, `answer`, `reply`).
public enum SendOutcome: Equatable, Sendable {
    /// It went out: the approval or question is resolved, the reply was typed into its terminal.
    case sent
    /// It could not go out (the bridge was unreachable, the terminal refused): the session still waits, and the card
    /// that asked keeps it for a retry.
    case notSent
    /// Nothing to send: the session no longer waits on this (answered elsewhere, or one send is already on its way).
    case nothingToSend
}

/// Where a reply typed on a finished turn's card goes: only a terminal pane or tab the engine knows exactly, never a
/// guess (P128).
/// - tmux: the pane from `TMUX_PANE` on the server from `TMUX`, both from the agent's own context note;
/// - iTerm: the session whose unique id is the `ITERM_SESSION_ID` UUID from the context note, and whose tty, when the
///   agent's is known, is the agent's (P17: when they disagree, nothing is sent);
/// - Ghostty: the terminal whose id upstream took from the focused terminal as the prompt was typed, by that id alone
///   (upstream's sender would also try the working directory and the title).
/// Terminal, Codex.app and every other host get no reply field.
public enum ReplyRoute: Equatable, Sendable {
    case tmux(pane: String, socket: String)
    case iterm(sessionID: String, tty: String?)
    case ghostty(terminalID: String)
}

extension SessionEngine {
    /// A reply is offered for a finished turn whose terminal is known exactly (`ReplyRoute`), while its session has
    /// not ended and its agent is still at that terminal's controls (`agentAwaitsReply`, P139). Every card mapping asks
    /// it: it looks up the agent's process and at most a few of its parents (`sysctl`), and no terminal.
    public func canReply(sessionID: String) -> Bool {
        guard let session = state.session(id: sessionID), session.phase == .completed, !session.isSessionEnded,
              replyRoute(for: session, lookUpTTY: false) != nil else { return false }
        return agentPID(awaitingReply: session) != nil
    }

    /// The agent a reply would go to, while it is still at its terminal's controls: its pid from the context note is
    /// alive, not stopped (Ctrl-Z) and its terminal's foreground job (P139). The route is only a pane or a tab, which
    /// may hold a bare shell again once the agent was stopped, crashed or quit; so with no pid known, no reply.
    func agentPID(awaitingReply session: AgentSession) -> Int32? {
        guard let pid = hookNotes.contexts[session.id]?.agentPID, dependencies.agentAtPrompt(pid) else { return nil }
        return pid
    }

    /// `lookUpTTY`: the agent's tty from its pid, as a jump does (`effectiveJumpTarget`), for the iTerm check; without
    /// it, the tty upstream took from the hook.
    func replyRoute(for session: AgentSession, lookUpTTY: Bool = true) -> ReplyRoute? {
        guard !session.isCodexAppSession else { return nil }
        let context = hookNotes.contexts[session.id]
        if let context, let pane = ExactJump.nonEmpty(context.tmuxPane), let socket = ExactJump.nonEmpty(context.tmuxSocketPath) {
            return .tmux(pane: pane, socket: socket)
        }
        let target = session.jumpTarget
        switch context?.hostBundleID ?? target.flatMap({ JumpHosts.bundleIdentifier(forTerminalApp: $0.terminalApp) }) {
        case ExactJump.itermBundleID:
            guard let id = ExactJump.nonEmpty(context?.itermSessionID) else { return nil }
            let agentTTY = lookUpTTY ? context?.agentPID.flatMap(dependencies.ttyForPID) : nil
            return .iterm(sessionID: id, tty: ExactJump.nonEmpty(agentTTY ?? target?.terminalTTY))
        case ExactJump.ghosttyBundleID:
            return ExactJump.nonEmpty(target?.terminalSessionID).map { .ghostty(terminalID: $0) }
        default:
            return nil
        }
    }

    /// Types `text` and Return into the finished session's own terminal. Only a session that `canReply`, one reply at a
    /// time per session; the send runs off the main thread, and the agent is looked at again there, just before the
    /// text is typed: one that left its terminal's controls since is sent nothing (P139). The outcome is the send's
    /// own, however long it takes (an Automation prompt the owner has not answered yet holds it): the session stays
    /// held until then, so no Retry can type the text a second time behind it (P128). A headless engine (tests, the
    /// demo) has no live sender: only an injected one runs, so nothing here can type into a real terminal.
    public func reply(sessionID: String, text: String) async -> SendOutcome {
        guard let line = ReplySender.line(text), let session = state.session(id: sessionID), session.phase == .completed,
              !session.isSessionEnded, let route = replyRoute(for: session),
              let pid = hookNotes.contexts[sessionID]?.agentPID else { return .nothingToSend }
        guard dependencies.agentAtPrompt(pid) else { return .notSent }
        guard sendingSessionIDs.insert(sessionID).inserted else { return .nothingToSend }
        defer { sendingSessionIDs.remove(sessionID) }
        guard let sender = dependencies.sendReply ?? (configuration.startBridge ? ReplySender.live : nil) else { return .notSent }
        let atPrompt = dependencies.agentAtPrompt
        let sent = await ReplySender.run { atPrompt(pid) && sender(route, line) }
        return sent ? .sent : .notSent
    }
}

/// Sends a reply along its route: tmux and Ghostty through upstream's `TerminalTextSender` (given a target that holds
/// the exact handle and nothing it could fall back on), iTerm through our own script, which types into the matched
/// session only.
enum ReplySender {
    /// Where replies run, one at a time.
    static let queue = DispatchQueue(label: "juice-island.reply", qos: .userInitiated)

    /// The reply as it is typed: trimmed, and on one line (a newline would press Return early).
    static func line(_ text: String) -> String? {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? nil : flat
    }

    static let live: @Sendable (ReplyRoute, String) -> Bool = { route, text in
        switch route {
        case let .tmux(pane, socket):
            return TerminalTextSender.send(text, to: carrier(JumpTarget(terminalApp: "tmux", workspaceName: "", paneTitle: "",
                                                                        tmuxTarget: pane, tmuxSocketPath: socket)))
        case let .ghostty(terminalID):
            // No working directory and no title: upstream's script then matches by the id alone.
            return TerminalTextSender.send(text, to: carrier(JumpTarget(terminalApp: "Ghostty", workspaceName: "", paneTitle: "",
                                                                        terminalSessionID: terminalID)))
        case let .iterm(sessionID, tty):
            let output = try? JumpRunner.osascript(itermScript(text, sessionID: sessionID, tty: tty), 5)
            return output == "sent"
        }
    }

    /// A session that carries only `target`, for upstream's sender, which reads nothing else.
    static func carrier(_ target: JumpTarget) -> AgentSession {
        AgentSession(id: "reply", title: "", tool: .claudeCode, phase: .completed, summary: "", updatedAt: Date(), jumpTarget: target)
    }

    /// Types into the one iTerm session whose unique id is `sessionID` (and whose tty is `tty`, when known), then
    /// presses Return as a key does (a carriage return of its own). Addressed by bundle id (P49); it never activates
    /// iTerm or selects anything.
    static func itermScript(_ text: String, sessionID: String, tty: String?) -> String {
        let id = ExactJump.escape(sessionID), tty = ExactJump.escape(tty), text = ExactJump.escape(text)
        return """
        tell application id "\(ExactJump.itermBundleID)"
            if not (it is running) then return ""
            set found to {}
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if (id of aSession as text) is "\(id)" then set end of found to aSession
                    end repeat
                end repeat
            end repeat
            if (count of found) is not 1 then return ""
            set targetSession to item 1 of found
            if "\(tty)" is not "" and (tty of targetSession as text) is not "\(tty)" then return ""
            tell targetSession
                write text "\(text)" newline no
                write text (ASCII character 13) newline no
            end tell
            return "sent"
        end tell
        """
    }

    /// Runs `body` on the reply queue (`on`, which a test gives its own) and answers what it answered, when it has:
    /// iTerm's script gives up after 5 s, but Ghostty's Apple Event waits on an Automation prompt as long as macOS lets
    /// it, and a reply that went late is still a reply that went.
    static func run(on queue: DispatchQueue = ReplySender.queue, _ body: @escaping @Sendable () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}
