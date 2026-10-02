import Foundation
import Testing
@testable import IslandEngine
import JuiceCore
import OpenIslandCore

/// A rollout whose last line has no newline yet (Codex writes `json + "\n"` in one write, and re-terminates a file it
/// finds cut: `recorder.rs` `ensure_rollout_is_newline_terminated`): the scanner hands that line to upstream's reducer
/// itself, past `RolloutFolder`'s machine-text rule, so Codex's own user message became the prompt and reopened the
/// finished turn (P155: every prompt writer goes through `PromptText.human`). Texts fictional.
struct CodexTrailingLineTests {
    typealias F = RolloutFixtures

    @Test
    func anUnterminatedMachineLineIsNeverThePromptNorANewTurn() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        let lines = F.head() + F.turn(prompt: "rename the module", reply: "renamed", from: 10)
        let last = F.message("user", "<subagent_notification>{\"agent_id\":\"c1\",\"status\":\"completed\"}</subagent_notification>", at: 30)
        try (F.text(lines) + last).write(to: url, atomically: true, encoding: .utf8)
        let record = try #require(CodexRolloutScanner(rootURL: root).discoverRecentSessions().first)
        #expect(record.codexMetadata?.lastUserPrompt == "rename the module")
        #expect(record.phase == .completed)
    }
}
