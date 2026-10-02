import AppKit
import IslandEngine
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The readers stream: Settings › Accounts in the release build (`LiveUsageModel` on `LiveFakes`: fictional folders,
/// logged fake readers, a temp store). Headless; nothing is shown and nothing real is read.
@MainActor
@Suite(.serialized)
struct RRenders {
    /// Six Claude folders and five Codex homes, and two folders found on this Mac that are not accounts yet. Each
    /// provider has one account in two folders (`~/.claude` and `~/.claude-lab`, `~/.codex` and `~/.codex-side`), a
    /// folder signed out and one not asked yet; the Codex account `~/.codex-night` held before its sign-out keeps its
    /// reading, with no row. logins.json says who each folder holds, and each folder's CLI answers the same, so nothing
    /// moves when a render with a CLI asks.
    static func fixture(_ fakes: LiveFakes) throws {
        let home = LiveFakes.home, now = DemoClock.now
        func account(_ provider: Provider, _ suffix: String, _ alias: String) -> Account {
            Account(provider: provider, folder: home + "/." + provider.rawValue + suffix, alias: alias)
        }
        let claude = [account(.claude, "", "Main"), account(.claude, "-work", "Work"), account(.claude, "-lab", "Lab"),
                      account(.claude, "-studio", "Studio"), account(.claude, "-research", "Research"), account(.claude, "-alt", "Alt")]
        let codex = [account(.codex, "", "Home"), account(.codex, "-side", "Side"), account(.codex, "-fresh", "Fresh"),
                     account(.codex, "-preset", "Preset"), account(.codex, "-night", "Night")]
        var records: [String: AccountRecord] = [:]
        let lefts: [Double] = [82, 100, 82, 0, 64, 12, 71, 71, 90, 12, 40]
        for (index, account) in (claude + codex).enumerated() {
            let left = lefts[index], plan = account.provider == .claude ? (index < 3 ? "max" : "pro") : (index < 2 + 6 ? "pro" : "plus")
            records[account.id] = AccountRecord(lastGood: AccountReading(accountID: account.id, readAt: now - 60, plan: plan, windows: [
                UsageWindow(seconds: 18_000, usedPercent: 100 - left, resetsAt: now + 1_320),
                UsageWindow(seconds: 604_800, usedPercent: (100 - left) / 2, resetsAt: now + 3 * 86_400),
            ]), lastAttemptAt: now - 60)
        }
        let night = records[codex[4].id]
        records[claude[5].id] = AccountRecord(lastError: .signInRequired, lastErrorAt: now - 3_600, lastAttemptAt: now - 3_600)
        records[codex[4].id] = AccountRecord(lastError: .signInRequired, lastErrorAt: now - 3_600, lastAttemptAt: now - 3_600)
        try fakes.writeStore(accounts: claude + codex, records: records)
        let holds: [(Account, String)] = [
            (claude[0], "sam@example.com"), (claude[1], "jordan.rivera@example.com"), (claude[2], "sam@example.com"),
            (claude[3], "jordan.riverside@example.com"), (codex[0], "sam@example.com"), (codex[1], "sam@example.com"), (codex[2], "ren@example.com"),
        ]
        let logins = LoginsStore(fileURL: fakes.directory.appendingPathComponent("logins.json"))
        for (folder, email) in holds {
            logins.place(email, in: folder, record: records[folder.id], now: now)
            if folder.provider == .claude { fakes.claude(folder, email, stamp: nil) } else { fakes.codex(folder, email, stamp: nil) }
        }
        logins.place("noor@example.com", in: codex[4], record: night, now: now)
        logins.signOut(claude[5].id)
        logins.signOut(codex[4].id)
        fakes.claude(claude[5], nil, stamp: nil)
        fakes.codex(codex[4], nil, stamp: nil)
        try logins.save()
        fakes.discovered = [DiscoveredProfile(provider: .claude, folder: home + "/.claude-demo", suggestedAlias: "demo"),
                            DiscoveredProfile(provider: .codex, folder: home + "/.codex-spare", suggestedAlias: "spare")]
    }

    static func environment(_ model: LiveUsageModel) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.usageSource = .juiceReadings
        return AppEnvironment(settings: settings, usage: model, sessions: FixtureSessionFeed(scenario: .allStates, now: DemoClock.now).makeModel())
    }

    private func render(_ model: LiveUsageModel, _ name: String) throws {
        let env = Self.environment(model)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .accounts), drawsTrafficLights: true, scrolls: false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    /// No CLI found: every account as the store left it, its plan or Sign In, the found folders with Add; the folders not
    /// placed yet show nothing, and one line says which CLIs are missing.
    @Test func accountsLive() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try Self.fixture(fakes)
        fakes.located = [:]                                   // nothing is read during the render
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.wiring?.value
        model.refreshDiscovery()
        await model.discovery?.value
        #expect(model.missingCLIs == [.claude, .codex] && model.asking.isEmpty && model.unanswered.isEmpty)
        #expect(LiveAccountsText.statusLine(model) == "Claude and Codex CLIs not found")
        try render(model, "R-settings-accounts-live")
    }

    /// Standalone Juice runs: one line, the list shown as Juice left it, nothing to add.
    @Test func accountsJuiceRunning() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try Self.fixture(fakes)
        fakes.running = [LiveFakes.juiceApp]
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        model.refreshDiscovery()
        await model.discovery?.value
        try render(model, "R-settings-accounts-juice-running")
    }

    /// P93: one row per account, titled by its email, with the folders that hold it under it. `~/.claude` and
    /// `~/.claude-lab` hold one account, as `~/.codex` and `~/.codex-side` do, so each has one row and one battery; the
    /// folders signed out (Sign In) and being asked who is signed in ("…") follow, titled by their paths; a Codex account
    /// no folder holds any more has no row. Every question is held, so nothing is answered or read.
    @Test func accountsByLogin() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try Self.fixture(fakes)
        fakes.holdQuestions.withValue { $0 = true }
        let model = fakes.model()
        defer {
            model.stop()
            fakes.holdQuestions.withValue { $0 = false }
        }
        model.start()
        await model.wiring?.value
        let claude = try #require(model.list(.claude)), codex = try #require(model.list(.codex))
        #expect(claude.logins.map(\.email) == ["sam@example.com", "jordan.rivera@example.com", "jordan.riverside@example.com"])
        #expect(claude.logins.first?.folders.map(\.alias) == ["Main", "Lab"])
        #expect(claude.folders.map(\.folder.alias) == ["Research", "Alt"] && claude.folders.map(\.state) == [.unknown, .signedOut])
        #expect(codex.logins.map(\.email) == ["sam@example.com", "ren@example.com"])
        #expect(codex.logins.map { $0.folders.map(\.alias) } == [["Home", "Side"], ["Fresh"]])
        #expect(codex.folders.map(\.folder.alias) == ["Preset", "Night"] && codex.folders.map(\.state) == [.unknown, .signedOut])
        #expect(model.claudeRow?.batteries.map(\.alias) == ["sam", "jordan.rivera", "jordan.riverside"])
        #expect(model.codexRow?.batteries.map(\.alias) == ["sam", "ren"] && model.panel.attentionNeeded)
        #expect(LiveAccountsText.folders(claude.logins[0].folders, home: model.home) == "~/.claude · ~/.claude-lab")
        #expect(model.asking == [claude.folders[0].id, codex.folders[0].id] && fakes.reads.isEmpty)
        model.refreshDiscovery()
        await model.discovery?.value
        try render(model, "R-settings-accounts-logins")
    }

    /// The same accounts on the usage surfaces: one battery per account, named by its email's local part, in the island's
    /// usage section and header strip (hovering the shared Codex account), the window's header with names under the
    /// batteries, the account lists a battery opens, and the desktop panel.
    @Test func usageByLogin() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try Self.fixture(fakes)
        fakes.located = [:]
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.wiring?.value
        let env = Self.environment(model)
        env.settings.islandUsagePlacement = .section
        env.settings.accountNamesUnderBatteries = true
        env.settings.windowHeader = .section
        let shared = try #require(model.codexRow?.batteries.first)
        #expect(HoverLabelText.full(.account(shared.id), usage: model)?.name == "sam")
        // A battery's menu copies its account's email.
        #expect(model.email(of: shared.id) == "sam@example.com" && PanelActions.desktop(env: env).email(shared.id) == "sam@example.com")
        let notch = IslandTheme.Metrics.referenceNotch
        try RenderHarness.render(DScene.island(OpenedIslandView(presentation: .list, notch: notch, ui: IslandUIState(), animated: false),
                                               notch: notch), "R-island-usage-logins", env: env)
        env.settings.islandUsagePlacement = .headerStrip
        try RenderHarness.render(DScene.island(OpenedIslandView(presentation: .list, notch: notch,
                                                                ui: IslandUIState(hover: .account(shared.id), stripOpen: true), animated: false),
                                               notch: notch), "R-island-strip-hover-logins", env: env)
        let header = WindowHeaderView(drawsTrafficLights: true).frame(width: 1200).padding(8).background(Color.black)
        let height = ceil(NSHostingView(rootView: header.fixedSize(horizontal: false, vertical: true).environment(env)
            .environment(\.colorScheme, .dark)).fittingSize.height)
        try RenderHarness.renderHosted(header, "R-window-header-logins", size: CGSize(width: 1216, height: height), env: env)
        try RenderHarness.render(VStack(spacing: 12) {
            AccountListView(provider: .claude)
            AccountListView(provider: .codex, selected: shared.id)
        }.padding(12), "R-account-list-logins", env: env, background: Color(hex: 0x1A2420))
        let content = DesktopPanelContent.make(usage: env.usage, settings: env.settings)
        let size = try #require(content.size)
        try RenderHarness.render(DesktopPanelView().padding(PanelGeometry.margin), "R-panel-logins",
                                 size: PanelGeometry.windowSize(for: size), env: env, background: PRenders.wallpaper)
    }

    /// A Refresh all in progress, and a sign-in that failed (no CLI found), each with its one line.
    @Test func accountsRefreshingAndSignInFailed() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try Self.fixture(fakes)
        fakes.located = [:]
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.wiring?.value
        fakes.clock.now += 600
        model.refreshAll()
        await model.wiring?.value
        let alt = try #require(model.accounts.first { $0.alias == "Alt" })
        #expect(model.signIn(id: alt.id))
        for _ in 0..<100 where model.signInPhase(for: alt.id).map({ if case .failed = $0 { false } else { true } }) ?? true {
            try await Task.sleep(for: .milliseconds(10))
        }
        try render(model, "R-settings-accounts-refreshing")
    }

    /// A Claude sign-in whose page ends on a code: the CLI (a fake in the temp store) printed its URL and asks for the
    /// code, so the row has the field to paste it into; then the same row after the CLI refused a code.
    @Test func accountsSignInWantsACode() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try Self.fixture(fakes)
        fakes.located = [.claude: try fakes.loginCLI("claude", """
            echo "If the browser didn't open, visit: https://example.com/oauth/authorize?code=true&state=demo"
            printf 'Paste code here if prompted > '
            while read -r code; do echo "Invalid code. Please make sure the full code was copied." >&2; done
            exit 1
            """)]
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.wiring?.value
        let alt = try #require(model.accounts.first { $0.alias == "Alt" })
        #expect(model.signIn(id: alt.id))
        #expect(await Self.waitUntil { if case .inBrowser(_?, true)? = model.signInPhase(for: alt.id) { true } else { false } })
        try render(model, "R-settings-accounts-sign-in-code")
        model.signInCoordinator.submitCode("half-a-code")
        #expect(await Self.waitUntil { model.signInCoordinator.codeRefused })
        try render(model, "R-settings-accounts-sign-in-code-refused")
        model.signInCoordinator.cancel()
    }

    /// A Codex sign-in by one-time code: the CLI (a fake in the temp store) printed the page and the code to type
    /// there, shown with Copy.
    @Test func accountsSignInShowsADeviceCode() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try Self.fixture(fakes)
        fakes.located = [.codex: try fakes.loginCLI("codex", """
            printf '1. Open this link in your browser and sign in to your account\\n   https://example.com/codex/device\\n\\n'
            printf '2. Enter this one-time code (expires in 15 minutes)\\n   ABCD-EFGH\\n\\n'
            read -r never
            exit 1
            """)]
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.wiring?.value
        let night = try #require(model.accounts.first { $0.alias == "Night" })
        #expect(model.signIn(id: night.id))
        #expect(await Self.waitUntil { model.signInCoordinator.deviceCode != nil && model.signInCoordinator.lastURL != nil })
        try render(model, "R-settings-accounts-sign-in-device-code")
        model.signInCoordinator.cancel()
    }

    /// "+" opens the name row under Claude's header: the new folder's path as it is typed, then Add; then the same row
    /// with a name the account list already has ("Exists", Add greyed). Every question is held, so nothing moves.
    @Test func accountsAdd() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try Self.fixture(fakes)
        fakes.holdQuestions.withValue { $0 = true }
        let model = fakes.model()
        defer {
            model.stop()
            fakes.holdQuestions.withValue { $0 = false }
        }
        model.start()
        await model.wiring?.value
        model.refreshDiscovery()
        await model.discovery?.value
        #expect(model.canAddAccount(.claude) && model.canAddAccount(.codex))
        model.newAccount = NewAccountDraft(provider: .claude, name: "side")
        #expect(model.checkNewAccount("side", provider: .claude) == .new(folder: LiveFakes.home + "/.claude-side"))
        try render(model, "R-settings-accounts-add")
        model.newAccount = NewAccountDraft(provider: .claude, name: "work")
        #expect(model.checkNewAccount("work", provider: .claude) == .problem(.exists))
        try render(model, "R-settings-accounts-add-exists")
    }

    /// No folder at all: each provider offers Add Account, or says its CLI is missing (Codex here), and nothing else.
    @Test func accountsEmpty() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [])
        fakes.located = [.claude: URL(fileURLWithPath: "/fake/bin/claude")]
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        model.refreshDiscovery()
        await model.discovery?.value
        #expect(model.logins.isEmpty && model.canAddAccount(.claude) && model.isMissingCLI(.codex))
        try render(model, "R-settings-accounts-empty")
    }

    /// After "+" made `~/.claude-demo` and `~/.codex-spare` and each signed in: their rows, and under each Setup's words
    /// for that folder's session hooks. The Claude folder offers Install, which only a click would run (nothing is
    /// installed here: the fake records every click); the Codex home, installed since, says to run /hooks once.
    @Test func accountsAddedOffersHooks() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        fakes.located = [.claude: try fakes.loginCLI("claude", "exit 0"), .codex: try fakes.loginCLI("codex", "exit 0")]
        try fakes.writeStore(accounts: [])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let demo = try model.addAccount("demo", provider: .claude).get()
        #expect(await Self.waitUntil { model.signingIn.isEmpty })
        let spare = try model.addAccount("spare", provider: .codex).get()
        #expect(await Self.waitUntil { model.signingIn.isEmpty })
        await model.settle()
        let env = Self.environment(model)
        let hooks = RecordingHooks(rows: [
            RecordingHooks.row(demo, word: "Not installed", action: .install, home: home),
            RecordingHooks.row(spare, word: "Needs /hooks", detail: HookRowText.trustHint, amber: true, action: .remove, home: home),
        ])
        env.hooks = hooks
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .accounts), drawsTrafficLights: true, scrolls: false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "R-settings-accounts-added-hooks", size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
        #expect(hooks.clicks.isEmpty && model.added == [demo.id, spare.id])
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}

/// Setup's rows for a render, with every click recorded instead of run.
@MainActor
final class RecordingHooks: HooksModel {
    let rows: [HookSetupRow]
    let alerts: [HookDriftAlert] = []
    let integrations = HookIntegrations(openIslandRunning: false, vibeProfiles: 0, helperInBuild: true)
    let lastEvents: [String: Date] = [:]
    private(set) var clicks: [String] = []

    init(rows: [HookSetupRow]) { self.rows = rows }

    /// A row for a folder, with the id Setup gives it (the resolved path).
    static func row(_ account: Account, word: String, detail: String? = nil, amber: Bool = false, action: ProfileHookAction?,
                    home: String) -> HookSetupRow {
        HookSetupRow(id: Account.id(provider: account.provider, folder: ProfileHookTargets.normalized(account.folder)),
                     provider: account.provider, alias: account.alias, folder: LiveAccountsText.folder(account.folder, home: home),
                     word: word, detail: detail, tone: amber ? .amber : .normal, action: action, refusal: nil, busy: false,
                     events: action == .install ? "0/14" : "4/4", isMonitored: true)
    }

    func clickRefusal(for id: String) -> String? { nil }
    func perform(_ action: ProfileHookAction, on id: String) { clicks.append("\(action) \(id)") }
    func installAllMonitored() { clicks.append("install all") }
    func activate() {}
}
