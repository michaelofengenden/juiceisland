import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Other agents shown as themselves (P151): the opened island's list in Clean and Detailed, the window's list, their
/// cards in both island styles and the window, each by state and by agent, and the marks at row size and enlarged.
/// Sessions: `FixtureSessionFeed.Scenario.agents` (OpenCode, Kimi and Qwen need you; Gemini, Cursor and Pi run; the
/// rest done) and `.agentQuestion`. Names `ag-…`: `zsh scripts/render-all.sh AgentRenders`.
@MainActor
@Suite(.serialized)
struct AgentRenders {
    typealias ID = FixtureSessionFeed.AgentID

    private func settings(style: IslandStyle = .clean, glyphs: GlyphColourMode = .byState) -> AppSettings {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        settings.glyphColour = glyphs
        return settings
    }

    // MARK: The opened island's list

    private func island(_ name: String, style: IslandStyle, glyphs: GlyphColourMode = .byState, showAll: Bool = false) throws {
        let env = AppEnvironment.demo(settings: settings(style: style, glyphs: glyphs), sessions: .agents)
        let ui = IslandUIState()
        ui.showAll = showAll
        let view = OpenedIslandView(presentation: .list, notch: IslandTheme.Metrics.referenceNotch, ui: ui, animated: false)
        try RenderHarness.render(DScene.island(view, notch: IslandTheme.Metrics.referenceNotch), name, env: env)
    }

    @Test func islandClean() throws { try island("ag-island-clean", style: .clean) }
    @Test func islandCleanByAgent() throws { try island("ag-island-clean-agent", style: .clean, glyphs: .byAgent) }
    @Test func islandCleanAll() throws { try island("ag-island-clean-all", style: .clean, glyphs: .byAgent, showAll: true) }
    @Test func islandDetailed() throws { try island("ag-island-detailed", style: .detailed) }
    @Test func islandDetailedByAgent() throws { try island("ag-island-detailed-agent", style: .detailed, glyphs: .byAgent) }
    @Test func islandDetailedAll() throws { try island("ag-island-detailed-all", style: .detailed, showAll: true) }

    // MARK: The window's list

    private func list(_ name: String, glyphs: GlyphColourMode) throws {
        let env = AppEnvironment.demo(settings: settings(glyphs: glyphs), sessions: .agents)
        let view = SessionListView()
            .frame(width: 1200, height: 760)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.previewSelectedOption, 0)
        try RenderHarness.renderHosted(view, name, size: CGSize(width: 1216, height: 776), env: env)
    }

    @Test func windowList() throws { try list("ag-window-1200", glyphs: .byState) }
    @Test func windowListByAgent() throws { try list("ag-window-1200-agent", glyphs: .byAgent) }

    // MARK: Cards

    private func islandCard(_ name: String, id: String, style: CardStyle, height: CGFloat,
                            scenario: FixtureSessionFeed.Scenario = .agents, glyphs: GlyphColourMode = .byState) throws {
        let env = AppEnvironment.demo(settings: settings(glyphs: glyphs), sessions: scenario)
        let card = try #require(env.sessions.card(for: id))
        let view = VStack(spacing: 0) {
            Color.black.frame(height: 36)
            SessionCardView(card: card, style: style).padding(.top, style == .islandClean ? 4 : 6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: 660, height: height)
        .background(Color.black)
        .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, name, size: CGSize(width: 660, height: height), env: env)
    }

    private func windowCard(_ name: String, id: String, height: CGFloat, scenario: FixtureSessionFeed.Scenario = .agents) throws {
        let env = AppEnvironment.demo(settings: settings(), sessions: scenario)
        let card = try #require(env.sessions.card(for: id))
        let view = SessionCardView(card: card, style: .window)
            .frame(width: 579)
            .frame(height: height, alignment: .top)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, name, size: CGSize(width: 595, height: height + 16), env: env)
    }

    @Test func cleanOpenCodeApproval() throws {
        try islandCard("ag-card-clean-opencode-approval", id: ID.openCodeApproval, style: .islandClean, height: 200)
    }
    @Test func detailedOpenCodeApproval() throws {
        try islandCard("ag-card-detailed-opencode-approval", id: ID.openCodeApproval, style: .islandDetailed, height: 230, glyphs: .byAgent)
    }
    @Test func windowOpenCodeApproval() throws { try windowCard("ag-card-window-opencode-approval", id: ID.openCodeApproval, height: 180) }
    @Test func cleanKimiApproval() throws {
        try islandCard("ag-card-clean-kimi-approval", id: ID.kimiApproval, style: .islandClean, height: 200)
    }
    @Test func detailedKimiApproval() throws {
        try islandCard("ag-card-detailed-kimi-approval", id: ID.kimiApproval, style: .islandDetailed, height: 230)
    }
    @Test func cleanQwenQuestion() throws {
        try islandCard("ag-card-clean-qwen-question", id: ID.qwenQuestion, style: .islandClean, height: 260)
    }
    @Test func cleanOpenCodeQuestion() throws {
        try islandCard("ag-card-clean-opencode-question", id: ID.openCodeQuestion, style: .islandClean, height: 260, scenario: .agentQuestion)
    }
    @Test func windowOpenCodeQuestion() throws {
        try windowCard("ag-card-window-opencode-question", id: ID.openCodeQuestion, height: 250, scenario: .agentQuestion)
    }
    @Test func cleanGeminiDone() throws { try islandCard("ag-card-clean-gemini-done", id: ID.geminiDone, style: .islandClean, height: 190) }
    @Test func detailedGeminiDone() throws {
        try islandCard("ag-card-detailed-gemini-done", id: ID.geminiDone, style: .islandDetailed, height: 220, glyphs: .byAgent)
    }
    @Test func cleanGrokDone() throws { try islandCard("ag-card-clean-grok-done", id: ID.grokDone, style: .islandClean, height: 170) }
    @Test func windowFactoryDone() throws { try windowCard("ag-card-window-factory-done", id: ID.factoryDone, height: 150) }

    // MARK: Marks

    /// Every agent's mark at the island row's 10 pt and the window's 11 pt, in its colour as rows draw it before the
    /// title, then at 20 pt, beside its By agent running colour and its name.
    @Test func marks() throws {
        let agents: [GlyphPalette.Agent] = [.claude, .codex] + AgentLookTests.others.map { .other($0) }
        let sheet = VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(agents.enumerated()), id: \.offset) { _, agent in
                HStack(spacing: 10) {
                    AgentMarkView(agent: agent, size: Theme.Mark.sessionRow)
                    AgentMarkView(agent: agent, size: 11)
                    AgentMarkView(agent: agent, size: 20)
                    Circle().fill(GlyphPalette.colour(agent: agent, state: .running, mode: .byAgent, needsYou: .pink)).frame(width: 7, height: 7)
                    Text(agent.displayName).font(Fonts.sys(11)).foregroundStyle(IslandTheme.ink2)
                    Spacer(minLength: 0)
                    Text("3m").font(Fonts.num(11, .regular)).foregroundStyle(IslandTheme.rowAge)
                }
                .frame(width: 220, height: 20)
            }
        }
        .padding(10)
        .background(Color.black)
        try RenderHarness.renderPixels(sheet, "ag-marks", scale: 2, zoom: 2)
        let row = HStack(spacing: 8) {
            ForEach(Array(agents.enumerated()), id: \.offset) { _, agent in AgentMarkView(agent: agent, size: Theme.Mark.sessionRow) }
        }
        .padding(4)
        .background(Color.black)
        try RenderHarness.renderPixels(row, "ag-marks-10pt-x4", scale: 2, zoom: 4)
    }
}
