import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Boost CX2: Codex's sandbox-escalation retry. The model runs `npm test` in the sandbox, it fails, and the model runs
/// the same command again with escalated permissions, which asks (PermissionRequest). One tracker read then holds the
/// first call, its output and the second call. The first call finished before the request was made, so it cannot be the
/// request's call; the request is the second call's and waits for that one's output (C7: "the newest call with no output").
@MainActor
@Suite(.serialized)
struct CodexBoostCX2Tests {
    typealias S = AttentionScene
    typealias R = RolloutFixtures
    typealias C = CodexAttentionTests
    typealias T = CodexAttentionTableTests

    @Test
    func aRetriedCommandsApprovalIsNotClosedByTheFailedFirstRun() throws {
        let s = S()
        s.begin("c1", tool: .codex)
        s.rollout("c1", [R.meta(id: "c1"), T.reviewer("user", at: -10), T.turn])
        let id = try #require(s.hook(S.codex("PermissionRequest", input: ["command": "npm test",
                                                                          "description": "Run the tests with network access"]),
                                     source: "codex", entrypoint: nil))
        // One read: the sandboxed run and its failure (both before the request), then the escalated retry.
        s.rollout("c1", [T.exec("call_A", "npm test", at: -3), C.output("call_A", "Error: getaddrinfo ENOTFOUND registry", at: -2),
                         C.call("exec_command", "call_B", arguments: #"{"cmd":"npm test","sandbox_permissions":"require_escalated"}"#, at: -1)])
        #expect(s.isOpen(id), "closed by the first run's output")
        #expect(s.request(id)?.callID == "call_B")
        s.at(8)
        #expect(s.glyph("c1") == "!" && s.needsYou.count == 1)
        s.rollout("c1", [C.output("call_B", "12 passing", at: 20)])
        #expect(!s.isOpen(id))
    }
}
