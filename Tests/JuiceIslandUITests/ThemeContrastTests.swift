import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Legibility on Smoke's glass (P522; Glass's is `GlassThemeTests`): every Smoke token against the surface where it is brightest, worked out (the floor over a
/// white window) and measured (the stand-in drawn over the three judged backdrops: a white window, a black desktop, a
/// busy photo). Text keeps 4.5:1 on the surface and 4:1 on a hover or card fill; marks, and every state and agent
/// colour, 3:1. Black's own claims on the pure black hold as before.
@MainActor
struct ThemeContrastTests {
    typealias C = GlassContrast

    static let glass = IslandPalette.smoke

    /// Text tokens, by name.
    static var text: [(String, Color)] {
        let p = glass
        return [("ink", p.ink), ("ink2", p.ink2), ("ink3", p.ink3), ("statusClean", p.statusClean), ("statusDetailed", p.statusDetailed),
                ("you", p.you), ("rowAge", p.rowAge), ("toolVerb", p.toolVerb), ("toolLine", p.toolLine), ("jump", p.jump),
                ("footer", p.footer), ("footerHover", p.footerHover), ("message", p.message), ("groupCount", p.groupCount),
                ("kbd", p.kbd), ("fieldPlaceholder", p.fieldPlaceholder), ("sendText", p.sendText), ("headerIcon", p.headerIcon),
                ("tagHost", p.tagHost.fg), ("tagTime", p.tagTime.fg), ("tagJump", p.tagJump.fg),
                ("panel.ink", PanelPalette.smoke.ink), ("panel.ink2", PanelPalette.smoke.ink2)]
    }

    /// Marks, and the colours that say a state or an agent at a glance.
    static var marks: [(String, Color)] {
        NeedsYouColourTests.colours + [("idleMark", glass.idleMark), ("headerIconRest", glass.headerIconRest), ("run", IslandTheme.run),
         ("done", IslandTheme.done),
         ("delegate", IslandTheme.delegate), ("stalled", IslandTheme.stalled), ("agentClaude", IslandTheme.agentClaude),
         ("agentCodex", IslandTheme.agentCodex), ("agentClaudeRunning", IslandTheme.agentClaudeRunning), ("brand", IslandTheme.brand),
         ("warn", Theme.warn), ("attention", Theme.attention)]
    }

    @Test func everyGlassTokenHoldsOverAWhiteWindow() {
        let floor = GlassStyle.island.floor
        for (name, colour) in Self.text {
            #expect(C.worstRatio(colour, floor: floor) >= C.text, "\(name): \(C.worstRatio(colour, floor: floor))")
            for fill in [Self.glass.islandHover, Self.glass.rowHover, Self.glass.card] {
                #expect(C.worstRatio(colour, floor: floor, fills: [fill]) >= C.textOnFill, "\(name) on a fill")
            }
        }
        for (name, colour) in Self.marks {
            #expect(C.worstRatio(colour, floor: floor) >= C.mark, "\(name): \(C.worstRatio(colour, floor: floor))")
            #expect(C.worstRatio(colour, floor: floor, fills: [Self.glass.islandHover]) >= C.mark, "\(name) on a hover")
        }
        // The panel's glass has the same floor.
        #expect(GlassStyle.panel.floor >= GlassStyle.island.floor)
    }

    /// The glass greys keep Black's order, so the hierarchy reads the same.
    @Test func theGlassGreysKeepBlacksOrder() {
        let order: [(IslandPalette) -> Color] = [\.ink3, \.ink2, \.statusClean, \.statusDetailed, \.message, \.ink]
        for palette in [IslandPalette.black, .smoke] {
            let lums = order.map { C.luminance($0(palette)) }
            #expect(lums == lums.sorted(), "\(lums)")
        }
    }

    /// Measured: the stand-in over each judged backdrop, its brightest pixel inside the island (clear of the rim), against
    /// every token.
    @Test func everyGlassTokenHoldsOnTheThreeBackdrops() throws {
        let size = CGSize(width: 480, height: 200), rect = CGRect(x: 8, y: 0, width: 464, height: 180)
        var report: [String] = []
        for backdrop in GlassBackdrop.judged {
            let view = GlassStage(backdrop: backdrop) {
                Color.clear.frame(width: rect.width, height: rect.height).themedSurface(IslandShape())
                    .padding(.leading, rect.minX).padding(.top, rect.minY)
            }
            .environment(\.juiceTheme, .smoke)
            let pixels = try ThemeTests.pixels(view, size: size)
            // Inside the body, 4 pt clear of the rim and the shoulders.
            let inset = IslandTheme.Metrics.shoulder + 4
            var brightest = 0.0, darkest = 1.0
            for y in stride(from: Int(2 * (rect.minY + inset)), to: Int(2 * (rect.maxY - IslandTheme.Metrics.bottomRadius)), by: 1) {
                for x in stride(from: Int(2 * (rect.minX + inset)), to: Int(2 * (rect.maxX - inset)), by: 1) {
                    let p = pixels.rgba(x, y)
                    let l = C.luminance(r: p.r, g: p.g, b: p.b)
                    brightest = max(brightest, l)
                    darkest = min(darkest, l)
                }
            }
            report.append("\(backdrop): \(brightest)…\(darkest)")
            #expect(brightest <= C.worstSurface(floor: GlassStyle.island.floor) + 0.002, "\(backdrop) \(brightest)")
            for (name, colour) in Self.text {
                #expect(C.ratio(C.luminance(colour), brightest) >= C.text, "\(backdrop) \(name)")
            }
            for (name, colour) in Self.marks {
                #expect(C.ratio(C.luminance(colour), brightest) >= C.mark, "\(backdrop) \(name)")
            }
        }
        print("glass surface luminance (brightest…darkest):", report.joined(separator: "; "))
    }

    /// The panel's glass battery track reads as a well over a black desktop (where it is Black's own track again) and a
    /// white one, never vanishing into the surface.
    @Test func theGlassTrackShowsOnAnyDesktop() {
        let floor = GlassStyle.panel.floor, track = PanelPalette.smoke.track
        let blackTrack = C.ratio(C.luminance(Theme.track), C.luminance(Theme.surface))
        for backdrop in [(r: 0.0, g: 0.0, b: 0.0), (r: 1.0, g: 1.0, b: 1.0)] {
            let surface = C.surface(over: backdrop, floor: floor), well = C.over(track, surface)
            let ratio = C.ratio(C.luminance(r: well.r, g: well.g, b: well.b), C.luminance(r: surface.r, g: surface.g, b: surface.b))
            #expect(ratio >= 0.95 * blackTrack, "\(backdrop): \(ratio) against Black's \(blackTrack)")
        }
    }

    /// Black's documented contrasts hold (`IslandTheme`: ink3 4.5:1, idleMark 3:1 on the pure black).
    @Test func blacksOwnClaimsHold() {
        let black = C.luminance(IslandTheme.bg)
        #expect(C.ratio(C.luminance(IslandTheme.ink3), black) >= 4.5)
        #expect(C.ratio(C.luminance(IslandTheme.idleMark), black) >= 3)
        #expect(C.ratio(C.luminance(IslandTheme.delegate), black) >= 7)
    }
}
