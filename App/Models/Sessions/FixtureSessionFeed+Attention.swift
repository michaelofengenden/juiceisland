import Foundation
import IslandEngine
import OpenIslandCore

/// The needs-you design's cases on the demo engine, through the paths the live ones take: hook inputs as the superset
/// helper hands them to the request broker (`loadPreviewHookRequest`, held or released by the policy), Codex rollout
/// lines as the tracker reads them (`loadPreviewRollout`: upstream's reducer and `CodexAttention`), and Claude's
/// notes (`loadPreviewNote`). Inputs in the public shapes (Claude Code's hooks docs, codex-rs `hooks/src/schema.rs`
/// and its rollout items); every text, id and folder fictional (C22).
extension FixtureSessionFeed {
    enum AttentionID {
        /// The owner's first screenshot: a Codex app thread asks with `request_user_input_async` and reasons on.
        static let codexQuestion = "demo-codex-paper"
        /// The owner's first screenshot: a Claude row whose last "prompt" was a background task's notice.
        static let retro = "demo-retro"
        /// Claude in a terminal asks twice (the island holds both hooks): an answerable card, one more behind it.
        static let claudeQueue = "demo-claude-queue"
        /// Codex in a terminal asks to run a command: released to Codex's own prompt, read-only here.
        static let codexApproval = "demo-codex-cli"
        /// A Claude subagent asks: released to Claude's prompt, on its parent's row.
        static let subagent = "demo-claude-worker"
        /// Claude Desktop's own session asks (`local-agent`): released, read-only, answered in Claude.
        static let desktop = "demo-claude-desktop"
        /// Claude says it waits on a prompt no hook stood for (a sandbox network prompt).
        static let notice = "demo-claude-notice"
        /// A turn that ended in a StopFailure.
        static let failed = "demo-turn-failed"
    }

    static let paperRollout = "/tmp/juice-island-demo/sessions/rollout-demo-codex-paper.jsonl"
    static let codexCLIRollout = "/tmp/juice-island-demo/sessions/rollout-demo-codex-cli.jsonl"
    static let paperPrompt = "tidy the figures in section B"
    static let paperQuestion = "Section B also has Figure 4. Should I remove Figure 4 too?"
    static let paperOptions = ["Remove it", "Keep it", "Move it to the appendix"]
    static let retroPrompt = "compare the three agents' retrospectives"
    /// A background task's notice as Claude Code writes it (fictional ids), its newlines as the launch fold flattens
    /// them: what the owner's row showed.
    static let taskNotification = "<task-notification> <task-id>b1a2c3d4</task-id> <tool-use-id>toolu_01ABC</tool-use-id> "
        + "<output-file>/tmp/claude-tasks/b1a2c3d4.output</output-file> <status>completed</status> "
        + "<summary>Background command \"npm run build\" completed (exit code 0)</summary> </task-notification> "
        + "Read the output file to retrieve the result: /tmp/claude-tasks/b1a2c3d4.output"

    // MARK: The owner's two situations

    static func ownerEvents(now: Date) -> [AgentEvent] {
        var events = start(AttentionID.codexQuestion, title: "Codex · field-notes", project: "field-notes", prompt: paperPrompt,
                           tool: .codex, at: now - 160, terminal: "Codex.app", transcript: paperRollout)
        events += start(AttentionID.retro, title: "Claude · retro-notes", project: "retro-notes", prompt: retroPrompt, at: now - 900)
        // The notice arrives as the owner's next prompt: the hook's UserPromptSubmit, and the launch fold's text.
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: AttentionID.retro, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: taskNotification), timestamp: now - 720)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: AttentionID.retro, summary: promptPrefix + taskNotification,
                                                              phase: .running, timestamp: now - 720)))
        return events
    }

    /// The Codex app thread's rollout: the prompt, the async question with its options, `{"accepted":true}`, and the
    /// model reasoning on while the question waits.
    static func paperLines(now: Date) -> [String] {
        let t = now - 150
        let folder = NSHomeDirectory() + "/Developer/field-notes"
        let arguments = try! JSONSerialization.data(withJSONObject: ["questions": [["title": paperQuestion, "options": paperOptions]]],
                                                    options: [.sortedKeys, .withoutEscapingSlashes])
        return [
            rolloutLine("session_meta", ["id": AttentionID.codexQuestion, "timestamp": stamp(t), "cwd": folder, "originator": "codex_desktop",
                                         "cli_version": "0.157.0", "source": "vscode"], at: t),
            rolloutLine("turn_context", ["cwd": folder, "model": "gpt-6", "approval_policy": "on-request", "approvals_reviewer": "user"], at: t + 1),
            rolloutEvent("user_message", ["message": paperPrompt, "images": []], at: t + 1),
            rolloutMessage("user", paperPrompt, at: t + 1),
            rolloutEvent("task_started", ["model_context_window": 272_000], at: t + 2),
            rolloutItem("reasoning", ["summary": [], "encrypted_content": "e30="], at: t + 3),
            rolloutItem("function_call", ["name": "request_user_input_async", "arguments": String(decoding: arguments, as: UTF8.self),
                                          "call_id": "call_demo_fig"], at: t + 30),
            rolloutItem("function_call_output", ["call_id": "call_demo_fig", "output": #"{"accepted":true}"#], at: t + 30),
            rolloutItem("reasoning", ["summary": [], "encrypted_content": "e30="], at: t + 40),
            rolloutEvent("agent_reasoning", ["text": "Going on with section C while the figure question waits."], at: t + 40),
        ]
    }

    // MARK: Requests, answerable and read-only

    static func attentionEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events = start(AttentionID.claudeQueue, title: "Ship the release", project: "notes-site", prompt: "ship the release",
                           at: now - 9 * m, terminal: "Ghostty")
        events += start(AttentionID.codexApproval, title: "Run the migration", project: "field-notes", prompt: "run the migration",
                        tool: .codex, at: now - 7 * m, transcript: codexCLIRollout)
        events += start(AttentionID.subagent, title: "Audit the links", project: "notes-site", prompt: "audit every link", at: now - 6 * m,
                        terminal: "iTerm")
        events += start(AttentionID.desktop, title: "Sort the inbox notes", project: "retro-notes", prompt: "sort the notes", at: now - 5 * m,
                        terminal: "Claude.app")
        events += start(AttentionID.notice, title: "Fetch the dataset", project: "field-notes", prompt: "fetch the dataset", at: now - 4 * m)
        events += start(AttentionID.failed, title: "Summarise the logs", project: "retro-notes", prompt: "summarise the logs", at: now - 12 * m)
        return events
    }

    /// Loads what the scenario reads besides the bridge's events, through the engine's live paths.
    static func loadAttention(_ scenario: Scenario, into engine: SessionEngine, now: Date) {
        switch scenario {
        case .demoSessions:
            loadDemoSessions(into: engine)
        case .owner:
            engine.loadPreviewRollout(sessionID: AttentionID.codexQuestion, transcriptPath: paperRollout, lines: paperLines(now: now))
        case .codexAppContext:
            engine.loadPreviewRollout(sessionID: CodexAppID.thread, transcriptPath: benchRollout, lines: codexAppContextLines(now: now))
        case .attention:
            // Claude in Ghostty holds two requests: git push, then an edit behind it.
            engine.loadPreviewHookRequest(claudeRequest(AttentionID.claudeQueue, tool: "Bash", useID: "toolu_demo_queue_push", input: [
                "command": "git push origin release/0.4", "description": "Push the release branch"]), source: "claude", entrypoint: "cli")
            engine.loadPreviewHookRequest(claudeRequest(AttentionID.claudeQueue, tool: "Edit", useID: "toolu_demo_queue_edit", input: [
                "file_path": NSHomeDirectory() + "/Developer/notes-site/CHANGELOG.md", "old_string": "## Unreleased",
                "new_string": "## 0.4"]), source: "claude", entrypoint: "cli")
            // Codex in a terminal: its thread asks a person (reviewer user), so Codex shows its own prompt and the island
            // shows it read-only.
            engine.loadPreviewRollout(sessionID: AttentionID.codexApproval, transcriptPath: codexCLIRollout, lines: codexCLILines(now: now))
            engine.loadPreviewHookRequest([
                "hook_event_name": "PermissionRequest", "session_id": AttentionID.codexApproval, "turn_id": "turn-demo-1",
                "cwd": NSHomeDirectory() + "/Developer/field-notes", "transcript_path": codexCLIRollout, "model": "gpt-6",
                "permission_mode": "default", "tool_name": "Bash",
                "tool_input": ["command": codexMigration, "description": "Apply the pending migration to the local database?"],
            ], source: "codex")
            // A subagent's request in iTerm, a Claude Desktop session's, and a prompt with no hook behind it.
            engine.loadPreviewHookRequest(claudeRequest(AttentionID.subagent, tool: "Bash", useID: "toolu_demo_worker", input: [
                "command": "curl -sI https://example.com/docs/setup", "description": "Check the setup link"],
                agent: "agent-demo-w1", agentType: "link-checker"), source: "claude", entrypoint: "cli")
            engine.loadPreviewHookRequest(claudeRequest(AttentionID.desktop, tool: "Write", useID: "toolu_demo_desktop", input: [
                "file_path": NSHomeDirectory() + "/Developer/retro-notes/inbox/sorted.md", "content": "# Sorted\n\n- Keep\n- Drop\n"]),
                                          source: "claude", entrypoint: "local-agent", hasTerminal: false)
            engine.loadPreviewNote(event: "Notification", sessionID: AttentionID.notice, notificationType: "permission_prompt")
            engine.loadPreviewNote(event: "StopFailure", sessionID: AttentionID.failed)
            engine.loadPreviewEvents([.sessionCompleted(SessionCompleted(sessionID: AttentionID.failed, summary: "rate_limit",
                                                                         timestamp: now - 60))])
        default:
            break
        }
    }

    static let codexMigration = "python3 scripts/migrate.py --apply --database data/notes.sqlite"

    static func codexCLILines(now: Date) -> [String] {
        let t = now - 420
        let folder = NSHomeDirectory() + "/Developer/field-notes"
        return [
            rolloutLine("session_meta", ["id": AttentionID.codexApproval, "timestamp": stamp(t), "cwd": folder, "originator": "codex_cli_rs",
                                         "cli_version": "0.157.0", "source": "cli"], at: t),
            rolloutLine("turn_context", ["cwd": folder, "model": "gpt-6", "approval_policy": "on-request", "approvals_reviewer": "user"], at: t + 1),
            rolloutEvent("user_message", ["message": "run the migration", "images": []], at: t + 1),
            rolloutMessage("user", "run the migration", at: t + 1),
            rolloutEvent("task_started", ["model_context_window": 272_000], at: t + 2),
            rolloutItem("function_call", ["name": "exec_command", "arguments": #"{"cmd":"\#(codexMigration)"}"#, "call_id": "call_demo_migrate"],
                        at: t + 20),
        ]
    }

    /// A Claude PermissionRequest's input (hooks docs), a subagent's with its `agent_id` and `agent_type`.
    static func claudeRequest(_ sessionID: String, tool: String, useID: String, input: [String: Any], agent: String? = nil,
                              agentType: String? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": sessionID, "cwd": NSHomeDirectory() + "/Developer/notes-site",
            "transcript_path": "/tmp/juice-island-demo/projects/\(sessionID).jsonl", "permission_mode": "default", "tool_name": tool,
            "tool_input": input, "tool_use_id": useID,
        ]
        if let agent {
            object["agent_id"] = agent
            object["agent_type"] = agentType ?? "worker"
        }
        return object
    }

    // MARK: Rollout lines (codex-rs shapes)

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func rolloutLine(_ type: String, _ payload: [String: Any], at date: Date) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        return #"{"timestamp":"\#(stamp(date))","type":"\#(type)","payload":\#(String(decoding: data, as: UTF8.self))}"#
    }

    static func rolloutEvent(_ type: String, _ fields: [String: Any] = [:], at date: Date) -> String {
        rolloutLine("event_msg", fields.merging(["type": type]) { $1 }, at: date)
    }

    static func rolloutItem(_ type: String, _ fields: [String: Any] = [:], at date: Date) -> String {
        rolloutLine("response_item", fields.merging(["type": type]) { $1 }, at: date)
    }

    static func rolloutMessage(_ role: String, _ text: String, at date: Date) -> String {
        rolloutItem("message", ["role": role, "content": [["type": role == "assistant" ? "output_text" : "input_text", "text": text]]], at: date)
    }
}
