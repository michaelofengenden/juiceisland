import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The Liquid glyph style on the island's black, drawn from the model at explicit times (never the live clock).
/// `gl-liquid-moods`: the six moods settled at 14, 20, 21, 28 and 84 pt; `gl-liquid-moods-20pt-zoom` and
/// `-28pt-zoom` (and 14 and 21): a row at 2× blown up 6× with no smoothing, so its pixels can be inspected;
/// `gl-liquid-running`: 8 frames over 2 s at 84 pt, then running and the marks at 20 and 28 pt;
/// `gl-liquid-transitions`: running → approval, running → question and approval → done, 8 frames each at 84 pt;
/// `gl-liquid-rim`: the rim in the pill's 240 × 3 pt band (`pillEdgeLine`), whole and then under the notch as the pill
/// holds it, running and draining, 4 frames each at 3×, and the top bar's short line; `gl-liquid-pill`: the moods at
/// 28 pt in a closed pill with the rim. Nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct LiquidGlyphRenders {
    /// A fixed moment near today's clock, so the sines run at realistic magnitudes.
    let start: TimeInterval = 812_000_000
    let moods = GlyphMood.allCases

    private func colour(_ mood: GlyphMood) -> Color {
        switch mood {
        case .running: IslandTheme.run
        case .delegating: IslandTheme.delegate
        case .approval, .question: NeedsYouColour.pink.wait
        case .done: IslandTheme.done
        case .idle: IslandTheme.ink3
        }
    }

    private func glyph(_ mood: GlyphMood, side: CGFloat, from: GlyphMood? = nil, age: TimeInterval = .infinity,
                       time: TimeInterval? = nil, glow: Bool = true) -> some View {
        let clock = time ?? LiquidGlyph.stillTime(mood)
        return LiquidGlyphFrame(primitives: LiquidGlyph.frame(mood: mood, from: from, changeAge: age, time: clock, side: side),
                                colour: colour(mood), side: side, dimmed: mood == .idle, glow: glow)
    }

    private func row(side: CGFloat, glow: Bool = true) -> some View {
        HStack(spacing: max(12, side * 0.5)) {
            ForEach(moods, id: \.self) { mood in glyph(mood, side: side, glow: glow) }
        }
    }

    @Test func settledMoods() throws {
        let sheet = VStack(alignment: .leading, spacing: 16) {
            ForEach([CGFloat(14), 20, 21, 28], id: \.self) { side in
                label("\(Int(side)) pt")
                row(side: side)
            }
            label("20 pt, no glow")
            row(side: 20, glow: false)
            label("84 pt")
            row(side: 84)
            label("84 pt, no glow")
            row(side: 84, glow: false)
            label("The views themselves, still (animated: false): the moods at 21 pt, done dimmed, and the rim")
            HStack(spacing: 12) {
                ForEach(moods, id: \.self) { mood in
                    LiquidGlyphView(mood: mood, colour: colour(mood), side: 21, dimmed: mood == .idle, animated: false)
                }
                LiquidGlyphView(mood: .done, colour: colour(.done), side: 21, dimmed: true, animated: false)
                LiquidRimView(running: true, colour: IslandTheme.run, width: 160, animated: false)
            }
        }
        .padding(18)
        .background(IslandTheme.bg)
        try RenderHarness.render(sheet, "gl-liquid-moods")
        try RenderHarness.renderPixels(row(side: 20).padding(8).background(IslandTheme.bg), "gl-liquid-moods-20pt-zoom", zoom: 6)
        try RenderHarness.renderPixels(row(side: 14).padding(8).background(IslandTheme.bg), "gl-liquid-moods-14pt-zoom", zoom: 6)
        try RenderHarness.renderPixels(row(side: 21).padding(8).background(IslandTheme.bg), "gl-liquid-moods-21pt-zoom", zoom: 6)
        try RenderHarness.renderPixels(row(side: 28).padding(8).background(IslandTheme.bg), "gl-liquid-moods-28pt-zoom", zoom: 6)
    }

    /// Every change between two moods at 42 pt, 8 frames each, the colour crossfading as the view does.
    @Test func everyTransition() throws {
        let ages: [TimeInterval] = [0, 0.12, 0.25, 0.4, 0.55, 0.75, 1.0, 1.4]
        let pairs = moods.flatMap { from in moods.filter { $0 != from }.map { (from, $0) } }
        let strip = VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<pairs.count, id: \.self) { p in
                let (from, to) = pairs[p]
                HStack(spacing: 10) {
                    Text(verbatim: "\(from.rawValue) → \(to.rawValue)").font(.system(size: 10)).foregroundStyle(IslandTheme.ink3)
                        .frame(width: 110, alignment: .leading)
                    ForEach(0..<ages.count, id: \.self) { i in
                        let fade = min(1, ages[i] / 0.35)
                        LiquidGlyphFrame(primitives: LiquidGlyph.frame(mood: to, from: from, changeAge: ages[i],
                                                                       time: start + LiquidGlyph.beat / 2 + ages[i], side: 42),
                                         colour: colour(from).mix(with: colour(to), by: fade), side: 42,
                                         dimmed: to == .idle && ages[i] > 1.2)
                    }
                }
            }
        }
        .padding(14)
        .background(IslandTheme.bg)
        try RenderHarness.render(strip, "gl-liquid-transitions-all")
    }

    @Test func runningFrames() throws {
        let strip = VStack(alignment: .leading, spacing: 14) {
            label("Running, 8 frames over 2 s")
            HStack(spacing: 14) {
                ForEach(0..<8, id: \.self) { i in
                    glyph(.running, side: 84, time: start + Double(i) * 0.25)
                }
            }
            label("Running at 20 pt, 16 frames at 1/8 s")
            HStack(spacing: 10) {
                ForEach(0..<16, id: \.self) { i in
                    glyph(.running, side: 20, time: start + Double(i) * 0.125)
                }
            }
            label("Running at 28 pt, 16 frames at 1/8 s")
            HStack(spacing: 10) {
                ForEach(0..<16, id: \.self) { i in
                    glyph(.running, side: 28, time: start + Double(i) * 0.125)
                }
            }
            ForEach([CGFloat(20), 28], id: \.self) { side in
                label("Approval and question at \(Int(side)) pt over one beat (every 0.2 s)")
                ForEach([GlyphMood.approval, .question], id: \.self) { mood in
                    HStack(spacing: 10) {
                        ForEach(0..<16, id: \.self) { i in
                            glyph(mood, side: side, time: start + Double(i) * LiquidGlyph.beat / 16)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(IslandTheme.bg)
        try RenderHarness.render(strip, "gl-liquid-running")
    }

    @Test func transitionFrames() throws {
        let ages: [TimeInterval] = [0, 0.15, 0.3, 0.45, 0.6, 0.8, 1.0, 1.3]
        let pairs: [(GlyphMood, GlyphMood)] = [(.running, .approval), (.running, .question), (.approval, .done)]
        let strip = VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<pairs.count, id: \.self) { p in
                let (from, to) = pairs[p]
                label("\(from.rawValue) → \(to.rawValue) at " + ages.map { String(format: "%.2f", $0) }.joined(separator: ", ") + " s")
                HStack(spacing: 14) {
                    ForEach(0..<ages.count, id: \.self) { i in
                        // Each change lands while the old mood's mark is formed (mid-beat).
                        glyph(to, side: 84, from: from, age: ages[i], time: start + LiquidGlyph.beat / 2 + ages[i])
                    }
                }
            }
        }
        .padding(18)
        .background(IslandTheme.bg)
        try RenderHarness.render(strip, "gl-liquid-transitions")
    }

    /// The rim in the pill's band, 240 × 3 pt: running with nothing over it (so its wave can be seen whole), then as the
    /// pill holds it, the reference notch over all but the band's last point; then the top bar's short line.
    @Test func rimFrames() throws {
        let height = IslandTheme.Metrics.pillEdgeLine
        func band(_ running: Bool, age: TimeInterval, time: TimeInterval, width: CGFloat = 240, notch: CGFloat = 185) -> some View {
            RimBandContext(width: width, height: height, notch: notch) {
                LiquidRimFrame(primitives: LiquidRim.frame(running: running, changeAge: age, time: time, width: width, height: height),
                               colour: IslandTheme.run)
            }
        }
        let strip = VStack(alignment: .leading, spacing: 8) {
            label("Running, every 0.4 s: the whole line, then under the notch")
            ForEach(0..<4, id: \.self) { i in band(true, age: .infinity, time: start + Double(i) * 0.4, notch: 0) }
            ForEach(0..<2, id: \.self) { i in band(true, age: .infinity, time: start + Double(i) * 0.4) }
            label("Draining, 0.15 s, 0.35 s, 0.55 s, 0.75 s after running stops")
            ForEach(0..<4, id: \.self) { i in
                let age = 0.15 + Double(i) * 0.2
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
        .background(IslandTheme.bg)
        try RenderHarness.renderPixels(strip, "gl-liquid-rim", scale: 3)
    }

    @Test func closedPill() throws {
        let strip = VStack(alignment: .leading, spacing: 10) {
            ForEach(moods, id: \.self) { mood in
                PillMock(glyph: 28) {
                    glyph(mood, side: 28)
                } rim: { width, height in
                    LiquidRimFrame(primitives: LiquidRim.frame(running: mood != .idle, time: start, width: width, height: height),
                                   colour: IslandTheme.run)
                }
            }
        }
        .padding(14)
        .background(Color(white: 0.09))
        try RenderHarness.render(strip, "gl-liquid-pill")
        try RenderHarness.renderPixels(strip, "gl-liquid-pill-zoom", scale: 2, zoom: 3)
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 11, weight: .medium)).foregroundStyle(IslandTheme.ink3)
    }
}

/// The pill's bottom band for rim renders, `width` × `height` points as the pill gives it to the rim, in the body's
/// lowest points: the black body above it, the notch (drawn dark grey, where the hardware hides the body) over all but
/// the band's last point, as the notch + 1 tall body leaves it, the body's corner curves either side, and the menu
/// bar's grey under the body's bottom edge. `notch` 0 draws the band with nothing over it.
struct RimBandContext<Rim: View>: View {
    let width: CGFloat
    let height: CGFloat
    var notch: CGFloat = 185
    @ViewBuilder let rim: Rim

    var body: some View {
        let radius = min(IslandTheme.Metrics.pillRadius, width / 2), above: CGFloat = 8
        ZStack(alignment: .top) {
            Rectangle().fill(Color(white: 0.09))
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
                .fill(IslandTheme.bg)
                .frame(width: width + 2 * radius, height: above + height)
            rim.frame(width: width, height: height).padding(.top, above)
            if notch > 0 {
                UnevenRoundedRectangle(bottomLeadingRadius: IslandTheme.Metrics.referenceNotchRadius,
                                       bottomTrailingRadius: IslandTheme.Metrics.referenceNotchRadius)
                    .fill(Color(white: 0.15))
                    .frame(width: min(notch, width), height: above + height - 1)
            }
        }
        .frame(width: width + 2 * radius + 12, height: above + height + 5)
    }
}

/// A closed pill with Liquid's or Sand's lead as the engine pill would draw it (not the app's pill, whose layout is the
/// pill stream's): the reference notch drawn dark grey, a body 1 pt taller than it, wings of the glyph and 6 pt each
/// side, the glyph centred over the rim's band, "10" in the count's type, and the rim in the body's lowest 3 pt
/// (`pillEdgeLine`) between its corner curves, the notch over all but its last point.
struct PillMock<Lead: View, Rim: View>: View {
    var glyph: CGFloat = 28
    var band: CGFloat = IslandTheme.Metrics.pillEdgeLine
    var count = "10"
    @ViewBuilder let lead: Lead
    let rim: (CGFloat, CGFloat) -> Rim

    var body: some View {
        let notch = IslandTheme.Metrics.referenceNotch, ear = IslandTheme.Metrics.pillEar
        let wing = glyph + 2 * 6, width = notch.width + 2 * wing, height = notch.height + 1
        let line = width - 2 * IslandTheme.Metrics.pillRadius
        ZStack(alignment: .top) {
            PillShape().fill(IslandTheme.bg).frame(width: width + 2 * ear, height: height)
            HStack(spacing: 0) {
                lead.frame(width: wing, height: height - band)
                Color.clear.frame(width: notch.width)
                Text(verbatim: count).font(IslandTheme.TypeScale.pillCount).foregroundStyle(.white)
                    .frame(width: wing, height: height - band)
            }
            rim(line, band).frame(width: line, height: band).padding(.top, height - band)
            UnevenRoundedRectangle(bottomLeadingRadius: IslandTheme.Metrics.referenceNotchRadius,
                                   bottomTrailingRadius: IslandTheme.Metrics.referenceNotchRadius)
                .fill(Color(white: 0.15))
                .frame(width: notch.width, height: notch.height)
        }
        .frame(width: width + 2 * ear + 20, height: height + 6, alignment: .top)
        .background(Color(white: 0.09))
    }
}
