import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The island's motion as pure values (spec §9.1): the curves, the choreography's timeline against the spec's numbers,
/// interruptions that keep their velocity, shrinks that never dip inside the pill, the card's glide, and content that
/// never shows outside the surface. Nothing is drawn.
@MainActor
struct DIslandMotionTests {
    typealias Model = IslandChoreography

    // MARK: Fixtures

    static let notch = IslandTheme.Metrics.referenceNotch
    static let lead = PillLead(glyph: .eq, agent: .claude, state: .running)

    /// The spec's reference pill, 253 × 33 (its numbers were worked out on it).
    static let referencePill = PillContent(lead: lead, count: 3, glance: false, style: .pixel, notch: notch, bodyHeight: 33,
                                           leftWing: 31, rightWing: 31)

    /// The spec's reference island: a Clean list of 4 rows and a footer, 228 tall (header 34, 2, 4 × 41, footer 20, 8);
    /// `rows` fewer gives the 167 one (3 rows, no footer).
    static func layout(rows: Int = 4, footer: Bool = true) -> ContentLayout {
        var layout = ContentLayout(header: 34, list: 2 + CGFloat(rows) * 41 + (footer ? 20 : 0))
        for i in 0..<rows { layout.parts[.row("r\(i)")] = CGRect(x: 18, y: 36 + CGFloat(i) * 41, width: 444, height: 41) }
        if footer { layout.parts[.footer] = CGRect(x: 18, y: 36 + CGFloat(rows) * 41, width: 444, height: 20) }
        layout.cardHeaderTop = 34 + 8
        return layout
    }

    static func model(pill: PillContent = referencePill, notch: CGSize? = notch, layout: ContentLayout = layout(),
                      surface: Model.Surface = .closed, reduceMotion: Bool = false) -> Model {
        Model(metrics: .init(targets: SurfaceTargets(notch: notch, pill: pill), layout: layout, reduceMotion: reduceMotion), surface: surface)
    }

    /// Plays `events` and samples every millisecond up to `end`.
    static func samples(_ start: Model, _ events: [(TimeInterval, Model.Event)], until end: TimeInterval,
                        _ body: (Model, TimeInterval) -> Void) {
        var model = start
        let sorted = events.sorted { $0.0 < $1.0 }
        var next = 0
        var t = 0.0
        while t <= end + 1e-9 {
            while next < sorted.count, sorted[next].0 <= t + 1e-9 {
                _ = model.advance(to: sorted[next].0)
                _ = model.handle(sorted[next].1, at: sorted[next].0)
                next += 1
            }
            _ = model.advance(to: t)
            body(model, t)
            t += 0.001
        }
    }

    /// The first sampled time from `from` at which `condition` holds.
    static func first(_ start: Model, _ events: [(TimeInterval, Model.Event)], from: TimeInterval = 0, until end: TimeInterval = 1.5,
                      _ condition: (Model, TimeInterval) -> Bool) -> TimeInterval? {
        var found: TimeInterval?
        samples(start, events, until: end) { model, t in
            if found == nil, t >= from - 1e-9, condition(model, t) { found = t }
        }
        return found
    }

    static func ms(_ t: TimeInterval?) -> Int { Int(((t ?? -1) * 1000).rounded()) }

    // MARK: 1–3: the curves

    /// SwiftUI's `Spring(response:dampingRatio:)` is the closed-form spring the spec's numbers come from: stiffness
    /// (2π / response)², damping 2ζ√k, mass 1; retargets keep position and velocity.
    @Test func curvesMatchTheClosedFormSprings() {
        func closedForm(_ curve: IslandMotion.Curve, from x0: Double, to x1: Double, v0: Double, t: Double) -> Double {
            let w = 2 * Double.pi / curve.response, z = curve.dampingFraction, d0 = x0 - x1
            if z < 1 {
                let a = z * w, wd = w * (1 - z * z).squareRoot(), b = (v0 + a * d0) / wd
                return x1 + exp(-a * t) * (d0 * cos(wd * t) + b * sin(wd * t))
            }
            return x1 + (d0 + (v0 + w * d0) * t) * exp(-w * t)
        }
        for curve in IslandMotion.all {
            for v0 in [0.0, 2000, -2000] {
                for step in 0...150 {
                    let t = Double(step) / 100
                    let value = ShadowValue(from: 253, velocity: v0, target: 480, start: 0, curve: curve).value(at: t)
                    #expect(abs(value - closedForm(curve, from: 253, to: 480, v0: v0, t: t)) < 1e-6, "\(curve) \(v0) \(t)")
                }
            }
        }
    }

    @Test func aRetargetKeepsPositionAndVelocity() {
        var value = ShadowValue(from: 33, velocity: 0, target: 228, start: 0, curve: IslandMotion.unfold)
        let (x, v) = (value.value(at: 0.13), value.velocity(at: 0.13))
        value.retarget(33, curve: IslandMotion.fold, at: 0.13)
        #expect(abs(value.value(at: 0.13) - x) < 1e-9 && abs(value.velocity(at: 0.13) - v) < 1e-9)
        #expect(abs(value.value(at: 0.1301) - x) < 0.2)
        value.retarget(100, curve: nil, at: 0.2)
        #expect(value.value(at: 0.2) == 100 && value.velocity(at: 0.3) == 0)
    }

    /// Growth sets the width 30 ms before the height on the same curve; SwiftUI then carries the whole outline on that
    /// curve from where it is, which leaves the width's path exactly as it was.
    @Test func theWidthLeadComposes() {
        var width = ShadowValue(from: 253, velocity: 0, target: 480, start: 0, curve: IslandMotion.unfold)
        let alone = width
        width.retarget(480, curve: IslandMotion.unfold, at: IslandMotion.lead)
        for step in 30...1500 {
            let t = Double(step) / 1000
            #expect(abs(width.value(at: t) - alone.value(at: t)) < 1e-9)
        }
    }

    // MARK: 4–5: overshoot and shrinks

    @Test(arguments: 0..<4)
    func growthOvershootStaysUnderAPoint(_ index: Int) {
        let notch = DIslandGeometryTests.laptops[index].notch
        for style in GlyphStyle.allCases {
            for notched in [true, false] {
                let pill = PillContent.make(lead: Self.lead, count: 3, glance: false, style: style, edgeLine: true,
                                            notch: notched ? notch : nil, menuBar: notched ? notch.height + 1 : 24)
                let start = Self.model(pill: pill, notch: notched ? notch : nil)
                let island = start.targets.island(height: 228)
                var over = (left: 0.0, right: 0.0, height: 0.0)
                Self.samples(start, [(0, .open(.hover, .list))], until: 1.2) { model, t in
                    let g = model.surface(at: t)
                    over = (max(over.left, g.left - island.left), max(over.right, g.right - island.right), max(over.height, g.height - 228))
                }
                // `unfold` overshoots 0.3 % of the travel: the slim pill's and the top bar's longer travels a little
                // more than the spec's 253 pt pill (0.33 a side), all well inside the 2 pt motion margin.
                let travel = (left: Double(island.left - pill.extent.left), right: Double(island.right - pill.extent.right),
                              height: Double(228 - pill.extent.height))
                #expect(over.left <= 0.0031 * travel.left && over.right <= 0.0031 * travel.right
                    && over.height <= 0.0031 * travel.height, "\(style) \(notched) \(over)")
                #expect(max(over.left, over.right, over.height) < 0.7)
                // A first session's wings.
                var emerge = 0.0
                let idle = Self.model(pill: PillContent.make(lead: nil, count: nil, glance: false, style: style, edgeLine: true,
                                                             notch: notched ? notch : nil, menuBar: notched ? notch.height + 1 : 24),
                                      notch: notched ? notch : nil)
                Self.samples(idle, [(0, .pill(pill))], until: 1) { model, t in
                    let g = model.surface(at: t)
                    emerge = max(emerge, g.left - pill.extent.left, g.right - pill.extent.right, g.height - pill.extent.height)
                }
                #expect(emerge <= 0.15, "\(style) \(notched) \(emerge)")
            }
        }
    }

    @Test func shrinksNeverDipInsideThePill() {
        let pill = Self.referencePill.extent
        func check(_ start: Model, _ events: [(TimeInterval, Model.Event)], target: IslandExtent, after: TimeInterval) {
            Self.samples(start, events, until: 1.8) { model, t in
                guard t >= after else { return }
                let g = model.surface(at: t)
                #expect(g.left >= target.left - 1e-6 && g.right >= target.right - 1e-6 && g.height >= target.height - 1e-6, "\(t) \(g)")
            }
        }
        // Fold, from a landed island.
        check(Self.model(surface: .island), [(0, .close(.fold))], target: pill, after: 0)
        // Unswell.
        check(Self.model(), [(0, .swell(true)), (0.4, .swell(false))], target: pill, after: 0.4)
        // Tuck: the last session.
        let empty = PillContent.make(lead: nil, count: nil, glance: false, style: .pixel, edgeLine: false, notch: Self.notch, menuBar: 33)
        check(Self.model(), [(0, .pill(empty))], target: IslandExtent(width: 185, height: 32), after: 0)
        // Abort from outward velocity, the pointer leaving 30, 60, 90 and 119 ms after the open.
        for leave in [0.03, 0.06, 0.09, 0.119] {
            check(Self.model(), [(0, .open(.hover, .list)), (leave, .close(.abort))], target: pill, after: leave + 0.2)
        }
    }

    // MARK: 6–7: the timelines

    @Test func theOpenTimelineMatchesTheSpec() {
        let start = Self.model()
        let open: [(TimeInterval, Model.Event)] = [(0, .open(.hover, .list))]
        let w90 = Self.first(start, open) { m, t in m.surface(at: t).width >= 253 + 0.9 * 227 }
        let h90 = Self.first(start, open) { m, t in m.surface(at: t).height >= 33 + 0.9 * 195 }
        #expect(abs(Self.ms(w90) - 254) <= 2 && abs(Self.ms(h90) - 284) <= 2, "\(Self.ms(w90)) \(Self.ms(h90))")
        var peak = 0.0
        Self.samples(start, open, until: 0.6) { m, t in
            peak = max(peak, (m.value(.left, at: t + 0.0005) + m.value(.right, at: t + 0.0005)
                - m.value(.left, at: t - 0.0005) - m.value(.right, at: t - 0.0005)) / 0.001)
        }
        // The closed form of `unfold` over the 227 pt gives 1188 pt/s (the spec's 1156 was an estimate).
        #expect(abs(peak - 1188) <= 5, "peak \(peak)")
        // Parts flip in order: the first at 60 ms, each at the edge, 20 ms apart at least, 100 ms after the first at most.
        var flips: [PartID: Int] = [:]
        Self.samples(start, open, until: 0.4) { m, t in
            for part in m.layout.listParts where flips[part] == nil && m.values[.part(part)]?.target == 1 { flips[part] = Self.ms(t) }
        }
        let order = Self.layout().listParts.map { flips[$0] ?? -1 }
        #expect(order.count == 5 && order[0] == 60 && order.last == 160, "\(order)")
        #expect(zip(order, order.dropFirst()).allSatisfy { $1 >= $0 }, "\(order)")
        #expect(abs(order[1] - 105) <= 3 && abs(order[2] - 147) <= 3 && order[3] == 160, "\(order)")
        // The brand glyph and the gear ride out with the shoulders, 410 → 462 pt wide.
        let gate = (Self.first(start, open) { m, t in m.surface(at: t).width >= 410 }, Self.first(start, open) { m, t in m.surface(at: t).width >= 462 })
        #expect(abs(Self.ms(gate.0) - 165) <= 3 && abs(Self.ms(gate.1) - 267) <= 3, "\(Self.ms(gate.0)) \(Self.ms(gate.1))")
        // The panel shrinks to the island once the shape is within 0.5 pt of it for good (about 581 ms), a frame later.
        let fit = Self.first(start, open) { m, _ in m.panel == IslandExtent(width: 480, height: 228) }
        #expect(abs(Self.ms(fit) - (581 + 17)) <= 4, "\(Self.ms(fit))")
    }

    @Test(arguments: [(4, true, 272), (3, false, 240)])
    func theCloseTimelineMatchesTheSpec(_ rows: Int, _ footer: Bool, _ gate: Int) {
        let start = Self.model(layout: Self.layout(rows: rows, footer: footer), surface: .island)
        let close: [(TimeInterval, Model.Event)] = [(0, .close(.fold))]
        let back = Self.first(start, close) { m, _ in m.values[.pill]?.target == 1 }
        #expect(abs(Self.ms(back) - gate) <= 3, "\(Self.ms(back))")
        // The panel shrinks to the pill at the fit (about 612 ms), and the resets wait for it.
        var model = start
        var batches: [(TimeInterval, [Model.Command])] = [(0, model.handle(.close(.fold), at: 0))]
        var t = 0.001
        while t < 1.5 {
            batches.append((t, model.advance(to: t)))
            t += 0.001
        }
        #expect(!batches[0].1.contains(.effect(.resetAfterFold)))
        let shrink = batches.first { $0.1.contains(.panel(Self.referencePill.extent)) }?.0
        let reset = batches.first { $0.1.contains(.effect(.resetAfterFold)) }?.0
        #expect(shrink != nil && reset != nil && (reset ?? 0) >= (shrink ?? 1))
        // The shape fits the pill once each side is within 0.5 pt for good (about 572 ms on the 228 island; the spec's
        // 612 measured the whole width), and the panel follows a frame later.
        var fit = 0.0
        Self.samples(start, close, until: 1.2) { m, t in
            if !Self.referencePill.extent.contains(m.surface(at: t).extent, tolerance: 0.5) { fit = t + 0.001 }
        }
        #expect(abs(Self.ms(shrink) - Self.ms(fit + IslandMotion.frameAhead)) <= 3, "\(Self.ms(shrink)) \(Self.ms(fit))")
        #expect(Self.ms(shrink) < 640)
    }

    // MARK: 8–10: interruptions

    @Test func edgeFlipsAreReSolvedOnRetarget() {
        // Closing, then back 130 ms into the fold: the open runs from the half-folded shape; parts already covered
        // come in at once, 20 ms apart.
        let start = Self.model(surface: .island)
        var model = start
        _ = model.handle(.close(.fold), at: 0)
        _ = model.advance(to: 0.13)
        _ = model.handle(.open(.hover, .list), at: 0.13)
        _ = model.advance(to: 0.13 + IslandMotion.lead)
        let flips = model.jobs.compactMap { job -> TimeInterval? in if case .reveal = job.step { job.time } else { nil } }.sorted()
        #expect(!flips.isEmpty)
        for (a, b) in zip(flips, flips.dropFirst()) { #expect(b - a >= IslandMotion.minStep - 1e-9 || b - a < 1e-9) }
    }

    @Test func aFlickFoldsStraightBack() {
        let start = Self.model()
        let events: [(TimeInterval, Model.Event)] = [(0, .open(.hover, .list)), (0.09, .close(.abort))]
        var peak = (width: 0.0, height: 0.0), minWidth = 1000.0
        var back: TimeInterval?, within: TimeInterval?
        Self.samples(start, events, until: 1.2) { m, t in
            let g = m.surface(at: t)
            peak = (max(peak.width, g.width), max(peak.height, g.height))
            if t > 0.09 { minWidth = min(minWidth, g.width) }
            if t > 0.09, back == nil, m.values[.pill]?.target == 1 { back = t }
            if t > 0.2, within == nil, abs(g.width - 253) < 1, abs(g.height - 33) < 1 { within = t }
        }
        // The closed forms of `unfold` and `abort` from a leave at 90 ms: 342.8 × 81.9 at the peak, within 1 pt at
        // 421 ms (the spec's 346 × 83 and 332 were estimates); the pill's glyph is back 101 ms after the leave.
        #expect(abs(peak.width - 342.8) <= 1 && abs(peak.height - 81.9) <= 1, "\(peak)")
        #expect(abs(Self.ms(back) - 191) <= 4, "\(Self.ms(back))")
        #expect(abs(Self.ms(within) - 421) <= 6, "\(Self.ms(within))")
        #expect(minWidth >= 253 - 1e-6)
    }

    @Test func aReturnDuringTheFoldReversesInPlace() {
        let start = Self.model(surface: .island)
        let events: [(TimeInterval, Model.Event)] = [(0, .close(.fold)), (0.13, .open(.hover, .list))]
        var smallest = (width: 1000.0, height: 1000.0), pill = 0.0
        var within: TimeInterval?
        Self.samples(start, events, until: 1.5) { m, t in
            let g = m.surface(at: t)
            smallest = (min(smallest.width, g.width), min(smallest.height, g.height))
            pill = max(pill, m.value(.pill, at: t))
            if t > 0.3, within == nil, abs(g.width - 480) < 0.5, abs(g.height - 228) < 0.5 { within = t }
        }
        #expect(abs(smallest.width - 408) <= 3 && abs(smallest.height - 138) <= 3, "\(smallest)")
        #expect(pill <= 0.01)
        #expect(abs(Self.ms(within) - 567) <= 8, "\(Self.ms(within))")
    }

    // MARK: 11–12: the card

    /// A row's span at `t`: its home slot plus its glide.
    static func span(_ m: Model, _ id: String, at t: TimeInterval) -> ClosedRange<CGFloat>? {
        guard let rect = m.layout.parts[.row(id)] else { return nil }
        let y = rect.minY + CGFloat(m.value(.glide(id), at: t))
        return y...(y + rect.height)
    }

    @Test(arguments: [0, 1, 3])
    func theCardGlideNeverCrossesARowThatIsShowing(_ index: Int) {
        let id = "r\(index)"
        let start = Self.model(layout: Self.cardLayout(id), surface: .island)
        let events: [(TimeInterval, Model.Event)] = [(0, .present(.card(sessionID: id))), (1, .present(.list))]
        // Card → list: the row glides home across the parts above it, and each waits until the row has passed it
        // (overlapping it by less than 12 pt), or until the cap, 200 ms after the answer, whichever comes first.
        var flips: [PartID: TimeInterval] = [:]
        Self.samples(start, events, until: 2) { m, t in
            guard t >= 1, let row = Self.span(m, id, at: t) else { return }
            for part in m.layout.listParts where part != .row(id) {
                if flips[part] == nil, m.values[.part(part)]?.target == 1 { flips[part] = t }
                guard m.value(.part(part), at: t) > 0.2, let rect = m.layout.parts[part] else { continue }
                let capped = (flips[part] ?? 0) >= 1 + IslandMotion.aboveCap - 0.0015
                let overlap = min(row.upperBound, rect.maxY) - max(row.lowerBound, rect.minY)
                #expect(overlap < (capped ? 20 : IslandMotion.aboveOverlap + 0.5), "\(part) at \(t): \(overlap)")
            }
        }
        // Row 4's home: rows 1, 2 and 3 start at 97, 148 and 200.
        if index == 3 {
            let starts = (0..<3).map { Self.ms((flips[.row("r\($0)")] ?? 0) - 1) }
            #expect(abs(starts[0] - 97) <= 3 && abs(starts[1] - 148) <= 3 && starts[2] == 200, "\(starts)")
        }
        // The row lands at the card's header slot, and there is never an empty frame between row and card header.
        Self.samples(start, events, until: 2) { m, t in
            guard t < 0.5 || (t > 1 && t < 1.5) else { return }
            let shown = m.value(.part(.row(id)), at: t) + m.value(.part(.cardHeader), at: t)
            #expect(shown > 0.4, "void at \(t): \(shown)")
        }
    }

    @Test func aRowAlreadyAtTheHeaderSlotDoesNotGlide() {
        var layout = Self.layout()
        layout.cardHeaderTop = layout.parts[.row("r0")]!.minY + layout.rowInset
        let start = Self.model(layout: layout, surface: .island)
        let (model, commands) = Model.replay(start, [(0, .present(.card(sessionID: "r0")))], until: 0.6)
        #expect(!commands.contains { if case let .animate(_, values) = $0 { values.keys.contains(.glide("r0")) } else { false } })
        #expect(model.values[.part(.cardHeader)]?.target == 1)
    }

    /// A card measured only once it has mounted (every card: its parts go when it unmounts) comes in at the cross all
    /// the same, taller or shorter than the list: its header as the row hands over, its body after it and never ahead
    /// of the edge.
    @Test(arguments: [120, 188] as [CGFloat])
    func aCardMeasuredAfterItMountsComesInAtTheCross(_ height: CGFloat) {
        let start = Self.model(surface: .island)
        var measured = Self.layout()
        measured.card = height
        measured.cardID = "r3"
        measured.parts[.cardHeader] = CGRect(x: 18, y: 42, width: 444, height: 31)
        let body = CGRect(x: 18, y: 73, width: 444, height: height - 48)
        measured.parts[.cardBody] = body
        let events: [(TimeInterval, Model.Event)] = [(0, .present(.card(sessionID: "r3"))), (0.016, .content(measured))]
        var header: TimeInterval?, bodyIn: TimeInterval?, rowOut: TimeInterval?
        var edgeAtBody = 0.0
        Self.samples(start, events, until: 1) { m, t in
            if header == nil, m.values[.part(.cardHeader)]?.target == 1 { header = t }
            if rowOut == nil, m.values[.part(.row("r3"))]?.target == 0 { rowOut = t }
            if bodyIn == nil, m.values[.part(.cardBody)]?.target == 1 { (bodyIn, edgeAtBody) = (t, m.surface(at: t).height) }
        }
        guard let header, let bodyIn, let rowOut else { Issue.record("\(height): the card never came in"); return }
        #expect(abs(header - rowOut) < 0.0015 && header > 0.1, "\(height): header \(Self.ms(header)), row out \(Self.ms(rowOut))")
        #expect(bodyIn >= header + IslandMotion.cardBody - 0.0015, "\(height): body \(Self.ms(bodyIn))")
        #expect(edgeAtBody >= Double(body.minY + IslandMotion.edgeDepth * body.height) - 0.5, "\(height): edge \(edgeAtBody)")
        let (end, _) = Model.replay(start, events, until: 1.5)
        #expect(end.value(.part(.cardHeader), at: 1.5) > 0.99 && end.value(.part(.cardBody), at: 1.5) > 0.99)
    }

    // MARK: 13–14: content and the surface, Reduce Motion

    /// The card fixture: row `id`'s card, 188 tall.
    static func cardLayout(_ id: String) -> ContentLayout {
        var layout = layout()
        layout.card = 188
        layout.cardID = id
        layout.parts[.cardHeader] = CGRect(x: 18, y: 42, width: 444, height: 31)
        layout.parts[.cardBody] = CGRect(x: 18, y: 73, width: 444, height: 140)
        return layout
    }

    /// Where `part` is drawn at `t`: its home slot, drifted up while it comes into focus, plus its glide.
    static func drawn(_ m: Model, _ part: PartID, _ rect: CGRect, at t: TimeInterval) -> CGRect {
        let p = m.value(.part(part), at: t)
        var y = rect.minY - CGFloat(1 - p) * part.drift
        if case let .row(id) = part { y += CGFloat(m.value(.glide(id), at: t)) }
        if part == .cardBody { y += CGFloat(m.value(.cardRide, at: t)) }
        return CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height)
    }

    /// Content comes into focus only where the surface has reached it, and leaves before the fold passes over it: at
    /// every millisecond of the open, the close, the flick, the reversed fold and the card, a part the surface hides
    /// entirely is out of focus (a flip waits for the edge to be a quarter into its part), and a part coming in is
    /// never below the edge.
    @Test func contentNeverShowsOutsideTheSurface() {
        let layout = Self.cardLayout("r2")
        let scenarios: [(String, Model, [(TimeInterval, Model.Event)])] = [
            ("open", Self.model(layout: layout), [(0, .open(.hover, .list))]),
            ("close", Self.model(layout: layout, surface: .island), [(0, .close(.fold))]),
            ("flick", Self.model(layout: layout), [(0, .open(.hover, .list)), (0.09, .close(.abort))]),
            ("card", Self.model(layout: layout, surface: .island), [(0, .present(.card(sessionID: "r2"))), (0.8, .present(.list))]),
            ("reverse", Self.model(layout: layout, surface: .island), [(0, .close(.fold)), (0.13, .open(.hover, .list))]),
            ("added", Self.model(layout: Self.layout(rows: 3, footer: false), surface: .island),
             [(0, .content(Self.layout(rows: 4, footer: false)))]),
            ("added-mid-open", Self.model(layout: Self.layout(rows: 3, footer: false)),
             [(0, .open(.hover, .list)), (0.1, .content(Self.layout(rows: 4, footer: false)))]),
        ]
        for (name, start, events) in scenarios {
            var hidden = (p: 0.0, at: "")
            var early = (p: 0.0, at: "")
            var flips: [PartID: TimeInterval] = [:]
            Self.samples(start, events, until: 1.6) { m, t in
                let g = m.surface(at: t)
                for (part, rect) in m.layout.parts {
                    let p = m.value(.part(part), at: t)
                    let drawn = Self.drawn(m, part, rect, at: t)
                    let target = m.values[.part(part)]?.target ?? 0
                    if target == 1, flips[part] == nil, p < 0.5 { flips[part] = t }
                    if target == 0, drawn.minY >= g.height, p > hidden.p { hidden = (p, "\(part) at \(Self.ms(t))") }
                    // A flip may beat its edge only at the cap: everything is sharp by then, the surface's mask hides
                    // the rest of it (the reference footer flips at 160, its edge is at 272).
                    let capped = flips[part].map { flip in flip - (flips.values.min() ?? flip) >= IslandMotion.cap - 0.0015 } ?? false
                    if target == 1, !capped, drawn.minY + IslandMotion.edgeDepth * drawn.height > g.height + 0.5, p > early.p {
                        early = (p, "\(part) at \(Self.ms(t))")
                    }
                }
            }
            // A fold that passes over a part still fading out cuts it at a fifth of its brightness at most.
            #expect(hidden.p <= 0.2, "\(name): \(hidden)")
            #expect(early.p <= 0.01, "\(name): \(early)")
        }
    }

    /// A part measured while the island is open (a new session, the first one after "No sessions", the footer) comes
    /// into focus as the edge that grows to make room for it reaches it, and is sharp once the island has landed.
    @Test func aPartThatArrivesWhileOpenComesIntoFocus() {
        let three = Self.layout(rows: 3, footer: false), four = Self.layout(rows: 4, footer: false)
        var nothing = ContentLayout(header: 34, list: 32)
        nothing.parts[.empty] = CGRect(x: 18, y: 36, width: 444, height: 32)
        let cases: [(String, Model, [(TimeInterval, Model.Event)], PartID)] = [
            ("mid-open", Self.model(layout: three), [(0, .open(.hover, .list)), (0.1, .content(four))], .row("r3")),
            ("landed", Self.model(layout: three, surface: .island), [(0, .content(four))], .row("r3")),
            ("after no sessions", Self.model(layout: nothing), [(0, .open(.hover, .list)), (1, .content(Self.layout(rows: 1, footer: false)))],
             .row("r0")),
            ("footer", Self.model(layout: three, surface: .island), [(0, .content(Self.layout(rows: 3, footer: true)))], .footer),
        ]
        for (name, start, events, part) in cases {
            let (model, _) = Model.replay(start, events, until: 2.5)
            #expect(model.value(.part(part), at: 2.5) > 0.99, "\(name): \(part) at \(model.value(.part(part), at: 2.5))")
            #expect(abs(model.surface(at: 2.5).height - model.layout.islandHeight(card: nil)) < 0.5, "\(name)")
        }
    }

    /// Under Reduce Motion the outline snaps, and only when nothing shows where the edge jumps: the island's content has
    /// faded before it snaps shut, the pill's before it tucks, the outgoing layer's before the height changes.
    @Test func reduceMotionSnapsOnlyWhenNothingShowsAtTheEdge() {
        let empty = PillContent.make(lead: nil, count: nil, glance: false, style: .pixel, edgeLine: false, notch: Self.notch, menuBar: 33)
        let layout = Self.cardLayout("r2")
        let scenarios: [(String, Model, [(TimeInterval, Model.Event)])] = [
            ("open", Self.model(layout: layout, reduceMotion: true), [(0, .open(.hover, .list))]),
            ("close", Self.model(layout: layout, surface: .island, reduceMotion: true), [(0, .close(.fold))]),
            ("card", Self.model(layout: layout, surface: .island, reduceMotion: true),
             [(0, .present(.card(sessionID: "r2"))), (1, .present(.list))]),
            ("depart", Self.model(reduceMotion: true), [(0, .pill(empty))]),
        ]
        for (name, start, events) in scenarios {
            var model = start
            var pending = events
            var snaps = 0
            var t = 0.0
            while t < 1.6 {
                var commands = model.advance(to: t)
                while let (time, event) = pending.first, time <= t + 1e-9 {
                    pending.removeFirst()
                    commands += model.handle(event, at: t)
                }
                for command in commands {
                    guard case let .animate(curve, values) = command, values.keys.contains(where: \.isSurface) else { continue }
                    #expect(curve == nil, "\(name): the outline travels at \(Self.ms(t))")
                    snaps += 1
                    // Everything that was showing where the edge jumps has faded: the island's parts and header on the
                    // way in or out, and the pill's glyph and count on a tuck.
                    for (channel, value) in model.values where value.target == 0 {
                        switch channel {
                        case .header, .part, .pillArrive:
                            #expect(value.value(at: t) <= 0.01, "\(name): \(channel) at \(Self.ms(t))")
                        default: break
                        }
                    }
                }
                t += 0.001
            }
            #expect(snaps >= 1, "\(name)")
        }
    }

    // MARK: The pill

    @Test func aFirstSessionEmergesAndTheLastTucks() {
        let empty = PillContent.make(lead: nil, count: nil, glance: false, style: .liquid, edgeLine: true, notch: Self.notch, menuBar: 33)
        let pill = PillContent.make(lead: Self.lead, count: 3, glance: false, style: .liquid, edgeLine: true, notch: Self.notch, menuBar: 33)
        let start = Self.model(pill: empty)
        var (model, commands) = Model.replay(start, [(0, .pill(pill))], until: 0.001)
        // The snapshot swaps at once with its glyph and count behind the notch; the wings grow on `emerge`.
        #expect(commands.contains(.pillSnapshot(pill, nil)))
        #expect(commands.contains(.animate(nil, [.pillArrive: 0])))
        #expect(commands.contains { if case let .animate(curve, values) = $0 { curve == IslandMotion.emerge && values[.left] != nil } else { false } })
        commands = model.advance(to: 0.1)
        #expect(commands.contains(.animate(IslandMotion.slide, [.pillArrive: 1])))
        // The last one: the glyph slides back, then the wings tuck; the snapshot empties once it is gone.
        _ = model.advance(to: 1)
        commands = model.handle(.pill(empty), at: 1)
        #expect(commands.contains(.animate(IslandMotion.focusOut, [.pillArrive: 0])))
        #expect(!commands.contains(.pillSnapshot(empty, nil)))
        commands = model.advance(to: 1.2)
        #expect(commands.contains(.pillSnapshot(empty, nil)))
        _ = model.advance(to: 2)
        let idle = model.targets.idle
        #expect(model.panel == IslandExtent(width: 185, height: 32))
        #expect(abs(model.surface(at: 2).width - idle.width) < 0.01 && abs(model.surface(at: 2).height - idle.height) < 0.01)
    }

    /// Without a notch the bar never goes: the brand glyph fades out, the bar resizes, the lead fades in (no slide), and
    /// back.
    @Test func theTopBarStaysAndCrossfadesItsContent() {
        let idle = PillContent.make(lead: nil, count: nil, glance: false, style: .pixel, edgeLine: false, notch: nil, menuBar: 24)
        let pill = PillContent.make(lead: Self.lead, count: 3, glance: false, style: .pixel, edgeLine: false, notch: nil, menuBar: 24)
        let start = Self.model(pill: idle, notch: nil)
        var model = start
        var commands = model.handle(.pill(pill), at: 0)
        #expect(!commands.contains { if case .pillSnapshot = $0 { true } else { false } })
        #expect(commands.contains(.animate(IslandMotion.focusOut, [.pillArrive: 0])))
        commands = model.advance(to: 0.1)
        #expect(commands.contains(.pillSnapshot(pill, nil)) && commands.contains(.animate(IslandMotion.focusIn, [.pillArrive: 1])))
        Self.samples(start, [(0, .pill(pill)), (1, .pill(idle))], until: 2) { m, t in
            #expect(m.surface(at: t).height == 24, "\(t)")
        }
        let (end, _) = Model.replay(start, [(0, .pill(pill)), (1, .pill(idle))], until: 2)
        #expect(end.shownPill == idle && end.panel == idle.extent && end.value(.pillArrive, at: 2) > 0.99)
    }

    /// Folding away for Show as Window, nothing opens the island again: a click on the folding pill and a hover rest
    /// leave it folding, and it still orders out.
    @Test func nothingOpensTheIslandWhileItHides() {
        for surface in [Model.Surface.closed, .island] {
            let events: [(TimeInterval, Model.Event)] = [(0, .hide), (0.1, .open(.click, .list)), (0.2, .open(.hover, .list))]
            let (model, commands) = Model.replay(Self.model(surface: surface), events, until: 2)
            #expect(!model.isOpen && !model.ordered && commands.contains(.effect(.orderOut)), "\(surface)")
            #expect(!commands.contains(.effect(.islandLive(true))), "\(surface)")
        }
    }

    // MARK: The director

    /// An event sent while a batch is being applied (the new target moves the shape under the pointer, and the hover
    /// machine answers at once) is handled once that batch is done, never inside it, so the view ends where the model
    /// rests: here a swell whose target makes the pointer leave, which unswells it.
    @Test func anEventSentWhileABatchIsAppliedWaitsForIt() {
        let ui = IslandUIState()
        let director = IslandMotionDirector(model: Self.model(), ui: ui)
        var answered = false
        director.targetChanged = {
            guard !answered else { return }
            answered = true
            director.send(.swell(false))
        }
        director.send(.swell(true))
        let rest = director.model.restGeometry
        #expect(answered && !director.model.swollen && rest == director.model.targets.closed)
        #expect(ui.surface == rest && ui.target == rest, "\(ui.surface)")
    }

    /// A click just after the last session left (its glyph sliding back, the wings not yet tucked) opens the island on
    /// its own curve, never the tuck's, and the departure lands while the pill is out of sight: the close folds into
    /// the idle notch with the pill emptied.
    @Test func anOpenJustAfterTheLastSessionLeftTakesOverTheDeparture() {
        let empty = PillContent.make(lead: nil, count: nil, glance: false, style: .pixel, edgeLine: false, notch: Self.notch, menuBar: 33)
        var model = Self.model()
        _ = model.handle(.pill(empty), at: 0)
        _ = model.advance(to: 0.05)
        var commands = model.handle(.open(.click, .list), at: 0.05)
        commands += model.advance(to: 1.2)
        #expect(!commands.contains { if case let .animate(curve, _) = $0 { curve == IslandMotion.tuck } else { false } })
        #expect(abs(model.surface(at: 1.2).height - 228) < 0.5 && model.panel == IslandExtent(width: 480, height: 228))
        #expect(model.shownPill == empty)
        _ = model.handle(.close(.fold), at: 1.2)
        _ = model.advance(to: 3)
        #expect(model.panel == IslandExtent(width: 185, height: 32) && model.value(.pill, at: 3) > 0.99)
    }

    /// Without a notch, Show as Island drops the idle bar from the sliver at the top edge (drawn there before it moves,
    /// its brand glyph after it) and Show as Window folds it back into the sliver before the panel goes, never popping
    /// in or out in one frame. Under a notch the idle surface is the notch itself: it is simply ordered in.
    @Test func withoutANotchTheBarDropsFromTheSliverAndFoldsBackIntoIt() {
        let idle = PillContent.make(lead: nil, count: nil, glance: false, style: .pixel, edgeLine: false, notch: nil, menuBar: 24)
        let start = Model(metrics: .init(targets: SurfaceTargets(notch: nil, pill: idle)), ordered: false)
        var shown = start
        let commands = shown.handle(.show, at: 0)
        #expect(commands.contains(.effect(.orderIn)) && shown.surface(at: 0).height == 0 && shown.value(.pillArrive, at: 0) == 0)
        var previous = 0.0, biggestStep = 0.0
        Self.samples(start, [(0, .show)], until: 1) { m, t in
            let height = m.surface(at: t).height
            biggestStep = max(biggestStep, abs(height - previous))
            previous = height
        }
        #expect(biggestStep < 1, "the bar jumps \(biggestStep) pt in a millisecond")
        let (landed, _) = Model.replay(start, [(0, .show)], until: 1)
        #expect(abs(landed.surface(at: 1).height - 24) < 0.01 && landed.value(.pillArrive, at: 1) > 0.99 && landed.panel == idle.extent)
        var (hidden, folding) = Model.replay(landed, [(1, .hide)], until: 1)
        (previous, biggestStep) = (24, 0)
        Self.samples(hidden, [], until: 2.5) { m, t in
            guard t > 1 else { return }
            let height = m.surface(at: t).height
            biggestStep = max(biggestStep, abs(height - previous))
            previous = height
        }
        #expect(biggestStep < 1, "the bar jumps \(biggestStep) pt in a millisecond")
        let more: [Model.Command]
        (hidden, more) = Model.replay(hidden, [], until: 2.5)
        folding += more
        #expect(!hidden.ordered && folding.contains(.effect(.orderOut)) && hidden.surface(at: 2.5).height < 0.01)
        // Under a notch: ordered in, no drop.
        let notched = Model(metrics: .init(targets: SurfaceTargets(notch: Self.notch, pill: Self.referencePill)), ordered: false)
        var model = notched
        #expect(model.handle(.show, at: 0) == [.effect(.orderIn)])
    }

    @Test func aWiderCountResizesTheRightSideOnly() {
        let three = PillContent.make(lead: Self.lead, count: 3, glance: false, style: .liquid, edgeLine: true, notch: Self.notch, menuBar: 33)
        let ten = PillContent.make(lead: Self.lead, count: 10, glance: false, style: .liquid, edgeLine: true, notch: Self.notch, menuBar: 33)
        var model = Self.model(pill: three)
        let commands = model.handle(.pill(ten), at: 0)
        // The panel grows before the snapshot and the outline change together on `resize`.
        let grow = commands.firstIndex { if case .panel = $0 { true } else { false } }
        let animate = commands.firstIndex { if case .animate = $0 { true } else { false } }
        guard let grow, let animate, case let .panel(grown) = commands[grow] else { Issue.record("no growth"); return }
        #expect(grow < animate && grown.right >= ten.extent.right && grown.left == three.extent.left)
        #expect(commands.contains(.pillSnapshot(ten, IslandMotion.resize)))
        Self.samples(model, [], until: 1) { m, t in #expect(abs(m.surface(at: t).left - three.extent.left) < 1e-9) }
        _ = model.advance(to: 1)
        #expect(model.panel == ten.extent)
    }
}
