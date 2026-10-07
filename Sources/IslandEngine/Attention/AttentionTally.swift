import Foundation

/// What the needs-you book did since launch, in counts only: no text, no path, no id (Diagnostics › Attention, C18).
/// This is how "are these real?" gets answered with numbers: how many requests arrived, from where, how many were
/// held, how many ever reached the owner, and what ended each one.
public struct AttentionTally: Equatable, Sendable {
    /// Requests opened, by `<agent>.<source>.<surface>` (`claude.broker.cli`, `codex.rollout.codexApp`, …; a missing
    /// Claude entrypoint is `missing`).
    public var opened: [String: Int] = [:]
    /// Broker requests held for the island, and released at once.
    public var held = 0
    public var released = 0
    /// Released and never shown: headless, `dontAsk`, Codex bypass, auto review, strict review, by reason.
    public var notShown: [String: Int] = [:]
    public var confirmed: [String: Int] = [:]
    /// Closed while still pending: answered or settled before the owner could have been asked.
    public var neverConfirmed = 0
    /// Released by their window unconfirmed, by surface (a surface whose notices never come shows here).
    public var releasedByWindow: [String: Int] = [:]
    public var closes: [String: Int] = [:]
    public var revivals = 0
    /// `permission_prompt` notices with no request behind them (a prompt with no hook, or a request never seen).
    public var noticesWithoutRequest = 0
    /// Codex requests with no call of their own (network, `write_stdin`, a call already yielded).
    public var codexUnmatched = 0
    /// Codex requests closed within their 8 s window: Codex settled them itself (a reviewer the config forces).
    public var codexClosedEarly = 0
    /// Island answers that lost the race: evidence after the click says the agent went the other way.
    public var lostRaces = 0
    /// Codex questions read from rollouts, and how each closed.
    public var codexQuestionsOpened = 0
    public var codexQuestionsClosed: [String: Int] = [:]
    /// Notes received, by version: 1 means a helper not yet updated (P163).
    public var noteVersions: [Int: Int] = [:]
    /// The version of the last note received: the helper in effect now. After Hook helper · Update every new hook
    /// sends the new version, while `noteVersions` still counts the old one since launch (P176).
    public var lastNoteVersion: Int?
    /// Broker requests the engine could not read (an input upstream's types reject).
    public var unreadable = 0
    /// Subagents' requests held for the island (Answer subagents on the island, P350) whose hold ended with no decision,
    /// by why: `timeUp`, `notShown`, `hidden`, `opened`, `switchedOff`, `brokerEnded`.
    public var subagentHolds: [String: Int] = [:]
    /// Codex requests held for the island (Answer Codex in Juice, P470) that ended with no decision, by why: the
    /// hold's ends as `subagentHolds`, and `focused`, `reviewer`, `unknownReviewer`, `hookEnded`, `switchedOff`,
    /// `notEntered`, `late` for one handed back before its card.
    public var codexHolds: [String: Int] = [:]

    public init() {}

    mutating func count(_ key: String, in keyPath: WritableKeyPath<AttentionTally, [String: Int]>) {
        self[keyPath: keyPath][key, default: 0] += 1
    }
}
