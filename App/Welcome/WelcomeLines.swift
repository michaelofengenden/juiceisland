import SwiftUI

/// "2 new agents can connect · Connect" (P966): after an update that can connect agents the last build could not, one
/// line in the window under the header and in the island under its header, as What's new is. Connect connects those
/// agents (each file backed up first) on this click; ✕ lets them be. Nothing once none of them is found here and
/// unconnected.
struct NewAgentsLine: View {
    var size: HookDriftRows.Size = .window
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        let ids = env.settings.newAgents
        let shown = ids.isEmpty ? [] : NewAgents.shown(ids, rows: env.agents.rows)
        if !shown.isEmpty {
            let font = Fonts.sys(size == .window ? 12 : 11)
            let palette = theme.island
            HStack(spacing: 6) {
                Circle().fill(palette.tone(WhatsNewCard.blue)).frame(width: 6, height: 6)
                Text(NewAgents.line(shown.count)).font(font).foregroundStyle(HookDriftLine.text(theme)).lineLimit(1)
                    .help(shown.map(\.name).joined(separator: ", "))
                Text("·").font(font).foregroundStyle(HookDriftLine.dot(theme))
                Button {
                    for row in shown { env.agents.perform(.connect, on: row.id) }
                    env.settings.newAgents = []
                } label: {
                    Text("Connect").font(font.weight(.semibold)).foregroundStyle(palette.toneText(WhatsNewCard.blue))
                }
                .buttonStyle(.plain)
                .help("Connect \(shown.map(\.name).joined(separator: ", ")); each file is backed up first")
                Spacer(minLength: 8)
                Button { env.settings.newAgents = [] } label: {
                    CrossIcon(colour: HookDriftLine.dot(theme)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
            }
            .padding(size == .window ? EdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 18)
                                     : EdgeInsets(top: 2, leading: 8, bottom: 4, trailing: 4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if size == .window { WindowTheme.hairline.frame(height: 1) }
            }
        }
    }
}

/// With no session at all, the list says where to start: "Start an agent", and Connect while no agent is connected yet,
/// which opens Settings › Agents (P965).
struct NoSessionsLine: View {
    var size: HookDriftRows.Size = .island
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme

    /// Nothing is connected: no folder, plugin or agent says Connected (or waits on Codex's trust). Before the files are
    /// read nothing is said, so Connect never flashes at launch.
    static func nothingConnected(_ rows: [AgentRow]) -> Bool {
        guard !rows.contains(where: { $0.status == .checking }) else { return false }
        return !rows.contains { row in
            AgentRowText.isConnected(row.status) || row.profiles.contains { AgentRowText.isConnected(AgentRowText.profileStatus($0, helperPath: "")) }
        }
    }

    var body: some View {
        let palette = theme.island
        let font = size == .island ? Fonts.sys(11) : Fonts.sys(12, .medium)
        HStack(spacing: 6) {
            Text("Start an agent").font(font).foregroundStyle(palette.ink3)
            if Self.nothingConnected(env.agents.rows) {
                Text("·").font(font).foregroundStyle(palette.ink3)
                Button { env.actions.openSettings(.agents) } label: {
                    Text("Connect").font(font.weight(.semibold)).foregroundStyle(palette.toneText(WhatsNewCard.blue))
                }
                .buttonStyle(.plain)
                .help("Connect your agents in Settings › Agents")
            }
        }
    }
}
