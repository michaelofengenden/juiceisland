import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The Sand glyph's model: every mood draws inside its square at every size, a change plays a transition and then
/// lands exactly on the settled frame, done and idle hold still (so the view can pause), frames are reproducible, the
/// "!" keeps its dot apart from a bar with no wide top, the rim drains to nothing, and 1,000 frames of every mood
/// compute well inside the budget. Pure values only.
struct SandGlyphTests {
    /// A fixed moment near today's clock, so the motion runs at realistic magnitudes.
    let start: TimeInterval = 812_000_000
    let sides: [CGFloat] = [14, 16, 20, 21, 22, 28, 84]

    /// The grains that reach outside the square (none, for every frame).
    private func outside(_ frame: SandFrame, side: CGFloat) -> [SandGrain] {
        frame.grains.filter { grain in
            let r = grain.size / 2
            return grain.x - r < -0.01 || grain.x + r > side + 0.01 || grain.y - r < -0.01 || grain.y + r > side + 0.01
        }
    }

    @Test func settledFramesDrawEveryMoodInsideTheSquare() {
        for side in sides {
            for mood in GlyphMood.allCases {
                let still = SandGlyph.stillFrame(mood: mood, side: side)
                #expect(still.grains.count > 40, "\(mood) at \(side) pt")
                #expect(outside(still, side: side).isEmpty, "\(mood) at \(side) pt")
                #expect(still.grains.allSatisfy { $0.alpha > 0 && $0.alpha <= 1 && (-1...1).contains($0.shade) })
                if mood != .running && mood != .idle {
                    #expect(still.grains.contains { $0.layer == .mark }, "\(mood) shows its mark")
                }
            }
        }
    }

    /// The still "!" and "?" (renders, Reduce Motion, dimmed) are whole and at rest, with no glint frozen across them:
    /// every grain of the mark is in place, opaque, and no brighter than its own shading.
    @Test func theStillMarkIsWholeWithNoGlintAcrossIt() {
        for side in sides {
            for (mood, kind) in [(GlyphMood.approval, SandMarkKind.bang), (.question, .ques)] {
                let marks = SandGeometry.forSide(Double(side)).marks(kind)
                let grains = SandGlyph.stillFrame(mood: mood, side: side).grains.filter { $0.layer == .mark }
                #expect(grains.count == marks.count, "\(mood) at \(side) pt")
                #expect(grains.allSatisfy { $0.alpha == 1 }, "\(mood) at \(side) pt")
                #expect(grains.map(\.shade).max()! <= marks.map(\.shade).max()! + 1e-9, "\(mood) at \(side) pt has a glint")
            }
        }
    }

    /// Under 30 pt the glyph reads clear and defined: the still stream is a pour at least three and a half grains wide
    /// (about 4 pt at the pill's 28 pt), over a pile at least 0.3 of the square tall, a formed mark has one solid body
    /// inside the square under its grains, and the mark stands clear of the pile. The large sizes keep their grain
    /// texture with no solid body and their finer stream.
    @Test func theSmallSizesReadClearAndDefined() {
        for side in sides {
            let crisp = side < 30
            let running = SandGlyph.stillFrame(mood: .running, side: side).grains
            let pileTop = running.filter { $0.layer == .pile }.map(\.y).min()!
            let stream = running.filter { $0.layer == .stream && $0.y < pileTop - 0.2 * side }
            let grain = stream.map(\.size).max()!
            let width = stream.map { $0.x + $0.size / 2 }.max()! - stream.map { $0.x - $0.size / 2 }.min()!
            if crisp {
                #expect(width >= 3.5 * grain, "stream \(width) pt at \(side) pt")
                let pile = running.filter { $0.layer == .pile && $0.alpha > 0.3 }
                let tall = SandGlyph.base * side - pile.map { $0.y - $0.size / 2 }.min()!
                #expect(tall >= 0.3 * side, "the pile is \(tall) pt tall at \(side) pt")
            } else {
                #expect(width <= 3 * grain, "stream \(width) pt at \(side) pt")
            }
            for mood in [GlyphMood.approval, .question, .done] {
                let frame = SandGlyph.stillFrame(mood: mood, side: side)
                #expect(frame.solids.count == (crisp ? 1 : 0), "\(mood) at \(side) pt")
                for solid in frame.solids {
                    let box = solid.path.boundingRect
                    #expect(box.minX >= 0 && box.minY >= 0 && box.maxX <= side && box.maxY <= side, "\(mood) at \(side) pt")
                }
                let marks = frame.grains.filter { $0.layer == .mark }
                let pile = frame.grains.filter { $0.layer == .pile && $0.alpha > 0.3 }
                var gap = CGFloat.infinity
                for m in marks {
                    for p in pile where abs(p.x - m.x) < (p.size + m.size) / 2 {
                        gap = min(gap, (p.y - p.size / 2) - (m.y + m.size / 2))
                    }
                }
                #expect(gap >= max(0.8, 0.05 * side), "\(mood) stands \(gap) pt clear of the pile at \(side) pt")
            }
        }
    }

    /// Every moment of a beat, a slump and each transition stays inside the square too.
    @Test func movingFramesStayInsideTheSquare() {
        for side in [14, 20, 84] as [CGFloat] {
            for mood in GlyphMood.allCases {
                for from in [nil] + GlyphMood.allCases.filter({ $0 != mood }) {
                    for i in 0..<90 {
                        let age = Double(i) / 30
                        let frame = SandGlyph.frame(mood: mood, from: from, changeAge: age, time: start + age, side: side)
                        let out = outside(frame, side: side)
                        #expect(out.isEmpty, "\(String(describing: from)) → \(mood) at \(age) s, \(side) pt: \(out.prefix(2))")
                    }
                }
            }
        }
    }

    @Test func aChangePlaysATransitionThenLandsOnTheSettledFrame() {
        let pairs: [(GlyphMood, GlyphMood, TimeInterval)] = [
            (.running, .approval, 0.2), (.running, .question, 0.2), (.approval, .done, 0.5), (.question, .running, 0.3),
            (.idle, .running, 0.3), (.running, .done, 0.4), (.done, .idle, 0.2), (.approval, .question, 0.2),
        ]
        for (from, mood, age) in pairs {
            let time = start + 10
            let moving = SandGlyph.frame(mood: mood, from: from, changeAge: age, time: time, side: 20, fromLasted: 1)
            let settled = SandGlyph.frame(mood: mood, from: nil, changeAge: .infinity, time: time, side: 20)
            #expect(moving != settled, "\(from) → \(mood)")
        }
        // Done and idle are exactly their settled frame from `settleTime` on, whatever came before and whenever.
        for mood in [GlyphMood.done, .idle] {
            let settled = SandGlyph.frame(mood: mood, from: nil, changeAge: .infinity, time: start, side: 20)
            for from in GlyphMood.allCases where from != mood {
                for age in [SandGlyph.settleTime, 4, 60] {
                    let frame = SandGlyph.frame(mood: mood, from: from, changeAge: age, time: start + 3.7 * age, side: 20, fromLasted: 2)
                    #expect(frame == settled, "\(from) → \(mood) at \(age) s")
                }
            }
        }
    }

    @Test func stillMoodsSettleAndMovingMoodsKeepMoving() {
        for mood in [GlyphMood.done, .idle] {
            #expect(!SandGlyph.keepsMoving(mood))
            #expect(!SandGlyph.isSettled(mood, changeAge: 1.4))
            #expect(SandGlyph.isSettled(mood, changeAge: 1.5))
            let a = SandGlyph.frame(mood: mood, from: nil, changeAge: .infinity, time: start, side: 21)
            let b = SandGlyph.frame(mood: mood, from: nil, changeAge: .infinity, time: start + 12.3, side: 21)
            #expect(a == b, "a settled \(mood) glyph never changes, so its timeline can pause")
        }
        for mood in [GlyphMood.running, .delegating, .approval, .question] {
            #expect(SandGlyph.keepsMoving(mood))
            #expect(!SandGlyph.isSettled(mood, changeAge: 600))
            let a = SandGlyph.frame(mood: mood, from: nil, changeAge: .infinity, time: start, side: 21)
            let b = SandGlyph.frame(mood: mood, from: nil, changeAge: .infinity, time: start + 0.6, side: 21)
            #expect(a != b, "\(mood) moves")
        }
        #expect(!SandGlyphView.moves(animated: true, dimmed: true, reduceMotion: false))
        #expect(!SandGlyphView.moves(animated: true, dimmed: false, reduceMotion: true))
        #expect(!SandGlyphView.moves(animated: false, dimmed: false, reduceMotion: false))
        #expect(SandGlyphView.moves(animated: true, dimmed: false, reduceMotion: false))
    }

    /// A settled done or idle glyph pauses, but a colour change (Glyph colour, or a By agent lead of another agent)
    /// runs its timeline again until the crossfade is over, so it never holds the old colour.
    @Test func aRestingGlyphWakesForAColourChange() {
        for mood in [GlyphMood.done, .idle] {
            #expect(SandGlyphView.rests(mood: mood, restingMood: mood, fading: false))
            #expect(!SandGlyphView.rests(mood: mood, restingMood: mood, fading: true), "\(mood) holds its old colour")
            #expect(!SandGlyphView.rests(mood: mood, restingMood: nil, fading: false))
        }
        for mood in [GlyphMood.running, .delegating, .approval, .question] {
            #expect(!SandGlyphView.rests(mood: mood, restingMood: mood, fading: false))
        }
    }

    /// The view's memory of its moods: the first change's mood before had no change of its own (its beat ran on the
    /// clock); a later one knows how long the mood before lasted.
    @Test func theHistoryRemembersHowLongTheMoodBeforeLasted() {
        let appeared = SandMoodHistory(mood: .running)
        let first = appeared.changed(to: .approval, at: 100)
        #expect(first == SandMoodHistory(mood: .approval, from: .running, at: 100, fromLasted: nil))
        let second = first.changed(to: .done, at: 103.5)
        #expect(second == SandMoodHistory(mood: .done, from: .approval, at: 103.5, fromLasted: 3.5))
    }

    @Test func framesAreReproducibleAndTheOffsetShiftsTheClock() {
        for mood in GlyphMood.allCases {
            for side in sides {
                let a = SandGlyph.frame(mood: mood, from: .running, changeAge: 0.4, time: start + 0.4, side: side, fromLasted: 3)
                let b = SandGlyph.frame(mood: mood, from: .running, changeAge: 0.4, time: start + 0.4, side: side, fromLasted: 3)
                #expect(a == b)
                #expect(SandGlyph.stillFrame(mood: mood, side: side) == SandGlyph.stillFrame(mood: mood, side: side))
            }
        }
        let one = SandGlyph.frame(mood: .running, from: nil, changeAge: .infinity, time: start, side: 20)
        let two = SandGlyph.frame(mood: .running, from: nil, changeAge: .infinity, time: start + SandGlyph.offsetShift, side: 20)
        #expect(one != two)
    }

    /// The "!" never reads as a "T": its dot stands clear of the bar (at least 1 pt at 20 pt), and the bar's top is no
    /// wider than its middle by more than a grain.
    @Test func theBangKeepsItsDotApartAndItsBarNarrow() {
        for (side, clearance) in [(14, 0.7), (20, 1.0), (21, 1.0), (84, 4.0)] as [(CGFloat, CGFloat)] {
            let grains = SandGlyph.stillFrame(mood: .approval, side: side).grains.filter { $0.layer == .mark }
            let spans = grains.map { ($0.y - $0.size / 2, $0.y + $0.size / 2) }.sorted { $0.0 < $1.0 }
            var reach = spans[0].1, widest: CGFloat = 0, splitAt: CGFloat = 0
            for span in spans.dropFirst() {
                if span.0 - reach > widest { widest = span.0 - reach; splitAt = span.0 }
                reach = max(reach, span.1)
            }
            #expect(widest >= clearance, "gap \(widest) pt at \(side) pt")
            let bar = grains.filter { $0.y < splitAt }
            let top = bar.map(\.y).min()!, bottom = bar.map(\.y).max()!
            func width(near y: CGFloat) -> CGFloat {
                let row = bar.filter { abs($0.y - y) < (bottom - top) * 0.1 }
                return row.map { $0.x + $0.size / 2 }.max()! - row.map { $0.x - $0.size / 2 }.min()!
            }
            let grain = grains.map(\.size).max()!
            #expect(width(near: top + (bottom - top) * 0.1) <= width(near: top + (bottom - top) * 0.5) + grain, "\(side) pt")
        }
    }

    /// Grains are fine: under a point at the rows' sizes and about a point in the 28 pt pill, so it reads as sand, not
    /// pixels.
    @Test func grainsAreFineAtTheRealSizes() {
        for side in [14, 16, 20, 21, 22, 28] as [CGFloat] {
            let grains = SandGlyph.stillFrame(mood: .question, side: side).grains
            #expect(grains.allSatisfy { $0.size < (side > 22 ? 1.25 : 1) }, "\(side) pt")
            #expect(grains.count <= 400, "\(grains.count) grains at \(side) pt")
        }
    }

    /// The pill's band (`pillEdgeLine`, 3 pt) and a taller one.
    static let bands: [CGFloat] = [IslandTheme.Metrics.pillEdgeLine, 5]

    /// It runs, drains and stays in its band: in the pill's 3 pt band a grain grazes the band's edges by a twentieth of
    /// a point at most, where the canvas clips it.
    @Test(arguments: bands)
    func theRimRunsDrainsAndStaysInItsBand(_ height: CGFloat) {
        let slack: CGFloat = height < 4 ? 0.06 : 0.01
        let running = SandRim.frame(running: true, changeAge: .infinity, time: start, width: 240, height: height)
        #expect(running.count > 600)
        for i in 0..<12 {
            let grains = SandRim.frame(running: true, changeAge: .infinity, time: start + Double(i) * 0.19, width: 240, height: height)
            #expect(grains.allSatisfy { $0.y - $0.size / 2 >= -slack && $0.y + $0.size / 2 <= height + slack && $0.x > -1 && $0.x < 241 })
        }
        let later = SandRim.frame(running: true, changeAge: .infinity, time: start + 0.25, width: 240, height: height)
        #expect(running != later)
        let draining = SandRim.frame(running: false, changeAge: 0.3, time: start + 0.3, width: 240, height: height)
        #expect(!draining.isEmpty && draining.count < running.count)
        #expect(SandRim.frame(running: false, changeAge: SandRim.drainTime, time: start, width: 240, height: height).isEmpty)
        #expect(SandRim.frame(running: false, changeAge: .infinity, time: start, width: 240, height: height).isEmpty)
        #expect(SandRim.isDrained(running: false, changeAge: SandRim.drainTime))
        #expect(!SandRim.isDrained(running: true, changeAge: 60))
        #expect(SandRim.stillFrame(running: false, width: 240, height: height).isEmpty)
        // A short line (the top bar's) still shows its grains rather than fading away whole.
        for i in 0..<10 {
            let short = SandRim.frame(running: true, changeAge: .infinity, time: start + Double(i) * 0.3, width: 23, height: height)
            #expect(short.filter { $0.alpha > 0.3 }.count >= 30, "\(short.filter { $0.alpha > 0.3 }.count) grains show")
        }
    }

    /// In the pill's 3 pt band (and a taller one) the line is a dense, continuous bed of grains about 2 pt deep, never
    /// a dotted line: along the middle of the line every half point is covered by nearly opaque grains, a column of them
    /// at least 1.8 pt deep, with brighter grains riding its crests.
    @Test(arguments: bands)
    func theRimIsADenseContinuousBed(_ height: CGFloat) {
        for i in 0..<12 {
            let grains = SandRim.frame(running: true, changeAge: .infinity, time: start + Double(i) * 0.19, width: 240, height: height)
            let bed = grains.filter { $0.layer == .pile && $0.alpha > 0.8 }
            for x in stride(from: CGFloat(40), through: 200, by: 0.5) {
                let column = bed.filter { abs($0.x - x) <= $0.size / 2 }
                #expect(!column.isEmpty, "a gap in the bed at \(x) pt")
                guard let top = column.map({ $0.y - $0.size / 2 }).min(), let bottom = column.map({ $0.y + $0.size / 2 }).max() else { continue }
                #expect(bottom - top >= 1.8, "the bed is \(bottom - top) pt deep at \(x) pt")
            }
            let crest = grains.filter { $0.layer == .stream && $0.alpha > 0.5 }
            let mean = { (grains: [SandGrain]) in grains.map(\.shade).reduce(0, +) / Double(max(1, grains.count)) }
            #expect(crest.count > 20 && mean(crest) > mean(bed) + 0.2, "no bright crest grains")
        }
    }

    /// The glow is one strip along the bed, never the grains again: inside the band, as deep as the bed where the line
    /// is whole (a little deeper under the crests), thin at the tapered ends, dimming as the line drains, and nothing
    /// once it has.
    @Test(arguments: bands)
    func theRimsGlowIsOneStripAlongTheBed(_ height: CGFloat) {
        for i in 0..<12 {
            let time = start + Double(i) * 0.19
            let grains = SandRim.frame(running: true, changeAge: .infinity, time: time, width: 240, height: height)
            guard let glow = SandRim.glow(running: true, changeAge: .infinity, time: time, width: 240, height: height) else {
                Issue.record("no glow while running"); continue
            }
            let box = glow.path.boundingRect
            #expect(box.minX >= 0 && box.maxX <= 240 && box.minY >= 0 && box.maxY <= height, "\(box)")
            #expect(glow.alpha == SandRim.glowOpacity)
            for x in stride(from: CGFloat(40), through: 200, by: 8) {
                let bed = grains.filter { $0.layer == .pile && abs($0.x - x) <= 0.5 }
                guard let top = bed.map({ $0.y - $0.size / 2 }).min(), let bottom = bed.map({ $0.y + $0.size / 2 }).max() else { continue }
                let strip = glow.path.cgPath.intersection(CGPath(rect: CGRect(x: x - 0.05, y: 0, width: 0.1, height: height), transform: nil))
                    .boundingBoxOfPath
                // Down to the bed's bottom, and up to its top or, under a crest, to the crest grains riding it.
                #expect(abs(strip.maxY - bottom) < 0.3 && strip.minY <= top + 0.3 && strip.minY >= top - 0.7,
                        "the glow \(strip.minY)…\(strip.maxY) misses the bed \(top)…\(bottom) at \(x) pt")
            }
            let tip = glow.path.cgPath.intersection(CGPath(rect: CGRect(x: 0, y: 0, width: 1, height: height), transform: nil)).boundingBoxOfPath
            #expect(tip.isNull || tip.height < 0.3, "the glow does not taper: \(tip)")
        }
        let draining = SandRim.glow(running: false, changeAge: 0.5, time: start + 0.5, width: 240, height: height)
        #expect(draining.map { $0.alpha > 0 && $0.alpha < SandRim.glowOpacity * 0.6 } == true)
        #expect(SandRim.glow(running: false, changeAge: SandRim.drainTime, time: start, width: 240, height: height) == nil)
        #expect(SandRim.stillGlow(running: false, width: 240, height: height) == nil && SandRim.stillGlow(running: true, width: 240, height: height) != nil)
    }

    /// 300 frames of the pill's rim well inside a second (it runs for as long as any session runs).
    @Test func theRimIsCheap() {
        var grains = 0
        let elapsed = FramePerf.cpuTime {
            for frame in 0..<300 {
                grains += SandRim.frame(running: true, changeAge: .infinity, time: start + Double(frame) / 30, width: 240,
                                        height: IslandTheme.Metrics.pillEdgeLine).count
            }
        }
        print("SandRim: 300 frames at 240 pt in \(elapsed), \(grains / 300) grains a frame on average")
        #expect(elapsed < .milliseconds(1000))
    }

    /// The rim as the pill draws it, 30 times a second for as long as any session runs: 300 frames of its grains over
    /// its glow at 240 × 3 pt (`pillEdgeLine`), drawn at 2×, well inside a second (about 0.25 s in a debug build on this Mac, the
    /// grains' model worked out beforehand). Its glow is one blurred strip: blurring the grains themselves as well drew
    /// every grain twice.
    @MainActor @Test func theRimDrawsCheaply() {
        let band = IslandTheme.Metrics.pillEdgeLine
        let frames = (0..<300).map { i in
            let time = start + Double(i) / 30
            return (SandRim.frame(running: true, changeAge: .infinity, time: time, width: 240, height: band),
                    SandRim.glow(running: true, changeAge: .infinity, time: time, width: 240, height: band))
        }
        let elapsed = FramePerf.cpuTime {
            for (grains, glow) in frames {
                let renderer = ImageRenderer(content: SandRimFrame(grains: grains, glow: glow, colour: IslandTheme.run).frame(width: 240, height: band))
                renderer.scale = 2
                #expect(renderer.cgImage != nil)
            }
        }
        print("SandRim: 300 frames drawn at 240 × \(band) pt and 2× in \(elapsed)")
        #expect(elapsed < .milliseconds(1000))
    }

    /// 1,000 frames of every mood (a change into it, then on for 33 s) at 20 pt, well inside 1.5 s on this Mac.
    @Test func aThousandFramesOfEveryMoodAreCheap() {
        let moods = GlyphMood.allCases
        var grains = 0
        let elapsed = FramePerf.cpuTime {
            for (i, mood) in moods.enumerated() {
                let from = moods[(i + moods.count - 1) % moods.count]
                for frame in 0..<1000 {
                    let age = Double(frame) / 30
                    grains += SandGlyph.frame(mood: mood, from: from, changeAge: age, time: start + age, side: 20,
                                              fromLasted: 2).grains.count
                }
            }
        }
        print("SandGlyph: \(moods.count) × 1,000 frames at 20 pt in \(elapsed), \(grains / (1000 * moods.count)) grains a frame on average")
        #expect(elapsed < .milliseconds(1500))
    }
}
