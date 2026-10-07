import AppKit
import Foundation
import IslandEngine
import OpenIslandCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The island and window polish of 2026-09-25: small text that reads on pure black, counts that say only what runs, a
/// host said once, battery digits never cut at the fill edge, and a card that fades out as another session's takes its
/// place (P133).
@MainActor
struct PolishTests {
    typealias Model = IslandChoreography

    // MARK: Contrast

    /// WCAG's contrast of `colour` on pure black, resolved in the dark look whatever this Mac's (the window's colours are
    /// twins since the Appearance, P762; black is the dark look's).
    static func contrastOnBlack(_ colour: Color) -> Double {
        var resolved: NSColor?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { resolved = NSColor(colour).usingColorSpace(.sRGB) }
        let rgb = resolved!
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return (luminance + 0.05) / 0.05
    }

    /// Every small grey text on the island's and the window's pure black reads at 4.5:1 or more, and a count stays
    /// quieter than its label.
    @Test func smallGreyTextReadsOnPureBlack() {
        let texts: [(String, Color)] = [
            ("ink3", IslandTheme.ink3), ("rowAge", IslandTheme.rowAge), ("toolLine", IslandTheme.toolLine),
            ("footer", IslandTheme.footer), ("tagTime", IslandTheme.tagTime.fg), ("codexLabel", IslandTheme.agentCodex),
            ("groupCount", IslandTheme.groupCount), ("sectionHeader", WindowTheme.sectionHeader),
            ("sectionCount", WindowTheme.sectionCount), ("accountName", WindowTheme.accountName), ("reason", CardTheme.reason), ("diffGap", CardTheme.diffGap),
        ]
        for (name, colour) in texts {
            #expect(Self.contrastOnBlack(colour) >= 4.5, "\(name): \(Self.contrastOnBlack(colour))")
        }
        #expect(Self.contrastOnBlack(IslandTheme.agentCodex) > Self.contrastOnBlack(IslandTheme.groupCount))
        #expect(Self.contrastOnBlack(WindowTheme.sectionHeader) > Self.contrastOnBlack(WindowTheme.sectionCount))
        #expect(Self.contrastOnBlack(IslandTheme.footerHover) > Self.contrastOnBlack(IslandTheme.footer))
        #expect(Self.contrastOnBlack(IslandTheme.statusClean) > Self.contrastOnBlack(IslandTheme.rowAge))
    }

    // MARK: Counts

    /// A Codex session idle at the prompt is never counted as running: "Running N" counts what runs, and with only
    /// idle Codex sessions the card still shows them (titled by the group).
    @Test func anIdleCodexSessionIsNeverCountedAsRunning() throws {
        let rows = FixtureSessionFeed(scenario: .prototype).makeModel().rows
        let columns = SessionListLayout.columns(rows)
        #expect(columns.runningCount == columns.running.count + 1)
        let idleOnly = SessionListLayout.columns(rows.filter { $0.id == FixtureSessionFeed.ID.codexIdle })
        #expect(idleOnly.runningCount == 0 && idleOnly.showsRunningCard && idleOnly.codexGroup.count == 1)
        #expect(!SessionListLayout.columns([]).showsRunningCard)
    }

    // MARK: Host tags

    /// The host most rows share is said by leaving it off; a row elsewhere keeps its tag, and "Codex.app" always shows.
    @Test func aHostTheRowsShareIsSaidOnce() throws {
        let base = try #require(FixtureSessionFeed(scenario: .prototype).makeModel().rows.first)
        func row(_ id: String, _ host: String?) -> SessionRow {
            var row = base
            row.id = id
            row.host = host
            return row
        }
        #expect(DetailedRowText.sharedHost([row("a", "Terminal"), row("b", "Terminal"), row("c", "Terminal")]) == "Terminal")
        #expect(DetailedRowText.sharedHost([row("a", "Terminal"), row("b", "Ghostty"), row("c", "Terminal")]) == "Terminal")
        // One row says its host itself; so do rows that each run somewhere else.
        #expect(DetailedRowText.sharedHost([row("a", "Terminal")]) == nil)
        #expect(DetailedRowText.sharedHost([row("a", "Terminal"), row("b", "Ghostty")]) == nil)
        // A tie goes to the host met first.
        #expect(DetailedRowText.sharedHost([row("a", "iTerm"), row("b", "Ghostty"), row("c", "Ghostty"), row("d", "iTerm")]) == "iTerm")
        #expect(DetailedRowText.sharedHost([row("a", "Codex.app"), row("b", "Codex.app"), row("c", nil)]) == nil)
    }

    // MARK: Battery digits

    /// Each digit of a battery's percent is one colour, picked by the side that holds its middle, and only a digit the
    /// fill edge runs through gets a halo: never more than one, and never at 0 or 100.
    @Test func batteryDigitsAreNeverCutAtTheFillEdge() {
        for percent in 1...100 {
            let text = "\(percent)"
            let edge = Theme.Battery.inset + UsageBatteryView.fillWidth(percent)
            let spans = BatteryDigits.spans(count: text.count)
            let sides = spans.map { BatteryDigits.side($0, edge: edge) }
            #expect(sides.count { $0.cut } <= 1, "\(percent)")
            for (span, side) in zip(spans, sides) {
                #expect(side.onFill == ((span.lowerBound + span.upperBound) / 2 < edge), "\(percent)")
            }
            // The digits sit in the body, centred.
            #expect(abs((spans.first!.lowerBound + spans.last!.upperBound) / 2 - Theme.Battery.width / 2) < 0.01)
        }
        #expect(BatteryDigits.spans(count: 3).map { BatteryDigits.side($0, edge: Theme.Battery.inset + UsageBatteryView.fillWidth(100)) }
            .allSatisfy { $0.onFill && !$0.cut })
    }

    // MARK: Card swap

    /// `card` with its session id set to `id`.
    static func card(_ id: String) -> SessionCard {
        let demo = AppEnvironment.demo(sessions: .prototype).sessions.card(for: FixtureSessionFeed.ID.approval)!
        guard case var .approval(model) = demo else { return demo }
        model.sessionID = id
        return .approval(model)
    }

    /// Another session's card takes the place of the one showing: the old card moves to the leaving layer at the focus
    /// it had and fades out there as the new header comes in, the two never both past half and both past a quarter for
    /// at most 40 ms, and at rest the leaving layer and its channels are gone, in the model and the views.
    @Test func aSwappedCardFadesOutAsTheNewOneComesIn() {
        for reduce in [false, true] {
            let layout = DIslandCrossTests.layout(card: "r1")
            let start = Model(metrics: .init(targets: SurfaceTargets(notch: DIslandCrossTests.notch, pill: DIslandPanelSizingTests.pill()),
                                             layout: layout, reduceMotion: reduce),
                              surface: .island, presentation: .card(sessionID: "r1"))
            let scenario = DIslandPanelSizingTests.Scenario(name: "swap", start: start,
                                                            events: [(0.1, .present(.card(sessionID: "r0"))),
                                                                     (0.116, .content(DIslandCrossTests.layout(card: "r0")))])
            let ui = IslandUIState()
            IslandMotionDirector.snap(ui, to: start, at: 0)
            ui.card = Self.card("r1")
            var leftWith: Double?, both = 0, half = 0, leavingSeen = false, rising = false
            var last = start
            var previous = 1.0
            DIslandPanelSizingTests.play(scenario, until: 1) { model, t, commands in
                for command in commands {
                    IslandMotionDirector.write(command, to: ui)
                    if case let .effect(.cardSnapshot(id)) = command { ui.card = id.map(Self.card) }
                }
                last = model
                guard t >= 0.1 else { return }
                let leaving = model.value(.part(.leavingHeader), at: t), header = model.value(.part(.cardHeader), at: t)
                if leftWith == nil { leftWith = leaving }
                if ui.leavingCard?.sessionID == "r1" && ui.card?.sessionID == "r0" { leavingSeen = true }
                if leaving > previous + 1e-9 { rising = true }
                previous = leaving
                if min(leaving, header) > 0.25 { both += 1 }
                if min(leaving, header) > 0.5 { half += 1 }
            }
            let tag = reduce ? "reduced" : "motion"
            #expect((leftWith ?? 0) > 0.99, "\(tag): the old card left from \(leftWith ?? -1), not from where it was")
            #expect(leavingSeen, "\(tag): the views never held the old card in the leaving layer")
            #expect(!rising, "\(tag): the leaving card came back up")
            #expect(half == 0 && both <= 40, "\(tag): both past a quarter \(both) ms, past half \(half) ms")
            #expect(last.cardLeaving == nil && ui.leavingCard == nil, "\(tag): the leaving layer stayed")
            #expect(ui.channels.part(.leavingHeader) == 0 && ui.channels.part(.leavingBody) == 0 && ui.channels.part(.cardHeader) == 1)
        }
    }

    /// A close, a display change or a fresh model mid-swap takes the leaving layer with it.
    @Test func aCloseOrADisplayChangeTakesTheLeavingCard() {
        for event in [Model.Event.close(.fold), .display(Model(metrics: .init(targets: SurfaceTargets(notch: DIslandCrossTests.notch,
                                                                                                        pill: DIslandPanelSizingTests.pill())),
                                                                 surface: .island).metrics)] {
            let start = Model(metrics: .init(targets: SurfaceTargets(notch: DIslandCrossTests.notch, pill: DIslandPanelSizingTests.pill()),
                                             layout: DIslandCrossTests.layout(card: "r1")),
                              surface: .island, presentation: .card(sessionID: "r1"))
            let scenario = DIslandPanelSizingTests.Scenario(name: "cut", start: start,
                                                            events: [(0, .present(.card(sessionID: "r0"))), (0.05, event)])
            let ui = IslandUIState()
            IslandMotionDirector.snap(ui, to: start, at: 0)
            ui.card = Self.card("r1")
            var last = start
            DIslandPanelSizingTests.play(scenario, until: 2) { model, _, commands in
                for command in commands {
                    IslandMotionDirector.write(command, to: ui)
                    if case let .effect(.cardSnapshot(id)) = command { ui.card = id.map(Self.card) }
                }
                last = model
            }
            #expect(last.cardLeaving == nil && ui.leavingCard == nil && ui.channels.part(.leavingHeader) == 0, "\(event)")
        }
    }
}

/// Show all never makes the island taller than its display (P133): past the display's height the list scrolls inside
/// it, every row it builds still measured and in focus (the rows' views move into the scroll view in one update, and the
/// old views' going takes no part away), and the island's height is exactly the capped list's. Past what the tallest
/// list can show, a row is built as the list scrolls to it, and is measured and in focus then (P400).
@MainActor
@Suite(.serialized)
struct ShowAllScrollTests {
    typealias Rig = FramePerf.IslandRig

    static func sessions(_ count: Int) -> [AgentEvent] {
        let now = Date()
        return (0..<count).flatMap { FramePerf.newSession("all-\($0)", title: "Task number \($0)", at: now - Double(60 * $0)) }
    }

    /// Waits until `settled`, laying `rig`'s island out and committing it before each look as a display would
    /// (`FramePerf.settle`): other suites share the main actor, so a set wait can end before the motion does, the rig's
    /// window is never on screen to be drawn, and `limit` counts looks, not seconds, which a full run spent with a
    /// handful of looks taken (P1258).
    @discardableResult
    static func until(_ rig: Rig, limit: TimeInterval = 30, _ settled: () -> Bool) async -> Bool {
        await FramePerf.settle(rig, limit: limit, settled)
    }

    /// The island open and at rest: the surface drawn at the height the model has.
    static func openAtRest(_ rig: Rig) -> Bool {
        let model = rig.director.model
        return model.surface == .island && model.islandHeight > 100 && abs(Double(rig.ui.surface.height) - Double(model.islandHeight)) < 0.5
    }

    @Test func showAllScrollsInsideTheDisplay() async throws {
        _ = NSApplication.shared
        for style in [IslandStyle.clean, .detailed] {
            let rig = Rig(style: style, scenario: .empty, events: Self.sessions(30), glyphsMove: false)
            await rig.start()
            rig.open()
            await Self.until(rig) { Self.openAtRest(rig) }
            withAnimation(IslandMotion.glide.animation) { rig.ui.showAll = true }
            let rows = SessionListLayout.displayOrder(rig.env.sessions.rows, now: rig.env.sessions.now).map(\.id)
            // The rows the list builds at once: every one but those it builds as it scrolls to them (P400).
            func built() -> [String] { rows.filter { !rig.director.model.layout.lazyRows.contains($0) } }
            func ready(_ id: String) -> Bool { rig.director.model.layout.parts[.row(id)] != nil && rig.ui.channels.part(.row(id)) == 1 }
            await Self.until(rig) {
                Self.openAtRest(rig) && rig.director.model.islandHeight > Rig.maxHeight - 60 && built().allSatisfy(ready)
            }
            let model = rig.director.model
            #expect(rows.count == 30)
            #expect(model.islandHeight <= Rig.maxHeight + 0.5, "\(style): \(model.islandHeight) > \(Rig.maxHeight)")
            #expect(model.islandHeight > Rig.maxHeight - 60, "\(style): the list stopped short at \(model.islandHeight)")
            #expect(abs(Double(rig.ui.surface.height) - Double(model.islandHeight)) < 0.5)
            let eager = built()
            #expect(eager.count >= IslandTheme.Metrics.visibleRows && Set(eager) == Set(rows.prefix(eager.count)), "\(style): built \(eager.count)")
            let missing = eager.filter { model.layout.parts[.row($0)] == nil }
            #expect(missing.isEmpty, "\(style): rows never measured \(missing.prefix(3))")
            let dim = eager.filter { rig.ui.channels.part(.row($0)) != 1 }
            #expect(dim.isEmpty, "\(style): rows out of focus \(dim.prefix(3))")
            // The last row, scrolled to by the keys: built, measured and in focus, the island's height the cap's still.
            let last = try #require(rows.last)
            rig.ui.selectedRow = last
            await Self.until(rig) { ready(last) && Self.openAtRest(rig) }
            #expect(ready(last), "\(style): the last row, scrolled to")
            #expect(rig.director.model.islandHeight <= Rig.maxHeight + 0.5 && abs(rig.director.model.islandHeight - model.islandHeight) < 0.5)
            // Folded back: the list leaves the scroll view, and every row it shows is measured and in focus again.
            rig.director.send(.close(.fold))
            await Self.until(rig) { rig.director.model.surface == .closed && !rig.ui.showAll && !rig.director.model.inMotion }
            rig.open()
            let shown = IslandListLayout.make(rows: rig.env.sessions.rows, style: style, showAll: false, now: rig.env.sessions.now).shown
            func inFocus() -> Bool {
                shown.allSatisfy { rig.director.model.layout.parts[.row($0.id)] != nil && rig.ui.channels.part(.row($0.id)) == 1 }
            }
            await Self.until(rig) { Self.openAtRest(rig) && rig.director.model.islandHeight < 500 && inFocus() }
            #expect(inFocus(), "\(style): after the fold")
            #expect(rig.director.model.islandHeight < 500)
            rig.stop()
        }
    }
}

/// Header strip placement keeps the usage block built while it is folded (P133): folded it is no part of the list
/// (not measured, out of focus, no height); unfolded it is measured and comes into focus, and folded again it goes.
@MainActor
@Suite(.serialized)
struct FoldedUsageTests {
    @Test func theFoldedBlockStaysBuiltAndUnfoldsIntoFocus() async throws {
        _ = NSApplication.shared
        typealias Waits = ShowAllScrollTests
        for style in [IslandStyle.clean, .detailed] {
            let rig = FramePerf.IslandRig(style: style, placement: .headerStrip, glyphsMove: false)
            await rig.start()
            rig.open()
            await Waits.until(rig) { Waits.openAtRest(rig) }
            let folded = rig.director.model
            #expect(folded.layout.parts[.usage] == nil && rig.ui.channels.part(.usage) == 0, "\(style): folded")
            withAnimation(IslandMotion.glide.animation) { rig.ui.stripOpen = true }
            await Waits.until(rig) {
                Waits.openAtRest(rig) && rig.ui.channels.part(.usage) == 1 && rig.director.model.islandHeight > folded.islandHeight + 40
            }
            let open = rig.director.model
            let block = try #require(open.layout.parts[.usage], "\(style): the unfolded block was never measured")
            #expect(block.height > 40 && rig.ui.channels.part(.usage) == 1, "\(style): \(block), \(rig.ui.channels.part(.usage))")
            #expect(open.islandHeight > folded.islandHeight + 40, "\(style): the island did not grow by the block")
            withAnimation(IslandMotion.glide.animation) { rig.ui.stripOpen = false }
            await Waits.until(rig) {
                Waits.openAtRest(rig) && rig.ui.channels.part(.usage) == 0 && abs(rig.director.model.islandHeight - folded.islandHeight) < 0.5
            }
            #expect(rig.director.model.layout.parts[.usage] == nil && rig.ui.channels.part(.usage) == 0, "\(style): folded again")
            #expect(abs(rig.director.model.islandHeight - folded.islandHeight) < 0.5, "\(style): the fold kept height")
            rig.stop()
        }
    }
}
