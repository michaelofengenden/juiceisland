import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Session glyphs on Glass (P590 to P593): at their state's or agent's colour at full strength, their contrast carried
/// by an edge in the colour's own shade for the glass's look, the Liquid and Sand lights kept short of washing the colour
/// out (the done check green, not pale), a bloom for the glow; nothing of the glass over them; Black and Smoke as they
/// were.
@MainActor
@Suite(.serialized)
struct GlassGlyphTests {
    typealias C = GlassContrast

    /// Every colour a session glyph is drawn in, by name.
    static let colours: [(String, Color)] = NeedsYouColour.allCases.map { ("wait \($0)", $0.wait) } + [
        ("run", IslandTheme.run), ("done", IslandTheme.done), ("delegate", IslandTheme.delegate),
        ("Claude", IslandTheme.agentClaude), ("Claude running", IslandTheme.agentClaudeRunning), ("Codex", IslandTheme.agentCodex),
        ("idle", IslandPalette.glass.idleMark),
    ]

    static func hex(_ colour: Color, _ look: ColorScheme) -> String {
        let c = C.components(colour, look)
        return String(format: "#%02X%02X%02X", Int(c.r * 255 + 0.5), Int(c.g * 255 + 0.5), Int(c.b * 255 + 0.5))
    }

    // MARK: The colour (P590)

    /// A glyph's colour is the state's or the agent's own in every theme, so Glass draws it at full strength; a mark that
    /// is not a glyph (a row's dot) keeps its twin on Glass; Black and Smoke draw both as they always did.
    @Test(arguments: NeedsYouColour.allCases)
    func aGlyphsColourIsTheStatesOwnInEveryTheme(_ needsYou: NeedsYouColour) {
        let cases: [(GlyphPalette.Agent, GlyphPalette.State, GlyphColourMode, Color)] = [
            (.claude, .running, .byState, IslandTheme.run), (.codex, .delegating, .byState, IslandTheme.delegate),
            (.claude, .waiting, .byState, needsYou.wait), (.codex, .done, .byState, IslandTheme.done),
            (.claude, .running, .byAgent, IslandTheme.agentClaudeRunning), (.codex, .running, .byAgent, IslandTheme.agentCodex),
            (.claude, .delegating, .byAgent, IslandTheme.agentClaudeRunning), (.codex, .waiting, .byAgent, needsYou.wait),
        ]
        for (agent, state, mode, want) in cases {
            #expect(GlyphPalette.glyph(agent: agent, state: state, mode: mode, needsYou: needsYou) == want, "\(agent) \(state) \(mode)")
            for palette in [IslandPalette.black, .smoke] {
                #expect(GlyphPalette.colour(agent: agent, state: state, mode: mode, needsYou: needsYou, palette: palette) == want)
            }
            #expect(GlyphPalette.colour(agent: agent, state: state, mode: mode, needsYou: needsYou, palette: .glass)
                == IslandPalette.glass.tone(want))
        }
        #expect(GlyphPalette.glyph(agent: .claude, state: .idle, mode: .byState, needsYou: needsYou, idle: IslandPalette.glass.idleMark)
            == IslandPalette.glass.idleMark)
        #expect(GlyphFinish(.glass) == .glass && GlyphFinish(.black) == .plain && GlyphFinish(.smoke) == .plain)
    }

    // MARK: The edge (P591)

    /// On each look's worst surface, bare and under a hover or card veil, every glyph colour holds a mark's 3:1 by itself
    /// or its edge does; an edge is drawn only where the colour needs one, keeps the colour's hue, and is darker than it
    /// on the light look and lighter on the dark. No colour is shifted. The table is printed for the report.
    @Test func everyGlyphHoldsByItselfOrByItsEdge() {
        var lines: [String] = []
        for (name, colour) in Self.colours {
            var line = "\(name) \(Self.hex(colour, .light))"
            for look in [ColorScheme.light, .dark] {
                let own = C.luminance(colour, look)
                let edge = GlassGlyph.edge(for: colour, look: look)
                if GlassTone.holds(own, look, .mark) {
                    #expect(edge == nil, "\(name) \(look): holds, yet edged")
                } else {
                    let e = try? #require(edge, "\(name) \(look): fails and has no edge")
                    guard let e else { continue }
                    let l = C.luminance(e, look)
                    #expect(C.ratio(l, C.worstAdapted(look)) >= C.mark, "\(name) \(look): edge \(C.ratio(l, C.worstAdapted(look)))")
                    for fill in GlassVeil.judged {
                        #expect(C.ratio(l, C.worstAdapted(look, fills: [fill])) >= C.mark, "\(name) \(look): edge on a veil")
                    }
                    #expect(look == .light ? l < own : l > own, "\(name) \(look): the edge's side")
                    let a = C.components(colour, look), b = C.components(e, look)
                    let (h1, _, _) = GlassTone.hsl(a.r, a.g, a.b), (h2, _, _) = GlassTone.hsl(b.r, b.g, b.b)
                    #expect(min(abs(h1 - h2), 1 - abs(h1 - h2)) < 0.01, "\(name) \(look): the edge's hue")
                }
                let ratio = C.worstAdaptedRatio(colour, look)
                line += String(format: " | %@ %.2f", look == .light ? "light" : "dark", ratio)
                if let edge { line += String(format: " edge %@ %.2f", Self.hex(edge, look), C.worstAdaptedRatio(edge, look)) }
            }
            lines.append(line)
        }
        print("glyph colours on Glass (own ratio on each look's worst surface; the edge where one is drawn):\n" + lines.joined(separator: "\n"))
    }

    /// A status word in a state's colour (P593) keeps the colour's hue and saturation and reads at text's 4.5:1 on each
    /// look's worst surface (4:1 on a veil): as it is where it holds, else its lightness moved only as far as that needs;
    /// a word has no edge to carry it. The table is printed for the report.
    @Test func statusWordsKeepTheirHueAndRead() {
        let words: [(String, Color)] = NeedsYouColour.allCases.map { ("approval \($0)", $0.wait) } + [("done", IslandTheme.done), ("delegate", IslandTheme.delegate),
                                        ("stalled", IslandTheme.stalled), ("Codex", IslandTheme.agentCodex)]
        var lines: [String] = []
        for (name, colour) in words {
            let word = IslandPalette.glass.toneText(colour)
            var line = "\(name) \(Self.hex(colour, .light))"
            for look in [ColorScheme.light, .dark] {
                let ratio = C.worstAdaptedRatio(word, look)
                #expect(ratio >= C.text, "\(name) \(look): \(ratio)")
                for fill in GlassVeil.judged { #expect(C.worstAdaptedRatio(word, look, fills: [fill]) >= C.textOnFill) }
                let a = C.components(colour), b = C.components(word, look)
                let (h1, s1, _) = GlassTone.hsl(a.r, a.g, a.b), (h2, s2, _) = GlassTone.hsl(b.r, b.g, b.b)
                #expect(min(abs(h1 - h2), 1 - abs(h1 - h2)) < 0.01 && abs(s1 - s2) < 0.02, "\(name) \(look): hue or saturation moved")
                line += String(format: " | %@ %@ %.2f", look == .light ? "light" : "dark", Self.hex(word, look), ratio)
            }
            lines.append(line)
        }
        print("status words on Glass (each look's word and its ratio on that look's worst surface):\n" + lines.joined(separator: "\n"))
    }

    /// A glyph asks for its edge at every frame it draws (a moving glyph, 30 a second, up to 120 rows): past the first
    /// time it is a table lookup, with nothing resolved and no dynamic colour, so it adds nothing like P567's cost.
    @Test func theEdgeIsALookup() {
        let colours = Self.colours.map(\.1)
        for colour in colours { _ = GlassGlyph.edge(for: colour, look: .light); _ = GlassGlyph.edge(for: colour, look: .dark) }
        let calls = 40_000
        let start = DispatchTime.now().uptimeNanoseconds
        var edged = 0
        for i in 0..<calls where GlassGlyph.edge(for: colours[i % colours.count], look: i & 1 == 0 ? .light : .dark) != nil { edged += 1 }
        let each = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(calls) / 1000
        print(String(format: "a glyph's edge: %.2f µs a lookup (%d of %d edged)", each, edged, calls))
        #expect(each < 20)
    }

    // MARK: As drawn (P590, P592)

    /// Draws `view` at 2x on a clear ground in `look`, in Glass unless `theme` says otherwise.
    static func bitmap<V: View>(_ view: V, look: ColorScheme, theme: JuiceTheme = .glass) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.environment(\.juiceTheme, theme).environment(\.colorScheme, look)
            .environment(\.glassRendering, .standIn))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        return NSBitmapImageRep(cgImage: image)
    }

    /// `colour` as the renderer draws it (its output is not the colour's own sRGB values): a swatch's centre.
    static func drawn(_ colour: Color, look: ColorScheme) throws -> (r: Double, g: Double, b: Double) {
        let rep = try bitmap(Rectangle().fill(colour).frame(width: 8, height: 8), look: look, theme: .black)
        let c = rgba(rep, 8, 8)
        return (c.r, c.g, c.b)
    }

    static func rgba(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        return (Double(c?.redComponent ?? 0), Double(c?.greenComponent ?? 0), Double(c?.blueComponent ?? 0), Double(c?.alphaComponent ?? 0))
    }

    /// A Pixel glyph's lit cell on Glass is the state's colour itself, on both looks (the pill's check, done green).
    @Test(arguments: [ColorScheme.light, .dark])
    func pixelsCellsAreTheColourItself(_ look: ColorScheme) throws {
        let glyph = StateGlyphView(glyph: .check, colour: IslandTheme.done, pixel: 2.5, glow: false, animated: false, style: .pixel)
            .padding(4)
        let rep = try Self.bitmap(glyph, look: look)
        // The check's cells: its top cells (the rest are 85 %) are done's green itself, never its twin.
        let want = try Self.drawn(IslandTheme.done, look: look)
        var best = 1.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let c = Self.rgba(rep, x, y)
                guard c.a > 0.99 else { continue }
                best = min(best, abs(c.r - want.r) + abs(c.g - want.g) + abs(c.b - want.b))
            }
        }
        #expect(best < 0.02, "\(look): nearest opaque pixel to done's green is \(best) away")
    }

    /// Liquid's done check on Glass is green: most of its body is within reach of done's own green, where Black's is
    /// pale by design (the colour mixed half to three quarters toward white); on either look.
    @Test(arguments: [ColorScheme.light, .dark])
    func liquidsCheckIsGreenOnGlass(_ look: ColorScheme) throws {
        func greenShare(_ theme: JuiceTheme) throws -> Double {
            let side: CGFloat = 28
            let glyph = StateGlyphView(glyph: .check, colour: IslandTheme.done, glow: false, animated: false, style: .liquid, engineSide: side)
            let rep = try Self.bitmap(glyph.frame(width: side, height: side), look: look, theme: theme)
            let want = try Self.drawn(IslandTheme.done, look: look)
            var near = 0, all = 0
            // The check alone: above the body (its surface sits at 0.7 of the square).
            for y in Int(Double(rep.pixelsHigh) * 0.12)..<Int(Double(rep.pixelsHigh) * 0.55) {
                for x in 0..<rep.pixelsWide {
                    let c = Self.rgba(rep, x, y)
                    guard c.a > 0.99 else { continue }
                    all += 1
                    let d = ((c.r - want.r) * (c.r - want.r) + (c.g - want.g) * (c.g - want.g) + (c.b - want.b) * (c.b - want.b)).squareRoot()
                    if d < 0.2 { near += 1 }
                }
            }
            return all == 0 ? 0 : Double(near) / Double(all)
        }
        let glass = try greenShare(.glass), black = try greenShare(.black)
        print("Liquid's done check, \(look): \(Int(glass * 100)) % of it near done's green on Glass, \(Int(black * 100)) % on Black")
        #expect(glass >= 0.5 && black < 0.2, "\(look): Glass \(glass), Black \(black)")
    }

    // MARK: Dimmed (P594)

    /// The closed pill's resting check (`PillLead`'s dimmed check) on Glass, in every style and on both looks, over the
    /// look's worst surface: drawn opaque in done's green stepped toward the glass, never at partial alpha, so it stays
    /// green (done's hue, most of its chroma: Black's 42 % over a light glass is a pale mint), reads weaker than the bright
    /// check (it stands out from the ground less), and on the light look its edge holds 3:1 as the bright one's does (an
    /// edge under a translucent glyph compounds into a solid dark core that stands out more than the bright check).
    @Test(arguments: GlyphStyle.allCases, [ColorScheme.light, .dark])
    func theDimCheckStaysGreenAndReadsWeaker(_ style: GlyphStyle, _ look: ColorScheme) throws {
        let ground = look == .light ? Color(hex: 0xBFBFBF) : Color(hex: 0x404040)
        struct Measure { var standout = 0.0, glyph = 0, green = 0, darkest = 1.0, ground = 0.0 }
        let done = C.components(IslandTheme.done, look)
        let (hue, _, _) = GlassTone.hsl(done.r, done.g, done.b)
        let chroma = max(done.r, done.g, done.b) - min(done.r, done.g, done.b)
        func measure(dimmed: Bool) throws -> Measure {
            let glyph = StateGlyphView(glyph: .check, colour: IslandTheme.done, pixel: 2.5, dimmed: dimmed, glow: !dimmed, animated: false,
                                       style: style, engineSide: 28)
                .frame(width: 28, height: 28).padding(10).background(ground)
            let rep = try Self.bitmap(glyph, look: look)
            let g = Self.rgba(rep, 1, 1), lg = C.luminance(r: g.r, g: g.g, b: g.b)
            var m = Measure(ground: lg)
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    let p = Self.rgba(rep, x, y), l = C.luminance(r: p.r, g: p.g, b: p.b)
                    m.standout += abs(l - lg)
                    guard abs(p.r - g.r) + abs(p.g - g.g) + abs(p.b - g.b) > 0.12 else { continue }
                    m.glyph += 1
                    m.darkest = min(m.darkest, l)
                    let (h, _, _) = GlassTone.hsl(p.r, p.g, p.b)
                    if min(abs(h - hue), 1 - abs(h - hue)) < 0.04, max(p.r, p.g, p.b) - min(p.r, p.g, p.b) >= 0.6 * chroma { m.green += 1 }
                }
            }
            return m
        }
        let bright = try measure(dimmed: false), dim = try measure(dimmed: true)
        let share = Double(dim.green) / Double(max(1, dim.glyph)), lg = dim.ground
        print(String(format: "%@ %@ dim check: %d %% green; stands out %.0f (bright %.0f); darkest %.2f:1 (bright %.2f:1)", style.rawValue,
                     look == .light ? "light" : "dark", Int(share * 100), dim.standout, bright.standout,
                     C.ratio(dim.darkest, lg), C.ratio(bright.darkest, lg)))
        #expect(share >= 0.5, "\(style) \(look): \(Int(share * 100)) % of the dim check is done's green")
        #expect(dim.standout < 0.9 * bright.standout, "\(style) \(look): the dim check stands out \(dim.standout), the bright \(bright.standout)")
        if look == .light {
            #expect(C.ratio(dim.darkest, lg) >= 0.95 * C.ratio(bright.darkest, lg),
                    "\(style): the dim check's edge \(C.ratio(dim.darkest, lg)), the bright's \(C.ratio(bright.darkest, lg))")
        }
    }

    // MARK: Pixel's cells on the device pixels (P595)

    /// Pixel's cells on Glass sit on the device pixels as Black's do: the canvas reaches past the glyph's square by whole
    /// points, so no lit cell straddles two device pixels (a half-pixel canvas smears each cell and half fills its gaps). At
    /// 2x, on both looks, at the footer's, the rows' and the pill's pixel: every device pixel of the check's full cells is
    /// done's green, and no other is.
    @Test(arguments: [CGFloat(1.5), 2, 2.5], [ColorScheme.light, .dark])
    func pixelsCellsSitOnTheDevicePixels(_ pixel: CGFloat, _ look: ColorScheme) throws {
        let want = try Self.drawn(IslandTheme.done, look: look)
        let full = PixelGlyph.check.alphas(frame: 0).joined().filter { $0 >= 1 }.count
        let cell = Int((2 * max(pixel - 0.5, 0.5)).rounded())
        for theme in [JuiceTheme.black, .glass] {
            let glyph = StateGlyphView(glyph: .check, colour: IslandTheme.done, pixel: pixel, glow: false, animated: false, style: .pixel)
                .padding(4)
            let rep = try Self.bitmap(glyph, look: look, theme: theme)
            var exact = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    let c = Self.rgba(rep, x, y)
                    if c.a > 0.99, abs(c.r - want.r) + abs(c.g - want.g) + abs(c.b - want.b) < 0.02 { exact += 1 }
                }
            }
            #expect(exact == full * cell * cell, "\(theme) \(look) at \(pixel) pt: \(exact) device pixels of done's green, want \(full * cell * cell)")
        }
    }

    // MARK: The header's brand glyph (P596)

    /// The opened island's brand glyph on Glass over white takes the session glyphs' finish: its cells are the brand's own
    /// orange at full strength over its edge, never the light look's twin (a murky brown) with a coloured-shadow glow.
    @Test func theHeadersBrandGlyphIsTheBrandsOwnColour() throws {
        let env = IslandGlassRenders.environment()
        let ui = IslandGlassRenders.state(env, surface: .island)
        let size = IslandGlassRenders.openSize
        let pixels = try ThemeTests.pixels(IslandGlassRenders.scene(ui, size: size, backdrop: .white, theme: .glass).environment(env), size: size)
        // Each colour as this renderer draws it on the light look: a swatch's centre.
        func drawn(_ colour: Color) throws -> (r: Double, g: Double, b: Double, a: Double) {
            try ThemeTests.pixels(Rectangle().fill(colour).environment(\.colorScheme, .light), size: CGSize(width: 8, height: 8)).rgba(8, 8)
        }
        let own = try drawn(IslandTheme.brand)
        var ownCount = 0
        // The header's row: the top 36 points of the left half.
        for y in 0..<72 {
            for x in 0..<Int(size.width) {
                let p = pixels.rgba(x, y)
                guard p.a > 0.99 else { continue }
                if abs(p.r - own.r) + abs(p.g - own.g) + abs(p.b - own.b) < 0.03 { ownCount += 1 }
            }
        }
        // Every full cell is the brand's own orange, all 3 × 3 device pixels of it (the edge under them is the twin).
        let full = PixelGlyph.brand.alphas(frame: 0).joined().filter { $0 >= 1 }.count
        #expect(ownCount >= 9 * full, "the brand's own orange in \(ownCount) device pixels, want \(9 * full)")
    }

    // MARK: The widget's system looks (P597)

    /// In the widget's tinted, clear and vibrant looks the system draws the content in one tint, so the rows' glyphs are
    /// plain on Glass as on Black (an edge would join the glyph: Pixel's plate filling its gaps, a rim around Liquid and
    /// Sand): the light scheme's tinted widget draws on Glass exactly what it draws on Black.
    @Test(arguments: GlyphStyle.allCases)
    func theWidgetsSystemLooksDrawPlainGlyphs(_ style: GlyphStyle) throws {
        var snapshot = WidgetSnapshot.preview(at: WidgetThemeTests.now)
        snapshot.glyphStyle = style.rawValue
        let size = WidgetRenders.Size.medium
        func pixels(_ theme: JuiceTheme) throws -> [UInt8] {
            try ThemeTests.pixels(IslandWidgetView(snapshot: snapshot, face: .medium, size: size, date: WidgetThemeTests.now, tinted: true)
                .environment(\.juiceTheme, theme).environment(\.colorScheme, .light), size: size).data
        }
        let before = try pixels(.black), glass = try pixels(.glass), after = try pixels(.black)
        // Liquid's drawing differs by a unit here and there from one draw to the next: an edge or a plate is far more.
        func apart(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).filter { abs(Int($0) - Int($1)) > 2 }.count }
        let off = min(apart(glass, before), apart(glass, after))
        #expect(off == 0, "\(style): the tinted widget on Glass differs from Black's in \(off) channels")
    }

    // MARK: Nothing of the glass over the glyphs (P593)

    /// The glass lays no colour filter over the island's content: in the Glass island's layers, headless, the only
    /// filters are the glass's own backdrop and its vibrant copy of the content at zero opacity; the glyphs' layers carry
    /// none (explicit colours take no vibrancy). What the window server composites live is P565's.
    @Test func theGlassTintsNoGlyph() async throws {
        _ = NSApplication.shared
        let rig = FramePerf.IslandRig(style: .clean, glyph: .liquid, glyphsMove: false, outline: .swiftUI, theme: .glass)
        await rig.start()
        await FramePerf.wait(0.3)
        rig.open()
        await FramePerf.wait(1.2)
        var filtered: [String] = []
        var drawn = 0
        func walk(_ layer: CALayer, hidden: Bool) {
            let kind = String(describing: type(of: layer))
            let unseen = hidden || layer.opacity == 0
            if kind.contains("Drawing") { drawn += 1 }
            // A blur is no tint: the opening's focus transition blurs its content while it runs, which under a loaded
            // full run can outlast the wait. Only a colour filter would change a glyph's colour.
            let tints = (layer.filters ?? []).map { String(describing: $0) }.filter { !$0.contains("gaussianBlur") }
            if !tints.isEmpty, !kind.contains("Backdrop"), !unseen {
                filtered.append("\(kind) \(tints)")
            }
            for sublayer in layer.sublayers ?? [] { walk(sublayer, hidden: unseen) }
        }
        walk(try #require(rig.host.layer), hidden: false)
        #expect(drawn > 10)
        #expect(filtered.isEmpty, "\(filtered)")
        rig.stop()
    }
}
