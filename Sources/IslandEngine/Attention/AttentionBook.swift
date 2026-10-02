import Foundation
import OpenIslandCore

/// The engine's open requests, per session, oldest first (§3.1 of the needs-you design). Pure: `SessionEngine` asks it
/// what to draw, feeds it evidence and carries out what it returns (releasing a held hook, applying the head to the
/// session state, sounding a confirmation).
///
/// Invariants, each with a test (`AttentionBookTests`):
/// 1. A session's glyph is its oldest confirmed request's; pending and dormant requests draw and count nothing (C13).
/// 2. Requests are kept per hook, a queue per session: a new request never replaces an old one, and a close never
///    closes a sibling. A `permission_prompt` confirms the unconfirmed request whose own notice is due (asked closest to
///    `noticeDelay` before it, the oldest on a tie); with none, it revives the newest dormant one; with none, the engine
///    opens a notification-only request (C2, C3, P180).
/// 3. Only the engine applies a request to the session state, from `head(of:)`.
/// 4. A closed request is gone; the engine releases its hook in the same step.
/// 5. Nothing is kept across a relaunch (the book lives in memory).
/// 6. A Codex request the old helper holds for the bridge closes only by the bridge's own ends (C4, P166).
struct AttentionBook: Sendable {
    /// Each request's one confirmation check, from its own `openedAt` (C2).
    static let window: TimeInterval = 8
    /// Claude's `permission_prompt` comes this long after its request arrives, "timed from when the request arrives"
    /// even behind another dialog (hooks#notification).
    static let noticeDelay: TimeInterval = 6
    /// How long a noted PreToolUse waits for its PermissionRequest (they may arrive out of order on two sockets).
    static let toolUseMemory: TimeInterval = 120
    /// At most this many noted PreToolUses per session.
    static let toolUseLimit = 32

    /// A PreToolUse the notes named: matched to a PermissionRequest by agent, tool and input digest.
    struct ToolUse: Equatable, Sendable {
        var agentID: String?
        var toolName: String?
        var digest: String?
        var toolUseID: String
        var at: Date
    }

    enum WindowResult: Equatable, Sendable {
        case confirmed(AttentionRequest)
        case released(AttentionRequest)
        case none
    }

    enum NoticeResult: Equatable, Sendable {
        case confirmed(AttentionRequest)
        case revived(AttentionRequest)
        case none
    }

    private(set) var requests: [String: AttentionRequest] = [:]
    private var sequence: [String: Int] = [:]
    private var nextSequence = 0
    private(set) var toolUses: [String: [ToolUse]] = [:]

    // MARK: Reading

    func request(_ id: String) -> AttentionRequest? { requests[id] }

    /// The session's open requests (pending, confirmed and dormant), oldest first.
    func open(in sessionID: String) -> [AttentionRequest] {
        requests.values.filter { $0.sessionID == sessionID }.sorted(by: isOlder)
    }

    /// The session's confirmed requests, oldest first: the queue its cards show.
    func confirmed(in sessionID: String) -> [AttentionRequest] { open(in: sessionID).filter(\.isConfirmed) }

    /// What the session's glyph and card show: its oldest confirmed request (invariant 1).
    func head(of sessionID: String) -> AttentionRequest? { confirmed(in: sessionID).first }

    var sessionIDs: Set<String> { Set(requests.values.map(\.sessionID)).union(toolUses.keys) }

    var all: [AttentionRequest] { requests.values.sorted(by: isOlder) }

    private func isOlder(_ lhs: AttentionRequest, _ rhs: AttentionRequest) -> Bool {
        if lhs.openedAt != rhs.openedAt { return lhs.openedAt < rhs.openedAt }
        return (sequence[lhs.id] ?? 0) < (sequence[rhs.id] ?? 0)
    }

    // MARK: Opening and confirming

    /// Enters a request (false when its id is already open). A PreToolUse noted before it gives it its call's id.
    @discardableResult
    mutating func insert(_ request: AttentionRequest) -> Bool {
        guard requests[request.id] == nil else { return false }
        var request = request
        if request.toolUseID == nil, let use = takeToolUse(for: request) {
            request.toolUseID = use.toolUseID
            // Upstream's request carries it too (the card's call read, the approve path).
            if case var .approval(permission) = request.content, permission.toolUseID == nil {
                permission.toolUseID = use.toolUseID
                request.content = .approval(permission)
            }
        }
        requests[request.id] = request
        sequence[request.id] = nextSequence
        nextSequence += 1
        return true
    }

    mutating func update(_ id: String, _ change: (inout AttentionRequest) -> Void) {
        guard var request = requests[id] else { return }
        change(&request)
        requests[id] = request
    }

    /// Pending or dormant → confirmed. Returns the request when that changed it.
    @discardableResult
    mutating func confirm(_ id: String, at now: Date) -> AttentionRequest? {
        guard var request = requests[id], request.state != .confirmed else { return nil }
        request.state = .confirmed
        request.confirmedAt = now
        requests[id] = request
        return request
    }

    /// The request's one check, `window` after its own `openedAt`: still pending, it is released (dormant) where its
    /// window releases, else confirmed.
    mutating func windowElapsed(_ id: String, at now: Date) -> WindowResult {
        guard var request = requests[id], request.state == .pending else { return .none }
        if request.windowReleases {
            request.state = .dormant
            requests[id] = request
            return .released(request)
        }
        return confirm(id, at: now).map(WindowResult.confirmed) ?? .none
    }

    /// Claude's `permission_prompt`: the session's unconfirmed (pending) request whose own notice is due is confirmed,
    /// the one asked closest to `noticeDelay` before it (the oldest on a tie). A request answered at the keyboard gets
    /// no notice but stays pending until its window, so the oldest pending one may be a prompt Claude no longer shows
    /// while a later one still waits (P180). With none pending, the newest dormant request comes back with its own kind
    /// (a question stays "?"); with none, nothing here.
    mutating func notice(sessionID: String, at now: Date) -> NoticeResult {
        let open = open(in: sessionID)
        func lateness(_ request: AttentionRequest) -> TimeInterval {
            abs(now.timeIntervalSince(request.openedAt) - Self.noticeDelay)
        }
        if let due = open.filter({ $0.state == .pending }).min(by: { lateness($0) < lateness($1) }),
           let confirmed = confirm(due.id, at: now) {
            return .confirmed(confirmed)
        }
        if let newest = open.last(where: { $0.state == .dormant }), let revived = confirm(newest.id, at: now) {
            return .revived(revived)
        }
        return .none
    }

    // MARK: Closing

    /// Whether `cause` may close the request: any, but for a Codex request the old helper holds (invariant 6), which
    /// only the bridge's own ends close.
    static func mayClose(_ request: AttentionRequest, cause: AttentionCloseCause, fromBridge: Bool) -> Bool {
        guard request.isHeldCodexLegacy else { return true }
        switch cause {
        case .hookEnded, .islandAnswer, .superseded, .sessionGone: return true
        case .turnEnd: return fromBridge
        default: return false
        }
    }

    @discardableResult
    mutating func close(_ id: String, cause: AttentionCloseCause, fromBridge: Bool = false) -> AttentionRequest? {
        guard let request = requests[id], Self.mayClose(request, cause: cause, fromBridge: fromBridge) else { return nil }
        requests[id] = nil
        sequence[id] = nil
        return request
    }

    /// Closes every open request of the session that `matches`, oldest first.
    @discardableResult
    mutating func close(in sessionID: String, cause: AttentionCloseCause, fromBridge: Bool = false,
                        where matches: (AttentionRequest) -> Bool) -> [AttentionRequest] {
        open(in: sessionID).filter(matches).compactMap { close($0.id, cause: cause, fromBridge: fromBridge) }
    }

    /// Everything kept for a session (its requests close as `sessionGone`).
    @discardableResult
    mutating func forget(_ sessionID: String) -> [AttentionRequest] {
        toolUses[sessionID] = nil
        return close(in: sessionID, cause: .sessionGone) { _ in true }
    }

    // MARK: Tool calls

    /// A PreToolUse: an open request of the same agent, tool and input with no call id yet takes this one's; else it
    /// is kept a while for a request that arrives after it.
    mutating func noteToolUse(sessionID: String, _ use: ToolUse) {
        if let match = open(in: sessionID).first(where: { $0.toolUseID == nil && Self.matches($0, use) }) {
            requests[match.id]?.toolUseID = use.toolUseID
            return
        }
        var uses = (toolUses[sessionID] ?? []).filter { use.at.timeIntervalSince($0.at) < Self.toolUseMemory }
        uses.append(use)
        if uses.count > Self.toolUseLimit { uses.removeFirst(uses.count - Self.toolUseLimit) }
        toolUses[sessionID] = uses
    }

    /// The call a tool event names (PostToolUse, PostToolUseFailure, PermissionDenied): the request with that call's
    /// id, or else one of the same agent, tool and input with no id. Never a sibling: another call's evidence closes
    /// nothing.
    mutating func closeForToolEvidence(sessionID: String, agentID: String?, toolUseID: String?, toolName: String?,
                                       digest: String?) -> [AttentionRequest] {
        forgetToolUse(sessionID: sessionID, toolUseID: toolUseID)
        let open = open(in: sessionID).filter { $0.agentID == agentID }
        if let toolUseID, let exact = open.first(where: { $0.toolUseID == toolUseID }) {
            return [close(exact.id, cause: .toolEvidence)].compactMap { $0 }
        }
        let use = ToolUse(agentID: agentID, toolName: toolName, digest: digest, toolUseID: toolUseID ?? "", at: .distantPast)
        guard digest != nil, let loose = open.first(where: { $0.toolUseID == nil && Self.matches($0, use) }) else { return [] }
        return [close(loose.id, cause: .toolEvidence)].compactMap { $0 }
    }

    private mutating func takeToolUse(for request: AttentionRequest) -> ToolUse? {
        guard var uses = toolUses[request.sessionID],
              let index = uses.lastIndex(where: { Self.matches(request, $0) }) else { return nil }
        let use = uses.remove(at: index)
        toolUses[request.sessionID] = uses.isEmpty ? nil : uses
        return use
    }

    private mutating func forgetToolUse(sessionID: String, toolUseID: String?) {
        guard let toolUseID, var uses = toolUses[sessionID] else { return }
        uses.removeAll { $0.toolUseID == toolUseID }
        toolUses[sessionID] = uses.isEmpty ? nil : uses
    }

    /// Same agent, same tool, same input digest (a request with no digest never matches loosely).
    static func matches(_ request: AttentionRequest, _ use: ToolUse) -> Bool {
        guard let digest = request.inputDigest, digest == use.digest else { return false }
        return request.agentID == use.agentID && (request.toolName == nil || use.toolName == nil || request.toolName == use.toolName)
    }
}
