import Foundation
import OpenIslandCore
import Testing
@testable import IslandEngine

/// The request book's invariants (§3.1 of the design), one test each, on the pure book.
struct AttentionBookTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func request(_ id: String, session: String = "s1", kind: AttentionRequest.Kind = .approval, at second: TimeInterval = 0,
                        agent: String? = nil, tool: AgentTool = .claudeCode, channel: AttentionRequest.Channel = .answer(.broker),
                        source: AttentionRequest.Source = .broker, state: AttentionRequest.State = .pending,
                        toolName: String? = "Bash", toolUseID: String? = nil, digest: String? = nil,
                        releases: Bool = false) -> AttentionRequest {
        let content: AttentionRequest.Content = kind.isQuestion
            ? .question(QuestionPrompt(title: "Which branch?", options: ["main", "dev"]))
            : .approval(PermissionRequest(title: "Allow Bash", summary: "", affectedPath: "ls", toolName: toolName))
        return AttentionRequest(id: id, sessionID: session, agentID: agent, kind: kind, channel: channel, source: source, tool: tool,
                                toolName: toolName, toolUseID: toolUseID, inputDigest: digest, content: content,
                                openedAt: t0.addingTimeInterval(second), state: state, windowReleases: releases)
    }

    /// Invariant 1 (C13): the glyph is the oldest confirmed request's; pending and dormant draw and count nothing.
    @Test
    func theHeadIsTheOldestConfirmedRequest() {
        var book = AttentionBook()
        book.insert(Self.request("q", kind: .question, at: 0))
        book.insert(Self.request("a", at: 1))
        #expect(book.head(of: "s1") == nil && book.confirmed(in: "s1").isEmpty)
        book.confirm("a", at: Self.t0.addingTimeInterval(6))
        #expect(book.head(of: "s1")?.id == "a")
        book.confirm("q", at: Self.t0.addingTimeInterval(7))
        // An old question and a newer approval: the question, older, is the glyph ("?"), not both.
        #expect(book.head(of: "s1")?.id == "q" && book.head(of: "s1")?.kind.isQuestion == true)
        #expect(book.confirmed(in: "s1").map(\.id) == ["q", "a"])
        // Same `openedAt`: the order they came in.
        var tie = AttentionBook()
        tie.insert(Self.request("x", state: .confirmed))
        tie.insert(Self.request("y", state: .confirmed))
        #expect(tie.confirmed(in: "s1").map(\.id) == ["x", "y"])
    }

    /// Invariant 2: one request per hook, a queue per session; a notice confirms the oldest unconfirmed one, else
    /// revives the newest dormant one, else says none (C2, C3).
    @Test
    func requestsQueueAndANoticeConfirmsTheOldestUnconfirmed() throws {
        var book = AttentionBook()
        let first = book.insert(Self.request("A", at: 0, releases: true))
        let second = book.insert(Self.request("B", at: 1, releases: true))
        let again = book.insert(Self.request("A", at: 2))
        #expect(first && second && !again)
        #expect(book.open(in: "s1").count == 2)
        // CL24: notices at 6 and 7 confirm A then B, first in, first out.
        let expected = try #require(book.request("A")).confirmedIfNeeded(at: 6)
        let atSix = book.notice(sessionID: "s1", at: Self.t0.addingTimeInterval(6))
        #expect(atSix == .confirmed(expected))
        #expect(book.request("B")?.state == .pending)
        guard case let .confirmed(confirmedB) = book.notice(sessionID: "s1", at: Self.t0.addingTimeInterval(7)) else {
            Issue.record("B not confirmed")
            return
        }
        #expect(confirmedB.id == "B")
        // No unconfirmed and none dormant: nothing here (the engine opens a notification-only request).
        let atEight = book.notice(sessionID: "s1", at: Self.t0.addingTimeInterval(8))
        #expect(atEight == .none)
    }

    /// CL23 (P165): A answered at the keyboard, B's own window, B's notice after both windows revives B.
    @Test
    func eachWindowRunsFromItsOwnOpeningAndANoticeRevivesTheNewestDormant() {
        var book = AttentionBook()
        book.insert(Self.request("A", at: 0, releases: true))
        book.insert(Self.request("B", at: 1, releases: true))
        let windowA = book.windowElapsed("A", at: Self.t0.addingTimeInterval(8))
        let windowB = book.windowElapsed("B", at: Self.t0.addingTimeInterval(9))
        #expect(windowA.isReleased && windowB.isReleased)
        #expect(book.head(of: "s1") == nil)
        guard case let .revived(revived) = book.notice(sessionID: "s1", at: Self.t0.addingTimeInterval(9.2)) else {
            Issue.record("nothing revived")
            return
        }
        #expect(revived.id == "B" && revived.state == .confirmed)
        // A question stays a question when it comes back (C3, #74052).
        var question = AttentionBook()
        question.insert(Self.request("Q", kind: .question, releases: true))
        _ = question.windowElapsed("Q", at: Self.t0.addingTimeInterval(8))
        guard case let .revived(back) = question.notice(sessionID: "s1", at: Self.t0.addingTimeInterval(18)) else {
            Issue.record("question not revived")
            return
        }
        #expect(back.kind == .question)
        // An unarmed request is confirmed by its window, not released.
        var unarmed = AttentionBook()
        unarmed.insert(Self.request("U"))
        let windowU = unarmed.windowElapsed("U", at: Self.t0.addingTimeInterval(8))
        #expect(windowU.isConfirmed)
        // A window never touches a request no longer pending.
        let late = unarmed.windowElapsed("U", at: Self.t0.addingTimeInterval(9))
        #expect(late == .none)
    }

    /// Invariant 2, closing: a close never closes a sibling; another call's evidence closes nothing.
    @Test
    func evidenceClosesOnlyItsOwnCall() {
        var book = AttentionBook()
        book.insert(Self.request("bash", toolUseID: "U1", digest: "d1"))
        book.insert(Self.request("edit", toolName: "Edit", digest: "d2"))
        book.insert(Self.request("sub", agent: "w1", toolUseID: "U9", digest: "d9"))
        // A sibling's PostToolUse (S5).
        let sibling = book.closeForToolEvidence(sessionID: "s1", agentID: nil, toolUseID: "U2", toolName: "Read", digest: "dx")
        // The same call id from another agent is not this one's.
        let otherAgent = book.closeForToolEvidence(sessionID: "s1", agentID: nil, toolUseID: "U9", toolName: "Bash", digest: "d9")
        #expect(sibling.isEmpty && otherAgent.isEmpty)
        let own = book.closeForToolEvidence(sessionID: "s1", agentID: nil, toolUseID: "U1", toolName: "Bash", digest: "d1")
        #expect(own.map(\.id) == ["bash"])
        // A request with no call id yet: by the same agent, tool and input digest.
        let loose = book.closeForToolEvidence(sessionID: "s1", agentID: nil, toolUseID: "U3", toolName: "Edit", digest: "d2")
        #expect(loose.map(\.id) == ["edit"])
        let subagent = book.closeForToolEvidence(sessionID: "s1", agentID: "w1", toolUseID: "U9", toolName: "Bash", digest: nil)
        #expect(subagent.map(\.id) == ["sub"])
        #expect(book.all.isEmpty)
    }

    /// A PreToolUse noted before or after its PermissionRequest gives the request its call id (two sockets, any order).
    @Test
    func aPreToolUseNamesItsRequestInEitherOrder() {
        var before = AttentionBook()
        before.noteToolUse(sessionID: "s1", .init(agentID: nil, toolName: "Bash", digest: "d1", toolUseID: "U1", at: Self.t0))
        before.insert(Self.request("r", digest: "d1"))
        #expect(before.request("r")?.toolUseID == "U1")
        #expect(before.toolUses["s1"] == nil)
        var after = AttentionBook()
        after.insert(Self.request("r", digest: "d1"))
        after.noteToolUse(sessionID: "s1", .init(agentID: nil, toolName: "Bash", digest: "d1", toolUseID: "U1", at: Self.t0))
        #expect(after.request("r")?.toolUseID == "U1")
        // Another agent's, another tool's or another input's PreToolUse is not its.
        var other = AttentionBook()
        other.insert(Self.request("r", digest: "d1"))
        other.noteToolUse(sessionID: "s1", .init(agentID: "w1", toolName: "Bash", digest: "d1", toolUseID: "U7", at: Self.t0))
        other.noteToolUse(sessionID: "s1", .init(agentID: nil, toolName: "Edit", digest: "d1", toolUseID: "U8", at: Self.t0))
        other.noteToolUse(sessionID: "s1", .init(agentID: nil, toolName: "Bash", digest: "d2", toolUseID: "U9", at: Self.t0))
        #expect(other.request("r")?.toolUseID == nil)
        // Kept a while, and at most so many per session.
        var many = AttentionBook()
        for index in 0..<(AttentionBook.toolUseLimit + 5) {
            many.noteToolUse(sessionID: "s1", .init(agentID: nil, toolName: "Read", digest: "r\(index)", toolUseID: "U\(index)",
                                                    at: Self.t0.addingTimeInterval(TimeInterval(index))))
        }
        #expect(many.toolUses["s1"]?.count == AttentionBook.toolUseLimit)
        many.noteToolUse(sessionID: "s1", .init(agentID: nil, toolName: "Read", digest: "late", toolUseID: "UL",
                                                at: Self.t0.addingTimeInterval(AttentionBook.toolUseMemory + 100)))
        #expect(many.toolUses["s1"]?.map(\.toolUseID) == ["UL"])
    }

    /// Invariant 4: a closed request is gone; the book returns it so the engine releases its hook in the same step.
    @Test
    func aClosedRequestIsGoneAndReturned() {
        var book = AttentionBook()
        book.insert(Self.request("r", state: .confirmed))
        let closed = book.close("r", cause: .islandAnswer)
        #expect(closed?.id == "r")
        #expect(book.request("r") == nil && book.head(of: "s1") == nil)
        let twice = book.close("r", cause: .islandAnswer)
        #expect(twice == nil)
        book.insert(Self.request("a", session: "s2"))
        book.insert(Self.request("b", session: "s2"))
        let forgotten = book.forget("s2")
        #expect(forgotten.map(\.id) == ["a", "b"])
        #expect(book.sessionIDs.isEmpty)
    }

    /// Invariant 5: nothing is kept across a relaunch (a new book is empty; the engine keeps it in memory only).
    @Test
    func aNewBookIsEmpty() {
        let book = AttentionBook()
        #expect(book.all.isEmpty && book.sessionIDs.isEmpty)
    }

    /// Invariant 6 (C4, P166): a Codex request the old helper holds closes only by the bridge's own ends.
    @Test
    func aCodexRequestTheOldHelperHoldsClosesOnlyByTheBridgesEnds() {
        let held = Self.request("c", tool: .codex, channel: .answer(.bridge), source: .bridge, state: .confirmed)
        #expect(held.isHeldCodexLegacy)
        for cause in AttentionCloseCause.allCases {
            let allowed = [.hookEnded, .islandAnswer, .superseded, .sessionGone].contains(cause)
            #expect(AttentionBook.mayClose(held, cause: cause, fromBridge: false) == allowed, "\(cause)")
        }
        #expect(AttentionBook.mayClose(held, cause: .turnEnd, fromBridge: true))
        var book = AttentionBook()
        book.insert(held)
        let byRollout = book.close(in: "s1", cause: .rolloutOutput) { _ in true }
        let byCross = book.close("c", cause: .dismissed)
        #expect(byRollout.isEmpty && byCross == nil)
        let byBridge = book.close("c", cause: .turnEnd, fromBridge: true)
        #expect(byBridge?.id == "c")
        // A released Codex request (the new helper) closes by any evidence.
        let released = Self.request("n", tool: .codex, channel: .open, state: .confirmed)
        #expect(!released.isHeldCodexLegacy)
        #expect(AttentionBook.mayClose(released, cause: .rolloutOutput, fromBridge: false))
    }
}

private extension AttentionRequest {
    func confirmedIfNeeded(at second: TimeInterval) -> AttentionRequest {
        var copy = self
        copy.state = .confirmed
        copy.confirmedAt = AttentionBookTests.t0.addingTimeInterval(second)
        return copy
    }
}

private extension AttentionBook.WindowResult {
    var isReleased: Bool { if case .released = self { true } else { false } }
    var isConfirmed: Bool { if case .confirmed = self { true } else { false } }
}
