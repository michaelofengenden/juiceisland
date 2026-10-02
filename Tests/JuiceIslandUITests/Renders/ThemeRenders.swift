import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Theme (P520 to P529), headless. Offscreen the window server composites no glass, so every glass here is the
/// stand-in (`GlassRendering.standIn`: the backdrop blurred in the shape, under the same floor and rim as the live
/// glass), named `th-standin-*` so no one takes it for a screenshot. The surfaces carry token samples (the glass palette's
/// ink, fills and lines, the state and agent colours), not the real island, panel or widget, which their lanes move onto
/// the palette. Also: the Settings row and its preview in each theme.
@MainActor
@Suite(.serialized)
struct ThemeRenders {
    // MARK: Samples

    /// An island's worth of tokens on its surface: three rows (a request, a run on hover, a delegation), a hairline and a
    /// footer, in the environment's theme.
    struct IslandSample: View {
        @Environment(\.juiceTheme) private var theme
        private var p: IslandPalette { theme.island }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                row(.bang, NeedsYouColour.pink.wait, agent: p.tone(IslandTheme.agentClaude), "Tidy the release notes",
                    word: "Needs approval", p.toneText(NeedsYouColour.pink.wait), "Bash", age: "2m")
                row(.eq, IslandTheme.run, agent: p.tone(IslandTheme.agentCodex), "Fix the flaky test", word: "Running",
                    p.statusClean, "cargo test", age: "5m")
                    .background(RoundedRectangle(cornerRadius: 8).fill(p.islandHover))
                row(.agents, IslandTheme.delegate, agent: p.tone(IslandTheme.agentClaude), "Name the app",
                    word: "Waiting on 2 agents", p.toneText(IslandTheme.delegate), nil, age: "12m")
                row(.check, IslandTheme.done, agent: p.tone(IslandTheme.agentCodex), "Pick a chart", word: "Done",
                    p.toneText(IslandTheme.done), "3 files", age: "1h")
                p.line.frame(height: 1).padding(.horizontal, 6).padding(.vertical, 4)
                HStack(spacing: 10) {
                    Text(verbatim: "Show 2 more").foregroundStyle(p.footer)
                    Text(verbatim: "Earlier").foregroundStyle(p.ink3)
                    Spacer(minLength: 0)
                    Text(verbatim: "⌃G").font(Fonts.sys(11)).foregroundStyle(p.kbd)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(p.button))
                }
                .font(Fonts.sys(11))
                .padding(.horizontal, 12)
            }
            .padding(.horizontal, IslandTheme.Metrics.horizontalPadding + IslandTheme.Metrics.shoulder)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(width: IslandTheme.Metrics.width + 2 * IslandTheme.Metrics.shoulder, alignment: .topLeading)
            .themedSurface(IslandShape())
        }

        private func row(_ glyph: PixelGlyph, _ colour: Color, agent: Color, _ title: String, word: String, _ wordColour: Color,
                         _ detail: String?, age: String) -> some View {
            HStack(alignment: .top, spacing: IslandTheme.Metrics.rowGlyphGap) {
                StateGlyphView(glyph: glyph, colour: colour, pixel: IslandTheme.Metrics.rowGlyphPixel, animated: false, style: .pixel)
                    .frame(width: IslandTheme.Metrics.rowGlyphColumn, height: IslandTheme.Metrics.rowGlyphColumn)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Circle().fill(agent).frame(width: 7, height: 7)
                        Text(verbatim: title).font(Fonts.sys(12.5, .semibold)).foregroundStyle(p.ink)
                    }
                    .frame(height: IslandTheme.Metrics.rowTitleHeight)
                    HStack(spacing: 0) {
                        Text(verbatim: word).foregroundStyle(wordColour)
                        if let detail {
                            Text(verbatim: " · ").foregroundStyle(p.ink3)
                            Text(verbatim: detail).foregroundStyle(p.statusClean)
                        }
                    }
                    .font(IslandTheme.TypeScale.cleanLine2)
                    .frame(height: IslandTheme.Metrics.rowStatusHeight)
                }
                Spacer(minLength: 0)
                Text(verbatim: age).font(IslandTheme.TypeScale.rowRight).foregroundStyle(p.rowAge)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, IslandTheme.Metrics.rowVerticalPadding)
        }
    }

    /// A closed pill's worth: an approval's "!", a running glyph and a count, hanging from the top.
    struct PillSample: View {
        @Environment(\.juiceTheme) private var theme
        private var p: IslandPalette { theme.island }

        var body: some View {
            HStack(spacing: 8) {
                StateGlyphView(glyph: .bang, colour: NeedsYouColour.pink.wait, pixel: 2.5, animated: false, style: .pixel)
                StateGlyphView(glyph: .eq, colour: IslandTheme.run, pixel: 2.5, animated: false, style: .pixel)
                Spacer(minLength: 0)
                Text(verbatim: "3").font(IslandTheme.TypeScale.pillCount).foregroundStyle(p.ink)
            }
            .padding(.horizontal, 12)
            .frame(width: 244, height: 33)
            .themedSurface(PillShape())
        }
    }

    /// The desktop panel's worth: its two ink greys, a divider and the warn and attention colours.
    struct PanelSample: View {
        @Environment(\.juiceTheme) private var theme
        private var p: PanelPalette { theme.panel }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Circle().fill(p.tone(Theme.claudeMark)).frame(width: 20, height: 20)
                    ForEach(0..<6, id: \.self) { index in
                        RoundedRectangle(cornerRadius: Theme.Battery.radius).fill(p.track)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: Theme.Battery.radius).fill(index == 2 ? p.tone(Theme.warn) : p.ink)
                                    .frame(width: CGFloat(10 + 5 * index))
                            }
                            .frame(width: Theme.Battery.width, height: Theme.Battery.height)
                    }
                }
                p.divider.frame(height: 1)
                HStack {
                    Text(verbatim: "OpenRouter").foregroundStyle(p.ink)
                    Spacer()
                    Text(verbatim: "$41.20").foregroundStyle(p.ink).fontWeight(.semibold)
                    Text(verbatim: "spent").foregroundStyle(p.ink2)
                }
                HStack {
                    Text(verbatim: "RunPod").foregroundStyle(p.ink)
                    Spacer()
                    Text(verbatim: "18h").foregroundStyle(p.toneText(Theme.attention)).fontWeight(.semibold)
                }
            }
            .font(Theme.moneyNameFont)
            .padding(Theme.Panel.padding)
            .frame(width: Theme.Panel.size.width, height: Theme.Panel.size.height, alignment: .topLeading)
            .themedSurface(RoundedRectangle(cornerRadius: Theme.Panel.radius), style: .panel, black: Theme.surface)
        }
    }

    /// A sample on `backdrop` in `theme`, placed as it sits: the island and the pill hang from the top edge, the panel
    /// floats with a margin.
    private func staged<V: View>(_ sample: V, _ backdrop: GlassBackdrop, _ theme: JuiceTheme, size: CGSize, hanging: Bool) -> some View {
        GlassStage(backdrop: backdrop) {
            sample
                .frame(width: size.width, height: size.height, alignment: hanging ? .top : .center)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.juiceTheme, theme)
    }

    static let islandSize = CGSize(width: 520, height: 210)
    static let pillSize = CGSize(width: 300, height: 56)
    static let panelSize = CGSize(width: 410, height: 232)

    // MARK: Renders

    /// The glass themes, as the files name them: Smoke's are Glass's before 2026-09-29, byte for byte.
    nonisolated static let glassThemes: [JuiceTheme] = [.glass, .smoke]

    @Test(arguments: GlassBackdrop.judged, glassThemes)
    func glassOnEachBackdrop(_ backdrop: GlassBackdrop, _ theme: JuiceTheme) throws {
        try RenderHarness.render(staged(IslandSample(), backdrop, theme, size: Self.islandSize, hanging: true),
                                 "th-standin-\(theme.rawValue)-island-\(backdrop.rawValue)")
        try RenderHarness.render(staged(PillSample(), backdrop, theme, size: Self.pillSize, hanging: true),
                                 "th-standin-\(theme.rawValue)-pill-\(backdrop.rawValue)")
        try RenderHarness.render(staged(PanelSample(), backdrop, theme, size: Self.panelSize, hanging: false),
                                 "th-standin-\(theme.rawValue)-panel-\(backdrop.rawValue)")
    }

    /// Black, Glass and Smoke side by side on each backdrop: the island, the pill and the panel.
    @Test func sheet() throws {
        let sheet = VStack(alignment: .leading, spacing: 12) {
            ForEach(GlassBackdrop.judged, id: \.self) { backdrop in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(JuiceTheme.allCases, id: \.self) { theme in
                        VStack(spacing: 8) {
                            staged(IslandSample(), backdrop, theme, size: Self.islandSize, hanging: true)
                            staged(PillSample(), backdrop, theme, size: Self.pillSize, hanging: true)
                        }
                    }
                    ForEach(JuiceTheme.allCases, id: \.self) { theme in
                        staged(PanelSample(), backdrop, theme, size: Self.panelSize, hanging: false)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(white: 0.2))
        try RenderHarness.render(sheet, "th-standin-sheet")
    }

    /// Reduce Transparency and Increase Contrast, on the busy photo and a white window. Smoke: the opaque solid, the
    /// heavier floor and the even rim. Glass: the system's own (P563), stood in for: the frostier opaque ground of the
    /// glass's look, and the stronger shift with the even rim; never our black floor.
    @Test func accessibility() throws {
        for (name, reduce, contrast) in [("reduce-transparency", true, ColorSchemeContrast.standard), ("increase-contrast", false, .increased)] {
            let view = GlassStage(backdrop: .busy) {
                GlassSurfaceBody(shape: IslandShape(), style: .island, rendering: .standIn, reduceTransparency: reduce, contrast: contrast)
                    .frame(width: 480, height: 150)
                    .frame(width: Self.islandSize.width, alignment: .top)
            }
            .frame(width: Self.islandSize.width, height: Self.islandSize.height)
            try RenderHarness.render(view, "th-standin-smoke-island-busy-\(name)")
            for backdrop in [GlassBackdrop.busy, .white] {
                var style = GlassStyle.island.clear
                style.glassFollowsShape = true
                let glass = GlassStage(backdrop: backdrop) {
                    GlassAdaptedStandIn(shape: IslandShape(), style: style, adaptation: backdrop.adaptation, reduceTransparency: reduce,
                                        contrast: contrast)
                        .frame(width: 480, height: 150)
                        .frame(width: Self.islandSize.width, alignment: .top)
                }
                .frame(width: Self.islandSize.width, height: Self.islandSize.height)
                try RenderHarness.render(glass, "th-standin-glass-island-\(backdrop.rawValue)-\(name)")
            }
        }
    }

    // MARK: Settings

    @Test(arguments: JuiceTheme.allCases)
    func settingsIsland(_ theme: JuiceTheme) throws {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = theme
        let env = AppEnvironment.demo(settings: settings)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .island), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "th-settings-island-\(theme.rawValue)", size: CGSize(width: SettingsTheme.Metrics.width, height: height),
                                       env: env)
        try RenderHarness.render(ThemePreview(theme: theme).scaleEffect(3, anchor: .topLeading)
            .frame(width: ThemePreview.size.width * 3, height: ThemePreview.size.height * 3, alignment: .topLeading),
                                 "th-settings-preview-\(theme.rawValue)", env: env)
    }
}
