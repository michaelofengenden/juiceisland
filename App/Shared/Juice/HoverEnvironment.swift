import SwiftUI

struct HoverTarget: Equatable, Sendable {
    var id: String
    var label: String
    /// True when the pointer left this target instead of arriving on it. SwiftUI does not promise that one target's
    /// exit arrives before the next one's enter, so an exit has to name itself for the controller to drop it when stale.
    var isExit: Bool = false

    /// The same target, reported as the pointer leaving it.
    var leaving: HoverTarget { HoverTarget(id: id, label: label, isExit: true) }
}

private struct HoverReporterKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (HoverTarget?) -> Void = { _ in }
}

extension EnvironmentValues {
    var hoverReporter: @MainActor @Sendable (HoverTarget?) -> Void {
        get { self[HoverReporterKey.self] }
        set { self[HoverReporterKey.self] = newValue }
    }
}

extension View {
    /// Reports the pointer resting on or leaving one panel target.
    func hoverTarget(id: String, label: String) -> some View {
        modifier(HoverTargetModifier(target: HoverTarget(id: id, label: label)))
    }
}

private struct HoverTargetModifier: ViewModifier {
    @Environment(\.hoverReporter) private var report
    let target: HoverTarget

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { inside in report(inside ? target : target.leaving) }
    }
}
