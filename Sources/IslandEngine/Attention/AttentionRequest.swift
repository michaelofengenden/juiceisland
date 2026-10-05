import Foundation
import OpenIslandCore

/// One thing an agent waits on the owner for (an approval, a plan, a question, an MCP form), with its own id. The
/// engine's `AttentionBook` keeps them; "!" and "?" are drawn only from confirmed ones, never from a session's phase,
/// a rollout line, a restored record, a PreToolUse or a Notification on its own (P161).
public struct AttentionRequest: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case approval, plan, question, elicitation

        /// "!" for an approval or a plan, "?" for a question or a form.
        public var isQuestion: Bool { self == .question || self == .elicitation }
    }

    /// Who can answer it.
    public enum Channel: Equatable, Sendable {
        /// The island holds the agent's hook and can answer it; the agent shows its own prompt at the same time
        /// (Claude), or waits on the island alone (Codex behind the old helper).
        case answer(Holder)
        /// Show and jump only: the agent's own prompt is where it is answered.
        case open
    }

    /// What holds an answerable request's hook.
    public enum Holder: String, Equatable, Sendable {
        /// The engine's request broker, over the request's own connection.
        case broker
        /// Upstream's bridge (a helper not yet updated, or another agent's plugin): answered by session.
        case bridge
    }

    public enum Source: String, Equatable, Sendable, CaseIterable {
        case broker, bridge, rollout, notification
    }

    public enum State: String, Equatable, Sendable {
        /// Asked, not yet confirmed: draws, counts and sounds nothing (C1).
        case pending
        /// The agent itself says the owner is away from its prompt, or the request stayed open long enough.
        case confirmed
        /// Released by its confirmation window unconfirmed: not drawn, kept only until evidence closes it, and
        /// revived by a later `permission_prompt` (C3).
        case dormant
    }

    /// Where Open goes, and what a read-only card names.
    public enum Place: String, Equatable, Sendable {
        case terminal, claudeApp, codexApp, ide
    }

    /// What the card shows: upstream's request or question, so the cards and `approve` keep working.
    public enum Content: Equatable, Sendable {
        case approval(PermissionRequest)
        case question(QuestionPrompt)
        /// A prompt with no hook behind it (a sandbox network prompt, an MCP form): the notification's kind only.
        case notice
    }

    public let id: String
    /// The root session (a subagent's request sits on its parent's row).
    public let sessionID: String
    public var agentID: String?
    public var agentType: String?
    public let kind: Kind
    public var channel: Channel
    public let source: Source
    public let tool: AgentTool
    public var toolName: String?
    public var toolUseID: String?
    public var inputDigest: String?
    /// Codex: the call this request is about, once matched, or the question's call.
    public var callID: String?
    public var turnID: String?
    /// Codex: the requesting thread's rollout (a subagent's own, C5).
    public var rolloutPath: String?
    /// Claude: the transcript whose `tool_result` for `toolUseID` closes it (a subagent's own, C9).
    public var transcriptPath: String?
    /// The command a Codex approval is about, to match it to its call.
    public var command: String?
    /// A Codex async question's items already answered through the hook (one reply envelope per question, P184).
    public var answeredItems: Set<Int> = []
    /// A Codex approval with a call of its own whose output closes it; false for a network approval, a `write_stdin`
    /// or a tool with no name, which close on turn end, Open or ✕ only (C7).
    public var hasOwnCall = true
    public var content: Content
    public let openedAt: Date
    public var confirmedAt: Date?
    public var state: State
    public var agentPID: Int32?
    public var entrypoint: String?
    public var place: Place
    /// The needs-you sound went out for it: a revival never sounds again.
    public var sounded = false
    /// Its confirmation window releases it (dormant) instead of confirming it: an armed Claude surface, where the
    /// agent's own `permission_prompt` says it waits.
    public var windowReleases: Bool
    /// A Claude subagent's request the broker holds for the island (Settings › Island › Answer subagents on the island,
    /// P350): when the hold ends at the latest, and the card turns read-only. nil for every other request, and once the
    /// hold ended (`SessionEngine.endSubagentHold`).
    public var holdEndsAt: Date?
    /// Claude: the permission mode the hook said the session was in when it asked (`permission_mode`; the last context
    /// note's for the bridge's). A mode button never offers it again (`ApprovalChoices.modes`).
    public var permissionMode: String?

    public init(id: String, sessionID: String, agentID: String? = nil, agentType: String? = nil, kind: Kind,
                channel: Channel, source: Source, tool: AgentTool, toolName: String? = nil, toolUseID: String? = nil,
                inputDigest: String? = nil, callID: String? = nil, turnID: String? = nil, rolloutPath: String? = nil,
                transcriptPath: String? = nil, command: String? = nil, content: Content, openedAt: Date,
                state: State = .pending, agentPID: Int32? = nil, entrypoint: String? = nil, place: Place = .terminal,
                windowReleases: Bool = false) {
        self.id = id
        self.sessionID = sessionID
        self.agentID = agentID
        self.agentType = agentType
        self.kind = kind
        self.channel = channel
        self.source = source
        self.tool = tool
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.inputDigest = inputDigest
        self.callID = callID
        self.turnID = turnID
        self.rolloutPath = rolloutPath
        self.transcriptPath = transcriptPath
        self.command = command
        self.content = content
        self.openedAt = openedAt
        self.state = state
        if state == .confirmed { confirmedAt = openedAt }
        self.agentPID = agentPID
        self.entrypoint = entrypoint
        self.place = place
        self.windowReleases = windowReleases
    }

    public var isConfirmed: Bool { state == .confirmed }
    /// Held for the island while its card shows, Claude's own prompt waiting on it (P350).
    public var isHeldForIsland: Bool { holdEndsAt != nil }
    public var isAnswerable: Bool { if case .answer = channel { true } else { false } }
    /// On the main thread (no subagent).
    public var isRoot: Bool { agentID == nil }
    /// A Codex request upstream's helper holds for the bridge: Codex waits on it and shows nothing, so no engine
    /// rule may hide or close it; only the bridge's own ends do (invariant 6, C4, P166).
    public var isHeldCodexLegacy: Bool { tool == .codex && channel == .answer(.bridge) }
    /// An approval the agent waits on with no prompt of its own while the island holds it: Codex behind the old helper,
    /// and the Claude-format agents the helper answers itself on the bridge, Copilot CLI and Devin (as CodeBuddy's) and
    /// Qwen Code. Copilot shows its own prompt only once the hook gives up, an hour later. Neither No alerts for focused
    /// sessions nor a mute rule keeps it quiet (P931).
    public var waitsOnIslandAlone: Bool {
        guard channel == .answer(.bridge), permissionRequest != nil else { return false }
        return tool == .codex || tool == .codebuddy || tool == .qwenCode
    }

    /// Upstream's request, for an approval or a plan.
    public var permissionRequest: PermissionRequest? {
        if case let .approval(request) = content { request } else { nil }
    }

    /// Upstream's question, for a question.
    public var questionPrompt: QuestionPrompt? {
        if case let .question(prompt) = content { prompt } else { nil }
    }
}

/// Why a request closed (Diagnostics counts them; no text).
public enum AttentionCloseCause: String, Equatable, Sendable, CaseIterable {
    /// Its hook ended: Claude or a timeout killed it, the bridge dropped it, the connection closed.
    case hookEnded
    case islandAnswer
    /// PostToolUse, PostToolUseFailure or PermissionDenied for its call.
    case toolEvidence
    /// The transcript's `tool_result` for its call.
    case transcript
    /// Stop, StopFailure, SessionEnd, a new prompt or turn, an interrupt, `idle_prompt`, SubagentStop.
    case turnEnd
    /// Codex: its call's output, or the question's.
    case rolloutOutput
    case pidGone
    /// Open handed it to the agent (a Codex request with no output of its own).
    case opened
    /// The ✕ on a read-only card.
    case dismissed
    /// Upstream's bridge took a newer request for the session in its one slot.
    case superseded
    /// The session is gone.
    case sessionGone
    /// The agent's own notice says the prompt it stood for is over.
    case noticeCleared
    /// Codex's reviewer takes it: a strict-review grant or a switch to auto review, read just after the request (C6).
    case reviewed
}
