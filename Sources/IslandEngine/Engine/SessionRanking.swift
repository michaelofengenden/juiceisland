import Foundation
import OpenIslandCore

/// Which sessions the lists show and in what order: upstream's AppModel rule (computeSessionBuckets and
/// displayPriority, AppModel.swift:1745-1835 at v1.2.1), moved here unchanged so the island and window agree with it.
enum SessionRanking {
    static let completedStaleThreshold = IslandCompletedStaleThreshold.fiveMinutes.seconds

    /// `needsAttention` is upstream's "requires attention" (an approval or a question), widened by the engine to a
    /// failed turn (spec §3.4), so a StopFailure ranks and places like a waiting session. `runs`: a session whose main
    /// turn ended while its subagents run ranks as a running one (P370). `archived`: one the owner archived that
    /// upstream's rule would still show (a session that is not hook-managed, its process alive) goes to the overflow
    /// (P729).
    static func buckets(sessions: [AgentSession], now: Date,
                        needsAttention: (AgentSession) -> Bool = { $0.phase.requiresAttention },
                        runs: (AgentSession) -> Bool = { _ in false },
                        archived: (AgentSession) -> Bool = { _ in false },
                        liveAttachmentKey: (AgentSession) -> String?) -> (primary: [AgentSession], overflow: [AgentSession]) {
        let ranked = sessions.sorted { lhs, rhs in
            let lhsScore = displayPriority(for: lhs, now: now, needsAttention: needsAttention(lhs), runs: runs(lhs))
            let rhsScore = displayPriority(for: rhs, now: now, needsAttention: needsAttention(rhs), runs: runs(rhs))
            if lhsScore == rhsScore {
                if lhs.islandActivityDate == rhs.islandActivityDate {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.islandActivityDate > rhs.islandActivityDate
            }
            return lhsScore > rhsScore
        }

        var primary: [AgentSession] = []
        var claimedKeys: Set<String> = []
        for session in ranked where session.isVisibleInIsland && !archived(session) {
            guard !session.isSubagentSession else { continue }
            if let key = liveAttachmentKey(session) {
                guard claimedKeys.insert(key).inserted else { continue }
            }
            primary.append(session)
        }
        let primaryIDs = Set(primary.map(\.id))
        let overflow = ranked.filter { !primaryIDs.contains($0.id) && !$0.isSubagentSession }
        return (primary, overflow)
    }

    static func displayPriority(for session: AgentSession, now: Date, needsAttention: Bool? = nil, runs: Bool = false) -> Int {
        let needsAttention = needsAttention ?? session.phase.requiresAttention
        var score = 0
        let presence = session.islandPresence(at: now)
        if session.isProcessAlive {
            score += presence == .inactive ? 3_000 : 12_000
        } else if session.isDemoSession || needsAttention {
            score += 6_000
        }
        if needsAttention { score += 10_000 }
        if session.currentToolName?.isEmpty == false { score += 6_000 }
        if session.jumpTarget != nil { score += 4_000 }
        switch runs ? .running : session.phase {
        case .running: score += 2_000
        case .waitingForApproval: score += 1_500
        case .waitingForAnswer: score += 1_200
        case .completed: score += 600
        }
        if !runs, session.isStaleCompletedForIsland(at: now, threshold: completedStaleThreshold) { score -= 900 }
        switch now.timeIntervalSince(session.islandActivityDate) {
        case ..<120: score += 500
        case ..<900: score += 250
        case ..<3_600: score += 120
        case ..<21_600: score += 40
        default: break
        }
        return score
    }
}
