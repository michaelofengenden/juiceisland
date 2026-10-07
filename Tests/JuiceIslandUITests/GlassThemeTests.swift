import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Theme Glass without black (P560 to P566): the island, the panel and the widget in the system's glass with no floor,
/// plate, shade or dark fill of ours; their ink in twins for the glass's light and dark looks, holding on each look's
/// worst surface (`GlassContrast.worstAdapted`); the state and agent colours keeping their hue; the stand-in's model; and
/// the island's glass inside its outline in both engines. The live glass is the window server's and cannot be seen
/// headless (P565).
@MainActor
@Suite(.serialized)
struct GlassThemeTests {
    typealias C = GlassContrast

    static let schemes: [ColorScheme] = [.light, .dark]
    static let p = IslandPalette.glass

    /// Text tokens, by name (the island's, the cards', the message's, the panel's).
    static var text: [(String, Color)] {
        let p = p, q = PanelPalette.glass
        return [("ink", p.ink), ("ink2", p.ink2), ("ink3", p.ink3), ("statusClean", p.statusClean), ("statusDetailed", p.statusDetailed),
                ("you", p.you), ("rowAge", p.rowAge), ("toolVerb", p.toolVerb), ("toolLine", p.toolLine), ("jump", p.jump),
                ("footer", p.footer), ("footerHover", p.footerHover), ("message", p.message), ("groupCount", p.groupCount),
                ("kbd", p.kbd), ("fieldPlaceholder", p.fieldPlaceholder), ("codeText", p.codeText), ("codeComment", p.codeComment),
                ("sendText", p.sendText), ("headerIcon", p.headerIcon), ("tagHost", p.tagHost.fg), ("tagTime", p.tagTime.fg),
                ("tagJump", p.tagJump.fg), ("optionBadgeText", p.optionBadgeText), ("optionSub", p.optionSub), ("cardKbd", p.cardKbd),
                ("reason", p.reason), ("diffContext", p.diffContext), ("optionTitle", p.optionTitle), ("link", p.link),
                ("messageHeader", p.messageHeader), ("diffAdded", p.diffAdded), ("diffRemoved", p.diffRemoved),
                ("pillCount", p.pillCount), ("panel.ink", q.ink), ("panel.ink2", q.ink2)]
    }

    /// Marks: the quiet greys, the outline, and every state and agent colour as Glass draws them (`tone`).
    static var marks: [(String, Color)] {
        let p = p
        let colours: [(String, Color)] = NeedsYouColourTests.colours + [
            ("run", IslandTheme.run), ("done", IslandTheme.done), ("delegate", IslandTheme.delegate), ("stalled", IslandTheme.stalled),
            ("agentClaude", IslandTheme.agentClaude), ("agentCodex", IslandTheme.agentCodex), ("agentClaudeRunning", IslandTheme.agentClaudeRunning),
            ("brand", IslandTheme.brand), ("warn", Theme.warn), ("attention", Theme.attention), ("claudeMark", Theme.claudeMark),
            ("codexMark", Theme.codexMark), ("neutral", AgentLook.neutral),
        ]
        return [("idleMark", p.idleMark), ("headerIconRest", p.headerIconRest), ("optionChevron", p.optionChevron),
                ("topBarIdle", p.topBarIdle), ("panel.line", PanelPalette.glass.line)] + colours.map { ($0.0, p.tone($0.1)) }
    }

    /// The words the states and agents colour (status words, amounts, the Codex group's name), as Glass draws them.
    static var words: [(String, Color)] {
        (NeedsYouColour.allCases.map { ("approval \($0)", $0.wait) }
            + [("done", IslandTheme.done), ("stalled", IslandTheme.stalled), ("agentCodex", IslandTheme.agentCodex),
               ("warn", Theme.warn), ("attention", Theme.attention), ("delegate", IslandTheme.delegate), ("amber", HookDriftLine.amber)])
            .map { ($0.0, p.toneText($0.1)) }
    }

    // MARK: Legibility, worked out (P562)

    /// Every Glass ink holds on each look's worst surface, bare and on a hover or card veil: text 4.5:1 (4:1 on a veil),
    /// marks 3:1; the ratios are printed for the report.
    @Test func everyGlassInkHoldsOnBothLooks() {
        var lines: [String] = []
        for scheme in Self.schemes {
            var lowest: [(String, Double)] = []
            for (name, colour) in Self.text + Self.words {
                let bare = C.worstAdaptedRatio(colour, scheme)
                #expect(bare >= C.text, "\(scheme) \(name): \(bare)")
                for fill in GlassVeil.judged {
                    #expect(C.worstAdaptedRatio(colour, scheme, fills: [fill]) >= C.textOnFill, "\(scheme) \(name) on a veil")
                }
                lowest.append((name, bare))
            }
            for (name, colour) in Self.marks {
                let bare = C.worstAdaptedRatio(colour, scheme)
                #expect(bare >= C.mark, "\(scheme) \(name): \(bare)")
                #expect(C.worstAdaptedRatio(colour, scheme, fills: [Self.p.islandHover]) >= C.mark, "\(scheme) \(name) on a hover")
                lowest.append(("mark " + name, bare))
            }
            lines.append("\(scheme): " + lowest.sorted { $0.1 < $1.1 }.map { "\($0.0) \(String(format: "%.2f", $0.1))" }.joined(separator: ", "))
        }
        print("glass inks on each look's worst surface:\n" + lines.joined(separator: "\n"))
    }

    /// The cards' text on the fill it sits on, in each look (as `IslandGlassContrastTests` checks Smoke's).
    @Test func theCardsInksHoldOnTheirVeils() {
        let p = Self.p
        let onFills: [(String, Color, [Color])] = [
            ("optionBadgeText", p.optionBadgeText, [p.optionBadge]), ("optionSub", p.optionSub, [p.optionBg]),
            ("optionSub selected", p.optionSub, [p.optionSelected]), ("optionSub hovered", p.optionSub, [p.rowHover, p.optionHover]),
            ("cardKbd on a button", p.cardKbd, [p.button]), ("reason hovered", p.reason, [p.rowHover]),
            ("diffContext", p.diffContext, [p.codeBg]), ("ink on a hovered button", p.ink, [p.buttonHover]),
            ("code in a Done card's box", p.codeText, [p.codeBg, p.messageCodeBox]), ("a table's header", p.messageHeader, [p.codeBg]),
            ("a link", p.link, [p.codeBg]), ("diffAdded", p.diffAdded, [p.diffAddedFill]), ("diffRemoved", p.diffRemoved, [p.diffRemovedFill]),
            ("a tag", p.tagHost.fg, [p.tagHost.bg]), ("the jump tag", p.tagJump.fg, [p.tagJump.bg]),
            ("the field's placeholder", p.fieldPlaceholder, [p.fieldHoverBg]),
        ]
        for scheme in Self.schemes {
            for (name, colour, fills) in onFills {
                let ratio = C.worstAdaptedRatio(colour, scheme, fills: fills)
                #expect(ratio >= C.textOnFill, "\(scheme) \(name): \(ratio)")
            }
            // The primary and send buttons stay light in both looks, their titles dark: 4.5:1 on their own fill.
            for (name, ink, fill) in [("primary", p.primaryText, p.primary), ("primary hovered", p.primaryText, p.primaryHover),
                                      ("send", p.sendActiveInk, p.sendActive), ("key on primary", p.kbdOnPrimary, p.primary),
                                      ("a picked option's number", p.optionBadgeSelectedText, p.optionBadgeSelected(.pink)),
                                      ("a picked option's number", p.optionBadgeSelectedText, p.optionBadgeSelected(.violet)),
                                      ("a picked option's number", p.optionBadgeSelectedText, p.optionBadgeSelected(.orange))] {
                let ratio = C.ratio(C.luminance(ink, scheme), C.luminance(fill, scheme))
                #expect(ratio >= (name == "key on primary" ? C.mark : name == "a picked option's number" ? C.textOnFill : C.text),
                        "\(scheme) \(name): \(ratio)")
            }
        }
    }

    /// The greys keep Black's order in the dark look, and its mirror in the light one, so the hierarchy reads the same.
    @Test func theGreysKeepBlacksOrderInBothLooks() {
        let order: [(IslandPalette) -> Color] = [\.ink3, \.ink2, \.statusClean, \.statusDetailed, \.message, \.ink]
        let dark = order.map { C.luminance($0(Self.p), .dark) }, light = order.map { C.luminance($0(Self.p), .light) }
        #expect(dark == dark.sorted(), "\(dark)")
        #expect(light == light.sorted(by: >), "\(light)")
    }

    /// A state's or an agent's colour keeps its hue on Glass: only its lightness moves, and only where the pair fails; a
    /// colour that holds already is itself (Black and Smoke never nudge).
    @Test func theStateAndAgentColoursKeepTheirHue() {
        let colours = NeedsYouColourTests.colours.map(\.1) + [IslandTheme.run, IslandTheme.done, IslandTheme.delegate, IslandTheme.agentClaude,
                       IslandTheme.agentCodex, IslandTheme.agentClaudeRunning, IslandTheme.stalled, Theme.warn, Theme.attention]
        var report: [String] = []
        for colour in colours {
            let c = C.components(colour)
            let (h, s, _) = GlassTone.hsl(c.r, c.g, c.b)
            var line = String(format: "#%02X%02X%02X", Int(c.r * 255 + 0.5), Int(c.g * 255 + 0.5), Int(c.b * 255 + 0.5))
            for scheme in Self.schemes {
                for use in [GlassTone.Use.mark, .text] {
                    let nudged = GlassTone.nudged(colour, scheme, use), n = C.components(nudged)
                    let (nh, ns, _) = GlassTone.hsl(n.r, n.g, n.b)
                    #expect(min(abs(nh - h), 1 - abs(nh - h)) < 0.01 && abs(ns - s) < 0.02, "\(scheme) \(use): hue or saturation moved")
                    if GlassTone.holds(C.luminance(colour), scheme, use) { #expect(nudged == colour, "\(scheme) \(use): nudged but held") }
                    if use == .mark {
                        line += String(format: " %@ #%02X%02X%02X %.2f", scheme == .dark ? "dark" : "light", Int(n.r * 255 + 0.5),
                                       Int(n.g * 255 + 0.5), Int(n.b * 255 + 0.5), C.worstAdaptedRatio(nudged, scheme))
                    }
                }
            }
            report.append(line)
        }
        print("state and agent colours on Glass (as is, then each look's twin and its ratio):\n" + report.joined(separator: "\n"))
    }

    // MARK: No black anywhere (P560, P563)

    /// Glass's palettes lay no black: no surface colour, no opaque or dark fill; every fill is a veil (under a fifth
    /// opaque, white where the glass is dark and the ink where it is light), and a cover, a cut or a fade that painted
    /// the black paints nothing.
    @Test func glassLaysNoBlack() {
        let p = Self.p, q = PanelPalette.glass
        #expect(C.components(p.bg).a == 0 && C.components(q.surface).a == 0)
        let fills = [p.card, p.islandHover, p.rowHover, p.button, p.codeBg, p.fieldBg, p.fieldHoverBg, p.groupBg, p.send, p.buttonHover,
                     p.sendHover, p.optionBg, p.optionHover, p.optionSelected, p.optionBadge, p.messageCodeBox, p.tagHost.bg, p.tagTime.bg,
                     p.line, p.usageHairline, p.rowHoverStroke, p.codeBorder, p.fieldBorder, p.messageRule, q.track, q.divider]
        for (index, fill) in fills.enumerated() {
            let dark = C.components(fill, .dark), light = C.components(fill, .light)
            #expect(dark.a < 0.2 && dark.r > 0.99 && dark.g > 0.99 && dark.b > 0.99, "fill \(index) on the dark look: \(dark)")
            #expect(light.a < 0.2, "fill \(index) on the light look: \(light)")
        }
        // The keys: Black's light grey on the dark look, the running blue on the light one; never a dark plate.
        for fill in [p.primary, p.primaryHover, p.sendActive] {
            let light = C.components(fill, .light), (h, s, _) = GlassTone.hsl(light.r, light.g, light.b)
            let run = C.components(IslandTheme.run), (rh, _, _) = GlassTone.hsl(run.r, run.g, run.b)
            #expect(abs(h - rh) < 0.01 && s > 0.5 && C.luminance(fill, .light) > 0.05, "the light key is the running blue")
            #expect(C.luminance(fill, .dark) > 0.7)
        }
    }

    /// The closed pill in Glass over a white window is the light glass all the way to the hardware notch: no plate, no
    /// shade, no floor. Only the notch drawn over it is black; Smoke's wings are black there.
    @Test func thePillsWingsAreGlassUpToTheNotch() throws {
        let env = IslandGlassRenders.environment()
        let ui = IslandGlassRenders.state(env)
        let size = IslandGlassRenders.pillSize, notch = IslandGlassRenders.notch
        func darkest(_ theme: JuiceTheme) throws -> Double {
            let pixels = try ThemeTests.pixels(IslandGlassRenders.scene(ui, size: size, backdrop: .white, theme: theme).environment(env), size: size)
            // The pill's wings beside the notch, at the notch's middle height: the surface itself (no glyph or count there).
            var darkest = 1.0
            // Above the lead glyph and the count, beside the notch, where Smoke's plate and shade are darkest.
            let y = 2 * 3
            for x in stride(from: Int(2 * (size.width / 2 - notch.width / 2 - 10)), to: Int(2 * (size.width / 2 - notch.width / 2 - 2)), by: 1) {
                let p = pixels.rgba(x, y)
                darkest = min(darkest, C.luminance(r: p.r, g: p.g, b: p.b))
            }
            return darkest
        }
        let glass = try darkest(.glass), smoke = try darkest(.smoke)
        #expect(glass >= C.worstAdapted(.light) - 0.02, "Glass's wing beside the notch: \(glass)")
        #expect(smoke < 0.01, "Smoke's wing beside the notch is its plate's black: \(smoke)")
    }

    /// The whole opened island in Glass over a white window: nothing of its surface is darker than the light look's
    /// bound (the text and marks aside), so no black plate, card, peek or fade lies anywhere on it.
    @Test func theOpenedIslandOverWhiteHasNoDarkPlate() throws {
        let env = IslandGlassRenders.environment()
        for (name, ui) in [("open", IslandGlassRenders.state(env, surface: .island)),
                           ("card", IslandGlassRenders.state(env, surface: .island, card: FixtureSessionFeed.ID.codexDone,
                                                             events: [(0, .present(.card(sessionID: FixtureSessionFeed.ID.codexDone)))], at: 1.5))] {
            let size = CGSize(width: 540, height: 330), geometry = ui.live.surface.value
            let pixels = try ThemeTests.pixels(IslandGlassRenders.scene(ui, size: size, backdrop: .white, theme: .glass).environment(env), size: size)
            // The island's inside, 6 pt clear of the rim, below the notch: count the pixels darker than the light glass's
            // veils allow that are not text or marks (a text's stroke is a few pixels wide; a plate is a grey block; a
            // glyph in its state's colour, solid on Glass's light look, P591, is no plate).
            let left = size.width / 2 - geometry.left + geometry.ear + 6, right = size.width / 2 + geometry.right - geometry.ear - 6
            let floor = C.worstAdapted(.light, fills: [Self.p.buttonHover]) - 0.02
            var blocks = 0
            for y in stride(from: Int(2 * 40), to: Int(2 * (geometry.height - 8)) - 8, by: 4) {
                for x in stride(from: Int(2 * left), to: Int(2 * right) - 8, by: 4) {
                    // A 4 × 4 point block, every pixel of it dark and grey: a plate, not a letter or a glyph.
                    var dark = true
                    for dy in 0..<8 where dark { for dx in 0..<8 where dark {
                        let p = pixels.rgba(x + dx, y + dy)
                        if C.luminance(r: p.r, g: p.g, b: p.b) >= floor || max(p.r, p.g, p.b) - min(p.r, p.g, p.b) > 0.12 { dark = false }
                    } }
                    if dark { blocks += 1 }
                }
            }
            print("\(name): \(blocks) dark 4-point blocks on the light glass")
            #expect(blocks < 4, "\(name): \(blocks) dark blocks on the light glass")
        }
    }

    // MARK: The stand-in's model (P565)

    /// The stand-in's glass stays in its look's bounds on every judged backdrop: nothing brighter than the dark look's
    /// ceiling, nothing darker than the light look's floor; darker (lighter) parts come through as they are.
    @Test func theStandInKeepsEachLookInItsBounds() throws {
        let size = CGSize(width: 300, height: 120)
        var style = GlassStyle.island.clear
        style.glassFollowsShape = true
        for backdrop in GlassBackdrop.judged + [.preview] {
            for scheme in Self.schemes {
                for contrast in [ColorSchemeContrast.standard, .increased] {
                    let view = GlassStage(backdrop: backdrop) {
                        GlassAdaptedStandIn(shape: Rectangle(), style: style, adaptation: scheme, reduceTransparency: false, contrast: contrast)
                            .frame(width: size.width, height: size.height)
                    }
                    let pixels = try ThemeTests.pixels(view, size: size)
                    let bound = C.worstAdapted(scheme, contrast: contrast)
                    var brightest = 0.0, darkest = 1.0
                    for y in stride(from: 8, to: pixels.height - 8, by: 2) {
                        for x in stride(from: 8, to: pixels.width - 8, by: 2) {
                            let p = pixels.rgba(x, y)
                            let l = C.luminance(r: p.r, g: p.g, b: p.b)
                            brightest = max(brightest, l)
                            darkest = min(darkest, l)
                        }
                    }
                    if scheme == .dark {
                        #expect(brightest <= bound + 0.01, "\(backdrop) dark \(contrast): \(brightest) over \(bound)")
                    } else {
                        #expect(darkest >= bound - 0.03, "\(backdrop) light \(contrast): \(darkest) under \(bound)")
                    }
                }
            }
        }
        // Over the black desktop the dark look is the desktop's black, over the white window the light look is white:
        // the glass adds nothing of its own there.
        #expect(GlassAdaptedBackdrop.shift(Self.flat(0), adaptation: .dark, contrast: .standard).map(Self.first) == 0)
        #expect(GlassAdaptedBackdrop.shift(Self.flat(255), adaptation: .light, contrast: .standard).map(Self.first) == 255)
    }

    static func flat(_ grey: UInt8) -> CGImage {
        var pixels = [UInt8](repeating: grey, count: 4 * 4 * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let context = CGContext(data: &pixels, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    static func first(_ image: CGImage) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[0]
    }

    /// Reduce Transparency and Increase Contrast are the system's own on Glass (P563), stood in for: the frostier opaque
    /// ground of the look, and the stronger shift with the even rim; never Smoke's black floor.
    @Test func accessibilityIsTheSystemsOwnNeverOurFloor() throws {
        var style = GlassStyle.island.clear
        style.glassFollowsShape = true
        #expect(style.floor == 0 && style.floorIncreased == 0 && style.adaptive)
        let size = CGSize(width: 120, height: 60)
        for scheme in Self.schemes {
            let view = GlassStage(backdrop: .busy) {
                GlassAdaptedStandIn(shape: Rectangle(), style: style, adaptation: scheme, reduceTransparency: true, contrast: .standard)
                    .frame(width: size.width, height: size.height)
            }
            let centre = try ThemeTests.pixels(view, size: size).rgba(120, 60)
            let solid = C.components(scheme == .dark ? GlassAdapted.solidDark : GlassAdapted.solidLight)
            #expect(centre.a == 1 && abs(centre.r - solid.r) < 0.01, "\(scheme): \(centre)")
        }
        #expect(C.worstAdapted(.dark, contrast: .increased) < C.worstAdapted(.dark))
        #expect(C.worstAdapted(.light, contrast: .increased) > C.worstAdapted(.light))
        #expect(style.edge(.increased).top == style.edge(.increased).bottom)
        // Live, the glass is the system's: `inGlass` lays nothing of ours under Reduce Transparency or Increase Contrast.
        let source = try String(contentsOf: RenderHarness.root.appendingPathComponent("App/Theme/GlassSurface.swift"), encoding: .utf8)
        let live = try #require(source.range(of: "case .live:\n            // The system's regular glass"))
        let rest = source[live.upperBound...].prefix(600)
        #expect(rest.contains(".glassEffect(.regular, in: shape)") && !rest.contains("floor") && !rest.contains("solid"))
    }

    // MARK: The island in both outline engines (P523, P565)

    /// Core Animation's outline in Glass: no black under the content (the black's fill clear), no glass or floor of
    /// ours (the content carries the system's glass), the rim alone over the content on the plan, masked by the model's
    /// outline at rest closed and open, with no notch plate or shade; nothing animating at rest.
    @Test func coreAnimationsGlassIsTheRimOverTheContent() async throws {
        _ = NSApplication.shared
        let rig = await IslandGlassTests.rig(.coreAnimation, theme: .glass)
        let canvas = rig.canvas
        let rim = try #require(canvas.glassView)
        let masked = try #require(canvas.maskedView)
        let views = try #require(rig.window.contentView?.subviews)
        #expect(rim.backdrop == .rimOnly && rim.effectView == nil && rim.floorLayer.fillColor == nil)
        #expect(views.firstIndex(of: masked)! < views.firstIndex(of: rim)!, "the rim over the content")
        #expect(canvas.layers.fill.fillColor == nil)
        #expect((rim.marksLayer.sublayers ?? []).isEmpty, "no notch plate, no shade")
        for step in [{}, { rig.open() }] as [@MainActor () -> Void] {
            step()
            await FramePerf.wait(1.6)
            let rest = rig.director.model.restGeometry
            #expect(rim.maskLayer.path == canvas.layers.path(rest, yDown: false))
            let outside = IslandGlassTests.maskOutside(rim, canvas: IslandGlassTests.canvasSize, expected: rest)
            #expect(outside.outside == 0 && outside.inside > 1000, "\(outside)")
            #expect(rim.pathLayers.allSatisfy { $0.animationKeys() == nil })
        }
        // Smoke and Glass trade places at rest: the glass is made again, on the outline.
        canvas.setTheme(.smoke)
        let smoke = try #require(canvas.glassView)
        #expect(smoke.backdrop != .rimOnly && rim.superview == nil && smoke.floorLayer.fillColor != nil)
        canvas.setTheme(.glass)
        let again = try #require(canvas.glassView)
        #expect(again.backdrop == .rimOnly && smoke.superview == nil && again.isSound)
        #expect(again.maskLayer.path == canvas.layers.path(rig.director.model.restGeometry, yDown: false))
        canvas.setTheme(.black)
        #expect(canvas.glassView == nil && canvas.layers.fill.fillColor == CGColor(gray: 0, alpha: 1))
        rig.stop()
    }

    /// Core Animation's outline in Glass draws the pill's edge line (its own canvas) and the rim (its view over the
    /// content) outside the glass, so each takes the look the glass hands its content, as the glyph and the count do and
    /// as SwiftUI's outline draws them, never the window's appearance (P568). Headless the glass hands its content the
    /// main hosting view's appearance, which stands in for the look, against a window in the other one, both ways.
    @Test(arguments: [ColorScheme.dark, .light])
    func coreAnimationsEdgeLineAndRimTakeTheGlasssLook(_ look: ColorScheme) async throws {
        _ = NSApplication.shared
        let other: ColorScheme = look == .dark ? .light : .dark
        func appearance(_ scheme: ColorScheme) -> NSAppearance? { NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) }
        let rig = FramePerf.IslandRig(style: .clean, glyph: .liquid, glyphsMove: false, outline: .coreAnimation, theme: .glass)
        rig.window.appearance = appearance(other)
        rig.host.appearance = appearance(look)
        await rig.start()
        await FramePerf.wait(0.3)
        let rim = try #require(rig.canvas.glassView), rimHost = try #require(rig.canvas.rimHost)
        #expect(rim.backdrop == .rimOnly)
        // The rim's light: white on the dark look, the ink at half strength on the light (`GlassAdapted.rimColour`).
        let light = try #require((rim.rimLayer.colors?.first).map { $0 as! CGColor }?.components)
        #expect(look == .dark ? light[0] > 0.99 : light[0] < 0.2, "\(look): the rim's light \(light)")
        // The edge line: its body (the darkest of its opaque pixels; its light only brightens it) is its colour's twin
        // for the look, not the window's.
        let pill = rig.ui.pill
        #expect(pill.showsEdgeLine)
        let colour = Self.p.tone(pill.edgeColour)
        let want = C.luminance(colour, look), not = C.luminance(colour, other)
        let rep = try #require(rimHost.bitmapImageRepForCachingDisplay(in: rimHost.bounds))
        rimHost.cacheDisplay(in: rimHost.bounds, to: rep)
        var body = 1.0, drawn = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.95 else { continue }
                body = min(body, C.luminance(r: c.redComponent, g: c.greenComponent, b: c.blueComponent))
                drawn += 1
            }
        }
        print("clear glass, Core Animation's edge line in the \(look) look: body \(body), its twin \(want), the other's \(not)")
        #expect(drawn > 20 && abs(body - want) < abs(body - not), "\(look): body \(body), its twin \(want), the other's \(not)")
        rig.stop()
    }

    /// SwiftUI's outline in Glass: nothing drawn beyond the outline at rest, closed and open, and in every frame of an
    /// open and a close, in both motion tunings (the content and its rim; the glass itself draws nothing offscreen).
    @Test(arguments: [MotionTuning(), MotionTuning(motion: .refined, hover: .quick)])
    func swiftUIsGlassStaysInside(_ tuning: MotionTuning) async throws {
        _ = NSApplication.shared
        let rig = await IslandGlassTests.rig(.swiftUI, theme: .glass, tuning: tuning)
        var worstOutside = 0, frames = 0
        func look() throws {
            guard let geometry = rig.outlines.paths.last?.geometry, geometry.height > 4, geometry.width > 40 else { return }
            let bitmap = try IslandGlassTests.snapshot(rig)
            let result = IslandGlassTests.inspect(bitmap, canvas: IslandGlassTests.canvasSize, hostOrigin: rig.host.frame.origin,
                                                  windowHeight: rig.window.contentView?.bounds.height ?? 0, geometry: geometry)
            worstOutside = max(worstOutside, result.outside)
            frames += 1
        }
        try look()
        rig.open()
        for _ in 0..<14 {
            await FramePerf.wait(0.03)
            try look()
        }
        await FramePerf.wait(1.2)
        try look()
        rig.director.send(.close(.fold))
        for _ in 0..<12 {
            await FramePerf.wait(0.03)
            try look()
        }
        print("clear glass, SwiftUI's outline, \(tuning.motion): \(frames) frames, outside \(worstOutside) px")
        #expect(frames > 10 && worstOutside == 0)
        rig.stop()
    }

    // MARK: The peek (P558)

    /// A peek's cover on Glass adds only its veil (the rows under it are not drawn there), in each look.
    @Test func aPeeksCoverOnGlassAddsOnlyItsVeil() throws {
        for scheme in Self.schemes {
            let ground = C.adapted(scheme)
            let fill = Self.p.islandHover
            let expected = C.over(fill, ground, scheme)
            let view = IslandGlassViewsTests.colour(ground).overlay(IslandCover(shape: Rectangle(), fill: fill))
                .environment(\.juiceTheme, .glass).environment(\.colorScheme, scheme)
            let c = try ThemeTests.pixels(view, size: CGSize(width: 40, height: 40)).rgba(40, 40)
            #expect(abs(c.r - expected.r) < 0.01 && abs(c.g - expected.g) < 0.01 && abs(c.b - expected.b) < 0.01, "\(scheme): \(c)")
        }
    }

    // MARK: The widget (P566, superseded by P1224)

    /// The widget takes no theme: whatever the island's theme, its container background is the owner's Widget background
    /// (`WidgetBackdrop`, P1401), Glass's material or Black's black, never a theme's plate.
    @Test func theWidgetTakesNoThemeOfItsOwn() throws {
        let size = CGSize(width: 160, height: 160), shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        for choice in WidgetBackgroundChoice.allCases {
            func drawn(_ theme: JuiceTheme) throws -> [UInt8] {
                // Over a red ground: an empty render's bytes are not read.
                try ThemeTests.pixels(ZStack { Color(red: 1, green: 0, blue: 0); WidgetBackdrop(choice: choice) }.environment(\.glassRendering, .live)
                    .frame(width: size.width, height: size.height).containerShape(shape).environment(\.juiceTheme, theme), size: size).data
            }
            let black = try drawn(.black)
            for theme in JuiceTheme.allCases { #expect(WidgetGlassRenders.alike(try drawn(theme), black), "\(choice) \(theme)") }
        }
    }
}
