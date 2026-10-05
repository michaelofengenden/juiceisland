import AppKit
import Foundation
@testable import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The needs-you pipeline's UI (the needs-you design §3.5): the owner's two situations as the island now draws them
/// (a Codex app thread's question as a read-only card, a Claude row with its owner's prompt instead of a background
/// task's notice), answerable and read-only request cards in the island and the window, the × of a failed turn in
/// each glyph style, and Setup's Hook helper · Update. Demo engines fed through the live paths
/// (`FixtureSessionFeed+Attention.swift`); nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct NRenders {
    typealias ID = FixtureSessionFeed.AttentionID

    private func env(_ scenario: FixtureSessionFeed.Scenario, configure: (AppSettings) -> Void = { _ in }) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        configure(settings)
        return AppEnvironment.demo(settings: settings, sessions: scenario)
    }

    /// The opened island at the reference notch, hosted (cards hold AppKit fields), at its own height.
    private func island(_ name: String, _ presentation: IslandPresentation, env: AppEnvironment) throws {
        let view = OpenedIslandView(presentation: presentation, notch: IslandTheme.Metrics.referenceNotch, ui: IslandUIState(), animated: false)
        let scene = DScene.island(view, notch: IslandTheme.Metrics.referenceNotch)
        let probe = NSHostingView(rootView: scene.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(scene, name, size: probe.fittingSize, env: env)
    }

    /// A card as tall as it is, as the island (660 wide) or the window (595) draws it.
    private func card(_ name: String, id: String, style: CardStyle, env: AppEnvironment) throws {
        let card = try #require(env.sessions.card(for: id))
        let content = VStack(spacing: 0) {
            Color.black.frame(height: style == .window ? 8 : 36)
            SessionCardView(card: card, style: style).padding(.top, style == .islandClean ? 4 : style == .window ? 0 : 6)
        }
        .padding(.horizontal, style == .window ? 8 : 12)
        .padding(.bottom, 12)
        .frame(width: style == .window ? 595 : 660)
        .background(Color.black)
        .environment(\.sessionGlyphsAnimated, false)
        let probe = NSHostingView(rootView: content.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(content, name, size: probe.fittingSize, env: env)
    }

    private func windowList(_ name: String, env: AppEnvironment, height: CGFloat) throws {
        let view = SessionListView().frame(width: 900, height: height).padding(8).background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, name, size: CGSize(width: 916, height: height + 16), env: env)
    }

    // MARK: The owner's two situations, after (the before shots come from build dfd752c)

    @Test func ownerIslandClean() throws { try island("N-owner-island-clean", .list, env: env(.owner)) }
    @Test func ownerIslandDetailed() throws {
        try island("N-owner-island-detailed", .list, env: env(.owner) { $0.islandStyle = .detailed })
    }
    @Test func ownerWindowList() throws { try windowList("N-owner-window-list", env: env(.owner), height: 470) }
    @Test func ownerQuestionIsland() throws { try island("N-owner-question-island", .card(sessionID: ID.codexQuestion), env: env(.owner)) }
    @Test func ownerQuestionDetailed() throws {
        try card("N-owner-question-detailed", id: ID.codexQuestion, style: .islandDetailed, env: env(.owner))
    }
    @Test func ownerQuestionWindow() throws { try card("N-owner-question-window", id: ID.codexQuestion, style: .window, env: env(.owner)) }

    // MARK: Requests, answerable and read-only

    @Test func attentionIslandClean() throws { try island("N-attention-island-clean", .list, env: env(.attention)) }
    @Test func attentionIslandDetailed() throws {
        try island("N-attention-island-detailed", .list, env: env(.attention) { $0.islandStyle = .detailed })
    }
    @Test func attentionWindowList() throws { try windowList("N-attention-window-list", env: env(.attention), height: 560) }

    /// Claude's two requests in Ghostty: the answerable card, "· N more" counting the one behind it and every other.
    @Test func claudeQueueIsland() throws { try island("N-card-claude-queue-island", .card(sessionID: ID.claudeQueue), env: env(.attention)) }
    @Test func claudeQueueWindow() throws { try card("N-card-claude-queue-window", id: ID.claudeQueue, style: .window, env: env(.attention)) }
    /// Codex in a terminal: released to Codex's own prompt; the command, why, Open and ✕.
    @Test func codexReadOnlyIsland() throws {
        try island("N-card-codex-readonly-island", .card(sessionID: ID.codexApproval), env: env(.attention))
    }
    @Test func codexReadOnlyDetailed() throws {
        try card("N-card-codex-readonly-detailed", id: ID.codexApproval, style: .islandDetailed, env: env(.attention))
    }
    @Test func codexReadOnlyWindow() throws { try card("N-card-codex-readonly-window", id: ID.codexApproval, style: .window, env: env(.attention)) }
    @Test func subagentCard() throws { try card("N-card-subagent-clean", id: ID.subagent, style: .islandClean, env: env(.attention)) }
    @Test func desktopCard() throws { try card("N-card-desktop-clean", id: ID.desktop, style: .islandClean, env: env(.attention)) }
    @Test func noticeCard() throws { try card("N-card-notice-clean", id: ID.notice, style: .islandClean, env: env(.attention)) }
    @Test func noticeCardWindow() throws { try card("N-card-notice-window", id: ID.notice, style: .window, env: env(.attention)) }

    // MARK: The × of a failed turn

    @Test func failedGlyphInEachStyle() throws {
        for style in GlyphStyle.allCases {
            let env = env(.attention) { $0.glyphStyle = style }
            let row = try #require(env.sessions.row(id: ID.failed))
            let view = VStack(alignment: .leading, spacing: 0) {
                CleanSessionRow(row: row, animated: false)
                DetailedRowView(row: row, metrics: .window)
            }
            .padding(12).frame(width: 600, height: 110, alignment: .top).background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
            try RenderHarness.renderHosted(view, "N-glyph-failed-\(style.rawValue)", size: CGSize(width: 600, height: 110), env: env)
        }
    }

    /// The closed pill with a failed turn and a running session: its lead is the ×.
    @Test func failedPill() throws {
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: [
            DStub.row("f", .claude, .needsYou, glyph: .cross, status: .failed), DStub.row("r", .codex, .running)]))
        try RenderHarness.render(DScene.pill(ClosedPillView(animated: false)), "N-pill-failed", env: env)
    }

    // MARK: Setup › Hooks: Hook helper · Update

    private func setup(_ name: String, _ update: HelperUpdate) throws {
        let env = AppEnvironment.demo()
        env.hooks = DemoHooksModel(helperUpdate: update)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .agents), drawsTrafficLights: true, scrolls: false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    @Test func setupHelperUpdate() throws { try setup("N-setup-helper-update", .available) }
    @Test func setupHelperUpdating() throws { try setup("N-setup-helper-updating", .updating) }
    @Test func setupHelperRefused() throws { try setup("N-setup-helper-refused", .refused("Quit Open Island first")) }

    @Test func islandHelperRow() throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        env.hooks = DemoHooksModel(helperUpdate: .available)
        let view = OpenedIslandView(presentation: .list, notch: IslandTheme.Metrics.referenceNotch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: IslandTheme.Metrics.referenceNotch), "N-island-helper-row", env: env)
    }

    @Test func windowHelperRow() throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        env.hooks = DemoHooksModel(helperUpdate: .available)
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), "N-window-helper-row", size: WindowTheme.Metrics.defaultSize,
                                       env: env)
    }
}
