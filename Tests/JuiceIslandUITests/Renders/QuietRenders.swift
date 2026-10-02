import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Settings › Island › Quiet (P330 to P333) and the pill in full screen. `QM-settings-island-quiet-off`: the two
/// switches, off (their follow-up rows hidden); `QM-settings-island-quiet-on`: Hide in full screen with Show needs you,
/// and Quiet hours 22:00 to 08:00. `QM-pill-fullscreen-*`: the pill as ever, then in full screen with Show needs you
/// (only what needs you and how many wait); hidden, it is not drawn at all.
@MainActor
@Suite(.serialized)
struct QuietRenders {
    private func renderIslandPane(_ name: String, settings: AppSettings) throws {
        let env = AppEnvironment.demo(settings: settings)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .island), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.locale, Locale(identifier: "en_GB"))
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    @Test func islandPaneQuietOff() throws {
        try renderIslandPane("QM-settings-island-quiet-off", settings: .ephemeral())
    }

    @Test func islandPaneQuietOn() throws {
        let settings = AppSettings.ephemeral()
        settings.hideInFullScreen = true
        settings.fullScreenShowsNeedsYou = true
        settings.quietHours = true
        try renderIslandPane("QM-settings-island-quiet-on", settings: settings)
    }

    @Test func thePillInFullScreen() throws {
        let rows = [ActiveCountTests.row("r", .codex, .running, ago: 10), ActiveCountTests.row("q", .claude, .needsYou, ago: 60),
                    ActiveCountTests.row("d", .claude, .done, ago: 120)]
        let settings = AppSettings.ephemeral()
        settings.hideInFullScreen = true
        settings.fullScreenShowsNeedsYou = true
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: rows))
        for (name, fullScreen) in [("QM-pill-fullscreen-before", false), ("QM-pill-fullscreen-needs-you", true)] {
            let content = QuietModeTests.pill(rows, settings: settings, fullScreen: fullScreen)
            #expect(content.count == (fullScreen ? 1 : 3))
            try RenderHarness.render(DScene.pill(ClosedPillView(animated: false, content: content)), name, env: env)
        }
    }
}
