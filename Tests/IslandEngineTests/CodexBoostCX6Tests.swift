import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Boost CX6: one `request_user_input_async` call with two questions. The Codex TUI answers them one at a time: each
/// Send is its own envelope naming `[tool, call id, index]` for that question only
/// (`tui/src/bottom_pane/async_questions/state.rs` `go_next_or_submit`, `resolve_answers`). After the first answer
/// the second question still waits in Codex, so the island's "?" must stay.
@MainActor
@Suite(.serialized)
struct CodexBoostCX6Tests {
    typealias S = AttentionScene
    typealias R = RolloutFixtures
    typealias C = CodexAttentionTests
    typealias T = CodexAttentionTableTests

    static let twoQuestions = #"{"questions":[{"title":"Remove the second figure?","options":["Remove it","Keep it"]},{"title":"Renumber the figures after it?","options":["Yes","No"]}]}"#

    /// The first question's answer only, as the TUI renders it (`AnsweredQuestion::render`).
    static let firstAnswer = "<send_user_message_question_reply>\n"
        + #"[{"answer":"Keep it","question":"Remove the second figure?","questionItemId":"[\"request_user_input_async\",\"call_A1\",0]"}]"#
        + "\n</send_user_message_question_reply>"

    @Test
    func theFoldKeepsTheCallOpenUntilEveryQuestionIsAnswered() {
        var attention = C.fold([R.meta(), C.call("request_user_input_async", "call_A1", arguments: Self.twoQuestions),
                                C.output("call_A1", #"{"accepted":true}"#)])
        _ = attention.takeEvents()
        attention.apply(R.message("user", Self.firstAnswer, at: 5))
        #expect(attention.questions["call_A1"] != nil, "one answer closed both questions")
    }

    @Test
    func theEngineKeepsTheQuestionWhenTheHookCarriesOneAnswer() {
        let s = S()
        s.begin("c1", tool: .codex)
        s.rollout("c1", [R.meta(id: "c1"), T.reviewer("user", at: -30), T.turn,
                         C.call("request_user_input_async", "call_A1", arguments: Self.twoQuestions),
                         C.output("call_A1", #"{"accepted":true}"#)])
        #expect(s.glyph("c1") == "?")
        // Steered into the running turn: UserPromptSubmit carries it at once.
        s.bridge(F.prompt("c1", Self.firstAnswer, at: s.clock.current))
        #expect(s.glyph("c1") == "?", "one answer closed both questions")
        s.rollout("c1", [R.message("user", Self.firstAnswer, at: 5)])
        #expect(s.glyph("c1") == "?", "one answer closed both questions")
    }

    typealias F = EngineFixtures
}
