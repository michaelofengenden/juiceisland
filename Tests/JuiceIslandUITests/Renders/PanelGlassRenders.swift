import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The desktop panel and its hover chip in Theme Glass (P530 to P535), headless. Offscreen the window server composites
/// no glass, so the glass here is the render stand-in (`GlassRendering.standIn`: the backdrop, drawn in code, blurred in
/// the panel's shape under the same floor and rim as the live glass), named `th-standin-desktop-*` so no one takes it for
/// a screenshot. Each panel sits in its window's 24 pt margin over a white, a black and a busy photo wallpaper.
@MainActor
@Suite(.serialized)
struct PanelGlassRenders {
    static let window = CGSize(width: 410, height: 232)

    /// `view` over `backdrop` in `theme`, `size` large.
    static func staged<V: View>(_ view: V, _ backdrop: GlassBackdrop, _ theme: JuiceTheme, size: CGSize) -> some View {
        GlassStage(backdrop: backdrop) {
            view.frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.juiceTheme, theme)
    }

    /// Every battery state on one panel, with the demo money: 100 (every digit on the fill), 57 and Next, 8 low (amber),
    /// used up, stale, sign in; signing in, not known, No plan, 45 (a digit across the edge), 4 low.
    static func statesContent(_ env: AppEnvironment) -> DesktopPanelContent {
        let now = env.usage.now
        func battery(_ id: String, _ state: AccountState, next: Bool = false) -> BatteryModel {
            BatteryModel(id: id, alias: id, state: state, isNext: next, hoverLabel: id)
        }
        func row(_ provider: Provider, _ batteries: [BatteryModel]) -> ProviderRowModel {
            ProviderRowModel(provider: provider, batteries: batteries, availability: Rules.availability(states: batteries.map(\.state)),
                             nextAlias: batteries.first { $0.isNext }?.alias, oldestReadingAge: nil, hoverLabel: provider.displayName)
        }
        let claude = row(.claude, [
            battery("c1", .available(percentLeft: 100, isLow: false)), battery("c2", .available(percentLeft: 57, isLow: false), next: true),
            battery("c3", .available(percentLeft: 8, isLow: true)), battery("c4", .usedUp(refill: now.addingTimeInterval(2 * 3600 + 300))),
            battery("c5", .stale(lastPercentLeft: 40)), battery("c6", .signInNeeded),
        ])
        let codex = row(.codex, [
            battery("x1", .signingIn), battery("x2", .unknown), battery("x3", .noPlan), battery("x4", .available(percentLeft: 45, isLow: false)),
            battery("x5", .available(percentLeft: 4, isLow: true)),
        ])
        let money = env.usage.shownMoney(env.settings)
        return DesktopPanelContent(rows: [claude, codex], money: money, now: now,
                                   size: PanelGeometry.panelSize(providerRows: 2, showsMoney: true, moneyCount: money.count))
    }

    static func statesPanel(_ env: AppEnvironment) -> some View {
        let content = statesContent(env)
        return DesktopPanelBody(content: content, size: content.size ?? Theme.Panel.size).padding(PanelGeometry.margin)
    }

    // MARK: Renders

    /// The glass themes, as the files name them: Smoke's are Glass's before 2026-09-29, byte for byte.
    nonisolated static let glassThemes: [JuiceTheme] = [.glass, .smoke]

    /// The demo panel (six Claude and five Codex batteries, five money sources) on glass over each wallpaper.
    @Test(arguments: GlassBackdrop.judged, glassThemes)
    func panel(_ backdrop: GlassBackdrop, _ theme: JuiceTheme) throws {
        try RenderHarness.render(Self.staged(DesktopPanelView().padding(PanelGeometry.margin), backdrop, theme, size: Self.window),
                                 "th-standin-\(theme.rawValue)-desktop-panel-\(backdrop.rawValue)", size: Self.window)
    }

    /// Every battery state on glass over each wallpaper, and the battery rows at 6x: the cut digits and the stale slash
    /// show the glass, never a black mark.
    @Test(arguments: GlassBackdrop.judged, glassThemes)
    func everyState(_ backdrop: GlassBackdrop, _ theme: JuiceTheme) throws {
        let env = AppEnvironment.demo()
        try RenderHarness.render(Self.staged(Self.statesPanel(env), backdrop, theme, size: Self.window),
                                 "th-standin-\(theme.rawValue)-desktop-panel-states-\(backdrop.rawValue)", size: Self.window, env: env)
        let rows = CGSize(width: 390, height: 110)
        let zoom = Self.staged(Self.statesPanel(env), backdrop, theme, size: Self.window)
            .frame(width: rows.width, height: rows.height, alignment: .topLeading)
            .clipped()
            .environment(env)
        try RenderHarness.renderPixels(zoom, "th-standin-\(theme.rawValue)-desktop-batteries-\(backdrop.rawValue)-6x", scale: 6)
    }

    /// The hover chip beside the panel on each wallpaper, as `P-panel-hover` draws it in Black.
    @Test(arguments: GlassBackdrop.judged, glassThemes)
    func hoverChip(_ backdrop: GlassBackdrop, _ theme: JuiceTheme) throws {
        let env = AppEnvironment.demo()
        let row = try #require(env.usage.claudeRow)
        let size = CGSize(width: 410, height: 232 + 52)
        let view = VStack(alignment: .trailing, spacing: 0) {
            PanelHoverLabelView(text: row.hoverLabel).fixedSize()
            DesktopPanelView().padding(PanelGeometry.margin)
        }
        try RenderHarness.render(Self.staged(view, backdrop, theme, size: size), "th-standin-\(theme.rawValue)-desktop-chip-\(backdrop.rawValue)",
                                 size: size, env: env)
    }

    /// Black, Glass and Smoke side by side on each wallpaper, the demo panel and every state.
    @Test func sheet() throws {
        let env = AppEnvironment.demo()
        let sheet = VStack(alignment: .leading, spacing: 12) {
            ForEach(GlassBackdrop.judged, id: \.self) { backdrop in
                HStack(spacing: 12) {
                    ForEach(JuiceTheme.allCases, id: \.self) { theme in
                        Self.staged(DesktopPanelView().padding(PanelGeometry.margin), backdrop, theme, size: Self.window)
                    }
                    ForEach(JuiceTheme.allCases, id: \.self) { theme in
                        Self.staged(Self.statesPanel(env), backdrop, theme, size: Self.window)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(white: 0.2))
        try RenderHarness.render(sheet, "th-standin-desktop-panel-sheet", env: env)
    }

    /// The money's red and amber runways and a source that cannot be read, on the busy photo.
    @Test(arguments: [DemoUsageModel.Variant.runway18h, .runway60h, .hetznerNoKey], glassThemes)
    func money(_ variant: DemoUsageModel.Variant, _ theme: JuiceTheme) throws {
        let env = AppEnvironment.demo(usage: variant)
        try RenderHarness.render(Self.staged(DesktopPanelView().padding(PanelGeometry.margin), .busy, theme, size: Self.window),
                                 "th-standin-\(theme.rawValue)-desktop-panel-busy-\(variant)", size: Self.window, env: env)
    }
}
