import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// CB1 (boost hunt, Claude FAILED row): a failed turn is cleared by the session's later *activity* (PreToolUse,
/// PostToolUse, SubagentStart, UserPromptSubmit, Stop), a jump, a dismiss or SessionEnd, never by a Notification.
/// Upstream's bridge echoes every Claude Notification as `activityUpdated` (`BridgeServer.swift:862-887`: phase
/// `.completed` for `idle_prompt`, the bridge's current phase otherwise), and Claude sends `idle_prompt` about 60 s
/// after a turn ends with nobody typing (hooks#notification), which is exactly when the owner is away.
@MainActor
struct BoostClaudeCB1Tests {
    typealias S = AttentionScene
    typealias F = EngineFixtures

    /// Upstream's echo of a Claude Notification.
    static func echo(_ phase: SessionPhase, _ message: String, at date: Date) -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: "s1", summary: message, phase: phase, timestamp: date))
    }

    @Test
    func cb1AFailedTurnOutlivesIdlePrompt() throws {
        let s = S()
        s.begin()
        s.hook(S.claude("StopFailure", extra: ["error": "server_error"]))
        s.bridge(F.completed("s1", at: s.clock.current))
        #expect(s.engine.hasFailedTurn(try #require(s.engine.state.session(id: "s1"))))
        s.at(60)
        s.hook(S.notification("idle_prompt"))
        s.bridge(Self.echo(.completed, "Claude is waiting for your input", at: s.clock.current))
        let after = try #require(s.engine.state.session(id: "s1"))
        #expect(s.engine.hasFailedTurn(after) && s.engine.needsAttention(after), "idle_prompt cleared the failed turn")
        #expect(s.engine.statusWord(for: after) != .done)
    }

    /// A usage-limit wait that ends without continuing (`quota_auto_resume_disabled`): Claude did not carry on.
    @Test
    func cb1AFailedTurnOutlivesAQuotaNotice() throws {
        let s = S()
        s.begin()
        s.hook(S.claude("StopFailure", extra: ["error": "rate_limit"]))
        s.bridge(F.completed("s1", at: s.clock.current))
        s.at(600)
        s.hook(S.notification("quota_auto_resume_disabled"))
        s.bridge(Self.echo(.completed, "Claude stopped waiting for the usage limit", at: s.clock.current))
        #expect(s.engine.hasFailedTurn(try #require(s.engine.state.session(id: "s1"))))
    }
}
