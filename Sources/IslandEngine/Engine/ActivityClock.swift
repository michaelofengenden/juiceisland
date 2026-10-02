import Foundation
import OpenIslandCore

/// When a session's current turn and its current tool began, and when its compaction did. `updatedAt` moves with every
/// event, so a time measured from it restarts whenever a long tool reports progress; these stay put until a new turn or
/// another tool starts, and a compaction's until it ends (P433).
struct ActivityClock: Equatable, Sendable {
    var turnStartedAt: Date
    var tool: String?
    var toolStartedAt: Date?
    /// When the compaction under way began: the PreCompact that started it. It lasts through compaction's own
    /// SessionStart, which keeps the session's summary (P3), and goes with the next activity.
    var compactingSince: Date?

    /// The clock once `event` has moved the session from `before` to `after`: a new turn after a finished one or on
    /// a new prompt, a new tool start when the tool's name changes. nil once the turn is over.
    static func next(_ current: ActivityClock?, event: AgentEvent, ingress: TrackedEventIngress,
                     before: AgentSession?, after: AgentSession?) -> ActivityClock? {
        guard let after, after.phase != .completed else { return nil }
        let at = after.updatedAt
        var clock = current ?? ActivityClock(turnStartedAt: at)
        if before == nil || before?.phase == .completed || SignalPipeline.isNewPrompt(event, ingress: ingress, before: before) {
            clock = ActivityClock(turnStartedAt: at)
        }
        let tool = after.currentToolName.flatMap { $0.isEmpty ? nil : $0 }
        if tool != clock.tool {
            clock.tool = tool
            clock.toolStartedAt = tool == nil ? nil : at
        }
        if StatusWord.isCompacting(after) {
            if clock.compactingSince == nil { clock.compactingSince = at }
        } else {
            clock.compactingSince = nil
        }
        return clock
    }
}
