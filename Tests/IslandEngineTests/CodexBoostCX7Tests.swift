import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Boost CX7: the reply envelope's other two shapes that Codex itself reads back (`tui/src/async_question_reply.rs`
/// `parse`: `Replies::One`, a single object; `bottom_pane/async_questions/state.rs` `resolve_answers`: "Older desktop
/// replies identify the whole source message instead of one question", a `questionItemId` that is the call id itself).
/// Either names one call: the hook must clear that question at once, and the rollout read must not clear another
/// question still waiting.
@MainActor
@Suite(.serialized)
struct CodexBoostCX7Tests {
    typealias S = AttentionScene
    typealias R = RolloutFixtures
    typealias C = CodexAttentionTests
    typealias T = CodexAttentionTableTests
    typealias F = EngineFixtures

    static let otherQuestion = #"{"questions":[{"title":"Also shorten the abstract?","options":["Yes","No"]}]}"#

    static let envelopes = [
        // One object, not an array.
        "<send_user_message_question_reply>\n"
            + #"{"answer":"Keep it","question":"Section E also has a second figure. Should I remove it?","questionItemId":"[\"request_user_input_async\",\"call_A1\",0]"}"#
            + "\n</send_user_message_question_reply>",
        // An older desktop's id: the whole message (the call id).
        "<send_user_message_question_reply>\n"
            + #"[{"answer":"Keep it","question":"Section E also has a second figure. Should I remove it?","questionItemId":"call_A1"}]"#
            + "\n</send_user_message_question_reply>",
    ]

    private func asked() -> S {
        let s = S()
        s.begin("c1", tool: .codex)
        s.rollout("c1", [R.meta(id: "c1"), T.reviewer("user", at: -30), T.turn,
                         C.call("request_user_input_async", "call_A1", arguments: C.asyncArguments),
                         C.output("call_A1", #"{"accepted":true}"#),
                         C.call("request_user_input_async", "call_A2", arguments: Self.otherQuestion, at: 2),
                         C.output("call_A2", #"{"accepted":true}"#, at: 3)])
        return s
    }

    @Test
    func theHookClearsTheQuestionItNames() {
        for envelope in Self.envelopes {
            let s = asked()
            #expect(s.engine.attentionQueue(for: "c1").count == 2)
            s.bridge(F.prompt("c1", envelope, at: s.clock.current))
            #expect(!s.isOpen("rollout:c1:call_A1"), "not cleared by the hook: \(envelope)")
            #expect(s.isOpen("rollout:c1:call_A2"))
        }
    }

    @Test
    func theRolloutReadClearsOnlyTheQuestionItNames() {
        for envelope in Self.envelopes {
            let s = asked()
            s.rollout("c1", [R.message("user", envelope, at: 5)])
            #expect(!s.isOpen("rollout:c1:call_A1"), "\(envelope)")
            #expect(s.isOpen("rollout:c1:call_A2"), "another question cleared: \(envelope)")
        }
    }
}
