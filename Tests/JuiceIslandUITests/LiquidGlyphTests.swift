import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The Liquid glyph style's model: every mood draws inside its square at every size, a change plays a transition that
/// differs from the settled frame, the same inputs always give the same shapes, done and idle stop changing once
/// settled (so the view can pause), a needs-you mark joins the clock's beat without a jump, the rim is a thick line in
/// its band and drains to nothing, and the model is cheap. Pure values only.
struct LiquidGlyphTests {
    /// A fixed moment near today's clock, so the sines run at realistic magnitudes.
    let start: TimeInterval = 812_000_000
    let sides: [CGFloat] = [14, 16, 20, 21, 22, 28, 84]

    /// Where a frame can show: each shape cut to the clips that keep it inside something.
    private func visibleBounds(_ frame: [LiquidGlyph.Primitive]) -> CGRect {
        frame.reduce(CGRect.null) { box, primitive in
            var region = primitive.path.cgPath
            for clip in primitive.clips where !clip.inverse { region = region.intersection(clip.path.cgPath) }
            return box.union(region.boundingBoxOfPath)
        }
    }

    @Test func settledFramesDrawInsideTheirSquare() {
        for mood in GlyphMood.allCases {
            for side in sides {
                // Over a whole beat: the needs-you marks rise, float, fall and splash in that time.
                for i in 0..<24 {
                    let frame = LiquidGlyph.frame(mood: mood, time: start + Double(i) * LiquidGlyph.beat / 24, side: side)
                    #expect(!frame.isEmpty)
                    let bounds = visibleBounds(frame)
                    #expect(!bounds.isNull && bounds.width > side * 0.5, "\(mood) at \(side) pt draws too little")
                    #expect(CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: -0.01, dy: -0.01).contains(bounds),
                            "\(mood) at \(side) pt draws outside its square: \(bounds)")
                }
                #expect(!LiquidGlyph.still(mood, side: side).isEmpty)
            }
        }
    }

    /// Each settled layout, mark included, sits in the middle of its square (the prototype's body sat low).
    @Test func settledGlyphsAreCentred() {
        for mood in GlyphMood.allCases {
            for side in [20, 28] as [CGFloat] {
                let bounds = visibleBounds(LiquidGlyph.still(mood, side: side))
                #expect(abs(bounds.midX - side / 2) < side * 0.03, "\(mood) is off centre across at \(side) pt: \(bounds)")
                #expect(abs(bounds.midY - side / 2) < side * 0.06, "\(mood) is off centre down at \(side) pt: \(bounds)")
            }
        }
    }

    /// Running Full (Settings › Island › Running), the round body, fills its square: its body is about two thirds of the
    /// square tall at every moment, not a flat strip. Slim is the default since wave 5 (P380).
    @Test func theFullRunningBodyFillsItsSquare() {
        for side in sides {
            for i in 0..<60 {
                let body = LiquidGlyph.frame(mood: .running, time: start + Double(i) * 0.11, side: side, running: .full)[0].path.boundingRect
                #expect(body.height >= side * 0.6, "running is \(body.height) pt tall at \(side) pt")
            }
        }
    }

    @Test func aChangePlaysATransition() {
        for to in GlyphMood.allCases {
            for from in GlyphMood.allCases where from != to {
                let time = start + LiquidGlyph.beat / 2 + 0.3
                let moving = LiquidGlyph.frame(mood: to, from: from, changeAge: 0.3, time: time, side: 20)
                #expect(moving != LiquidGlyph.frame(mood: to, time: time, side: 20), "\(from) → \(to) plays nothing")
            }
        }
        // No change, or the same mood, is the settled frame.
        let settled = LiquidGlyph.frame(mood: .running, time: start, side: 20)
        #expect(LiquidGlyph.frame(mood: .running, from: .running, changeAge: 0.2, time: start, side: 20) == settled)
        #expect(LiquidGlyph.frame(mood: .running, from: .done, changeAge: .infinity, time: start, side: 20) == settled)
    }

    @Test func theSameMomentAlwaysDrawsTheSameShapes() {
        for mood in GlyphMood.allCases {
            for i in 0..<20 {
                let time = start + Double(i) * 0.37
                #expect(LiquidGlyph.frame(mood: mood, time: time, side: 21) == LiquidGlyph.frame(mood: mood, time: time, side: 21))
                #expect(LiquidGlyph.frame(mood: mood, from: .running, changeAge: 0.4, time: time, side: 21)
                        == LiquidGlyph.frame(mood: mood, from: .running, changeAge: 0.4, time: time, side: 21))
            }
        }
        #expect(LiquidGlyph.frame(mood: .running, time: start, side: 20) != LiquidGlyph.frame(mood: .running, time: start + 0.2, side: 20))
        #expect(LiquidGlyph.hash(3, 11) == LiquidGlyph.hash(3, 11))
        #expect(LiquidGlyph.hash(3, 11) != LiquidGlyph.hash(4, 11))
    }

    /// Done and idle stop changing by `settleTime` after any change, and settled they never change, so the view can
    /// pause their timeline at `pauseAfter`; running and needs-you keep moving.
    @Test func stillMoodsStopChangingOnceSettled() {
        #expect(LiquidGlyph.settleTime < LiquidGlyph.pauseAfter && LiquidGlyph.pauseAfter <= 1.5)
        for to in [GlyphMood.done, .idle] {
            let settled = LiquidGlyph.frame(mood: to, time: start, side: 20)
            #expect(LiquidGlyph.frame(mood: to, time: start + 9.1, side: 20) == settled)
            for from in GlyphMood.allCases where from != to {
                for offset in [0.0, 0.4, 1.3, 2.9] {
                    let time = start + offset
                    let first = LiquidGlyph.frame(mood: to, from: from, changeAge: LiquidGlyph.settleTime, time: time, side: 20)
                    let later = LiquidGlyph.frame(mood: to, from: from, changeAge: LiquidGlyph.settleTime + 4.7, time: time + 4.7, side: 20)
                    #expect(first == later, "\(from) → \(to) still moves after it settled")
                }
            }
            #expect(!LiquidGlyph.keepsMoving(to))
            #expect(LiquidGlyphView.paused(to, settled: true))
            #expect(!LiquidGlyphView.paused(to, settled: false))
        }
        for mood in [GlyphMood.running, .delegating, .approval, .question] {
            #expect(LiquidGlyph.keepsMoving(mood))
            #expect(!LiquidGlyphView.paused(mood, settled: true))
            #expect(LiquidGlyph.frame(mood: mood, time: start + 0.1, side: 20) != LiquidGlyph.frame(mood: mood, time: start + 0.6, side: 20))
        }
    }

    /// After a change into needs-you the mark rises at once, holds, and hands over to the clock's beat with no jump.
    @Test func aNewMarkJoinsTheClocksBeatSmoothly() {
        let step = 1.0 / 60
        for k in 0..<12 {
            let change = start + Double(k) * 0.29
            var previous: LiquidGlyph.Jet?
            var risen = false
            for i in 0..<Int(9 / step) {
                let time = change + Double(i) * step
                let jet = LiquidGlyph.needsBeat(changeTime: change, delay: 0.06, time: time).jet
                if let jet, time - change < 0.9, jet.pinch == 1 { risen = true }
                if let a = previous, let b = jet {
                    #expect(abs(b.grow - a.grow) < 0.2 && abs(b.pinch - a.pinch) < 0.3 && abs(b.drop - a.drop) < 0.15,
                            "the mark jumps \(time - change) s after a change: \(a) → \(b)")
                }
                previous = jet
            }
            #expect(risen, "the mark is not up within 0.9 s of the change")
        }
    }

    /// The rim's primitives: glow, core, ridge, glint, bloom.
    private let glowIndex = 0, coreIndex = 1, glintIndex = 3

    /// The pill's band (`pillEdgeLine`, 3 pt) and a taller one.
    static let bands: [CGFloat] = [IslandTheme.Metrics.pillEdgeLine, 5]

    @Test(arguments: bands)
    func theRimLivesWhileRunningAndDrainsToNothing(_ height: CGFloat) {
        let width: CGFloat = 240
        let band = CGRect(x: 0, y: 0, width: width, height: height)
        for i in 0..<30 {
            let frame = LiquidRim.frame(running: true, time: start + Double(i) * 0.21, width: width, height: height)
            #expect(frame.count == 5)
            #expect(band.insetBy(dx: -0.01, dy: -0.01).contains(visibleBounds(frame)), "\(visibleBounds(frame))")
            // What is blurred is clipped to the band, so the glow never spills out of the pill, and fades in under the
            // band's top rather than being cut flat there (beside the notch the black body goes on above it).
            for primitive in frame where primitive.blur > 0 {
                #expect(primitive.clips.contains { !$0.inverse && $0.path.boundingRect == band && $0.feather == LiquidRim.glowFeather })
            }
            #expect(LiquidRim.glowFeather >= 1 && LiquidRim.glowFeather <= height / 2)
            #expect(frame == LiquidRim.frame(running: true, time: start + Double(i) * 0.21, width: width, height: height))
        }
        #expect(LiquidRim.frame(running: false, time: start, width: width, height: height).isEmpty)
        #expect(!LiquidRim.frame(running: false, changeAge: 0.3, time: start, width: width, height: height).isEmpty)
        #expect(LiquidRim.frame(running: false, changeAge: LiquidRim.drainTime, time: start, width: width, height: height).isEmpty)
        #expect(LiquidRim.drainTime < LiquidGlyph.pauseAfter)
        // It drains from both ends toward the middle, and thins as it goes.
        let early = LiquidRim.frame(running: false, changeAge: 0.2, time: start, width: width, height: height)[coreIndex].path
        let late = LiquidRim.frame(running: false, changeAge: 0.6, time: start, width: width, height: height)[coreIndex].path
        #expect(late.boundingRect.width < early.boundingRect.width)
        #expect(abs(late.boundingRect.midX - width / 2) < 2)
        #expect(thickness(late, at: width / 2) < thickness(early, at: width / 2))
    }

    /// The core's height where it crosses `x` (the ribbon's vertical extent there).
    private func thickness(_ path: Path, at x: CGFloat) -> CGFloat {
        path.cgPath.intersection(CGPath(rect: CGRect(x: x - 0.05, y: -10, width: 0.1, height: 30), transform: nil)).boundingBoxOfPath.height
    }

    /// In the pill's 3 pt band the line is clearly there: a full-colour core about 2 pt thick (1.75 to 2.3 as its top
    /// rises and falls) all the way between the tapered ends, 0.25 pt clear of the pill's edge and inside the band,
    /// its top waving by more than half a point, and its bottom always over the band's last point, the one that shows
    /// under the notch. In a 5 pt band it is 2 to 2.6 pt thick, clear of both edges, and the whole line waves by about a
    /// point either way.
    @Test(arguments: bands)
    func inTheBandTheLineIsAThickFullColourCore(_ height: CGFloat) {
        let width: CGFloat = 240, pill = height == IslandTheme.Metrics.pillEdgeLine
        var tops: [CGFloat] = []
        for i in 0..<40 {
            let frame = LiquidRim.frame(running: true, time: start + Double(i) * 0.17, width: width, height: height)
            let core = frame[coreIndex]
            guard case .linear(let stops, _, _) = core.paint else { Issue.record("the core is not faded at its ends"); continue }
            #expect(stops.map(\.tone.opacity).max() == 1 && stops.allSatisfy { abs($0.tone.light) < 0.1 }, "the core is not full colour")
            for x in stride(from: 24, through: width - 24, by: 6) {
                let t = thickness(core.path, at: x)
                #expect(pill ? t >= 1.75 && t <= 2.3 : t >= 2 && t <= 2.6, "the core is \(t) pt thick at \(x) in \(height) pt")
                if pill {
                    let bottom = core.path.cgPath.intersection(CGPath(rect: CGRect(x: x - 0.05, y: -1, width: 0.1, height: height + 2),
                                                                      transform: nil)).boundingBoxOfPath.maxY
                    #expect(bottom >= height - 0.75, "under the notch the line is \(bottom - height + 1) pt at \(x)")
                }
            }
            let box = core.path.boundingRect
            #expect(box.minY >= (pill ? 0 : 0.25) && box.maxY <= height - 0.25, "the core touches the band's edge: \(box)")
            #expect(box.minX < 2 && box.maxX > width - 2, "the core stops short of the ends: \(box)")
            // The ends taper to points by the corner curves.
            #expect(thickness(core.path, at: 2) < 0.8 && thickness(core.path, at: width - 2) < 0.8)
            tops.append(core.path.cgPath.intersection(CGPath(rect: CGRect(x: 119.95, y: 0, width: 0.1, height: height), transform: nil))
                .boundingBoxOfPath.minY)
            #expect(frame[glowIndex].blur > 0)
        }
        #expect(tops.max()! - tops.min()! > 0.6, "the line does not wave")
        #expect(tops.max()! - tops.min()! < 2.2, "the line waves more than a point either way")
    }

    /// On a short line (the top bar's, about 23 pt) the glint is a bell along part of it, never a wash over all of it.
    @Test func aShortRimKeepsItsGlintToPartOfIt() {
        for width in [23, 60, 228] as [CGFloat] {
            let frame = LiquidRim.frame(running: true, time: start, width: width, height: IslandTheme.Metrics.pillEdgeLine)
            guard case .linear(_, let from, let to) = frame[glintIndex].paint else { Issue.record("no glint"); continue }
            #expect(to.x - from.x <= min(52, width * 0.6), "a \(to.x - from.x) pt glint on a \(width) pt line")
        }
    }

    /// 300 frames of the pill's rim well inside a second (it runs for as long as any session runs).
    @Test func theRimIsCheap() {
        var shapes = 0
        let elapsed = FramePerf.cpuTime {
            for i in 0..<300 {
                shapes += LiquidRim.frame(running: true, time: start + Double(i) * LiquidGlyph.motionInterval, width: 240,
                                          height: IslandTheme.Metrics.pillEdgeLine).count
            }
        }
        print("LiquidRim: 300 frames at 240 pt in \(elapsed)")
        #expect(shapes == 1_500 && elapsed < .milliseconds(1000))
    }

    /// 1,000 frames of each mood, a new moment each, well within budget (the bound covers all moods on this Mac).
    @Test func theModelIsCheap() {
        var shapes = 0
        let elapsed = FramePerf.cpuTime {
            for mood in GlyphMood.allCases {
                for i in 0..<1_000 {
                    let time = start + Double(i) * LiquidGlyph.motionInterval
                    shapes += LiquidGlyph.frame(mood: mood, from: i < 60 ? .running : nil, changeAge: Double(i) / 30, time: time, side: 20).count
                }
            }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("LiquidGlyph: \(GlyphMood.allCases.count) × 1,000 frames in \(String(format: "%.3f", seconds)) s (\(shapes) shapes)")
        #expect(seconds < 1.5)
    }
}
