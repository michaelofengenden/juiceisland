import Foundation
import OpenIslandCore

/// How sessions end and come back, around upstream's reducer and process monitor (P3, P5, P7).
/// Pure: SessionEngine asks `gate` before it applies an event, tells `noteApplied` after, and passes every process
/// monitor pass through `review`. Upstream's `SessionState` and `ProcessMonitoringCoordinator` stay unchanged.
struct SessionLifecycle: Sendable {
    /// How long an ended session's id stays closed to late events.
    static let tombstoneLifetime: TimeInterval = 600
    /// A session with a hook event this recent is never ended by process polling.
    static let recentHookWindow: TimeInterval = 600
    /// Upstream ends a session after its 2nd missed poll (SessionState.swift:445-452, polls every 60 s,
    /// ProcessMonitoringCoordinator.swift:53); here it takes 3 in a row.
    static let missesToEnd = 3

    enum Gate: Equatable, Sendable {
        case apply
        /// A late event for a session that ended less than 10 minutes ago, or a rollout trying to reopen a turn
        /// the bridge finished, without a new prompt.
        case drop
        /// A new prompt for an ended session: apply `prefix` (the start the bridge sent for it), reopen, then apply.
        case revive(prefix: [AgentEvent])
        /// SessionStart for a session that is still live (compaction, resume): this replaces it, keeping its phase,
        /// title, summary and children (P3). "Compacting" therefore lasts through compaction's own SessionStart,
        /// until the next activity, request or completion replaces the summary.
        case merge(AgentSession)
    }

    private(set) var tombstones: [String: Date] = [:]
    private(set) var lastHookEventAt: [String: Date] = [:]
    private(set) var reprieves: [String: Int] = [:]
    private(set) var promptSinceCompletion: Set<String> = []
    /// Sessions whose last completion came from the bridge (a Stop hook).
    private(set) var bridgeCompleted: Set<String> = []
    private var heldStarts: [String: AgentEvent] = [:]

    mutating func gate(_ event: AgentEvent, sessionID: String, ingress: TrackedEventIngress, current: AgentSession?,
                       now: Date) -> Gate {
        if let endedAt = tombstones[sessionID], now.timeIntervalSince(endedAt) < Self.tombstoneLifetime {
            switch event {
            case let .sessionStarted(payload) where ingress == .bridge && Self.isRealSessionStart(payload):
                tombstones[sessionID] = nil
                heldStarts[sessionID] = nil
                return .apply
            case .sessionStarted where ingress == .bridge:
                // The bridge re-creates a session it no longer knows for any late hook; keep it in case a prompt follows.
                heldStarts[sessionID] = event
                return .drop
            case let .activityUpdated(payload) where ingress == .bridge && payload.summary.hasPrefix(SignalPipeline.promptPrefix):
                tombstones[sessionID] = nil
                let held = heldStarts.removeValue(forKey: sessionID)
                return .revive(prefix: current == nil ? [held].compactMap { $0 } : [])
            default:
                return .drop
            }
        }
        // Upstream's guard (AppModel.swift:1551-1556 at 1.2.1): a rollout read before `task_complete` was flushed must
        // not reopen a turn the bridge's Stop already finished. A new prompt since that Stop may. Only a bridge
        // completion can race a stale read: after the rollout's own completion, a running rollout is its next turn
        // (task_started or a user message, even one with the same text as the last).
        if ingress == .rollout, case let .activityUpdated(payload) = event, payload.phase == .running,
           current?.phase == .completed, bridgeCompleted.contains(sessionID), !promptSinceCompletion.contains(sessionID) {
            return .drop
        }
        if case let .sessionStarted(payload) = event, ingress == .bridge, let current, !current.isSessionEnded {
            return .merge(Self.mergedStart(payload, into: current))
        }
        return .apply
    }

    mutating func noteApplied(_ event: AgentEvent, sessionID: String, ingress: TrackedEventIngress,
                              before: AgentSession?, now: Date) {
        if ingress == .bridge { lastHookEventAt[sessionID] = now }
        if SignalPipeline.isNewPrompt(event, ingress: ingress, before: before) { promptSinceCompletion.insert(sessionID) }
        if case let .sessionCompleted(payload) = event {
            promptSinceCompletion.remove(sessionID)
            if ingress == .bridge { bridgeCompleted.insert(sessionID) } else { bridgeCompleted.remove(sessionID) }
            if payload.isSessionEnd == true { noteEnded(sessionID, at: now) }
        }
    }

    mutating func noteEnded(_ sessionID: String, at date: Date) {
        tombstones[sessionID] = date
        reprieves[sessionID] = nil
    }

    /// Every session it keeps anything for.
    var sessionIDs: Set<String> {
        Set(tombstones.keys).union(lastHookEventAt.keys).union(reprieves.keys).union(promptSinceCompletion)
            .union(bridgeCompleted).union(heldStarts.keys)
    }

    /// Sessions still closed to late events (a tombstone, and the start it holds): kept while they are gone from the
    /// state, until the tombstone expires.
    var closedIDs: Set<String> { Set(tombstones.keys).union(heldStarts.keys) }

    /// Forgets a session that left the state (`SessionEngine.forgetSession`).
    mutating func forget(_ sessionID: String) {
        tombstones[sessionID] = nil
        heldStarts[sessionID] = nil
        lastHookEventAt[sessionID] = nil
        reprieves[sessionID] = nil
        bridgeCompleted.remove(sessionID)
        promptSinceCompletion.remove(sessionID)
    }

    /// Tombstones older than 10 minutes; each id is returned once, so the engine can forget it everywhere.
    mutating func expire(now: Date) -> [String] {
        let expired = tombstones.filter { now.timeIntervalSince($0.value) >= Self.tombstoneLifetime }.keys.sorted()
        for id in expired {
            tombstones[id] = nil
            heldStarts[id] = nil
            lastHookEventAt[id] = nil
            bridgeCompleted.remove(id)
            promptSinceCompletion.remove(id)
        }
        return expired
    }

    /// P7: looks at what one process-monitor pass did. A session it ended or removed comes back unchanged when it
    /// waits on you or had a hook event in the last 10 minutes; otherwise it comes back once, so ending takes a
    /// third miss in a row. A pass that finds the process again resets the count. Sessions that stay ended are
    /// tombstoned.
    mutating func review(old: SessionState, new: SessionState, now: Date,
                         waitsOnYou: (AgentSession) -> Bool = { $0.phase.requiresAttention },
                         isEligible: (AgentSession) -> Bool) -> SessionState {
        var restored: [AgentSession] = []
        for session in old.sessions where session.isVisibleInIsland && !session.isSessionEnded && isEligible(session) {
            let after = new.session(id: session.id)
            if let after, after.isVisibleInIsland {
                if after.processNotSeenCount == 0 { reprieves[session.id] = nil }
                continue
            }
            let waitsOnYou = waitsOnYou(session)
            let recentHook = lastHookEventAt[session.id].map { now.timeIntervalSince($0) < Self.recentHookWindow } ?? false
            if waitsOnYou || recentHook {
                reprieves[session.id] = nil
                restored.append(session)
            } else if reprieves[session.id, default: 0] < Self.missesToEnd - 2 {
                reprieves[session.id, default: 0] += 1
                restored.append(session)
            } else {
                noteEnded(session.id, at: now)
            }
        }
        guard !restored.isEmpty else { return new }
        let restoredIDs = Set(restored.map(\.id))
        return SessionState(sessions: new.sessions.filter { !restoredIDs.contains($0.id) } + restored)
    }

    /// A SessionStart for a live session keeps what the session already shows (phase, title, summary, request,
    /// children and tasks) and takes the start's jump target and file metadata. Upstream would rebuild the session
    /// as completed with none of its children (SessionState.swift:58-90). The flags that decide how the session ends
    /// (hook-managed, remote, Codex.app) are the ones upstream's own reducer gives the start, so a session first
    /// found in a transcript and then resumed live follows its hooks from then on.
    static func mergedStart(_ start: SessionStarted, into existing: AgentSession) -> AgentSession {
        var merged = existing
        var scratch = SessionState()
        scratch.apply(.sessionStarted(start))
        if let fresh = scratch.session(id: start.sessionID) {
            merged.isRemote = fresh.isRemote
            // Upstream never downgrades a Codex.app classification (SessionState.swift:353-365).
            merged.isCodexAppSession = existing.isCodexAppSession || fresh.isCodexAppSession
            merged.isHookManaged = merged.isCodexAppSession ? false : fresh.isHookManaged
        }
        if let jumpTarget = start.jumpTarget { merged.jumpTarget = jumpTarget }
        if let incoming = start.claudeMetadata {
            var metadata = existing.claudeMetadata ?? ClaudeSessionMetadata()
            metadata.transcriptPath = incoming.transcriptPath ?? metadata.transcriptPath
            metadata.model = incoming.model ?? metadata.model
            metadata.startupSource = incoming.startupSource ?? metadata.startupSource
            metadata.permissionMode = incoming.permissionMode ?? metadata.permissionMode
            metadata.worktreeBranch = incoming.worktreeBranch ?? metadata.worktreeBranch
            merged.claudeMetadata = metadata
        }
        if let incoming = start.codexMetadata {
            var metadata = existing.codexMetadata ?? CodexSessionMetadata()
            metadata.transcriptPath = incoming.transcriptPath ?? metadata.transcriptPath
            merged.codexMetadata = metadata
        }
        merged.updatedAt = max(existing.updatedAt, start.timestamp)
        merged.attachmentState = .attached
        merged.isProcessAlive = true
        merged.processNotSeenCount = 0
        return merged
    }

    /// A SessionStart the agent sent, not one the bridge made up for a late hook. Claude's carries its source
    /// (startup, resume, clear, compact); Codex's summary names the start (CodexHooks.swift:411-418 at 1.2.1).
    static func isRealSessionStart(_ start: SessionStarted) -> Bool {
        switch start.tool {
        case .codex:
            return start.summary.hasPrefix("Started Codex session") || start.summary.hasPrefix("Resumed Codex session")
        default:
            if start.claudeMetadata != nil || start.tool == .claudeCode { return start.claudeMetadata?.startupSource != nil }
            return true
        }
    }
}
