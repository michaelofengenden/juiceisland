import Foundation

/// What the engine keeps of the Codex threads that are never rows (P212): the ids it hid (Codex's approvals reviewer,
/// its other helpers, the subagents a chat spawned, a review folded into its chat) and each chat's subagents and
/// reviews, for the chat's row ("3 subagents"), for whether a review is folded (P217), and for a subagent's request,
/// which waits on its chat's row under the subagent's name. Pure; memory only.
struct CodexThreadBook: Equatable, Sendable {
    /// A hidden id is kept this long after it was last seen: a thread quiet that long is no longer written.
    static let hiddenLifetime: TimeInterval = 86_400
    /// A hidden id's last sighting moves on at most this often, so a scan every 10 s changes nothing that is drawn.
    static let sightingStep: TimeInterval = 3_600
    /// A subagent whose rollout has been quiet this long no longer counts as running on its chat's row: a subagent
    /// that crashed mid-turn never writes its turn end.
    static let runningQuietLimit: TimeInterval = 30 * 60
    /// Subagents whose rollouts are watched at most (the newest running ones).
    static let watchLimit = 16
    /// How deep a chain of subagents is followed to its chat.
    static let depthLimit = 8

    /// Threads that are never rows, by id, with when they were last seen.
    private(set) var hidden: [String: Date] = [:]
    /// Subagents by id.
    private(set) var children: [String: CodexChildThread] = [:]

    func isHidden(_ id: String) -> Bool { hidden[id] != nil }

    func child(_ id: String) -> CodexChildThread? { children[id] }

    mutating func hide(_ id: String, at date: Date) {
        if let known = hidden[id], date.timeIntervalSince(known) < Self.sightingStep { return }
        hidden[id] = max(hidden[id] ?? date, date)
    }

    /// A scan's subagents and reviews (or one the tracker found): each subagent is hidden, and each replaces what was
    /// known of it unless that is newer (a live read since the scan read the file). A review is hidden only once it is
    /// folded into its chat (`SessionEngine.foldsReview`, P217).
    mutating func take(_ incoming: [CodexChildThread], at date: Date) {
        for child in incoming {
            if !child.isReview || isHidden(child.id) { hide(child.id, at: date) }
            if let known = children[child.id], known.updatedAt > child.updatedAt { continue }
            children[child.id] = child
        }
    }

    /// A watched subagent's own turn started (true) or ended (false), at `date`.
    mutating func setRunning(_ id: String, _ running: Bool, at date: Date) {
        guard var child = children[id] else { return }
        child.isRunning = running
        child.updatedAt = max(child.updatedAt, date)
        children[id] = child
    }

    /// The chat a subagent belongs to: the root its rollout names, else the first thread up its parents that is not a
    /// subagent of this book.
    func owner(of childID: String) -> String? {
        guard var child = children[childID] else { return nil }
        if let root = child.rootID { return root }
        for _ in 0..<Self.depthLimit {
            guard let parent = children[child.parentID] else { return child.parentID }
            if let root = parent.rootID { return root }
            child = parent
        }
        return child.parentID
    }

    /// The subagents of `chatID` that run now: their last turn has not ended and their rollout was written in the
    /// last `runningQuietLimit`.
    func running(in chatID: String, now: Date) -> [CodexChildThread] {
        children.values.filter { !$0.isReview && $0.isRunning && isFresh($0, now: now) && owner(of: $0.id) == chatID }
    }

    /// The subagents whose rollouts are watched: every one of `holding` (a request of its is open, which only its own
    /// rollout closes, however long it is quiet, P218), then the running ones, newest first, up to `watchLimit`.
    func watched(now: Date, holding: Set<String> = []) -> [CodexChildThread] {
        let watchable = children.values.filter { !$0.isReview && !$0.transcriptPath.isEmpty }
        let held = watchable.filter { holding.contains($0.id) }.sorted(by: Self.newestFirst)
        let running = watchable.filter { !holding.contains($0.id) && $0.isRunning && isFresh($0, now: now) }.sorted(by: Self.newestFirst)
        return held + running.prefix(max(0, Self.watchLimit - held.count))
    }

    /// When the first subagent watched for its running alone goes quiet past `runningQuietLimit`, and so leaves the
    /// watch; nil when none is (P218).
    func nextLapse(now: Date, holding: Set<String> = []) -> Date? {
        watched(now: now, holding: holding).filter { !holding.contains($0.id) }
            .map { $0.updatedAt.addingTimeInterval(Self.runningQuietLimit) }.min()
    }

    private static func newestFirst(_ lhs: CodexChildThread, _ rhs: CodexChildThread) -> Bool {
        (lhs.updatedAt, lhs.id) > (rhs.updatedAt, rhs.id)
    }

    private func isFresh(_ child: CodexChildThread, now: Date) -> Bool {
        abs(now.timeIntervalSince(child.updatedAt)) <= Self.runningQuietLimit
    }

    /// Forgets a thread not seen for `hiddenLifetime`, a subagent with it, and a review not folded that was not written
    /// for as long.
    mutating func prune(now: Date) {
        hidden = hidden.filter { now.timeIntervalSince($0.value) < Self.hiddenLifetime }
        children = children.filter {
            hidden[$0.key] != nil || ($0.value.isReview && now.timeIntervalSince($0.value.updatedAt) < Self.hiddenLifetime)
        }
    }

    var hiddenCount: Int { hidden.count }
}
