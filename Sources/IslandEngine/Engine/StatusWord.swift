import Foundation
import OpenIslandCore

/// What a main agent waits on (P510): background agents, and Claude's workflows.
public struct SubagentWait: Equatable, Sendable {
    public var agents: Int
    public var workflows: Int

    public init(agents: Int, workflows: Int = 0) {
        self.agents = agents
        self.workflows = workflows
    }

    public var total: Int { agents + workflows }
}

/// The one word (or tool) a row's second line shows. Derived for display only; SessionPhase is not extended.
public enum StatusWord: Equatable, Sendable {
    case needsApproval(tool: String?)
    case question
    case tool(name: String, detail: String?)
    /// Claude's permission check denied a tool and Claude goes on (PermissionDenied): activity, not a finished turn.
    case denied(tool: String?)
    case thinking
    case compacting
    case working
    /// A main agent that waits on its subagents: how many agents, and how many of Claude's workflows (P510). A Claude
    /// session whose main turn ended while background agents or workflows it started still run (P370, P510), or a Codex
    /// chat whose turn waits on its running subagents, or whose turn ended while they run (P212, P513). Drawn in the
    /// delegate teal. `SessionEngine.statusWord(for:)` gives it; `of(_:interrupted:)` never does.
    case subagents(Int, workflows: Int = 0)
    /// A Codex chat whose review runs (`/review`, the app's Review, P217), from the chat's own rollout, which says it
    /// entered review mode. `SessionEngine.statusWord(for:)` keeps it until the turn ends.
    case reviewing
    case done
    /// The turn was cancelled (Esc or Ctrl-C), which upstream shows as done.
    case interrupted
    /// The turn ended in a StopFailure (an API error or a rate limit), named by the context note: it needs you.
    /// `SessionEngine.statusWord(for:)` gives it; `of(_:interrupted:)` never does.
    case failed

    /// The summary a Codex chat's rollout fold gives a review's start (`RolloutFolder.applyReviewStart`).
    public static let reviewingSummary = "Reviewing."

    /// "Waiting on 1 agent", "Waiting on 3 agents", "Waiting on 1 workflow", "Waiting on 2 agents · 1 workflow" (P510).
    public static func subagentsText(_ count: Int, workflows: Int = 0) -> String {
        let parts = [Self.counted(count, "agent"), Self.counted(workflows, "workflow")].compactMap { $0 }
        return "Waiting on " + (parts.isEmpty ? "0 agents" : parts.joined(separator: " · "))
    }

    private static func counted(_ count: Int, _ noun: String) -> String? {
        count > 0 ? "\(count) \(noun)\(count == 1 ? "" : "s")" : nil
    }

    /// The summary SessionEngine gives a PermissionDenied, which it applies as running activity.
    public static func deniedSummary(tool: String?) -> String {
        tool.map { "Denied · \($0)" } ?? "Denied"
    }

    /// A running session whose last activity is PreCompact's (`… is compacting the conversation.`, upstream's bridge):
    /// it compacts until its next activity, request or completion; compaction's own SessionStart keeps it (P3).
    public static func isCompacting(_ session: AgentSession) -> Bool {
        session.phase == .running && session.summary.hasSuffix("is compacting the conversation.")
    }

    public static func of(_ session: AgentSession, interrupted: Bool) -> StatusWord {
        switch session.phase {
        case .waitingForApproval:
            return .needsApproval(tool: session.permissionRequest?.toolName)
        case .waitingForAnswer:
            return .question
        case .completed:
            return interrupted ? .interrupted : .done
        case .running:
            if isCompacting(session) { return .compacting }
            if session.tool == .codex, session.summary == reviewingSummary { return .reviewing }
            if session.summary == deniedSummary(tool: nil) { return .denied(tool: nil) }
            if session.summary.hasPrefix(deniedSummary(tool: "")) {
                return .denied(tool: String(session.summary.dropFirst(deniedSummary(tool: "").count)))
            }
            if let tool = session.currentToolName, !tool.isEmpty {
                return .tool(name: tool, detail: session.currentCommandPreviewText)
            }
            if session.summary == "Thinking." { return .thinking }
            return .working
        }
    }
}
