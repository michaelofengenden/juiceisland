import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The quiet lane's Settings (P420 to P426). `QL-settings-island-default`: the Island pane as it starts, Quiet while locked
/// on and Mute rules' one row, Add Rule. `QL-settings-island-mute-rules`: three rules (one just added, its hint showing)
/// and how many of the demo sessions they match. `QL-settings-sound-default`: Mute, Volume at 100 %, Needs you (Glass),
/// Question (Same as Needs you) and Done (None). `QL-settings-sound-custom`: 40 %, a Question sound of its own, a Done
/// sound, and Mute on (the rows dimmed).
@MainActor
@Suite(.serialized)
struct QuietLaneRenders {
    private func render(_ pane: SettingsPane, _ name: String, settings: AppSettings) throws {
        let env = AppEnvironment.demo(settings: settings)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: pane), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.locale, Locale(identifier: "en_GB"))
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    @Test func islandPaneAsItStarts() throws {
        try render(.island, "QL-settings-island-default", settings: .ephemeral())
    }

    @Test func islandPaneWithMuteRules() throws {
        let settings = AppSettings.ephemeral()
        settings.muteRules = [MuteRule(field: .folder, text: "notes-site"),
                              MuteRule(field: .title, text: "settings", agent: "codex"),
                              MuteRule(field: .prompt)]
        let env = AppEnvironment.demo(settings: settings)
        #expect(MuteRules.matchCount(env.sessions.rows, rules: settings.muteRules) > 0)
        try render(.island, "QL-settings-island-mute-rules", settings: settings)
    }

    @Test func soundPaneAsItStarts() throws {
        try render(.sound, "QL-settings-sound-default", settings: .ephemeral())
    }

    @Test func soundPaneWithItsOwnChoices() throws {
        let settings = AppSettings.ephemeral()
        settings.soundVolume = 0.4
        settings.questionSound = .system("Submarine")
        settings.doneSound = .system("Hero")
        try render(.sound, "QL-settings-sound-custom", settings: settings)
        settings.soundsMuted = true
        try render(.sound, "QL-settings-sound-muted", settings: settings)
    }
}
