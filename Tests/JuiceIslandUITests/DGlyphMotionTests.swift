import Foundation
import Testing
@testable import JuiceIslandUI

/// Stream D: the glyphs' motion. The equalizer glides on a function of the clock (in range, continuous, never all on
/// the floor, a second one offset), its fractional bars blend the still frames, the needs-you pulse is a function of
/// the clock alone, and Reduce Motion or `animated: false` hold every glyph still. Pure values only.
struct DGlyphMotionTests {
    /// A fixed moment near today's clock, so the sines run at realistic magnitudes.
    let start: TimeInterval = 812_000_000
    let step = PixelGlyph.motionInterval

    private func samples(seconds: Double, offset: Int = 0) -> [[Double]] {
        (0..<Int(seconds / step)).map { PixelGlyph.equalizerHeights(at: start + Double($0) * step, offset: offset) }
    }

    @Test func theEqualizerIsAFunctionOfTheClock() {
        for i in 0..<50 {
            let t = start + Double(i) * 0.37
            #expect(PixelGlyph.equalizerHeights(at: t) == PixelGlyph.equalizerHeights(at: t))
            #expect(PixelGlyph.equalizerHeights(at: t, offset: 3) == PixelGlyph.equalizerHeights(at: t, offset: 3))
            #expect(PixelGlyph.equalizerHeights(at: t).count == 4)
        }
    }

    @Test func theBarsStayInTheirRangeAndNeverAllRestOnTheFloor() {
        for heights in samples(seconds: 600) + samples(seconds: 120, offset: 3) {
            #expect(heights.allSatisfy { (2...6).contains($0) })
            #expect(heights.max()! >= PixelGlyph.equalizerLowestPeak - 1e-9)
        }
    }

    @Test func theBarsUseTheirWholeRange() {
        let all = samples(seconds: 600).flatMap { $0 }
        #expect(all.min()! < 2.3)
        #expect(all.max()! > 5.7)
    }

    /// A bar moves well under a pixel per frame: the motion glides where the old frames jumped up to 4 pixels.
    @Test func theBarsMoveContinuously() {
        let frames = samples(seconds: 600)
        var largest = 0.0, total = 0.0
        for (previous, next) in zip(frames, frames.dropFirst()) {
            for bar in 0..<4 {
                let change = abs(next[bar] - previous[bar])
                largest = max(largest, change)
                total += change
            }
        }
        #expect(largest < 0.6)
        // …and it still moves: on average about 6 pixels a second.
        #expect(total / Double((frames.count - 1) * 4) > 0.1)
    }

    @Test func aSecondEqualizerMovesDifferently() {
        let first = samples(seconds: 30), second = samples(seconds: 30, offset: 3)
        var difference = 0.0
        for (a, b) in zip(first, second) {
            for bar in 0..<4 { difference += abs(a[bar] - b[bar]) }
        }
        #expect(difference / Double(first.count * 4) > 0.5)
    }

    @Test func wholeHeightsDrawExactlyTheStillFrames() {
        for frame in 0..<8 {
            let heights = PixelGlyph.equalizerFrames[frame].map(Double.init)
            #expect(PixelGlyph.equalizerAlphas(heights: heights) == PixelGlyph.eq.alphas(frame: frame))
        }
    }

    /// The top pixel and the cap fade with the fraction, and nothing jumps as a bar crosses a whole height.
    @Test func fractionalBarsFadeTheirTopPixel() {
        let half = PixelGlyph.equalizerAlphas(heights: [3.5, 3.5, 3.5, 3.5])
        // Column 0, from the bottom: pixels 0-2 are the bar, 3 fades toward it, 4 is the cap fading in.
        #expect(half[6][0] == 0.85 && half[4][0] == 0.85)
        #expect(abs(half[3][0] - (0.38 + 0.85) / 2) < 1e-12)
        #expect(abs(half[2][0] - 0.19) < 1e-12)
        #expect(half[1][0] == 0 && half[3][1] == 0)
        for whole in 2...5 {
            let below = PixelGlyph.equalizerAlphas(heights: Array(repeating: Double(whole) - 1e-9, count: 4))
            let at = PixelGlyph.equalizerAlphas(heights: Array(repeating: Double(whole), count: 4))
            for y in 0..<7 { #expect(abs(below[y][0] - at[y][0]) < 1e-6) }
        }
    }

    @Test func thePulseDependsOnlyOnTheClock() {
        let period = PixelGlyph.pulsePeriod
        for i in 0..<40 {
            let t = start + Double(i) * 0.29
            let pulse = PixelGlyph.pulse(at: t)
            #expect(pulse == PixelGlyph.pulse(at: t))
            #expect((0...1).contains(pulse))
            #expect(abs(PixelGlyph.pulse(at: t + period) - pulse) < 1e-6)
        }
        // It breathes: rest at the start of a period, bright half way, and never more than a small step per frame.
        let rest = (start / period).rounded(.up) * period
        #expect(PixelGlyph.pulse(at: rest) < 1e-6)
        #expect(PixelGlyph.pulse(at: rest + period / 2) > 1 - 1e-6)
        for i in 0..<Int(period / step) {
            let t = rest + Double(i) * step
            #expect(abs(PixelGlyph.pulse(at: t + step) - PixelGlyph.pulse(at: t)) < 0.05)
        }
    }

    @Test func reduceMotionAndRendersHoldStill() {
        for glyph in PixelGlyph.allCases {
            #expect(!PixelGlyphView.moves(glyph, animated: false, reduceMotion: false))
            #expect(!PixelGlyphView.moves(glyph, animated: true, reduceMotion: true))
            #expect(PixelGlyphView.moves(glyph, animated: true, reduceMotion: false) == (glyph == .eq || glyph == .agents || glyph.needsYou))
        }
        // The still equalizer is the offset's still frame, as before.
        #expect(PixelGlyph.eq.alphas(frame: 3) == PixelGlyph.alphas(rows: PixelGlyph.eq.pattern(frame: 3)))
        #expect(PixelGlyph.eq.pattern(frame: 0) == ["......+", "..+...#", "..#...#", "+.#...#", "#.#.+.#", "#.#.#.#", "#.#.#.#"])
    }
}
