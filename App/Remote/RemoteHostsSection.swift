import IslandEngine
import SwiftUI

/// Settings › Agents › SSH hosts (P751): one row per host, then the add row: a field for `user@host` or a `Host` from
/// `~/.ssh/config` (its pop-up lists them), and Set up once something is typed. Nothing connects or installs without a
/// click here.
struct RemoteHostsSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var typed: String
    /// Set up was clicked on text that is not a host name: the field keeps it and says so until it changes.
    @State private var refused: Bool

    /// Renders start from a typed text and a refusal; the app from an empty field.
    init(typed: String = "", refused: Bool = false) {
        _typed = State(initialValue: typed)
        _refused = State(initialValue: refused)
    }

    var body: some View {
        let model = env.remoteHosts
        FormSection(RemoteHostsText.title) {
            ForEach(model.rows) { RemoteHostRowView(row: $0) }
            addRow(model)
        }
        .task { model.refreshConfigHosts() }
    }

    private func addRow(_ model: any RemoteHostsModel) -> some View {
        HStack(spacing: 8) {
            RemoteHostField(text: $typed)
            if !model.configHosts.isEmpty {
                Menu {
                    ForEach(model.configHosts, id: \.self) { name in
                        Button(name) { typed = name }
                    }
                } label: {
                    SVGIcon(svg: ChromeIcon.upDown, size: CGSize(width: 7, height: 11), colour: SettingsTheme.ink)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(SettingsTheme.popupCircle))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(RemoteHostsText.pickHelp)
                .accessibilityLabel(RemoteHostsText.pickHelp)
            }
            if refused {
                Text(RemoteHostsText.notAHost).font(Fonts.sys(12)).foregroundStyle(SettingsTheme.statusAmber).fixedSize()
            }
            if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                PushButton(title: "Set up", blue: true, small: true) {
                    if model.setUp(typed) {
                        typed = ""
                    } else {
                        refused = true
                    }
                }
                .help(RemoteHostsText.setUpHelp)
            }
        }
        .onChange(of: typed) { refused = false }
        .padding(SettingsTheme.Metrics.rowPadding)
        .frame(minHeight: SettingsTheme.Metrics.rowMinHeight)
    }
}

/// The section's few words (unit-tested).
enum RemoteHostsText {
    static let title = "SSH hosts"
    static let prompt = "user@host, or a Host from ~/.ssh/config"
    static let pickHelp = "Hosts in ~/.ssh/config"
    static let setUpHelp = "Copy the hook helper there and add its hooks, over your own ssh"
    /// Set up on text ssh would not take as a host (`ssh gpu1`, `me@gpu1 -p 2222`).
    static let notAHost = RemoteSetupFailure.invalidDestination.words
}

/// One host: its name and what is hooked there; the state word and what to do about it; the state's button, and Remove.
struct RemoteHostRowView: View {
    let row: RemoteHostRow
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsTheme.ink2)
                .frame(width: 16)
            Text(row.name).font(Fonts.sys(13, .medium)).foregroundStyle(SettingsTheme.ink).lineLimit(1).truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.word).font(Fonts.sys(12.5)).foregroundStyle(row.amber ? SettingsTheme.statusAmber : SettingsTheme.ink2)
                if let detail = row.detail {
                    Text(detail).font(Fonts.sys(11)).foregroundStyle(SettingsTheme.ink2).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = row.action, let title = row.actionTitle {
                PushButton(title: title, blue: true, small: true) { env.remoteHosts.perform(action, on: row.id) }
                    .help(title)
            }
            if row.removable {
                PushButton(title: "Remove", quiet: true, small: true) { env.remoteHosts.remove(row.id) }
                    .help("Take our hooks off this host and forget it")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 46)
    }
}

/// The add row's field, as Mute rules' is drawn: 12 pt on the control grey, radius 5, 20 pt tall.
private struct RemoteHostField: View {
    @Binding var text: String

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(Fonts.sys(12))
            .foregroundStyle(SettingsTheme.ink)
            .lineLimit(1)
            .autocorrectionDisabled()
            .background(alignment: .leading) {
                if text.isEmpty {
                    Text(RemoteHostsText.prompt).font(Fonts.sys(12)).foregroundStyle(SettingsTheme.ink3).allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(SettingsTheme.control))
            .accessibilityLabel("SSH host")
    }
}
