import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The island panel's sizes (spec §7, §9.2, §9.4): exact rest frames, a panel that takes in every modelled frame, grows
/// only while anything moves and shrinks only once the shape fits, a canvas that never moves on the screen, the hit
/// region, and a display change. The scenarios are the spec's headless replays, each also under Reduce Motion.
@MainActor
struct DIslandPanelSizingTests {
    typealias Model = IslandChoreography
    typealias Events = [(TimeInterval, Model.Event)]

    static let notch = IslandTheme.Metrics.referenceNotch
    static let lead = PillLead(glyph: .eq, agent: .claude, state: .running)

    static func pill(count: Int? = 3, notch: CGSize? = notch, lead: PillLead? = lead) -> PillContent {
        PillContent.make(lead: lead, count: count, glance: false, style: .liquid, edgeLine: true, notch: notch,
                         menuBar: notch.map { $0.height + 1 } ?? 24)
    }

    /// A Clean list of `rows` rows (41 pt apart) and a footer, and row "r1"'s 188 pt card.
    static func layout(rows: Int = 4) -> ContentLayout {
        var layout = ContentLayout(header: 34, list: 2 + CGFloat(rows) * 41 + 20)
        for i in 0..<rows { layout.parts[.row("r\(i)")] = CGRect(x: 18, y: 36 + CGFloat(i) * 41, width: 444, height: 41) }
        layout.parts[.footer] = CGRect(x: 18, y: 36 + CGFloat(rows) * 41, width: 444, height: 20)
        layout.card = 188
        layout.cardID = "r1"
        layout.parts[.cardHeader] = CGRect(x: 18, y: 42, width: 444, height: 31)
        layout.parts[.cardBody] = CGRect(x: 18, y: 73, width: 444, height: 140)
        return layout
    }

    struct Scenario {
        var name: String
        var start: Model
        var events: Events

        /// The same replay under Motion: Refined and Hover: Quick (the motion round A's feel).
        var refined: Scenario {
            var start = start
            _ = start.handle(.tuning(MotionTuning(motion: .refined, hover: .quick)), at: 0)
            return Scenario(name: name + " (Refined)", start: start, events: events)
        }
    }

    /// `scenarios` as they are, or as they play under Motion: Refined and Hover: Quick.
    static func scenarios(refined: Bool) -> [Scenario] { refined ? scenarios.map(\.refined) : scenarios }

    /// The spec's replays (§9.4), on the notch and the top bar, with and without Reduce Motion.
    static var scenarios: [Scenario] {
        var all: [Scenario] = []
        for notch in [Optional(Self.notch), nil] {
            for reduce in [false, true] {
                func model(_ surface: Model.Surface = .closed, pill: PillContent? = nil, layout: ContentLayout = layout(),
                           presentation: IslandPresentation = .list, ordered: Bool = true, hideWhenIdle: Bool = false) -> Model {
                    let targets = SurfaceTargets(notch: notch, pill: pill ?? Self.pill(notch: notch), hideWhenIdle: hideWhenIdle)
                    return Model(metrics: .init(targets: targets, layout: layout, reduceMotion: reduce), surface: surface,
                                 presentation: presentation, ordered: ordered)
                }
                let tag = "\(notch == nil ? "bar" : "notch")\(reduce ? " reduced" : "")"
                let empty = Self.pill(count: nil, notch: notch, lead: nil)
                var added = layout(rows: 6)
                added.parts[.row("r5")] = nil
                let removed = layout(rows: 3)
                var unmeasured = layout()
                (unmeasured.card, unmeasured.cardID) = (nil, nil)
                unmeasured.parts[.cardHeader] = nil
                unmeasured.parts[.cardBody] = nil
                var nothing = ContentLayout(header: 34, list: 32)
                nothing.parts[.empty] = CGRect(x: 18, y: 36, width: 444, height: 32)
                all += [
                    Scenario(name: "brush \(tag)", start: model(),
                             events: [(0, .swell(true)), (0.08, .swell(false)), (0.3, .swell(true)), (0.38, .swell(false))]),
                    Scenario(name: "rest-open \(tag)", start: model(), events: [(0, .swell(true)), (0.15, .open(.hover, .list))]),
                    Scenario(name: "click-open \(tag)", start: model(), events: [(0, .open(.click, .list))]),
                    Scenario(name: "attention-card \(tag)", start: model(), events: [(0, .open(.attention, .card(sessionID: "r1")))]),
                    Scenario(name: "flick \(tag)", start: model(), events: [(0, .open(.hover, .list)), (0.09, .close(.abort))]),
                    Scenario(name: "retreat \(tag)", start: model(), events: [(0, .open(.hover, .list)), (0.2, .retreat), (0.22, .resume)]),
                    Scenario(name: "retreat-close \(tag)", start: model(),
                             events: [(0, .open(.hover, .list)), (0.2, .retreat), (0.24, .close(.fold))]),
                    Scenario(name: "return-during-fold \(tag)", start: model(.island),
                             events: [(0, .close(.fold)), (0.13, .open(.hover, .list))]),
                    Scenario(name: "return-after-fold \(tag)", start: model(.island),
                             events: [(0, .close(.fold)), (0.7, .swell(true)), (0.85, .open(.hover, .list))]),
                    Scenario(name: "esc \(tag)", start: model(.island), events: [(0, .close(.dismiss))]),
                    Scenario(name: "card-row1 \(tag)", start: model(.island),
                             events: [(0, .present(.card(sessionID: "r0"))), (0.02, .content(Self.cardFor("r0"))),
                                      (1, .present(.list))]),
                    Scenario(name: "card-row2 \(tag)", start: model(.island),
                             events: [(0, .present(.card(sessionID: "r1"))), (1, .present(.list))]),
                    Scenario(name: "card-measured-after-mount \(tag)", start: model(.island, layout: unmeasured),
                             events: [(0, .present(.card(sessionID: "r3"))), (0.016, .content(Self.cardFor("r3"))),
                                      (1, .present(.list))]),
                    Scenario(name: "card-row4 \(tag)", start: model(.island),
                             events: [(0, .present(.card(sessionID: "r3"))), (0.02, .content(Self.cardFor("r3"))),
                                      (1, .present(.list))]),
                    Scenario(name: "rows-added-mid-open \(tag)", start: model(),
                             events: [(0, .open(.hover, .list)), (0.1, .content(added))]),
                    Scenario(name: "row-removed-while-open \(tag)", start: model(.island), events: [(0, .content(removed))]),
                    Scenario(name: "row-added-while-open \(tag)", start: model(.island, layout: removed), events: [(0, .content(layout()))]),
                    Scenario(name: "first-row-after-empty \(tag)", start: model(layout: nothing),
                             events: [(0, .open(.hover, .list)), (1, .content(layout(rows: 1)))]),
                    Scenario(name: "arrive \(tag)", start: model(pill: empty), events: [(0, .pill(Self.pill(notch: notch)))]),
                    Scenario(name: "depart \(tag)", start: model(), events: [(0, .pill(empty))]),
                    Scenario(name: "open-mid-arrive \(tag)", start: model(pill: empty),
                             events: [(0, .pill(Self.pill(notch: notch))), (0.03, .open(.click, .list)), (1.2, .close(.fold))]),
                    Scenario(name: "open-mid-depart \(tag)", start: model(),
                             events: [(0, .pill(empty)), (0.05, .open(.click, .list)), (1.2, .close(.fold))]),
                    Scenario(name: "resize \(tag)", start: model(), events: [(0, .pill(Self.pill(count: 10, notch: notch)))]),
                    // Hide the pill when idle (P94): the last active session ages out, one arrives, one needs you.
                    Scenario(name: "idle-hide-depart \(tag)", start: model(hideWhenIdle: true), events: [(0, .pill(empty))]),
                    Scenario(name: "idle-hide-arrive \(tag)", start: model(pill: empty, ordered: false, hideWhenIdle: true),
                             events: [(0, .pill(Self.pill(notch: notch)))]),
                    Scenario(name: "idle-hide-attention \(tag)", start: model(pill: empty, ordered: false, hideWhenIdle: true),
                             events: [(0, .open(.attention, .card(sessionID: "r1"))), (0.001, .pill(Self.pill(notch: notch)))]),
                    Scenario(name: "hide \(tag)", start: model(.island), events: [(0, .hide)]),
                    Scenario(name: "hide-closed \(tag)", start: model(), events: [(0, .hide)]),
                    Scenario(name: "show \(tag)", start: model(pill: empty, ordered: false), events: [(0, .show)]),
                    Scenario(name: "show-with-sessions \(tag)", start: model(pill: empty, ordered: false),
                             events: [(0, .show), (0.005, .pill(Self.pill(notch: notch)))]),
                    Scenario(name: "display-change-mid-open \(tag)", start: model(),
                             events: [(0, .open(.hover, .list)), (0.12, .display(model().metrics))]),
                    Scenario(name: "display-change-mid-close \(tag)", start: model(.island),
                             events: [(0, .close(.fold)), (0.2, .display(model().metrics))]),
                ]
            }
        }
        return all
    }

    /// The fixture's layout with `id`'s card measured.
    static func cardFor(_ id: String) -> ContentLayout {
        var layout = layout()
        layout.cardID = id
        return layout
    }

    /// Plays a scenario at 1 ms steps, calling `body` with each step's commands and the model after them.
    static func play(_ scenario: Scenario, until end: TimeInterval = 2.5,
                     _ body: (_ model: Model, _ t: TimeInterval, _ commands: [Model.Command]) -> Void) {
        var model = scenario.start
        var pending = scenario.events.sorted { $0.0 < $1.0 }
        var t = 0.0
        while t <= end + 1e-9 {
            var commands = model.advance(to: t)
            while let (time, event) = pending.first, time <= t + 1e-9 {
                pending.removeFirst()
                commands += model.handle(event, at: time)
            }
            body(model, t, commands)
            t += 0.001
        }
    }

    // MARK: 1: rest frames

    @Test(arguments: 0..<4)
    func restFramesAreExactlyTheShape(_ index: Int) throws {
        let laptop = DIslandGeometryTests.laptops[index]
        for origin in [CGPoint.zero, CGPoint(x: -1512, y: 211)] {
            let screen = DIslandGeometryTests.laptop(laptop.screen, notch: laptop.notch, origin: origin)
            let notch = try #require(NotchGeometry.notchRect(on: screen))
            let pill = Self.pill(notch: laptop.notch)
            let targets = SurfaceTargets(notch: laptop.notch, pill: pill)
            for (name, g) in [("idle", targets.idle), ("pill", targets.closed), ("swell", targets.swell()),
                              ("island", targets.island(height: 228))] {
                let frame = NotchGeometry.frame(g.extent, on: screen)
                #expect(frame.maxY == screen.frame.maxY, "\(name)")
                #expect(frame.minX * 2 == (frame.minX * 2).rounded(), "\(name) off the half-point grid")
                #expect(abs((frame.minX + g.left) - notch.midX) <= 0.5, "\(name)")
                #expect(frame.width == g.width && frame.height == g.height, "\(name)")
            }
            // The idle surface is exactly the notch.
            #expect(NotchGeometry.frame(targets.idle.extent, on: screen) == notch)
        }
        // An external display: the top bar, centred on the screen.
        let external = DIslandGeometryTests.external(CGRect(x: 1512, y: -300, width: 2560, height: 1440))
        let bar = SurfaceTargets(notch: nil, pill: Self.pill(notch: nil))
        for g in [bar.idle, bar.closed, bar.island(height: 228)] {
            let frame = NotchGeometry.frame(g.extent, on: external)
            #expect(frame.maxY == external.frame.maxY && abs(frame.midX - external.frame.midX) <= 0.5)
        }
    }

    // MARK: 2–4: the panel through every replay

    @Test(arguments: [false, true])
    func everyModelledFrameFitsItsPanel(refined: Bool) {
        for scenario in Self.scenarios(refined: refined) {
            var worst = (over: 0.0, at: 0.0)
            Self.play(scenario) { model, t, _ in
                let g = model.surface(at: t), panel = model.panel
                let over = max(Double(g.left - panel.left), Double(g.right - panel.right), Double(g.height - panel.height))
                if over > worst.over { worst = (over, t) }
            }
            #expect(worst.over <= Double(IslandMotion.fitTolerance) + 1e-9, "\(scenario.name): \(worst)")
        }
    }

    /// A panel smaller than the one before is emitted only once the outline fits it for good (and, for a shrink
    /// that follows a motion, a frame after that).
    @Test(arguments: [false, true])
    func panelsOnlyGrowWhileMovingAndShrinkOnlyAfterTheShapeFits(refined: Bool) {
        for scenario in Self.scenarios(refined: refined) {
            var previous = scenario.start.panel
            Self.play(scenario) { model, t, commands in
                for command in commands {
                    guard case let .panel(new) = command else { continue }
                    defer { previous = new }
                    guard !new.contains(previous) else { continue }
                    // A shrink: from now on the outline stays inside it.
                    let fits = model.fitTime(new, from: t).map { $0 <= t + 1e-9 } ?? false
                    #expect(fits, "\(scenario.name): shrink to \(new) at \(Int(t * 1000)) ms before the shape fits")
                }
            }
            #expect(previous == scenario.startedRest(after: 2.5), "\(scenario.name): the panel ends at the rest shape")
        }
    }

    @Test func atMostTwoSnapsPerTransitionAndFourPerCycle() {
        let start = Model(metrics: .init(targets: SurfaceTargets(notch: Self.notch, pill: Self.pill()), layout: Self.layout()))
        let cycle: Events = [(0, .swell(true)), (0.15, .open(.hover, .list)), (1.2, .close(.fold))]
        var snaps: [(Int, IslandExtent)] = []
        Self.play(Scenario(name: "cycle", start: start, events: cycle)) { _, t, commands in
            for command in commands { if case let .panel(extent) = command { snaps.append((Int(t * 1000), extent)) } }
        }
        // Enter (the swell and its margin), open (the island and its margin), landed (exactly the island), close
        // (exactly the pill).
        #expect(snaps.count == 4, "\(snaps)")
        #expect(snaps.last?.1 == Self.pill().extent)
        #expect(snaps.count > 2 && snaps[2].1 == IslandExtent(width: 480, height: Self.layout().islandHeight(card: nil)))
    }

    /// Every replay ends at the rest of the state it ends in. Open: the header and every part the presentation shows in
    /// focus, the pill out of sight, only the island's glyph clock running. Closed: nothing of the island in focus, its
    /// clock stopped and a close's reset run, and the pill back with its clock running unless it went away.
    @Test(arguments: [false, true])
    func everyReplayEndsAtItsRest(refined: Bool) {
        for scenario in Self.scenarios(refined: refined) {
            var model = scenario.start
            var live = (island: model.isOpen, pill: !model.isOpen)
            var closes = 0, resets = 0
            Self.play(scenario) { m, _, commands in
                model = m
                for command in commands {
                    switch command {
                    case .effect(.islandLive(let on)): live.island = on
                    case .effect(.pillLive(let on)): live.pill = on
                    case .effect(.resetAfterFold): resets += 1
                    default: break
                    }
                }
            }
            for (_, event) in scenario.events { if case .close = event { closes += 1 } }
            #expect(live.island == model.isOpen, "\(scenario.name): the island's clock")
            if model.ordered { #expect(live.pill == !model.isOpen, "\(scenario.name): the pill's clock") }
            if !model.isOpen, closes > 0 { #expect(resets > 0, "\(scenario.name): no reset after the close") }
            func near(_ channel: Channel, _ value: Double) -> Bool { abs(model.value(channel, at: 2.5) - value) < 0.01 }
            if model.isOpen {
                #expect(near(.header, 1) && near(.pill, 0), "\(scenario.name)")
                #expect(!model.presentedParts.isEmpty, "\(scenario.name)")
                for part in model.presentedParts {
                    #expect(near(.part(part), 1), "\(scenario.name): \(part) at \(model.value(.part(part), at: 2.5))")
                }
            } else {
                #expect(near(.header, 0), "\(scenario.name)")
                for channel in model.values.keys {
                    if case .part = channel { #expect(near(channel, 0), "\(scenario.name): \(channel)") }
                }
                if model.ordered { #expect(near(.pill, 1), "\(scenario.name)") }
                #expect(model.shownPill == model.targets.pill, "\(scenario.name): the pill's snapshot")
                if model.ordered, model.targets.topBar || !model.shownPill.isEmpty {
                    #expect(near(.pillArrive, 1), "\(scenario.name): the pill's glyph and count")
                }
            }
        }
    }

    // MARK: 5–7

    @Test func theCanvasNeverMovesOnScreen() {
        let canvas = IslandPanelSizing.canvasRect(centreX: 756, top: 982, screenHeight: 982)
        #expect(canvas.width == 496 && canvas.maxY == 982 && canvas.midX == 756)
        let extents = [IslandExtent(width: 185, height: 32), Self.pill().extent, Self.pill(count: 10).extent,
                       IslandExtent(width: 482, height: 230), IslandExtent(width: 480, height: 600)]
        for extent in extents {
            let panel = NotchGeometry.frame(extent, centreX: 756, top: 982)
            let origin = IslandPanelSizing.hostingOrigin(canvas: canvas, panel: panel)
            #expect(origin.x + panel.minX == canvas.minX && origin.y + panel.minY == canvas.minY)
        }
    }

    @Test func hitRegionUsesTheTarget() {
        let pill = Self.pill().extent
        let rect = NotchGeometry.frame(pill, centreX: 756, top: 982)
        // Inside, outside, and the band that applies only while the landed island is open.
        #expect(IslandHitRegion.contains(CGPoint(x: rect.midX, y: rect.midY), target: pill, centreX: 756, top: 982))
        #expect(!IslandHitRegion.contains(CGPoint(x: rect.maxX + 4, y: rect.midY), target: pill, centreX: 756, top: 982))
        #expect(IslandHitRegion.contains(CGPoint(x: rect.maxX + 4, y: rect.midY), target: pill, centreX: 756, top: 982, band: 8))
        #expect(!IslandHitRegion.contains(CGPoint(x: rect.midX, y: rect.minY - 9), target: pill, centreX: 756, top: 982, band: 8))
        // The pointer pressed against the top edge is on the pill.
        #expect(IslandHitRegion.contains(CGPoint(x: rect.midX, y: 990), target: pill, centreX: 756, top: 982))
        // A hidden sliver is never hit.
        #expect(!IslandHitRegion.contains(CGPoint(x: 756, y: 982), target: .zero, centreX: 756, top: 982))
    }

    @Test func aDisplayChangeSnapsToTheExactRestFrame() {
        let start = Model(metrics: .init(targets: SurfaceTargets(notch: Self.notch, pill: Self.pill()), layout: Self.layout()))
        var (model, _) = Model.replay(start, [(0, .open(.hover, .list))], until: 0.12)
        #expect(!model.jobs.isEmpty)
        let wider = SurfaceTargets(notch: CGSize(width: 204, height: 34), pill: Self.pill(notch: CGSize(width: 204, height: 34)))
        let commands = model.handle(.display(.init(targets: wider, layout: Self.layout())), at: 0.12)
        let island = IslandExtent(width: 480, height: Self.layout().islandHeight(card: nil))
        #expect(commands.filter { if case .panel = $0 { true } else { false } } == [.panel(island)])
        #expect(!commands.contains { if case let .animate(curve, _) = $0 { curve != nil } else { false } })
        #expect(model.jobs.isEmpty && model.surface(at: 0.12) == wider.island(height: island.height))
    }
}

extension DIslandPanelSizingTests.Scenario {
    /// The panel once everything in the scenario has settled: the rest shape it ends in.
    func startedRest(after end: TimeInterval) -> IslandExtent {
        let (model, _) = IslandChoreography.replay(start, events, until: end)
        return model.restGeometry.extent
    }
}
