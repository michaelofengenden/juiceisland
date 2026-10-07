import SwiftUI

/// Settings › Desktop Panel (spec §4.5), one group wired to `DesktopPanelController`; it works in Window and Island
/// mode alike. Use the widget instead first (P1226), only in a build that feeds the widget (P1280): on, the Usage widget
/// takes the panel's place and the pane says in one line how to add it. Beside it, in the same builds, Widget background,
/// what both widgets stand on (P1401): Glass, the system's own, or Black. Off, or in any other build, the panel's own rows:
/// Show on desktop, Lock position, Display (listed only with more than one display), then Position: the corner the panel
/// starts in, beside Reset, which forgets where it was dragged and puts it back in that corner.
struct DesktopPanelPane: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        let displays = PanelDisplays.choices()
        FormPane {
            FormSection(footnote: settings.panelGivesWay ? DesktopPanelText.widgetHint : nil) {
                if settings.widgetFed {
                    FormRow("Use the widget instead") {
                        SettingsSwitch(isOn: Binding(get: { settings.panelUseWidget }, set: { DesktopPanelText.useWidget($0, settings) }),
                                       label: "Use the widget instead")
                    }
                    FormRow("Widget background") {
                        SettingsPopup(selection: $settings.widgetBackground,
                                      options: WidgetBackgroundChoice.allCases.map { ($0, $0.title) }, label: "Widget background")
                    }
                }
                if !settings.panelGivesWay {
                    FormRow("Show on desktop") {
                        SettingsSwitch(isOn: $settings.panelShowOnDesktop, label: "Show on desktop")
                    }
                    FormRow("Lock position") { SettingsSwitch(isOn: $settings.panelLocked, label: "Lock position") }
                    if displays.count > 1 {
                        FormRow("Display") {
                            SettingsPopup(selection: Binding(get: { PanelDisplays.selection(stored: settings.panelDisplay, in: displays) },
                                                             set: { settings.panelDisplay = $0 }),
                                          options: displays, label: "Panel display")
                        }
                    }
                    FormRow("Position") {
                        HStack(spacing: 8) {
                            SettingsPopup(selection: $settings.panelCorner, options: PanelCorner.allCases.map { ($0, $0.title) }, label: "Panel corner")
                            PushButton(title: "Reset") { env.actions.resetPanelPosition() }
                        }
                    }
                }
            }
        }
    }
}

/// The pane's words and its one switch's rule (P1226).
@MainActor
enum DesktopPanelText {
    /// How to put the widget on the desktop: macOS's own way, which the app cannot do for the owner.
    static var widgetHint: String {
        "Right-click the desktop, choose Edit Widgets, then add \(Product.name)'s Usage widget."
    }

    /// Turning Use the widget instead off gives the panel back: shown on the desktop at once.
    static func useWidget(_ on: Bool, _ settings: AppSettings) {
        settings.panelUseWidget = on
        if !on { settings.panelShowOnDesktop = true }
    }
}
