import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// CB3 (boost hunt, Claude main-thread and subagent approval rows, C2/P165): "A permission request that arrives while
/// another dialog is on screen keeps the same six-second gate, timed from when the request arrives. Its notification
/// can reach you while the request still waits behind the open dialog" (hooks#notification). A (t=0) is answered at
/// the keyboard at 3 s and its tool runs (no PostToolUse yet, so A is still pending in the book until its 8 s window);
/// B (t=1) waits, and its notice comes at 7 s. The book gives the notice to the oldest pending request, A: A is drawn
/// (answerable, though Claude no longer reads its hook), B is released at 9 s and never shown, and when A's tool ends
/// nothing is drawn while B still waits: a phantom "!" and a missed prompt at once.
@MainActor
struct BoostClaudeCB3Tests {
    typealias S = AttentionScene

    @Test
    func cb3TheNoticeGoesToTheRequestStillWaiting() throws {
        let s = S()
        s.begin()
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "U1"))
        let a = try #require(s.hook(S.claude("PermissionRequest", tool: "Bash", input: S.push)))
        s.at(1)
        s.hook(S.claude("PreToolUse", tool: "Edit", input: S.edit, toolUseID: "U2"))
        let b = try #require(s.hook(S.claude("PermissionRequest", tool: "Edit", input: S.edit)))
        s.at(7)
        s.hook(S.notification("permission_prompt"))
        #expect(s.head()?.id == b, "the notice confirmed A, answered at the keyboard, instead of B")
        #expect(s.state(a) != .confirmed)
        s.at(9)
        #expect(s.state(b) == .confirmed)
        s.at(60)
        s.hook(S.claude("PostToolUse", tool: "Bash", input: S.push, toolUseID: "U1"))
        #expect(s.head()?.id == b && s.glyph() == "!", "B still waits at the terminal")
    }

    /// The same with two background subagents (the default since 2.1.198), whose prompts queue in the main session.
    @Test
    func cb3ASubagentsNoticeGoesToTheRequestStillWaiting() throws {
        let s = S()
        s.begin()
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "UW1", agent: "w1"))
        let a = try #require(s.hook(S.claude("PermissionRequest", tool: "Bash", input: S.push, agent: "w1")))
        s.at(1)
        s.hook(S.claude("PreToolUse", tool: "Edit", input: S.edit, toolUseID: "UW2", agent: "w2", agentType: "tester"))
        let b = try #require(s.hook(S.claude("PermissionRequest", tool: "Edit", input: S.edit, agent: "w2", agentType: "tester")))
        s.at(7)
        s.hook(S.notification("permission_prompt"))
        #expect(s.head()?.id == b && s.head()?.agentType == "tester")
        #expect(s.state(a) != .confirmed)
    }
}
