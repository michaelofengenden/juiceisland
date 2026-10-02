import AppKit
import IslandEngine
import JuiceCore
import SwiftUI

/// Settings › Diagnostics (prototype L1716-1727, spec §4.5): bridge, floors and jumps in one group, the Accounts,
/// Money and Hooks tables, then the build line with Refresh All and Copy Report (redacted). Where the usage cannot be
/// read from here (demo data, Juice's readings, standalone Juice running), Refresh All is left out and the Accounts
/// table's note says why. The CLIs' versions have no row until the app reads them: a fixed stand-in said wrong ones
/// (P120). Owner: stream A.
struct DiagnosticsPane: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme
    @State private var copied = false

    /// The widest a row's value may be: the row in the Settings window, less its label.
    static let valueWidth: CGFloat = 400

    var body: some View {
        let usage = env.usage
        @Bindable var settings = env.settings
        let motions = env.motionLog.entries
        // One row per login, as the batteries are (P360): its folders' aliases, its battery's state, the scheduler's next
        // read; then the folders no login row lists.
        let accountLines = DiagnosticsText.accounts(usage.logins, records: usage.records, schedule: { usage.schedule(of: $0) },
                                                    question: { usage.question(forFolder: $0) }, now: usage.now)
        let moneyLines = usage.panel.money.map { row in
            let detail = usage.moneyDetails[row.id]
            let line = DiagnosticsText.money(id: row.id, readable: detail?.isReadable ?? (row.amount != nil))
            return (row, (next: detail?.nextRead ?? line.next, status: detail?.status ?? line.status))
        }
        let moneyRequests = usage.panel.money.flatMap { usage.moneyDetails[$0.id]?.requests ?? [] }
        // The bridge and the last jump are the live engine's; demo data and renders have none, and show no row for
        // them.
        let live = env.liveSessions
        let engine = live?.mode == .live ? live?.engine : nil
        let bridge = live.map { live in
            DiagnosticsText.bridge(switchOn: live.settings.liveSessions, live: live.mode == .live, refusal: live.refusal,
                                   health: engine?.bridgeHealth ?? .off, takenBackAt: engine?.bridgeTakenBackAt,
                                   notesProblem: engine?.hookNotesProblem, now: usage.now)
        }
        let lastJump = engine?.recentJumps.first.map { DiagnosticsText.jump($0, now: usage.now) }
        let attention = engine.flatMap { DiagnosticsText.attention($0.attentionTally) }
        let attentionDetails = engine.flatMap { DiagnosticsText.attentionDetails($0.attentionTally) }
        VStack(alignment: .leading, spacing: 0) {
            FormPane {
                FormSection {
                    if let bridge {
                        // A refusal can be long (a start failure in macOS's words): two lines at most, beside the label
                        // and never wider than the row leaves it, the whole of it on hover.
                        FormRow("Bridge") {
                            MonoText(bridge, lines: 2).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: Self.valueWidth, alignment: .trailing).layoutPriority(1).help(bridge)
                        }
                    }
                    FormRow("Floors") {
                        MonoText(DiagnosticsText.floorsLine, lines: 2).multilineTextAlignment(.trailing).fixedSize()
                    }
                    if let lastJump { FormRow("Last jump") { MonoText(lastJump).fixedSize() } }
                    if let attention {
                        FormRow("Needs you") {
                            MonoText(attention, lines: 2).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: Self.valueWidth, alignment: .trailing).layoutPriority(1).help(attention)
                        }
                    }
                }
                FormSection("Accounts", footnote: usage.refreshUnavailableReason) {
                    DiagnosticsTable(headers: ["Account", "Last read", "Next", "Status"], rows: accountLines.map { entry in
                        DiagnosticsTable.Row(id: entry.id, icon: AnyView(ProviderMarkView(provider: entry.provider, size: 12, theme: theme)),
                                             cells: [entry.label, entry.line.lastRead, entry.line.next, entry.line.status], tone: entry.line.tone)
                    })
                }
                FormSection("Money") {
                    DiagnosticsTable(headers: ["Source", "Last read", "Next", "Status"], rows: moneyLines.map { row, line in
                        DiagnosticsTable.Row(id: row.id, icon: AnyView(MoneySourceTile(id: row.id, size: 12)),
                                             cells: [row.name, usage.moneyDetails[row.id]?.lastRead ?? "never", line.next, line.status], tone: .normal)
                    })
                    if !moneyRequests.isEmpty {
                        FormRow("Requests") {
                            MonoText(moneyRequests.joined(separator: "\n"), lines: moneyRequests.count).multilineTextAlignment(.trailing)
                        }
                    }
                }
                // With the Bridge row saying Open Island runs, the Hooks footnote does not say it again.
                DiagnosticsHooksSection(openIslandSaid: bridge == LiveSessions.refusalText(for: SessionEngineError.otherIslandRunning))
                // The island's motion as this display shows it, and the 120 Hz vote: both off, and nothing runs at rest;
                // and who draws the outline.
                FormSection("Motion", footnote: settings.recordIslandMotion ? DiagnosticsText.motionFolder : nil) {
                    FormRow("Record island motion") {
                        SettingsSwitch(isOn: $settings.recordIslandMotion, label: "Record island motion")
                    }
                    FormRow("Ask for 120 Hz while moving") {
                        SettingsSwitch(isOn: $settings.paceIslandMotion, label: "Ask for 120 Hz while moving")
                    }
                    // Who draws the island's black outline: SwiftUI on the main thread, or Core Animation from the model's
                    // plan in the render server. Applied once the island rests.
                    FormRow("Outline") {
                        SettingsSegmented(selection: $settings.islandOutline,
                                          options: [(.swiftUI, "SwiftUI"), (.coreAnimation, "Core Animation")], label: "Island outline")
                    }
                    if !motions.isEmpty {
                        DiagnosticsTable(headers: ["Last motions", "fps", "Jobs late", "Hitches"], rows: motions.map { entry in
                            let line = DiagnosticsText.motion(entry)
                            return DiagnosticsTable.Row(id: "\(entry.id)", icon: AnyView(EmptyView()), cells: line.cells, tone: line.tone)
                        })
                    }
                }
            }
            // The build line and the two actions share the pane's last line, so no row holds buttons alone.
            HStack(spacing: 8) {
                Text(DiagnosticsText.shortBuildLine(env.updateChecker.stamp))
                    .font(Fonts.mono(11))
                    .foregroundStyle(SettingsTheme.ink3)
                    .lineLimit(1)
                    .padding(.leading, 10)
                Spacer(minLength: 0)
                if usage.refreshUnavailableReason == nil {
                    PushButton(title: "Refresh All") { usage.refreshAll() }
                }
                PushButton(title: copied ? "Copied" : "Copy Report") { copyReport(accountLines, moneyLines, bridge: bridge, attention: attention,
                                                                                   details: attentionDetails) }
            }
            .padding(.top, 12)
        }
    }

    private func copyReport(_ accounts: [DiagnosticsText.AccountEntry], _ money: [(MoneyRowModel, (next: String, status: String))],
                            bridge: String?, attention: String?, details: String?) {
        let text = DiagnosticsText.report(lines: accounts.map { ($0.label, $0.provider, $0.line) }, money: money.map { ($0.0.name, $0.1.status) },
                                          bridge: bridge, attention: attention, attentionDetails: details, stamp: env.updateChecker.stamp)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}

/// The four-column table (`1.2fr .8fr .7fr 1.5fr`, 12.5 pt; header 600 11 grey; rows padding 5 12, full-width
/// separators above each row).
struct DiagnosticsTable: View {
    struct Row: Identifiable {
        var id: String
        var icon: AnyView
        var cells: [String]
        var tone: DiagnosticsText.Tone
    }

    let headers: [String]
    let rows: [Row]
    static let weights: [CGFloat] = [1.2, 0.8, 0.7, 1.5]

    var body: some View {
        GeometryReader { proxy in
            let widths = Self.columnWidths(total: proxy.size.width)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(headers.indices, id: \.self) { index in
                        Text(headers[index]).font(Fonts.sys(11, .semibold)).foregroundStyle(SettingsTheme.ink2)
                            .padding(EdgeInsets(top: 9, leading: 12, bottom: 5, trailing: 12))
                            .frame(width: widths[index], alignment: .leading)
                    }
                }
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        ForEach(row.cells.indices, id: \.self) { index in
                            HStack(spacing: 7) {
                                if index == 0 { row.icon }
                                Text(row.cells[index]).font(Fonts.sys(12.5)).lineLimit(1).truncationMode(.tail)
                                    .foregroundStyle(index == 3 ? Self.colour(row.tone) : SettingsTheme.ink)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .frame(width: widths[index], alignment: .leading)
                        }
                    }
                    .overlay(alignment: .top) { SettingsTheme.separator.frame(height: 1) }
                }
            }
        }
        .frame(height: Self.height(rows: rows.count))
    }

    static func colour(_ tone: DiagnosticsText.Tone) -> Color {
        switch tone {
        case .normal: SettingsTheme.ink2
        case .amber: SettingsTheme.statusAmber
        case .red: SettingsTheme.statusRed
        }
    }

    /// Fractional columns over the group's width.
    static func columnWidths(total: CGFloat) -> [CGFloat] {
        let sum = weights.reduce(0, +)
        return weights.map { total * $0 / sum }
    }

    /// Header 9 + 14 + 5; each row 5 + 15.5 + 5 (12.5 pt text) + 1 separator.
    static func height(rows: Int) -> CGFloat { 28 + CGFloat(rows) * 25.5 }
}
