import Foundation
import IslandEngine
import OpenIslandCore

/// Claude Code and Codex side by side, for the agent colours and chat titles (P200-P208): each session titled as its
/// agent titles it (`loadTitles`: Claude's `ai-title` line, Codex's `session_index.jsonl` line), one Claude session with
/// no title yet (its first prompt titles it), one renamed at length, and OpenCode's question titled by its first prompt.
/// Fictional folders (C22).
extension FixtureSessionFeed {
    enum LookID {
        static let claudeApproval = "look-claude-approval"
        static let codexApproval = "look-codex-approval"
        static let openCodeQuestion = "opencode-ses_look_branch"
        static let claudeRunning = "look-claude-running"
        static let codexRunning = "look-codex-running"
        static let claudeUntitled = "look-claude-untitled"
        static let claudeLong = "look-claude-long"
    }

    /// A name renamed at the length Claude allows (`/rename`, 200 characters at most).
    static let longTitle = "Rework the island's card spacing so approvals, questions and done cards share one rhythm "
        + "across Clean and Detailed, then check every card against the owner's screenshots and the prototype"

    static func lookEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events: [AgentEvent] = []
        // Claude asks to push.
        events += start(LookID.claudeApproval, title: "Ship the window mode", project: "juice-island", prompt: "push the branch", at: now - 9 * m)
        events.append(claudeApproval(LookID.claudeApproval, "Bash", useID: "toolu_demo_push", shown: pushCommand, at: now - 3 * m))
        // Codex asks to run the tests (its automatic title: at most 36 characters).
        events += start(LookID.codexApproval, title: "Fix the flaky upload test", project: "notes-site", prompt: "fix the flaky test",
                        tool: .codex, at: now - 7 * m)
        events.append(codexApproval(LookID.codexApproval, command: "npm test -- --watch=false",
                                    justification: "Run the test suite once to check the fix?", useID: "call_look_test", at: now - 2 * m))
        // OpenCode asks which branch: its title is its first prompt.
        let id = LookID.openCodeQuestion
        events += openCodeStart(id, project: "notes-site", prompt: "ship the release", at: now - 6 * m)
        var asked = openCodePayload(id, project: "notes-site", event: .questionAsked)
        asked.questionID = "que_look_branch"
        asked.questionText = "Which branch should the release go out from?"
        asked.questions = [OpenCodeQuestionPayload(question: "Which branch should the release go out from?", header: "Question 1", options: [
            OpenCodeQuestionOptionPayload(label: "main", description: "What is merged today."),
            OpenCodeQuestionOptionPayload(label: "release/0.4", description: "Cut last week, fixes only."),
        ])]
        events.append(.questionAsked(QuestionAsked(sessionID: id, prompt: asked.questionPrompt, timestamp: now - 1 * m)))
        // Claude edits a file.
        events += start(LookID.claudeRunning, title: "Tighten the card spacing", project: "WeatherStation", prompt: "tighten the cards",
                        at: now - 30 * m)
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: LookID.claudeRunning, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "now the footer", currentTool: "Edit", currentToolInputPreview: "App/Cards/CardStyle.swift"), timestamp: now - 4 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: LookID.claudeRunning, summary: "Running Edit", phase: .running,
                                                              timestamp: now - 4 * m)))
        // Codex resizes images.
        events += start(LookID.codexRunning, title: "Resize the MCP images for the docs", project: "Desktop", prompt: "resize the mcp images",
                        tool: .codex, at: now - 20 * m)
        events.append(.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: LookID.codexRunning, codexMetadata: CodexSessionMetadata(
            transcriptPath: demoRollout(LookID.codexRunning), lastUserPrompt: "resize the mcp images", currentTool: "exec_command", currentCommandPreview: "sips -Z 512 *.png"),
            timestamp: now - 5 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: LookID.codexRunning, summary: "Running exec_command", phase: .running,
                                                              timestamp: now - 5 * m)))
        // Claude's first turn, before its generated title lands: upstream's own title, so the first prompt titles it.
        events += start(LookID.claudeUntitled, title: "Claude · MarathonTrainingLog", project: "MarathonTrainingLog",
                        prompt: "compare the three runs and write up what changed", at: now - 1 * m)
        // Claude renamed at length, finished.
        events += start(LookID.claudeLong, title: longTitle, project: "juice-island", prompt: "rework the card spacing", at: now - 50 * m)
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: LookID.claudeLong, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "rework the card spacing", lastAssistantMessage: "Every card now shares the 8 pt rhythm."), timestamp: now - 40 * m)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: LookID.claudeLong, summary: "Every card now shares the 8 pt rhythm.",
                                                         timestamp: now - 40 * m)))
        return events
    }
}
