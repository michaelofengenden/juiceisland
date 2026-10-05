import AppKit
import OpenIslandCore
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// The public README's screenshots (P845, P980), headless, from the Demo sessions scenario only
/// (`FixtureSessionFeed.Scenario.demoSessions`, the one Settings › Diagnostics › Demo sessions plays, P967): the demo's
/// fictional accounts and money, and six sessions in fictional folders (Claude asks to run a command, Claude asks a
/// question, Claude edits a file, Codex runs a command, Codex is done, Copilot CLI runs). Files `readme-window`,
/// `readme-pill`, `readme-island`, `readme-approval`, `readme-question`, `readme-themes`, `readme-panel`, `readme-widget`,
/// `readme-agents` (the first run's Agents screen) and the repository's `social-preview`; `JI_RENDER_DIR=<folder>` writes
/// them there (the README's images are `docs/public/images` here, `docs/images` in the public repository). Nothing is
/// shown on screen: `zsh scripts/render-all.sh ReadmeShotRenders`.
@MainActor
@Suite(.serialized)
struct ReadmeShotRenders {
    typealias ID = FixtureSessionFeed.DemoSessionsID
    static let ask = ID.approval
    static let question = ID.question
    /// The folders the shots may name: none is a real project.
    static let folders: Set<String> = FixtureSessionFeed.demoSessionsFolders

    static func environment(theme: JuiceTheme = .black) throws -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = theme
        settings.islandStyle = .clean
        settings.islandUsagePlacement = .section
        settings.islandShowsMoney = true
        settings.glyphStyle = .pixel
        let env = AppEnvironment.demo(settings: settings, sessions: .demoSessions, usage: .showcase)
        guard case .approval? = env.sessions.card(for: ask) else {
            Issue.record("the scenario's approval is not waiting")
            return env
        }
        return env
    }

    /// Every session the shots show is one of the scenario's six, in a fictional folder.
    @Test func theShotsShowOnlyFictionalFolders() throws {
        let env = try Self.environment()
        #expect(Set(env.sessions.rows.map(\.id)) == [ID.approval, ID.question, ID.edit, ID.codexRun, ID.codexDone, ID.copilot])
        #expect(Set(env.sessions.rows.compactMap(\.project)).isSubset(of: Self.folders))
        #expect(Self.folders == ["notes-site", "field-notes"])
    }

    /// The shots' usage reads as a Mac in good health, not one owner's setup or a broken state: a few batteries, each with
    /// plenty left, and two money lines (P991).
    @Test func theShotsShowAFewHealthyBatteriesAndTwoMoneyLines() throws {
        let panel = try Self.environment().usage.panel
        let batteries = panel.rows.flatMap(\.batteries)
        #expect((2...3).contains(batteries.count), "\(batteries.map(\.alias))")
        #expect(batteries.allSatisfy { if case let .available(_, low) = $0.state { !low } else { false } })
        #expect((1...2).contains(panel.money.count), "\(panel.money.map(\.name))")
    }

    /// The Agents shot shows only the welcome fixture's made-up Mac: its folders' fixture names, no email, and no file of
    /// the private app's (P925); the files Connect writes sit behind the "i", which the shot leaves closed.
    @Test func theAgentsShotNamesOnlyFixtures() throws {
        let env = Self.agentsEnvironment()
        let model = WelcomeModel.fixture(step: .agents, env: env)
        let lines = model.lines
        #expect(Set(lines.map(\.name)).isSuperset(of: ["Claude Code", "Codex", "OpenCode", "Copilot CLI", "Cursor"]))
        let words = lines.flatMap { [$0.name, $0.detail ?? "", $0.note ?? ""] }.joined(separator: " ")
        #expect(!words.contains("@") && !words.contains("juice-island") && !words.contains("Juice Island"))
        let folders = env.hooks.rows.map { ($0.folder as NSString).lastPathComponent }
        #expect(Set(folders) == [".claude", ".claude-work", ".codex"])
    }

    @Test func window() throws {
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true).environment(\.sessionGlyphsAnimated, false),
                                       "readme-window", size: CGSize(width: 1100, height: 640), env: try Self.environment())
    }

    /// The closed island in the notch: what sits there all day.
    @Test func pill() throws {
        let env = try Self.environment()
        let scene = AppearanceRenders.islandScene(IslandGlassRenders.state(env), size: CGSize(width: 540, height: 64),
                                                  backdrop: .preview, theme: .black, scheme: .dark)
        try RenderHarness.render(scene, "readme-pill", env: env)
    }

    @Test func island() throws {
        let env = try Self.environment()
        let scene = AppearanceRenders.islandScene(IslandGlassRenders.state(env, surface: .island), size: CGSize(width: 540, height: 340),
                                                  backdrop: .preview, theme: .black, scheme: .dark)
        try RenderHarness.render(scene, "readme-island", env: env)
    }

    static func card(_ env: AppEnvironment, _ id: String) -> IslandUIState {
        IslandGlassRenders.state(env, surface: .island, card: id, events: [(0, .present(.card(sessionID: id)))], at: 1.5)
    }

    @Test func approval() throws {
        let env = try Self.environment()
        let scene = AppearanceRenders.islandScene(Self.card(env, Self.ask), size: CGSize(width: 540, height: 210), backdrop: .preview,
                                                  theme: .black, scheme: .dark)
        try RenderHarness.render(scene, "readme-approval", env: env)
    }

    /// Hosted, so the card's reply field (an AppKit text field, which `ImageRenderer` cannot draw) shows as it is.
    @Test func question() throws {
        let env = try Self.environment()
        let size = CGSize(width: 540, height: 310)
        let scene = AppearanceRenders.islandScene(Self.card(env, Self.question), size: size, backdrop: .preview, theme: .black,
                                                  scheme: .dark)
        try RenderHarness.renderHosted(scene, "readme-question", size: size, env: env)
    }

    /// Black, Glass, Smoke and Solid, two by two, each with the same approval. Offscreen the window server composites no
    /// glass, so Glass and Smoke are the renders' stand-in for it (`IslandGlassRenders`).
    @Test func themes() throws {
        let size = CGSize(width: 540, height: 232)
        var tiles: [AnyView] = []
        for theme in JuiceTheme.allCases {
            let env = try Self.environment(theme: theme)
            let scene = AppearanceRenders.islandScene(Self.card(env, Self.ask), size: size, backdrop: .preview, theme: theme, scheme: .dark)
                .environment(env)
                .overlay(alignment: .bottomLeading) {
                    Text(theme.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 1).padding(.horizontal, 16).padding(.bottom, 12)
                }
            tiles.append(AnyView(scene))
        }
        let grid = VStack(spacing: 0) {
            HStack(spacing: 0) { tiles[0]; tiles[1] }
            HStack(spacing: 0) { tiles[2]; tiles[3] }
        }
        try RenderHarness.render(grid, "readme-themes", size: CGSize(width: 2 * size.width, height: 2 * size.height),
                                 env: try Self.environment())
    }

    /// The repository's social preview, 1280 by 640 pixels as GitHub asks: the approval in the notch, and the name. Not
    /// in the README; the owner uploads it in the repository's settings.
    @Test func socialPreview() throws {
        let env = try Self.environment()
        let size = CGSize(width: 640, height: 320)
        let scene = AppearanceRenders.islandScene(Self.card(env, Self.ask), size: size, backdrop: .preview, theme: .black, scheme: .dark)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Juice").font(.system(size: 30, weight: .bold))
                    Text("Your agents, in the notch").font(.system(size: 16, weight: .medium)).opacity(0.9)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                .padding(.horizontal, 28).padding(.bottom, 22)
            }
        try RenderHarness.render(scene, "social-preview", size: size, env: env)
    }

    @Test func panel() throws {
        let env = try Self.environment()
        let content = DesktopPanelContent.make(usage: env.usage, settings: env.settings)
        let size = try #require(content.size)
        try RenderHarness.render(DesktopPanelView().padding(PanelGeometry.margin), "readme-panel",
                                 size: PanelGeometry.windowSize(for: size), env: env, background: PRenders.wallpaper)
    }

    /// The desktop widget, medium, on the panel's wallpaper, drawn as WidgetKit frames it (`WidgetRenders`).
    @Test func widget() throws {
        let env = try Self.environment()
        let snapshot = WidgetSnapshot.make(env, at: DemoClock.now)
        let size = WidgetRenders.Size.medium, margin = WidgetRenders.margin
        let view = IslandWidgetView(snapshot: snapshot, face: .medium,
                                    size: CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin),
                                    date: DemoClock.now, tinted: false)
            .padding(margin)
            .frame(width: size.width, height: size.height)
            .background {
                RoundedRectangle(cornerRadius: WidgetRenders.radius, style: .continuous).fill(IslandTheme.bg)
            }
            .clipShape(RoundedRectangle(cornerRadius: WidgetRenders.radius, style: .continuous))
            .padding(24)
            .background(PRenders.wallpaper)
        try RenderHarness.render(view, "readme-widget", env: env)
    }

    // MARK: The Agents shot

    static func agentsEnvironment() -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = .black
        settings.appearance = .dark
        return AppEnvironment.demo(settings: settings, sessions: .empty)
    }

    /// The first run's Agents screen on the welcome's made-up Mac (`WelcomeModel.fixture`): Claude Code with Main and
    /// Work, Codex, OpenCode, Copilot CLI and Cursor, each with Approve or Watch, ticked, and Connect.
    @Test func agents() throws {
        let env = Self.agentsEnvironment()
        let model = WelcomeModel.fixture(step: .agents, env: env)
        try RenderHarness.renderHosted(WelcomeView(model: model).environment(\.sessionGlyphsAnimated, false), "readme-agents",
                                       size: WelcomeView.size, env: env, scheme: .dark)
    }
}
