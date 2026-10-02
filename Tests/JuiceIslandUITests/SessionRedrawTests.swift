import Foundation
import IslandEngine
import Observation
import OpenIslandCore
import Testing
@testable import JuiceIslandUI

/// P89: views redraw only when what they draw changed. The session lists observe the model's revision, never the
/// engine: an engine change that leaves every row and card as it was redraws nothing, and the ages move on each minute.
@MainActor
@Suite(.serialized)
struct SessionRedrawTests {
    /// An engine change that leaves every row and card as it was (here: the profiles set again, which clears the
    /// account tags a preview session never had) redraws nothing; a new session does, and a read right after it sees it.
    @Test func onlyAChangeViewsDrawRedrawsThem() async throws {
        let engine = SessionEngine.preview(clock: { DemoClock.now })
        engine.loadPreviewEvents(FixtureSessionFeed.events(.prototype, now: DemoClock.now))
        let model = EngineSessionsModel(engine: engine, clock: { DemoClock.now })
        let before = model.rows
        let redraws = Redraws()
        redraws.watch { _ = model.rows; _ = model.card(for: FixtureSessionFeed.ID.question) }

        engine.setProfiles(accounts: [], discovered: [])
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(redraws.count == 0)
        #expect(model.rows == before)

        engine.loadPreviewEvents([
            .sessionStarted(SessionStarted(sessionID: "perf-new", title: "A new task", tool: .claudeCode, origin: .live,
                                           initialPhase: .running, summary: "Started.", timestamp: DemoClock.now - 10,
                                           jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "demo", paneTitle: "claude",
                                                                  workingDirectory: "/tmp/demo"),
                                           claudeMetadata: ClaudeSessionMetadata(lastUserPrompt: "start"))),
            .activityUpdated(SessionActivityUpdated(sessionID: "perf-new", summary: FixtureSessionFeed.promptPrefix + "start",
                                                    phase: .running, timestamp: DemoClock.now - 9)),
        ])
        #expect(model.row(id: "perf-new") != nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(redraws.count == 1)
    }

    /// A hook event that moves only a running session's time, inside the minute it had, redraws nothing: ages show
    /// whole minutes. One in a later minute does.
    @Test func aNewTimeInTheSameMinuteRedrawsNothing() async throws {
        let engine = SessionEngine.preview(clock: { DemoClock.now })
        engine.loadPreviewEvents(FixtureSessionFeed.events(.prototype, now: DemoClock.now))
        let minute = Date(timeIntervalSinceReferenceDate: (DemoClock.now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 - 180)
        func activity(at date: Date) -> [AgentEvent] {
            [.activityUpdated(SessionActivityUpdated(sessionID: "perf-tick", summary: "Working.", phase: .running, timestamp: date))]
        }
        engine.loadPreviewEvents([
            .sessionStarted(SessionStarted(sessionID: "perf-tick", title: "A long task", tool: .claudeCode, origin: .live,
                                           initialPhase: .running, summary: "Working.", timestamp: minute + 5,
                                           jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "demo", paneTitle: "claude",
                                                                  workingDirectory: "/tmp/demo"),
                                           claudeMetadata: ClaudeSessionMetadata(lastUserPrompt: "start"))),
        ] + activity(at: minute + 10))
        let model = EngineSessionsModel(engine: engine, clock: { DemoClock.now })
        #expect(model.row(id: "perf-tick")?.updatedAt == minute + 10)
        let redraws = Redraws()
        redraws.watch { _ = model.rows }

        engine.loadPreviewEvents(activity(at: minute + 40))
        #expect(model.row(id: "perf-tick")?.updatedAt == minute + 40)
        try await Task.sleep(for: .milliseconds(50))
        #expect(redraws.count == 0)

        engine.loadPreviewEvents(activity(at: minute + 70))
        try await Task.sleep(for: .milliseconds(50))
        #expect(redraws.count == 1)
    }

    /// Ages move on each minute, with nothing else changing.
    @Test func aNewMinuteRedrawsTheAges() {
        var now = DemoClock.now
        let engine = SessionEngine.preview(clock: { DemoClock.now })
        engine.loadPreviewEvents(FixtureSessionFeed.events(.prototype, now: DemoClock.now))
        let model = EngineSessionsModel(engine: engine, clock: { now })
        let redraws = Redraws()
        redraws.watch { _ = model.now }
        model.tick()
        #expect(redraws.count == 0)
        now += 61
        model.tick()
        #expect(redraws.count == 1)
    }

    @Test func requestedJumpsKeepTheLastTwenty() {
        let model = FixtureSessionFeed(scenario: .prototype).makeModel()
        for index in 0..<30 { model.jump("s\(index)") }
        #expect(model.requestedJumps.count == EngineSessionsModel.requestedJumpLimit)
        #expect(model.requestedJumps.last == "s29")
    }
}

/// Counts the changes a tracked read sees, re-tracking after each one, as a SwiftUI body would.
@MainActor
final class Redraws {
    var count = 0

    func watch(_ read: @escaping @MainActor () -> Void) {
        withObservationTracking(read) { [weak self] in
            MainActor.assumeIsolated { self?.count += 1 }
            Task { @MainActor [weak self] in self?.watch(read) }
        }
    }
}
