import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// OpenCode's requests on the island by plugin API (P481): every approval answerable through the bridge; a question
/// answerable under OpenCode 1 only. OpenCode 2's shows read-only (Open, ✕), sends nothing on a click, and goes when
/// the bridge lets it go (answered in OpenCode) or a newer request of the session takes its place.
@MainActor
struct OpenCodeAttentionTests {
    typealias S = AttentionScene
    typealias F = EngineFixtures

    static let v2 = "opencode2-ses_q"
    static let v1 = "opencode-ses_q"

    @Test
    func sessionIDsNameTheirAPI() {
        #expect(OpenCodeAPI.of(sessionID: Self.v2) == .two)
        #expect(OpenCodeAPI.of(sessionID: Self.v1) == .one)
        #expect(OpenCodeAPI.of(sessionID: "ses_q") == .one)
        #expect(!OpenCodeAPI.islandAnswers(sessionID: Self.v2, isQuestion: true))
        #expect(OpenCodeAPI.islandAnswers(sessionID: Self.v2, isQuestion: false))
        #expect(OpenCodeAPI.islandAnswers(sessionID: Self.v1, isQuestion: true))
    }

    @Test
    func anOpenCode2QuestionIsReadOnlyAndSendsNothing() async {
        let s = S()
        s.begin(Self.v2, tool: .openCode)
        s.bridge(F.question(Self.v2, at: s.clock.current))
        let head = s.head(Self.v2)
        #expect(s.glyph(Self.v2) == "?")
        #expect(head?.channel == .open && head?.isConfirmed == true && head?.isAnswerable == false)
        #expect(await s.engine.answer(sessionID: Self.v2, response: QuestionPromptResponse(answer: "main")) == .nothingToSend)
        if let id = head?.id {
            #expect(await s.engine.answer(requestID: id, response: QuestionPromptResponse(answer: "main")) == .nothingToSend)
        }
        #expect(s.sent.current.isEmpty)
        // Answered in OpenCode: the plugin's PostToolUse makes the bridge let its slot go.
        s.bridge(.actionableStateResolved(ActionableStateResolved(sessionID: Self.v2, summary: "Approval was handled outside Open Island.",
                                                                  timestamp: s.clock.current)))
        #expect(s.head(Self.v2) == nil)
    }

    @Test
    func anOpenCode2QuestionGivesWayToANewerRequest() {
        let s = S()
        s.begin(Self.v2, tool: .openCode)
        s.bridge(F.question(Self.v2, at: s.clock.current))
        let question = s.head(Self.v2)?.id
        s.bridge(F.permission(Self.v2, toolUseID: nil, at: s.clock.current))
        #expect(!s.isOpen(question))
        #expect(s.head(Self.v2)?.channel == .answer(.bridge) && s.glyph(Self.v2) == "!")
    }

    @Test
    func openCode1QuestionsAndEveryApprovalStayAnswerable() async {
        let s = S()
        s.begin(Self.v1, tool: .openCode)
        s.bridge(F.question(Self.v1, at: s.clock.current))
        #expect(s.head(Self.v1)?.channel == .answer(.bridge))
        #expect(await s.engine.answer(sessionID: Self.v1, response: QuestionPromptResponse(answer: "main")) == .sent)

        let t = S()
        t.begin(Self.v2, tool: .openCode)
        t.bridge(F.permission(Self.v2, toolUseID: nil, at: t.clock.current))
        #expect(t.head(Self.v2)?.channel == .answer(.bridge))
        #expect(await t.engine.approve(sessionID: Self.v2, decision: .allowOnce) == .sent)
        #expect(t.sent.current == [.resolvePermission(sessionID: Self.v2, resolution: .allowOnce())])
    }

    /// Another agent's session never takes OpenCode's rule, whatever its id.
    @Test
    func onlyOpenCodeSessionsAreRead() {
        let s = S()
        s.begin("opencode2-lookalike", tool: .cursor)
        s.bridge(F.question("opencode2-lookalike", at: s.clock.current))
        #expect(s.head("opencode2-lookalike")?.channel == .answer(.bridge))
    }
}
