import AppKit
import CoreGraphics
import Darwin
import Foundation
import Metal
import QuartzCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Motion round B2: the island's outline and the clip that reveals its content drawn by Core Animation from the model's
/// own plan (Diagnostics › Motion › Outline, the motion research's E3 with its eight companions), and F5 (Motion:
/// Refined's open on two springs started together). The model's plan is the model (A); Core Animation's outline builds
/// no path on the main thread (B); a stalled main thread holds none of it, the edge line rides it, and the rising edge
/// never cuts a row the stall holds mid-glide (C); its layers draw the shape SwiftUI draws (E); and it fails closed: the
/// black is its own shape whatever happens to the mask, and every snap, display change and Window ⇄ Island keeps the
/// layers where they belong (F). All headless: windows are never ordered in.
@MainActor
@Suite(.serialized)
struct CoreAnimationOutlineTests {
    typealias Model = IslandChoreography
    typealias Events = [(TimeInterval, Model.Event)]

    static let refined = MotionTuning(motion: .refined, hover: .calm)
    static let liquid = MotionTuning(motion: .liquid, hover: .calm)
    static let notch = DIslandMotionTests.notch
    static let pill = DIslandMotionTests.referencePill
    static let empty = PillContent.make(lead: nil, count: nil, glance: false, style: .pixel, edgeLine: false, notch: notch, menuBar: 33)
    static let bar = PillContent.make(lead: DIslandMotionTests.lead, count: 3, glance: false, style: .pixel, edgeLine: false,
                                      notch: nil, menuBar: 24)

    static func model(layout: ContentLayout = DIslandMotionTests.layout(), surface: Model.Surface = .closed, pill: PillContent = pill,
                      notch: CGSize? = notch, tuning: MotionTuning = MotionTuning(), outline: IslandOutline = .coreAnimation,
                      at t: TimeInterval = 0) -> Model {
        Model(metrics: .init(targets: SurfaceTargets(notch: notch, pill: pill), layout: layout, tuning: tuning, outline: outline),
              surface: surface, at: t)
    }

    struct Scenario {
        var name: String
        var start: Model
        var events: Events
        var until: TimeInterval
        /// The moments the parity strips draw.
        var times: [TimeInterval]
        /// The model's time at its start.
        var base: TimeInterval = 0
    }

    static let openTimes: [TimeInterval] = [0, 0.03, 0.06, 0.1, 0.15, 0.2, 0.26, 0.34, 0.6]

    /// Every kind of surface motion, once under Original and once under Refined (F5's two springs, the tucked fold).
    static func scenarios(tuning: MotionTuning = MotionTuning(), base: TimeInterval = 0) -> [Scenario] {
        let card = DIslandMotionTests.cardLayout("r2")
        func m(_ layout: ContentLayout = DIslandMotionTests.layout(), _ surface: Model.Surface = .closed, pill: PillContent = pill,
               notch: CGSize? = notch) -> Model {
            model(layout: layout, surface: surface, pill: pill, notch: notch, tuning: tuning, at: base)
        }
        let list: [Scenario] = [
            Scenario(name: "swell", start: m(), events: [(0, .swell(true))], until: 0.6, times: [0, 0.03, 0.06, 0.1, 0.2, 0.4]),
            Scenario(name: "open", start: m(), events: [(0, .open(.hover, .list))], until: 1.2, times: openTimes),
            Scenario(name: "hover-open", start: m(), events: [(0, .swell(true)), (0.15, .open(.hover, .list))], until: 1.3,
                     times: [0.1] + openTimes.map { 0.15 + $0 }),
            Scenario(name: "close", start: m(.init(), .island), events: [(0, .close(.fold))], until: 1.2,
                     times: [0, 0.05, 0.1, 0.15, 0.2, 0.272, 0.33, 0.4, 0.46, 0.62]),
            Scenario(name: "abort@90", start: m(), events: [(0, .open(.hover, .list)), (0.09, .close(.abort))], until: 1.2,
                     times: [0.06, 0.09, 0.1, 0.12, 0.15, 0.191, 0.26, 0.42]),
            Scenario(name: "reverse@fold130", start: m(.init(), .island), events: [(0, .close(.fold)), (0.13, .open(.hover, .list))],
                     until: 1.4, times: [0.1, 0.13, 0.14, 0.16, 0.2, 0.3, 0.4, 0.567]),
            Scenario(name: "rapid in/out", start: m(),
                     events: [(0, .open(.hover, .list)), (0.18, .close(.fold)), (0.36, .open(.hover, .list)), (0.54, .close(.fold))],
                     until: 1.8, times: [0.1, 0.18, 0.25, 0.36, 0.45, 0.54, 0.65, 0.9]),
            Scenario(name: "list→card→list", start: m(card, .island), events: [(0, .present(.card(sessionID: "r2"))), (1, .present(.list))],
                     until: 2.2, times: [0, 0.05, 0.103, 0.15, 0.2, 0.3, 1, 1.05, 1.1, 1.15, 1.25, 1.4]),
            Scenario(name: "arrive/depart", start: m(pill: empty), events: [(0, .pill(pill)), (1, .pill(empty))], until: 2.2,
                     times: [0, 0.04, 0.08, 0.12, 0.18, 0.26, 0.4, 1, 1.06, 1.12, 1.2, 1.3, 1.46]),
            Scenario(name: "top bar open/close", start: m(pill: bar, notch: nil), events: [(0, .open(.hover, .list)), (0.8, .close(.fold))],
                     until: 2, times: [0, 0.05, 0.1, 0.2, 0.4, 0.8, 0.9, 1, 1.2]),
            Scenario(name: "hide", start: m(.init(), .island), events: [(0, .hide)], until: 1.2, times: [0, 0.05, 0.1, 0.2, 0.3, 0.5]),
        ]
        return list.map { s in
            var s = s
            s.events = s.events.map { ($0.0 + base, $0.1) }
            s.times = s.times.map { $0 + base }
            s.until += base
            s.base = base
            return s
        }
    }

    /// The plan each event hands Core Animation, from the start and after each event.
    static func plans(_ scenario: Scenario, step: TimeInterval = IslandSurfaceLayers.step, lean: Bool = true) -> [Model.SurfacePlan] {
        var model = scenario.start
        var plans = [model.surfacePlan(from: scenario.base, step: step, lean: lean)]
        for (t, event) in scenario.events {
            _ = model.advance(to: t)
            _ = model.handle(event, at: t)
            plans.append(model.surfacePlan(from: t, step: step, lean: lean))
        }
        return plans
    }

    /// The model's own surface and edge line lift at each of `times` (events at their times, jobs as they fall due).
    static func truth(_ scenario: Scenario, at times: [TimeInterval]) -> [(SurfaceGeometry, CGFloat)] {
        truthAndLiquid(scenario, at: times).map { ($0.0, $0.1) }
    }

    /// The model's own surface, edge line lift and Motion: Liquid's values at each of `times`.
    static func truthAndLiquid(_ scenario: Scenario, at times: [TimeInterval]) -> [(SurfaceGeometry, CGFloat, LiquidParams)] {
        var model = scenario.start
        var pending = scenario.events[...]
        var out: [(SurfaceGeometry, CGFloat, LiquidParams)] = []
        for s in times {
            while let (t, e) = pending.first, t <= s + 1e-12 {
                _ = model.advance(to: t)
                _ = model.handle(e, at: t)
                pending = pending.dropFirst()
            }
            _ = model.advance(to: s)
            out.append((model.surface(at: s), CGFloat(model.value(.rimLift, at: s)), model.liquid(at: s)))
        }
        return out
    }

    /// What Core Animation draws at `s`: the latest plan (by its start), between its samples.
    static func drawn(_ plans: [Model.SurfacePlan], at s: TimeInterval) -> (SurfaceGeometry, CGFloat)? {
        guard let plan = plans.last(where: { $0.start <= s + 1e-12 }) else { return nil }
        return (plan.geometry(at: s), plan.rim(at: s))
    }

    // MARK: A. The plan is the model

    /// Every plan reproduces the model exactly at its samples, jobs and leads included (the open's height 30 ms after
    /// its width under Original, at once under Refined; the fold's lag; the pill's arrival), its last sample the model's
    /// rest (within the 0.002 the springs settle to, measured 0.0017), and Core Animation's linear
    /// interpolation between them stays within 0.2 pt, the edge line's lift too. The copy that skips what cannot move
    /// the surface plans the same samples as the one that runs every job.
    @Test func thePlanIsTheModel() {
        var lines: [String] = []
        for tuning in [MotionTuning(), Self.refined, Self.liquid] {
            for scenario in Self.scenarios(tuning: tuning) {
                let plans = Self.plans(scenario)
                let full = Self.plans(scenario, lean: false)
                #expect(plans == full, "\(scenario.name): the lean plan differs from the full one")
                var atSamples: CGFloat = 0, atRest: CGFloat = 0
                for (k, plan) in plans.enumerated() {
                    let end = k + 1 < plans.count ? plans[k + 1].start : scenario.until
                    let times = plan.surface.indices.map { plan.start + Double($0) * plan.step }.filter { $0 < end - 1e-9 }
                    for ((g, rim, liquid), i) in zip(Self.truthAndLiquid(scenario, at: times), times.indices) {
                        var d = max(IslandSurfaceLayers.distance(g, plan.surface[i]), abs(rim - plan.rim[i]))
                        // Motion: Liquid: its values and the reservoir too.
                        #expect((plan.liquid == nil) == !tuning.liquid, "\(scenario.name): a liquid plan under \(tuning.motion)")
                        if let planned = plan.liquid?[i] { d = max(d, LiquidParams.distance(liquid, planned)) }
                        // The last sample is where the model comes to rest (its targets), which its springs are still
                        // a hair short of there: the layers rest on exactly what the model rests on.
                        if i == plan.surface.count - 1 { atRest = max(atRest, d) } else { atSamples = max(atSamples, d) }
                    }
                }
                let grid = stride(from: 0.0, through: scenario.until, by: 0.0005).map { $0 }
                var between: CGFloat = 0
                for ((g, rim), s) in zip(Self.truth(scenario, at: grid), grid) {
                    guard let d = Self.drawn(plans, at: s) else { continue }
                    between = max(between, IslandSurfaceLayers.distance(g, d.0), abs(rim - d.1))
                }
                lines.append("\(tuning.motion) \(scenario.name): \(plans.count) plans, at samples \(atSamples), between \(between)")
                #expect(atSamples < 1e-6, "\(tuning.motion) \(scenario.name): \(atSamples) pt at the samples")
                #expect(atRest < 0.002, "\(tuning.motion) \(scenario.name): \(atRest) pt at the last sample")
                #expect(between <= 0.2, "\(tuning.motion) \(scenario.name): \(between) pt between the samples")
            }
        }
        print(lines.joined(separator: "\n"))
    }

    /// The model hands the plan the director would: played through the real director on a clock the test drives, with
    /// every job fired on time and, in a second pass, late; the check after each job finds the model on its plan every
    /// time (a job that moved the surface without saying so would have made it play again). An event that moves no
    /// part of the surface (a measurement, a pill that waits while open) leaves the plan playing.
    @Test func theDirectorsJobsNeverLeaveThePlan() {
        for late in [0.0, 0.017] {
            for tuning in [MotionTuning(), Self.refined, Self.liquid] {
                for scenario in Self.scenarios(tuning: tuning, base: 100) {
                    let clock = FakeJobClock(now: 100)
                    let ui = IslandUIState()
                    let director = IslandMotionDirector(model: scenario.start, ui: ui, clock: clock)
                    let layers = IslandSurfaceLayers(canvas: CGSize(width: IslandPanelSizing.canvasWidth, height: 982))
                    director.surface = layers
                    director.reset(scenario.start)
                    for (t, event) in scenario.events {
                        while let due = clock.due, due + late <= t { clock.fire(late: late) }
                        clock.now = t
                        director.send(event)
                    }
                    while clock.due != nil { clock.fire(late: late) }
                    #expect(layers.mismatches == 0, "\(tuning.motion) \(scenario.name) late \(late): \(layers.mismatches) mismatches")
                    #expect(layers.checks > 0 || scenario.name == "swell", "\(scenario.name): no job checked")
                }
            }
        }
        // A measurement that changes nothing of the surface keeps the plan.
        let clock = FakeJobClock(now: 100)
        let start = Self.model(surface: .island, at: 100)
        let director = IslandMotionDirector(model: start, ui: IslandUIState(), clock: clock)
        let layers = IslandSurfaceLayers(canvas: CGSize(width: IslandPanelSizing.canvasWidth, height: 982))
        director.surface = layers
        director.reset(start)
        director.send(.close(.fold))
        let installed = layers.plays - layers.skipped
        clock.now = 100.02
        director.send(.pill(Self.pill))
        director.send(.content(DIslandMotionTests.layout()))
        #expect(layers.plays - layers.skipped == installed && layers.skipped >= 2, "\(layers.plays) plays, \(layers.skipped) kept")
    }

    /// The plan costs the event's turn little (thread CPU, so the machine's load does not count): a median under a
    /// millisecond, and none over 3, for every event of every scenario.
    @Test func aPlanIsCheap() {
        var cpus: [Double] = []
        for tuning in [MotionTuning(), Self.refined] {
            for scenario in Self.scenarios(tuning: tuning) {
                var model = scenario.start
                for (t, event) in scenario.events {
                    _ = model.advance(to: t)
                    _ = model.handle(event, at: t)
                    let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                    _ = model.surfacePlan(from: t, step: IslandSurfaceLayers.step)
                    cpus.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e6)
                }
            }
        }
        let sorted = cpus.sorted()
        print("plan CPU ms: median \(sorted[sorted.count / 2]), max \(sorted.last ?? 0), \(cpus.count) plans")
        #expect(sorted[sorted.count / 2] < 1 && (sorted.last ?? 0) < 3)
        // Motion: Liquid plans in the event (the panel takes in its union): the event and its plan together, against
        // Refined's, the best of five runs each (a debug build: the release budget is Refined's plus a millisecond).
        func turns(_ tuning: MotionTuning) -> [Double] {
            var best: [Double] = []
            for run in 0..<5 {
                var k = 0
                for scenario in Self.scenarios(tuning: tuning) {
                    var model = scenario.start
                    for (t, event) in scenario.events {
                        _ = model.advance(to: t)
                        let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                        _ = model.handle(event, at: t)
                        _ = model.surfacePlan(from: t, step: IslandSurfaceLayers.step)
                        let ms = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e6
                        if run == 0 { best.append(ms) } else { best[k] = min(best[k], ms) }
                        k += 1
                    }
                }
            }
            return best.sorted()
        }
        let refined = turns(Self.refined), liquid = turns(Self.liquid)
        print("event and plan CPU ms: Refined median \(refined[refined.count / 2]), max \(refined.last ?? 0); Liquid median \(liquid[liquid.count / 2]), max \(liquid.last ?? 0)")
        #expect(liquid[liquid.count / 2] < refined[refined.count / 2] + 2 && (liquid.last ?? 0) < (refined.last ?? 0) + 4)
    }

    // MARK: The shoulder gate from the plan

    /// Core Animation's outline takes the brand glyph's and the gear's gate from the width's own crossings: it turns as
    /// the widening surface reaches the gate's near bound and is 90 % there as it reaches the far one, on the open and on
    /// Refined's quicker width; a flick turns it back as the width narrows past the gate, and SwiftUI's outline has no
    /// gate channel (it reads its width in each frame).
    @Test func theShouldersShowAsTheWidthPassesThem() {
        let gate = IslandTheme.Metrics.shoulderGate
        for tuning in [MotionTuning(), Self.refined] {
            let start = Self.model(tuning: tuning)
            let open: Events = [(0, .open(.hover, .list))]
            func width(_ m: Model, _ t: TimeInterval) -> Double { m.value(.left, at: t) + m.value(.right, at: t) }
            let near = DIslandMotionTests.first(start, open) { m, t in width(m, t) >= Double(gate.lowerBound) }
            let far = DIslandMotionTests.first(start, open) { m, t in width(m, t) >= Double(gate.upperBound) }
            let turns = DIslandMotionTests.first(start, open) { m, _ in m.values[.shoulders]?.target == 1 }
            let shown = DIslandMotionTests.first(start, open) { m, t in m.value(.shoulders, at: t) >= 0.9 }
            print("\(tuning.motion): width crosses \(DIslandMotionTests.ms(near))–\(DIslandMotionTests.ms(far)) ms; gate turns at \(DIslandMotionTests.ms(turns)), 90 % at \(DIslandMotionTests.ms(shown))")
            #expect(abs(DIslandMotionTests.ms(turns) - DIslandMotionTests.ms(near)) <= 1)
            #expect(abs(DIslandMotionTests.ms(shown) - DIslandMotionTests.ms(far)) <= 8)
            // Never before the wall has passed it: nothing of it shows while the width is short of the near bound.
            var early = 0.0
            DIslandMotionTests.samples(start, open, until: 0.6) { m, t in
                if width(m, t) < Double(gate.lowerBound) { early = max(early, m.value(.shoulders, at: t)) }
            }
            #expect(early == 0)
            // A flick back: it goes as the width narrows past it.
            let flick: Events = [(0, .open(.hover, .list)), (0.2, .close(.abort))]
            let gone = DIslandMotionTests.first(start, flick, from: 0.2) { m, _ in m.values[.shoulders]?.target == 0 }
            let below = DIslandMotionTests.first(start, flick, from: 0.2) { m, t in width(m, t) <= Double(gate.upperBound) }
            #expect(gone != nil && abs(DIslandMotionTests.ms(gone) - DIslandMotionTests.ms(below)) <= 1)
            // SwiftUI's outline: no channel, no job.
            var swiftUI = Self.model(tuning: tuning, outline: .swiftUI)
            _ = swiftUI.handle(.open(.hover, .list), at: 0)
            _ = swiftUI.advance(to: 0.6)
            #expect(swiftUI.values[.shoulders] == nil && !swiftUI.jobs.contains { $0.tag == .shoulders })
        }
        // Switched at rest: the gate as the rest has it, and gone again for SwiftUI's.
        var open = Self.model(surface: .island, outline: .swiftUI)
        let on = open.handle(.outline(.coreAnimation), at: 0)
        #expect(on == [.animate(nil, [.shoulders: 1])])
        let off = open.handle(.outline(.swiftUI), at: 0)
        #expect(off == [.animate(nil, [.shoulders: 0])] && open.values[.shoulders] == nil)
    }

    // MARK: F5: Motion: Refined's open on two springs

    /// Refined's open starts the width (both reaches and the ear) and the height (the height, the corners and the edge
    /// line's lift) together, each on its own spring, with no job for the height; Original keeps one spring, the height
    /// 30 ms behind. A curve set on one of them leaves the other on its own (a card's height while the width still
    /// widens), where Original's one vector carries all five.
    @Test func refinedOpensOnTwoSpringsStartedTogether() {
        var refined = Self.model(tuning: Self.refined)
        let commands = refined.handle(.open(.hover, .list), at: 0)
        let curves = commands.compactMap { command -> (IslandMotion.Curve, Set<Channel>)? in
            guard case let .animate(curve?, values) = command else { return nil }
            return (curve, Set(values.keys))
        }
        #expect(curves.contains { $0.0 == IslandMotion.splitWidth && $0.1 == [.left, .right, .ear] })
        #expect(curves.contains { $0.0 == IslandMotion.splitHeight && $0.1 == [.height, .radius, .rimLift] })
        #expect(!refined.jobs.contains { if case .openHeight = $0.step { true } else { false } })
        #expect(refined.values[.left]?.curve == IslandMotion.splitWidth && refined.values[.ear]?.curve == IslandMotion.splitWidth)
        #expect(refined.values[.height]?.curve == IslandMotion.splitHeight && refined.values[.radius]?.curve == IslandMotion.splitHeight)
        var original = Self.model()
        _ = original.handle(.open(.hover, .list), at: 0)
        #expect(original.jobs.contains { $0.step == .openHeight(trigger: 0) && abs($0.time - IslandMotion.lead) < 1e-9 })
        // A taller card while the width still widens: the height retargets on the unfold, the width keeps its spring.
        var tall = DIslandMotionTests.layout()
        tall.list += 100
        _ = refined.advance(to: 0.05)
        _ = refined.handle(.content(tall), at: 0.05)
        #expect(refined.values[.height]?.curve == IslandMotion.unfold && refined.values[.left]?.curve == IslandMotion.splitWidth)
        _ = original.advance(to: 0.05)
        _ = original.handle(.content(tall), at: 0.05)
        #expect(original.values[.left]?.curve == IslandMotion.unfold && original.values[.left]?.start == 0.05)
        // The top bar's longer travel on the wide pair.
        var bar = Self.model(pill: Self.bar, notch: nil, tuning: Self.refined)
        _ = bar.handle(.open(.hover, .list), at: 0)
        #expect(bar.values[.left]?.curve == IslandMotion.splitWidthWide && bar.values[.height]?.curve == IslandMotion.splitHeightWide)
    }

    /// Refined's open with F5, against Original, on the reference island: the width 90 % there at 280 ms (308), the
    /// height at 243 (284); the wave behind its edge at 50 · 73 · 113 · 162 · 232 ms (the research's figures); the footer
    /// still the last detail to settle, so it comes into focus on 0.22 (`footerFocusIn`): 90 % at 369 ms, where on the
    /// rows' 0.26 it trailed Original's 334 by 59 ms; the overshoot within the panel's motion margin.
    @Test func refinedsOpenLandsSoonerAndItsFooterKeepsUp() {
        let open: Events = [(0, .open(.hover, .list))]
        let layout = DIslandMotionTests.layout()
        let island = Double(layout.islandHeight(card: nil))
        func timeline(_ tuning: MotionTuning) -> (w90: Int, h90: Int, footer90: Int, overshoot: CGFloat) {
            var w90 = -1, h90 = -1, footer = -1
            var overshoot: CGFloat = 0
            let rest = SurfaceTargets(notch: Self.notch, pill: Self.pill).island(height: CGFloat(island))
            DIslandMotionTests.samples(Self.model(tuning: tuning), open, until: 1) { m, t in
                let g = m.surface(at: t)
                if w90 < 0, Double(g.width) >= 244 + 0.9 * (496 - 244) { w90 = DIslandMotionTests.ms(t) }
                if h90 < 0, Double(g.height) >= 33 + 0.9 * (island - 33) { h90 = DIslandMotionTests.ms(t) }
                if footer < 0, m.value(.part(.footer), at: t) >= 0.9 { footer = DIslandMotionTests.ms(t) }
                overshoot = max(overshoot, g.width - rest.width, g.height - rest.height)
            }
            return (w90, h90, footer, overshoot)
        }
        let original = timeline(MotionTuning()), refined = timeline(Self.refined)
        var rowsCurve = Self.refined
        rowsCurve.footerFocusIn = nil
        let trailing = timeline(rowsCurve)
        print("F5: Original \(original), Refined \(refined), Refined with the rows' curve for the footer \(trailing)")
        #expect(refined.w90 < original.w90 - 20 && refined.h90 < original.h90 - 35)
        #expect(abs(refined.h90 - 243) <= 3)
        #expect(trailing.footer90 > original.footer90 + 40, "the footer trails on the rows' curve")
        #expect(refined.footer90 < trailing.footer90 - 20)
        #expect(refined.overshoot < IslandTheme.Metrics.motionMargin)
    }
}
