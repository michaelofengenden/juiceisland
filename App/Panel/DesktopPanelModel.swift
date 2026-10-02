import AppKit
import JuiceCore

/// What the desktop panel draws, taken from whichever `UsageModel` runs (P34, P41: `PanelModelBuilder`'s rows, so no
/// battery state is computed here) and the money the owner left switched on in Settings › Money.
struct DesktopPanelContent: Equatable {
    var rows: [ProviderRowModel]
    var money: [MoneyRowModel]
    var now: Date
    /// nil when there is nothing to draw: no monitored account and no money shown. The panel is not shown then.
    var size: CGSize?
    /// The accounts in use (P814): their batteries wear the dot, in the account list's order as ever.
    var inUse = AccountsInUse.none

    @MainActor
    static func make(usage: any UsageModel, settings: AppSettings, inUse: AccountsInUse = .none) -> DesktopPanelContent {
        let rows = usage.panel.rows.filter { !$0.batteries.isEmpty }
        let money = usage.shownMoney(settings)
        return DesktopPanelContent(rows: rows, money: money, now: usage.now,
                                   size: PanelGeometry.panelSize(providerRows: rows.count, showsMoney: !money.isEmpty, moneyCount: money.count),
                                   inUse: inUse)
    }
}

/// The panel background's right-click menu (Juice spec §2.6, prototype `menuItems("panel")`, plus Refresh all, the
/// menu bar item's job that moved here in amendment 1): Refresh all · — · Lock position · Hide panel · — · Settings…
@MainActor
enum PanelMenu {
    enum Action: Sendable { case refreshAll, toggleLock, hide, settings }

    struct Item: Equatable {
        var title: String
        var isEnabled = true
        var action: Action
    }

    /// nil is a separator.
    static func items(usage: any UsageModel, settings: AppSettings) -> [Item?] {
        let refresh: Item = if let progress = usage.refreshProgress {
            Item(title: "Refreshing \(progress) of \(usage.refreshTotal)…", isEnabled: false, action: .refreshAll)
        } else {
            Item(title: "Refresh all", isEnabled: usage.refreshUnavailableReason == nil, action: .refreshAll)
        }
        return [
            refresh,
            nil,
            Item(title: settings.panelLocked ? "Unlock position" : "Lock position", action: .toggleLock),
            Item(title: "Hide panel", action: .hide),
            nil,
            Item(title: "Settings…", action: .settings),
        ]
    }

    static func perform(_ action: Action, env: AppEnvironment) {
        switch action {
        case .refreshAll: env.usage.refreshAll()
        case .toggleLock: env.settings.panelLocked.toggle()
        case .hide: env.settings.panelShowOnDesktop = false
        case .settings: env.actions.openSettings(.desktopPanel)
        }
    }
}

extension PanelActions {
    /// The batteries' and money rows' menus (Juice §2.6) acting on the app: Refresh account goes through the usage
    /// model's `refreshAccount` and Refresh source through its `refreshMoney` (their floors still apply), sign-in and
    /// management open Settings, and the position switches are the Desktop Panel settings themselves.
    @MainActor
    static func desktop(env: AppEnvironment) -> PanelActions {
        PanelActions(
            refreshAccount: { id in env.usage.refreshAccount(id) },
            refreshAccountItem: { id in AccountRefreshMenu.item(id, usage: env.usage, now: Date()) },
            email: { id in env.usage.email(of: id) },
            signIn: { _ in env.actions.openSettings(.accounts) },
            manageAccount: { _ in env.actions.openSettings(.accounts) },
            refreshSource: { id in env.usage.refreshMoney(id) },
            canRefreshSource: { id in env.usage.canRefreshMoney(id) },
            openBillingPage: { id in
                if let url = BillingPages.url(for: id) { NSWorkspace.shared.open(url) }
            },
            manageSource: { _ in env.actions.openSettings(.money) },
            toggleLock: { env.settings.panelLocked.toggle() },
            isLocked: { env.settings.panelLocked },
            hidePanel: { env.settings.panelShowOnDesktop = false },
            toggleShown: { env.settings.panelShowOnDesktop.toggle() },
            openSettings: { env.actions.openSettings(.desktopPanel) })
    }
}
