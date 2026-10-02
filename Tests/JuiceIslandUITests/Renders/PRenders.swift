import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The desktop panel (Juice spec §2; Juice Island spec §4.3), headless: `renders/P-panel-*.png`. Each panel is drawn
/// inside its window's 24 pt shadow margin (410 × 232 pt for the full panel) over a plain wallpaper grey, so the 0.5 pt
/// edge and the shadow show. Nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct PRenders {
    static let wallpaper = Color(red: 0.36, green: 0.38, blue: 0.42)

    private func panel(_ name: String, env: AppEnvironment) throws {
        let content = DesktopPanelContent.make(usage: env.usage, settings: env.settings)
        let size = try #require(content.size)
        try RenderHarness.render(DesktopPanelView().padding(PanelGeometry.margin), name,
                                 size: PanelGeometry.windowSize(for: size), env: env, background: Self.wallpaper)
    }

    private func env(_ configure: (AppSettings) -> Void = { _ in }, usage: DemoUsageModel.Variant = .standard) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        configure(settings)
        return .demo(settings: settings, usage: usage)
    }

    /// Six Claude and five Codex batteries, the five sources (RunPod 52d).
    @Test func elevenAccounts() throws { try panel("P-panel-11", env: env()) }

    /// One Claude and one Codex account: the rows keep their places, the batteries stay left.
    @Test func twoAccounts() throws {
        let environment = env()
        let accounts = DemoUsageData.accounts
        environment.followUsageSource { _ in PanelFixtureUsage(accounts: [accounts[0], accounts[6]]) }
        try panel("P-panel-2", env: environment)
    }

    /// Every money source switched off in Settings › Money: no band, no rows, a shorter panel.
    @Test func noMoney() throws {
        try panel("P-panel-nomoney", env: env { settings in MoneyAccount.allCases.forEach { settings.moneyShown[$0] = false } })
    }

    /// RunPod's runway under 24 h: its amount and runway in red, the only red besides a key.
    @Test func runwayRed() throws { try panel("P-panel-runway", env: env(usage: .runway18h)) }

    /// RunPod's runway under 72 h: amber.
    @Test func runwayAmber() throws { try panel("P-panel-runway-60h", env: env(usage: .runway60h)) }

    /// A source that cannot be read: two open rails.
    @Test func unreadableSource() throws { try panel("P-panel-hetzner-nokey", env: env(usage: .hetznerNoKey)) }

    /// The sign-in key glyph, magnified, with the label its battery shows on hover.
    @Test func signInKey() throws {
        let environment = env()
        let battery = try #require(environment.usage.allBatteries.first { $0.state == .signInNeeded })
        let signingIn = BatteryModel(id: "signing", alias: "Edge", state: .signingIn, isNext: false, hoverLabel: "Edge · signing in…")
        let view = VStack(spacing: 28) {
            HStack(spacing: Theme.Battery.gap) {
                BatteryView(battery: battery, now: environment.usage.now)
                BatteryView(battery: signingIn, now: environment.usage.now)
            }
            .scaleEffect(4)
            .frame(width: 4 * (2 * Theme.Battery.cellWidth + Theme.Battery.gap), height: 4 * Theme.Battery.height)
            PanelHoverLabelView(text: battery.hoverLabel).fixedSize()
        }
        .padding(24)
        .frame(width: 440, height: 220)
        .background(Theme.surface)
        try RenderHarness.render(view, "P-panel-signin", size: CGSize(width: 440, height: 220), env: environment)
    }

    /// A hover label beside the panel, as the chip draws it (Juice §2.5).
    @Test func hoverChip() throws {
        let environment = env()
        let row = try #require(environment.usage.claudeRow)
        let view = VStack(alignment: .trailing, spacing: 0) {
            PanelHoverLabelView(text: row.hoverLabel).fixedSize()
            DesktopPanelView().padding(PanelGeometry.margin)
        }
        try RenderHarness.render(view, "P-panel-hover", size: CGSize(width: 410, height: 232 + 52), env: environment,
                                 background: Self.wallpaper)
    }

    /// Settings › Desktop Panel with the Corner row.
    @Test func settingsPane() throws {
        let environment = env()
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .desktopPanel), drawsTrafficLights: true, scrolls: false)
        try RenderHarness.renderHosted(view, "P-settings-panel", size: CGSize(width: SettingsTheme.Metrics.width, height: SettingsTheme.Metrics.minHeight),
                                       env: environment)
    }
}
