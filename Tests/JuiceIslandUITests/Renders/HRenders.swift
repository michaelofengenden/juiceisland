import AppKit
import Foundation
@testable import IslandEngine
import JuiceCore
import OpenIslandCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The hooks stream: Setup's real states and refusals, the drift rows in the window and the island, and Diagnostics'
/// Hooks section. Fixture profiles (fictional aliases and folders); nothing is read or written.
@MainActor
@Suite(.serialized)
struct HRenders {
    /// Setup rows built by `HookRowText` from engine states, as the app would build them.
    final class StubHooks: HooksModel {
        let rows: [HookSetupRow]
        let alerts: [HookDriftAlert]
        let integrations: HookIntegrations
        let lastEvents: [String: Date] = [:]
        init(rows: [HookSetupRow], alerts: [HookDriftAlert] = [], integrations: HookIntegrations) {
            self.rows = rows
            self.alerts = alerts
            self.integrations = integrations
        }
        func clickRefusal(for id: String) -> String? { nil }
        func perform(_ action: ProfileHookAction, on id: String) {}
        func installAllMonitored() {}
        func activate() {}
    }

    private static func row(_ provider: Provider, _ name: String, alias: String, _ state: ProfileHookStatus.State, vibe: Int = 0,
                            managed: Int, openIsland: Bool = false, helper: Bool = true, missing: [HookEntrySpec] = []) -> HookSetupRow {
        let home = "/tmp/ji-render-home"
        let target = ProfileHookTarget(provider: provider, folder: home + "/" + name, alias: alias, isDefaultFolder: !name.contains("-"),
                                       accountID: nil, isMonitored: true)
        let status = ProfileHookStatus(target: target, state: state, intent: .untouched, managedEventCount: managed,
                                       expectedEventCount: provider == .claude ? 14 : 4, vibeEntryCount: vibe, otherHookCount: 0,
                                       helperMatchesBundle: true, codexFeatureEnabled: provider == .codex ? true : nil,
                                       checkedAt: DemoClock.now)
        let choice = ProfileHookChoice.of(status, setupState: state, openIslandRunning: openIsland, helperPresent: helper)
        return HookRowText.row(target: target, status: status, setupState: state, choice: choice, missing: missing, busy: false,
                               clickRefusal: nil, home: home)
    }

    /// Before cutover: the default folders hold Vibe Island's hooks next to Open Island's, so they wait; the other
    /// profiles can be installed now.
    static let beforeCutover: [HookSetupRow] = [
        row(.claude, ".claude", alias: "Main", .installed, vibe: 14, managed: 14),
        row(.claude, ".claude-work", alias: "Work", .notInstalled, managed: 0),
        row(.claude, ".claude-lab", alias: "Lab", .partial(installed: 12, expected: 14), managed: 14,
            missing: [HookEntrySpec(event: "Notification", matcher: "*", timeout: nil), HookEntrySpec(event: "PreCompact", matcher: nil, timeout: nil)]),
        row(.claude, ".claude-studio", alias: "Studio", .linkedConfig(file: "settings.json"), managed: 0),
        row(.codex, ".codex", alias: "Home", .installed, vibe: 4, managed: 4),
        row(.codex, ".codex-side", alias: "Side", .codexNeedsTrust(untrustedEvents: ["Stop"]), managed: 4),
        row(.codex, ".codex-fresh", alias: "Fresh", .notInstalled, managed: 0),
        row(.codex, ".codex-preset", alias: "Preset", .hasComments(file: "hooks.json"), managed: 0),
    ]

    private func renderSettings(_ pane: SettingsPane, _ name: String, env: AppEnvironment) throws {
        let view = SettingsRootView(navigation: SettingsNavigation(pane: pane), drawsTrafficLights: true, scrolls: false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    @Test func setupBeforeCutover() throws {
        let env = AppEnvironment.demo()
        env.hooks = StubHooks(rows: Self.beforeCutover,
                              integrations: HookIntegrations(openIslandRunning: false, vibeProfiles: 2, helperInBuild: true))
        try renderSettings(.agents, "H-setup-before-cutover", env: env)
    }

    @Test func setupWhileOpenIslandRunsWithoutAHelper() throws {
        let env = AppEnvironment.demo()
        let rows = [
            Self.row(.claude, ".claude-work", alias: "Work", .notInstalled, managed: 0, openIsland: true, helper: false),
            Self.row(.claude, ".claude-lab", alias: "Lab", .installed, managed: 14, openIsland: true, helper: false),
            Self.row(.codex, ".codex-fresh", alias: "Fresh", .notInstalled, managed: 0, helper: false),
            Self.row(.codex, ".codex-gone", alias: "Gone", .folderMissing, managed: 0, helper: false),
        ]
        env.hooks = StubHooks(rows: rows, integrations: HookIntegrations(openIslandRunning: true, vibeProfiles: 0, helperInBuild: false))
        try renderSettings(.agents, "H-setup-refused", env: env)
    }

    @Test func diagnosticsHooks() throws {
        let env = AppEnvironment.demo()
        env.hooks = StubHooks(rows: Self.beforeCutover,
                              integrations: HookIntegrations(openIslandRunning: false, vibeProfiles: 2, helperInBuild: true))
        try renderSettings(.diagnostics, "H-diagnostics-hooks", env: env)
    }

    /// P120: Diagnostics with the live engine's Bridge row (a stand-in bridge: nothing is bound), once live after a
    /// socket was taken back, once while another app holds the socket.
    @Test func diagnosticsLiveBridge() throws {
        for (name, health) in [("H-diagnostics-bridge-live", BridgeHealth.live(sockets: 2)), ("H-diagnostics-bridge-taken", .taken)] {
            let env = AppEnvironment.demo()
            env.hooks = StubHooks(rows: Self.beforeCutover,
                                  integrations: HookIntegrations(openIslandRunning: false, vibeProfiles: 0, helperInBuild: true))
            let settings = AppSettings.ephemeral()
            settings.liveSessions = true
            let live = LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .prototype).makeModel() }, engine: {
                var configuration = SessionEngine.Configuration.headless
                configuration.startBridge = true
                configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-render-\(UUID().uuidString).sock")
                var dependencies = SessionEngine.Dependencies()
                dependencies.isOtherIslandRunning = { false }
                dependencies.socketHasOwner = { _ in false }
                dependencies.socketIdentity = { _ in nil }
                dependencies.startBridge = { _ in RenderBridge() }
                dependencies.startRuntime = { _ in }
                dependencies.updateProcessRoots = { _ in }
                return SessionEngine(configuration: configuration, dependencies: dependencies)
            }, profiles: { LiveProfiles(accounts: [], discovered: []) }, identity: .production)
            live.apply()
            live.engine?.bridgeHealth = health
            live.engine?.bridgeTakenBackAt = DemoClock.now - 300
            env.liveSessions = live
            try renderSettings(.diagnostics, name, env: env)
            live.shutdown()
        }
    }

    /// The Bridge row while the engine is refused: a long start failure in macOS's words (two lines, the pane as wide
    /// as ever), and Open Island running (said once, in the Bridge row; the Hooks footnote leaves it out).
    @Test func diagnosticsRefusedBridge() throws {
        let failure = CocoaError(.fileWriteNoPermission,
                                 userInfo: [NSFilePathErrorKey: "/tmp/juice-island-render/Library/Application Support/Open Island"])
        for (name, other) in [("H-diagnostics-bridge-refused", false), ("H-diagnostics-bridge-open-island", true)] {
            let env = AppEnvironment.demo()
            env.hooks = StubHooks(rows: Self.beforeCutover,
                                  integrations: HookIntegrations(openIslandRunning: other, vibeProfiles: 0, helperInBuild: true))
            let live = DiagnosticsBridgeTests.refusedLive(failure, otherIsland: other)
            env.liveSessions = live
            try renderSettings(.diagnostics, name, env: env)
            live.shutdown()
        }
    }

    /// Stands in for BridgeServer in renders: no socket.
    final class RenderBridge: EngineBridge, @unchecked Sendable {
        func updateStateSnapshot(_ snapshot: SessionState) {}
        func stop() {}
    }

    @Test func windowDriftRow() throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        env.hooks = DemoHooksModel(showsDrift: true)
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), "H-window-drift",
                                       size: WindowTheme.Metrics.defaultSize, env: env)
    }

    @Test func islandDriftRow() throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        env.hooks = DemoHooksModel(showsDrift: true)
        let view = OpenedIslandView(presentation: .list, notch: IslandTheme.Metrics.referenceNotch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: IslandTheme.Metrics.referenceNotch), "H-island-drift", env: env)
    }

    /// No drift, no row: the window and island renders of the other streams do not change.
    @Test func noDriftDrawsNothing() throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        #expect(env.hooks.alerts.isEmpty)
        let bare = NSHostingView(rootView: HookDriftRows().environment(env))
        #expect(bare.fittingSize.height == 0)
        env.hooks = DemoHooksModel(showsDrift: true)
        let drifted = NSHostingView(rootView: HookDriftRows().environment(env))
        #expect(drifted.fittingSize.height > 20)
    }
}
