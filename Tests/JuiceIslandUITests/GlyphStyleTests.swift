import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Settings › Island › Glyph style and Pill edge line: the settings, the mood each pixel glyph stands for, the square
/// every style draws in, the closed pill's glyph and wings per style, and when its edge line runs.
@MainActor
struct GlyphStyleTests {
    // MARK: Settings

    @Test func glyphStyleIsPixelAndTheEdgeLineOnByDefault() {
        let settings = AppSettings.ephemeral()
        #expect(settings.glyphStyle == .pixel)
        #expect(settings.glyphEdgeLine)
        #expect(GlyphStyle.allCases == [.pixel, .liquid, .sand])
    }

    @Test func glyphStyleAndEdgeLinePersistUnderTheirKeys() throws {
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.glyphStyle = .sand
        settings.glyphEdgeLine = false
        #expect(defaults.string(forKey: "ji.island.glyphStyle") == "sand")
        #expect(defaults.object(forKey: "ji.island.glyphEdgeLine") as? Bool == false)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.glyphStyle == .sand && !reloaded.glyphEdgeLine)
        reloaded.glyphStyle = .liquid
        #expect(AppSettings(defaults: defaults).glyphStyle == .liquid)
    }

    @Test func anUnknownStoredStyleFallsBackToPixel() throws {
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dune", forKey: AppSettings.Key.glyphStyle)
        #expect(AppSettings(defaults: defaults).glyphStyle == .pixel)
    }

    @Test func thePillEdgeLineRowShowsOnlyForLiquidAndSand() {
        #expect(!IslandPaneText.showsEdgeLineRow(.pixel))
        #expect(IslandPaneText.showsEdgeLineRow(.liquid))
        #expect(IslandPaneText.showsEdgeLineRow(.sand))
    }

    // MARK: Moods

    @Test func eachPixelGlyphSaysItsMood() {
        #expect(GlyphMood(.eq) == .running)
        #expect(GlyphMood(.bang) == .approval)
        #expect(GlyphMood(.ques) == .question)
        #expect(GlyphMood(.check) == .done)
        #expect(GlyphMood(.brand) == .idle)
        for glyph in PixelGlyph.allCases { #expect(GlyphMood(glyph).needsYou == glyph.needsYou) }
        #expect(Set(PixelGlyph.allCases.map(GlyphMood.init)) == Set(GlyphMood.allCases))
    }

    // MARK: The glyph's square

    @Test func pixelKeepsItsSevenPixelsAndTheEnginesTheirSide() {
        #expect(StateGlyphView.side(style: .pixel, pixel: 3, engineSide: nil) == 21)
        #expect(StateGlyphView.side(style: .pixel, pixel: 2, engineSide: 20) == 14)
        for style in [GlyphStyle.liquid, .sand] {
            #expect(StateGlyphView.side(style: style, pixel: 3, engineSide: nil) == 21)
            #expect(StateGlyphView.side(style: style, pixel: 2, engineSide: 20) == 20)
        }
    }

    @Test(arguments: GlyphStyle.allCases)
    func theGlyphsFrameIsItsSquare(_ style: GlyphStyle) {
        func size(_ view: StateGlyphView) -> CGSize {
            NSHostingView(rootView: view.environment(AppEnvironment.demo())).fittingSize
        }
        // A row's 21 pt glyph is 21 pt in every style, so rows never move when the style changes.
        let row = size(StateGlyphView(glyph: .eq, colour: IslandTheme.run, pixel: 3, animated: false, style: style))
        #expect(row == CGSize(width: 21, height: 21))
        let lead = size(StateGlyphView(glyph: .bang, colour: NeedsYouColour.pink.wait, pixel: ClosedPillView.leadPixel, animated: false,
                                       style: style, engineSide: ClosedPillView.engineGlyphSize))
        // Pixel's 17.5 pt lead: a hosting view's fitting size rounds up to whole points.
        let side = style == .pixel ? 18 : ClosedPillView.engineGlyphSize
        #expect(lead == CGSize(width: side, height: side))
    }

    @Test func withoutAStyleTheGlyphFollowsSettings() {
        let settings = AppSettings.ephemeral()
        settings.glyphStyle = .liquid
        let view = StateGlyphView(glyph: .check, pixel: 2, animated: false, engineSide: 20)
        #expect(NSHostingView(rootView: view.environment(AppEnvironment.demo(settings: settings))).fittingSize == CGSize(width: 20, height: 20))
        settings.glyphStyle = .pixel
        #expect(NSHostingView(rootView: view.environment(AppEnvironment.demo(settings: settings))).fittingSize == CGSize(width: 14, height: 14))
    }

    @Test func rowsKeepTheirSizeInEveryStyle() {
        func size<V: View>(_ view: V, _ style: GlyphStyle) -> CGSize {
            let settings = AppSettings.ephemeral()
            settings.glyphStyle = style
            let root = view.frame(width: 420).environment(AppEnvironment.demo(settings: settings)).environment(\.sessionGlyphsAnimated, false)
            return NSHostingView(rootView: root).fittingSize
        }
        let row = DStub.row("a", .claude, .needsYou, glyph: .bang)
        for style in [GlyphStyle.liquid, .sand] {
            // Liquid and Sand draw past Pixel's square (20 pt in the island's rows, 24 in the window's), laid out as it.
            #expect(size(CleanSessionRow(row: row, animated: false), style) == size(CleanSessionRow(row: row, animated: false), .pixel))
            #expect(size(CleanSessionRow(row: row, oneLine: true, animated: false), style)
                == size(CleanSessionRow(row: row, oneLine: true, animated: false), .pixel))
            #expect(size(DetailedSessionRow(row: row, animated: false), style) == size(DetailedSessionRow(row: row, animated: false), .pixel))
            #expect(size(DetailedRowView(row: row), style) == size(DetailedRowView(row: row), .pixel))
            #expect(size(DetailedRowView(row: row, showsStatus: false), style) == size(DetailedRowView(row: row, showsStatus: false), .pixel))
            #expect(size(CleanRowView(row: row, oneLine: true), style) == size(CleanRowView(row: row, oneLine: true), .pixel))
        }
        #expect(IslandTheme.Metrics.rowGlyphEngine == 20)
    }

    // MARK: The closed pill

    private static let reference = IslandTheme.Metrics.referenceNotch
    private static let running = PillLead(glyph: .eq, agent: .claude, state: .running)

    private static func pill(_ style: GlyphStyle, edgeLine: Bool = true, count: Int? = 3, notch: CGSize? = reference,
                             menuBar: CGFloat? = 33, displayScale: CGFloat = 2) -> PillContent {
        PillContent.make(lead: running, count: count, glance: false, style: style, edgeLine: edgeLine, notch: notch, menuBar: menuBar,
                         displayScale: displayScale)
    }

    @Test func pixelsLeadIsTwoAndAHalfPointPixelsWhereverItFits() {
        #expect(ClosedPillView.leadPixel == 2.5 && ClosedPillView.glyphSize == 17.5)
        // 17.5 pt with 2.5 pt above and below needs 22.5 pt of room: every notch's body has it.
        #expect(ClosedPillView.leadPixel(room: 33, displayScale: 2) == 2.5 && ClosedPillView.leadPixel(room: 22.5, displayScale: 2) == 2.5)
        #expect(ClosedPillView.leadPixel(room: 22, displayScale: 2) == 2)
        // A top bar on a 1× display: 3 pt pixels (21 pt) when they fit, else 2 pt (14), whole points either way.
        #expect(ClosedPillView.leadPixel(room: 28, displayScale: 1) == 3 && ClosedPillView.leadPixel(room: 24, displayScale: 1) == 2)
        // In the owner's 33 pt pill: 17.5 pt in a 27.5 pt wing (5 pt each side), and never an edge line.
        let pill = Self.pill(.pixel)
        #expect(pill.glyphSide == 17.5 && pill.leftWing == 27.5 && !pill.showsEdgeLine && pill.room == 33)
    }

    @Test(arguments: [GlyphStyle.liquid, .sand])
    func liquidAndSandDrawTheLargestLeadTheBodyHolds(_ style: GlyphStyle) {
        // The owner's 33 pt pill with its line in the lowest 3 pt: 25 pt, 2.5 pt clear of the top and of the line.
        let lined = Self.pill(style)
        #expect(lined.bodyHeight == 33 && lined.edgeLine == 3 && lined.room == 30)
        #expect(lined.glyphSide == 25 && lined.leftWing == 35)
        // Without the line: 28 pt, the most it draws, in a 38 pt wing.
        let plain = Self.pill(style, edgeLine: false)
        #expect(plain.glyphSide == 28 && plain.leftWing == 38 && plain.room == 33)
        #expect(ClosedPillView.glyphSide(style, room: 60) == ClosedPillView.engineGlyphSize && ClosedPillView.engineGlyphSize == 28)
        // A 24 pt top bar: 16 pt over its line, 19 without.
        #expect(Self.pill(style, notch: nil, menuBar: 24).glyphSide == 16 && Self.pill(style, edgeLine: false, notch: nil, menuBar: 24).glyphSide == 19)
    }

    @Test func theLeadSitsCentredOnTheHalfPointGrid() {
        // Pixel in a 27.5 pt wing of a 33 pt body: centred at 5, 7.5, on the display's pixel grid.
        #expect(ClosedPillView.leadOrigin(side: 17.5, width: 27.5, room: 33) == CGPoint(x: 5, y: 7.5))
        #expect(ClosedPillView.leadOrigin(side: 17.5, width: 30, room: 33) == CGPoint(x: 6, y: 7.5))
        #expect(ClosedPillView.leadOrigin(side: 17.5, width: 17.5, room: 28) == CGPoint(x: 0, y: 5))
        // Liquid and Sand: 25 pt above the line of the 33 pt body, 28 pt without it; 5 pt each side either way.
        #expect(ClosedPillView.leadOrigin(side: 25, width: 35, room: 30) == CGPoint(x: 5, y: 2.5))
        #expect(ClosedPillView.leadOrigin(side: 28, width: 38, room: 33) == CGPoint(x: 5, y: 2.5))
        for room in stride(from: 24.0, through: 40, by: 0.5) {
            let origin = ClosedPillView.leadOrigin(side: 17.5, width: 30, room: room)
            #expect((origin.y * 2).rounded() == origin.y * 2 && abs(origin.y + 8.75 - room / 2) <= 0.25)
        }
        // A top bar on a 1× display: 3 pt pixels (21 pt) on whole points where they fit, where 2.5 pt ones would split
        // every other column; at 2× it keeps 2.5.
        #expect(ClosedPillView.leadPixel(room: 28, displayScale: 1) == 3 && ClosedPillView.leadPixel(room: 28, displayScale: 2) == 2.5)
        #expect(ClosedPillView.leadOrigin(side: 21, width: 21, room: 28, displayScale: 1) == CGPoint(x: 0, y: 3))
        for room in stride(from: 24.0, through: 40, by: 0.5) {
            let origin = ClosedPillView.leadOrigin(side: 21, width: 33, room: room, displayScale: 1)
            let centred = (room - 21) / 2
            #expect(origin.x == 6 && origin.y.rounded() == origin.y && origin.y <= centred && origin.y > centred - 1)
        }
    }

    @Test(arguments: 0..<4)
    func theEngineGlyphFitsEveryNotchAboveTheLine(_ index: Int) {
        let notch = DIslandGeometryTests.laptops[index].notch
        #expect(IslandTheme.Metrics.pillEdgeLine == 3)
        // The line lives inside the body, which stays the notch + 1 (never below a 33 pt menu bar).
        for style in [GlyphStyle.liquid, .sand] {
            let pill = Self.pill(style, notch: notch, menuBar: notch.height + 1)
            #expect(pill.bodyHeight == notch.height + 1 && pill.room == notch.height - 2)
            // The glyph centres above the line, 2.5 pt clear of the top and of the line.
            let origin = ClosedPillView.leadOrigin(side: pill.glyphSide, width: pill.leftWing, room: pill.room)
            #expect(origin.y >= 2.5 && origin.y + pill.glyphSide <= pill.room - 2.5 + 0.25, "\(style) on \(notch)")
        }
    }

    /// The line follows the style, the setting and whether the pill shows anything, never whether a session runs, so
    /// the line draining leaves the pill as it was.
    @Test func theLineFollowsStyleSettingAndContent() {
        for style in GlyphStyle.allCases {
            for edgeLine in [false, true] {
                for count in [nil, 3] as [Int?] {
                    let pill = PillContent.make(lead: count == nil ? nil : Self.running, count: count, glance: false, style: style,
                                                edgeLine: edgeLine, notch: Self.reference, menuBar: 33)
                    #expect(pill.edgeLine == (style != .pixel && edgeLine && count != nil ? 3 : 0))
                    // It never changes the body's height.
                    #expect(pill.isEmpty || pill.bodyHeight == 33)
                }
            }
        }
    }

    @Test(arguments: GlyphStyle.allCases)
    func thePillIsItsContentsExtentAndNoTaller(_ style: GlyphStyle) {
        func size(_ rows: [SessionRow], edgeLine: Bool = true, notch: CGSize? = Self.reference) -> CGSize {
            let settings = AppSettings.ephemeral()
            settings.glyphStyle = style
            settings.glyphEdgeLine = edgeLine
            let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: rows))
            return NSHostingView(rootView: ClosedPillView(notch: notch, animated: false).environment(env)).fittingSize
        }
        let notch = Self.reference, ear = IslandTheme.Metrics.pillEar
        let lead: CGFloat = style == .pixel ? 27.5 : 35, count = ClosedPillView.countWidth(1) + 10
        let running = [DStub.row("r", .claude, .running)], done = [DStub.row("d", .codex, .done)]
        // The lead's wing, the notch, the count's wing and two ears; 33 pt, the notch + 1, with the line or without.
        #expect(size(running) == CGSize(width: (lead + notch.width + count + 2 * ear).rounded(.up), height: 33))
        // The line drained: nothing moves as sessions stop.
        #expect(size(done) == size(running))
        #expect(size(running, edgeLine: false).height == 33)
        // Idle: the notch itself.
        #expect(size([]) == notch)
        // The top bar: its menu bar's height, 24 when it cannot be measured.
        #expect(size(running, notch: nil).height == IslandTheme.Metrics.topBarFallbackHeight)
    }

    @Test func theCountIsSmallAndLight() {
        #expect(IslandTheme.TypeScale.pillCountSize == 12)
        #expect(IslandTheme.TypeScale.pillCountWeight == .medium && IslandTheme.TypeScale.pillCount == Fonts.num(12, .medium))
        // The wing measures the count in the weight it draws in.
        #expect(NSFont.Weight(IslandTheme.TypeScale.pillCountWeight) == .medium)
        #expect(NSFont.Weight(Font.Weight.semibold) == .semibold && NSFont.Weight(Font.Weight.regular) == .regular)
        // "10" in a wing only 5 pt wider each side.
        #expect(ClosedPillView.countWidth(10) + 2 * IslandTheme.Metrics.pillCountPadding <= 26)
    }

    @Test func onlyPixelsLeadCrossfadesToANewLead() {
        let running = PillLead(glyph: .eq, agent: .claude, state: .running)
        let approval = PillLead(glyph: .bang, agent: .codex, state: .waiting)
        #expect(ClosedPillView.leadIdentity(running, style: .pixel) != ClosedPillView.leadIdentity(approval, style: .pixel))
        #expect(ClosedPillView.leadIdentity(running, style: .pixel) == AnyHashable(running))
        for style in [GlyphStyle.liquid, .sand] {
            #expect(ClosedPillView.leadIdentity(running, style: style) == ClosedPillView.leadIdentity(approval, style: style))
        }
    }

    // MARK: The edge line

    @Test func theEdgeLineShowsForLiquidAndSandWhenThePillShowsSomething() {
        for style in GlyphStyle.allCases {
            for edgeLine in [false, true] {
                for showsSomething in [false, true] {
                    #expect(ClosedPillView.showsEdgeLine(style: style, edgeLine: edgeLine, showsSomething: showsSomething)
                        == (style != .pixel && edgeLine && showsSomething))
                }
            }
        }
    }

    @Test func theEdgeLineRunsWhileAnySessionRuns() {
        let running = DStub.row("r", .codex, .running), done = DStub.row("d", .claude, .done)
        let waiting = DStub.row("a", .claude, .needsYou, glyph: .bang)
        #expect(!ClosedPillView.edgeLineRuns(rows: []))
        #expect(!ClosedPillView.edgeLineRuns(rows: [done, waiting]))
        #expect(ClosedPillView.edgeLineRuns(rows: [running]))
        #expect(ClosedPillView.edgeLineRuns(rows: [waiting, done, running]))
    }

    /// The pill keeps the state's colours whatever Glyph colour says (P206): its line is the running blue, and so is its
    /// running lead, while a Codex or a Claude session runs.
    @Test func theEdgeLineIsTheRunningColour() {
        #expect(ClosedPillView.edgeLineColour == IslandTheme.run)
        let settings = AppSettings.ephemeral()
        settings.glyphColour = .byAgent
        settings.glyphStyle = .liquid
        settings.glyphEdgeLine = true
        for agent in [GlyphPalette.Agent.codex, .claude] {
            let pill = PillContent.make(rows: [DStub.row("r", agent, .running)], settings: settings, glance: false, recentlyFinished: nil,
                                        now: DemoClock.now, notch: IslandTheme.Metrics.referenceNotch, menuBar: 33)
            #expect(pill.edgeColour == IslandTheme.run)
            #expect(pill.lead?.state == .running)
        }
    }

    @Test func theEdgeLineReachesIntoTheCornersAndShowsInBothWings() {
        // The 12.5 pt corner crosses the middle of the 3 pt band 6.56 pt in: the line starts 7 pt in, on the grid.
        #expect(ClosedPillView.edgeLineInset(radius: 12.5, band: 3) == 7)
        #expect(ClosedPillView.edgeLineInset(radius: 12.5, band: 0) == 0)
        let pill = Self.pill(.liquid)
        #expect(ClosedPillView.edgeLineWidth(bodyWidth: pill.bodyWidth, radius: 12.5, band: 3) == pill.bodyWidth - 14)
        // What shows of it: the lead's wing on the left, the count's on the right, less the inset each.
        let ends = ClosedPillView.edgeLineEnds(pill)
        #expect(ends == RimEnds(left: pill.leftWing - 7, right: pill.rightWing - 7) && ends.right > 8)
        // The top bar shows all of it.
        let bar = Self.pill(.sand, notch: nil, menuBar: 24)
        let width = ClosedPillView.edgeLineWidth(bodyWidth: bar.barWidth, radius: 12, band: 3)
        #expect(ClosedPillView.edgeLineEnds(bar) == RimEnds(left: width, right: width))
    }

    @Test func pixelDrawsNoRim() {
        let rim = PillRimView(style: .pixel, running: true, colour: IslandTheme.run, width: 200, animated: false)
        #expect(NSHostingView(rootView: rim).fittingSize == .zero)
        for style in [GlyphStyle.liquid, .sand] {
            let size = NSHostingView(rootView: PillRimView(style: style, running: true, colour: IslandTheme.run, width: 200, animated: false)).fittingSize
            #expect(size == CGSize(width: 200, height: IslandTheme.Metrics.pillEdgeLine))
            let taller = PillRimView(style: style, running: true, colour: IslandTheme.run, width: 200, height: 7, animated: false)
            #expect(NSHostingView(rootView: taller).fittingSize == CGSize(width: 200, height: 7))
        }
    }
}
