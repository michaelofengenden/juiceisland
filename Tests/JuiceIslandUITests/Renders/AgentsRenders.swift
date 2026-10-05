import AppKit
@testable import IslandEngine
import JuiceCore
import OpenIslandCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Settings › Agents and Island › Display, headless (P935 to P944), every file named `ag-*`: the Agents pane on Black
/// and Glass in Light and Dark (Claude's and Codex's folders, OpenCode, the agents table's rows through a stand-in
/// source, Approve and Watch, every state with its button or Copy, the quiet "Not found" line and Remove from all
/// agents), the pane while Vibe Island runs too, with nothing found, and the Island pane's Display row on the fixture's
/// two screens. Fixture folders and fictional agents only; nothing is read from this Mac.
@MainActor
@Suite(.serialized)
struct AgentsRenders {
    nonisolated static let themes: [JuiceTheme] = [.black, .glass]
    nonisolated static let schemes: [ColorScheme] = [.light, .dark]

    static func word(_ scheme: ColorScheme) -> String { scheme == .light ? "light" : "dark" }

    /// A stand-in for the agents table's source (the agents lane's), fed by hand.
    final class TableSource: AgentRowSource {
        let rows: [AgentRow]
        let notFound: [String]
        init(rows: [AgentRow], notFound: [String]) {
            self.rows = rows
            self.notFound = notFound
        }
        func perform(_ action: AgentRowAction, on id: String) {}
        func refresh() {}
    }

    static func folder(_ provider: Provider, _ name: String, alias: String, _ state: ProfileHookStatus.State, managed: Int,
                       moves: Bool = false) -> HookSetupRow {
        let home = "/tmp/ji-render-home"
        let target = ProfileHookTarget(provider: provider, folder: home + "/" + name, alias: alias, isDefaultFolder: !name.contains("-"),
                                       accountID: nil, isMonitored: true)
        let status = ProfileHookStatus(target: target, state: state, intent: .untouched, managedEventCount: managed,
                                       expectedEventCount: provider == .claude ? 14 : 4, vibeEntryCount: 0, otherHookCount: 0,
                                       helperMatchesBundle: true, codexFeatureEnabled: provider == .codex ? true : nil,
                                       checkedAt: DemoClock.now)
        let choice = ProfileHookChoice.of(status, setupState: state, openIslandRunning: false, helperPresent: true)
        var row = HookRowText.row(target: target, status: status, setupState: state, choice: choice, missing: [], busy: false,
                                  clickRefusal: nil, home: home)
        if moves {
            // Hooks that still call Open Island's helper (`ProfileHookStatus.State.oldHelper`).
            row.movesToJuiceHelper = true
            row.action = .repair
        }
        return row
    }

    static func folders() -> [HookSetupRow] {
        [folder(.claude, ".claude", alias: "Main", .installed, managed: 14),
         folder(.claude, ".claude-work", alias: "Work", .notInstalled, managed: 0),
         folder(.claude, ".claude-lab", alias: "Lab", .installed, managed: 14, moves: true),
         folder(.codex, ".codex", alias: "Home", .installed, managed: 4),
         folder(.codex, ".codex-side", alias: "Side", .codexNeedsTrust(untrustedEvents: ["Stop"]), managed: 4),
         folder(.codex, ".codex-preset", alias: "Preset", .hasComments(file: "hooks.json"), managed: 0)]
    }

    /// The agents table's rows as `TableAgents` makes them, with each agent's own mark: Cursor is Watch (P919).
    static func tableRows() -> [AgentRow] {
        let snippet = "\"version\": 1,\n\"hooks\": {}"
        return [
            AgentRow(id: "copilot", name: "Copilot CLI", look: AgentLook.of(GlyphPalette.Agent.kind(.copilot)), reach: .approve,
                     place: "~/.copilot/hooks/juice-island.json", status: .connected, actions: [.remove]),
            AgentRow(id: "cursor", name: "Cursor", look: AgentLook.of(.other(.cursor)), reach: .watch, place: "~/.cursor/hooks.json",
                     status: .addByHand(file: "hooks.json", snippet: snippet), actions: []),
            AgentRow(id: "qwen", name: "Qwen Code", look: AgentLook.of(.other(.qwenCode)), reach: .approve, place: "~/.qwen/settings.json",
                     status: .notConnected, actions: [.connect]),
            AgentRow(id: "devin", name: "Devin", look: AgentLook.of(GlyphPalette.Agent.kind(.devin)), reach: .approve,
                     place: "~/.config/devin/config.json", status: .attention(word: "Partial 5/6", detail: nil), actions: [.repair, .remove]),
            AgentRow(id: "kilo", name: "Kilo", look: AgentLook.of(GlyphPalette.Agent.kind(.kilo)), reach: .approve,
                     place: "~/.config/kilo/plugin/juice-island.js", status: .attention(word: "Older than this build", detail: nil),
                     actions: [.update, .remove]),
        ]
    }

    static func environment(theme: JuiceTheme, scheme: ColorScheme, vibeIsland: Bool = false, empty: Bool = false) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = theme
        settings.appearance = scheme == .light ? .light : .dark
        let env = AppEnvironment.demo(settings: settings)
        let openCode = OpenCodeSetupRow(title: "OpenCode 2.0.18", folder: "~/.config/opencode", word: "Installed", tone: .normal,
                                        action: .remove, refusal: nil, busy: false)
        env.hooks = OpenCodeHooks(rows: empty ? [] : folders(), openCode: empty ? nil : openCode,
                                  integrations: HookIntegrations(openIslandRunning: false, vibeProfiles: 0, helperInBuild: true,
                                                                 vibeIslandRunning: vibeIsland))
        env.agentsPane.answersCodex = { false }
        env.agentsPane.helperPath = { "/tmp/ji-render-home/Library/Application Support/Juice Island/bin/JuiceHooks" }
        env.agentsPane.sources = [TableSource(rows: empty ? [] : tableRows(),
                                              notFound: empty ? ["Copilot CLI", "Cursor", "Qwen Code", "Devin", "Kilo"] : [])]
        return env
    }

    final class OpenCodeHooks: HooksModel {
        let rows: [HookSetupRow]
        let alerts: [HookDriftAlert] = []
        let integrations: HookIntegrations
        let lastEvents: [String: Date] = [:]
        let openCodeRow: OpenCodeSetupRow?
        init(rows: [HookSetupRow], openCode: OpenCodeSetupRow?, integrations: HookIntegrations) {
            self.rows = rows
            openCodeRow = openCode
            self.integrations = integrations
        }
        func clickRefusal(for id: String) -> String? { nil }
        func perform(_ action: ProfileHookAction, on id: String) {}
        func installAllMonitored() {}
        func activate() {}
    }

    static func render(_ pane: SettingsPane, _ name: String, env: AppEnvironment, scheme: ColorScheme) throws {
        let view = SettingsRootView(navigation: SettingsNavigation(pane: pane), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env, scheme: scheme)
    }

    /// The pane in both themes and both looks: Claude unfolds into Main (Connected), Work (Connect) and Lab (Move to
    /// Juice's helper); Codex is Watch while the island does not answer it, with Side waiting on its trust (Copy /hooks)
    /// and Preset a file with comments (Add by hand, Copy snippet); then OpenCode and the table's agents.
    @Test(arguments: themes, schemes)
    func agentsPane(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        try Self.render(.agents, "ag-settings-agents-\(theme.rawValue)-\(Self.word(scheme))",
                        env: Self.environment(theme: theme, scheme: scheme), scheme: scheme)
    }

    /// While Vibe Island runs too: one quiet line says two islands show; every button still works (P914).
    @Test func agentsPaneWhileVibeIslandRuns() throws {
        try Self.render(.agents, "ag-settings-agents-vibe-island-running",
                        env: Self.environment(theme: .black, scheme: .dark, vibeIsland: true), scheme: .dark)
    }

    /// Nothing found: one line in the list, the quiet "Not found" line under it, no Remove from all agents.
    @Test func agentsPaneWithNothingFound() throws {
        try Self.render(.agents, "ag-settings-agents-none", env: Self.environment(theme: .black, scheme: .dark, empty: true), scheme: .dark)
    }

    /// Island › Display on the fixture's two screens, once on Follow focus (with its one line) and once on a screen that
    /// is away (listed as not connected, with its line).
    @Test(arguments: schemes)
    func islandDisplay(_ scheme: ColorScheme) throws {
        let env = Self.environment(theme: .black, scheme: scheme)
        env.settings.islandDisplay = IslandDisplayChoice.followFocusID
        try Self.render(.island, "ag-settings-island-display-follow-focus-\(Self.word(scheme))", env: env, scheme: scheme)
        env.settings.islandDisplay = "AWAY-DISPLAY-UUID"
        try Self.render(.island, "ag-settings-island-display-away-\(Self.word(scheme))", env: env, scheme: scheme)
    }
}
