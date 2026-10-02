import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The widget in the Smoke theme (spec §4.8, P540 to P545; Glass's, P566, in `GlassThemeTests`): its container background, what it never draws, the colours
/// it draws on its glass, and the system's own looks, where both themes draw the same.
@MainActor
@Suite(.serialized)
struct WidgetThemeTests {
    typealias C = GlassContrast

    static let now = DemoClock.now
    static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    /// Black's container background is today's, the pure black, pixel for pixel (P544).
    @Test func blacksBackgroundIsThePureBlack() throws {
        let size = CGSize(width: 120, height: 80)
        let before = try ThemeTests.pixels(IslandTheme.bg.clipShape(Self.shape).padding(4), size: size)
        let after = try ThemeTests.pixels(WidgetBackground().clipShape(Self.shape).padding(4).environment(\.juiceTheme, .black), size: size)
        #expect(before.data == after.data)
        let glass = try ThemeTests.pixels(WidgetBackground().clipShape(Self.shape).padding(4).environment(\.juiceTheme, .smoke), size: size)
        #expect(glass.data != before.data, "Glass draws its own background")
    }

    /// Live, Glass is the floor and the rim and nothing else: translucent, so what the system puts under a widget shows
    /// through the 18 % the floor leaves; its rim lit from above; nothing past the widget's rounded corners (P540, P541).
    @Test func glassIsATranslucentFloorAndARimInTheWidgetsShape() throws {
        let size = CGSize(width: 160, height: 160)
        func pixels(_ reduce: Bool = false, _ contrast: ColorSchemeContrast = .standard) throws -> ThemeTests.Pixels {
            try ThemeTests.pixels(WidgetSmokeBody(rendering: .live, reduceTransparency: reduce, contrast: contrast)
                .frame(width: size.width, height: size.height).containerShape(Self.shape), size: size)
        }
        let live = try pixels()
        let centre = live.rgba(160, 160)
        #expect(abs(centre.a - WidgetSmokeBody.style.floor) < 0.01, "\(centre)")
        #expect(centre.r < 0.01 && centre.g < 0.01 && centre.b < 0.01)
        // The rim: brighter at the top edge than at the bottom one, both brighter than the floor.
        let top = live.rgba(160, 1), bottom = live.rgba(160, 318)
        #expect(top.r * top.a > bottom.r * bottom.a && bottom.r * bottom.a > centre.r * centre.a, "\(top) \(bottom)")
        // The corners, outside the rounded shape, are untouched.
        #expect(live.rgba(1, 1).a == 0 && live.rgba(318, 318).a == 0)
        // Reduce Transparency: the opaque solid. Increase Contrast: the heavier floor.
        let solid = try pixels(true).rgba(160, 160), expected = C.components(WidgetSmokeBody.style.solid)
        #expect(solid.a == 1 && abs(solid.r - expected.r) < 0.01)
        #expect(abs(try pixels(false, .increased).rgba(160, 160).a - WidgetSmokeBody.style.floorIncreased) < 0.01)
    }

    /// WidgetKit composites no glass in a widget: nothing under `App/Widget` asks for the system's glass or the island's
    /// glass surface, whose live path is `glassEffect` (P540).
    @Test func theWidgetNeverAsksForGlassWidgetKitCannotDraw() throws {
        let folder = RenderHarness.root.appendingPathComponent("App/Widget")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count >= 5)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for call in ["glassEffect(", "GlassEffectContainer", "NSGlassEffectView", "NSVisualEffectView", "GlassSurface(", "GlassSurfaceBody(",
                         "themedSurface(", "glassSurface(", "Material", "widgetTexture("] {
                #expect(!source.contains(call), "\(file.lastPathComponent): \(call)")
            }
        }
    }

    // MARK: Legibility (P543)

    /// Text the widget draws in full colour on Glass: titles, the idle and "N more" greys, a request's detail, and the
    /// needs-you colour of its word, each choice of it.
    static var text: [(String, Color)] {
        let p = IslandPalette.smoke
        return [("title", p.ink), ("idle", p.ink3), ("more", p.footer), ("detail", p.statusClean)]
            + NeedsYouColour.allCases.map { ("word \($0)", $0.wait) }
    }

    /// Marks: the glyphs by state and by agent, the agents' and providers' marks, the mini batteries' ink, outline and
    /// low amber.
    static var marks: [(String, Color)] {
        let panel = PanelPalette.smoke
        var marks: [(String, Color)] = NeedsYouColourTests.colours + [("run", IslandTheme.run), ("delegate", IslandTheme.delegate),
                                        ("agentClaude", IslandTheme.agentClaude), ("agentCodex", IslandTheme.agentCodex),
                                        ("claudeRunning", IslandTheme.agentClaudeRunning), ("neutral", AgentLook.neutral),
                                        ("claudeMark", Theme.claudeMark), ("codexMark", Theme.codexMark), ("brand", IslandTheme.brand),
                                        ("battery.ink", panel.ink), ("battery.line", panel.line), ("battery.low", Theme.warn)]
        for agent in [GlyphPalette.Agent.claude, .codex] {
            for state in [GlyphPalette.State.running, .waiting, .delegating] {
                for mode in GlyphColourMode.allCases {
                    for needsYou in NeedsYouColour.allCases {
                        marks.append(("glyph \(agent) \(state) \(mode) \(needsYou)",
                                      GlyphPalette.colour(agent: agent, state: state, mode: mode, needsYou: needsYou)))
                    }
                }
            }
        }
        return marks
    }

    /// Worked out: on the widget's floor over a white wallpaper, where the glass is brightest.
    @Test func everyColourHoldsOnTheGlassOverAWhiteWallpaper() {
        let floor = WidgetSmokeBody.style.floor
        for (name, colour) in Self.text {
            #expect(C.worstRatio(colour, floor: floor) >= C.text, "\(name): \(C.worstRatio(colour, floor: floor))")
        }
        for (name, colour) in Self.marks {
            #expect(C.worstRatio(colour, floor: floor) >= C.mark, "\(name): \(C.worstRatio(colour, floor: floor))")
        }
        let ratios = (Self.text + Self.marks).map { ($0.0, C.worstRatio($0.1, floor: floor)) }.sorted { $0.1 < $1.1 }
        print("widget glass over white:", ratios.map { "\($0.0) \(String(format: "%.2f", $0.1))" }.joined(separator: ", "))
    }

    /// Measured: the stand-in over a white wallpaper, a black one and a busy photo, its brightest pixel inside the
    /// widget (clear of the rim) against every colour.
    @Test func everyColourHoldsOnTheThreeBackdrops() throws {
        let size = CGSize(width: 240, height: 200), inner = CGRect(x: 20, y: 20, width: 200, height: 160)
        var report: [String] = []
        for backdrop in GlassBackdrop.judged {
            let view = GlassStage(backdrop: backdrop) {
                WidgetBackground()
                    .frame(width: inner.width, height: inner.height)
                    .clipShape(Self.shape)
                    .containerShape(Self.shape)
                    .offset(x: inner.minX, y: inner.minY)
            }
            .environment(\.juiceTheme, .smoke)
            let pixels = try ThemeTests.pixels(view, size: size)
            var brightest = 0.0
            for y in Int(2 * (inner.minY + 12))..<Int(2 * (inner.maxY - 12)) {
                for x in Int(2 * (inner.minX + 12))..<Int(2 * (inner.maxX - 12)) {
                    let p = pixels.rgba(x, y)
                    brightest = max(brightest, C.luminance(r: p.r, g: p.g, b: p.b))
                }
            }
            report.append("\(backdrop): \(brightest)")
            #expect(brightest <= C.worstSurface(floor: WidgetSmokeBody.style.floor) + 0.002, "\(backdrop) \(brightest)")
            for (name, colour) in Self.text { #expect(C.ratio(C.luminance(colour), brightest) >= C.text, "\(backdrop) \(name)") }
            for (name, colour) in Self.marks { #expect(C.ratio(C.luminance(colour), brightest) >= C.mark, "\(backdrop) \(name)") }
        }
        print("widget glass, brightest luminance inside:", report.joined(separator: "; "))
    }

    // MARK: The system's looks (P542)

    /// In the desktop's tinted, clear and vibrant looks the system takes either theme's background away and draws the
    /// content in one colour, so Glass draws exactly what Black draws there: none of its greys or veils.
    /// Black is drawn before and after Glass, and Glass must match one of them exactly: run with the other suites, the
    /// large face's first draw came out 1/255 off in 2 pixels of a battery, and Black drawn again matched Glass.
    @Test func inTheSystemsLooksGlassDrawsWhatBlackDraws() throws {
        let snapshots: [WidgetSnapshot?] = [.preview(at: Self.now), .closed(at: Self.now, theme: .smoke), nil]
        for snapshot in snapshots {
            for face in WidgetFace.allCases {
                let size = WidgetRenders.Size.of(face)
                func pixels(_ theme: JuiceTheme) throws -> [UInt8] {
                    try ThemeTests.pixels(IslandWidgetView(snapshot: snapshot, face: face, size: size, date: Self.now, tinted: true)
                        .environment(\.juiceTheme, theme), size: size).data
                }
                let before = try pixels(.black), glass = try pixels(.smoke), after = try pixels(.black)
                #expect(glass == before || glass == after, "\(face) \(snapshot?.appRunning.description ?? "none")")
            }
        }
    }

    /// In full colour Glass draws its own greys and battery wells, and nothing else changes: the same rows, glyphs and
    /// batteries in the same places.
    @Test func inFullColourOnlyTheGreysAndTheWellsChange() throws {
        let size = WidgetRenders.Size.medium
        func pixels(_ theme: JuiceTheme) throws -> ThemeTests.Pixels {
            try ThemeTests.pixels(IslandWidgetView(snapshot: .preview(at: Self.now), face: .medium, size: size, date: Self.now)
                .environment(\.juiceTheme, theme), size: size)
        }
        let black = try pixels(.black), glass = try pixels(.smoke)
        #expect(black.data != glass.data)
        // Where one draws, the other draws: the content keeps its shape (a quarter covered or more, so the glass wells'
        // white veil, 0.14 at most, is not lost at an antialiased edge).
        var drawnApart = 0
        for y in 0..<black.height {
            for x in 0..<black.width {
                let a = black.rgba(x, y).a, b = glass.rgba(x, y).a
                if max(a, b) >= 0.25, min(a, b) == 0 { drawnApart += 1 }
            }
        }
        #expect(drawnApart == 0)
    }
}
