import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// After the merge: one environment drives both modes. Window mode draws the toolbar, usage header and sessions;
/// Show as Island (the same action the toolbar, menu and island gear call) gives the pill and the opened island over
/// the same usage and sessions; Show as Window brings the window back. Nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct MRenders {
    /// The app's wiring for `setShowAs`, without windows: the delegate writes the setting and observes it.
    private func environment() -> AppEnvironment {
        let env = AppEnvironment.demo(settings: .ephemeral(), sessions: .prototype)
        env.actions.setShowAs = { [weak env] mode in env?.settings.showAs = mode }
        return env
    }

    @Test func showAsRoundTrip() throws {
        let env = environment()
        #expect(env.settings.showAs == .window)
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), "M-window-mode-1200",
                                       size: WindowTheme.Metrics.defaultSize, env: env)

        env.actions.setShowAs(.island)
        #expect(env.settings.showAs == .island)
        try RenderHarness.render(DScene.pill(ClosedPillView(animated: false)), "M-island-mode-pill", env: env)
        try RenderHarness.render(DScene.island(OpenedIslandView(presentation: .list, animated: false),
                                               notch: IslandTheme.Metrics.referenceNotch), "M-island-mode-open", env: env)

        env.actions.setShowAs(.window)
        #expect(env.settings.showAs == .window)
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), "M-window-mode-back-900",
                                       size: CGSize(width: 900, height: 760), env: env)
    }

    @Test func islandAndWindowShowTheSameSessionsAndUsage() {
        let env = environment()
        let now = env.sessions.now
        let windowIDs = SessionListLayout.displayOrder(env.sessions.rows, now: now).map(\.id)
        let islandIDs = IslandListLayout.make(rows: env.sessions.rows, style: env.settings.islandStyle, showAll: true, now: now).shown.map(\.id)
        #expect(islandIDs == windowIDs && Set(windowIDs) == Set(env.sessions.rows.map(\.id)))
        let active = env.sessions.rows.filter { SessionActivity.isActive($0, now: now) }
        #expect(PillSummary.make(rows: env.sessions.rows, countMode: env.settings.closedPillCount, now: now).count == active.count)
        // The demo's week window no longer binds first: Main and Work read as the prototype (82, 100).
        let claude = env.usage.claudeRow?.batteries ?? []
        #expect(claude.first { $0.alias == "Main" }?.state == .available(percentLeft: 82, isLow: false))
        #expect(claude.first { $0.alias == "Work" }?.state == .available(percentLeft: 100, isLow: false))
    }
}
