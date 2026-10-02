import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Claude's own notice for a subagent's request once the island's hold ended (P352). With Answer subagents on the island
/// on, the request is confirmed at once; Claude builds its own prompt only when the hold ends, so its `permission_prompt`
/// comes about `AttentionBook.noticeDelay` after the release, not after the request. That notice is the released
/// prompt's own: after a ✕ it brings nothing back and sounds nothing again, and it never confirms a main-thread request
/// asked since, which waits for its own. A notice past `SubagentHold.noticeGrace` is another prompt's, as always.
@MainActor
struct SubagentHoldNoticeTests {
    typealias S = AttentionScene

    /// A scene with the switch on; a subagent asks, and the island shows its card.
    private func held(_ s: S, agent: String = "wf-a", useID: String = "UA") throws -> String {
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: useID, agent: agent, agentType: "workflow-subagent"))
        let id = try #require(s.hook(S.claude("PermissionRequest", tool: "Bash", input: S.push, agent: agent, agentType: "workflow-subagent")))
        #expect(s.request(id)?.isHeldForIsland == true && s.state(id) == .confirmed)
        s.engine.islandShows(requestID: id)
        return id
    }

    private func scene() -> S {
        let s = S()
        s.engine.answersSubagents = true
        s.begin()
        return s
    }

    /// The owner's path: the line runs out at 12 s, ✕ a second later, Claude's notice six seconds after the release:
    /// no card comes back and nothing sounds again. The control, with the switch off, is the same.
    @Test
    func aDismissBeforeClaudesNoticeStaysDismissed() throws {
        let s = scene()
        let id = try held(s)
        #expect(s.needsYou.count == 1)
        s.at(SubagentHold.limit)
        #expect(s.broker.released.current == [id] && s.request(id)?.channel == .open)
        s.at(SubagentHold.limit + 1)
        s.engine.dismissRequest(requestID: id)
        #expect(s.head() == nil)
        s.at(SubagentHold.limit + AttentionBook.noticeDelay)
        s.hook(S.notification("permission_prompt"))
        #expect(s.head() == nil && s.engine.openRequests.isEmpty && s.needsYou.count == 1)
        #expect(s.engine.attentionTally.subagentHolds == ["timeUp": 1])
    }

    /// Released by a fold (or Esc, another app) and ✕'d at once: the same.
    @Test
    func aDismissAfterAnyReleaseStaysDismissed() throws {
        let s = scene()
        let id = try held(s)
        s.at(4)
        s.engine.islandShows(requestID: nil)
        s.engine.dismissRequest(requestID: id)
        s.at(4 + AttentionBook.noticeDelay + 0.5)
        s.hook(S.notification("permission_prompt"))
        #expect(s.head() == nil && s.needsYou.count == 1)
    }

    /// The notice came first (the card still there, nothing sounds), ✕ after it: the next notice is another prompt's and
    /// shows, even a second later.
    @Test
    func aNoticeThatCameBeforeTheDismissIsSpent() throws {
        let s = scene()
        let id = try held(s)
        s.at(SubagentHold.limit)
        s.at(SubagentHold.limit + AttentionBook.noticeDelay)
        s.hook(S.notification("permission_prompt"))
        #expect(s.head()?.id == id && s.needsYou.count == 1)
        s.engine.dismissRequest(requestID: id)
        s.at(SubagentHold.limit + AttentionBook.noticeDelay + 1)
        s.hook(S.notification("permission_prompt"))
        #expect(s.head()?.content == .notice && s.needsYou.count == 2)
    }

    /// No notice came for the released prompt (answered in Claude at once, say): past `noticeGrace` a notice is another
    /// prompt's, and one naming another subagent is that subagent's, whenever it comes.
    @Test
    func aLaterNoticeOrAnotherAgentsIsShown() throws {
        let s = scene()
        let id = try held(s)
        s.at(SubagentHold.limit)
        s.engine.dismissRequest(requestID: id)
        s.at(SubagentHold.limit + AttentionBook.noticeDelay + SubagentHold.noticeGrace + 0.5)
        s.hook(S.notification("permission_prompt"))
        #expect(s.head()?.content == .notice && s.needsYou.count == 2)

        let other = scene()
        let first = try held(other)
        other.at(SubagentHold.limit)
        other.engine.dismissRequest(requestID: first)
        other.at(SubagentHold.limit + AttentionBook.noticeDelay)
        other.hook(S.notification("permission_prompt", agent: "wf-b"))
        #expect(other.head()?.content == .notice && other.needsYou.count == 2)
    }

    /// A main-thread request asked three seconds after the release: the released prompt's notice, three seconds before
    /// the main thread's is due, confirms nothing; the main thread's own does, and sounds.
    @Test
    func theReleasedPromptsNoticeNeverConfirmsAMainThreadRequest() throws {
        let s = scene()
        let sub = try held(s)
        s.at(SubagentHold.limit)
        s.at(SubagentHold.limit + 3)
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.read, toolUseID: "UM"))
        let main = try #require(s.hook(S.claude("PermissionRequest", tool: "Bash", input: S.read)))
        #expect(s.state(main) == .pending)
        s.at(SubagentHold.limit + AttentionBook.noticeDelay)
        s.hook(S.notification("permission_prompt"))
        #expect(s.state(main) == .pending && s.needsYou.count == 1 && s.head()?.id == sub)
        s.at(SubagentHold.limit + 3 + AttentionBook.noticeDelay)
        s.hook(S.notification("permission_prompt"))
        #expect(s.state(main) == .confirmed && s.needsYou.count == 2)
    }

    /// With the switch off nothing of this applies: the card appears only from Claude's notice, so a ✕ comes after it.
    @Test
    func offTheNoticeOpensTheCard() throws {
        let s = S()
        s.begin()
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "UA", agent: "wf-a", agentType: "workflow-subagent"))
        let id = try #require(s.hook(S.claude("PermissionRequest", tool: "Bash", input: S.push, agent: "wf-a", agentType: "workflow-subagent")))
        #expect(s.broker.held.current.isEmpty && s.state(id) == .pending)
        s.at(AttentionBook.noticeDelay)
        s.hook(S.notification("permission_prompt"))
        #expect(s.head()?.id == id && s.needsYou.count == 1)
        s.engine.dismissRequest(requestID: id)
        s.at(AttentionBook.noticeDelay + 1)
        s.hook(S.notification("permission_prompt"))
        #expect(s.head()?.content == .notice && s.needsYou.count == 2)
    }
}
