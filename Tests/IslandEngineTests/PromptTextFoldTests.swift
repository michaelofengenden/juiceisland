import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// P155 in the folds: the human prompt survives every injected user line of a Claude transcript and a Codex rollout,
/// and Claude Code's synthetic replies and title lines never become the last message. Fixtures are fictional, in the
/// public shapes.
struct PromptTextFoldTests {
    typealias F = ClaudeFixtures
    typealias R = RolloutFixtures

    private func fold(_ lines: [String]) -> ClaudeTranscriptFold {
        var fold = ClaudeTranscriptFold(sessionID: F.sessionID, updatedAt: Date())
        lines.forEach { fold.apply($0) }
        return fold
    }

    @Test(arguments: [
        F.user("<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>", at: 5),
        F.line(["type": "user", "origin": ["kind": "task-notification"], "message": ["role": "user", "content": "Background task done"]], at: 5),
        F.line(["type": "user", "isMeta": true, "message": ["role": "user", "content": "Base directory for this skill: /tmp/s"]], at: 5),
        F.line(["type": "user", "isCompactSummary": true, "message": ["role": "user", "content": "This session is being continued…"]], at: 5),
        F.line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "x"],
                                                                         ["type": "text", "text": "[Request interrupted by user for tool use]"]]]], at: 5),
        F.user("<local-command-stdout>Set model</local-command-stdout>", at: 5),
        F.user("<bash-input>ls</bash-input>", at: 5),
        F.userBlocks("<system-reminder>only a reminder</system-reminder>", at: 5),
    ])
    func theHumanPromptSurvivesAnInjectedLine(_ injected: String) {
        let folded = fold([F.user("fix the tests", at: 0), F.assistant("on it", at: 1), injected])
        #expect(folded.lastUserPrompt == "fix the tests")
        #expect(folded.initialUserPrompt == "fix the tests")
    }

    @Test
    func aReminderBeforeTheTextIsSkipped() {
        let line = F.line(["type": "user", "message": ["role": "user", "content": [
            ["type": "text", "text": "<system-reminder>context</system-reminder>"], ["type": "text", "text": "rename the file"]]]], at: 0)
        #expect(fold([line]).lastUserPrompt == "rename the file")
    }

    @Test
    func aSlashCommandReadsAsTyped() {
        let line = F.user("<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>main</command-args>", at: 0)
        #expect(fold([line]).lastUserPrompt == "/review main")
    }

    @Test
    func syntheticRepliesAndTitlesAreNotTheLastMessage() {
        let folded = fold([F.user("fix it", at: 0), F.assistant("fixed it", at: 1),
                           F.assistant("No response requested.", model: "<synthetic>", at: 2),
                           F.line(["type": "assistant", "isApiErrorMessage": true,
                                   "message": ["role": "assistant", "model": "claude-test-1", "content": [["type": "text", "text": "API Error: 529"]]]], at: 3),
                           F.summary("A title")])
        #expect(folded.lastAssistantMessage == "fixed it")
        #expect(folded.model == "claude-test-1")
        #expect(folded.session(transcriptPath: "/tmp/t.jsonl")?.summary == "fixed it")
    }

    /// A session whose only user text is machine text has no prompt, so it is not surfaced by one.
    @Test
    func aTranscriptOfOnlyMachineTextHasNoPrompt() {
        let folded = fold([F.user("<command-name>/clear</command-name>", at: 0),
                           F.user("<local-command-stdout></local-command-stdout>", at: 1)])
        // `/clear` is what the owner typed.
        #expect(folded.lastUserPrompt == "/clear")
        let onlyNotes = fold([F.user("<task-notification><task-id>x</task-id></task-notification>", at: 0)])
        #expect(onlyNotes.lastUserPrompt == nil && onlyNotes.initialUserPrompt == nil)
    }

    private func rolloutFold(_ lines: [String]) -> CodexRolloutSnapshot {
        var folder = RolloutFolder()
        lines.forEach { folder.apply($0) }
        return folder.finish()
    }

    @Test(arguments: [
        "<turn_aborted>The user interrupted the previous turn on purpose.</turn_aborted>",
        "<user_shell_command><command>ls</command><result>ok</result></user_shell_command>",
        "<subagent_notification>done</subagent_notification>",
        "<send_user_message_question_reply>\n[{\"answer\":\"Keep it\"}]\n</send_user_message_question_reply>",
        "# Context from my IDE setup:\n## My request for Codex:\n<send_user_message_question_reply>[]</send_user_message_question_reply>",
    ])
    func aCodexPromptSurvivesAnInjectedMessage(_ injected: String) {
        let snapshot = rolloutFold(R.turn(prompt: "rename the module", reply: "renamed", from: 0)
                                   + [R.message("user", injected, at: 20), R.event("user_message", ["message": injected], at: 20)])
        #expect(snapshot.lastUserPrompt == "rename the module")
        // Machine text never reopens the finished turn.
        #expect(snapshot.isCompleted)
    }

    @Test
    func aCodexIdePromptStillCounts() {
        let text = "# Context from my IDE setup:\n## Active file: a.swift\n## My request for Codex:\nadd a test"
        let snapshot = rolloutFold(R.turn(prompt: "first", reply: "ok", from: 0) + [R.message("user", text, at: 20)])
        #expect(snapshot.lastUserPrompt == "add a test")
        #expect(!snapshot.isCompleted)
    }
}
