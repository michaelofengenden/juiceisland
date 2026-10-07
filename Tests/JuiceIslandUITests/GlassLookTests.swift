import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// State tint, Frost and the pointer-lit rim (`GlassLook`, P630 to P639): what the tint follows; every Glass ink holding
/// under each tint and across Frost's range, on both looks, standard and Increase Contrast; the rim's light on the
/// pointer's side; the settings; and, in both outline engines, each drawn inside the outline, on the plan, at rest with
/// nothing running. The live glass is the window server's (P565).
@MainActor
@Suite(.serialized)
struct GlassLookTests {
    typealias C = GlassContrast

    static let schemes: [ColorScheme] = [.light, .dark]
    static let contrasts: [ColorSchemeContrast] = [.standard, .increased]

    // MARK: State tint: what it follows

    /// The tint is the pill's lead: what needs you (an approval, a question, a failed turn), the bright check of a
    /// finish, a main turn delegating; never a run, a stalled run, the dim check or nothing.
    @Test func theTintFollowsThePillsLead() {
        func lead(_ glyph: PixelGlyph, _ state: GlyphPalette.State, dimmed: Bool = false, still: Bool = false) -> PillLead {
            PillLead(glyph: glyph, agent: .claude, state: state, dimmed: dimmed, still: still)
        }
        #expect(StateTint(lead: lead(.bang, .waiting)) == .needsYou)
        #expect(StateTint(lead: lead(.ques, .waiting)) == .needsYou)
        #expect(StateTint(lead: lead(.cross, .waiting)) == .needsYou)
        #expect(StateTint(lead: lead(.check, .done)) == .finished)
        #expect(StateTint(lead: lead(.agents, .delegating)) == .delegating)
        #expect(StateTint(lead: lead(.check, .done, dimmed: true)) == nil)
        #expect(StateTint(lead: lead(.eq, .running)) == nil)
        #expect(StateTint(lead: lead(.eq, .running, still: true)) == nil)
        #expect(StateTint(lead: nil) == nil)
        // From the rows, as the pill leads: a request over a run; a run over a finish; a finish's 4 s once nothing runs.
        let run = ActiveCountTests.row("r", .codex, .running, ago: 10), ask = ActiveCountTests.row("q", .claude, .needsYou, ago: 60)
        let done = ActiveCountTests.row("d", .claude, .done, ago: 120)
        #expect(StateTint(lead: PillLead.make(rows: [run, ask], recentlyFinished: nil)) == .needsYou)
        #expect(StateTint(lead: PillLead.make(rows: [run, done], recentlyFinished: .claude)) == nil)
        #expect(StateTint(lead: PillLead.make(rows: [done], recentlyFinished: .claude)) == .finished)
        #expect(StateTint(lead: PillLead.make(rows: [done], recentlyFinished: nil)) == nil)
        // Its colours are the states' own; what needs you, in each choice of its colour.
        for needsYou in NeedsYouColour.allCases {
            #expect(StateTint.needsYou.colour(needsYou) == needsYou.wait && StateTint.finished.colour(needsYou) == IslandTheme.done
                && StateTint.delegating.colour(needsYou) == IslandTheme.delegate)
        }
    }

    // MARK: Glass's veil: legible on both looks

    /// Each veil twin keeps its state's hue and saturation, on the ink's far side of its look's bound: lighter than the
    /// light look's floor, darker than the dark look's ceiling, under Increase Contrast's bounds too.
    @Test(arguments: NeedsYouColour.allCases)
    func eachVeilKeepsItsHueOnTheFarSideOfItsBound(_ needsYou: NeedsYouColour) {
        for tint in StateTint.allCases {
            let c = C.components(tint.colour(needsYou))
            let (h, s, _) = GlassTone.hsl(c.r, c.g, c.b)
            for contrast in Self.contrasts {
                for scheme in Self.schemes {
                    let twin = C.components(StateTint.twin(tint.colour(needsYou), scheme, contrast))
                    let (th, ts, _) = GlassTone.hsl(twin.r, twin.g, twin.b)
                    #expect(min(abs(th - h), 1 - abs(th - h)) < 0.01 && abs(ts - s) < 0.02, "\(tint) \(scheme) \(contrast): hue moved")
                    let lum = C.luminance(r: twin.r, g: twin.g, b: twin.b), bound = C.worstAdapted(scheme, contrast: contrast)
                    if scheme == .light { #expect(lum > bound * 1.1, "\(tint) light \(contrast): \(lum)") }
                    else { #expect(lum < bound * 0.75, "\(tint) dark \(contrast): \(lum)") }
                }
            }
        }
    }

    /// The fills a Glass surface can carry at once: Frost's at `frost` (none at 0), then the tint's veil (none for nil)
    /// with `needsYou` chosen.
    static func fills(frost: Double, tint: StateTint?, needsYou: NeedsYouColour = .pink, contrast: ColorSchemeContrast) -> [Color] {
        (frost > 0 ? [GlassFrost.colour(frost)] : []) + (tint.map { [$0.veil(contrast, needsYou: needsYou)] } ?? [])
    }

    /// Every tint a surface can take: what needs you in each of its colours, a finish, a delegation; and none with Frost.
    static func tints(frost: Double) -> [(tint: StateTint, needsYou: NeedsYouColour)?] {
        StateTint.allCases.flatMap { tint in
            tint == .needsYou ? NeedsYouColour.allCases.map { (tint, $0) } : [(tint, NeedsYouColour.pink)]
        } + (frost > 0 ? [nil] : [])
    }

    /// Every Glass ink holds under each tint (and none), at Frost's two ends, on both looks, standard and Increase
    /// Contrast: text 4.5:1 bare and 4:1 on a hover or card veil, the cards' inks 4:1 on their own fills, marks and every
    /// state and agent colour 3:1 bare and on a hover. The lowest are printed for the report.
    @Test(arguments: [0.0, 1.0])
    func everyGlassInkHoldsUnderEachTintAndFrost(_ frost: Double) {
        let p = IslandPalette.glass
        let cards: [(String, Color, [Color])] = [
            ("optionBadgeText", p.optionBadgeText, [p.optionBadge]), ("optionSub", p.optionSub, [p.optionBg]),
            ("optionSub hovered", p.optionSub, [p.rowHover, p.optionHover]), ("cardKbd on a button", p.cardKbd, [p.button]),
            ("diffContext", p.diffContext, [p.codeBg]), ("code in a Done card's box", p.codeText, [p.codeBg, p.messageCodeBox]),
            ("diffAdded", p.diffAdded, [p.diffAddedFill]), ("diffRemoved", p.diffRemoved, [p.diffRemovedFill]),
            ("the jump tag", p.tagJump.fg, [p.tagJump.bg]),
        ]
        var lines: [String] = []
        for contrast in Self.contrasts {
            for scheme in Self.schemes {
                var lowestText = (name: "", ratio: Double.infinity), lowestMark = lowestText
                // The tints only: the lowest under any of them (the untinted glass's own lowest is `GlassThemeTests`').
                for each in Self.tints(frost: frost) {
                    let tint = each?.tint
                    let base = Self.fills(frost: frost, tint: tint, needsYou: each?.needsYou ?? .pink, contrast: contrast)
                    func ratio(_ colour: Color, _ more: [Color] = []) -> Double {
                        C.ratio(C.luminance(colour, scheme), C.worstAdapted(scheme, fills: base + more, contrast: contrast))
                    }
                    let label = "\(scheme) \(contrast) frost \(frost) \(tint?.rawValue ?? "none") \(each?.needsYou.rawValue ?? "")"
                    for (name, colour) in GlassThemeTests.text + GlassThemeTests.words {
                        let bare = ratio(colour)
                        #expect(bare >= C.text, "\(label) \(name): \(bare)")
                        for veil in GlassVeil.judged { #expect(ratio(colour, [veil]) >= C.textOnFill, "\(label) \(name) on a veil") }
                        if bare < lowestText.ratio { lowestText = (name + " · " + (tint?.rawValue ?? "none"), bare) }
                    }
                    for (name, colour, own) in cards {
                        #expect(ratio(colour, own) >= C.textOnFill, "\(label) \(name) on its fill")
                    }
                    for (name, colour) in GlassThemeTests.marks {
                        let bare = ratio(colour)
                        #expect(bare >= C.mark, "\(label) mark \(name): \(bare)")
                        #expect(ratio(colour, [p.islandHover]) >= C.mark, "\(label) mark \(name) on a hover")
                        if bare < lowestMark.ratio { lowestMark = (name + " · " + (tint?.rawValue ?? "none"), bare) }
                    }
                }
                lines.append(String(format: "frost %.0f %@ %@: text %@ %.2f, mark %@ %.2f", frost, "\(scheme)", "\(contrast)",
                                    lowestText.name, lowestText.ratio, lowestMark.name, lowestMark.ratio))
            }
        }
        print("glass inks under the tints and frost:\n" + lines.joined(separator: "\n"))
    }

    // MARK: Frost

    /// Frost only frosts: across its range each look's worst surface moves away from its ink (lighter on the light look,
    /// darker on the dark), never toward it; at 0 it is nothing at all; a value is kept in hundredths, 0 to 1.
    @Test func frostOnlyMovesEachLooksWorstSurfaceAwayFromItsInk() {
        for step in 0...10 {
            let frost = Double(step) / 10
            for contrast in Self.contrasts {
                for scheme in Self.schemes {
                    let frosted = C.worstAdapted(scheme, fills: [GlassFrost.colour(frost)], contrast: contrast)
                    let bare = C.worstAdapted(scheme, contrast: contrast)
                    if scheme == .light { #expect(frosted >= bare - 1e-12, "\(frost) light \(contrast)") }
                    else { #expect(frosted <= bare + 1e-12, "\(frost) dark \(contrast)") }
                }
            }
        }
        for scheme in Self.schemes { #expect(C.components(GlassFrost.colour(0), scheme).a == 0) }
        #expect(abs(C.components(GlassFrost.colour(1), .light).a - GlassFrost.maximum) < 0.001)
        #expect(GlassFrost.stored(-0.3) == 0 && GlassFrost.stored(1.7) == 1 && GlassFrost.stored(0.456) == 0.46)
        #expect(FrostSlider.value(at: 0, knob: 16) == 0 && FrostSlider.value(at: FrostSlider.width, knob: 16) == 1)
    }

    // MARK: The rim's light

    /// The light sits on the pointer's side: pushed from the island's middle out through the pointer, toward the rim
    /// nearest it; its reach a third of the island's width and height together, 60 to 160 pt.
    @Test func theRimsLightSitsOnThePointersSide() {
        let pill = SurfaceGeometry(left: 110, right: 150, height: 33, ear: 6, radius: 10)
        let island = SurfaceGeometry(width: 480, height: 330, ear: 10, radius: 24)
        let midX: CGFloat = 300
        let pillMiddle = CGPoint(x: midX + 20, y: 16.5)
        let left = RimLight.place(pointer: CGPoint(x: 230, y: 24), target: pill, midX: midX)
        #expect(left.centre.x < 230 && left.centre.y > 24)
        #expect(abs((left.centre.x - pillMiddle.x) / (230 - pillMiddle.x) - RimLight.push) < 0.001)
        let bottom = RimLight.place(pointer: CGPoint(x: midX, y: 300), target: island, midX: midX)
        #expect(bottom.centre.y > 300 && abs(bottom.centre.x - midX) < 0.001)
        let right = RimLight.place(pointer: CGPoint(x: midX + 200, y: 165), target: island, midX: midX)
        #expect(right.centre.x > midX + 200 && abs(right.centre.y - 165) < 0.001)
        #expect(abs(left.radius - (260 + 33) * 0.3) < 0.001 && bottom.radius == 160)
        #expect(RimLight.place(pointer: .zero, target: SurfaceGeometry(width: 80, height: 20, ear: 0, radius: 0), midX: 40).radius == 60)
    }

    // MARK: Settings

    /// State tint is on and Frost at 0 until the owner changes them; both are kept, Frost in hundredths; Frost's row
    /// shows under Glass only, State tint's under Black and Glass.
    @Test func theSettingsKeepTheirDefaultsAndTheirWords() throws {
        let fresh = AppSettings.ephemeral()
        #expect(fresh.islandStateTint && fresh.glassFrost == 0)
        let suite = "glass-look-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.islandStateTint && settings.glassFrost == 0)
        settings.islandStateTint = false
        settings.glassFrost = 0.437
        #expect(defaults.object(forKey: AppSettings.Key.islandStateTint) as? Bool == false)
        #expect(defaults.object(forKey: AppSettings.Key.glassFrost) as? Double == 0.44)
        let again = AppSettings(defaults: defaults)
        #expect(!again.islandStateTint && again.glassFrost == 0.44)
        defaults.set(3.0, forKey: AppSettings.Key.glassFrost)
        #expect(AppSettings(defaults: defaults).glassFrost == 1)
        #expect(IslandPaneText.showsFrostRow(.glass) && !IslandPaneText.showsFrostRow(.black) && !IslandPaneText.showsFrostRow(.smoke))
        #expect(IslandPaneText.showsStateTintRow(.glass) && IslandPaneText.showsStateTintRow(.black) && !IslandPaneText.showsStateTintRow(.smoke))
    }

    /// Nothing tints or frosts unless asked: a view reads State tint off and Frost 0; under a root with
    /// `juiceThemeFromSettings()`, the settings.
    @Test func theRootsTakeTintAndFrostFromTheSettings() throws {
        let box = LookBox()
        _ = try RenderHarness.hostedBitmap(LookProbe(box: box), "look-probe", size: CGSize(width: 10, height: 10))
        #expect(box.tint == false && box.frost == 0)
        let env = AppEnvironment.demo()
        env.settings.glassFrost = 0.7
        _ = try RenderHarness.hostedBitmap(LookProbe(box: box).juiceThemeFromSettings(), "look-probe", size: CGSize(width: 10, height: 10), env: env)
        #expect(box.tint == true && box.frost == 0.7)
    }

    // MARK: SwiftUI's outline: drawn inside, and nothing else changes

    /// The island at 2×, `state` of the renders' island (SwiftUI's outline) on `backdrop`, with the look's options.
    static func bitmap(_ ui: IslandUIState, env: AppEnvironment, size: CGSize, backdrop: GlassBackdrop, theme: JuiceTheme,
                       tint: Bool = false, frost: Double = 0, needsYou: NeedsYouColour = .pink) throws -> CGImage {
        let view = IslandGlassRenders.scene(ui, size: size, backdrop: backdrop, theme: theme)
            .environment(\.islandStateTint, tint).environment(\.glassFrost, frost).environment(\.needsYouColour, needsYou)
            .environment(env).environment(\.colorScheme, .dark).environment(\.glassRendering, .standIn)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    static func pixels(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int) {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (bytes, w, h)
    }

    /// Where two renders of one scene differ by more than `threshold` in a channel (a tint laid under the content moves
    /// the glyphs' glows by a level or four as they composite over it): each pixel inside the island's outline (as the
    /// scene places it: the canvas centred in `size`, its corners within a point and a half, where antialiasing and the
    /// corners' two curves differ) or not, and within `band` points of its edge or not.
    static func differences(_ a: CGImage, _ b: CGImage, geometry: SurfaceGeometry, size: CGSize, band: CGFloat = 1.6, threshold: Int = 6)
        -> (outside: Int, deep: Int, edge: Int, points: [(x: Int, y: Int)]) {
        let pa = pixels(a), pb = pixels(b)
        let canvasX = (size.width - IslandPanelSizing.canvasWidth) / 2
        let path = NotchSurfaceShape.path(geometry, originX: canvasX + IslandPanelSizing.canvasWidth / 2 - geometry.left, top: 0).cgPath
        var outside = 0, deep = 0, edge = 0, points: [(Int, Int)] = []
        for y in 0..<pa.height {
            for x in 0..<pa.width {
                let i = (y * pa.width + x) * 4
                guard (0..<4).contains(where: { abs(Int(pa.bytes[i + $0]) - Int(pb.bytes[i + $0])) > threshold }) else { continue }
                let p = CGPoint(x: (CGFloat(x) + 0.5) / 2, y: (CGFloat(y) + 0.5) / 2)
                let near = [CGPoint(x: -1.5, y: 0), CGPoint(x: 1.5, y: 0), CGPoint(x: 0, y: -1.5), CGPoint(x: 0, y: 1.5), .zero]
                    .contains { path.contains(CGPoint(x: p.x + $0.x, y: p.y + $0.y)) }
                guard near else { outside += 1; continue }
                let deepInside = [CGPoint(x: -band, y: 0), CGPoint(x: band, y: 0), CGPoint(x: 0, y: band), CGPoint(x: 0, y: -band)]
                    .allSatisfy { path.contains(CGPoint(x: p.x + $0.x, y: p.y + $0.y)) || p.y + $0.y < 0 }
                if deepInside { deep += 1 } else { edge += 1 }
                points.append((x, y))
            }
        }
        return (outside, deep, edge, points)
    }

    static func rgb(_ image: CGImage, _ x: CGFloat, _ y: CGFloat) -> (r: Int, g: Int, b: Int) {
        let p = pixels(image), i = (Int(y * 2) * p.width + Int(x * 2)) * 4
        return (Int(p.bytes[i]), Int(p.bytes[i + 1]), Int(p.bytes[i + 2]))
    }

    /// Black's edge on SwiftUI's outline: only a line just inside the outline changes, in the state's colour, strongest
    /// along the bottom; the #000 body and everything beyond the outline stay as they are; State tint off draws nothing.
    @Test(arguments: NeedsYouColour.allCases)
    func blacksEdgeIsALineJustInsideTheOutline(_ needsYou: NeedsYouColour) throws {
        let env = IslandGlassRenders.environment()
        for (name, ui, size) in [("closed", IslandGlassRenders.state(env), IslandGlassRenders.pillSize),
                                 ("open", IslandGlassRenders.state(env, surface: .island), IslandGlassRenders.openSize)] {
            #expect(StateTint(lead: ui.pill.lead) == .needsYou, "the prototype's sessions lead with an approval")
            let off = try Self.bitmap(ui, env: env, size: size, backdrop: .white, theme: .black, needsYou: needsYou)
            let on = try Self.bitmap(ui, env: env, size: size, backdrop: .white, theme: .black, tint: true, needsYou: needsYou)
            // Only the line changes: nothing more than 1.6 pt inside (the #000 body) and nothing beyond the outline.
            let d = Self.differences(off, on, geometry: ui.surface, size: size)
            #expect(d.outside == 0 && d.deep == 0 && d.edge > 100, "\(name): \(d.outside) outside, \(d.deep) deep, \(d.edge) on the edge")
            // The bottom's middle, half a point inside: the needs-you colour, its channels in its own order.
            let line = Self.rgb(on, size.width / 2, ui.surface.height - 0.5)
            let axis = Self.axis(needsYou.wait), channels = [line.r, line.g, line.b]
            #expect(channels[axis.high] > channels[axis.middle] && channels[axis.middle] > channels[axis.low] && channels[axis.high] > 90,
                    "\(name) \(needsYou) line \(line)")
        }
    }

    /// Glass's veil on SwiftUI's outline: the island's glass takes the state's hue (for what needs you, its colour's), only
    /// inside the outline; beyond it nothing changes.
    @Test(arguments: NeedsYouColour.allCases)
    func glasssVeilTintsOnlyTheGlassInside(_ needsYou: NeedsYouColour) throws {
        let env = IslandGlassRenders.environment()
        let ui = IslandGlassRenders.state(env, surface: .island), size = IslandGlassRenders.openSize
        let axis = Self.axis(needsYou.wait)
        func hue(_ p: (r: Int, g: Int, b: Int)) -> Int { let c = [p.r, p.g, p.b]; return c[axis.high] - c[axis.low] }
        for backdrop in [GlassBackdrop.white, .black] {
            let off = try Self.bitmap(ui, env: env, size: size, backdrop: backdrop, theme: .glass, needsYou: needsYou)
            let on = try Self.bitmap(ui, env: env, size: size, backdrop: backdrop, theme: .glass, tint: true, needsYou: needsYou)
            let d = Self.differences(off, on, geometry: ui.surface, size: size)
            #expect(d.outside == 0 && d.deep > 10_000, "\(backdrop): \(d.outside) outside, \(d.deep) inside")
            // Where it changed (the glass, never the ink over it): further along the colour's own axis on average (its
            // strongest channel over its weakest: red over blue for the orange, red over green for the pink, blue over
            // green for the violet).
            let before = Self.mean(d.points, off, hue), tinted = Self.mean(d.points, on, hue)
            #expect(tinted > before + 8, "\(backdrop) \(needsYou): \(before) → \(tinted)")
        }
    }

    /// `colour`'s channels (0 red, 1 green, 2 blue) from its strongest to its weakest.
    static func axis(_ colour: Color) -> (high: Int, middle: Int, low: Int) {
        let c = C.components(colour), order = [c.r, c.g, c.b].enumerated().sorted { $0.element > $1.element }.map(\.offset)
        return (order[0], order[1], order[2])
    }

    /// Frost on SwiftUI's outline: the glass over the busy photo evens out (less of the photo shows), only inside.
    @Test func frostEvensTheGlassOnlyInside() throws {
        let env = IslandGlassRenders.environment()
        let ui = IslandGlassRenders.state(env, surface: .island), size = IslandGlassRenders.openSize
        let clear = try Self.bitmap(ui, env: env, size: size, backdrop: .busy, theme: .glass)
        let frosted = try Self.bitmap(ui, env: env, size: size, backdrop: .busy, theme: .glass, frost: 1)
        let d = Self.differences(clear, frosted, geometry: ui.surface, size: size)
        #expect(d.outside == 0 && d.deep > 10_000, "\(d.outside) outside, \(d.deep) inside")
        // Where it changed (the glass), less of the photo's colour shows: its mean chroma falls.
        let chroma = Self.mean(d.points, clear) { max($0.r, $0.g, $0.b) - min($0.r, $0.g, $0.b) }
        let frostedChroma = Self.mean(d.points, frosted) { max($0.r, $0.g, $0.b) - min($0.r, $0.g, $0.b) }
        #expect(frostedChroma < chroma * 0.6, "\(chroma) → \(frostedChroma)")
    }

    /// The mean of `value` over `points` (pixels) of `image`.
    static func mean(_ points: [(x: Int, y: Int)], _ image: CGImage, _ value: ((r: Int, g: Int, b: Int)) -> Int) -> Double {
        let p = pixels(image)
        guard !points.isEmpty else { return 0 }
        return Double(points.reduce(0) { total, point in
            let i = (point.y * p.width + point.x) * 4
            return total + value((Int(p.bytes[i]), Int(p.bytes[i + 1]), Int(p.bytes[i + 2])))
        }) / Double(points.count)
    }

    /// The rim's light on SwiftUI's outline: only the rim changes, near the spot; nothing beyond the outline.
    @Test func theRimCatchesTheLightOnlyOnItsLine() throws {
        let env = IslandGlassRenders.environment()
        for (name, ui, size) in [("closed", IslandGlassRenders.state(env), IslandGlassRenders.pillSize),
                                 ("open", IslandGlassRenders.state(env, surface: .island), IslandGlassRenders.openSize)] {
            let dark = try Self.bitmap(ui, env: env, size: size, backdrop: .black, theme: .glass)
            let canvasMid = IslandPanelSizing.canvasWidth / 2
            let place = RimLight.place(pointer: CGPoint(x: canvasMid - ui.surface.left + 30, y: ui.surface.height - 8), target: ui.surface,
                                       midX: canvasMid)
            ui.rimLight.set(.init(centre: place.centre, radius: place.radius))
            let lit = try Self.bitmap(ui, env: env, size: size, backdrop: .black, theme: .glass)
            ui.rimLight.set(nil)
            let d = Self.differences(dark, lit, geometry: ui.surface, size: size)
            #expect(d.outside == 0 && d.deep == 0 && d.edge > 40, "\(name): \(d.outside) outside, \(d.deep) deep, \(d.edge) on the rim")
            // Every change lies within the light's reach of its centre (the scene's canvas offset added).
            let offset = (size.width - IslandPanelSizing.canvasWidth) / 2
            let far = d.points.filter { hypot(CGFloat($0.x) / 2 - offset - place.centre.x, CGFloat($0.y) / 2 - place.centre.y) > place.radius + 1 }
            #expect(far.isEmpty, "\(name): \(far.count) beyond the light's reach")
            let again = try Self.bitmap(ui, env: env, size: size, backdrop: .black, theme: .glass)
            #expect(Self.differences(dark, again, geometry: ui.surface, size: size).points.isEmpty, "\(name): gone with the pointer")
        }
    }

    // MARK: Core Animation's outline

    /// Whether `condition` holds within `seconds` worth of looks (`Looks`). Counted looks, not the clock: what it waits
    /// for (a light's or an edge's sweep, a main-queue wake after its fade) waits behind a loaded run's main actor as
    /// each look does, and two seconds of wall clock have passed there with the wake still queued (P1253).
    static func within(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        await Looks.until(seconds, condition)
    }

    /// A layer of the black's view rendered alone (`CALayer.render(in:)`, the view flipped: y down), against `expected`'s
    /// outline at 2×: pixels beyond the outline (more than a pixel from its edge) and inside it, in the canvas's top 400 pt.
    static func outside(_ layer: CALayer, canvas: CGSize, expected: SurfaceGeometry) -> (outside: Int, inside: Int) {
        let scale: CGFloat = 2
        let w = Int(canvas.width * scale), h = Int(min(canvas.height, 400) * scale)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        let path = NotchSurfaceShape.path(expected, originX: canvas.width / 2 - expected.left, top: 0).cgPath
        var outside = 0, inside = 0
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 128 {
                let p = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                let near = [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1), .zero]
                    .contains { path.contains(CGPoint(x: p.x + $0.x * 0.75, y: p.y + $0.y * 0.75)) }
                if near { inside += 1 } else { outside += 1 }
            }
        }
        return (outside, inside)
    }

    /// Black's edge on Core Animation's outline: none while State tint is off; on, a host over the black's fill in its
    /// own view (the fill still #000), masked by the outline, its light masked by the outline's line; both on the fill's
    /// very paths at rest, closed and open, the plan's keyframes mid-open (its begin and length the content's clip's),
    /// and no animation left at rest; the rig's sessions lead with an approval, so it shows what needs you.
    @Test func blacksEdgeRidesThePlanInsideTheOutline() async throws {
        _ = NSApplication.shared
        let rig = await IslandGlassTests.rig(.coreAnimation, theme: .black)
        let canvas = rig.canvas, layers = canvas.layers
        #expect(canvas.edgeLayers == nil && layers.edge == nil)
        canvas.setStateTint(true)
        let edge = try #require(canvas.edgeLayers)
        let surface = try #require(canvas.surfaceView)
        let sublayers = surface.root.sublayers ?? []
        #expect(edge.host.superlayer === surface.root && sublayers.firstIndex(of: edge.host)! > sublayers.firstIndex(of: layers.fill)!)
        #expect(edge.isSound && edge.host.mask === edge.mask && edge.light.mask === edge.stroke && layers.edge === edge)
        #expect(layers.fill.fillColor == CGColor(gray: 0, alpha: 1))
        #expect(edge.stroke.lineWidth == 2 && edge.stroke.fillColor == nil)
        #expect(edge.tint == .needsYou && !edge.host.isHidden)
        #expect(edge.host.contentsScale == rig.window.backingScaleFactor)
        for step in [{}, { rig.open() }] as [@MainActor () -> Void] {
            step()
            await FramePerf.wait(1.6)
            #expect(edge.mask.path == layers.fill.path && edge.stroke.path == layers.fill.path)
            let rest = Self.outside(edge.mask, canvas: IslandGlassTests.canvasSize, expected: rig.director.model.restGeometry)
            #expect(rest.outside == 0 && rest.inside > 1000, "\(rest)")
        }
        rig.director.send(.close(.fold))
        let playing = try #require(edge.mask.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation)
        let clip = try #require(layers.clip.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation)
        #expect(playing.values?.count == clip.values?.count && abs(playing.beginTime - clip.beginTime) < 0.001 && playing.duration == clip.duration)
        #expect(edge.stroke.animation(forKey: IslandSurfaceLayers.key) != nil)
        await FramePerf.wait(1.8)
        #expect(edge.pathLayers.allSatisfy { $0.animationKeys() == nil } && edge.light.animationKeys() == nil)
        #expect(edge.mask.path == layers.fill.path)
        rig.stop()
    }

    /// The edge comes and goes with State tint, the theme and the outline, mid-motion on the plan where it is; a lost
    /// mask comes back at the next check; a tint that clears fades on the render server and then hides, nothing left on
    /// its layers.
    @Test func blacksEdgeComesAndGoesAndFadesToNothing() async throws {
        _ = NSApplication.shared
        let rig = await IslandGlassTests.rig(.coreAnimation, theme: .black)
        let canvas = rig.canvas
        canvas.setStateTint(true)
        canvas.setTheme(.glass)
        #expect(canvas.edgeLayers == nil, "Glass's tint is its veil")
        rig.open()
        canvas.setTheme(.black)
        let edge = try #require(canvas.edgeLayers)
        let playing = try #require(edge.mask.animation(forKey: IslandSurfaceLayers.key))
        let clip = try #require(canvas.layers.clip.animation(forKey: IslandSurfaceLayers.key))
        #expect(abs(playing.beginTime - clip.beginTime) < 0.001 && playing.duration == clip.duration, "in mid-open, on the plan")
        await FramePerf.wait(1.6)
        #expect(edge.mask.path == canvas.layers.fill.path)
        // A lost mask: the next check puts it back.
        edge.host.mask = nil
        edge.light.mask = nil
        let repairs = canvas.repairs
        #expect(canvas.ensure() && canvas.repairs > repairs && edge.isSound)
        // A finish's green, then none: it fades, then hides, with nothing left on its layers.
        edge.show(.finished)
        #expect(edge.light.animation(forKey: "tint") != nil && !edge.host.isHidden)
        edge.show(nil)
        await FramePerf.wait(StateTint.finished.fadeOut() * 0.5)
        #expect(!edge.host.isHidden, "still fading")
        #expect(await Self.within(StateTint.finished.fadeOut() + 2) { edge.host.isHidden && edge.light.animationKeys() == nil }, "faded, then hidden")
        // Off, and SwiftUI's outline: gone, nothing of it left.
        canvas.setStateTint(false)
        #expect(canvas.edgeLayers == nil && edge.host.superlayer == nil && canvas.layers.edge == nil)
        canvas.setStateTint(true)
        let again = try #require(canvas.edgeLayers)
        canvas.setOutline(.swiftUI)
        #expect(canvas.edgeLayers == nil && again.host.superlayer == nil)
        rig.stop()
    }

    /// Glass's rim's light on Core Animation's outline: inside the rim's own mask (a sublayer of its light, masked by
    /// the outline's line), placed at the spot (y up), following it eased from where it is (at once under Reduce Motion),
    /// fading out when the pointer leaves and then hidden with nothing left on it. Black and Smoke have none.
    @Test func glasssRimCatchesTheLightOnCoreAnimationsOutline() async throws {
        _ = NSApplication.shared
        let rig = await IslandGlassTests.rig(.coreAnimation, theme: .glass)
        let glass = try #require(rig.canvas.glassView)
        #expect(glass.backdrop == .rimOnly && glass.lightLayer.superlayer === glass.lightHost && glass.lightHost.superlayer === glass.rimLayer)
        #expect(glass.rimLayer.mask === glass.rimStroke && glass.lightHost.mask != nil && glass.lightHost.frame == glass.bounds)
        #expect(!glass.isLit && glass.lightLayer.isHidden)
        let spot = IslandRimLight.Spot(centre: CGPoint(x: 220, y: 30), radius: 80)
        rig.canvas.setRimLight(spot)
        #expect(glass.isLit && glass.lightLayer.position == CGPoint(x: 220, y: glass.bounds.height - 30))
        #expect(glass.lightLayer.bounds.size == CGSize(width: 160, height: 160) && glass.lightLayer.type == .radial)
        rig.canvas.setRimLight(.init(centre: CGPoint(x: 280, y: 30), radius: 80))
        #expect(glass.lightLayer.animation(forKey: "follow.position") != nil, "eased from where it is")
        #expect(await Self.within(2) { glass.lightLayer.animationKeys() == nil }, "swept once played")
        glass.setRimLight(.init(centre: CGPoint(x: 320, y: 30), radius: 80), reduceMotion: true)
        #expect(glass.lightLayer.animation(forKey: "follow.position") == nil && glass.lightLayer.position.x == 320, "Reduce Motion: at once")
        rig.canvas.setRimLight(nil)
        #expect(!glass.isLit && glass.lightLayer.animation(forKey: "fade") != nil)
        #expect(await Self.within(2) { glass.lightLayer.isHidden && glass.lightLayer.animationKeys() == nil }, "faded, then hidden")
        rig.stop()
        for theme in [JuiceTheme.black, .smoke] {
            let other = await IslandGlassTests.rig(.coreAnimation, theme: theme)
            other.canvas.setRimLight(spot)
            #expect(other.canvas.glassView?.isLit != true && other.canvas.glassView?.lightHost.superlayer == nil)
            other.stop()
        }
    }
}

final class LookBox {
    var tint: Bool?
    var frost: Double?
}

/// Records State tint and Frost as it is drawn in them.
private struct LookProbe: View {
    let box: LookBox
    @Environment(\.islandStateTint) private var tint
    @Environment(\.glassFrost) private var frost

    var body: some View {
        box.tint = tint
        box.frost = frost
        return Color.clear
    }
}
