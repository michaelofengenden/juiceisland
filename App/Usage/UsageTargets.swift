import AppKit
import JuiceCore
import SwiftUI

/// What a usage surface does when a battery, mark or amount is pointed at, focused or clicked. The window header sets
/// it; the island (D) sets its own. The default does nothing, so the pieces render standalone.
struct UsageInteraction {
    /// The pointer or keyboard focus arrived on (true) or left (false) a target, with its frame in `space`.
    var hover: @MainActor (HoverTargetID, Bool, CGRect) -> Void = { _, _, _ in }
    /// A battery or mark was clicked (or Enter/Space): its provider, the account (nil for a mark) and its frame in the
    /// `UsageInteraction.space` coordinate space. nil makes batteries and marks plain drawings, not buttons.
    var open: (@MainActor (Provider, String?, CGRect) -> Void)?

    /// The coordinate space target frames are reported in (the surface's own top-left).
    static let space = "usageSurface"
}

private struct UsageInteractionKey: EnvironmentKey {
    static let defaultValue = UsageInteraction()
}

extension EnvironmentValues {
    var usageInteraction: UsageInteraction {
        get { self[UsageInteractionKey.self] }
        set { self[UsageInteractionKey.self] = newValue }
    }
}

extension View {
    /// A battery or mark: hover and focus report `target`; a click opens the account list when the surface allows it;
    /// right-click raises its menu (Juice §2.6).
    func usageTarget(_ target: HoverTargetID, provider: Provider, account: String?) -> some View {
        modifier(UsageTargetModifier(target: target, provider: provider, account: account))
    }

    /// A money amount: a hover target only; right-click raises the source menu.
    func moneyTarget(_ id: String) -> some View {
        modifier(MoneyTargetModifier(id: id))
    }
}

private struct UsageTargetModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.usageInteraction) private var interaction
    @FocusState private var focused: Bool
    @State private var frame: CGRect = .zero
    let target: HoverTargetID
    let provider: Provider
    let account: String?

    func body(content: Content) -> some View {
        Group {
            if let open = interaction.open {
                Button { open(provider, account, frame) } label: { content.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .focused($focused)
                    .onChange(of: focused) { _, now in interaction.hover(target, now, frame) }
            } else {
                content
            }
        }
        .onHover { inside in interaction.hover(target, inside, frame) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(UsageInteraction.space)) } action: { frame = $0 }
        .contextMenu { UsageMenus.target(target, provider: provider, account: account, env: env) }
    }
}

private struct MoneyTargetModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.usageInteraction) private var interaction
    @State private var frame: CGRect = .zero
    let id: String

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { inside in interaction.hover(.money(id), inside, frame) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(UsageInteraction.space)) } action: { frame = $0 }
            .contextMenu { UsageMenus.money(id, env: env) }
    }
}

/// The right-click menus of prototype.md §2 (Juice §2.6).
@MainActor
enum UsageMenus {
    @ViewBuilder
    static func target(_ target: HoverTargetID, provider: Provider, account: String?, env: AppEnvironment) -> some View {
        if let account, let battery = env.usage.battery(id: account) {
            let refresh = AccountRefreshMenu.item(account, usage: env.usage, now: Date())
            Button(refresh.title) { env.usage.refreshAccount(account) }
                .disabled(!refresh.isEnabled)
            if let email = env.usage.email(of: account) {
                Button("Copy email") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(email, forType: .string)
                }
            }
            if battery.state == .signInNeeded {
                Button("Sign in") { env.actions.openSettings(.accounts) }
            }
            Button("Manage account…") { env.actions.openSettings(.accounts) }
        } else {
            Button("Manage accounts…") { env.actions.openSettings(.accounts) }
        }
    }

    @ViewBuilder
    static func money(_ id: String, env: AppEnvironment) -> some View {
        Button("Refresh source") { env.usage.refreshMoney(id) }
            .disabled(!env.usage.canRefreshMoney(id))
        Button("Open billing page") {
            if let url = BillingPages.url(for: id) { NSWorkspace.shared.open(url) }
        }
        Button("Manage source…") { env.actions.openSettings(.money) }
    }

    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Product.name
    }
}

/// Refresh account in a battery's menu (#12): one account, within its floors and any 429 pause. Read too recently, it
/// says when it can read and, clicked, moves the read up to then; paused or reading, it only says so.
@MainActor
enum AccountRefreshMenu {
    struct Item: Equatable, Sendable {
        var title: String
        var isEnabled: Bool
    }

    static func item(_ id: String, usage: any UsageModel, now: Date) -> Item {
        item(usage.manualRead(id), unavailable: usage.refreshUnavailableReason != nil, now: now)
    }

    static func item(_ read: RefreshScheduler.ManualRead, unavailable: Bool, now: Date) -> Item {
        switch read {
        case .now: Item(title: "Refresh account", isEnabled: true)
        case .reading: Item(title: "Reading…", isEnabled: false)
        case let .floor(until): Item(title: "Refresh in " + wait(until, now: now), isEnabled: true)
        case let .paused(until): Item(title: "Rate limited · next read in " + wait(until, now: now), isEnabled: false)
        case .unavailable: Item(title: "Refresh account", isEnabled: false)
        }
    }

    /// "45s", "2m", "1h 5m": never sooner than the wait.
    static func wait(_ until: Date, now: Date) -> String {
        let seconds = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
        guard seconds >= 60 else { return "\(seconds)s" }
        return Formatting.duration(Double((seconds + 59) / 60 * 60))
    }
}

/// The usage block's background menu, the same in the window header and the island (C12: no Lock position): Refresh
/// all (greyed, with its progress, while one runs) · ✓ Desktop panel · — · Show as the other mode ⌘⇧I · Settings….
/// One Settings item, on Accounts, since the menu is about the accounts.
@MainActor
enum UsageBackgroundMenu {
    enum Action: Equatable, Sendable { case refreshAll, toggleDesktopPanel, showAs(ShowAs), settings }

    struct Item: Equatable {
        var title: String
        var isEnabled = true
        /// A switch's tick; nil for a plain item.
        var isOn: Bool?
        /// With ⌘⇧.
        var key: Character?
        var action: Action
    }

    /// nil is a separator. `showing`: the mode the menu is shown in; it offers the other one.
    static func items(usage: any UsageModel, settings: AppSettings, showing: ShowAs) -> [Item?] {
        let refresh: Item = if let progress = usage.refreshProgress {
            Item(title: "Refreshing \(progress) of \(usage.refreshTotal)…", isEnabled: false, action: .refreshAll)
        } else {
            Item(title: "Refresh all", isEnabled: usage.refreshUnavailableReason == nil, action: .refreshAll)
        }
        let other: ShowAs = showing == .window ? .island : .window
        return [
            refresh,
            Item(title: "Desktop panel", isOn: settings.panelShowOnDesktop, action: .toggleDesktopPanel),
            nil,
            Item(title: other == .island ? "Show as Island" : "Show as Window", key: "i", action: .showAs(other)),
            Item(title: "Settings…", action: .settings),
        ]
    }

    static func perform(_ action: Action, env: AppEnvironment) {
        switch action {
        case .refreshAll: env.usage.refreshAll()
        case .toggleDesktopPanel: env.settings.panelShowOnDesktop.toggle()
        case let .showAs(mode): env.actions.setShowAs(mode)
        case .settings: env.actions.openSettings(.accounts)
        }
    }
}

/// `UsageBackgroundMenu` as context-menu content.
struct UsageBackgroundMenuItems: View {
    @Environment(AppEnvironment.self) private var env
    let showing: ShowAs

    var body: some View {
        let items = UsageBackgroundMenu.items(usage: env.usage, settings: env.settings, showing: showing)
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if let item {
                if let isOn = item.isOn {
                    Toggle(item.title, isOn: Binding(get: { isOn }, set: { _ in UsageBackgroundMenu.perform(item.action, env: env) }))
                } else if let key = item.key {
                    Button(item.title) { UsageBackgroundMenu.perform(item.action, env: env) }
                        .keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .shift])
                        .disabled(!item.isEnabled)
                } else {
                    Button(item.title) { UsageBackgroundMenu.perform(item.action, env: env) }
                        .disabled(!item.isEnabled)
                }
            } else {
                Divider()
            }
        }
    }
}
