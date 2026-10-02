import AppKit
import Foundation
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Many sessions (P400): Show all builds at once only the rows the tallest list could show, the rest lazily as the list
/// scrolls to them; a row built that way is there at once, never coming into focus as a new row does, and still leaves
/// with the others.
@MainActor
@Suite(.serialized)
struct ManySessionsTests {
    typealias Model = IslandChoreography

    /// Every row the list could show without scrolling, at the shortest a row can be, and one more; never fewer than the
    /// four the list always shows, never more than there are; every row with no cap (renders).
    @Test func showAllBuildsAtOnceOnlyWhatTheTallestListCanShow() {
        #expect(IslandListLayout.eagerCount(120, maximum: 900) == 26)
        #expect(IslandListLayout.eagerCount(3, maximum: 900) == 3)
        #expect(IslandListLayout.eagerCount(120, maximum: nil) == 120)
        #expect(IslandListLayout.eagerCount(120, maximum: 50) == IslandTheme.Metrics.visibleRows)
        // Whatever a row measures, the rows built at once are taller than the cap whenever one waits: the list's height
        // is the cap's, and no lazy row's estimate ever moves the island's edge.
        for maximum in stride(from: 160.0, through: 1400.0, by: 37.0) {
            let eager = IslandListLayout.eagerCount(500, maximum: maximum)
            #expect(CGFloat(eager) * 41 > maximum && CGFloat(eager) * IslandListLayout.shortestRow > maximum)
        }
    }

    /// The model: a row the list builds as it scrolls to it snaps into focus in the turn its measure comes; a new row
    /// (one the list did not build lazily) still waits for its reveal; neither comes in while a card shows.
    @Test func aRowBuiltAsTheListScrollsIsThereAtOnce() {
        var model = MotionRoundCTests.open(MotionRoundCTests.list(rows: 6, footer: false))
        var next = MotionRoundCTests.list(rows: 8, footer: false)
        next.lazyRows = ["r7"]
        let out = model.handle(.content(next), at: 1)
        #expect(out.contains(.animate(nil, [.part(.row("r7")): 1])))
        #expect(model.value(.part(.row("r7")), at: 1) == 1)
        #expect(!model.jobs.contains { $0.step == .reveal(.row("r7")) })
        #expect(model.value(.part(.row("r6")), at: 1) < 1 && model.jobs.contains { $0.step == .reveal(.row("r6")) })

        var card = MotionRoundCTests.open(MotionRoundCTests.list(rows: 6, footer: false))
        _ = card.handle(.present(.card(sessionID: "r0")), at: 1)
        let under = card.handle(.content(next), at: 1.01)
        #expect(!MotionRoundCTests.snaps(.row("r7"), under) && card.value(.part(.row("r7")), at: 1.01) == 0)
    }

    /// A row built lazily leaves with the others: a close takes every row out of focus.
    @Test func aLazyRowLeavesWithTheOthers() {
        var model = MotionRoundCTests.open(MotionRoundCTests.list(rows: 6, footer: false))
        var next = MotionRoundCTests.list(rows: 8, footer: false)
        next.lazyRows = ["r6", "r7"]
        _ = model.handle(.content(next), at: 1)
        let close = model.handle(.close(.fold), at: 2)
        let leaving = close.compactMap { command -> [Channel: Double]? in
            if case let .animate(_, values) = command { values } else { nil }
        }.reduce(into: [Channel: Double]()) { $0.merge($1) { _, new in new } }
        #expect(leaving[.part(.row("r7"))] == 0 && leaving[.part(.row("r6"))] == 0 && leaving[.part(.row("r0"))] == 0)
    }

    /// Live, over `count` sessions (the list in its scroll view, as the panel has it): Show all builds the rows the list can
    /// show and a few past them, not all of them; the list measures its cap; the keys' row scrolled far down is built as
    /// the list reaches it and is in focus in the turn its measure comes, with no reveal to wait for.
    @Test func showAllOverManySessionsBuildsWhatShowsAndScrollsTheRestIn() throws {
        let count = 120
        let island = Self.harness(count: count, maxHeight: 500)
        defer { island.close() }
        let rows: (ContentLayout) -> Set<String> = { layout in
            Set(layout.parts.keys.compactMap { if case let .row(id) = $0 { id } else { nil } })
        }
        island.director.send(.list(.showAll))
        island.settle(0.8)
        let layout = island.director.model.layout
        let order = SessionListLayout.displayOrder(island.env.sessions.rows, now: island.env.sessions.now).map(\.id)
        #expect(order.count == count && island.ui.showAll, "rows \(order.count), show all \(island.ui.showAll)")
        guard order.count == count else { return }
        let maximum = 500 - layout.header - IslandTheme.Metrics.bottomPadding
        let eager = IslandListLayout.eagerCount(count, maximum: maximum)
        let built = rows(layout)
        #expect(built.count >= eager && built.count < eager + 20, "built \(built.count) of \(count), eager \(eager)")
        #expect(Set(order.prefix(eager)).isSubset(of: built))
        #expect(abs(layout.list - maximum) < 1, "the list measures its cap: \(layout.list) against \(maximum)")
        #expect(layout.lazyRows == Set(order.dropFirst(eager)))

        let deep = order[80]
        #expect(!built.contains(deep))
        island.ui.selectedRow = deep
        var inFocusAtOnce: Bool?
        for _ in 0..<200 where inFocusAtOnce == nil {
            island.hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            island.director.flushMeasurements()
            // Read before any job fires: a row that came in by a reveal would still be out of focus here.
            if island.director.model.layout.parts[.row(deep)] != nil {
                inFocusAtOnce = island.ui.channels.part(.row(deep)) == 1
            }
            while island.clock.fire() {}
        }
        #expect(inFocusAtOnce == true)
        #expect(rows(island.director.model.layout).count < count / 2, "scrolling builds the rows it passes, not the list")
    }

    /// The live island over `count` sessions, a third running, the rest done (`FramePerf.manySessions`).
    static func harness(count: Int, maxHeight: CGFloat, settings: AppSettings = .ephemeral()) -> LiveIslandHarness {
        let feed = FixtureSessionFeed(scenario: .empty, now: Date())
        feed.engine.loadPreviewEvents(FramePerf.manySessions(count))
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: Date()),
                                 sessions: EngineSessionsModel(engine: feed.engine, clock: { Date() }))
        return LiveIslandHarness(env: env, presenting: nil, tuning: MotionRoundCTests.refined, maxHeight: maxHeight)
    }
}
