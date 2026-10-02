import Accelerate
import CoreGraphics
import Foundation
import Testing
@testable import JuiceIslandUI

/// Motion: Liquid's outline (`LiquidPath`): one union of always the same 45 elements, inside its extent, today's path at
/// rest, never crossing itself, its separated parts never overlapping, the neck's flag and the reservoir coming and going
/// without a jump, and a junction with nothing to join drawing nothing (the build spec §8.1).
@MainActor
struct LiquidPathTests {
    typealias Kind = LiquidPath.RecordingSink.Kind

    /// A seeded generator, so a failure repeats.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func body(_ r: inout Seeded) -> SurfaceGeometry {
        SurfaceGeometry(left: .random(in: 0...300, using: &r), right: .random(in: 0...300, using: &r), height: .random(in: 0...400, using: &r),
                        ear: .random(in: 0...20, using: &r), radius: .random(in: 0...60, using: &r), meniscus: .random(in: 0...4, using: &r))
    }

    /// A body the model can reach: about as wide either side of the centre line, past its ears.
    static func plausibleBody(_ r: inout Seeded) -> SurfaceGeometry {
        let reach = CGFloat.random(in: 30...300, using: &r), ear = CGFloat.random(in: 0...12, using: &r)
        return SurfaceGeometry(left: reach + .random(in: -20...20, using: &r), right: reach + .random(in: -20...20, using: &r),
                               height: .random(in: 0...400, using: &r), ear: ear, radius: .random(in: 0...40, using: &r),
                               meniscus: .random(in: 0...2, using: &r))
    }

    /// Values the model can reach: a pill as wide either side as the body it drains, as tall as a pill.
    static func plausibleParams(_ r: inout Seeded, buds: Bool = true) -> LiquidParams {
        var p = params(&r, buds: buds)
        if p.reservoir != nil {
            let reach = CGFloat.random(in: 60...200, using: &r)
            p.reservoir = SurfaceGeometry(left: reach + .random(in: -10...10, using: &r), right: reach + .random(in: -10...10, using: &r),
                                          height: .random(in: 20...60, using: &r), ear: .random(in: 0...10, using: &r),
                                          radius: .random(in: 0...20, using: &r))
        }
        return p
    }

    static func params(_ r: inout Seeded, buds: Bool = true) -> LiquidParams {
        var p = LiquidParams()
        p.sag = .random(in: -5...40, using: &r)
        p.round = .random(in: -5...40, using: &r)
        if buds, Bool.random(using: &r) {
            p.budGap = .random(in: -60...80, using: &r)
            p.budHalf = .random(in: 0...200, using: &r)
            p.budHeight = .random(in: 0...200, using: &r)
            p.budRadius = .random(in: 0...60, using: &r)
            p.joined = Bool.random(using: &r) ? 1 : 0
            p.lipBody = .random(in: 0...20, using: &r)
            p.lipBead = .random(in: 0...20, using: &r)
            p.tension = .random(in: 0...20, using: &r)
        }
        if Bool.random(using: &r) {
            p.reservoir = SurfaceGeometry(left: .random(in: 0...200, using: &r), right: .random(in: 0...200, using: &r),
                                          height: .random(in: 0...60, using: &r), ear: .random(in: 0...10, using: &r),
                                          radius: .random(in: 0...20, using: &r))
        }
        return p
    }

    /// The degenerate and extreme values: zeros, the huge, the negative, the non-finite.
    static var degenerate: [(SurfaceGeometry, LiquidParams)] {
        let bodies = [SurfaceGeometry.zero, SurfaceGeometry(left: 1e6, right: 1e6, height: 1e6, ear: 1e6, radius: 1e6),
                      SurfaceGeometry(left: -10, right: -10, height: -10, ear: -1, radius: -1),
                      SurfaceGeometry(left: .nan, right: 100, height: 100, ear: 5, radius: 10),
                      SurfaceGeometry(left: 100, right: .infinity, height: 100, ear: 5, radius: 10),
                      SurfaceGeometry(left: 120, right: 120, height: 300, ear: 6, radius: 24)]
        var ps: [LiquidParams] = [LiquidParams()]
        for key in LiquidKey.allCases {
            for v: CGFloat in [0, -1e6, 1e6, .nan, .infinity, -.infinity] {
                var p = LiquidParams(); p[key] = v; ps.append(p)
                var q = p; q.reservoir = SurfaceGeometry(left: 90, right: 90, height: 33, ear: 4, radius: 10); ps.append(q)
            }
        }
        var bad = LiquidParams(); bad.reservoir = SurfaceGeometry(left: .nan, right: 1, height: 1, ear: 0, radius: 0); ps.append(bad)
        var huge = LiquidParams(); huge.reservoir = SurfaceGeometry(left: 1e6, right: 1e6, height: 1e6, ear: 1e6, radius: 1e6); ps.append(huge)
        return bodies.flatMap { b in ps.map { (b, $0) } }
    }

    static let template: [Kind] = [.move, .line] + LiquidPath.sideCurves.map { $0 ? .curve : .line }
        + LiquidPath.sideCurves.reversed().map { $0 ? .curve : .line } + [.close]

    @Test func sameElementsForAnyValues() {
        #expect(Self.template.count == LiquidPath.elementCount)
        var r = Seeded(state: 1)
        var cases = Self.degenerate
        for _ in 0..<5000 { cases.append((Self.body(&r), Self.params(&r))) }
        var wrong = 0
        for (g, p) in cases {
            let kinds = LiquidPath.elements(g, p).map(\.kind)
            if kinds != Self.template { wrong += 1 }
            #expect(kinds == Self.template, "\(g) \(p): \(kinds.count) elements")
            if wrong > 5 { break }
        }
    }

    /// A keyframe's path written from its points (`PointsSink.replay`, as the layers build them) is the union's own path,
    /// element for element, on bodies as wide on both sides (the left side shared) and not.
    @Test func aPathFromItsPointsIsTheUnionsOwn() {
        var r = Seeded(state: 7)
        var cases = Self.degenerate
        for k in 0..<3000 {
            var g = Self.body(&r), p = Self.params(&r)
            if k % 2 == 0 {
                g.left = g.right
                if var pill = p.reservoir { pill.left = pill.right; p.reservoir = pill }
            }
            cases.append((g, p))
        }
        for (g, p) in cases {
            let points = LiquidPath.PointsSink(g, p)
            #expect(LiquidPath.cgPath(points, centreX: 240) == LiquidPath.cgPath(g, p, centreX: 240), "\(g) \(p)")
        }
    }

    @Test func theUnionStaysInsideItsExtent() {
        var r = Seeded(state: 2)
        for _ in 0..<3000 {
            let g = Self.body(&r), p = Self.params(&r)
            let exact = LiquidPath.extent(g, p), quick = LiquidPath.bounds(g, p)
            let box = LiquidPath.cgPath(g, p, centreX: 0).boundingBoxOfPath
            #expect(box.minX >= -exact.left - 1e-6 && box.maxX <= exact.right + 1e-6 && box.maxY <= exact.height + 1e-6 && box.minY >= -1e-6,
                    "\(g) \(p): the path \(box) outside its extent \(exact)")
            #expect(exact.left <= quick.left + 1e-6 && exact.right <= quick.right + 1e-6 && exact.height <= quick.height + 1e-6,
                    "\(g) \(p): extent \(exact) outside the quick bounds \(quick)")
        }
    }

    /// Every liquid value at rest draws today's continuous outline within 0.05 pt, for the pill, the island and the
    /// no-notch top bar; and a reservoir equal to the body draws the body.
    @Test func theRestIsTodaysPath() {
        for g in Self.restShapes {
            let today = IslandSurfaceLayers.fixedPath(g, originX: -g.left, top: 0, flipHeight: nil, continuous: true)
            let rest = LiquidPath.cgPath(g, .rest, centreX: 0)
            #expect(Self.hausdorff(today, rest) < 0.05, "\(g): rest \(Self.hausdorff(today, rest))")
            var landed = LiquidParams(); landed.reservoir = g
            let pill = LiquidPath.cgPath(g, landed, centreX: 0)
            #expect(Self.hausdorff(today, pill) < 0.05, "\(g): landed \(Self.hausdorff(today, pill))")
        }
    }

    static var restShapes: [SurfaceGeometry] {
        let notch = SurfaceTargets(notch: DIslandMotionTests.notch, pill: DIslandMotionTests.referencePill)
        let bar = SurfaceTargets(notch: nil, pill: CoreAnimationOutlineTests.bar)
        let open = LiquidRenders.model(.init(name: "open", events: [(0, .open(.hover, .list))], to: 2), until: 2)
        return [notch.closed, bar.closed, open.surface(at: 2), notch.swell(), notch.idle]
    }

    @Test func noSelfIntersection() {
        var r = Seeded(state: 3)
        var shapes: [(SurfaceGeometry, LiquidParams)] = []
        for _ in 0..<1500 { shapes.append((Self.plausibleBody(&r), Self.plausibleParams(&r))) }
        shapes += LiquidMotionTests.scriptedFrames().map { ($0.body, $0.params) }
        var bad = 0
        for (g, p) in shapes {
            let crossings = Self.crossings(Self.polyline(LiquidPath.cgPath(g, p, centreX: 0)))
            if crossings > 0 { bad += 1 }
            #expect(crossings == 0, "\(g) \(p): \(crossings) crossings")
            if bad > 5 { break }
        }
    }

    /// Apart, the body's stub ends above the bud's (the bridge is never negative), whatever the stubs ask for.
    @Test func separatedPartsNeverOverlap() {
        var r = Seeded(state: 4)
        var apart = 0
        for _ in 0..<4000 {
            let g = Self.plausibleBody(&r)
            var p = Self.plausibleParams(&r)
            p.joined = 0
            p.budHalf = max(p.budHalf, 20)
            p.budHeight = max(p.budHeight, 20)
            p.budGap = .random(in: 0...60, using: &r)
            let e = LiquidPath.elements(g, p)
            // The right side's upper neck (13) and bridge (14), after the move and the top line.
            let upper = e[2 + 13].points.last!, bridge = e[2 + 14].points.last!
            if bridge.y > upper.y + 1e-9 { apart += 1 }
            #expect(bridge.y >= upper.y - 1e-9, "\(g) \(p): the bridge \(bridge.y - upper.y)")
            #expect(Self.crossings(Self.polyline(LiquidPath.cgPath(g, p, centreX: 0))) == 0, "\(g) \(p)")
        }
        #expect(apart > 100)
    }

    /// The neck's flag flips where the joined neck's waist reaches nothing and the stubs are its fillet's radius: the
    /// two outlines agree there within 0.05 pt. And a reservoir comes and goes where it draws nothing of its own.
    @Test func thePinchAndJoinAreContinuous() {
        let g = SurfaceGeometry(left: 150, right: 150, height: 300, ear: 6, radius: 24)
        for (half, height, radius, k) in [(CGFloat(19), CGFloat(38), CGFloat(19), CGFloat(8)), (30, 60, 30, 12), (9.5, 19, 9.5, 4)] {
            var p = LiquidParams()
            p.budHalf = half; p.budHeight = height; p.budRadius = radius; p.tension = k; p.joined = 1
            // The gap where the waist is nothing.
            var lo: CGFloat = -10, hi: CGFloat = 60
            for _ in 0..<60 {
                let mid = (lo + hi) / 2
                p.budGap = mid
                if let w = LiquidPath.waist(p), w > 0 { lo = mid } else { hi = mid }
            }
            p.budGap = lo
            let joined = LiquidPath.elements(g, p)
            var q = p; q.joined = 0; q.lipBody = k; q.lipBead = k
            let apart = LiquidPath.elements(g, q)
            let d = Self.distance(joined, apart)
            #expect(d < 0.05, "bud \(half)×\(height) r \(radius) k \(k): \(d) pt at the pinch")
        }
        // A reservoir set on a body that stands past it and hangs well below, and cleared where it draws nothing.
        let island = SurfaceGeometry(left: 180, right: 180, height: 300, ear: 6, radius: 24)
        let pill = SurfaceTargets(notch: DIslandMotionTests.notch, pill: DIslandMotionTests.referencePill).closed
        for round: CGFloat in [0, 12, 36] {
            var p = LiquidParams(); p.round = round
            var set = p; set.reservoir = pill
            #expect(LiquidPath.drawsNothing(pill, body: island, round: round))
            let d = Self.hausdorff(LiquidPath.cgPath(island, p, centreX: 0), LiquidPath.cgPath(island, set, centreX: 0))
            #expect(d < 0.05, "round \(round): \(d) pt as the reservoir comes")
        }
    }

    /// A junction with nothing to join is zero-size: with no reservoir the pill's elements; with a reservoir the pill
    /// covers, the body's own corner past the pill's; apart with no stubs, the stubs.
    @Test func junctionsShrinkToNothing() {
        let g = SurfaceGeometry(left: 150, right: 150, height: 300, ear: 6, radius: 24)
        func size(_ e: [LiquidPath.RecordingSink.Element], _ i: Int) -> CGFloat {
            let start = e[2 + i - 1].points.last!
            return e[2 + i].points.map { hypot($0.x - start.x, $0.y - start.y) }.max() ?? 0
        }
        let plain = LiquidPath.elements(g, LiquidParams())
        for i in 1...6 { #expect(size(plain, i) < 1e-9, "element \(i): \(size(plain, i))") }
        for i in 13...20 { #expect(size(plain, i) < 1e-9, "element \(i): \(size(plain, i))") }
        var apart = LiquidParams(); apart.budGap = 20; apart.budHalf = 30; apart.budHeight = 60; apart.budRadius = 22
        let e = LiquidPath.elements(g, apart)
        #expect(size(e, 13) < 1e-9 && size(e, 15) < 1e-9, "the stubs: \(size(e, 13)), \(size(e, 15))")
        var landed = LiquidParams(); landed.reservoir = g
        let l = LiquidPath.elements(g, landed)
        #expect(size(l, 6) < 1e-9, "the reservoir's fillet: \(size(l, 6))")
    }

    // MARK: Geometry helpers

    /// The path as points, each cubic in 16 chords.
    static func polyline(_ path: CGPath, chords: Int = 16) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: points.append(e.points[0])
            case .addCurveToPoint:
                let p0 = points.last ?? .zero, c1 = e.points[0], c2 = e.points[1], p3 = e.points[2]
                for i in 1...chords {
                    let t = CGFloat(i) / CGFloat(chords), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    points.append(CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x, y: a * p0.y + b * c1.y + c * c2.y + d * p3.y))
                }
            case .addQuadCurveToPoint: points.append(e.points[1])
            case .closeSubpath: if let first = points.first { points.append(first) }
            @unknown default: break
            }
        }
        var out: [CGPoint] = []
        for p in points where out.last.map({ hypot($0.x - p.x, $0.y - p.y) > 1e-7 }) ?? true { out.append(p) }
        return out
    }

    /// Proper crossings between segments that do not share an end (touching and running along each other are not
    /// crossings: the bridge is a line down and the same line up).
    static func crossings(_ p: [CGPoint]) -> Int {
        guard p.count > 3 else { return 0 }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        let n = p.count - 1
        var count = 0
        for i in 0..<(n - 2) {
            let a = p[i], b = p[i + 1]
            for j in (i + 2)..<n where !(i == 0 && j == n - 1) {
                let c = p[j], d = p[j + 1]
                guard max(a.x, b.x) >= min(c.x, d.x), max(c.x, d.x) >= min(a.x, b.x), max(a.y, b.y) >= min(c.y, d.y),
                      max(c.y, d.y) >= min(a.y, b.y) else { continue }
                let d1 = cross(a, b, c), d2 = cross(a, b, d), d3 = cross(c, d, a), d4 = cross(c, d, b)
                let eps: CGFloat = 1e-6
                if (d1 > eps && d2 < -eps || d1 < -eps && d2 > eps), (d3 > eps && d4 < -eps || d3 < -eps && d4 > eps) { count += 1 }
            }
        }
        return count
    }

    /// The largest distance between two paths' points and the other's outline, either way.
    static func hausdorff(_ a: CGPath, _ b: CGPath) -> CGFloat {
        let pa = polyline(a, chords: 32), pb = polyline(b, chords: 32)
        func toSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y, l = dx * dx + dy * dy
            let t = l > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l)) : 0
            return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
        }
        func one(_ ps: [CGPoint], _ poly: [CGPoint]) -> CGFloat {
            ps.map { p in (0..<(poly.count - 1)).map { toSegment(p, poly[$0], poly[$0 + 1]) }.min() ?? .infinity }.max() ?? 0
        }
        return max(one(pa, pb), one(pb, pa))
    }

    /// The largest distance between two element lists' points, element by element.
    static func distance(_ a: [LiquidPath.RecordingSink.Element], _ b: [LiquidPath.RecordingSink.Element]) -> CGFloat {
        zip(a, b).flatMap { zip($0.points, $1.points).map { hypot($0.x - $1.x, $0.y - $1.y) } }.max() ?? 0
    }
}

/// Motion: Liquid's model: no liquid under Reduce Motion or in the other feels, reversals without a pop, every frame
/// inside the panel and the panel back at its rest, and the layers' `holds` and `check` seeing the liquid values.
@MainActor
struct LiquidMotionTests {
    typealias Model = IslandChoreography
    typealias Motion = LiquidRenders.Motion

    static let liquid = MotionTuning(motion: .liquid, hover: .quick)

    struct Frame { var t: TimeInterval; var body: SurfaceGeometry; var params: LiquidParams; var panel: IslandExtent }

    static var scripts: [Motion] {
        [Motion(name: "open", events: [(0, .open(.hover, .list))], to: 1.2),
         Motion(name: "close", surface: .island, events: [(0, .close(.fold))], to: 1.2),
         Motion(name: "hover", events: [(0, .swell(true)), (0.4, .swell(false))], to: 1.2),
         Motion(name: "hover-open", events: [(0, .swell(true)), (0.15, .open(.hover, .list))], to: 1.3),
         Motion(name: "rapid", events: [(0, .open(.hover, .list)), (0.18, .close(.fold)), (0.36, .open(.hover, .list)), (0.54, .close(.fold))],
                to: 1.8),
         Motion(name: "topbar", events: [(0, .open(.hover, .list)), (0.8, .close(.fold))], to: 2, notch: nil),
         Motion(name: "hide", surface: .island, events: [(0, .close(.fold)), (0.2, .hide)], to: 1.2)]
    }

    /// Every 1/240 s of `motion` (events at their times, jobs as they fall due).
    static func frames(_ motion: Motion, tuning: MotionTuning = liquid, step: TimeInterval = 1.0 / 240) -> [Frame] {
        var model = LiquidRenders.model(motion, tuning: tuning, until: 0)
        var pending = motion.events.filter { $0.0 > 0 }[...]
        var out: [Frame] = []
        var t: TimeInterval = 0
        while t <= motion.to + 1e-9 {
            while let (s, e) = pending.first, s <= t + 1e-12 {
                _ = model.advance(to: s)
                _ = model.handle(e, at: s)
                pending = pending.dropFirst()
            }
            _ = model.advance(to: t)
            out.append(Frame(t: t, body: model.surface(at: t), params: model.liquid(at: t), panel: model.panel))
            t += step
        }
        return out
    }

    static func scriptedFrames() -> [Frame] {
        scripts.flatMap { frames($0, step: 1.0 / 120) } + (reversals + drains).flatMap { frames($0, step: 1.0 / 60) }
            + LiquidBudTests.motions.flatMap { frames($0, step: 1.0 / 240) } + LiquidBudTests.reversals.flatMap { frames($0, step: 1.0 / 60) }
    }

    /// A close the pointer comes back to while it drains: a swell at every 25 ms, then an open or the pointer leaving
    /// again; and closes of a short and a tall island.
    static var drains: [Motion] {
        stride(from: 0.1, through: 0.55, by: 0.025).flatMap { r -> [Motion] in
            [Motion(name: "close-swell@\(r)", surface: .island, events: [(0, .close(.fold)), (r, .swell(true))], to: r + 0.7),
             Motion(name: "close-swell-open@\(r)", surface: .island, events: [(0, .close(.fold)), (r, .swell(true)), (r + 0.1, .open(.hover, .list))],
                    to: r + 0.8),
             Motion(name: "close-swell-leave@\(r)", surface: .island, events: [(0, .close(.fold)), (r, .swell(true)), (r + 0.08, .swell(false))],
                    to: r + 0.8)]
        }
    }

    /// Open, close and hover reversed at every 30 ms.
    static var reversals: [Motion] {
        stride(from: 0.03, through: 0.48, by: 0.03).flatMap { r -> [Motion] in
            [Motion(name: "open@\(r)", events: [(0, .open(.hover, .list)), (r, .close(.fold))], to: r + 0.9),
             Motion(name: "close@\(r)", surface: .island, events: [(0, .close(.fold)), (r, .open(.hover, .list))], to: r + 0.9),
             Motion(name: "swell@\(r)", events: [(0, .swell(true)), (r, .swell(false))], to: r + 0.6)]
        }
    }

    @Test func reduceMotionHasNoLiquid() {
        for motion in Self.scripts {
            var m = motion; m.reduceMotion = true
            var model = LiquidRenders.model(m, until: 0)
            for (t, e) in m.events.sorted(by: { $0.0 < $1.0 }) {
                _ = model.advance(to: t)
                let commands = model.handle(e, at: t)
                #expect(!commands.contains { if case let .animate(_, v) = $0 { v.keys.contains(where: \.isLiquid) } else { false } })
                #expect(!model.surfacePlan(from: t, step: 1.0 / 240).drawsLiquid, "\(m.name)")
                for s in stride(from: t, through: t + 0.5, by: 0.01) {
                    #expect(model.liquid(at: s).isRest && model.reservoir == nil, "\(m.name) at \(s)")
                }
                #expect(!model.jobs.contains { if case .liquid = $0.step { true } else { false } }, "\(m.name)")
            }
        }
    }

    /// Original and Refined over a 4 s script: no liquid channel, job, reservoir or plan array.
    @Test func otherFeelsHaveNoLiquid() {
        for feel in [MotionFeel.original, .refined] {
            let tuning = MotionTuning(motion: feel, hover: .quick)
            let script = Motion(name: "all", events: [(0, .swell(true)), (0.3, .open(.hover, .list)), (1.2, .close(.fold)), (1.35, .open(.hover, .list)),
                                                      (2.2, .close(.fold)), (3, .swell(true)), (3.4, .swell(false))], to: 4)
            var model = LiquidRenders.model(script, tuning: tuning, until: 0)
            for (t, e) in script.events {
                let commands = model.advance(to: t) + model.handle(e, at: t)
                #expect(!commands.contains { if case let .animate(_, v) = $0 { v.keys.contains(where: \.isLiquid) } else { false } })
                #expect(model.surfacePlan(from: t, step: 1.0 / 240).liquid == nil, "\(feel) at \(t)")
                #expect(!model.values.keys.contains(where: \.isLiquid) && model.reservoir == nil, "\(feel) at \(t)")
                #expect(!model.jobs.contains { if case .liquid = $0.step { true } else { false } }, "\(feel) at \(t)")
            }
        }
    }

    /// Reversed at every 30 ms, the outline never jumps: no point of the union moves between two 240 Hz frames by more
    /// than the body's and the liquid values' own motion allows (twice their sum, and half a point).
    @Test func reversalsAreContinuous() {
        var worst: (CGFloat, String) = (0, "")
        for motion in Self.reversals + Self.scripts {
            let frames = Self.frames(motion)
            var previous = LiquidPath.elements(frames[0].body, frames[0].params)
            for (a, b) in zip(frames, frames.dropFirst()) {
                let now = LiquidPath.elements(b.body, b.params)
                let g = IslandSurfaceLayers.distance(a.body, b.body) * 2 + abs(a.body.left - b.body.left) + abs(a.body.right - b.body.right)
                let allowed = 2 * (g + abs(a.params.sag - b.params.sag) + abs(a.params.round - b.params.round) * ContinuousCorner.reach) + 0.5
                // The points first (a bound on the outline's move); where they move more (a zero-size element sliding
                // along a wall as the reservoir comes or goes), the outlines themselves.
                var moved = LiquidPathTests.distance(previous, now)
                if moved > allowed {
                    moved = LiquidPathTests.hausdorff(LiquidPath.cgPath(a.body, a.params, centreX: 0), LiquidPath.cgPath(b.body, b.params, centreX: 0))
                }
                if moved - allowed > worst.0 { worst = (moved - allowed, "\(motion.name) at \(b.t): \(moved) pt, \(allowed) allowed") }
                #expect(moved <= allowed, "\(motion.name) at \(b.t): \(moved) pt, \(allowed) allowed")
                previous = now
            }
        }
        print("reversals: worst over \(worst)")
    }

    /// Core Animation's linear interpolation between two of a plan's keyframes stays on the model's union: half-way, under
    /// the spec's half a point from it (the points first, a bound on the outline; where they stray more, the outlines
    /// themselves), the reservoir's coming and going and the pill's corner handing over to the body's included. The plan
    /// adds keyframes between samples where the union's points move along curves (`SurfacePlan.liquidKeyframes`).
    @Test func interpolationStaysOnTheShape() {
        var worst: (CGFloat, String) = (0, "")
        var extra = 0
        for motion in Self.reversals + Self.scripts + LiquidBudTests.motions + LiquidBudTests.reversals {
            var model = LiquidRenders.model(motion, until: 0)
            var plans = [model.surfacePlan(from: 0, step: IslandSurfaceLayers.step)]
            for (t, e) in motion.events where t > 0 {
                _ = model.advance(to: t)
                _ = model.handle(e, at: t)
                plans.append(model.surfacePlan(from: t, step: IslandSurfaceLayers.step))
            }
            var mids: [(TimeInterval, [LiquidPath.RecordingSink.Element])] = []
            for (k, plan) in plans.enumerated() {
                guard plan.liquid != nil else { continue }
                let end = k + 1 < plans.count ? plans[k + 1].start : motion.to
                let keys = plan.liquidKeyframes()
                extra += keys.count - plan.surface.count
                for (a, b) in zip(keys, keys.dropFirst()) {
                    let s = plan.start + (a.index + b.index) / 2 * plan.step
                    guard s < end, b.index <= Double(plan.surface.count - 2) else { break }
                    let x = LiquidPath.elements(a.body, a.params), y = LiquidPath.elements(b.body, b.params)
                    mids.append((s, zip(x, y).map { x, y in
                        LiquidPath.RecordingSink.Element(kind: x.kind, points: zip(x.points, y.points).map { CGPoint(x: ($0.x + $1.x) / 2, y: ($0.y + $1.y) / 2) })
                    }))
                }
            }
            var truth = LiquidRenders.model(motion, until: 0)
            var pending = motion.events.filter { $0.0 > 0 }[...]
            for (s, mid) in mids {
                while let (t, e) = pending.first, t <= s {
                    _ = truth.advance(to: t)
                    _ = truth.handle(e, at: t)
                    pending = pending.dropFirst()
                }
                _ = truth.advance(to: s)
                let body = truth.surface(at: s), params = truth.liquid(at: s)
                var d = LiquidPathTests.distance(mid, LiquidPath.elements(body, params))
                if d > 0.3 { d = LiquidPathTests.hausdorff(Self.path(mid), LiquidPath.cgPath(body, params, centreX: 0)) }
                if d > worst.0 { worst = (d, "\(motion.name) at \(s): \(Self.worstElement(mid, LiquidPath.elements(body, params)))") }
                #expect(d < 0.5, "\(motion.name) at \(s): \(d) pt off the union, \(Self.worstElement(mid, LiquidPath.elements(body, params)))")
            }
        }
        print("interpolation: worst \(worst), \(extra) keyframes added")
    }

    /// The element that strays most, and by how much.
    static func worstElement(_ a: [LiquidPath.RecordingSink.Element], _ b: [LiquidPath.RecordingSink.Element]) -> String {
        let per = zip(a, b).map { zip($0.points, $1.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0 }
        let i = per.indices.max { per[$0] < per[$1] } ?? 0
        return "element \(i) by \(per[i])"
    }

    static func path(_ elements: [LiquidPath.RecordingSink.Element]) -> CGPath {
        let path = CGMutablePath()
        for e in elements {
            switch e.kind {
            case .move: path.move(to: e.points[0])
            case .line: path.addLine(to: e.points[0])
            case .curve: path.addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    /// While a close drains into the pill, the outline holds the pill whole: rasterised at 4x every 1/240 s of every close
    /// (a short, the standard and a tall island), every 30 ms reversal and every swell while it drains, no pixel of the
    /// pill lies outside the union (drawn an eighth of a point wider, for the rasteriser's own edge: two outlines a
    /// hundredth of a point apart still differ by a pixel where one edge passes a pixel's sample) at its corners.
    @Test func theUnionHoldsThePill() {
        let close = Motion(name: "close", surface: .island, events: [(0, .close(.fold))], to: 1)
        let motions = Self.reversals + Self.drains + [close] + Self.scripts.filter { $0.name == "rapid" }
        var worst: (Int, String) = (0, "")
        var checked = 0
        for (rows, list) in [(4, motions), (2, [close]), (8, [close])] {
            for motion in list {
                var model = LiquidRenders.model(motion, layout: DIslandMotionTests.layout(rows: rows), until: 0)
                var pending = motion.events.filter { $0.0 > 0 }[...]
                var t: TimeInterval = 0
                while t <= motion.to + 1e-9 {
                    while let (s, e) = pending.first, s <= t + 1e-12 {
                        _ = model.advance(to: s)
                        _ = model.handle(e, at: s)
                        pending = pending.dropFirst()
                    }
                    _ = model.advance(to: t)
                    let body = model.surface(at: t), params = model.liquid(at: t)
                    if let pill = params.reservoir {
                        let n = Self.outside(pill, of: LiquidPath.cgPath(body, params, centreX: 0))
                        checked += 1
                        if n > worst.0 { worst = (n, "\(motion.name) (\(rows) rows) at \(t)") }
                        #expect(n == 0, "\(motion.name) (\(rows) rows) at \(t): \(n) px of the pill outside the union")
                    }
                    t += 1.0 / 240
                }
            }
        }
        #expect(checked > 5000)
        print("containment: \(checked) frames, worst \(worst)")
    }

    /// Pixels of `pill` outside `union` by more than half a pixel's coverage, at 4x, antialiased, around the pill's left
    /// corner and ear (two outlines a hundredth of a point apart differ by a few levels; a bite of a quarter point, by
    /// a whole pixel).
    static func outside(_ pill: SurfaceGeometry, of union: CGPath) -> Int {
        let crop = CGRect(x: -pill.left - 6, y: 0, width: 60, height: pill.height + 4), scale: CGFloat = 4
        let w = Int(crop.width * scale), h = Int(crop.height * scale)
        func coverage(_ path: CGPath) -> [Float] {
            var pixels = [UInt8](repeating: 0, count: w * h)
            let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: -crop.minX, y: -crop.minY)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(path)
            ctx.fillPath()
            var floats = [Float](repeating: 0, count: pixels.count)
            vDSP.convertElements(of: pixels, to: &floats)
            return floats
        }
        let a = coverage(IslandSurfaceLayers.fixedPath(pill, originX: -pill.left, top: 0, flipHeight: nil, continuous: true)), b = coverage(union)
        // Each pixel's shortfall past half a pixel, as 0 to 1 (vectorised: a debug loop over every pixel is slow).
        let short = vDSP.clip(vDSP.add(-128, vDSP.subtract(a, b)), to: 0...1)
        return Int(vDSP.sum(short).rounded(.up))
    }

    /// Every frame's union lies inside the panel the model asked for (to the model's own fit tolerance, as Refined's).
    @Test func everyFrameFitsThePanel() {
        for motion in Self.reversals + Self.scripts {
            for f in Self.frames(motion) {
                let e = LiquidPath.extent(f.body, f.params)
                let tolerance = IslandMotion.fitTolerance
                #expect(e.left <= f.panel.left + tolerance && e.right <= f.panel.right + tolerance && e.height <= f.panel.height + tolerance,
                        "\(motion.name) at \(f.t): \(e) outside \(f.panel)")
            }
        }
    }

    /// After open, close, hover and their reversals, the panel is where Refined's is, within 0.1 s of the motion's end.
    @Test func thePanelReturnsToItsRest() {
        for motion in Self.reversals + Self.scripts {
            let liquid = LiquidRenders.model(motion, until: motion.to + 1)
            let refined = LiquidRenders.model(motion, tuning: LiquidRenders.refined, until: motion.to + 1)
            #expect(liquid.panel == refined.panel, "\(motion.name): \(liquid.panel) against \(refined.panel)")
            #expect(liquid.reservoir == nil && liquid.liquid(at: motion.to + 1).isRest, "\(motion.name): \(liquid.liquid(at: motion.to + 1))")
        }
    }

    /// `holds` tells a plan with other liquid values from the one playing, and `check` finds a model off its liquid plan.
    @Test func holdsAndCheckCompareTheLiquid() {
        let open = Motion(name: "open", events: [(0, .open(.hover, .list))], to: 1)
        var model = LiquidRenders.model(open, until: 0)
        _ = model.handle(.open(.hover, .list), at: 0)
        let plan = model.surfacePlan(from: 0, step: IslandSurfaceLayers.step)
        #expect(plan.drawsLiquid)
        #expect(IslandSurfaceLayers.holds(plan, plan))
        var other = plan
        other.liquid = plan.liquid?.map { var p = $0; p.sag += 3; return p }
        #expect(!IslandSurfaceLayers.holds(plan, other))
        var still = plan
        still.liquid = plan.liquid?.map { _ in LiquidParams() }
        #expect(!IslandSurfaceLayers.holds(plan, still))
    }
}

/// Settings › Island › Motion: Original, Refined and Liquid; a stored choice keeps its feel (Refined stays Refined, the
/// default); the row is hidden under Reduce Motion; Liquid's tuning is Refined's with the liquid outline.
@MainActor
struct LiquidSettingsTests {
    @Test func theMotionRowHasThreeSegments() throws {
        #expect(IslandPaneText.motions.map(\.0) == [.original, .refined, .liquid])
        #expect(IslandPaneText.motions.map(\.1) == ["Original", "Refined", "Liquid"])
        #expect(!IslandPaneText.showsMotionRow(reduceMotion: true) && IslandPaneText.showsMotionRow(reduceMotion: false))
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppSettings(defaults: defaults).islandMotion == .refined)
        defaults.set("refined", forKey: AppSettings.Key.islandMotion)
        #expect(AppSettings(defaults: defaults).islandMotion == .refined)
        let settings = AppSettings(defaults: defaults)
        settings.islandMotion = .liquid
        #expect(defaults.string(forKey: AppSettings.Key.islandMotion) == "liquid" && AppSettings(defaults: defaults).islandMotion == .liquid)
        var liquid = MotionTuning(motion: .liquid, hover: .quick), refined = MotionTuning(motion: .refined, hover: .quick)
        #expect(liquid.liquid && !refined.liquid && !MotionTuning(motion: .original, hover: .quick).liquid)
        liquid.motion = .refined
        liquid.liquid = false
        refined.motion = .refined
        #expect(liquid == refined, "Liquid's tuning is Refined's and the outline")
    }
}
