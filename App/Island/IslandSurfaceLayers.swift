import AppKit
import Observation
import QuartzCore
import SwiftUI

// Diagnostics › Motion › Outline: Core Animation. The island's black outline and the clip that reveals its content are
// drawn by the render server, from the choreography model's own plan (`IslandChoreography.surfacePlan`): after every
// event the model's future for the surface, its pending jobs included, is handed over as one keyframe animation of the
// outline, 240 samples a second, and the render server plays it on its own clock. Nothing about the outline then runs on
// the app's main thread until the next event: no path a frame, no animation step, no commit. A busy main thread (a
// card's build, a stall) no longer holds the edge, and the model's leads and lags land on time. The content stays
// SwiftUI's; it is masked by the same outline, so nothing it draws ever shows beyond the black.
//
// It fails closed (P240): the black is a shape layer of its own, in a layer-hosting view whose layer the app owns, so a
// lost or replaced mask can never turn the canvas's rectangle black; the content's view is born masked (its backing
// layer carries the clip and keeps it), and after every snap and display change the canvas checks the layers are
// where they belong, puts back what is not, and falls back to SwiftUI's outline if it cannot.

/// The outline's layers and the plan they play: the black (`fill`), the content's mask (`clip`) and the edge line's
/// carrier (`rim`), each on the same keyframes.
@MainActor
final class IslandSurfaceLayers {
    /// Keyframe spacing: linear interpolation between samples 1/240 s apart stays within 0.12 pt of the springs at the
    /// choreography's hardest acceleration (the motion research's proto-ca §2.1; 1/120 s: 0.44 pt).
    static let step: TimeInterval = 1.0 / 240
    /// The animations' key on each layer.
    static let key = "outline"

    /// The black, under the content (`IslandSurfaceView`).
    let fill = CAShapeLayer()
    /// The same outline as the content's mask (`IslandMaskedView`).
    let clip = CAShapeLayer()
    /// The edge line's carrier (`IslandRimCarrier`'s layer): its sublayers move down by the plan's lift.
    weak var rim: CALayer?
    /// Solid's notch plate cut out of the edge line (`IslandRimCarrier.cut`, the carrier's mask on Solid). Core Animation
    /// moves a layer's mask with its sublayers, so the cut takes the lift back on the same keyframes and stays where the
    /// notch is (P797).
    weak var rimCut: CALayer?
    /// Theme Glass: the glass that takes the black's place (`IslandCanvas.glassView`), its path layers on the same
    /// keyframes (its layers are y up, the canvas's top at their bounds' top).
    weak var glass: GlassSurfaceNSView?
    /// Black with State tint: the tint's edge over the black (`IslandCanvas.edgeLayers`), its outline layers on the same
    /// keyframes as the fill, in the fill's orientation (`attach`).
    private(set) var edge: IslandStateEdgeLayers?
    /// The canvas: the surface hangs from its top, centred on its midX.
    private(set) var canvas: CGSize
    /// The plan now playing, and what each play cost.
    private(set) var plan: IslandChoreography.SurfacePlan?
    private(set) var plays = 0
    private(set) var skipped = 0
    private(set) var checks = 0
    private(set) var mismatches = 0
    /// Plans handed over; a sweep for an older one does nothing.
    private var sweeps = 0
    /// Main-thread CPU (ms) of the last play: the plan, and the paths and animations.
    private(set) var lastPlayCPU: (plan: Double, install: Double) = (0, 0)
    /// Each plan as it is handed over, with when (uptime): measurements and tests. nil costs nothing.
    var onInstall: ((IslandChoreography.SurfacePlan, TimeInterval) -> Void)?

    init(canvas: CGSize) {
        self.canvas = canvas
        for layer in [fill, clip] {
            layer.fillColor = CGColor(gray: 0, alpha: 1)
            layer.actions = Self.still
            layer.frame = CGRect(origin: .zero, size: canvas)
        }
        fill.name = "island.outline.fill"
        clip.name = "island.outline.clip"
    }

    /// No implicit animation for anything the app sets on a layer.
    static let still: [String: any CAAction] = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
                                                "contentsScale": NSNull(), "sublayerTransform": NSNull(), "hidden": NSNull()]

    func resize(_ size: CGSize) {
        guard size != canvas else { return }
        canvas = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [fill, clip] { layer.frame = CGRect(origin: .zero, size: size) }
        edge?.layout(canvas: size, yDown: Self.yDown(fill))
        CATransaction.commit()
    }

    /// The model changed at `t` (an event, a reset): the render server plays its plan for the surface from `t`. A plan
    /// the one playing already holds (an event that moves no part of the surface) is left playing.
    func play(_ model: IslandChoreography, at t: TimeInterval) {
        let start = Self.cpu()
        let plan = model.surfacePlan(from: t, step: Self.step)
        let planned = Self.cpu()
        plays += 1
        if let old = self.plan, Self.holds(old, plan) {
            skipped += 1
            lastPlayCPU = (Double(planned - start) / 1e6, 0)
            return
        }
        install(plan)
        lastPlayCPU = (Double(planned - start) / 1e6, Double(Self.cpu() - planned) / 1e6)
    }

    /// Whether `old`, playing, already draws `new` at every one of its samples (and rests where it does: past its end
    /// `old` draws its last sample), to within what drawing between its own samples already allows (`tolerance`).
    static func holds(_ old: IslandChoreography.SurfacePlan, _ new: IslandChoreography.SurfacePlan) -> Bool {
        guard old.continuous == new.continuous, distance(old.last, new.last) < 0.001,
              abs((old.rim.last ?? 0) - (new.rim.last ?? 0)) < 0.001 else { return false }
        // Motion: Liquid: the liquid values and the reservoir too (a card's bud leaves the body where it is).
        guard (old.liquid == nil) == (new.liquid == nil), old.drawsLiquid == new.drawsLiquid else { return false }
        if let a = old.liquid?.last, let b = new.liquid?.last, LiquidParams.distance(a, b) > 0.001 { return false }
        for (i, g) in new.surface.enumerated() {
            let s = new.start + Double(i) * new.step
            if distance(old.geometry(at: s), g) > tolerance || abs(old.rim(at: s) - new.rim[i]) > tolerance { return false }
            if let p = new.liquid?[i], let q = old.liquid(at: s), LiquidParams.distance(p, q) > tolerance { return false }
        }
        return true
    }

    /// How far linear interpolation between samples `step` apart strays from the springs at most (0.15 pt measured on
    /// every scenario; `CoreAnimationOutlineTests.thePlanIsTheModel`).
    static let tolerance: CGFloat = 0.2

    static func distance(_ a: SurfaceGeometry, _ b: SurfaceGeometry) -> CGFloat {
        max(abs(a.left - b.left), abs(a.right - b.right), abs(a.height - b.height), abs(a.ear - b.ear), abs(a.radius - b.radius))
    }

    /// Hands `plan` to the layers: each takes its last sample as its own value (what it rests on once the animation has
    /// ended and gone, so nothing ticks at rest) and, while it moves, one keyframe animation from the plan's start in the
    /// model's time, asking the display for 80 to 120 frames a second while it plays.
    func install(_ plan: IslandChoreography.SurfacePlan) {
        self.plan = plan
        onInstall?(plan, ProcessInfo.processInfo.systemUptime)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Every layer's animation starts at one media time, read once (each layer converting its own left the fill and
        // the mask a few microseconds apart).
        let begin = Self.mediaTime(plan.start)
        let paths = self.paths(plan)
        // Motion: Liquid's keyframes where the union moves along curves faster than a sample's line follows
        // (`liquidKeyframes`): the fill, the mask, the glass and the tint's edge share them.
        let times = paths.times.map { $0.map { NSNumber(value: $0 / Double(max(1, plan.surface.count - 1))) } }
        // Motion: Liquid's plan that comes to rest with nothing of its own rests on today's outline itself (its last
        // keyframe draws the same within 0.05 pt, `LiquidPathTests.theRestIsTodaysPath`).
        let today = plan.drawsLiquid && (plan.liquid?.last?.isRest ?? true)
        // Black's tint edge takes the fill's own paths, in the fill's orientation.
        let fillDown = Self.yDown(fill)
        for (layer, paths, down) in [(fill, paths.fill, fillDown), (clip, paths.clip, Self.yDown(clip))]
            + (edge?.pathLayers.map { ($0, paths.fill, fillDown) } ?? []) {
            layer.removeAnimation(forKey: Self.key)
            layer.path = today ? path(plan.last, yDown: down, continuous: plan.continuous) : paths.last
            guard paths.count > 1 else { continue }
            layer.add(animation(keyPath: "path", values: paths, plan: plan, on: layer, begin: begin, times: times), forKey: Self.key)
        }
        if let glass {
            install(plan, paths: paths.glass, on: glass, begin: begin, times: times,
                    rest: today ? path(plan.last, yDown: false, continuous: plan.continuous) : nil)
        }
        if let rim {
            let lift = plan.rim.last ?? 0
            rim.removeAnimation(forKey: Self.key)
            rim.sublayerTransform = CATransform3DMakeTranslation(0, lift, 0)
            rimCut?.removeAnimation(forKey: Self.key)
            rimCut?.transform = CATransform3DMakeTranslation(0, -lift, 0)
            if plan.rim.count > 1, plan.rim.contains(where: { abs($0 - lift) > 0.001 }) {
                rim.add(animation(keyPath: "sublayerTransform.translation.y", values: plan.rim.map { NSNumber(value: Double($0)) },
                                  plan: plan, on: rim, begin: begin), forKey: Self.key)
                rimCut?.add(animation(keyPath: "transform.translation.y", values: plan.rim.map { NSNumber(value: -Double($0)) },
                                      plan: plan, on: rim, begin: begin), forKey: Self.key)
            }
        }
        CATransaction.commit()
        sweep(after: plan)
    }

    /// The plan's outline at every sample, for the fill, the clip and the glass's path layers (y up). Motion: Liquid's
    /// union of the body and its liquid parts (`LiquidPath`, always the same elements, so the keyframes interpolate):
    /// one pass writes the y-down path the fill and the clip share and the glass's y-up one from the same points. A plan
    /// that draws nothing but the body keeps today's outline exactly.
    private func paths(_ plan: IslandChoreography.SurfacePlan) -> (fill: [CGPath], clip: [CGPath], glass: [CGPath], times: [Double]?) {
        let fillDown = Self.yDown(fill), clipDown = Self.yDown(clip)
        if let liquid = plan.liquid, liquid.count == plan.surface.count, plan.drawsLiquid {
            // Each keyframe's union once, y down; the y-up copy flips it (as `LiquidPath.cgPaths`).
            let (keys, down) = plan.liquidKeyframes(centreX: canvas.width / 2)
            var up: [CGPath] = []
            if glass != nil || !fillDown || !clipDown {
                up.reserveCapacity(keys.count)
                var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvas.height)
                for (key, path) in zip(keys, down) {
                    up.append(path.copy(using: &flip) ?? LiquidPath.cgPath(key.body, key.params, centreX: canvas.width / 2, flipHeight: canvas.height))
                }
            }
            let times = keys.count == plan.surface.count ? nil : keys.map(\.index)
            return (fillDown ? down : up, clipDown ? down : up, up, times)
        }
        let fillPaths = plan.surface.map { path($0, yDown: fillDown, continuous: plan.continuous) }
        let clipPaths = clipDown == fillDown ? fillPaths : plan.surface.map { path($0, yDown: clipDown, continuous: plan.continuous) }
        let glassPaths = glass == nil ? [] : plan.surface.map { path($0, yDown: false, continuous: plan.continuous) }
        return (fillPaths, clipPaths, glassPaths, nil)
    }

    /// The tint's edge in (`edge` nil: out): its outline layers take the plan now playing, the fill's own paths where the
    /// fill is (its motion from where it is, if the plan still runs, Motion: Liquid's union and keyframes included; at
    /// rest, only its last outline, since an animation that has ended would stay on its layers, P241).
    func attach(_ edge: IslandStateEdgeLayers?) {
        self.edge = edge
        guard let edge else { return }
        let down = Self.yDown(fill)
        edge.layout(canvas: canvas, yDown: down)
        guard let plan else { return edge.setPath(nil) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let running = CACurrentMediaTime() < Self.mediaTime(plan.end)
        let today = plan.drawsLiquid && (plan.liquid?.last?.isRest ?? true)
        let liquid = plan.drawsLiquid && !today
        // At rest: the fill's own rest (a card's bud stays out on the union; a Liquid plan come to rest is today's).
        let played = running || liquid ? self.paths(plan) : nil
        let paths = running ? played?.fill ?? [] : [played?.fill.last ?? path(plan.last, yDown: down, continuous: plan.continuous)]
        let times = running ? played?.times.map { $0.map { NSNumber(value: $0 / Double(max(1, plan.surface.count - 1))) } } : nil
        for layer in edge.pathLayers {
            layer.removeAnimation(forKey: Self.key)
            layer.path = today ? path(plan.last, yDown: down, continuous: plan.continuous) : paths.last
            guard paths.count > 1 else { continue }
            layer.add(animation(keyPath: "path", values: paths, plan: plan, on: layer, begin: Self.mediaTime(plan.start), times: times),
                      forKey: Self.key)
        }
        CATransaction.commit()
    }

    /// The plan on the glass's path layers (its mask, floor and rim), y up.
    private func install(_ plan: IslandChoreography.SurfacePlan, paths: [CGPath], on glass: GlassSurfaceNSView, begin: CFTimeInterval,
                         times: [NSNumber]?, rest: CGPath? = nil) {
        glass.removePathAnimations(forKey: Self.key)
        glass.setPath(rest ?? paths.last)
        guard paths.count > 1 else { return }
        glass.addPathAnimation(animation(keyPath: "path", values: paths, plan: plan, on: glass.floorLayer, begin: begin, times: times),
                               forKey: Self.key)
    }

    /// Core Animation takes an ended animation off its layer only at the next commit, and at rest there is none: the
    /// plan's animations would stay on the layers for good (P241). One wake as the plan ends takes them off (the layers
    /// already rest on the last sample, so nothing moves); a plan replaced before then cancels it. One wake a motion,
    /// never a tick.
    private func sweep(after plan: IslandChoreography.SurfacePlan) {
        sweeps += 1
        let id = sweeps
        guard plan.surface.count > 1 || plan.rim.count > 1 else { return }
        let delay = max(0, Self.mediaTime(plan.end) - CACurrentMediaTime()) + 0.02
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.sweep(id) }
        }
    }

    private func sweep(_ id: Int) {
        guard id == sweeps else { return }
        var playing = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [fill, clip, rim, rimCut].compactMap(\.self) + (glass?.pathLayers ?? []) + (edge?.pathLayers ?? []) {
            guard let animation = layer.animation(forKey: Self.key) else { continue }
            if layer.convertTime(CACurrentMediaTime(), from: nil) >= animation.beginTime + animation.duration {
                layer.removeAnimation(forKey: Self.key)
            } else {
                playing = true
            }
        }
        CATransaction.commit()
        guard playing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.sweep(id) }
        }
    }

    private func animation(keyPath: String, values: [Any], plan: IslandChoreography.SurfacePlan, on layer: CALayer,
                           begin: CFTimeInterval, times: [NSNumber]? = nil) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.calculationMode = .linear
        // Keyframes at the plan's samples, evenly; or, with Motion: Liquid's extra ones, each at its own time.
        if let times, times.count == values.count { animation.keyTimes = times }
        let intervals = times != nil && times?.count == values.count ? max(1, plan.surface.count - 1) : values.count - 1
        animation.duration = Double(intervals) * plan.step * IslandMotion.slowdown
        // The model's clock is the system uptime (`IslandMotionDirector.now`), the clock of CA's media time: the plan
        // starts where the model's event did, whenever this turn's commit reaches the render server.
        animation.beginTime = layer.convertTime(begin, from: nil)
        animation.fillMode = .both
        animation.preferredFrameRateRange = IslandFramePacing.motion
        return animation
    }

    /// After a job ran on the director's timer: the model must still be on the plan (it ran the same jobs ahead). A
    /// difference (a job that moves the surface without saying so, `Step.movesSurface`) plays the model again.
    func check(_ model: IslandChoreography, at t: TimeInterval) {
        checks += 1
        guard let plan else { return play(model, at: t) }
        var worst: CGFloat = 0
        // At the plan's own samples, where it is the model exactly (between them it is the springs to 0.2 pt), and only
        // before the model's next step that moves the surface, which its springs do not know of yet.
        let now = Int(((t - plan.start) / plan.step).rounded(.up))
        let next = model.jobs.filter(\.step.movesSurface).map(\.time).min() ?? .infinity
        for ahead in [0, 12, 48, 120] {
            let i = min(max(0, now + ahead), plan.surface.count - 1)
            let s = max(t, plan.start + Double(i) * plan.step)
            guard ahead == 0 || s < next - 1e-9 else { break }
            let g = i == plan.surface.count - 1 && s > plan.start + Double(i) * plan.step ? plan.last : plan.surface[i]
            worst = max(worst, Self.distance(model.surface(at: s), g), abs(CGFloat(model.value(.rimLift, at: s)) - plan.rim[i]))
            // Motion: Liquid: its values and the reservoir too.
            if (plan.liquid == nil) != !model.tuning.liquid { worst = .infinity }
            if let liquid = plan.liquid { worst = max(worst, LiquidParams.distance(model.liquid(at: s), liquid[i])) }
        }
        guard worst > 0.01 else { return }
        mismatches += 1
        self.plan = nil
        play(model, at: t)
    }

    /// Model time → CA media time (the same mach clock; `slowdown` stretches the model's).
    static func mediaTime(_ t: TimeInterval) -> CFTimeInterval {
        t * IslandMotion.slowdown + (CACurrentMediaTime() - ProcessInfo.processInfo.systemUptime)
    }

    /// Whether `layer`'s own y grows downward: a flipped view's layer (in the window's unflipped content view) is.
    static func yDown(_ layer: CALayer) -> Bool {
        let host = layer.superlayer
        return host?.isGeometryFlipped ?? true
    }

    /// The outline in the canvas's layer space, as `NotchSurfaceShape` draws it: with the playing plan's corners unless
    /// `continuous` says.
    func path(_ g: SurfaceGeometry, yDown: Bool = true, continuous: Bool? = nil) -> CGPath {
        Self.fixedPath(g, originX: canvas.width / 2 - g.left, top: 0, flipHeight: yDown ? nil : canvas.height,
                       continuous: continuous ?? plan?.continuous ?? false)
    }

    /// The outline with always the same elements (a move, four lines, four cubic quarter-arcs and a close; with
    /// `continuous` corners three cubics for each bottom corner, F9), so Core Animation can interpolate between any two of
    /// one plan (`CAShapeLayer.path` animates only between paths of the same elements), ears and corners of 0 included,
    /// where `NotchSurfaceShape` leaves an ear of 0 out (idle ⇄ pill). The arcs are the circles `NotchSurfaceShape`
    /// draws, to a quarter of a pixel; the continuous corners its very cubics.
    nonisolated static func fixedPath(_ g: SurfaceGeometry, originX: CGFloat, top: CGFloat, flipHeight: CGFloat?,
                                      continuous: Bool = false) -> CGPath {
        let w = max(0, g.width), h = max(0, g.height)
        let e = max(0, min(g.ear + g.meniscus, h, w / 4))
        let k: CGFloat = 0.5522847498
        var transform = CGAffineTransform(translationX: originX, y: top)
        if let flipHeight { transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: originX, ty: flipHeight - top) }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0), transform: transform)
        path.addLine(to: CGPoint(x: w, y: 0), transform: transform)
        path.addCurve(to: CGPoint(x: w - e, y: e), control1: CGPoint(x: w - k * e, y: 0), control2: CGPoint(x: w - e, y: e - k * e),
                      transform: transform)
        if continuous {
            let r = ContinuousCorner.radius(g.radius, width: w, height: h, ear: e), reach = ContinuousCorner.reach
            path.addLine(to: CGPoint(x: w - e, y: h - reach * r), transform: transform)
            for c in ContinuousCorner.curves(corner: CGPoint(x: w - e, y: h), into: CGVector(dx: 0, dy: 1), out: CGVector(dx: -1, dy: 0), radius: r) {
                path.addCurve(to: c.to, control1: c.c1, control2: c.c2, transform: transform)
            }
            path.addLine(to: CGPoint(x: e + reach * r, y: h), transform: transform)
            for c in ContinuousCorner.curves(corner: CGPoint(x: e, y: h), into: CGVector(dx: -1, dy: 0), out: CGVector(dx: 0, dy: -1), radius: r) {
                path.addCurve(to: c.to, control1: c.c1, control2: c.c2, transform: transform)
            }
        } else {
            let r = max(0, min(g.radius, (w - 2 * e) / 2, h / 2))
            path.addLine(to: CGPoint(x: w - e, y: h - r), transform: transform)
            path.addCurve(to: CGPoint(x: w - e - r, y: h), control1: CGPoint(x: w - e, y: h - r + k * r),
                          control2: CGPoint(x: w - e - r + k * r, y: h), transform: transform)
            path.addLine(to: CGPoint(x: e + r, y: h), transform: transform)
            path.addCurve(to: CGPoint(x: e, y: h - r), control1: CGPoint(x: e + r - k * r, y: h), control2: CGPoint(x: e, y: h - r + k * r),
                          transform: transform)
        }
        path.addLine(to: CGPoint(x: e, y: e), transform: transform)
        path.addCurve(to: CGPoint(x: 0, y: 0), control1: CGPoint(x: e, y: e - k * e), control2: CGPoint(x: k * e, y: 0), transform: transform)
        path.closeSubpath()
        return path
    }

    private static func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
}

/// Core Animation's outline: the island's black, a layer-hosting view whose one layer the app owns (never an AppKit
/// backing layer, which AppKit may drop and build again), holding the black as a shape layer of its own, so whatever
/// becomes of the mask over the content the black is the outline and nothing else (P240). It takes no click.
final class IslandSurfaceView: NSView {
    let root = CALayer()
    /// Its display or scale changed: the canvas checks its layers.
    var changed: () -> Void = {}

    init(frame: CGRect, fill: CALayer) {
        super.init(frame: frame)
        root.name = "island.outline.surface"
        root.actions = IslandSurfaceLayers.still
        root.addSublayer(fill)
        // Layer-hosting: the layer is set before `wantsLayer`, so AppKit never makes one of its own.
        layer = root
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        changed()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        changed()
    }
}

/// The content's backing layer: born with the outline as its mask, and it keeps it (a mask set to anything else, or to
/// nil, stays the outline). A presentation copy takes what Core Animation gives it.
final class IslandMaskedLayer: CALayer {
    let clip: CALayer
    private let locked: Bool

    init(clip: CALayer) {
        self.clip = clip
        locked = true
        super.init()
        super.mask = clip
    }

    override init(layer: Any) {
        clip = (layer as? IslandMaskedLayer)?.clip ?? CALayer()
        locked = false
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mask: CALayer? {
        get { super.mask }
        set { super.mask = locked ? clip : newValue }
    }
}

/// Core Animation's outline: the view the content (the hosting view, and the edge line's carrier) sits in, masked by the
/// outline: whatever backing layer AppKit gives it is an `IslandMaskedLayer`, masked from its first moment.
final class IslandMaskedView: NSView {
    let clip: CALayer
    var changed: () -> Void = {}

    init(frame: CGRect, clip: CALayer) {
        self.clip = clip
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func makeBackingLayer() -> CALayer { IslandMaskedLayer(clip: clip) }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        changed()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        changed()
    }
}

/// Core Animation's outline: the pill's edge line (`IslandRimView`) rides the plan: this view's layer moves its sublayers
/// down by the plan's lift (`sublayerTransform`), the line's own hosting view laid out at the canvas's top. On Solid its
/// layer's mask is `cut`, the notch plate cut out of the line, kept where the notch is as the line rides (P797). It takes
/// no click.
final class IslandRimCarrier: NSView {
    let cut: CAShapeLayer = {
        let cut = CAShapeLayer()
        cut.name = "island.rim.plateCut"
        cut.fillColor = CGColor(gray: 0, alpha: 1)
        cut.fillRule = .evenOdd
        cut.actions = IslandSurfaceLayers.still
        return cut
    }()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The edge line's own canvas (`IslandRimView`): no click lands on it.
final class IslandRimHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The island's canvas in its panel, drawn with the outline Diagnostics › Motion › Outline asks for. SwiftUI's: the
/// hosting view alone, which fills and clips the surface itself. Core Animation's: under it the black
/// (`IslandSurfaceView`), and the hosting view inside the masked view (`IslandMaskedView`) with the edge line's carrier
/// over it. A snap moves the canvas's views together; after every snap and display change the layers are checked and put
/// back where they belong, and if they cannot be, the canvas falls back to SwiftUI's outline (`fellBack`), so the black
/// never shows beyond the island and the content never shows unmasked.
@MainActor
final class IslandCanvas {
    let ui: IslandUIState
    let hosting: NSHostingView<AnyView>
    let layers: IslandSurfaceLayers
    private weak var container: NSView?
    private(set) var outline = IslandOutline.swiftUI
    private(set) var surfaceView: IslandSurfaceView?
    private(set) var maskedView: IslandMaskedView?
    private(set) var rimCarrier: IslandRimCarrier?
    private(set) var rimHost: IslandRimHostingView?
    /// Settings › Island › Theme, as the canvas draws it (`setTheme`).
    private(set) var theme = JuiceTheme.black
    /// Theme Glass on Core Animation's outline: the glass in the black's place, between the black's view (clear then)
    /// and the content, masked by the outline's plan (`IslandSurfaceLayers.glass`), the notch plate among its marks.
    private(set) var glassView: GlassSurfaceNSView?
    /// Settings › Island › State tint, as the canvas draws it (`setStateTint`): Black's edge on Core Animation's outline.
    private(set) var stateTint = false
    /// Settings › Island › Needs you colour, which that edge shows while something needs you (`setNeedsYou`).
    private(set) var needsYou = NeedsYouColour.pink
    /// Black with State tint on Core Animation's outline: the tint's edge over the black, in the black's own view, on the
    /// plan (`IslandSurfaceLayers.edge`), showing the lead state's colour (`StateTint`).
    private(set) var edgeLayers: IslandStateEdgeLayers?
    /// The notch the canvas hangs from (nil: the top bar), for the glass's notch plate.
    private var notch: CGSize?
    private var rimRoot = AnyView(EmptyView())
    private var size: CGSize
    private var origin = CGPoint.zero
    /// Core Animation's layers could not be put back: the canvas has gone back to SwiftUI's outline.
    var fellBack: () -> Void = {}
    /// Times a check found something out of place and put it back.
    private(set) var repairs = 0

    init(ui: IslandUIState, hosting: NSHostingView<AnyView>, container: NSView, size: CGSize = .zero) {
        self.ui = ui
        self.hosting = hosting
        self.container = container
        self.size = size
        layers = IslandSurfaceLayers(canvas: size)
        hosting.frame = CGRect(origin: .zero, size: size)
        container.addSubview(hosting)
        observeGlassScheme()
        observeLead()
    }

    /// The tint's edge follows the pill's lead (`StateTint(lead:)`), which the director writes into `ui.pill`.
    private func observeLead() {
        withObservationTracking {
            _ = ui.pill
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.edgeLayers?.show(StateTint(lead: self.ui.pill.lead))
                self.observeLead()
            }
        }
    }

    /// Glass's rim is drawn outside the glass, over the content: it takes the look the glass hands the content
    /// (`IslandUIState.glassScheme`), as the edge line does, never the window's appearance (P568).
    private func observeGlassScheme() {
        withObservationTracking {
            _ = ui.glassScheme
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.paintRimLook()
                self.observeGlassScheme()
            }
        }
    }

    /// Glass's rim in the glass's look: its view's appearance from the content's scheme (nil, the window's, until the
    /// glass has said), which its light follows (`GlassSurfaceNSView.paintRim`). Smoke's glass keeps its own dark one.
    private func paintRimLook() {
        guard let glassView, glassView.backdrop == GlassSurfaceNSView.Backdrop.rimOnly else { return }
        let appearance = ui.glassScheme.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
        if glassView.appearance?.name != appearance?.name { glassView.appearance = appearance }
    }

    /// The views the canvas's views were last placed at, inside the panel (the hosting view's origin with SwiftUI's).
    var placed: CGPoint { origin }

    /// The edge line's root, for Core Animation's outline (the main root is the hosting view's own).
    func setRimRoot(_ root: AnyView) {
        rimRoot = root
        rimHost?.rootView = root
    }

    /// Draws Black's pure black, Smoke (`glassView`: the glass, floor and plate), Glass (`glassView`: the rim over the
    /// content's own glass) or Solid (`glassView`: the window material and its hairline; its plate is the content's) from
    /// now on; with SwiftUI's outline the root view draws the theme itself (`IslandSurfaceBackground`,
    /// `IslandGlassContent`). Mid-motion the glass takes the plan where it is.
    func setTheme(_ new: JuiceTheme) {
        guard new != theme else { return }
        theme = new
        syncGlass()
        syncEdge()
        placeRimCut()
    }

    /// Settings › Island › State tint from now on: Black's edge on Core Animation's outline in or out (the views draw the
    /// rest, `IslandSurfaceBackground`, `IslandGlassContent`).
    func setStateTint(_ on: Bool) {
        guard on != stateTint else { return }
        stateTint = on
        syncEdge()
    }

    /// Settings › Island › Needs you colour from now on, for Black's edge on Core Animation's outline (the views read
    /// `\.needsYouColour`).
    func setNeedsYou(_ new: NeedsYouColour) {
        needsYou = new
        edgeLayers?.setNeedsYou(new)
    }

    /// Glass's rim's light at `spot` (nil: none), on Core Animation's outline; SwiftUI's reads `IslandUIState.rimLight`.
    func setRimLight(_ spot: IslandRimLight.Spot?) {
        guard let glassView, glassView.backdrop == GlassSurfaceNSView.Backdrop.rimOnly else { return }
        glassView.setRimLight(spot, reduceMotion: ui.reduceMotion)
    }

    /// Whether Black's tint edge belongs in the canvas: State tint on, Black, Core Animation's outline.
    private var wantsEdge: Bool { stateTint && theme == .black && outline == .coreAnimation && surfaceView != nil }

    /// The tint's edge in or out as State tint, the theme and the outline ask: in, over the black's fill in its own view,
    /// on the plan where it is, showing the lead's tint at once; out, with nothing left of it.
    private func syncEdge() {
        guard wantsEdge != (edgeLayers != nil) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if edgeLayers != nil { return removeEdge() }
        guard let surfaceView else { return }
        let edge = IslandStateEdgeLayers()
        surfaceView.root.insertSublayer(edge.host, above: layers.fill)
        edge.setContentsScale(container?.window?.backingScaleFactor ?? 2)
        layers.attach(edge)
        edge.setNeedsYou(needsYou)
        edge.show(StateTint(lead: ui.pill.lead), animated: false)
        edgeLayers = edge
    }

    private func removeEdge() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeLayers?.host.removeFromSuperlayer()
        edgeLayers = nil
        layers.attach(nil)
        CATransaction.commit()
    }

    /// Reduce Transparency or Increase Contrast changed: the glass is made again (it reads them when made).
    func rebuildGlass() {
        guard glassView != nil else { return }
        // One transaction: the black never shows between the old glass and the new.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeGlass()
        syncGlass()
        CATransaction.commit()
    }

    /// The notch the glass meets (the display changed).
    func setNotch(_ notch: CGSize?) {
        guard notch != self.notch else { return }
        self.notch = notch
        placePlate()
        placeRimCut()
    }

    /// Solid's notch plate cut out of the edge line on Core Animation's outline (P797): the carrier's mask, in its layer's
    /// own space, over all the canvas the line can ride into; none on another theme or without a notch. The plan's lift
    /// moves the carrier's sublayers and its mask with them, and the cut takes it back on the same keyframes
    /// (`IslandSurfaceLayers.rimCut`), so the line rides under the plate where the notch is, as it rides under the
    /// hardware. True when it changed anything.
    @discardableResult
    private func placeRimCut() -> Bool {
        guard let carrier = rimCarrier, let layer = carrier.layer else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard theme == .solid, let notch else {
            guard layer.mask != nil else { return false }
            layer.mask = nil
            return true
        }
        let cut = carrier.cut, shape = SolidLook.plateCut(notch, canvas: size, band: carrier.bounds.height, yDown: Self.runsDown(layer))
        var changed = false
        // Bounds and position, not the frame: the cut's transform takes the plan's lift back (`IslandSurfaceLayers.rimCut`).
        let bounds = CGRect(origin: .zero, size: shape.frame.size), position = CGPoint(x: shape.frame.midX, y: shape.frame.midY)
        if cut.bounds != bounds || cut.position != position {
            cut.bounds = bounds
            cut.position = position
            changed = true
        }
        if cut.path != shape.path {
            cut.path = shape.path
            changed = true
        }
        let scale = container?.window?.backingScaleFactor ?? 2
        if cut.contentsScale != scale { cut.contentsScale = scale }
        if layer.mask !== cut {
            layer.mask = cut
            changed = true
        }
        return changed
    }

    /// Whether `layer`'s own space runs down the screen: an odd number of flipped layers from it up to the window's (a
    /// flipped view's layer in a flipped view's is not itself flipped, yet runs down).
    static func runsDown(_ layer: CALayer) -> Bool {
        var down = false
        var next: CALayer? = layer
        while let current = next {
            if current.isGeometryFlipped { down.toggle() }
            next = current.superlayer
        }
        return down
    }

    /// What the glass view is made of for the theme on Core Animation's outline: Smoke's glass (or Reduce
    /// Transparency's solid), Glass's rim alone, Solid's window material, or none for Black.
    private var wantedGlass: GlassSurfaceNSView.Backdrop? {
        guard outline == .coreAnimation, surfaceView != nil else { return nil }
        switch theme {
        case .black: return nil
        case .glass: return .rimOnly
        case .smoke: return .preferred()
        case .solid: return .window
        }
    }

    /// Glass's rim, Solid's material, or Smoke's glass (made again by `rebuildGlass` for its Reduce Transparency).
    private static func kind(_ backdrop: GlassSurfaceNSView.Backdrop) -> Int {
        switch backdrop {
        case .rimOnly: 0
        case .window: 1
        default: 2
        }
    }

    /// Glass's rim sits over the content (its glass is the content's own, which would blur a rim under it); Smoke's
    /// glass between the black's view and the content.
    private var glassOverContent: Bool { glassView?.backdrop == GlassSurfaceNSView.Backdrop.rimOnly }

    /// The glass in or out as the theme and the outline ask: in for Smoke, Glass and Solid on Core Animation's outline,
    /// the black's fill clear; out otherwise, the black back. A switch between them makes it again.
    private func syncGlass() {
        let wanted = wantedGlass
        if let glassView, let wanted, Self.kind(glassView.backdrop) == Self.kind(wanted) { return }
        if wanted == nil, glassView == nil { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if glassView != nil { removeGlass() }
        guard let wanted, let container, let surfaceView, let maskedView else { return }
        let glass = GlassSurfaceNSView(style: .island, backdrop: wanted)
        glass.frame = CGRect(origin: origin, size: size)
        if wanted == GlassSurfaceNSView.Backdrop.rimOnly {
            container.addSubview(glass, positioned: .above, relativeTo: maskedView)
        } else {
            container.addSubview(glass, positioned: .above, relativeTo: surfaceView)
        }
        glassView = glass
        layers.glass = glass
        layers.fill.fillColor = nil
        paintRimLook()
        placePlate()
        glass.setContentsScale(container.window?.backingScaleFactor ?? 2)
        // The plan now playing, on the glass too; at rest, its last outline.
        if let plan = layers.plan { layers.install(plan) }
        ensure()
    }

    private func removeGlass() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glassView?.removeFromSuperview()
        glassView = nil
        layers.glass = nil
        layers.fill.fillColor = CGColor(gray: 0, alpha: 1)
        CATransaction.commit()
    }

    /// Smoke's notch plate and shade among the glass's marks, where the notch is; none without a notch, and none on Glass
    /// or Solid: Solid's plate is the content's, over the State tint's veil the content lays (`IslandGlassContent`,
    /// P793), where a mark of the glass, under the content, took the veil's tint.
    private func placePlate() {
        guard let glass = glassView else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let scale = container?.window?.backingScaleFactor ?? 2
        let plate = glass.marksLayer.sublayers?.first { $0.name == "island.glass.notchPlate" }
        let shade = glass.marksLayer.sublayers?.first { $0.name == "island.glass.shade" } as? CAGradientLayer
        guard let notch, glass.backdrop != GlassSurfaceNSView.Backdrop.rimOnly, glass.backdrop != GlassSurfaceNSView.Backdrop.window else {
            plate?.removeFromSuperlayer()
            shade?.removeFromSuperlayer()
            return
        }
        let model = NotchPlate(notch: notch)
        if let shade { model.placeShade(shade, canvas: size) } else { glass.marksLayer.addSublayer(model.shadeLayer(canvas: size)) }
        if let plate { model.place(plate, canvas: size, scale: scale) } else { glass.marksLayer.addSublayer(model.layer(canvas: size, scale: scale)) }
    }

    /// The display changed, or the canvas was built: its size.
    func resize(_ size: CGSize) {
        self.size = size
        hosting.frame = CGRect(origin: .zero, size: size)
        layers.resize(size)
        let frame = CGRect(origin: origin, size: size)
        if outline == .coreAnimation { hosting.setFrameOrigin(.zero) } else { hosting.setFrameOrigin(origin) }
        surfaceView?.frame = frame
        maskedView?.frame = frame
        rimCarrier?.frame = CGRect(x: 0, y: 0, width: size.width, height: IslandRimView.band)
        rimHost?.frame = CGRect(x: 0, y: 0, width: size.width, height: IslandRimView.band)
        glassView?.frame = frame
        placePlate()
        placeRimCut()
        ensure()
    }

    /// A panel snap: the canvas stays where it is on the screen, so its views move by the panel's change. Call inside the
    /// snap's transaction, before the panel's frame changes; `ensure` after.
    func place(_ origin: CGPoint) {
        self.origin = origin
        if let surfaceView, let maskedView {
            surfaceView.setFrameOrigin(origin)
            glassView?.setFrameOrigin(origin)
            maskedView.setFrameOrigin(origin)
        } else {
            hosting.setFrameOrigin(origin)
        }
    }

    /// Draws the outline `outline` asks for from now on. Core Animation's builds its views around the hosting view (kept,
    /// with all its SwiftUI state); SwiftUI's takes them away again.
    func setOutline(_ new: IslandOutline) {
        guard new != outline, let container else { return }
        outline = new
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if new == .coreAnimation {
            let frame = CGRect(origin: origin, size: size)
            let surfaceView = IslandSurfaceView(frame: frame, fill: layers.fill)
            let maskedView = IslandMaskedView(frame: frame, clip: layers.clip)
            maskedView.autoresizesSubviews = false
            let carrier = IslandRimCarrier(frame: CGRect(x: 0, y: 0, width: size.width, height: IslandRimView.band))
            carrier.wantsLayer = true
            carrier.autoresizesSubviews = false
            let rimHost = IslandRimHostingView(rootView: rimRoot)
            rimHost.sizingOptions = []
            rimHost.safeAreaRegions = []
            rimHost.autoresizingMask = []
            rimHost.frame = CGRect(x: 0, y: 0, width: size.width, height: IslandRimView.band)
            carrier.addSubview(rimHost)
            hosting.removeFromSuperview()
            hosting.setFrameOrigin(.zero)
            maskedView.addSubview(hosting)
            maskedView.addSubview(carrier)
            container.addSubview(surfaceView, positioned: .below, relativeTo: nil)
            container.addSubview(maskedView, positioned: .above, relativeTo: surfaceView)
            self.surfaceView = surfaceView
            self.maskedView = maskedView
            rimCarrier = carrier
            self.rimHost = rimHost
            layers.rim = carrier.layer
            layers.rimCut = carrier.cut
            surfaceView.changed = { [weak self] in self?.ensure() }
            maskedView.changed = { [weak self] in self?.ensure() }
            ui.outline = .coreAnimation
            syncGlass()
            syncEdge()
            placeRimCut()
            ensure()
        } else {
            takeDown()
            showSwiftUIsOutline()
        }
    }

    /// The views' copy of the outline back to SwiftUI's, in a transaction that animates nothing: SwiftUI's clip, which
    /// drew nothing while Core Animation's outline did, takes the surface where it is at once. On the curves the last
    /// motion left in the surface's box it would grow from nothing, the island vanishing and growing back.
    private func showSwiftUIsOutline() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { ui.outline = .swiftUI }
    }

    /// SwiftUI's outline again: the hosting view straight in the container, at the canvas's place.
    private func takeDown() {
        guard let container else { return }
        hosting.removeFromSuperview()
        hosting.setFrameOrigin(origin)
        container.addSubview(hosting)
        for view in [surfaceView, maskedView] as [NSView?] { view?.removeFromSuperview() }
        removeGlass()
        removeEdge()
        rimHost?.rootView = AnyView(EmptyView())
        surfaceView = nil
        maskedView = nil
        rimCarrier = nil
        rimHost = nil
        layers.rim = nil
        layers.rimCut = nil
    }

    /// Core Animation's layers where they belong, put back where they are not: the black in the surface view's own
    /// layer, the mask on the content's layer, the edge line's carrier with its layer, the views in order at the canvas's
    /// place, the shape layers at the canvas's size and the display's scale. Called after every snap and display change,
    /// before the turn's commit. False: they could not be put back, and the canvas went back to SwiftUI's outline (a
    /// jump, never a spill).
    @discardableResult
    func ensure() -> Bool {
        guard outline == .coreAnimation, let surfaceView, let maskedView, let rimCarrier, let container else { return true }
        var repaired = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if surfaceView.layer !== surfaceView.root {
            surfaceView.layer = surfaceView.root
            repaired = true
        }
        if layers.fill.superlayer !== surfaceView.root {
            surfaceView.root.addSublayer(layers.fill)
            repaired = true
        }
        if !maskedView.wantsLayer {
            maskedView.wantsLayer = true
            repaired = true
        }
        if maskedView.layer?.mask !== layers.clip {
            maskedView.layer?.mask = layers.clip
            repaired = true
        }
        if !rimCarrier.wantsLayer {
            rimCarrier.wantsLayer = true
            repaired = true
        }
        if layers.rim !== rimCarrier.layer || layers.rimCut !== rimCarrier.cut {
            layers.rim = rimCarrier.layer
            layers.rimCut = rimCarrier.cut
            if let plan = layers.plan { layers.install(plan) }
            repaired = true
        }
        // Solid's plate cut out of the edge line, on the carrier's layer.
        if placeRimCut() { repaired = true }
        if surfaceView.superview !== container || maskedView.superview !== container {
            container.addSubview(surfaceView, positioned: .below, relativeTo: nil)
            container.addSubview(maskedView, positioned: .above, relativeTo: surfaceView)
            repaired = true
        }
        if let index = container.subviews.firstIndex(of: maskedView), container.subviews.firstIndex(of: surfaceView).map({ $0 > index }) == true {
            container.addSubview(maskedView, positioned: .above, relativeTo: surfaceView)
            repaired = true
        }
        if hosting.superview !== maskedView {
            hosting.removeFromSuperview()
            hosting.setFrameOrigin(.zero)
            maskedView.addSubview(hosting, positioned: .below, relativeTo: rimCarrier)
            repaired = true
        }
        let frame = CGRect(origin: origin, size: size)
        for view in [surfaceView, maskedView] as [NSView] where view.frame != frame {
            view.frame = frame
            repaired = true
        }
        // Smoke and Solid: the glass (or the material) masked, between the black's view and the content; Glass: its rim
        // masked, over the content; where the canvas is, on the plan.
        if let glass = glassView {
            if !glass.ensure() { repaired = true }
            let views = container.subviews
            let at = views.firstIndex(of: glass) ?? 0, surface = views.firstIndex(of: surfaceView) ?? 0
            let masked = views.firstIndex(of: maskedView) ?? 0
            if glassOverContent {
                if glass.superview !== container || at < masked {
                    container.addSubview(glass, positioned: .above, relativeTo: maskedView)
                    repaired = true
                }
            } else if glass.superview !== container || at < surface || at > masked {
                container.addSubview(glass, positioned: .below, relativeTo: maskedView)
                repaired = true
            }
            if glass.frame != frame {
                glass.frame = frame
                repaired = true
            }
            if layers.glass !== glass {
                layers.glass = glass
                if let plan = layers.plan { layers.install(plan) }
                repaired = true
            }
            if layers.fill.fillColor != nil { layers.fill.fillColor = nil }
            glass.setContentsScale(container.window?.backingScaleFactor ?? 2)
        }
        let scale = container.window?.backingScaleFactor ?? 2
        for layer in [layers.fill, layers.clip, surfaceView.root] as [CALayer] where layer.contentsScale != scale {
            layer.contentsScale = scale
        }
        let bounds = CGRect(origin: .zero, size: size)
        for layer in [layers.fill, layers.clip] where layer.frame != bounds {
            layer.frame = bounds
            repaired = true
        }
        // Black's tint edge: masked by the outline, over the black's fill in its view, on the plan, at the canvas's size.
        if let edge = edgeLayers {
            if !edge.ensure() { repaired = true }
            let sublayers = surfaceView.root.sublayers ?? []
            if edge.host.superlayer !== surfaceView.root
                || (sublayers.firstIndex(of: edge.host) ?? 0) < (sublayers.firstIndex(of: layers.fill) ?? 0) {
                surfaceView.root.insertSublayer(edge.host, above: layers.fill)
                repaired = true
            }
            if layers.edge !== edge || edge.host.frame != bounds {
                layers.attach(edge)
                repaired = true
            }
            edge.setContentsScale(scale)
        }
        if repaired { repairs += 1 }
        let sound = maskedView.layer?.mask === layers.clip && layers.fill.superlayer === surfaceView.root
            && surfaceView.layer === surfaceView.root && surfaceView.root.backgroundColor == nil && glassView?.isSound != false
            && edgeLayers?.isSound != false
        guard sound else {
            outline = .swiftUI
            takeDown()
            showSwiftUIsOutline()
            fellBack()
            return false
        }
        return true
    }
}
