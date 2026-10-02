import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Lane c14/keys: U's battery in the island's usage (P461), in Section and Header strip placement (U unfolds the strip's
/// block) and with Hover details off (the key's label shows all the same); a window past its reset, refilled until the
/// next read (P460), as U and the hover name it. The Shortcuts pane with Switch sessions (P462) is `ActionsRenders.settingsShortcuts`' third render.
/// Nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct KeysRenders {
    static let research = DemoUsageData.accounts[2].id
    static let night = DemoUsageData.accounts[8].id

    @Test func usageKeySection() throws {
        try island("L-keys-usage-section", key: DemoUsageData.accounts[3].id) { $0.islandUsagePlacement = .section }
    }

    @Test func usageKeyHoverDetailsOff() throws {
        try island("L-keys-usage-hover-off", key: Self.night, stripOpen: true) { $0.hoverDetails = false }
    }

    @Test func usageKeyStrip() throws {
        try island("L-keys-usage-strip", key: Self.night, stripOpen: true) { $0.islandUsagePlacement = .headerStrip }
    }

    @Test func usageKeyDetailed() throws {
        try island("L-keys-usage-detailed", key: DemoUsageData.accounts[0].id) {
            $0.islandStyle = .detailed
            $0.islandUsagePlacement = .section
        }
    }

    /// Research's 5-hour window reset after its last read: its battery is the week's 50 %, and the key's label says so.
    @Test func windowResetRefilled() throws {
        try island("L-keys-window-reset", key: Self.research, stripOpen: true, usage: .windowReset)
    }

    /// The same battery before its reset, for comparison: used up, back in 22 minutes.
    @Test func windowBeforeReset() throws {
        try island("L-keys-window-before-reset", key: Self.research, stripOpen: true)
    }

    // MARK: Helpers

    private func island(_ name: String, key: String, stripOpen: Bool = false, usage: DemoUsageModel.Variant = .standard,
                        settings configure: (AppSettings) -> Void = { _ in }) throws {
        let settings = AppSettings.ephemeral()
        configure(settings)
        let env = AppEnvironment.demo(settings: settings, sessions: .prototype, usage: usage)
        let ui = IslandUIState(stripOpen: stripOpen)
        ui.keyHover(.account(key))
        let view = OpenedIslandView(presentation: .list, notch: IslandTheme.Metrics.referenceNotch, ui: ui, animated: false)
        try RenderHarness.render(DScene.island(view, notch: IslandTheme.Metrics.referenceNotch), name, env: env)
    }
}
