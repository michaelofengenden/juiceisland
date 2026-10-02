import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Replay (owner's messages 1 and 2): two permission prompts in one Claude session, the first answered at once (its
/// command then runs for minutes, so no PostToolUse yet), the second left alone. Claude's `permission_prompt` for the
/// second comes six seconds after the second arrived, while the first is still unconfirmed in the book (its own 8 s
/// window has not run). Claude only sends that notice for a prompt still on screen, so it is about the second: the
/// island must draw the second (the one really waiting), never the first, which already runs.
@MainActor
@Suite(.serialized)
struct ReplayNoticeMatchTests {
    typealias E = AttentionEndToEndTests

    func begin(_ rig: AttentionRig, entrypoint: String) async {
        await rig.finished(E.claude(rig, "SessionStart", extra: ["source": "startup"]), entrypoint: entrypoint,
                           events: [E.started("s1", transcript: E.transcript(rig, "s1"))])
        await rig.finished(E.claude(rig, "UserPromptSubmit", extra: ["prompt": "run the tests, then push"]), entrypoint: entrypoint,
                           events: E.prompt("s1", "run the tests, then push", transcript: E.transcript(rig, "s1")))
    }

    /// PreToolUse, then the PermissionRequest (held by the broker).
    func ask(_ rig: AttentionRig, useID: String, input: [String: Any], entrypoint: String) async -> HelperRun {
        await rig.finished(E.claude(rig, "PreToolUse", tool: "Bash", input: input, toolUseID: useID), entrypoint: entrypoint,
                           events: [E.running("s1", "Running Bash: \(input["command"] ?? "")")])
        let count = rig.engine.openRequests.count
        let run = rig.hook(E.claude(rig, "PermissionRequest", tool: "Bash", input: input), entrypoint: entrypoint)
        await rig.waitUntil { rig.engine.openRequests.count > count }
        return run
    }

    /// `answeredAfter`: when the owner answers the first prompt; `secondAfter`: when the second request arrives (both from
    /// the first request). The desktop sends the notice 6 s after a request arrives, flat; a terminal 6 s after the
    /// prompt appears (the first was answered before the second showed, so no keystroke defers it).
    @Test(arguments: [("claude-desktop", 2.0, 1.0), ("cli", 0.8, 1.0)])
    func theNoticeConfirmsTheRequestStillWaiting(surface: String, answeredAfter: Double, secondAfter: Double) async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await begin(rig, entrypoint: surface)
        let runA = await ask(rig, useID: "toolu_A", input: ["command": "npm test", "description": "Run the tests"], entrypoint: surface)
        rig.advance(secondAfter)
        let runB = await ask(rig, useID: "toolu_B", input: ["command": "git push origin main", "description": "Push the branch"],
                             entrypoint: surface)
        _ = answeredAfter // A was allowed at the prompt: `npm test` runs for minutes, no hook says so.
        rig.advance(6)
        await rig.finished(E.claude(rig, "Notification", extra: ["notification_type": "permission_prompt",
                                                                 "message": "Claude needs your permission to use Bash"]),
                           entrypoint: surface,
                           events: [.activityUpdated(SessionActivityUpdated(sessionID: "s1", summary: "Claude needs your permission to use Bash",
                                                                            phase: rig.engine.state.session(id: "s1")?.phase ?? .running,
                                                                            timestamp: .now))])
        rig.advance(3)
        await rig.settle()
        let head = rig.engine.attentionHead(for: "s1")
        #expect(head?.toolUseID == "toolu_B",
                "\(surface): the island shows \(head?.toolUseID ?? "nothing"); the push, which still waits, is \(rig.engine.openRequests.first { $0.toolUseID == "toolu_B" }?.state.rawValue ?? "gone")")
        #expect(rig.row("s1")?.detail?.contains("git push") == true, "\(surface): the card names \(rig.row("s1")?.detail ?? "nothing")")
        _ = (runA, runB)
    }
}
