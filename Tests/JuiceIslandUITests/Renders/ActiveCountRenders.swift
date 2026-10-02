import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The pill's count of active sessions: 30 rows from a day of history, 3 of them active, read "3"; Needs you reads
/// the one waiting. Settings › Island's Pill count ("Active" | "Needs you") is `A-settings-island` (ARenders).
@MainActor
@Suite(.serialized)
struct ActiveCountRenders {
    @Test(arguments: PillCount.allCases)
    func pillCountsTheActiveSessions(_ mode: PillCount) throws {
        let settings = AppSettings.ephemeral()
        settings.closedPillCount = mode
        let sessions = DStub(rows: ActiveCountTests.thirtyRows)
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: DemoClock.now), sessions: sessions)
        #expect(PillSummary.make(rows: sessions.rows, countMode: mode, now: sessions.now).count == (mode == .active ? 3 : 1))
        try RenderHarness.render(DScene.pill(ClosedPillView(animated: false)), "D-pill-count-\(mode.rawValue)-of-30", env: env)
    }
}
