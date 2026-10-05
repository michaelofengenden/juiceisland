import AppKit
@testable import IslandEngine
import JuiceCore
import OpenIslandCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The first run, headless (P950 to P974), every file named `ob-*`: each of the welcome's four screens on Black and Glass
/// in Light and Dark; the Agents screen after Connect, with Vibe Island's card, with Open Island's, and with nothing
/// found; Pick a look without a notch; First session with no agent; the whole first moment (the island's demo card over
/// the welcome); the
/// island's and the window's "Start an agent" and "2 new agents can connect"; Settings › About's Show welcome and
/// Diagnostics' Demo sessions; and the window and the island playing Demo sessions. Made-up agents and folders only;
/// nothing is read from this Mac.
@MainActor
@Suite(.serialized)
struct WelcomeRenders {
    nonisolated static let themes: [JuiceTheme] = [.black, .glass]
    nonisolated static let schemes: [ColorScheme] = [.light, .dark]
    nonisolated static let steps: [WelcomeModel.Step] = WelcomeModel.Step.allCases

    static func word(_ scheme: ColorScheme) -> String { scheme == .light ? "light" : "dark" }
    static func word(_ step: WelcomeModel.Step) -> String {
        switch step {
        case .hello: "hello"
        case .agents: "agents"
        case .look: "look"
        case .start: "start"
        }
    }

    static func environment(theme: JuiceTheme = .black, scheme: ColorScheme = .dark, sessions: FixtureSessionFeed.Scenario = .empty) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = theme
        settings.appearance = scheme == .light ? .light : .dark
        settings.glyphStyle = .liquid
        return AppEnvironment.demo(settings: settings, sessions: sessions)
    }

    static func render(_ model: WelcomeModel, _ name: String, env: AppEnvironment, scheme: ColorScheme) throws {
        try RenderHarness.renderHosted(WelcomeView(model: model).environment(\.sessionGlyphsAnimated, false), name,
                                       size: WelcomeView.size, env: env, scheme: scheme)
    }

    /// Every screen, both themes, both looks: Hello's icon and line, Agents' ticked list (Claude with Main and Work,
    /// Codex, OpenCode, Copilot CLI, Cursor; Approve and Watch), Pick a look (Island chosen on a notch Mac, Liquid,
    /// Launch at Login on), First session (Start Claude Code, the Automation line, Later).
    @Test(arguments: themes, schemes)
    func everyScreen(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        for step in Self.steps {
            let env = Self.environment(theme: theme, scheme: scheme)
            let model = WelcomeModel.fixture(step: step, env: env)
            try Self.render(model, "ob-welcome-\(Self.word(step))-\(theme.rawValue)-\(Self.word(scheme))", env: env, scheme: scheme)
        }
    }

    /// After Connect: every line Connected, Codex amber with its trust and Copy /hooks; the button says Next.
    @Test func agentsAfterConnect() throws {
        let env = Self.environment()
        try Self.render(WelcomeModel.fixture(step: .agents, env: env, mac: .connected), "ob-welcome-agents-connected-black-dark",
                        env: env, scheme: .dark)
    }

    /// Vibe Island connected to four agents: its card with Switch to Juice and Keep Vibe Island; its folders say so.
    @Test(arguments: schemes)
    func agentsWithVibeIsland(_ scheme: ColorScheme) throws {
        let env = Self.environment(theme: scheme == .light ? .glass : .black, scheme: scheme)
        try Self.render(WelcomeModel.fixture(step: .agents, env: env, mac: .vibeIsland),
                        "ob-welcome-agents-vibe-island-\(Self.word(scheme))", env: env, scheme: scheme)
    }

    /// After Switch to Juice, with Claude's Main file left as it was (a link): its line says Vibe Island's lines are
    /// still in it, and the line under the card counts the files that still hold them (P974).
    @Test func agentsAfterSwitchWithAFileLeft() async throws {
        let env = Self.environment()
        let model = WelcomeModel.fixture(step: .agents, env: env, mac: .vibeIsland)
        let services = try #require(model.services as? FixtureWelcomeServices)
        services.switchOutcomes = [WelcomeModel.fixtureVibe[0].place.url: .left("Add by hand")]
        model.switchToJuice()
        for _ in 0..<400 where model.vibeChoice != .switched { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.vibeFilesLeft == 1)
        try Self.render(model, "ob-welcome-agents-vibe-left-black-dark", env: env, scheme: .dark)
    }

    /// Open Island running: its card with Quit Open Island and Keep it.
    @Test func agentsWithOpenIsland() throws {
        let env = Self.environment()
        try Self.render(WelcomeModel.fixture(step: .agents, env: env, openIslandRunning: true), "ob-welcome-agents-open-island-black-dark",
                        env: env, scheme: .dark)
    }

    /// Nothing found: one line that points to Settings › Agents, and Next.
    @Test func agentsNoneFound() throws {
        let env = Self.environment()
        try Self.render(WelcomeModel.fixture(step: .agents, env: env, mac: .empty), "ob-welcome-agents-none-black-dark",
                        env: env, scheme: .dark)
    }

    /// Pick a look on a Mac without a notch: Window chosen.
    @Test func lookWithoutNotch() throws {
        let env = Self.environment(theme: .glass, scheme: .light)
        try Self.render(WelcomeModel.fixture(step: .look, env: env, hasNotch: false), "ob-welcome-look-no-notch-glass-light",
                        env: env, scheme: .light)
    }

    /// First session with no agent at all: the line says where to go, the button ends.
    @Test func startWithNoAgent() throws {
        let env = Self.environment()
        try Self.render(WelcomeModel.fixture(step: .start, env: env, mac: .empty), "ob-welcome-start-none-black-dark", env: env, scheme: .dark)
    }

    /// The first moment as a stranger sees it: the island under the notch opens on the demo's card, the welcome below it.
    @Test(arguments: themes, schemes)
    func helloScene(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        let env = Self.environment(theme: theme, scheme: scheme)
        let feed = try #require(env.fixtureFeed)
        feed.engine.loadPreviewEvents(HelloDemo.askingEvents(now: DemoClock.now))
        let model = WelcomeModel.fixture(step: .hello, env: env)
        let size = CGSize(width: 760, height: 840)
        let ui = IslandGlassRenders.state(env, surface: .island, card: HelloDemo.sessionID,
                                          events: [(0, .present(.card(sessionID: HelloDemo.sessionID)))], at: 1.5)
        let welcome = WelcomeView(model: model)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
        let scene = ZStack(alignment: .top) {
            AppearanceRenders.islandScene(ui, size: size, backdrop: .night, theme: theme, scheme: scheme)
            welcome.padding(.top, 250)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(scene, "ob-welcome-scene-hello-\(theme.rawValue)-\(Self.word(scheme))", size: size, env: env,
                                       scheme: scheme)
    }

    /// The window itself, title bar included: the close button alone over the screen's top, nothing ordered on screen.
    @Test(arguments: themes)
    func window(_ theme: JuiceTheme) throws {
        let env = Self.environment(theme: theme, scheme: .dark)
        _ = WelcomeModel.fixture(step: .agents, env: env)
        let controller = WelcomeWindowController(env: env, services: FixtureWelcomeServices(), step: .look, firstRun: true)
        controller.model.animates = false
        controller.model.showsLaunchAtLogin = true
        try RenderHarness.renderWindow(controller.window, "ob-welcome-window-\(theme.rawValue)", contentSize: WelcomeView.size)
    }

    /// The island with nothing to show: "Start an agent · Connect" while nothing is connected; "2 new agents can connect".
    @Test func islandLines() throws {
        let env = Self.environment()
        _ = WelcomeModel.fixture(step: .agents, env: env)
        env.settings.newAgents = ["copilot", "cursor"]
        let ui = IslandGlassRenders.state(env, surface: .island)
        try RenderHarness.render(AppearanceRenders.islandScene(ui, size: CGSize(width: 540, height: 200), backdrop: .preview, theme: .black,
                                                               scheme: .dark),
                                 "ob-island-empty-new-agents-black-dark", env: env)
    }

    /// The window with no session: "Start an agent · Connect" in the middle, the new agents' line under the header.
    @Test(arguments: themes)
    func windowEmpty(_ theme: JuiceTheme) throws {
        let env = Self.environment(theme: theme, scheme: .dark)
        _ = WelcomeModel.fixture(step: .agents, env: env)
        env.settings.newAgents = ["copilot", "cursor"]
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true).environment(\.sessionGlyphsAnimated, false),
                                       "ob-window-empty-\(theme.rawValue)-dark", size: CGSize(width: 1000, height: 560), env: env, scheme: .dark)
    }

    /// Diagnostics' Demo sessions: the window and the island showing the scenario's six sessions.
    @Test func demoSessions() throws {
        let env = Self.environment(sessions: .demoSessions)
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true).environment(\.sessionGlyphsAnimated, false),
                                       "ob-window-demo-sessions-black-dark", size: CGSize(width: 1100, height: 640), env: env, scheme: .dark)
        let ui = IslandGlassRenders.state(env, surface: .island)
        try RenderHarness.render(AppearanceRenders.islandScene(ui, size: CGSize(width: 540, height: 420), backdrop: .preview, theme: .black,
                                                               scheme: .dark),
                                 "ob-island-demo-sessions-black-dark", env: env)
    }

    /// Settings › About with Show welcome; Diagnostics' Screenshots section with Demo sessions.
    @Test func settings() throws {
        let env = Self.environment()
        try AgentsRenders.render(.about, "ob-settings-about-show-welcome", env: env, scheme: .dark)
        let live = LiveSessions(settings: env.settings, demo: { FixtureSessionFeed(scenario: .empty).makeModel() })
        live.show(DemoSessionsPlayer.makeFeed(now: DemoClock.now).makeModel(), as: .demoSessions)
        env.liveSessions = live
        try AgentsRenders.render(.diagnostics, "ob-settings-diagnostics-demo-sessions", env: env, scheme: .dark)
    }
}
