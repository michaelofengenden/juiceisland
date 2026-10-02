import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Boost CX4 (C6): what hides a Codex request is what its rollout says when it asks. The strict-review grant (or a
/// mid-thread switch to auto review) is already written, but the tracker's view of the thread is up to 3 s old: the
/// hook's own poll lands just after the broker's request. The request must still end up not shown, with no "!" and no
/// sound, as CX13 and CX14 ask.
@MainActor
@Suite(.serialized)
struct CodexBoostCX4Tests {
    typealias S = AttentionScene
    typealias R = RolloutFixtures
    typealias C = CodexAttentionTests
    typealias T = CodexAttentionTableTests

    private func scene() -> S {
        let s = S()
        s.begin("c1", tool: .codex)
        // The tracker already knows the thread: reviewer user, a turn running.
        s.rollout("c1", [R.meta(id: "c1"), T.reviewer("user", at: -30), T.turn])
        return s
    }

    @Test
    func aStrictReviewGrantReadJustAfterTheRequestHidesIt() {
        let s = scene()
        s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil)
        s.rollout("c1", [C.call("request_permissions", "call_P", arguments: #"{"permissions":{"network":{"enabled":true}}}"#, at: -4),
                         C.output("call_P", #"{"permissions":{"network":{"enabled":true}},"scope":"turn","strict_auto_review":true}"#, at: -3),
                         T.exec("call_X", at: -1)])
        s.at(10)
        #expect(s.engine.openRequests.isEmpty, "a request Guardian reviews is shown")
        #expect(s.glyph("c1") == nil && s.needsYou.isEmpty)
    }

    @Test
    func anAutoReviewSwitchReadJustAfterTheRequestHidesIt() {
        let s = scene()
        s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil)
        s.rollout("c1", [R.event("thread_settings_applied", ["thread_settings": ["model": "gpt-6", "approval_policy": "on-request",
                                                                                 "approvals_reviewer": "auto_review"]], at: -3),
                         T.exec("call_X", at: -1)])
        s.at(10)
        #expect(s.engine.openRequests.isEmpty, "a request Guardian reviews is shown")
        #expect(s.glyph("c1") == nil && s.needsYou.isEmpty)
    }
}
