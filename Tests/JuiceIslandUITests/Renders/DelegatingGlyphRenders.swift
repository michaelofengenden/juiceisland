import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Delegating (the main turn waits on its subagents) and Liquid's slim running, as frame strips drawn from the models at
/// explicit times (never the live clock), on the island's black. Nothing is shown on screen.
/// - `gl-delegating-strips-row`, `-pill`: every style × running (Liquid's Slim and Full), delegating and done, 12 frames
///   over one `HelperBeat` period (2.4 s), at the rows' size (Pixel 14 pt, Liquid and Sand 20 pt) and the pill's
///   (Pixel 17.5 pt, Liquid and Sand 28 pt); `-row-zoom` and `-pill-zoom` show every device pixel 4 × 4.
/// - `gl-delegating-lineup`: each style's moods side by side, still, at 14, 20 and 28 pt, so running, delegating and
///   done can be told apart at a glance; `-lineup-14-zoom` the 14 pt line enlarged.
/// - `gl-delegating-transitions`: Liquid and Sand from running into delegating and on to done, an approval and back,
///   8 frames each at 42 pt, and the same at 20 pt.
/// - `gl-delegating-pill`: the closed-pill mock with a delegating lead in Liquid and Sand, and Pixel's 17.5 pt lead.
/// - `gl-running-slim-frames`: Liquid's slim running over two crests at 84 pt, 28 pt and 20 pt, and Full beside it.
@MainActor
@Suite(.serialized)
struct DelegatingGlyphRenders {
    /// A whole number of helper periods and crest periods near today's clock, so every strip starts at a period's start.
    let start: TimeInterval = 811_999_992

    enum Row: Hashable {
        case running(LiquidRunningLook), delegating, done

        var mood: GlyphMood {
            switch self {
            case .running: .running
            case .delegating: .delegating
            case .done: .done
            }
        }

        var glyph: PixelGlyph {
            switch self {
            case .running: .eq
            case .delegating: .agents
            case .done: .check
            }
        }

        var colour: Color {
            switch self {
            case .running: IslandTheme.run
            case .delegating: IslandTheme.delegate
            case .done: IslandTheme.done
            }
        }

        var name: String {
            switch self {
            case .running(let look): "running · \(look.rawValue)"
            case .delegating: "delegating"
            case .done: "done"
            }
        }
    }

    static func rows(_ style: GlyphStyle) -> [Row] {
        style == .liquid ? [.running(.slim), .running(.full), .delegating, .done] : [.running(.slim), .delegating, .done]
    }

    /// One moment of `row` in `style` at `time`, `side` points square (Pixel: its pixel is side / 7).
    @ViewBuilder
    static func moment(_ style: GlyphStyle, _ row: Row, time: TimeInterval, side: CGFloat) -> some View {
        switch style {
        case .pixel:
            PixelGlyphView(glyph: row.glyph, colour: row.colour, pixel: side / 7)
                .moment(at: Date(timeIntervalSinceReferenceDate: time))
        case .liquid:
            let look: LiquidRunningLook = if case .running(let look) = row { look } else { .slim }
            LiquidGlyphFrame(primitives: LiquidGlyph.frame(mood: row.mood, time: time, side: side, running: look), colour: row.colour,
                             side: side)
        case .sand:
            SandFrameView(frame: SandGlyph.frame(mood: row.mood, from: nil, changeAge: .infinity, time: time, side: side),
                          colour: row.colour, side: side)
        }
    }

    private func strips(pixelSide: CGFloat, engineSide: CGFloat) -> some View {
        let times = (0..<12).map { start + HelperBeat.period * Double($0) / 12 }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(GlyphStyle.allCases, id: \.self) { style in
                ForEach(Self.rows(style), id: \.self) { row in
                    HStack(spacing: 8) {
                        label("\(style.rawValue) · \(style == .liquid ? row.name : row.mood.rawValue)").frame(width: 120, alignment: .leading)
                        ForEach(0..<times.count, id: \.self) { i in
                            Self.moment(style, row, time: times[i], side: style == .pixel ? pixelSide : engineSide)
                                .frame(width: engineSide, height: engineSide)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(IslandTheme.bg)
    }

    @Test func stripsAtRowAndPillSizes() throws {
        try RenderHarness.render(strips(pixelSide: 14, engineSide: 20), "gl-delegating-strips-row")
        try RenderHarness.renderPixels(strips(pixelSide: 14, engineSide: 20), "gl-delegating-strips-row-zoom", zoom: 4)
        try RenderHarness.render(strips(pixelSide: 17.5, engineSide: 28), "gl-delegating-strips-pill")
        try RenderHarness.renderPixels(strips(pixelSide: 17.5, engineSide: 28), "gl-delegating-strips-pill-zoom", zoom: 4)
    }

    /// Every mood still, as Reduce Motion and the renders draw it: the running looks, delegating, the marks, done, idle.
    private func lineup(_ side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(GlyphStyle.allCases, id: \.self) { style in
                HStack(spacing: max(10, side * 0.6)) {
                    label(style.rawValue).frame(width: 50, alignment: .leading)
                    ForEach(Self.lineupGlyphs(style), id: \.0) { _, glyph, colour, look in
                        StateGlyphView(glyph: glyph, colour: colour, pixel: style == .pixel ? side / 7 : 2, dimmed: glyph == .brand,
                                       animated: false, style: style, engineSide: side, liquidRunning: look)
                    }
                }
            }
        }
        .padding(12)
        .background(IslandTheme.bg)
    }

    static func lineupGlyphs(_ style: GlyphStyle) -> [(String, PixelGlyph, Color, LiquidRunningLook)] {
        var glyphs: [(String, PixelGlyph, Color, LiquidRunningLook)] = [("run", .eq, IslandTheme.run, .slim)]
        if style == .liquid { glyphs.append(("full", .eq, IslandTheme.run, .full)) }
        glyphs += [("agents", .agents, IslandTheme.delegate, .slim), ("bang", .bang, NeedsYouColour.pink.wait, .slim),
                   ("ques", .ques, NeedsYouColour.pink.question, .slim), ("check", .check, IslandTheme.done, .slim),
                   ("idle", .brand, IslandTheme.idleMark, .slim)]
        return glyphs
    }

    @Test func lineupAtEverySize() throws {
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach([CGFloat(14), 20, 28], id: \.self) { side in
                label("\(Int(side)) pt")
                lineup(side)
            }
        }
        .padding(10)
        .background(IslandTheme.bg)
        try RenderHarness.render(sheet, "gl-delegating-lineup")
        try RenderHarness.renderPixels(lineup(14), "gl-delegating-lineup-14-zoom", zoom: 6)
    }

    @Test func transitions() throws {
        let ages: [TimeInterval] = [0, 0.1, 0.2, 0.3, 0.45, 0.6, 0.8, 1.1]
        let pairs: [(GlyphMood, GlyphMood)] = [(.running, .delegating), (.delegating, .running), (.delegating, .done),
                                               (.delegating, .approval), (.question, .delegating), (.done, .delegating)]
        func colour(_ mood: GlyphMood) -> Color {
            switch mood {
            case .running: IslandTheme.run
            case .delegating: IslandTheme.delegate
            case .approval: NeedsYouColour.pink.wait
            case .question: NeedsYouColour.pink.question
            case .done: IslandTheme.done
            case .idle: IslandTheme.idleMark
            }
        }
        func sheet(_ side: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach([GlyphStyle.liquid, .sand], id: \.self) { style in
                    ForEach(0..<pairs.count, id: \.self) { p in
                        let (from, to) = pairs[p]
                        HStack(spacing: 8) {
                            label("\(style.rawValue) \(from.rawValue) → \(to.rawValue)").frame(width: 170, alignment: .leading)
                            ForEach(0..<ages.count, id: \.self) { i in
                                let age = ages[i], time = start + 1.9 + age, tint = colour(from).mix(with: colour(to), by: min(1, age / 0.35))
                                if style == .liquid {
                                    LiquidGlyphFrame(primitives: LiquidGlyph.frame(mood: to, from: from, changeAge: age, time: time, side: side),
                                                     colour: tint, side: side)
                                } else {
                                    SandFrameView(frame: SandGlyph.frame(mood: to, from: from, changeAge: age, time: time, side: side, fromLasted: 3),
                                                  colour: tint, side: side)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(IslandTheme.bg)
        }
        try RenderHarness.render(sheet(42), "gl-delegating-transitions")
        try RenderHarness.render(sheet(20), "gl-delegating-transitions-20")
    }

    @Test func inThePill() throws {
        let sheet = VStack(alignment: .leading, spacing: 10) {
            PillMock(glyph: 28) {
                LiquidGlyphFrame(primitives: LiquidGlyph.still(.delegating, side: 28), colour: IslandTheme.delegate, side: 28)
            } rim: { width, height in
                LiquidRimFrame(primitives: LiquidRim.frame(running: true, time: start, width: width, height: height), colour: IslandTheme.delegate)
            }
            PillMock(glyph: 28) {
                LiquidGlyphFrame(primitives: LiquidGlyph.still(.running, side: 28), colour: IslandTheme.run, side: 28)
            } rim: { width, height in
                LiquidRimFrame(primitives: LiquidRim.frame(running: true, time: start, width: width, height: height), colour: IslandTheme.run)
            }
            PillMock(glyph: 28) {
                SandFrameView(frame: SandGlyph.stillFrame(mood: .delegating, side: 28), colour: IslandTheme.delegate, side: 28)
            } rim: { width, height in
                SandRimFrame(grains: SandRim.stillFrame(running: true, width: width, height: height),
                             glow: SandRim.stillGlow(running: true, width: width, height: height), colour: IslandTheme.delegate)
            }
            PillMock(glyph: 17.5) {
                PixelGlyphView(glyph: .agents, colour: IslandTheme.delegate, pixel: 2.5, animated: false)
            } rim: { _, _ in EmptyView() }
        }
        .padding(14)
        .background(Color(white: 0.09))
        try RenderHarness.render(sheet, "gl-delegating-pill")
        try RenderHarness.renderPixels(sheet, "gl-delegating-pill-zoom", scale: 2, zoom: 3)
    }

    @Test func slimRunningFrames() throws {
        let strip = VStack(alignment: .leading, spacing: 12) {
            ForEach([CGFloat(84), 28, 20, 14], id: \.self) { side in
                label("Slim at \(Int(side)) pt, 12 frames over two crests (1.5 s)")
                HStack(spacing: side > 40 ? 12 : 8) {
                    ForEach(0..<12, id: \.self) { i in
                        LiquidGlyphFrame(primitives: LiquidGlyph.frame(mood: .running, time: start + LiquidGlyph.crestPeriod * Double(i) / 12,
                                                                       side: side, running: .slim),
                                         colour: IslandTheme.run, side: side)
                    }
                }
            }
            label("Full (the alternative) at 28 pt, the same moments")
            HStack(spacing: 8) {
                ForEach(0..<12, id: \.self) { i in
                    LiquidGlyphFrame(primitives: LiquidGlyph.frame(mood: .running, time: start + LiquidGlyph.crestPeriod * Double(i) / 12,
                                                                   side: 28, running: .full),
                                     colour: IslandTheme.run, side: 28)
                }
            }
        }
        .padding(14)
        .background(IslandTheme.bg)
        try RenderHarness.render(strip, "gl-running-slim-frames")
        try RenderHarness.renderPixels(strip, "gl-running-slim-frames-zoom", zoom: 2)
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 10, weight: .medium)).foregroundStyle(IslandTheme.ink3)
    }
}
