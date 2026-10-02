import AppKit
import IslandEngine
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// P580 and P581 on the surfaces: one email in a personal Max plan (`~/.claude`) and in a Team organization
/// (`~/.claude-lab`, "Research Lab") is two rows and two batteries, the organization's named beside the email and after
/// the battery's name; another email's Enterprise organization billed by usage (`~/.claude-studio`, "Northwind") is No
/// limits. `LiveUsageModel` on `LiveFakes`: fictional folders, emails and organizations, every login read 10 s ago,
/// every question held, so nothing is read during a render. Headless; nothing is shown.
@MainActor
@Suite(.serialized)
struct OrgRenders {
    static let sam = "sam@example.com", jordan = "jordan@example.com"
    static let personal = LoginIdentity(email: sam, org: LoginOrganization.key(for: "0b7e5c2a-1111-4c3d-9e8f-000000000001"))
    static let research = LoginIdentity(email: sam, org: LoginOrganization.key(for: "0b7e5c2a-2222-4c3d-9e8f-000000000002"), orgName: "Research Lab")
    static let northwind = LoginIdentity(email: jordan, org: LoginOrganization.key(for: "0b7e5c2a-3333-4c3d-9e8f-000000000003"), orgName: "Northwind")

    /// `mainUsed`: how much of `~/.claude`'s Max plan is used; `studioAnswer`: what Northwind's reads said.
    static func fixture(_ fakes: LiveFakes, mainUsed: Double = 40, studioAnswer: ReadError = .noLimitsReported) throws {
        let home = LiveFakes.home, now = DemoClock.now
        let main = Account(provider: .claude, folder: home + "/.claude", alias: "Main")
        let lab = Account(provider: .claude, folder: home + "/.claude-lab", alias: "Lab")
        let studio = Account(provider: .claude, folder: home + "/.claude-studio", alias: "Studio")
        let codex = Account(provider: .codex, folder: home + "/.codex", alias: "Home")
        try fakes.writeStore(accounts: [main, lab, studio, codex])
        let logins = LoginsStore(fileURL: fakes.directory.appendingPathComponent("logins.json"))
        let held: [(Account, LoginIdentity, String, Double)] = [
            (main, personal, "max", mainUsed), (lab, research, "team", 25), (codex, LoginIdentity(email: sam), "plus", 30),
        ]
        for (folder, who, plan, used) in held {
            let id = logins.place(who, in: folder, now: now).login
            logins.apply(.success(AccountReading(accountID: id, readAt: now - 10, plan: plan, windows: [
                UsageWindow(seconds: 18_000, usedPercent: used, resetsAt: now + 1_320),
                UsageWindow(seconds: 604_800, usedPercent: used / 2, resetsAt: now + 3 * 86_400),
            ])), to: id, at: now - 10)
            fakes.claudeFolders.withValue {
                $0[folder.folder] = LiveFakes.ClaudeFolder(who: .success(SignInIdentity(email: who.email, plan: plan, org: who.org,
                                                                                           orgName: who.orgName)), stamp: nil)
            }
        }
        // Northwind reports no limits (or, its seat taken away, no plan limits): four answers over 35 minutes.
        let studioID = logins.place(northwind, in: studio, now: now).login
        for minutes in [-35.0, -30, -20, -5] { logins.apply(.failure(studioAnswer), to: studioID, at: now + minutes * 60) }
        fakes.codex(codex, sam, stamp: nil)
        try logins.save()
        let accounts = AccountsStore(fileURL: fakes.directory.appendingPathComponent("accounts.json"))
        let readings = ReadingsStore(fileURL: fakes.directory.appendingPathComponent("readings.json"))
        accounts.load()
        readings.load()
        readings.replace(logins.projection(of: accounts.accounts, onto: readings.records, now: now))
        try readings.save()
    }

    static func model(_ fakes: LiveFakes, mainUsed: Double = 40, studioAnswer: ReadError = .noLimitsReported) async throws -> LiveUsageModel {
        try fixture(fakes, mainUsed: mainUsed, studioAnswer: studioAnswer)
        fakes.holdQuestions.withValue { $0 = true }
        let model = fakes.model()
        model.start()
        await model.wiring?.value
        return model
    }

    private func settings(_ pane: SettingsPane, _ name: String, env: AppEnvironment) throws {
        let view = SettingsRootView(navigation: SettingsNavigation(pane: pane), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    /// Settings › Accounts and Diagnostics: a row per login, the organization after the email (the personal one as the
    /// email alone); the No limits row keeps its plan's place (no Remove: nothing ended).
    @Test func accountsWithOrganizations() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let model = try await Self.model(fakes)
        defer {
            model.stop()
            fakes.holdQuestions.withValue { $0 = false }
        }
        let claude = try #require(model.list(.claude))
        #expect(claude.logins.map(\.title) == [Self.sam, Self.sam + " · Research Lab", Self.jordan + " · Northwind"])
        #expect(claude.logins.map(\.battery.state) == [.available(percentLeft: 60, isLow: false), .available(percentLeft: 75, isLow: false), .noLimits])
        #expect(fakes.reads.isEmpty)
        let env = RRenders.environment(model)
        try settings(.accounts, "O-settings-accounts-orgs", env: env)
        let rows = DiagnosticsText.accounts(model.logins, records: model.records, schedule: { model.schedule(of: $0) }, now: model.now)
        #expect(rows.map(\.label) == ["Main", "Lab · Research Lab", "Studio · Northwind", "Home"])
        #expect(rows.map(\.line.status) == ["OK", "OK", "No limits", "OK"])
        // Copy Report names an organization only as the list does: never an email, an organization's id or its key.
        let report = DiagnosticsText.report(lines: rows.map { ($0.label, $0.provider, $0.line) }, money: [])
        #expect(report.contains("  Claude Lab · Research Lab: OK") && report.contains("  Claude Studio · Northwind: No limits"))
        #expect(!report.contains("@") && !report.contains("0b7e5c2a"))
        for key in [Self.personal.org, Self.research.org, Self.northwind.org].compactMap({ $0 }) { #expect(!report.contains(key)) }
        try settings(.diagnostics, "O-settings-diagnostics-orgs", env: env)
    }

    /// The batteries: the desktop panel, the island's usage section and its header strip hovering the organization's
    /// battery, and the window's account list.
    @Test func batteriesWithOrganizations() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let model = try await Self.model(fakes)
        defer {
            model.stop()
            fakes.holdQuestions.withValue { $0 = false }
        }
        let batteries = try #require(model.claudeRow?.batteries)
        #expect(batteries.map(\.alias) == ["sam", "sam · Research Lab", "jordan · Northwind"])
        #expect(batteries.map(\.isNext) == [true, false, false])
        let lab = batteries[1]
        #expect(HoverLabelText.full(.account(lab.id), usage: model)?.name == "sam · Research Lab")
        let env = RRenders.environment(model)
        env.settings.islandUsagePlacement = .section
        env.settings.accountNamesUnderBatteries = true
        let content = DesktopPanelContent.make(usage: env.usage, settings: env.settings)
        let size = try #require(content.size)
        try RenderHarness.render(DesktopPanelView().padding(PanelGeometry.margin), "O-panel-orgs",
                                 size: PanelGeometry.windowSize(for: size), env: env, background: PRenders.wallpaper)
        // On Glass (P561) the organization's names and No limits' words take the look's ink: light glass over white,
        // dark over black (the render stand-in, so `standin` in the name).
        for backdrop in [GlassBackdrop.white, .black] {
            let window = PanelGeometry.windowSize(for: size)
            try RenderHarness.render(PanelGlassRenders.staged(DesktopPanelView().padding(PanelGeometry.margin), backdrop, .glass, size: window),
                                     "O-standin-glass-panel-orgs-\(backdrop.rawValue)", size: window, env: env)
        }
        let notch = IslandTheme.Metrics.referenceNotch
        try RenderHarness.render(DScene.island(OpenedIslandView(presentation: .list, notch: notch, ui: IslandUIState(), animated: false),
                                               notch: notch), "O-island-usage-orgs", env: env)
        env.settings.islandUsagePlacement = .headerStrip
        try RenderHarness.render(DScene.island(OpenedIslandView(presentation: .list, notch: notch,
                                                                ui: IslandUIState(hover: .account(lab.id), stripOpen: true), animated: false),
                                               notch: notch), "O-island-strip-hover-orgs", env: env)
        try RenderHarness.render(VStack(spacing: 12) { AccountListView(provider: .claude, selected: lab.id) }.padding(12),
                                 "O-account-list-orgs", env: env, background: Color(hex: 0x1A2420))
    }

    /// P584 and P583: the Max plan used up, so the organization's login is Next and the account list names it whole; and
    /// Northwind's seat taken away (its reads say no plan limits with the Team plan named), so it is No plan, "subscription
    /// ended?", with Remove in its row, never "billed by usage".
    @Test func organizationNextAndASeatTakenAway() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let model = try await Self.model(fakes, mainUsed: 100, studioAnswer: .noPlanLimits)
        defer {
            model.stop()
            fakes.holdQuestions.withValue { $0 = false }
        }
        let row = try #require(model.claudeRow)
        #expect(row.batteries.map(\.alias) == ["sam", "sam · Research Lab", "jordan · Northwind"])
        #expect(row.batteries.map(\.isNext) == [false, true, false] && row.batteries.last?.state == .noPlan)
        #expect(AccountListText.summary(row) == "1 of 2 available · next sam · Research Lab")
        #expect(AccountListText.detail(row.batteries[2], usage: model).text == "subscription ended?")
        #expect(fakes.reads.isEmpty)
        let env = RRenders.environment(model)
        try settings(.accounts, "O-settings-accounts-org-ended", env: env)
        try RenderHarness.render(VStack(spacing: 12) { AccountListView(provider: .claude, selected: row.batteries[1].id) }.padding(12),
                                 "O-account-list-org-next", env: env, background: Color(hex: 0x1A2420))
    }
}
