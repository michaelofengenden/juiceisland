import AppKit
import CoreGraphics
import Darwin
import Foundation
import QuartzCore
import Testing
@testable import JuiceIslandUI

/// Motion: Liquid on the live island's Core Animation outline (`FramePerf.IslandRig`, in a window never ordered in), in
/// Black and in Glass: nothing ticks at rest, the fill, the mask and the glass's path layers draw one union on one clock,
/// a stalled main thread holds none of it, and Core Animation's keyframes are the model's union (the build spec §8.1).
@MainActor
@Suite(.serialized)
struct LiquidLiveTests {
    static let liquid = MotionTuning(motion: .liquid, hover: .quick)

    static func rig(_ theme: JuiceTheme) async -> (FramePerf.IslandRig, CoreAnimationOutlineLiveTests.PlanLog) {
        let rig = FramePerf.IslandRig(style: .clean, glyph: .liquid, glyphsMove: false, outline: .coreAnimation, tuning: liquid, theme: theme)
        let log = CoreAnimationOutlineLiveTests.PlanLog()
        rig.canvas.layers.onInstall = { plan, at in log.plans.append((plan, at)) }
        await rig.start()
        return (rig, log)
    }

    static func animated(_ rig: FramePerf.IslandRig) -> [CALayer] {
        let layers = rig.canvas.layers
        return [layers.fill, layers.clip, layers.rim].compactMap { $0 } + (layers.glass?.pathLayers ?? [])
    }

    @Test(arguments: [JuiceTheme.black, .glass])
    func nothingTicksAtRest(_ theme: JuiceTheme) async throws {
        _ = NSApplication.shared
        let (rig, log) = await Self.rig(theme)
        #expect(theme == .black || rig.canvas.layers.glass != nil)
        for step in [{ rig.open() }, { rig.director.send(.close(.fold)) }, { rig.open() }] as [@MainActor () -> Void] {
            step()
            // At rest with every layer swept, however late a loaded run's main actor lets the jobs and the sweep run
            // (looks counted, not a set 1.8 s, P1258); a layer never swept still fails here.
            await FramePerf.settle(rig) {
                !rig.director.model.inMotion && !rig.ui.liquid.playing && Self.animated(rig).allSatisfy { $0.animationKeys() == nil }
            }
            #expect(Self.animated(rig).allSatisfy { $0.animationKeys() == nil }, "\(theme): an animation left on a layer")
            let model = rig.director.model
            #expect(!model.inMotion && model.reservoir == nil && model.liquid(at: IslandMotionDirector.now).isRest, "\(theme)")
            #expect(!rig.ui.liquid.playing)
            #expect(rig.canvas.layers.fill.path == rig.canvas.layers.path(model.restGeometry), "\(theme): the rest is not today's path")
        }
        #expect(log.plans.contains { $0.plan.drawsLiquid }, "\(theme): no liquid plan played")
        rig.stop()
    }

    /// Polled every 4 ms through an open, a close and a close reversed: the fill and the mask carry the same keyframes
    /// (the same paths) from one begin time, the glass's path layers the same union flipped, and what each draws now
    /// stands at most 0.01 pt from the others.
    @Test(arguments: [JuiceTheme.black, .glass])
    func theMaskIsTheFill(_ theme: JuiceTheme) async throws {
        _ = NSApplication.shared
        let (rig, log) = await Self.rig(theme)
        let layers = rig.canvas.layers
        let height = layers.canvas.height
        var installs = 0
        // Right after each event's install: the same paths on the fill and the mask, from one begin time; as many on the
        // glass's path layers.
        func sameKeyframes() {
            guard let fill = layers.fill.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation,
                  log.plans.last?.plan.drawsLiquid == true else { return }
            installs += 1
            let clip = layers.clip.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation
            let values = (fill.values as? [CGPath]) ?? [], clipValues = (clip?.values as? [CGPath]) ?? []
            #expect(!values.isEmpty && values.count == clipValues.count && zip(values, clipValues).allSatisfy { $0 === $1 },
                    "\(theme): the fill and the mask carry other paths")
            #expect(fill.beginTime == clip?.beginTime)
            for layer in layers.glass?.pathLayers ?? [] {
                let a = layer.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation
                #expect((a?.values?.count ?? 0) == values.count, "\(theme): the glass carries other keyframes")
                #expect(a?.beginTime == fill.beginTime, "\(theme): the glass begins apart from the fill")
            }
        }
        let poll = Poll(fill: layers.fill, clip: layers.clip, glass: layers.glass?.pathLayers ?? [], height: height,
                        key: IslandSurfaceLayers.key)
        poll.start()
        var commits: [TimeInterval] = []
        for (open, wait) in [(true, 0.9), (false, 0.12), (true, 0.9), (false, 1.0)] {
            if open { rig.open() } else { rig.director.send(.close(.fold)) }
            sameKeyframes()
            // The event's install committed now, as the run loop would at the end of this turn (late under load).
            CATransaction.flush()
            commits.append(ProcessInfo.processInfo.systemUptime)
            await FramePerf.wait(wait)
        }
        let reads = poll.stop()
        // Reads from an install to its commit are left out: until the commit, `presentation()` off the main thread can
        // see one layer's new path without its animation, which the render server, given only commits, never draws
        // (`CoreAnimationOutlineLiveTests.committed`); a read within an install, one layer's plan new and the next's
        // old, is left out by the poll itself. Both showed the whole island apart (293 pt) in loaded runs (P1257).
        let ends = rig.probe.turns.map { Double($0.end) / 1e9 } + commits
        let windows = log.plans.map { install in (install.at - 0.001, ends.filter { $0 >= install.at }.min() ?? .infinity) }
        func inWindow(_ from: TimeInterval, _ to: TimeInterval) -> Bool { windows.contains { to >= $0.0 && from <= $0.1 } }
        let kept = reads.samples.filter { !inWindow($0.from, $0.to) }
        // A torn read is the main thread midway through handing a plan over, or through a sweep taking ended animations
        // off; anything else is the layers out of step (a glass that begins apart from the fill, a mask with other
        // paths), which this test exists to catch, so it is never dropped quietly (P1283).
        let unexplained = reads.torn.filter { !$0.sweep && !inWindow($0.from, $0.to) }
        let clip = kept.map(\.clip).max() ?? 0, glass = kept.map(\.glass).max() ?? 0
        print("\(theme): \(kept.count) reads, fill against mask \(clip) pt, against the glass \(glass) pt, \(installs) liquid plans; "
              + "\(reads.samples.count - kept.count) reads before a commit and \(reads.torn.count) within an install or a sweep "
              + "left out, \(unexplained.count) out of step")
        #expect(installs >= 3 && kept.count > 300)
        #expect(unexplained.isEmpty, "\(theme): \(unexplained.count) reads found the layers out of step outside an install")
        #expect(clip <= 0.01 && glass <= 0.01, "\(theme): fill against mask \(clip) pt, against the glass \(glass) pt")
        rig.stop()
    }

    /// SwiftUI's outline: the liquid values play from the model's plan while it moves (the clip draws the union frame by
    /// frame), and at rest nothing plays, the clip draws nothing liquid (today's outline) and builds no outline at all.
    @Test(arguments: [JuiceTheme.black, .glass])
    func swiftUIsOutlinePlaysTheUnionAndRests(_ theme: JuiceTheme) async throws {
        _ = NSApplication.shared
        // The sessions' clock pinned: each minute's turn redraws the rows' ages, and the island with them, which a loaded
        // run's long look at the rest caught as the clip drawing (once a minute, a few seconds past it; P1261).
        let made = Date()
        let rig = FramePerf.IslandRig(style: .clean, glyph: .liquid, glyphsMove: false, outline: .swiftUI, tuning: Self.liquid, theme: theme,
                                      sessionsClock: { made })
        await rig.start()
        await FramePerf.rest(rig)
        for open in [true, false] {
            // Some frame draws the union's own while the plan plays: each look lays the rig out and commits it as a
            // display frame would (`FramePerf.frame`). A frame is owed only by a look made while the plan's union draws
            // more than the body (`LiquidParams.isRest` false, now and a moment on); a main actor held through all of
            // that (a full run's) makes none, and the step plays again from its rest, at most four times (P1258).
            var drawn = false, owed = false
            for attempt in 0..<5 where !drawn && !owed {
                if attempt > 0 {
                    if open { rig.director.send(.close(.fold)) } else { rig.open() }
                    await FramePerf.settle(rig) { !rig.director.model.inMotion && !rig.ui.liquid.playing }
                }
                let before = rig.outlines.paths.count
                if open { rig.open() } else { rig.director.send(.close(.fold)) }
                #expect(rig.ui.liquid.playing && rig.ui.liquid.plan?.drawsLiquid == true, "\(theme): nothing liquid plays")
                let plan = rig.ui.liquid.plan
                let end = plan?.end ?? 0
                await Looks.until(10, every: 0.02) {
                    let now = IslandMotionDirector.now
                    let liquid = [now, now + 0.03].allSatisfy { plan?.liquid(at: $0).map { !$0.isRest } ?? false }
                    FramePerf.frame(rig)
                    drawn = rig.outlines.paths.dropFirst(before).contains(where: \.liquid)
                    owed = owed || liquid
                    return drawn || IslandMotionDirector.now >= end
                }
            }
            #expect(drawn, "\(theme): the clip draws nothing liquid mid-motion")
            await FramePerf.settle(rig) { !rig.director.model.inMotion && !rig.ui.liquid.playing }
            #expect(!rig.ui.liquid.playing && (rig.ui.liquid.params?.isRest ?? true), "\(theme): still playing at rest")
            // At rest the clip builds nothing: once the motion's last frames are drawn (late under load), a stretch of
            // looks, each a frame, adds none. A clip that drew every frame at rest never goes still and fails here.
            var still = 0, last = rig.outlines.paths.count
            await FramePerf.settle(rig) {
                let count = rig.outlines.paths.count
                still = count == last ? still + 1 : 0
                last = count
                return still >= 6
            }
            let rest = rig.outlines.paths.count
            for _ in 0..<6 {
                await FramePerf.wait(0.05)
                FramePerf.frame(rig)
            }
            #expect(rig.outlines.paths.count == rest, "\(theme): the clip draws at rest")
        }
        rig.stop()
    }

    /// Reads the fill's, the mask's and the glass's presentation every 4 ms on its own thread, each read with when it
    /// began and ended and how far the mask and the glass stood from the fill. A read that crossed an install is not
    /// kept (`torn`): the main thread hands a plan to the layers one after another, so a read between two of them sees
    /// the new plan on one and the old on the next. One install gives every layer the same begin and the fill and the
    /// mask the same path, so a read is whole when they share both, the same before and after it. Each torn read keeps
    /// its times, and whether a sweep could explain it (`Torn.sweep`), for the test to hold the rest against the installs.
    final class Poll: @unchecked Sendable {
        struct Read { var from: TimeInterval; var to: TimeInterval; var clip: CGFloat; var glass: CGFloat }
        /// A torn read: `sweep` when the layers stood, before and after it, as a sweep leaves them midway (each layer's
        /// animation gone or the one plan's, the fill's and the mask's paths one).
        struct Torn { var from: TimeInterval; var to: TimeInterval; var sweep: Bool }
        nonisolated(unsafe) let fill: CAShapeLayer
        nonisolated(unsafe) let clip: CAShapeLayer
        nonisolated(unsafe) let glass: [CAShapeLayer]
        let height: CGFloat
        let key: String
        private let lock = NSLock()
        private var running = true
        private var samples: [Read] = []
        private var torn: [Torn] = []

        init(fill: CAShapeLayer, clip: CAShapeLayer, glass: [CAShapeLayer], height: CGFloat, key: String) {
            self.fill = fill
            self.clip = clip
            self.glass = glass
            self.height = height
            self.key = key
        }

        /// Each layer's animation's begin (-1 for none), and whether the fill's and the mask's paths are one.
        private func plan() -> (begins: [CFTimeInterval], same: Bool) {
            (([fill, clip] + glass).map { $0.animation(forKey: key)?.beginTime ?? -1 }, fill.path == clip.path)
        }

        /// As a sweep leaves the layers midway: one plan's begin on those it has not reached yet, none on the rest.
        private static func sweeping(_ plan: (begins: [CFTimeInterval], same: Bool)) -> Bool {
            plan.same && Set(plan.begins.filter { $0 >= 0 }).count <= 1
        }

        func start() {
            let thread = Thread { [self] in
                func d(_ a: CGRect, _ b: CGRect) -> CGFloat {
                    max(abs(a.minX - b.minX), abs(a.maxX - b.maxX), abs(a.minY - b.minY), abs(a.maxY - b.maxY))
                }
                while true {
                    lock.lock()
                    let go = running
                    lock.unlock()
                    guard go else { return }
                    let from = ProcessInfo.processInfo.systemUptime, before = plan()
                    CATransaction.flush()
                    // One transaction: every layer's presentation at the same moment.
                    let f = fill.presentation()?.path?.boundingBoxOfPath, c = clip.presentation()?.path?.boundingBoxOfPath
                    let g = glass.compactMap { $0.presentation()?.path?.boundingBoxOfPath }
                    CATransaction.flush()
                    let after = plan(), to = ProcessInfo.processInfo.systemUptime
                    lock.lock()
                    if before != after || Set(before.begins).count != 1 || !before.same {
                        torn.append(Torn(from: from, to: to, sweep: Self.sweeping(before) && Self.sweeping(after)))
                    } else if let f, let c, !f.isNull, !c.isNull {
                        // The glass is y up in the canvas.
                        let down = g.filter { !$0.isNull }
                            .map { CGRect(x: $0.minX, y: height - $0.maxY, width: $0.width, height: $0.height) }
                        samples.append(Read(from: from, to: to, clip: d(f, c), glass: down.map { d(f, $0) }.max() ?? 0))
                    }
                    lock.unlock()
                    usleep(4000)
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        func stop() -> (samples: [Read], torn: [Torn]) {
            lock.lock()
            defer { lock.unlock() }
            running = false
            return (samples, torn)
        }
    }

    /// A 50 ms busy loop on the main thread 100 ms into Liquid's open: the drawn union keeps moving (never still for
    /// more than a few milliseconds while the model's moves more than a point) and stays within a point of the model's.
    @Test func aStalledMainThreadHoldsNoneOfTheOutline() async throws {
        _ = NSApplication.shared
        for stall in [0.0, 0.05] {
            let (rig, log) = await Self.rig(.black)
            let sampler = CoreAnimationOutlineLiveTests.Sampler(clip: rig.canvas.layers.clip, rim: rig.canvas.layers.rim)
            sampler.start()
            try? await Task.sleep(for: .milliseconds(40))
            let t0 = ProcessInfo.processInfo.systemUptime
            FramePerf.inTurn { rig.open() }
            try? await Task.sleep(for: .milliseconds(100))
            if stall > 0 { _ = await CoreAnimationOutlineLiveTests.stall(stall) }
            try? await Task.sleep(for: .milliseconds(600))
            let samples = CoreAnimationOutlineLiveTests.committed(sampler.stop(), rig: rig, log: log)
            func union(_ s: TimeInterval) -> CGFloat? {
                guard let plan = log.plans.last(where: { $0.plan.start <= s })?.plan, let p = plan.liquid(at: s) else { return nil }
                return LiquidPath.extent(plan.geometry(at: s), p).height
            }
            // From the open's first commit: until its turn ends nothing is drawn (the trigger turn, measured by the
            // frame harness), stall or none.
            let first = samples.first { $0.t >= t0 && $0.h > samples[0].h + 0.01 }?.t ?? t0
            var frozen = 0.0, lag: CGFloat = 0, run: CoreAnimationOutlineLiveTests.Sampler.Sample?
            for s in samples where s.t >= first {
                guard let h = union(s.t) else { continue }
                if let r = run, abs(s.h - r.h) < 0.01 {
                    if let a = union(r.t), abs(a - h) > 1 { frozen = max(frozen, s.t - r.t) }
                } else {
                    run = s
                }
                // The sample's clock and the transaction's can stand a fraction of a millisecond apart, and a preempted
                // read more: held from 2 ms before the read's first clock to 2 ms after its last (`Sample.end`, P1262).
                let near = stride(from: s.t - 0.002, through: max(s.t, s.end) + 0.002, by: 0.0002).compactMap { union($0) }
                lag = max(lag, near.map { abs(s.h - $0) }.min() ?? abs(s.h - h))
            }
            print("Liquid, stall \(Int(stall * 1000)) ms: frozen \(frozen * 1000) ms, lag \(lag) pt, \(samples.count) samples")
            #expect(samples.count > 200)
            #expect(frozen * 1000 <= 6 && lag <= 1, "stall \(stall): frozen \(frozen * 1000) ms, lag \(lag) pt")
            rig.stop()
        }
    }

    /// Core Animation's keyframes are the model's union: each of the fill's keyframes of an open and of a close, drawn,
    /// against the model's union at that sample drawn the same way, 0 pixels apart by more than 64 levels; and the
    /// glass's keyframes, flipped, draw the fill's.
    @Test(arguments: [JuiceTheme.black, .glass])
    func coreAnimationPlaysTheUnion(_ theme: JuiceTheme) async throws {
        _ = NSApplication.shared
        let (rig, log) = await Self.rig(theme)
        let layers = rig.canvas.layers
        var worst = 0, glassWorst = 0, drawn = 0
        for step in [{ rig.open() }, { rig.director.send(.close(.fold)) }] as [@MainActor () -> Void] {
            step()
            let fill = try #require(layers.fill.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation)
            let values = try #require(fill.values as? [CGPath])
            let plan = try #require(log.plans.last?.plan)
            let liquid = try #require(plan.liquid)
            let glass = (layers.glass?.floorLayer.animation(forKey: IslandSurfaceLayers.key) as? CAKeyframeAnimation)?.values as? [CGPath]
            // Its keyframes: the plan's samples and the ones between them where the union moves along curves.
            let keys = plan.liquidKeyframes()
            _ = liquid
            #expect(keys.count == values.count, "\(theme): \(values.count) keyframes for \(keys.count)")
            for i in stride(from: 0, to: min(values.count, keys.count), by: 6) {
                let model = LiquidPath.cgPath(keys[i].body, keys[i].params, centreX: layers.canvas.width / 2)
                worst = max(worst, Self.differing(Self.render(values[i]), Self.render(model)))
                if let glass {
                    var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: layers.canvas.height)
                    let down = try #require(glass[i].copy(using: &flip))
                    glassWorst = max(glassWorst, Self.differing(Self.render(values[i]), Self.render(down)))
                }
                drawn += 1
            }
            await FramePerf.wait(1.4)
        }
        print("\(theme): \(drawn) keyframes, \(worst) px off the model's union, the glass \(glassWorst) px off the fill")
        #expect(drawn > 40 && worst == 0 && glassWorst == 0, "\(theme): \(worst), \(glassWorst)")
        rig.stop()
    }

    /// The top 420 points of the canvas at 2×, alpha only.
    static func render(_ path: CGPath) -> [UInt8] {
        let w = Int(IslandPanelSizing.canvasWidth * 2), h = 840
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 2, y: -2)
        ctx.addPath(path)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillPath()
        return pixels
    }

    static func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 64 ? 1 : 0) }
    }
}
