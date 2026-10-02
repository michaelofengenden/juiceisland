import Foundation
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Tier 2 of the needs-you test plan (§5.2): the same path with upstream's real `BridgeServer` on a scratch socket
/// instead of the stand-in, so upstream's own events and holds are what the engine sees. Runs only when
/// JUICE_ISLAND_BRIDGE_TESTS=1, which scripts/test.sh sets after checking that no island app owns a hook socket:
/// BridgeServer also binds the legacy /tmp/open-island-<uid>.sock and deletes whatever is there.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["JUICE_ISLAND_BRIDGE_TESTS"] == "1"))
struct AttentionBridgeTests {
    typealias E = AttentionEndToEndTests

    /// CL2 through upstream's bridge: its own SessionStart, prompt and PreToolUse events; the broker holds the request;
    /// Claude's notice confirms it; the island's Allow is printed by the helper.
    @Test
    func cl2ThroughTheRealBridge() async throws {
        let rig = try await AttentionRig(realBridge: true)
        defer { rig.stop() }
        await rig.waitUntil { rig.engine.isBridgeReady }
        await rig.finished(E.claude(rig, "SessionStart", extra: ["source": "startup"]))
        await rig.finished(E.claude(rig, "UserPromptSubmit", extra: ["prompt": "fix the tests"]))
        await rig.finished(E.claude(rig, "PreToolUse", tool: "Bash", input: E.push, toolUseID: "U1"))
        let run = rig.hook(E.claude(rig, "PermissionRequest", tool: "Bash", input: E.push))
        await rig.waitUntil { !rig.engine.openRequests.isEmpty }
        rig.advance(6)
        #expect(rig.row("s1")?.bucket != .needsYou)
        await rig.finished(E.claude(rig, "Notification", extra: ["notification_type": "permission_prompt", "message": "Claude needs your permission"]))
        #expect(rig.row("s1")?.glyph == .bang)
        await rig.model.decide("s1", .allowOnce)
        let result = await run.result(within: 30)
        #expect(result?.printed.contains(#""behavior":"allow""#) == true)
    }

    /// CL20 through upstream's bridge: no broker, so upstream's helper and bridge hold the request as before; the
    /// island's answer goes through the bridge and reaches the helper; its echo is never a Done (C12).
    @Test
    func cl20ThroughTheRealBridge() async throws {
        let rig = try await AttentionRig(broker: false, realBridge: true)
        defer { rig.stop() }
        await rig.waitUntil { rig.engine.isBridgeReady }
        await rig.finished(E.claude(rig, "SessionStart", extra: ["source": "startup"]))
        await rig.finished(E.claude(rig, "UserPromptSubmit", extra: ["prompt": "fix the tests"]))
        let run = rig.hook(E.claude(rig, "PermissionRequest", tool: "Bash", input: E.push))
        await rig.waitUntil { !rig.engine.openRequests.isEmpty }
        rig.advance(6)
        await rig.finished(E.claude(rig, "Notification", extra: ["notification_type": "permission_prompt", "message": "Claude needs your permission"]))
        #expect(rig.row("s1")?.glyph == .bang)
        await rig.model.decide("s1", .deny)
        let result = await run.result(within: 30)
        #expect(result?.printed.contains(#""behavior":"deny""#) == true)
        await rig.settle()
        rig.advance(5)
        #expect(rig.dones.isEmpty && rig.row("s1")?.status == .denied(tool: "Bash"))
    }
}
