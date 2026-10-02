import Observation

/// The selected Settings pane. The Settings window controller owns one; `openSettings(_:)` sets it.
@MainActor
@Observable
final class SettingsNavigation {
    var pane: SettingsPane = .general
    init(pane: SettingsPane = .general) { self.pane = pane }
}
