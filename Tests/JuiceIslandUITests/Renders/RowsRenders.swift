import AppKit
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The rows lane (P310-P312): the opened island in Clean and Detailed with models, modes and task lists and a stalled
/// run; a row's peek in both styles (under its row, over the rows below it, and with the room the list lacks); the stalled
/// run's one notice as a card in both styles; the window's list with the stalled row. Sessions:
/// `FixtureSessionFeed.Scenario.rows`, stalled after 10 minutes. Names `rw-…`: `zsh scripts/render-all.sh RowsRenders`.
@MainActor
@Suite(.serialized)
struct RowsRenders {
    typealias ID = FixtureSessionFeed.RowsID
    static let notch = IslandTheme.Metrics.referenceNotch
    static let limit: TimeInterval = 600

    static func env(_ style: IslandStyle, glyph: GlyphStyle = .pixel) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        settings.glyphStyle = glyph
        return AppEnvironment.demo(settings: settings, sessions: .rows, stalledAfter: limit)
    }

    // MARK: The opened island

    @Test(arguments: [IslandStyle.clean, .detailed])
    func island(_ style: IslandStyle) throws {
        let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "rw-island-\(style.rawValue)", env: Self.env(style))
    }

    // MARK: Peeks

    /// A peek as the island shows it: hosted, so it is measured and placed (and the room it lacks added) before the
    /// picture is taken.
    private func renderPeek(_ env: AppEnvironment, _ peek: SessionPeek, _ name: String) throws {
        let ui = IslandUIState()
        ui.peek = peek
        let view = DScene.island(OpenedIslandView(presentation: .list, notch: Self.notch, ui: ui, animated: false), notch: Self.notch)
            .environment(\.sessionGlyphsAnimated, false)
        let hosting = NSHostingView(rootView: view.environment(env).environment(\.colorScheme, .dark))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let size = CGSize(width: 920, height: ceil(hosting.fittingSize.height))
        try RenderHarness.renderHosted(view, name, size: size, env: env)
    }

    /// Clean: the Codex chat's peek under its row (its reply, and the model and progress Clean rows leave to it).
    @Test func peekCleanCodex() async throws {
        let env = Self.env(.clean)
        let peek = try #require(await env.sessions.peek(ID.codexRunning, clean: true))
        try renderPeek(env, peek, "rw-peek-clean-codex")
    }

    /// Clean: a Claude turn still running, its transcript tail read (a fixture read: no file is opened here): the prompt,
    /// the reply so far and the model, mode and progress.
    @Test func peekCleanClaudeRunning() throws {
        let env = Self.env(.clean)
        let row = try #require(env.sessions.row(id: ID.claudePlan))
        let read = SessionPeekRead(prompt: "how should search index the notes? plan it first", reply: "The index is rebuilt on every save; a tokenizer per locale would halve it.",
                                   tool: "Read", toolDetail: "search/index.ts", model: "claude-opus-5-5")
        let peek = try #require(SessionPeek.make(row: row, clean: true, prompt: row.lastPrompt, reply: nil, replyIsCurrent: false, read: read))
        try renderPeek(env, peek, "rw-peek-clean-claude")
    }

    /// Detailed: the finished turn's whole reply under its row (the row's line has room for its first words only).
    @Test func peekDetailedDone() async throws {
        let env = Self.env(.detailed)
        let peek = try #require(await env.sessions.peek(ID.claudeDone, clean: false))
        try renderPeek(env, peek, "rw-peek-detailed-done")
    }

    /// Clean: the Claude turn done, whose row is the list's third of four: its peek lies over the last row, and the list
    /// grows by what the last row leaves it short.
    @Test func peekCleanDone() async throws {
        let env = Self.env(.clean)
        let peek = try #require(await env.sessions.peek(ID.claudeDone, clean: true))
        try renderPeek(env, peek, "rw-peek-clean-done")
    }

    /// One row, and its peek needs more than the list has: the list, and so the island, grows by what it lacks.
    @Test func peekRoom() async throws {
        let settings = AppSettings.ephemeral()
        let feed = FixtureSessionFeed(scenario: .rows, now: DemoClock.now)
        let model = feed.makeModel(stalledAfter: Self.limit)
        let only = try #require(model.row(id: ID.claudeDone))
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: [only]))
        let peek = try #require(await model.peek(ID.claudeDone, clean: true))
        try renderPeek(env, peek, "rw-peek-clean-room")
    }

    // MARK: The stalled notice

    @Test(arguments: [IslandStyle.clean, .detailed])
    func stalledCard(_ style: IslandStyle) throws {
        let env = Self.env(style)
        let view = OpenedIslandView(presentation: .card(sessionID: ID.claudeStalled), notch: Self.notch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "rw-stalled-card-\(style.rawValue)", env: env)
    }

    // MARK: The window

    @Test func window() throws {
        let env = Self.env(.clean)
        let view = SessionListView()
            .frame(width: 1_000, height: 420)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, "rw-window", size: CGSize(width: 1_016, height: 436), env: env)
    }
}
