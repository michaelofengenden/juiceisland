import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Lane c11/actions: the keys' row (P321) in the island (Clean and Detailed) and the window (a row and a card), and
/// Settings › Shortcuts with the system-wide key's Action (P323). A right-click menu draws only when it pops up on the
/// screen, so it has no render (its items are `SessionActionsTests`'). Nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct ActionsRenders {
    typealias ID = FixtureSessionFeed.ID

    @Test func islandCleanSelected() throws {
        try island("K-island-clean-selected", selected: ID.question)
    }

    @Test func islandDetailedSelected() throws {
        try island("K-island-detailed-selected", selected: ID.question) { $0.islandStyle = .detailed }
    }

    @Test func windowSelectedRow() throws {
        try window("K-window-selected-row", selected: ID.running)
    }

    @Test func windowSelectedCard() throws {
        try window("K-window-selected-card", selected: ID.question)
    }

    @Test func settingsShortcuts() throws {
        for action in GlobalKeyAction.allCases {
            let settings = AppSettings.ephemeral()
            settings.globalKeyAction = action
            settings.globalJumpKey = "ctrl+opt+j"
            settings.globalJumpEnabled = true
            let env = AppEnvironment.demo(settings: settings)
            let view = SettingsRootView(navigation: SettingsNavigation(pane: .shortcuts), drawsTrafficLights: true, scrolls: false)
            let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
            try RenderHarness.renderHosted(view, "K-settings-shortcuts-\(action.rawValue)",
                                           size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
        }
    }

    // MARK: Helpers

    private func island(_ name: String, selected: String, settings configure: (AppSettings) -> Void = { _ in }) throws {
        let settings = AppSettings.ephemeral()
        configure(settings)
        let env = AppEnvironment.demo(settings: settings, sessions: .prototype)
        let ui = IslandUIState()
        ui.selectedRow = selected
        let view = OpenedIslandView(presentation: .list, notch: IslandTheme.Metrics.referenceNotch, ui: ui, animated: false)
        try RenderHarness.render(DScene.island(view, notch: IslandTheme.Metrics.referenceNotch), name, env: env)
    }

    private func window(_ name: String, selected: String) throws {
        let env = AppEnvironment.demo(settings: .ephemeral(), sessions: .prototype)
        env.windowSelection = selected
        let view = SessionListView()
            .frame(width: 1200, height: 609)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, name, size: CGSize(width: 1216, height: 625), env: env)
    }
}
