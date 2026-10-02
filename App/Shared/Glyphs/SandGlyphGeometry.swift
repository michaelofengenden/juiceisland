import Foundation
import simd
import SwiftUI

/// The Sand glyph's fixed geometry in the unit square (y down), built once per grain pitch: the pile's grains on a
/// packed lattice and the grains of the three marks. `SandGlyph.frame` moves these; nothing here depends on time.
///
/// Grains are fine: about 0.6 pt at 14 pt, 0.8 pt at 20 to 22 pt (1.2 to 1.7 device pixels at 2×), 1.1 pt in the 28 pt
/// pill and under 2 pt at 84 pt, a touch wider than their pitch so the pile and the marks read as solid sand with a
/// grain in it. A mark is woven along its strokes, its outermost rows exactly on the edge, so "!" and "?" have clean
/// silhouettes at 22 pt.
struct SandGeometry: Sendable {
    /// Lattice pitch (distance between neighbouring grains) and grain diameter, in unit-square lengths.
    let pitch: Double
    let grain: Double
    /// The pill's and the rows' sizes (under 30 pt), where at 2× every grain is a pixel or two: grains vary a third as
    /// much in shade and place, the stream is a dense pour about four grains wide onto a fuller pile (`SandPile.crisp`)
    /// and a formed mark has a solid body under its grains, so the glyph reads clear and defined instead of speckled.
    /// The large sizes keep their full texture.
    let crisp: Bool
    /// The distance between two rows of the pile's packed lattice.
    let rowPitch: Double
    let cells: [SandPileCell]
    let bang: [SandMarkGrain]
    let ques: [SandMarkGrain]
    let check: [SandMarkGrain]
    /// Delegating's three clumps (`SandMarkShape.helpers`), left to right.
    let helpers: [SandMarkGrain]
    /// The check's upper-right tip, where the done sparkle glints.
    let checkTip: SIMD2<Double>
    /// The pile's resting shape: `SandPile.crisp` at the crisp sizes, `.fine` above them.
    let pile: SandPile

    /// Four pitches cover every size: 14 pt, the pill and rows (17…30 pt), mid sizes and large renders. Each is built
    /// the first time a glyph of its size draws (a few milliseconds), so the app only ever builds the ones it shows.
    static let small = SandGeometry(pitch: 0.043, crisp: true)
    static let regular = SandGeometry(pitch: 0.035, crisp: true)
    static let medium = SandGeometry(pitch: 0.028, crisp: false)
    static let large = SandGeometry(pitch: 0.021, crisp: false)

    static func forSide(_ side: Double) -> SandGeometry {
        side < 17 ? small : side < 30 ? regular : side < 60 ? medium : large
    }

    // MARK: The pile

    init(pitch: Double, crisp: Bool) {
        self.pitch = pitch
        self.crisp = crisp
        grain = pitch * 1.08
        rowPitch = pitch * 0.866
        pile = crisp ? .crisp : .fine
        cells = Self.pileCells(pitch: pitch, rowPitch: rowPitch, pile: pile)
        let inset = grain * 0.45, texture = crisp ? 1.0 / 3 : 1
        bang = Self.markGrains(SandMarkShape.bang, kind: .bang, pitch: pitch, inset: inset, texture: texture)
        ques = Self.markGrains(SandMarkShape.ques, kind: .ques, pitch: pitch, inset: inset, texture: texture)
        check = Self.markGrains(SandMarkShape.check, kind: .check, pitch: pitch, inset: inset, texture: texture)
        helpers = Self.markGrains(SandMarkShape.helpers, kind: .dots, pitch: pitch, inset: inset, texture: texture)
        checkTip = SIMD2(0.852, 0.1)
    }

    /// The pile's lattice: packed rows from the base line up to the resting surface plus room for the running bump.
    /// Each grain keeps its own coverage threshold (a sandy edge), jitter, shade noise, size and a rare glint.
    private static func pileCells(pitch: Double, rowPitch: Double, pile: SandPile) -> [SandPileCell] {
        var cells: [SandPileCell] = []
        let columns = Int((1 / pitch).rounded(.up)) + 1
        let rows = Int(((pile.height + 0.06) / rowPitch).rounded(.up))
        for row in 0..<rows {
            let floor = Double(row) * rowPitch
            let shift = row & 1 == 1 ? 0.5 : 0
            for column in 0..<columns {
                let x = 0.5 + (Double(column - columns / 2) + shift) * pitch
                guard x > 0.02, x < 0.98, pile.height(at: x) + 0.055 >= floor else { continue }
                let h = { (salt: Int) in SandHash.unit(column, row, salt) }
                cells.append(SandPileCell(
                    x: x, floor: floor, rest: pile.height(at: x), threshold: 0.25 + 0.5 * h(4),
                    jitterX: (h(2) - 0.5) * 0.3 * pitch, jitterY: (h(3) - 0.5) * 0.26 * pitch,
                    noise: h(1) - 0.5, size: 0.86 + 0.28 * h(5), glint: h(6) > 0.955))
            }
        }
        return cells
    }

    // MARK: The marks

    /// A mark's grains, woven along its strokes: rows of grains run parallel to each stroke's centre line, evenly
    /// spaced from one edge to the other (the outermost rows exactly on the edge, so the silhouette is clean), and turn
    /// round each end as nested half rings; a dot is nested rings. There are no gaps between an outline and a fill.
    /// Each grain is shaded like a lit tube: bright on the side facing the upper left, a touch darker on the far side.
    /// `texture` scales how far each grain strays from that in shade and place. `order` runs 0 (first to fly) … 1: top
    /// to bottom for "!" and "?", left to right for the check and delegating's clumps.
    private static func markGrains(_ shape: SandMarkShape, kind: SandMarkKind, pitch: Double, inset: Double,
                                   texture: Double) -> [SandMarkGrain] {
        var placed: [(p: SIMD2<Double>, facing: Double)] = []
        let light = simd_normalize(SIMD2(-0.55, -0.85))
        /// `across` is where the grain sits across its stroke (−1 … 1 along `normal`), which sets its shading.
        func place(_ p: SIMD2<Double>, _ normal: SIMD2<Double>, across: Double) {
            guard !placed.contains(where: { simd_length($0.p - p) < 0.6 * pitch }) else { return }
            placed.append((p, simd_dot(normal, light) * across))
        }
        for stroke in shape.strokes { weave(stroke, inset: inset, pitch: pitch, into: place) }
        for dot in shape.dots {
            let outer = dot.z - inset, rings = max(1, Int((outer / (0.87 * pitch)).rounded()))
            for ring in 0...rings {
                let radius = outer * (1 - Double(ring) / Double(rings))
                let count = radius < 0.3 * pitch ? 1 : max(3, Int((2 * .pi * radius / pitch).rounded()))
                for i in 0..<count {
                    let angle = 2 * .pi * (Double(i) + 0.5 * Double(ring & 1)) / Double(count) - .pi / 2
                    let normal = SIMD2(cos(angle), sin(angle))
                    place(SIMD2(dot.x, dot.y) + normal * radius, normal, across: radius / max(1e-9, outer))
                }
            }
        }

        let xs = placed.map { $0.p.x }, ys = placed.map { $0.p.y }
        let (x0, x1, y0, y1) = (xs.min() ?? 0, xs.max() ?? 1, ys.min() ?? 0, ys.max() ?? 1)
        return placed.enumerated().map { i, grain in
            let h = { (salt: Int) in SandHash.unit(i, kind.rawValue, salt) }
            let p = grain.p + SIMD2(h(5) - 0.5, h(6) - 0.5) * 0.14 * texture * pitch
            let across = kind == .check || kind == .dots
            let along = across ? (p.x - x0) / max(1e-6, x1 - x0) : (p.y - y0) / max(1e-6, y1 - y0)
            // The jet runs up the middle, then fans out to the grain's place.
            let pull = across ? 0.55 : 0.2
            return SandMarkGrain(
                x: p.x, y: p.y, order: min(1, max(0, 0.85 * along + 0.15 * h(1))), h: h(1),
                sourceX: 0.5 + (h(2) - 0.5) * 0.3, controlX: 0.5 + (p.x - 0.5) * pull,
                shade: 0.18 + 0.24 * grain.facing + (h(3) - 0.5) * 0.14 * texture, size: 0.94 + 0.12 * h(4),
                diagonal: (p.x - 0.5) * 0.7 - (p.y - 0.35))
        }
    }

    /// Weaves one stroke (a centre line with a radius at every point): rows parallel to the centre line from edge to
    /// edge (`inset` inside it), each resampled every `pitch` along its length and staggered half a pitch from its
    /// neighbours, and at each end nested half rings joining row j to its mirror row.
    private static func weave(_ stroke: [SIMD3<Double>], inset: Double, pitch: Double,
                              into place: (SIMD2<Double>, SIMD2<Double>, Double) -> Void) {
        let points = stroke.map { SIMD2($0.x, $0.y) }, count = points.count
        guard count >= 2 else { return }
        let normals: [SIMD2<Double>] = (0..<count).map { i in
            let t = simd_normalize(points[min(count - 1, i + 1)] - points[max(0, i - 1)])
            return SIMD2(-t.y, t.x)
        }
        let widest = stroke.map(\.z).max()! - inset
        let rows = max(2, Int((2 * widest / (0.87 * pitch)).rounded()) + 1)
        for row in 0..<rows {
            let across = -1 + 2 * Double(row) / Double(rows - 1)
            let line = (0..<count).map { points[$0] + normals[$0] * across * (stroke[$0].z - inset) }
            var s = row & 1 == 1 ? 0.5 * pitch : 0
            for i in 1..<count {
                let a = line[i - 1], b = line[i], length = simd_length(b - a)
                while s <= length {
                    let u = length > 0 ? s / length : 0
                    let normal = simd_normalize(normals[i - 1] * (1 - u) + normals[i] * u)
                    place(a + (b - a) * u, across < 0 ? -normal : normal, abs(across))
                    s += pitch
                }
                s -= length
            }
        }
        for end in [0, count - 1] {
            let centre = points[end], outer = stroke[end].z - inset
            let t = end == 0 ? simd_normalize(points[0] - points[1]) : simd_normalize(points[count - 1] - points[count - 2])
            let base = atan2(t.y, t.x)
            for row in 0..<(rows / 2) {
                let radius = outer * (1 - 2 * Double(row) / Double(rows - 1))
                let steps = max(2, Int((Double.pi * radius / pitch).rounded()))
                for i in 1..<steps {
                    let angle = base - .pi / 2 + .pi * Double(i) / Double(steps)
                    let normal = SIMD2(cos(angle), sin(angle))
                    place(centre + normal * radius, normal, radius / max(1e-9, outer))
                }
            }
        }
    }
}

/// The pile's resting shape in the unit square: how tall and how wide it is, how full its flanks are (the cone's
/// exponent: lower is rounder), and how far its top sinks where a mark's grains left it, so a formed "!", "?" or check
/// stands clear of the pile's flattened top. It is the same in every mood, so it never reads as a meter.
struct SandPile: Sendable {
    let height: Double
    let halfWidth: Double
    let fullness: Double
    let dip: Double

    /// The large sizes' pile: a cone with a slightly rounded peak and a flared foot, 0.28 tall and 0.86 wide.
    static let fine = SandPile(height: 0.28, halfWidth: 0.43, fullness: 1.3, dip: 0.08)
    /// The pill's and the rows' pile: taller, wider and fuller, so running reads as sand pouring onto a heap rather
    /// than a needle over a speck. Its top sinks further under a mark, which stands as clear of it as of the fine one.
    static let crisp = SandPile(height: 0.32, halfWidth: 0.46, fullness: 1.15, dip: 0.12)

    /// The resting surface's height above the base line at `x`.
    func height(at x: Double) -> Double {
        let d = abs(x - 0.5) / halfWidth
        return d < 1 ? height * (1 - pow(d, fullness)) : 0
    }
}

/// One grain of the pile: its lattice position, the row's floor as a height above the base line, the resting surface
/// above it, and what makes it its own grain (threshold, jitter, shade noise, size, glint).
struct SandPileCell: Sendable {
    let x: Double
    let floor: Double
    let rest: Double
    let threshold: Double
    let jitterX: Double
    let jitterY: Double
    let noise: Double
    let size: Double
    let glint: Bool
}

/// One grain of a mark: where it rests in the mark, when it flies (`order`), where it leaves the pile and the jet's
/// control point, its shade (lit rim or core), its size and where it sits along the glint's diagonal.
struct SandMarkGrain: Sendable {
    let x: Double
    let y: Double
    let order: Double
    let h: Double
    let sourceX: Double
    let controlX: Double
    let shade: Double
    let size: Double
    let diagonal: Double
}

enum SandMarkKind: Int, Sendable {
    /// `dots`: delegating's three clumps.
    case bang = 1, ques = 2, check = 3, dots = 4

    /// The mark's outline in the unit square (`SandMarkShape.outline`), built once.
    var outline: Path { Self.outlines[rawValue - 1] }

    private static let outlines = [SandMarkShape.bang, .ques, .check, .helpers].map { $0.outline() }
}

/// The marks as strokes (centre lines with a radius at every point, x y r) and dots (x y r), in the unit square. The
/// "!"'s bar is nearly even (no wide top) and its dot stands 0.07 clear of it (1.5 pt at 22 pt); the "?"'s hook is a
/// round arc that curls back into a short stem over its own dot.
struct SandMarkShape: Sendable {
    let strokes: [[SIMD3<Double>]]
    let dots: [SIMD3<Double>]

    static let bang = SandMarkShape(
        strokes: [[SIMD3(0.5, 0.112, 0.077), SIMD3(0.5, 0.26, 0.07), SIMD3(0.5, 0.398, 0.062)]],
        dots: [SIMD3(0.5, 0.61, 0.081)])

    static let ques: SandMarkShape = {
        let centre = SIMD2(0.5, 0.244), radius = 0.148, width = 0.07
        var line: [SIMD3<Double>] = stride(from: 200.0, through: 385.0, by: 7.5).map { degrees in
            let angle = degrees * .pi / 180
            return SIMD3(centre.x + radius * cos(angle), centre.y + radius * sin(angle), width)
        }
        // From the arc's lower right, a curve back to the middle and a short stem straight down.
        let start = SIMD2(line.last!.x, line.last!.y)
        let c1 = start + SIMD2(-0.033, 0.055), c2 = SIMD2(0.5, 0.35), end = SIMD2(0.5, 0.393)
        for i in 1...8 {
            let u = Double(i) / 8, v = 1 - u
            let p = start * (v * v * v) + c1 * (3 * v * v * u) + c2 * (3 * v * u * u) + end * (u * u * u)
            line.append(SIMD3(p.x, p.y, width))
        }
        line.append(SIMD3(0.5, 0.401, width))
        return SandMarkShape(strokes: [line], dots: [SIMD3(0.5, 0.61, 0.079)])
    }()

    /// Delegating's three clumps, side by side over the pile's top with room above them for their hops.
    static let helpers = SandMarkShape(strokes: [], dots: SandGlyph.helperXs.map { SIMD3($0, SandGlyph.helperY, SandGlyph.helperRadius) })

    /// Which of delegating's clumps (0 … 2, left to right) a grain at `x` belongs to.
    static func helperIndex(_ x: Double) -> Int {
        SandGlyph.helperXs.indices.min { abs(SandGlyph.helperXs[$0] - x) < abs(SandGlyph.helperXs[$1] - x) } ?? 0
    }

    static let check = SandMarkShape(
        strokes: [[SIMD3(0.159, 0.395, 0.075), SIMD3(0.39, 0.61, 0.075)], [SIMD3(0.39, 0.61, 0.075), SIMD3(0.852, 0.1, 0.075)]],
        dots: [])

    /// The mark as one filled outline in the unit square: each stroke's segments as tapered capsules (the hull of the
    /// circles at their two ends) and each dot, all wound one way (Liquid's helpers) so the overlaps fill as one.
    func outline() -> Path {
        var path = Path()
        func point(_ p: SIMD3<Double>) -> CGPoint { CGPoint(x: p.x, y: p.y) }
        for stroke in strokes where stroke.count > 1 {
            for i in 1..<stroke.count {
                LiquidGlyph.addTaper(&path, point(stroke[i - 1]), stroke[i - 1].z, point(stroke[i]), stroke[i].z)
            }
        }
        for dot in dots { LiquidGlyph.addCircle(&path, point(dot), dot.z) }
        return path
    }

    /// Signed distance from `p` to the mark: negative inside.
    func distance(_ p: SIMD2<Double>) -> Double {
        var best = Double.infinity
        for stroke in strokes {
            for i in 1..<stroke.count {
                let a = stroke[i - 1], b = stroke[i]
                let ab = SIMD2(b.x - a.x, b.y - a.y), ap = SIMD2(p.x - a.x, p.y - a.y)
                let t = min(1, max(0, simd_dot(ap, ab) / max(1e-12, simd_dot(ab, ab))))
                best = min(best, simd_length(ap - ab * t) - (a.z + (b.z - a.z) * t))
            }
        }
        for dot in dots { best = min(best, simd_length(p - SIMD2(dot.x, dot.y)) - dot.z) }
        return best
    }
}

/// A seeded integer hash (the prototype's), so grains are reproducible: renders match and a re-created view draws
/// the same sand.
enum SandHash {
    static func unit(_ a: Int, _ b: Int, _ c: Int) -> Double {
        let ua = UInt32(truncatingIfNeeded: a), ub = UInt32(truncatingIfNeeded: b), uc = UInt32(truncatingIfNeeded: c)
        var h = (ua &* 0x27d4_eb2d) ^ ((ub &+ 0x3c6e_f372) &* 0x1656_67b1) ^ ((uc &+ 0x61c8_8647) &* 0x9e37_79b1)
        h = (h ^ (h >> 15)) &* 0x85eb_ca6b
        h = (h ^ (h >> 13)) &* 0xc2b2_ae35
        h ^= h >> 16
        return Double(h) / 4_294_967_296
    }
}
