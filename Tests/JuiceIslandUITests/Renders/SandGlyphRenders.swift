import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The Sand glyph style on the island's black, headless. Every frame comes from `SandGlyph.frame` at explicit times
/// (never the live clock), drawn with `SandFrameView` as the app draws it.
/// - `gl-sand-moods`: the six moods settled (and done after its first 4 s, dimmed) at 14, 20, 21, 28 and 84 pt, at 2×.
/// - `gl-sand-moods-28-zoom`, `-20-zoom`, `-14-zoom`: the 28, 20 and 14 pt rows with and without glow, each device
///   pixel shown 6 × 6.
/// - `gl-sand-pill`, `gl-sand-pill-zoom`: the 28 pt glyph and the rim in a closed-pill mock (`PillMock`).
/// - `gl-sand-running`: running over 2 s, 8 frames, at 84 pt, then at 28 and 20 pt (zoomed 6×).
/// - `gl-sand-transitions`: running → approval, running → question and approval → done, 8 frames each at 84 pt and
///   at 28 and 20 pt.
/// - `gl-sand-rim`: the rim in the pill's 240 × 3 pt band (`pillEdgeLine`, `RimBandContext`), running (whole, then
///   under the notch), draining and filling, and the top bar's short line, drawn at 3× (3 device pixels a point).
@MainActor
@Suite(.serialized)
struct SandGlyphRenders {
    private let moods = GlyphMood.allCases
    /// A fixed moment near today's clock, so the running motion runs at realistic magnitudes.
    private let start: TimeInterval = 812_000_000

    @Test func moodsSettled() throws {
        let sheet = VStack(alignment: .leading, spacing: 16) {
            ForEach([14, 20, 21, 28, 84] as [CGFloat], id: \.self) { side in
                VStack(alignment: .leading, spacing: 6) {
                    label("\(Int(side)) pt")
                    moodRow(side: side, glow: true)
                }
            }
        }
        .padding(18)
        .background(Color.black)
        try RenderHarness.render(sheet, "gl-sand-moods")
    }

    @Test func moodsZoomed() throws {
        for side in [28, 20, 14] as [CGFloat] {
            let sheet = VStack(alignment: .leading, spacing: 6) {
                moodRow(side: side, glow: true)
                moodRow(side: side, glow: false)
            }
            .padding(8)
            .background(Color.black)
            try RenderHarness.renderPixels(sheet, "gl-sand-moods-\(Int(side))-zoom", zoom: 6)
        }
    }

    /// The glyph at 28 pt and the rim in a closed-pill mock, once per mood, at 2× and enlarged 3×.
    @Test func inThePill() throws {
        let sheet = VStack(spacing: 10) {
            ForEach(moods, id: \.self) { mood in
                PillMock(glyph: 28) {
                    SandFrameView(frame: SandGlyph.stillFrame(mood: mood, side: 28), colour: Self.colour(mood), side: 28,
                                  dimmed: mood == .idle)
                } rim: { width, height in
                    SandRimFrame(grains: SandRim.frame(running: mood != .idle, changeAge: .infinity, time: start, width: width,
                                                       height: height),
                                 glow: SandRim.glow(running: mood != .idle, changeAge: .infinity, time: start, width: width,
                                                    height: height),
                                 colour: IslandTheme.run)
                }
            }
        }
        .padding(8)
        .background(Color(white: 0.09))
        try RenderHarness.render(sheet, "gl-sand-pill")
        try RenderHarness.renderPixels(sheet, "gl-sand-pill-zoom", zoom: 3)
    }

    @Test func runningFrames() throws {
        let times = (0..<8).map { start + Double($0) * 0.25 }
        let big = HStack(spacing: 12) {
            ForEach(times, id: \.self) { time in
                SandFrameView(frame: SandGlyph.frame(mood: .running, from: nil, changeAge: .infinity, time: time, side: 84),
                              colour: IslandTheme.run, side: 84)
            }
        }
        func small(_ side: CGFloat) -> some View {
            HStack(spacing: 8) {
                ForEach(times, id: \.self) { time in
                    SandFrameView(frame: SandGlyph.frame(mood: .running, from: nil, changeAge: .infinity, time: time, side: side),
                                  colour: IslandTheme.run, side: side)
                }
            }
        }
        try RenderHarness.render(VStack(alignment: .leading, spacing: 10) {
            label("Running, every 0.25 s over 2 s")
            big
        }.padding(18).background(Color.black), "gl-sand-running")
        try RenderHarness.renderPixels(small(20).padding(6).background(Color.black), "gl-sand-running-20-zoom", zoom: 6)
        try RenderHarness.renderPixels(small(28).padding(6).background(Color.black), "gl-sand-running-28-zoom", zoom: 6)
    }

    @Test func transitions() throws {
        let needsAges: [TimeInterval] = [0.05, 0.15, 0.25, 0.4, 1.2, 2.3, 2.45, 2.6]
        let doneAges: [TimeInterval] = [0.05, 0.3, 0.5, 0.7, 0.9, 1.1, 1.25, 1.5]
        let rows: [(String, GlyphMood, GlyphMood, TimeInterval?, [TimeInterval], Color)] = [
            ("running → approval", .running, .approval, nil, needsAges, NeedsYouColour.pink.wait),
            ("running → question", .running, .question, nil, needsAges, NeedsYouColour.pink.wait),
            ("approval → done (the “!” held 1 s)", .approval, .done, 1.0, doneAges, IslandTheme.done),
        ]
        for side in [84, 28, 20] as [CGFloat] {
            let sheet = VStack(alignment: .leading, spacing: side > 40 ? 14 : 6) {
                ForEach(rows.indices, id: \.self) { r in
                    let row = rows[r]
                    VStack(alignment: .leading, spacing: 6) {
                        if side > 40 { label("\(row.0), at " + row.4.map { String(format: "%.2f", $0) }.joined(separator: " · ") + " s") }
                        HStack(spacing: side > 40 ? 12 : 8) {
                            ForEach(row.4, id: \.self) { age in
                                SandFrameView(frame: SandGlyph.frame(mood: row.2, from: row.1, changeAge: age, time: start + age,
                                                                     side: side, fromLasted: row.3),
                                              colour: row.5, side: side)
                            }
                        }
                    }
                }
            }
            .padding(side > 40 ? 18 : 6)
            .background(Color.black)
            if side > 40 {
                try RenderHarness.render(sheet, "gl-sand-transitions")
            } else {
                try RenderHarness.renderPixels(sheet, "gl-sand-transitions-\(Int(side))-zoom", zoom: 6)
            }
        }
    }

    @Test func rim() throws {
        let height = IslandTheme.Metrics.pillEdgeLine
        func band(_ running: Bool, age: TimeInterval, time: TimeInterval, width: CGFloat = 240, notch: CGFloat = 185) -> some View {
            RimBandContext(width: width, height: height, notch: notch) {
                SandRimFrame(grains: SandRim.frame(running: running, changeAge: age, time: time, width: width, height: height),
                             glow: SandRim.glow(running: running, changeAge: age, time: time, width: width, height: height),
                             colour: IslandTheme.run)
            }
        }
        let sheet = VStack(alignment: .leading, spacing: 8) {
            label("Running, every 0.25 s: the whole line, then under the notch")
            ForEach(0..<4, id: \.self) { i in band(true, age: .infinity, time: start + Double(i) * 0.25, notch: 0) }
            ForEach(0..<2, id: \.self) { i in band(true, age: .infinity, time: start + Double(i) * 0.25) }
            label("Draining, 0.1 s, 0.3 s, 0.5 s, 0.7 s after running stops")
            ForEach(0..<4, id: \.self) { i in
                let age = 0.1 + Double(i) * 0.2
                band(false, age: age, time: start + age)
            }
            label("Filling, 0.1 s and 0.3 s after running starts; the top bar's 40 pt line")
            band(true, age: 0.1, time: start + 0.1)
            band(true, age: 0.3, time: start + 0.3)
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { i in band(true, age: .infinity, time: start + Double(i) * 0.5, width: 40, notch: 0) }
            }
        }
        .padding(12)
        .background(Color.black)
        try RenderHarness.renderPixels(sheet, "gl-sand-rim", scale: 3)
    }

    // MARK: Helpers

    /// The moods as the app draws them still (`SandGlyphView`, `animated: false`), idle dimmed, then done dimmed.
    private func moodRow(side: CGFloat, glow: Bool) -> some View {
        HStack(spacing: max(8, side * 0.5)) {
            ForEach(moods, id: \.self) { mood in
                SandGlyphView(mood: mood, colour: Self.colour(mood), side: side, dimmed: mood == .idle, glow: glow, animated: false)
            }
            SandGlyphView(mood: .done, colour: Self.colour(.done), side: side, dimmed: true, glow: glow, animated: false)
        }
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 11, weight: .medium)).foregroundStyle(IslandTheme.ink3)
    }

    /// The glyph colours by state (approval and question share one colour).
    static func colour(_ mood: GlyphMood) -> Color {
        switch mood {
        case .running: IslandTheme.run
        case .delegating: IslandTheme.delegate
        case .approval, .question: NeedsYouColour.pink.wait
        case .done: IslandTheme.done
        case .idle: IslandTheme.ink3
        }
    }
}
