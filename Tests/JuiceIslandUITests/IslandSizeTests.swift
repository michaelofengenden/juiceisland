import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Settings › Island › Width and Text size (P401, P402), and the update dot on the pill and the gear (P403).
@MainActor
@Suite(.serialized)
struct IslandSizeTests {
    typealias Model = IslandChoreography

    // MARK: Settings

    /// 480 and 12 until the owner picks, the pill's dot on; a stored value off the steps is read as the nearest step.
    @Test func theDefaultsAndTheSteps() {
        let settings = AppSettings.ephemeral()
        #expect(settings.islandWidth == 480 && settings.islandTextSize == 12 && settings.pillUpdateDot)
        #expect(IslandSize(settings) == .standard)
        let suite = "IslandSizeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(9999, forKey: AppSettings.Key.islandWidth)
        defaults.set(11, forKey: AppSettings.Key.islandTextSize)
        let stored = AppSettings(defaults: defaults)
        #expect(stored.islandWidth == 640 && stored.islandTextSize == 12)
        #expect(IslandSize(width: 530, text: 14) == IslandSize(outer: 520, text: 14))
    }

    /// The standard size is the island every earlier round measured: 464 between the shoulders, 444 of content, a 496
    /// canvas, the shoulder gate at 410...462, and every line box as it was.
    @Test func theStandardSizeIsTheIslandAsItWas() {
        let size = IslandSize.standard
        #expect(size.width == IslandTheme.Metrics.width && size.contentWidth == IslandTheme.Metrics.contentWidth)
        #expect(size.canvasWidth == IslandTheme.Metrics.width + 2 * IslandTheme.Metrics.shoulder + 2 * IslandTheme.Metrics.canvasMargin)
        #expect(size.shoulderGate == IslandTheme.Metrics.shoulderGate)
        #expect(size.rowTitleHeight == IslandTheme.Metrics.rowTitleHeight && size.rowStatusHeight == IslandTheme.Metrics.rowStatusHeight)
        #expect(size.line(19, for: 12) == 19 && size.text(11) == 11 && size.scaled(24, for: 11) == 24)
        #expect(DetailedRowMetrics.island.scaled(size).title == DetailedRowMetrics.island.title)
        #expect(SurfaceTargets(notch: IslandTheme.Metrics.referenceNotch, pill: .empty).island(height: 200).width == 480)
    }

    // MARK: Width

    /// Every width lays the island out at that width: its surface, its canvas centred on the notch, its content and its
    /// shoulder gate, which keeps its place against the shoulders.
    @Test func everyWidthIsTheSurfacesTheCanvassAndTheGates() {
        let notch = IslandTheme.Metrics.referenceNotch
        for width in IslandSize.widths {
            let size = IslandSize(width: width, text: 12)
            let targets = SurfaceTargets(notch: notch, pill: .empty, islandWidth: size.outer)
            #expect(targets.island(height: 300).width == CGFloat(width))
            #expect(targets.shoulderGate.upperBound == CGFloat(width) - 18 && targets.shoulderGate.lowerBound == CGFloat(width) - 70)
            let canvas = IslandPanelSizing.canvasRect(centreX: 756, top: 982, screenHeight: 982, size: size)
            #expect(canvas.width == CGFloat(width) + 16 && abs(canvas.midX - 756) <= 0.5)
            #expect(size.contentWidth == CGFloat(width) - 36)
            var model = Model(metrics: .init(targets: targets, outline: .coreAnimation), surface: .island)
            #expect(model.restGeometry.width == CGFloat(width))
            // Core Animation's outline takes the gate from the model: open at this width, the shoulders show.
            _ = model.handle(.outline(.swiftUI), at: 1)
            let back = model.handle(.outline(.coreAnimation), at: 2)
            #expect(back.contains(.animate(nil, [.shoulders: 1])))
        }
    }

    /// The header's left wing, at the narrowest width, still holds the brand glyph and the usage strip's pair beside the
    /// reference notch (why the narrowest is 460).
    @Test func theNarrowestHeaderStillHoldsTheStrip() {
        let need = IslandHeaderView.brandInset + IslandTheme.Metrics.rowGlyphColumn + 8 + HeaderStripPair.width
        for width in IslandSize.widths {
            let layout = IslandHeaderLayout(notch: IslandTheme.Metrics.referenceNotch, contentWidth: IslandSize(width: width, text: 12).contentWidth)
            #expect(layout.leftSlot.width >= need && layout.rightSlot.width >= need, "\(width): \(layout.leftSlot.width) < \(need)")
        }
        let narrower = IslandHeaderLayout(notch: IslandTheme.Metrics.referenceNotch, contentWidth: IslandSize(outer: 440, text: 12).contentWidth)
        #expect(narrower.leftSlot.width < need, "440 would not hold it")
    }

    /// Measured live at the narrowest and widest, the rows span the content and the header its width.
    @Test func theIslandIsMeasuredAtItsWidth() {
        for width in [IslandSize.widths.first!, IslandSize.widths.last!] {
            let size = IslandSize(width: width, text: 12)
            let settings = AppSettings.ephemeral()
            settings.islandUsagePlacement = .section
            let layout = DMotionRenders.measure(env: .demo(settings: settings, sessions: .prototype), notch: IslandTheme.Metrics.referenceNotch,
                                                card: nil, island: size)
            let rows = layout.parts.filter { if case .row = $0.key { true } else { false } }.map(\.value)
            #expect(!rows.isEmpty)
            for row in rows {
                #expect(abs(row.width - size.contentWidth) < 0.5 && abs(row.minX - (IslandTheme.Metrics.shoulder + IslandTheme.Metrics.horizontalPadding)) < 0.5,
                        "\(width): \(row)")
            }
            let usage = layout.parts[.usage]
            #expect(usage.map { abs($0.width - size.contentWidth) < 0.5 } == true)
        }
    }

    // MARK: Text size

    /// Every row line and its box step with the text: a Clean row is 41 pt at 12 and 49 at 15, measured live; the card
    /// header's Detailed row steps the same way.
    @Test func theRowsGrowWithTheText() {
        let big = IslandSize(width: 480, text: 15)
        #expect(big.rowTitleHeight == 20 && big.rowStatusHeight == 19 && big.text(11) == 14)
        #expect(DetailedRowMetrics.island.scaled(big).title == (15, 22) && DetailedRowMetrics.island.scaled(big).status == (14, 20))
        #expect(big.scaled(IslandTheme.Metrics.rowAgeWidth, for: 11) == 31)
        for (size, height) in [(IslandSize.standard, 41.0), (big, 49.0)] {
            let layout = DMotionRenders.measure(env: .demo(sessions: .prototype), notch: IslandTheme.Metrics.referenceNotch, card: nil, island: size)
            let rows = layout.parts.filter { if case .row = $0.key { true } else { false } }.map(\.value)
            #expect(!rows.isEmpty && rows.allSatisfy { abs($0.height - height) < 0.5 }, "\(size.text): \(rows.map(\.height))")
        }
    }

    // MARK: The update dot

    static func pill(update: Bool, rows: [SessionRow], settings: AppSettings = .ephemeral(), fullScreen: Bool = false) -> PillContent {
        PillContent.make(rows: rows, settings: settings, glance: false, recentlyFinished: nil, now: DemoClock.now,
                         notch: IslandTheme.Metrics.referenceNotch, menuBar: IslandTheme.Metrics.referenceMenuBar,
                         fullScreen: fullScreen, update: update)
    }

    /// A pill that shows something shows the dot after its count, its wing wider by the dot and its gap; a pill with
    /// nothing else to show, one hidden when idle, one in full screen or with the switch off shows none.
    @Test func theUpdateDotJoinsWhatThePillShows() {
        let rows = [ActiveCountTests.row("r", .claude, .running, ago: 10), ActiveCountTests.row("d", .codex, .done, ago: 60)]
        let plain = Self.pill(update: false, rows: rows), dotted = Self.pill(update: true, rows: rows)
        #expect(!plain.update && dotted.update && dotted.count == plain.count)
        #expect(dotted.rightWing - plain.rightWing == ClosedPillView.dotGap + ClosedPillView.updateDotSize)
        #expect(dotted.extent.left == plain.extent.left)

        let empty = Self.pill(update: true, rows: [])
        #expect(!empty.update && empty.isEmpty && empty.extent == IslandExtent(width: 185, height: 32))

        let off = AppSettings.ephemeral()
        off.pillUpdateDot = false
        #expect(!Self.pill(update: true, rows: rows, settings: off).update)

        let idle = AppSettings.ephemeral()
        idle.hidePillWhenIdle = true
        let old = [ActiveCountTests.row("d", .codex, .done, ago: 7200)]
        #expect(!Self.pill(update: true, rows: old, settings: idle).update)

        let full = AppSettings.ephemeral()
        full.hideInFullScreen = true
        full.fullScreenShowsNeedsYou = true
        let waiting = [ActiveCountTests.row("q", .claude, .needsYou, ago: 10)]
        #expect(!Self.pill(update: true, rows: waiting, settings: full, fullScreen: true).update)

        // The top bar without a notch widens by the dot too.
        let bar = PillContent.make(lead: dotted.lead, count: dotted.count, glance: false, update: true, style: .pixel, edgeLine: false,
                                   notch: nil, menuBar: 24)
        let barPlain = PillContent.make(lead: dotted.lead, count: dotted.count, glance: false, style: .pixel, edgeLine: false,
                                        notch: nil, menuBar: 24)
        #expect(bar.barWidth - barPlain.barWidth == ClosedPillView.dotGap + ClosedPillView.updateDotSize)
    }

    /// The gear's dot and the pill's follow the updater's own state: an update offered and not running, or a restart asked
    /// for; nothing while one runs, before a check, or once one is done.
    @Test func theDotFollowsTheUpdatersState() {
        let info = UpdateInfo(newer: 3, subjects: ["Fix"])
        #expect(UpdateText.menuEnabled(available: info, phase: .idle))
        #expect(UpdateText.menuEnabled(available: nil, phase: .restartNeeded))
        #expect(!UpdateText.menuEnabled(available: info, phase: .building))
        #expect(!UpdateText.menuEnabled(available: nil, phase: .idle))
        #expect(!UpdateText.menuEnabled(available: nil, phase: .updated("3d74159")))
    }
}
