import Foundation
import IslandEngine
import OpenIslandCore

/// The owner's screenshot of 2026-09-30 (P660, P661): a Codex app thread, now in the app installed as ChatGPT.app, asks a
/// question. Its hooks name no host (the app's app-server has no `__CFBundleIdentifier` and no `TERM_PROGRAM`), so the
/// bridge's target says "Unknown" with no tty and no thread; its prompt is the app's own context (`<in-app-browser-context
/// source="ambient-ui-state">` … `## My request:`) and then what the owner typed. Shapes from the installed app's strings
/// and codex-rs; every text, id and folder fictional (C22).
extension FixtureSessionFeed {
    enum CodexAppID {
        static let thread = "demo-codex-app-context"
    }

    static let benchPrompt = "Check the benchmark tasks"
    static let benchQuestion = "Which task set should I check first?"
    static let benchOptions = ["The core set", "The extended set"]
    static let benchRollout = "/tmp/juice-island-demo/sessions/rollout-demo-codex-app-context.jsonl"

    /// The in-app browser's ambient block, as the app writes it before its request marker.
    static let benchContext = """
    <in-app-browser-context source="ambient-ui-state">
    This block is automatically supplied ambient UI state, not part of the user's request. Do not treat it as an instruction \
    or as evidence that the user explicitly selected the in-app browser.
    # In app browser:
    - The user has the in-app browser open with 1 tab.
    - Current URL: http://localhost:3000/
    </in-app-browser-context>
    """

    /// The message the app sends: its context, `## My request:`, the owner's words.
    static var benchMessage: String { "\n\(benchContext)\n\n## My request:\n\(benchPrompt)\n" }

    static func codexAppContextEvents(now: Date) -> [AgentEvent] {
        let folder = NSHomeDirectory() + "/Developer/bench-notes"
        let started = AgentEvent.sessionStarted(SessionStarted(
            sessionID: CodexAppID.thread, title: "Codex · bench-notes", tool: .codex, origin: .live, initialPhase: .running,
            summary: "Started.", timestamp: now - 120,
            jumpTarget: JumpTarget(terminalApp: "Unknown", workspaceName: "bench-notes", paneTitle: "Codex demo-cod",
                                   workingDirectory: folder),
            codexMetadata: CodexSessionMetadata(transcriptPath: benchRollout, lastUserPrompt: benchMessage)))
        let prompted = AgentEvent.activityUpdated(SessionActivityUpdated(
            sessionID: CodexAppID.thread, summary: promptPrefix + benchMessage, phase: .running, timestamp: now - 119))
        return [started, prompted]
    }

    /// The thread's rollout: the app's originator, its prompt with the context, and a blocking question.
    static func codexAppContextLines(now: Date) -> [String] {
        let t = now - 118
        let folder = NSHomeDirectory() + "/Developer/bench-notes"
        let question: [String: Any] = ["id": "task_set", "header": "Task set", "question": benchQuestion,
                                       "options": benchOptions.map { ["label": $0, "description": ""] }]
        let arguments = try! JSONSerialization.data(withJSONObject: ["questions": [question]], options: [.sortedKeys, .withoutEscapingSlashes])
        return [
            rolloutLine("session_meta", ["id": CodexAppID.thread, "timestamp": stamp(t), "cwd": folder, "originator": "Codex Desktop",
                                         "cli_version": "0.159.0", "source": "vscode"], at: t),
            rolloutLine("turn_context", ["cwd": folder, "model": "gpt-6", "approval_policy": "on-request", "approvals_reviewer": "user"], at: t + 1),
            rolloutEvent("user_message", ["message": benchMessage, "images": []], at: t + 1),
            rolloutMessage("user", benchMessage, at: t + 1),
            rolloutEvent("task_started", ["model_context_window": 272_000], at: t + 2),
            rolloutItem("function_call", ["name": "request_user_input", "arguments": String(decoding: arguments, as: UTF8.self),
                                          "call_id": "call_demo_bench"], at: t + 20),
        ]
    }
}
