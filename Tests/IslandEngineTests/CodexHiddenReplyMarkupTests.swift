import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Codex records the model's reply in the rollout as it came (`record_conversation_items` with the raw
/// `ResponseItem`), hidden markup included: Plan mode's `<proposed_plan>…</proposed_plan>` and memory citations
/// `<oai-mem-citation>…</oai-mem-citation>`. Its own `agent_message` and `task_complete.last_agent_message` strip both
/// (`stream_events_utils.rs` `strip_hidden_assistant_markup`, `last_assistant_message_from_item`), and a plan-only reply
/// has no `last_agent_message` at all. The fold took the raw item, so the Done row and card read `<proposed_plan> # …`
/// (P155). Texts fictional, in codex-rs 0.157's shapes.
struct CodexHiddenReplyMarkupTests {
    typealias R = RolloutFixtures

    private func fold(_ lines: [String]) -> CodexRolloutSnapshot {
        var folder = RolloutFolder()
        lines.forEach { folder.apply($0) }
        return folder.finish()
    }

    @Test
    func aPlanModeReplyIsNeverShownAsMarkup() {
        let snapshot = fold([
            R.turnContext(at: 0),
            R.event("user_message", ["message": "plan the refactor", "images": []], at: 0),
            R.message("user", "plan the refactor", at: 0),
            R.event("task_started", ["model_context_window": 272_000], at: 1),
            R.message("assistant", "<proposed_plan>\n# Split the session model\n1. Move the row mapping out\n2. Add tests\n</proposed_plan>", at: 5),
            R.event("task_complete", [:], at: 6),
        ])
        #expect(snapshot.isCompleted)
        #expect(snapshot.lastAssistantMessage?.contains("proposed_plan") == false)
        #expect(snapshot.lastAssistantMessage?.hasPrefix("<") == false)
    }

    @Test
    func aMemoryCitationIsNeverPartOfTheLastMessage() {
        // The raw item landing after `task_complete` (the reducer's own note: "the JSONL may still contain trailing
        // response_item entries (the final assistant message)").
        let snapshot = fold(R.turn(prompt: "fix it", reply: "Fixed the parser.", from: 0) + [
            R.message("assistant", "Fixed the parser.<oai-mem-citation><citation_entries>\nMEMORY.md:1-2|note=[parser]\n</citation_entries></oai-mem-citation>", at: 8),
        ])
        #expect(snapshot.lastAssistantMessage == "Fixed the parser.")
    }
}
