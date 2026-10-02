import Foundation
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// The owner's island after the fix (P212, `CodexThreadScene`): Claude's row and the two Codex chats, the chats first
/// among Codex's; no reviewer thread or subagent is a row, a card, a count or a title; chat A says how many of its
/// subagents run; no JSON is ever a status.
@MainActor
struct CodexThreadRowTests {
    typealias S = CodexThreadScene

    @Test
    func theOwnersIslandListsOnlyTheirChats() throws {
        let scene = S()
        let rows = scene.model.rows
        #expect(Set(rows.map(\.id)) == [S.claude, S.chatA, S.chatB])
        #expect(scene.model.runningCount == 3)
        #expect(scene.model.needsYouCount == 0)
        for row in rows {
            #expect(!row.task.hasPrefix("The following is"), "\(row.id)")
            #expect(!PromptText.isJSON(row.detail), "\(row.id)")
            #expect(scene.model.card(for: row.id) == nil, "\(row.id)")
        }
        let chatA = try #require(scene.model.row(id: S.chatA))
        #expect(chatA.task == "Continue MarathonTrainingLog")
        #expect(chatA.status == .subagents(3))
        // Its turn waits on its subagents: the delegate's glyph and words, as a Claude session's (P370).
        #expect(chatA.glyph == .agents && chatA.glyphState == .delegating && chatA.bucket == .running)
        #expect(SessionRowText.cleanStatus(chatA).text == "Waiting on 3 agents")
        #expect(DetailedRowText.status(chatA).word == "Waiting on 3 agents")
        #expect(SessionListLayout.groupStatus(chatA, now: scene.now).hasPrefix("Waiting on 3 agents · "))
        let chatB = try #require(scene.model.row(id: S.chatB))
        #expect(chatB.task == "Review paper for inconsistencies")
        #expect(chatB.bucket == .running)
        // Both chats are in the island's first four rows.
        let layout = IslandListLayout.make(rows: rows, style: .clean, showAll: false, now: scene.now)
        #expect(Set(layout.shown.map(\.id)).isSuperset(of: [S.chatA, S.chatB]))
        #expect(!layout.showsFooter)
        #expect(scene.engine.hiddenCodexThreadCount == 6 + 160)
    }

    /// Chat B's review runs (P217): its row says Reviewing in every style; the review's thread is no row.
    @Test
    func aChatWhoseReviewRunsSaysReviewing() throws {
        let scene = S(reviewing: true)
        #expect(Set(scene.model.rows.map(\.id)) == [S.claude, S.chatA, S.chatB])
        let chatB = try #require(scene.model.row(id: S.chatB))
        #expect(chatB.status == .reviewing)
        #expect(chatB.bucket == .running)
        #expect(SessionRowText.cleanStatus(chatB).text == "Reviewing")
        #expect(DetailedRowText.status(chatB).word == "Reviewing")
        #expect(SessionListLayout.groupStatus(chatB, now: scene.now).hasPrefix("Reviewing · "))
        #expect(scene.engine.state.session(id: S.review) == nil)
    }

    /// A chat whose last message is JSON (the reviewer's verdict shape) says Done on its row, never the JSON; its Done
    /// card still shows the message itself.
    @Test
    func jsonIsNeverAStatus() {
        #expect(EngineSessionsModel.rowText(S.verdict) == nil)
        #expect(EngineSessionsModel.rowText("All three runs pass.") == "All three runs pass.")
        let row = SessionRow(id: "r", agent: .codex, bucket: .done, project: "p", task: "t", status: .done, detail: nil, lastPrompt: nil,
                             host: nil, accountAlias: nil, updatedAt: DemoClock.now, isCodexApp: true, glyph: .check, glyphState: .done,
                             hasCard: false)
        #expect(SessionRowText.cleanStatus(row).text == "Done")
        #expect(StatusWord.subagentsText(1) == "Waiting on 1 agent")
    }

    /// A review that is a row of its own (a chat's first action, P217) says its explanation, on its row and its Done
    /// card, never the review model's JSON.
    @Test
    func aReviewsAnswerIsItsExplanation() {
        let answer = #"{"findings":[{"title":"Off by one","body":"…"}],"overall_correctness":"patch is incorrect","overall_explanation":"One off-by-one in the loop.","overall_confidence_score":0.7}"#
        let session = AgentSession(id: "r", title: "Codex · p", tool: .codex, phase: .completed, summary: answer, updatedAt: DemoClock.now,
                                   codexMetadata: CodexSessionMetadata(lastAssistantMessage: answer))
        #expect(EngineSessionsModel.lastMessage(session) == "One off-by-one in the loop.")
        #expect(PromptText.reviewExplanation(S.verdict) == nil)
        #expect(PromptText.reviewExplanation("All three runs pass.") == nil)
    }
}
