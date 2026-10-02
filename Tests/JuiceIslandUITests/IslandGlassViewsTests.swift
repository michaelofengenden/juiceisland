import AppKit
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Which colours the island's views draw on Smoke's glass (P553, P556 to P558; Glass's, `GlassThemeTests`): the palette's contrast tests check its tokens,
/// these check that a view draws them. Each view is drawn at 2× on the island's glass at its brightest (a white window
/// behind it: the floor over white, `GlassContrast.surface`, with the fill it sits on), and its ink is read back.
@MainActor
@Suite(.serialized)
struct IslandGlassViewsTests {
    typealias RGB = (r: Double, g: Double, b: Double)
    typealias Pixels = ThemeTests.Pixels

    /// The island's glass over a white window, with `fills` laid over it.
    static func worst(_ fills: [Color] = []) -> RGB {
        GlassContrast.surface(over: (1, 1, 1), floor: GlassStyle.island.floor, fills: fills)
    }

    static func colour(_ c: RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }
    static func luminance(_ c: RGB) -> Double { GlassContrast.luminance(r: c.r, g: c.g, b: c.b) }

    /// `view` in `theme` on `ground`, `size` points, at 2×.
    static func pixels<V: View>(_ view: V, size: CGSize, theme: JuiceTheme = .smoke, ground: RGB, env: AppEnvironment = .demo()) throws -> Pixels {
        try ThemeTests.pixels(view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(colour(ground))
            .environment(\.juiceTheme, theme)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(env), size: size)
    }

    static func rgb(_ p: Pixels, _ x: Int, _ y: Int) -> RGB {
        let c = p.rgba(x, y)
        return (c.r, c.g, c.b)
    }

    /// The contrast on `ground` of the brightest pixel in `rect` (points) that `keep` takes: a text's core, where the
    /// glyph covers its pixel whole, is the text's own colour.
    static func brightest(_ p: Pixels, in rect: CGRect, ground: RGB, keep: (RGB) -> Bool = { _ in true }) -> Double {
        var best = -1.0
        for y in max(0, Int(rect.minY * 2))..<min(p.height, Int(rect.maxY * 2)) {
            for x in max(0, Int(rect.minX * 2))..<min(p.width, Int(rect.maxX * 2)) {
                let c = rgb(p, x, y)
                guard keep(c) else { continue }
                best = max(best, luminance(c))
            }
        }
        return best < 0 ? 0 : GlassContrast.ratio(best, luminance(ground))
    }

    /// Lays `hosting` out, lets its updates run, and lays it out again.
    static func settle(_ hosting: NSView) {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hosting.layoutSubtreeIfNeeded()
    }

    static func isGrey(_ c: RGB) -> Bool { abs(c.r - c.g) < 0.04 && abs(c.g - c.b) < 0.05 }
    static func isBlue(_ c: RGB) -> Bool { c.b - c.r > 0.15 }

    static func row(status: StatusWord, prompt: String?, ago: TimeInterval = 180) -> SessionRow {
        SessionRow(id: "glass-row", agent: .claude, bucket: .running, project: "notes-site", task: "Fix the upload test", status: status,
                   detail: nil, lastPrompt: prompt, host: "Terminal", accountAlias: nil, updatedAt: DemoClock.now.addingTimeInterval(-ago),
                   isCodexApp: false, glyph: .eq, glyphState: .running, hasCard: false)
    }

    // MARK: A card's header (P557)

    /// An island card's header is the Detailed or the Clean row (`SessionCardView`): on the card's lift over the glass at
    /// its brightest, its age, "You:", its tool line and its jump hint read at the palette's 4:1 on a fill, as the list's
    /// rows do, never Black's greys (the age #7C7C80 at 2.7:1 there).
    @Test func aCardsHeaderDrawsTheGlassGreys() throws {
        let ground = Self.worst([IslandPalette.smoke.rowHover])
        let min = GlassContrast.textOnFill
        let metrics = DetailedRowMetrics.island
        let tool = Self.row(status: .tool(name: "Bash", detail: "swift test --filter Upload"), prompt: "fix the flaky upload test")
        let width: CGFloat = 440
        let detailed = try Self.pixels(DetailedRowView(row: tool, metrics: metrics, jumpHint: "⌃1").environment(\.showsShortcutHints, true),
                                       size: CGSize(width: width, height: 56), ground: ground)
        let title = metrics.title.line, status = metrics.status.line
        // The age and the jump hint, on the right of the title's line.
        let right = CGRect(x: width - 60, y: 0, width: 60, height: title)
        #expect(Self.brightest(detailed, in: right, ground: ground, keep: Self.isGrey) >= min, "the age")
        #expect(Self.brightest(detailed, in: right, ground: ground, keep: Self.isBlue) >= min, "the jump hint")
        // "You:" at the start of line 2 (the prompt after it is brighter).
        let you = CGRect(x: metrics.leading, y: title, width: 20, height: status)
        #expect(Self.brightest(detailed, in: you, ground: ground, keep: Self.isGrey) >= min, "You:")
        // The tool line: its verb and its text.
        let line = CGRect(x: metrics.leading, y: title + status, width: width - metrics.leading - 80, height: metrics.tool.line)
        #expect(Self.brightest(detailed, in: line, ground: ground, keep: Self.isBlue) >= min, "the tool's verb")
        #expect(Self.brightest(detailed, in: line, ground: ground, keep: Self.isGrey) >= min, "the tool line")

        let clean = try Self.pixels(CleanRowView(row: tool, cardStatus: SessionRowText.DetailedStatus(word: nil, tone: .muted, isPrompt: true, text: "fix it")),
                                    size: CGSize(width: width, height: 40), ground: ground)
        #expect(Self.brightest(clean, in: CGRect(x: width - 40, y: 0, width: 40, height: 18), ground: ground, keep: Self.isGrey) >= min, "Clean's age")
        #expect(Self.brightest(clean, in: CGRect(x: 49, y: 18, width: 20, height: 17), ground: ground, keep: Self.isGrey) >= min, "Clean's You:")
    }

    // MARK: Wave 6's views (P556)

    /// The gear's update dot is ringed apart from the cog's teeth: in Black by the island's black, on glass by cutting
    /// the ring out of the cog, never a black disc on the glass. Black keeps its ring.
    @Test func theGearsUpdateDotIsNoBlackDiscOnGlass() throws {
        let ground = Self.worst()
        func dark(_ theme: JuiceTheme) throws -> Int {
            let p = try Self.pixels(IslandGearButton(dot: true, action: {}).padding(6), size: CGSize(width: 32, height: 32), theme: theme, ground: ground)
            var count = 0
            for y in 0..<p.height {
                for x in 0..<p.width where Self.luminance(Self.rgb(p, x, y)) < Self.luminance(ground) * 0.6 { count += 1 }
            }
            return count
        }
        #expect(try dark(.smoke) == 0)
        #expect(try dark(.black) > 20, "Black's ring")
    }

    /// A Done card's message box, its code box, its table's rule and its fades are veils on glass: drawn over two
    /// grounds, no dark pixel of it is the same (an opaque #121214 box is).
    @Test func aDoneMessageOnGlassIsVeilsNotOpaqueGreys() throws {
        let text = "Done: **two** things.\n\n| Step | Time |\n| --- | ---: |\n| build | 2 min |\n\n```\nswift test --filter Upload\n```\n\nAll green."
        let size = CGSize(width: 360, height: 190)
        let view = DoneMessageView(text: text)
        let over = try Self.pixels(view, size: size, ground: Self.worst())
        let black = try Self.pixels(view, size: size, ground: (0, 0, 0))
        var same = 0
        for y in 0..<over.height {
            for x in 0..<over.width {
                let a = Self.rgb(over, x, y), b = Self.rgb(black, x, y)
                if Self.luminance(a) < 0.1, abs(a.r - b.r) < 0.004, abs(a.g - b.g) < 0.004, abs(a.b - b.b) < 0.004 { same += 1 }
            }
        }
        #expect(same < 40, "\(same) dark pixels hide the ground")
    }

    /// The branch tag (a Detailed row's line 2 and a Clean peek's) reads at 4.5:1 on the glass at its brightest.
    @Test func theBranchTagReadsOnGlass() throws {
        let ground = Self.worst()
        let p = try Self.pixels(IslandBranchTag(branch: "fix/upload-retries"), size: CGSize(width: 110, height: 16), ground: ground)
        #expect(Self.brightest(p, in: CGRect(x: 0, y: 0, width: 110, height: 16), ground: ground) >= GlassContrast.text)
    }

    /// A peek's "Recap:" label reads as its "You:" does, on the hovered row's lift over the glass at its brightest.
    @Test func aPeeksRecapLabelReadsOnGlass() throws {
        let ground = Self.worst([IslandPalette.smoke.islandHover])
        let peek = SessionPeek(sessionID: "glass-row", prompt: nil, reply: nil, tool: nil, facts: RowFacts(), recap: "Split the upload retries out")
        let width: CGFloat = 420
        let glass = try Self.pixels(IslandPeekView(peek: peek, clean: true, reply: nil), size: CGSize(width: width, height: 30), ground: ground)
        let leading = 8 + IslandTheme.Metrics.rowGlyphColumn + IslandTheme.Metrics.rowGlyphGap
        let label = CGRect(x: leading, y: 0, width: 30, height: 30)
        #expect(Self.brightest(glass, in: label, ground: ground, keep: Self.isGrey) >= GlassContrast.textOnFill)
    }

    // MARK: The peek (P558)

    /// A peek's ground on glass is the island's own glass and the hovered row's veil: it lays no glass and no floor of
    /// its own (live, a glass of its own samples the island's already-darkened surface and darkens it again, to about
    /// #17 over a white window under a #3B row). What is under it adds only its veil, whatever lies behind the island.
    @Test func aPeeksCoverOnGlassAddsOnlyItsVeil() throws {
        let ground = Self.worst()
        let fill = IslandPalette.smoke.islandHover
        let expected = GlassContrast.over(fill, ground)
        for backdrop in [GlassBackdrop.white, .black, .busy] {
            let view = GlassStage(backdrop: backdrop) {
                Self.colour(ground).overlay(IslandCover(shape: Rectangle(), fill: fill))
            }
            let p = try ThemeTests.pixels(view.environment(\.juiceTheme, .smoke), size: CGSize(width: 40, height: 40))
            let c = Self.rgb(p, 40, 40)
            #expect(abs(c.r - expected.r) < 0.01 && abs(c.g - expected.g) < 0.01 && abs(c.b - expected.b) < 0.01,
                    "\(backdrop): \(c) against \(expected)")
        }
        // Black's cover is the black and the veil, as it always was.
        let black = try ThemeTests.pixels(IslandCover(shape: Rectangle(), fill: IslandTheme.islandHover), size: CGSize(width: 40, height: 40))
        let b = Self.rgb(black, 40, 40), veil = GlassContrast.over(IslandTheme.islandHover, (0, 0, 0))
        #expect(abs(b.r - veil.r) < 0.01 && abs(b.g - veil.g) < 0.01 && abs(b.b - veil.b) < 0.01)
    }

    /// Which rows a peek lies over: every row (or part) that reaches into its ground below its own row, whole or in part;
    /// never its own row or one above it.
    @Test func aPeekCoversTheRowsUnderItsGround() {
        let own = CGRect(x: 0, y: 40, width: 400, height: 40)
        let top = own.maxY + IslandPeekPlacement.gap
        let cover = IslandPeekCover(minY: top, maxY: top + 60)
        #expect(!cover.covers(own))
        #expect(!cover.covers(CGRect(x: 0, y: 0, width: 400, height: 40)))
        #expect(cover.covers(CGRect(x: 0, y: 80, width: 400, height: 40)), "the next row, which starts under the gap")
        #expect(cover.covers(CGRect(x: 0, y: 120, width: 400, height: 40)), "a row the ground ends in")
        #expect(!cover.covers(CGRect(x: 0, y: 162, width: 400, height: 40)), "a row past the ground")
    }

    /// Live, on glass: the rows a peek lies over are not drawn under it (its ground is the island's glass, so nothing
    /// hides them there); in Black the cover hides them, as ever, and every row is drawn.
    @Test func onGlassTheRowsUnderAPeekAreNotDrawn() async throws {
        typealias ID = FixtureSessionFeed.RowsID
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .clean
        let env = AppEnvironment.demo(settings: settings, sessions: .rows, stalledAfter: 600)
        let peek = try #require(await env.sessions.peek(ID.codexRunning, clean: true))
        for theme in JuiceTheme.allCases {
            let ui = IslandUIState()
            ui.peek = peek
            let view = OpenedIslandView(presentation: .list, notch: IslandTheme.Metrics.referenceNotch, ui: ui, animated: false)
                .environment(\.sessionGlyphsAnimated, false).environment(\.juiceTheme, theme)
            let hosting = NSHostingView(rootView: view.environment(env).environment(\.colorScheme, .dark))
            hosting.frame = CGRect(x: 0, y: 0, width: 600, height: 420)
            Self.settle(hosting)
            let frames = ui.rowFrames.frames
            let own = try #require(frames[ID.codexRunning])
            let under = frames.filter { !$0.key.hasPrefix(IslandRowFrames.part) && $0.value.minY >= own.maxY }
            #expect(!under.isEmpty)
            let cover = try #require(ui.peekCover, "\(theme)")
            for (id, frame) in under {
                #expect(cover.covers(frame), "\(id)")
                #expect(IslandPeekCovered.hides(theme: theme, cover: cover, frame: frame) == theme.knocksOut, "\(id)")
            }
            #expect(!IslandPeekCovered.hides(theme: theme, cover: cover, frame: own))
            #expect(!IslandPeekCovered.hides(theme: theme, cover: nil, frame: under.first!.value))
            // The peek gone, nothing is covered.
            ui.peek = nil
            Self.settle(hosting)
            #expect(ui.peekCover == nil)
        }
    }
}
