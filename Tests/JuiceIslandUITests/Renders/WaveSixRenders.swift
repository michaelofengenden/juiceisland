import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Wave 6's lanes together, as merged. `W6-settings-island`: Settings › Island with every row the wave added showing
/// (Width, Text size, Questions open the island off with its line, Update dot on the pill, Answer Codex in Juice,
/// Quiet while locked, two mute rules), and the rows that show only under another (Liquid's Pill edge line and Running,
/// Show needs you, Quiet hours' span); `W6-settings-sound`: Volume and a Question sound of its own;
/// `W6-settings-general`: Behavior with Permission modes on cards, Remind again and Notification banners;
/// `W6-island-detailed-580-15`: the Detailed island at 580 and 15 pt, its rows with a branch, a compaction's time and the
/// model's facts; `W6-card-plan-640-15`: a plan's card with its mode buttons at 15 pt. Nothing is shown on screen:
/// `zsh scripts/render-all.sh WaveSixRenders`.
@MainActor
@Suite(.serialized)
struct WaveSixRenders {
    typealias ID = FixtureSessionFeed.ID
    static let notch = IslandTheme.Metrics.referenceNotch

    @Test func islandPaneWithEveryNewRow() throws {
        let settings = AppSettings.ephemeral()
        settings.islandWidth = 520
        settings.islandTextSize = 13
        settings.glyphStyle = .liquid
        settings.questionsOpenIsland = false
        settings.answerCodexOnIsland = true
        settings.hideInFullScreen = true
        settings.quietHours = true
        settings.muteRules = [MuteRule(field: .folder, text: "notes-site"), MuteRule(field: .prompt, text: "benchmark", agent: "codex")]
        try pane(.island, "W6-settings-island", settings: settings)
    }

    @Test func soundPane() throws {
        let settings = AppSettings.ephemeral()
        settings.soundVolume = 0.6
        settings.questionSound = .system("Submarine")
        try pane(.sound, "W6-settings-sound", settings: settings)
    }

    @Test func generalPane() throws {
        let settings = AppSettings.ephemeral()
        settings.followUpAfter = .twoMinutes
        settings.notificationBanners = true
        try pane(.general, "W6-settings-general", settings: settings)
    }

    @Test func detailedIslandAtLargeText() throws {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .detailed
        let env = AppEnvironment.demo(settings: settings, sessions: .details)
        let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: IslandUIState(), animated: false)
            .environment(\.islandSize, IslandSize(width: 580, text: 15))
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "W6-island-detailed-580-15", env: env)
    }

    @Test func planCardWithModesAtLargeText() throws {
        let env = AppEnvironment.demo(settings: .ephemeral(), sessions: .allStates)
        let view = OpenedIslandView(presentation: .card(sessionID: ID.plan), notch: Self.notch, ui: IslandUIState(), animated: false)
            .environment(\.islandSize, IslandSize(width: 640, text: 15))
        let scene = DScene.island(view, notch: Self.notch)
        // Cards hold AppKit text fields, which `ImageRenderer` leaves blank: draw them hosted, at the scene's own size.
        let probe = NSHostingView(rootView: scene.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(scene, "W6-card-plan-640-15", size: probe.fittingSize, env: env)
    }

    private func pane(_ pane: SettingsPane, _ name: String, settings: AppSettings) throws {
        let env = AppEnvironment.demo(settings: settings)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: pane), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.locale, Locale(identifier: "en_GB"))
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }
}
