import AppKit
import IslandEngine
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The accounts lane (P360 to P363): Diagnostics › Accounts by login, a No plan battery on the panel and the island, and
/// Settings › Accounts with Remove. `RRenders`' fixture (`LiveUsageModel` on `LiveFakes`: fictional folders and emails,
/// logged fake readers, a temp store) with every login read 10 s ago, `jordan.riverside@example.com`'s subscription
/// ended (four "no plan limits" answers over 35 minutes) and `ren@example.com` held by a 429. Every question is held and
/// nothing is due, so nothing is read during a render. Headless; nothing is shown.
@MainActor
@Suite(.serialized)
struct AccountsRenders {
    static let ended = LoginsStore.id(provider: .claude, email: "jordan.riverside@example.com")
    static let limited = LoginsStore.id(provider: .codex, email: "ren@example.com")

    static func fixture(_ fakes: LiveFakes) throws {
        try RRenders.fixture(fakes)
        let now = DemoClock.now
        let logins = LoginsStore(fileURL: fakes.directory.appendingPathComponent("logins.json"))
        logins.load()
        for (id, login) in logins.logins {
            guard var reading = login.record?.lastGood else { continue }
            // The ended login's last good reading came before its answers.
            reading.readAt = now - (id == ended ? 3_000 : 10)
            logins.apply(.success(reading), to: id, at: reading.readAt)
        }
        for minutes in [-40.0, -35, -25, -5] { logins.apply(.failure(.noPlanLimits), to: ended, at: now + minutes * 60) }
        logins.apply(.failure(.rateLimited(retryAfter: 60)), to: limited, at: now - 120)
        try logins.save()
        // readings.json follows, as the app writes it (each folder's record its login's).
        let accounts = AccountsStore(fileURL: fakes.directory.appendingPathComponent("accounts.json"))
        let readings = ReadingsStore(fileURL: fakes.directory.appendingPathComponent("readings.json"))
        accounts.load()
        readings.load()
        readings.replace(logins.projection(of: accounts.accounts, onto: readings.records, now: now))
        try readings.save()
    }

    /// The model on the fixture, reading, with every question held.
    static func model(_ fakes: LiveFakes) async throws -> LiveUsageModel {
        try fixture(fakes)
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

    /// One row per login, named by its folders' aliases: two logins in two folders each, a login switched off, the No
    /// plan login with its 6-hour wait, the 429 with its retry time in Next, then the folders signed out and being asked.
    @Test func diagnosticsByLogin() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let model = try await Self.model(fakes)
        defer {
            model.stop()
            fakes.holdQuestions.withValue { $0 = false }
        }
        model.setMonitored(login: LoginsStore.id(provider: .claude, email: "jordan.rivera@example.com"), false)
        let rows = DiagnosticsText.accounts(model.logins, records: model.records, schedule: { model.schedule(of: $0) },
                                            question: { model.question(forFolder: $0) }, now: model.now)
        #expect(rows.map(\.label) == ["Main + Lab", "Work", "Studio", "Research", "Alt", "Home + Side", "Fresh", "Preset", "Night"])
        #expect(rows.map(\.line.status) == ["OK", "Not monitored", "No plan", "New · first read due", "Sign-in required", "OK",
                                            "Rate limited", "New · first read due", "Sign-in required"])
        #expect(rows[2].line.next == "in 6h" && rows[0].line.next == "in 5m" && rows[5].line.next == "in 51s")
        #expect(rows[6].line.next == DiagnosticsText.hhmm(DemoClock.now - 119 + 960))
        try settings(.diagnostics, "K-settings-diagnostics-logins", env: RRenders.environment(model))
    }

    /// The No plan battery, dimmed with its words: on the desktop panel, in the island's usage section, and in the
    /// header strip opened on it with its hover.
    @Test func noPlanBattery() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let model = try await Self.model(fakes)
        defer {
            model.stop()
            fakes.holdQuestions.withValue { $0 = false }
        }
        let battery = try #require(model.claudeRow?.batteries.first { $0.id == Self.ended })
        #expect(battery.state == .noPlan && !battery.isNext)
        #expect(HoverLabelText.full(.account(Self.ended), usage: model)?.text == "jordan.riverside · " + NoPlanStreak.hover)
        let env = RRenders.environment(model)
        let content = DesktopPanelContent.make(usage: env.usage, settings: env.settings)
        let size = try #require(content.size)
        try RenderHarness.render(DesktopPanelView().padding(PanelGeometry.margin), "K-panel-no-plan",
                                 size: PanelGeometry.windowSize(for: size), env: env, background: PRenders.wallpaper)
        let notch = IslandTheme.Metrics.referenceNotch
        env.settings.islandUsagePlacement = .section
        try RenderHarness.render(DScene.island(OpenedIslandView(presentation: .list, notch: notch, ui: IslandUIState(), animated: false),
                                               notch: notch), "K-island-usage-no-plan", env: env)
        env.settings.islandUsagePlacement = .headerStrip
        try RenderHarness.render(DScene.island(OpenedIslandView(presentation: .list, notch: notch,
                                                                ui: IslandUIState(hover: .account(Self.ended), stripOpen: true), animated: false),
                                               notch: notch), "K-island-strip-no-plan", env: env)
        try RenderHarness.render(VStack(spacing: 12) { AccountListView(provider: .claude) }.padding(12), "K-account-list-no-plan",
                                 env: env, background: Color(hex: 0x1A2420))
    }

    /// Settings › Accounts: the No plan row offers Remove in its plan's place; then two rows as Remove leaves them for
    /// 3 s, asking once more ("Remove — click again"): the No plan row after its Remove, and a row after its menu's
    /// Remove Account.
    @Test func accountsWithRemove() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let model = try await Self.model(fakes)
        defer {
            model.stop()
            fakes.holdQuestions.withValue { $0 = false }
        }
        model.refreshDiscovery()
        await model.discovery?.value
        let env = RRenders.environment(model)
        try settings(.accounts, "K-settings-accounts-no-plan", env: env)
        let claude = try #require(model.list(.claude))
        let ended = try #require(claude.logins.first { $0.id == Self.ended }), first = try #require(claude.logins.first)
        let armed = RemoveConfirmation(armedAt: DemoClock.now)
        let rows = FormPane {
            FormSection("Claude") {
                LoginRowView(row: first, now: model.now, home: model.home, monitor: { _ in }, stopMonitoring: { _ in }, forget: { _ in },
                             remove: {}, removal: armed)
                LoginRowView(row: ended, now: model.now, home: model.home, monitor: { _ in }, stopMonitoring: { _ in }, forget: { _ in },
                             remove: {}, removal: armed)
                LoginRowView(row: ended, now: model.now, home: model.home, monitor: { _ in }, stopMonitoring: { _ in }, forget: { _ in },
                             remove: {})
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        try RenderHarness.render(rows, "K-settings-accounts-remove", size: CGSize(width: 620, height: 210), env: env,
                                 background: SettingsTheme.window)
    }
}
