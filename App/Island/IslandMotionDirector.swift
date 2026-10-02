import Foundation
import SwiftUI

/// Carries out the island's choreography (spec §8.4): a thin executor around the pure `IslandChoreography`. It sends
/// events into the model and applies the commands that come back in order (E5): a panel growth first, then every write
/// of the batch (the target, the values, the pill's snapshot, the glyph clocks, the leaving card and the card snapshot)
/// in one plain SwiftUI transaction, each channel on the curve its command gave it, which the modifier that draws the
/// channel scopes to its own effect (`ChannelFocus`, `ChannelOffset`, `IslandSurfaceClip`, the pill's), a snap a true
/// snap (`ChannelMotion.snap`); the panel's other sizes, the pill's snapshot on a curve and the controller's other effects
/// (order in or out, the post-fold reset) where they fall (`transactions(_:)`). It keeps one strict timer for the model's
/// next job, so nothing ticks at rest. An event sent while a batch is being applied (a panel snap or a new target moves
/// the shape under the pointer, and the hover machine answers at once) waits until that batch is done, so no batch is
/// ever applied inside another and left to land stale after it. It also gathers the island's measurements into one
/// `ContentLayout` per run-loop turn, never inside a SwiftUI update.
/// With Core Animation's outline (`surface`) it hands the model to the render server after every event and reset, and
/// checks it after every job.
@MainActor
final class IslandMotionDirector {
    private(set) var model: IslandChoreography
    private let ui: IslandUIState
    /// Snaps the panel to a size (the controller's `applyPanel`).
    var applyPanel: (IslandExtent) -> Void = { _ in }
    /// Order in or out, the post-fold reset, the card snapshot: the controller's side.
    var perform: (IslandChoreography.Effect) -> Void = { _ in }
    /// The island has come to rest: the model's last step (its fit) ran, in the turn before this one (E4: a card waiting
    /// to be built ahead is built now, never inside a motion).
    var rested: () -> Void = {}
    /// Whether the model had a step still to run after the last batch.
    private var moving = false
    /// The target changed: the pointer may now be on the other side of it.
    var targetChanged: () -> Void = {}
    /// Diagnostics › Motion: records each motion, or asks for 120 Hz while it runs (`MotionRecorder`). nil, the default,
    /// costs nothing.
    var recorder: MotionRecorder?
    /// Each job as its timer fires: when it was due and when it fired (model time), and the steps it runs. nil, the
    /// default, costs nothing; measurements and tests read the lateness here.
    var onJob: (@MainActor (_ due: TimeInterval, _ fired: TimeInterval, _ steps: [IslandChoreography.Step]) -> Void)?
    /// The model's clock and the timer for its next job (`StrictJobClock`: real time, a strict timer set for the job's
    /// own moment).
    let clock: any IslandJobClock
    private var timer: (any IslandTimerToken)?
    /// The panel's size as last applied: a batch's growth is applied before its writes (`panelFirst`).
    private var panel: IslandExtent
    /// Events sent while a batch is being applied, handled in order once it is done.
    private var queued: [IslandChoreography.Event] = []
    private var applying = false
    private var measuring: ContentLayout?
    private var cardInset: CGFloat?
    /// The views that hold each part (`IslandMeasure.part`), the one that reported last at the end, with the frame each
    /// reported: a part goes only when the last of them goes, and until then has the frame of the one that reported
    /// last. Two views can hold a part for an update (the opened island rebuilt, Motion changed, P307), and report in
    /// either order: the old one's frame after the new one's, then its going.
    private var holders: [PartID: [(owner: Int, rect: CGRect)]] = [:]
    /// Diagnostics › Motion › Outline: Core Animation's layers, which play the model's plan for the surface from each
    /// event's own time (`IslandSurfaceLayers.play`) and check it after each job. nil: SwiftUI draws the outline from the
    /// values written here, as ever. The surface's values are written either way (no view reads them with Core
    /// Animation's), so switching needs nothing else.
    var surface: IslandSurfaceLayers?
    /// The last event's time in the batch being applied, for its plan.
    private var eventAt: TimeInterval?

    /// The model's clock: real time, slowed by `IslandMotion.slowdown` in a debug build.
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime / IslandMotion.slowdown }

    init(model: IslandChoreography, ui: IslandUIState, clock: any IslandJobClock = StrictJobClock()) {
        self.model = model
        self.ui = ui
        self.clock = clock
        panel = model.panel
    }

    /// A fresh model (a new display, a new show): the view snaps to its rest, the panel to its size.
    func reset(_ model: IslandChoreography) {
        timer?.cancel()
        timer = nil
        recorder?.interrupt()
        self.model = model
        Self.snap(ui, to: model, at: clock.now)
        panel = model.panel
        applyPanel(model.panel)
        targetChanged()
        noteRest()
        eventAt = nil
        surface?.play(model, at: clock.now)
        if surface == nil { playLiquid(at: clock.now) }
    }

    func send(_ event: IslandChoreography.Event) {
        guard !applying else {
            queued.append(event)
            return
        }
        let t = clock.now
        eventAt = t
        apply(model.handle(event, at: t))
        rearm()
        noteRest()
        recorder?.observe(event.recordName)
        surfaceMoved(job: false)
    }

    /// Core Animation's outline: an event (or one queued meanwhile) plays the new plan from its own time; a job alone
    /// only checks the model is still on it.
    private func surfaceMoved(job: Bool) {
        if let t = eventAt {
            eventAt = nil
            surface?.play(model, at: t)
            if surface == nil { playLiquid(at: t) }
        } else if job {
            surface?.check(model, at: clock.now)
            if surface == nil { checkLiquid(at: clock.now) }
        }
    }

    /// Motion: Liquid on SwiftUI's outline: the model's plan to the ticker (`LiquidBox`), from `t`; nothing to play
    /// while nothing of Liquid's moves.
    private func playLiquid(at t: TimeInterval) {
        guard model.tuning.liquid else {
            if ui.liquid.params != nil { ui.liquid.show(nil) }
            return
        }
        guard model.liquidActive(at: t) else {
            if ui.liquid.params != model.liquid(at: t) || ui.liquid.playing { ui.liquid.show(model.liquid(at: t)) }
            return
        }
        ui.liquid.play(model.surfacePlan(from: t, step: IslandChoreography.planStep), at: t)
    }

    /// After a job: the ticker's plan must still be the model's (it ran the same jobs ahead); a difference plays the
    /// model again.
    private func checkLiquid(at t: TimeInterval) {
        guard model.tuning.liquid else { return }
        guard let plan = ui.liquid.plan else {
            if model.liquidActive(at: t) { playLiquid(at: t) }
            return
        }
        guard let liquid = plan.liquid, !liquid.isEmpty else { return playLiquid(at: t) }
        // At the plan's own samples, where it is the model exactly, and only before the model's next step that moves
        // the surface, which its springs do not know of yet.
        let now = Int(((t - plan.start) / plan.step).rounded(.up))
        let next = model.jobs.filter(\.step.movesSurface).map(\.time).min() ?? .infinity
        for ahead in [0, 12, 48] {
            let i = min(max(0, now + ahead), liquid.count - 1)
            let s = max(t, plan.start + Double(i) * plan.step)
            guard ahead == 0 || s < next - 1e-9 else { break }
            if LiquidParams.distance(model.liquid(at: s), liquid[i]) > 0.01 { return playLiquid(at: t) }
        }
    }

    /// One measurement of the live island; they are gathered and sent as one `.content` a turn later.
    func measured(_ measure: IslandMeasure) {
        var layout = measuring ?? model.layout
        switch measure {
        case let .header(height): layout.header = height
        case let .list(height): layout.list = height
        case let .card(id, height):
            layout.card = height
            layout.cardID = id
        case let .part(part, rect?, owner):
            layout.parts[part] = rect
            holders[part, default: []].removeAll { $0.owner == owner }
            holders[part, default: []].append((owner, rect))
        case let .part(part, nil, owner):
            // A view that goes while another still holds the part takes nothing away: the part keeps the other's frame.
            holders[part]?.removeAll { $0.owner == owner }
            if let last = holders[part]?.last {
                layout.parts[part] = last.rect
            } else {
                holders[part] = nil
                layout.parts[part] = nil
            }
        case let .insets(row, card):
            layout.rowInset = row
            cardInset = card
        case let .lazyRows(ids):
            layout.lazyRows = ids
        }
        if let cardInset { layout.cardHeaderTop = layout.header + cardInset }
        let first = measuring == nil
        measuring = layout
        guard first else { return }
        Task { @MainActor [weak self] in self?.flushMeasurements() }
    }

    /// Sends what was gathered as one `.content` (a turn after the first measurement; renders call it at once).
    func flushMeasurements() {
        guard let layout = measuring else { return }
        measuring = nil
        guard layout != model.layout else { return }
        send(.content(layout))
    }

    /// Applies `commands`, then the batch of each event sent meanwhile, in order, each with its panel growth first.
    private func apply(_ commands: [IslandChoreography.Command]) {
        applying = true
        defer { applying = false }
        var batch = commands
        while true {
            for write in Self.transactions(Self.panelFirst(batch, from: panel)) { run(write) }
            guard !queued.isEmpty else { return }
            let event = queued.removeFirst()
            let t = clock.now
            eventAt = t
            batch = model.handle(event, at: t)
            recorder?.observe(event.recordName)
        }
    }

    private func run(_ write: Write) {
        switch write {
        case let .other(.panel(extent)):
            panel = extent
            applyPanel(extent)
        case let .other(.effect(effect)):
            perform(effect)
        case .other:
            break
        case let .writes(commands):
            // The card snapshot is the controller's (it finds the card), inside the batch's transaction: the card built
            // ahead goes live in the same update as the channels that bring it in and the leaving card's that fade the
            // other out, so neither is drawn a frame with the other's focus (E4(c), P231).
            Self.write(commands, to: ui) { [perform] effect in perform(effect) }
            if commands.contains(where: { if case .target = $0 { true } else { false } }) { targetChanged() }
        case .pill, .list:
            Self.write(write, to: ui)
        }
    }

    /// `commands` with the panel's growth first (E2): the panel snaps with `setFrame(display: true)`, which brings the
    /// views up to date with whatever was written before it, so a snap after the batch's still write (the open's target
    /// and glyph clock) paid for that update as well (1.7 ms against 0.8, the motion research). A growth only ever takes
    /// in more than the panel held, so nothing drawn before the batch's writes is cut; the first panel that is not a
    /// growth (a shrink once the shape fits) stays where the model put it, after the writes it waits for, and so does
    /// every panel after it.
    static func panelFirst(_ commands: [IslandChoreography.Command], from panel: IslandExtent) -> [IslandChoreography.Command] {
        var growths: [IslandChoreography.Command] = [], rest: [IslandChoreography.Command] = []
        var held = panel, growing = true
        for command in commands {
            if growing, case let .panel(extent) = command {
                if extent.contains(held) {
                    growths.append(command)
                    held = extent
                    continue
                }
                growing = false
            }
            rest.append(command)
        }
        return growths + rest
    }

    /// One SwiftUI transaction of a batch (`transactions(_:)`).
    enum Write: Equatable {
        /// Writes in one plain transaction, in order: the target, the values (each channel on its own curve, or a true
        /// snap), the pill's still snapshot, the glyph clocks, the leaving card and the card snapshot.
        case writes([IslandChoreography.Command])
        /// The pill's snapshot on a curve: its own `withAnimation`, so its wings resize (and its lead changes) on it.
        case pill(PillContent, IslandMotion.Curve)
        /// A list change (Show all, the strip): its own `withAnimation(curve)`, so what it moves in the list moves on the
        /// curve the edge follows (E6).
        case list(IslandChoreography.ListChange, IslandMotion.Curve?)
        /// The panel or an effect for the controller (order in or out, the post-fold reset): nothing written.
        case other(IslandChoreography.Command)
    }

    /// A batch's commands as SwiftUI transactions, in order (E5): every write is one plain transaction, since each
    /// channel's curve rides in its box and each extra transaction costs an update (three rows coming into focus at one
    /// moment once cost three, P102), split only where the panel snaps, the controller acts (order in or out, the post-fold
    /// reset), the pill's snapshot moves on a curve, a list change is written on its own (E6), or a channel is written
    /// again on another curve (a snap, then a spring from there: merged, the spring would start from where the channel
    /// was; the surface's five are two channels, its width and its height, since SwiftUI's outline animates each as one
    /// vector, `SurfaceBox`). A later value of a channel on the same curve wins.
    static func transactions(_ commands: [IslandChoreography.Command]) -> [Write] {
        var out: [Write] = [], pending: [IslandChoreography.Command] = []
        var written: [Channel: ChannelMotion] = [:]
        func flush() {
            guard !pending.isEmpty else { return }
            out.append(.writes(pending))
            pending = []
            written = [:]
        }
        for command in commands {
            switch command {
            case let .animate(curve, values):
                let motion = ChannelMotion(curve)
                let keys = Set(values.keys.map { Channel.surfaceWidth.contains($0) ? .left : Channel.surfaceHeight.contains($0) ? .height : $0 })
                if keys.contains(where: { written[$0].map { $0 != motion } ?? false }) { flush() }
                for key in keys { written[key] = motion }
                pending.append(command)
            case .target, .pillSnapshot(_, .none), .effect(.islandLive), .effect(.pillLive), .effect(.cardLeaving),
                 .effect(.cardSnapshot), .effect(.bud):
                pending.append(command)
            case let .pillSnapshot(pill, curve?):
                flush()
                out.append(.pill(pill, curve))
            case let .effect(.list(change, curve)):
                flush()
                out.append(.list(change, curve))
            case .panel, .effect:
                flush()
                out.append(.other(command))
            }
        }
        flush()
        return out
    }

    /// What `command` writes into the views' state, as the director writes it: in a plain transaction, each value on the
    /// curve its command gave it, a snap a true snap. Renders and tests replay a model through this, so they hold what the
    /// live island holds. The panel and the controller's effects write nothing (a card snapshot is theirs to write).
    static func write(_ command: IslandChoreography.Command, to ui: IslandUIState) {
        for write in transactions([command]) { self.write(write, to: ui) }
    }

    /// One transaction's writes into the views' state.
    static func write(_ write: Write, to ui: IslandUIState) {
        switch write {
        case let .writes(commands):
            self.write(commands, to: ui) { _ in }
        case let .pill(pill, curve):
            withAnimation(curve.animation) { ui.pill = pill }
        case let .list(change, curve):
            withAnimation(curve?.animation) {
                switch change {
                case .showAll: if !ui.showAll { ui.showAll = true }
                case let .strip(open): if ui.stripOpen != open { ui.stripOpen = open }
                }
            }
        case .other:
            break
        }
    }

    /// `commands` in one plain transaction (never one that disables animations: it would stop every channel's scoped
    /// curve, and leave a spring in flight running on under a snap, P230); a card snapshot goes to `perform`, in order.
    private static func write(_ commands: [IslandChoreography.Command], to ui: IslandUIState,
                              perform: (IslandChoreography.Effect) -> Void) {
        withTransaction(Transaction()) {
            for command in commands {
                if case let .effect(effect) = command, case .cardSnapshot = effect {
                    perform(effect)
                } else {
                    assign(command, to: ui)
                }
            }
        }
    }

    /// `command`'s values in the current transaction; one that changes nothing is not written, so nothing redraws.
    private static func assign(_ command: IslandChoreography.Command, to ui: IslandUIState) {
        switch command {
        case let .target(geometry, isOpen):
            if ui.target != geometry { ui.target = geometry }
            if ui.isOpen != isOpen { ui.isOpen = isOpen }
        case let .animate(curve, values):
            ui.apply(values, motion: ChannelMotion(curve))
        case let .pillSnapshot(pill, _):
            if ui.pill != pill { ui.pill = pill }
        case let .effect(.islandLive(on)):
            if ui.islandLive != on { ui.islandLive = on }
        case let .effect(.pillLive(on)):
            if ui.pillLive != on { ui.pillLive = on }
        case let .effect(.bud(base, hit)):
            if ui.budBase != base { ui.budBase = base }
            if ui.budHit != hit { ui.budHit = hit }
        case let .effect(.cardLeaving(id)):
            // The card layer's card as it is now moves to the leaving layer (the new card's snapshot comes after).
            let leaving = id.flatMap { ui.card?.sessionID == $0 ? ui.card : nil }
            if ui.leavingCard != leaving { ui.leavingCard = leaving }
        case .panel, .effect:
            break
        }
    }

    /// One timer, for the model's next job, set for the job's own moment (a strict timer: no leeway, E1).
    private func rearm() {
        timer?.cancel()
        timer = nil
        guard let due = model.nextJobTime else { return }
        timer = clock.schedule(at: due) { [weak self] in self?.fire(due: due) }
    }

    /// The timer for the job due at `due` fired: every job due by now runs, each at its own time (`advance(to:)`), so a
    /// late timer delays what is drawn, never where the model says it is.
    private func fire(due: TimeInterval) {
        timer = nil
        let fired = clock.now
        // A deadline read back through another clock's rounding may land a hair early: the job is due all the same.
        let t = max(fired, due)
        if onJob != nil || recorder != nil {
            let steps = model.dueSteps(by: t)
            onJob?(due, fired, steps)
            recorder?.jobFired(due: due, steps: steps.map(\.recordName))
        }
        apply(model.advance(to: t))
        rearm()
        noteRest()
        recorder?.observe(nil)
        surfaceMoved(job: true)
    }

    /// Tells `rested` once the model has no step left to run, a turn later (an idle turn, not the fit's own), and only
    /// if nothing has set it moving again by then.
    private func noteRest() {
        let now = model.inMotion
        defer { moving = now }
        guard moving, !now else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.model.inMotion else { return }
            self.rested()
        }
    }

    /// `ui` exactly as `model` is at `t` (a new display, renders): the channels in a true snap (in a plain transaction,
    /// P230), the rest with no animation; a part, a glide or a card the model does not know goes from the views too (P101).
    static func snap(_ ui: IslandUIState, to model: IslandChoreography, at t: TimeInterval) {
        var values = model.frame(at: t).values
        let held = ui.channels
        for part in held.parts.keys where values[.part(part)] == nil { values[.part(part)] = 0 }
        for id in held.glides.keys where values[.glide(id)] == nil { values[.glide(id)] = 0 }
        withoutAnimation {
            if model.cardMounted == nil { ui.card = nil }
            if model.cardLeaving == nil { ui.leavingCard = nil }
            ui.aheadCard = nil
            ui.target = model.restGeometry
            ui.isOpen = model.isOpen
            ui.pill = model.shownPill
            ui.islandLive = model.isOpen
            ui.pillLive = !model.isOpen
            ui.reduceMotion = model.metrics.reduceMotion
            if ui.tuning != model.tuning { ui.tuning = model.tuning }
            let bud = model.budState
            if ui.budBase != bud.base { ui.budBase = bud.base }
            if ui.budHit != bud.hit { ui.budHit = bud.hit }
        }
        withTransaction(Transaction()) { ui.apply(values, motion: .snap) }
        // Motion: Liquid: its outline where the model is at `t`, still.
        ui.liquid.show(model.tuning.liquid ? model.liquid(at: t) : nil)
    }

    /// Writes with no animation, and none of the views' own (`.animation(_:value:)`) either: never the channels (P230).
    static func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}
