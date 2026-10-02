import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// CB1 end to end (built helper, real sockets, engine, model): a failed turn's row still needs you after Claude's
/// `idle_prompt`, which upstream's bridge echoes as a completed activity.
@MainActor
@Suite(.serialized)
struct BoostClaudeCB1EndToEndTests {
    typealias E = AttentionEndToEndTests

    @Test
    func cb1TheFailedRowOutlivesIdlePrompt() async throws {
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await rig.finished(E.claude(rig, "SessionStart", extra: ["source": "startup"]),
                           events: [E.started("s1", transcript: E.transcript(rig, "s1"))])
        await rig.finished(E.claude(rig, "UserPromptSubmit", extra: ["prompt": "fix the tests"]),
                           events: E.prompt("s1", "fix the tests", transcript: E.transcript(rig, "s1")))
        await rig.finished(E.claude(rig, "StopFailure", extra: ["error": "server_error", "last_assistant_message": "API Error: 500"]),
                           events: [.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "server_error", timestamp: .now))])
        await rig.settle()
        #expect(rig.row("s1")?.status == .failed && rig.row("s1")?.bucket == .needsYou)
        rig.advance(60)
        await rig.finished(E.claude(rig, "Notification", extra: ["notification_type": "idle_prompt",
                                                                 "message": "Claude is waiting for your input"]),
                           events: [.activityUpdated(SessionActivityUpdated(sessionID: "s1", summary: "Claude is waiting for your input",
                                                                            phase: .completed, timestamp: .now))])
        #expect(rig.row("s1")?.status == .failed && rig.row("s1")?.bucket == .needsYou,
                "idle_prompt turned the failed turn into a finished one")
    }
}
