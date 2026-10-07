import JuiceCore
import SwiftUI

/// What the panel can ask the app to do. Views never touch the model directly.
struct PanelActions: Sendable {
    var refreshAccount: @MainActor @Sendable (String) -> Void = { _ in }
    /// Refresh account's words and whether it acts (`AccountRefreshMenu`, #12).
    var refreshAccountItem: @MainActor @Sendable (String) -> AccountRefreshMenu.Item = { _ in .init(title: "Refresh account", isEnabled: false) }
    /// The email of the account a battery draws (`UsageModel.email(of:)`); nil leaves Copy email out of its menu.
    var email: @MainActor @Sendable (String) -> String? = { _ in nil }
    var signIn: @MainActor @Sendable (String) -> Void = { _ in }
    /// Refresh login on a lapsed Codex login's battery (P1551): the usage model's `refreshLogin`, on the owner's click.
    /// Nil where a surface opens nothing, and then its battery's menu offers no Refresh login (`BatteryView.firstMenuItem`).
    var refreshLogin: (@MainActor @Sendable (String) -> Void)?
    var manageAccount: @MainActor @Sendable (String) -> Void = { _ in }
    var refreshSource: @MainActor @Sendable (String) -> Void = { _ in }
    /// Whether Refresh source can read that source now (the usage model's `canRefreshMoney`); false where nothing reads.
    var canRefreshSource: @MainActor @Sendable (String) -> Bool = { _ in false }
    var openBillingPage: @MainActor @Sendable (String) -> Void = { _ in }
    var manageSource: @MainActor @Sendable (String) -> Void = { _ in }
    var toggleLock: @MainActor @Sendable () -> Void = {}
    var isLocked: @MainActor @Sendable () -> Bool = { false }
    /// The panel's own menu hides it; the menu bar's tick toggles it.
    var hidePanel: @MainActor @Sendable () -> Void = {}
    var toggleShown: @MainActor @Sendable () -> Void = {}
    var openSettings: @MainActor @Sendable () -> Void = {}
}

private struct PanelActionsKey: EnvironmentKey {
    static let defaultValue = PanelActions()
}

extension EnvironmentValues {
    var panelActions: PanelActions {
        get { self[PanelActionsKey.self] }
        set { self[PanelActionsKey.self] = newValue }
    }
}

/// Each source's billing page, opened in the browser by Open billing page (never read by the app). Every key of a
/// source opens its source's page.
enum BillingPages {
    static let urls: [String: String] = [
        "OpenRouter": "https://openrouter.ai/credits",
        "Anthropic": "https://console.anthropic.com/settings/billing",
        "OpenAI": "https://platform.openai.com/settings/organization/billing/overview",
        "RunPod": "https://www.runpod.io/console/user/billing",
        "Hetzner": "https://console.hetzner.cloud/",
        "DeepSeek": "https://platform.deepseek.com/usage",
        "Moonshot": "https://platform.kimi.ai/",
        "xAI": "https://console.x.ai/",
        "Fireworks": "https://app.fireworks.ai/account/billing",
        "fal.ai": "https://fal.ai/dashboard/billing",
        "ElevenLabs": "https://elevenlabs.io/app/subscription",
        "Vast.ai": "https://cloud.vast.ai/billing/",
        "DigitalOcean": "https://cloud.digitalocean.com/account/billing",
    ]

    /// The page for a money row's id (`OpenRouter 2` opens OpenRouter's).
    static func url(for id: String) -> URL? {
        (MoneyAccount(rawValue: id).flatMap { urls[$0.source.rawValue] } ?? urls[id]).flatMap(URL.init(string:))
    }
}
