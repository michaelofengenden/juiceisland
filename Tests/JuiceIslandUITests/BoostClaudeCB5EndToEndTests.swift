import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// CB5 end to end: a finished session whose background subagent's request closes reads finished, not running.
@MainActor
@Suite(.serialized)
struct BoostClaudeCB5EndToEndTests {
    typealias E = AttentionEndToEndTests

    @Test
    func cb5TheRowReadsFinishedAfterTheSubagentsRequest() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await rig.finished(E.claude(rig, "SessionStart", extra: ["source": "startup"]),
                           events: [E.started("s1", transcript: E.transcript(rig, "s1"))])
        await rig.finished(E.claude(rig, "UserPromptSubmit", extra: ["prompt": "fix the tests"]),
                           events: E.prompt("s1", "fix the tests", transcript: E.transcript(rig, "s1")))
        await rig.finished(E.claude(rig, "Stop"), events: E.stop("s1", lastPrompt: "fix the tests"))
        rig.advance(2)
        #expect(rig.row("s1")?.bucket == .done)
        // A background subagent asks; upstream's bridge acknowledges a subagent's hooks with no event.
        await rig.finished(E.claude(rig, "PreToolUse", tool: "Bash", input: E.push, toolUseID: "UW", agent: "w1"))
        let run = rig.hook(E.claude(rig, "PermissionRequest", tool: "Bash", input: E.push, agent: "w1"))
        await rig.waitUntil { !rig.engine.openRequests.isEmpty }
        _ = await run.result(within: 30)
        rig.advance(6)
        await rig.finished(E.claude(rig, "Notification", extra: ["notification_type": "permission_prompt",
                                                                 "message": "Claude needs your permission to use Bash"]))
        #expect(rig.row("s1")?.glyph == .bang)
        rig.advance(30)
        // Its SubagentStop: the bridge's phase is completed, so it acknowledges with no event.
        await rig.finished(E.claude(rig, "SubagentStop", agent: "w1"))
        #expect(rig.engine.openRequests.isEmpty)
        #expect(rig.row("s1")?.bucket == .done, "the finished session now reads running")
    }
}
