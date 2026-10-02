import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Motion: Refined and Hover: Quick, the motion research's round A (`MotionTuning(motion:hover:)`), held to the
/// research's numbers on the model: the close's timeline (the empty black span, the glyph back, the landing and how much
/// of the footer the rising edge cuts), the open's reveal wave, the card's cross, the pill's own changes and the hover's
/// pointer model with its brush. Original and Calm are measured beside them, so each number says what changed.
@MainActor
struct MotionRefinedTests {
    typealias Model = IslandChoreography
    typealias Events = [(TimeInterval, Model.Event)]

    static let refined = MotionTuning(motion: .refined, hover: .calm)
    static let quick = MotionTuning(motion: .original, hover: .quick)

    static func model(layout: ContentLayout = DIslandMotionTests.layout(), surface: Model.Surface = .closed,
                      tuning: MotionTuning, reduceMotion: Bool = false, pill: PillContent = DIslandMotionTests.referencePill) -> Model {
        Model(metrics: .init(targets: SurfaceTargets(notch: DIslandMotionTests.notch, pill: pill), layout: layout,
                             reduceMotion: reduceMotion, tuning: tuning), surface: surface)
    }

    /// The research's tall island: the usage block over the reference list, 326 tall (header 34, usage 98, 2, 4 × 41,
    /// footer 20, 8).
    static func usageLayout() -> ContentLayout {
        var layout = ContentLayout(header: 34, list: 98 + 2 + 4 * 41 + 20)
        layout.parts[.usage] = CGRect(x: 18, y: 36, width: 444, height: 98)
        for i in 0..<4 { layout.parts[.row("r\(i)")] = CGRect(x: 18, y: 134 + CGFloat(i) * 41, width: 444, height: 41) }
        layout.parts[.footer] = CGRect(x: 18, y: 134 + 4 * 41, width: 444, height: 20)
        layout.cardHeaderTop = 34 + 8
        return layout
    }

    // MARK: The close (F1)

    struct Close: CustomStringConvertible {
        /// Every part and the header below 5 %, and the pill's glyph back to 5 %: between them nothing shows.
        var contentGone: Int
        var glyphIn: Int
        var glyph90: Int
        /// The shape within 2 pt of the pill for good (width and height).
        var home: Int
        /// The footer's focus when the rising edge has moved 8 pt.
        var footerAtRise: Double
        /// How much of the footer shows where that edge meets it: its focus, faded 2 pt inside a soft edge (F6).
        var footerShown: Double
        var peakHeight: Double
        var peakWidth: Double
        var empty: Int { glyphIn - contentGone }
        var description: String {
            "empty \(empty) ms (\(contentGone)–\(glyphIn)), glyph ≥ 90 % \(glyph90), within 2 pt \(home), footer p "
                + String(format: "%.2f (shown %.2f), peak H %.0f W %.0f pt/s", footerAtRise, footerShown, peakHeight, peakWidth)
        }
    }

    static func close(_ layout: ContentLayout, tuning: MotionTuning) -> Close {
        let start = model(layout: layout, surface: .island, tuning: tuning)
        let island = Double(layout.islandHeight(card: nil))
        let pill = DIslandMotionTests.referencePill.extent
        var gone: TimeInterval = 0, glyphIn: TimeInterval?, glyph90: TimeInterval?, home: TimeInterval = 0, footer: Double?
        var peak = (height: 0.0, width: 0.0)
        DIslandMotionTests.samples(start, [(0, .close(.fold))], until: 1.5) { m, t in
            let shown = ([Channel.header] + m.layout.parts.keys.map(Channel.part)).map { m.value($0, at: t) }.max() ?? 0
            if shown >= 0.05 { gone = t + 0.001 }
            if glyphIn == nil, m.value(.pill, at: t) >= 0.05 { glyphIn = t }
            if glyph90 == nil, m.value(.pill, at: t) >= 0.9 { glyph90 = t }
            let g = m.surface(at: t)
            if abs(g.width - pill.width) > 2 || abs(g.height - pill.height) > 2 { home = t + 0.001 }
            if footer == nil, g.height <= island - 8 { footer = m.value(.part(.footer), at: t) }
            let h = (m.surface(at: t + 0.0005).height - m.surface(at: t - 0.0005).height) / 0.001
            let w = (m.surface(at: t + 0.0005).width - m.surface(at: t - 0.0005).width) / 0.001
            peak = (max(peak.height, -h), max(peak.width, -w))
        }
        let ms = DIslandMotionTests.ms
        return Close(contentGone: ms(gone), glyphIn: ms(glyphIn), glyph90: ms(glyph90), home: ms(home),
                     footerAtRise: footer ?? -1, footerShown: (footer ?? 1) * SoftEdgeMask.alpha(inside: 2, depth: tuning.softEdge),
                     peakHeight: peak.height, peakWidth: peak.width)
    }

    /// The tucked fold against `synth/foldlag.py`'s table, and round C's 30 ms lag behind the soft edge: the empty black
    /// 95 ms (126 on the tall island) where Original has 166 (199) and round A's 50 ms lag had 114 (145), the glyph at
    /// 90 % at 362 (393) where it has 433 (466) and round A 382 (413), the pill within 2 pt at 412 (426) where it has 512
    /// and round A 439 (445). The fold starts 20 ms sooner, so the footer is still at 0.41 (0.45) where the rising edge
    /// has moved 8 pt, where Original's is at 0.23 (0.26) under a hard edge; the soft edge (F6) shows it there at 0.07,
    /// under a third of Original's cut. The model's travels are the reference pill's (243 pt of width, not the script's
    /// round 260), so a few milliseconds differ.
    @Test func theTuckedFoldCarriesAndLands() {
        for (layout, expected) in [(DIslandMotionTests.layout(), (95, 362, 412, 165, 433, 522)),
                                   (Self.usageLayout(), (126, 393, 426, 198, 466, 522))] {
            let today = Self.close(layout, tuning: MotionTuning()), refined = Self.close(layout, tuning: Self.refined)
            print("close \(layout.islandHeight(card: nil)): Original \(today) · Refined \(refined)")
            #expect(abs(refined.empty - expected.0) <= 8 && abs(refined.glyph90 - expected.1) <= 8 && abs(refined.home - expected.2) <= 12,
                    "\(refined)")
            #expect(abs(today.empty - expected.3) <= 8 && abs(today.glyph90 - expected.4) <= 8 && abs(today.home - expected.5) <= 12,
                    "\(today)")
            #expect(today.footerShown == today.footerAtRise && refined.footerShown < today.footerShown / 3, "\(refined) \(today)")
            #expect(refined.peakHeight <= today.peakHeight * 1.05 && refined.peakWidth <= today.peakWidth * 1.05)
        }
    }

    /// Refined folds the height and the width together, on one curve: a retreat's close never folds the height while the
    /// width still grows (Original's width waits 30 ms more).
    @Test func theTuckedFoldMovesOneWay() {
        for tuning in [MotionTuning(), Self.refined] {
            let events: Events = [(0, .open(.hover, .list)), (0.2, .retreat), (0.24, .close(.fold))]
            var growing = 0.0
            DIslandMotionTests.samples(Self.model(tuning: tuning), events, until: 1) { m, t in
                guard t > 0.24 else { return }
                let folding = m.surface(at: t + 0.0005).height < m.surface(at: t - 0.0005).height
                let w = (m.surface(at: t + 0.0005).width - m.surface(at: t - 0.0005).width) / 0.001
                if folding { growing = max(growing, w) }
            }
            print("retreat \(tuning.motion): the width grows at \(Int(growing)) pt/s at most while the height folds")
            if tuning.motion == .refined { #expect(growing < 1) } else { #expect(growing > 100) }
        }
    }

    /// A shrink on the tucked fold dips inside the pill by `IslandMotion.undershoot` of its travel at most
    /// (7.06 × 10⁻⁵): from the reference island, the tall one, a 700 pt one and up to the tallest a display allows
    /// (Show all on a 1,440 pt display, less the Dock and the margin), into the notch's pill and into the no-notch top
    /// bar. In points that is 0.014 from the reference island and 0.1 from the tallest.
    @Test func theTuckedFoldUndershootsTheLeastItMay() {
        let bar = PillContent.make(lead: DIslandMotionTests.lead, count: 3, glance: false, style: .pixel, edgeLine: false, notch: nil, menuBar: 24)
        for height in [228, 326, 700, 1100, 1400] as [CGFloat] {
            var layout = DIslandMotionTests.layout()
            layout.list = height - 34 - 8
            let notch = SurfaceTargets(notch: DIslandMotionTests.notch, pill: DIslandMotionTests.referencePill)
            for targets in [notch, SurfaceTargets(notch: nil, pill: bar)] {
                let start = Model(metrics: .init(targets: targets, layout: layout, tuning: Self.refined), surface: .island)
                let island = start.restGeometry, pill = targets.closed
                var dip = (left: 0.0, right: 0.0, height: 0.0)
                DIslandMotionTests.samples(start, [(0, .close(.fold))], until: 1.8) { m, t in
                    let g = m.surface(at: t)
                    dip = (max(dip.left, pill.left - g.left), max(dip.right, pill.right - g.right), max(dip.height, pill.height - g.height))
                }
                let bound = (left: IslandMotion.undershoot * (island.left - pill.left), right: IslandMotion.undershoot * (island.right - pill.right),
                             height: IslandMotion.undershoot * (island.height - pill.height))
                print("tucked fold from \(height) into the \(targets.topBar ? "top bar" : "pill"): dips "
                    + String(format: "%.4f pt (bound %.4f)", dip.height, bound.height))
                #expect(dip.height > 0 && dip.height <= bound.height && dip.left <= bound.left && dip.right <= bound.right, "\(height): \(dip)")
            }
        }
    }

    /// Hover: Quick's wider ear is the notch pill's (3 → 3.5 pt): the no-notch top bar, which has no ears, swells with
    /// none, as under Calm, and never steps its sides in.
    @Test func quickWidensOnlyAnEarThePillHas() {
        let bar = PillContent.make(lead: DIslandMotionTests.lead, count: 3, glance: false, style: .pixel, edgeLine: false, notch: nil, menuBar: 24)
        let topBar = SurfaceTargets(notch: nil, pill: bar)
        let notch = SurfaceTargets(notch: DIslandMotionTests.notch, pill: DIslandMotionTests.referencePill)
        #expect(topBar.closed.ear == 0 && topBar.swell(Self.quick).ear == 0 && topBar.swell(MotionTuning()).ear == 0)
        #expect(notch.closed.ear == 3 && notch.swell(Self.quick).ear == 3.5 && notch.swell(MotionTuning()).ear == 3)
        var model = Model(metrics: .init(targets: topBar, layout: DIslandMotionTests.layout(), tuning: Self.quick), surface: .closed)
        _ = model.handle(.swell(true), at: 0)
        _ = model.advance(to: 0.6)
        #expect(model.value(.ear, at: 0.6) == 0)
    }

    // MARK: The open (F2)

    /// When each part's focus turns to 1 (ms), and the header's.
    static func flips(_ start: Model, _ events: Events, until end: TimeInterval = 0.6) -> (header: Int?, parts: [Int]) {
        var header: Int?, flips: [PartID: Int] = [:]
        DIslandMotionTests.samples(start, events, until: end) { m, t in
            if header == nil, m.values[.header]?.target == 1 { header = DIslandMotionTests.ms(t) }
            for part in m.layout.listParts where flips[part] == nil && m.values[.part(part)]?.target == 1 { flips[part] = DIslandMotionTests.ms(t) }
        }
        return (header, start.layout.listParts.map { flips[$0] ?? -1 })
    }

    /// The most any part shows while the bottom edge covers more than a quarter of it: where it is drawn (drifted up
    /// while it comes in) and at its place.
    static func slicing(_ start: Model, _ events: Events) -> (drawn: Double, placed: Double, at: String) {
        var worst = (drawn: 0.0, placed: 0.0, at: "")
        DIslandMotionTests.samples(start, events, until: 0.8) { m, t in
            let edge = m.surface(at: t).height
            for (part, rect) in m.layout.parts {
                let p = m.value(.part(part), at: t)
                let drawn = Self.drawn(m, part, rect, at: t)
                if edge < drawn.maxY - 0.25 * drawn.height, p > worst.drawn { worst = (p, worst.placed, "\(part) at \(DIslandMotionTests.ms(t))") }
                if edge < rect.maxY - 0.25 * rect.height { worst.placed = max(worst.placed, p) }
            }
        }
        return worst
    }

    /// Refined's parts come in as one wave behind the dropping edge: with no cap each part flips as the edge is a quarter
    /// into it, the first too (`rowFloor`'s 50 ms its floor), the header at 30: 50 · 73 · 113 · 162 · 232 ms where
    /// Original's cap flips the last two together at 160 (the research's own numbers: round B's F5 starts the height with
    /// the width on its own spring, so the edge reaches each part sooner than round A's 62 · 107 · 148 · 199 · 272). No
    /// part shows more than a quarter while the edge covers more than a quarter of it (Original's footer: 0.85), and no
    /// two come in on one 120 Hz frame.
    @Test func theRevealWaveFollowsTheEdge() {
        let open: Events = [(0, .open(.hover, .list))]
        let today = Self.flips(Self.model(tuning: MotionTuning()), open), refined = Self.flips(Self.model(tuning: Self.refined), open)
        let sliced = (today: Self.slicing(Self.model(tuning: MotionTuning()), open), refined: Self.slicing(Self.model(tuning: Self.refined), open))
        print("open: Original header \(today.header ?? -1), parts \(today.parts), sliced \(sliced.today) · Refined header \(refined.header ?? -1), parts \(refined.parts), sliced \(sliced.refined)")
        #expect(today.header == 40 && today.parts.first == 60 && Array(today.parts.suffix(2)) == [160, 160], "\(today.parts)")
        #expect(refined.header == 30)
        // Each part at its edge (the edge a quarter into it), none sooner.
        let layout = DIslandMotionTests.layout()
        let edges = layout.listParts.map { part -> Int in
            let rect = layout.parts[part]!
            return DIslandMotionTests.ms(DIslandMotionTests.first(Self.model(tuning: Self.refined), open) { m, t in
                m.surface(at: t).height >= Double(rect.minY + IslandMotion.edgeDepth * rect.height)
            })
        }
        for (flip, edge) in zip(refined.parts, edges) { #expect(abs(flip - max(edge, 50)) <= 1, "\(refined.parts) \(edges)") }
        #expect(zip(refined.parts, [50, 73, 113, 162, 232]).allSatisfy { abs($0 - $1) <= 2 }, "\(refined.parts)")
        // One reveal a frame at most.
        func frames(_ tuning: MotionTuning) -> Int {
            var model = Self.model(tuning: tuning), most = 0
            _ = model.handle(.open(.hover, .list), at: 0)
            for frame in 1...72 {
                let reveals = model.advance(to: Double(frame) / 120).reduce(0) { count, command in
                    guard case let .animate(_, values) = command else { return count }
                    return count + values.filter { if case .part = $0.key { $0.value == 1 } else { false } }.count
                }
                most = max(most, reveals)
            }
            return most
        }
        #expect(frames(MotionTuning()) == 2 && frames(Self.refined) == 1)
    }

    /// On every list from one row to four and a footer, Refined's wave cuts no part more than Original's does, and on
    /// the reference island less than a quarter where it is drawn. (A list's last part meets the height's slow tail,
    /// which only F6's soft edge takes further: a lone row still shows 0.41 while more than a quarter covered, where
    /// Original shows 0.74.) The footer's quicker focus (`MotionTuning.footerFocusIn`, round B) shows it 0.26 at its
    /// place while the edge still covers a quarter of it at 253 ms, where it is drawn (4 pt higher, drifting in) 0.12.
    @Test func refinedSlicesNoListMoreThanOriginal() {
        let open: Events = [(0, .open(.hover, .list))]
        for rows in 1...4 {
            for footer in [false, true] {
                let layout = DIslandMotionTests.layout(rows: rows, footer: footer)
                let today = Self.slicing(Self.model(layout: layout, tuning: MotionTuning()), open)
                let refined = Self.slicing(Self.model(layout: layout, tuning: Self.refined), open)
                print("slicing \(rows) rows\(footer ? " and the footer" : ""): Original " + String(format: "%.2f", today.drawn)
                    + " (\(today.at)) · Refined " + String(format: "%.2f", refined.drawn) + " (\(refined.at))")
                #expect(refined.drawn <= today.drawn + 0.001, "\(rows) \(footer): \(refined) against \(today)")
                if rows == 4, footer { #expect(refined.drawn <= 0.25 && refined.placed <= 0.27, "\(refined)") }
            }
        }
    }

    /// A part the edge never reaches (below the tallest island) still comes in, where Original's cap had it.
    @Test func aPartTheEdgeNeverReachesStillComesIn() {
        var layout = DIslandMotionTests.layout()
        layout.parts[.footer] = CGRect(x: 18, y: 2000, width: 444, height: 20)
        var model = Self.model(layout: layout, tuning: Self.refined)
        _ = model.handle(.open(.hover, .list), at: 0)
        _ = model.advance(to: 0.031)
        let footer = model.jobs.first { $0.step == .reveal(.footer) }?.time
        let last = model.jobs.compactMap { job -> TimeInterval? in
            if case let .reveal(part) = job.step, part != .footer { job.time } else { nil }
        }.max() ?? 0
        #expect(footer.map { $0 >= last + IslandMotion.minStep - 1e-9 && $0 < 0.5 } == true, "\(String(describing: footer))")
    }

    /// Where `part` is drawn at `t` as the views draw it under the model's tuning: drifted up while out of focus (8 pt
    /// for a row, Refined), plus its glide or ride.
    static func drawn(_ m: Model, _ part: PartID, _ rect: CGRect, at t: TimeInterval) -> CGRect {
        let p = m.value(.part(part), at: t)
        let drift = IslandChannelReveal.drift(part, tuning: m.tuning)
        var y = rect.minY - CGFloat(1 - p) * drift
        if case let .row(id) = part { y += CGFloat(m.value(.glide(id), at: t)) }
        if part == .cardBody { y += CGFloat(m.value(.cardRide, at: t)) }
        return CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height)
    }

    /// `DIslandMotionTests.contentNeverShowsOutsideTheSurface` under Refined, which has no cap to excuse an early flip:
    /// a part the surface hides is out of focus (a fifth at most as the fold passes over one still fading: behind round
    /// C's soft edge, its top shows no more than a fifth in the fade's outer half, the footer 0.24 where the fade begins,
    /// 8 pt in, as the 30 ms lag folds sooner), and a part never comes in below the edge, in the open, the close, the
    /// flick, the reversed fold, the card and parts that arrive while open.
    @Test func contentNeverShowsOutsideTheSurface() {
        let layout = DIslandMotionTests.cardLayout("r2")
        let three = DIslandMotionTests.layout(rows: 3, footer: false), four = DIslandMotionTests.layout(rows: 4, footer: false)
        let scenarios: [(String, Model, Events)] = [
            ("open", Self.model(layout: layout, tuning: Self.refined), [(0, .open(.hover, .list))]),
            ("close", Self.model(layout: layout, surface: .island, tuning: Self.refined), [(0, .close(.fold))]),
            ("tall close", Self.model(layout: Self.usageLayout(), surface: .island, tuning: Self.refined), [(0, .close(.fold))]),
            ("flick", Self.model(layout: layout, tuning: Self.refined), [(0, .open(.hover, .list)), (0.09, .close(.abort))]),
            ("card", Self.model(layout: layout, surface: .island, tuning: Self.refined),
             [(0, .present(.card(sessionID: "r2"))), (0.8, .present(.list))]),
            ("card r0", Self.model(layout: DIslandMotionTests.cardLayout("r0"), surface: .island, tuning: Self.refined),
             [(0, .present(.card(sessionID: "r0"))), (0.8, .present(.list))]),
            ("card r3", Self.model(layout: DIslandMotionTests.cardLayout("r3"), surface: .island, tuning: Self.refined),
             [(0, .present(.card(sessionID: "r3"))), (0.8, .present(.list))]),
            ("reverse", Self.model(layout: layout, surface: .island, tuning: Self.refined), [(0, .close(.fold)), (0.13, .open(.hover, .list))]),
            ("retreat", Self.model(layout: layout, tuning: Self.refined), [(0, .open(.hover, .list)), (0.2, .retreat), (0.24, .close(.fold))]),
            ("added", Self.model(layout: three, surface: .island, tuning: Self.refined), [(0, .content(four))]),
            ("added-mid-open", Self.model(layout: three, tuning: Self.refined), [(0, .open(.hover, .list)), (0.1, .content(four))]),
        ]
        for (name, start, events) in scenarios {
            var hidden = (p: 0.0, at: ""), early = (p: 0.0, at: "")
            let soft = start.tuning.softEdge
            DIslandMotionTests.samples(start, events, until: 1.6) { m, t in
                let g = m.surface(at: t)
                for (part, rect) in m.layout.parts {
                    let p = m.value(.part(part), at: t)
                    let drawn = Self.drawn(m, part, rect, at: t)
                    let target = m.values[.part(part)]?.target ?? 0
                    // Behind the soft edge (F6) a part's top shows its focus faded by how far inside the edge it is: the
                    // fold passing over a part still fading shows it that much in the fade's outer half (its last 4 pt,
                    // which shows half or less), and the hard edge (no fade) its focus the moment it is hidden.
                    let inside = g.height - drawn.minY
                    let shown = soft > 0 ? p * SoftEdgeMask.alpha(inside: inside, depth: soft) : (inside <= 0 ? p : 0)
                    if target == 0, soft > 0 ? inside <= soft / 2 : inside <= 0, shown > hidden.p {
                        hidden = (shown, "\(part) at \(DIslandMotionTests.ms(t))")
                    }
                    let covered = drawn.minY + IslandMotion.edgeDepth * drawn.height > g.height + 0.5
                    let seen = soft > 0 ? p * SoftEdgeMask.alpha(inside: max(0, inside), depth: soft) : p
                    if target == 1, covered, seen > early.p { early = (seen, "\(part) at \(DIslandMotionTests.ms(t))") }
                }
            }
            print("\(name): hidden while shown \(String(format: "%.3f", hidden.p)) (\(hidden.at)), in under the edge \(String(format: "%.3f", early.p)) (\(early.at))")
            #expect(hidden.p <= 0.2, "\(name): \(hidden)")
            #expect(early.p <= 0.01, "\(name): \(early)")
        }
    }

    // MARK: The card (F4)

    /// List → card on the approval's row, 1 pt from the card header's place: Refined crosses where it is at 40 ms and
    /// brings the body in from the tap at 40, so the island's lower three quarters are empty (nothing above 0.3) for a
    /// moment only, where Original waits for a 1 pt glide and leaves them empty from 64 to 198 ms.
    @Test func theCardCrossHasNoVoid() {
        func card(_ tuning: MotionTuning) -> (glides: Bool, header: Int, body: Int, empty: (Int, Int)) {
            let start = Self.model(layout: DIslandMotionTests.cardLayout("r0"), surface: .island, tuning: tuning)
            let events: Events = [(0, .present(.card(sessionID: "r0")))]
            let (after, _) = Model.replay(start, events, until: 0)
            let glides = after.jobs.contains { if case .glideStart = $0.step { true } else { false } }
            var header = -1, body = -1, empty: (Int, Int) = (-1, -1)
            let lower: [PartID] = [.row("r1"), .row("r2"), .row("r3"), .footer, .cardBody]
            DIslandMotionTests.samples(start, events, until: 0.6) { m, t in
                let ms = DIslandMotionTests.ms(t)
                if header < 0, m.values[.part(.cardHeader)]?.target == 1 { header = ms }
                if body < 0, m.values[.part(.cardBody)]?.target == 1 { body = ms }
                let shown = lower.map { m.value(.part($0), at: t) }.max() ?? 0
                if shown < 0.3, empty.0 < 0 { empty.0 = ms }
                if shown >= 0.3, empty.0 >= 0, empty.1 < 0 { empty.1 = ms }
            }
            return (glides, header, body, empty)
        }
        let today = card(MotionTuning()), refined = card(Self.refined)
        print("card: Original \(today) · Refined \(refined)")
        #expect(today.glides && !refined.glides)
        #expect(refined.header == 40 && refined.body == 40)
        #expect(abs(today.empty.0 - 64) <= 4 && abs(today.empty.1 - 198) <= 6, "\(today)")
        #expect(refined.empty.1 - refined.empty.0 <= 40, "\(refined)")
    }

    /// A card taller than the list: the body waits for the edge that grows to it, never ahead of it, from the tap or
    /// measured after it mounts.
    @Test func aTallCardsBodyWaitsForTheEdge() {
        var tall = DIslandMotionTests.cardLayout("r0")
        tall.card = 400
        tall.parts[.cardBody] = CGRect(x: 18, y: 73, width: 444, height: 352)
        var measuredLater = DIslandMotionTests.layout()
        measuredLater.parts[.cardHeader] = nil
        for (name, start, events) in [
            ("measured", Self.model(layout: tall, surface: .island, tuning: Self.refined), [(0, .present(.card(sessionID: "r0")))] as Events),
            ("after mount", Self.model(layout: measuredLater, surface: .island, tuning: Self.refined),
             [(0, .present(.card(sessionID: "r0"))), (0.016, .content(tall))] as Events),
        ] {
            var bodyIn: TimeInterval?, edge = 0.0
            DIslandMotionTests.samples(start, events, until: 1) { m, t in
                if bodyIn == nil, m.values[.part(.cardBody)]?.target == 1 { (bodyIn, edge) = (t, m.surface(at: t).height) }
            }
            let line = Double(73 + IslandMotion.edgeDepth * 352)
            #expect(bodyIn.map { $0 >= 0.040 - 1e-9 } == true && edge >= line - 0.5, "\(name): \(String(describing: bodyIn)) at \(edge)")
            let (end, _) = Model.replay(start, events, until: 1.5)
            #expect(end.value(.part(.cardHeader), at: 1.5) > 0.99 && end.value(.part(.cardBody), at: 1.5) > 0.99, "\(name)")
        }
    }

    /// The card fixture for row `id` with a card `height` tall (the reference is 188; a card has its header row, 31,
    /// and padding, 17, around its body).
    static func card(_ id: String, height: CGFloat) -> ContentLayout {
        var layout = DIslandMotionTests.cardLayout(id)
        layout.card = height
        layout.parts[.cardBody] = CGRect(x: 18, y: 73, width: 444, height: height - 31 - 17)
        return layout
    }

    /// The most the card body shows while the bottom edge covers more than a quarter of it where it is drawn: drifted
    /// up while out of focus and hanging from its gliding row (`cardRide`), as `IslandChannelReveal` draws it; and when
    /// it starts to come in (ms).
    static func bodySliced(_ start: Model, _ events: Events) -> (p: Double, at: String, flip: Int) {
        var worst = (p: 0.0, at: "", flip: -1)
        DIslandMotionTests.samples(start, events, until: 1.2) { m, t in
            if worst.flip < 0, t >= events.first?.0 ?? 0, m.values[.part(.cardBody)]?.target == 1 { worst.flip = DIslandMotionTests.ms(t) }
            guard m.cardMounted != nil, let rect = m.layout.parts[.cardBody] else { return }
            let p = m.value(.part(.cardBody), at: t), drawn = Self.drawn(m, .cardBody, rect, at: t), edge = m.surface(at: t).height
            if edge < drawn.maxY - 0.25 * drawn.height, p > worst.p {
                worst = (p, "\(DIslandMotionTests.ms(t)) ms, edge \(Int(edge)), drawn \(Int(drawn.minY))–\(Int(drawn.maxY))", worst.flip)
            }
        }
        return worst
    }

    /// Refined brings the card body in from the tap only once the edge has passed most of it where it is drawn: under a
    /// row that still glides up (rows 2 to 4), on a card taller than the list, on a swap to a tall card and on a card
    /// measured only after it mounts, the body never shows more than Original's does while the edge still covers more
    /// than a quarter of it, or more than a quarter at most. (Gated on its resting place, row 4's body came in at 40 ms
    /// half-way into focus while it rode 55 pt below its home, under the edge.)
    @Test func theCardBodyComesInWhereTheEdgeHasPassedItAsDrawn() {
        var cases: [(String, (MotionTuning) -> Model, Events)] = []
        for row in ["r0", "r1", "r2", "r3"] {
            for height in [188, 260, 400] as [CGFloat] {
                cases.append(("\(row), card \(Int(height))", { Self.model(layout: Self.card(row, height: height), surface: .island, tuning: $0) },
                              [(0, .present(.card(sessionID: row)))]))
            }
        }
        var before = DIslandMotionTests.layout()
        before.parts[.cardHeader] = nil
        for row in ["r0", "r3"] {
            for height in [188, 400] as [CGFloat] {
                for late in [0.016, 0.050, 0.100] {
                    cases.append(("\(row), card \(Int(height)) measured at \(Int(late * 1000)) ms",
                                  { Self.model(layout: before, surface: .island, tuning: $0) },
                                  [(0, .present(.card(sessionID: row))), (late, .content(Self.card(row, height: height)))]))
                }
            }
        }
        // Resting on row 2's card: the tall card built ahead for row 3, measured as it goes live, takes its place.
        cases.append(("card → a tall card", { tuning in
            Model(metrics: .init(targets: SurfaceTargets(notch: DIslandMotionTests.notch, pill: DIslandMotionTests.referencePill),
                                 layout: Self.card("r2", height: 400), tuning: tuning),
                  surface: .island, presentation: .card(sessionID: "r1"))
        }, [(0, .present(.card(sessionID: "r2")))]))
        for (name, start, events) in cases {
            let original = Self.bodySliced(start(MotionTuning()), events), refined = Self.bodySliced(start(Self.refined), events)
            print("card body under the edge, \(name): Original " + String(format: "%.2f", original.p)
                + " (\(original.at)), in at \(original.flip) ms · Refined " + String(format: "%.2f", refined.p)
                + " (\(refined.at)), in at \(refined.flip) ms")
            #expect(refined.p <= max(original.p + 0.001, 0.25), "\(name): Refined \(refined) against Original \(original)")
        }
    }

    // MARK: The pill (F8)

    /// A new lead or count of the same size: Refined writes the snapshot on `pillIn` so the lead's focus pull and the
    /// count's roll play (Original and Reduce Motion write it still, the lead swapping in one frame), and only while the
    /// pill shows.
    @Test func aSameSizePillChangePlaysOnPillIn() {
        let old = DIslandMotionTests.referencePill
        var new = old
        new.lead = PillLead(glyph: .bang, agent: .codex, state: .waiting)
        new.count = 4
        #expect(new.extent == old.extent)
        func snapshot(_ tuning: MotionTuning, reduceMotion: Bool = false, open: Bool = false) -> IslandMotion.Curve?? {
            var model = Self.model(surface: open ? .island : .closed, tuning: tuning, reduceMotion: reduceMotion)
            return model.handle(.pill(new), at: 1).lazy.compactMap { command -> IslandMotion.Curve?? in
                if case let .pillSnapshot(pill, curve) = command, pill == new { curve } else { nil }
            }.first
        }
        #expect(snapshot(Self.refined) == .some(IslandMotion.pillIn))
        #expect(snapshot(MotionTuning()) == .some(nil))
        #expect(snapshot(Self.refined, reduceMotion: true) == .some(nil))
        #expect(snapshot(Self.refined, open: true) == .some(nil))
        #expect(IslandMotionDirector.transactions([.pillSnapshot(new, IslandMotion.pillIn)]) == [.pill(new, IslandMotion.pillIn)])
        // The views learn the tuning from the model.
        let ui = IslandUIState()
        IslandMotionDirector.snap(ui, to: Self.model(tuning: Self.refined), at: 0)
        #expect(ui.tuning.pillFocus && !MotionTuning().pillFocus)
    }

    /// On a real hosting view (a window never ordered in, the glyph's own clock held still): Refined's new lead pulls
    /// into focus and its count rolls over frames of their own. Original's still write is now a plain transaction (E5),
    /// so its lead plays its own 0.25 s crossfade, which the write that disabled animations cut to one frame (map D1, the
    /// implicit animation round B1 lets run), and its count, which has no transition of its own, still swaps at once.
    @Test func thePillsOwnChangesDrawInBetweenFrames() throws {
        let env = AppEnvironment.demo()
        let old = DIslandMotionTests.referencePill
        var lead = old, count = old
        lead.lead = PillLead(glyph: .bang, agent: .codex, state: .waiting)
        count.count = 4
        for (name, new) in [("lead", lead), ("count", count)] {
            let original = try Self.inBetweenFrames(from: old, to: new, refined: false, env: env)
            let refined = try Self.inBetweenFrames(from: old, to: new, refined: true, env: env)
            print("the pill's \(name): Original \(original) frames between, Refined \(refined)")
            #expect((name == "lead" ? original > 0 : original == 0) && refined > 0, "\(name): \(original) \(refined)")
        }
    }

    /// How many distinct images the pill draws between `from` and `to` (neither the one nor the other), sampled every
    /// few milliseconds over 0.5 s after the snapshot is written as the director writes it.
    static func inBetweenFrames(from: PillContent, to: PillContent, refined: Bool, env: AppEnvironment) throws -> Int {
        _ = NSApplication.shared
        let ui = IslandUIState()
        ui.pill = from
        ui.tuning = refined ? Self.refined : MotionTuning()
        let size = CGSize(width: 280, height: 40)
        let root = PillProbe(ui: ui).environment(env).environment(\.colorScheme, .dark).environment(\.glyphClock, GlyphClock())
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        func image() throws -> Data {
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return try #require(rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerPlane) })
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let before = try image()
        var model = Self.model(tuning: ui.tuning, pill: from)
        for command in model.handle(.pill(to), at: 1) { IslandMotionDirector.write(command, to: ui) }
        var seen = Set<Data>()
        let end = Date().addingTimeInterval(0.5)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
            seen.insert(try image())
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let after = try image()
        window.contentView = nil
        window.close()
        #expect(before != after)
        return seen.subtracting([before, after]).count
    }

    /// The live pill as the island draws it, from the views' state.
    struct PillProbe: View {
        let ui: IslandUIState
        var body: some View {
            ClosedPillView(notch: DIslandMotionTests.notch, animated: true, content: ui.pill, leadFocus: ui.tuning.pillFocus)
                .frame(width: 280, height: 40, alignment: .top)
        }
    }

    // MARK: Hover (F3)

    /// A pointer driven through `PointerSpeed` and the hover machine, with the choreography's target for inside and
    /// outside (the swell widens it): samples every `1/rate` s along `path` (points from the notch's middle, x right and
    /// y down from the screen's top edge), the machine's timers at their times. Returns when it entered, swelled and
    /// opened, and the model at the end.
    static func hover(_ tuning: MotionTuning, rate: Double = 120, until end: TimeInterval,
                      path: (TimeInterval) -> CGPoint) -> (entered: TimeInterval?, swelled: TimeInterval?, opened: TimeInterval?, model: Model) {
        var machine = IslandHoverMachine()
        machine.tuning = tuning
        var model = Self.model(tuning: tuning)
        var speed = PointerSpeed()
        var timers: [(time: TimeInterval, generation: Int)] = []
        var inside = false
        var entered: TimeInterval?, swelled: TimeInterval?, opened: TimeInterval?
        func run(_ effects: [IslandHoverMachine.Effect], at t: TimeInterval) {
            for effect in effects {
                switch effect {
                case let .schedule(after, generation): timers.append((t + after, generation))
                case let .swell(on):
                    if on, swelled == nil { swelled = t }
                    _ = model.advance(to: t)
                    _ = model.handle(.swell(on), at: t)
                case let .open(reason):
                    if opened == nil { opened = t }
                    _ = model.advance(to: t)
                    _ = model.handle(.open(reason, .list), at: t)
                case let .close(style):
                    _ = model.advance(to: t)
                    _ = model.handle(.close(style), at: t)
                case .retreat, .resume: break
                }
            }
        }
        var sample = 0
        while true {
            let t = Double(sample) / rate
            guard t <= end else { break }
            // Timers due before this sample fire first, in order.
            while let next = timers.enumerated().min(by: { $0.element.time < $1.element.time }), next.element.time <= t {
                timers.remove(at: next.offset)
                run(machine.handle(.timerFired(generation: next.element.generation, at: next.element.time)), at: next.element.time)
            }
            let point = path(t)
            let target = model.restGeometry
            let now = point.y <= target.height && point.x >= -target.left && point.x <= target.right
            let v = speed.add(point, at: t)
            if now != inside {
                inside = now
                if now, entered == nil { entered = t }
                run(machine.handle(now ? .pointerEntered(at: t) : .pointerExited(at: t)), at: t)
            }
            if now { run(machine.handle(.pointerMoved(speed: v, at: t)), at: t) }
            sample += 1
        }
        return (entered, swelled, opened, model)
    }

    /// design §3.5's pointer model: a minimum-jerk move of 390 pt up into the pill, over 350, 450 and 600 ms, coming to
    /// rest 22 pt inside it (it enters at 283, 367 and 483 ms, as there). Quick opens 40 ms sooner (177–193 ms after the
    /// entry here, where Calm takes 217–233; the research's 168–185 and 208–225) and out of a swell still widening, where
    /// Calm's has all but stopped.
    @Test func quickOpensOutOfAMovingSwell() {
        for (duration, calm, quick) in [(0.35, 208, 168), (0.45, 217, 177), (0.60, 225, 185)] {
            func move(_ t: TimeInterval) -> CGPoint {
                let s = min(max(t / duration, 0), 1)
                return CGPoint(x: 0, y: 11 + 390 * (1 - (10 * pow(s, 3) - 15 * pow(s, 4) + 6 * pow(s, 5))))
            }
            var speeds: [HoverFeel: Double] = [:], opens: [HoverFeel: Int] = [:]
            for tuning in [MotionTuning(), Self.quick] {
                let run = Self.hover(tuning, until: 1.2, path: move)
                guard let entered = run.entered, let swelled = run.swelled, let opened = run.opened else {
                    Issue.record("\(duration) \(tuning.hover): \(run)"); continue
                }
                let after = DIslandMotionTests.ms(opened - entered)
                // The swell's outward speed per side when the open fires.
                speeds[tuning.hover] = Self.swellSpeed(tuning, swelled: swelled, opened: opened)
                print("move \(Int(duration * 1000)) ms, \(tuning.hover): enters \(DIslandMotionTests.ms(entered)), swells \(DIslandMotionTests.ms(swelled)), opens +\(after) after the entry, the swell widening at \(String(format: "%.0f", speeds[tuning.hover] ?? 0)) pt/s")
                // Within a sample of the research's (its pointer's last fast sample falls a little differently).
                #expect(abs(after - (tuning.hover == .quick ? quick : calm)) <= 9, "\(duration) \(tuning.hover): +\(after)")
                opens[tuning.hover] = after
            }
            #expect(opens[.calm].map { calm in opens[.quick].map { abs(calm - $0 - 40) <= 1 } } == true, "\(opens)")
            #expect((speeds[.quick] ?? 0) > 2 * (speeds[.calm] ?? 0) && (speeds[.quick] ?? 0) >= 15, "\(speeds)")
        }
        // The research's framing, the open its rest after the swell starts: 54 pt/s against 17.
        let framed = (calm: Self.swellSpeed(MotionTuning(), swelled: 0, opened: 0.15), quick: Self.swellSpeed(Self.quick, swelled: 0, opened: 0.11))
        print("the swell widening when the open fires its rest after the swell: Calm \(String(format: "%.0f", framed.calm)), Quick \(String(format: "%.0f", framed.quick)) pt/s")
        #expect(abs(framed.calm - 17) <= 3 && abs(framed.quick - 54) <= 4, "\(framed)")
    }

    /// How fast the swell widens (both sides, pt/s) at `opened`, having started at `swelled`.
    static func swellSpeed(_ tuning: MotionTuning, swelled: TimeInterval, opened: TimeInterval) -> Double {
        var swell = Self.model(tuning: tuning)
        _ = swell.handle(.swell(true), at: swelled)
        return (swell.values[.left]?.velocity(at: opened) ?? 0) + (swell.values[.right]?.velocity(at: opened) ?? 0)
    }

    /// A brush: the pointer crossing the pill at 500 pt/s, along the menu bar or down through it to the tabs below, at
    /// 120 and 60 samples a second, never opens the island, Calm or Quick; the pill nods (swells) and lets go.
    @Test func aBrushNeverOpens() {
        let paths: [(String, (TimeInterval) -> CGPoint)] = [
            ("along the menu bar", { t in CGPoint(x: -300 + 500 * t, y: 16) }),
            ("down to the tabs", { t in CGPoint(x: -150 + 500 * cos(0.2) * t, y: 500 * sin(0.2) * t) }),
            ("across a corner", { t in CGPoint(x: -140 + 500 * cos(0.6) * t, y: 500 * sin(0.6) * t) }),
        ]
        for (name, path) in paths {
            for tuning in [MotionTuning(), Self.quick, MotionTuning(motion: .refined, hover: .quick)] {
                for rate in [120.0, 60] {
                    let run = Self.hover(tuning, rate: rate, until: 1.5, path: path)
                    #expect(run.entered != nil, "\(name) never reached the pill")
                    #expect(run.opened == nil, "\(name), \(tuning.hover), \(Int(rate)) Hz: opened at \(run.opened ?? -1)")
                    #expect(!run.model.isOpen && !run.model.swollen, "\(name), \(tuning.hover), \(Int(rate)) Hz")
                }
            }
        }
    }
}
