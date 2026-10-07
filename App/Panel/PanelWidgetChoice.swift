import WidgetKit

/// Settings › Desktop Panel › Use the widget instead, decided once by the first launch that feeds the widget (P1281).
/// WidgetKit cannot tell a widget on the desktop from one in Notification Center (P1226), but it can tell whether a
/// Usage widget is placed at all: the switch turns on only then, so the owner's widget, which kept its kind (P1220), takes
/// the panel's place, and an update never hides the panel of someone who never added the widget. The answer is kept, and
/// from then on the switch is the owner's. No answer (WidgetKit could not say) leaves it unset for the next launch. The
/// panel starts after the answer, so it never shows for a moment before a placed widget hides it, but never later than
/// `patience`; an answer that comes later still decides.
@MainActor
enum PanelWidgetChoice {
    /// The kinds of this app's widgets placed now, or nil when WidgetKit could not say.
    typealias Placed = @MainActor () async -> [String]?

    /// Decides the switch where it is unset in a build that feeds the widget, then calls `start` once; anywhere else
    /// calls it at once. The decision's task, for tests to wait on.
    @discardableResult
    static func settle(_ settings: AppSettings, placed: @escaping Placed = Self.placed, patience: Duration = .seconds(3),
                       then start: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard settings.widgetFed, !settings.panelUseWidgetSet else {
            start()
            return nil
        }
        let gate = Gate(start)
        Task { @MainActor in
            try? await Task.sleep(for: patience)
            gate.open()
        }
        return Task { @MainActor in
            let kinds = await placed()
            if let kinds, !settings.panelUseWidgetSet {
                settings.panelUseWidget = kinds.contains(WidgetKind.usage.rawValue)
            }
            gate.open()
        }
    }

    /// WidgetKit's list of this app's placed widgets, by kind. It only reads: nothing is reloaded.
    static func placed() async -> [String]? {
        try? await WidgetCenter.shared.currentConfigurations().map(\.kind)
    }

    /// Calls its start once, whichever opens it first.
    private final class Gate {
        private var start: (@MainActor () -> Void)?
        init(_ start: @escaping @MainActor () -> Void) { self.start = start }
        @MainActor func open() {
            let start = start
            self.start = nil
            start?()
        }
    }
}
