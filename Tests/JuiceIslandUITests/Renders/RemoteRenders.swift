import AppKit
@testable import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// SSH hosts (P751, P745): Setup's SSH hosts section with fixture hosts in their states and with none, and remote rows
/// on the island and in the window, tagged with their host. Fixture hosts and the demo engine; nothing is read, written,
/// connected or shown on screen. Names `SSH-…`: `zsh scripts/render-all.sh RemoteRenders`.
@MainActor
@Suite(.serialized)
struct RemoteRenders {
    private func renderSetup(_ name: String, env: AppEnvironment) throws {
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .setup), drawsTrafficLights: true, scrolls: false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    /// Setup as the owner finds it with hosts in each state they meet most.
    @Test func setupWithHosts() throws {
        let env = AppEnvironment.demo()
        env.remoteHosts = DemoRemoteHostsModel.fixture
        try renderSetup("SSH-setup-hosts", env: env)
    }

    /// Setup with no host yet: the add row alone, with its pop-up of config hosts.
    @Test func setupWithNoHost() throws {
        let env = AppEnvironment.demo()
        env.remoteHosts = DemoRemoteHostsModel(configHosts: ["gpu1", "trainer"])
        try renderSetup("SSH-setup-empty", env: env)
    }

    /// Every row state, one under the other, at the pane's width.
    @Test func hostRowStates() throws {
        let setup = DemoRemoteHostsModel.setup
        func row(_ name: String, _ state: TunnelMachine.State?, setup: RemoteSetupResult? = setup, busy: RemoteHostBusy? = nil,
                 failure: RemoteSetupFailure? = nil, removeFailed: Bool = false) -> RemoteHostRow {
            RemoteHostText.row(RemoteHostRecord(id: name, destination: name, setup: setup), state: state, busy: busy,
                               failure: failure, removeFailed: removeFailed)
        }
        var older = setup
        older.helper = 0
        let rows = [
            row("gpu1", .connected(helper: 1)), row("gpu2", .connecting), row("ubuntu@trainer", .retrying(at: DemoClock.now, after: .unreachable)),
            row("spare", .offline(.unreachable)), row("lab-box", .offline(.needsKeyLogin)), row("new-box", .offline(.hostKey)),
            row("wiped", .offline(.notSetUp)), row("old", .connected(helper: 0), setup: older), row("paused", nil),
            row("fresh", nil, setup: nil), row("bare", nil, setup: nil, failure: .noPython), row("build", nil, setup: nil, busy: .settingUp),
            row("gone", .offline(.unreachable), failure: .connection(.unreachable), removeFailed: true),
            row("linked", .connected(helper: 0), setup: older, failure: .refused("config.toml is a link")),
        ]
        let env = AppEnvironment.demo()
        env.remoteHosts = DemoRemoteHostsModel(rows: rows)
        let view = FormPane { RemoteHostsSection() }
            .padding(SettingsTheme.Metrics.panePadding)
            .frame(width: SettingsTheme.Metrics.width - 200)
            .background(SettingsTheme.window)
        let height = ARenders.fittingHeight(view, env: env)
        try RenderHarness.renderHosted(view, "SSH-host-rows", size: CGSize(width: SettingsTheme.Metrics.width - 200, height: height), env: env)
    }

    /// Set up clicked on text that is not a host name: the field keeps it and says so.
    @Test func setupRefusesWhatIsNotAHost() throws {
        let env = AppEnvironment.demo()
        env.remoteHosts = DemoRemoteHostsModel(configHosts: ["gpu1", "trainer"])
        let view = FormPane { RemoteHostsSection(typed: "ssh gpu1", refused: true) }
            .padding(SettingsTheme.Metrics.panePadding)
            .frame(width: SettingsTheme.Metrics.width - 200)
            .background(SettingsTheme.window)
        let height = ARenders.fittingHeight(view, env: env)
        try RenderHarness.renderHosted(view, "SSH-setup-refused", size: CGSize(width: SettingsTheme.Metrics.width - 200, height: height), env: env)
    }

    /// Two demo sessions filed under hosts, as the tunnels' relay files them (`sameHost`: both on gpu1).
    private func remoteEnv(style: IslandStyle, sameHost: Bool = false) throws -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        let env = AppEnvironment.demo(settings: settings)
        let engine = try #require(env.fixtureFeed?.engine)
        for (id, host) in [(FixtureSessionFeed.ID.approval, "gpu1"), (FixtureSessionFeed.ID.running, sameHost ? "gpu1" : "trainer")] {
            engine.remoteSessions.record(id, RemoteSessionDirectory.Entry(hostID: host, hostName: host, destination: host))
            engine.markRemoteIfKnown(id)
        }
        return env
    }

    /// Two sessions on one host: each still says where it runs (an SSH host is never the shared host left off).
    @Test func islandRowsDetailed() throws {
        let env = try remoteEnv(style: .detailed, sameHost: true)
        let view = OpenedIslandView(presentation: .list, notch: IslandTheme.Metrics.referenceNotch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: IslandTheme.Metrics.referenceNotch), "SSH-island-detailed", env: env)
    }

    @Test func islandRowsClean() throws {
        let env = try remoteEnv(style: .clean)
        let view = OpenedIslandView(presentation: .list, notch: IslandTheme.Metrics.referenceNotch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: IslandTheme.Metrics.referenceNotch), "SSH-island-clean", env: env)
    }

    @Test func windowRows() throws {
        let env = try remoteEnv(style: .detailed)
        #expect(env.sessions.rows.first { $0.id == FixtureSessionFeed.ID.approval }?.host == "gpu1")
        let view = SessionListView()
            .frame(width: 1200, height: 760)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.previewSelectedOption, 0)
        try RenderHarness.renderHosted(view, "SSH-window", size: CGSize(width: 1216, height: 776), env: env)
    }
}
