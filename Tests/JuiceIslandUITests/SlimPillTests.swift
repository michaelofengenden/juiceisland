import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The slim pill (owner: "make the pill slightly less wide, it goes over a tiny bit on my safari page, also make it as
/// least as you can on the right hand side"): never below the menu bar, the lead's wing on the left, the count's as
/// narrow as its digits on the right, the edge line inside the body. Pure values; nothing is drawn.
@MainActor
struct SlimPillTests {
    static let lead = PillLead(glyph: .eq, agent: .claude, state: .running)

    static func pill(_ style: GlyphStyle, count: Int? = 3, glance: Bool = false, edgeLine: Bool = true,
                     notch: CGSize? = IslandTheme.Metrics.referenceNotch, menuBar: CGFloat? = 33) -> PillContent {
        PillContent.make(lead: lead, count: count, glance: glance, style: style, edgeLine: edgeLine, notch: notch, menuBar: menuBar)
    }

    /// Every notch height from 24 to 38 pt under every menu bar from 22 to 40 pt (and none measured): the pill is never
    /// taller than the menu bar and never shorter than the notch unless the menu bar is, and the lead fits above the
    /// line with its margins.
    @Test(arguments: GlyphStyle.allCases)
    func thePillNeverReachesBelowTheMenuBar(_ style: GlyphStyle) {
        for notchHeight in stride(from: CGFloat(24), through: 38, by: 1) {
            let notch = CGSize(width: 185, height: notchHeight)
            let menuBars: [CGFloat?] = [nil] + Array(stride(from: CGFloat(22), through: 40, by: 0.5))
            for menuBar in menuBars {
                for edgeLine in [true, false] {
                    let content = Self.pill(style, edgeLine: edgeLine, notch: notch, menuBar: menuBar)
                    let e = content.extent
                    let expected: CGFloat = min(notchHeight + 1, menuBar ?? notchHeight + 1)
                    #expect(e.height == expected && e.height <= notchHeight + 1)
                    // The lead sits 2.5 pt clear of the top and of the line (or the body's bottom).
                    let margin = IslandTheme.Metrics.pillGlyphMargin
                    #expect(content.glyphSide + 2 * margin <= content.room + 0.001, "\(style) \(notch) \(String(describing: menuBar))")
                    if style == .pixel { #expect(content.glyphSide == 17.5 || content.glyphSide == 14) }
                    // The line lives inside the body.
                    #expect(content.edgeLine == (style != .pixel && edgeLine ? 3 : 0) && content.room + content.edgeLine == e.height)
                }
            }
        }
    }

    /// The swell under the pointer never hangs below the menu bar either: it is never taller than the pill's body (the
    /// idle notch's swell grows to that body at most), so on the owner's display it only widens, and the top bar's swell
    /// only widens everywhere.
    @Test(arguments: GlyphStyle.allCases)
    func theSwellNeverReachesBelowTheMenuBar(_ style: GlyphStyle) {
        for notchHeight in stride(from: CGFloat(24), through: 38, by: 2) {
            let notch = CGSize(width: 185, height: notchHeight)
            for menuBar in [nil, 22, 24, 30, 32, 33, 34, 37, 40] as [CGFloat?] {
                let pill = Self.pill(style, notch: notch, menuBar: menuBar)
                let idle = PillContent.make(lead: nil, count: nil, glance: false, style: style, edgeLine: true, notch: notch, menuBar: menuBar)
                let swell = SurfaceTargets(notch: notch, pill: pill).swell(), idleSwell = SurfaceTargets(notch: notch, pill: idle).swell()
                #expect(swell.height == pill.bodyHeight && swell.width == pill.extent.width + 6, "\(notch) \(String(describing: menuBar))")
                #expect(idleSwell.height == max(notchHeight, min(notchHeight + 2, idle.bodyHeight)), "\(notch) \(String(describing: menuBar))")
                #expect(menuBar.map { swell.height <= $0 } ?? true)
            }
        }
        let owners = SurfaceTargets(notch: IslandTheme.Metrics.referenceNotch, pill: Self.pill(style))
        #expect(owners.swell().height == 33 && owners.swell().width == owners.closed.width + 6)
        for menuBar in [nil, 24, 28] as [CGFloat?] {
            let bar = SurfaceTargets(notch: nil, pill: Self.pill(style, notch: nil, menuBar: menuBar))
            #expect(bar.swell().height == bar.closed.height)
        }
    }

    /// The top bar fits its menu bar too.
    @Test func theTopBarFitsItsMenuBar() {
        for menuBar in [nil, 22, 24, 25, 28, 37] as [CGFloat?] {
            for style in GlyphStyle.allCases {
                let bar = Self.pill(style, notch: nil, menuBar: menuBar)
                #expect(bar.extent.height == min(28, menuBar ?? 24) && bar.extent.height <= (menuBar ?? 24))
                #expect(bar.glyphSide + 2 * IslandTheme.Metrics.pillGlyphMargin <= bar.room + 0.001)
                #expect(bar.extent.left == bar.extent.right)
            }
        }
    }

    /// The live pill takes its display's scale: on a no-notch display at 1× Pixel's lead is drawn in whole-point pixels
    /// (2 pt in a 24 pt bar, 3 pt where its 21 pt fit), never 2.5 pt ones that go soft in every other column.
    @Test func theLivePillTakesItsDisplaysScale() throws {
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.glyphStyle = .pixel
        for (menuBar, scale, pixel) in [(24, 1, 2), (24, 2, 2.5), (28, 1, 3), (28, 2, 2.5)] as [(CGFloat, CGFloat, CGFloat)] {
            var screen = DIslandGeometryTests.external(CGRect(x: 0, y: 0, width: 1920, height: 1080))
            screen.menuBarHeight = menuBar
            screen.scale = scale
            let pill = IslandPanelController.pill(rows: [], settings: settings, glance: false, recentlyFinished: .claude, now: Date(),
                                                  on: screen)
            let idle = IslandPanelController.idlePill(settings: settings, on: screen)
            #expect(pill.lead != nil && pill.leadPixel == pixel && pill.displayScale == scale, "\(menuBar) at \(scale)×")
            #expect(idle.displayScale == scale && idle.leadPixel == pixel, "\(menuBar) at \(scale)×")
            #expect((pill.leadPixel * scale).rounded() == pill.leadPixel * scale)
        }
    }

    /// The right wing is the count and 5 pt each side, one to three digits (and Glance's dot), and nothing without a
    /// count; the left wing is the lead and 5 pt each side; the notch stays where it is.
    @Test(arguments: GlyphStyle.allCases)
    func theWingsAreAsSlimAsTheirContent(_ style: GlyphStyle) {
        let notch = IslandTheme.Metrics.referenceNotch, ear = IslandTheme.Metrics.pillEar
        for count in [1, 9, 10, 42, 99, 100, 999] {
            for glance in [false, true] {
                let content = Self.pill(style, count: count, glance: glance)
                let digits = ClosedPillView.countWidth(count)
                let dot: CGFloat = glance ? ClosedPillView.dotSize + ClosedPillView.dotGap : 0
                let wing = ceil(digits + dot + 10)
                #expect(content.rightWing == wing)
                #expect(content.extent.right == notch.width / 2 + content.rightWing + ear)
                #expect(content.extent.left == notch.width / 2 + content.leftWing + ear)
                #expect(content.leftWing == ((content.glyphSide + 10) * 2).rounded(.up) / 2)
            }
        }
        // Two digits need no more than 26 pt; each digit more adds its own width only.
        let two = Self.pill(style, count: 99).rightWing, three = Self.pill(style, count: 999).rightWing
        #expect(two <= 26 && three - two <= 9)
        // No count, no Glance: no right wing at all, only the ear beyond the notch.
        let bare = Self.pill(style, count: nil)
        #expect(bare.rightWing == 0 && bare.extent.right == notch.width / 2 + ear)
        // A count alone (no lead) has no left wing.
        let countOnly = PillContent.make(lead: nil, count: 2, glance: false, style: style, edgeLine: true, notch: notch, menuBar: 33)
        #expect(countOnly.leftWing == 0 && countOnly.rightWing > 0)
    }

    /// The owner's display: a 185 × 32 notch in a 33 pt menu bar. Today's pill was 273 × 37 with Liquid and the line;
    /// the slim one is 33 tall and reaches 23 pt less to the right.
    @Test func theOwnersPillIsSlimmer() {
        let liquid = Self.pill(.liquid).extent, half: CGFloat = 92.5, ear: CGFloat = 3
        #expect(liquid.height == 33)
        #expect(liquid.left == half + 35 + ear)
        let right: CGFloat = half + Self.pill(.liquid).rightWing + ear
        #expect(liquid.right == right)
        #expect(liquid.right <= half + 18 + ear)
        #expect(liquid.width < 248)
        let pixel = Self.pill(.pixel).extent
        #expect(pixel.left == half + 27.5 + ear)
        #expect(pixel.height == 33)
    }
}
