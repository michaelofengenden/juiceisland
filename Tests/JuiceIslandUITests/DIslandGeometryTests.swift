import AppKit
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Stream D: where the pill and island sit (P36, P37, P38). Screens are plain values; no real display is read.
@MainActor
struct DIslandGeometryTests {
    /// Notch sizes shaped like the 13-, 14-, 15- and 16-inch laptops at their default scaling. They are
    /// representative, not measured: the code reads the notch from each screen and never assumes any of them.
    static let laptops: [(name: String, screen: CGSize, notch: CGSize)] = [
        ("13-inch", CGSize(width: 1470, height: 956), CGSize(width: 176, height: 32)),
        ("14-inch", CGSize(width: 1512, height: 982), CGSize(width: 185, height: 32)),
        ("15-inch", CGSize(width: 1710, height: 1112), CGSize(width: 192, height: 33)),
        ("16-inch", CGSize(width: 1728, height: 1117), CGSize(width: 204, height: 34)),
    ]

    static func laptop(_ size: CGSize, notch: CGSize, origin: CGPoint = .zero, id: String = "built-in") -> IslandScreen {
        let side = (size.width - notch.width) / 2
        return IslandScreen(id: id, frame: CGRect(origin: origin, size: size), safeAreaTop: notch.height,
                            auxiliaryLeftWidth: side, auxiliaryRightWidth: side)
    }

    static func external(_ frame: CGRect, id: String = "external") -> IslandScreen {
        IslandScreen(id: id, frame: frame, safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil)
    }

    @Test(arguments: 0..<4)
    func pillWrapsEachNotchCentredAtTheTopEdge(_ index: Int) throws {
        let laptop = Self.laptops[index]
        let screen = Self.laptop(laptop.screen, notch: laptop.notch)
        let notch = try #require(NotchGeometry.notchRect(on: screen))
        #expect(notch.size == laptop.notch)
        #expect(notch.midX == laptop.screen.width / 2 && notch.maxY == laptop.screen.height)

        // The pill hangs from the top edge by its own reach either side of the notch's middle: the lead's wing on the
        // left, the count's on the right, 3 pt ears; one point taller than the notch.
        let content = PillContent.make(lead: PillLead(glyph: .eq, agent: .claude, state: .running), count: 3, glance: false,
                                       style: .liquid, edgeLine: true, notch: laptop.notch, menuBar: laptop.notch.height + 1)
        let pill = NotchGeometry.frame(content.extent, on: screen)
        #expect(pill.width == laptop.notch.width + content.leftWing + content.rightWing + 6)
        #expect(pill.height == laptop.notch.height + 1 && pill.maxY == screen.frame.maxY)
        #expect(pill.minX + 3 + content.leftWing == notch.minX && pill.maxX - 3 - content.rightWing == notch.maxX)
        #expect(content.leftWing > content.rightWing)
        let island = NotchGeometry.frame(IslandExtent(width: 480, height: 400), on: screen)
        #expect(island.width == 464 + 16 && island.width <= 480)
        #expect(island.maxY == screen.frame.maxY && abs(island.midX - notch.midX) <= 0.5)
    }

    @Test func thePillNeverReachesBelowTheMenuBar() {
        let notch = IslandTheme.Metrics.referenceNotch
        // The owner's display: a 32 pt notch in a 33 pt menu bar gives the 33 pt body.
        #expect(NotchGeometry.pillBodyHeight(notch: notch, menuBar: 33) == 33)
        // A menu bar no taller than the notch caps it; without one measured, the notch + 1.
        #expect(NotchGeometry.pillBodyHeight(notch: notch, menuBar: 32) == 32)
        #expect(NotchGeometry.pillBodyHeight(notch: notch, menuBar: nil) == 33)
        #expect(NotchGeometry.pillBodyHeight(notch: notch, menuBar: 40) == 33)
        // The top bar fits its menu bar: 24 when it cannot be read, 28 at most.
        #expect(NotchGeometry.topBarHeight(menuBar: nil) == 24 && NotchGeometry.topBarHeight(menuBar: 24) == 24)
        #expect(NotchGeometry.topBarHeight(menuBar: 37) == 28)
    }

    @Test func aScreenWithANonZeroOriginStillCentres() throws {
        // The laptop sits right of a 2560-wide primary display, 200 pt lower.
        let screen = Self.laptop(CGSize(width: 1512, height: 982), notch: CGSize(width: 185, height: 32), origin: CGPoint(x: 2560, y: -200))
        let notch = try #require(NotchGeometry.notchRect(on: screen))
        #expect(notch.midX == 2560 + 756 && notch.maxY == 782)
        let pill = NotchGeometry.frame(IslandExtent(left: 130.5, right: 113.5, height: 33), on: screen)
        #expect(pill.minX + 130.5 == notch.midX && pill.maxY == 782)
    }

    @Test func aDisplayWithoutANotchGetsTheTopBar() {
        let screen = Self.external(CGRect(x: -1920, y: 982, width: 1920, height: 1080))
        #expect(!screen.hasNotch && NotchGeometry.notchRect(on: screen) == nil)
        let bar = NotchGeometry.frame(IslandExtent(width: 60, height: 24), on: screen)
        #expect(bar == CGRect(x: -960 - 30, y: 982 + 1080 - 24, width: 60, height: 24))
    }

    @Test func aSafeAreaWithoutAuxiliaryAreasIsNoNotch() {
        let screen = IslandScreen(id: "x", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 24,
                                  auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil)
        #expect(NotchGeometry.notchRect(on: screen) == nil)
    }

    // MARK: P38

    @Test func resolverSurvivesNoScreensAndAGoneDisplay() {
        let laptop = Self.laptop(CGSize(width: 1512, height: 982), notch: CGSize(width: 185, height: 32))
        let external = Self.external(CGRect(x: 1512, y: 0, width: 2560, height: 1440))
        #expect(IslandScreenResolver.resolve([], preferredID: nil) == nil)
        #expect(IslandScreenResolver.resolve([], preferredID: "gone") == nil)
        #expect(IslandScreenResolver.resolve([external, laptop], preferredID: "gone") == laptop)
        #expect(IslandScreenResolver.resolve([external, laptop], preferredID: nil) == laptop)
        #expect(IslandScreenResolver.resolve([external, laptop], preferredID: "external") == external)
        #expect(IslandScreenResolver.resolve([external], preferredID: "built-in") == external)
    }

    // MARK: P36

    @Test func flipUsesThePrimaryDisplayForAnExternalAboveAndLeft() {
        let primaryHeight: CGFloat = 982
        // The external display (1920 × 1080) sits above and left of the primary: its top edge is at y 2062.
        let islandOnExternal = CGRect(x: -1300, y: 982 + 1080 - 300, width: 688, height: 300)
        let topLeft = ScreenSpace.topLeft(fromAppKit: islandOnExternal, primaryHeight: primaryHeight)
        #expect(topLeft == CGRect(x: -1300, y: -1080, width: 688, height: 300))
        #expect(ScreenSpace.appKit(fromTopLeft: topLeft, primaryHeight: primaryHeight) == islandOnExternal)
        #expect(ScreenSpace.topLeft(fromAppKit: CGPoint(x: 10, y: 982), primaryHeight: primaryHeight) == CGPoint(x: 10, y: 0))
    }

    // MARK: P37: the header never reaches under the notch

    @Test func headerWingsWithTheReferenceNotch() {
        let layout = IslandHeaderLayout(notch: IslandTheme.Metrics.referenceNotch)
        #expect(layout.contentWidth == 444)
        #expect(layout.notchMinX == 129.5 && layout.notchMaxX == 314.5)
        #expect(layout.leftSlot.minX == 4 && layout.leftSlot.maxX == 125)
        #expect(layout.rightSlot.minX == 319 && layout.rightSlot.maxX == 440)
        #expect(layout.height == 34)
    }

    @Test(arguments: 0..<4)
    func headerWingsAndSplitLabelsStayClearOfEachNotch(_ index: Int) {
        let layout = IslandHeaderLayout(notch: Self.laptops[index].notch)
        #expect(layout.leftSlot.maxX <= layout.notchMinX - IslandHeaderLayout.slotGap)
        #expect(layout.rightSlot.minX >= layout.notchMaxX + IslandHeaderLayout.slotGap)
        #expect(layout.leftSlot.width > 100 && layout.rightSlot.width > 100)
        #expect(layout.height >= Self.laptops[index].notch.height)

        // Every hover label the demo's 6 + 5 accounts, both marks and all money can show (Clean and Detailed alike):
        // the name fits the left wing, at least one detail fits the right one.
        let usage = DemoUsageModel(now: DemoClock.now)
        var targets: [HoverTargetID] = usage.allBatteries.map { .account($0.id) } + [.provider(.claude), .provider(.codex)]
        targets += usage.panel.money.map { .money($0.id) }
        for target in targets {
            guard let label = HoverLabelText.short(target, usage: usage),
                  let fitted = IslandHeaderView.label(target, usage: usage, layout: layout) else { continue }
            #expect(!fitted.label.parts.isEmpty || label.parts.isEmpty)
            #expect(IslandSlotText.nameWidth(fitted.label.name, size: fitted.size) <= layout.leftSlot.width,
                    "\(label.name) overruns a \(Self.laptops[index].name) left wing")
            #expect(IslandSlotText.partsWidth(fitted.label.parts, size: fitted.size) <= layout.rightSlot.width,
                    "\(label.text) overruns a \(Self.laptops[index].name) right wing")
        }
    }

    @Test func headerChromeSitsOverTheRowColumns() {
        // The brand glyph's column starts where a Clean row's glyph column does (row padding 8), so they line up.
        let layout = IslandHeaderLayout(notch: IslandTheme.Metrics.referenceNotch)
        #expect(layout.leftSlot.minX + IslandHeaderView.brandInset == 8)
    }

    @Test(arguments: 0..<4)
    func headerStripPairsFitBesideEachNotch(_ index: Int) {
        let layout = IslandHeaderLayout(notch: Self.laptops[index].notch)
        // Left: brand inset 4 and column 16, gap 8, the Claude pair. Right: the Codex pair, gap 8, the gear (13 + 3
        // padding each side).
        #expect(IslandHeaderView.brandInset + IslandTheme.Metrics.rowGlyphColumn + 8 + HeaderStripPair.width <= layout.leftSlot.width)
        #expect(HeaderStripPair.width + 8 + 19 <= layout.rightSlot.width)
        let env = AppEnvironment.demo()
        let pair = NSHostingView(rootView: HeaderStripPair(row: env.usage.claudeRow, action: {}).environment(env))
        #expect(pair.fittingSize.width <= HeaderStripPair.width + 0.5)
    }

    // MARK: The closed pill

    @Test func pillWingsFollowTheirContent() {
        let lead = PillLead(glyph: .eq, agent: .claude, state: .running), notch = IslandTheme.Metrics.referenceNotch
        func pill(_ lead: PillLead?, _ count: Int?, glance: Bool = false) -> PillContent {
            PillContent.make(lead: lead, count: count, glance: glance, style: .pixel, edgeLine: false, notch: notch, menuBar: 33)
        }
        // Idle: nothing beside the notch.
        #expect(pill(nil, nil).leftWing == 0 && pill(nil, nil).rightWing == 0 && pill(nil, nil).extent == IslandExtent(width: 185, height: 32))
        // A lead and no count: no right wing at all, only the ear.
        #expect(pill(lead, nil).leftWing == 27.5 && pill(lead, nil).rightWing == 0)
        #expect(pill(lead, nil).extent.right == notch.width / 2 + IslandTheme.Metrics.pillEar)
        // The count's wing is the count and 5 pt each side, and a wider count widens only it.
        for count in [1, 10, 100, 1000] {
            let content = pill(lead, count, glance: true)
            #expect(content.rightWing == ClosedPillView.countWidth(count) + ClosedPillView.dotSize + ClosedPillView.dotGap + 10)
            #expect(content.leftWing == 27.5)
        }
        #expect(pill(lead, 10).rightWing > pill(lead, 1).rightWing && pill(lead, 10).rightWing <= 26)
    }

    @Test func thePillShowsTheMostUrgentGlyph() {
        func row(_ id: String, _ agent: GlyphPalette.Agent, _ bucket: SessionBucket, _ glyph: PixelGlyph) -> SessionRow {
            SessionRow(id: id, agent: agent, bucket: bucket, project: "p", task: id, status: .working, detail: nil, lastPrompt: nil,
                       host: nil, accountAlias: nil, updatedAt: Date(timeIntervalSince1970: 0), isCodexApp: false, glyph: glyph,
                       glyphState: .running, hasCard: bucket == .needsYou)
        }
        let running = row("r", .codex, .running, .eq), done = row("d", .claude, .done, .check)
        let question = row("q", .claude, .needsYou, .ques), approval = row("a", .codex, .needsYou, .bang)
        #expect(PillLead.make(rows: [], recentlyFinished: nil) == nil)
        #expect(PillLead.make(rows: [done], recentlyFinished: nil) == PillLead(glyph: .check, agent: .claude, state: .done, dimmed: true))
        #expect(PillLead.make(rows: [done], recentlyFinished: .codex) == PillLead(glyph: .check, agent: .codex, state: .done))
        #expect(PillLead.make(rows: [done, running], recentlyFinished: .claude) == PillLead(glyph: .eq, agent: .codex, state: .running))
        #expect(PillLead.make(rows: [running, question], recentlyFinished: nil) == PillLead(glyph: .ques, agent: .claude, state: .waiting))
        #expect(PillLead.make(rows: [question, running, approval], recentlyFinished: nil)
            == PillLead(glyph: .bang, agent: .codex, state: .waiting))
    }

    // MARK: Motion

    /// Only growth overshoots; every shrink is critically damped but Motion: Refined's tucked fold, whose bounce of 0.05
    /// undershoots by 7.06 × 10⁻⁵ of its travel: within `IslandMotion.undershoot` of it.
    @Test func onlyGrowthOvershootsAndEveryShrinkIsCriticallyDampedButTheTuckedFold() {
        for curve in IslandMotion.all { #expect(curve.bounce <= 0.12 + 1e-9) }
        let tucked: Set = [IslandMotion.tuckedFold, IslandMotion.tuckedFoldWide]
        for curve in IslandMotion.shrinks where !tucked.contains(curve) { #expect(curve.dampingFraction == 1) }
        for curve in tucked {
            let z = curve.dampingFraction
            #expect(z < 1 && exp(-z * Double.pi / (1 - z * z).squareRoot()) <= IslandMotion.undershoot, "\(curve)")
        }
        let overshooting = IslandMotion.all.filter { $0.bounce > 0 }
        #expect(Set(overshooting) == Set(IslandMotion.growths).union(tucked))
        #if !DEBUG
        #expect(IslandMotion.slowdown == 1)
        #endif
    }
}
