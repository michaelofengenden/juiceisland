import AppKit
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Glass look (P870 to P879), headless: the closed pill (a delegating lead, State tint on, as the owner's), the opened
/// island on a card, and the desktop panel with its chip, over three sample wallpapers drawn in code (a night photo, a
/// purple to pink gradient, a near-white one), in a light macOS, every file named `wgl-*`:
/// - `before`: Light and dark, as the owner saw it (Frost at its most), the glass's light face as Core Animation draws it;
/// - `after`: Widget, Frost at its most; `after-frost0`: Widget, Frost at 0 (its floor, P874); the glass's dark face as
///   Core Animation draws it, Widget's ink (P879);
/// - `reference`: the same content as macOS draws a desktop widget over that wallpaper (a model fitted to the owner's
///   screenshot: lavender #8A8CC8 behind a widget comes out #6F6FC4), in Widget's ink, which is white or nearly as the
///   widgets' accented rendering tints its content white; no Frost of ours (`GlassStage.bare`), no tint. Its glyphs keep
///   their colours, where a widget's would be white too: a model of the widgets' glass, not of their content.
/// Offscreen there is no glass: each face is `GlassFaceModel`, the glass's own filter as Core Animation renders it over
/// flat colours, applied to the blurred wallpaper. The island is SwiftUI's outline, as every island render.
@MainActor
@Suite(.serialized)
struct WidgetGlassRenders {
    enum Variant: String, CaseIterable {
        case before, after, afterFrost0 = "after-frost0", reference

        var look: GlassLookChoice { self == .before ? .lightAndDark : .widget }
        var face: GlassFaceModel? {
            switch self {
            case .before: .light
            case .reference: WidgetGlassRenders.widgetModel
            default: nil
            }
        }
        var frost: Double { self == .before || self == .after ? 1 : 0 }
        var tint: Bool { self != .reference }
        var bare: Bool { self == .reference }
    }

    /// macOS's desktop widgets as the owner's screenshot shows them (lavender #8A8CC8 behind, #6F6FC4 under the widget):
    /// the glass's dark face a little deeper (0.865 of its greys) and more saturated (1.4). One point fitted; a model,
    /// not a measurement.
    nonisolated static let widgetModel = GlassFaceModel(tone: GlassFaceModel.dark.tone.map { $0 * 0.865 }, chromaAtBlack: 1.4, chromaAtWhite: 1.4)

    static let notch = IslandGlassRenders.notch

    /// The owner's island: Clean, the header strip, Pixel, a main turn waiting on its subagents leading the pill.
    static func islandStates() -> [(name: String, env: AppEnvironment, ui: IslandUIState, size: CGSize)] {
        let env = IslandGlassRenders.environment()
        let closed = IslandGlassRenders.state(env)
        let card = IslandGlassRenders.state(env, surface: .island, card: FixtureSessionFeed.ID.approval,
                                            events: [(0, .present(.card(sessionID: FixtureSessionFeed.ID.approval)))], at: 1.5)
        for ui in [closed, card] {
            ui.pill.lead = PillLead(glyph: .agents, agent: .claude, state: .delegating)
        }
        return [("pill", env, closed, IslandGlassRenders.pillSize), ("island", env, card, CGSize(width: 540, height: 330))]
    }

    static func islandScene(_ ui: IslandUIState, size: CGSize, wallpaper: GlassBackdrop, variant: Variant,
                            scheme: ColorScheme = .light) -> some View {
        let island = IslandSize.standard
        return GlassStage(backdrop: wallpaper, look: scheme, face: variant.face, bare: variant.bare) {
            ZStack(alignment: .top) {
                Rectangle().fill(Color.black.opacity(0.1)).frame(height: IslandGlassRenders.menuBar)
                IslandRootView(ui: ui, notch: notch, canvas: CGSize(width: island.canvasWidth, height: size.height), size: island,
                               actions: IslandViewActions(), pillClicked: {}, measured: { _ in })
                DScene.hardwareNotch(notch)
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.juiceTheme, .glass)
        .environment(\.glassLook, variant.look)
        .environment(\.glassFrost, variant.frost)
        .environment(\.islandStateTint, variant.tint)
    }

    static let panelSize = CGSize(width: 410, height: 232 + 52)

    static func panelScene(_ env: AppEnvironment, wallpaper: GlassBackdrop, variant: Variant, scheme: ColorScheme = .light) throws -> some View {
        let row = try #require(env.usage.claudeRow)
        let view = VStack(alignment: .trailing, spacing: 0) {
            PanelHoverLabelView(text: row.hoverLabel).fixedSize()
            DesktopPanelView().padding(PanelGeometry.margin)
        }
        return GlassStage(backdrop: wallpaper, look: scheme, face: variant.face, bare: variant.bare) {
            view.frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .environment(\.juiceTheme, .glass)
        .environment(\.glassLook, variant.look)
        .environment(\.glassFrost, variant.frost)
    }

    // MARK: Renders

    /// Every variant of the pill, the island on a card and the panel with its chip over each wallpaper:
    /// `wgl-<wallpaper>-<pill|island|panel>-<variant>`.
    @Test(arguments: GlassBackdrop.wallpapers)
    func eachSurfaceOverEachWallpaper(_ wallpaper: GlassBackdrop) throws {
        let panelEnv = AppEnvironment.demo()
        for variant in Variant.allCases {
            for state in Self.islandStates() {
                try RenderHarness.render(Self.islandScene(state.ui, size: state.size, wallpaper: wallpaper, variant: variant),
                                         "wgl-\(wallpaper.rawValue)-\(state.name)-\(variant.rawValue)", env: state.env, scheme: .light)
            }
            try RenderHarness.render(Self.panelScene(panelEnv, wallpaper: wallpaper, variant: variant),
                                     "wgl-\(wallpaper.rawValue)-panel-\(variant.rawValue)", size: Self.panelSize, env: panelEnv, scheme: .light)
        }
    }

    // MARK: Checks

    /// Under 1 % of `a`'s pixels apart from `b`'s. Two renders of one scene a moment apart differ where the glyphs take
    /// their frames from the clock and where the agent marks' edges follow whichever render first drew the shared image,
    /// the more so in a full run (P769): a few hundred pixels of a card. A look that leaked would change the whole glass.
    static func alike(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        let differ = stride(from: 0, to: a.count, by: 4).filter { a[$0 ..< $0 + 4] != b[$0 ..< $0 + 4] }.count
        return Double(differ) / Double(a.count / 4) < 0.01
    }

    /// Widget is the same in either macOS mode: the pill, the island and the panel under a dark Appearance draw the
    /// pixels they draw under a light one (`alike`; alone, the very same).
    @Test func widgetIsTheSameInEitherMode() throws {
        let panelEnv = AppEnvironment.demo()
        for state in Self.islandStates() {
            let light = try AppearanceRenders.bitmap(Self.islandScene(state.ui, size: state.size, wallpaper: .gradient, variant: .after),
                                                     size: state.size, env: state.env, scheme: .light)
            let dark = try AppearanceRenders.bitmap(Self.islandScene(state.ui, size: state.size, wallpaper: .gradient, variant: .after, scheme: .dark),
                                                    size: state.size, env: state.env, scheme: .dark)
            #expect(Self.alike(light, dark), "\(state.name)")
        }
        let light = try AppearanceRenders.bitmap(Self.panelScene(panelEnv, wallpaper: .gradient, variant: .after), size: Self.panelSize,
                                                 env: panelEnv, scheme: .light)
        let dark = try AppearanceRenders.bitmap(Self.panelScene(panelEnv, wallpaper: .gradient, variant: .after, scheme: .dark),
                                                size: Self.panelSize, env: panelEnv, scheme: .dark)
        #expect(Self.alike(light, dark), "panel")
    }

    /// Light and dark draws Glass as before (no glass look said, as every earlier render), and Black, Smoke and Solid draw
    /// the same under either look: the closed pill and an approval's card on each judged backdrop, in a light and a dark
    /// Appearance (`alike`; alone, the very same pixels).
    @Test func lightAndDarkAndTheOtherThemesAreUnchanged() throws {
        let states = IslandGlassRenders.states().filter { ["closed", "card-approval"].contains($0.name) }
        for state in states {
            for backdrop in GlassBackdrop.judged {
                for scheme in [ColorScheme.light, .dark] {
                    func bitmap(_ theme: JuiceTheme, _ look: GlassLookChoice?) throws -> [UInt8] {
                        let scene = AppearanceRenders.islandScene(state.ui, size: state.size, backdrop: backdrop, theme: theme, scheme: scheme)
                        if let look {
                            return try AppearanceRenders.bitmap(scene.environment(\.glassLook, look), size: state.size, env: state.env, scheme: scheme)
                        }
                        return try AppearanceRenders.bitmap(scene, size: state.size, env: state.env, scheme: scheme)
                    }
                    #expect(try Self.alike(bitmap(.glass, nil), bitmap(.glass, .lightAndDark)), "glass \(state.name) \(backdrop) \(scheme)")
                    for theme in [JuiceTheme.black, .smoke, .solid] {
                        #expect(try Self.alike(bitmap(theme, .lightAndDark), bitmap(theme, .widget)), "\(theme) \(state.name) \(backdrop) \(scheme)")
                    }
                }
            }
        }
    }
}
