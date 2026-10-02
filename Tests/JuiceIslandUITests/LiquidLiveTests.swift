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
            await FramePerf.wait(1.8)
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
            }
        }
        let poll = Poll(fill: layers.fill, clip: layers.clip, glass: layers.glass?.pathLayers ?? [], height: height)
        poll.start()
        for (open, wait) in [(true, 0.9), (false, 0.12), (true, 0.9), (false, 1.0)] {
            if open { rig.open() } else { rig.director.send(.close(.fold)) }
            sameKeyframes()
            await FramePerf.wait(wait)
        }
        let result = poll.stop()
        print("\(theme): \(result.reads) reads, fill against mask \(result.clip) pt, against the glass \(result.glass) pt, \(installs) liquid plans")
        #expect(installs >= 3 && result.reads > 300)
        #expect(result.clip <= 0.01 && result.glass <= 0.01, "\(theme): \(result)")
        rig.stop()
    }

    /// SwiftUI's outline: the liquid values play from the model's plan while it moves (the clip draws the union frame by
    /// frame), and at rest nothing plays, the clip draws nothing liquid (today's outline) and builds no outline at all.
    @Test(arguments: [JuiceTheme.black, .glass])
    func swiftUIsOutlinePlaysTheUnionAndRests(_ theme: JuiceTheme) async throws {
        _ = NSApplication.shared
        let rig = FramePerf.IslandRig(style: .clean, glyph: .liquid, glyphsMove: false, outline: .swiftUI, tuning: Self.liquid, theme: theme)
        await rig.start()
        for open in [true, false] {
            let before = rig.outlines.paths.count
            if open { rig.open() } else { rig.director.send(.close(.fold)) }
            #expect(rig.ui.liquid.playing && rig.ui.liquid.plan?.drawsLiquid == true, "\(theme): nothing liquid plays")
            // The clip's frames come as the run loop turns (later under load): some frame draws the union's own.
            var drawn = false
            for _ in 0..<40 where !drawn {
                await FramePerf.wait(0.02)
                drawn = rig.outlines.paths.dropFirst(before).contains(where: \.liquid)
            }
            #expect(drawn, "\(theme): the clip draws nothing liquid mid-motion")
            await FramePerf.wait(1.8)
            #expect(!rig.ui.liquid.playing && (rig.ui.liquid.params?.isRest ?? true), "\(theme): still playing at rest")
            let rest = rig.outlines.paths.count
            await FramePerf.wait(0.3)
            #expect(rig.outlines.paths.count == rest, "\(theme): the clip draws at rest")
        }
        rig.stop()
    }

    /// Reads the fill's, the mask's and the glass's presentation every 4 ms on its own thread.
    final class Poll: @unchecked Sendable {
        nonisolated(unsafe) let fill: CAShapeLayer
        nonisolated(unsafe) let clip: CAShapeLayer
        nonisolated(unsafe) let glass: [CAShapeLayer]
        let height: CGFloat
        private let lock = NSLock()
        private var running = true
        private var result = (reads: 0, clip: CGFloat(0), glass: CGFloat(0))

        init(fill: CAShapeLayer, clip: CAShapeLayer, glass: [CAShapeLayer], height: CGFloat) {
            self.fill = fill
            self.clip = clip
            self.glass = glass
            self.height = height
        }

        func start() {
            let thread = Thread { [self] in
                while true {
                    lock.lock()
                    let go = running
                    lock.unlock()
                    guard go else { return }
                    CATransaction.flush()
                    // One transaction: every layer's presentation at the same moment.
                    let f = fill.presentation()?.path?.boundingBoxOfPath, c = clip.presentation()?.path?.boundingBoxOfPath
                    let g = glass.compactMap { $0.presentation()?.path?.boundingBoxOfPath }
                    CATransaction.flush()
                    if let f, let c, !f.isNull, !c.isNull {
                        func d(_ a: CGRect, _ b: CGRect) -> CGFloat {
                            max(abs(a.minX - b.minX), abs(a.maxX - b.maxX), abs(a.minY - b.minY), abs(a.maxY - b.maxY))
                        }
                        lock.lock()
                        result.reads += 1
                        result.clip = max(result.clip, d(f, c))
                        for box in g where !box.isNull {
                            // The glass is y up in the canvas.
                            let down = CGRect(x: box.minX, y: height - box.maxY, width: box.width, height: box.height)
                            result.glass = max(result.glass, d(f, down))
                        }
                        lock.unlock()
                    }
                    usleep(4000)
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        func stop() -> (reads: Int, clip: CGFloat, glass: CGFloat) {
            lock.lock()
            defer { lock.unlock() }
            running = false
            return result
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
                // The sample's clock and the transaction's can stand a fraction of a millisecond apart.
                let near = stride(from: -0.002, through: 0.002, by: 0.0002).compactMap { union(s.t + $0) }
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
