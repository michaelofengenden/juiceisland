import Foundation
import IslandHookNotes

/// Settings › Island › Answer subagents on the island (P350; the owner's choice of 2026-09-28, the c10 round's option A).
/// Claude awaits a background subagent's PermissionRequest hook before it builds its own "Allow once", and sends no
/// `permission_prompt` while the hook holds (claude-code#82150, P280): holding one takes Claude's own prompt away. The
/// opt-in trades that for Allow on the island, bounded and only while the owner can see it:
/// - off by default; held only while it is on in Island mode, and only a tool approval (not a question, not a plan) from
///   the four surfaces a main-thread request is held for, never `dontAsk` or a headless run (`AttentionPolicy.brokerHold`);
/// - confirmed and sounded at once, since no notice can come while the hook holds;
/// - held only while the island shows its card: one the island has not shown within `showGrace`, or stops showing (a
///   fold, the owner going to another app, Esc, Open, another card in its place, Window mode), is released at once;
/// - at most `limit` after it was asked; then released, and its card turns read-only, as every subagent's is when the
///   switch is off;
/// - the broker ends the hold by itself `limit + backstopMargin` after its reply, on its own queue, whatever the main
///   thread does; a quit or a crash ends the connection; either way the helper exits silent and Claude builds its own
///   prompt (fail open).
/// An island answer goes over that request's own connection only (P170, P186), with no Always allow (Claude's
/// suggestions may widen the whole session's permissions) and no No and stop (a subagent's interrupt is not the turn's).
public enum SubagentHold {
    /// How long the island may keep a subagent's request from Claude's own prompt: the tuning constant. Twice the
    /// island's idle fold (6 s, P292), so an owner who notices the sound and the island has the time Claude itself gives
    /// before it calls the owner away (its `permission_prompt` comes at 6 s) and as long again to read the command and
    /// click; well under nirux's 15 s, as every subagent request pays it when the owner answers in Claude instead: Claude's
    /// prompt comes up to 12 s late, its desktop and phone notice up to 18 s.
    public static let limit: TimeInterval = 12
    /// How long the island has to put a held request's card in front of the owner (it does in a turn or two): not shown
    /// by then (another card is up, Quiet, the island hidden), it is released.
    public static let showGrace: TimeInterval = 2
    /// The broker's own end of a hold, past `limit`: only a main thread stuck that long reaches it.
    public static let backstopMargin: TimeInterval = 3
    /// How late past `AttentionBook.noticeDelay` after a release Claude's notice may come and still be the released
    /// prompt's own (P352): the book's own window gives a notice 2 s past its 6 (`AttentionBook.window`); twice that
    /// here, as Claude's timer starts only once its hook returned and it built the dialog. At most one notice is taken
    /// for each release.
    public static let noticeGrace: TimeInterval = 4

    /// Why a hold ended with no decision (Diagnostics › Needs you counts them; no text).
    enum End: String {
        /// `limit` passed.
        case timeUp
        /// The island never showed its card within `showGrace`.
        case notShown
        /// The island stopped showing it (a fold, another app, Esc, another card in its place, Window mode), and the
        /// window does not show it either (closed, covered, another app, P1050).
        case hidden
        /// Open, a jump to its session, or ✕.
        case opened
        /// The switch went off (or Island mode did).
        case switchedOff
        /// The broker had already ended it (its backstop, a main thread stuck past it).
        case brokerEnded
    }
}

/// A subagent's prompt Claude built as the island's hold on it ended (P352). Claude sends no `permission_prompt` while its
/// hook holds, so the notice for this prompt comes about `AttentionBook.noticeDelay` after the release, not after the
/// request, which the island confirmed and sounded at once: that notice is this prompt's own, whether its read-only card
/// is still there or the owner dismissed it before the notice came.
struct ReleasedHoldPrompt: Equatable, Sendable {
    var sessionID: String
    var agentID: String?
    var releasedAt: Date
    /// ✕ closed its request before its notice came: the notice brings nothing back and sounds nothing.
    var dismissed = false

    var noticeDue: Date { releasedAt.addingTimeInterval(AttentionBook.noticeDelay) }

    /// How far from due a notice at `now` is.
    func lateness(at now: Date) -> TimeInterval { abs(now.timeIntervalSince(noticeDue)) }

    /// Whether this prompt's notice may still come.
    func isLive(at now: Date) -> Bool { now <= noticeDue.addingTimeInterval(SubagentHold.noticeGrace) }

    /// Whether a notice for `sessionID` at `now` can be this prompt's: after the release, within `noticeGrace` of due,
    /// and not naming another subagent.
    func matches(sessionID: String, agentID: String?, at now: Date) -> Bool {
        sessionID == self.sessionID && now >= releasedAt && isLive(at: now)
            && (agentID == nil || self.agentID == nil || agentID == self.agentID)
    }
}

/// The switch the broker reads on its own queue, set from the main thread (`SessionEngine.answersSubagents`).
final class SubagentHoldSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    var isOn: Bool { lock.withLock { on } }

    func set(_ value: Bool) { lock.withLock { on = value } }
}

extension SessionEngine {
    /// Settings › Island › Answer subagents on the island, while the app shows as Island (P350). Off: every subagent's
    /// request is handed back at once and shown read-only (P280). Turned off, every hold ends at once.
    public var answersSubagents: Bool {
        get { subagentHoldSwitch.isOn }
        set {
            subagentHoldSwitch.set(newValue)
            guard !newValue else { return }
            for request in attention.all where request.isHeldForIsland && request.tool != .codex { endSubagentHold(request.id, .switchedOff) }
        }
    }

    /// The request whose card the island shows now, as the owner sees it; nil when it shows none (folded, folding, the
    /// list, another app, Window mode). A subagent's request held for the island is held only while it shows (P350).
    public func islandShows(requestID: String?) {
        let previous = islandShownRequest
        guard previous != requestID else { return }
        islandShownRequest = requestID
        if let requestID, attention.request(requestID)?.isHeldForIsland == true { subagentHoldsSeen.insert(requestID) }
        if let previous, !windowShownRequests.contains(previous) { endSubagentHold(previous, .hidden) }
    }

    /// The requests whose cards the window shows the owner now (Window mode, P1050): the Needs you cards in view while
    /// the window is on screen and the owner has not gone to another app; empty otherwise (closed, minimised, covered,
    /// Island mode). A request held for its card is held while the island or the window shows it, and ends at once when
    /// neither does, as the island's fold ends it. Only Codex requests are held in Window mode (`answersSubagents` is the
    /// island's alone).
    public func windowShows(requestIDs: Set<String>) {
        let previous = windowShownRequests
        guard previous != requestIDs else { return }
        windowShownRequests = requestIDs
        for id in requestIDs where attention.request(id)?.isHeldForIsland == true { subagentHoldsSeen.insert(id) }
        for id in previous.subtracting(requestIDs) where islandShownRequest != id { endSubagentHold(id, .hidden) }
    }

    /// A subagent's request held for the island: released if the island has not shown it within `showGrace`, and at
    /// `limit` whatever happens.
    func scheduleSubagentHold(_ request: AttentionRequest) {
        guard let ends = request.holdEndsAt else { return }
        let id = request.id, now = dependencies.now()
        dependencies.scheduleAttentionCheck(max(0, request.openedAt.addingTimeInterval(SubagentHold.showGrace).timeIntervalSince(now))) {
            [weak self] in
            guard let self, !self.subagentHoldsSeen.contains(id), self.islandShownRequest != id,
                  !self.windowShownRequests.contains(id) else { return }
            self.endSubagentHold(id, .notShown)
        }
        dependencies.scheduleAttentionCheck(max(0, ends.timeIntervalSince(now))) { [weak self] in
            self?.endSubagentHold(id, .timeUp)
        }
    }

    /// Ends a subagent's hold with no decision: the helper exits silent and Claude builds its own prompt; the request stays
    /// open, confirmed and read-only (Open, ✕), until its own evidence closes it, as any subagent's (P280). A request that
    /// is not held for the island is left alone. A Codex request held for the island (P470) ends the same way: Codex's
    /// reviewer or its own prompt takes it, and Codex sends no notice that could come back for it.
    func endSubagentHold(_ id: String, _ end: SubagentHold.End) {
        guard let request = attention.request(id), request.isHeldForIsland else { return }
        subagentHoldsSeen.remove(id)
        if request.channel == .answer(.broker) { hookRequestBroker?.release(id) }
        attention.update(id) {
            $0.channel = .open
            $0.holdEndsAt = nil
        }
        if request.tool == .codex {
            attentionTally.count(end.rawValue, in: \.codexHolds)
            return
        }
        attentionTally.count(end.rawValue, in: \.subagentHolds)
        // Claude builds its prompt now; its notice comes about `noticeDelay` from here (P352).
        let now = dependencies.now()
        releasedHoldPrompts = releasedHoldPrompts.filter { $0.value.isLive(at: now) }
        releasedHoldPrompts[id] = ReleasedHoldPrompt(sessionID: request.sessionID, agentID: request.agentID, releasedAt: now)
    }

    /// Claude's `permission_prompt` for a prompt it built as the island's hold ended (P352): the released prompt due
    /// closest to `now`, unless one of the session's pending requests is due closer (then the book's). Taken, it is
    /// spent: its request's card is already there (confirmed at once), or the owner dismissed it before this notice came,
    /// so nothing opens, nothing is confirmed in its place and nothing sounds. Past `noticeGrace` a notice is another
    /// prompt's, as always.
    func takeReleasedHoldNotice(sessionID: String, agentID: String?, now: Date) -> Bool {
        releasedHoldPrompts = releasedHoldPrompts.filter { $0.value.isLive(at: now) }
        guard let (id, prompt) = releasedHoldPrompts.filter({ $0.value.matches(sessionID: sessionID, agentID: agentID, at: now) })
            .min(by: { $0.value.lateness(at: now) < $1.value.lateness(at: now) }) else { return false }
        let pendingDue = attention.open(in: sessionID).filter { $0.state == .pending }
            .map { abs(now.timeIntervalSince($0.openedAt) - AttentionBook.noticeDelay) }.min()
        if let pendingDue, pendingDue < prompt.lateness(at: now) { return false }
        releasedHoldPrompts[id] = nil
        return true
    }

    /// A released prompt's request closed: by ✕, its notice may still come and is kept for it; by anything else (its
    /// call ran, Claude's prompt was answered, the session went) no notice will come for it.
    func noteReleasedHoldClosed(_ request: AttentionRequest, cause: AttentionCloseCause) {
        guard releasedHoldPrompts[request.id] != nil else { return }
        if cause == .dismissed { releasedHoldPrompts[request.id]?.dismissed = true } else { releasedHoldPrompts[request.id] = nil }
    }

    /// Every hold of a session ends: the owner goes to it (a jump, Open), where Claude must show its own prompt.
    func endSubagentHolds(in sessionID: String, _ end: SubagentHold.End) {
        for request in attention.open(in: sessionID) where request.isHeldForIsland { endSubagentHold(request.id, end) }
    }
}
