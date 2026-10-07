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
///   (upstream's sender would also try the working directory and the title);
/// - Terminal: the one tab whose tty is the agent's own, found from its pid as a jump finds it (P1300); with no pid, or
///   no tty for it, no route.
/// Codex.app, Warp, the editors and every other host get no reply field.
public enum ReplyRoute: Equatable, Sendable {
    case tmux(pane: String, socket: String)
    case iterm(sessionID: String, tty: String?)
    case ghostty(terminalID: String)
    case terminal(tty: String)
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
    /// A Codex app-server (the shared daemon) is never that agent: it holds no tab, and its parent's terminal is another
    /// session's (P1485).
    func agentPID(awaitingReply session: AgentSession) -> Int32? {
        guard let pid = hookNotes.contexts[session.id]?.agentPID, !agentIsCodexServer(pid), dependencies.agentAtPrompt(pid) else {
            return nil
        }
        return pid
    }

    /// A Claude Code session Claude Code's own list names as a background one, by its id or its agent's pid (P1545): it
    /// runs under the supervisor, in no tab. A dictionary look, cheap enough for every mapping.
    func runsInClaudeBackground(_ session: AgentSession) -> Bool {
        guard session.tool == .claudeCode, let backgrounder = claudeBackground else { return false }
        return backgrounder.runsInBackground(session.id, pid: hookNotes.contexts[session.id]?.agentPID)
    }

    /// Before a fold or a reply takes a tab that a Claude Code session's notes name by their environment alone (a tmux
    /// pane, an iTerm tab), its profile's list is read, once per session, where a background session could exist (the
    /// switch on, or a supervisor's roster there), unless the list names it already (P1545). True when it was read.
    func lookedForClaudeBackground(_ session: AgentSession) async -> Bool {
        guard session.tool == .claudeCode, let backgrounder = claudeBackground, backgrounder.canRun,
              backgrounder.known[session.id] == nil, backgrounder.elsewhere[session.id] == nil,
              !backgrounder.lookedFor.contains(session.id) else { return false }
        switch replyRoute(for: session, lookUpTTY: false) {
        case .tmux?, .iterm?: break
        default: return false
        }
        let profile = claudeProfile(for: session)
        guard keepsClaudeRunning || backgrounder.dependencies.hasRoster(profile) else { return false }
        backgrounder.lookedFor.insert(session.id)
        await backgrounder.list(profile: profile)
        return true
    }

    /// `lookUpTTY`: the agent's tty from its pid, as a jump does (`effectiveJumpTarget`), for the iTerm check; without
    /// it, the tty upstream took from the hook. Terminal's tab is found by the agent's own tty alone, so it is always
    /// looked up (one `sysctl`, P1300).
    func replyRoute(for session: AgentSession, lookUpTTY: Bool = true) -> ReplyRoute? {
        guard !session.isCodexAppSession else { return nil }
        let context = hookNotes.contexts[session.id]
        // The notes of a session Codex's shared daemon runs carry the daemon's own terminal variables (the first client's
        // tab) and its parent's tty: no tab of this session's is known (P1486).
        if let pid = context?.agentPID, agentIsCodexServer(pid) { return nil }
        // Nor a session in Claude Code's own background: its notes carry the environment of the terminal that started the
        // supervisor, another session's pane or tab (P1545).
        if runsInClaudeBackground(session) { return nil }
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
        case ExactJump.terminalBundleID:
            // Never upstream's tty, which a closed tab's successor can carry: only the agent's own, while it runs.
            return context?.agentPID.flatMap(dependencies.ttyForPID).flatMap(ExactJump.nonEmpty).map { .terminal(tty: $0) }
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
        // A pane named by inherited environment alone may be another session's: one look at Claude Code's list (P1545).
        if await lookedForClaudeBackground(session), runsInClaudeBackground(session) { return .notSent }
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

    /// The reply as it is typed: trimmed, and on one line (a newline would press Return early), with no other control
    /// character (an Esc would interrupt the agent, a tab complete a path, P1301).
    static func line(_ text: String) -> String? {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let plain = String(String.UnicodeScalarView(flat.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
            .trimmingCharacters(in: .whitespaces)
        return plain.isEmpty ? nil : plain
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
        case .iterm, .terminal:
            return scripted(route, text, osascript: JumpRunner.osascript)
        }
    }

    /// The routes typed through our own script (iTerm, Terminal): the one script for `route`, run once by `osascript`
    /// (the live one gives up after `timeout(for:)`; a test's records it), sent when it answers "sent". tmux and Ghostty
    /// go through upstream's sender and are not this.
    static func scripted(_ route: ReplyRoute, _ text: String, submit: TerminalSubmit = .standard,
                         osascript: JumpRunner.AppleScript) -> Bool {
        let script: String
        switch route {
        case let .iterm(sessionID, tty): script = itermScript(text, sessionID: sessionID, tty: tty)
        case let .terminal(tty): script = terminalScript(text, tty: tty, submit: submit)
        case .tmux, .ghostty: return false
        }
        return (try? osascript(script, timeout(for: route))) == "sent"
    }

    /// How long `osascript` may take. iTerm's two writes follow each other at once: 5 s. Terminal's are 0.3 s apart, and
    /// an Automation prompt the owner has not answered yet holds the first: stopped at 5 s, the script could leave the
    /// text typed and its Return unsent behind a "Not sent" whose Retry types it again (P1361). So Terminal's waits past
    /// AppleScript's own two minutes for an Apple event's answer, and the card reads Sending… meanwhile.
    static func timeout(for route: ReplyRoute) -> TimeInterval {
        if case .terminal = route { return terminalTimeout }
        return 5
    }

    static let terminalTimeout: TimeInterval = 150

    /// How a line typed into a Terminal tab is submitted (P1301). Terminal's dictionary has one way to type into a tab,
    /// `do script`, which "runs a UNIX shell script or command": it writes the text and a line end in one go. Claude
    /// Code reads a burst of characters that ends in a line end as pasted text and leaves it in its prompt, unsent, which
    /// is why upstream's own senders press Return as a key of its own (tmux `send-keys` then `Enter`, Ghostty's `input
    /// text` then `send key "enter"`) and the iTerm route writes the carriage return on its own. So the standard is
    /// `.thenReturn`: the text, a pause, then an empty `do script`, a line end alone, which Claude Code reads as Return.
    /// `.inOne` is the plain `do script`; the owner's live test of it decides between the two (`TerminalSubmit.from`).
    enum TerminalSubmit: Equatable, Sendable {
        /// `do script "<text>"`: the text and its line end in one write.
        case inOne
        /// `do script "<text>"`, a pause, then `do script ""`: the line end on its own.
        case thenReturn

        static let standard: TerminalSubmit = .thenReturn
        /// The pause before the line end alone: long enough to be read apart from the text (a paste is one read).
        static let pause = 0.3
    }

    /// Types into the one Terminal tab whose tty is the agent's (`tty`), then submits it as `submit` says. Addressed by
    /// bundle id (P49); it selects nothing, activates nothing and never opens a tab: `do script` with no tab would.
    /// The tab is held by its window's id, not by the windows' order, and `.thenReturn` finds it again by its tty after
    /// the pause: a window brought forward, opened or tucked meanwhile never takes the line end (P1357). A tab gone in
    /// the pause took the text with it: "typed", not sent.
    static func terminalScript(_ text: String, tty: String, submit: TerminalSubmit) -> String {
        let tty = ExactJump.escape(tty), text = ExactJump.escape(text)
        let find = """
                set found to {}
                repeat with aWindow in windows
                    set k to 0
                    repeat with aTab in tabs of aWindow
                        set k to k + 1
                        if (tty of aTab as text) is "\(tty)" then set end of found to tab k of window id (id of aWindow)
                    end repeat
                end repeat
            """
        let returnAlone = submit == .thenReturn ? """

                delay \(TerminalSubmit.pause)
            \(find)
                if (count of found) is not 1 then return "typed"
                set targetTab to item 1 of found
                do script "" in targetTab
            """ : ""
        return """
        tell application id "\(ExactJump.terminalBundleID)"
            if not (it is running) then return ""
        \(find)
            if (count of found) is not 1 then return ""
            set targetTab to item 1 of found
            do script "\(text)" in targetTab\(returnAlone)
            return "sent"
        end tell
        """
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
