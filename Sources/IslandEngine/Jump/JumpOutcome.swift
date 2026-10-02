import Foundation

/// One runner call made during a jump, for Diagnostics › Recent jumps.
public struct JumpStep: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case appleScript
        case open
        case process
    }

    public let kind: Kind
    /// A short description: the first line of a script, or the command and its arguments.
    public let detail: String
    public let succeeded: Bool
    public let error: String?
    public let duration: TimeInterval
}

public enum JumpResult: String, Sendable {
    /// The exact tab, pane or window came forward.
    case matched
    /// The host came forward but the exact pane was not found.
    case activatedOnly
    /// The exact jump failed; the host app was brought forward instead.
    case fallbackActivated
    case failed
    /// The session has no jump target yet.
    case noTarget
    /// No app or terminal is known for the session, so its working folder was opened in Finder (upstream's last resort,
    /// never for a Codex app thread, P660).
    case folderOpened
}

public enum JumpFailure: String, Sendable {
    case unknownHost
    case automationDenied
    case timedOut
    case scriptFailed
    case openFailed
    /// The session's host app is not running, so its tab is gone; nothing is launched (M5's verified jumps).
    case hostNotRunning
    /// The command-line tool the jump needs (tmux, `code`, `idea`, …) was not found; `JumpOutcome.tool` names it.
    case cliMissing
    /// The tmux session has no client attached, so selecting its pane shows nothing (P47).
    case detached
    /// More than one Ghostty terminal matches, so none is picked (P46).
    case ambiguous
    /// The jump reported a match but the focused tab is another one (P43).
    case wrongTab
    /// The Codex app did not come forward for its thread link (P50).
    case threadLinkFailed
    /// A Codex app thread with no thread id to link to: the app came forward, not the thread (P660).
    case threadUnknown
}

public struct JumpOutcome: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: String
    public let host: String
    public let startedAt: Date
    public let duration: TimeInterval
    public let result: JumpResult
    /// Why the exact jump did not work, when it did not.
    public let failure: JumpFailure?
    public let message: String
    public let steps: [JumpStep]
    /// The missing command-line tool, with `cliMissing`.
    public var tool: String? = nil
}

/// Exact handles for one session's jump, from the superset helper's context notes (spec §3.8). With them, a jump
/// goes to the iTerm session by its id, the tmux pane by its id, the Terminal tab by the agent's tty, and only to
/// the app that started the agent (P49).
public struct JumpContext: Equatable, Sendable {
    public var hostBundleID: String?
    /// The iTerm session UUID from `ITERM_SESSION_ID` (P17).
    public var itermSessionID: String?
    public var tmuxSocketPath: String?
    /// `%<id>`, from `TMUX_PANE`.
    public var tmuxPane: String?
    public var agentPID: Int32?

    public init(hostBundleID: String? = nil, itermSessionID: String? = nil, tmuxSocketPath: String? = nil,
                tmuxPane: String? = nil, agentPID: Int32? = nil) {
        self.hostBundleID = hostBundleID
        self.itermSessionID = itermSessionID
        self.tmuxSocketPath = tmuxSocketPath
        self.tmuxPane = tmuxPane
        self.agentPID = agentPID
    }

    var hasTmuxPane: Bool { tmuxPane?.isEmpty == false && tmuxSocketPath?.isEmpty == false }
}
