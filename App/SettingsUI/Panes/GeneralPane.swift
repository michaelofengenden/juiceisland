import AppKit
import SwiftUI

/// Settings › General (spec §4.5): the app, the window and behaviour. No Language picker (C8). Labels say what a row
/// does; a subtitle only where the effect is not obvious. Launch at Login shows only in the installed release build
/// (`LaunchAtLogin`). Live sessions is a development build's switch: the release build shows it only while it is off,
/// so it can be turned back on. Owner: stream A.
struct GeneralPane: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        FormPane {
            FormSection {
                FormRow("Show as") {
                    SettingsSegmented(selection: $settings.showAs,
                                      options: [(.window, "Window"), (.island, "Island")], label: "Show as")
                }
                // Settings follows it in every theme; the island, the panel and the window on Glass and Solid (P761).
                FormRow("Appearance", subtitle: GeneralPaneText.appearance) {
                    SettingsSegmented(selection: $settings.appearance, options: AppearanceChoice.allCases.map { ($0, $0.title) },
                                      label: "Appearance")
                }
                if let login = env.launchAtLogin, login.isAvailable { LaunchAtLoginRow(login: login) }
                // Window mode always shows the Dock icon, so the row appears only where it can change.
                if settings.showAs == .island {
                    FormRow("Dock icon") {
                        SettingsSwitch(isOn: $settings.dockIconInIslandMode, label: "Dock icon")
                    }
                }
                FormRow("Menu bar icon") {
                    SettingsSwitch(isOn: $settings.menuBarItem, label: "Menu bar icon")
                }
                if env.identity != .production || !settings.liveSessions {
                    FormRow("Live sessions", subtitle: env.liveSessions?.refusal ?? GeneralPaneText.liveSessions(env.identity)) {
                        SettingsSwitch(isOn: $settings.liveSessions, label: "Live sessions")
                    }
                }
            }
            FormSection("Window") {
                FormRow("Header") {
                    SettingsSegmented(selection: $settings.windowHeader, options: [(.section, "Section"), (.strip, "Strip")], label: "Window header")
                }
                FormRow("Show money") {
                    SettingsSwitch(isOn: $settings.windowShowsMoney, label: "Show money in the window")
                }
                FormRow("Account names") {
                    SettingsSwitch(isOn: $settings.accountNamesUnderBatteries, label: "Account names under batteries")
                }
            }
            FormSection("Behavior") {
                FormRow("Keep approvals open until answered") {
                    SettingsSwitch(isOn: $settings.keepOpenUntilDecision, label: "Keep approvals open until answered")
                }
                FormRow("Permission modes on cards", subtitle: GeneralPaneText.modeChoices) {
                    SettingsSwitch(isOn: $settings.modeChoicesOnCards, label: "Permission modes on cards")
                }
                // Only where the session's own tab is known exactly (P128).
                FormRow("Reply from completion card", subtitle: "In tmux, iTerm and Ghostty") {
                    SettingsSwitch(isOn: $settings.replyFromCompletionCard, label: "Reply from completion card")
                }
                FormRow("No alerts for focused sessions") {
                    SettingsSwitch(isOn: $settings.suppressForFocusedSessions, label: "No alerts for focused sessions")
                }
                FormRow("Remind again", subtitle: GeneralPaneText.remind) {
                    SettingsSegmented(selection: $settings.followUpAfter, options: GeneralPaneText.remindOptions, label: "Remind again")
                }
                BannersRow()
                FormRow("Show Codex app threads") {
                    SettingsSwitch(isOn: $settings.showCodexAppThreads, label: "Show Codex app threads")
                }
            }
        }
    }
}

/// Launch at Login: the switch shows what macOS says; an item still to be allowed says so, with the way there.
private struct LaunchAtLoginRow: View {
    let login: LaunchAtLogin

    var body: some View {
        FormRow("Launch at Login", subtitle: login.note) {
            HStack(spacing: 12) {
                if login.needsApproval {
                    PushButton(title: "Open Login Items", small: true) { login.openSystemSettings() }
                }
                SettingsSwitch(isOn: Binding(get: { login.isOn }, set: { login.set($0) }), label: "Launch at Login")
            }
        }
        // The owner may have allowed it (or turned it off) in System Settings meanwhile.
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
    }
}

/// Notification banners (P412): the switch, and while it is on what macOS says when it does not let them show, with the
/// one way on from there (Allow asks macOS; Open goes to System Settings). No row says anything while banners work.
private struct BannersRow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        let permission = settings.notificationBanners ? env.banners?.permission ?? .unknown : .unknown
        FormRow("Notification banners", subtitle: GeneralPaneText.banners(on: settings.notificationBanners, permission)) {
            HStack(spacing: 12) {
                switch GeneralPaneText.bannerAction(permission) {
                case .allow?:
                    PushButton(title: "Allow", small: true) { env.banners?.ask() }
                case .open?:
                    PushButton(title: "Open System Settings", small: true) { env.banners?.openSystemSettings() }
                case nil:
                    EmptyView()
                }
                SettingsSwitch(isOn: $settings.notificationBanners, label: "Notification banners")
            }
        }
        // The owner may have allowed them (or turned them off) in System Settings meanwhile.
        .onAppear { env.banners?.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in env.banners?.refresh() }
    }
}

/// General's subtitles.
enum GeneralPaneText {
    /// What Appearance leaves alone, which its name alone does not say (P760).
    static let appearance = "Black and Smoke stay dark."

    /// What the mode buttons do, which the row's name alone does not say (P450).
    static let modeChoices = "Approve into Accept edits, Manual or Bypass."

    /// Remind again: once, and only for what the owner has not seen (P410).
    static let remind = "Once, for what you have not looked at."

    static let remindOptions: [(FollowUpDelay, String)] = [(.off, "Off"), (.oneMinute, "1 min"), (.twoMinutes, "2 min"),
                                                           (.threeMinutes, "3 min"), (.fiveMinutes, "5 min")]

    /// Notification banners' line: where it stands when macOS keeps them from showing, else when they come (P412).
    static func banners(on: Bool, _ permission: BannerPermission) -> String? {
        guard on else { return nil }
        switch permission {
        case .notAsked: return "Not allowed yet."
        case .denied: return "Off in System Settings."
        case .unavailable: return "Not available in this build."
        case .allowed, .unknown: return "When the app does not show it."
        }
    }

    enum BannerAction: Equatable { case allow, open }

    /// The way on from where macOS stands: ask it, or go to System Settings; nothing when there is none.
    static func bannerAction(_ permission: BannerPermission) -> BannerAction? {
        switch permission {
        case .notAsked: .allow
        case .denied: .open
        case .allowed, .unknown, .unavailable: nil
        }
    }

    /// Live sessions takes Open Island's hook socket, and approvals then wait for an answer here. The release build's
    /// row shows only while the switch is off, and needs no reminder.
    static func liveSessions(_ identity: AppIdentity) -> String? {
        identity == .production ? nil : "Quit Open Island first. Approvals then wait for you here."
    }
}
