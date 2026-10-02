import AppKit
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The money stream: Settings › Money (demo and live, and its key states), and the surfaces with only the sources that
/// have a key file (OpenRouter and RunPod read, Anthropic's key without the Admin role; OpenAI and Hetzner not set up,
/// so hidden). Headless only (`zsh scripts/render-all.sh MoneyRenders`); nothing is shown on screen and nothing is read:
/// the key files are fake keys in a temporary home.
@MainActor
@Suite(.serialized)
struct MoneyRenders {
    private func settingsPane(_ name: String, env: AppEnvironment, preview: [MoneyAccount: MoneyKeyPreview] = [:]) throws {
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .money), drawsTrafficLights: true, scrolls: false)
            .environment(\.moneyKeyPreview, preview)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    /// A temporary home with fake key files for `sources`, written the way Save writes them.
    private final class KeyHome {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("money-render-\(UUID().uuidString)", isDirectory: true)
        var path: String { url.path }

        convenience init(_ sources: [MoneySource]) throws { try self.init(accounts: sources.map { MoneyAccount($0) }) }

        init(accounts: [MoneyAccount]) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let keys: [MoneySource: String] = [.openRouter: "sk-or-v1-FAKE", .anthropic: "sk-ant-admin01-FAKE", .openAI: "sk-admin-FAKE",
                                               .runPod: "rpa_FAKE", .hetzner: "FAKEhetzner", .deepSeek: "sk-FAKEdeepseek",
                                               .moonshot: "sk-FAKEmoonshot", .xAI: "xai-FAKEmanagement", .fireworks: "fw_FAKE",
                                               .fal: "FAKEfal:FAKEsecret", .elevenLabs: "sk_FAKEelevenlabs", .vastAI: "FAKEvast",
                                               .digitalOcean: "dop_v1_FAKE"]
            for account in accounts { try MoneyKeyFile.write(keys[account.source]!, for: account, guard: MoneyKeyFileGuard(home: path)) }
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// Mixed records with key files for the three sources that have them.
    private func liveWithKeys(settings: AppSettings = .ephemeral()) throws -> (AppEnvironment, KeyHome) {
        let home = try KeyHome([.openRouter, .anthropic, .runPod])
        let (env, _) = MoneyModelTests.live(MoneyModelTests.mixed, settings: settings, home: home.path)
        return (env, home)
    }

    /// The window's header as `BRenders` draws it: the toolbar line (usage on it when it fits), the band under it, and
    /// 8 pt of window around it.
    private func header(_ name: String, env: AppEnvironment, width: CGFloat = 1200, hover: HoverTargetID? = nil) throws {
        let view = WindowHeaderView(drawsTrafficLights: true, hover: hover)
            .overlay(alignment: .bottom) { WindowTheme.hairline.frame(height: 1) }
            .frame(width: width)
            .padding(8)
            .background(Color.black)
        let height = ceil(NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true).environment(env)
            .environment(\.colorScheme, .dark)).fittingSize.height)
        try RenderHarness.renderHosted(view, name, size: CGSize(width: width + 16, height: height), env: env)
    }

    private func island(_ name: String, env: AppEnvironment, ui: IslandUIState = IslandUIState()) throws {
        let notch = IslandTheme.Metrics.referenceNotch
        let view = OpenedIslandView(presentation: .list, notch: notch, ui: ui, animated: false)
        try RenderHarness.render(DScene.island(view, notch: notch), name, env: env)
    }

    @Test func settingsDemo() throws { try settingsPane("Money-settings-demo", env: .demo()) }

    @Test func settingsLive() throws {
        let settings = AppSettings.ephemeral()
        settings.money.credits[.anthropic] = 1_400
        settings.money.creditDates[.anthropic] = Date(timeIntervalSince1970: 1_788_739_200)
        settings.money.topUps[.runPod] = 250
        let (env, home) = try liveWithKeys(settings: settings)
        try settingsPane("Money-settings-live", env: env)
        withExtendedLifetime(home) {}
    }

    /// Typing a key (OpenAI, empty; Hetzner, with dots), and Remove asking (RunPod).
    @Test func settingsKeyStates() throws {
        let (env, home) = try liveWithKeys()
        try settingsPane("Money-settings-keys", env: env, preview: [
            .openAI: MoneyKeyPreview(mode: .adding(error: nil)),
            .hetzner: MoneyKeyPreview(mode: .adding(error: nil), draft: "FAKEFAKEFAKEFAKEFAKE"),
            .runPod: MoneyKeyPreview(mode: .confirmingRemove(error: nil)),
        ])
        withExtendedLifetime(home) {}
    }

    /// Remove asking while another key file the lookup finds waits behind the one it deletes (RunPod's `api-key`, made
    /// by hand): the line under the question names it.
    @Test func settingsRemoveNamesTheNextKey() throws {
        let (env, home) = try liveWithKeys()
        try FileManager.default.createDirectory(atPath: home.path + "/.config/runpod", withIntermediateDirectories: true)
        try "rpa_FAKEOLDER\n".write(toFile: home.path + "/.config/runpod/api-key", atomically: true, encoding: .utf8)
        try settingsPane("Money-settings-remove-next", env: env, preview: [.runPod: MoneyKeyPreview(mode: .confirmingRemove(error: nil))])
        withExtendedLifetime(home) {}
    }

    /// Save refused (Anthropic takes an Admin key only), and a Remove that failed.
    @Test func settingsKeyErrors() throws {
        let (env, home) = try liveWithKeys()
        try settingsPane("Money-settings-key-errors", env: env, preview: [
            .anthropic: MoneyKeyPreview(mode: .adding(error: MoneyKeyEditError.notAnAdminKey.message), draft: "FAKEFAKEFAKE"),
            .openRouter: MoneyKeyPreview(mode: .confirmingRemove(error: MoneyKeyEditError.failed("delete the key file").message)),
        ])
        withExtendedLifetime(home) {}
    }

    /// No key anywhere: five lines, each with Add key….
    @Test func settingsNothingSetUp() throws {
        let home = try KeyHome([])
        let (env, _) = MoneyModelTests.live([:], home: home.path)
        try settingsPane("Money-settings-none", env: env)
    }

    /// Keys just saved, nothing read yet.
    @Test func settingsReading() throws {
        let home = try KeyHome(MoneySource.allCases)
        let (env, _) = MoneyModelTests.live([:], home: home.path)
        try settingsPane("Money-settings-reading", env: env)
    }

    @Test func headerLive() throws {
        let settings = AppSettings.ephemeral()
        settings.windowHeader = .section
        let (env, _) = MoneyModelTests.live(MoneyModelTests.mixed, settings: settings)
        try header("Money-header-live-1200", env: env)
        try header("Money-header-live-900", env: env, width: 900)
        try header("Money-header-live-hover-anthropic", env: env, hover: .money("Anthropic"))
    }

    @Test func headerStripLive() throws {
        let settings = AppSettings.ephemeral()
        settings.windowHeader = .strip
        let (env, _) = MoneyModelTests.live(MoneyModelTests.mixed, settings: settings)
        try header("Money-header-strip-live-1200", env: env)
    }

    @Test func headerNothingConnected() throws {
        let (env, _) = MoneyModelTests.live([:])
        try header("Money-header-none-1200", env: env)
    }

    @Test func islandCleanLive() throws {
        let settings = AppSettings.ephemeral()
        settings.islandUsagePlacement = .section
        let (env, _) = MoneyModelTests.live(MoneyModelTests.mixed, settings: settings)
        try island("Money-island-clean-live", env: env)
        try island("Money-island-clean-live-hover-runpod", env: env, ui: IslandUIState(hover: .money("RunPod")))
    }

    @Test func islandDetailedLive() throws {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .detailed
        settings.islandUsagePlacement = .section
        let (env, _) = MoneyModelTests.live(MoneyModelTests.mixed, settings: settings)
        try island("Money-island-detailed-live", env: env)
    }

    // MARK: The sources added with the figure kinds (§8 decision 14)

    static let sideOpenRouter = MoneyAccount(.openRouter, slot: 2)
    static let teamID = "00000000-0000-4000-8000-00000000000a"

    /// Two OpenRouter keys (the second labelled `Side`), Anthropic without the Admin role, RunPod, and seven of the new
    /// sources: DeepSeek in yuan, Moonshot, xAI with its team id, Fireworks without its account id, ElevenLabs' quota,
    /// Vast.ai burning (amber) and DigitalOcean's month so far. OpenAI, Hetzner and fal.ai have no key.
    static var everyKind: [MoneyAccount: MoneySourceRecord] {
        let now = MoneyModelTests.now
        func reading(_ account: MoneyAccount, _ figures: MoneyReading.Figures) -> MoneySourceRecord {
            MoneyModelTests.reading(account.source, figures)
        }
        var records = MoneyModelTests.mixed.filter { $0.value.lastError != .notConfigured }
        records[sideOpenRouter] = reading(sideOpenRouter, .balance(OpenRouterFigures(usageDaily: 1.2, totalCredits: 100, totalUsage: 19.5).kind))
        records[.deepSeek] = reading(.deepSeek, .balance(BalanceFigures(currency: .cny, amount: 110)))
        records[.moonshot] = reading(.moonshot, .balance(BalanceFigures(currency: .usd, amount: 49.58894)))
        records[.xAI] = reading(.xAI, .balance(BalanceFigures(currency: .usd, amount: 37.25)))
        records[.fireworks] = MoneySourceRecord(lastError: .idMissing("Account ID"), lastErrorAt: now - 30, keyFileName: "key")
        records[.elevenLabs] = reading(.elevenLabs, .quota(QuotaFigures(used: 2_600, limit: 10_000, unit: "characters",
                                                                        resetsAt: Date(timeIntervalSince1970: 1_790_899_200))))
        records[.vastAI] = reading(.vastAI, .balance(BalanceFigures(currency: .usd, amount: 86.25, burnPerHour: 1.75)))
        records[.digitalOcean] = reading(.digitalOcean, .spend(SpendFigures(currency: .usd, daily: [:],
                                                                             coveredFrom: MoneyRules.startOfMonth(now), monthToDate: 11.21)))
        return records
    }

    private func everyKindLive(_ configure: (AppSettings) -> Void = { _ in }) throws -> (AppEnvironment, KeyHome) {
        let settings = AppSettings.ephemeral()
        settings.money.topUps[.runPod] = 250
        settings.money.labels[Self.sideOpenRouter] = "Side"
        settings.money.accountIDs[.xAI] = Self.teamID
        configure(settings)
        let home = try KeyHome(accounts: [.openRouter, Self.sideOpenRouter, .anthropic, .runPod, .deepSeek, .moonshot, .xAI, .fireworks,
                                          .elevenLabs, .vastAI, .digitalOcean])
        let (env, _) = MoneyModelTests.live(Self.everyKind, settings: settings, home: home.path)
        return (env, home)
    }

    /// Settings › Money with every kind: the keyed accounts in the panel's order (xAI's team id, Fireworks' missing
    /// account id, the two OpenRouter keys named, the thresholds on RunPod), then the sources with no key.
    @Test func settingsEveryKind() throws {
        let (env, home) = try everyKindLive()
        try settingsPane("Money-settings-every-kind", env: env)
        withExtendedLifetime(home) {}
    }

    /// Add another on OpenRouter: the field for `OpenRouter 3`.
    @Test func settingsAddAnother() throws {
        let (env, home) = try everyKindLive()
        try settingsPane("Money-settings-add-another", env: env, preview: [.openRouter: MoneyKeyPreview(mode: .addingAnother(error: nil))])
        withExtendedLifetime(home) {}
    }

    /// Vast.ai alone burns: the thresholds sit on it.
    @Test func settingsVastCarriesTheThresholds() throws {
        let home = try KeyHome(accounts: [.vastAI, .deepSeek])
        let (env, _) = MoneyModelTests.live([.vastAI: Self.everyKind[.vastAI]!, .deepSeek: Self.everyKind[.deepSeek]!], home: home.path)
        try settingsPane("Money-settings-vast", env: env)
    }

    @Test func surfacesEveryKind() throws {
        let (header, home) = try everyKindLive { $0.windowHeader = .section }
        try self.header("Money-header-every-kind-1200", env: header)
        try self.header("Money-header-every-kind-hover-elevenlabs", env: header, hover: .money("ElevenLabs"))
        let (strip, _) = try everyKindLive { $0.windowHeader = .strip }
        try self.header("Money-header-strip-every-kind-1200", env: strip)
        let (clean, _) = try everyKindLive { $0.islandUsagePlacement = .section }
        try island("Money-island-clean-every-kind", env: clean)
        try island("Money-island-clean-every-kind-hover-vast", env: clean, ui: IslandUIState(hover: .money("Vast.ai")))
        let (detailed, _) = try everyKindLive {
            $0.islandStyle = .detailed
            $0.islandUsagePlacement = .section
        }
        try island("Money-island-detailed-every-kind", env: detailed)
        let (panel, _) = try everyKindLive()
        let content = DesktopPanelContent.make(usage: panel.usage, settings: panel.settings)
        let size = try #require(content.size)
        try RenderHarness.render(DesktopPanelView().padding(PanelGeometry.margin), "Money-panel-every-kind",
                                 size: PanelGeometry.windowSize(for: size), env: panel, background: PRenders.wallpaper)
        withExtendedLifetime(home) {}
    }

    @Test func islandNothingConnected() throws {
        let (env, _) = MoneyModelTests.live([:])
        try island("Money-island-clean-none", env: env)
    }

    // MARK: Several keys of one source (wave 3's review)

    private func panel(_ name: String, env: AppEnvironment) throws {
        let content = DesktopPanelContent.make(usage: env.usage, settings: env.settings)
        let size = try #require(content.size)
        try RenderHarness.render(DesktopPanelView().padding(PanelGeometry.margin), name, size: PanelGeometry.windowSize(for: size), env: env,
                                 background: PRenders.wallpaper)
    }

    /// Two unnamed keys each of OpenRouter and RunPod, and DigitalOcean: each second key keeps its slot digit where a
    /// name is cut (`OpenRouter 2`), and RunPod's blocks in Settings share one layout, the thresholds never wrapped.
    @Test func twoKeysOfOneSource() throws {
        let side = Self.sideOpenRouter, gpu = MoneyAccount(.runPod, slot: 2)
        var records = Self.everyKind.filter { [.openRouter, side, .runPod, .digitalOcean].contains($0.key) }
        records[gpu] = MoneyModelTests.reading(.runPod, .balance(RunPodFigures(balance: 12, burnPerHour: 1.1).kind))
        let home = try KeyHome(accounts: [.openRouter, side, .runPod, gpu, .digitalOcean])
        func live(_ configure: (AppSettings) -> Void = { _ in }) -> AppEnvironment {
            let settings = AppSettings.ephemeral()
            configure(settings)
            return MoneyModelTests.live(records, settings: settings, home: home.path).0
        }
        try settingsPane("Money-settings-two-keys", env: live())
        try island("Money-island-detailed-two-keys", env: live {
            $0.islandStyle = .detailed
            $0.islandUsagePlacement = .section
        })
        try panel("Money-panel-two-keys", env: live())
        withExtendedLifetime(home) {}
    }

    /// Four OpenRouter keys (one named with the longest name there is room for), two RunPod keys and seven more
    /// sources.
    @Test func manyKeys() throws {
        let keys = (2...4).map { MoneyAccount(.openRouter, slot: $0) }
        let gpu = MoneyAccount(.runPod, slot: 2)
        var records = Self.everyKind
        records[keys[1]] = MoneyModelTests.reading(.openRouter, .balance(OpenRouterFigures(usageDaily: 1.2, totalCredits: 300, totalUsage: 19.5).kind))
        records[keys[2]] = MoneyModelTests.reading(.openRouter, .balance(OpenRouterFigures(usageDaily: 1.2, totalCredits: 2_000, totalUsage: 19.5).kind))
        records[gpu] = MoneyModelTests.reading(.runPod, .balance(RunPodFigures(balance: 12, burnPerHour: 1.1).kind))
        let accounts: [MoneyAccount] = [.openRouter] + keys + [.anthropic, .runPod, gpu, .deepSeek, .moonshot, .xAI, .fireworks, .elevenLabs,
                                                               .vastAI, .digitalOcean]
        let home = try KeyHome(accounts: accounts)
        func live(_ configure: (AppSettings) -> Void = { _ in }) -> AppEnvironment {
            let settings = AppSettings.ephemeral()
            settings.money.labels[keys[0]] = "Side"
            settings.money.labels[keys[2]] = "Client work for Acme Co"
            settings.money.accountIDs[.xAI] = Self.teamID
            configure(settings)
            return MoneyModelTests.live(records, settings: settings, home: home.path).0
        }
        try settingsPane("Money-settings-many-keys", env: live())
        try island("Money-island-detailed-many-keys", env: live {
            $0.islandStyle = .detailed
            $0.islandUsagePlacement = .section
        })
        try panel("Money-panel-many-keys", env: live())
        withExtendedLifetime(home) {}
    }

    /// The first OpenRouter key removed, the second kept: the source is listed once, the second key's block carrying
    /// Add another; and ids: one kept by an earlier build that is not an id (`Team ID not valid`), one just refused.
    @Test func settingsFirstKeyGoneAndIDs() throws {
        let home = try KeyHome(accounts: [Self.sideOpenRouter, .xAI, .fireworks])
        let settings = AppSettings.ephemeral()
        settings.money.accountIDs[.xAI] = "team-00000000"
        let now = MoneyModelTests.now
        let records: [MoneyAccount: MoneySourceRecord] = [
            Self.sideOpenRouter: Self.everyKind[Self.sideOpenRouter]!,
            .xAI: MoneySourceRecord(lastError: .idInvalid("Team ID"), lastErrorAt: now - 30, keyFileName: "management-key"),
            .fireworks: MoneySourceRecord(lastError: .idMissing("Account ID"), lastErrorAt: now - 30, keyFileName: "key"),
        ]
        let (env, _) = MoneyModelTests.live(records, settings: settings, home: home.path)
        try settingsPane("Money-settings-first-key-gone", env: env, preview: [
            .fireworks: MoneyKeyPreview(mode: .idle, idRefusal: MoneySource.fireworks.notAnIDWord),
        ])
        withExtendedLifetime(home) {}
    }
}
