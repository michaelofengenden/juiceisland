import SwiftUI

/// Settings › Desktop Panel (spec §4.5), one group wired to `DesktopPanelController`; it works in Window and Island
/// mode alike. Show on desktop, Lock position, Display (listed only with more than one display), then Position: the
/// corner the panel starts in, beside Reset, which forgets where it was dragged and puts it back in that corner.
struct DesktopPanelPane: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        let displays = PanelDisplays.choices()
        FormPane {
            FormSection {
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
