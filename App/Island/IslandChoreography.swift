import CoreGraphics
import Foundation
import SwiftUI

/// A part of the opened island that comes into focus on its own.
enum PartID: Hashable, Sendable {
    case usage, row(String), codexGroup, footer, empty, cardHeader, cardBody
    /// The header and body of the card another session's card took the place of, fading out in a layer of their own.
    case leavingHeader, leavingBody
    /// A card built ahead of showing, while another shows: no channel ever brings it in (P133).
    case cardAhead

    var isCard: Bool {
        switch self {
        case .cardHeader, .cardBody, .leavingHeader, .leavingBody, .cardAhead: true
        default: false
        }
    }

    /// The leaving layer's part for a card part.
    var leaving: PartID {
        switch self {
        case .cardHeader: .leavingHeader
        case .cardBody: .leavingBody
        default: self
        }
    }

    /// How soft and how far it comes into focus (`FocusReveal`): rows and blocks 6 and 6, the footer 4 and 4, the
    /// card's header in place.
    var blur: CGFloat {
        switch self {
        case .footer, .cardHeader, .leavingHeader: 4
        default: 6
        }
    }

    var drift: CGFloat {
        switch self {
        case .footer: 4
        case .cardHeader, .leavingHeader: 0
        default: 6
        }
    }
}

/// One value the island animates. The surface's five (both reaches, height, ear, radius) are one animatable vector
/// to SwiftUI, so a new curve on any of them carries all five, or two with the open's two springs (Motion: Refined,
/// `MotionTuning.splitsSurface`: the width's three and the height's two); every other channel is its own.
enum Channel: Hashable, Sendable {
    case left, right, height, ear, radius
    /// How far the surface reaches below the closed pill: the edge line rides it.
    case rimLift
    /// The pill's focus, and its glyph and count sliding out from behind the notch.
    case pill, pillArrive
    /// The header group's focus.
    case header
    case part(PartID)
    /// A row's render offset as it glides (a card's row rising to the header and back).
    case glide(String)
    /// The card body hanging from its gliding row.
    case cardRide
    /// Core Animation's outline only: the header's brand glyph and gear, shown as the widening surface passes them
    /// (`IslandChoreography.scheduleShoulders`; SwiftUI's outline reads its width in each frame instead, `ShoulderGate`).
    case shoulders
    /// Motion: Liquid's values beside the body (`LiquidParams`): the belly, the corners' extra roundness, the bud and
    /// its neck. Both outlines draw them from the model's plan (`SurfacePlan.liquid`), never from a box of their own.
    case liquid(LiquidKey)

    static let surface: [Channel] = [.left, .right, .height, .ear, .radius]
    var isSurface: Bool { Self.surface.contains(self) }
    var isLiquid: Bool { if case .liquid = self { true } else { false } }
    /// The surface as two vectors (`MotionTuning.splitsSurface`): the width (both reaches and the ear, which follows the
    /// shoulders) and the height (the height and the bottom corners).
    static let surfaceWidth: [Channel] = [.left, .right, .ear]
    static let surfaceHeight: [Channel] = [.height, .radius]
}

/// One animated scalar as SwiftUI runs it: from a value and a velocity at `start` toward `target` on `curve` (nil: at
/// rest, snapped). A retarget keeps the value and the velocity, as a SwiftUI spring does.
struct ShadowValue: Equatable, Sendable {
    var from: Double
    var velocity: Double
    var target: Double
    var start: TimeInterval
    var curve: IslandMotion.Curve?

    static func rest(_ value: Double, at time: TimeInterval = 0) -> ShadowValue {
        ShadowValue(from: value, velocity: 0, target: value, start: time, curve: nil)
    }

    /// SwiftUI's spring in closed form (`IslandMotion.Curve.state`), the same numbers `curve.spring` gives.
    func value(at t: TimeInterval) -> Double {
        guard let curve else { return target }
        guard t > start else { return from }
        return target + curve.state(from - target, velocity: velocity, time: t - start).x
    }

    func velocity(at t: TimeInterval) -> Double {
        guard let curve else { return 0 }
        guard t > start else { return velocity }
        return curve.state(from - target, velocity: velocity, time: t - start).v
    }

    /// Toward `target` from where it is now, keeping its velocity; a nil curve snaps.
    mutating func retarget(_ target: Double, curve: IslandMotion.Curve?, at t: TimeInterval) {
        guard curve != nil else {
            self = .rest(target, at: t)
            return
        }
        self = ShadowValue(from: value(at: t), velocity: velocity(at: t), target: target, start: t, curve: curve)
    }
}

/// The opened island's measured layout (its content is laid out once at its final size; nothing the surface does
/// changes it): the header group's height, each layer's height and every part's frame, in the island's coordinates
/// (x from its left edge, shoulders included; y from the screen's top edge).
struct ContentLayout: Equatable, Sendable {
    var header: CGFloat = IslandTheme.Metrics.headerHeight
    var list: CGFloat = 0
    /// The card layer's height and whose card it measured, while one is mounted.
    var card: CGFloat?
    var cardID: String?
    var parts: [PartID: CGRect] = [:]
    /// Where a card's header row starts (the card layer's top and its padding), and a list row's own top inset: a
    /// tapped row glides by the difference.
    var cardHeaderTop: CGFloat = IslandTheme.Metrics.headerHeight + 8
    var rowInset: CGFloat = 5
    /// Show all's rows the list builds only as it scrolls to them (P400): one that comes is there at once.
    var lazyRows: Set<String> = []

    /// The island as tall as the header, the shown layer and the bottom padding.
    func islandHeight(card id: String?) -> CGFloat {
        let layer = id != nil && cardID == id ? (card ?? list) : list
        return max(header + 8, header + layer + IslandTheme.Metrics.bottomPadding)
    }

    /// The list layer's parts, top to bottom.
    var listParts: [PartID] {
        parts.filter { !$0.key.isCard }.sorted { $0.value.minY < $1.value.minY || ($0.value.minY == $1.value.minY && "\($0.key)" < "\($1.key)") }
            .map(\.key)
    }
}

/// Every channel's value and the surface at one moment, and the panel then: what a render draws.
struct IslandFrame: Equatable, Sendable {
    var surface: SurfaceGeometry
    var values: [Channel: Double]
    var panel: IslandExtent
}

/// The island's choreography as a pure value (spec §8.3): which values retarget, on which curve and when, the panel's
/// sizes and the side effects, with the same closed-form springs SwiftUI runs, so the live app, the renders and the
/// tests all play it and it can be replayed. Later steps are jobs (data, with a tag), never timers or `.delay`, so a new
/// transition cancels the other direction's pending steps. The model's clock is `IslandMotionDirector`'s (real time
/// divided by `IslandMotion.slowdown`).
struct IslandChoreography: Sendable {
    struct Metrics: Equatable, Sendable {
        var targets: SurfaceTargets
        var layout = ContentLayout()
        var reduceMotion = false
        /// Settings › Island › Motion and Hover.
        var tuning = MotionTuning()
        /// Diagnostics › Motion › Outline: Core Animation's outline takes its shoulder gate from the model
        /// (`scheduleShoulders`) and plays the model's plan (`surfacePlan`).
        var outline = IslandOutline.swiftUI
        /// The tallest the opened island may be on its display (`IslandPanelSizing.maxIslandHeight`); nil: no limit.
        /// Motion: Liquid's bud (L2) only: a card that would reach past it presents in the body, as Refined's.
        var maxHeight: CGFloat? = nil
    }

    enum Event: Equatable, Sendable {
        case swell(Bool)
        case open(IslandHoverMachine.OpenReason, IslandPresentation)
        case close(IslandHoverMachine.CloseStyle)
        /// The pointer left while the island was still opening: content that has not landed turns back.
        case retreat
        /// It came back within the retreat's grace.
        case resume
        /// List ⇄ card while open (stored while closed).
        case present(IslandPresentation)
        /// Show all pressed, or the usage strip clicked open or folded (E6): played here, the list's own change written
        /// by the model (`Effect.list`) once what leaves has faded, on the curve the edge then follows.
        case list(ListChange)
        /// The opened island's content was measured again.
        case content(ContentLayout)
        /// What the closed pill shows: a first session arrives, the last departs, the pill resizes.
        case pill(PillContent)
        /// The panel was built at the idle geometry: order it in (unless the idle pill hides) for the pill to arrive.
        case show
        /// Show as Window: fold everything into the notch, then order out.
        case hide
        /// The display changed: snap to the rest of the current state on the new geometry.
        case display(Metrics)
        case reduceMotion(Bool)
        /// Settings › Island › Motion or Hover changed: the next transition plays the new values.
        case tuning(MotionTuning)
        /// Diagnostics › Motion › Outline changed (at rest, or falling back to SwiftUI's).
        case outline(IslandOutline)
    }

    enum Command: Equatable, Sendable {
        /// The panel's size, emitted before the batch it covers (a growth) or once the shape fits (a shrink).
        case panel(IslandExtent)
        /// The shape pointer and clicks are judged against, and whether it is the island.
        case target(SurfaceGeometry, isOpen: Bool)
        /// These values on `curve` (nil: a true snap), in the batch's one plain transaction, the curve in each channel's
        /// box (`IslandChannelStore`, E5).
        case animate(IslandMotion.Curve?, [Channel: Double])
        /// The closed pill's snapshot, swapped in `withAnimation(curve)` (nil: still, in the batch's plain transaction).
        case pillSnapshot(PillContent, IslandMotion.Curve?)
        case effect(Effect)
    }

    enum Effect: Equatable, Sendable {
        case orderIn, orderOut
        /// After a close has folded away: the list, not Show all, the strip folded, no hover label.
        case resetAfterFold
        /// Whether the island's and the pill's glyph clocks run: each only while its glyphs can be seen (E2). The island's
        /// starts with the first write that brings anything of it in (the header's job, or a reverse's re-aim) and stops
        /// as a close starts; the pill's stops as an open starts and starts again as it comes back (`pillIn`). A stopped
        /// clock's glyphs hold where they are (`IslandUIState.holdsGlyphs`), so a glyph still fading out never jumps.
        case islandLive(Bool), pillLive(Bool)
        /// Mount the card layer with this session's card, or unmount it (nil).
        case cardSnapshot(String?)
        /// The card layer's card (this session's) moves to the leaving layer as another takes its place, or the leaving
        /// layer goes (nil). Written with the values, as the views' own state (`IslandMotionDirector`).
        case cardLeaving(String?)
        /// The list's change (Show all, the strip open or folded) written in its own transaction on `curve` (nil: none),
        /// so what it moves (the rows under the usage block, the Codex group under new rows) moves on the curve the
        /// edge follows (E6). Written by the director, as the views' own state.
        case list(ListChange, IslandMotion.Curve?)
        /// Motion: Liquid's bud (L2): the card layers ride in the bud below the list, from the body's height `base`
        /// (nil: in the body), and the pointer and clicks count `hit` as the island (nil: the target shape alone).
        case bud(base: CGFloat?, hit: IslandExtent?)
    }

    /// What `Event.list` changes in the list (E6).
    enum ListChange: Equatable, Sendable {
        /// Every row, the footer gone.
        case showAll
        /// The usage block unfolded from the header strip (true) or folded back into it.
        case strip(Bool)

        /// Whether the list grows with it (the edge unfolds) or shrinks (it folds).
        var grows: Bool { self != .strip(false) }
        /// The part that leaves with it: faded first, never cut (the footer, the usage block).
        var leaving: PartID? {
            switch self {
            case .showAll: .footer
            case .strip(false): .usage
            case .strip(true): nil
            }
        }
    }

    enum Surface: Equatable, Sendable { case closed, island }

    enum Tag: Hashable, Sendable {
        case open, reveal, fold, pillIn, pillSleep, shrink, arrive, depart, card, list, gone, content, reduced, show, leave, shoulders
        /// A list change waiting for what leaves with it to fade (`Step.listSwap`).
        case swap
        /// Motion: Liquid's beats (`Step.liquid`): the other direction cancels them.
        case liquid
        /// Motion: Liquid's bud (L2): the card's bud out, its merge back and its close; the next of them cancels them (an
        /// open does not: a bud still merging goes on into the island).
        case bud
    }

    /// Motion: Liquid's later beats, each a job that retargets the liquid values (or the body, the close's) from where
    /// they are.
    enum LiquidBeat: Equatable, Sendable {
        /// The open: the belly flattens; the corners firm.
        case sagOut, firm
        /// The close: the body folds and narrows under the pill (the reservoir set), then lands in it; the reservoir
        /// cleared once it draws nothing of its own.
        case close, land, drained
        /// The neck pinches (the bud parts) or joins, at the moment solved from the springs.
        case pinch, join
        /// The neck's fillet back to its own radius after a join.
        case tension
        /// The bud: it is seeded (once the open's belly has gone), starts to grow and fall (or spreads, apart), spreads
        /// into the card, the card's content fades (the merge), it rises back in once it is a bead, the body gulps it and
        /// lets go, and it goes (snapped to its rest inside the body).
        case budSeed, budStart, spread, budFade, rise, gulp, gulpOut, budGone
        /// The close narrows the body under the pill (with the bud out, once the bead is in).
        case narrow
    }

    enum Step: Equatable, Sendable {
        case liquid(LiquidBeat)
        case openHeight(trigger: TimeInterval)
        case header
        case reveal(PartID)
        case foldHeight(IslandMotion.Curve)
        case foldWidth(IslandMotion.Curve)
        case pillIn, pillSleep, fit
        case arriveContent, tuck(IslandMotion.Curve), departSnapshot, barSwap
        /// No notch: the bar drops from the sliver as the island is shown.
        case drop
        case glideStart(String, Double)
        case cross(String?)
        case glideHome(String, trigger: TimeInterval)
        case listIn(trigger: TimeInterval)
        case cardGone, glideReset(String)
        /// The card that left for another has faded out: its layer goes.
        case leavingGone
        case contentHeight
        case reducedOpen, reducedIn([PartID]), reducedClose, reducedHeight, reducedDepart
        /// Core Animation's outline: the shoulder gate turns (`scheduleShoulders`).
        case shoulders(Double, IslandMotion.Curve)
        /// What leaves with a list change has faded: the change is written (E6).
        case listSwap(ListChange)

        /// Steps that move the surface: a fit waits for the last of them.
        var movesSurface: Bool {
            switch self {
            case .openHeight, .foldHeight, .foldWidth, .tuck, .drop, .contentHeight, .glideHome, .reducedOpen, .reducedClose,
                 .reducedHeight, .reducedDepart, .liquid: true
            default: false
            }
        }
    }

    struct Job: Equatable, Sendable {
        var time: TimeInterval
        var tag: Tag
        var step: Step
        var seq: Int
    }

    enum AfterFit: Hashable, Sendable { case reset, orderOut }

    private(set) var metrics: Metrics
    private(set) var surface: Surface
    private(set) var swollen = false
    private(set) var presentation: IslandPresentation
    private(set) var values: [Channel: ShadowValue] = [:]
    private(set) var jobs: [Job] = []
    private(set) var panel: IslandExtent
    private(set) var ordered: Bool
    /// The pill the view shows (a departing pill plays out before its snapshot empties).
    private(set) var shownPill: PillContent
    /// The card the card layer holds, if mounted.
    private(set) var cardMounted: String?
    /// The card fading out in the leaving layer after another session's card took its place.
    private(set) var cardLeaving: String?
    /// Motion: Refined. The body of the card a present brought comes in no sooner than this (`gateCardBody`).
    private var cardBodyFrom: TimeInterval = 0
    /// The list change last written on a curve (E6): the content it brings retargets the height on that curve from
    /// then, a shorter one at once (its parts already left), so the rows it moves and the edge move as one.
    private var listMove: ListMove?
    /// Parts arriving before this come in no sooner (E6): Show all's rows once the footer has faded, the usage block
    /// once the rows it pushes down have cleared all but the edge's depth of it.
    private var arrivalFloor: TimeInterval = -.infinity
    /// The floor each part that arrived under `arrivalFloor` keeps while its reveal is solved again.
    private var revealFloors: [PartID: TimeInterval] = [:]

    struct ListMove: Sendable {
        var curve: IslandMotion.Curve
        var at: TimeInterval
        var grows: Bool
    }
    private var seq = 0
    private var openedAt: TimeInterval = -.infinity
    private var retreated = false
    private var turnedBack: Set<Channel> = []
    private var afterFit: Set<AfterFit> = []
    /// Whether the island's glyph clock runs (`Effect.islandLive`): from the first reveal that brings anything of it in to
    /// the start of the close.
    private var islandClockRuns = false
    /// Hiding (Show as Window): the rest is the idle notch (no notch: the sliver) whatever the pill shows.
    private var hiding = false
    /// A copy playing ahead for the surface's plan (`surfacePlan`): it skips what cannot move the surface (reveals, fits,
    /// the pill's and the shoulders' gates, the card body's gate) and their scans.
    fileprivate var planning = false
    /// Motion: Liquid. The closed pill a close drains into, from the close's fold until the body draws nothing past it
    /// (model state, not a channel: the plan copies it into each sample).
    private(set) var reservoir: SurfaceGeometry?
    /// Every change to the model counts one, so the plan an event made for the panel (`liquidPlan`) is handed on only
    /// while the model is still as it made it.
    private var version = 0
    /// Motion: Liquid. The plan the last event made for the panel (`growForLiquid`), for the director to hand over.
    private var liquidPlan: (version: Int, plan: SurfacePlan)?
    /// Motion: Liquid's bud (L2). The card whose layers ride in the bud below the list, from its present until its layer
    /// goes, and the body's height they ride from.
    private(set) var budCard: String?
    private(set) var budBase: CGFloat?
    /// The bud as the views hold it (`Effect.bud`).
    private var budSent = BudState()
    /// A close with the bud out: the body narrows under the pill once the bead is in.
    private var narrowWaits = false

    struct BudState: Equatable, Sendable {
        var base: CGFloat?
        var hit: IslandExtent?
    }

    var targets: SurfaceTargets { metrics.targets }
    var layout: ContentLayout { metrics.layout }
    var tuning: MotionTuning { metrics.tuning }
    var isOpen: Bool { surface == .island }

    /// At rest in `surface` (closed: the pill, or idle), `presentation` showing when open.
    init(metrics: Metrics, surface: Surface = .closed, presentation: IslandPresentation = .list, ordered: Bool = true,
         at time: TimeInterval = 0) {
        self.metrics = metrics
        self.surface = surface
        self.presentation = presentation
        self.ordered = ordered
        shownPill = metrics.targets.pill
        panel = .zero
        if surface == .island, case let .card(id) = presentation { cardMounted = id }
        if surface == .island, case let .card(id) = presentation, metrics.tuning.liquid, budFits(id) {
            budCard = id
            budBase = metrics.layout.islandHeight(card: nil)
        }
        budSent = budState
        islandClockRuns = surface == .island
        snapToRest(at: time)
    }

    // MARK: Reading

    func value(_ channel: Channel, at t: TimeInterval) -> Double {
        values[channel]?.value(at: t) ?? Self.defaultValue(channel)
    }

    private func target(_ channel: Channel) -> Double {
        values[channel]?.target ?? Self.defaultValue(channel)
    }

    static func defaultValue(_ channel: Channel) -> Double {
        switch channel {
        case .pillArrive: 1
        case let .liquid(key): Double(LiquidParams.rest[key])
        default: 0
        }
    }

    func surface(at t: TimeInterval) -> SurfaceGeometry {
        SurfaceGeometry(left: value(.left, at: t), right: value(.right, at: t), height: value(.height, at: t),
                        ear: value(.ear, at: t), radius: value(.radius, at: t))
    }

    /// Motion: Liquid's values at `t`, and the reservoir.
    func liquid(at t: TimeInterval) -> LiquidParams {
        var p = LiquidParams()
        for key in LiquidKey.every { p[key] = CGFloat(value(.liquid(key), at: t)) }
        p.reservoir = reservoir
        return p
    }

    /// Every channel's value at `t` (jobs due by then must have run: `advance(to:)` first).
    func frame(at t: TimeInterval) -> IslandFrame {
        IslandFrame(surface: surface(at: t), values: values.mapValues { $0.value(at: t) }, panel: panel)
    }

    var nextJobTime: TimeInterval? { jobs.map(\.time).min() }

    /// A step of the choreography is still to run (the fit last of all): the island is in motion. A card is built ahead
    /// only once it is not (E4), so that 10 to 29 ms turn never lands inside a motion.
    var inMotion: Bool { !jobs.isEmpty }

    /// When what the island shows has settled, seen from `t` (E4): the fit, or the last step still to move the surface,
    /// when one is pending; else the first moment from which every channel stays within a hair of its target (half a
    /// point; 1 % of a focus), so a growth's tail, a row's glide home and a reveal's last fade are done; nil when that is
    /// now, or not within `horizon`. Looked at in 4 ms steps, and only for the channels still moving at `t`.
    private func settles(from t: TimeInterval) -> TimeInterval? {
        if let job = jobs.filter({ $0.step.movesSurface || $0.step == .fit }).map(\.time).max() { return job }
        let moving = values.filter { channel, value in !Self.still(channel, value, at: t) }
        guard !moving.isEmpty else { return nil }
        let step = 0.004
        var last: TimeInterval?
        var s = t
        while s <= t + IslandMotion.horizon {
            let unsettled = moving.contains { channel, value in
                abs(value.value(at: s) - value.target) > Self.settledWithin(channel)
            }
            if unsettled { last = s }
            s += step
        }
        guard let last else { return nil }
        return last + step <= t + IslandMotion.horizon ? last + step : nil
    }

    /// A channel all but still at `t`, as `isAtRest` reads it.
    private static func still(_ channel: Channel, _ value: ShadowValue, at t: TimeInterval) -> Bool {
        guard value.curve != nil else { return true }
        let (distance, speed) = movesPoints(channel) ? (0.1, 1.0) : (0.002, 0.02)
        return abs(value.value(at: t) - value.target) < distance && abs(value.velocity(at: t)) < speed
    }

    /// How far from its target a channel may be and read as settled: half a point, or 1 % of a focus.
    private static func settledWithin(_ channel: Channel) -> Double {
        movesPoints(channel) ? Double(IslandMotion.fitTolerance) : 0.01
    }

    /// Whether a channel is in points (the surface, the rim, the glides and the ride) rather than a 0 to 1 focus.
    private static func movesPoints(_ channel: Channel) -> Bool {
        switch channel {
        case .left, .right, .height, .ear, .radius, .rimLift, .glide, .cardRide, .liquid: true
        case .pill, .pillArrive, .header, .part, .shoulders: false
        }
    }

    /// Nothing is scheduled and nothing moves at `t`: every channel within a hair of its target and all but still (0.1 pt
    /// and 1 pt/s for the surface, the rim, the glides and the ride; 0.002 and 0.02/s for a focus). A recorded motion
    /// ends here (`MotionRecorder`).
    func isAtRest(at t: TimeInterval) -> Bool {
        guard jobs.isEmpty else { return false }
        return values.allSatisfy { channel, value in Self.still(channel, value, at: t) }
    }

    /// The jobs due by `t`, in the order `advance(to:)` runs them.
    func dueSteps(by t: TimeInterval) -> [Step] {
        jobs.filter { $0.time <= t + 1e-9 }.sorted { ($0.time, $0.seq) < ($1.time, $1.seq) }.map(\.step)
    }

    /// The island's height for what it presents (a card in its bud: the list's).
    var islandHeight: CGFloat {
        if budding { return layout.islandHeight(card: nil) }
        if case let .card(id) = presentation { return layout.islandHeight(card: id) }
        return layout.islandHeight(card: nil)
    }

    /// The surface's rest in the current state: the island, the swell, the pill or idle (while hiding, the idle notch or
    /// the sliver the bar folds into).
    var restGeometry: SurfaceGeometry {
        if surface == .island { return targets.island(height: islandHeight) }
        if hiding { return targets.topBar ? targets.sliver : targets.idle }
        return swollen ? targets.swell(tuning) : targets.closed
    }

    // MARK: Events

    mutating func handle(_ event: Event, at t: TimeInterval) -> [Command] {
        var out: [Command] = []
        version += 1
        switch event {
        case let .swell(on): swell(on, at: t, into: &out)
        case let .open(_, presentation): open(presentation, at: t, into: &out)
        case let .close(style): close(style, at: t, into: &out)
        case .retreat: retreat(at: t, into: &out)
        case .resume: resume(at: t, into: &out)
        case let .present(presentation): present(presentation, at: t, into: &out)
        case let .list(change): listChange(change, at: t, into: &out)
        case let .content(layout): content(layout, at: t, into: &out)
        case let .pill(content): pill(content, at: t, into: &out)
        case .show: show(at: t, into: &out)
        case .hide: hide(at: t, into: &out)
        case let .display(metrics): display(metrics, at: t, into: &out)
        case let .reduceMotion(on): reduceMotionChanged(on, at: t, into: &out)
        case let .tuning(tuning): tuningChanged(tuning, at: t, into: &out)
        case let .outline(outline): outlineChanged(outline, into: &out)
        }
        growForLiquid(at: t, into: &out)
        syncBud(into: &out)
        return out
    }

    /// Runs every job due by `t`, in time order.
    mutating func advance(to t: TimeInterval) -> [Command] {
        var out: [Command] = []
        while let index = dueJob(by: t) {
            let job = jobs.remove(at: index)
            version += 1
            run(job.step, at: job.time, into: &out)
        }
        syncBud(into: &out)
        return out
    }

    private func dueJob(by t: TimeInterval) -> Int? {
        var best: Int?
        for (i, job) in jobs.enumerated() where job.time <= t + 1e-9 {
            if let b = best, (jobs[b].time, jobs[b].seq) <= (job.time, job.seq) { continue }
            best = i
        }
        return best
    }

    // MARK: Swell

    private mutating func swell(_ on: Bool, at t: TimeInterval, into out: inout [Command]) {
        guard surface == .closed, !hiding, ordered, !metrics.reduceMotion, swollen != on, targets.closed.height > 0 else { return }
        swollen = on
        let g = restGeometry
        cancel(.shrink)
        if on { growPanel(to: g, curve: tuning.swell, at: t, into: &out) }
        out.append(.target(g, isOpen: false))
        // Liquid, a close still draining into the pill: the swell (or the unswell) takes the body from where it is, its
        // drop and land give way, its corners and belly settle, and the reservoir stays until the body holds it.
        let draining = tuning.liquid && (reservoir != nil || jobs.contains { $0.step == .liquid(.close) })
        if draining {
            jobs.removeAll { [.liquid(.close), .liquid(.narrow), .liquid(.land)].contains($0.step) }
            liquidSettle(at: t, into: &out)
            scheduleShoulders(at: t, into: &out)
            schedulePillGate(at: t)
        }
        if on, tuning.liquid {
            // Liquid: the swell's width with one soft overshoot, at Hover's response; its height as Hover has it.
            set([.left: g.left, .right: g.right, .ear: g.ear], curve: liquidSwell, at: t, into: &out)
            set([.height: g.height, .radius: g.radius, .rimLift: rimLift(g.height)], curve: tuning.swell, at: t, into: &out)
        } else {
            setSurface(g, curve: on ? tuning.swell : IslandMotion.unswell, at: t, into: &out)
        }
        if draining { scheduleDrained(at: t) }
        // The swell keeps its motion margin (an open usually follows); the unswell shrinks the panel once it fits.
        if !on { scheduleFit(at: t) }
    }

    // MARK: Open

    private mutating func open(_ presentation: IslandPresentation, at t: TimeInterval, into out: inout [Command]) {
        // Folding away for Show as Window: nothing opens it again.
        guard !hiding else { return }
        // Already open (a click, or something that needs you, over an island still open): a list ⇄ card on its way plays
        // on, never cut halfway with the row it lifted left in focus under the card (P101); what it shows changes as a
        // present does.
        guard surface != .island else {
            if retreated { resume(at: t, into: &out) }
            present(presentation, at: t, into: &out)
            return
        }
        // The idle pill hid the panel (Hide the pill when idle): something that needs you opens it all the same.
        if !ordered {
            ordered = true
            out.append(.effect(.orderIn))
        }
        // A pill still arriving or departing gives way too; it lands once the pill is out of sight (`settlePill`).
        cancel(.open, .reveal, .fold, .pillIn, .shrink, .card, .list, .gone, .content, .reduced, .show, .arrive, .depart, .swap, .liquid)
        listMove = nil
        arrivalFloor = -.infinity
        revealFloors = [:]
        surface = .island
        swollen = false
        hiding = false
        retreated = false
        turnedBack = []
        afterFit = []
        openedAt = t
        self.presentation = presentation
        mountCard(for: presentation, at: t, into: &out)
        // Motion: Liquid's bud (L2): a card opens on the list, and buds out below it once the open has landed its belly.
        budCard = nil
        budBase = nil
        narrowWaits = false
        if tuning.liquid, case let .card(id) = presentation, budFits(id) {
            budCard = id
            budBase = layout.islandHeight(card: nil)
        }
        // The pill's clock stops now, its glyph held where it is as it fades; the island's starts with its first reveal.
        out.append(.effect(.pillLive(false)))
        let g = restGeometry
        out.append(.target(g, isOpen: true))
        if metrics.reduceMotion {
            set([.pill: 0], curve: IslandMotion.reduced, at: t, into: &out)
            schedule(.reducedOpen, at: t + IslandMotion.reducedOpenSnap, tag: .reduced)
            // A pill change the open cut short lands once the pill has faded, as after an open with motion.
            schedule(.pillSleep, at: t + IslandMotion.reducedSwap, tag: .pillSleep)
            return
        }
        let unfold = targets.topBar ? IslandMotion.unfoldWide : IslandMotion.unfold
        // Back while it folds: the body is still dropping toward the pill, so the height turns at once (no lead), and
        // parts it already covers flip from now.
        let reversing = value(.height, at: t) > Double(targets.swell(tuning).height) + 1
        growPanel(to: g, curve: unfold, at: t, into: &out)
        if tuning.splitsSurface {
            // F5: the width on its own spring, the ear with the shoulders; the height starts with it below, on its own.
            set([.left: g.left, .right: g.right, .ear: g.ear], curve: splitCurves.width, at: t, into: &out)
        } else {
            set([.left: g.left, .right: g.right], curve: unfold, at: t, into: &out)
        }
        scheduleShoulders(at: t, into: &out)
        set([.pill: 0], curve: IslandMotion.focusOut, at: t, into: &out)
        // Coming back while it folds: what is still visible re-aims from where it is, the rest waits for the edge.
        var reAim: [Channel: Double] = [:]
        for channel in [Channel.header] + presentedParts.map(Channel.part) where value(channel, at: t) > IslandMotion.shown { reAim[channel] = 1 }
        if !reAim.isEmpty { set(reAim, curve: tuning.focusIn, at: t, into: &out) }
        schedule(.pillSleep, at: t + 0.17, tag: .pillSleep)
        // An open to a card in its bud leads with the bud, not the belly (the two never draw at once).
        if tuning.liquid { liquidOpen(belly: !budding, at: t, into: &out) }
        if budding {
            // A bud a close was taking in goes on from where it is once the island has opened on the list.
            cancel(.bud)
            schedule(.liquid(.budSeed), at: t + LiquidMotion.openBudAt, tag: .bud)
        }
        if reAim[.header] == nil { schedule(.header, at: t + tuning.headerIn, tag: .open) }
        if reversing {
            run(.openHeight(trigger: t - tuning.rowFloor), at: t, into: &out)
        } else if tuning.splitsSurface {
            // No lead: the height starts now, on its own spring, so no job waits to run late.
            run(.openHeight(trigger: t), at: t, into: &out)
        } else {
            schedule(.openHeight(trigger: t), at: t + IslandMotion.lead, tag: .open)
        }
    }

    /// The open's two springs (F5), the top bar's for its longer travel.
    private var splitCurves: (width: IslandMotion.Curve, height: IslandMotion.Curve) {
        targets.topBar ? (IslandMotion.splitWidthWide, IslandMotion.splitHeightWide) : (IslandMotion.splitWidth, IslandMotion.splitHeight)
    }

    /// The parts the current presentation shows, top to bottom.
    var presentedParts: [PartID] {
        if budding { return layout.listParts }
        if case .card = presentation { return cardMounted == nil ? [] : [.cardHeader, .cardBody] }
        return layout.listParts
    }

    /// Motion: Liquid's bud (L2): the card's parts, which its bud brings in (not the list's reveals).
    var budParts: [PartID] { budding && cardMounted != nil ? [.cardHeader, .cardBody] : [] }

    /// The card layer takes `presentation`'s card; a card it held that still shows fades out in the leaving layer.
    private mutating func mountCard(for presentation: IslandPresentation, at t: TimeInterval, into out: inout [Command]) {
        let wanted: String? = if case let .card(id) = presentation { id } else { nil }
        guard wanted != cardMounted else { return }
        if let old = cardMounted, wanted != nil { leave(old, at: t, into: &out) }
        cardMounted = wanted
        if wanted != nil { snap([.part(.cardHeader): 0, .part(.cardBody): 0], into: &out) }
        out.append(.effect(.cardSnapshot(wanted)))
    }

    /// Every part the presentation shows that is not already on its way in comes into focus: the first at
    /// `trigger + rowFloor`, each further one when the dropping edge is `edgeDepth` into it, at least `minStep` after
    /// the one before and, with a cap (Motion: Original), no later than `revealCap` after the first (`MotionTuning`).
    /// With none (Refined) the wave follows the edge from the first part to the last: the first waits for its edge too,
    /// `rowFloor` its floor (a short island's edge reaches its one row as late as 100 ms), and one the edge never
    /// reaches comes in at the cap's time, as it did with one. Solved from the height's spring as it is now, and solved
    /// again whenever the height retargets. `edgeSynced`: the first one waits for the edge too (the open's first part
    /// is already due).
    private mutating func scheduleReveals(trigger: TimeInterval, at t: TimeInterval, parts: [PartID]? = nil,
                                          edgeSynced: Bool = false) {
        if planning { return }
        cancel(.reveal)
        let pending = (parts ?? presentedParts).filter { target(.part($0)) < 1 }
        let first = max(t, trigger + tuning.rowFloor)
        let latest = first + (tuning.revealCap ?? IslandMotion.cap)
        var previous: TimeInterval? = edgeSynced ? -.infinity : nil
        for part in pending {
            var flip = first
            if let previous {
                let edge = max(previous + IslandMotion.minStep, edgeTime(part, from: t) ?? latest)
                flip = max(t, tuning.revealCap == nil ? edge : min(edge, latest))
            } else if tuning.revealCap == nil, let edge = edgeTime(part, from: t) {
                flip = max(first, edge)
            }
            if let floor = revealFloors[part] { flip = max(flip, floor) }
            schedule(.reveal(part), at: flip, tag: .reveal)
            previous = flip
        }
    }

    /// The reveals still to come, and `extra` parts, solved again from the height's spring as it is now; once the open's
    /// first part is due, each of them waits for the edge.
    private mutating func resolveReveals(adding extra: [PartID] = [], at t: TimeInterval) {
        let waiting = Set(jobs.compactMap { job -> PartID? in
            guard job.tag == .reveal, case let .reveal(part) = job.step else { return nil }
            return part
        } + extra)
        guard !waiting.isEmpty else { return }
        scheduleReveals(trigger: openedAt, at: t, parts: presentedParts.filter(waiting.contains),
                        edgeSynced: t >= openedAt + tuning.rowFloor)
    }

    /// When the surface's bottom edge is `edgeDepth` into `part` for good, from `t`: an open that reverses a fold keeps
    /// the fold's speed and dips a little further before it turns, so a part whose line the edge is past as it turns is
    /// covered again for a moment, and came in under the edge (round C, P303). Nil when not within `horizon`.
    private func edgeTime(_ part: PartID, from t: TimeInterval) -> TimeInterval? {
        guard let rect = layout.parts[part], let height = values[.height] else { return nil }
        let line = Double(rect.minY + IslandMotion.edgeDepth * rect.height)
        var s = t, last: TimeInterval?, reached = false
        while s <= t + IslandMotion.horizon {
            if height.value(at: s) >= line { reached = true } else { last = s }
            s += 0.001
        }
        guard reached else { return nil }
        guard let last else { return t }
        return last + 0.001 <= t + IslandMotion.horizon ? last + 0.001 : nil
    }

    // MARK: Close

    private mutating func close(_ style: IslandHoverMachine.CloseStyle, at t: TimeInterval, into out: inout [Command]) {
        guard surface == .island else {
            if swollen { swell(false, at: t, into: &out) }
            return
        }
        cancel(.open, .reveal, .fold, .pillIn, .pillSleep, .shrink, .card, .list, .gone, .content, .reduced, .swap, .liquid, .bud)
        listMove = nil
        narrowWaits = false
        let budShows = tuning.liquid && liquid(at: t).budShows
        surface = .closed
        swollen = false
        let g = restGeometry
        out.append(.target(g, isOpen: false))
        // The island's clock stops as its content starts to leave, the glyphs held where they are as they fade.
        islandClock(false, into: &out)
        afterFit = [.reset]
        // Nothing left to show and the idle pill hides (a departure the open cut short): it goes once folded.
        if targets.pill.isEmpty, targets.hideWhenIdle { afterFit.insert(.orderOut) }
        var leaving: [Channel: Double] = [.header: 0]
        for channel in values.keys {
            if case .part = channel, target(channel) > 0 || value(channel, at: t) > 0.001 { leaving[channel] = 0 }
        }
        if metrics.reduceMotion {
            set(leaving, curve: IslandMotion.reduced, at: t, into: &out)
            schedule(.reducedClose, at: t + IslandMotion.reducedSwap, tag: .reduced)
            if budShows { schedule(.liquid(.budGone), at: t + IslandMotion.reducedSwap, tag: .bud) }
            retreated = false
            return
        }
        set(leaving, curve: IslandMotion.focusOut, at: t, into: &out)
        // Motion: Liquid's bud (L2): the card's bud contracts to a bead and rises into the body as it folds.
        if budShows { budClose(at: t, into: &out) }
        if style == .abort {
            // A flick: straight back from where it is, keeping its outward speed, with no lag.
            setSurface(g, curve: targets.topBar ? IslandMotion.abortWide : IslandMotion.abort, at: t, into: &out)
            if tuning.liquid { liquidSettle(at: t, into: &out) }
            scheduleShoulders(at: t, into: &out)
            schedulePillGate(at: t)
            scheduleFit(at: t)
        } else {
            let fold = targets.topBar ? tuning.foldWide : tuning.fold
            // After a retreat the content is already leaving: no lag.
            let lag = retreated ? 0 : tuning.foldLag
            if tuning.liquid, !targets.topBar {
                liquidClose(at: t, lag: lag, into: &out)
            } else {
                schedule(.foldHeight(fold), at: t + lag, tag: .fold)
                schedule(.foldWidth(fold), at: t + lag + tuning.foldWidthAfter, tag: .fold)
                // The no-notch bar is its own reservoir: Refined's close, the belly and the corners settling.
                if tuning.liquid { liquidSettle(at: t, into: &out) }
            }
        }
        retreated = false
    }

    /// The pill's glyph and count come back once the folding shape is close to the pill (`MotionTuning.pillGate`),
    /// solved from the springs as they are now.
    private mutating func schedulePillGate(at t: TimeInterval) {
        if planning { return }
        cancel(.pillIn)
        let closed = restGeometry, gate = tuning.pillGate
        let when = firstTime(from: t) { model, s in
            let g = model.surface(at: s)
            return g.width < closed.width + gate.width && g.height < closed.height + gate.height
        } ?? t + IslandMotion.horizon
        schedule(.pillIn, at: when, tag: .pillIn)
    }

    /// Core Animation's outline: the header's brand glyph and gear show as the widening surface passes them and go as
    /// it narrows past them (`SurfaceTargets.shoulderGate`, as SwiftUI's outline shows them from its width in each
    /// frame, `ShoulderGate`). Solved from the width's springs as they are now, when the width retargets: the gate turns at
    /// the first crossing of its near bound, on a critically damped curve 90 % there as the width crosses the far one, a
    /// job on the strict timer (a late one shows them a moment late, masked, never early and cut by the walls).
    private mutating func scheduleShoulders(at t: TimeInterval, into out: inout [Command]) {
        guard metrics.outline == .coreAnimation, !planning else { return }
        let gate = targets.shoulderGate
        let opening = target(.left) + target(.right) >= Double(gate.upperBound)
        let shown: Double = opening ? 1 : 0
        let pending = jobs.contains { $0.tag == .shoulders }
        guard pending || abs(target(.shoulders) - shown) > 1e-9 else { return }
        cancel(.shoulders)
        guard abs(target(.shoulders) - shown) > 1e-9 else { return }
        let (near, far) = opening ? (Double(gate.lowerBound), Double(gate.upperBound)) : (Double(gate.upperBound), Double(gate.lowerBound))
        func crossed(_ line: Double) -> (IslandChoreography, TimeInterval) -> Bool {
            { model, s in
                let width = model.value(.left, at: s) + model.value(.right, at: s)
                return opening ? width >= line : width <= line
            }
        }
        let start = firstTime(from: t, where: crossed(near)) ?? t
        let end = firstTime(from: start, where: crossed(far)) ?? start + IslandMotion.shouldersSpan
        // A critically damped spring is 90 % there 0.619 of its response in.
        let curve = IslandMotion.Curve(response: min(max((end - start) / 0.619, 0.06), 0.30), dampingFraction: 1)
        if start <= t + 1e-9 {
            set([.shoulders: shown], curve: curve, at: t, into: &out)
        } else {
            schedule(.shoulders(shown, curve), at: start, tag: .shoulders)
        }
    }

    /// Diagnostics › Motion › Outline: Core Animation's takes the shoulder gate from here, at the rest of the current
    /// state; SwiftUI's reads its width and has no gate channel.
    private mutating func outlineChanged(_ outline: IslandOutline, into out: inout [Command]) {
        guard metrics.outline != outline else { return }
        metrics.outline = outline
        cancel(.shoulders)
        if outline == .coreAnimation {
            let width = target(.left) + target(.right)
            snap([.shoulders: width >= Double(targets.shoulderGate.upperBound) ? 1 : 0], into: &out)
        } else {
            forget([.shoulders], into: &out)
        }
    }

    private mutating func retreat(at t: TimeInterval, into out: inout [Command]) {
        guard surface == .island else { return }
        cancel(.reveal)
        retreated = true
        var back: [Channel: Double] = [:]
        for channel in [Channel.header] + presentedParts.map(Channel.part) where value(channel, at: t) < 0.5 {
            back[channel] = 0
        }
        turnedBack = Set(back.keys)
        if !back.isEmpty { set(back, curve: IslandMotion.focusOut, at: t, into: &out) }
    }

    private mutating func resume(at t: TimeInterval, into out: inout [Command]) {
        guard surface == .island, retreated else { return }
        retreated = false
        if turnedBack.contains(.header) { set([.header: 1], curve: tuning.focusIn, at: t, into: &out) }
        turnedBack = []
        scheduleReveals(trigger: t - tuning.rowFloor, at: t)
        scheduleFit(at: t)
    }

    // MARK: List ⇄ card

    private mutating func present(_ new: IslandPresentation, at t: TimeInterval, into out: inout [Command]) {
        guard new != presentation else { return }
        guard surface == .island else {
            presentation = new
            return
        }
        switch (presentation, new) {
        case (.list, let .card(id)): toCard(id, at: t, into: &out)
        case let (.card(id), .list): toList(from: id, at: t, into: &out)
        case (.card, let .card(id)):
            // Another session's card: swap it through the list at once; the one showing fades out where it is, in the
            // leaving layer, as the new one comes in (never cut out in one frame, P133).
            presentation = .list
            toCard(id, at: t, into: &out)
        default: break
        }
    }

    private mutating func toCard(_ id: String, at t: TimeInterval, into out: inout [Command]) {
        // Motion: Liquid (L2): the card buds out below the list, when the display has room for it.
        if tuning.liquid, budFits(id) { return budOut(id, at: t, into: &out) }
        // A card that leaves a bud for the body (no room for the new one): the bud goes at once.
        if budCard != nil { dropBud(at: t, into: &out) }
        cancel(.reveal, .card, .list, .gone, .content, .reduced)
        homeOtherRows(except: id, at: t, into: &out)
        presentation = .card(sessionID: id)
        mountCard(for: presentation, at: t, into: &out)
        let row = PartID.row(id)
        var leaving: [Channel: Double] = [:]
        for part in layout.listParts where part != row { leaving[.part(part)] = 0 }
        if metrics.reduceMotion {
            leaving[.part(row)] = 0
            set(leaving, curve: IslandMotion.reduced, at: t, into: &out)
            schedule(.reducedHeight, at: t + IslandMotion.reducedSwap, tag: .reduced)
            return
        }
        // Only a row that shows lifts into the header's place. Another card's (the list hidden under it) or one the list
        // does not show leaves with the rest, and the header comes in where it is.
        let lifts = layout.parts[row] != nil && value(.part(row), at: t) > IslandMotion.shown
        if !lifts, values[.part(row)] != nil { leaving[.part(row)] = 0 }
        set(leaving, curve: IslandMotion.focusOut, at: t, into: &out)
        if lifts, let rect = layout.parts[row] {
            let delta = Double(layout.cardHeaderTop - (rect.minY + layout.rowInset))
            // Back before it got home, it rises from where it is.
            let glide = value(.glide(id), at: t)
            let glides = abs(delta - glide) >= Double(tuning.glideThreshold)
            if glides {
                // The card body hangs from the gliding row: it starts where the row is, drawn once there before the glide
                // (a body still showing, back before it left, stays where it is).
                if value(.part(.cardBody), at: t) <= IslandMotion.shown { snap([.cardRide: glide - delta], into: &out) }
                schedule(.glideStart(id, delta), at: t + IslandMotion.frameAhead, tag: .card)
            } else {
                // Already in the header's place (its home there, or back before it left it).
                schedule(.cross(id), at: t + IslandMotion.crossWithoutGlide, tag: .card)
            }
            // Out of focus after the cross, it goes home.
            if (glides ? delta : glide) != 0 { schedule(.glideReset(id), at: t + IslandMotion.goneAfter, tag: .gone) }
        } else {
            schedule(.cross(nil), at: t + IslandMotion.crossWithoutGlide, tag: .card)
        }
        retargetHeight(at: t, into: &out)
        // Motion: Refined. The body comes in from the tap, overlapping the rows' exit, once the edge has passed most of
        // it where it is drawn (`gateCardBody`, solved again as the ride, the height or the card's measure changes).
        if let lead = tuning.cardBodyFromTap {
            cardBodyFrom = t + lead
            schedule(.reveal(.cardBody), at: t + lead, tag: .card)
            gateCardBody(at: t)
        }
    }

    /// Motion: Refined. When the card body a present brought comes in, solved from `t`: `cardBodyFrom` at the earliest,
    /// and once the bottom edge has passed all but `edgeDepth` of it where it is drawn (`cardBodyClears`): under a row
    /// that still glides up to the header's place the body hangs below its home (`cardRide`), and a card taller than
    /// the list waits for the height that grows to it. Gated on its home alone, it came in 40 ms after the tap half-way
    /// into focus while the edge cut through it. A card not yet measured (built at its present, or taking the place of
    /// another whose measure the layout still holds) waits for its measure, which comes a turn later, and a body whose
    /// row has not started to glide waits for the glide; should neither come, it comes in once the rows it replaces are
    /// gone (`goneAfter`). Solved again as the glide starts, the height retargets or the card is measured.
    private mutating func gateCardBody(at t: TimeInterval) {
        guard !planning, tuning.cardBodyFromTap != nil, case let .card(id) = presentation,
              let i = jobs.firstIndex(where: { $0.tag == .card && $0.step == .reveal(.cardBody) }) else { return }
        let waiting = cardBodyFrom + IslandMotion.goneAfter
        let when: TimeInterval
        if layout.cardID != id || jobs.contains(where: { if case .glideStart = $0.step { true } else { false } }) {
            when = waiting
        } else if layout.parts[.cardBody] == nil {
            // Its header alone: nothing to wait for.
            when = cardBodyFrom
        } else {
            when = cardBodyClears(from: t).map { max(cardBodyFrom, $0) } ?? waiting
        }
        jobs[i].time = max(t, when)
    }

    /// The first moment from `t` at which the card body, drawn in full focus (the lowest it is drawn: out of focus it
    /// drifts up) at its home plus its ride, has the bottom edge past all but `edgeDepth` of it; nil when not within
    /// `horizon`. From then on it stays past: the ride only rises, and the edge only grows toward a card (a shorter one
    /// folds to no less than the card's own height).
    private func cardBodyClears(from t: TimeInterval) -> TimeInterval? {
        guard let rect = layout.parts[.cardBody] else { return nil }
        let line = Double(rect.maxY - IslandMotion.edgeDepth * rect.height)
        return firstTime(from: t) { model, s in model.value(.height, at: s) >= line + model.value(.cardRide, at: s) }
    }

    private mutating func toList(from id: String, at t: TimeInterval, into out: inout [Command]) {
        // Motion: Liquid (L2): the card in its bud merges back into the island.
        if budCard == id { return budMerge(at: t, into: &out) }
        cancel(.reveal, .card, .list, .gone, .content, .reduced)
        homeOtherRows(except: id, at: t, into: &out)
        presentation = .list
        let leaving: [Channel: Double] = [.part(.cardHeader): 0, .part(.cardBody): 0]
        if metrics.reduceMotion {
            set(leaving, curve: IslandMotion.reduced, at: t, into: &out)
            schedule(.reducedHeight, at: t + IslandMotion.reducedSwap, tag: .reduced)
            schedule(.cardGone, at: t + IslandMotion.goneAfter, tag: .gone)
            return
        }
        set(leaving, curve: IslandMotion.focusOut, at: t, into: &out)
        let row = PartID.row(id)
        if let rect = layout.parts[row] {
            if value(.part(row), at: t) > IslandMotion.shown {
                // Back before the row had crossed: it glides home from where it is, never jumping to the header's place.
                set([.part(row): 1], curve: tuning.focusIn, at: t, into: &out)
                run(.glideHome(id, trigger: t), at: t, into: &out)
            } else {
                // The row appears where the card's header was, in a crossfade with it, then glides home.
                let delta = Double(layout.cardHeaderTop - (rect.minY + layout.rowInset))
                snap([.glide(id): delta], into: &out)
                set([.part(row): 1], curve: tuning.focusIn, at: t, into: &out)
                schedule(.glideHome(id, trigger: t), at: t + IslandMotion.glideBack, tag: .list)
            }
        } else {
            schedule(.contentHeight, at: t + IslandMotion.glideBack, tag: .content)
            schedule(.listIn(trigger: t), at: t + IslandMotion.glideBack, tag: .list)
        }
        schedule(.cardGone, at: t + IslandMotion.goneAfter, tag: .gone)
    }

    /// A card gives way to another (card → card, or a card still fading when another comes): it moves to the leaving
    /// layer at the focus it has and fades out there (`focusOut`, or `reduced`), while the new card's header crosses in
    /// 40 ms later, so the two blend for a moment and the swap is never a cut. A card still leaving from an earlier swap
    /// goes at once; one that had not come in yet has nothing to fade (P133).
    private mutating func leave(_ id: String, at t: TimeInterval, into out: inout [Command]) {
        let header = value(.part(.cardHeader), at: t), body = value(.part(.cardBody), at: t)
        dropLeaving(into: &out)
        guard cardMounted == id, max(header, body) > IslandMotion.shown else { return }
        cardLeaving = id
        snap([.part(.leavingHeader): header, .part(.leavingBody): body], into: &out)
        out.append(.effect(.cardLeaving(id)))
        set([.part(.leavingHeader): 0, .part(.leavingBody): 0],
            curve: metrics.reduceMotion ? IslandMotion.reduced : IslandMotion.focusOut, at: t, into: &out)
        schedule(.leavingGone, at: t + IslandMotion.goneAfter, tag: .leave)
    }

    /// The leaving layer goes, and its channels with it, in the views too.
    private mutating func dropLeaving(into out: inout [Command]) {
        cancel(.leave)
        guard cardLeaving != nil else { return }
        cardLeaving = nil
        forget([.part(.leavingHeader), .part(.leavingBody)], into: &out)
        out.append(.effect(.cardLeaving(nil)))
    }

    /// Another row still out of its place (the card or the list it lifted for was cut short, its reset with it) goes
    /// home: at once while out of focus, on the glide's curve while it shows (P101).
    private mutating func homeOtherRows(except id: String, at t: TimeInterval, into out: inout [Command]) {
        var away: [Channel] = [], showing: [Channel: Double] = [:]
        for channel in values.keys {
            guard case let .glide(other) = channel, other != id, target(channel) != 0 || value(channel, at: t) != 0 else { continue }
            if value(.part(.row(other)), at: t) > IslandMotion.shown { showing[channel] = 0 } else { away.append(channel) }
        }
        forget(away, into: &out)
        set(showing, curve: metrics.reduceMotion ? nil : IslandMotion.glide, at: t, into: &out)
    }

    /// Where the card's row is (its home slot plus its glide) at `s`.
    private func rowSpan(_ id: String, at s: TimeInterval) -> ClosedRange<CGFloat>? {
        guard let rect = layout.parts[.row(id)] else { return nil }
        let y = rect.minY + CGFloat(value(.glide(id), at: s))
        return y...(y + rect.height)
    }

    // MARK: Content

    private mutating func content(_ new: ContentLayout, at t: TimeInterval, into out: inout [Command]) {
        let old = metrics.layout
        metrics.layout = new
        // Parts that went away take their channels with them, in the views too: one that comes back (a row the list sorts
        // out and back, the usage block, the footer) starts out of focus, never at the focus it left with (P101). One
        // still in sight while the island is open fades out instead (E6): its view may still be drawn, leaving on its
        // transition or folding away (the footer Show all took, the usage block folded, a row the list let go), and a
        // snap would cut it in one frame. It is forgotten once out of sight, when the content next changes.
        let gone = values.keys.filter { if case let .part(part) = $0 { !part.isCard && new.parts[part] == nil } else { false } }
        var fading: [Channel: Double] = [:], dropped: [Channel] = []
        for channel in gone {
            if surface == .island, value(channel, at: t) > IslandMotion.shown {
                if target(channel) > 0 { fading[channel] = 0 }
            } else {
                dropped.append(channel)
            }
        }
        jobs.removeAll { if case let .reveal(part) = $0.step { gone.contains(.part(part)) } else { false } }
        forget(dropped, into: &out)
        set(fading, curve: metrics.reduceMotion ? IslandMotion.reduced : IslandMotion.focusOut, at: t, into: &out)
        guard surface == .island else { return }
        // Parts that arrived while open come into focus as the edge reaches them, solved with the reveals still to come
        // (and again if the height retargets). A card's header and body never arrive: a card is measured only once it
        // has mounted, and the cross brings them in. After a retreat the resume brings them in with the rest.
        var arrived = presentedParts.filter { !$0.isCard && old.parts[$0] == nil && target(.part($0)) < 1 }
        // A row Show all builds as the list scrolls to it is there at once: the list moved, nothing new came (P400).
        let scrolledIn = arrived.filter { if case let .row(id) = $0 { new.lazyRows.contains(id) } else { false } }
        if !scrolledIn.isEmpty {
            arrived.removeAll { scrolledIn.contains($0) }
            snap(Dictionary(uniqueKeysWithValues: scrolledIn.map { (Channel.part($0), 1.0) }), into: &out)
        }
        // A list change's parts wait for what it moves out of their way (E6).
        if arrivalFloor > t { for part in arrived { revealFloors[part] = arrivalFloor } }
        if !arrived.isEmpty, !retreated, !jobs.contains(where: { $0.step == .openHeight(trigger: openedAt) }) {
            if metrics.reduceMotion {
                set(Dictionary(uniqueKeysWithValues: arrived.map { (Channel.part($0), 1.0) }), curve: IslandMotion.reduced, at: t, into: &out)
            } else {
                resolveReveals(adding: arrived, at: t)
            }
        }
        retargetHeight(at: t, into: &out)
        // The card measured: its body (Refined) now knows where it is.
        gateCardBody(at: t)
        // Motion: Liquid's bud (L2): the card measured in its bud, which takes its height.
        budMeasured(at: t, into: &out)
    }

    /// The island's height follows its content: a taller one unfolds now (the panel grows first), a shorter one folds
    /// `shrinkLag` after its parts start to leave.
    private mutating func retargetHeight(at t: TimeInterval, into out: inout [Command]) {
        guard surface == .island, !jobs.contains(where: { if case .openHeight = $0.step { true } else { false } }) else { return }
        let g = restGeometry
        guard abs(Double(g.height) - target(.height)) >= 0.5 else { return }
        // The content of a list change written moments ago (E6): its rows already move on the change's curve, from then.
        let move = listMove.flatMap { t - $0.at <= IslandMotion.listWindow ? $0 : nil }
        listMove = nil
        if metrics.reduceMotion {
            // A list change's leaving part has already faded: its height snaps with it.
            let lag = Double(g.height) > target(.height) || move != nil ? 0 : IslandMotion.reducedSwap
            schedule(.reducedHeight, at: t + lag, tag: .reduced)
            return
        }
        if Double(g.height) > target(.height) {
            // Only a shorter height still waiting gives way; every reveal stays, solved again below.
            jobs.removeAll { $0.step == .contentHeight }
            let unfold = targets.topBar ? IslandMotion.unfoldWide : IslandMotion.unfold
            growPanel(to: g, curve: unfold, at: t, into: &out)
            set([.height: g.height, .ear: g.ear, .radius: g.radius, .rimLift: rimLift(g.height)], curve: unfold, at: t, into: &out)
            out.append(.target(g, isOpen: true))
            resolveReveals(at: t)
            // A card body still to come (its card measured after the cross) waits for the edge that now drops to it;
            // under Refined, for the edge to pass most of it where it is drawn.
            if tuning.cardBodyFromTap != nil {
                gateCardBody(at: t)
            } else {
                for i in jobs.indices where jobs[i].step == .reveal(.cardBody) {
                    jobs[i].time = max(jobs[i].time, edgeTime(.cardBody, from: t) ?? jobs[i].time)
                }
            }
            scheduleFit(at: t)
        } else if let move, !move.grows {
            // The usage block folded: it faded before the rows moved up, so the edge folds with them, at once.
            jobs.removeAll { $0.step == .contentHeight }
            run(.contentHeight, at: t, into: &out)
        } else if !jobs.contains(where: { $0.step == .contentHeight }) {
            schedule(.contentHeight, at: t + IslandMotion.shrinkLag, tag: .content)
        }
    }

    // MARK: Show all and the usage strip

    /// Show all, or the strip clicked open or folded (E6). What leaves with the change (the footer, the usage block)
    /// fades out first, as a part leaves on a close, and the change is written once it is down to `swapFocus` (99 ms
    /// on `focusOut`), on the curve the edge then follows: the rows it moves and the edge move as one, and what arrives
    /// with it waits for what it moves out of the way (`listSwap`). With nothing in sight to leave, it is written at
    /// once. Clicked back before a fold is written, the block comes back into focus where it is and nothing changes.
    private mutating func listChange(_ change: ListChange, at t: TimeInterval, into out: inout [Command]) {
        guard !jobs.contains(where: { $0.step == .listSwap(change) }) else { return }
        let reduce = metrics.reduceMotion
        if case let .strip(open) = change, let back = jobs.firstIndex(where: { $0.step == .listSwap(.strip(!open)) }) {
            // Only a fold waits (an unfold has nothing to fade first): the block comes back.
            jobs.remove(at: back)
            if open, surface == .island { set([.part(.usage): 1], curve: reduce ? IslandMotion.reduced : tuning.focusIn, at: t, into: &out) }
            return
        }
        guard surface == .island, let part = change.leaving, presentation == .list,
              value(.part(part), at: t) > IslandMotion.shown || target(.part(part)) > 0 else {
            run(.listSwap(change), at: t, into: &out)
            return
        }
        jobs.removeAll { $0.step == .reveal(part) }
        set([.part(part): 0], curve: reduce ? IslandMotion.reduced : IslandMotion.focusOut, at: t, into: &out)
        let fade = values[.part(part)]
        let swap = fade.flatMap { v in firstTime(from: t) { _, s in v.value(at: s) <= IslandMotion.swapFocus } } ?? t
        schedule(.listSwap(change), at: swap, tag: .swap)
    }

    /// The strip as it will be once a change still waiting is written (nil: none waits): a click toggles that.
    var stripAfterSwap: Bool? {
        jobs.last { if case .listSwap(.strip) = $0.step { true } else { false } }.flatMap {
            if case let .listSwap(.strip(open)) = $0.step { open } else { nil }
        }
    }

    /// The list change written, on the curve the height takes for it (none under Reduce Motion, or closed).
    private mutating func swap(_ change: ListChange, at t: TimeInterval, into out: inout [Command]) {
        guard surface == .island, !metrics.reduceMotion else {
            if surface == .island { listMove = ListMove(curve: IslandMotion.reduced, at: t, grows: change.grows) }
            out.append(.effect(.list(change, nil)))
            return
        }
        let curve = change.grows ? (targets.topBar ? IslandMotion.unfoldWide : IslandMotion.unfold)
            : (targets.topBar ? IslandMotion.foldWide : IslandMotion.fold)
        listMove = ListMove(curve: curve, at: t, grows: change.grows)
        switch change {
        case .showAll:
            // The new rows come in once the footer they take the place of is out of sight.
            let footer = values[.part(.footer)]
            arrivalFloor = footer.flatMap { v in firstTime(from: t) { _, s in v.value(at: s) <= IslandMotion.shown } } ?? t
        case .strip(true):
            // The block comes in once the rows it pushes down have cleared all but the edge's depth of it: they slide
            // over it, where an edge would hide what it has not reached.
            let rows = ShadowValue(from: 0, velocity: 0, target: 1, start: t, curve: curve)
            arrivalFloor = firstTime(from: t) { _, s in rows.value(at: s) >= Double(1 - IslandMotion.edgeDepth) } ?? t
        case .strip(false):
            arrivalFloor = -.infinity
        }
        out.append(.effect(.list(change, curve)))
    }

    // MARK: The pill

    private mutating func pill(_ new: PillContent, at t: TimeInterval, into out: inout [Command]) {
        let old = metrics.targets.pill
        metrics.targets.pill = new
        guard old != new || shownPill != new else { return }
        // Motion: Liquid. A close draining into the pill drains into the new one.
        if reservoir != nil, surface == .closed, !hiding {
            reservoir = targets.closed
            if jobs.contains(where: { [.liquid(.close), .liquid(.narrow), .liquid(.land)].contains($0.step) }) {
                shownPill = new
                out.append(.pillSnapshot(new, nil))
                return
            }
        }
        guard surface == .closed, !hiding else {
            // Open (or hiding): the pill waits, hidden; its new size is the close's target.
            shownPill = new
            out.append(.pillSnapshot(new, nil))
            return
        }
        let g = restGeometry
        let wasEmpty = shownPill.isEmpty
        let reduce = metrics.reduceMotion
        if targets.topBar, !targets.hideWhenIdle, wasEmpty != new.isEmpty {
            // No notch: the bar never goes. It resizes while the brand glyph and the lead crossfade (out, then in); a bar
            // still to drop from the sliver drops to the new size.
            cancel(.arrive, .depart, .shrink)
            out.append(.target(g, isOpen: false))
            set([.pillArrive: 0], curve: reduce ? IslandMotion.reduced : IslandMotion.focusOut, at: t, into: &out)
            if !reduce, !jobs.contains(where: { $0.step == .drop }) {
                growPanel(to: g, curve: IslandMotion.resize, at: t, into: &out)
                setSurface(g, curve: IslandMotion.resize, at: t, into: &out)
                scheduleFit(at: t)
            }
            schedule(.barSwap, at: t + (reduce ? IslandMotion.reducedSwap : IslandMotion.departLag), tag: .arrive)
        } else if wasEmpty && !new.isEmpty {
            // A first session: the wings slide out from behind the notch, the glyph and count after them.
            cancel(.arrive, .depart, .shrink)
            if !ordered {
                ordered = true
                out.append(.effect(.orderIn))
            }
            shownPill = new
            out.append(.pillSnapshot(new, nil))
            if value(.pillArrive, at: t) > 0.5 || target(.pillArrive) > 0.5 { snap([.pillArrive: 0], into: &out) }
            out.append(.target(g, isOpen: false))
            if reduce {
                snapSurface(g, at: t, into: &out)
                exactPanel(into: &out)
                set([.pillArrive: 1], curve: IslandMotion.reduced, at: t, into: &out)
                return
            }
            growPanel(to: g, curve: IslandMotion.emerge, at: t, into: &out)
            setSurface(g, curve: IslandMotion.emerge, at: t, into: &out)
            schedule(.arriveContent, at: t + IslandMotion.arriveContent, tag: .arrive)
            scheduleFit(at: t)
        } else if !wasEmpty && new.isEmpty {
            // The last session: the glyph and count slide back behind the notch, then the wings tuck.
            cancel(.arrive, .depart, .shrink)
            out.append(.target(g, isOpen: false))
            if metrics.targets.hideWhenIdle { afterFit.insert(.orderOut) }
            if reduce {
                set([.pillArrive: 0], curve: IslandMotion.reduced, at: t, into: &out)
                schedule(.reducedDepart, at: t + IslandMotion.reducedSwap, tag: .depart)
                return
            }
            set([.pillArrive: 0], curve: IslandMotion.focusOut, at: t, into: &out)
            schedule(.tuck(IslandMotion.tuck), at: t + IslandMotion.departLag, tag: .depart)
            schedule(.departSnapshot, at: t + 0.17, tag: .depart)
        } else {
            shownPill = new
            let from = surface(at: t)
            guard abs(from.left - g.left) >= 0.01 || abs(from.right - g.right) >= 0.01 || abs(from.height - g.height) >= 0.01
                || abs(target(.left) - Double(g.left)) >= 0.01 || abs(target(.right) - Double(g.right)) >= 0.01 else {
                // The same size: a new lead or count in place, still, or (`MotionTuning.pillFocus`) on the pill's own
                // curve, so the lead's focus pull and the count's roll play.
                out.append(.pillSnapshot(new, tuning.pillFocus && !reduce ? IslandMotion.pillIn : nil))
                return
            }
            out.append(.target(g, isOpen: false))
            if reduce {
                out.append(.pillSnapshot(new, nil))
                snapSurface(g, at: t, into: &out)
                exactPanel(into: &out)
                return
            }
            // The count grew or shrank, a dot came or went: the pill and its content resize together.
            cancel(.shrink)
            growPanel(to: g, curve: IslandMotion.resize, at: t, into: &out)
            out.append(.pillSnapshot(new, IslandMotion.resize))
            setSurface(g, curve: IslandMotion.resize, at: t, into: &out)
            scheduleFit(at: t)
        }
    }

    // MARK: Window ⇄ island

    private mutating func show(at t: TimeInterval, into out: inout [Command]) {
        hiding = false
        guard !ordered else { return }
        if targets.pill.isEmpty && targets.hideWhenIdle { return }
        ordered = true
        guard targets.topBar, surface == .closed, !metrics.reduceMotion else {
            out.append(.effect(.orderIn))
            return
        }
        // No notch: the bar drops from the sliver at the top edge (drawn there once before it moves), its content after
        // it. Under a notch the idle surface is the notch itself, and the pill arrives from behind it.
        snapSurface(targets.sliver, at: t, into: &out)
        snap([.pillArrive: 0], into: &out)
        out.append(.effect(.orderIn))
        schedule(.drop, at: t + IslandMotion.frameAhead, tag: .show)
    }

    private mutating func hide(at t: TimeInterval, into out: inout [Command]) {
        cancel(.open, .reveal, .fold, .pillIn, .pillSleep, .shrink, .card, .list, .gone, .content, .reduced, .arrive, .depart, .show, .swap, .liquid)
        listMove = nil
        let wasOpen = surface == .island
        liquidRetire(at: t, into: &out)
        budCard = nil
        budBase = nil
        surface = .closed
        swollen = false
        hiding = true
        let g = restGeometry
        out.append(.target(g, isOpen: false))
        islandClock(false, into: &out)
        afterFit = [.reset, .orderOut]
        var leaving: [Channel: Double] = [.header: 0, .pillArrive: 0]
        for channel in values.keys { if case .part = channel { leaving[channel] = 0 } }
        guard ordered, !metrics.reduceMotion else {
            snap(leaving, into: &out)
            snapSurface(g, at: t, into: &out)
            exactPanel(into: &out)
            runAfterFit(into: &out)
            return
        }
        set(leaving, curve: IslandMotion.focusOut, at: t, into: &out)
        if wasOpen {
            schedule(.foldHeight(IslandMotion.fold), at: t + IslandMotion.foldLag, tag: .fold)
            schedule(.foldWidth(IslandMotion.fold), at: t + IslandMotion.foldLag + IslandMotion.lead, tag: .fold)
        } else {
            schedule(.tuck(IslandMotion.tuck), at: t + IslandMotion.departLag, tag: .depart)
        }
    }

    private mutating func display(_ new: Metrics, at t: TimeInterval, into out: inout [Command]) {
        metrics = new
        shownPill = new.targets.pill
        jobs = []
        reservoir = nil
        narrowWaits = false
        listMove = nil
        revealFloors = [:]
        dropLeaving(into: &out)
        // A close or a hide cut short: its resets run now, as they would have once the shape fit (whether the panel is
        // ordered in or out is settled below).
        afterFit.remove(.orderOut)
        runAfterFit(into: &out)
        let rest = snapToRest(at: t)
        // Ordered in unless hiding, or idle with the idle pill hidden.
        let visible = !hiding && !(surface == .closed && targets.pill.isEmpty && targets.hideWhenIdle)
        if visible != ordered {
            ordered = visible
            out.append(.effect(visible ? .orderIn : .orderOut))
        }
        out.append(.panel(panel))
        out.append(.target(restGeometry, isOpen: surface == .island))
        out.append(.pillSnapshot(shownPill, nil))
        out.append(.animate(nil, rest))
        // The glyph clocks as the rest has them: a wake or a sleep still to come went with the jobs.
        islandClockRuns = surface == .island
        out.append(.effect(.islandLive(islandClockRuns)))
        out.append(.effect(.pillLive(surface != .island)))
    }

    /// Every channel at the rest of the current state, and the panel exactly its shape.
    @discardableResult
    private mutating func snapToRest(at t: TimeInterval) -> [Channel: Double] {
        let g = restGeometry, open = surface == .island
        var rest: [Channel: Double] = [.left: g.left, .right: g.right, .height: g.height, .ear: g.ear, .radius: g.radius,
                                       .rimLift: rimLift(g.height), .pill: open ? 0 : 1, .pillArrive: 1, .header: open ? 1 : 0,
                                       .cardRide: 0]
        for channel in values.keys {
            if case .part = channel { rest[channel] = 0 }
            if case .glide = channel { rest[channel] = 0 }
        }
        if open { for part in presentedParts + budParts { rest[.part(part)] = 1 } }
        if metrics.outline == .coreAnimation { rest[.shoulders] = open ? 1 : 0 }
        for (channel, v) in rest { values[channel] = .rest(v, at: t) }
        // Motion: Liquid: nothing of its own at rest (the bud's rest, while a card buds, is its values').
        reservoir = nil
        for channel in values.keys where channel.isLiquid { values[channel] = nil }
        for (key, v) in liquidRest { values[.liquid(key)] = .rest(Double(v), at: t) }
        panel = restExtent
        afterFit = []
        return rest
    }

    // MARK: Jobs

    private mutating func run(_ step: Step, at t: TimeInterval, into out: inout [Command]) {
        switch step {
        case let .liquid(beat):
            runLiquid(beat, at: t, into: &out)
        case let .openHeight(trigger):
            let g = restGeometry
            let unfold = targets.topBar ? IslandMotion.unfoldWide : IslandMotion.unfold
            growPanel(to: g, curve: unfold, at: t, into: &out)
            if tuning.splitsSurface {
                // F5: the height on its own spring; the ear went with the width.
                set([.height: g.height, .radius: g.radius, .rimLift: rimLift(g.height)], curve: splitCurves.height, at: t, into: &out)
            } else {
                set([.height: g.height, .ear: g.ear, .radius: g.radius, .rimLift: rimLift(g.height)], curve: unfold, at: t, into: &out)
            }
            scheduleReveals(trigger: trigger, at: t)
            scheduleFit(at: t)
        case .header:
            set([.header: 1], curve: tuning.focusIn, at: t, into: &out)
        case let .reveal(part):
            revealFloors[part] = nil
            set([.part(part): 1], curve: part == .footer ? tuning.footerFocusIn ?? tuning.focusIn : tuning.focusIn, at: t, into: &out)
        case let .foldHeight(curve):
            let g = restGeometry
            set([.height: g.height, .ear: g.ear, .radius: g.radius, .rimLift: rimLift(g.height)], curve: curve, at: t, into: &out)
        case let .foldWidth(curve):
            let g = restGeometry
            set([.left: g.left, .right: g.right], curve: curve, at: t, into: &out)
            scheduleShoulders(at: t, into: &out)
            if !hiding { schedulePillGate(at: t) }
            scheduleFit(at: t)
        case .pillIn:
            out.append(.effect(.pillLive(true)))
            settlePill(into: &out)
            set([.pill: 1], curve: metrics.reduceMotion ? IslandMotion.reduced : IslandMotion.pillIn, at: t, into: &out)
        case .pillSleep:
            // The pill is out of sight (its clock stopped as the open started): a change the open cut short lands.
            guard target(.pill) == 0 else { return }
            settlePill(into: &out)
        case .fit:
            let rest = restExtent
            // Motion: Liquid: a beat still to come moves the union (the bud's rise, its gulp), and asks for the fit after it;
            // an outline that never fits within the horizon on the springs as they are waits for it too.
            if tuning.liquid, jobs.contains(where: { if case .liquid = $0.step { true } else { false } }) { return }
            let fit = fitTime(rest, from: t)
            if let fit, fit > t + 0.001 {
                schedule(.fit, at: fit + IslandMotion.frameAhead, tag: .shrink)
                return
            }
            if tuning.liquid, fit == nil {
                schedule(.fit, at: t + IslandMotion.horizon, tag: .shrink)
                return
            }
            exactPanel(into: &out)
            runAfterFit(into: &out)
        case .arriveContent:
            set([.pillArrive: 1], curve: IslandMotion.slide, at: t, into: &out)
        case let .tuck(curve):
            setSurface(restGeometry, curve: curve, at: t, into: &out)
            scheduleFit(at: t)
        case .drop:
            let g = restGeometry
            growPanel(to: g, curve: IslandMotion.emerge, at: t, into: &out)
            setSurface(g, curve: IslandMotion.emerge, at: t, into: &out)
            if !jobs.contains(where: { $0.step == .barSwap }) { schedule(.barSwap, at: t + IslandMotion.arriveContent, tag: .arrive) }
            scheduleFit(at: t)
        case .departSnapshot:
            shownPill = targets.pill
            out.append(.pillSnapshot(targets.pill, nil))
        case .barSwap:
            shownPill = targets.pill
            out.append(.pillSnapshot(targets.pill, nil))
            if metrics.reduceMotion {
                growPanel(to: restGeometry, curve: nil, at: t, into: &out)
                snapSurface(restGeometry, at: t, into: &out)
                exactPanel(into: &out)
            }
            set([.pillArrive: 1], curve: metrics.reduceMotion ? IslandMotion.reduced : tuning.focusIn, at: t, into: &out)
        case let .glideStart(id, delta):
            set([.glide(id): delta, .cardRide: 0], curve: IslandMotion.glide, at: t, into: &out)
            // The body rides up with the row from now: Refined's body comes in once the edge has passed it there.
            gateCardBody(at: t)
            let when = firstTime(from: t) { model, s in model.value(.glide(id), at: s) / delta >= IslandMotion.glideCross } ?? t
            schedule(.cross(id), at: when, tag: .card)
        case let .cross(id):
            if let id { set([.part(.row(id)): 0], curve: IslandMotion.focusOut, at: t, into: &out) }
            set([.part(.cardHeader): 1], curve: tuning.focusIn, at: t, into: &out)
            // The body follows the cross, unless it follows the tap (`toCard`).
            if tuning.cardBodyFromTap == nil {
                let body = max(t + tuning.cardBody, edgeTime(.cardBody, from: t) ?? t)
                schedule(.reveal(.cardBody), at: body, tag: .card)
            }
        case let .glideHome(id, trigger):
            set([.glide(id): 0], curve: IslandMotion.glide, at: t, into: &out)
            if abs(target(.height) - Double(restGeometry.height)) >= 0.5 { run(.contentHeight, at: t, into: &out) }
            revealAroundRow(id, trigger: trigger, at: t)
        case let .listIn(trigger):
            scheduleReveals(trigger: trigger, at: t)
        case .leavingGone:
            // The leaving layer goes once the island has settled (E4): its unmount (10 to 17 ms) never lands in a fold,
            // an unfold's tail, a glide or a fade still running.
            if let settled = settles(from: t) {
                schedule(.leavingGone, at: settled, tag: .leave)
                return
            }
            dropLeaving(into: &out)
        case .cardGone:
            guard presentation == .list, cardMounted != nil else { return }
            // As the leaving layer: the card layer goes once the island has settled, never while it still moves (E4).
            if let settled = settles(from: t) {
                schedule(.cardGone, at: settled, tag: .gone)
                return
            }
            cardMounted = nil
            forget([.part(.cardHeader), .part(.cardBody)], into: &out)
            out.append(.effect(.cardSnapshot(nil)))
            // Motion: Liquid (L2): the bud's card layer has gone with it.
            budCard = nil
            budBase = nil
        case let .glideReset(id):
            // The row, out of focus since the cross, goes home; the body's ride lands on its own curve.
            guard presentation == .card(sessionID: id) else { return }
            snap([.glide(id): 0], into: &out)
        case let .listSwap(change):
            swap(change, at: t, into: &out)
        case .contentHeight:
            let g = restGeometry
            guard surface == .island else { return }
            let curve = Double(g.height) > target(.height) ? (targets.topBar ? IslandMotion.unfoldWide : IslandMotion.unfold)
                : (targets.topBar ? IslandMotion.foldWide : IslandMotion.fold)
            if curve.bounce > 0 { growPanel(to: g, curve: curve, at: t, into: &out) }
            set([.height: g.height, .ear: g.ear, .radius: g.radius, .rimLift: rimLift(g.height)], curve: curve, at: t, into: &out)
            out.append(.target(g, isOpen: true))
            scheduleFit(at: t)
        case .reducedOpen:
            let g = restGeometry
            growPanel(to: g, curve: nil, at: t, into: &out)
            snapSurface(g, at: t, into: &out)
            // Motion: Liquid's bud (L2): its black snaps in where the card will cross-fade in.
            snapBudRest(into: &out)
            exactPanel(into: &out)
            schedule(.reducedIn(presentedParts + budParts), at: t + IslandMotion.reducedIn - IslandMotion.reducedOpenSnap, tag: .reduced)
        case let .reducedIn(parts):
            var shown: [Channel: Double] = [.header: 1]
            for part in parts { shown[.part(part)] = 1 }
            set(shown, curve: IslandMotion.reduced, at: t, into: &out)
        case .reducedClose:
            snapSurface(restGeometry, at: t, into: &out)
            exactPanel(into: &out)
            if !hiding {
                out.append(.effect(.pillLive(true)))
                settlePill(into: &out)
                set([.pill: 1], curve: IslandMotion.reduced, at: t, into: &out)
            }
            runAfterFit(into: &out)
        case .reducedHeight:
            let g = restGeometry
            growPanel(to: g, curve: nil, at: t, into: &out)
            snapSurface(g, at: t, into: &out)
            exactPanel(into: &out)
            out.append(.target(g, isOpen: surface == .island))
            var shown: [Channel: Double] = [:]
            for part in presentedParts + budParts { shown[.part(part)] = 1 }
            if !shown.isEmpty { set(shown, curve: IslandMotion.reduced, at: t, into: &out) }
            if presentation == .list, cardMounted != nil { schedule(.cardGone, at: t + IslandMotion.goneAfter, tag: .gone) }
        case .reducedDepart:
            shownPill = targets.pill
            out.append(.pillSnapshot(targets.pill, nil))
            snapSurface(restGeometry, at: t, into: &out)
            exactPanel(into: &out)
            runAfterFit(into: &out)
        case let .shoulders(shown, curve):
            set([.shoulders: shown], curve: curve, at: t, into: &out)
        }
    }

    /// Card → list: the parts under the row's home come in edge-synced from `listBelow`; the parts its path crosses wait
    /// until the gliding row overlaps them by less than `aboveOverlap`, and no longer than `aboveCap`.
    private mutating func revealAroundRow(_ id: String, trigger: TimeInterval, at t: TimeInterval) {
        if planning { return }
        cancel(.reveal)
        guard let home = layout.parts[.row(id)] else { return }
        let parts = layout.listParts.filter { $0 != .row(id) && target(.part($0)) < 1 }
        let below = parts.filter { (layout.parts[$0]?.minY ?? 0) >= home.minY }
        let above = parts.filter { (layout.parts[$0]?.minY ?? 0) < home.minY }
        scheduleReveals(trigger: trigger + IslandMotion.listBelow - tuning.rowFloor, at: t, parts: below)
        for part in above {
            guard let rect = layout.parts[part] else { continue }
            // Clear once the row has passed it for good (it may start above the part and cross it later).
            let clear = settleTime(from: t) { model, s in
                guard let span = model.rowSpan(id, at: s) else { return false }
                return min(span.upperBound, rect.maxY) - max(span.lowerBound, rect.minY) >= IslandMotion.aboveOverlap
            }
            schedule(.reveal(part), at: min(clear, trigger + IslandMotion.aboveCap), tag: .reveal)
        }
    }

    /// A pill change an open cut short lands while the pill is out of sight: the snapshot it was going to show, and its
    /// glyph and count back in place. Nothing while one still plays.
    private mutating func settlePill(into out: inout [Command]) {
        guard !jobs.contains(where: { $0.tag == .arrive || $0.tag == .depart }) else { return }
        if shownPill != targets.pill {
            shownPill = targets.pill
            out.append(.pillSnapshot(targets.pill, nil))
        }
        if target(.pillArrive) < 1 { snap([.pillArrive: 1], into: &out) }
    }

    private mutating func runAfterFit(into out: inout [Command]) {
        let actions = afterFit
        afterFit = []
        if actions.contains(.reset), surface == .closed {
            presentation = .list
            budCard = nil
            budBase = nil
            // Every row home and the body unhung, in the views too: a close that cut a glide short leaves no row out of
            // its place for the next open (P101).
            var reset = values.keys.filter { if case .glide = $0 { true } else { false } }
            if cardMounted != nil {
                cardMounted = nil
                reset += [.part(.cardHeader), .part(.cardBody)]
                out.append(.effect(.cardSnapshot(nil)))
            }
            forget(reset, into: &out)
            dropLeaving(into: &out)
            if let ride = values[.cardRide], ride.target != 0 || ride.curve != nil { snap([.cardRide: 0], into: &out) }
            out.append(.effect(.resetAfterFold))
        }
        if actions.contains(.orderOut), surface == .closed, ordered {
            ordered = false
            out.append(.effect(.orderOut))
        }
    }

    // MARK: Helpers

    /// `values` in one batch on `curve`. A curve on any of the surface's five carries all five (SwiftUI animates them
    /// as one vector), so the others continue from where they are on the new curve, toward their own targets. The first
    /// that brings anything of the open island in (the header's job, a reveal, a reverse re-aiming what still shows, the
    /// card's cross) starts the island's glyph clock with it.
    private mutating func set(_ changes: [Channel: Double], curve: IslandMotion.Curve?, at t: TimeInterval, into out: inout [Command]) {
        guard !changes.isEmpty else { return }
        if !islandClockRuns, surface == .island, changes.contains(where: { Self.bringsInTheIsland($0.key) && $0.value > 0 }) {
            islandClock(true, into: &out)
        }
        // What SwiftUI's outline does with a curve (`SurfaceClip`): one vector carries all five, or with the two springs
        // (`MotionTuning.splitsSurface`) each vector is carried by a curve that changes one of its own values; a value set
        // to the target it already has changes nothing there, so it keeps its own curve.
        var kept: Set<Channel> = []
        if curve != nil, tuning.splitsSurface {
            for group in [Channel.surfaceWidth, Channel.surfaceHeight] {
                let carried = group.contains { channel in changes[channel].map { abs($0 - target(channel)) > 1e-9 } ?? false }
                if carried {
                    for channel in group where changes[channel] == nil {
                        values[channel, default: .rest(Self.defaultValue(channel))].retarget(target(channel), curve: curve, at: t)
                    }
                } else {
                    kept.formUnion(group)
                }
            }
        } else if curve != nil, changes.keys.contains(where: \.isSurface) {
            for channel in Channel.surface where changes[channel] == nil {
                values[channel, default: .rest(Self.defaultValue(channel))].retarget(target(channel), curve: curve, at: t)
            }
        }
        for (channel, v) in changes where !kept.contains(channel) {
            values[channel, default: .rest(Self.defaultValue(channel))].retarget(v, curve: curve, at: t)
        }
        Self.append(.animate(curve, changes), to: &out)
    }

    /// A write for the views: Motion: Liquid's values are the outline's, played from the plan (`SurfacePlan.liquid`),
    /// never written to a view's box, so a batch that moves nothing else writes nothing.
    private static func append(_ command: Command, to out: inout [Command]) {
        guard case let .animate(curve, values) = command, values.keys.contains(where: \.isLiquid) else {
            out.append(command)
            return
        }
        let shown = values.filter { !$0.key.isLiquid }
        if !shown.isEmpty { out.append(.animate(curve, shown)) }
    }

    /// The header group or a part of the island that shows (not a card leaving, or one built ahead that nothing brings in).
    private static func bringsInTheIsland(_ channel: Channel) -> Bool {
        switch channel {
        case .header: true
        case let .part(part): part != .leavingHeader && part != .leavingBody && part != .cardAhead
        default: false
        }
    }

    /// The island's glyph clock on or off (written with the batch's still writes, before the values it goes with).
    private mutating func islandClock(_ on: Bool, into out: inout [Command]) {
        guard islandClockRuns != on else { return }
        islandClockRuns = on
        out.append(.effect(.islandLive(on)))
    }

    /// Drops `channels` from the model and sets them to their default in the views, with no animation (their parts have
    /// gone, or are out of sight): the views never hold a value the model no longer knows.
    private mutating func forget(_ channels: [Channel], into out: inout [Command]) {
        guard !channels.isEmpty else { return }
        for channel in channels { values[channel] = nil }
        Self.append(.animate(nil, Dictionary(channels.map { ($0, Self.defaultValue($0)) }, uniquingKeysWith: { a, _ in a })), to: &out)
    }

    private mutating func snap(_ changes: [Channel: Double], into out: inout [Command]) {
        guard !changes.isEmpty else { return }
        for (channel, v) in changes { values[channel] = .rest(v) }
        Self.append(.animate(nil, changes), to: &out)
    }

    private mutating func setSurface(_ g: SurfaceGeometry, curve: IslandMotion.Curve?, at t: TimeInterval, into out: inout [Command]) {
        set([.left: g.left, .right: g.right, .height: g.height, .ear: g.ear, .radius: g.radius, .rimLift: rimLift(g.height)],
            curve: curve, at: t, into: &out)
    }

    private mutating func snapSurface(_ g: SurfaceGeometry, at t: TimeInterval, into out: inout [Command]) {
        snap([.left: g.left, .right: g.right, .height: g.height, .ear: g.ear, .radius: g.radius, .rimLift: rimLift(g.height)], into: &out)
    }

    /// How far the surface reaches below the closed pill at `height`.
    private func rimLift(_ height: CGFloat) -> Double {
        Double(max(0, height - targets.closed.height))
    }

    /// Before a growth: the panel takes in the shape as it is and where it is going (and `motionMargin` more when the
    /// curve may overshoot). It only ever grows while anything moves.
    private mutating func growPanel(to g: SurfaceGeometry, curve: IslandMotion.Curve?, at t: TimeInterval, into out: inout [Command]) {
        var need = panel.union(surface(at: t).extent).union(g.extent)
        if let curve, curve.bounce > 0 { need = need.union(g.extent.grown(by: IslandTheme.Metrics.motionMargin)) }
        guard need != panel else { return }
        panel = need
        out.append(.panel(need))
    }

    /// The panel exactly the rest shape (P36).
    private mutating func exactPanel(into out: inout [Command]) {
        let rest = restExtent
        guard rest != panel else { return }
        panel = rest
        out.append(.panel(rest))
    }

    /// The panel shrinks to the rest shape once the outline fits it for good, one frame late so a frame drawn late is
    /// never cut; the close's resets wait for the same moment. Only after the transition's last surface step.
    private mutating func scheduleFit(at t: TimeInterval) {
        if planning { return }
        cancel(.shrink)
        guard !jobs.contains(where: \.step.movesSurface) else { return }
        let fit = fitTime(restExtent, from: t) ?? t + IslandMotion.horizon
        schedule(.fit, at: fit + IslandMotion.frameAhead, tag: .shrink)
    }

    /// The first moment from which the outline stays inside `extent` (+ `fitTolerance`), looking `horizon` ahead.
    func fitTime(_ extent: IslandExtent, from t: TimeInterval) -> TimeInterval? {
        let step = 0.002, tolerance = IslandMotion.fitTolerance
        // The extent is the reaches and the height alone, read from their springs once (P300).
        let rest: (Channel) -> ShadowValue = { .rest(Self.defaultValue($0)) }
        let left = values[.left] ?? rest(.left), right = values[.right] ?? rest(.right), height = values[.height] ?? rest(.height)
        // Motion: Liquid: the union's reach (`LiquidPath.bounds`), from every value it reads, while any of its own draws.
        let unions = tuning.liquid && (reservoir != nil || values.contains { $0.key.isLiquid && !Self.still($0.key, $0.value, at: t) }
            || !liquid(at: t).isRest)
        let ear = values[.ear] ?? rest(.ear), radius = values[.radius] ?? rest(.radius)
        // Only the values the union's reach reads (`LiquidPath.bounds`), and of those only the ones that move.
        var fixed = LiquidParams()
        var own: [(LiquidKey, ShadowValue)] = []
        if unions {
            for key in LiquidPath.reachKeys {
                let v = values[.liquid(key)] ?? rest(.liquid(key))
                if Self.still(.liquid(key), v, at: t) { fixed[key] = CGFloat(v.value(at: t)) } else { own.append((key, v)) }
            }
        }
        var last: TimeInterval?
        var s = t
        while s <= t + IslandMotion.horizon {
            var e = IslandExtent(left: CGFloat(left.value(at: s)), right: CGFloat(right.value(at: s)), height: CGFloat(height.value(at: s)))
            if unions {
                var p = fixed
                for (key, v) in own { p[key] = CGFloat(v.value(at: s)) }
                p.reservoir = reservoir
                e = LiquidPath.bounds(SurfaceGeometry(left: e.left, right: e.right, height: e.height, ear: CGFloat(ear.value(at: s)),
                                                      radius: CGFloat(radius.value(at: s))), p)
            }
            if !extent.contains(e, tolerance: tolerance) { last = s }
            s += step
        }
        guard let last else { return t }
        return last + step <= t + IslandMotion.horizon ? last + step : nil
    }

    /// The first moment from which `blocked` stays false (1 ms steps, `horizon` ahead; `t` when it never holds).
    func settleTime(from t: TimeInterval, while blocked: (IslandChoreography, TimeInterval) -> Bool) -> TimeInterval {
        var last: TimeInterval?
        var s = t
        while s <= t + IslandMotion.horizon {
            if blocked(self, s) { last = s }
            s += 0.001
        }
        return last.map { $0 + 0.001 } ?? t
    }

    /// The first moment from `t` (1 ms steps, `horizon` ahead) at which `condition` holds.
    func firstTime(from t: TimeInterval, where condition: (IslandChoreography, TimeInterval) -> Bool) -> TimeInterval? {
        var s = t
        while s <= t + IslandMotion.horizon {
            if condition(self, s) { return s }
            s += 0.001
        }
        return nil
    }

    private mutating func schedule(_ step: Step, at time: TimeInterval, tag: Tag) {
        if planning, !step.movesSurface { return }
        seq += 1
        jobs.append(Job(time: time, tag: tag, step: step, seq: seq))
    }

    private mutating func cancel(_ tags: Tag...) {
        jobs.removeAll { tags.contains($0.tag) }
    }

    // MARK: Replay

    /// Plays `events` (each at its time) from `model`, running jobs as they fall due, up to `time`.
    static func replay(_ model: IslandChoreography, _ events: [(TimeInterval, Event)], until time: TimeInterval)
        -> (model: IslandChoreography, commands: [Command]) {
        var model = model, commands: [Command] = []
        for (t, event) in events.sorted(by: { $0.0 < $1.0 }) where t <= time {
            commands += model.advance(to: t)
            commands += model.handle(event, at: t)
        }
        commands += model.advance(to: time)
        return (model, commands)
    }
}

// MARK: - The surface's plan (Core Animation's outline)

extension IslandChoreography {
    /// The surface from `start` exactly as the model plays it if no other event comes, sampled every `step`: the outline
    /// and the edge line's lift, to be handed to Core Animation (`IslandSurfaceLayers`), which plays it in the render
    /// server on its own clock, so a late job timer or a busy main thread no longer moves the edge.
    struct SurfacePlan: Equatable, Sendable {
        var start: TimeInterval
        var step: TimeInterval
        var surface: [SurfaceGeometry]
        var rim: [CGFloat]
        /// The bottom corners of continuous curvature (Motion: Refined, F9).
        var continuous = false
        /// Motion: Liquid: its values and the reservoir at each sample; the outline is their union with the body
        /// (`LiquidPath`). nil for every other feel.
        var liquid: [LiquidParams]? = nil
        /// Motion: Liquid: where the neck pinches or joins between two samples, the values just before and just after
        /// (the same outline, written as the joined neck and as the stubs): drawn exactly there, each side between it
        /// and its own sample, never mixed across it.
        var flips: [LiquidFlip] = []
        /// Motion: Liquid: the model's own values between two samples, where a straight line between them would miss
        /// them: halfway, where a liquid value's own curve leaves that line by more than `LiquidPath.midStray` (a large
        /// spring starting from rest), and closing in on each pinch and join (`LiquidPath.nearFlip`). Drawn there too.
        var mids: [LiquidMid] = []

        var end: TimeInterval { start + Double(max(0, surface.count - 1)) * step }
        var last: SurfaceGeometry { surface.last ?? .zero }

        /// Motion: Liquid's values at `t`, linearly between the samples as Core Animation draws them (and through the
        /// knots between them: a jump on its side of it, the model's own values).
        func liquid(at t: TimeInterval) -> LiquidParams? {
            guard let liquid, let last = liquid.last else { return nil }
            guard liquid.count > 1 else { return last }
            let x = max(0, (t - start) / step), i = Int(x.rounded(.down))
            guard i + 1 < liquid.count else { return last }
            // Through the knots between these samples, in order: the jumps (each side between its neighbours only) and
            // the model's own values (most intervals have none: a straight line, nothing built).
            guard hasKnots(after: i) else { return liquid[i].mixed(liquid[i + 1], CGFloat(x - Double(i))) }
            var from = (index: Double(i), params: liquid[i])
            for knot in knots(after: i) {
                if x < knot.index { return from.params.mixed(knot.before, CGFloat((x - from.index) / max(1e-12, knot.index - from.index))) }
                from = (knot.index, knot.after)
            }
            let span = Double(i + 1) - from.index
            return span > 1e-9 ? from.params.mixed(liquid[i + 1], CGFloat((x - from.index) / span)) : liquid[i + 1]
        }

        /// The knots between samples `i` and `i + 1`, in order: every jump (up to and on `i + 1`) and model value (before
        /// it), its body and its values on either side (the same for a model value).
        func knots(after i: Int) -> [Knot] {
            let lo = Double(i), hi = Double(i + 1)
            let f = Self.first(flips, after: lo, \.index), m = Self.first(mids, after: lo, \.index)
            var out = flips[f...].prefix { $0.index <= hi }.map { Knot(index: $0.index, body: $0.body, before: $0.before, after: $0.after) }
            let inside = mids[m...].prefix { $0.index < hi }
            guard !inside.isEmpty else { return out }
            let jumps = out.count
            out += inside.map { Knot(index: $0.index, body: $0.body, before: $0.params, after: $0.params) }
            guard jumps > 0 else { return out }
            // A jump before a model value at the same moment (the value is the jump's after).
            let order = out.indices.sorted { (out[$0].index, $0) < (out[$1].index, $1) }
            return order.map { out[$0] }
        }

        /// Whether a jump or a model value lies between samples `i` and `i + 1`.
        func hasKnots(after i: Int) -> Bool {
            let lo = Double(i), f = Self.first(flips, after: lo, \.index), m = Self.first(mids, after: lo, \.index)
            return (f < flips.count && flips[f].index <= lo + 1) || (m < mids.count && mids[m].index < lo + 1)
        }

        /// The first of `items` (in order of `index`) past `lo`.
        static func first<T>(_ items: [T], after lo: Double, _ index: KeyPath<T, Double>) -> Int {
            var a = 0, b = items.count
            while a < b {
                let mid = (a + b) / 2
                if items[mid][keyPath: index] > lo { b = mid } else { a = mid + 1 }
            }
            return a
        }

        struct Knot {
            var index: Double
            var body: SurfaceGeometry
            var before: LiquidParams
            var after: LiquidParams
        }

        /// Whether any sample draws anything but the body (a plan that does not keeps today's outline exactly).
        var drawsLiquid: Bool { liquid?.contains { !$0.isRest } ?? false }

        /// The plan at `t`, linearly between its samples, as Core Animation draws it (its last sample once it ended).
        func geometry(at t: TimeInterval) -> SurfaceGeometry {
            guard surface.count > 1 else { return last }
            let x = max(0, (t - start) / step), i = Int(x.rounded(.down))
            guard i + 1 < surface.count else { return last }
            let u = CGFloat(x - Double(i)), a = surface[i], b = surface[i + 1]
            func mix(_ p: CGFloat, _ q: CGFloat) -> CGFloat { p + (q - p) * u }
            return SurfaceGeometry(left: mix(a.left, b.left), right: mix(a.right, b.right), height: mix(a.height, b.height),
                                   ear: mix(a.ear, b.ear), radius: mix(a.radius, b.radius))
        }

        func rim(at t: TimeInterval) -> CGFloat {
            guard rim.count > 1 else { return rim.last ?? 0 }
            let x = max(0, (t - start) / step), i = Int(x.rounded(.down))
            guard i + 1 < rim.count else { return rim[rim.count - 1] }
            return rim[i] + (rim[i + 1] - rim[i]) * CGFloat(x - Double(i))
        }
    }

    /// Motion: Liquid: a job moves the values at once at a sample's fractional `index`: the neck pinches or joins
    /// (`neck`: `before` and `after` draw the same outline with the other flag), or a bud hidden in the body snaps away,
    /// a reservoir comes or goes. Drawn exactly there, never mixed across.
    struct LiquidFlip: Equatable, Sendable {
        var index: Double
        var body: SurfaceGeometry
        var before: LiquidParams
        var after: LiquidParams
        var neck = true
    }

    /// Motion: Liquid: the model's own values between two samples (`SurfacePlan.mids`).
    struct LiquidMid: Equatable, Sendable {
        var index: Double
        var body: SurfaceGeometry
        var params: LiquidParams
    }

    /// The channels the plan carries: the surface's five and the edge line's lift.
    static let planned: [Channel] = Channel.surface + [.rimLift]

    /// The job due next by `t`, if any: where it waits, when, whether it can move the surface (only such a job moves
    /// the liquid, so the plan that skips the rest plans the same), and whether it pinches or joins the neck.
    fileprivate func nextJob(by t: TimeInterval) -> (index: Int, time: TimeInterval, moves: Bool, neck: Bool)? {
        guard let index = dueJob(by: t) else { return nil }
        let step = jobs[index].step
        return (index, jobs[index].time, step.movesSurface, step == .liquid(.pinch) || step == .liquid(.join))
    }

    /// Runs that job.
    fileprivate mutating func runJob(_ index: Int) {
        let job = jobs.remove(at: index)
        version += 1
        var ignored: [Command] = []
        run(job.step, at: job.time, into: &ignored)
    }

    /// The model's future for the surface from `t`: a copy runs its pending jobs at their own times (the open's height
    /// after its lead, a fold's height then width, a content height, a tuck), sampled every `step` until every planned
    /// value rests and no job that moves the surface waits, `IslandMotion.horizon` at most. `lean` (the default) has the
    /// copy skip what cannot move the surface (reveals, fits, gates, and every job that is not `Step.movesSurface`), about
    /// ten times cheaper for the same samples; a job that moves the surface must say so there, or the plan misses it
    /// (the director's check after every job then plays the model again).
    func surfacePlan(from t: TimeInterval, step: TimeInterval, lean: Bool = true) -> SurfacePlan {
        // The plan the event made for the panel, while the model is still as it made it.
        if lean, let cached = liquidPlan, cached.version == version, cached.plan.start == t, cached.plan.step == step { return cached.plan }
        var model = self
        if lean {
            model.planning = true
            model.jobs.removeAll { !$0.step.movesSurface }
        }
        let liquids = tuning.liquid
        let planned = Self.planned
        var surface: [SurfaceGeometry] = [], rim: [CGFloat] = [], liquid: [LiquidParams] = []
        var flips: [LiquidFlip] = []
        var mids: [LiquidMid] = []
        // Motion: Liquid's values, read from the model again only after a job has changed it.
        var liquidValues: [ShadowValue] = [], read = -1, sampled = -1
        // Beside a pinch or a join the neck's waist moves as a square root of the values, and the springs curve between
        // the samples: the model's own values there, closing in on it geometrically. `knot` is the last sample or job,
        // `nearAfter` a pinch or a join the values after which are still to be drawn.
        var knot = t, nearAfter: TimeInterval?
        // The jobs that moved the surface so far, and as of the last sample.
        var moved = 0
        func nearValues(_ m: IslandChoreography, _ a: TimeInterval, _ b: TimeInterval, closingOnStart: Bool) -> [LiquidMid] {
            guard b - a > 1e-9 else { return [] }
            return (closingOnStart ? LiquidPath.nearFlip : LiquidPath.nearFlip.reversed().map { 1 - $0 }).map { u in
                let time = a + (b - a) * u
                return LiquidMid(index: (time - t) / step, body: m.surface(at: time), params: m.liquid(at: time))
            }
        }
        func near(_ m: IslandChoreography, _ a: TimeInterval, _ b: TimeInterval, closingOnStart: Bool) {
            mids.append(contentsOf: nearValues(m, a, b, closingOnStart: closingOnStart))
        }
        var s = t
        while true {
            // The jumps between the samples (the neck's pinches and joins, snaps, a reservoir), each at its own moment
            // (one a job schedules as it runs included: the jobs run one at a time).
            while liquids, let job = model.nextJob(by: s) {
                guard job.moves else { model.runJob(job.index); continue }
                moved += 1
                // The springs since a pinch or a join are the model's own until this job: drawn there, closing in on it.
                if let from = nearAfter { near(model, from, job.time, closingOnStart: true); nearAfter = nil }
                // The springs up to a pinch or a join, the same from the other side (kept only where the neck flips).
                let before = model.liquid(at: job.time), body = model.surface(at: job.time)
                let lead = job.neck ? nearValues(model, knot, job.time, closingOnStart: false) : []
                model.runJob(job.index)
                knot = job.time
                let after = model.liquid(at: job.time)
                guard LiquidParams.distance(before, after) > 0.01 else { continue }
                let neck = before.isJoined != after.isJoined
                if neck { mids.append(contentsOf: lead); nearAfter = job.time }
                // On a sample, exactly there (the job's time read back through the step's rounding).
                var index = (job.time - t) / step
                if abs(index - index.rounded()) < 1e-6 { index = index.rounded() }
                flips.append(LiquidFlip(index: index, body: body, before: before, after: after, neck: neck))
            }
            _ = model.advance(to: s)
            if let from = nearAfter { near(model, from, s, closingOnStart: true); nearAfter = nil }
            knot = s
            surface.append(model.surface(at: s))
            rim.append(CGFloat(model.value(.rimLift, at: s)))
            var moving = false
            if liquids {
                if read != model.version {
                    liquidValues = LiquidKey.every.map { model.values[.liquid($0)] ?? .rest(Self.defaultValue(.liquid($0))) }
                    read = model.version
                }
                var p = LiquidParams()
                for (key, v) in zip(LiquidKey.every, liquidValues) {
                    p[key] = CGFloat(v.value(at: s))
                    if !moving, v.curve != nil, abs(v.value(at: s) - v.target) > 0.002 || abs(v.velocity(at: s)) > 0.02 { moving = true }
                }
                p.reservoir = model.reservoir
                // No job ran since the last sample: the values halfway are the same springs' there. Where one leaves the
                // straight line between the samples by more than a hair, the plan draws it there too.
                if sampled == moved, let before = liquid.last, before.budShows || p.budShows {
                    let h = s - step / 2
                    var m = LiquidParams()
                    for (key, v) in zip(LiquidKey.every, liquidValues) { m[key] = CGFloat(v.value(at: h)) }
                    m.reservoir = model.reservoir
                    let line = before.mixed(p, 0.5)
                    if LiquidKey.every.contains(where: { abs(m[$0] - line[$0]) > LiquidPath.midStray }) {
                        mids.append(LiquidMid(index: Double(liquid.count) - 0.5, body: model.surface(at: h), params: m))
                    }
                }
                sampled = moved
                liquid.append(p)
            }
            moving = moving || planned.contains { channel in
                guard let v = model.values[channel], v.curve != nil else { return false }
                return abs(v.value(at: s) - v.target) > 0.002 || abs(v.velocity(at: s)) > 0.02
            }
            if !moving, !model.jobs.contains(where: \.step.movesSurface) {
                // At rest: its last sample the rest itself, not a hair short of it, so the layers rest exactly there.
                surface[surface.count - 1] = SurfaceGeometry(left: model.target(.left), right: model.target(.right),
                                                             height: model.target(.height), ear: model.target(.ear),
                                                             radius: model.target(.radius))
                rim[rim.count - 1] = CGFloat(model.target(.rimLift))
                if liquids {
                    var p = LiquidParams()
                    for key in LiquidKey.every { p[key] = CGFloat(model.target(.liquid(key))) }
                    p.reservoir = model.reservoir
                    liquid[liquid.count - 1] = p
                }
                break
            }
            if s - t >= IslandMotion.horizon { break }
            s += step
        }
        // The knots in order of their place (a job's values before and after it are recorded as it runs).
        mids = mids.enumerated().sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }.map(\.element)
        return SurfacePlan(start: t, step: step, surface: surface, rim: rim, continuous: tuning.continuousCorners,
                           liquid: liquids ? liquid : nil, flips: flips, mids: mids)
    }
}

// MARK: - Motion: Liquid

extension IslandChoreography {
    /// The plan's sample spacing (`IslandSurfaceLayers.step`): the panel's growth plans at it.
    static let planStep: TimeInterval = 1.0 / 240

    /// The swell's width under Liquid: Hover's response, one soft overshoot.
    fileprivate var liquidSwell: IslandMotion.Curve {
        IslandMotion.Curve(response: tuning.swell.response, dampingFraction: LiquidMotion.swellDamping)
    }

    /// Liquid's values at rest in the current state (only what differs from `LiquidParams.rest`): the card's bud while
    /// a card rests in it.
    var liquidRest: [LiquidKey: CGFloat] {
        guard let p = budRestParams else { return [:] }
        return [.budGap: p.budGap, .budHalf: p.budHalf, .budHeight: p.budHeight, .budRadius: p.budRadius]
    }

    /// The rest's reach, which the panel fits: the body, and while a card rests in its bud the gap's band and the bud
    /// below it, a point more.
    var restExtent: IslandExtent {
        let g = restGeometry
        guard let p = budRestParams else { return g.extent }
        return IslandExtent(left: max(g.left, p.budHalf), right: max(g.right, p.budHalf), height: g.height + p.budGap + p.budHeight + 1)
    }

    // MARK: The card's bud (L2)

    /// A card rests in its bud below the list (Motion: Liquid): presented, open, and budding.
    var budding: Bool {
        guard let budCard, surface == .island, case let .card(id) = presentation else { return false }
        return id == budCard
    }

    /// The bud's height for `id`'s card: its layer as measured (a card not yet measured: `budGuess`), and the insets.
    func budHeight(_ id: String) -> CGFloat {
        let card = layout.cardID == id ? layout.card : nil
        return (card ?? LiquidMotion.budGuess) + LiquidMotion.budInsetTop + LiquidMotion.budInsetBottom
    }

    /// Whether `id`'s card has room in its bud: the list's island, the gap and the bud within the display's height
    /// (`Metrics.maxHeight`); a card without it presents in the body, as Refined's, with the liquid body morph.
    func budFits(_ id: String) -> Bool {
        guard let max = metrics.maxHeight else { return true }
        return layout.islandHeight(card: nil) + LiquidMotion.restGap + budHeight(id) <= max
    }

    /// The bud at rest while a card rests in it: as wide as the body between its shoulders, `restGap` below it, the
    /// card's height and its insets, round corners.
    var budRestParams: LiquidParams? {
        guard budding, case let .card(id) = presentation else { return nil }
        let g = restGeometry
        var p = LiquidParams()
        p.budGap = LiquidMotion.restGap
        p.budHalf = max(0, min(g.left, g.right) - g.ear)
        p.budHeight = budHeight(id)
        p.budRadius = LiquidMotion.budCorner
        return p
    }

    /// The bud as the views hold it: the body's height the card layers ride from while they ride in it, and the rest's
    /// reach the pointer and clicks count while the card rests in it.
    var budState: BudState {
        BudState(base: budCard == nil ? nil : budBase, hit: budding ? restExtent : nil)
    }

    /// The views take the bud's state when it changes (`Effect.bud`).
    fileprivate mutating func syncBud(into out: inout [Command]) {
        guard !planning else { return }
        let now = budState
        guard now != budSent else { return }
        budSent = now
        out.append(.effect(.bud(base: now.base, hit: now.hit)))
    }

    /// The bud's values at its rest, in a true snap (Reduce Motion, where nothing of it shows yet).
    fileprivate mutating func snapBudRest(into out: inout [Command]) {
        guard let p = budRestParams else { return }
        snap([.liquid(.budGap): Double(p.budGap), .liquid(.budHalf): Double(p.budHalf), .liquid(.budHeight): Double(p.budHeight),
              .liquid(.budRadius): Double(p.budRadius), .liquid(.joined): 0, .liquid(.lipBody): 0, .liquid(.lipBead): 0,
              .liquid(.tension): Double(LiquidPath.tension)], into: &out)
    }

    /// The bud's values back at their rest inside the body, in a true snap (it draws nothing there).
    fileprivate mutating func snapBudAway(into out: inout [Command]) {
        let rest = LiquidParams.rest
        var away: [Channel: Double] = [:]
        for key in [LiquidKey.budGap, .budHalf, .budHeight, .budRadius, .joined, .lipBody, .lipBead, .tension] {
            if target(.liquid(key)) != Double(rest[key]) || values[.liquid(key)]?.curve != nil { away[.liquid(key)] = Double(rest[key]) }
        }
        snap(away, into: &out)
    }

    /// The bud goes at once, its card layer in the body (a card with no room for its bud replaced one in it): a jump,
    /// never a spill.
    fileprivate mutating func dropBud(at t: TimeInterval, into out: inout [Command]) {
        cancel(.bud)
        snapBudAway(into: &out)
        budCard = nil
        budBase = nil
    }

    /// List → card (or a card for another in its bud): the list stays, and the card buds out below it. A bead is seeded
    /// just inside the bottom edge, grows and falls on a neck that thins and pinches, and spreads into the card, whose
    /// parts come into focus as it uncovers them. From a bud already out it goes on from where it is: joined, it grows
    /// and falls again; apart, it spreads; a card already in it swaps its content and takes the new card's height.
    fileprivate mutating func budOut(_ id: String, at t: TimeInterval, into out: inout [Command]) {
        cancel(.card, .list, .gone, .content, .reduced, .bud)
        jobs.removeAll { $0.step == .reveal(.cardHeader) || $0.step == .reveal(.cardBody) }
        // Every row home: none lifts into the header's place, the list stays as it is.
        homeOtherRows(except: "", at: t, into: &out)
        let swapping = budCard != nil && cardMounted != nil && cardMounted != id
        presentation = .card(sessionID: id)
        mountCard(for: presentation, at: t, into: &out)
        if budCard == nil { budBase = layout.islandHeight(card: nil) }
        budCard = id
        // The list back in focus (a card in the body had replaced it), the island at its height.
        var back: [Channel: Double] = [:]
        for part in layout.listParts where target(.part(part)) < 1 { back[.part(part)] = 1 }
        if metrics.reduceMotion {
            set(back.merging([.part(.cardHeader): 1, .part(.cardBody): 1]) { a, _ in a }, curve: IslandMotion.reduced, at: t, into: &out)
            snapBudRest(into: &out)
            let g = restGeometry
            if abs(target(.height) - Double(g.height)) >= 0.5 { schedule(.reducedHeight, at: t + IslandMotion.reducedSwap, tag: .reduced) }
            exactPanel(into: &out)
            return
        }
        if !back.isEmpty { set(back, curve: tuning.focusIn, at: t, into: &out) }
        retargetHeight(at: t, into: &out)
        let p = liquid(at: t)
        if swapping, p.budShows, !p.isJoined {
            // Another card in the bud: its content crosses in as the other's fades, the bud takes its height.
            run(.liquid(.spread), at: t, into: &out)
            schedule(.reveal(.cardHeader), at: t + IslandMotion.crossWithoutGlide, tag: .card)
            schedule(.reveal(.cardBody), at: t + IslandMotion.crossWithoutGlide + IslandMotion.cardBody, tag: .card)
        } else if p.budShows {
            run(.liquid(.budStart), at: t, into: &out)
        } else {
            run(.liquid(.budSeed), at: t, into: &out)
        }
    }

    /// Card → list: the card's content fades (readable a moment more), the card contracts to a bead as it sinks a
    /// little, rises once it is one, joins through the neck as the stubs meet and is taken in with a gulp. A bead still
    /// joined rises at once.
    fileprivate mutating func budMerge(at t: TimeInterval, into out: inout [Command]) {
        cancel(.card, .list, .gone, .content, .reduced, .bud)
        jobs.removeAll { $0.step == .reveal(.cardHeader) || $0.step == .reveal(.cardBody) }
        presentation = .list
        let leaving: [Channel: Double] = [.part(.cardHeader): 0, .part(.cardBody): 0]
        schedule(.cardGone, at: t + IslandMotion.goneAfter, tag: .gone)
        if metrics.reduceMotion {
            set(leaving, curve: IslandMotion.reduced, at: t, into: &out)
            schedule(.liquid(.budGone), at: t + IslandMotion.reducedSwap, tag: .bud)
            return
        }
        let p = liquid(at: t)
        let shows = value(.part(.cardHeader), at: t) > IslandMotion.shown || value(.part(.cardBody), at: t) > IslandMotion.shown
        if shows { schedule(.liquid(.budFade), at: t + LiquidMotion.budFadeAt, tag: .bud) } else { set(leaving, curve: IslandMotion.focusOut, at: t, into: &out) }
        guard p.budShows else { return run(.liquid(.budGone), at: t, into: &out) }
        let r = LiquidMotion.mergeBead
        if p.isJoined {
            run(.liquid(.rise), at: t, into: &out)
            return
        }
        set([.liquid(.budHalf): Double(r - LiquidMotion.beadNarrow), .liquid(.budHeight): Double(2 * r), .liquid(.budRadius): Double(r)],
            curve: LiquidMotion.contract, at: t, into: &out)
        set([.liquid(.budGap): Double(LiquidMotion.sinkGap)], curve: LiquidMotion.reach, at: t, into: &out)
        set([.liquid(.lipBody): Double(LiquidPath.tension), .liquid(.lipBead): Double(LiquidPath.tension)], curve: LiquidMotion.lipBody, at: t, into: &out)
        scheduleRise(from: t + LiquidMotion.riseAt)
    }

    /// A close with the bud out: the card's bud contracts to a bead at once and rises as soon as it is one, joining
    /// through the neck, and the body's narrowing under the pill waits until it is in (`narrowWaits`).
    fileprivate mutating func budClose(at t: TimeInterval, into out: inout [Command]) {
        let p = liquid(at: t)
        let r = LiquidMotion.closeBead
        if p.isJoined {
            set([.liquid(.budHalf): Double(r - LiquidMotion.beadNarrow), .liquid(.budHeight): Double(2 * r), .liquid(.budRadius): Double(r)],
                curve: LiquidMotion.closeContract, at: t, into: &out)
            set([.liquid(.budGap): -Double(2 * r + 8)], curve: LiquidMotion.closeRise, at: t, into: &out)
            scheduleBudIn(at: t)
            return
        }
        set([.liquid(.budHalf): Double(r - LiquidMotion.beadNarrow), .liquid(.budHeight): Double(2 * r), .liquid(.budRadius): Double(r)],
            curve: LiquidMotion.closeContract, at: t, into: &out)
        set([.liquid(.lipBody): Double(LiquidPath.tension), .liquid(.lipBead): Double(LiquidPath.tension)], curve: LiquidMotion.lipBody, at: t, into: &out)
        scheduleRise(from: t)
    }

    /// The rise once the contracting card is a bead, no sooner than `from`.
    fileprivate mutating func scheduleRise(from t: TimeInterval) {
        jobs.removeAll { $0.step == .liquid(.rise) }
        let when = firstTime(from: t) { model, s in LiquidPath.flatTop(model.liquid(at: s)) <= LiquidMotion.beadFlat } ?? t
        schedule(.liquid(.rise), at: when, tag: .bud)
    }

    /// The join, once the stubs meet and the bud is a bead (`LiquidPath.canJoin`), solved from the springs as they are.
    fileprivate mutating func scheduleJoin(at t: TimeInterval) {
        jobs.removeAll { $0.step == .liquid(.join) }
        guard let when = firstTime(from: t, where: { model, s in LiquidPath.canJoin(model.liquid(at: s)) }) else { return }
        schedule(.liquid(.join), at: when, tag: .bud)
    }

    /// The gulp (or, closing, its going) once the bud is all inside the body.
    fileprivate mutating func scheduleBudIn(at t: TimeInterval) {
        jobs.removeAll { $0.step == .liquid(.gulp) }
        let when = firstTime(from: t) { model, s in LiquidPath.budInside(model.liquid(at: s)) } ?? t + IslandMotion.horizon
        schedule(.liquid(.gulp), at: when, tag: .bud)
    }

    /// The card's parts come into focus as the spreading bud uncovers them: the header once the bud's bottom is past
    /// `edgeDepth` of it and the bud is most of its width, the body likewise.
    fileprivate mutating func scheduleBudReveals(at t: TimeInterval) {
        if planning { return }
        guard let rest = budRestParams else { return }
        jobs.removeAll { $0.step == .reveal(.cardHeader) || $0.step == .reveal(.cardBody) }
        let top = LiquidMotion.budInsetTop + 2
        let header = layout.cardID == budCard ? layout.parts[.cardHeader]?.height ?? 30 : 30
        let body = layout.cardID == budCard ? layout.parts[.cardBody]?.height ?? 0 : 0
        var previous = t, first = true
        for (part, line) in [(PartID.cardHeader, top + IslandMotion.edgeDepth * header), (.cardBody, top + header + IslandMotion.edgeDepth * body)]
            where target(.part(part)) < 1 {
            let from = first ? previous : previous + IslandMotion.cardBody
            let when = firstTime(from: from) { model, s in
                let p = model.liquid(at: s)
                return !p.isJoined && p.budHeight >= line && p.budHalf >= LiquidMotion.budUncovers * rest.budHalf
            } ?? from + 0.2
            schedule(.reveal(part), at: when, tag: .card)
            previous = when
            first = false
        }
    }

    /// The card measured in its bud (or another card's content in it): the bud takes its height, and its parts' reveals
    /// are solved again.
    fileprivate mutating func budMeasured(at t: TimeInterval, into out: inout [Command]) {
        guard budding, let rest = budRestParams else { return }
        if metrics.reduceMotion {
            if abs(target(.liquid(.budHeight)) - Double(rest.budHeight)) > 0.01 { snap([.liquid(.budHeight): Double(rest.budHeight)], into: &out) }
            exactPanel(into: &out)
            return
        }
        // Only once it has spread (a bead still growing spreads to the height it has then).
        guard abs(target(.liquid(.budHalf)) - Double(rest.budHalf)) < 0.01, abs(target(.liquid(.budHeight)) - Double(rest.budHeight)) > 0.01 else { return }
        set([.liquid(.budHeight): Double(rest.budHeight)], curve: LiquidMotion.resize, at: t, into: &out)
        if jobs.contains(where: { $0.step == .reveal(.cardHeader) || $0.step == .reveal(.cardBody) }) { scheduleBudReveals(at: t) }
        scheduleFit(at: t)
    }

    /// The open: the pill's bottom balloons into a belly that leads the edge and flattens as the body arrives, the
    /// corners rounder while it moves; a reservoir a close left stays until the body is past it. The belly and the
    /// corners lead only the travel the body still has: an open that reverses a close before its fold has started has
    /// none to lead (no belly under an island that is not moving), and one past most of its way has little. A bud still
    /// out (a close with the bud out, reopened before the bead is in) leads with none either: the belly and the neck never
    /// draw at once, and a belly held back under a joined bead would appear at once as the bead goes deep (P669); the
    /// gulp's own belly follows the bead in.
    fileprivate mutating func liquidOpen(belly: Bool = true, at t: TimeInterval, into out: inout [Command]) {
        let rest = restGeometry.height, from = targets.closed.height
        let travel = rest > from + 1 ? min(1, max(0, (rest - CGFloat(value(.height, at: t))) / (rest - from))) : 0
        let lead = travel <= LiquidMotion.leadFloor || !belly || liquid(at: t).budShows ? 0 : travel
        if lead > 0 {
            set([.liquid(.sag): Double(LiquidMotion.openSag * lead)], curve: LiquidMotion.sagIn, at: t, into: &out)
            set([.liquid(.round): Double(LiquidMotion.openRound * lead)], curve: LiquidMotion.roundIn, at: t, into: &out)
            schedule(.liquid(.sagOut), at: t + LiquidMotion.sagOutAt, tag: .liquid)
            schedule(.liquid(.firm), at: t + LiquidMotion.firmAt, tag: .liquid)
        } else {
            liquidSettle(at: t, into: &out)
        }
        scheduleDrained(at: t)
    }

    /// The close: a belly an open left goes at once; the body folds and narrows under the pill after the lag
    /// (`LiquidBeat.close`).
    fileprivate mutating func liquidClose(at t: TimeInterval, lag: TimeInterval, into out: inout [Command]) {
        if target(.liquid(.sag)) != 0 || abs(value(.liquid(.sag), at: t)) > 0.01 {
            set([.liquid(.sag): 0], curve: LiquidMotion.sagOut, at: t, into: &out)
        }
        schedule(.liquid(.close), at: t + lag, tag: .fold)
    }

    /// The belly and the corners back to nothing (a flick back, the top bar's close).
    fileprivate mutating func liquidSettle(at t: TimeInterval, into out: inout [Command]) {
        for (key, curve) in [(LiquidKey.sag, LiquidMotion.sagOut), (.round, LiquidMotion.firm)]
            where target(.liquid(key)) != 0 || abs(value(.liquid(key), at: t)) > 0.01 {
            set([.liquid(key): 0], curve: curve, at: t, into: &out)
        }
    }

    /// Everything of Liquid's at once to nothing, its beats cancelled (hiding, Reduce Motion or another feel mid-motion):
    /// a jump at most, never a spill.
    fileprivate mutating func liquidRetire(at t: TimeInterval, into out: inout [Command]) {
        jobs.removeAll { if case .liquid = $0.step { true } else { false } }
        cancel(.liquid, .bud)
        reservoir = nil
        narrowWaits = false
        let own = values.keys.filter(\.isLiquid)
        for channel in own { values[channel] = nil }
    }

    /// Liquid stops mid-motion (Reduce Motion turned on, another Motion chosen): a close draining into the pill lands in
    /// it at once.
    fileprivate mutating func liquidStop(at t: TimeInterval, into out: inout [Command]) {
        let draining = reservoir != nil || jobs.contains { [.liquid(.close), .liquid(.narrow), .liquid(.land)].contains($0.step) }
        liquidRetire(at: t, into: &out)
        guard draining, surface == .closed else { return }
        snapSurface(restGeometry, at: t, into: &out)
        scheduleShoulders(at: t, into: &out)
        if !hiding { schedulePillGate(at: t) }
        scheduleFit(at: t)
    }

    fileprivate mutating func reduceMotionChanged(_ on: Bool, at t: TimeInterval, into out: inout [Command]) {
        let was = metrics.reduceMotion
        metrics.reduceMotion = on
        guard on, !was, tuning.liquid else { return }
        liquidStop(at: t, into: &out)
        // A card in its bud stays there (Reduce Motion keeps Liquid's layout), still; one merging back is in.
        if budding {
            snapBudRest(into: &out)
            snap([.part(.cardHeader): 1, .part(.cardBody): 1], into: &out)
            exactPanel(into: &out)
        }
    }

    fileprivate mutating func tuningChanged(_ new: MotionTuning, at t: TimeInterval, into out: inout [Command]) {
        let bud = budCard != nil
        if tuning.liquid, !new.liquid { liquidStop(at: t, into: &out) }
        metrics.tuning = new
        // Another Motion with a card in its bud: the card presents in the body, as that Motion has it, at once (a
        // settings change, never a motion).
        guard bud, !new.liquid else { return }
        budCard = nil
        budBase = nil
        let rest = snapToRest(at: t)
        out.append(.panel(panel))
        out.append(.target(restGeometry, isOpen: surface == .island))
        out.append(.animate(nil, rest))
    }

    fileprivate mutating func runLiquid(_ beat: LiquidBeat, at t: TimeInterval, into out: inout [Command]) {
        switch beat {
        case .sagOut:
            set([.liquid(.sag): 0], curve: LiquidMotion.sagOut, at: t, into: &out)
            scheduleFit(at: t)
        case .firm:
            set([.liquid(.round): 0], curve: LiquidMotion.firm, at: t, into: &out)
            scheduleFit(at: t)
        case .close:
            // The reservoir set to the pill; the height folds. The width narrows under it (the bottom a U) once the body
            // hangs within `narrowReach` of the pill: a taller island folds its width as Refined's does until then, so it
            // becomes a drop only in its last points and never a column under flat wings.
            let g = restGeometry
            reservoir = g
            set([.height: g.height, .radius: g.radius, .rimLift: rimLift(g.height)], curve: LiquidMotion.foldHeight, at: t, into: &out)
            // It lands once it hangs `landHang` below the pill (solved from the height's spring).
            let land = Double(g.height + LiquidMotion.landHang)
            let landing = firstTime(from: t) { model, s in model.value(.height, at: s) <= land } ?? t + LiquidMotion.landAt
            schedule(.liquid(.land), at: max(landing, t + LiquidMotion.landAfterNarrow), tag: .liquid)
            let hang = Double(g.height + LiquidMotion.narrowReach)
            if liquid(at: t).budShows {
                // The bud's bead is still out: the body folds as Refined's, and narrows once it is in.
                set([.left: g.left, .right: g.right, .ear: g.ear], curve: tuning.fold, at: t, into: &out)
                narrowWaits = true
            } else if value(.height, at: t) > hang + 0.5 {
                set([.left: g.left, .right: g.right, .ear: g.ear], curve: tuning.fold, at: t, into: &out)
                let when = firstTime(from: t) { model, s in model.value(.height, at: s) <= hang } ?? t
                schedule(.liquid(.narrow), at: when, tag: .liquid)
            } else {
                runLiquid(.narrow, at: t, into: &out)
            }
            scheduleShoulders(at: t, into: &out)
        case .narrow:
            // Too late once it has landed, and while the bud's bead is still out it waits for it.
            guard reservoir != nil, jobs.contains(where: { $0.step == .liquid(.land) }) else { return }
            if liquid(at: t).budShows {
                narrowWaits = true
                return
            }
            // Once the bud's bead is in, a body already near the pill folds on as Refined's: a drop needs room to form.
            let late = narrowWaits && value(.height, at: t) <= Double(restGeometry.height + LiquidMotion.dropRoom)
            narrowWaits = false
            if late { return }
            let g = restGeometry
            set([.left: g.left * LiquidMotion.narrowShare, .right: g.right * LiquidMotion.narrowShare, .ear: g.ear],
                curve: LiquidMotion.narrow, at: t, into: &out)
            set([.liquid(.round): Double(LiquidMotion.closeRound)], curve: LiquidMotion.roundIn, at: t, into: &out)
            scheduleShoulders(at: t, into: &out)
            if let i = jobs.firstIndex(where: { $0.step == .liquid(.land) }) { jobs[i].time = max(jobs[i].time, t + LiquidMotion.landAfterNarrow) }
        case .land:
            // It lands in the pill, its walls a little past the pill's and back (a soft splash), so it holds the pill
            // before it has risen into it and the reservoir leaves with nothing of it drawn; the pill's glyph and count
            // come in on the land.
            let g = restGeometry
            set([.left: g.left, .right: g.right, .ear: g.ear], curve: LiquidMotion.land, at: t, into: &out)
            set([.liquid(.round): 0], curve: LiquidMotion.landRound, at: t, into: &out)
            scheduleShoulders(at: t, into: &out)
            if !hiding { schedulePillGate(at: t) }
            scheduleDrained(at: t)
            scheduleFit(at: t)
        case .drained:
            reservoir = nil
            scheduleFit(at: t)
        case .budSeed:
            // The bead goes in just inside the bottom edge once the open's belly has gone (the two never draw at once).
            guard budding, !liquid(at: t).budShows else { return run(.liquid(.budStart), at: t, into: &out) }
            if value(.liquid(.sag), at: t) > 0.25 {
                // A gulp's belly still out (a card back into a bud just taken in): it flattens first.
                if target(.liquid(.sag)) != 0 { set([.liquid(.sag): 0], curve: LiquidMotion.gulpOut, at: t, into: &out) }
                let when = firstTime(from: t) { model, s in model.value(.liquid(.sag), at: s) <= 0.25 } ?? t + IslandMotion.horizon
                schedule(.liquid(.budSeed), at: when, tag: .bud)
                return
            }
            let r = LiquidMotion.beadSeed
            if abs(value(.liquid(.sag), at: t)) > 0.001 || target(.liquid(.sag)) != 0 { snap([.liquid(.sag): 0], into: &out) }
            snap([.liquid(.budGap): Double(LiquidMotion.seedGap), .liquid(.budHalf): Double(r), .liquid(.budHeight): Double(2 * r),
                  .liquid(.budRadius): Double(r), .liquid(.joined): 1, .liquid(.lipBody): 0, .liquid(.lipBead): 0,
                  .liquid(.tension): Double(LiquidPath.tension)], into: &out)
            schedule(.liquid(.budStart), at: t + LiquidMotion.budStartAt, tag: .bud)
        case .budStart:
            // Joined: the bead grows and falls, the neck thins and pinches (solved), and it spreads after. Apart: it
            // spreads now.
            guard budding else { return }
            let p = liquid(at: t)
            guard p.isJoined else { return run(.liquid(.spread), at: t, into: &out) }
            let r = LiquidMotion.beadRadius
            set([.liquid(.budHalf): Double(r), .liquid(.budHeight): Double(2 * r), .liquid(.budRadius): Double(r)], curve: LiquidMotion.bead,
                at: t, into: &out)
            set([.liquid(.budGap): Double(LiquidMotion.fallGap)], curve: LiquidMotion.fall, at: t, into: &out)
            if value(.liquid(.tension), at: t) != Double(LiquidPath.tension) {
                set([.liquid(.tension): Double(LiquidPath.tension)], curve: LiquidMotion.firm, at: t, into: &out)
            }
            let pinch = firstTime(from: t) { model, s in LiquidPath.pinched(model.liquid(at: s)) }
            if let pinch { schedule(.liquid(.pinch), at: pinch, tag: .bud) }
            let spread = max(t + LiquidMotion.spreadAt - LiquidMotion.budStartAt, (pinch ?? t) + LiquidMotion.spreadAfterPinch)
            schedule(.liquid(.spread), at: spread, tag: .bud)
        case .pinch:
            // The neck lets go: the joined outline at its pinch is the two stubs at the neck's radius, which retract.
            let k = max(0, value(.liquid(.tension), at: t))
            snap([.liquid(.joined): 0, .liquid(.lipBody): k, .liquid(.lipBead): k], into: &out)
            set([.liquid(.lipBody): 0], curve: LiquidMotion.lipBody, at: t, into: &out)
            set([.liquid(.lipBead): 0], curve: LiquidMotion.lipBead, at: t, into: &out)
        case .spread:
            // Never before the pinch: a bead still joined waits for it.
            guard let rest = budRestParams else { return }
            if liquid(at: t).isJoined {
                if !jobs.contains(where: { $0.step == .liquid(.pinch) }) {
                    let pinch = firstTime(from: t) { model, s in LiquidPath.pinched(model.liquid(at: s)) } ?? t
                    schedule(.liquid(.pinch), at: pinch, tag: .bud)
                }
                let when = jobs.first(where: { $0.step == .liquid(.pinch) }).map { $0.time + LiquidMotion.spreadAfterPinch } ?? t
                schedule(.liquid(.spread), at: max(when, t + 0.001), tag: .bud)
                return
            }
            set([.liquid(.budHalf): Double(rest.budHalf), .liquid(.budHeight): Double(rest.budHeight)], curve: LiquidMotion.spread, at: t, into: &out)
            set([.liquid(.budRadius): Double(rest.budRadius)], curve: LiquidMotion.firm, at: t, into: &out)
            set([.liquid(.budGap): Double(rest.budGap)], curve: LiquidMotion.budRise, at: t, into: &out)
            var lips: [Channel: Double] = [:]
            if target(.liquid(.lipBody)) != 0 { lips[.liquid(.lipBody)] = 0 }
            if target(.liquid(.lipBead)) != 0 { lips[.liquid(.lipBead)] = 0 }
            if !lips.isEmpty { set(lips, curve: LiquidMotion.lipBody, at: t, into: &out) }
            scheduleBudReveals(at: t)
            scheduleFit(at: t)
        case .budFade:
            set([.part(.cardHeader): 0, .part(.cardBody): 0], curve: IslandMotion.focusOut, at: t, into: &out)
        case .rise:
            // A bead: up into the body, the stubs meeting it (the join solved); joined already, it rises straight in.
            let p = liquid(at: t)
            guard p.budShows else { return run(.liquid(.budGone), at: t, into: &out) }
            let closing = surface == .closed
            let r = closing ? LiquidMotion.closeBead : LiquidMotion.mergeBead
            let curve = closing ? LiquidMotion.closeRise : LiquidMotion.rise
            if p.isJoined {
                set([.liquid(.budHalf): Double(r - LiquidMotion.beadNarrow), .liquid(.budHeight): Double(2 * r), .liquid(.budRadius): Double(r)],
                    curve: closing ? LiquidMotion.closeContract : LiquidMotion.contract, at: t, into: &out)
            }
            set([.liquid(.budGap): -Double(2 * r + 8)], curve: curve, at: t, into: &out)
            if p.isJoined {
                scheduleBudIn(at: t)
            } else {
                if target(.liquid(.lipBody)) != Double(LiquidPath.tension) || target(.liquid(.lipBead)) != Double(LiquidPath.tension) {
                    set([.liquid(.lipBody): Double(LiquidPath.tension), .liquid(.lipBead): Double(LiquidPath.tension)], curve: LiquidMotion.lipBody,
                        at: t, into: &out)
                }
                scheduleJoin(at: t)
            }
        case .join:
            // The stubs meet on a bead: joined, with the neck's radius they have (the same outline), the stubs gone.
            let p = liquid(at: t)
            guard !p.isJoined, let k = LiquidPath.joinTension(p) else { return scheduleBudIn(at: t) }
            snap([.liquid(.joined): 1, .liquid(.tension): Double(k), .liquid(.lipBody): 0, .liquid(.lipBead): 0], into: &out)
            set([.liquid(.tension): Double(LiquidPath.tension)], curve: LiquidMotion.firm, at: t, into: &out)
            scheduleBudIn(at: t)
        case .gulp:
            // All in: the body swallows it (a small belly, open only) and the bud goes; a close's narrowing goes on.
            guard LiquidPath.budInside(liquid(at: t)) else { return scheduleBudIn(at: t) }
            snapBudAway(into: &out)
            if surface == .island, !budding {
                set([.liquid(.sag): Double(LiquidMotion.gulpSag)], curve: LiquidMotion.sagIn, at: t, into: &out)
                schedule(.liquid(.gulpOut), at: t + LiquidMotion.gulpOutAfter, tag: .bud)
            }
            if narrowWaits { run(.liquid(.narrow), at: t, into: &out) }
            scheduleFit(at: t)
        case .gulpOut:
            set([.liquid(.sag): 0], curve: LiquidMotion.gulpOut, at: t, into: &out)
            scheduleFit(at: t)
        case .budGone:
            snapBudAway(into: &out)
            if narrowWaits { run(.liquid(.narrow), at: t, into: &out) }
            scheduleFit(at: t)
        case .tension:
            break
        }
    }

    /// The reservoir goes once it draws nothing of its own (`LiquidPath.drawsNothing`): the body holds it (landed on it,
    /// swollen past it, or opened past it). Solved from the springs as they are now, at the plan's own samples.
    fileprivate mutating func scheduleDrained(at t: TimeInterval) {
        jobs.removeAll { $0.step == .liquid(.drained) }
        guard reservoir != nil else { return }
        // At the plan's own samples (the reservoir goes where one of them draws nothing of it).
        var when = t + IslandMotion.horizon
        var s = t
        while s <= t + IslandMotion.horizon {
            if reservoirDrawsNothing(at: s) { when = s; break }
            s += Self.planStep
        }
        schedule(.liquid(.drained), at: when, tag: .liquid)
    }

    func reservoirDrawsNothing(at s: TimeInterval) -> Bool {
        guard let pill = reservoir else { return true }
        return LiquidPath.drawsNothing(pill, body: surface(at: s), round: CGFloat(value(.liquid(.round), at: s)))
    }

    /// Whether anything of Liquid's moves, waits or draws at `t`.
    func liquidActive(at t: TimeInterval) -> Bool {
        reservoir != nil || jobs.contains { if case .liquid = $0.step { true } else { false } }
            || values.contains { $0.key.isLiquid && ($0.value.curve != nil || abs($0.value.target - Self.defaultValue($0.key)) > 1e-9) }
    }

    /// Motion: Liquid, after an event: the panel takes in the plan's greatest union (`LiquidPath.bounds` at every
    /// sample), rounded out to whole points and one more, before the belly, the pill or the bud reaches it. The plan is
    /// kept for the director, which hands it to the outline (`surfacePlan`).
    fileprivate mutating func growForLiquid(at t: TimeInterval, into out: inout [Command]) {
        liquidPlan = nil
        guard tuning.liquid, !planning, !metrics.reduceMotion, liquidActive(at: t) else { return }
        let plan = surfacePlan(from: t, step: Self.planStep)
        liquidPlan = (version, plan)
        guard let liquid = plan.liquid, plan.drawsLiquid else { return }
        var reach = IslandExtent.zero
        for (g, p) in zip(plan.surface, liquid) where !p.isRest { reach = reach.union(LiquidPath.bounds(g, p)) }
        // A panel that already holds it, to the fit's own tolerance, stays (a resize is the trigger turn's dearest step:
        // 6 to 9 ms of a merge's, P667); one that does not grows past it by a point, and fits again once the motion rests.
        guard !panel.contains(reach, tolerance: IslandMotion.fitTolerance) else { return }
        let need = panel.union(IslandExtent(left: reach.left.rounded(.up) + 1, right: reach.right.rounded(.up) + 1,
                                            height: reach.height.rounded(.up) + 1))
        guard need != panel else { return }
        panel = need
        out.append(.panel(need))
        if !jobs.contains(where: { $0.step == .fit }) { scheduleFit(at: t) }
    }
}
