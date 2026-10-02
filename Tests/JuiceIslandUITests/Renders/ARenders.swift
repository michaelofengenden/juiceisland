import AppKit
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Stream A: the window shell and toolbar, and the Settings window with each pane. Refs: `refs/A-*.png`.
/// Settings panes render at their full height (no scrolling), like the prototype's auto-height window.
@MainActor
@Suite(.serialized)
struct ARenders {
    /// The prototype's sessions, with the Demo badge the app shows while Live sessions is off.
    private static func windowEnv() -> AppEnvironment { withBadge(.demo(sessions: .prototype)) }

    static func withBadge(_ env: AppEnvironment) -> AppEnvironment {
        env.liveSessions = LiveSessions(settings: env.settings, demo: { [sessions = env.sessions] in sessions })
        return env
    }

    @Test func windowOverview1200() throws {
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), "A-window-overview-1200",
                                       size: WindowTheme.Metrics.defaultSize, env: Self.windowEnv())
    }

    @Test func windowOverview900() throws {
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), "A-window-overview-900",
                                       size: CGSize(width: 900, height: 760), env: Self.windowEnv())
    }

    @Test func windowToolbar() throws {
        try RenderHarness.renderHosted(WindowToolbarView(drawsTrafficLights: true).background(Color.black), "A-toolbar-1200",
                                       size: CGSize(width: 1200, height: WindowChromeMetrics.standard.lineHeight), env: Self.windowEnv())
    }

    @Test func windowOverviewMinimum() throws {
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), "A-window-overview-min",
                                       size: WindowTheme.Metrics.minSize, env: Self.windowEnv())
    }

    /// The owner's own setup: one Claude and one Codex account whose readings are days old, no money reader.
    @Test func windowOverviewTwoAccounts() throws {
        let (env, directory) = try Self.twoAccountEnv()
        defer { try? FileManager.default.removeItem(at: directory) }
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), "A-window-two-accounts-1200",
                                       size: WindowTheme.Metrics.defaultSize, env: env)
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), "A-window-two-accounts-min",
                                       size: WindowTheme.Metrics.minSize, env: env)
    }

    // MARK: The real window, offscreen

    /// The main window itself (AppKit's title bar and traffic lights), never ordered on screen: the toolbar line must
    /// share the lights' line, with nothing between them and the header's content.
    @Test(arguments: [("1200", WindowTheme.Metrics.defaultSize), ("900", CGSize(width: 900, height: 760)),
                      ("min", WindowTheme.Metrics.minSize)])
    func windowChrome(_ name: String, _ size: CGSize) throws {
        let controller = MainWindowController(env: Self.windowEnv())
        let url = try RenderHarness.renderWindow(controller.window, "A-window-chrome-\(name)", contentSize: size)
        try Self.expectBrandOnTheLightsLine(url, window: controller.window)
    }

    @Test func windowChromeTwoAccounts() throws {
        let (env, directory) = try Self.twoAccountEnv()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MainWindowController(env: env)
        let url = try RenderHarness.renderWindow(controller.window, "A-window-chrome-two-accounts-1200",
                                                 contentSize: WindowTheme.Metrics.defaultSize)
        try Self.expectBrandOnTheLightsLine(url, window: controller.window)
    }

    /// The brand glyph (orange) is drawn right after the zoom button, on the lights' centre line.
    static func expectBrandOnTheLightsLine(_ url: URL, window: NSWindow) throws {
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        let metrics = WindowChromeMetrics.measure(window)
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        var found = false
        let centre = Int(metrics.lineHeight / 2 * scale)
        for y in (centre - 6)...(centre + 6) {
            for x in Int(metrics.contentLeading * scale)..<Int((metrics.contentLeading + 20) * scale) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if colour.redComponent > 0.6, colour.blueComponent < 0.5 { found = true }
            }
        }
        #expect(found, "no brand glyph on the traffic lights' line")
    }

    /// Juice's two files with one Claude and one Codex account, read three days ago; no money reader.
    static func twoAccountEnv() throws -> (AppEnvironment, URL) {
        let directory = try JuiceReadingsUsageModelTests.makeDirectory()
        let now = JuiceReadingsUsageModelTests.now
        func old(_ account: Account, left: Double) -> AccountRecord {
            AccountRecord(lastGood: AccountReading(accountID: account.id, readAt: now - 3 * 86_400, plan: "pro", windows: [
                UsageWindow(seconds: 18_000, usedPercent: 100 - left, resetsAt: now - 2 * 86_400),
            ]), lastAttemptAt: now - 3 * 86_400)
        }
        let work = JuiceReadingsUsageModelTests.work, side = JuiceReadingsUsageModelTests.side
        try JuiceReadingsUsageModelTests.write(directory, records: [work.id: old(work, left: 64), side.id: old(side, left: 30)])
        let usage = JuiceReadingsUsageModelTests.model(directory)
        let feed = FixtureSessionFeed(scenario: .prototype, now: now)
        let sessions = feed.makeModel()
        let env = AppEnvironment(settings: .ephemeral(), usage: usage, sessions: sessions)
        // The badge's switch also keeps the demo feed alive.
        env.liveSessions = LiveSessions(settings: env.settings, demo: { _ = feed; return sessions })
        return (env, directory)
    }

    @Test(arguments: SettingsPane.allCases)
    func settingsPane(_ pane: SettingsPane) throws {
        try renderSettings(pane, name: "A-settings-\(Self.refName(pane))", env: .demo())
    }

    /// The dev build's mirror of Juice's readings: only Juice's accounts, read-only, one of them signed out.
    @Test func settingsAccountsMirror() throws {
        let directory = try JuiceReadingsUsageModelTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = JuiceReadingsUsageModelTests.work, side = JuiceReadingsUsageModelTests.side
        try JuiceReadingsUsageModelTests.write(directory, records: [
            work.id: JuiceReadingsUsageModelTests.record(work, left: 64),
            side.id: AccountRecord(lastError: .signInRequired, lastErrorAt: DemoClock.now - 3_600, lastAttemptAt: DemoClock.now - 3_600),
        ])
        let settings = AppSettings.ephemeral()
        settings.usageSource = .juiceReadings
        let usage = JuiceReadingsUsageModel(directory: directory, pollInterval: nil, clock: { DemoClock.now })
        let env = AppEnvironment(settings: settings, usage: usage, sessions: FixtureSessionFeed(scenario: .allStates, now: DemoClock.now).makeModel())
        try renderSettings(.accounts, name: "A-settings-accounts-mirror", env: env)
    }

    @Test func settingsGeneralIslandMode() throws {
        let settings = AppSettings.ephemeral()
        settings.showAs = .island
        try renderSettings(.general, name: "A-settings-general-islandmode", env: .demo(settings: settings))
    }

    @Test func settingsShortcutsRecordedCtrlG() throws {
        let settings = AppSettings.ephemeral()
        settings.globalJumpKey = "ctrl+g"
        try renderSettings(.shortcuts, name: "A-settings-shortcuts-ctrl-g", env: .demo(settings: settings))
    }

    /// The installed release build: Launch at Login registered and waiting for the owner's approval; no development
    /// switch (Live sessions is on). A fake login item: nothing is registered.
    @Test func settingsGeneralRelease() throws {
        let env = AppEnvironment.demo(identity: .production)
        env.settings.liveSessions = true
        env.launchAtLogin = LaunchAtLogin(settings: env.settings, identity: .production, bundlePath: LaunchAtLogin.installedPath,
                                          service: FakeLoginItem(status: .requiresApproval))
        try renderSettings(.general, name: "A-settings-general-release", env: env)
    }

    /// The jump key on, but another app holds it: the row says so. A recording stand-in: nothing is registered.
    @Test func settingsShortcutsKeyTaken() throws {
        let settings = AppSettings.ephemeral()
        settings.globalJumpKey = "ctrl+opt+g"
        settings.globalJumpEnabled = true
        let keys = RecordingHotKeys()
        keys.refuses = true
        let layout = try GlobalJumpHotKeyTests.layout("com.apple.keylayout.US")
        let hotKey = GlobalJumpHotKey(settings: settings, registrar: keys, layout: { layout }, jump: {})
        hotKey.apply()
        let env = AppEnvironment.demo(settings: settings)
        env.globalJump = hotKey
        try renderSettings(.shortcuts, name: "A-settings-shortcuts-taken", env: env)
    }

    private func renderSettings(_ pane: SettingsPane, name: String, env: AppEnvironment) throws {
        // The Island pane's Glyph style preview holds still, like every render's glyphs.
        let view = SettingsRootView(navigation: SettingsNavigation(pane: pane), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
        let height = max(SettingsTheme.Metrics.minHeight, Self.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    /// The pane's natural height at 780 pt wide.
    static func fittingHeight<V: View>(_ view: V, env: AppEnvironment) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: SettingsTheme.Metrics.width).fixedSize(horizontal: false, vertical: true)
            .environment(env).environment(\.colorScheme, .dark))
        return ceil(hosting.fittingSize.height)
    }

    /// The reference shots' pane names (`refs/A-settings-<name>.png`).
    static func refName(_ pane: SettingsPane) -> String {
        pane == .desktopPanel ? "panel" : pane.rawValue
    }
}
