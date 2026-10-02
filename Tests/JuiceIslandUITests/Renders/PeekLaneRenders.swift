import AppKit
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Lane PEEK (P720 to P729). `pk-peek-codex-<theme>`: the rows fixture's Codex chat's peek, its reasoning summary and its
/// seven-step plan (a window around the current step), on Black, Glass and Smoke. `pk-peek-claude-detailed`: Claude's
/// task list in a Detailed peek. `pk-peek-claude-todos`: a Clean peek whose list is the transcript's `TodoWrite`.
/// `pk-pill-snoozed-<n>`: the closed pill with Snooze's moon, after a count, after the update dot, with Liquid.
/// `pk-settings-island`: the Island pane with Archive idle sessions after. Every text and folder fictional.
@MainActor
@Suite(.serialized)
struct PeekLaneRenders {
    typealias ID = FixtureSessionFeed.RowsID

    static func env(_ style: IslandStyle = .clean, configure: (AppSettings) -> Void = { _ in }) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        settings.islandUsagePlacement = .headerStrip
        settings.glyphStyle = .pixel
        configure(settings)
        return AppEnvironment.demo(settings: settings, sessions: .rows, stalledAfter: 600)
    }

    /// The room the list lacks for `peek` (`IslandUIState.peekRoom`), as the live island adds it: the opened island laid
    /// out once with it, hosted.
    private func room(_ env: AppEnvironment, _ peek: SessionPeek) -> CGFloat {
        _ = NSApplication.shared
        let ui = IslandUIState()
        ui.peek = peek
        let view = OpenedIslandView(presentation: .list, notch: IslandGlassRenders.notch, ui: ui, animated: false)
            .environment(\.sessionGlyphsAnimated, false)
        let hosting = NSHostingView(rootView: view.environment(env).environment(\.colorScheme, .dark))
        hosting.frame = CGRect(x: 0, y: 0, width: 920, height: 900)
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return ui.peekRoom
    }

    /// The opened island with `peek` under its row, as the glass renders draw it (hosted, so the peek is measured and
    /// placed), the list grown by the room it lacks, on the busy backdrop.
    private func renderPeek(_ env: AppEnvironment, _ peek: SessionPeek, theme: JuiceTheme, _ name: String) throws {
        var layout = DMotionRenders.measure(env: env, notch: IslandGlassRenders.notch, card: nil)
        layout.list += room(env, peek)
        let ui = IslandGlassRenders.state(env, surface: .island, layout: layout)
        ui.reduceMotion = true
        ui.peek = peek
        let size = CGSize(width: 540, height: 460)
        try RenderHarness.renderHosted(IslandGlassRenders.scene(ui, size: size, backdrop: .busy, theme: theme)
            .environment(\.sessionGlyphsAnimated, false), name, size: size, env: env)
    }

    @Test(arguments: JuiceTheme.allCases)
    func codexPeek(_ theme: JuiceTheme) async throws {
        let env = Self.env()
        let peek = try #require(await env.sessions.peek(ID.codexRunning, clean: true))
        #expect(peek.thinking != nil && peek.steps.count == 7)
        try renderPeek(env, peek, theme: theme, "pk-peek-codex-\(theme.rawValue)")
    }

    @Test func claudeDetailedPeek() async throws {
        let env = Self.env(.detailed)
        let peek = try #require(await env.sessions.peek(ID.claudePlan, clean: false))
        #expect(peek.steps.count == 5)
        try renderPeek(env, peek, theme: .black, "pk-peek-claude-detailed")
    }

    /// A Claude turn whose list is in its transcript only (`TodoWrite`): the read's todos (a fixture read; no file is
    /// opened), the current step's text long enough to cut.
    @Test func claudeTodosPeek() throws {
        let env = Self.env()
        var row = try #require(env.sessions.row(id: ID.claudeStalled))
        row.facts.progress = nil
        let read = SessionPeekRead(prompt: "run the whole e2e suite until it passes", tool: "Bash", toolDetail: "npm run test:e2e",
                                   todos: [.init("Run the suite once to see what fails", .done),
                                           .init("Fix the upload retry that waits on the shared timer and never gives up", .current),
                                           .init("Run it 20 times", .pending)])
        let peek = try #require(SessionPeek.make(row: row, clean: true, prompt: row.lastPrompt, reply: nil, replyIsCurrent: false, read: read))
        try renderPeek(env, peek, theme: .black, "pk-peek-claude-todos")
    }

    /// The closed pill while snoozed: the moon after the count; after the update dot too; with Liquid's glyph.
    @Test func snoozedPill() throws {
        let cases: [(String, (AppSettings) -> Void)] = [
            ("count", { _ in }),
            ("liquid", { $0.glyphStyle = .liquid; $0.glyphEdgeLine = true }),
        ]
        for (name, configure) in cases {
            let env = Self.env(configure: configure)
            env.settings.snoozedUntil = Date.distantFuture
            try RenderHarness.render(DScene.pill(ClosedPillView(animated: false)), "pk-pill-snoozed-\(name)", env: env)
        }
        let env = Self.env()
        env.settings.snoozedUntil = Date.distantFuture
        let notch = IslandTheme.Metrics.referenceNotch
        let rows = env.sessions.rows
        let content = PillContent.make(rows: rows, settings: env.settings, glance: true, recentlyFinished: nil, now: env.sessions.now,
                                       notch: notch, menuBar: IslandTheme.Metrics.referenceMenuBar, update: true)
        #expect(content.snoozed && content.update)
        try RenderHarness.render(DScene.pill(ClosedPillView(animated: false, content: content)), "pk-pill-snoozed-dots", env: env)
    }

    @Test func islandSettings() throws {
        let env = AppEnvironment.demo(settings: .ephemeral())
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .island), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.locale, Locale(identifier: "en_GB"))
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "pk-settings-island", size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }
}
