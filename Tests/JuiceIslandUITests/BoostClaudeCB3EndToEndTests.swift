import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// CB3 end to end (built helper, the real broker and notes sockets, engine, model): two held requests, A answered at
/// the keyboard (its tool runs), B waiting; B's notice 6 s after B arrived puts A on the card instead of B.
@MainActor
@Suite(.serialized)
struct BoostClaudeCB3EndToEndTests {
    typealias E = AttentionEndToEndTests
    static let edit: [String: Any] = ["file_path": "/tmp/project/a.swift", "old_string": "a", "new_string": "b"]

    @Test
    func cb3TheCardShowsTheRequestStillWaiting() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await rig.finished(E.claude(rig, "SessionStart", extra: ["source": "startup"]),
                           events: [E.started("s1", transcript: E.transcript(rig, "s1"))])
        await rig.finished(E.claude(rig, "UserPromptSubmit", extra: ["prompt": "fix the tests"]),
                           events: E.prompt("s1", "fix the tests", transcript: E.transcript(rig, "s1")))
        await rig.finished(E.claude(rig, "PreToolUse", tool: "Bash", input: E.push, toolUseID: "U1"), events: [E.running("s1")])
        let runA = rig.hook(E.claude(rig, "PermissionRequest", tool: "Bash", input: E.push))
        await rig.waitUntil { rig.engine.openRequests.count == 1 }
        rig.advance(1)
        await rig.finished(E.claude(rig, "PreToolUse", tool: "Edit", input: Self.edit, toolUseID: "U2"),
                           events: [E.running("s1", "Running Edit")])
        let runB = rig.hook(E.claude(rig, "PermissionRequest", tool: "Edit", input: Self.edit))
        await rig.waitUntil { rig.engine.openRequests.count == 2 }
        let b = try #require(rig.engine.openRequests.last?.id)
        rig.advance(6)
        await rig.finished(E.claude(rig, "Notification", extra: ["notification_type": "permission_prompt",
                                                                 "message": "Claude needs your permission to use Edit"]))
        guard case let .approval(card)? = rig.card("s1") else {
            Issue.record("no approval card")
            return
        }
        #expect(card.request?.id == b && card.tool == "Edit", "the card shows A (answered, running) instead of B")
        runA.kill()
        runB.kill()
    }
}
