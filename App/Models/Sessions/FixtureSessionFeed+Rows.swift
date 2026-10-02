import Foundation
import IslandEngine
import OpenIslandCore

/// The rows lane's sessions (P310-P312): Claude in plan mode on Opus at xhigh effort with its task list two steps in, Claude
/// on Sonnet in bypass mode stalled after a long test run, a Codex chat on GPT-6 Astra at high effort three steps into its
/// plan (from its rollout's `turn_context` and `update_plan`, as the tracker reads them), and a Claude turn done with a long
/// reply for its peek.
/// Every text, id and folder fictional (C22).
extension FixtureSessionFeed {
    enum RowsID {
        static let claudePlan = "rows-claude-plan"
        static let claudeStalled = "rows-claude-stalled"
        static let codexRunning = "rows-codex-running"
        static let claudeDone = "rows-claude-done"
    }

    static let rowsCodexRollout = "/tmp/juice-island-demo/sessions/rollout-rows-codex-running.jsonl"
    static let rowsStalledCommand = "npm run test:e2e -- --repeat 20"
    static let rowsDoneReply = "Split the upload retries out of the client and gave each its own timeout. The flaky test "
        + "waited on a shared timer; it now passes 50 runs in a row. **Two things left:** the docs still name the old flag, "
        + "and the CI cache key should include the lockfile."
    static let rowsCodexReply = "Moved every settings read behind one store; the migration is next."
    /// Codex's reasoning summary since that reply, as it writes one (`agent_reasoning`, P720).
    static let rowsCodexThinking = "**Checking the old keys**\n\nThe store has to read the old keys until the shims go, "
        + "so the migration copies them once and keeps them for one release."

    static func rowsEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events: [AgentEvent] = []
        // Claude plans on Opus: reading, two of five tasks done.
        events += start(RowsID.claudePlan, title: "Plan the search index", project: "notes-site",
                        prompt: "how should search index the notes? plan it first", at: now - 8 * m, terminal: "Ghostty")
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: RowsID.claudePlan, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "how should search index the notes? plan it first", currentTool: "Read",
            currentToolInputPreview: NSHomeDirectory() + "/Developer/notes-site/search/index.ts", model: "claude-opus-5-5[1m]",
            permissionMode: .plan, activeTasks: [
                ClaudeTaskInfo(id: "1", title: "Read the current index", status: .completed),
                ClaudeTaskInfo(id: "2", title: "List the fields", status: .completed),
                ClaudeTaskInfo(id: "3", title: "Pick the tokenizer", status: .inProgress),
                ClaudeTaskInfo(id: "4", title: "Sketch the schema"),
                ClaudeTaskInfo(id: "5", title: "Write the plan"),
            ]), timestamp: now - 1 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: RowsID.claudePlan, summary: "Running Read", phase: .running,
                                                              timestamp: now - 1 * m)))
        // Claude on Sonnet in bypass mode: its long test run ended 14 minutes ago and nothing has come since (a call still in
        // flight would be at work, P440).
        events += start(RowsID.claudeStalled, title: "Fix the flaky upload test", project: "juice-island",
                        prompt: "run the whole e2e suite until it passes", at: now - 30 * m)
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: RowsID.claudeStalled, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "run the whole e2e suite until it passes", currentTool: "Bash", currentToolInputPreview: rowsStalledCommand,
            model: "claude-sonnet-4-5-20250929", permissionMode: .bypassPermissions), timestamp: now - 14 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: RowsID.claudeStalled, summary: "Bash finished.", phase: .running,
                                                              timestamp: now - 14 * m)))
        // Codex's chat: its hooks' start, then its rollout (`loadRows`).
        events += start(RowsID.codexRunning, title: "Move the settings to one store", project: "field-notes",
                        prompt: "move the settings reads to one store", tool: .codex, at: now - 12 * m, transcript: rowsCodexRollout)
        // Claude done, a long reply.
        events += start(RowsID.claudeDone, title: "Fix the upload retries", project: "notes-site", prompt: "why does the upload test flake",
                        at: now - 40 * m)
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: RowsID.claudeDone, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "fix it and run it 50 times", lastAssistantMessage: rowsDoneReply, model: "claude-opus-5-5"), timestamp: now - 6 * m)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: RowsID.claudeDone, summary: "Split the upload retries", timestamp: now - 6 * m)))
        return events
    }

    /// Codex's rollout: its model, its plan three of seven steps in, a reply, what it thinks since, and a command still
    /// running.
    static func rowsCodexLines(now: Date) -> [String] {
        let t = now - 12 * 60
        let folder = NSHomeDirectory() + "/Developer/field-notes"
        let steps = ["Find every settings read", "Add the store", "Move the reads", "Migrate the old keys", "Delete the shims",
                     "Run the tests", "Write the notes"]
        let plan = steps.enumerated().map { index, step in
            ["step": step, "status": index < 3 ? "completed" : index == 3 ? "in_progress" : "pending"]
        }
        let arguments = try! JSONSerialization.data(withJSONObject: ["plan": plan], options: [.sortedKeys, .withoutEscapingSlashes])
        return [
            rolloutLine("session_meta", ["id": RowsID.codexRunning, "timestamp": stamp(t), "cwd": folder, "originator": "codex_cli_rs",
                                         "cli_version": "0.157.0", "source": "cli"], at: t),
            rolloutLine("turn_context", ["cwd": folder, "model": "gpt-6-astra", "effort": "high", "approval_policy": "on-request",
                                         "approvals_reviewer": "user"], at: t + 1),
            rolloutEvent("user_message", ["message": "move the settings reads to one store", "images": []], at: t + 1),
            rolloutMessage("user", "move the settings reads to one store", at: t + 1),
            rolloutEvent("task_started", ["model_context_window": 272_000], at: t + 2),
            rolloutItem("function_call", ["name": "update_plan", "arguments": String(decoding: arguments, as: UTF8.self),
                                          "call_id": "call_rows_plan"], at: t + 200),
            rolloutItem("function_call_output", ["call_id": "call_rows_plan", "output": "Plan updated"], at: t + 200),
            rolloutEvent("agent_message", ["message": rowsCodexReply], at: t + 590),
            rolloutMessage("assistant", rowsCodexReply, at: t + 590),
            rolloutEvent("agent_reasoning", ["text": rowsCodexThinking], at: t + 595),
            rolloutItem("function_call", ["name": "exec_command", "arguments": #"{"cmd":"swift test --filter SettingsStore"}"#,
                                          "call_id": "call_rows_test"], at: t + 600),
        ]
    }

    /// What the scenario reads besides the bridge's events: Codex's rollout, and the effort Claude's plan runs at, as its
    /// hooks' context note names it (P443).
    static func loadRows(into engine: SessionEngine, now: Date) {
        engine.loadPreviewRollout(sessionID: RowsID.codexRunning, transcriptPath: rowsCodexRollout, lines: rowsCodexLines(now: now))
        engine.loadPreviewNote(event: "PostToolUse", sessionID: RowsID.claudePlan, effort: "xhigh")
    }
}
