import AppKit
@testable import IslandEngine
import IslandHookNotes
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Wave 4's three lanes on one Mac, headless, every file named `w4i-*` (P1176 to P1179): Settings › Agents and the
/// welcome's Agents screen with every agent of the table found (eighteen with Claude Code, Codex and OpenCode), each
/// Approve or Watch, and the island's "10 new agents can connect" after an update from 0.4.0. Rows are made from the
/// table as `TableAgents` makes them; made-up folders only, nothing is read from this Mac.
@MainActor
@Suite(.serialized)
struct Wave4CrossLaneRenders {
    typealias A = AgentsRenders

    /// Every agent of the table as its row: wave 1's five as `AgentsRenders` draws them, then wave 4's ten in a few of
    /// the states a Mac shows (Qoder and Pi connected, Gemini CLI's settings with comments for Add by hand, the rest to
    /// connect).
    static func rows(connectAll: Bool = false) -> [AgentRow] {
        let added = AgentHookTable.wave1.filter { spec in !A.tableRows().contains { $0.id == spec.kind.rawValue } }
        let new = added.map { spec -> AgentRow in
            let place = "~/" + spec.folder + "/" + spec.file(stem: "juice-island")
            var status: AgentRowStatus = .notConnected
            var actions: [AgentRowAction] = [.connect]
            if !connectAll, [.qoder, .pi].contains(spec.kind) {
                status = .connected
                actions = [.remove]
            } else if !connectAll, spec.kind == .gemini {
                status = .addByHand(file: "settings.json", snippet: "\"hooks\": {}")
                actions = []
            }
            return AgentRow(id: spec.kind.rawValue, name: spec.name, look: AgentLook.of(EngineSessionsModel.agent(spec.kind)),
                            reach: spec.answers == .approve ? .approve : .watch, place: place, status: status, actions: actions,
                            reachNote: spec.reachNote)
        }
        return (connectAll ? [] : A.tableRows()) + new
    }

    @Test(arguments: [(JuiceTheme.black, ColorScheme.dark), (.glass, .light)])
    func settingsAgentsWithEveryAgent(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        let env = A.environment(theme: theme, scheme: scheme)
        env.agentsPane.sources = [A.TableSource(rows: Self.rows(), notFound: [])]
        try A.render(.agents, "w4i-settings-agents-all-\(theme.rawValue)-\(A.word(scheme))", env: env, scheme: scheme)
    }

    /// A Mac with Claude Code and Codex only: the agents not found are counted, the names in the line's help (P1192).
    @Test func settingsAgentsWithNoTableAgentFound() throws {
        let env = A.environment(theme: .black, scheme: .dark)
        env.agentsPane.sources = [A.TableSource(rows: [], notFound: AgentHookTable.wave1.map(\.name))]
        #expect(env.agentsPane.notFound.count >= AgentHookTable.wave1.count)
        try A.render(.agents, "w4s-settings-agents-none-found-black-dark", env: env, scheme: .dark)
    }

    @Test(arguments: [(JuiceTheme.black, ColorScheme.dark), (.glass, .light)])
    func welcomeAgentsWithEveryAgent(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        let env = WelcomeRenders.environment(theme: theme, scheme: scheme)
        let model = WelcomeModel.fixture(step: .agents, env: env)
        env.agentsPane.sources = [A.TableSource(rows: Self.rows(connectAll: true), notFound: [])]
        try WelcomeRenders.render(model, "w4i-welcome-agents-all-\(theme.rawValue)-\(WelcomeRenders.word(scheme))", env: env, scheme: scheme)
    }

    /// After an update from 0.4.0 on a Mac with all ten: one line, "10 new agents can connect · Connect".
    @Test func islandNewAgentsLine() throws {
        let env = WelcomeRenders.environment()
        _ = WelcomeModel.fixture(step: .agents, env: env)
        env.agentsPane.sources = [A.TableSource(rows: Self.rows(connectAll: true), notFound: [])]
        env.settings.newAgents = Wave4CrossLaneTests.addedIDs
        #expect(NewAgents.shown(env.settings.newAgents, rows: env.agents.rows).count == 10)
        let ui = IslandGlassRenders.state(env, surface: .island)
        try RenderHarness.render(AppearanceRenders.islandScene(ui, size: CGSize(width: 540, height: 200), backdrop: .preview, theme: .black,
                                                               scheme: .dark),
                                 "w4i-island-new-agents-black-dark", env: env)
    }
}
