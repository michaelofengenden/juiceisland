import AppKit
@testable import IslandEngine
import IslandHookNotes
import OpenIslandCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Wave 4's plugin agents, headless (P1150 to P1174), every file named `pl-*`: Settings › Agents with Pi, Oh My Pi and
/// Amp under wave 1's agents (Pi connected, Oh My Pi to connect, Amp's plugin older than this build, each tagged Watch,
/// each its own file), on Black and Glass in Light and Dark; and the island in the same four looks: its list with
/// Amp waiting, Pi running and Oh My Pi done, and Amp's read-only waiting card (its command, Open and ✕, no answer).
/// The window's card too. Sessions from `PluginAgentsUITests.feed` (fictional folders); nothing is read from this Mac.
/// `zsh scripts/render-all.sh PluginAgentsRenders`.
@MainActor
@Suite(.serialized)
struct PluginAgentsRenders {
    /// The three rows as `TableAgents` makes them, from the states the installer reads.
    static func pluginRows() -> [AgentRow] {
        let states: [(AgentHookSpec, AgentHookState)] = [(AgentHookTable.pi, .connected), (AgentHookTable.ohMyPi, .notConnected),
                                                         (AgentHookTable.amp, .outdated)]
        return states.map { spec, state in
            let place = "~/\(spec.folder)/\(spec.file(stem: "juice-island"))"
            let (status, actions) = AgentRowText.table(state, spec: spec, place: place)
            return AgentRow(id: spec.kind.rawValue, name: spec.name, look: AgentLook.of(EngineSessionsModel.agent(spec.kind)),
                            reach: spec.answers == .approve ? .approve : .watch, place: place, status: status, actions: actions)
        }
    }

    @Test(arguments: AgentsRenders.themes, AgentsRenders.schemes)
    func agentsPane(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        let env = AgentsRenders.environment(theme: theme, scheme: scheme)
        env.agentsPane.sources = [AgentsRenders.TableSource(rows: AgentsRenders.tableRows() + Self.pluginRows(), notFound: [])]
        try AgentsRenders.render(.agents, "pl-settings-agents-\(theme.rawValue)-\(AgentsRenders.word(scheme))", env: env, scheme: scheme)
    }

    static func environment(_ look: AlertsRenders.Look, style: IslandStyle = .clean) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        settings.juiceTheme = look.theme
        settings.appearance = look.scheme == .light ? .light : .dark
        return PluginAgentsUITests.environment(settings)
    }

    /// The opened island's list, Clean and Detailed, in each look.
    @Test func islandList() throws {
        for look in AlertsRenders.looks {
            for style in IslandStyle.allCases {
                let env = Self.environment(look, style: style)
                let size = CGSize(width: 540, height: style == .clean ? 300 : 420)
                try RenderHarness.render(AlertsRenders.scene(IslandGlassRenders.state(env, surface: .island), look: look, size: size),
                                         "pl-island-\(style.rawValue)-\(look.name)", env: env, scheme: look.scheme)
            }
        }
    }

    /// Amp's waiting thread: a read-only card on Amp's row, in each look.
    @Test func ampWaitingCard() throws {
        for look in AlertsRenders.looks {
            let env = Self.environment(look)
            try RenderHarness.render(AlertsRenders.scene(AlertsRenders.card(env, PluginAgentsUITests.ampID), look: look,
                                                         size: CGSize(width: 540, height: 360)),
                                     "pl-card-amp-waiting-\(look.name)", env: env, scheme: look.scheme)
        }
    }

    /// The window's card for Amp's waiting thread, and Oh My Pi's Done card.
    @Test func windowCards() throws {
        let env = Self.environment(AlertsRenders.looks[0])
        for (id, name, height) in [(PluginAgentsUITests.ampID, "amp-waiting", CGFloat(170)), (PluginAgentsUITests.ompID, "ohmypi-done", 150)] {
            let card = try #require(env.sessions.card(for: id))
            let view = SessionCardView(card: card, style: .window)
                .frame(width: 579)
                .frame(height: height, alignment: .top)
                .padding(8)
                .background(Color.black)
                .environment(\.sessionGlyphsAnimated, false)
            try RenderHarness.renderHosted(view, "pl-card-window-\(name)", size: CGSize(width: 595, height: height + 16), env: env)
        }
    }
}
