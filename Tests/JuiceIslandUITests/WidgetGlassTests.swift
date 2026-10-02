import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Settings › Island › Glass look (P870 to P879), headless: the setting (Widget by default, stored, an unknown word read
/// as Widget), the roots that hand it on, the look and ink each Glass surface takes under it in either macOS mode (the
/// island on both outlines, the panel, its chip, the Settings preview), the glass's own face (its layers' filter), Frost
/// and State tint under it, the measured faces the stand-ins draw, and every other theme deaf to it.
@MainActor
@Suite(.serialized)
struct WidgetGlassTests {
    typealias C = GlassContrast

    // MARK: The setting

    @Test func theSettingIsWidgetByDefaultStoredAndMapped() throws {
        #expect(AppSettings.ephemeral().glassLook == .widget)
        #expect(GlassLookChoice.allCases == [.widget, .lightAndDark] && GlassLookChoice.allCases.map(\.title) == ["Widget", "Light and dark"])
        let suite = "glass-look-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppSettings(defaults: defaults).glassLook == .widget)
        let settings = AppSettings(defaults: defaults)
        settings.glassLook = .lightAndDark
        #expect(defaults.string(forKey: AppSettings.Key.glassLook) == "lightAndDark")
        #expect(AppSettings(defaults: defaults).glassLook == .lightAndDark)
        settings.glassLook = .widget
        #expect(defaults.string(forKey: AppSettings.Key.glassLook) == "widget" && AppSettings(defaults: defaults).glassLook == .widget)
        // A word this build does not know reads as Widget.
        defaults.set("frosted", forKey: AppSettings.Key.glassLook)
        #expect(AppSettings(defaults: defaults).glassLook == .widget)
        // Widget is dark in either macOS mode; Light and dark is the Appearance's.
        for appearance in [ColorScheme.light, .dark] {
            #expect(GlassLookChoice.widget.scheme(appearance: appearance) == .dark)
            #expect(GlassLookChoice.lightAndDark.scheme(appearance: appearance) == appearance)
        }
        // The row shows under Glass only.
        #expect(JuiceTheme.allCases.filter(IslandPaneText.showsGlassLookRow) == [.glass])
    }

    /// Nothing hands the look on unless asked: a view reads Light and dark (renders stay as they were, P637); a root with
    /// `juiceThemeFromSettings()` reads the setting.
    @Test func theRootsTakeTheGlassLook() throws {
        let box = GlassLookBox()
        _ = try RenderHarness.hostedBitmap(GlassLookProbe(box: box), "glass-look-probe", size: CGSize(width: 10, height: 10))
        #expect(box.look == .lightAndDark)
        let env = AppEnvironment.demo()
        #expect(env.settings.glassLook == .widget)
        _ = try RenderHarness.hostedBitmap(GlassLookProbe(box: box).juiceThemeFromSettings(), "glass-look-probe", size: CGSize(width: 10, height: 10),
                                           env: env)
        #expect(box.look == .widget)
        env.settings.glassLook = .lightAndDark
        _ = try RenderHarness.hostedBitmap(GlassLookProbe(box: box).juiceThemeFromSettings(), "glass-look-probe", size: CGSize(width: 10, height: 10),
                                           env: env)
        #expect(box.look == .lightAndDark)
    }

    // MARK: The glass and its ink

    /// Under Widget the content inside the glass reads the dark scheme in a window of either look, and the live glass is
    /// drawn in its dark face: its layers' `glassBackground` filter keeps a 0.6 luma ceiling and saturates 1.3, where the
    /// light face has none (1) and 1.2. Under Light and dark both are the window's, as before (P764).
    @Test(arguments: [ColorScheme.light, .dark])
    func widgetDrawsTheGlassDarkInEitherMode(_ system: ColorScheme) async throws {
        for look in GlassLookChoice.allCases {
            let box = SchemeBox()
            let stage = LookStage(root: AnyView(Color.clear.frame(width: 80, height: 40)
                .background(SchemeReader(box: box, key: "inside"))
                .inGlass(Rectangle(), style: GlassStyle.island.clear)
                .environment(\.glassLook, look)), size: CGSize(width: 80, height: 40))
            stage.system(system)
            await FramePerf.wait(0.15)
            let want = look.scheme(appearance: system)
            #expect(box.seen["inside"] == want, "\(look) under a \(system) Mac")
            let face = try #require(Self.glassFace(stage.host.layer), "\(look) under a \(system) Mac: no glass")
            #expect(abs(face.maxLuma - (want == .dark ? 0.6 : 1)) < 0.001, "\(look) under a \(system) Mac: \(face)")
            #expect(abs(face.saturation - (want == .dark ? 1.3 : 1.2)) < 0.001, "\(look) under a \(system) Mac: \(face)")
        }
    }

    /// Each Glass surface under Widget, in a light and a dark window: the island's content (SwiftUI's outline), the
    /// panel's (its surface), the chip's window and the Settings preview take the dark look; under Light and dark the
    /// window's. The chip's window keeps the look it was given at its show.
    @Test(arguments: [ColorScheme.light, .dark])
    func eachSurfaceTakesTheLook(_ system: ColorScheme) async {
        for look in GlassLookChoice.allCases {
            let box = SchemeBox(), ink = WidgetInkBox()
            let stage = LookStage(root: AnyView(VStack {
                Color.clear.background(SchemeReader(box: box, key: "island")).background(WidgetInkReader(box: ink, key: "island"))
                    .modifier(IslandGlassContent(ui: IslandUIState(), outside: false))
                Color.clear.frame(width: 20, height: 10).background(SchemeReader(box: box, key: "panel"))
                    .background(WidgetInkReader(box: ink, key: "panel")).modifier(PanelSurface(radius: 10))
                    .modifier(PanelInkScheme(theme: .glass))
                Color.clear.frame(width: 4, height: 4).background(WidgetInkReader(box: ink, key: "outside"))
            }.environment(\.juiceTheme, .glass).environment(\.glassLook, look)), size: CGSize(width: 60, height: 60))
            stage.system(system)
            await FramePerf.wait(0.15)
            let want = look.scheme(appearance: system)
            #expect(box.seen["island"] == want && box.seen["panel"] == want, "\(look) under a \(system) Mac: \(box.seen)")
            // Widget's ink inside its glass only (P879): never outside it, never under Light and dark.
            #expect(ink.seen["island"] == (look == .widget) && ink.seen["panel"] == (look == .widget) && ink.seen["outside"] == false,
                    "\(look) under a \(system) Mac: \(ink.seen)")
            #expect(ThemePreview.look(.glass, glass: look, settings: system) == want)
        }
        let chip = PanelHoverLabelWindow(above: .normal)
        chip.setText("Claude · 57%", theme: .glass, frost: 0.5, look: .widget)
        #expect(chip.theme == .glass && chip.frost == 0.5 && chip.look == .widget)
        chip.setText("Codex · 12%", theme: .glass)
        #expect(chip.look == .lightAndDark)
    }

    /// Core Animation's outline under Widget in a light window: the content's look (read inside the glass) is dark, and so
    /// are the rim and the edge line drawn outside it (`glassScheme`, P568).
    @Test func coreAnimationsOutlineTakesTheWidgetLook() async throws {
        _ = NSApplication.shared
        let rig = FramePerf.IslandRig(style: .clean, glyph: .pixel, glyphsMove: false, outline: .coreAnimation, theme: .glass, glassLook: .widget)
        await rig.start()
        for system in [ColorScheme.light, .dark, .light] {
            rig.window.appearance = NSAppearance.named(system)
            await FramePerf.wait(0.3)
            #expect(rig.ui.glassScheme == .dark, "under a \(system) Mac: \(String(describing: rig.ui.glassScheme))")
            let glass = try #require(rig.canvas.glassView)
            #expect(glass.effectiveAppearance.colorScheme == .dark)
            // The rim's full light is white, as the dark look's always was.
            let line = try #require((glass.rimLayer.colors?[1]).map { $0 as! CGColor }?.components)
            #expect(line[0] > 0.99, "\(line)")
        }
        rig.stop()
    }

    // MARK: Frost and State tint under Widget

    /// Widget's Frost is the dark ground, never the light one, from its floor (0.5) at 0 to 0.6 at 1, so the default
    /// (Frost 0) has it too (P873, P874); Light and dark's is as it was. At its floor it holds white text at 5:1 on the
    /// dark face over a white window (#B4B4B4 there), where the bare face gave 2.1:1.
    @Test func frostUnderWidgetIsTheDarkGround() {
        #expect(GlassFrost.widgetFloor == 0.5 && GlassFrost.widgetMaximum == 0.6)
        for frost in stride(from: 0.0, through: 1.0, by: 0.1) {
            for scheme in [ColorScheme.light, .dark] {
                let widget = C.components(GlassFrost.colour(frost, look: .widget), scheme)
                let ground = C.components(GlassFrost.dark)
                #expect(abs(widget.r - ground.r) < 0.002 && abs(widget.b - ground.b) < 0.002, "\(frost) \(scheme): \(widget)")
                let a = GlassFrost.widgetFloor + GlassFrost.stored(frost) * (GlassFrost.widgetMaximum - GlassFrost.widgetFloor)
                #expect(abs(widget.a - a) < 0.002 && abs(GlassFrost.widgetOpacity(frost) - a) < 0.0001)
                let before = C.components(GlassFrost.colour(frost), scheme), now = C.components(GlassFrost.colour(frost, look: .lightAndDark), scheme)
                #expect(before == now)
            }
        }
        // The bare face over white fails white text; the floor holds it, with room.
        let white = GlassFaceModel.dark.apply(1, 1, 1)
        #expect(abs(white.r - 0xB4 / 255.0) < 0.002)
        #expect(C.ratio(1, C.luminance(r: white.r, g: white.g, b: white.b)) < 2.2)
        let floor = C.widgetSurface(frost: 0)
        #expect(abs(floor.r - 0x6C / 255.0) < 1.5 / 255, "\(floor)")
        #expect(C.ratio(1, C.worstWidget()) >= 5, "\(C.ratio(1, C.worstWidget()))")
        // And never past the dark look's own ceiling toward white: the ink's far side.
        #expect(C.luminance(GlassFrost.dark) < C.worstAdapted(.dark))
        // The default a new Mac starts on is Widget at Frost 0: the floor.
        let settings = AppSettings.ephemeral()
        #expect(settings.glassLook == .widget && settings.glassFrost == 0)
    }

    // MARK: Widget's ink (P879)

    /// The brightest point of each sample wallpaper under the glass's dark face, as the renders draw it (blurred, then
    /// `GlassFaceModel.dark`), and white (a white window), in encoded sRGB.
    static func brightestUnderTheFace() throws -> [(String, (r: Double, g: Double, b: Double))] {
        var grounds: [(String, (r: Double, g: Double, b: Double))] = []
        grounds.append(("white window", C.darkFaceOverWhite))
        for wallpaper in GlassBackdrop.wallpapers {
            let stage = GlassStageInfo(backdrop: wallpaper, size: CGSize(width: 540, height: 330))
            let image = try #require(GlassFaceBackdrop.image(stage, style: GlassStyle.island.clear, face: .dark))
            let width = image.width, height = image.height
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
            var best = (r: 0.0, g: 0.0, b: 0.0), most = -1.0
            for i in stride(from: 0, to: width * height * 4, by: 4) {
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                let l = C.luminance(r: r, g: g, b: b)
                if l > most { most = l; best = (r, g, b) }
            }
            grounds.append((wallpaper.rawValue, best))
        }
        return grounds
    }

    /// Every Glass ink in its Widget twin holds over the glass's measured dark face (`GlassFaceModel.dark`): over a white
    /// window and over the brightest point of each sample wallpaper (the night photo, the purple to pink gradient, the
    /// near-white one), at Frost 0 (Widget's floor, the default) and at Frost 1, bare and on a hover or card veil: text
    /// 4.5:1 (4:1 on a veil), marks 3:1, as Glass's inks hold on the model of bounds (P522). The dark twins the grey inks
    /// had there (ink2 #B8B8BD) gave 1.4:1 to 3:1 over the gradient (P879).
    @Test func everyWidgetInkHoldsOnTheMeasuredFace() throws {
        let grounds = try Self.brightestUnderTheFace()
        var lines: [String] = []
        for (name, backdrop) in grounds {
            for frost in [0.0, 1.0] {
                let surface = C.widgetSurface(face: backdrop, frost: frost)
                let base = C.luminance(r: surface.r, g: surface.g, b: surface.b)
                let veiled = GlassVeil.judged.map { fill -> Double in
                    let c = C.over(fill, surface, .dark)
                    return C.luminance(r: c.r, g: c.g, b: c.b)
                }
                var lowest: [String: (name: String, ratio: Double)] = [:]
                func check(_ token: String, _ colour: Color, _ use: String, bare: Double, onFill: Double) {
                    let c = C.components(colour, .dark, widget: true)
                    let l = C.luminance(r: c.r, g: c.g, b: c.b)
                    let ratio = C.ratio(l, base)
                    #expect(ratio >= bare, "\(name) frost \(frost) \(token): \(ratio)")
                    for v in veiled { #expect(C.ratio(l, v) >= onFill, "\(name) frost \(frost) \(token) on a veil: \(C.ratio(l, v))") }
                    if ratio < lowest[use, default: ("", 99)].ratio { lowest[use] = (token, ratio) }
                }
                for (token, colour) in GlassThemeTests.text + GlassThemeTests.words { check(token, colour, "text", bare: C.text, onFill: C.textOnFill) }
                for (token, colour) in GlassThemeTests.marks { check(token, colour, "mark", bare: C.mark, onFill: C.mark) }
                let text = lowest["text", default: ("", 0)], mark = lowest["mark", default: ("", 0)]
                lines.append("\(name) frost \(frost): ground \(Self.hex(surface)), lowest text \(text.name) \(String(format: "%.2f", text.ratio)), "
                             + "mark \(mark.name) \(String(format: "%.2f", mark.ratio))")
            }
        }
        print("Widget ink over the measured face:\n" + lines.joined(separator: "\n"))
    }

    /// Widget's twins are lighter than the dark ones they come from, keep their hue, and leave the dark look alone: outside
    /// Widget's glass every token resolves to the twin it always had (P876).
    @Test func widgetTwinsAreLighterAndOnlyInsideWidget() {
        for (token, colour) in GlassThemeTests.text + GlassThemeTests.words + GlassThemeTests.marks {
            let dark = C.components(colour, .dark), widget = C.components(colour, .dark, widget: true)
            #expect(C.luminance(r: widget.r, g: widget.g, b: widget.b) >= C.luminance(r: dark.r, g: dark.g, b: dark.b) - 0.0001, "\(token)")
            let (h0, s0, _) = GlassTone.hsl(dark.r, dark.g, dark.b), (h1, s1, l1) = GlassTone.hsl(widget.r, widget.g, widget.b)
            if s0 > 0.1, l1 < 0.97 { #expect(abs(h0 - h1) < 0.02 || abs(abs(h0 - h1) - 1) < 0.02, "\(token): hue \(h0) to \(h1), \(s1)") }
            // On the light look the flag changes nothing.
            #expect(C.components(colour, .light, widget: true) == C.components(colour, .light), "\(token)")
        }
        // The primary ink is white on Widget's glass; the grey inks are near white, as the widgets' accented content is.
        #expect(C.components(IslandPalette.glass.ink, .dark, widget: true) == C.components(Color.white, .dark))
        #expect(C.components(PanelPalette.glass.ink, .dark, widget: true) == C.components(Color.white, .dark))
        #expect(C.components(PanelPalette.glass.ink2, .dark, widget: true).r > 0xE8 / 255.0)
    }

    /// A glyph's edge on Widget's glass is the shade that holds a mark's 3:1 there (or none where its colour does), so the
    /// teal of a delegating lead reads on the glass over a white window (P879).
    @Test func glyphEdgesHoldOnWidgetsGround() {
        let colours: [(String, Color)] = NeedsYouColourTests.colours + [
            ("run", IslandTheme.run), ("done", IslandTheme.done), ("delegate", IslandTheme.delegate), ("stalled", IslandTheme.stalled),
            ("agentClaude", IslandTheme.agentClaude), ("agentCodex", IslandTheme.agentCodex), ("idle", IslandTheme.idleMark),
        ]
        for (name, colour) in colours {
            let edge = GlassGlyph.edge(for: colour, look: .dark, widget: true) ?? colour
            #expect(C.ratio(C.luminance(edge, .dark), C.worstWidget()) >= C.mark, "\(name)")
            // Off Widget's glass the edge is the dark look's, as before.
            #expect(GlassGlyph.edge(for: colour, look: .dark, widget: false) == GlassGlyph.edge(for: colour, look: .dark), "\(name)")
            #expect(GlassGlyph.edge(for: colour, look: .light, widget: true) == GlassGlyph.edge(for: colour, look: .light), "\(name)")
        }
    }

    static func hex(_ c: (r: Double, g: Double, b: Double)) -> String {
        String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    /// State tint under Widget is each state's dark twin: its hue, darker than the dark look's ceiling, never the light
    /// look's pale one.
    @Test func stateTintUnderWidgetKeepsTheStatesColourDark() {
        for tint in StateTint.allCases {
            let veil = tint.veil(needsYou: .pink)
            let dark = C.components(veil, .dark), light = C.components(veil, .light)
            #expect(C.luminance(r: dark.r, g: dark.g, b: dark.b) <= StateTint.target(.dark) * 1.02, "\(tint)")
            #expect(C.luminance(r: dark.r, g: dark.g, b: dark.b) < C.luminance(r: light.r, g: light.g, b: light.b))
            let hue = GlassTone.hsl(dark.r, dark.g, dark.b).h, own = C.components(tint.colour(.pink))
            #expect(abs(hue - GlassTone.hsl(own.r, own.g, own.b).h) < 0.02, "\(tint)")
        }
    }

    // MARK: The measured faces

    /// The stand-ins' faces give back what Core Animation drew for the system's glass over flat colours on macOS 27 (the
    /// owner's lavender, a pink, a night sky), within two levels.
    @Test func theFacesGiveBackTheMeasurements() {
        let cases: [(GlassFaceModel, UInt32, UInt32)] = [
            (.dark, 0x8A8CC8, 0x8285C5), (.dark, 0xE58BC0, 0xD97BB2), (.dark, 0x1B2440, 0x2D385B), (.dark, 0xFFFFFF, 0xB4B4B4),
            (.dark, 0x000000, 0x141414), (.light, 0x8A8CC8, 0xB2B4F6), (.light, 0x1B2440, 0x7882A1), (.light, 0x000000, 0x6F6F6F),
        ]
        for (face, input, measured) in cases {
            let c = { (hex: UInt32, shift: UInt32) in Double((hex >> shift) & 0xFF) / 255 }
            let out = face.apply(c(input, 16), c(input, 8), c(input, 0))
            for (got, want) in [(out.r, c(measured, 16)), (out.g, c(measured, 8)), (out.b, c(measured, 0))] {
                #expect(abs(got - want) <= 2.5 / 255, "\(String(input, radix: 16)): \(out), measured \(String(measured, radix: 16))")
            }
        }
        // The dark face deepens a light colour and saturates it (its chroma against its brightness): the widgets' way.
        let lavender = GlassFaceModel.dark.apply(0x8A / 255.0, 0x8C / 255.0, 0xC8 / 255.0)
        #expect(C.luminance(r: lavender.r, g: lavender.g, b: lavender.b) < C.luminance(r: 0x8A / 255.0, g: 0x8C / 255.0, b: 0xC8 / 255.0))
        func saturation(_ r: Double, _ g: Double, _ b: Double) -> Double { (max(r, g, b) - min(r, g, b)) / max(r, g, b) }
        #expect(saturation(lavender.r, lavender.g, lavender.b) > saturation(0x8A / 255.0, 0x8C / 255.0, 0xC8 / 255.0) + 0.02)
    }

    // MARK: The other themes

    /// Black, Smoke and Solid never read the glass look: under Widget their island content and panel take the schemes
    /// they took (Black and Smoke dark, Solid the window's), and the Settings preview too.
    @Test func theOtherThemesAreDeafToIt() async {
        for theme in [JuiceTheme.black, .smoke, .solid] {
            for system in [ColorScheme.light, .dark] {
                let box = SchemeBox(), ink = WidgetInkBox()
                let stage = LookStage(root: AnyView(VStack {
                    Color.clear.background(SchemeReader(box: box, key: "island")).background(WidgetInkReader(box: ink, key: "island"))
                        .modifier(IslandGlassContent(ui: IslandUIState(), outside: false))
                    Color.clear.background(SchemeReader(box: box, key: "panel")).background(WidgetInkReader(box: ink, key: "panel"))
                        .modifier(PanelSurface(radius: 10)).modifier(PanelInkScheme(theme: theme))
                }.environment(\.juiceTheme, theme).environment(\.glassLook, .widget)), size: CGSize(width: 60, height: 60))
                stage.system(system)
                await FramePerf.wait(0.15)
                let want: ColorScheme = theme == .solid ? system : .dark
                #expect(box.seen["island"] == want && box.seen["panel"] == want, "\(theme) under a \(system) Mac: \(box.seen)")
                #expect(ink.seen["island"] == false && ink.seen["panel"] == false, "\(theme) under a \(system) Mac: \(ink.seen)")
                #expect(ThemePreview.look(theme, glass: .widget, settings: system) == ThemePreview.look(theme, settings: system))
            }
        }
    }

    // MARK: Helpers

    /// The face of the first glass in `layer`'s tree: its `glassBackground` filter's luma ceiling and saturation.
    static func glassFace(_ layer: CALayer?) -> (maxLuma: Double, saturation: Double)? {
        for layer in AppearanceTests.flatten(layer) where String(describing: type(of: layer)).contains("Backdrop") {
            for filter in layer.filters ?? [] {
                guard let filter = filter as? NSObject, String(describing: filter.value(forKey: "name") ?? "") == "glassBackground",
                      let keys = filter.value(forKey: "inputKeys") as? [String],
                      keys.contains("inputFaceColorMatrixMaxLuma"), keys.contains("inputFaceColorMatrixSaturation"),
                      let luma = filter.value(forKey: "inputFaceColorMatrixMaxLuma") as? NSNumber,
                      let saturation = filter.value(forKey: "inputFaceColorMatrixSaturation") as? NSNumber
                else { continue }
                return (luma.doubleValue, saturation.doubleValue)
            }
        }
        return nil
    }
}

@MainActor
final class WidgetInkBox {
    var seen: [String: Bool] = [:]
}

/// Records whether the ink it is drawn in is Widget's (`\.glassWidgetInk`).
private struct WidgetInkReader: View {
    let box: WidgetInkBox
    let key: String
    @Environment(\.glassWidgetInk) private var widget

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .onChange(of: widget, initial: true) { _, new in box.seen[key] = new }
    }
}

@MainActor
final class GlassLookBox {
    var look: GlassLookChoice?
}

/// Records the glass look it is drawn in.
private struct GlassLookProbe: View {
    let box: GlassLookBox
    @Environment(\.glassLook) private var look

    var body: some View {
        box.look = look
        return Color.clear
    }
}
