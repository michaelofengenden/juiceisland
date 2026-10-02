import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// A job clock the test drives: it keeps the timer the director asked for last and fires it when told, as late as told.
@MainActor
final class FakeJobClock: IslandJobClock {
    final class Token: IslandTimerToken {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }

    var now: TimeInterval
    /// Every moment the director asked for, in order.
    private(set) var asked: [TimeInterval] = []
    private var pending: (due: TimeInterval, fire: @MainActor @Sendable () -> Void, token: Token)?

    init(now: TimeInterval = 0) { self.now = now }

    /// When the timer the director holds is set for (nil: none, or it was called off).
    var due: TimeInterval? {
        guard let pending, !pending.token.cancelled else { return nil }
        return pending.due
    }

    func schedule(at due: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> any IslandTimerToken {
        asked.append(due)
        let token = Token()
        pending = (due, fire, token)
        return token
    }

    /// Fires the timer the director holds `late` after its moment; false when there is none.
    @discardableResult
    func fire(late: TimeInterval = 0) -> Bool {
        guard let pending, !pending.token.cancelled else { return false }
        self.pending = nil
        now = pending.due + late
        pending.fire()
        return true
    }
}

/// Round A's engine (E1, E2, E4): exact timers, the pointer's own time, the panel's growth first.
@MainActor
struct MotionEngineTests {
    typealias Model = IslandChoreography

    // MARK: Round C: the model's springs in closed form

    /// The model's springs in closed form (`IslandMotion.Curve.state`) are SwiftUI's own (`Spring.value`, `.velocity`):
    /// every curve, from rest and moving each way, over the whole motion, within 10⁻⁹ of the travel (and of the travel
    /// a second for the velocity). The model then asks for them several times cheaper (P300).
    @Test func theClosedFormIsSwiftUIsSpring() {
        var worst = (x: 0.0, v: 0.0)
        // Every island curve is critically damped or under (an overdamped one's velocity, which SwiftUI gives a whole travel
        // a second off its own position's slope, is never asked for).
        for curve in IslandMotion.all + [IslandMotion.Curve(response: 0.2, dampingFraction: 0.5)] {
            for (from, to, v0) in [(0.0, 300.0, 0.0), (228, 33, -900), (33, 228, 1200), (1, 0, 0), (0.4, 1, 3), (-20, 5, 50)] as [(Double, Double, Double)] {
                for ms in stride(from: 0, through: 1500, by: 7) {
                    let t = Double(ms) / 1000
                    let ours = curve.state(from - to, velocity: v0, time: t)
                    let x = curve.spring.value(fromValue: from, toValue: to, initialVelocity: v0, time: t)
                    let v = curve.spring.velocity(fromValue: from, toValue: to, initialVelocity: v0, time: t)
                    let travel = max(abs(from - to), 1)
                    worst = (max(worst.x, abs(to + ours.x - x) / travel), max(worst.v, abs(ours.v - v) / travel))
                }
            }
        }
        #expect(worst.x < 1e-9 && worst.v < 1e-9, "\(worst)")
    }

    // MARK: E1: exact timers

    /// The director's job timer, the hover machine's and the pointer poll are strict dispatch timers with no leeway, and
    /// a strict timer never fires before its deadline.
    @Test func theTimersAreStrictWithNoLeeway() async throws {
        #expect(StrictTimer.flags == .strict)
        #expect(StrictTimer.leeway == .nanoseconds(0))
        #expect(StrictJobClock().now == IslandMotionDirector.now || abs(StrictJobClock().now - IslandMotionDirector.now) < 0.01)
        #expect(IslandPanelController.pollInterval == 1.0 / 60)
        var early: [Double] = []
        var fired = 0
        var timers: [StrictTimer] = []
        for i in 0..<5 {
            let deadline = DispatchTime.now() + .milliseconds(5 + 3 * i)
            timers.append(StrictTimer(at: deadline) {
                let now = DispatchTime.now().uptimeNanoseconds
                if now < deadline.uptimeNanoseconds { early.append(Double(deadline.uptimeNanoseconds - now) / 1e6) }
                fired += 1
            })
        }
        // However busy the main thread (other suites share it), each fires once, and never before its deadline.
        try await MotionRecorderTests.waitUntil({ fired == 5 }, seconds: 120)
        #expect(early.isEmpty, "early by \(early) ms")
        _ = timers
    }

    /// The director asks its clock for the model's next job at that job's own moment, every time, and logs each firing
    /// (fired − due); fired on time, every job runs exactly as the model replayed on its own runs it.
    @Test func eachJobIsAskedForAtItsOwnTimeAndRunsThere() {
        let clock = FakeJobClock(now: 100)
        let start = DIslandMotionTests.model()
        let director = IslandMotionDirector(model: start, ui: IslandUIState(), clock: clock)
        var log: [(due: TimeInterval, fired: TimeInterval, steps: [Model.Step])] = []
        director.onJob = { log.append(($0, $1, $2)) }
        director.send(.open(.click, .list))
        var dues: [TimeInterval] = []
        while let due = clock.due {
            #expect(due == director.model.nextJobTime)
            dues.append(due)
            clock.fire()
        }
        #expect(dues.count >= 5, "\(dues)")
        #expect(log.count == dues.count && log.allSatisfy { $0.fired == $0.due && !$0.steps.isEmpty })
        #expect(log.map(\.due) == dues && clock.asked == dues)
        // The first job is the height, 30 ms after the width (`IslandMotion.lead`).
        #expect(log.first?.steps.first == .openHeight(trigger: 100) && abs((log.first?.due ?? 0) - 100.03) < 1e-9)
        let (alone, _) = Model.replay(start, [(100, .open(.click, .list))], until: dues.last ?? 100)
        #expect(director.model.values == alone.values && director.model.jobs.isEmpty && alone.jobs.isEmpty)
    }

    /// A timer that fires late (a busy main thread) logs how late, and the jobs still run at their scheduled times: the
    /// model ends exactly where it would have with every timer on time.
    @Test func aLateTimerStillRunsItsJobsAtTheirScheduledTimes() {
        let start = DIslandMotionTests.model(surface: .island)
        let onTime = FakeJobClock(now: 50), late = FakeJobClock(now: 50)
        let a = IslandMotionDirector(model: start, ui: IslandUIState(), clock: onTime)
        let b = IslandMotionDirector(model: start, ui: IslandUIState(), clock: late)
        var lateness: [TimeInterval] = []
        b.onJob = { due, fired, _ in lateness.append(fired - due) }
        a.send(.close(.fold))
        b.send(.close(.fold))
        while onTime.fire() {}
        while late.fire(late: 0.007) {}
        #expect(!lateness.isEmpty && lateness.allSatisfy { abs($0 - 0.007) < 1e-9 })
        #expect(a.model.values == b.model.values)
        // Late timers can only merge jobs into fewer firings, never move them.
        #expect(late.asked.count <= onTime.asked.count && Set(late.asked).isSubset(of: Set(onTime.asked)))
    }

    /// A new event calls the pending timer off and asks for the new next job; with nothing left to run no timer is held.
    @Test func aNewEventReplacesThePendingTimerAndNothingWaitsAtRest() {
        let clock = FakeJobClock(now: 10)
        let director = IslandMotionDirector(model: DIslandMotionTests.model(), ui: IslandUIState(), clock: clock)
        director.send(.open(.hover, .list))
        let first = clock.due
        clock.now = 10.01
        director.send(.close(.abort))
        #expect(first != nil && clock.due == director.model.nextJobTime && clock.due != first)
        while clock.fire() {}
        #expect(clock.due == nil && director.model.jobs.isEmpty)
    }

    /// A slow move (60 pt/s, a sample every 8 ms) that a busy main thread handles four samples at a time: timed by the
    /// events' own timestamps it reads slow, so the rest runs on from the entry; timed by when it was handled (the old
    /// reading) the first bunch read thousands of points a second and restarted the rest three times.
    @Test func bunchedPointerSamplesWithSpreadTimestampsDoNotRestartTheRest() throws {
        let events = try (0..<12).map { i in
            try #require(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 700 + 0.48 * Double(i), y: 960), modifierFlags: [],
                                            timestamp: 500 + 0.008 * Double(i), windowNumber: 0, context: nil, eventNumber: i,
                                            clickCount: 0, pressure: 0))
        }
        let samples = events.map { PointerSample(event: $0) }
        #expect(samples.map(\.time) == events.map(\.timestamp))
        #expect(samples.map(\.location) == events.map(\.locationInWindow))
        // Handled in bunches of four, 0.1 ms apart within a bunch, the bunches 32 ms apart.
        let handled = samples.indices.map { i in 600 + 0.032 * Double(i / 4) + 0.0001 * Double(i % 4) }

        func restarts(_ time: (Int) -> TimeInterval) -> Int {
            var machine = IslandHoverMachine()
            var speed = PointerSpeed()
            var restarts = 0
            _ = machine.handle(.pointerEntered(at: 0))
            for (i, sample) in samples.enumerated() {
                let v = speed.add(sample.location, at: time(i))
                for case .schedule in machine.handle(.pointerMoved(speed: v, at: Double(i) * 0.008)) { restarts += 1 }
            }
            #expect(machine.phase == .opening)
            return restarts
        }
        #expect(restarts { samples[$0].time } == 0, "by the events' own time")
        #expect(restarts { handled[$0] } == 3, "by the handling time")
    }

    /// A move routed to the panel before one of its snaps (the swell's, the open's, the fit's) and handled after it, as
    /// a busy main thread does: its place in the window was worked out against the frame the panel had then, so read
    /// through the frame it has now it lands off by the snap (here the open's: 115.5 pt left, 150 down). The sample
    /// takes the event's own place on the screen instead, and its own time.
    @Test func aMoveHandledAfterThePanelsSnapKeepsItsPlaceOnTheScreen() throws {
        _ = NSApplication.shared
        let panel = IslandPanel(contentRect: CGRect(x: 500, y: 800, width: 200, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let screen = try #require(NSScreen.screens.first).frame
        let place = CGPoint(x: 600, y: 820)
        let routed = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                          mouseCursorPosition: CGPoint(x: place.x, y: screen.maxY - place.y), mouseButton: .left))
        // The window it was routed to (kCGMouseEventWindowUnderMousePointer) and when it happened.
        routed.setIntegerValueField(try #require(CGEventField(rawValue: 51)), value: Int64(panel.windowNumber))
        routed.timestamp = 123_456_000_000
        let event = try #require(NSEvent(cgEvent: routed))
        #expect(event.window === panel)
        // The panel snaps (it hangs from the top edge: wider and taller, the top kept) before the move is handled.
        panel.setFrame(CGRect(x: 384.5, y: 650, width: 431, height: 190), display: false)
        let sample = PointerSample(event: event)
        #expect(sample.location == place && sample.time == 123.456, "\(sample)")
    }

    /// AppKit makes an entry or an exit up from the tracking area, its place worked out against the panel's frame as it
    /// is when read: the sample is the pointer as it is now, at the time it is handled.
    @Test func anEntryOrAnExitIsThePointerNow() throws {
        let now = PointerSample(location: CGPoint(x: 612, y: 1100), time: 900)
        for type in [NSEvent.EventType.mouseEntered, .mouseExited] {
            let event = try #require(NSEvent.enterExitEvent(with: type, location: CGPoint(x: 100, y: 20), modifierFlags: [], timestamp: 1,
                                                            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            #expect(PointerSample(event: event, now: { now }) == now)
        }
    }

    /// A sample that arrives after a later one (a tracking event handled after the poll's sample) takes its place in
    /// time, so the speed is the path's, never a negative or huge span.
    @Test func aSampleHandledOutOfOrderTakesItsPlaceInTime() {
        var inOrder = PointerSpeed(), outOfOrder = PointerSpeed()
        let path = (0..<6).map { (CGPoint(x: 10 + Double($0), y: 0), 1 + 0.01 * Double($0)) }
        var last = 0.0
        for (point, time) in path { last = inOrder.add(point, at: time) }
        for index in [0, 1, 2, 4, 3, 5] { _ = outOfOrder.add(path[index].0, at: path[index].1) }
        #expect(abs(last - 100) < 0.01 && abs(outOfOrder.speed - last) < 0.01, "\(last) \(outOfOrder.speed)")
    }

    // MARK: E2: the panel's growth first

    /// A batch's panel growth is applied before its writes: the open's before its still write (the target, the pill's
    /// clock), which `setFrame(display: true)` would otherwise bring up to date inside the snap. A shrink stays after the
    /// writes it waits for, and a batch is only reordered, never changed.
    @Test func thePanelGrowsBeforeTheBatchesWrites() throws {
        func isPanel(_ command: Model.Command) -> Bool { if case .panel = command { true } else { false } }
        func isTarget(_ command: Model.Command) -> Bool { if case .target = command { true } else { false } }
        var model = DIslandMotionTests.model()
        let before = model.panel
        let open = model.handle(.open(.click, .list), at: 0)
        let applied = IslandMotionDirector.panelFirst(open, from: before)
        #expect(try #require(open.firstIndex(where: isTarget)) < (try #require(open.firstIndex(where: isPanel))))
        #expect(applied.first.map(isPanel) == true)
        #expect(applied.filter { !isPanel($0) } == open.filter { !isPanel($0) } && applied.filter(isPanel) == open.filter(isPanel))

        let pill = IslandExtent(width: 253, height: 33), grown = IslandExtent(width: 484, height: 230)
        let island = IslandExtent(width: 480, height: 200)
        let fit: [Model.Command] = [.animate(nil, [.height: 33]), .panel(pill)]
        #expect(IslandMotionDirector.panelFirst(fit, from: grown) == fit)
        // Reduce Motion's open: a growth, the snap, the exact panel.
        let snap: [Model.Command] = [.target(.zero, isOpen: true), .panel(grown), .animate(nil, [.height: 200]), .panel(island)]
        #expect(IslandMotionDirector.panelFirst(snap, from: pill)
                == [.panel(grown), .target(.zero, isOpen: true), .animate(nil, [.height: 200]), .panel(island)])

        // The director: the panel snaps while the views still hold the closed pill.
        let ui = IslandUIState()
        let director = IslandMotionDirector(model: DIslandMotionTests.model(), ui: ui, clock: FakeJobClock())
        var openAtSnap: [Bool] = []
        director.applyPanel = { _ in openAtSnap.append(ui.isOpen) }
        director.send(.open(.click, .list))
        #expect(openAtSnap.first == false && ui.isOpen)
    }

    // MARK: E2: glyph clocks only while their glyphs can be seen

    /// Over every replay, a millisecond at a time, under Motion: Original and Refined: the island's glyph clock runs only
    /// while the island is open, and always while anything of it that is coming in or shown can be seen; the pill's runs
    /// only while the island is closed, and always while the pill that is coming back or shown can be seen. So an open's
    /// pill stops at its first frame, the island's clock waits for the first reveal, and a close stops it at once.
    @Test(arguments: [false, true])
    func theGlyphClocksRunOnlyWhileTheirGlyphsCanBeSeen(refined: Bool) {
        for scenario in DIslandCrossTests.everyScenario(refined: refined) {
            var wrong: [String] = []
            _ = DIslandCrossTests.playView(scenario) { model, ui, t in
                func arriving(_ channel: Channel) -> Bool {
                    (model.values[channel]?.target ?? 0) > 0.5 && model.value(channel, at: t) > IslandMotion.shown
                }
                let islandSeen = model.values.keys.contains { channel in
                    if case .part(let part) = channel, part != .leavingHeader, part != .leavingBody, part != .cardAhead { arriving(channel) } else { false }
                } || arriving(.header)
                if ui.islandLive, !model.isOpen { wrong.append("island clock while closed at \(Int(t * 1000))") }
                if islandSeen, !ui.islandLive { wrong.append("island seen, clock off at \(Int(t * 1000))") }
                if ui.pillLive, model.isOpen { wrong.append("pill clock while open at \(Int(t * 1000))") }
                if model.ordered, arriving(.pill), !ui.pillLive { wrong.append("pill seen, clock off at \(Int(t * 1000))") }
            }
            #expect(wrong.isEmpty, "\(scenario.name): \(wrong.prefix(3))")
        }
    }

    /// An open stops the pill's clock in its first frame and starts the island's with its first reveal, the header's job
    /// (40 ms, Refined 30), never before; a close stops the island's in its first frame; a reverse that re-aims parts still
    /// in sight starts it at once.
    @Test func anOpenStartsTheIslandsClockWithItsFirstRevealAndACloseStopsItAtOnce() {
        for tuning in [MotionTuning(), MotionTuning(motion: .refined, hover: .quick)] {
            var model = DIslandMotionTests.model()
            _ = model.handle(.tuning(tuning), at: 0)
            let open = model.handle(.open(.click, .list), at: 0)
            #expect(open.contains(.effect(.pillLive(false))) && !open.contains(.effect(.islandLive(true))))
            let before = model.advance(to: tuning.headerIn - 0.001)
            #expect(!before.contains(.effect(.islandLive(true))))
            let header = model.advance(to: tuning.headerIn)
            #expect(header.contains(.effect(.islandLive(true))), "\(tuning.motion)")
            _ = model.advance(to: 1.5)
            let close = model.handle(.close(.fold), at: 1.5)
            #expect(close.contains(.effect(.islandLive(false))))
            // Back 40 ms into the fold: the rows are still half in sight, and move again at once.
            let reverse = model.handle(.open(.hover, .list), at: 1.54)
            #expect(reverse.contains(.effect(.islandLive(true))) && reverse.contains(.effect(.pillLive(false))), "\(tuning.motion)")
            _ = model.advance(to: 3)
            let again = model.handle(.close(.fold), at: 3)
            let late = model.advance(to: 3.2) + model.handle(.open(.hover, .list), at: 3.2)
            // Back 200 ms in: nothing is left in sight, so the clock waits for the header's job again.
            #expect(again.contains(.effect(.islandLive(false))) && !late.contains(.effect(.islandLive(true))), "\(tuning.motion)")
        }
    }

    /// The live island (`holdsGlyphs`): a stopped clock's glyphs hold where they are and draw no frames, the island's
    /// rows and the pill's lead alike; a clock that runs draws. Counted on the app's own timelines, so debug only.
    @Test(.enabled(if: GlyphFrames.countsTimelines)) func aStoppedClockDrawsNoGlyphFrames() {
        func frames(island: Bool, pill: Bool) -> Int {
            _ = NSApplication.shared
            let env = AppEnvironment.demo(sessions: .prototype)
            let ui = IslandUIState()
            IslandMotionDirector.snap(ui, to: DIslandMotionTests.model(surface: .island), at: 0)
            ui.holdsGlyphs = true
            (ui.islandLive, ui.pillLive) = (island, pill)
            let size = CGSize(width: IslandPanelSizing.canvasWidth, height: 400)
            let root = IslandRootView(ui: ui, notch: DIslandMotionTests.notch, canvas: size, actions: IslandViewActions(),
                                      pillClicked: {}, measured: { _ in })
            let hosting = NSHostingView(rootView: AnyView(root.environment(env).glyphMotion(SurfaceMotion(.shown))))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let before = GlyphFrames.count
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let drawn = GlyphFrames.count - before
            window.contentView = nil
            window.close()
            return drawn
        }
        let held = frames(island: false, pill: false)
        let island = frames(island: true, pill: false), pill = frames(island: false, pill: true)
        #expect(held <= 2, "held: \(held) frames")
        #expect(island > 4 && pill > 4, "the island's clock: \(island), the pill's: \(pill)")
    }

    // MARK: E4: card turns out of motion

    /// A card that asks while the island folds is built at once, in a turn of its own, since the next turn presents it
    /// anyway: the reversing open then finds it measured and heads straight for its height, its body in on time. Left
    /// to that open's turn, the open went for the list's height, fitted early, turned again to the card's once it was
    /// measured, and brought the body in 40 to 80 ms late. (Only a card built ahead for later, the next that waits or
    /// the hovered row's, waits for the island to rest.)
    @Test func aCardAboutToBePresentedIsBuiltEvenWhileTheIslandMoves() {
        var folding = DIslandMotionTests.model(surface: .island)
        _ = folding.handle(.close(.fold), at: 0)
        _ = folding.advance(to: 0.12)
        #expect(folding.inMotion && !IslandPanelController.buildsAhead(folding))
        #expect(IslandPanelController.buildsAhead(folding, presenting: true))

        // What that buys, on the model: the card measured before the open, or only after it.
        var card = DIslandMotionTests.layout()
        card.card = 120
        card.cardID = "r1"
        card.parts[.cardHeader] = CGRect(x: 18, y: 42, width: 444, height: 31)
        card.parts[.cardBody] = CGRect(x: 18, y: 73, width: 444, height: 72)
        let open = Model.Event.open(.attention, .card(sessionID: "r1"))
        let built: [(TimeInterval, Model.Event)] = [(0, .close(.fold)), (0.118, .content(card)), (0.12, open)]
        let late: [(TimeInterval, Model.Event)] = [(0, .close(.fold)), (0.12, open), (0.136, .content(card))]
        func heights(_ events: [(TimeInterval, Model.Event)]) -> (targets: Set<Int>, body: Int) {
            var targets = Set<Int>(), body = -1
            DIslandMotionTests.samples(DIslandMotionTests.model(surface: .island), events, until: 1) { m, t in
                if t >= 0.12, let target = m.values[.height]?.target { targets.insert(Int(target.rounded())) }
                if body < 0, m.values[.part(.cardBody)]?.target == 1 { body = DIslandMotionTests.ms(t) }
            }
            return (targets, body)
        }
        let first = heights(built), second = heights(late)
        #expect(first.targets == [162] && second.targets == [228, 162], "\(first) \(second)")
        #expect(first.body < second.body, "\(first) \(second)")
    }

    /// A card is built ahead only while the island is not in motion: from a close's first frame to its fit, and from a
    /// card's present to its fit, the panel builds nothing (the build is a 10 to 29 ms turn, 17 ms in the middle of a
    /// fold); once the last step has run it may.
    @Test func noCardIsBuiltAheadWhileTheIslandMoves() async {
        for scenario in DIslandCrossTests.everyScenario(refined: false) + DIslandCrossTests.everyScenario(refined: true) {
            // The main actor is shared: other suites' timers run between two replays.
            await Task.yield()
            var wrong: [String] = []
            DIslandPanelSizingTests.play(scenario, until: 3) { model, t, _ in
                let moving = model.jobs.contains { $0.step.movesSurface || $0.step == .fit }
                if moving, IslandPanelController.buildsAhead(model) { wrong.append("\(Int(t * 1000))") }
            }
            let (end, _) = Model.replay(scenario.start, scenario.events, until: 3)
            #expect(wrong.isEmpty && IslandPanelController.buildsAhead(end), "\(scenario.name): \(wrong.prefix(3))")
        }
    }

    /// The director says the island has come to rest once, a turn after its last step (the fit), and not if something
    /// set it moving again in that turn.
    @Test func theDirectorSaysOnceWhenTheIslandHasComeToRest() async throws {
        let clock = FakeJobClock(now: 20)
        let director = IslandMotionDirector(model: DIslandMotionTests.model(surface: .island), ui: IslandUIState(), clock: clock)
        var rests = 0
        director.rested = { rests += 1 }
        director.send(.close(.fold))
        while let due = clock.due {
            #expect(director.model.inMotion)
            clock.fire()
            #expect(rests == 0, "at \(due)")
        }
        #expect(!director.model.inMotion)
        try await MotionRecorderTests.waitUntil({ rests == 1 })
        // At rest again, then moving again before the turn that would say so.
        director.send(.open(.click, .list))
        while clock.due != nil { clock.fire() }
        director.send(.close(.fold))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rests == 1 && director.model.inMotion)
    }

    /// A card that leaves for the list, or for another session's card, is unmounted once the island has settled: never
    /// while the height still moves (a fold, an unfold, a growth's tail), a row glides home or a reveal still fades;
    /// with nothing moving it goes 300 ms after it started to leave.
    @Test(arguments: [false, true])
    func aCardLayerIsUnmountedOnceTheIslandHasSettled(refined: Bool) async {
        var checked = 0
        for scenario in DIslandCrossTests.everyScenario(refined: refined) {
            // The main actor is shared: other suites' timers run between two replays.
            await Task.yield()
            var wrong: [String] = []
            DIslandPanelSizingTests.play(scenario, until: 3) { model, t, commands in
                let unmounts = commands.contains(.effect(.cardSnapshot(nil))) || commands.contains(.effect(.cardLeaving(nil)))
                guard unmounts, model.isOpen else { return }
                checked += 1
                if model.jobs.contains(where: { $0.step.movesSurface || $0.step == .fit }) { wrong.append("\(Int(t * 1000)) pending") }
                let g = model.surface(at: t), rest = model.restGeometry
                if abs(g.height - rest.height) > IslandMotion.fitTolerance { wrong.append("\(Int(t * 1000)) height off by \(g.height - rest.height)") }
                for (channel, value) in model.values {
                    let points = switch channel {
                    case .left, .right, .height, .ear, .radius, .rimLift, .glide, .cardRide, .liquid: true
                    case .pill, .pillArrive, .header, .part, .shoulders: false
                    }
                    let off = abs(value.value(at: t) - value.target)
                    if off > (points ? Double(IslandMotion.fitTolerance) : 0.01) + 1e-9 { wrong.append("\(Int(t * 1000)) \(channel) off by \(off)") }
                }
            }
            #expect(wrong.isEmpty, "\(scenario.name): \(wrong.prefix(3))")
        }
        #expect(checked > 10)
    }

    /// The ahead → live swap moves no layer: the card built ahead keeps its place as it takes the showing one's, and the
    /// showing one keeps its own as it leaves; the root's body reads neither what the island presents nor its cards, so
    /// a present, an arrival or a card swap re-evaluates the card layers and the header, never the whole island; nor any
    /// channel (E5), so no step of the motion re-evaluates it either.
    @Test func theAheadToLiveSwapMovesNoLayerAndTheRootReadsNoCard() {
        let a = DIslandKeyTests.approval, q = DIslandKeyTests.question
        let before = IslandCardLayer.stack(card: a, leaving: nil, ahead: q).map { "\($0.id):\($0.role)" }
        let after = IslandCardLayer.stack(card: q, leaving: a, ahead: nil).map { "\($0.id):\($0.role)" }
        #expect(before == ["\(a.sessionID):live", "\(q.sessionID):ahead"])
        #expect(after == ["\(a.sessionID):leaving", "\(q.sessionID):live"])

        let ui = IslandUIState()
        let root = IslandRootView(ui: ui, notch: DIslandMotionTests.notch, canvas: CGSize(width: 496, height: 400),
                                  actions: IslandViewActions(), pillClicked: {}, measured: { _ in })
        let invalidated = Flag()
        withObservationTracking { _ = root.body } onChange: { invalidated.set() }
        ui.presentation = .card(sessionID: q.sessionID)
        ui.card = q
        ui.aheadCard = a
        ui.leavingCard = a
        ui.arrivingCard = q.sessionID
        #expect(!invalidated.value)
        ui.apply([.pill: 0.5, .pillArrive: 0.5, .rimLift: 3, .header: 1, .part(.row("r0")): 1, .glide("r0"): 10, .cardRide: 4,
                  .left: 100, .right: 120, .height: 200], motion: .spring(IslandMotion.unfold))
        #expect(!invalidated.value)
        ui.isOpen = true
        #expect(invalidated.value)
    }
}

/// A flag an observation's change handler can set from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
