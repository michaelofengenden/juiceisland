import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Boost CX3: turn 1 ends and turn 2 starts at once (a queued prompt, or a turn Codex starts by itself after a
/// subagent's notice), and turn 2's first command asks before the tracker's next 3 s read. That read holds turn 1's
/// `task_complete`: it is not the end of the request's turn (turn-2), so it may not close it (§2.2: the request's own
/// turn end).
@MainActor
@Suite(.serialized)
struct CodexBoostCX3Tests {
    typealias S = AttentionScene
    typealias R = RolloutFixtures
    typealias C = CodexAttentionTests
    typealias T = CodexAttentionTableTests

    @Test
    func thePreviousTurnsEndReadLateLeavesTheNewTurnsRequest() throws {
        let s = S()
        s.begin("c1", tool: .codex)
        s.rollout("c1", [R.meta(id: "c1"), T.reviewer("user", at: -30), R.event("task_started", ["turn_id": "turn-1"], at: -30)])
        let id = try #require(s.hook(S.codex("PermissionRequest", turn: "turn-2"), source: "codex", entrypoint: nil))
        // The read after the request: turn 1's end, turn 2's start, turn 2's call.
        s.rollout("c1", [R.event("task_complete", ["turn_id": "turn-1", "last_agent_message": "done"], at: -3),
                         T.reviewer("user", at: -2), R.event("task_started", ["turn_id": "turn-2"], at: -2),
                         T.exec("call_2", at: -1)])
        #expect(s.isOpen(id), "closed by the previous turn's end")
        s.at(8)
        #expect(s.glyph("c1") == "!" && s.needsYou.count == 1)
    }
}
