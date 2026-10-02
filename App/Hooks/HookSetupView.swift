import JuiceCore
import IslandEngine
import SwiftUI

/// Settings › Setup (spec §4.5; P19 to P27): one row per profile with its hook state and the one button a click may
/// use (Install, Repair or Remove), or the reason it is unavailable, in a few words. Nothing installs, repairs or
/// removes without a click here or on a drift row.
struct HookSetupView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let hooks = env.hooks
        let rows = hooks.rows
        let claude = rows.filter { $0.provider == .claude }
        let codex = rows.filter { $0.provider == .codex }
        let integrations = hooks.integrations
        FormPane {
            if let helper = hooks.helperUpdate {
                FormSection("Hook helper") {
                    FormRow("Older than this build") {
                        if case let .refused(reason) = helper {
                            SetupStatusWord(reason, amber: true)
                        } else {
                            PushButton(title: helper == .updating ? "…" : "Update", blue: true, small: true) { hooks.updateHelper() }
                                .disabled(helper != .available)
                                .help("Replace the hook helper with this build's; no hook settings change")
                        }
                    }
                }
            }
            if !claude.isEmpty {
                FormSection("Claude Code") {
                    ForEach(claude) { HookSetupRowView(row: $0) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if !codex.isEmpty {
                    FormSection("Codex") {
                        ForEach(codex) { HookSetupRowView(row: $0) }
                    }
                }
                // Only while a monitored profile can be installed now; it never repairs (P20).
                if !hooks.installableMonitoredRows.isEmpty {
                    HStack {
                        Spacer(minLength: 0)
                        PushButton(title: "Install All", blue: true) { hooks.installAllMonitored() }
                            .help("Install for every monitored account")
                    }
                }
            }
            if let openCode = hooks.openCodeRow {
                FormSection("OpenCode") {
                    OpenCodeSetupRowView(row: openCode)
                }
            }
            RemoteHostsSection()
            // Other apps, read-only, and only while one of them holds the buttons up.
            if integrations.openIslandRunning || integrations.vibeProfiles > 0 || !integrations.helperInBuild {
                FormSection("Other apps") {
                    if integrations.openIslandRunning {
                        FormRow("Open Island") { SetupStatusWord("Running") }
                    }
                    if integrations.vibeProfiles > 0 {
                        FormRow("Vibe Island") {
                            SetupStatusWord("Hooks in \(integrations.vibeProfiles) profile\(integrations.vibeProfiles == 1 ? "" : "s")")
                        }
                    }
                    if !integrations.helperInBuild {
                        FormRow("Hook helper") { SetupStatusWord("Missing from this build", amber: true) }
                    }
                }
            }
        }
        .task { hooks.refreshOpenCode() }
    }
}

/// One profile: mark, alias and folder; the state word and its detail; the button, or why it is unavailable.
struct HookSetupRowView: View {
    let row: HookSetupRow
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        let refusal = row.refusal ?? env.hooks.clickRefusal(for: row.id)
        HStack(spacing: 10) {
            ProviderMarkView(provider: row.provider, size: 16, theme: theme)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.alias).font(Fonts.sys(13, .medium)).foregroundStyle(SettingsTheme.ink).lineLimit(1)
                MonoText(row.folder)
            }
            .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.word).font(Fonts.sys(12.5))
                    .foregroundStyle(row.tone == .amber ? SettingsTheme.statusAmber : SettingsTheme.ink2)
                if let detail = row.detail {
                    Text(detail).font(Fonts.sys(11)).foregroundStyle(SettingsTheme.ink2).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // A refused profile shows its reason and no button. Install and Repair are blue; Remove stays quiet so the
            // rows that need a click stand out.
            if let refusal, !row.busy {
                if refusal != row.word {
                    Text(refusal).font(Fonts.sys(11)).foregroundStyle(SettingsTheme.ink3).lineLimit(2)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 170, alignment: .trailing)
                }
            } else if let title = row.buttonTitle {
                PushButton(title: row.busy ? "…" : title, blue: row.action != .remove, quiet: row.action == .remove,
                           small: true) {
                    if let action = row.action { env.hooks.perform(action, on: row.id) }
                }
                .disabled(!row.canClick)
                .help(title)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 46)
    }
}

/// A grey status word, as Setup's rows write theirs; amber for a problem.
private struct SetupStatusWord: View {
    let text: String
    var amber = false
    init(_ text: String, amber: Bool = false) {
        self.text = text
        self.amber = amber
    }

    var body: some View {
        Text(text).font(Fonts.sys(12.5)).foregroundStyle(amber ? SettingsTheme.statusAmber : SettingsTheme.ink2)
    }
}
