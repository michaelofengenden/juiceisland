import Observation
import QuartzCore
import SwiftUI

// Motion: Liquid on SwiftUI's outline. The body keeps SwiftUI's two scoped springs (F5); the liquid values (the belly,
// the corners' roundness, the reservoir, the bud and its neck) come from the model's own plan
// (`IslandChoreography.surfacePlan`), read at each display frame by the clip itself (`LiquidClock`): a play bumps a
// pulse the clip animates linearly over the plan's time left, so SwiftUI draws the clip every frame until the plan ends
// and nothing at rest, with no view of its own, no state written a frame, no layout. With Liquid off the clock is still
// and carries nothing, so every view is exactly today's. The neck's flag and the bud come from the same model clock, so
// the pinch is coherent.

/// What SwiftUI's liquid outline draws: the plan now playing, or still values (renders, a snap). nil: Liquid is off,
/// and the clip draws today's outline.
@MainActor
@Observable
final class LiquidBox {
    /// The plan playing, from its start; nil once it ended (its last sample is then `still`).
    private(set) var plan: IslandChoreography.SurfacePlan?
    /// Still values (renders, a snap, a plan's end), or none.
    private(set) var still: LiquidParams?
    /// Bumped at each play, which the clip animates on `clock`.
    private(set) var pulse = 0
    /// The pulse's curve: linear over the plan's time left.
    @ObservationIgnored private(set) var clock: Animation?
    @ObservationIgnored private var ends = 0

    /// Whether a plan plays (the clip draws each frame only then).
    var playing: Bool { plan != nil }

    /// The values now: the plan's while it plays, the still ones otherwise.
    var params: LiquidParams? { frame?.params(at: IslandMotionDirector.now) }

    /// What the clip draws.
    var frame: LiquidFrame? { plan.map(LiquidFrame.plan) ?? still.map(LiquidFrame.still) }

    /// The plan from its start; at its end it rests on its last sample.
    func play(_ plan: IslandChoreography.SurfacePlan, at now: TimeInterval = IslandMotionDirector.now) {
        ends += 1
        guard let liquid = plan.liquid, let last = liquid.last else { return show(nil) }
        guard liquid.count > 1, plan.drawsLiquid else { return show(last) }
        let duration = max(0, plan.end - now) * IslandMotion.slowdown + 0.03
        self.plan = plan
        clock = .linear(duration: duration)
        pulse &+= 1
        let id = ends
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.ends == id else { return }
                self.show(last)
            }
        }
    }

    /// Still values (renders, a snap), or none.
    func show(_ params: LiquidParams?) {
        ends += 1
        clock = nil
        if plan != nil { plan = nil }
        if still != params { still = params }
    }
}

/// The liquid outline's source: a plan (read at the frame's moment) or still values.
enum LiquidFrame: Equatable, Sendable {
    case plan(IslandChoreography.SurfacePlan)
    case still(LiquidParams)

    /// The values at `now` (the model's clock).
    func params(at now: TimeInterval) -> LiquidParams? {
        switch self {
        case let .plan(plan): plan.liquid(at: now)
        case let .still(params): params
        }
    }
}

/// A clip that draws Motion: Liquid's union (`SurfaceClip`, `SurfaceRimClip`).
protocol LiquidClipping: ViewModifier {
    var liquid: LiquidParams? { get set }
}

/// Motion: Liquid on SwiftUI's outline: the clip's liquid values, read from the frame at the display frame's moment. Its
/// one animatable value is the box's pulse, animated on the box's clock (linear over the plan's time left), so while a
/// plan plays SwiftUI runs this small body every frame, as it runs the width's (`SurfaceClip`), and no frame at rest.
/// The clip inside keeps the width's curve, its height the height's. Liquid off: no frame, no pulse, today's clip.
nonisolated struct LiquidClock<Clip: LiquidClipping>: ViewModifier, Animatable {
    var pulse: Double
    var frame: LiquidFrame?
    var clip: Clip
    /// The width's curve, scoped to the clip (the pulse's is scoped around this).
    var width: Animation?

    var animatableData: Double {
        get { pulse }
        set { pulse = newValue }
    }

    func body(content: Content) -> some View {
        var clip = clip
        clip.liquid = frame?.params(at: ProcessInfo.processInfo.systemUptime / IslandMotion.slowdown)
        return content.animation(width) { $0.modifier(clip) }
    }
}

// MARK: The card's bud (L2)

/// Motion: Liquid's bud: the card layers, laid out where the list starts, ride in the bud below the list: from the body's
/// height `ui.budBase` the gap and the bud's top inset lower (a still offset, so it snaps in and out with the card
/// layer), and with the body's height as it moves from there (on the height's own curve). Render offsets (geometry
/// effects, as `offset` is), so hit testing and VoiceOver follow the card and nothing is laid out again. With the card in
/// the body, or Liquid off, both are nothing.
struct LiquidBudRide: ViewModifier {
    let ui: IslandUIState
    /// Where the card layers start: the header group's height.
    var listTop: CGFloat

    func body(content: Content) -> some View {
        let surface = ui.live.surface
        let base = ui.budBase
        let still = base.map { $0 + LiquidMotion.restGap + LiquidMotion.budInsetTop - listTop } ?? 0
        let rides = base.map { surface.value.height - $0 } ?? 0
        content
            .animation(base == nil ? nil : surface.heightMotion.animation) { $0.modifier(ScopedOffset(y: rides)) }
            .modifier(ScopedOffset(y: still))
    }
}

/// The island's hit-test shape: the target shape (`NotchSurfaceShape`), and while a card rests in its bud the rest's
/// reach below it (`IslandChoreography.restExtent`: the gap's band and the bud), so a click on the card's keys lands and
/// one in the gap does what the panel's margin does.
struct IslandHitShape: Shape {
    var geometry: SurfaceGeometry
    var hit: IslandExtent?

    func path(in rect: CGRect) -> Path {
        var path = NotchSurfaceShape(geometry: geometry).path(in: rect)
        if let hit, hit.height > geometry.height {
            path.addRect(CGRect(x: rect.midX - hit.left, y: rect.minY + max(0, geometry.height - 1), width: hit.width,
                                height: hit.height - max(0, geometry.height - 1)))
        }
        return path
    }
}
