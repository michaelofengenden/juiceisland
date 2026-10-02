import CoreGraphics
import SwiftUI

// Motion: Liquid. The island's outline as one union of fixed elements: the body (today's surface), a belly under it,
// the closed pill a close drains into (the reservoir), a bud below it (a bead, or a card) and the neck that joins them.
// Every part is written in closed form from circles and continuous corners, into one path of always the same 45
// elements, so Core Animation interpolates any two of a plan's samples, SwiftUI's clip draws the same path from the
// same values, and a part a configuration does not use is a zero-size element at a defined point, never a different
// kind. The union always contains the body: a value that is not finite, or a configuration outside the cases below,
// draws the body alone (still 45 elements), so less shows, never more.
//
// Space: x runs from the centre line (the notch's midX), right positive; y down from the top edge. Everything liquid
// (belly, bead, bud, neck) sits on the centre line; the body and the pill have a reach of their own on each side.

/// One of Motion: Liquid's values beside the body, each a model channel on springs (`Channel.liquid`).
enum LiquidKey: Int, CaseIterable, Hashable, Sendable {
    /// The belly's depth below the flat bottom at the centre line.
    case sag
    /// Extra bottom-corner radius while the body moves.
    case round
    /// The bud: its top below the body's bottom (negative: inside), its half-width, height and corner radius.
    case budGap, budHalf, budHeight, budRadius
    /// The neck: joined (1) or apart (0), only ever snapped; the stubs' radii once apart; the neck's fillet radius.
    case joined, lipBody, lipBead, tension

    /// Every key, stored (the synthesized `allCases` builds its array at each call).
    static let every: [LiquidKey] = allCases
}

/// Motion: Liquid's values at one moment, and the reservoir (model state, not a channel).
struct LiquidParams: Equatable, Sendable {
    var sag: CGFloat = 0
    var round: CGFloat = 0
    var budGap: CGFloat = LiquidPath.restGap
    var budHalf: CGFloat = 0
    var budHeight: CGFloat = 0
    var budRadius: CGFloat = 0
    var joined: CGFloat = 0
    var lipBody: CGFloat = 0
    var lipBead: CGFloat = 0
    var tension: CGFloat = LiquidPath.tension
    /// The closed pill a close drains into, from the close's fold until the body has landed in it.
    var reservoir: SurfaceGeometry?

    /// Drawing nothing of its own.
    static let rest = LiquidParams()

    subscript(key: LiquidKey) -> CGFloat {
        get {
            switch key {
            case .sag: sag
            case .round: round
            case .budGap: budGap
            case .budHalf: budHalf
            case .budHeight: budHeight
            case .budRadius: budRadius
            case .joined: joined
            case .lipBody: lipBody
            case .lipBead: lipBead
            case .tension: tension
            }
        }
        set {
            switch key {
            case .sag: sag = newValue
            case .round: round = newValue
            case .budGap: budGap = newValue
            case .budHalf: budHalf = newValue
            case .budHeight: budHeight = newValue
            case .budRadius: budRadius = newValue
            case .joined: joined = newValue
            case .lipBody: lipBody = newValue
            case .lipBead: lipBead = newValue
            case .tension: tension = newValue
            }
        }
    }

    var isJoined: Bool { joined >= 0.5 }

    /// The bud reaches below the body's bottom.
    var budShows: Bool { budHalf > 0 && budHeight > 0 && budGap + budHeight > 0 }

    /// Draws nothing but the body: the outline is today's.
    /// Drawing nothing of its own (a spring's tail below a thousandth of a point counts as rest).
    var isRest: Bool {
        sag <= 0.001 && round <= 0.001 && reservoir == nil && lipBody <= 0.001 && lipBead <= 0.001 && !budShows
    }

    /// Linearly between `self` and `other` (SwiftUI's ticker between a plan's samples, as Core Animation interpolates
    /// its keyframes); the neck's flag and the reservoir's presence from the nearer sample (where either flips the two
    /// samples draw the same outline).
    func mixed(_ other: LiquidParams, _ u: CGFloat) -> LiquidParams {
        var out = LiquidParams()
        for key in LiquidKey.every where key != .joined { out[key] = self[key] + (other[key] - self[key]) * u }
        out.joined = u < 0.5 ? joined : other.joined
        switch (reservoir, other.reservoir) {
        case let (a?, b?):
            out.reservoir = SurfaceGeometry(left: a.left + (b.left - a.left) * u, right: a.right + (b.right - a.right) * u,
                                            height: a.height + (b.height - a.height) * u, ear: a.ear + (b.ear - a.ear) * u,
                                            radius: a.radius + (b.radius - a.radius) * u)
        case let (a, b): out.reservoir = u < 0.5 ? (a ?? b) : (b ?? a)
        }
        return out
    }

    /// The most any value differs (the neck's flag counts a point; a reservoir that one has and the other has not, any
    /// amount).
    static func distance(_ a: LiquidParams, _ b: LiquidParams) -> CGFloat {
        var d: CGFloat = 0
        for key in LiquidKey.every where key != .joined { d = max(d, abs(a[key] - b[key])) }
        if a.isJoined != b.isJoined { d = max(d, 1) }
        switch (a.reservoir, b.reservoir) {
        case (nil, nil): break
        case let (x?, y?): d = max(d, abs(x.left - y.left), abs(x.right - y.right), abs(x.height - y.height), abs(x.ear - y.ear),
                                   abs(x.radius - y.radius))
        default: d = .infinity
        }
        return d
    }
}

/// Where the emitter writes: a `CGMutablePath`, SwiftUI's `Path`, the extent, or a test's element list. The points are
/// in outline space; each sink places them.
protocol LiquidSink {
    mutating func move(_ p: CGPoint)
    mutating func line(_ p: CGPoint)
    mutating func curve(_ c1: CGPoint, _ c2: CGPoint, _ p: CGPoint)
    mutating func close()
}

enum LiquidPath {
    /// The path's elements: a move, the top edge, 21 down the right side, 21 up the left, and a close.
    static let elementCount = 45
    /// Elements a side: ear, outer wall, pill corner (3), pill bottom, reservoir fillet, body wall, body corner (3), flat
    /// bottom, belly, upper neck, bridge, lower neck, bud (top line, top arc, wall, bottom arc, bottom line).
    static let sideCount = 21
    /// Which of a side's elements are cubics (the rest are lines), top to bottom.
    static let sideCurves: [Bool] = [true, false, true, true, true, false, true, false, true, true, true, false, true, true, false,
                                     true, false, true, false, true, false]
    /// The reservoir's fillet radius (kr) and the neck's (k).
    static let reservoirFillet: CGFloat = 12
    static let tension: CGFloat = 12
    /// The belly's share of the flat half-bottom, from the centre line.
    static let bellySpan: CGFloat = 0.7
    /// The bud at rest, drawing nothing: its top 40 pt inside the body, no size.
    static let restGap: CGFloat = -40
    /// Over how many points of the pill standing out its ear blends from the body's to its own, and the body's corners
    /// from continuous corners to circles (the drop reads round).
    static let earBlend: CGFloat = 8
    /// The pill's wall is drawn this far inside itself: a pill that stands out past the body by less is the body's, so a
    /// body landing on the pill's reach from outside never makes the pill stand out again by a spring's last wobble.
    static let standEpsilon: CGFloat = 0.002
    /// Where the pill stands out by little, the body's corner is no rounder than the pill's plus these shares of how far
    /// the body hangs below it, of how far it reaches past it, and of how far the pill stands out: so the body's corner
    /// holds the pill's (the union is the body there, and the pill's elements lie on its wall).
    static let containHang: CGFloat = 0.6
    static let containWide: CGFloat = 0.6
    static let containStand: CGFloat = 2
    /// The belly at most this deep for each point of its span (the open's is 24 deep over 70).
    static let bellyAspect: CGFloat = 0.25
    /// A quarter circle's cubic handle.
    static let quarter: CGFloat = 0.5522847498

    // MARK: Output

    /// The union's `CGPath` in a canvas's layer space: the centre line at `centreX`, the top edge at `top`, y down, or y
    /// up (`flipHeight`: the canvas's height, as `IslandSurfaceLayers.fixedPath`).
    static func cgPath(_ body: SurfaceGeometry, _ params: LiquidParams, centreX: CGFloat, top: CGFloat = 0,
                       flipHeight: CGFloat? = nil) -> CGPath {
        var sink = PathSink(transform: transform(centreX: centreX, top: top, flipHeight: flipHeight))
        emit(body, params, into: &sink)
        return sink.path
    }

    /// The union's y-down `CGPath` from its points (`PointsSink`), the same as `cgPath` writes; nil for no union.
    static func cgPath(_ points: PointsSink, centreX: CGFloat) -> CGPath? {
        guard points.count == PointsSink.capacity else { return nil }
        var sink = PathSink(transform: transform(centreX: centreX, top: 0, flipHeight: nil))
        points.replay(into: &sink)
        return sink.path
    }

    /// The union twice from one pass: y down for the fill and the clip, y up for Glass's path layers.
    static func cgPaths(_ body: SurfaceGeometry, _ params: LiquidParams, centreX: CGFloat, flipHeight: CGFloat) -> (down: CGPath, up: CGPath) {
        let down = cgPath(body, params, centreX: centreX)
        // The y-up copy flips the y-down path (Core Graphics copies the elements at once, cheaper than writing them again).
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: flipHeight)
        return (down, down.copy(using: &flip) ?? cgPath(body, params, centreX: centreX, flipHeight: flipHeight))
    }

    static func transform(centreX: CGFloat, top: CGFloat, flipHeight: CGFloat?) -> CGAffineTransform {
        if let flipHeight { return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: centreX, ty: flipHeight - top) }
        return CGAffineTransform(translationX: centreX, y: top)
    }

    /// The union as SwiftUI's shape draws it: hanging from `rect`'s top, its centre line on `rect`'s midX.
    static func path(_ body: SurfaceGeometry, _ params: LiquidParams, in rect: CGRect) -> Path {
        var sink = SwiftUISink(origin: CGPoint(x: rect.midX, y: rect.minY))
        emit(body, params, into: &sink)
        return sink.path
    }

    /// The union's exact extent: the bounds of its control points (a cubic lies in its hull), either side of the centre
    /// line and below the top edge.
    static func extent(_ body: SurfaceGeometry, _ params: LiquidParams) -> IslandExtent {
        var sink = ExtentSink()
        emit(body, params, into: &sink)
        return IslandExtent(left: max(0, -sink.minX), right: max(0, sink.maxX), height: max(0, sink.maxY))
    }

    /// The union's reach at a glance, at least its exact extent (`extent`) and cheap: the outer reach the top edge runs
    /// to, the bud's half-width, and the lowest of the body, the belly and the bud. The panel and the fit read it at
    /// every sample of a plan and every 2 ms of a fit's scan.
    /// The values `bounds` reads.
    static let reachKeys: [LiquidKey] = [.sag, .budGap, .budHalf, .budHeight]

    static func bounds(_ body: SurfaceGeometry, _ p: LiquidParams) -> IslandExtent {
        guard finite(body), finite(p) else { return finite(body) ? body.extent : .zero }
        let w = max(0, body.width), h = max(0, body.height)
        let ear = max(0, min(body.ear + body.meniscus, h, w / 4))
        // A side's top edge runs to its wall and its ear, however short its reach.
        var left = max(0, body.left, ear), right = max(0, body.right, ear), bottom = h
        if let pill = p.reservoir {
            let pw = max(0, pill.width), ph = max(0, pill.height)
            let pillEar = max(0, min(pill.ear, ph, pw / 4))
            func outer(_ reach: CGFloat, _ pillReach: CGFloat) -> CGFloat {
                max(0, reach - ear, pillReach - pillEar) + max(ear, pillEar)
            }
            left = outer(body.left, pill.left)
            right = outer(body.right, pill.right)
            bottom = max(h, ph)
        }
        var height = bottom + max(0, p.sag)
        let a = max(0, p.budHalf), bh = max(0, p.budHeight)
        if a > 0, bh > 0, p.budGap + bh > 0 {
            height = max(height, bottom + p.budGap + bh)
            left = max(left, a)
            right = max(right, a)
        }
        return IslandExtent(left: left, right: right, height: height)
    }

    /// Whether the reservoir `pill` draws nothing of its own on `body`: the body holds it (its bottom at or below the
    /// pill's, its walls at or past the pill's, its corners no rounder than hold the pill's), so the union is the body
    /// and the pill's elements lie on its walls: clearing it then moves no point off the outline.
    static func drawsNothing(_ pill: SurfaceGeometry, body: SurfaceGeometry, round: CGFloat) -> Bool {
        guard finite(pill), finite(body), body.height >= pill.height - 0.001 else { return false }
        var p = LiquidParams()
        p.round = round
        p.reservoir = pill
        guard let shape = Shape(body, p, strict: false) else { return false }
        return shape.holdsPill(reach: body.left, pillReach: pill.left) && shape.holdsPill(reach: body.right, pillReach: pill.right)
    }

    // MARK: The emitter

    struct Segment: Equatable {
        var curve: Bool
        var c1: CGPoint
        var c2: CGPoint
        var to: CGPoint

        static func line(_ p: CGPoint) -> Segment { Segment(curve: false, c1: p, c2: p, to: p) }
        static func cubic(_ c1: CGPoint, _ c2: CGPoint, _ p: CGPoint) -> Segment { Segment(curve: true, c1: c1, c2: c2, to: p) }
        /// `a` toward `b` by `u` (two segments of one kind).
        static func mix(_ a: Segment, _ b: Segment, _ u: CGFloat) -> Segment {
            func m(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * u, y: p.y + (q.y - p.y) * u) }
            return Segment(curve: b.curve, c1: m(a.c1, b.c1), c2: m(a.c2, b.c2), to: m(a.to, b.to))
        }
    }

    /// One side, top to bottom: from the top edge's end, its 21 elements.
    struct Side {
        var start: CGPoint
        var segments: InlineArray<21, Segment>
        var count = 0

        init(start: CGPoint) {
            self.start = start
            segments = InlineArray(repeating: Segment.line(start))
        }

        mutating func add(_ s: Segment) {
            assert(count < LiquidPath.sideCount && s.curve == LiquidPath.sideCurves[count], "an element of the wrong kind")
            segments[count] = s
            count += 1
        }

        var end: CGPoint { count == 0 ? start : segments.span[count - 1].to }
    }

    /// Writes the union of `body` and `params` into `sink`: always the same 45 elements.
    static func emit<S: LiquidSink>(_ body: SurfaceGeometry, _ params: LiquidParams, into sink: inout S) {
        let body = finite(body) ? body : .zero
        if let shape = Shape(body, finite(params) ? params : LiquidParams(), strict: true), let sides = shape.sides() {
            write(sides, into: &sink)
        } else if let shape = Shape(body, LiquidParams(), strict: false), let sides = shape.sides() {
            // A configuration outside the cases: the body alone.
            write(sides, into: &sink)
        }
    }

    private static func write<S: LiquidSink>(_ sides: (right: Side, left: Side), into sink: inout S) {
        func mirror(_ p: CGPoint) -> CGPoint { CGPoint(x: -p.x, y: p.y) }
        // Read through spans: an element read from the inline storage itself can copy all of it.
        let right = sides.right.segments.span, left = sides.left.segments.span
        sink.move(mirror(sides.left.start))
        sink.line(sides.right.start)
        for i in 0..<sideCount {
            let s = right[i]
            if s.curve { sink.curve(s.c1, s.c2, s.to) } else { sink.line(s.to) }
        }
        // The left side mirrored, bottom to top: each element reversed.
        for i in stride(from: sideCount - 1, through: 0, by: -1) {
            let s = left[i]
            let from = i == 0 ? sides.left.start : left[i - 1].to
            if s.curve { sink.curve(mirror(s.c2), mirror(s.c1), mirror(from)) } else { sink.line(mirror(from)) }
        }
        sink.close()
    }

    static func finite(_ g: SurfaceGeometry) -> Bool {
        g.left.isFinite && g.right.isFinite && g.height.isFinite && g.ear.isFinite && g.radius.isFinite && g.meniscus.isFinite
    }

    static func finite(_ p: LiquidParams) -> Bool {
        p.sag.isFinite && p.round.isFinite && p.budGap.isFinite && p.budHalf.isFinite && p.budHeight.isFinite && p.budRadius.isFinite
            && p.joined.isFinite && p.lipBody.isFinite && p.lipBead.isFinite && p.tension.isFinite && (p.reservoir.map(finite) ?? true)
    }

    // MARK: The neck's two measures (the model solves the pinch and the join on them)

    /// The joined neck's half-width at its narrowest (the fillet's innermost point from the centre line) for a bud of
    /// `params` and the fillet radius `tension`: the bud pinches where it reaches 0. nil when the fillet cannot reach the
    /// bud (it has gone past the pinch) or the bud is inside the body.
    static func waist(_ params: LiquidParams) -> CGFloat? {
        let bud = Bud(params, bottom: 0)
        // The fillet as the outline draws it: no larger than twice what the bud stands out (`Shape`).
        guard !bud.inside, let neck = bud.joined(k: min(max(0.5, params.tension), 2 * max(0, bud.top + bud.h))) else { return nil }
        return neck.xf - neck.k
    }

    /// Apart: the gap left between the body's stub and the bud's (the stubs' own radii now), negative once they would
    /// overlap. nil when the bud is inside the body.
    static func bridge(_ params: LiquidParams, lips: CGFloat? = nil) -> CGFloat? {
        let bud = Bud(params, bottom: 0)
        guard !bud.inside else { return nil }
        let l = max(0, lips ?? params.lipBody), l2 = max(0, lips ?? params.lipBead)
        return bud.stubTip(l2) - l
    }

    /// How flat the bud's top is: the half-width of its flat top (0 for a bead, whose top is its circle). Joining and
    /// parting only ever happen at 0.
    static func flatTop(_ params: LiquidParams) -> CGFloat {
        Bud(params, bottom: 0).cx
    }

    /// Apart: the stubs' radius at which they would just meet at this gap, the same for both (the apart outline then
    /// is the joined one of that fillet radius with no waist). nil when the bud is inside the body or overlaps it.
    static func joinTension(_ params: LiquidParams) -> CGFloat? {
        let bud = Bud(params, bottom: 0)
        guard !bud.inside else { return nil }
        func gap(_ l: CGFloat) -> CGFloat { bud.stubTip(l) - l }
        guard gap(0) >= 0 else { return nil }
        var lo: CGFloat = 0, hi: CGFloat = 64
        if gap(hi) >= 0 { return hi }
        for _ in 0..<32 {
            let mid = (lo + hi) / 2
            if gap(mid) >= 0 { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Apart and rising: the stubs have met (both at least `joinTension`) and the bud is a bead, so a join there draws
    /// the same outline.
    static func canJoin(_ params: LiquidParams) -> Bool {
        guard !params.isJoined, let k = joinTension(params) else { return false }
        return min(params.lipBody, params.lipBead) >= k && flatTop(params) <= min(LiquidMotion.beadFlat, k)
    }

    /// Joined: the neck has pinched (its waist gone, or the fillet no longer reaches a bud that still shows).
    static func pinched(_ params: LiquidParams) -> Bool {
        guard params.isJoined, !Bud(params, bottom: 0).inside else { return false }
        guard let w = waist(params) else { return true }
        return w <= 0
    }

    /// The bud is all inside the body: nothing of it draws.
    static func budInside(_ params: LiquidParams) -> Bool {
        Bud(params, bottom: 0).inside
    }

    // MARK: Geometry

    /// The bud and its neck, from the body's bottom `bottom`: half-width, height, corner radius (clamped), top.
    struct Bud {
        var a: CGFloat
        var h: CGFloat
        var r: CGFloat
        var top: CGFloat
        var bottomLine: CGFloat
        var cx: CGFloat { a - r }
        var topCentre: CGPoint { CGPoint(x: cx, y: top + r) }
        var bottomCentre: CGPoint { CGPoint(x: cx, y: top + h - r) }
        /// Nothing of it below the body's bottom.
        var inside: Bool { !(a > 0 && h > 0) || top + h <= bottomLine }

        init(_ p: LiquidParams, bottom: CGFloat) {
            a = max(0, p.budHalf)
            h = max(0, p.budHeight)
            r = max(0, min(p.budRadius, a, h / 2))
            top = bottom + p.budGap
            bottomLine = bottom
        }

        struct Joined {
            var k: CGFloat
            var xf: CGFloat
            /// The circle it is tangent to, and where; nil for the wall.
            var circle: CGPoint?
            var touch: CGPoint
            var feature: Feature
        }

        enum Feature { case top, wall, bottom }

        /// The fillet of radius `k` tangent to the body's bottom from below and to the bud: nil when it cannot reach.
        func joined(k: CGFloat) -> Joined? {
            let y0 = bottomLine + k, rho = r + k
            let ct = topCentre, cb = bottomCentre
            if y0 < top - k { return nil }
            if y0 < ct.y {
                let d = ct.y - y0
                let xf = cx + (max(0, rho * rho - d * d)).squareRoot()
                let f = CGPoint(x: xf, y: y0)
                return Joined(k: k, xf: xf, circle: ct, touch: toward(ct, f, r), feature: .top)
            }
            if y0 <= cb.y { return Joined(k: k, xf: a + k, circle: nil, touch: CGPoint(x: a, y: y0), feature: .wall) }
            if y0 <= top + h + k {
                let d = y0 - cb.y
                let xf = cx + (max(0, rho * rho - d * d)).squareRoot()
                let f = CGPoint(x: xf, y: y0)
                return Joined(k: k, xf: xf, circle: cb, touch: toward(cb, f, r), feature: .bottom)
            }
            return nil
        }

        /// The bud's stub of radius `l` apart: where its tip meets the centre line.
        func stubTip(_ l: CGFloat) -> CGFloat {
            if cx >= l { return top - l }
            let ct = topCentre, dx = l - cx
            return ct.y - (max(0, (r + l) * (r + l) - dx * dx)).squareRoot()
        }
    }

    /// The point `radius` from `centre` toward `point`.
    static func toward(_ centre: CGPoint, _ point: CGPoint, _ radius: CGFloat) -> CGPoint {
        let dx = point.x - centre.x, dy = point.y - centre.y, d = (dx * dx + dy * dy).squareRoot()
        guard d > 1e-9 else { return centre }
        return CGPoint(x: centre.x + radius * dx / d, y: centre.y + radius * dy / d)
    }

    /// An arc of `centre` and `radius` from angle `from` to `to` (radians, y down, |to − from| ≤ π/2) as one cubic.
    static func arc(_ centre: CGPoint, _ radius: CGFloat, from a: CGFloat, to b: CGFloat) -> (start: CGPoint, segment: Segment) {
        let p1 = CGPoint(x: centre.x + radius * cos(a), y: centre.y + radius * sin(a))
        let p2 = CGPoint(x: centre.x + radius * cos(b), y: centre.y + radius * sin(b))
        let t = 4 / 3 * tan((b - a) / 4) * radius
        let c1 = CGPoint(x: p1.x - t * sin(a), y: p1.y + t * cos(a))
        let c2 = CGPoint(x: p2.x + t * sin(b), y: p2.y - t * cos(b))
        return (p1, .cubic(c1, c2, p2))
    }

    /// A bottom-right continuous corner (F9) at `corner` of `r`: from `reach·r` up the wall to `reach·r` along the
    /// bottom, three cubics (`ContinuousCorner.curves`, without its array).
    static func corner(_ side: inout Side, at corner: CGPoint, radius r: CGFloat) {
        let c = cornerCurves(at: corner, radius: r)
        side.add(c.0)
        side.add(c.1)
        side.add(c.2)
    }

    static func cornerCurves(at corner: CGPoint, radius r: CGFloat) -> (Segment, Segment, Segment) {
        func p(_ t: CGFloat, _ n: CGFloat) -> CGPoint { CGPoint(x: corner.x - n * r, y: corner.y - t * r) }
        return (.cubic(p(1.08849323, 0), p(0.86840689, 0), p(0.66993427, 0.06549600)),
                .cubic(p(0.37260046, 0.17941168), p(0.17941097, 0.37260121), p(0.06549569, 0.66993493)),
                .cubic(p(0, 0.86840689), p(0, 1.08849323), p(0, ContinuousCorner.reach)))
    }

    static func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// The union's values, resolved once for both sides.
    struct Shape {
        var body: SurfaceGeometry
        var p: LiquidParams
        var pill: SurfaceGeometry?
        /// The body's bottom as drawn: with a reservoir, never above the pill's.
        var bottom: CGFloat
        var ear: CGFloat
        var radius: CGFloat
        var pillEar: CGFloat = 0
        var pillRadius: CGFloat = 0
        var sag: CGFloat
        var neck: Neck

        enum Neck {
            /// No neck: the belly (or the flat bottom) runs to the centre line, where every bud element lies.
            case none
            /// Joined through a fillet of radius `k` at `xf`.
            case joined(Bud.Joined, Bud)
            /// Apart: the body's stub `l`, the bud's `l2`.
            case apart(l: CGFloat, l2: CGFloat, Bud)
        }

        init?(_ body: SurfaceGeometry, _ p: LiquidParams, strict: Bool) {
            self.body = body
            self.p = p
            let w = max(0, body.width), h = max(0, body.height)
            ear = max(0, min(body.ear + body.meniscus, h, w / 4))
            var bottom = h
            if let pill = p.reservoir {
                self.pill = pill
                bottom = max(h, max(0, pill.height))
                let pw = max(0, pill.width), ph = max(0, pill.height)
                pillEar = max(0, min(pill.ear, ph, pw / 4))
                pillRadius = ContinuousCorner.radius(pill.radius, width: pw, height: ph, ear: pillEar)
            }
            self.bottom = bottom
            radius = ContinuousCorner.radius(body.radius + max(0, p.round), width: w, height: bottom, ear: ear)
            sag = max(0, p.sag)
            neck = .none
            guard strict else { return }
            let bud = Bud(p, bottom: bottom)
            guard !bud.inside else { return }
            if p.isJoined {
                // The neck's fillets no larger than twice what the bud stands out below the body, so a bud rising all in
                // (or seeded all in) takes them to nothing with it: its going draws the flat bottom it leaves.
                let stands = max(0, bud.top + bud.h - bottom)
                guard let resolved = Self.joinedNeck(bud, k: min(max(0.5, p.tension), 2 * stands)) else { return nil }
                neck = resolved
            } else {
                guard let resolved = Self.apartNeck(bud, l: max(0, p.lipBody), l2: max(0, p.lipBead), tension: max(0.5, p.tension)) else { return nil }
                neck = resolved
            }
            sag = 0
        }

        /// Joined: the fillet, or at the pinch's limit (its waist gone below nothing, or it cannot reach) the two stubs of
        /// the pinch itself, which are the same outline there.
        static func joinedNeck(_ bud: Bud, k: CGFloat) -> Neck? {
            if let j = bud.joined(k: k), j.xf - j.k >= 0 { return .joined(j, bud) }
            return apartNeck(bud, l: k, l2: k, tension: k)
        }

        /// Apart: the stubs, scaled together so the bridge between them is never negative (the parts never overlap); a
        /// part that would overlap the body even with no stubs is drawn joined (a jump, never a spill).
        static func apartNeck(_ bud: Bud, l: CGFloat, l2: CGFloat, tension: CGFloat) -> Neck? {
            func gap(_ s: CGFloat) -> CGFloat { bud.stubTip(s * l2) - (bud.bottomLine + s * l) }
            if gap(1) >= 0 { return .apart(l: l, l2: l2, bud) }
            guard gap(0) >= 0 else {
                guard let j = bud.joined(k: tension), j.xf - j.k >= 0 else { return nil }
                return .joined(j, bud)
            }
            var lo: CGFloat = 0, hi: CGFloat = 1
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if gap(mid) >= 0 { lo = mid } else { hi = mid }
            }
            return .apart(l: lo * l, l2: lo * l2, bud)
        }

        /// Where the neck leaves the body's bottom (0: no neck).
        var neckStart: CGFloat {
            switch neck {
            case .none: 0
            case let .joined(j, _): j.xf
            case let .apart(l, _, _): l
            }
        }

        func sides() -> (right: Side, left: Side)? {
            guard let right = side(reach: body.right, pillReach: pill?.right) else { return nil }
            // A body (and a pill) as wide on both sides has the same side twice, the left written mirrored.
            if body.left == body.right, pill?.left == pill?.right { return (right, right) }
            guard let left = side(reach: body.left, pillReach: pill?.left) else { return nil }
            return (right, left)
        }

        /// One side, top to bottom, from the top edge's end to the centre line.
        func side(reach w: CGFloat, pillReach: CGFloat?) -> Side? {
            let k = LiquidPath.quarter, reach = ContinuousCorner.reach
            let wb = max(0, w - ear)
            var side: Side
            // Where the bottom ends (the corner's end) and the wall it hangs from.
            let flatEnd: CGFloat, wall: CGFloat
            if let pill, let pillReach {
                guard let joint = junction(reach: w, pillReach: pillReach, pill: pill) else { return nil }
                side = joint.side
                flatEnd = joint.flatEnd
                wall = joint.wall
            } else {
                // No pill: its elements lie where the ear meets the wall; the body's own continuous corners (F9).
                let rb = min(radius, max(0, wb) / reach)
                side = Side(start: CGPoint(x: wb + ear, y: 0))
                side.add(.cubic(CGPoint(x: wb + ear - k * ear, y: 0), CGPoint(x: wb, y: ear - k * ear), CGPoint(x: wb, y: ear)))
                let at = CGPoint(x: wb, y: ear)
                for i in 1...6 { side.add(LiquidPath.sideCurves[i] ? .cubic(at, at, at) : .line(at)) }
                side.add(.line(CGPoint(x: wb, y: bottom - reach * rb)))
                corner(&side, at: CGPoint(x: wb, y: bottom), radius: rb)
                flatEnd = wb - reach * rb
                wall = wb
            }
            guard flatEnd >= -1e-6 else { return nil }
            // Flat bottom, the belly, the neck and the bud.
            let n = neckStart
            guard n <= flatEnd + 1e-6 else { return nil }
            switch neck {
            case .none:
                // The belly: the bottom sags as a hanging skin, most at the centre line and nothing at the walls (a
                // parabola across the bottom, the corners carried down with it), no deeper than the body's width allows,
                // so it stays a soft bowl on a narrow body. At no depth it is the flat bottom.
                let xe = max(0, flatEnd)
                let depth = wall > 0 ? max(0, min(sag, LiquidPath.bellyAspect * wall)) : 0
                func sink(_ p: CGPoint) -> CGPoint {
                    let u = wall > 0 ? min(1, abs(p.x) / wall) : 1
                    return CGPoint(x: p.x, y: p.y + depth * (1 - u * u))
                }
                if depth > 0 {
                    // Every point of the side (nothing moves past the wall), so a junction that ends on the body's corner
                    // moves with it.
                    let written = side.segments
                    for i in 0..<side.count {
                        let e = written[i]
                        side.segments[i] = Segment(curve: e.curve, c1: sink(e.c1), c2: sink(e.c2), to: sink(e.to))
                    }
                }
                let start = sink(CGPoint(x: xe, y: bottom)), end = CGPoint(x: 0, y: bottom + depth)
                side.add(.line(start))
                // The parabola as a cubic: its handles a third of the way along its tangents.
                let slope = wall > 0 ? 2 * depth * xe * xe / (wall * wall) : 0
                side.add(.cubic(CGPoint(x: 2 * xe / 3, y: start.y + slope / 3), CGPoint(x: xe / 3, y: end.y), end))
                for i in 13...20 { side.add(LiquidPath.sideCurves[i] ? .cubic(end, end, end) : .line(end)) }
            case let .joined(j, bud):
                let x0 = max(n, LiquidPath.bellySpan * max(0, flatEnd))
                side.add(.line(CGPoint(x: x0, y: bottom)))
                let start = CGPoint(x: j.xf, y: bottom)
                side.add(.cubic(CGPoint(x: x0 + (j.xf - x0) * 0.45, y: bottom), CGPoint(x: x0 + (j.xf - x0) * 0.55, y: bottom), start))
                let f = CGPoint(x: j.xf, y: bottom + j.k)
                // The fillet from its top (−π/2), turning toward the centre line: to its innermost point (−π), or to the
                // tangent point if it comes first; the rest of it after the bridge (nothing long, joined).
                var toward: CGFloat
                if let c = j.circle { toward = atan2(c.y - f.y, c.x - f.x) } else { toward = .pi }
                if toward > -.pi / 2 { toward -= 2 * .pi }
                let mid = max(toward, -.pi)
                side.add(LiquidPath.arc(f, j.k, from: -.pi / 2, to: mid).segment)
                let inner = side.end
                side.add(.line(inner))
                side.add(LiquidPath.arc(f, j.k, from: mid, to: toward).segment)
                budHalf(&side, bud, from: j.touch, feature: j.feature)
            case let .apart(l, l2, bud):
                let x0 = max(n, LiquidPath.bellySpan * max(0, flatEnd))
                side.add(.line(CGPoint(x: x0, y: bottom)))
                // The body's stub.
                let stub = CGPoint(x: l, y: bottom + l)
                side.add(.cubic(CGPoint(x: x0 + (l - x0) * 0.45, y: bottom), CGPoint(x: x0 + (l - x0) * 0.55, y: bottom), CGPoint(x: l, y: bottom)))
                side.add(LiquidPath.arc(stub, l, from: -.pi / 2, to: -.pi).segment)
                // The bridge down the centre line, then the bud's stub from its tip.
                let tip = bud.stubTip(l2)
                side.add(.line(CGPoint(x: 0, y: tip)))
                if bud.cx >= l2 {
                    let s = CGPoint(x: l2, y: bud.top - l2)
                    side.add(LiquidPath.arc(s, l2, from: -.pi, to: -1.5 * .pi).segment)
                    budHalf(&side, bud, from: CGPoint(x: l2, y: bud.top), feature: nil)
                } else {
                    let s = CGPoint(x: l2, y: tip), ct = bud.topCentre
                    var angle = atan2(ct.y - s.y, ct.x - s.x)
                    if angle > -.pi / 2 { angle -= 2 * .pi }
                    side.add(LiquidPath.arc(s, l2, from: -.pi, to: max(angle, -1.5 * .pi)).segment)
                    budHalf(&side, bud, from: LiquidPath.toward(ct, s, bud.r), feature: .top)
                }
            }
            guard side.count == LiquidPath.sideCount else { return nil }
            return side
        }


        /// The bud's right half from `from` (on its top line when `feature` is nil, else on that part) to its bottom
        /// centre: top line, top arc, wall, bottom arc, bottom line, whatever lies before `from` collapsed onto it.
        func budHalf(_ side: inout Side, _ bud: Bud, from: CGPoint, feature: Bud.Feature?) {
            let ct = bud.topCentre, cb = bud.bottomCentre, r = bud.r
            switch feature {
            case nil:
                side.add(.line(CGPoint(x: bud.cx, y: bud.top)))
                side.add(LiquidPath.arc(ct, r, from: -.pi / 2, to: 0).segment)
                side.add(.line(CGPoint(x: bud.a, y: cb.y)))
            case .top:
                side.add(.line(from))
                let angle = min(0, max(-.pi / 2, atan2(from.y - ct.y, from.x - ct.x)))
                side.add(LiquidPath.arc(ct, r, from: angle, to: 0).segment)
                side.add(.line(CGPoint(x: bud.a, y: cb.y)))
            case .wall:
                side.add(.line(from))
                side.add(.cubic(from, from, from))
                side.add(.line(CGPoint(x: bud.a, y: cb.y)))
            case .bottom:
                side.add(.line(from))
                side.add(.cubic(from, from, from))
                side.add(.line(from))
            }
            let start: CGFloat = feature == .bottom ? min(.pi / 2, max(0, atan2(from.y - cb.y, from.x - cb.x))) : 0
            side.add(LiquidPath.arc(cb, r, from: start, to: .pi / 2).segment)
            side.add(.line(CGPoint(x: 0, y: bud.top + bud.h)))
        }
    }
}

// MARK: Sinks

extension LiquidPath {
    struct PathSink: LiquidSink {
        let path = CGMutablePath()
        var transform: CGAffineTransform

        mutating func move(_ p: CGPoint) { path.move(to: p, transform: transform) }
        mutating func line(_ p: CGPoint) { path.addLine(to: p, transform: transform) }
        mutating func curve(_ c1: CGPoint, _ c2: CGPoint, _ p: CGPoint) { path.addCurve(to: p, control1: c1, control2: c2, transform: transform) }
        mutating func close() { path.closeSubpath() }
    }

    struct SwiftUISink: LiquidSink {
        var path = Path()
        var origin: CGPoint

        private func at(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x, y: origin.y + p.y) }
        mutating func move(_ p: CGPoint) { path.move(to: at(p)) }
        mutating func line(_ p: CGPoint) { path.addLine(to: at(p)) }
        mutating func curve(_ c1: CGPoint, _ c2: CGPoint, _ p: CGPoint) { path.addCurve(to: at(p), control1: at(c1), control2: at(c2)) }
        mutating func close() { path.closeSubpath() }
    }

    struct ExtentSink: LiquidSink {
        var minX: CGFloat = 0, maxX: CGFloat = 0, maxY: CGFloat = 0

        private mutating func take(_ p: CGPoint) {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        mutating func move(_ p: CGPoint) { take(p) }
        mutating func line(_ p: CGPoint) { take(p) }
        mutating func curve(_ c1: CGPoint, _ c2: CGPoint, _ p: CGPoint) { take(c1); take(c2); take(p) }
        mutating func close() {}
    }

    /// Every element as it was written (tests): its kind and its points.
    struct RecordingSink: LiquidSink {
        enum Kind: Equatable { case move, line, curve, close }
        struct Element: Equatable { var kind: Kind; var points: [CGPoint] }
        var elements: [Element] = []

        mutating func move(_ p: CGPoint) { elements.append(Element(kind: .move, points: [p])) }
        mutating func line(_ p: CGPoint) { elements.append(Element(kind: .line, points: [p])) }
        mutating func curve(_ c1: CGPoint, _ c2: CGPoint, _ p: CGPoint) { elements.append(Element(kind: .curve, points: [c1, c2, p])) }
        mutating func close() { elements.append(Element(kind: .close, points: [])) }
    }

    static func elements(_ body: SurfaceGeometry, _ params: LiquidParams) -> [RecordingSink.Element] {
        var sink = RecordingSink()
        emit(body, params, into: &sink)
        return sink.elements
    }
}

// MARK: Keyframes

extension LiquidPath {
    /// The union's points in order (the move's, each line's, each cubic's three): 96 for the 45 elements.
    struct PointsSink: LiquidSink {
        static let capacity = 96
        var points = InlineArray<96, CGPoint>(repeating: .zero)
        var count = 0

        private mutating func take(_ p: CGPoint) {
            guard count < Self.capacity else { return }
            points[count] = p
            count += 1
        }
        mutating func move(_ p: CGPoint) { take(p) }
        mutating func line(_ p: CGPoint) { take(p) }
        mutating func curve(_ c1: CGPoint, _ c2: CGPoint, _ p: CGPoint) { take(c1); take(c2); take(p) }
        mutating func close() {}

        init() {}

        init(_ body: SurfaceGeometry, _ params: LiquidParams) {
            LiquidPath.emit(body, params, into: &self)
        }

        /// The union written again from its points into `sink`: the elements the emitter writes, in its order (every
        /// union has the same 45, `sideCurves` a side), so the same path from the points alone.
        func replay<S: LiquidSink>(into sink: inout S) {
            guard count == Self.capacity else { return }
            // Read through a span: an element read from the inline storage itself can copy all of it (P605).
            let p = points.span
            var i = 2
            sink.move(p[0])
            sink.line(p[1])
            for pass in 0..<2 {
                for j in 0..<LiquidPath.sideCount {
                    if LiquidPath.sideCurves[pass == 0 ? j : LiquidPath.sideCount - 1 - j] {
                        sink.curve(p[i], p[i + 1], p[i + 2])
                        i += 3
                    } else {
                        sink.line(p[i])
                        i += 1
                    }
                }
            }
            sink.close()
        }

        /// How far the points bend at `self` between `a` before it and `b` after it, equally spaced: their second
        /// difference, at most. A point's straight line between two of them strays at most half of it (a path with one
        /// corner between them; an even curve, an eighth).
        func bend(from a: Self, to b: Self) -> CGFloat {
            var worst: CGFloat = 0
            let ps = points.span, qs = a.points.span, rs = b.points.span
            for i in 0..<min(count, a.count, b.count) {
                let p = ps[i], q = qs[i], r = rs[i]
                let x = q.x - 2 * p.x + r.x, y = q.y - 2 * p.y + r.y
                worst = max(worst, x * x + y * y)
            }
            return worst.squareRoot()
        }

        /// The points' third difference over four equally spaced unions, at most: small where they move on an even curve,
        /// the size of the turn where their path has a corner between the last two.
        static func jerk(_ a: Self, _ b: Self, _ c: Self, _ d: Self) -> CGFloat {
            var worst: CGFloat = 0
            let ps = a.points.span, qs = b.points.span, rs = c.points.span, ts = d.points.span
            for i in 0..<min(a.count, b.count, c.count, d.count) {
                let p = ps[i], q = qs[i], r = rs[i], t = ts[i]
                let x = t.x - 3 * r.x + 3 * q.x - p.x, y = t.y - 3 * r.y + 3 * q.y - p.y
                worst = max(worst, x * x + y * y)
            }
            return worst.squareRoot()
        }

        /// How far `self` (the union between `a` and `b`) lies from the straight line between their points, at most.
        func stray(from a: Self, to b: Self) -> CGFloat {
            var worst: CGFloat = 0
            let ps = points.span, qs = a.points.span, rs = b.points.span
            for i in 0..<min(count, a.count, b.count) {
                let p = ps[i], q = qs[i], r = rs[i]
                let x = p.x - (q.x + r.x) / 2, y = p.y - (q.y + r.y) / 2
                worst = max(worst, x * x + y * y)
            }
            return worst.squareRoot()
        }
    }

    /// How far Core Animation's straight line between two keyframes may stray from the union halfway (the spec's
    /// bound is 0.5 pt; the keyframes keep it under this, the points' own stray, which bounds the outline's).
    static let keyframeStray: CGFloat = 0.2
    /// How far a liquid value's own spring may leave the straight line between two samples halfway before the plan takes
    /// the model's values there too (`SurfacePlan.mids`).
    static let midStray: CGFloat = 0.1
    /// Where the plan takes the model's values beside a pinch or a join, as shares of the time to the next sample or job:
    /// closing in on it geometrically (the neck's waist moves as a square root of the values there), then halving.
    static let nearFlip: [Double] = [1.0 / 8192, 1.0 / 2048, 1.0 / 512, 1.0 / 128, 1.0 / 64, 1.0 / 32, 1.0 / 16, 1.0 / 8, 3.0 / 16, 1.0 / 4,
                                     3.0 / 8, 1.0 / 2, 5.0 / 8, 3.0 / 4, 7.0 / 8]
}

extension IslandChoreography.SurfacePlan {
    /// Motion: Liquid's keyframes for Core Animation, each at its place among the samples (a fractional index): every
    /// sample and knot (a jump drawn both ways at its moment, the model's own values: `flips`, `mids`), and between two
    /// where a reservoir or the neck and the bud draw, as many more as keep the straight line between them within
    /// `LiquidPath.keyframeStray` of the union (from the values between them, as SwiftUI's ticker draws them). Where the
    /// pill's corner hands over to the body's, or the neck pinches, the union's points move along curves faster than a
    /// sample's straight line follows; everywhere else a sample's line is the union.
    func liquidKeyframes() -> [(index: Double, body: SurfaceGeometry, params: LiquidParams)] { liquidKeyframes(centreX: nil).keys }

    /// The keyframes and, with `centreX`, each one's union as a y-down `CGPath` (the fill's), written from the points the
    /// stray's check already wrote where it did.
    func liquidKeyframes(centreX: CGFloat?) -> (keys: [(index: Double, body: SurfaceGeometry, params: LiquidParams)], paths: [CGPath]) {
        guard let liquid, liquid.count == surface.count, !liquid.isEmpty else { return ([], []) }
        func structured(_ p: LiquidParams) -> Bool { p.reservoir != nil || p.budShows || p.lipBody > 0.001 || p.lipBead > 0.001 }
        func mix(_ a: SurfaceGeometry, _ b: SurfaceGeometry, _ u: CGFloat) -> SurfaceGeometry {
            SurfaceGeometry(left: a.left + (b.left - a.left) * u, right: a.right + (b.right - a.right) * u, height: a.height + (b.height - a.height) * u,
                            ear: a.ear + (b.ear - a.ear) * u, radius: a.radius + (b.radius - a.radius) * u, meniscus: a.meniscus + (b.meniscus - a.meniscus) * u)
        }
        var out: [(index: Double, body: SurfaceGeometry, params: LiquidParams)] = [(0, surface[0], liquid[0])]
        out.reserveCapacity(liquid.count + 8 + 2 * flips.count + mids.count)
        var built: [CGPath?] = centreX == nil ? [] : [nil]
        /// The unions' points the checks below wrote: the last segment's end and the two before it, and the next.
        var ring = [LiquidPath.PointsSink](repeating: LiquidPath.PointsSink(), count: 4)
        func append(_ key: (index: Double, body: SurfaceGeometry, params: LiquidParams), slot: Int? = nil) {
            out.append(key)
            if let centreX { built.append(slot.flatMap { LiquidPath.cgPath(ring[$0], centreX: centreX) }) }
        }
        /// The last keyframe drawn with other values (a knot's other side, a sample's own).
        func setLast(_ params: LiquidParams) {
            guard out[out.count - 1].params != params else { return }
            out[out.count - 1].params = params
            if centreX != nil { built[built.count - 1] = nil }
        }
        func write(_ g: SurfaceGeometry, _ p: LiquidParams, into slot: Int) {
            ring[slot].count = 0
            LiquidPath.emit(g, p, into: &ring[slot])
        }
        /// The last segment's end: its values, its points' place in the ring, how many unions before it at the same step
        /// are there (up to two), and the step.
        var carried: (body: SurfaceGeometry, params: LiquidParams, slot: Int, history: Int, span: Double)?
        /// From `(ia, ga, a)` to `(ib, gb, b)`: the keyframes between them that keep the line within the stray, then `b`.
        func segment(_ ia: Double, _ ga: SurfaceGeometry, _ a: LiquidParams, _ ib: Double, _ gb: SurfaceGeometry, _ b: LiquidParams) {
            guard structured(a) || structured(b) else {
                carried = nil
                return append((ib, gb, b))
            }
            let reused = carried.flatMap { $0.body == ga && $0.params == a && abs($0.span - (ib - ia)) < 1e-9 ? $0 : nil }
            let from = reused?.slot ?? 0, history = reused?.history ?? 0
            if reused == nil { write(ga, a, into: from) }
            let to = (from + 1) % 4
            write(gb, b, into: to)
            carried = (gb, b, to, min(history + 1, 2), ib - ia)
            // Where the points run on as they came, no look halfway: over equal steps, their second difference at most
            // eight times the stray halfway of an even curve (under 0.8: 0.1), and their third difference what a corner
            // in the path between the last two adds (under 0.2: 0.1).
            var even = false
            if history >= 2 {
                let previous = (from + 3) % 4, earlier = (from + 2) % 4
                even = ring[from].bend(from: ring[previous], to: ring[to]) < 4 * LiquidPath.keyframeStray
                    && LiquidPath.PointsSink.jerk(ring[earlier], ring[previous], ring[from], ring[to]) < LiquidPath.keyframeStray
            }
            if !even {
                let stray = LiquidPath.PointsSink(mix(ga, gb, 0.5), a.mixed(b, 0.5)).stray(from: ring[from], to: ring[to])
                if stray > LiquidPath.keyframeStray {
                    // The stray halfway shrinks as the square of the spacing.
                    let n = min(8, Int((stray / LiquidPath.keyframeStray).squareRoot().rounded(.up)))
                    for j in 1..<max(1, n) {
                        let u = CGFloat(j) / CGFloat(n)
                        append((ia + (ib - ia) * Double(u), mix(ga, gb, u), a.mixed(b, u)))
                    }
                }
            }
            append((ib, gb, b), slot: to)
        }
        for i in 1..<liquid.count {
            guard hasKnots(after: i - 1) else {
                segment(Double(i - 1), surface[i - 1], liquid[i - 1], Double(i), surface[i], liquid[i])
                continue
            }
            // Through the knots between these samples: a jump drawn both ways at its moment (each side between its
            // neighbours only), the model's own values where they curve.
            var from = (index: Double(i - 1), body: surface[i - 1], params: liquid[i - 1])
            for knot in knots(after: i - 1) {
                if knot.index > from.index + 1e-9 {
                    segment(from.index, from.body, from.params, knot.index, knot.body, knot.before)
                } else {
                    setLast(knot.before)
                }
                if knot.after != knot.before { append((knot.index, knot.body, knot.after)) }
                from = (knot.index, knot.body, knot.after)
            }
            if from.index < Double(i) - 1e-9 {
                segment(from.index, from.body, from.params, Double(i), surface[i], liquid[i])
            } else {
                setLast(liquid[i])
            }
        }
        guard let centreX else { return (out, []) }
        let paths = zip(out, built).map { key, path in path ?? LiquidPath.cgPath(key.body, key.params, centreX: centreX) }
        return (out, paths)
    }
}
