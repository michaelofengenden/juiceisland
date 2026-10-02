import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Glyph style: Settings › Island in each style, the closed pill at 3× in each style and mood with the edge line on and
/// off and a count of 3 and of 10, the no-notch top bar, the same pills at their real size in one sheet
/// (`gl-foundation-pill-sheet`), the window's session list and the opened island. Files `gl-foundation-*`. Liquid and
/// Sand draw their real engines, still (`animated: false`).
@MainActor
@Suite(.serialized)
struct GlyphStyleRenders {
    enum Mood: String, CaseIterable { case running, approval, question, done }

    // MARK: Settings

    @Test(arguments: GlyphStyle.allCases)
    func settingsIsland(_ style: GlyphStyle) throws {
        let env = AppEnvironment.demo(settings: settings(style))
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .island), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "gl-foundation-settings-island-\(style.rawValue)",
                                       size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    // MARK: The closed pill

    static let counts = [3, 10]

    @Test(arguments: GlyphStyle.allCases)
    func pill(_ style: GlyphStyle) throws {
        for mood in Mood.allCases {
            for edgeLine in [true, false] {
                for count in Self.counts {
                    let (rows, finished) = Self.rows(mood, count: count)
                    let tile = pillTile(style: style, edgeLine: edgeLine, rows: rows, recentlyFinished: finished)
                    try RenderHarness.render(Self.zoomed(tile), "gl-foundation-pill-\(style.rawValue)-\(mood.rawValue)-edge-\(edgeLine ? "on" : "off")-\(count)")
                }
            }
        }
    }

    @Test(arguments: GlyphStyle.allCases)
    func topBar(_ style: GlyphStyle) throws {
        for edgeLine in [true, false] {
            let tile = pillTile(style: style, edgeLine: edgeLine, rows: Self.rows(.running, count: 10).0, notch: nil)
            try RenderHarness.render(Self.zoomed(tile), "gl-foundation-topbar-\(style.rawValue)-running-edge-\(edgeLine ? "on" : "off")")
        }
    }

    /// Every pill above at its real size (2×, as on the display): a row per style, edge line and count, a column per
    /// mood, then the top bars.
    @Test func pillSheet() throws {
        let sheet = VStack(alignment: .leading, spacing: 4) {
            ForEach(GlyphStyle.allCases, id: \.self) { style in
                ForEach([true, false], id: \.self) { edgeLine in
                    ForEach(Self.counts, id: \.self) { count in
                        HStack(spacing: 6) {
                            Text(verbatim: "\(style.rawValue) · edge \(edgeLine ? "on" : "off") · \(count)")
                                .frame(width: 110, alignment: .leading)
                            ForEach(Mood.allCases, id: \.self) { mood in
                                let (rows, finished) = Self.rows(mood, count: count)
                                pillTile(style: style, edgeLine: edgeLine, rows: rows, recentlyFinished: finished)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Text(verbatim: "top bar · edge on / off").frame(width: 110, alignment: .leading)
                ForEach(GlyphStyle.allCases, id: \.self) { style in
                    ForEach([true, false], id: \.self) { edgeLine in
                        pillTile(style: style, edgeLine: edgeLine, rows: Self.rows(.running, count: 3).0, notch: nil, width: 100)
                    }
                }
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color(white: 0.85))
        .padding(10)
        .background(Color(white: 0.16))
        try RenderHarness.render(sheet, "gl-foundation-pill-sheet")
    }

    // MARK: Lists

    @Test(arguments: GlyphStyle.allCases)
    func sessionList(_ style: GlyphStyle) throws {
        let env = AppEnvironment.demo(settings: settings(style), sessions: .allStates)
        let view = SessionListView()
            .frame(width: 900, height: 700)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, "gl-foundation-list-\(style.rawValue)", size: CGSize(width: 916, height: 716), env: env)
    }

    @Test(arguments: GlyphStyle.allCases)
    func openedIsland(_ style: GlyphStyle) throws {
        let env = AppEnvironment.demo(settings: settings(style), sessions: .prototype)
        let notch = IslandTheme.Metrics.referenceNotch
        let view = OpenedIslandView(presentation: .list, notch: notch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: notch), "gl-foundation-island-\(style.rawValue)", env: env)
    }

    // MARK: Helpers

    private func settings(_ style: GlyphStyle, edgeLine: Bool = true) -> AppSettings {
        let settings = AppSettings.ephemeral()
        settings.glyphStyle = style
        settings.glyphEdgeLine = edgeLine
        return settings
    }

    /// The board behind each mood's lead, `count` sessions in all (done ones fill it up, so the lead and the line stay
    /// the mood's own). A running session sits behind the approval and the question, so their edge line runs; the check
    /// has none behind it, so its line has drained.
    private static func rows(_ mood: Mood, count: Int) -> ([SessionRow], GlyphPalette.Agent?) {
        let (lead, finished): ([SessionRow], GlyphPalette.Agent?) = switch mood {
        case .running: ([DStub.row("r", .claude, .running)], nil)
        case .approval: ([DStub.row("a", .claude, .needsYou, glyph: .bang), DStub.row("r", .codex, .running)], nil)
        case .question: ([DStub.row("q", .claude, .needsYou, glyph: .ques), DStub.row("r", .codex, .running)], nil)
        case .done: ([DStub.row("d", .codex, .done)], .codex)
        }
        let rest = (lead.count..<max(lead.count, count)).map { DStub.row("d\($0)", .claude, .done, minutesAgo: 30) }
        return (lead + rest, finished)
    }

    /// The pill as the display shows it, `width` × 44: a mid-grey menu bar (the owner's measured 33 pt beside the
    /// notch, or 24 without one) over a darker ground, its bottom marked by a thin magenta line, the pill hanging from
    /// the top by its notch, and the hardware notch (the reference 185 × 32 with its radius, pure black) drawn over it,
    /// as the display's cutout is: whatever the pill draws behind the notch does not show, the edge line reads full in
    /// the wings and as a hairline under the notch (P72), and nothing may cross the magenta line.
    private func pillTile(style: GlyphStyle, edgeLine: Bool, rows: [SessionRow], recentlyFinished: GlyphPalette.Agent? = nil,
                          notch: CGSize? = IslandTheme.Metrics.referenceNotch, width: CGFloat = 300) -> some View {
        let env = AppEnvironment(settings: settings(style, edgeLine: edgeLine), usage: DemoUsageModel(now: DemoClock.now),
                                 sessions: DStub(rows: rows))
        let menuBar = notch == nil ? IslandTheme.Metrics.topBarFallbackHeight : IslandTheme.Metrics.referenceMenuBar
        return ZStack(alignment: .notchTop) {
            Color(white: 0.36)
            Color(white: 0.52).frame(height: menuBar)
            Self.menuBarMark.frame(height: 0.5).offset(y: menuBar)
            ClosedPillView(notch: notch, animated: false, recentlyFinished: recentlyFinished, menuBar: menuBar)
            if let notch {
                UnevenRoundedRectangle(bottomLeadingRadius: IslandTheme.Metrics.referenceNotchRadius,
                                       bottomTrailingRadius: IslandTheme.Metrics.referenceNotchRadius)
                    .fill(.black).frame(width: notch.width, height: notch.height)
            }
        }
        .frame(width: width, height: 44)
        .environment(env)
    }

    /// The menu bar's bottom edge in the tiles.
    static let menuBarMark = Color(red: 1, green: 0.2, blue: 0.75)

    /// A tile drawn at 3× (6 px a point).
    private static func zoomed<V: View>(_ tile: V) -> some View {
        tile.scaleEffect(3, anchor: .topLeading).frame(width: 900, height: 132, alignment: .topLeading)
    }
}
