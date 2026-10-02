import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Boost CX5 (C7): a model that runs `apply_patch` through `exec_command`. Codex intercepts it
/// (`core/src/tools/handlers/apply_patch.rs` `intercept_apply_patch`), and its approval reaches the hook as tool
/// `apply_patch` (`approvals.rs` `permission_request_payload`), while the rollout's call, and later its output, are
/// the `exec_command`'s, under the same call id. Approved in Codex, the patch is applied and the output written:
/// the read-only "!" must go then, not at the turn's end.
@MainActor
@Suite(.serialized)
struct CodexBoostCX5Tests {
    typealias S = AttentionScene
    typealias R = RolloutFixtures
    typealias C = CodexAttentionTests
    typealias T = CodexAttentionTableTests

    @Test
    func aPatchAppliedThroughExecCommandClosesOnThatCallsOutput() throws {
        let s = S()
        s.begin("c1", tool: .codex)
        s.rollout("c1", [R.meta(id: "c1"), T.reviewer("user", at: -30), T.turn])
        let patch = "*** Begin Patch\n*** Update File: /tmp/elsewhere/a.swift\n@@\n-let a = 1\n+let a = 2\n*** End Patch"
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["cmd": "apply_patch <<'EOF'\n\(patch)\nEOF\n"]),
                               as: UTF8.self)
        s.rollout("c1", [C.call("exec_command", "call_P", arguments: arguments, at: 0)])
        let id = try #require(s.hook(S.codex("PermissionRequest", tool: "apply_patch", input: ["command": patch]),
                                     source: "codex", entrypoint: nil))
        s.at(8)
        #expect(s.glyph("c1") == "!")
        s.rollout("c1", [C.output("call_P", "Success. Updated the following files:\nM /tmp/elsewhere/a.swift", at: 12)])
        #expect(!s.isOpen(id), "the applied patch's approval stays until the turn ends")
        #expect(s.glyph("c1") == nil)
    }
}
