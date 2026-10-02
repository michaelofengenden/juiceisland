import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Motion round A's switches: Diagnostics › Motion with Record island motion on and its last motions, and Settings ›
/// Island with Motion and Hover set to the new feels. Renders: `ra-*.png`.
@MainActor
@Suite(.serialized)
struct MotionRoundARenders {
    /// Record on (its folder said once, under the section), Ask for 120 Hz off, and four motions, newest first: a card
    /// whose hitches are critical (red), a close with noticeable ones (amber), a clean open and a swell with no jobs.
    @Test func diagnosticsMotion() throws {
        let settings = AppSettings.ephemeral()
        settings.recordIslandMotion = true
        let env = AppEnvironment.demo(settings: settings)
        let log = env.motionLog
        log.add(MotionRecorderTests.report(events: ["swell", "unswell"], fps: 120, late: nil))
        log.add(MotionRecorderTests.report(events: ["swell", "open-hover-list"], fps: 118.4, late: 5.8))
        log.add(MotionRecorderTests.report(events: ["close-fold"], fps: 96.2, hitches: 2, ratio: 6.3, late: 9.2))
        log.add(MotionRecorderTests.report(events: ["present-card"], fps: 71, hitches: 5, ratio: 18.4, late: 14))
        try render(.diagnostics, "ra-diagnostics-motion", env: env)
    }

    /// Settings › Island with Motion: Refined and Hover: Quick.
    @Test func islandMotionAndHover() throws {
        let settings = AppSettings.ephemeral()
        settings.islandMotion = .refined
        settings.islandHover = .quick
        try render(.island, "ra-settings-island-motion", env: AppEnvironment.demo(settings: settings))
    }

    private func render(_ pane: SettingsPane, _ name: String, env: AppEnvironment) throws {
        let view = SettingsRootView(navigation: SettingsNavigation(pane: pane), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }
}
