import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// P433: a compacting row counts the compaction's own time, from the PreCompact that began it, through compaction's own
/// SessionStart (which keeps the row, P3), until the next activity; a second compaction starts its own count.
@MainActor
struct CompactionClockTests {
    private typealias F = EngineFixtures

    private func since(_ engine: SessionEngine, _ id: String = "s1") -> Date? {
        engine.state.session(id: id).flatMap(engine.compactingSince(for:))
    }

    @Test
    func aCompactionIsTimedFromItsPreCompactUntilTheNextActivity() {
        let engine = F.engine()
        let t0 = F.now
        engine.ingest(F.started("s1", at: t0), ingress: .bridge)
        engine.ingest(F.prompt("s1", at: t0 + 5), ingress: .bridge)
        engine.ingest(F.running("s1", summary: "Running Bash", at: t0 + 60), ingress: .bridge)
        #expect(since(engine) == nil)
        engine.ingest(F.compacting("s1", at: t0 + 100), ingress: .bridge)
        #expect(since(engine) == t0 + 100)
        // Compaction's own SessionStart keeps the row and its count (P3).
        let start = SessionStarted(sessionID: "s1", title: "Claude · project", tool: .claudeCode, origin: .live, initialPhase: .completed,
                                   summary: "Compacted Claude Code context in project.", timestamp: t0 + 130,
                                   claudeMetadata: ClaudeSessionMetadata(model: "claude-opus", startupSource: .compact))
        engine.ingest(.sessionStarted(start), ingress: .bridge)
        let session = engine.state.session(id: "s1")
        #expect(session.map { engine.statusWord(for: $0) } == .compacting)
        #expect(since(engine) == t0 + 100)
        // The turn's own clock is left as it was.
        #expect(session.flatMap(engine.activeSince(for:)) == t0 + 5)
        // The next activity ends it; another compaction counts from its own start.
        engine.ingest(F.running("s1", summary: "Running Edit", at: t0 + 140), ingress: .bridge)
        #expect(since(engine) == nil)
        engine.ingest(F.compacting("s1", at: t0 + 200), ingress: .bridge)
        #expect(since(engine) == t0 + 200)
        engine.ingest(F.completed("s1", at: t0 + 260), ingress: .bridge)
        #expect(since(engine) == nil)
        // `/compact` at the prompt, after a finished turn: its own start.
        engine.ingest(F.compacting("s1", at: t0 + 300), ingress: .bridge)
        #expect(since(engine) == t0 + 300)
    }

    @Test
    func aSessionNotCompactingHasNoCount() {
        let engine = F.engine()
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.prompt("s1"), ingress: .bridge)
        #expect(since(engine) == nil)
        engine.ingest(F.running("s1", summary: "Thinking."), ingress: .bridge)
        #expect(since(engine) == nil)
        #expect(StatusWord.isCompacting(engine.state.session(id: "s1")!) == false)
    }
}
