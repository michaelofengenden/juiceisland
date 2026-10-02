import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// P155 in the engine: a turn started by a background task's notification is a real turn (its Stop is one Done), but
/// its text never replaces the owner's prompt and never surfaces a session by itself.
@MainActor
struct PromptTextEngineTests {
    private typealias F = EngineFixtures
    static let notification = "<task-notification>\n<task-id>b1a2c3d4</task-id>\n<status>completed</status>\n</task-notification>"

    private func metadata(_ id: String, prompt: String, first: String = "fix the tests") -> AgentEvent {
        .claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
            initialUserPrompt: first, lastUserPrompt: prompt), timestamp: F.now))
    }

    @Test
    func aNotificationTurnKeepsTheHumanPromptAndGivesOneDone() {
        let clock = F.Box(F.now)
        let engine = F.engine(clock: clock)
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(metadata("s1", prompt: "fix the tests"), ingress: .bridge)
        engine.ingest(F.prompt("s1", "fix the tests"), ingress: .bridge)
        engine.ingest(F.completed("s1"), ingress: .bridge)
        clock.update { $0 = $0.addingTimeInterval(2) }
        engine.flushHeldSignals()
        #expect(signals == [.done(sessionID: "s1")])

        engine.ingest(metadata("s1", prompt: Self.notification), ingress: .bridge)
        engine.ingest(F.prompt("s1", Self.notification), ingress: .bridge)
        #expect(engine.signals.turn(for: "s1") == 2)
        #expect(engine.state.session(id: "s1")?.claudeMetadata?.lastUserPrompt == "fix the tests")
        engine.ingest(F.completed("s1"), ingress: .bridge)
        clock.update { $0 = $0.addingTimeInterval(2) }
        engine.flushHeldSignals()
        #expect(signals == [.done(sessionID: "s1"), .done(sessionID: "s1")])
    }

    @Test
    func aSessionFirstSeenThroughANotificationIsNotSurfaced() {
        let engine = F.engine()
        engine.ingest(F.started("bg"), ingress: .bridge)
        engine.ingest(metadata("bg", prompt: Self.notification, first: Self.notification), ingress: .bridge)
        engine.ingest(F.prompt("bg", Self.notification), ingress: .bridge)
        #expect(engine.rows.isEmpty)
        #expect(engine.state.session(id: "bg").flatMap(SessionEngine.recordedPrompt(of:)) == nil)
    }
}
