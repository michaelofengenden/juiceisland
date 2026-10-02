import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Boost CX8 (C7): an MCP tool's approval. Codex exposes MCP tools to the model as namespaced functions
/// (`core/src/tools/handlers/mcp.rs` `create_tool_spec`: `ToolSpec::Namespace`), so the rollout's call is
/// `{"name":"create_issue","namespace":"mcp__github"}`, while the hook names the joined tool, `mcp__github__create_issue`
/// (`hook_tool_name`: `ensure_mcp_prefix(join_tool_name(…))`). Approved in Codex, the call runs and its output is
/// written: the read-only "!" must go then, not at the turn's end.
@MainActor
@Suite(.serialized)
struct CodexBoostCX8Tests {
    typealias S = AttentionScene
    typealias R = RolloutFixtures
    typealias C = CodexAttentionTests
    typealias T = CodexAttentionTableTests

    @Test
    func anMCPApprovalClosesOnItsNamespacedCallsOutput() throws {
        let s = S()
        s.begin("c1", tool: .codex)
        s.rollout("c1", [R.meta(id: "c1"), T.reviewer("user", at: -30), T.turn])
        s.rollout("c1", [R.item("function_call", ["name": "create_issue", "namespace": "mcp__github",
                                                  "arguments": #"{"repo":"example/paper","title":"Figure N"}"#, "call_id": "call_M"], at: 0)])
        let id = try #require(s.hook(S.codex("PermissionRequest", tool: "mcp__github__create_issue",
                                             input: ["repo": "example/paper", "title": "Figure N"]),
                                     source: "codex", entrypoint: nil))
        s.at(8)
        #expect(s.glyph("c1") == "!")
        s.rollout("c1", [C.output("call_M", #"{"number":7}"#, at: 12)])
        #expect(!s.isOpen(id), "the MCP approval stays until the turn ends")
        #expect(s.glyph("c1") == nil)
    }
}
