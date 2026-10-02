import Foundation
@testable import IslandEngine
import OpenIslandCore

/// Events shaped the way upstream's bridge and rollout watcher emit them. Folder names are fictional.
enum EngineFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
        var current: Value { lock.withLock { value } }
    }

    /// A SessionStart. `source` is what Claude sends (startup, resume, compact); a start the bridge makes up for a
    /// late hook has none (`BridgeServer.ensureClaudeSessionExists`).
    static func started(_ id: String, tool: AgentTool = .claudeCode, transcript: String? = nil, cwd: String = "/tmp/project",
                        source: ClaudeSessionStartSource? = .startup, title: String = "Claude · project",
                        phase: SessionPhase = .running, terminal: String = "Terminal", terminalID: String? = nil,
                        at date: Date = now) -> AgentEvent {
        .sessionStarted(SessionStarted(
            sessionID: id, title: title, tool: tool, origin: .live, initialPhase: phase, summary: "Started.", timestamp: date,
            jumpTarget: JumpTarget(terminalApp: terminal, workspaceName: "project", paneTitle: "claude",
                                   workingDirectory: cwd, terminalSessionID: terminalID, terminalTTY: "/dev/ttys003"),
            codexMetadata: tool == .codex ? CodexSessionMetadata(transcriptPath: transcript) : nil,
            claudeMetadata: tool == .claudeCode ? ClaudeSessionMetadata(transcriptPath: transcript, startupSource: source) : nil))
    }

    /// UserPromptSubmit, as the bridge sends it.
    static func prompt(_ id: String, _ text: String = "fix the tests", at date: Date = now) -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: id, summary: SignalPipeline.promptPrefix + text, phase: .running, timestamp: date))
    }

    /// PreToolUse, PostToolUse, SubagentStart and the other hooks the bridge turns into a running activity.
    static func running(_ id: String, summary: String = "Running Bash: ls", at date: Date = now) -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: id, summary: summary, phase: .running, timestamp: date))
    }

    /// PreCompact, as the bridge sends it.
    static func compacting(_ id: String, at date: Date = now) -> AgentEvent {
        running(id, summary: "Claude Code is compacting the conversation.", at: date)
    }

    /// Stop (or Esc, with `interrupted`). The bridge's summary is Claude's last message.
    static func completed(_ id: String, interrupted: Bool = false, at date: Date = now) -> AgentEvent {
        .sessionCompleted(SessionCompleted(sessionID: id, summary: "Done.", timestamp: date, isInterrupt: interrupted))
    }

    /// PermissionDenied, as the bridge sends it: first the tool from the hook's `tool_name` in the session's metadata,
    /// then the same completion as Stop with its fixed summary (BridgeServer.swift:845-860; the hook has no `error`).
    static func permissionDenied(_ id: String, tool: String = "Bash", at date: Date = now) -> [AgentEvent] {
        [.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(currentTool: tool),
                                                                    timestamp: date)),
         .sessionCompleted(SessionCompleted(sessionID: id, summary: "Claude Code permission was denied.", timestamp: date))]
    }

    static func sessionEnd(_ id: String, at date: Date = now) -> AgentEvent {
        .sessionCompleted(SessionCompleted(sessionID: id, summary: "Claude Code session ended.", timestamp: date,
                                           isInterrupt: true, isSessionEnd: true))
    }

    static let gitPushRule = ClaudePermissionUpdate.addRules(
        destination: .localSettings, rules: [ClaudePermissionRuleValue(toolName: "Bash", ruleContent: "git push:*")], behavior: .allow)

    /// A Claude PermissionRequest as the bridge makes it: "Allow Bash", upstream's fixed sentence, and the command as
    /// the affected path (`ClaudeHooks.swift` `permissionRequestTitle`, `permissionRequestSummary`, `permissionAffectedPath`).
    static func permission(_ id: String, toolUseID: String? = "toolu_1", at date: Date = now) -> AgentEvent {
        .permissionRequested(PermissionRequested(sessionID: id, request: PermissionRequest(
            title: "Allow Bash", summary: "Claude Code wants to run Bash.", affectedPath: "git push origin main",
            primaryActionTitle: "Allow Once", secondaryActionTitle: "Deny", toolName: "Bash", toolUseID: toolUseID,
            suggestedUpdates: [.setMode(destination: .session, mode: .bypassPermissions), gitPushRule]), timestamp: date))
    }

    static func question(_ id: String, at date: Date = now) -> AgentEvent {
        .questionAsked(QuestionAsked(sessionID: id, prompt: QuestionPrompt(title: "Which branch?", options: ["main", "dev"]), timestamp: date))
    }

    /// What a rollout watcher sends for a new user message: the metadata, then the activity it writes for the
    /// message (CodexSessionTracking.swift, `applyUserMessage` and `events(from:to:)`). The text may repeat the last one.
    static func rolloutPrompt(_ id: String, _ text: String, at date: Date = now) -> [AgentEvent] {
        [.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: id, codexMetadata: CodexSessionMetadata(lastUserPrompt: text), timestamp: date)),
         .activityUpdated(SessionActivityUpdated(sessionID: id, summary: SignalPipeline.promptPrefix + text, phase: .running, timestamp: date))]
    }
}
