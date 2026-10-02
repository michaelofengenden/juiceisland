import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Claude Code and Codex told apart, titled as their chats (P200-P208): the opened island in Clean and Detailed in each
/// glyph style, the default Clean island with its footer, the cards in the island's two styles and the window, the
/// window's list, the closed pill (by state whatever Glyph colour says), every state per agent by state and by agent,
/// By agent in Liquid and Sand, Detailed's Codex group with a long title, and titles at Codex's 36 characters,
/// Claude's 200 and the repo alone. Sessions: `FixtureSessionFeed.Scenario.look`.
/// Names `lk-…`: `zsh scripts/render-all.sh LookRenders`.
@MainActor
@Suite(.serialized)
struct LookRenders {
    typealias ID = FixtureSessionFeed.LookID
    static let notch = IslandTheme.Metrics.referenceNotch

    private func settings(_ island: IslandStyle = .clean, _ glyph: GlyphStyle = .pixel, colour: GlyphColourMode = .byState) -> AppSettings {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = island
        settings.glyphStyle = glyph
        settings.glyphColour = colour
        settings.glyphEdgeLine = true
        return settings
    }

    // MARK: The opened island

    @Test(arguments: [IslandStyle.clean, .detailed], [GlyphStyle.pixel, .liquid, .sand])
    func island(_ island: IslandStyle, _ glyph: GlyphStyle) throws {
        let env = AppEnvironment.demo(settings: settings(island, glyph), sessions: .look)
        let ui = IslandUIState()
        ui.showAll = true
        let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: ui, animated: false)
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "lk-island-\(island.rawValue)-\(glyph.rawValue)", env: env)
    }

    /// The default Clean island: four rows and the footer's marks.
    @Test func islandCleanFooter() throws {
        let env = AppEnvironment.demo(settings: settings(.clean, .liquid), sessions: .look)
        let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "lk-island-clean-liquid-footer", env: env)
    }

    /// By agent: the running glyphs in their agents' colours, every state that needs you as by state. In Sand a running
    /// stream and an approval's "!" are both a warm stroke over a pile, so Claude's running glyph takes its redder tint
    /// and never reads as one more approval (P207).
    @Test(arguments: [IslandStyle.clean, .detailed], [GlyphStyle.liquid, .sand])
    func islandByAgent(_ island: IslandStyle, _ glyph: GlyphStyle) throws {
        let env = AppEnvironment.demo(settings: settings(island, glyph, colour: .byAgent), sessions: .look)
        let ui = IslandUIState()
        ui.showAll = true
        let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: ui, animated: false)
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "lk-island-\(island.rawValue)-\(glyph.rawValue)-agent", env: env)
    }

    /// Detailed's Codex group under four other active rows, one Codex row titled by a 110-character first prompt: the
    /// title is cut at the tail inside the island, never laid out past it (P209).
    @Test func islandCodexGroupLongTitle() throws {
        func row(_ id: String, _ agent: GlyphPalette.Agent, _ bucket: SessionBucket, _ task: String, _ source: TitleSource,
                 minutes: Double) -> SessionRow {
            var row = DStub.row(id, agent, bucket, project: "notes-site", task: task, minutesAgo: minutes)
            row.titleSource = source
            return row
        }
        let rows = [
            row("n1", .claude, .needsYou, "Ship the window mode", .agent, minutes: 1),
            row("r1", .claude, .running, "Tighten the card spacing", .agent, minutes: 2),
            row("r2", .claude, .running, "Name the app", .agent, minutes: 2),
            row("r3", .claude, .running, "Write the release checklist", .agent, minutes: 2),
            row("c1", .codex, .running, Self.longPrompt, .prompt, minutes: 3),
            row("c2", .codex, .running, "Resize the MCP images for the docs", .agent, minutes: 4),
        ]
        let env = AppEnvironment(settings: settings(.detailed, .liquid), usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: rows))
        let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "lk-island-detailed-codex-group-long", env: env)
        // The window's group, at a first prompt's 200 characters: the title is cut, the status stays whole.
        var windowRows = rows
        windowRows[4].task = Self.longPrompt + ", and tag the release once the checks are green on every runner the harness uses today"
        let window = AppEnvironment(settings: settings(.clean, .liquid), usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: windowRows))
        let list = SessionListView()
            .frame(width: 900, height: 560)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(list, "lk-window-codex-group-long", size: CGSize(width: 916, height: 576), env: window)
    }

    /// A first prompt at 110 characters, as `codex exec` or a first turn before Codex's own title titles a row.
    static let longPrompt = "compare the three eval runs and write up what changed in the harness, then open a pull request with the notes"

    // MARK: Cards

    @Test(arguments: [CardStyle.islandClean, .islandDetailed, .window])
    func cards(_ style: CardStyle) throws {
        let env = AppEnvironment.demo(settings: settings(style == .islandDetailed ? .detailed : .clean, .liquid), sessions: .look)
        let cards = try [ID.claudeApproval, ID.codexApproval, ID.openCodeQuestion, ID.claudeLong].map { try #require(env.sessions.card(for: $0)) }
        let width: CGFloat = style == .window ? 579 : 460
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                SessionCardView(card: card, style: style).frame(width: width)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: width + 24, height: 1_020, alignment: .top)
        .background(Color.black)
        .environment(\.sessionGlyphsAnimated, false)
        let name = style == .window ? "window" : style == .islandClean ? "clean" : "detailed"
        try RenderHarness.renderHosted(view, "lk-cards-\(name)", size: CGSize(width: width + 24, height: 1_020), env: env)
    }

    // MARK: The window's list

    @Test(arguments: [GlyphColourMode.byState, .byAgent])
    func window(_ colour: GlyphColourMode) throws {
        let env = AppEnvironment.demo(settings: settings(.clean, .liquid, colour: colour), sessions: .look)
        let view = SessionListView()
            .frame(width: 1_000, height: 620)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, "lk-window\(colour == .byAgent ? "-agent" : "")", size: CGSize(width: 1_016, height: 636), env: env)
    }

    // MARK: The closed pill

    /// The board's lead (an approval) and a board where only Codex, or only Claude, runs, By agent: the pill keeps
    /// the state's colours (P206).
    @Test(arguments: [GlyphStyle.pixel, .liquid])
    func pill(_ glyph: GlyphStyle) throws {
        let env = AppEnvironment.demo(settings: settings(.clean, glyph, colour: .byAgent), sessions: .look)
        try RenderHarness.render(DScene.pill(ClosedPillView(animated: false)), "lk-pill-needs-\(glyph.rawValue)", env: env)
        for agent in [GlyphPalette.Agent.codex, .claude] {
            let running = env.sessions.rows.filter { $0.agent == agent && $0.bucket == .running }
            let only = AppEnvironment(settings: settings(.clean, glyph, colour: .byAgent), usage: DemoUsageModel(now: DemoClock.now),
                                      sessions: DStub(rows: running))
            try RenderHarness.render(DScene.pill(ClosedPillView(animated: false)), "lk-pill-\(agent.displayName.lowercased())-running-\(glyph.rawValue)",
                                     env: only)
        }
    }

    // MARK: States

    /// Every state for Claude, Codex, OpenCode, Gemini and Pi (the two greens), each glyph style, by state and by agent:
    /// the agent's mark in its colour beside them.
    @Test(arguments: [GlyphColourMode.byState, .byAgent])
    func states(_ colour: GlyphColourMode) throws {
        let agents: [GlyphPalette.Agent] = [.claude, .codex, .other(.openCode), .other(.geminiCLI), .other(.pi)]
        let moods: [(PixelGlyph, GlyphPalette.State, String)] = [
            (.eq, .running, "Running"), (.bang, .waiting, "Approval"), (.ques, .waiting, "Question"), (.cross, .waiting, "Failed"),
            (.check, .done, "Done"), (.check, .idle, "Earlier"),
        ]
        let sheet = VStack(alignment: .leading, spacing: 14) {
            ForEach([GlyphStyle.pixel, .liquid, .sand], id: \.self) { style in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 0) {
                        Text(style.rawValue).font(Fonts.sys(10, .semibold)).foregroundStyle(IslandTheme.ink2).frame(width: 96, alignment: .leading)
                        ForEach(Array(moods.enumerated()), id: \.offset) { _, mood in
                            Text(mood.2).font(Fonts.sys(10)).foregroundStyle(IslandTheme.ink3).frame(width: 60)
                        }
                    }
                    ForEach(Array(agents.enumerated()), id: \.offset) { _, agent in
                        HStack(spacing: 0) {
                            HStack(spacing: 5) {
                                AgentMarkView(agent: agent, size: 11)
                                Text(agent.displayName).font(Fonts.sys(11, .semibold)).foregroundStyle(IslandTheme.ink)
                            }
                            .frame(width: 96, alignment: .leading)
                            ForEach(Array(moods.enumerated()), id: \.offset) { _, mood in
                                StateGlyphView(glyph: mood.0, colour: GlyphPalette.colour(agent: agent, state: mood.1 == .idle ? .done : mood.1, mode: colour,
                                                                                         needsYou: .pink),
                                               pixel: 2, dimmed: mood.1 == .idle, animated: false, style: style, engineSide: 20)
                                    .frame(width: 20, height: 20)
                                    .frame(width: 60)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.black)
        try RenderHarness.render(sheet, "lk-states-\(colour == .byAgent ? "agent" : "state")", env: AppEnvironment.demo(settings: settings()))
    }

    // MARK: Title lengths

    /// Codex's automatic title (36 characters at most), Claude's name at 200, a first prompt, and the repo alone before
    /// any prompt, in the island's Clean and Detailed lists and the window's.
    @Test func titleLengths() throws {
        func row(_ id: String, _ agent: GlyphPalette.Agent, _ task: String, _ source: TitleSource, project: String = "juice-island",
                 bucket: SessionBucket = .running, minutes: Double = 3) -> SessionRow {
            var row = DStub.row(id, agent, bucket, project: project, task: task, minutesAgo: minutes)
            row.titleSource = source
            return row
        }
        let rows = [
            row("t36", .codex, "Resize the MCP images for the docs", .agent, project: "Desktop"),
            row("t200", .claude, FixtureSessionFeed.longTitle, .agent),
            row("tprompt", .claude, "build it", .prompt, project: "MarathonTrainingLog", minutes: 1),
            row("trepo", .codex, "notes-site", .repo, project: "notes-site", bucket: .needsYou, minutes: 0),
        ]
        for island in [IslandStyle.clean, .detailed] {
            let env = AppEnvironment(settings: settings(island, .liquid), usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: rows))
            let ui = IslandUIState()
            ui.showAll = true
            let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: ui, animated: false)
            try RenderHarness.render(DScene.island(view, notch: Self.notch), "lk-titles-\(island.rawValue)", env: env)
        }
        let env = AppEnvironment(settings: settings(.clean, .liquid), usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: rows))
        let view = SessionListView()
            .frame(width: 1_000, height: 420)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, "lk-titles-window", size: CGSize(width: 1_016, height: 436), env: env)
    }

    // MARK: Settings

    /// Island › Glyph colour's preview under By agent: the running glyph in Claude's colour, the others by state.
    @Test func glyphColourPreview() throws {
        let view = VStack(alignment: .trailing, spacing: 10) {
            ForEach([GlyphStyle.pixel, .liquid, .sand], id: \.self) { style in GlyphStylePreview(style: style) }
        }
        .padding(12)
        .background(Color(hex: 0x1C1C1E))
        .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.render(view, "lk-settings-glyph-colour-agent", env: AppEnvironment.demo(settings: settings(colour: .byAgent)))
    }
}
