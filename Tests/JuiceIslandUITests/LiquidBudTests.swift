import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Motion: Liquid's card bud (L2, the build spec §3.4 to §3.7 and §6): the card buds out below the list on a neck that
/// pinches, spreads into the card and merges back through a join with a gulp; a close takes it in; a second card swaps
/// in the bud; a card with no room presents in the body. Every frame is continuous, joins and parts only as a bead,
/// never draws the belly and the neck at once, never needs the fallback join, and fits the panel; the rest holds the
/// card, the gap and its clicks.
@MainActor
struct LiquidBudTests {
    typealias Model = IslandChoreography
    typealias Motion = LiquidRenders.Motion

    static let card: Model.Event = .present(.card(sessionID: "r1"))
    static let list: Model.Event = .present(.list)
    static let listLayout: ContentLayout = { var l = DIslandMotionTests.layout(); l.cardHeaderTop = 42; return l }()
    static let cardLayout = DIslandMotionTests.cardLayout("r1")
    /// The reference island's bud: the body's walls, 16 below its 228, the 188 card and its insets.
    static let restHalf: CGFloat = 232

    static var motions: [Motion] {
        [Motion(name: "bud", surface: .island, events: [(0, card)], to: 1.2, layout: cardLayout),
         Motion(name: "merge", surface: .island, events: [(0, list)], to: 1.4, presentation: .card(sessionID: "r1"), layout: cardLayout),
         Motion(name: "budflip", surface: .island, events: [(0, card), (0.14, list)], to: 1.3, layout: cardLayout),
         Motion(name: "closebud", surface: .island, events: [(0, .close(.fold))], to: 1.2, presentation: .card(sessionID: "r1"), layout: cardLayout),
         Motion(name: "opencard", events: [(0, .open(.attention, .card(sessionID: "r1")))], to: 1.4, layout: cardLayout),
         Motion(name: "swap", surface: .island, events: [(0, .present(.card(sessionID: "r2"))), (0.02, .content(swapped))], to: 1.2,
                presentation: .card(sessionID: "r1"), layout: cardLayout)]
    }

    /// Bud, merge, close and reopen (to the card, and to the list) reversed at every 30 ms.
    static var reversals: [Motion] {
        stride(from: 0.03, through: 0.45, by: 0.03).flatMap { r -> [Motion] in
            [Motion(name: "budflip@\(r)", surface: .island, events: [(0, card), (r, list)], to: r + 1.1, layout: cardLayout),
             Motion(name: "mergeflip@\(r)", surface: .island, events: [(0, list), (r, card)], to: r + 1.1, presentation: .card(sessionID: "r1"),
                    layout: cardLayout),
             Motion(name: "budclose@\(r)", surface: .island, events: [(0, card), (r, .close(.fold))], to: r + 1.1, layout: cardLayout),
             Motion(name: "closebudopen@\(r)", surface: .island, events: [(0, .close(.fold)), (r, .open(.hover, .card(sessionID: "r1")))],
                    to: r + 1.2, presentation: .card(sessionID: "r1"), layout: cardLayout),
             Motion(name: "closebudlist@\(r)", surface: .island, events: [(0, .close(.fold)), (r, .open(.hover, .list))],
                    to: r + 1.2, presentation: .card(sessionID: "r1"), layout: cardLayout)]
        }
    }

    /// Card r2 measured in r1's place (140 tall).
    static let swapped: ContentLayout = {
        var l = DIslandMotionTests.layout()
        l.card = 140
        l.cardID = "r2"
        l.parts[.cardHeader] = CGRect(x: 18, y: 258, width: 444, height: 31)
        l.parts[.cardBody] = CGRect(x: 18, y: 289, width: 444, height: 100)
        return l
    }()

    static func frames(_ motion: Motion) -> [LiquidMotionTests.Frame] { LiquidMotionTests.frames(motion) }

    /// The model at every 1/240 s of `motion`, with it.
    static func each(_ motion: Motion, _ body: (Model, TimeInterval) -> Void) {
        var model = LiquidRenders.model(motion, until: 0)
        var pending = motion.events.filter { $0.0 > 0 }[...]
        var t: TimeInterval = 0
        while t <= motion.to + 1e-9 {
            while let (s, e) = pending.first, s <= t + 1e-12 {
                _ = model.advance(to: s)
                _ = model.handle(e, at: s)
                pending = pending.dropFirst()
            }
            _ = model.advance(to: t)
            body(model, t)
            t += 1.0 / 240
        }
    }

    // MARK: The bud out

    /// List → card: the list stays in focus, a bead grows and falls on a neck that pinches once, and the bud spreads into
    /// the card at its rest (its gap, the body's walls, the card's height), its parts in focus; the panel is the rest's.
    @Test func theBudPinchesAndSpreadsIntoTheCard() throws {
        let motion = try #require(Self.motions.first { $0.name == "bud" })
        var pinches = 0, joined = true, listDimmed = false
        Self.each(motion) { m, t in
            let p = m.liquid(at: t)
            if joined, !p.isJoined, p.budShows { pinches += 1 }
            joined = p.isJoined
            for part in m.layout.listParts where m.value(.part(part), at: t) < 0.99 { listDimmed = true }
        }
        #expect(pinches == 1 && !listDimmed, "pinches \(pinches), list dimmed \(listDimmed)")
        let end = LiquidRenders.model(motion, until: 2.5)
        let p = end.liquid(at: 2.5)
        #expect(end.budding && abs(p.budGap - 16) < 0.1 && abs(p.budHalf - Self.restHalf) < 0.1 && abs(p.budHeight - (188 + 14)) < 0.1 && abs(p.budRadius - 22) < 0.1,
                "\(p)")
        #expect(end.value(.part(.cardHeader), at: 2.5) > 0.99 && end.value(.part(.cardBody), at: 2.5) > 0.99)
        #expect(abs(end.surface(at: 2.5).height - 228) < 0.01, "the island keeps the list's height")
        #expect(end.panel == end.restExtent && end.restExtent == IslandExtent(left: 240, right: 240, height: 228 + 16 + 202 + 1), "\(end.panel)")
        #expect(end.budState == Model.BudState(base: 228, hit: end.restExtent))
    }

    /// The card may show no content for at most 100 ms once the bud is card-like (wider than the bead), on a present and
    /// on an open to a card.
    @Test func theBlankCardLastsAtMost100ms() {
        for motion in Self.motions where ["bud", "opencard"].contains(motion.name) {
            var blank: TimeInterval = 0
            Self.each(motion) { m, t in
                let p = m.liquid(at: t)
                if p.budShows, !p.isJoined, p.budHalf >= 2 * LiquidMotion.beadRadius, m.value(.part(.cardHeader), at: t) < 0.2 { blank += 1.0 / 240 }
            }
            #expect(blank <= 0.1 + 1e-9, "\(motion.name): blank \(Int(blank * 1000)) ms")
            print("\(motion.name): blank \(Int(blank * 1000)) ms")
        }
    }

    // MARK: The merge

    /// Card → list: the card's content stays in focus (half or more) while the card is 70 % of its width or more; it
    /// joins once, as a bead, and the bud goes into the body with a gulp.
    @Test func theMergeKeepsItsContentPast70Percent() throws {
        let motion = try #require(Self.motions.first { $0.name == "merge" })
        var joins = 0, joined = false, gulped = false
        Self.each(motion) { m, t in
            let p = m.liquid(at: t)
            if p.budHalf >= 0.7 * Self.restHalf {
                #expect(m.value(.part(.cardHeader), at: t) >= 0.5, "at \(Int(t * 1000)) ms: \(m.value(.part(.cardHeader), at: t))")
            }
            if !joined, p.isJoined { joins += 1 }
            joined = p.isJoined
            if p.sag > 1 { gulped = true }
        }
        #expect(joins == 1 && gulped, "joins \(joins), gulped \(gulped)")
        let end = LiquidRenders.model(motion, until: 3)
        #expect(!end.budding && end.budCard == nil && end.cardMounted == nil && end.liquid(at: 3).isRest, "\(end.liquid(at: 3))")
        #expect(end.panel == IslandExtent(left: 240, right: 240, height: 228) && end.budState == Model.BudState())
    }

    // MARK: Every frame

    /// No frame jumps: the union's points move no more than the body's and the liquid values' own motion allows, and where
    /// the neck's flag flips the outlines on either side agree within half a point.
    @Test func budReversalsAreContinuous() {
        var worst: (CGFloat, String) = (0, "")
        for motion in Self.motions + Self.reversals {
            let frames = Self.frames(motion)
            for (a, b) in zip(frames, frames.dropFirst()) {
                let g = IslandSurfaceLayers.distance(a.body, b.body) * 2 + abs(a.body.left - b.body.left) + abs(a.body.right - b.body.right)
                var liquid: CGFloat = abs(a.params.sag - b.params.sag) + abs(a.params.round - b.params.round) * ContinuousCorner.reach
                for key in [LiquidKey.budGap, .budHalf, .budHeight, .budRadius, .lipBody, .lipBead, .tension] {
                    liquid += abs(a.params[key] - b.params[key])
                }
                let allowed = 2 * (g + liquid) + 0.5
                var moved = LiquidPathTests.distance(LiquidPath.elements(a.body, a.params), LiquidPath.elements(b.body, b.params))
                if moved > allowed || a.params.isJoined != b.params.isJoined {
                    moved = LiquidPathTests.hausdorff(LiquidPath.cgPath(a.body, a.params, centreX: 0), LiquidPath.cgPath(b.body, b.params, centreX: 0))
                }
                // Near the pinch the neck's waist moves faster than the values that move it (it goes as a square root):
                // its own motion is allowed too.
                let waist = a.params.isJoined && b.params.isJoined ? abs((LiquidPath.waist(a.params) ?? 0) - (LiquidPath.waist(b.params) ?? 0)) : 0
                let bound = a.params.isJoined != b.params.isJoined ? min(allowed, 0.5 + 2 * liquid) : allowed + 2 * waist
                if moved - bound > worst.0 { worst = (moved - bound, "\(motion.name) at \(b.t): \(moved) pt, \(bound) allowed") }
                #expect(moved <= bound, "\(motion.name) at \(Int(b.t * 1000)) ms: \(moved) pt, \(bound) allowed")
            }
        }
        print("bud reversals: worst over \(worst)")
    }

    /// The neck joins and parts only through a bead (its top a circle), never a flat card's web letting go at once.
    @Test func joinAndPartOnlyThroughTheNeckAsABead() {
        for motion in Self.motions + Self.reversals {
            let frames = Self.frames(motion)
            for (a, b) in zip(frames, frames.dropFirst()) where a.params.isJoined != b.params.isJoined && b.params.budShows {
                // The flag flips between the two frames, where the bud is a bead (the nearer of them no flatter than one).
                #expect(min(LiquidPath.flatTop(a.params), LiquidPath.flatTop(b.params)) <= LiquidMotion.beadFlat + 1e-6,
                        "\(motion.name) at \(Int(b.t * 1000)) ms: flat \(LiquidPath.flatTop(a.params)) → \(LiquidPath.flatTop(b.params))")
            }
        }
    }

    /// Apart, the bud never overlaps the body (the geometry would draw it joined: a jump), and the belly and the neck never
    /// draw at once.
    @Test func theFallbackJoinNeverRunsAndTheBellyWaits() {
        for motion in Self.motions + Self.reversals {
            for f in Self.frames(motion) where f.params.budShows && !LiquidPath.budInside(f.params) {
                if !f.params.isJoined {
                    #expect(f.params.budGap >= -1e-6, "\(motion.name) at \(Int(f.t * 1000)) ms: apart at gap \(f.params.budGap)")
                }
                #expect(f.params.sag <= 0.001, "\(motion.name) at \(Int(f.t * 1000)) ms: belly \(f.params.sag) with the neck")
            }
        }
    }

    /// Every frame's union lies inside the panel; the rest's panel is the rest's reach, the bud included while a card rests
    /// in it.
    @Test func everyBudFrameFitsThePanel() {
        for motion in Self.motions + Self.reversals {
            for f in Self.frames(motion) {
                let e = LiquidPath.extent(f.body, f.params), tolerance = IslandMotion.fitTolerance
                #expect(e.left <= f.panel.left + tolerance && e.right <= f.panel.right + tolerance && e.height <= f.panel.height + tolerance,
                        "\(motion.name) at \(Int(f.t * 1000)) ms: \(e) outside \(f.panel)")
            }
            let end = LiquidRenders.model(motion, until: motion.to + 1.5)
            #expect(end.panel == end.restExtent, "\(motion.name): \(end.panel) against \(end.restExtent)")
            #expect(end.reservoir == nil && end.jobs.isEmpty, "\(motion.name): \(end.jobs.map(\.step))")
        }
    }

    /// The panel holds the rest within the fit's own tolerance, so an event at rest, or in a motion's last half point,
    /// never grows it (P667): the merge back from a card at rest in its bud resizes no window on its trigger turn (a
    /// resize there cost 6 to 9 ms of the merge's send), and an event that moves nothing (an unswell, a close while
    /// closed) any time in a bud's or a close's tail leaves the panel on its rest.
    @Test func anEventAtRestGrowsNoPanel() {
        let rest = LiquidRenders.model(Motion(name: "bud", surface: .island, events: [(0, Self.card)], to: 1.5, layout: Self.cardLayout), until: 1.5)
        #expect(rest.panel == rest.restExtent && rest.jobs.isEmpty)
        for event: Model.Event in [Self.list, .swell(false), .swell(true)] {
            var model = rest
            let commands = model.handle(event, at: 1.5)
            #expect(!commands.contains { if case .panel = $0 { true } else { false } }, "\(event): \(commands)")
        }
        for s in stride(from: 0.2, through: 1.2, by: 0.01) {
            let tails = [Motion(name: "bud", surface: .island, events: [(0, Self.card), (s, .swell(false))], to: s + 1.5, layout: Self.cardLayout),
                         Motion(name: "closebud", surface: .island, events: [(0, .close(.fold)), (s, .close(.fold))], to: s + 1.5,
                                presentation: .card(sessionID: "r1"), layout: Self.cardLayout)]
            for motion in tails {
                let end = LiquidRenders.model(motion, until: motion.to)
                #expect(end.panel == end.restExtent && end.jobs.isEmpty, "\(motion.name) with a no-op at \(s): \(end.panel) against \(end.restExtent)")
            }
        }
    }

    // MARK: Close, swap, room

    /// A close with the bud out: the card contracts to a bead that joins and is in before the body lands (the pill's
    /// height and 20 pt more), and the close ends no later than Refined's close of the card plus 80 ms.
    @Test func closeWithTheBudOut() throws {
        let motion = try #require(Self.motions.first { $0.name == "closebud" })
        let pill = DIslandMotionTests.referencePill.bodyHeight
        var inAt: TimeInterval?, landedAt: TimeInterval?
        Self.each(motion) { m, t in
            let p = m.liquid(at: t)
            if inAt == nil, !p.budShows || LiquidPath.budInside(p) { inAt = t }
            if landedAt == nil, m.surface(at: t).height <= pill + 20 { landedAt = t }
        }
        let inside = try #require(inAt), landed = try #require(landedAt)
        #expect(inside <= landed + 1e-9, "in at \(Int(inside * 1000)) ms, the body at the pill's height and 20 at \(Int(landed * 1000))")
        func settle(_ tuning: MotionTuning) -> TimeInterval {
            var m = LiquidRenders.model(motion, tuning: tuning, until: 0)
            _ = m.handle(.close(.fold), at: 0)
            var t: TimeInterval = 0
            while t < 3 {
                _ = m.advance(to: t)
                if m.isAtRest(at: t) { return t }
                t += 0.004
            }
            return t
        }
        let liquid = settle(LiquidRenders.liquid), refined = settle(LiquidRenders.refined)
        print("close with the bud: liquid \(Int(liquid * 1000)) ms, refined \(Int(refined * 1000)) ms, in at \(Int(inside * 1000)), landed \(Int(landed * 1000))")
        #expect(liquid <= refined + 0.08, "liquid \(liquid) against refined \(refined)")
    }

    /// A second card while one is in the bud: its content swaps there (the first in the leaving layer), there is no second
    /// bud, and the bud takes the new card's height.
    @Test func aSecondCardSwapsInTheBud() throws {
        let motion = try #require(Self.motions.first { $0.name == "swap" })
        Self.each(motion) { m, t in
            let p = m.liquid(at: t)
            #expect(p.budShows && !p.isJoined && !LiquidPath.budInside(p) && LiquidPath.flatTop(p) > 50, "at \(Int(t * 1000)) ms: \(p)")
        }
        let mid = LiquidRenders.model(motion, until: 0.05)
        #expect(mid.cardLeaving == "r1" && mid.cardMounted == "r2" && mid.budCard == "r2")
        let end = LiquidRenders.model(motion, until: 2)
        #expect(abs(end.liquid(at: 2).budHeight - (140 + 14)) < 0.1 && end.panel == end.restExtent, "\(end.liquid(at: 2))")
        #expect(end.value(.part(.cardHeader), at: 2) > 0.99 && end.value(.part(.cardBody), at: 2) > 0.99)
    }

    /// A card with no room for its bud under the display's height presents in the body, as Refined's (the list leaves,
    /// the island takes the card's height); with room it buds.
    @Test func aTallListLeavesRoomForTheBud() {
        for (room, buds) in [(CGFloat(228 + 16 + 202), true), (CGFloat(228 + 16 + 150), false)] {
            var model = Model(metrics: .init(targets: SurfaceTargets(notch: IslandTheme.Metrics.referenceNotch, pill: DIslandMotionTests.referencePill),
                                             layout: Self.cardLayout, tuning: LiquidRenders.liquid, maxHeight: room), surface: .island)
            _ = model.handle(Self.card, at: 0)
            _ = model.advance(to: 2)
            #expect(model.budding == buds && (model.budCard != nil) == buds, "room \(room)")
            #expect(abs(model.surface(at: 2).height - (buds ? 228 : Self.cardLayout.islandHeight(card: "r1"))) < 0.01, "room \(room): \(model.surface(at: 2))")
            #expect(model.liquid(at: 2).budShows == buds && model.value(.part(.row("r0")), at: 2) > (buds ? 0.99 : -1), "room \(room)")
            if !buds { #expect(model.value(.part(.row("r0")), at: 2) < 0.01) }
        }
    }

    /// Reduce Motion: the bud's black snaps in and the card cross-fades in; back, the card fades out and the bud snaps away.
    /// No bead, neck or belly.
    @Test func reduceMotionSnapsTheBud() {
        var model = Model(metrics: .init(targets: SurfaceTargets(notch: IslandTheme.Metrics.referenceNotch, pill: DIslandMotionTests.referencePill),
                                         layout: Self.cardLayout, reduceMotion: true, tuning: LiquidRenders.liquid), surface: .island)
        _ = model.handle(Self.card, at: 0)
        let p = model.liquid(at: 0)
        #expect(abs(p.budGap - 16) < 1e-6 && abs(p.budHalf - Self.restHalf) < 1e-6 && !p.isJoined && p.sag == 0, "\(p)")
        #expect(!model.jobs.contains { if case .liquid = $0.step { true } else { false } }, "\(model.jobs.map(\.step))")
        #expect(model.values[.part(.cardHeader)]?.curve == IslandMotion.reduced)
        _ = model.advance(to: 1)
        _ = model.handle(Self.list, at: 1)
        #expect(model.liquid(at: 1.1).budShows)
        _ = model.advance(to: 1 + IslandMotion.reducedSwap + 0.01)
        #expect(!model.liquid(at: 1.3).budShows)
        _ = model.advance(to: 3)
        #expect(model.budCard == nil && model.panel == IslandExtent(left: 240, right: 240, height: 228))
    }

    // MARK: Clicks, the pointer and the card's place

    /// The card's keys take clicks where the card is (the hit shape holds the bud's rest), and the pointer in the gap
    /// between the list and the card is inside the island; with no card in a bud, neither is.
    @Test func theBudTakesClicksAndThePointerInTheGapStaysInside() {
        let end = LiquidRenders.model(Self.motions[0], until: 2)
        let target = end.restGeometry, hit = end.budState.hit
        let canvas = CGRect(x: 0, y: 0, width: 496, height: 900)
        let gap = CGPoint(x: canvas.midX, y: 228 + 8), key = CGPoint(x: canvas.midX + 150, y: 228 + 16 + 180), below = CGPoint(x: canvas.midX, y: 228 + 16 + 202 + 30)
        let shape = IslandHitShape(geometry: target, hit: hit).path(in: canvas)
        #expect(shape.contains(gap) && shape.contains(key) && !shape.contains(below))
        let bare = IslandHitShape(geometry: target, hit: nil).path(in: canvas)
        #expect(!bare.contains(gap) && !bare.contains(key))
        #expect(bare == NotchSurfaceShape(geometry: target).path(in: canvas), "no bud: the target shape exactly")
        // The pointer (screen space, y up; the top edge at 1000).
        func inside(_ p: CGPoint, _ extent: IslandExtent) -> Bool {
            IslandHitRegion.contains(CGPoint(x: 500 + p.x - canvas.midX, y: 1000 - p.y), target: extent, centreX: 500, top: 1000)
        }
        #expect(inside(gap, hit ?? .zero) && inside(key, hit ?? .zero) && !inside(gap, target.extent))
    }

    /// The card is laid out where its bud is: its parts' frames (which VoiceOver and clicks follow) lie in the bud below
    /// the list, in the live island.
    @Test func theCardsFrameIsItsBud() throws {
        let island = LiveIslandHarness(presenting: nil, tuning: LiquidRenders.liquid)
        island.present(.card(sessionID: FixtureSessionFeed.ID.approval))
        island.play(for: 1.0) { _ in }
        island.settle(0.4)
        let m = island.director.model
        let header = try #require(m.layout.parts[.cardHeader])
        let body = try #require(m.layout.parts[.cardBody])
        let top = m.restGeometry.height + LiquidMotion.restGap
        let bottom = top + m.liquid(at: island.clock.now).budHeight
        #expect(m.budding && island.ui.budBase == m.restGeometry.height && island.ui.budHit == m.restExtent)
        #expect(header.minY >= top + LiquidMotion.budInsetTop - 0.5 && body.maxY <= bottom - LiquidMotion.budInsetBottom + 0.5, "\(header) \(body) in \(top)...\(bottom)")
    }
}
