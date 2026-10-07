import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Wave 5's two lanes on one Mac, headless, every file named `w5i-*`: Settings › Desktop Panel as the owner's installed
/// app opens it, a build that feeds the widget with a Usage widget placed (P1226, P1281): Use the widget instead on, the
/// panel's own rows gone and the one line that says how to add the Usage widget; and the same build with no widget
/// placed, the switch off over the panel's rows. `P-settings-panel` is a build that cannot feed the widget: the panel's
/// rows alone, no switch (P1280). Widget background shows beside the switch in a build that feeds the widget (P1401).
@MainActor
@Suite(.serialized)
struct Wave5CrossLaneRenders {
    @Test(arguments: [true, false])
    func desktopPanelPaneInABuildThatFeedsTheWidget(_ placed: Bool) throws {
        let settings = AppSettings.ephemeral()
        settings.widgetFed = true
        settings.panelUseWidget = placed
        let environment = AppEnvironment.demo(settings: settings)
        #expect(settings.panelShown == !placed)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .desktopPanel), drawsTrafficLights: true, scrolls: false)
        try RenderHarness.renderHosted(view, placed ? "w5i-settings-panel-widget" : "w5i-settings-panel-fed-off",
                                       size: CGSize(width: SettingsTheme.Metrics.width, height: SettingsTheme.Metrics.minHeight),
                                       env: environment)
    }
}
