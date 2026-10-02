import QuartzCore
import SwiftUI

/// The island's one black surface as a value, in points: the closed pill, its swell, the opened island, a card, the idle
/// notch and the no-notch top bar are all this outline, hanging from the top edge. `left` and `right` are its reach
/// either side of the centre line (the notch's midX, or the screen's), ears included: the closed pill is not
/// symmetric about the notch (the lead's wing is wider than the count's), so its two edges move on their own.
struct SurfaceGeometry: Equatable, Sendable {
    var left: CGFloat
    var right: CGFloat
    var height: CGFloat
    /// The concave fillet outside each top corner.
    var ear: CGFloat
    /// The bottom corners.
    var radius: CGFloat
    /// A whisper of extra ear while the shoulders move fast (`IslandMotion.meniscus`; 0 unless enabled).
    var meniscus: CGFloat = 0

    static let zero = SurfaceGeometry(left: 0, right: 0, height: 0, ear: 0, radius: 0)

    init(left: CGFloat, right: CGFloat, height: CGFloat, ear: CGFloat, radius: CGFloat, meniscus: CGFloat = 0) {
        self.left = left
        self.right = right
        self.height = height
        self.ear = ear
        self.radius = radius
        self.meniscus = meniscus
    }

    /// Centred on the line: `width` wide.
    init(width: CGFloat, height: CGFloat, ear: CGFloat, radius: CGFloat) {
        self.init(left: width / 2, right: width / 2, height: height, ear: ear, radius: radius)
    }

    var width: CGFloat { left + right }
    var extent: IslandExtent { IslandExtent(left: left, right: right, height: height) }
}

/// A black surface hanging from the top edge: a body with rounded bottom corners and a concave "ear" outside each top
/// corner, so it flows out of the menu bar. It draws `geometry` from the top of whatever rect it is given, its centre
/// line on the rect's midX, and every value animates (both reaches, height, ear, radius, meniscus), so one shape morphs
/// from the pill to the island and back with no second surface. A height of 0 draws nothing (the no-notch sliver).
struct NotchSurfaceShape: Shape {
    var geometry: SurfaceGeometry
    /// The island's drawn surface, which Diagnostics › Motion › Record island motion watches (`SurfaceRenderTap`); never
    /// a hit-test shape or the pill's own.
    var recorded = false

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>> {
        get {
            AnimatablePair(AnimatablePair(geometry.left, geometry.right),
                           AnimatablePair(AnimatablePair(geometry.height, geometry.ear), AnimatablePair(geometry.radius, geometry.meniscus)))
        }
        set {
            geometry.left = newValue.first.first
            geometry.right = newValue.first.second
            geometry.height = newValue.second.first.first
            geometry.ear = newValue.second.first.second
            geometry.radius = newValue.second.second.first
            geometry.meniscus = newValue.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Off, this is one atomic load.
        if recorded { SurfaceRenderTap.record(geometry) }
        return Self.path(geometry, originX: rect.midX - geometry.left, top: rect.minY)
    }

    /// The outline with its left edge at `originX`. `continuous`: its bottom corners of continuous curvature (Motion:
    /// Refined, F9, `ContinuousCorner`), where the arc's curvature jumps from nothing to 1/r where it meets the wall.
    static func path(_ g: SurfaceGeometry, originX: CGFloat, top: CGFloat, continuous: Bool = false) -> Path {
        let (w, h) = (g.width, g.height)
        guard w > 0, h > 0 else { return Path() }
        let e = max(0, min(g.ear + g.meniscus, h, w / 4))
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: w, y: 0))
        if e > 0 { path.addArc(tangent1End: CGPoint(x: w - e, y: 0), tangent2End: CGPoint(x: w - e, y: e), radius: e) }
        if continuous {
            let r = ContinuousCorner.radius(g.radius, width: w, height: h, ear: e), k = ContinuousCorner.reach
            path.addLine(to: CGPoint(x: w - e, y: h - k * r))
            for c in ContinuousCorner.curves(corner: CGPoint(x: w - e, y: h), into: CGVector(dx: 0, dy: 1), out: CGVector(dx: -1, dy: 0), radius: r) {
                path.addCurve(to: c.to, control1: c.c1, control2: c.c2)
            }
            path.addLine(to: CGPoint(x: e + k * r, y: h))
            for c in ContinuousCorner.curves(corner: CGPoint(x: e, y: h), into: CGVector(dx: -1, dy: 0), out: CGVector(dx: 0, dy: -1), radius: r) {
                path.addCurve(to: c.to, control1: c.c1, control2: c.c2)
            }
        } else {
            let r = max(0, min(g.radius, (w - 2 * e) / 2, h / 2))
            path.addLine(to: CGPoint(x: w - e, y: h - r))
            path.addArc(tangent1End: CGPoint(x: w - e, y: h), tangent2End: CGPoint(x: w - e - r, y: h), radius: r)
            path.addLine(to: CGPoint(x: e + r, y: h))
            path.addArc(tangent1End: CGPoint(x: e, y: h), tangent2End: CGPoint(x: e, y: h - r), radius: r)
        }
        path.addLine(to: CGPoint(x: e, y: e))
        if e > 0 { path.addArc(tangent1End: CGPoint(x: e, y: 0), tangent2End: CGPoint(x: 0, y: 0), radius: e) }
        path.closeSubpath()
        return path.offsetBy(dx: originX, dy: top)
    }

    /// The shape filling `rect` exactly, with `ear` and `radius` (the standalone pill and island).
    static func filling(_ rect: CGRect, ear: CGFloat, radius: CGFloat) -> Path {
        path(SurfaceGeometry(width: rect.width, height: rect.height, ear: ear, radius: radius), originX: rect.minX, top: rect.minY)
    }
}

/// A bottom corner of continuous curvature (Motion: Refined, F9): Apple's, as the app's icon draws it (`IconBody`), three
/// cubics reaching `reach` radii along each edge, so the curvature grows from the wall's nothing instead of jumping to
/// 1/r where a circle's arc meets it. At the diagonal it passes 0.006 r outside the circle of the same radius, so the
/// corner reads as the same size, only softer into the walls.
enum ContinuousCorner {
    static let reach: CGFloat = 1.52866483

    /// `radius` as far as the outline has room for it: both corners' reach across the body, and the reach up the wall
    /// below the ear.
    static func radius(_ radius: CGFloat, width w: CGFloat, height h: CGFloat, ear e: CGFloat) -> CGFloat {
        max(0, min(radius, (w - 2 * e) / (2 * reach), (h - e) / reach))
    }

    struct Curve { var c1: CGPoint; var c2: CGPoint; var to: CGPoint }

    /// The three cubics from `reach` radii before `corner` along `into` (the edge coming into it) to `reach` radii along
    /// `out` (the edge leaving it).
    static func curves(corner: CGPoint, into: CGVector, out: CGVector, radius r: CGFloat) -> [Curve] {
        func p(_ t: CGFloat, _ n: CGFloat) -> CGPoint {
            CGPoint(x: corner.x - t * r * into.dx + n * r * out.dx, y: corner.y - t * r * into.dy + n * r * out.dy)
        }
        return [Curve(c1: p(1.08849323, 0), c2: p(0.86840689, 0), to: p(0.66993427, 0.06549600)),
                Curve(c1: p(0.37260046, 0.17941168), c2: p(0.17941097, 0.37260121), to: p(0.06549569, 0.66993493)),
                Curve(c1: p(0, 0.86840689), c2: p(0, 1.08849323), to: p(0, reach))]
    }
}

/// SwiftUI's outline as the clip of the island's canvas (whose background is the black): one path a frame, the surface as
/// two animatable vectors, so each keeps the curve that moved it last: the width (both reaches and the ear, which
/// follows the shoulders) is this modifier's, the height (the height and the bottom corners) the shape's own
/// (`SurfaceHeightShape`). Motion: Refined's open moves them on two springs (F5, `MotionTuning.splitsSurface`); with one
/// curve for both, as Original's, they move as the one vector did. While the width moves, this small body runs each
/// frame (the height's does not). In the live island each vector's curve is scoped to its own effect (E5): the width's
/// around this modifier and the height's (`height`) around the shape (`IslandSurfaceClip`, from the surface's box). With
/// Core Animation's outline it clips nothing (`clips` false; the render server masks the canvas) and reads no surface.
nonisolated struct SurfaceClip: ViewModifier, Animatable, LiquidClipping {
    var geometry: SurfaceGeometry
    var clips = true
    /// Continuous bottom corners (Motion: Refined, F9).
    var continuous = false
    /// The curve the height moves on, scoped to the shape alone (nil: none, as with Core Animation's outline).
    var height: Animation? = nil
    var probe: OutlineProbe? = nil
    /// Motion: Liquid: the union's liquid parts this frame (`LiquidPath`); nil or at rest, today's outline.
    var liquid: LiquidParams? = nil

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(geometry.left, geometry.right), geometry.ear) }
        set {
            geometry.left = newValue.first.first
            geometry.right = newValue.first.second
            geometry.ear = newValue.second
        }
    }

    func body(content: Content) -> some View {
        probe?.clip()
        let shape = SurfaceHeightShape(geometry: geometry, clips: clips, continuous: continuous, probe: probe, liquid: liquid)
        return content.animation(height) { $0.clipShape(shape) }
    }
}

/// The island's drawn outline with its height and bottom corners animatable, its width set by `SurfaceClip` each frame.
/// Diagnostics › Motion › Record island motion watches it (`SurfaceRenderTap`). Not clipping, the whole rect.
struct SurfaceHeightShape: Shape {
    var geometry: SurfaceGeometry
    var clips = true
    var continuous = false
    var probe: OutlineProbe? = nil
    /// Motion: Liquid (`SurfaceClip.liquid`).
    var liquid: LiquidParams? = nil

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(geometry.height, AnimatablePair(geometry.radius, geometry.meniscus)) }
        set {
            geometry.height = newValue.first
            geometry.radius = newValue.second.first
            geometry.meniscus = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard clips else { return Path(rect) }
        let union = liquid.map { !$0.isRest } ?? false
        probe?.path(geometry, liquid: union)
        // Off, this is one atomic load.
        SurfaceRenderTap.record(geometry)
        if union, let liquid { return LiquidPath.path(geometry, liquid, in: rect) }
        return NotchSurfaceShape.path(geometry, originX: rect.midX - geometry.left, top: rect.minY, continuous: continuous)
    }
}

/// A test's view of its own island's outline work: each outline SwiftUI built (when, in media time, and what), and the
/// shoulder-gate and width bodies it ran, for the tests that hold Core Animation's outline to none. Set on one island's
/// root (`\.outlineProbe`), it counts that island only, so suites running at once never count each other's (a global
/// counter, or the motion recorder's tap, would). The app sets none: nothing is counted.
final class OutlineProbe: @unchecked Sendable {
    struct Path { var time: TimeInterval; var geometry: SurfaceGeometry; var liquid = false }
    private let lock = NSLock()
    private var built: [Path] = []
    private var gates = 0
    private var clips = 0

    init() {}

    /// An outline built: `liquid`, Motion: Liquid's union drawing more than the body.
    func path(_ geometry: SurfaceGeometry, liquid: Bool = false) {
        let time = CACurrentMediaTime()
        lock.withLock { built.append(Path(time: time, geometry: geometry, liquid: liquid)) }
    }

    func gate() { lock.withLock { gates += 1 } }
    func clip() { lock.withLock { clips += 1 } }

    var paths: [Path] { lock.withLock { built } }
    /// Outlines built, gate bodies and width bodies so far.
    var count: (paths: Int, gates: Int, clips: Int) { lock.withLock { (built.count, gates, clips) } }
}

extension EnvironmentValues {
    @Entry var outlineProbe: OutlineProbe? = nil
}

/// The closed pill: bottom radius 12.5 and 3 pt ears (the no-notch top bar: radius half its height, no ears).
struct PillShape: Shape {
    var topBar = false
    func path(in rect: CGRect) -> Path {
        NotchSurfaceShape.filling(rect, ear: topBar ? 0 : IslandTheme.Metrics.pillEar,
                                  radius: topBar ? rect.height / 2 : IslandTheme.Metrics.pillRadius)
    }
}

/// The opened island: bottom radius 20 and 8 pt shoulders.
struct IslandShape: Shape {
    func path(in rect: CGRect) -> Path {
        NotchSurfaceShape.filling(rect, ear: IslandTheme.Metrics.shoulder, radius: IslandTheme.Metrics.bottomRadius)
    }
}

/// Everything but the notch, for an even-odd clip: the pill's glyph and count slide out from behind the notch clipped
/// by it, so nothing of them is ever drawn over the hardware (P37). The notch starts `notchMinX` into the rect, at its
/// top; everything else, well past the rect's edges too, stays.
struct NotchCut: Shape {
    var notchMinX: CGFloat
    var notch: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -64, dy: -64))
        path.addRect(CGRect(x: rect.minX + notchMinX, y: rect.minY, width: notch.width, height: notch.height))
        return path
    }
}
