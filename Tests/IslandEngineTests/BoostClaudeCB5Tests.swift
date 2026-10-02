import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// CB5 (boost hunt, Claude RUNNING / WAITING-PROMPT rows): when the book's last confirmed request closes, the engine
/// applies upstream's `actionableStateResolved`, which always sets `.running` (`SessionState.swift:244-258`). When the
/// main thread had already finished (a background subagent's request after the main Stop), the session then reads
/// Running with nothing running, and nothing moves it back: upstream's bridge acknowledges the subagent's SubagentStop
/// with no event when its own phase is completed (`BridgeServer.swift:963-977`).
@MainActor
struct BoostClaudeCB5Tests {
    typealias S = AttentionScene
    typealias F = EngineFixtures

    @Test
    func cb5ASubagentsRequestClosingLeavesAFinishedSessionFinished() throws {
        let s = S()
        s.begin()
        s.hook(S.claude("Stop"))
        s.bridge(F.completed("s1", at: s.clock.current))
        s.at(2)
        #expect(s.phase() == .completed)
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "UW", agent: "w1"))
        let id = try #require(s.hook(S.claude("PermissionRequest", tool: "Bash", input: S.push, agent: "w1")))
        s.at(8)
        s.hook(S.notification("permission_prompt"))
        #expect(s.head()?.id == id && s.phase() == .waitingForApproval)
        s.at(40)
        s.hook(S.claude("SubagentStop", agent: "w1"))
        #expect(!s.isOpen(id))
        #expect(s.phase() == .completed, "the finished session now reads running")
    }

    /// The ✕ on that read-only card, with the main thread finished.
    @Test
    func cb5DismissingANoticeLeavesAFinishedSessionFinished() throws {
        let s = S()
        s.begin()
        s.hook(S.claude("Stop"))
        s.bridge(F.completed("s1", at: s.clock.current))
        s.at(2)
        s.hook(S.claude("PreToolUse", tool: "Bash", input: S.push, toolUseID: "UW", agent: "w1"))
        let id = try #require(s.hook(S.claude("PermissionRequest", tool: "Bash", input: S.push, agent: "w1")))
        s.at(8)
        s.hook(S.notification("permission_prompt"))
        s.engine.dismissRequest(requestID: id)
        #expect(s.phase() == .completed)
    }
}
