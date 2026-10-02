import AppKit
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Settings › General › Appearance and Theme Solid, headless (P760 to P779): Settings, the window, the island closed and
/// opened with a card, the desktop panel and its chip, on Glass and on Solid in Light and in Dark, and Settings in Light
/// on Black, every file named `ap-*`. Offscreen there is no glass and no wallpaper: Glass is the stand-in in the look
/// asked for (`GlassStage.look`), and Solid the window material's untinted ground of that look (its wallpaper tint is
/// the window server's, live only). The island is SwiftUI's outline, as every island render.
@MainActor
@Suite(.serialized)
struct AppearanceRenders {
    nonisolated static let themes: [JuiceTheme] = [.glass, .solid]
    nonisolated static let schemes: [ColorScheme] = [.light, .dark]

    static func word(_ scheme: ColorScheme) -> String { scheme == .light ? "light" : "dark" }

    // MARK: Settings

    static func settings(_ pane: SettingsPane, theme: JuiceTheme, scheme: ColorScheme) throws {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = theme
        settings.appearance = scheme == .light ? .light : .dark
        let env = AppEnvironment.demo(settings: settings)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: pane), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "ap-settings-\(pane.rawValue)-\(theme.rawValue)-\(word(scheme))",
                                       size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env, scheme: scheme)
    }

    /// Settings in Light on Black, every pane: the General pane holds the Appearance row; the Island pane's previews show
    /// Black's island, dark as it stays.
    @Test func settingsLightOnBlack() throws {
        for pane in SettingsPane.allCases { try Self.settings(pane, theme: .black, scheme: .light) }
    }

    /// The Island pane on Glass and Solid in both looks (the preview in the look the island takes), and General on Solid.
    @Test(arguments: themes, schemes)
    func settingsOnAdaptingThemes(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        try Self.settings(.island, theme: theme, scheme: scheme)
        if theme == .solid { try Self.settings(.general, theme: theme, scheme: scheme) }
    }

    // MARK: The window

    @Test(arguments: themes, schemes)
    func window(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = theme
        let env = ARenders.withBadge(AppEnvironment.demo(settings: settings, sessions: .prototype))
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), "ap-window-\(theme.rawValue)-\(Self.word(scheme))",
                                       size: CGSize(width: 1000, height: 640), env: env, scheme: scheme)
    }

    // MARK: The island

    /// The island on `backdrop` in `theme` and `scheme` (the Appearance's): `IslandGlassRenders.scene` with the stage's
    /// look and the scheme said.
    static func islandScene(_ ui: IslandUIState, notch: CGSize? = IslandGlassRenders.notch, size: CGSize, backdrop: GlassBackdrop,
                            theme: JuiceTheme, scheme: ColorScheme) -> some View {
        let menuBar: CGFloat = notch == nil ? IslandTheme.Metrics.topBarFallbackHeight : IslandGlassRenders.menuBar
        let island = IslandSize.standard
        return GlassStage(backdrop: backdrop, look: scheme) {
            ZStack(alignment: .top) {
                Rectangle().fill(Color.black.opacity(0.1)).frame(height: menuBar)
                IslandRootView(ui: ui, notch: notch, canvas: CGSize(width: island.canvasWidth, height: size.height), size: island,
                               actions: IslandViewActions(), pillClicked: {}, measured: { _ in })
                if let notch { DScene.hardwareNotch(notch) }
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.juiceTheme, theme)
        .environment(\.islandStateTint, true)
    }

    @Test(arguments: themes, schemes)
    func island(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        let picked = ["closed", "closed-liquid", "open", "card-approval", "card-done"]
        for state in IslandGlassRenders.states() where picked.contains(state.name) {
            for backdrop in [GlassBackdrop.white, .busy] {
                try RenderHarness.render(Self.islandScene(state.ui, size: state.size, backdrop: backdrop, theme: theme, scheme: scheme),
                                         "ap-island-\(theme.rawValue)-\(Self.word(scheme))-\(state.name)-\(backdrop.rawValue)",
                                         env: state.env, scheme: scheme)
            }
        }
        let bar = IslandGlassRenders.topBar()
        try RenderHarness.render(Self.islandScene(bar.closed, notch: nil, size: CGSize(width: 360, height: 50), backdrop: .white,
                                                  theme: theme, scheme: scheme),
                                 "ap-island-\(theme.rawValue)-\(Self.word(scheme))-topbar-closed-white", env: bar.env, scheme: scheme)
    }

    // MARK: The desktop panel and its chip

    @Test(arguments: themes, schemes)
    func panelAndChip(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        let env = AppEnvironment.demo()
        let row = try #require(env.usage.claudeRow)
        let size = CGSize(width: 410, height: 232 + 52)
        for backdrop in [GlassBackdrop.white, .busy] {
            let view = VStack(alignment: .trailing, spacing: 0) {
                PanelHoverLabelView(text: row.hoverLabel).fixedSize()
                DesktopPanelView().padding(PanelGeometry.margin)
            }
            let staged = GlassStage(backdrop: backdrop, look: scheme) {
                view.frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .frame(width: size.width, height: size.height)
            .environment(\.juiceTheme, theme)
            try RenderHarness.render(staged, "ap-panel-\(theme.rawValue)-\(Self.word(scheme))-\(backdrop.rawValue)", size: size, env: env,
                                     scheme: scheme)
        }
    }

    // MARK: Black and Smoke under a light Appearance

    /// Black's and Smoke's island drawn under a light Appearance: still dark (P760), the same pixels as under a dark one
    /// but for the glyphs' frames, which a render takes from the clock (two renders a moment apart differ in the glyph's
    /// cells, the more so on a busy machine: under 1 % of the closed pill's scene seen). Fewer than 5 % of the pixels may
    /// differ, by any amount; an island that took the light look would change its whole surface, far more than that.
    @Test(arguments: [JuiceTheme.black, .smoke])
    func darkThemesStayDark(_ theme: JuiceTheme) throws {
        let states = IslandGlassRenders.states()
        for state in states where ["closed", "open", "card-approval"].contains(state.name) {
            let light = try Self.bitmap(Self.islandScene(state.ui, size: state.size, backdrop: .white, theme: theme, scheme: .light)
                .environment(\.islandStateTint, false), size: state.size, env: state.env, scheme: .light)
            let dark = try Self.bitmap(Self.islandScene(state.ui, size: state.size, backdrop: .white, theme: theme, scheme: .dark)
                .environment(\.islandStateTint, false), size: state.size, env: state.env, scheme: .dark)
            #expect(light.count == dark.count)
            let differ = stride(from: 0, to: min(light.count, dark.count), by: 4).filter { light[$0 ..< $0 + 4] != dark[$0 ..< $0 + 4] }.count
            #expect(Double(differ) / Double(max(1, light.count / 4)) < 0.05, "\(theme) \(state.name): \(differ) of \(light.count / 4) pixels differ")
        }
    }

    /// `view`'s pixels at 2x, RGBA, row by row.
    static func bitmap<V: View>(_ view: V, size: CGSize, env: AppEnvironment, scheme: ColorScheme) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(env)
            .environment(\.colorScheme, scheme).environment(\.glassRendering, .standIn))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}
