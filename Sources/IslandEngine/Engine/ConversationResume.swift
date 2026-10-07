import Foundation

/// Route (b) of a folded session (wave 6): its tab is gone (closed, or its agent quit), so a reply goes on with the
/// agent's own resume, and Open in terminal reopens the conversation in a new window (`SessionResumer`). The card asks
/// it only once the tab is gone. Nothing here runs by itself: every call is the owner's Return or
/// click on the card. The conforming type is `@Observable`, so a card that reads `isRunning` redraws when a run starts
/// or ends.
@MainActor
public protocol ConversationResuming: AnyObject {
    /// What the card offers for a session whose tab is gone.
    func availability(for sessionID: String) -> ResumeAvailability
    /// A resumed run of the session is under way: the card reads Working and offers Stop.
    func isRunning(_ sessionID: String) -> Bool
    /// Runs the agent's own resume with `text`, in the session's folder and profile, hooks on. `.sent` once the run
    /// started; `.notSent` when it could not start; `.nothingToSend` when one already runs or the session cannot resume.
    func continueConversation(_ sessionID: String, text: String) async -> SendOutcome
    /// Stop: ends the session's run.
    func stop(_ sessionID: String)
    /// Open in terminal for a session whose tab is gone: a new window with the interactive resume, given `prompt` as its
    /// first prompt when set (a stopped turn carried on, P1439). True once it opened.
    func openInTerminal(_ sessionID: String, continuing prompt: String?) async -> Bool
    /// One line for a run that did not start or ended badly ("Not sent · Claude Code not found", "Failed · …"); nil once
    /// the next send starts, and after a run that ended well or was stopped (contract R3, P1331).
    func problem(_ sessionID: String) -> String?
    /// The last run's own final text from the agent's output, for a profile whose hooks did not report it (R3).
    func answer(_ sessionID: String) -> String?
    /// Remembers what the session's resume would run while its session is still in the engine's state, so a reply and
    /// Open in terminal still go once upstream's process monitor drops the ended session (P1355). The engine asks it as
    /// the session folds and at each change of it while folded; it starts nothing.
    func keep(_ sessionID: String)
    /// What Codex's shared background service last said of the session's thread (P1487); nil when it was never asked or
    /// there is no link to it (any agent but Codex, a headless engine).
    func serviceStatus(_ sessionID: String) -> CodexDaemonStatus?
    /// Asks Codex's shared background service now, off the main thread, whether it holds the session's thread and runs a
    /// turn there (`thread/read`, nothing loaded or subscribed). Nothing for any other agent, or with no link.
    func lookAgain(_ sessionID: String) async
    /// Whether Codex's shared background service has a thread loaded in the Codex home `profile` (its writer), asked now:
    /// true holds it, false runs and does not, nil no service or no answer (Open in Codex asks it, P1516, P1532).
    func codexDaemonHolds(threadID: String, profile: String) async -> Bool?
}

extension ConversationResuming {
    public func serviceStatus(_ sessionID: String) -> CodexDaemonStatus? { nil }
    public func lookAgain(_ sessionID: String) async {}
    public func codexDaemonHolds(threadID: String, profile: String) async -> Bool? { nil }

    /// Codex's shared background service runs a turn of the session's thread now, whoever started it. (Claude Code's own
    /// background is `SessionEngine.backgroundTurnRuns`.)
    public func serviceTurnRuns(_ sessionID: String) -> Bool { serviceStatus(sessionID)?.turnRuns == true }
}

/// What a folded session's card offers once its tab is gone (`ConversationResuming.availability(for:)`).
public enum ResumeAvailability: Equatable, Sendable {
    /// A reply resumes the conversation. `note`, when set, is one short line the card shows above its field before the
    /// first send (Codex: it runs its commands without asking).
    case resume(note: String?)
    /// Codex's shared background service holds the thread (P1487): a reply starts a turn there (`turn/start` over its
    /// control socket), and Open in terminal attaches to it (`codex resume <id>`). `note`, before the first send.
    case daemon(note: String?)
    /// No resume for this agent: the card says "Open in terminal to reply".
    case openOnly
}
