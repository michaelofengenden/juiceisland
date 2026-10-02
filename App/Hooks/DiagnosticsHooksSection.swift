import SwiftUI

/// Diagnostics › Hooks (spec §4.5): per profile, our entries against the expected set, the last hook event the live
/// engine saw, and Setup's state word (drift, feature and trust included); one line for the helper and the other
/// island apps under it, which leaves Open Island out when the Bridge row already says it runs (`openIslandSaid`).
struct DiagnosticsHooksSection: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme
    var openIslandSaid = false

    var body: some View {
        let hooks = env.hooks
        let events = hooks.lastEvents
        let now = env.sessions.now
        FormSection("Hooks", footnote: HookRowText.integrationsLine(hooks.integrations, openIslandSaid: openIslandSaid)) {
            DiagnosticsTable(headers: ["Profile", "Events", "Last event", "Status"], rows: hooks.rows.map { row in
                DiagnosticsTable.Row(id: row.id, icon: AnyView(ProviderMarkView(provider: row.provider, size: 12, theme: theme)),
                                     cells: [row.alias, row.events,
                                             events[row.id].map { DiagnosticsText.age(now.timeIntervalSince($0)) } ?? "never",
                                             Self.state(row)],
                                     tone: row.tone == .amber ? .amber : .normal)
            })
        }
    }

    /// The state word, or for a drifted profile what is missing (Events already shows the count).
    static func state(_ row: HookSetupRow) -> String {
        if let detail = row.detail, detail.hasPrefix("Missing ") { return detail }
        return row.word
    }
}
