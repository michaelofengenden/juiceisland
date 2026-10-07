import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The accounts in use up front (P810 to P815), headless, over `InUseFixtures` (Work's session runs, Lab's finished, a
/// Codex chat in Team): the header strip, the usage block (Clean and Detailed), the desktop panel and the widget, on
/// Black, Glass in the light look and Solid in the light look. Files `iu-<look>-<scene>`; `-next` is Usage shows first
/// Next, the island as it was but for the dots.
@MainActor
@Suite(.serialized)
struct InUseRenders {
    struct Look: Sendable {
        var name: String
        var theme: JuiceTheme
        var scheme: ColorScheme
        var backdrop: GlassBackdrop
    }

    nonisolated static let looks: [Look] = [
        Look(name: "black", theme: .black, scheme: .dark, backdrop: .busy),
        Look(name: "glass-light", theme: .glass, scheme: .light, backdrop: .white),
        Look(name: "solid-light", theme: .solid, scheme: .light, backdrop: .white),
    ]

    static func environment(_ look: Look, _ configure: (AppSettings) -> Void = { _ in }) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .clean
        settings.islandUsagePlacement = .headerStrip
        settings.glyphStyle = .pixel
        settings.islandShowsMoney = true
        settings.juiceTheme = look.theme
        settings.appearance = look.scheme == .light ? .light : .dark
        configure(settings)
        return InUseFixtures.env(settings: settings)
    }

    /// The opened island as the live one shows it after an open: the accounts in use taken at the open.
    static func opened(_ env: AppEnvironment, hover: HoverTargetID? = nil) -> IslandUIState {
        let ui = IslandGlassRenders.state(env, surface: .island)
        ui.inUse = env.accountsInUseNow
        ui.hover = hover
        return ui
    }

    static func island(_ look: Look, _ name: String, env: AppEnvironment, ui: IslandUIState, size: CGSize) throws {
        let scene = AppearanceRenders.islandScene(ui, size: size, backdrop: look.backdrop, theme: look.theme, scheme: look.scheme)
        try RenderHarness.render(scene, "iu-\(look.name)-\(name)", env: env, scheme: look.scheme)
    }

    @Test
    func strip() throws {
        for look in Self.looks {
            for first in UsageFirst.allCases {
                let env = Self.environment(look) { $0.usageFirst = first }
                try Self.island(look, first == .inUse ? "strip" : "strip-next", env: env, ui: Self.opened(env), size: IslandGlassRenders.openSize)
            }
        }
    }

    @Test
    func block() throws {
        for look in Self.looks {
            for first in UsageFirst.allCases {
                let env = Self.environment(look) { $0.islandUsagePlacement = .section; $0.usageFirst = first }
                try Self.island(look, first == .inUse ? "block" : "block-next", env: env, ui: Self.opened(env),
                                size: CGSize(width: 540, height: 470))
            }
            let detailed = Self.environment(look) { $0.islandUsagePlacement = .section; $0.islandStyle = .detailed }
            try Self.island(look, "block-detailed", env: detailed, ui: Self.opened(detailed), size: CGSize(width: 540, height: 470))
            // The hover ring on the battery in use clears its dot.
            let hovered = Self.environment(look) { $0.islandUsagePlacement = .section }
            try Self.island(look, "block-hover", env: hovered, ui: Self.opened(hovered, hover: .account(InUseFixtures.workBattery)),
                            size: CGSize(width: 540, height: 470))
        }
    }

    @Test
    func panel() throws {
        for look in Self.looks {
            let env = Self.environment(look)
            // The panel's watch, as the panel's controller starts it.
            env.watchAccountsInUse(true)
            defer { env.watchAccountsInUse(false) }
            let size = CGSize(width: 410, height: 232)
            let staged = GlassStage(backdrop: look.backdrop, look: look.scheme) {
                DesktopPanelView().padding(PanelGeometry.margin).frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .frame(width: size.width, height: size.height)
            .environment(\.juiceTheme, look.theme)
            try RenderHarness.render(staged, "iu-\(look.name)-panel", size: size, env: env, scheme: look.scheme)
        }
    }

    /// Settings › Island › Usage: Shows first under Placement, while usage shows.
    @Test
    func settings() throws {
        let env = AppEnvironment.demo()
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .island), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "iu-settings-island", size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    @Test
    func widget() throws {
        for look in Self.looks {
            let env = Self.environment(look)
            let snapshot = WidgetSnapshot.make(env, at: WidgetRenders.now)
            for (face, size) in [(WidgetFace.large, WidgetRenders.Size.large), (.medium, WidgetRenders.Size.medium), (.small, WidgetRenders.Size.small)] {
                let margin = WidgetRenders.margin
                let shape = RoundedRectangle(cornerRadius: WidgetRenders.radius, style: .continuous)
                let scene = GlassStage(backdrop: look.backdrop, look: look.scheme) {
                    IslandWidgetView(snapshot: snapshot, face: face,
                                     size: CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin), date: WidgetRenders.now)
                        .padding(margin)
                        .frame(width: size.width, height: size.height)
                        .background { WidgetBackdrop(choice: .glass) }
                        .clipShape(shape)
                        .containerShape(shape)
                        .modifier(SessionsWidgetInk(fullColour: true))
                        .padding(24)
                }
                .frame(width: size.width + 48, height: size.height + 48)
                .environment(\.juiceTheme, look.theme)
                try RenderHarness.render(scene, "iu-\(look.name)-widget-\(face.rawValue)", scheme: look.scheme)
            }
        }
    }
}
