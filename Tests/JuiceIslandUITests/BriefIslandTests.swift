import Foundation
import IslandEngine
import OpenIslandCore
import Testing
@testable import JuiceIslandUI

/// Hide the pill when idle hides it when no session is active (P94), not only when there are no rows: a day of
/// finished history no longer keeps it up, and the last finished session takes it away on the minute clock with the
/// motion's tuck, the next one bringing it back with the emerge.
@MainActor
@Suite(.serialized)
struct HideWhenIdleTests {
    static let now = ActiveCountTests.now
    static let notch = IslandTheme.Metrics.referenceNotch

    static func pill(_ rows: [SessionRow], hide: Bool = true, glance: Bool = false, now: Date = now) -> PillContent {
        let settings = AppSettings.ephemeral()
        settings.hidePillWhenIdle = hide
        return PillContent.make(rows: rows, settings: settings, glance: glance, recentlyFinished: nil, now: now, notch: notch,
                                menuBar: notch.height + 1)
    }

    static func row(_ id: String, _ bucket: SessionBucket, ago: TimeInterval, status: StatusWord? = nil) -> SessionRow {
        ActiveCountTests.row(id, .claude, bucket, ago: ago, status: status)
    }

    @Test func thePillHidesWhenNoSessionIsActive() {
        // Hours of finished rows: hidden with the setting on, the dim check without it (as before).
        let history = ActiveCountTests.thirtyRows.filter { !SessionActivity.isActive($0, now: Self.now) }
        #expect(history.count == 27)
        #expect(Self.pill(history).isEmpty)
        #expect(!Self.pill(history, hide: false).isEmpty && Self.pill(history, hide: false).lead?.dimmed == true)
        // A finished session keeps it up for 15 minutes, on either side of the minute.
        #expect(!Self.pill([Self.row("d", .done, ago: 14 * 60 + 59)] + history).isEmpty)
        #expect(Self.pill([Self.row("d", .done, ago: 15 * 60 + 1)] + history).isEmpty)
        #expect(Self.pill([Self.row("i", .done, ago: 15 * 60 + 1, status: .interrupted)]).isEmpty)
        // Running and waiting sessions keep it up however long ago they reported.
        #expect(!Self.pill([Self.row("r", .running, ago: 6 * 3_600)] + history).isEmpty)
        #expect(!Self.pill([Self.row("q", .needsYou, ago: 6 * 3_600)] + history).isEmpty)
        #expect(!Self.pill([Self.row("f", .needsYou, ago: 6 * 3_600, status: .failed)]).isEmpty)
        // No rows at all, and a Glance dot left from a session that has since aged out: hidden.
        #expect(Self.pill([]).isEmpty && Self.pill(history, glance: true).isEmpty)
        #expect(SessionActivity.isIdle([], now: Self.now) && SessionActivity.isIdle(history, now: Self.now))
    }

    /// The last finished session ages out on the models' minute tick, with no event of its own: the read the panel
    /// controller observes (the rows and the clock) changes, and the pill it builds from them is empty.
    @Test func theLastFinishedSessionHidesThePillOnTheMinuteTick() {
        var now = Self.now
        let engine = SessionEngine.preview(clock: { DemoClock.now })
        engine.loadPreviewEvents(ActiveCountTests.session("idle-done", finishedAt: Self.now - (14 * 60 + 30)))
        let model = EngineSessionsModel(engine: engine, clock: { now })
        func pill() -> PillContent { Self.pill(model.rows, now: model.now) }
        #expect(model.totalCount == 1 && !pill().isEmpty)
        let redraws = Redraws()
        redraws.watch { _ = model.rows; _ = model.now }

        now += 20
        model.tick()
        #expect(redraws.count == 0 && !pill().isEmpty)

        now += 60
        model.tick()
        #expect(redraws.count == 1 && pill().isEmpty && model.totalCount == 1)
    }

    // MARK: The motion

    typealias Model = IslandChoreography

    static func model(pill: PillContent, ordered: Bool = true) -> Model {
        Model(metrics: .init(targets: SurfaceTargets(notch: notch, pill: pill, hideWhenIdle: true),
                             layout: DIslandPanelSizingTests.layout()), ordered: ordered)
    }

    static var shown: PillContent { DIslandPanelSizingTests.pill() }
    static var empty: PillContent { DIslandPanelSizingTests.pill(count: nil, lead: nil) }

    /// Ages out: the glyph and the count slide back behind the notch, the wings tuck, and the panel orders out once the
    /// shape fits. Back: it orders in and the wings emerge.
    @Test func theIdlePillTucksAwayAndEmergesWithTheMotion() {
        let (gone, out) = Model.replay(Self.model(pill: Self.shown), [(0, .pill(Self.empty))], until: 2)
        #expect(out.contains { if case let .animate(curve, _) = $0 { curve == IslandMotion.tuck } else { false } })
        #expect(out.last { if case .effect(.orderOut) = $0 { true } else { false } } != nil)
        #expect(!gone.ordered && gone.shownPill.isEmpty)

        let (back, ins) = Model.replay(gone, [(3, .pill(Self.shown))], until: 5)
        #expect(ins.first { if case .effect(.orderIn) = $0 { true } else { false } } != nil)
        #expect(ins.contains { if case let .animate(curve, _) = $0 { curve == IslandMotion.emerge } else { false } })
        #expect(back.ordered && back.shownPill == Self.shown)
    }

    /// A session that needs you while the idle pill is hidden: the island opens, ordered in, whatever the pill does.
    @Test func somethingThatNeedsYouOpensTheHiddenIsland() {
        var model = Self.model(pill: Self.empty, ordered: false)
        let commands = model.handle(.open(.attention, .card(sessionID: "r1")), at: 0)
        #expect(commands.first { if case .effect(.orderIn) = $0 { true } else { false } } != nil)
        #expect(model.ordered && model.isOpen)
    }
}

/// The brief Done card (P95): a finished session's card (Card) opens as before and folds back into the pill by itself
/// after `doneCardLife`, held while the pointer is on the island; a newer finish restarts the one timer, and something
/// that needs you takes over and never closes by itself. The timeline runs the hover machine as the panel does, firing
/// every timer it asks for at its time (a stale generation is ignored).
struct BriefDoneCardTests {
    typealias M = IslandHoverMachine

    struct Timeline {
        var machine = M()
        var timers: [(at: TimeInterval, generation: Int)] = []
        var log: [(at: TimeInterval, effect: M.Effect)] = []

        /// Fires the timers due by `t`, then sends `event`.
        mutating func send(_ event: M.Event, at t: TimeInterval) {
            run(until: t)
            record(machine.handle(event), at: t)
        }

        mutating func run(until t: TimeInterval) {
            while let index = timers.indices.min(by: { timers[$0].at < timers[$1].at }), timers[index].at <= t + 1e-9 {
                let timer = timers.remove(at: index)
                record(machine.handle(.timerFired(generation: timer.generation, at: timer.at)), at: timer.at)
            }
        }

        private mutating func record(_ effects: [M.Effect], at t: TimeInterval) {
            for effect in effects {
                log.append((t, effect))
                if case let .schedule(delay, generation) = effect { timers.append((t + delay, generation)) }
            }
        }

        var opens: [TimeInterval] { log.compactMap { if case .open = $0.effect { $0.at } else { nil } } }
        var closes: [TimeInterval] { log.compactMap { if case .close = $0.effect { $0.at } else { nil } } }
    }

    @Test func itOpensAndClosesByItselfAtThreeSeconds() {
        var timeline = Timeline()
        timeline.send(.finished(at: 0), at: 0)
        #expect(timeline.log.map { $0.effect } == [.open(.attention), .schedule(after: 3, generation: timeline.machine.generation)])
        #expect(timeline.machine.brief && timeline.machine.openReason == .attention)
        timeline.run(until: 2.99)
        #expect(timeline.closes.isEmpty && timeline.machine.isOpen)
        timeline.run(until: 3)
        #expect(timeline.closes == [3])
        #expect(timeline.log.last?.effect == .close(.fold))
        #expect(timeline.machine.phase == .closed && !timeline.machine.brief)
        // Not a pointer close: no reverse; a rest opens it again.
        #expect(timeline.machine.foldStartedAt == nil && !timeline.machine.mustLeaveBeforeReopen)
    }

    @Test func thePointerOnTheIslandHoldsItAndALeaveClosesItAfterTheGrace() {
        var timeline = Timeline()
        timeline.send(.finished(at: 0), at: 0)
        timeline.send(.pointerEntered(at: 1), at: 1)
        timeline.run(until: 20)
        #expect(timeline.closes.isEmpty && timeline.machine.isOpen)
        // A leave: the normal grace; back inside it keeps the card, and the next leave closes it after the grace.
        timeline.send(.pointerExited(at: 20), at: 20)
        timeline.send(.pointerEntered(at: 20.1), at: 20.1)
        timeline.run(until: 25)
        #expect(timeline.closes.isEmpty && timeline.machine.phase == .open)
        timeline.send(.pointerExited(at: 25), at: 25)
        timeline.run(until: 30)
        #expect(timeline.closes == [25 + M.closeGrace])
    }

    /// The card opens under a resting pointer (no entry, no leave): held; the island moving off the still pointer starts
    /// its three seconds again.
    @Test func aStillPointerHoldsItUntilTheIslandMovesOff() {
        var timeline = Timeline()
        timeline.send(.finished(at: 0), at: 0)
        timeline.send(.pointerRelocated(inside: true), at: 0.3)
        timeline.run(until: 10)
        #expect(timeline.closes.isEmpty)
        timeline.send(.pointerRelocated(inside: false), at: 10)
        timeline.run(until: 12.9)
        #expect(timeline.closes.isEmpty)
        timeline.run(until: 20)
        #expect(timeline.closes == [13])
    }

    /// A finish while the pointer rests on the pill (the rest not yet up): it opens at once, held by the pointer.
    @Test func aFinishUnderARestingPointerOpensHeld() {
        var timeline = Timeline()
        timeline.send(.pointerEntered(at: 0), at: 0)
        timeline.send(.finished(at: 0.05), at: 0.05)
        #expect(timeline.opens == [0.05] && timeline.machine.openReason == .attention)
        timeline.run(until: 10)
        #expect(timeline.closes.isEmpty && timeline.opens == [0.05])
        timeline.send(.pointerExited(at: 10), at: 10)
        timeline.run(until: 11)
        #expect(timeline.closes == [10 + M.closeGrace])
    }

    /// Something that needs you takes over the Done card and never closes on the card's 3 s: held by the pointer, it
    /// stays until Esc or an answer; left alone, it folds on its own time (P292), and Keep open holds it.
    @Test func somethingThatNeedsYouTakesOverAndNeverClosesOnTheDoneCardsTime() {
        var timeline = Timeline()
        timeline.send(.finished(at: 0), at: 0)
        timeline.send(.attention(at: 1), at: 1)
        timeline.send(.pointerEntered(at: 1.5), at: 1.5)
        #expect(!timeline.machine.brief && timeline.opens == [0])
        timeline.run(until: 60)
        #expect(timeline.closes.isEmpty && timeline.machine.phase == .open)
        // Esc (or an answer) still closes it.
        timeline.send(.dismissed, at: 60)
        #expect(timeline.closes == [60])

        // Left alone, it folds on the request's time, never the Done card's.
        var alone = Timeline()
        alone.send(.finished(at: 0), at: 0)
        alone.send(.attention(at: 1), at: 1)
        alone.run(until: 600)
        #expect(alone.closes == [1 + M.attentionIdle])

        // An approval with Keep open never closes by itself.
        var approval = Timeline()
        approval.machine.holdOpen = true
        approval.send(.attention(at: 0), at: 0)
        approval.run(until: 600)
        #expect(approval.closes.isEmpty && approval.timers.isEmpty)
    }

    /// Two or three finishes close together: the newest shows (one open), and its own three seconds close it once.
    @Test func finishesInARowShareOneTimer() {
        var timeline = Timeline()
        timeline.send(.finished(at: 0), at: 0)
        timeline.send(.finished(at: 1), at: 1)
        timeline.run(until: 3.5)
        #expect(timeline.closes.isEmpty)
        timeline.send(.finished(at: 2.5), at: 2.5)
        timeline.run(until: 30)
        #expect(timeline.opens == [0] && timeline.closes == [5.5])
    }

    /// Leaving the island just before a finish: its Done card keeps the island instead of folding in the grace.
    @Test func aFinishDuringTheLeaveGraceKeepsTheIsland() {
        var timeline = Timeline()
        timeline.send(.clicked(at: 0), at: 0)
        timeline.send(.pointerEntered(at: 0), at: 0)
        timeline.send(.pointerExited(at: 2), at: 2)
        timeline.send(.finished(at: 2.05), at: 2.05)
        timeline.run(until: 30)
        #expect(timeline.closes == [5.05])
        // Something that needs you in the grace keeps it too, and never on the grace's time: left alone, it folds on its
        // own (P292).
        var waiting = Timeline()
        waiting.send(.clicked(at: 0), at: 0)
        waiting.send(.pointerEntered(at: 0), at: 0)
        waiting.send(.pointerExited(at: 2), at: 2)
        waiting.send(.attention(at: 2.05), at: 2.05)
        waiting.run(until: 2.05 + M.attentionIdle - 0.01)
        #expect(waiting.closes.isEmpty && waiting.machine.phase == .open)
        waiting.run(until: 30)
        #expect(waiting.closes == [2.05 + M.attentionIdle])
    }

    /// P97: an approval or a finish in the leave grace keeps the island, and then holds it instead of the pointer. When its
    /// card goes with the pointer away (answered in the terminal, a new prompt), the panel's fallback to the list closes
    /// it: no leave or timer would come. With the pointer back on the island, the list stays.
    @Test func anArrivalInTheLeaveGraceHoldsTheIslandOnlyWhileItsCardShows() {
        for arrival in [M.Event.attention(at: 2.05), .finished(at: 2.05)] {
            var m = M()
            _ = m.handle(.clicked(at: 0))
            _ = m.handle(.pointerEntered(at: 0))
            _ = m.handle(.pointerExited(at: 2))
            #expect(m.phase == .closing)
            _ = m.handle(arrival)
            #expect(m.phase == .open && m.openReason == .attention && m.closesWithItsCard)
            m.endBrief()
            #expect(m.handle(.dismissed) == [.close(.dismiss)] && m.phase == .closed)

            var back = M()
            _ = back.handle(.clicked(at: 0))
            _ = back.handle(.pointerEntered(at: 0))
            _ = back.handle(.pointerExited(at: 2))
            _ = back.handle(arrival)
            _ = back.handle(.pointerEntered(at: 2.5))
            #expect(back.phase == .open && !back.closesWithItsCard)
        }
        // Keep open until approve or deny, opened by a rest: the pointer leaves the approval, which is then answered
        // elsewhere. Nothing holds the island any more.
        var held = M()
        held.holdOpen = true
        _ = held.handle(.pointerEntered(at: 0))
        #expect(held.handle(.timerFired(generation: held.generation, at: 0.15)) == [.open(.hover)])
        #expect(held.handle(.pointerExited(at: 1)).isEmpty && held.phase == .open && held.openReason == .hover)
        #expect(held.closesWithItsCard)
        // A hovered island with the pointer on it never closes with its card.
        var hovered = M()
        _ = hovered.handle(.pointerEntered(at: 0))
        _ = hovered.handle(.timerFired(generation: hovered.generation, at: 0.15))
        #expect(hovered.phase == .open && !hovered.closesWithItsCard)
    }

    /// The island moves on from the Done card (the list, another card): it no longer closes by itself. Esc during the
    /// card closes it once, and its timer comes to nothing.
    @Test func whatEndsTheCardEndsItsTimer() {
        var timeline = Timeline()
        timeline.send(.finished(at: 0), at: 0)
        timeline.machine.endBrief()
        timeline.run(until: 30)
        #expect(timeline.closes.isEmpty && timeline.machine.isOpen)

        var esc = Timeline()
        esc.send(.finished(at: 0), at: 0)
        esc.send(.dismissed, at: 1)
        esc.run(until: 30)
        #expect(esc.closes == [1] && esc.log.last?.effect == .close(.dismiss))
    }

    // MARK: Which card a batch shows

    @MainActor static func row(_ id: String, _ bucket: SessionBucket, ago: TimeInterval) -> SessionRow {
        ActiveCountTests.row(id, .claude, bucket, ago: ago)
    }

    @MainActor @Test func aBatchShowsWhatNeedsYouElseTheNewestFinish() {
        let rows = [Self.row("a", .done, ago: 30), Self.row("b", .done, ago: 5), Self.row("q", .needsYou, ago: 20)]
        // The newest finish, brief, whatever order the rows come in.
        let finishes: [IslandSignal] = [.finished("b"), .finished("a")]
        #expect(IslandAttention.respond(to: finishes, rows: rows, finish: .card, cardInUse: false)
            == .init(card: "b", brief: true))
        // Something that needs you comes first, and never closes by itself.
        #expect(IslandAttention.respond(to: finishes + [.needsYou("q")], rows: rows, finish: .card, cardInUse: false)
            == .init(card: "q", brief: false))
        // A finish never takes the place of the card the owner is at (a waiting card, or a Done card they are replying
        // to, P96); something new that needs you does.
        #expect(IslandAttention.respond(to: finishes, rows: rows, finish: .card, cardInUse: true) == .init())
        #expect(IslandAttention.respond(to: [.needsYou("q")], rows: rows, finish: .card, cardInUse: true).card == "q")
        // Glance: no card, the newest finish lights the dot.
        #expect(IslandAttention.respond(to: finishes, rows: rows, finish: .glance, cardInUse: false)
            == .init(card: nil, brief: false, glance: "b"))
        #expect(IslandAttention.respond(to: [], rows: rows, finish: .card, cardInUse: false) == .init())
    }

    // MARK: The card

    @MainActor @Test func theCardIsBriefInTheIslandAndHoldsNoFieldUntilThePointerComes() {
        let done = DoneCardModel(sessionID: "s", agent: .claude, message: "Wrote it.", interrupted: false)
        var failed = done
        failed.failed = true
        var interrupted = done
        interrupted.interrupted = true
        #expect(DoneCardView.isBrief(done, style: .islandClean) && DoneCardView.isBrief(done, style: .islandDetailed))
        #expect(!DoneCardView.isBrief(done, style: .window) && !DoneCardView.isBrief(failed, style: .islandClean))
        // An interrupt opens no card by itself: opened from the list, its card keeps "Interrupted".
        #expect(!DoneCardView.isBrief(interrupted, style: .islandClean) && !SessionCard.done(interrupted).isBrief(in: .islandDetailed))
        #expect(DoneCardView.lineLimit(done, style: .islandClean) == 2 && DoneCardView.lineLimit(failed, style: .islandClean) == 6)
        #expect(DoneCardView.lineLimit(done, style: .window) == nil)
        #expect(SessionCard.done(done).isBrief(in: .islandClean) && !SessionCard.done(failed).isBrief(in: .islandDetailed))
        // Reply from completion card on: the brief card shows its field only once the pointer has been on it, so an
        // auto-opened card holds nothing that could take the keys. The failed turn's card keeps its field.
        #expect(!DoneCardView.showsReply(brief: true, setting: true, uncovered: false))
        #expect(DoneCardView.showsReply(brief: true, setting: true, uncovered: true))
        #expect(!DoneCardView.showsReply(brief: true, setting: false, uncovered: true))
        #expect(DoneCardView.showsReply(brief: false, setting: true, uncovered: false))
    }
}
