import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Boost CX1: a Codex subagent that already ran a turn (a `send_input` follow-up starts its second one). The child
/// watch's first read of its rollout replays that earlier turn: its end, and a call with the same command whose output
/// is already there. Neither is about the request that just arrived, so neither may close it (C5, C7).
@MainActor
@Suite(.serialized)
struct CodexBoostCX1Tests {
    typealias S = AttentionScene
    typealias R = RolloutFixtures
    typealias C = CodexAttentionTests
    typealias T = CodexAttentionTableTests

    /// `make k1` again: the earlier call's output is read as this request's. `make lint`: the earlier turn's end is.
    @Test(arguments: ["make k1", "make lint"])
    func aReusedSubagentsEarlierTurnDoesNotCloseItsNewRequest(earlier: String) async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("juice-boost-\(UUID().uuidString.prefix(8))",
                                                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = S()
        s.begin("c1", tool: .codex)
        s.rollout("c1", [R.meta(id: "c1"), T.reviewer("user"), T.turn])
        // The child ran an earlier turn (`earlier`) that ended; its second turn runs `make k1`, which asks.
        let url = dir.appendingPathComponent("rollout-k1.jsonl")
        try R.text([R.meta(id: "k1"), T.reviewer("user", at: -40), R.event("task_started", at: -40),
                    T.exec("call_old", earlier, at: -39), C.output("call_old", "ok", at: -38),
                    R.event("task_complete", ["last_agent_message": "built"], at: -37),
                    T.reviewer("user", at: -2), R.event("task_started", at: -2), T.exec("call_k1", "make k1", at: -1)])
            .write(to: url, atomically: true, encoding: .utf8)
        let id = try #require(s.hook(S.codex("PermissionRequest", input: ["command": "make k1"], agent: "k1", transcript: url.path),
                                     source: "codex", entrypoint: nil))
        // The request is entered after one bounded read of the child's rollout, off the main thread (C6).
        for _ in 0..<40 where s.request(id) == nil && s.engine.attentionTally.closes.isEmpty {
            await s.settle { s.request(id) != nil || !s.engine.attentionTally.closes.isEmpty }
        }
        #expect(s.engine.attentionTally.opened["codex.broker.terminal"] == 1)
        // The child watch reads the whole (small) rollout once.
        for _ in 0..<40 where s.isOpen(id) && s.request(id)?.callID == nil {
            s.engine.childRollouts?.waitUntilIdle()
            await s.settle { s.request(id)?.callID != nil || !s.isOpen(id) }
        }
        #expect(s.isOpen(id), "closed by the child's earlier turn (\(earlier)): \(s.engine.attentionTally.closes)")
        #expect(s.request(id)?.callID == "call_k1")
        s.at(9)
        #expect(s.glyph("c1") == "!")
    }
}
