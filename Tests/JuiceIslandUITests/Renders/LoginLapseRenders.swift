import AppKit
import IslandEngine
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// P1550 to P1553 on the surfaces, over `LoginLapseLiveTests.rig` (a temporary home: `~/.codex` and `~/.codex-side` over
/// 9 days old and refused twice, so lapsed; `~/.codex-fresh` refused as a rate limit on a fresh login; a Claude folder
/// read well beside them): the island's usage block with the lapsed battery's caption, the window's header caption, the
/// desktop panel, the widget and the account list, on Black and Glass in Light and Dark, and Settings › Accounts in both
/// looks; then the early word on a login over 8 days old whose reads work. Files `lapse-*`. Headless; nothing is shown
/// and nothing opens.
@MainActor
@Suite(.serialized)
struct LoginLapseRenders {
    struct Look: Sendable {
        var name: String
        var theme: JuiceTheme
        var scheme: ColorScheme
        var backdrop: GlassBackdrop
    }

    nonisolated static let looks: [Look] = [
        Look(name: "black-dark", theme: .black, scheme: .dark, backdrop: .busy),
        Look(name: "black-light", theme: .black, scheme: .light, backdrop: .white),
        Look(name: "glass-dark", theme: .glass, scheme: .dark, backdrop: .busy),
        Look(name: "glass-light", theme: .glass, scheme: .light, backdrop: .white),
    ]

    static func environment(_ model: LiveUsageModel, _ look: Look, _ configure: (AppSettings) -> Void = { _ in }) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.usageSource = .juiceReadings
        settings.islandStyle = .clean
        settings.islandUsagePlacement = .section
        settings.windowHeader = .section
        settings.glyphStyle = .pixel
        settings.juiceTheme = look.theme
        settings.appearance = look.scheme == .light ? .light : .dark
        configure(settings)
        return AppEnvironment(settings: settings, usage: model, sessions: FixtureSessionFeed(scenario: .prototype, now: DemoClock.now).makeModel())
    }

    static func rig(_ fakes: LiveFakes, failing: Bool = true, freshDays: Double = 1) async throws -> LoginLapseLiveTests.Rig {
        try await LoginLapseLiveTests.rig(fakes, withClaude: true, failing: failing, freshDays: freshDays)
    }

    /// The island opened on its list with the usage block, the pointer on `hover` (its short caption across the notch).
    func island(_ look: Look, _ name: String, env: AppEnvironment, hover: HoverTargetID?) throws {
        let ui = IslandGlassRenders.state(env, surface: .island)
        ui.hover = hover
        let scene = AppearanceRenders.islandScene(ui, size: CGSize(width: 540, height: 420), backdrop: look.backdrop, theme: look.theme,
                                                  scheme: look.scheme)
        try RenderHarness.render(scene, "lapse-\(look.name)-\(name)", env: env, scheme: look.scheme)
    }

    /// The window's header with the pointer on `hover` (its full caption).
    func header(_ look: Look, _ name: String, env: AppEnvironment, hover: HoverTargetID?) throws {
        let width: CGFloat = 900
        let view = WindowHeaderView(drawsTrafficLights: true, hover: hover, allowsTitleLine: false)
            .overlay(alignment: .bottom) { WindowTheme.hairline.frame(height: 1) }
            .frame(width: width)
            .padding(8)
            .background(look.scheme == .dark ? Color.black : Color.white)
            .environment(\.juiceTheme, look.theme)
        let height = ceil(NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true).environment(env)
            .environment(\.colorScheme, look.scheme)).fittingSize.height)
        try RenderHarness.renderHosted(view, "lapse-\(look.name)-\(name)", size: CGSize(width: width + 16, height: height), env: env,
                                       scheme: look.scheme)
    }

    @Test func lapsedBatteryCaptionsAndIslandBlock() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let rig = try await Self.rig(fakes)
        defer { rig.model.stop() }
        let lapsed = try #require(rig.battery(rig.side))
        #expect(lapsed.state == .loginLapsed && rig.battery(rig.codex)?.state == .loginLapsed)
        for look in Self.looks {
            let env = Self.environment(rig.model, look)
            try island(look, "island-block", env: env, hover: nil)
            try island(look, "island-block-hover", env: env, hover: .account(lapsed.id))
            try header(look, "window-hover", env: env, hover: .account(lapsed.id))
            // The desktop panel and the widget: the dashed outline and its turning arrow.
            let content = DesktopPanelContent.make(usage: env.usage, settings: env.settings)
            let size = try #require(content.size)
            let window = PanelGeometry.windowSize(for: size)
            let panel = GlassStage(backdrop: look.backdrop, look: look.scheme) {
                DesktopPanelView().padding(PanelGeometry.margin).frame(width: window.width, height: window.height, alignment: .topLeading)
            }
            .frame(width: window.width, height: window.height)
            .environment(\.juiceTheme, look.theme)
            try RenderHarness.render(panel, "lapse-\(look.name)-panel", size: window, env: env, scheme: look.scheme)
            let snapshot = WidgetSnapshot.make(env, at: WidgetRenders.now)
            let face = WidgetFace.medium, widgetSize = WidgetRenders.Size.medium, margin = WidgetRenders.margin
            let shape = RoundedRectangle(cornerRadius: WidgetRenders.radius, style: .continuous)
            let widget = GlassStage(backdrop: look.backdrop, look: look.scheme) {
                IslandWidgetView(snapshot: snapshot, face: face,
                                 size: CGSize(width: widgetSize.width - 2 * margin, height: widgetSize.height - 2 * margin), date: WidgetRenders.now)
                    .padding(margin)
                    .frame(width: widgetSize.width, height: widgetSize.height)
                    .background { WidgetBackdrop(choice: .glass) }
                    .clipShape(shape)
                    .containerShape(shape)
                    .modifier(SessionsWidgetInk(fullColour: true))
                    .padding(24)
            }
            .frame(width: widgetSize.width + 48, height: widgetSize.height + 48)
            .environment(\.juiceTheme, look.theme)
            try RenderHarness.render(widget, "lapse-\(look.name)-widget-medium", scheme: look.scheme)
        }
    }

    /// The account list a battery opens (Refresh login and the hint), and Settings › Accounts (the row's line, Refresh
    /// login, the hint) and Diagnostics, in both looks.
    @Test func accountListAndSettingsRows() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let rig = try await Self.rig(fakes)
        defer { rig.model.stop() }
        let lapsed = try #require(rig.battery(rig.side))
        for look in Self.looks where look.theme == .black {
            let env = Self.environment(rig.model, look)
            try RenderHarness.render(VStack(spacing: 12) { AccountListView(provider: .codex, selected: lapsed.id) }.padding(12),
                                     "lapse-\(look.name)-account-list", env: env,
                                     background: look.scheme == .dark ? Color(hex: 0x1A2420) : Color(hex: 0xE8ECEA), scheme: look.scheme)
            for pane in [SettingsPane.accounts, .diagnostics] {
                let view = SettingsRootView(navigation: SettingsNavigation(pane: pane), drawsTrafficLights: true, scrolls: false)
                    .environment(\.sessionGlyphsAnimated, false)
                let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
                try RenderHarness.renderHosted(view, "lapse-\(look.scheme == .dark ? "dark" : "light")-settings-\(pane.rawValue)",
                                               size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env, scheme: look.scheme)
            }
        }
        // Glass's batteries in the row, the look's own.
        let glass = Self.environment(rig.model, Self.looks[3])
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .accounts), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: glass))
        try RenderHarness.renderHosted(view, "lapse-light-settings-accounts-glass", size: CGSize(width: SettingsTheme.Metrics.width, height: height),
                                       env: glass, scheme: .light)
    }

    /// P1553: logins over 8 days old whose reads work end their caption with the early word; nothing else changes.
    @Test func agingCaption() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let rig = try await Self.rig(fakes, failing: false, freshDays: 8.5)
        defer { rig.model.stop() }
        let aging = try #require(rig.battery(rig.fresh))
        #expect(aging.loginAging && aging.state.isAvailable)
        #expect(aging.hoverLabel.hasSuffix(" · " + Rules.loginAgingWords))
        for look in [Self.looks[0], Self.looks[3]] {
            let env = Self.environment(rig.model, look)
            try header(look, "window-hover-aging", env: env, hover: .account(aging.id))
            try island(look, "island-block-hover-aging", env: env, hover: .account(aging.id))
        }
    }
}
