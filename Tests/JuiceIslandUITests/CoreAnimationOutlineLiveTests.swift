import AppKit
import CoreGraphics
import Darwin
import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Core Animation's outline on the live island (`FramePerf.IslandRig`: the real root view, director, choreography and
/// canvas, in a window never ordered in): what it costs the main thread (B), what a stalled main thread does to it (C),
/// the edge line on it, and how it fails closed (F). What is drawn is read off the main thread from the layers'
/// presentation: the committed animation evaluated now, which is what the render server evaluates at each refresh.
@MainActor
@Suite(.serialized)
struct CoreAnimationOutlineLiveTests {
    typealias Model = IslandChoreography

    // MARK: Sampling what Core Animation draws

    /// Reads, on its own thread about every millisecond, the outline's presentation (its height and width) and the edge
    /// line carrier's lift.
    final class Sampler: @unchecked Sendable {
        struct Sample { var t: TimeInterval; var w: CGFloat; var h: CGFloat; var rim: CGFloat }
        private let lock = NSLock()
        private var samples: [Sample] = []
        private var running = true
        nonisolated(unsafe) let clip: CAShapeLayer
        nonisolated(unsafe) let rim: CALayer?

        init(clip: CAShapeLayer, rim: CALayer?) {
            self.clip = clip
            self.rim = rim
        }

        func start() {
            let thread = Thread { [self] in
                while true {
                    lock.lock()
                    let go = running
                    lock.unlock()
                    guard go else { return }
                    // A thread with no run loop never ends its implicit transaction, and a transaction's presentation is
                    // evaluated at its own start: end it around each read, so each read is of now.
                    CATransaction.flush()
                    let t = ProcessInfo.processInfo.systemUptime
                    let box = clip.presentation()?.path?.boundingBoxOfPath
                    let lift = rim?.presentation()?.sublayerTransform.m42 ?? 0
                    CATransaction.flush()
                    if let box {
                        lock.lock()
                        samples.append(Sample(t: t, w: box.width, h: box.height, rim: lift))
                        lock.unlock()
                    }
                    usleep(1000)
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        func stop() -> [Sample] {
            lock.lock()
            defer { lock.unlock() }
            running = false
            return samples
        }
    }

    /// The plans the layers were handed, and when, so what is drawn can be held against the model.
    final class PlanLog {
        var plans: [(plan: Model.SurfacePlan, at: TimeInterval)] = []

        func model(at s: TimeInterval) -> (SurfaceGeometry, CGFloat)? {
            guard let plan = plans.last(where: { $0.plan.start <= s })?.plan else { return nil }
            return (plan.geometry(at: s), plan.rim(at: s))
        }
    }

    /// Drops the samples read while a plan was handed over but not yet committed (from its install to the end of that
    /// run-loop turn): off the main thread `presentation()` can then see the new model value without its animation,
    /// which the render server, receiving only commits, never draws.
    static func committed(_ samples: [Sampler.Sample], rig: FramePerf.IslandRig, log: PlanLog) -> [Sampler.Sample] {
        let ends = rig.probe.turns.map { Double($0.end) / 1e9 }
        let windows = log.plans.map { install in (install.at - 0.001, ends.first(where: { $0 >= install.at }) ?? install.at + 0.03) }
        return samples.filter { s in !windows.contains { s.t >= $0.0 && s.t <= $0.1 + 0.0005 } }
    }

    struct Stall: CustomStringConvertible {
        /// The longest stretch the drawn height stood still while the model moved more than a point.
        var frozenMS: Double
        /// The most the drawn height stood from the model's from the stall to 60 ms after it.
        var lag: CGFloat
        /// The most the edge line's lift stood from the plan's, within 2 ms of the read.
        var rimOff: CGFloat
        var samples: Int
        var description: String {
            String(format: "frozen %.1f ms, lag %.2f pt, edge line off %.2f pt, %d samples", frozenMS, Double(lag), Double(rimOff), samples)
        }
    }

    static func measure(_ samples: [Sampler.Sample], log: PlanLog, from t0: TimeInterval, stall: (TimeInterval, TimeInterval)) -> Stall {
        var frozen = 0.0, lag: CGFloat = 0, rim: CGFloat = 0
        var run: Sampler.Sample?
        for s in samples where s.t >= t0 {
            guard let m = log.model(at: s.t) else { continue }
            if let r = run, abs(s.h - r.h) < 0.01 {
                if let a = log.model(at: r.t), abs(a.0.height - m.0.height) > 1 { frozen = max(frozen, s.t - r.t) }
            } else {
                run = s
            }
            if s.t >= stall.0, s.t <= stall.1 + 0.06 { lag = max(lag, abs(s.h - m.0.height)) }
            // The sample's clock and the transaction's can stand a fraction of a millisecond apart, a point at the
            // lift's fastest: the lift is held against the plan anywhere within 2 ms of the read (a quarter of a frame).
            let near = stride(from: -0.002, through: 0.002, by: 0.0002).compactMap { log.model(at: s.t + $0)?.1 }
            rim = max(rim, near.map { abs(s.rim - $0) }.min() ?? abs(s.rim - m.1))
        }
        return Stall(frozenMS: frozen * 1000, lag: lag, rimOff: rim, samples: samples.count)
    }

    /// A busy main thread for `seconds`, in a run-loop turn of its own.
    static func stall(_ seconds: TimeInterval) async -> (TimeInterval, TimeInterval) {
        var span = (0.0, 0.0)
        FramePerf.inTurn {
            let start = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - start < seconds {}
            span = (start, ProcessInfo.processInfo.systemUptime)
        }
        while span.1 == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        return span
    }

    static func rig(_ outline: IslandOutline, glyph: GlyphStyle = .liquid, tuning: MotionTuning = MotionTuning()) async -> (FramePerf.IslandRig, PlanLog) {
        let rig = FramePerf.IslandRig(style: .clean, glyph: glyph, glyphsMove: false, outline: outline, tuning: tuning)
        let log = PlanLog()
        rig.canvas.layers.onInstall = { plan, at in log.plans.append((plan, at)) }
        await rig.start()
        return (rig, log)
    }

    // MARK: C. A stalled main thread holds none of the outline

    /// A 50 ms busy loop on the main thread 100 ms into an open, while the width and the height move fastest: Core
    /// Animation's outline keeps moving through it (never still for more than a few milliseconds while the model moves)
    /// and stays within a point of the model, and the edge line's lift stays on the plan the whole way (it rides the
    /// edge). SwiftUI's outline, for the record, draws nothing through the stall and jumps after it.
    @Test func aStalledMainThreadHoldsNoneOfTheOutline() async throws {
        _ = NSApplication.shared
        var results: [String] = []
        for stallMS in [0.0, 0.05] {
            let (rig, log) = await Self.rig(.coreAnimation)
            let sampler = Sampler(clip: rig.canvas.layers.clip, rim: rig.canvas.layers.rim)
            sampler.start()
            try? await Task.sleep(for: .milliseconds(40))
            let t0 = ProcessInfo.processInfo.systemUptime
            FramePerf.inTurn { rig.open() }
            try? await Task.sleep(for: .milliseconds(100))
            let span = stallMS > 0 ? await Self.stall(stallMS) : (t0 + 0.1, t0 + 0.1)
            try? await Task.sleep(for: .milliseconds(600))
            let samples = Self.committed(sampler.stop(), rig: rig, log: log)
            let result = Self.measure(samples, log: log, from: t0, stall: span)
            results.append("Core Animation, stall \(Int(stallMS * 1000)) ms: \(result)")
            #expect(result.samples > 200)
            #expect(result.frozenMS <= 6, "stall \(stallMS): \(result)")
            #expect(result.lag <= 1, "stall \(stallMS): \(result)")
            #expect(result.rimOff <= 1, "stall \(stallMS): \(result)")
            rig.stop()
        }
        // SwiftUI's outline, for the record: the outlines it built (its island's probe) and the longest gap between them.
        let (rig, _) = await Self.rig(.swiftUI)
        FramePerf.inTurn { rig.open() }
        try? await Task.sleep(for: .milliseconds(100))
        let span = await Self.stall(0.05)
        try? await Task.sleep(for: .milliseconds(400))
        let renders = rig.outlines.paths
        rig.stop()
        let offset = CACurrentMediaTime() - ProcessInfo.processInfo.systemUptime
        let gaps = zip(renders, renders.dropFirst()).filter { $0.0.time - offset >= span.0 - 0.02 }.map { ($1.time - $0.time) * 1000 }
        let jump = zip(renders, renders.dropFirst()).map { abs($1.geometry.height - $0.geometry.height) }.max() ?? 0
        results.append(String(format: "SwiftUI, stall 50 ms: longest gap %.1f ms, largest step %.1f pt, %d frames", gaps.max() ?? 0,
                              Double(jump), renders.count))
        print(results.joined(separator: "\n"))
    }

    /// List → card with a gliding row under a stall: the render server keeps moving the edge (up, when the card is
    /// shorter than the list) while the stalled SwiftUI content stays where it was, the tapped row mid-glide and the card
    /// body mid-ride under it, the rows mid-fade. Played on the model for every stall of 30, 50 and 80 ms starting
    /// anywhere in the first 400 ms, each part held as it was drawn when the stall began, against the edge as it moves on,
    /// on every row's card, a short card and a tall list, both feels:
    /// - the gliding row is never cut by it, at any focus;
    /// - no part it covers more than a quarter of shows more than the fold itself lets a fading row show (0.2; measured
    ///   0.10 at most, a row leaving the tall list under an 80 ms stall);
    /// - a part more than half in focus is cut by at most 6 pt more than the model itself cuts it at that moment (5.2
    ///   measured: Refined's card body, p 0.53, riding up from the tall list's last row under an 80 ms stall).
    /// Below half focus a stall cuts more (P242, the research's proto-ca risk 3, content freezing inside a moving shape):
    /// Refined's card body at p 0.24 by 9.6 / 13.9 / 19.6 pt under 30 / 50 / 80 ms, Original's parts by 2.2 at most. It
    /// is masked, never spilled, and comes back as the stall ends. And live: the edge keeps moving through a 50 ms stall
    /// 60 ms in.
    @Test func aRowHeldMidGlideIsNeverCutByTheRisingEdge() async throws {
        var row: (depth: CGFloat, at: String) = (0, ""), covered: (p: Double, at: String) = (0, "")
        var added: [Int: (depth: CGFloat, at: String)] = [:], own: (depth: CGFloat, at: String) = (0, "")
        var half: (depth: CGFloat, at: String) = (0, "")
        for tuning in [MotionTuning(), CoreAnimationOutlineTests.refined] {
            for id in ["r0", "r1", "r2", "r3"] {
                for (name, list) in [("short card", DIslandMotionTests.cardLayout(id)), ("tall list", Self.tallList(DIslandMotionTests.cardLayout(id)))] {
                    var model = CoreAnimationOutlineTests.model(layout: list, surface: .island, tuning: tuning)
                    _ = model.handle(.present(.card(sessionID: id)), at: 0)
                    var frames: [(TimeInterval, Model)] = []
                    for ms in 0...600 {
                        let t = Double(ms) / 1000
                        _ = model.advance(to: t)
                        frames.append((t, model))
                    }
                    for stall in [0.030, 0.050, 0.080] {
                        let key = Int(stall * 1000)
                        for s0 in stride(from: 0, through: 400, by: 5) {
                            let held = frames[s0].1, at = frames[s0].0
                            for (part, rect) in held.layout.parts {
                                let p = held.value(.part(part), at: at)
                                guard p > 0.01 else { continue }
                                let drawn = MotionRefinedTests.drawn(held, part, rect, at: at)
                                let where_ = "\(tuning.motion) \(id) \(name) \(part) p \(String(format: "%.2f", p)), stall \(key) ms at \(s0) ms"
                                for ms in s0...min(600, s0 + key) {
                                    let (t, live) = frames[ms], edge = live.surface(at: t).height
                                    let depth = drawn.maxY - edge
                                    if part == .row(id), depth > row.depth { row = (depth, where_) }
                                    if edge < drawn.maxY - 0.25 * drawn.height, p > covered.p { covered = (p, where_) }
                                    guard p > 0.2, let now = live.layout.parts[part] else { continue }
                                    // What the model itself cuts at `t` (a part coming out of the dark as the edge
                                    // passes), against which the stall's own share is measured.
                                    let ownDepth = max(0, MotionRefinedTests.drawn(live, part, now, at: t).maxY - edge)
                                    if ownDepth > own.depth, live.value(.part(part), at: t) > 0.2 { own = (ownDepth, where_) }
                                    if depth - ownDepth > added[key, default: (0, "")].depth { added[key] = (depth - ownDepth, where_) }
                                    if p > 0.5, depth - ownDepth > half.depth { half = (depth - ownDepth, where_) }
                                }
                            }
                        }
                    }
                }
            }
        }
        let text = added.sorted { $0.key < $1.key }.map { "\($0.key) ms \(String(format: "%.1f", Double($0.value.depth))) pt (\($0.value.at))" }
        print("the moving edge against content held by a stall: the gliding row cut \(String(format: "%.2f", Double(row.depth))) pt at most; a part that shows (p > 0.2) cut beyond what the model cuts: \(text.joined(separator: "; ")); p > 0.5: \(String(format: "%.1f", Double(half.depth))) pt (\(half.at)); the model's own cut \(String(format: "%.1f", Double(own.depth))) pt (\(own.at)); a part more than a quarter covered shows \(String(format: "%.2f", covered.p)) at most (\(covered.at))")
        #expect(row.depth <= 0.5, "\(row.at)")
        #expect(covered.p <= 0.2, "\(covered.at)")
        #expect(half.depth <= 6, "\(half.at)")

        // Live: the card's edge keeps moving through a 50 ms stall 60 ms in.
        _ = NSApplication.shared
        let (rig, log) = await Self.rig(.coreAnimation)
        rig.open()
        await FramePerf.wait(0.8)
        let sampler = Sampler(clip: rig.canvas.layers.clip, rim: rig.canvas.layers.rim)
        sampler.start()
        try? await Task.sleep(for: .milliseconds(30))
        let t0 = ProcessInfo.processInfo.systemUptime
        FramePerf.inTurn { rig.present(.card(sessionID: FixtureSessionFeed.ID.approval)) }
        try? await Task.sleep(for: .milliseconds(60))
        let span = await Self.stall(0.05)
        try? await Task.sleep(for: .milliseconds(500))
        let samples = Self.committed(sampler.stop(), rig: rig, log: log)
        let result = Self.measure(samples, log: log, from: t0, stall: span)
        print("list → card, stall 50 ms at 60 ms: \(result)")
        #expect(result.frozenMS <= 6 && result.lag <= 1, "\(result)")
        rig.stop()
    }

    /// The list with a fifth row under the fourth, so a card rises from further down.
    static func tallList(_ layout: ContentLayout) -> ContentLayout {
        var layout = layout
        layout.parts[.row("r4")] = CGRect(x: 18, y: 38 + 4 * 41 + 20, width: 444, height: 41)
        layout.list += 41
        return layout
    }

    // MARK: B. No path on the main thread

    /// Core Animation's outline builds no outline on the main thread and runs no shoulder-gate or width body in a frame:
    /// through an open, a card and back, a close, a swell and an unswell, its island's probe (`OutlineProbe`) counts 0 of
    /// each, where SwiftUI's builds one a frame. A play (the plan and its animations) costs the event's
    /// turn 1.4 ms of CPU at most run alone, and the first play once measured 2.9 ms run after the suite's stalls (a
    /// slower core or cold caches, not told apart): the median stays under 2 ms and none reaches 4.
    @Test func coreAnimationsOutlineBuildsNothingOnTheMainThread() async throws {
        _ = NSApplication.shared
        var line: [String] = []
        for outline in [IslandOutline.swiftUI, .coreAnimation] {
            let (rig, _) = await Self.rig(outline)
            // From the island at rest, built once.
            let before = rig.outlines.count
            var plays: [Double] = [], parts: [String] = []
            rig.canvas.layers.onInstall = { _, _ in }
            for step in [{ rig.open() }, { rig.present(.card(sessionID: FixtureSessionFeed.ID.approval)) }, { rig.present(.list) },
                         { rig.director.send(.close(.fold)) }, { rig.director.send(.swell(true)) }, { rig.director.send(.swell(false)) }] as [@MainActor () -> Void] {
                FramePerf.inTurn(step)
                await FramePerf.wait(0.7)
                let cpu = rig.canvas.layers.lastPlayCPU
                plays.append(cpu.plan + cpu.install)
                parts.append(String(format: "%.2f+%.2f", cpu.plan, cpu.install))
            }
            let after = rig.outlines.count
            let counts = (paths: after.paths - before.paths, gates: after.gates - before.gates, clips: after.clips - before.clips)
            line.append("\(outline): outlines built, gate bodies, width bodies \(counts); plays (plan+install ms) \(parts)")
            if outline == .coreAnimation {
                #expect(counts.paths == 0 && counts.gates == 0 && counts.clips == 0, "\(counts)")
                #expect(plays.sorted()[plays.count / 2] < 2 && plays.allSatisfy { $0 < 4 }, "\(parts)")
                #expect(rig.canvas.layers.mismatches == 0)
            } else {
                #expect(counts.paths > 20 && counts.gates > 20 && counts.clips > 20, "\(counts)")
            }
            rig.stop()
        }
        print(line.joined(separator: "\n"))
    }

    /// Nothing ticks at rest: once a motion is over no layer holds an animation, the director waits on no job, and the
    /// layers rest on the plan's last sample.
    @Test func nothingTicksAtRest() async throws {
        _ = NSApplication.shared
        let (rig, _) = await Self.rig(.coreAnimation)
        rig.open()
        await FramePerf.wait(1.8)
        let layers = rig.canvas.layers
        #expect(layers.fill.animationKeys() == nil && layers.clip.animationKeys() == nil && layers.rim?.animationKeys() == nil)
        #expect(!rig.director.model.inMotion)
        #expect(layers.fill.path == layers.path(rig.director.model.restGeometry))
        rig.director.send(.close(.fold))
        await FramePerf.wait(1.8)
        #expect(layers.fill.animationKeys() == nil && layers.clip.animationKeys() == nil && layers.rim?.animationKeys() == nil)
        #expect(layers.fill.path == layers.path(rig.director.model.restGeometry))
        #expect(layers.rim?.sublayerTransform.m42 == 0)
        rig.stop()
    }

    // MARK: F. It fails closed

    /// The black is a shape layer of its own in a view whose one layer the app owns: nothing else in the canvas has a
    /// background or contents, so whatever becomes of the mask, nothing black is drawn beyond the outline. Drawn from
    /// its layer, the black covers exactly the model's outline.
    @Test func theBlackIsItsOwnShapeAndNothingElse() async throws {
        _ = NSApplication.shared
        let (rig, _) = await Self.rig(.coreAnimation)
        let canvas = rig.canvas
        let surface = try #require(canvas.surfaceView), masked = try #require(canvas.maskedView)
        #expect(surface.layer === surface.root && surface.root.sublayers?.count == 1 && surface.root.sublayers?.first === canvas.layers.fill)
        #expect(masked.layer is IslandMaskedLayer && masked.layer?.mask === canvas.layers.clip)
        #expect(canvas.layers.fill.fillColor == CGColor(gray: 0, alpha: 1))
        for layer in [surface.root, canvas.layers.fill, masked.layer, canvas.rimCarrier?.layer, rig.window.contentView?.layer].compactMap({ $0 }) {
            #expect(layer.backgroundColor == nil && layer.contents == nil, "\(layer)")
        }
        #expect(!rig.window.isOpaque && rig.window.backgroundColor == .clear)
        // What the black draws, at rest and open, against the model's outline.
        for step in [{}, { rig.open() }] as [@MainActor () -> Void] {
            step()
            await FramePerf.wait(1.6)
            let outside = Self.blackOutside(canvas: canvas, expected: rig.director.model.restGeometry)
            #expect(outside.outside == 0 && outside.inside > 1000, "\(outside)")
        }
        rig.stop()
    }

    /// The black drawn from its own layer (`CALayer.render(in:)`) against `expected`'s outline at 2×: pixels black
    /// beyond it (more than a pixel from its edge) and inside it.
    static func blackOutside(canvas: IslandCanvas, expected: SurfaceGeometry) -> (outside: Int, inside: Int) {
        guard let root = canvas.surfaceView?.root else { return (-1, 0) }
        let size = root.bounds.size, scale: CGFloat = 2
        let w = Int(size.width * scale), h = Int(min(size.height, 400) * scale)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // The context's first row is its top: the root's y grows downward (a flipped view).
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        root.render(in: ctx)
        let path = NotchSurfaceShape.path(expected, originX: size.width / 2 - expected.left, top: 0).cgPath
        var outside = 0, inside = 0
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 128 {
                let p = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                let near = [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1), .zero]
                    .contains { path.contains(CGPoint(x: p.x + $0.x * 0.75, y: p.y + $0.y * 0.75)) }
                if near { inside += 1 } else { outside += 1 }
            }
        }
        return (outside, inside)
    }

    /// A mask taken off or replaced, a backing layer AppKit builds again, the black taken out of its view or its view's
    /// layer replaced: the content's layer keeps the outline as its mask, and the next snap's check puts everything
    /// else back before the turn commits, the black still exactly the outline. A mask that cannot be put back sends the
    /// canvas back to SwiftUI's outline: the hosting view in the container again, nothing of Core Animation's left.
    @Test func aLostOrReplacedMaskOrBlackComesBack() async throws {
        _ = NSApplication.shared
        let (rig, _) = await Self.rig(.coreAnimation)
        let canvas = rig.canvas, layers = canvas.layers
        let surface = try #require(canvas.surfaceView), masked = try #require(canvas.maskedView)
        var sound: [Bool] = []
        rig.afterSnap = { _, ok in sound.append(ok) }
        masked.layer?.mask = nil
        #expect(masked.layer?.mask === layers.clip)
        masked.layer?.mask = CALayer()
        #expect(masked.layer?.mask === layers.clip)
        masked.wantsLayer = false
        masked.wantsLayer = true
        #expect(masked.layer is IslandMaskedLayer && masked.layer?.mask === layers.clip)
        layers.fill.removeFromSuperlayer()
        surface.layer = CALayer()
        canvas.rimCarrier?.wantsLayer = false
        let repairs = canvas.repairs
        rig.open()
        await FramePerf.wait(1.2)
        #expect(!sound.isEmpty && sound.allSatisfy { $0 })
        #expect(canvas.repairs > repairs)
        #expect(surface.layer === surface.root && layers.fill.superlayer === surface.root && masked.layer?.mask === layers.clip)
        #expect(layers.rim != nil && layers.rim === canvas.rimCarrier?.layer)
        let outside = Self.blackOutside(canvas: canvas, expected: rig.director.model.restGeometry)
        #expect(outside.outside == 0 && outside.inside > 1000, "\(outside)")
        // A layer that takes no mask: the canvas falls back to SwiftUI's outline.
        var fell = false
        canvas.fellBack = { fell = true }
        masked.layer = RefusingLayer()
        #expect(!canvas.ensure())
        #expect(fell && canvas.outline == .swiftUI && rig.ui.outline == .swiftUI)
        #expect(rig.host.superview === rig.window.contentView && canvas.surfaceView == nil && surface.superview == nil)
        rig.stop()
    }

    /// A layer that will not take a mask, standing in for whatever could keep the outline off the content.
    final class RefusingLayer: CALayer {
        override var mask: CALayer? {
            get { nil }
            set {}
        }
    }

    /// A display change: the canvas takes its new size and the model snaps to its rest there; the layers follow, masked,
    /// the black the new rest's outline. A scale change puts the shape layers at the display's scale.
    @Test func aDisplayOrScaleChangeKeepsTheLayers() async throws {
        _ = NSApplication.shared
        let (rig, _) = await Self.rig(.coreAnimation)
        let canvas = rig.canvas, layers = canvas.layers
        rig.open()
        await FramePerf.wait(0.1)
        // A taller display mid-open.
        let size = CGSize(width: IslandPanelSizing.canvasWidth, height: 1117)
        canvas.resize(size)
        var metrics = rig.director.model.metrics
        metrics.targets.notch = CGSize(width: 200, height: 38)
        rig.director.send(.display(metrics))
        #expect(layers.fill.frame.size == size && layers.clip.frame.size == size)
        #expect(canvas.maskedView?.frame.size == size && canvas.surfaceView?.frame.size == size)
        #expect(canvas.maskedView?.layer?.mask === layers.clip)
        #expect(layers.fill.animationKeys() == nil && layers.fill.path == layers.path(rig.director.model.restGeometry))
        let outside = Self.blackOutside(canvas: canvas, expected: rig.director.model.restGeometry)
        #expect(outside.outside == 0 && outside.inside > 1000, "\(outside)")
        // The display's scale.
        layers.fill.contentsScale = 1
        layers.clip.contentsScale = 1
        canvas.surfaceView?.viewDidChangeBackingProperties()
        let scale = rig.window.backingScaleFactor
        #expect(layers.fill.contentsScale == scale && layers.clip.contentsScale == scale)
        rig.stop()
    }

    /// Show as Window and back: the island folds into the notch with the layers on, the panel's content is dropped, and
    /// built again for Island it is the same canvas, masked, the black the rest's outline, nothing left animating.
    @Test func windowAndIslandKeepTheLayers() async throws {
        _ = NSApplication.shared
        let (rig, _) = await Self.rig(.coreAnimation)
        let canvas = rig.canvas, layers = canvas.layers
        rig.open()
        await FramePerf.wait(0.8)
        rig.director.send(.hide)
        await FramePerf.wait(1.2)
        #expect(!rig.director.model.inMotion)
        #expect(layers.fill.path == layers.path(rig.director.model.restGeometry))
        // Window mode: the content goes; Island: a fresh model at the idle rest, then the pill.
        rig.host.rootView = AnyView(Color.clear)
        canvas.setRimRoot(AnyView(EmptyView()))
        let targets = SurfaceTargets(notch: FramePerf.IslandRig.notch, pill: .empty)
        rig.director.reset(Model(metrics: .init(targets: targets, outline: .coreAnimation), ordered: false, at: IslandMotionDirector.now))
        rig.director.send(.show)
        rig.director.send(.pill(DIslandMotionTests.referencePill))
        await FramePerf.wait(1.2)
        #expect(canvas.outline == .coreAnimation && canvas.maskedView?.layer?.mask === layers.clip)
        #expect(layers.fill.superlayer === canvas.surfaceView?.root)
        #expect(layers.fill.animationKeys() == nil && layers.fill.path == layers.path(rig.director.model.restGeometry))
        let outside = Self.blackOutside(canvas: canvas, expected: rig.director.model.restGeometry)
        #expect(outside.outside == 0 && outside.inside > 100, "\(outside)")
        rig.stop()
    }

    /// Every panel snap of an open, a card and back, a close, a swell and an unswell: the layers are sound when the snap
    /// is done, and what the black draws then (the committed plan, as the render server would) is inside the new
    /// panel: a growth takes it in before it grows, a shrink comes once it fits.
    @Test func everySnapKeepsTheBlackInsideThePanel() async throws {
        _ = NSApplication.shared
        let (rig, _) = await Self.rig(.coreAnimation)
        var checked = 0, worst: CGFloat = 0
        var unsound = 0
        rig.afterSnap = { extent, ok in
            checked += 1
            if !ok { unsound += 1 }
            CATransaction.flush()
            guard let box = rig.canvas.layers.fill.presentation()?.path?.boundingBoxOfPath, !box.isNull else { return }
            let canvasWidth = IslandPanelSizing.canvasWidth
            let panel = CGRect(x: canvasWidth / 2 - extent.left, y: 0, width: extent.width, height: extent.height)
            worst = max(worst, panel.minX - box.minX, box.maxX - panel.maxX, box.maxY - panel.maxY)
        }
        for step in [{ rig.open() }, { rig.present(.card(sessionID: FixtureSessionFeed.ID.approval)) }, { rig.present(.list) },
                     { rig.director.send(.close(.fold)) }, { rig.director.send(.swell(true)) }, { rig.director.send(.swell(false)) }] as [@MainActor () -> Void] {
            FramePerf.inTurn(step)
            await FramePerf.wait(0.8)
        }
        rig.afterSnap = nil
        print("snaps \(checked), unsound \(unsound), black beyond the panel by at most \(worst) pt")
        #expect(checked >= 6 && unsound == 0)
        #expect(worst <= 0.5)
        rig.stop()
    }

    /// Diagnostics › Motion › Outline switched at rest: Core Animation's views come around the same hosting view (its
    /// SwiftUI state kept) and go again; the views' copy follows; the model takes its shoulder gate or gives it up.
    @Test func switchingTheOutlineKeepsTheHostingView() async throws {
        _ = NSApplication.shared
        let (rig, _) = await Self.rig(.swiftUI)
        let canvas = rig.canvas, host = rig.host
        #expect(host.superview === rig.window.contentView && rig.ui.outline == .swiftUI)
        canvas.setOutline(.coreAnimation)
        rig.director.surface = canvas.layers
        rig.director.send(.outline(.coreAnimation))
        #expect(host.superview === canvas.maskedView && rig.ui.outline == .coreAnimation)
        #expect(rig.director.model.metrics.outline == .coreAnimation && rig.director.model.values[.shoulders] != nil)
        #expect(canvas.layers.fill.path == canvas.layers.path(rig.director.model.restGeometry))
        canvas.setOutline(.swiftUI)
        rig.director.surface = nil
        rig.director.send(.outline(.swiftUI))
        #expect(host.superview === rig.window.contentView && canvas.surfaceView == nil && rig.ui.outline == .swiftUI)
        #expect(rig.director.model.values[.shoulders] == nil)
        // The setting: persisted under its key.
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppSettings(defaults: defaults).islandOutline == AppSettings.defaultOutline)
        AppSettings(defaults: defaults).islandOutline = .swiftUI
        #expect(defaults.string(forKey: "ji.diagnostics.islandOutline") == "swiftUI" && AppSettings(defaults: defaults).islandOutline == .swiftUI)
        rig.stop()
    }

    /// Back to SwiftUI's outline, by the setting at rest or by the fall back at rest or mid-open: SwiftUI's clip, which
    /// drew nothing while Core Animation's outline did, draws the island at once where its box has it, never growing
    /// from nothing on the curves the last motion left there (at rest the pill was drawn 0 × 0, 0.7 × 0.1, 1.9 × 0.3 …
    /// over 244 frames: the island vanished and grew back).
    @Test(arguments: ["setting", "fall back", "fall back mid-open"])
    func backToSwiftUIsOutlineDrawsTheIslandWhereItIs(_ how: String) async throws {
        _ = NSApplication.shared
        let (rig, _) = await Self.rig(.coreAnimation)
        let canvas = rig.canvas
        rig.open()
        await FramePerf.wait(0.8)
        let island = rig.director.model.restGeometry
        rig.director.send(.close(.fold))
        await FramePerf.wait(1.2)
        #expect(!rig.director.model.inMotion)
        let pill = rig.director.model.restGeometry
        if how == "fall back mid-open" {
            rig.open()
            await FramePerf.wait(0.06)
        }
        let before = rig.outlines.paths.count
        canvas.fellBack = { [director = rig.director] in
            director.surface = nil
            director.send(.outline(.swiftUI))
        }
        if how == "setting" {
            canvas.setOutline(.swiftUI)
            rig.director.surface = nil
            rig.director.send(.outline(.swiftUI))
        } else {
            canvas.maskedView?.layer = RefusingLayer()
            #expect(!canvas.ensure())
        }
        #expect(canvas.outline == .swiftUI && rig.ui.outline == .swiftUI)
        await FramePerf.wait(0.8)
        let drawn = rig.outlines.paths.dropFirst(before).map(\.geometry)
        func size(_ g: SurfaceGeometry?) -> String { g.map { String(format: "%.1f × %.1f", Double($0.width), Double($0.height)) } ?? "none" }
        let smallest = drawn.min { $0.width * $0.height < $1.width * $1.height }
        print("\(how): \(drawn.count) outlines; first \(size(drawn.first)), smallest \(size(smallest)), last \(size(drawn.last)); pill \(size(pill)), island \(size(island))")
        #expect(!drawn.isEmpty, "\(how)")
        // Never smaller than the pill it came from: nothing vanishes.
        #expect(drawn.allSatisfy { $0.width >= pill.width - 0.5 && $0.height >= pill.height - 0.5 }, "\(how)")
        if how == "fall back mid-open" {
            // A jump towards where the open goes, never beyond it, and it rests there.
            #expect(drawn.allSatisfy { $0.width <= island.width + 0.5 && $0.height <= island.height + 0.5 }, "\(how)")
            #expect(drawn.last.map { abs($0.width - island.width) < 0.5 && abs($0.height - island.height) < 0.5 } == true, "\(how)")
        } else {
            #expect(drawn.allSatisfy { abs($0.width - pill.width) < 0.5 && abs($0.height - pill.height) < 0.5 }, "\(how)")
        }
        rig.stop()
    }

    // MARK: F5 on SwiftUI's outline

    /// SwiftUI's outline draws Refined's two springs as the model plays them (the width's own vector, the height's own):
    /// every frame it drew lies on the model's path from the pill to the island (how far the width has come for how far
    /// the height has) within 3 %, which one vector on one spring would not (it would draw the width on the height's
    /// spring). Original's open is recorded: its height's job timer moves it off the model's path by its lateness.
    @Test func swiftUIsOutlineDrawsTheTwoSprings() async throws {
        _ = NSApplication.shared
        for tuning in [MotionTuning(), CoreAnimationOutlineTests.refined] {
            let (rig, _) = await Self.rig(.swiftUI, tuning: tuning)
            let start = rig.director.model
            rig.open()
            await FramePerf.wait(0.7)
            let renders = rig.outlines.paths
            let from = start.restGeometry, to = rig.director.model.restGeometry
            // The model's path: the width's progress for the height's, at each millisecond.
            var model = start
            _ = model.handle(.open(.hover, .list), at: 0)
            var path: [(w: CGFloat, h: CGFloat)] = []
            for ms in 0...700 {
                _ = model.advance(to: Double(ms) / 1000)
                let g = model.surface(at: Double(ms) / 1000)
                path.append(((g.width - from.width) / (to.width - from.width), (g.height - from.height) / (to.height - from.height)))
            }
            var worst: CGFloat = 0, checked = 0
            for render in renders {
                let g = render.geometry
                let w = (g.width - from.width) / (to.width - from.width), h = (g.height - from.height) / (to.height - from.height)
                guard h > 0.05, h < 0.9 else { continue }
                // The model's width progress where its height had come as far (the first time: the height only rises there).
                guard let i = path.firstIndex(where: { $0.h >= h }), i > 0 else { continue }
                let a = path[i - 1], b = path[i]
                let u = b.h > a.h ? (h - a.h) / (b.h - a.h) : 0
                worst = max(worst, abs(w - (a.w + (b.w - a.w) * u)))
                checked += 1
            }
            print("\(tuning.motion): \(checked) frames checked against the model's path, worst width progress off by \(worst)")
            // Refined's two springs start in the event's own turn. Original's height starts on a job, which SwiftUI
            // plays from when its timer fires: off the model's path by as much as the timer is late (0.016 to 0.034
            // run alone, over 0.08 once in the suite), so it is recorded, not held to a bound.
            #expect(checked > 10, "\(tuning.motion): \(checked) frames")
            if tuning.splitsSurface { #expect(worst <= 0.03, "\(tuning.motion): \(worst) over \(checked)") }
            rig.stop()
        }
    }
}
