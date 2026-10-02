import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Each SwiftUI transaction costs the island an update (P102): the director writes a batch in one plain transaction,
/// each channel's curve riding in its box (E5), split only where the panel snaps, the controller acts, the pill's
/// snapshot moves on a curve or a channel is written again on another curve; and the views end up exactly as the
/// commands written one by one would leave them, every channel on the curve its last command gave it. The frame costs
/// themselves: `JI_MEASURE_FRAMES=1 swift test -c release -Xswiftc -enable-testing --filter IslandFrameMeasurements`
/// (`IslandFramePerf.swift`).
@MainActor
struct IslandFluidityTests {
    typealias Model = IslandChoreography

    @Test func aBatchIsOnePlainTransactionSplitOnlyWhereItMustBe() {
        let unfold = IslandMotion.unfold, focusIn = IslandMotion.focusIn, focusOut = IslandMotion.focusOut
        let commands: [Model.Command] = [
            .effect(.islandLive(true)), .target(.zero, isOpen: true), .panel(.zero),
            .animate(unfold, [.left: 240, .right: 240]), .animate(focusOut, [.pill: 0]),
            .animate(focusIn, [.part(.row("r2")): 1]), .animate(focusIn, [.part(.row("r3")): 1]),
            .animate(focusIn, [.part(.footer): 1, .part(.row("r2")): 0.5]),
            .animate(nil, [.cardRide: 47]), .effect(.cardSnapshot("r0")), .animate(nil, [.glide("r0"): 0]),
            .pillSnapshot(.empty, nil), .pillSnapshot(.empty, IslandMotion.slide), .effect(.pillLive(true)),
            // The surface on another curve, and a part snapped then brought in: each starts a transaction of its own.
            .animate(unfold, [.height: 300]), .animate(IslandMotion.fold, [.height: 200, .ear: 3]),
            .animate(nil, [.part(.cardHeader): 0]), .animate(focusIn, [.part(.cardHeader): 1]),
            .effect(.orderOut),
            // F5: the width and the height on two springs at once share a transaction (two vectors, two curves).
            .animate(IslandMotion.splitWidth, [.left: 240, .right: 240, .ear: 3]),
            .animate(IslandMotion.splitHeight, [.height: 300, .radius: 20, .rimLift: 4]),
            .animate(IslandMotion.fold, [.ear: 0]),
        ]
        #expect(IslandMotionDirector.transactions(commands) == [
            .writes([.effect(.islandLive(true)), .target(.zero, isOpen: true)]),
            .other(.panel(.zero)),
            // Every value, whatever its curve, the card snapshot and the still pill snapshot: one update.
            .writes([.animate(unfold, [.left: 240, .right: 240]), .animate(focusOut, [.pill: 0]),
                     .animate(focusIn, [.part(.row("r2")): 1]), .animate(focusIn, [.part(.row("r3")): 1]),
                     .animate(focusIn, [.part(.footer): 1, .part(.row("r2")): 0.5]),
                     .animate(nil, [.cardRide: 47]), .effect(.cardSnapshot("r0")), .animate(nil, [.glide("r0"): 0]),
                     .pillSnapshot(.empty, nil)]),
            .pill(.empty, IslandMotion.slide),
            .writes([.effect(.pillLive(true)), .animate(unfold, [.height: 300])]),
            .writes([.animate(IslandMotion.fold, [.height: 200, .ear: 3]), .animate(nil, [.part(.cardHeader): 0])]),
            .writes([.animate(focusIn, [.part(.cardHeader): 1])]),
            .other(.effect(.orderOut)),
            .writes([.animate(IslandMotion.splitWidth, [.left: 240, .right: 240, .ear: 3]),
                     .animate(IslandMotion.splitHeight, [.height: 300, .radius: 20, .rimLift: 4])]),
            // The ear is the width's: on another curve, a transaction of its own.
            .writes([.animate(IslandMotion.fold, [.ear: 0])]),
        ])
    }

    /// Every replay the island's tests know, a millisecond at a time: the views written a transaction at a time hold
    /// what they would hold written a command at a time.
    @Test func theViewsHoldWhatEachCommandWouldLeave() {
        for scenario in DIslandCrossTests.everyScenario {
            let single = IslandUIState(), grouped = IslandUIState()
            IslandMotionDirector.snap(single, to: scenario.start, at: 0)
            IslandMotionDirector.snap(grouped, to: scenario.start, at: 0)
            var differing: [TimeInterval] = []
            DIslandPanelSizingTests.play(scenario, until: 3.5) { _, t, commands in
                for command in commands { IslandMotionDirector.write(command, to: single) }
                for write in IslandMotionDirector.transactions(commands) { IslandMotionDirector.write(write, to: grouped) }
                if !Self.same(single, grouped) { differing.append(t) }
            }
            #expect(differing.isEmpty, "\(scenario.name): \(differing.prefix(3))")
        }
    }

    /// Merging never moves a channel onto another curve: no transaction holds one channel (the surface's five count as
    /// two, its width and its height, `SurfaceBox`) on two curves, so the curve a box ends a transaction on is its last
    /// command's.
    @Test func aTransactionNeverHoldsAChannelOnTwoCurves() {
        for scenario in DIslandCrossTests.everyScenario {
            var mixed: [String] = []
            DIslandPanelSizingTests.play(scenario, until: 3.5) { _, t, commands in
                for case let .writes(writes) in IslandMotionDirector.transactions(commands) {
                    var curves: [Channel: Set<String>] = [:]
                    for case let .animate(curve, values) in writes {
                        for channel in values.keys { curves[Self.vector(channel), default: []].insert(Self.name(curve)) }
                    }
                    if curves.values.contains(where: { $0.count > 1 }) { mixed.append("\(Int(t * 1000)) ms") }
                }
            }
            #expect(mixed.isEmpty, "\(scenario.name): \(mixed.prefix(3))")
        }
    }

    /// The surface's box keeps a curve for each of its two vectors (F5, P246): a write that moves only the height leaves
    /// the width on its own curve, one that moves the ear (the width's) carries the width alone, and one that moves
    /// nothing changes no curve, as SwiftUI keeps an animation whose value did not change.
    @Test func theSurfacesBoxKeepsACurveForEachVector() {
        let store = IslandChannelStore(), box = store.surface
        let width = ChannelMotion.spring(IslandMotion.splitWidth), height = ChannelMotion.spring(IslandMotion.splitHeight)
        store.write([.left: 240, .right: 240, .ear: 3], width)
        #expect(box.widthMotion == width && box.heightMotion == .snap)
        store.write([.height: 300, .radius: 20, .rimLift: 4], height)
        #expect(box.widthMotion == width && box.heightMotion == height && box.value.height == 300)
        store.write([.left: 240, .height: 300], .spring(IslandMotion.fold))
        #expect(box.widthMotion == width && box.heightMotion == height)
        store.write([.ear: 0], .snap)
        #expect(box.widthMotion == .snap && box.heightMotion == height && box.value.ear == 0)
    }

    /// The surface's width (`.left`) or height (`.height`), each one vector with one curve; any other channel itself.
    static func vector(_ channel: Channel) -> Channel {
        Channel.surfaceWidth.contains(channel) ? .left : Channel.surfaceHeight.contains(channel) ? .height : channel
    }

    static func name(_ curve: IslandMotion.Curve?) -> String {
        curve.map { "\($0.response)/\($0.dampingFraction)" } ?? "snap"
    }

    static func same(_ a: IslandUIState, _ b: IslandUIState) -> Bool {
        a.surface == b.surface && a.channels == b.channels && a.target == b.target && a.isOpen == b.isOpen && a.pill == b.pill
            && a.islandLive == b.islandLive && a.pillLive == b.pillLive
    }
}
