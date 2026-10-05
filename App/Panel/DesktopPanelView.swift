import JuiceCore
import SwiftUI

/// The desktop panel (Juice spec §2, unchanged per the Juice Island spec's §4.3): the black capsule with a Claude row,
/// a Codex row and the money, drawn from `DesktopPanelContent`. It only draws: no state, no timers, no reads. Every
/// word is in the hover labels (`hoverReporter`) and the right-click menus (`panelActions`, `PanelMenu`). Nothing
/// animates (§2.6, amendment 4).
struct DesktopPanelView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let content = DesktopPanelContent.make(usage: env.usage, settings: env.settings, inUse: env.accountsInUse)
        if let size = content.size {
            DesktopPanelBody(content: content, size: size)
                .contextMenu { PanelBackgroundMenu() }
                .transaction { $0.animation = nil }
        }
    }
}

/// The capsule itself, from plain values (renders use it directly), on its surface in the environment's theme
/// (`PanelSurface`: Black's black, or glass).
struct DesktopPanelBody: View {
    typealias P = Theme.Panel

    let content: DesktopPanelContent
    let size: CGSize
    @Environment(\.juiceTheme) private var theme
    /// Drawing the copy that casts Widget's full-colour ink shadow (P1206): the divider, a veil, casts none.
    @Environment(\.inkShadowPass) private var shadowPass
    private var palette: PanelPalette { theme.panel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(content.rows.enumerated()), id: \.element.id) { index, row in
                PanelProviderRow(row: row, now: content.now, theme: theme, inUse: content.inUse)
                    .padding(.top, index == 0 ? 0 : P.rowGap)
            }
            if !content.money.isEmpty {
                if !content.rows.isEmpty {
                    Rectangle()
                        .fill(shadowPass ? .clear : palette.divider)
                        .frame(height: 1)
                        .padding(.top, P.dividerAbove)
                        .padding(.bottom, P.dividerBelow)
                }
                MoneyRowsView(rows: content.money, width: size.width - 2 * P.padding, palette: palette)
            }
            Spacer(minLength: 0)
        }
        .padding(P.padding)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .modifier(PanelSurface(radius: P.radius))
        .contentShape(RoundedRectangle(cornerRadius: P.radius))
    }
}

/// One provider: its 20 pt mark, 10 pt, then its batteries in the owner's order, an account in use with its dot (P814).
struct PanelProviderRow: View {
    let row: ProviderRowModel
    var now: Date
    /// The panel's theme, passed down for the mark (P559).
    var theme = JuiceTheme.black
    var inUse = AccountsInUse.none

    var body: some View {
        HStack(spacing: Theme.Panel.markGap) {
            ProviderMarkView(provider: row.provider, size: Theme.Panel.markSize, theme: theme)
                .accessibilityLabel(row.hoverLabel)
                .hoverTarget(id: "mark:\(row.provider.rawValue)", label: row.hoverLabel)
            PanelBatteryRun(batteries: row.batteries, now: now, inUse: inUse)
            Spacer(minLength: 0)
        }
        .frame(height: Theme.Panel.rowHeight)
    }
}

/// A row's batteries, 6 pt apart: six Claude batteries take their 300 pt exactly, five Codex batteries 249 pt
/// (amendment 12).
struct PanelBatteryRun: View {
    let batteries: [BatteryModel]
    var now: Date
    var inUse = AccountsInUse.none
    /// Read once for the row and passed to its batteries (`BatteryView.glass`, P559).
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        HStack(spacing: Theme.Battery.gap) {
            ForEach(batteries) { battery in
                BatteryView(battery: battery, now: now, theme: theme, inUse: inUse.contains(battery.id))
            }
        }
    }
}

/// Right-click on the panel's background (batteries and money rows raise their own menus).
private struct PanelBackgroundMenu: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ForEach(Array(PanelMenu.items(usage: env.usage, settings: env.settings).enumerated()), id: \.offset) { _, item in
            if let item {
                Button(item.title) { PanelMenu.perform(item.action, env: env) }
                    .disabled(!item.isEnabled)
            } else {
                Divider()
            }
        }
    }
}

/// The window's content: the panel inside its 24 pt shadow margin, pinned to the bottom so a panel that shrinks
/// (money switched off) keeps its place while the window follows.
///
/// It takes the desktop widgets' look of the moment (`widgets`, P1204): Glass look Widget draws the panel as macOS draws its
/// widgets beside it, full colour while the desktop is in front and dimmed while an app is (P1214). Without a watch (renders,
/// previews) it draws Widget as the island does.
struct DesktopPanelRootView: View {
    let actions: PanelActions
    let hover: @MainActor @Sendable (HoverTarget?) -> Void
    var widgets: DesktopWidgetWatch?

    var body: some View {
        DesktopPanelView()
            .padding(PanelGeometry.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .environment(\.panelActions, actions)
            .environment(\.hoverReporter, hover)
            .environment(\.widgetGlassState, widgets?.state ?? .overApps)
            .modifier(DesktopPanelInkScheme())
    }
}

/// The panel root's ink scheme from its theme (`PanelInkScheme`).
private struct DesktopPanelInkScheme: ViewModifier {
    @Environment(\.juiceTheme) private var theme

    func body(content: Content) -> some View { content.modifier(PanelInkScheme(theme: theme)) }
}
