import CoreGraphics

// Motion: Liquid. Where the closed pill a close drains into (the reservoir) meets the body, one side at a time: the
// union of the two outlines, exactly, with a concave fillet where they cross. From the top edge the outline runs down
// whichever wall stands out; where the pill stands out it follows the pill's own corner and bottom until they cross the
// body's wall or corner, turns into the body on a fillet, and follows the body's own wall and corner to its bottom. So
// the drawn outline holds both (nothing of the pill is cut), its corners are always the pill's and the body's own (never
// sharpened into a ledge), and as the body's wall comes out to the pill's the pill's part shrinks along its own corner to
// nothing at the corner's top, where the pill's elements then lie on the body's wall. Where the pill stands out by
// nothing the body's corner is kept no rounder than holds the pill's (`LiquidPath.containHang`), so the union is the
// body there: the reservoir clears where that clamp is idle (`drawsNothing`) and no point leaves the outline.

extension LiquidPath {
    /// A corner's three cubics from `start`.
    struct Chain {
        var start: CGPoint
        var a: Segment
        var b: Segment
        var c: Segment

        init(start: CGPoint, _ s: (Segment, Segment, Segment)) {
            self.start = start
            a = s.0
            b = s.1
            c = s.2
        }

        func segment(_ i: Int) -> Segment { i == 0 ? a : i == 1 ? b : c }
        func from(_ i: Int) -> CGPoint { i == 0 ? start : i == 1 ? a.to : b.to }
        var end: CGPoint { c.to }
        var all: (Segment, Segment, Segment) { (a, b, c) }

        /// The cubic and the parameter on it for `s` in 0...3.
        static func locate(_ s: CGFloat) -> (Int, CGFloat) {
            let i = min(2, max(0, Int(s.rounded(.down))))
            return (i, min(1, max(0, s - CGFloat(i))))
        }

        func point(_ s: CGFloat) -> CGPoint {
            let (i, t) = Self.locate(s)
            return LiquidPath.point(segment(i), from: from(i), t)
        }

        /// The unit direction of travel at `s` (`fallback` where the chain has no length).
        func direction(_ s: CGFloat, fallback: CGPoint) -> CGPoint {
            let (i, t) = Self.locate(s)
            return LiquidPath.direction(segment(i), from: from(i), t, fallback: fallback)
        }

        /// From its start to `s`, as three cubics: those past `s` lie at its point.
        func head(_ s: CGFloat) -> (Segment, Segment, Segment) {
            let (i, t) = Self.locate(s)
            let p = point(s), none = Segment.cubic(p, p, p)
            func slot(_ j: Int) -> Segment { j < i ? segment(j) : j == i ? LiquidPath.piece(segment(j), from: from(j), 0, t) : none }
            return (slot(0), slot(1), slot(2))
        }

        /// From `s` to its end, as three cubics: those before `s` lie at its point.
        func tail(_ s: CGFloat) -> (Segment, Segment, Segment) {
            let (i, t) = Self.locate(s)
            let p = point(s), none = Segment.cubic(p, p, p)
            func slot(_ j: Int) -> Segment { j < i ? none : j == i ? LiquidPath.piece(segment(j), from: from(j), t, 1) : segment(j) }
            return (slot(0), slot(1), slot(2))
        }
    }

    /// A chain at 25 points (8 a cubic), with the length along it at each: enough to find where two outlines cross and
    /// how far along them a fillet reaches (a chord of an eighth of a 90° corner of radius 40 is 0.02 pt off its arc).
    struct Samples {
        static let perCubic = 8
        static let count = 25
        var points: InlineArray<25, CGPoint>
        var lengths: InlineArray<25, CGFloat>

        init(_ chain: Chain) {
            points = InlineArray(repeating: chain.start)
            lengths = InlineArray(repeating: 0)
            var previous = chain.start, total: CGFloat = 0
            for i in 0..<3 {
                let segment = chain.segment(i), from = chain.from(i)
                for k in 1...Self.perCubic {
                    let p = LiquidPath.point(segment, from: from, CGFloat(k) / CGFloat(Self.perCubic))
                    total += hypot(p.x - previous.x, p.y - previous.y)
                    let index = 1 + i * Self.perCubic + (k - 1)
                    points[index] = p
                    lengths[index] = total
                    previous = p
                }
            }
        }

        var length: CGFloat { lengths.span[Self.count - 1] }

        static func parameter(_ index: Int) -> CGFloat { CGFloat(index) / CGFloat(perCubic) }

        /// The length along the chain at `s` (between samples, linearly).
        func length(at s: CGFloat) -> CGFloat {
            let x = min(CGFloat(Self.count - 1), max(0, s * CGFloat(Self.perCubic)))
            let i = min(Self.count - 2, Int(x.rounded(.down)))
            let l = lengths.span
            return l[i] + (l[i + 1] - l[i]) * (x - CGFloat(i))
        }

        /// Where along the chain the length reaches `l` (clamped to the chain).
        func parameter(atLength l: CGFloat) -> CGFloat {
            guard l > 0 else { return 0 }
            guard l < length else { return 3 }
            var i = 1
            let lengths = lengths.span
            while i < Self.count - 1, lengths[i] < l { i += 1 }
            let a = lengths[i - 1], b = lengths[i]
            let u = b > a ? (l - a) / (b - a) : 0
            return (CGFloat(i - 1) + u) / CGFloat(Self.perCubic)
        }
    }

    // MARK: Cubics

    static func point(_ s: Segment, from p0: CGPoint, _ t: CGFloat) -> CGPoint {
        guard s.curve else { return CGPoint(x: p0.x + (s.to.x - p0.x) * t, y: p0.y + (s.to.y - p0.y) * t) }
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * s.c1.x + c * s.c2.x + d * s.to.x, y: a * p0.y + b * s.c1.y + c * s.c2.y + d * s.to.y)
    }

    static func direction(_ s: Segment, from p0: CGPoint, _ t: CGFloat, fallback: CGPoint) -> CGPoint {
        var d: CGPoint
        if s.curve {
            let u = 1 - t
            let a = 3 * u * u, b = 6 * u * t, c = 3 * t * t
            d = CGPoint(x: a * (s.c1.x - p0.x) + b * (s.c2.x - s.c1.x) + c * (s.to.x - s.c2.x),
                        y: a * (s.c1.y - p0.y) + b * (s.c2.y - s.c1.y) + c * (s.to.y - s.c2.y))
            // A handle of no length: the chord toward the far end.
            if hypot(d.x, d.y) < 1e-9 { d = t < 0.5 ? CGPoint(x: s.c2.x - p0.x, y: s.c2.y - p0.y) : CGPoint(x: s.to.x - s.c1.x, y: s.to.y - s.c1.y) }
        } else {
            d = CGPoint(x: s.to.x - p0.x, y: s.to.y - p0.y)
        }
        let l = hypot(d.x, d.y)
        return l > 1e-9 ? CGPoint(x: d.x / l, y: d.y / l) : fallback
    }

    /// The piece of a cubic from `t0` to `t1` (its start is `p0`'s point at `t0`); a line's piece is its line to `t1`.
    static func piece(_ s: Segment, from p0: CGPoint, _ t0: CGFloat, _ t1: CGFloat) -> Segment {
        guard s.curve else { return .line(point(s, from: p0, t1)) }
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        // [0, t1] by de Casteljau.
        let a1 = lerp(p0, s.c1, t1), b1 = lerp(s.c1, s.c2, t1), c1 = lerp(s.c2, s.to, t1)
        let a2 = lerp(a1, b1, t1), b2 = lerp(b1, c1, t1)
        let end = lerp(a2, b2, t1)
        guard t1 > 1e-12 else { return .cubic(p0, p0, p0) }
        // Its piece from t0 / t1.
        let u = min(1, max(0, t0 / t1))
        let q0 = p0, q1 = a1, q2 = a2, q3 = end
        let r1 = lerp(q1, q2, u), r2 = lerp(q2, q3, u)
        _ = q0
        return .cubic(lerp(r1, r2, u), r2, q3)
    }

    /// The direction's angle from straight down, turning toward the centre line (down 0, inward π/2).
    static func heading(_ d: CGPoint) -> CGFloat { atan2(-d.x, d.y) }
}

extension LiquidPath.Shape {
    /// The junction's values on one side.
    struct JunctionValues {
        /// The body's wall and bottom as drawn, and how far it hangs below the pill.
        var wb: CGFloat
        var bottom: CGFloat
        var hang: CGFloat
        /// The pill's wall (a hair inside itself, `standEpsilon`), bottom and corner.
        var wp: CGFloat
        var hp: CGFloat
        var rp: CGFloat
        /// How far the pill stands out past the body's wall (0 where it does not).
        var stands: CGFloat
        /// The top edge's ear, the body's continuous corner and its circle as drawn (clamped to hold the pill's where it
        /// stands out by little), the continuous corner it has of its own, and how round its corners are (0 continuous,
        /// 1 circles).
        var ear: CGFloat
        var rb: CGFloat
        var rc: CGFloat
        var ownRadius: CGFloat
        var roundness: CGFloat
    }

    func junctionValues(reach w: CGFloat, pillReach: CGFloat, pill: SurfaceGeometry) -> JunctionValues {
        let reach = ContinuousCorner.reach
        let wb = max(0, w - ear)
        let hp = max(0, pill.height)
        let hang = max(0, bottom - hp)
        let wp = max(0, pillReach - pillEar - LiquidPath.standEpsilon)
        let gp = max(0, wp - wb), gm = max(0, wb - wp)
        let blend = LiquidPath.smoothstep(gp / LiquidPath.earBlend)
        // The top edge reaches at least as far as the pill's: its ear no smaller than the pill's where the pill stands
        // out, and than what the pill's reaches past the body's wall where it does not.
        let earNow = gp > 0 ? max(ear + (pillEar - ear) * blend, pillEar) : max(ear, pillEar - gm)
        let rp = max(0, min(pillRadius, (hp - earNow) / reach))
        let cap = rp + LiquidPath.containHang * hang + LiquidPath.containWide * gm + LiquidPath.containStand * gp
        let room = max(0, bottom - earNow)
        let own = max(0, min(radius, wb / reach, room / reach))
        let rb = min(own, cap)
        let rc = max(0, min(body.radius + max(0, p.round), wb, room, cap))
        return JunctionValues(wb: wb, bottom: bottom, hang: hang, wp: wp, hp: hp, rp: rp, stands: gp, ear: earNow, rb: rb, rc: rc,
                              ownRadius: own, roundness: blend)
    }

    /// Whether the body holds the pill on this side: it does not stand out, and the body's corner is its own.
    func holdsPill(reach w: CGFloat, pillReach: CGFloat) -> Bool {
        guard let pill else { return true }
        let v = junctionValues(reach: w, pillReach: pillReach, pill: pill)
        return v.stands <= 0 && v.ownRadius - v.rb <= 0.01 && v.ear <= ear + 0.001
    }

    /// One side from the top edge's end to the body's bottom, with a reservoir: the ear, the outer wall, the pill's
    /// corner and bottom, the fillet, the body's wall and corner; where the body's bottom starts, and its wall.
    func junction(reach w: CGFloat, pillReach: CGFloat, pill: SurfaceGeometry) -> (side: LiquidPath.Side, flatEnd: CGFloat, wall: CGFloat)? {
        let reach = ContinuousCorner.reach, k = LiquidPath.quarter
        let v = junctionValues(reach: w, pillReach: pillReach, pill: pill)
        let wb = v.wb, H = v.bottom, hp = v.hp, earNow = v.ear
        guard wb.isFinite, H.isFinite, v.wp.isFinite, hp.isFinite else { return nil }
        if v.stands <= 0 {
            // The body stands out (or as far): its own wall and continuous corner, the pill's elements on its wall at the
            // pill's corner's top (or the body's corner's, if higher).
            let top = H - reach * v.rb
            let yp = max(earNow, min(hp - reach * v.rp, top))
            let at = CGPoint(x: wb, y: yp)
            var side = LiquidPath.Side(start: CGPoint(x: wb + earNow, y: 0))
            side.add(.cubic(CGPoint(x: wb + earNow - k * earNow, y: 0), CGPoint(x: wb, y: earNow - k * earNow), CGPoint(x: wb, y: earNow)))
            side.add(.line(at))
            for _ in 0..<3 { side.add(.cubic(at, at, at)) }
            side.add(.line(at))
            side.add(.cubic(at, at, at))
            side.add(.line(CGPoint(x: wb, y: top)))
            LiquidPath.corner(&side, at: CGPoint(x: wb, y: H), radius: v.rb)
            return (side, wb - reach * v.rb, wb)
        }
        // The pill stands out: its wall, its own corner (A), then where it meets the body (B: its wall, then its corner,
        // a continuous corner blending to circles as the pill stands out).
        let wp = v.wp, rp = v.rp
        let pillStart = CGPoint(x: wp, y: hp - reach * rp)
        let a = LiquidPath.Chain(start: pillStart, LiquidPath.cornerCurves(at: CGPoint(x: wp, y: hp), radius: rp))
        let c = v.roundness
        let f9 = LiquidPath.cornerCurves(at: CGPoint(x: wb, y: H), radius: v.rb)
        let centre = CGPoint(x: wb - v.rc, y: H - v.rc)
        func arc(_ i: Int) -> LiquidPath.Segment {
            LiquidPath.arc(centre, v.rc, from: .pi / 2 * CGFloat(i) / 3, to: .pi / 2 * CGFloat(i + 1) / 3).segment
        }
        let bodyTop = CGPoint(x: wb, y: H - (reach * v.rb + (v.rc - reach * v.rb) * c))
        let b = LiquidPath.Chain(start: bodyTop, (.mix(f9.0, arc(0), c), .mix(f9.1, arc(1), c), .mix(f9.2, arc(2), c)))
        let aSamples = LiquidPath.Samples(a), bSamples = LiquidPath.Samples(b)
        // Their points read from local copies: an element read through the stored inline storage can copy all of it.
        let aPoints = aSamples.points, bPoints = bSamples.points
        let bodyEnd = b.end

        // Along a corner y − x only grows (its heading runs from down to inward), and fast (at least 1 a point), so a
        // point's place along the body's corner is found by it, well-conditioned where the corner runs flat.
        func diagonal(_ p: CGPoint) -> CGFloat { p.y - p.x }
        // Inside the body (or on it): left of its wall above the corner, above its bottom past it, and on the inner side
        // of the corner's chord between.
        func inside(_ p: CGPoint) -> Bool {
            let m = diagonal(p)
            let first = bPoints[0], last = bPoints[LiquidPath.Samples.count - 1]
            if p.y > H + 1e-9 { return false }
            if m <= diagonal(first) || p.y <= bodyTop.y { return p.x <= wb + 1e-9 }
            if m >= diagonal(last) { return p.y <= H + 1e-9 }
            var j = 1
            while j < LiquidPath.Samples.count - 1, diagonal(bPoints[j]) < m { j += 1 }
            let u = bPoints[j - 1], v = bPoints[j]
            return (v.x - u.x) * (p.y - u.y) - (v.y - u.y) * (p.x - u.x) >= -1e-9
        }
        // Where along the body's corner a point on it is (by y − x, on the curve itself).
        func bodyParameter(_ p: CGPoint) -> CGFloat {
            let m = diagonal(p)
            if m <= diagonal(bodyTop) { return 0 }
            if m >= diagonal(bodyEnd) { return 3 }
            var lo: CGFloat = 0, hi: CGFloat = 3
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if diagonal(b.point(mid)) < m { lo = mid } else { hi = mid }
            }
            return (lo + hi) / 2
        }
        // Where the body's outline crosses the height y (its wall, or its corner, on the curve itself).
        func bodyX(_ y: CGFloat) -> CGFloat {
            if y <= bodyTop.y { return wb }
            if y >= bodyEnd.y { return bodyEnd.x }
            var lo: CGFloat = 0, hi: CGFloat = 3
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if b.point(mid).y < y { lo = mid } else { hi = mid }
            }
            return b.point((lo + hi) / 2).x
        }

        // Where the pill's outline first enters the body: on its corner, or on its bottom.
        var crossing: CGFloat?
        for i in 1..<LiquidPath.Samples.count where inside(aPoints[i]) {
            var lo = LiquidPath.Samples.parameter(i - 1), hi = LiquidPath.Samples.parameter(i)
            for _ in 0..<16 {
                let mid = (lo + hi) / 2
                if inside(a.point(mid)) { hi = mid } else { lo = mid }
            }
            crossing = hi
            break
        }
        let x: CGPoint, alongPill: CGFloat, onBottom: CGFloat
        if let s = crossing {
            x = a.point(s)
            alongPill = aSamples.length(at: s)
            onBottom = 0
        } else {
            let end = a.end
            let meet = min(end.x, bodyX(hp))
            x = CGPoint(x: meet, y: hp)
            onBottom = max(0, end.x - meet)
            alongPill = aSamples.length + onBottom
        }
        // Where that is on the body: its wall (a length before the corner's top), or along its corner (or its bottom).
        let bodyStart: CGFloat, bodyHeading: CGFloat
        if x.y <= bodyTop.y {
            bodyStart = -(bodyTop.y - x.y)
            bodyHeading = 0
        } else {
            let s = bodyParameter(x)
            bodyStart = bSamples.length(at: s)
            bodyHeading = LiquidPath.heading(b.direction(s, fallback: CGPoint(x: -1, y: 0)))
        }
        // The kink: how far the outline turns back from the pill's heading to the body's.
        let pillHeading = crossing.map { LiquidPath.heading(a.direction($0, fallback: CGPoint(x: -1, y: 0))) } ?? .pi / 2
        let turn = max(0, pillHeading - bodyHeading)
        // The fillet: tangent to both at a reach that makes a circle of the reservoir's radius, no more than half of the
        // pill that shows before the crossing nor half of the body that hangs below it.
        let d = max(0, min(LiquidPath.reservoirFillet * tan(min(turn, .pi / 2 - 1e-6) / 2), alongPill / 2, (H - x.y) / 2))
        // Its start on the pill: back along the bottom, or along the corner.
        let fa: CGPoint, faHeading: CGPoint, faOnBottom: Bool, faCorner: CGFloat
        if crossing == nil, onBottom >= d {
            fa = CGPoint(x: x.x + d, y: hp)
            faHeading = CGPoint(x: -1, y: 0)
            faOnBottom = true
            faCorner = 3
        } else {
            faCorner = aSamples.parameter(atLength: alongPill - d)
            fa = a.point(faCorner)
            faHeading = a.direction(faCorner, fallback: CGPoint(x: 0, y: 1))
            faOnBottom = false
        }
        // Its end on the body: down the wall, along the corner, or along the bottom.
        enum Where { case wall, corner(CGFloat), bottom }
        let fb: CGPoint, fbHeading: CGPoint, fbOn: Where
        let target = bodyStart + d
        if target <= 0 {
            fb = CGPoint(x: wb, y: bodyTop.y + target)
            fbHeading = CGPoint(x: 0, y: 1)
            fbOn = .wall
        } else if target < bSamples.length {
            let s = bSamples.parameter(atLength: target)
            fb = b.point(s)
            fbHeading = b.direction(s, fallback: CGPoint(x: -1, y: 0))
            fbOn = .corner(s)
        } else {
            fb = CGPoint(x: bodyEnd.x - (target - bSamples.length), y: H)
            fbHeading = CGPoint(x: -1, y: 0)
            fbOn = .bottom
        }
        // A cubic tangent to both, as a circle's arc through them would be.
        let chord = hypot(fb.x - fa.x, fb.y - fa.y)
        let bend = max(0, LiquidPath.heading(faHeading) - LiquidPath.heading(fbHeading))
        let handle = bend < 1e-4 ? chord / 3 : 4 / 3 * tan(bend / 4) * chord / (2 * sin(bend / 2))
        let fillet = LiquidPath.Segment.cubic(CGPoint(x: fa.x + handle * faHeading.x, y: fa.y + handle * faHeading.y),
                                              CGPoint(x: fb.x - handle * fbHeading.x, y: fb.y - handle * fbHeading.y), fb)

        var side = LiquidPath.Side(start: CGPoint(x: wp + earNow, y: 0))
        side.add(.cubic(CGPoint(x: wp + earNow - k * earNow, y: 0), CGPoint(x: wp, y: earNow - k * earNow), CGPoint(x: wp, y: earNow)))
        side.add(.line(pillStart))
        let pillCorner = faOnBottom ? a.all : a.head(faCorner)
        side.add(pillCorner.0)
        side.add(pillCorner.1)
        side.add(pillCorner.2)
        side.add(.line(fa))
        side.add(fillet)
        let flatEnd: CGFloat
        switch fbOn {
        case .wall:
            side.add(.line(bodyTop))
            side.add(b.a)
            side.add(b.b)
            side.add(b.c)
            flatEnd = bodyEnd.x
        case let .corner(s):
            side.add(.line(fb))
            let rest = b.tail(s)
            side.add(rest.0)
            side.add(rest.1)
            side.add(rest.2)
            flatEnd = bodyEnd.x
        case .bottom:
            side.add(.line(fb))
            for _ in 0..<3 { side.add(.cubic(fb, fb, fb)) }
            flatEnd = fb.x
        }
        guard flatEnd.isFinite, side.end.x.isFinite, side.end.y.isFinite else { return nil }
        return (side, flatEnd, wb)
    }
}
