import SwiftUI

/// The Settings window's content: the full-height sidebar column (traffic lights at its top) and the detail (the pane's
/// title on the traffic lights' line, then the scrolling pane, padding 0 22 22), in the window's colour scheme, which
/// is Settings › General › Appearance's (P763). Owner: stream A.
struct SettingsRootView: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var navigation: SettingsNavigation
    /// Headless renders draw static traffic lights where AppKit's own buttons sit.
    var drawsTrafficLights = false
    /// Renders lay the pane out at full height instead of scrolling it.
    var scrolls = true

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(navigation: navigation, drawsTrafficLights: drawsTrafficLights)
            VStack(alignment: .leading, spacing: 0) {
                Text(navigation.pane.title)
                    .font(SettingsTheme.TypeScale.title)
                    .foregroundStyle(SettingsTheme.ink)
                    .frame(height: SettingsTheme.Metrics.titleBarHeight)
                    .padding(.horizontal, 22)
                if scrolls {
                    ScrollView { pane }.scrollIndicators(.automatic)
                } else {
                    // At its ideal height, as the ScrollView lays it out; otherwise the Spacer takes half the room and
                    // every row shrinks to its 38 pt minimum.
                    pane.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: SettingsTheme.Metrics.width)
        .frame(minHeight: SettingsTheme.Metrics.minHeight, maxHeight: .infinity, alignment: .top)
        .background(SettingsTheme.window)
        .ignoresSafeArea()
        .foregroundStyle(SettingsTheme.ink)
        // The shared views' tokens for the window's look: Black's where it is dark, as they always were (P763).
        .opaqueTokensForLook()
    }

    private var pane: some View {
        SettingsPaneView(pane: navigation.pane)
            .padding(SettingsTheme.Metrics.panePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// One pane by name. Owner: stream A.
struct SettingsPaneView: View {
    let pane: SettingsPane

    var body: some View {
        switch pane {
        case .general: GeneralPane()
        case .island: IslandPane()
        case .sound: SoundPane()
        case .shortcuts: ShortcutsPane()
        case .accounts: AccountsPane()
        case .money: MoneyPane()
        case .desktopPanel: DesktopPanelPane()
        case .diagnostics: DiagnosticsPane()
        case .setup: SetupPane()
        case .about: AboutPane()
        }
    }
}
