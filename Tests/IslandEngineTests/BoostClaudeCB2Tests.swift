import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// CB2 (boost hunt, Claude "prompt with no hook" and MCP rows): upstream's bridge echoes every Claude Notification as
/// `activityUpdated` carrying *the bridge's own current phase* (`BridgeServer.swift:862-887`), which is `.completed`
/// whenever the main thread has finished (a background subagent asks after the main Stop; background is the default
/// since 2.1.198) or the bridge has never seen the session (the app relaunched; `ensureClaudeSessionExists` starts it
/// completed). The engine reads any bridge `activityUpdated(.completed)` as a turn end and closes the root's requests,
/// so the notice the same Notification just opened (its note arrives first: the prelude sends it before upstream's
/// helper runs) is closed at once: the prompt is missed.
@MainActor
struct BoostClaudeCB2Tests {
    typealias S = AttentionScene
    typealias F = EngineFixtures

    static func echo(_ phase: SessionPhase, _ message: String, at date: Date) -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: "s1", summary: message, phase: phase, timestamp: date))
    }

    /// A background subagent's sandboxed command asks for a network host after the main thread's Stop (no
    /// PermissionRequest for it: hooks#permissionrequest).
    @Test
    func cb2ANetworkPromptAfterTheMainStopSurvivesItsOwnEcho() {
        let s = S()
        s.begin()
        s.hook(S.claude("Stop"))
        s.bridge(F.completed("s1", at: s.clock.current))
        s.at(30)
        s.hook(S.notification("permission_prompt"))
        #expect(s.glyph() == "!")
        s.bridge(Self.echo(.completed, "Claude needs your permission", at: s.clock.current))
        #expect(s.glyph() == "!", "the bridge's echo of the same Notification closed the notice it opened")
    }

    /// An MCP form from a background subagent after the main thread's Stop.
    @Test
    func cb2AnMCPFormAfterTheMainStopSurvivesItsOwnEcho() {
        let s = S()
        s.begin()
        s.hook(S.claude("Stop"))
        s.bridge(F.completed("s1", at: s.clock.current))
        s.at(30)
        s.hook(S.notification("elicitation_dialog"))
        #expect(s.glyph() == "?")
        s.bridge(Self.echo(.completed, "An MCP server needs your input", at: s.clock.current))
        #expect(s.glyph() == "?")
    }

    /// Relaunch mid-wait, before Claude's notice: the new bridge has never seen the session, so its first event for
    /// it is the start it makes up (completed) and then the Notification's echo (completed).
    @Test
    func cb2ANoticeAfterARelaunchSurvivesTheFreshBridge() {
        let s = S()
        s.begin()
        s.bridge(F.running("s1", summary: "Running Bash: git push origin main", at: s.clock.current))
        s.at(6)
        s.hook(S.notification("permission_prompt"))
        #expect(s.glyph() == "!")
        s.bridge(F.started("s1", source: nil, phase: .completed, at: s.clock.current),
                 Self.echo(.completed, "Claude needs your permission to use Bash", at: s.clock.current))
        #expect(s.glyph() == "!")
    }
}
