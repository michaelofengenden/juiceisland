import JuiceCore
import SwiftUI

/// Settings › Accounts (prototype L1675-1690, spec §4.5): the release build's list by account (`LiveAccountsPane`), and
/// in the dev build the same rows from the demo's fixtures or from Juice's readings (`FolderLogins`), with no control
/// that could not act. Each account (mark, email, the folders that hold it, plan, battery; Monitor in the demo, through
/// `DemoUsageModel.setMonitored`, P34), then the folders signed out ("Signed out") or not placed, then the sign-in
/// browser profile (demo only) and the usage source in one unlabelled group. Juice's readings (the dev build's
/// read-only mirror) show only what Juice has, and a provider with no folder is left out. Owner: stream A.
struct AccountsPane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var browserProfile = "Chrome · Work"

    static let browserProfiles = ["Default browser", "Chrome · Work", "Chrome · Personal", "Safari"]

    /// The Monitor switch and the browser pop-up only for demo data; every other source shows what it read.
    static func showsFixtures(_ usage: any UsageModel) -> Bool { usage is DemoUsageModel }

    var body: some View {
        // The release build reads the accounts itself: the real list, with Add, Monitor, Remove and Sign In.
        if let live = env.liveUsage { LiveAccountsPane(model: live) } else { pane(editable: Self.showsFixtures(env.usage)) }
    }

    @ViewBuilder private func pane(editable: Bool) -> some View {
        @Bindable var settings = env.settings
        FormPane {
            ForEach(env.usage.logins) { list in
                FormSection(list.provider.displayName) { rows(list, editable: editable) }
            }
            FormSection {
                if editable {
                    FormRow("Sign-in browser") {
                        SettingsPopup(selection: $browserProfile, options: Self.browserProfiles.map { ($0, $0) }, label: "Browser profile")
                    }
                }
                FormRow("Usage source") {
                    SettingsPopup(selection: $settings.usageSource, options: UsageSource.allCases.map { ($0, $0.title(in: env.identity)) },
                                  label: "Usage source")
                }
            }
        }
    }

    /// One provider's accounts, then its folders signed out (the word: neither model can sign in) or not placed.
    @ViewBuilder private func rows(_ list: ProviderLogins, editable: Bool) -> some View {
        let usage = env.usage
        ForEach(list.logins) { row in
            LoginRowView(row: row, now: usage.now,
                         monitor: editable ? { on in row.folders.forEach { (usage as? DemoUsageModel)?.setMonitored($0.id, on) } } : nil)
        }
        ForEach(list.folders) { loose in
            FolderRow(provider: loose.folder.provider, path: loose.folder.folder) {
                if loose.state == .signedOut {
                    Text("Signed out").font(Fonts.sys(12)).foregroundStyle(SettingsTheme.ink2)
                }
            }
        }
    }
}
