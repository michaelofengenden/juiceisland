import CoreGraphics
import Foundation
import Testing
@testable import JuiceIslandUI

/// Settings › Island › Motion and Hover (`MotionTuning`): the default is exactly the island's feel before the switches,
/// so every other motion test and render keeps its meaning, and the model, the swell and the hover machine play what the
/// tuning says.
@MainActor
struct MotionTuningTests {
    typealias Model = IslandChoreography

    /// Today's values, as numbers: a change to a default is a change to the island's feel, never a side effect.
    @Test func theDefaultIsTodaysFeelExactly() {
        let t = MotionTuning()
        #expect(t.motion == .original && t.hover == .calm)
        #expect(t.foldLag == 0.050 && t.foldWidthAfter == 0.030)
        #expect(t.fold == IslandMotion.Curve(response: 0.40, dampingFraction: 1) && t.foldWide == IslandMotion.Curve(response: 0.46, dampingFraction: 1))
        #expect(t.pillGate == CGSize(width: 77, height: 27))
        #expect(t.headerIn == 0.040 && t.rowFloor == 0.060 && t.revealCap == 0.100)
        #expect(t.focusIn == IslandMotion.Curve(response: 0.28, dampingFraction: 1))
        #expect(t.glideThreshold == 1 && t.cardBody == 0.030)
        #expect(t.swell == IslandMotion.Curve(response: 0.30, dampingFraction: 0.88))
        #expect(t.swellGrowth == CGSize(width: 6, height: 2) && t.swellRadius == 1 && t.swellEar == 0)
        #expect(t.openDelay == 0.15)
        // The constants the model read before the switches.
        #expect(t.foldLag == IslandMotion.foldLag && t.fold == IslandMotion.fold && t.foldWide == IslandMotion.foldWide
            && t.foldWidthAfter == IslandMotion.lead && t.pillGate == IslandMotion.pillGate && t.headerIn == IslandMotion.headerIn
            && t.rowFloor == IslandMotion.rowFloor && t.revealCap == IslandMotion.cap && t.focusIn == IslandMotion.focusIn
            && t.cardBody == IslandMotion.cardBody && t.swell == IslandMotion.swell && t.swellGrowth == IslandTheme.Metrics.swellGrowth
            && t.openDelay == IslandHoverMachine.openDelay)
        #expect(Model.Metrics(targets: SurfaceTargets(notch: nil, pill: .empty)).tuning == t)
        #expect(IslandHoverMachine().tuning == t)
    }

    /// Refined and Quick are the motion research's round A exactly (recommendations §2a): the tucked fold, the gate
    /// (110, 45) and an 8 pt exit drift; the reveal wave with no cap; the card's 4 pt glide threshold and its body 40 ms
    /// after the tap; the pill's soft changes; and Quick's swell and 110 ms rest. Round B's two springs, and round C's
    /// soft 8 pt edge (F6) with the fold's lag 50 → 30 ms (F1), the pill riding the wings (F7) and continuous corners
    /// (F9). Each switch changes only its own values.
    @Test func refinedAndQuickAreRoundA() {
        let r = MotionTuning(motion: .refined, hover: .calm)
        #expect(r.foldLag == 0.030 && r.foldWidthAfter == 0)
        #expect(r.softEdge == 8 && r.pillRides && r.continuousCorners)
        #expect(r.fold == IslandMotion.Curve(response: 0.40, dampingFraction: 0.95) && r.foldWide == IslandMotion.Curve(response: 0.46, dampingFraction: 0.95))
        #expect(r.pillGate == CGSize(width: 110, height: 45) && r.drift == 8)
        #expect(r.headerIn == 0.030 && r.rowFloor == 0.050 && r.revealCap == nil)
        #expect(r.focusIn == IslandMotion.Curve(response: 0.26, dampingFraction: 1))
        #expect(r.glideThreshold == 4 && r.cardBodyFromTap == 0.040 && r.pillFocus)
        // Round B (F5): the open's two springs, and the footer a little quicker behind them.
        #expect(r.splitsSurface && r.footerFocusIn == IslandMotion.Curve(response: 0.22, dampingFraction: 1))
        var hoverOnly = r
        hoverOnly.motion = .original
        (hoverOnly.fold, hoverOnly.foldWide, hoverOnly.foldWidthAfter, hoverOnly.pillGate, hoverOnly.drift) =
            (IslandMotion.fold, IslandMotion.foldWide, IslandMotion.lead, IslandMotion.pillGate, nil)
        (hoverOnly.headerIn, hoverOnly.rowFloor, hoverOnly.revealCap, hoverOnly.focusIn) =
            (IslandMotion.headerIn, IslandMotion.rowFloor, IslandMotion.cap, IslandMotion.focusIn)
        (hoverOnly.glideThreshold, hoverOnly.cardBodyFromTap, hoverOnly.pillFocus) = (1, nil, false)
        (hoverOnly.splitsSurface, hoverOnly.footerFocusIn) = (false, nil)
        (hoverOnly.foldLag, hoverOnly.softEdge, hoverOnly.pillRides, hoverOnly.continuousCorners) = (IslandMotion.foldLag, 0, false, false)
        #expect(hoverOnly == MotionTuning(), "Refined changes nothing of the hover")
        let q = MotionTuning(motion: .original, hover: .quick)
        #expect(q.swell == IslandMotion.Curve(response: 0.34, dampingFraction: 0.88) && q.swellGrowth == CGSize(width: 10, height: 2))
        #expect(q.swellRadius == 1.5 && q.swellEar == 0.5 && q.openDelay == 0.11)
        var motionOnly = q
        motionOnly.hover = .calm
        (motionOnly.swell, motionOnly.swellGrowth, motionOnly.swellRadius, motionOnly.swellEar, motionOnly.openDelay) =
            (IslandMotion.swell, IslandTheme.Metrics.swellGrowth, 1, 0, IslandHoverMachine.openDelay)
        #expect(motionOnly == MotionTuning(), "Quick changes nothing of the motion")
        // The swell on the owner's display: 5 pt a side, 1.5 rounder, 3.5 pt ears, never taller than the pill.
        let targets = SurfaceTargets(notch: DIslandMotionTests.notch, pill: DIslandMotionTests.referencePill)
        let closed = targets.closed, swell = targets.swell(q)
        #expect(swell.width == closed.width + 10 && swell.height == closed.height && swell.radius == closed.radius + 1.5 && swell.ear == 3.5)
        #expect(MotionTuning(motion: .refined, hover: .quick) == { var both = r; both.hover = .quick
            (both.swell, both.swellGrowth, both.swellRadius, both.swellEar, both.openDelay) = (q.swell, q.swellGrowth, 1.5, 0.5, 0.11)
            return both }())
    }

    /// Refined and Quick by default (motion round B1); each switch keeps its choice under its key, Original and Calm
    /// included, and a value it does not know reads as the default.
    @Test func theSwitchesDefaultToRefinedAndQuickAndPersist() throws {
        let fresh = AppSettings.ephemeral()
        #expect(fresh.islandMotion == .refined && fresh.islandHover == .quick)
        #expect(!fresh.recordIslandMotion && !fresh.paceIslandMotion)
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.islandMotion = .refined
        settings.islandHover = .quick
        settings.recordIslandMotion = true
        settings.paceIslandMotion = true
        #expect(defaults.string(forKey: "ji.island.motion") == "refined" && defaults.string(forKey: "ji.island.hover") == "quick")
        #expect(defaults.object(forKey: "ji.diagnostics.recordIslandMotion") as? Bool == true)
        #expect(defaults.object(forKey: "ji.diagnostics.paceIslandMotion") as? Bool == true)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.islandMotion == .refined && reloaded.islandHover == .quick && reloaded.recordIslandMotion && reloaded.paceIslandMotion)
        settings.islandMotion = .original
        settings.islandHover = .calm
        let kept = AppSettings(defaults: defaults)
        #expect(kept.islandMotion == .original && kept.islandHover == .calm)
        defaults.set("brisk", forKey: AppSettings.Key.islandMotion)
        #expect(AppSettings(defaults: defaults).islandMotion == .refined)
        let tuning = MotionTuning(motion: .refined, hover: .quick)
        #expect(tuning.motion == .refined && tuning.hover == .quick)
    }

    /// The close plays the tuning's lag, fold and width delay, and brings the pill back at its gate.
    @Test func theCloseFollowsItsTuning() {
        func folds(_ tuning: MotionTuning) -> (height: TimeInterval?, width: TimeInterval?, curve: IslandMotion.Curve?, pillIn: TimeInterval?) {
            var model = Self.model(surface: .island, tuning: tuning)
            _ = model.handle(.close(.fold), at: 0)
            let height = model.jobs.first { if case .foldHeight = $0.step { true } else { false } }
            let width = model.jobs.first { if case .foldWidth = $0.step { true } else { false } }
            let curve: IslandMotion.Curve? = if case let .foldHeight(c)? = height?.step { c } else { nil }
            // Past the width's fold, which solves the pill's gate.
            _ = model.advance(to: 0.09)
            return (height?.time, width?.time, curve, model.jobs.first { $0.step == .pillIn }?.time)
        }
        let today = folds(MotionTuning())
        #expect(today.height == 0.050 && today.width == 0.080 && today.curve == IslandMotion.fold)
        var tuning = MotionTuning()
        tuning.foldLag = 0.020
        tuning.foldWidthAfter = 0
        tuning.fold = IslandMotion.Curve(response: 0.40, dampingFraction: 0.95)
        tuning.pillGate = CGSize(width: 110, height: 45)
        let tuned = folds(tuning)
        #expect(tuned.height == 0.020 && tuned.width == 0.020 && tuned.curve == tuning.fold)
        #expect(tuned.pillIn != nil && today.pillIn != nil && tuned.pillIn! < today.pillIn!, "a wider gate brings the pill back sooner")
    }

    /// The open's header, first part and cap follow the tuning, and so does the curve they come in on.
    @Test func theOpenFollowsItsTuning() {
        func reveals(_ tuning: MotionTuning) -> (header: TimeInterval?, flips: [TimeInterval], curve: IslandMotion.Curve?) {
            var model = Self.model(tuning: tuning)
            _ = model.handle(.open(.click, .list), at: 0)
            let header = model.jobs.first { $0.step == .header }?.time
            var commands = model.advance(to: 0.035)
            let flips = model.jobs.compactMap { job -> TimeInterval? in if case .reveal = job.step { job.time } else { nil } }.sorted()
            commands += model.advance(to: 0.5)
            let curve = commands.lazy.compactMap { command -> IslandMotion.Curve? in
                if case let .animate(curve, values) = command, values[.header] == 1 { curve } else { nil }
            }.first
            return (header, flips, curve)
        }
        let today = reveals(MotionTuning())
        #expect(today.header == 0.040 && today.flips.first.map { abs($0 - 0.060) < 1e-9 } == true && today.curve == IslandMotion.focusIn)
        #expect(today.flips.last.map { $0 <= 0.060 + 0.100 + 1e-9 } == true)
        var tuning = MotionTuning()
        tuning.headerIn = 0.030
        tuning.rowFloor = 0.050
        tuning.revealCap = 0.300
        tuning.focusIn = IslandMotion.Curve(response: 0.26, dampingFraction: 1)
        let tuned = reveals(tuning)
        #expect(tuned.header == 0.030 && tuned.flips.first.map { abs($0 - 0.050) < 1e-9 } == true && tuned.curve == tuning.focusIn)
        #expect(tuned.flips.last.map { $0 > 0.060 + 0.100 } == true, "a later cap lets the last part wait for the edge")
    }

    /// The swell grows, rounds and flexes by the tuning, on its curve, and a new tuning reaches the model as an event.
    @Test func theSwellFollowsItsTuning() {
        var tuning = MotionTuning()
        tuning.swellGrowth = CGSize(width: 10, height: 2)
        tuning.swellRadius = 1.5
        tuning.swellEar = 0.5
        tuning.swell = IslandMotion.Curve(response: 0.34, dampingFraction: 0.88)
        var model = Self.model()
        _ = model.handle(.tuning(tuning), at: 0)
        #expect(model.metrics.tuning == tuning)
        let commands = model.handle(.swell(true), at: 0)
        let closed = model.targets.closed, swell = model.restGeometry
        #expect(swell == model.targets.swell(tuning) && swell.width == closed.width + 10 && swell.radius == closed.radius + 1.5
            && swell.ear == closed.ear + 0.5)
        #expect(commands.contains { if case let .animate(curve, values) = $0 { curve == tuning.swell && values[.left] != nil } else { false } })
        let calm = SurfaceTargets(notch: DIslandMotionTests.notch, pill: DIslandMotionTests.referencePill).swell()
        #expect(calm.width == closed.width + 6 && calm.radius == closed.radius + 1 && calm.ear == closed.ear)
    }

    /// List → card: a row nearer the header's place than the threshold crosses where it is; the body follows the cross
    /// by the tuning's delay.
    @Test func theCardFollowsItsTuning() {
        var layout = DIslandMotionTests.layout()
        // Row 0 sits 1 pt from the card header's slot.
        layout.cardHeaderTop = layout.parts[.row("r0")]!.minY + layout.rowInset + 1
        func steps(_ tuning: MotionTuning) -> (glides: Bool, body: TimeInterval?) {
            var model = Self.model(layout: layout, surface: .island, tuning: tuning)
            _ = model.handle(.present(.card(sessionID: "r0")), at: 0)
            let glides = model.jobs.contains { if case .glideStart = $0.step { true } else { false } }
            _ = model.advance(to: 0.045)
            return (glides, model.jobs.first { $0.step == .reveal(.cardBody) }?.time)
        }
        #expect(steps(MotionTuning()).glides)
        var tuning = MotionTuning()
        tuning.glideThreshold = 4
        tuning.cardBody = 0.050
        let tuned = steps(tuning)
        #expect(!tuned.glides && tuned.body.map { abs($0 - (0.040 + 0.050)) < 1e-9 } == true, "\(String(describing: tuned.body))")
    }

    /// The hover machine rests as long as Hover says before it opens.
    @Test func theRestFollowsItsTuning() {
        var machine = IslandHoverMachine()
        machine.tuning.openDelay = 0.11
        let entered = machine.handle(.pointerEntered(at: 0))
        #expect(entered.contains { if case .schedule(0.11, _) = $0 { true } else { false } })
        let moved = machine.handle(.pointerMoved(speed: 400, at: 0.02))
        #expect(moved.contains { if case .schedule(0.11, _) = $0 { true } else { false } })
    }

    static func model(layout: ContentLayout = DIslandMotionTests.layout(), surface: Model.Surface = .closed,
                      tuning: MotionTuning = MotionTuning()) -> Model {
        Model(metrics: .init(targets: SurfaceTargets(notch: DIslandMotionTests.notch, pill: DIslandMotionTests.referencePill), layout: layout,
                             tuning: tuning), surface: surface)
    }

    /// The strip unfolding: the header's pairs are half gone as the usage block starts to come in, not 150 ms before,
    /// so usage never leaves the island while the rows slide down; they start to leave before it, so it never shows
    /// twice at full.
    @Test func theHeaderPairsHoldUntilTheBlockComes() {
        let arrival = IslandMotion.stripBlockArrival(curve: IslandMotion.unfold)
        let pair = ShadowValue(from: 1, velocity: 0, target: 0, start: IslandMotion.stripPairHold, curve: IslandMotion.focusOut)
        let half = IslandMotion.firstTime { pair.value(at: $0) <= 0.5 }
        #expect(arrival > 0.15 && arrival < 0.3)
        #expect(abs(half - arrival) <= 0.01)
        #expect(IslandMotion.stripPairHold < arrival)
    }
}
