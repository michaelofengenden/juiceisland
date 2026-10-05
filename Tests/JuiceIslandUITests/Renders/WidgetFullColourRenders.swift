import AppKit
import IslandEngine
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Glass look Widget beside macOS's desktop widgets (P1204 to P1214), headless, every file `wfc-*`: the desktop panel as
/// the owner's screenshot of 2026-10-03 had it (the Claude and Codex rows, OpenRouter, OpenAI unread, RunPod) with its
/// hover chip, over three wallpapers drawn in code (the owner's lavender sunset, a pale one, a dark one), in a light and
/// a dark macOS:
/// - `before`: what the owner saw, Widget as it was (the dark face under Frost's dark ground, at Frost 0 its floor; the
///   OpenAI row's rails). The island's look still, over the apps.
/// - `after`: the panel now with the desktop in front: full colour, the dark face with nothing of ours in it, the white
///   ink's lift, the OpenAI row's word.
/// - `dimmed`: the panel now with an app in front: the same glass a tenth deeper, the same lift (P1214).
/// - `reference`: the same content through a model of the widgets' full-colour glass fitted to the screenshot
///   (`WidgetGlassRenders.fullColourModel`), with Widget's white ink and nothing of ours: what the Batteries widget beside
///   the panel looked like. Fitted over the lavender only: over the pale and the night wallpapers it extrapolates the
///   chosen glass, so it cannot disagree with it there (P1205).
/// - `reference-dimmed`: the same through the model of the dimmed widgets fitted to P872's one point
///   (`WidgetGlassRenders.widgetModel`).
/// And the island in Widget look as it ships (the closed pill and a card; the island keeps Widget as it was), to check
/// it still reads in either mode: `wfc-<wallpaper>-<mode>-pill`, `-island`.
@MainActor
@Suite(.serialized)
struct WidgetFullColourRenders {
    enum Variant: String, CaseIterable {
        case before, after, dimmed, reference, referenceDimmed = "reference-dimmed"

        /// Where the panel draws: Widget as it was, or on the desktop in one of the widgets' looks.
        var state: WidgetGlassState {
            switch self {
            case .after: .fullColour
            case .dimmed: .dimmed
            case .before, .reference, .referenceDimmed: .overApps
            }
        }

        /// The reference's model of the widgets' glass.
        var face: GlassFaceModel? {
            switch self {
            case .reference: WidgetGlassRenders.fullColourModel
            case .referenceDimmed: WidgetGlassRenders.widgetModel
            default: nil
            }
        }
    }

    static let schemes: [ColorScheme] = [.light, .dark]

    /// The owner's panel: the demo's battery rows and the screenshot's three money rows.
    static func ownerContent(word: Bool) -> (DesktopPanelContent, CGSize) {
        let usage = DemoUsageModel()
        let rows = usage.panel.rows.filter { !$0.batteries.isEmpty }
        let money = [
            MoneyRowModel(id: "OpenRouter", name: "OpenRouter", amount: "$7,595", hoverLabel: "OpenRouter · $7,595 balance"),
            MoneyRowModel(id: "OpenAI", name: "OpenAI", amount: nil, hoverLabel: "OpenAI · not available with this key",
                          word: word ? MoneyReadError.notAvailableWithThisKey.rowWord : nil),
            MoneyRowModel(id: "RunPod", name: "RunPod", amount: "$0.00", hoverLabel: "RunPod · $0.00 balance"),
        ]
        let size = PanelGeometry.panelSize(providerRows: rows.count, showsMoney: true, moneyCount: money.count) ?? .zero
        return (DesktopPanelContent(rows: rows, money: money, now: usage.now, size: size), size)
    }

    static let panelSize = CGSize(width: 410, height: 232 + 52)

    static func panelScene(wallpaper: GlassBackdrop, variant: Variant, scheme: ColorScheme) -> some View {
        let (content, size) = ownerContent(word: variant != .before)
        let view = VStack(alignment: .trailing, spacing: 0) {
            PanelHoverLabelView(text: "Claude · 3 of 6 ready · next Main").fixedSize()
            DesktopPanelBody(content: content, size: size).padding(PanelGeometry.margin)
        }
        return GlassStage(backdrop: wallpaper, look: scheme, face: variant.face, bare: variant.face != nil) {
            view.frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .environment(\.juiceTheme, .glass)
        .environment(\.glassLook, .widget)
        .environment(\.glassFrost, 0)
        .environment(\.widgetGlassState, variant.state)
    }

    /// `wfc-<wallpaper>-<light|dark>-panel-<variant>` and the island's two.
    @Test(arguments: GlassBackdrop.widgetWallpapers)
    func eachWallpaper(_ wallpaper: GlassBackdrop) throws {
        let env = AppEnvironment.demo()
        for scheme in Self.schemes {
            let mode = scheme == .dark ? "dark" : "light"
            for variant in Variant.allCases {
                try RenderHarness.render(Self.panelScene(wallpaper: wallpaper, variant: variant, scheme: scheme),
                                         "wfc-\(wallpaper.rawValue)-\(mode)-panel-\(variant.rawValue)", size: Self.panelSize, env: env, scheme: scheme)
            }
            for state in WidgetGlassRenders.islandStates() {
                try RenderHarness.render(WidgetGlassRenders.islandScene(state.ui, size: state.size, wallpaper: wallpaper, variant: .afterFrost0,
                                                                        scheme: scheme),
                                         "wfc-\(wallpaper.rawValue)-\(mode)-\(state.name)", env: state.env, scheme: scheme)
            }
        }
    }

    /// Full colour is the same in either macOS mode, as Widget is (P870): the system's dark face and white ink whatever
    /// the Appearance.
    @Test func fullColourIsTheSameInEitherMode() throws {
        let env = AppEnvironment.demo()
        let light = try AppearanceRenders.bitmap(Self.panelScene(wallpaper: .sunset, variant: .after, scheme: .light), size: Self.panelSize,
                                                 env: env, scheme: .light)
        let dark = try AppearanceRenders.bitmap(Self.panelScene(wallpaper: .sunset, variant: .after, scheme: .dark), size: Self.panelSize,
                                                env: env, scheme: .dark)
        #expect(WidgetGlassRenders.alike(light, dark))
    }

    /// The panel's glass under `variant` over `wallpaper`, as one colour: the mean of its top padding, where there is
    /// no ink (the panel starts 52 + 24 pt down and 24 pt in; its top 16 pt are glass alone, away from the corners).
    static func glass(_ variant: Variant, over wallpaper: GlassBackdrop) throws -> UInt32 {
        let data = try AppearanceRenders.bitmap(panelScene(wallpaper: wallpaper, variant: variant, scheme: .light),
                                                size: panelSize, env: .demo(), scheme: .light)
        let w = Int(panelSize.width * 2)
        var sum = (0.0, 0.0, 0.0)
        var n = 0.0
        for y in (2 * 52 + 2 * 24 + 6)..<(2 * 52 + 2 * 24 + 26) {
            for x in (2 * 24 + 300)..<(2 * 24 + 400) {
                let i = (y * w + x) * 4
                sum.0 += Double(data[i]); sum.1 += Double(data[i + 1]); sum.2 += Double(data[i + 2]); n += 1
            }
        }
        return WidgetFullColourTests.hex((sum.0 / n / 255, sum.1 / n / 255, sum.2 / n / 255))
    }

    /// Over the owner's sunset, the panel's glass in full colour comes within a few levels of the reference's, where
    /// Widget as it was (`before`) sat far below it.
    @Test func fullColourComesToTheWidgetsGlass() throws {
        let after = try Self.glass(.after, over: .sunset), reference = try Self.glass(.reference, over: .sunset)
        let before = try Self.glass(.before, over: .sunset)
        let near = WidgetFullColourTests.deltaE(after, reference), far = WidgetFullColourTests.deltaE(before, reference)
        #expect(near < 6 && far > 20, "after \(String(after, radix: 16)) reference \(String(reference, radix: 16)) before \(String(before, radix: 16)): \(near), \(far)")
    }

    /// With an app in front, over the lavender where P872 measured the dimmed widgets (the gradient), the panel keeps the
    /// wallpaper's colour, a step deeper than full colour: about as far from the dimmed widgets' model as the dark face
    /// alone is, where Widget as it was sat twice as far, grey (P1214).
    @Test func dimmedKeepsTheWallpapersColourAndDimsWithTheWidgets() throws {
        let dimmed = try Self.glass(.dimmed, over: .gradient), reference = try Self.glass(.referenceDimmed, over: .gradient)
        let before = try Self.glass(.before, over: .gradient), full = try Self.glass(.after, over: .gradient)
        let near = WidgetFullColourTests.deltaE(dimmed, reference), far = WidgetFullColourTests.deltaE(before, reference)
        let luma = { (c: UInt32) in 0.2126 * Double(c >> 16 & 0xFF) + 0.7152 * Double(c >> 8 & 0xFF) + 0.0722 * Double(c & 0xFF) }
        #expect(near < 18 && far > 28, "dimmed \(String(dimmed, radix: 16)) reference \(String(reference, radix: 16)) before \(String(before, radix: 16)): \(near), \(far)")
        #expect(luma(full) > luma(dimmed) + 4 && luma(dimmed) > luma(before) + 20, "\(luma(full)) \(luma(dimmed)) \(luma(before))")
    }
}
