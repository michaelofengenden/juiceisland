import AppKit
import Foundation
@testable import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Answer Codex on the island (P470), headless. `O-settings-island-codex`: Settings › Island with the switch on, under
/// Answer subagents on the island. `O-card-codex-held-{island,detailed}`: Codex in a terminal asks to run a migration,
/// held for the island, 7 s of its 12 left: No and Yes, the time left a thin line along Yes's foot, no Always allow and
/// no No and stop (Codex's hook takes neither). `O-card-codex-released-island`: the same request once its hold ended,
/// read-only where it was (Open, ✕), answered in Codex. Demo engines fed through the live paths (the broker's request as
/// the helper hands it, the rollout as the tracker folds it); nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct CodexOptInRenders {
    static let session = "demo-codex-held"
    static let rollout = FixtureSessionFeed.demoRollout(session)
    static let command = "python3 scripts/migrate.py --apply --database data/notes.sqlite"

    /// A demo engine with the Codex session, its rollout's reviewer (the owner) and its request, held for the island and
    /// shown; the model's clock `elapsed` seconds on.
    private func scene(elapsed: TimeInterval = 5, released: Bool = false, window: Bool = false,
                       configure: (AppSettings) -> Void = { _ in }) async throws -> AppEnvironment {
        let now = DemoClock.now
        let feed = FixtureSessionFeed(scenario: .attention, now: now)
        let engine = feed.engine
        engine.loadPreviewEvents(FixtureSessionFeed.start(Self.session, title: "Run the migration", project: "field-notes",
                                                          prompt: "run the migration", tool: .codex, at: now - 120,
                                                          transcript: Self.rollout))
        let folder = NSHomeDirectory() + "/Developer/field-notes"
        engine.loadPreviewRollout(sessionID: Self.session, transcriptPath: Self.rollout, lines: [
            FixtureSessionFeed.rolloutLine("session_meta", ["id": Self.session, "timestamp": FixtureSessionFeed.stamp(now - 120),
                                                            "cwd": folder, "originator": "codex_cli_rs", "source": "cli"], at: now - 120),
            FixtureSessionFeed.rolloutLine("turn_context", ["cwd": folder, "model": "gpt-6", "approval_policy": "on-request",
                                                            "approvals_reviewer": "user"], at: now - 119),
            FixtureSessionFeed.rolloutEvent("task_started", ["model_context_window": 272_000], at: now - 118),
        ])
        engine.answersCodex = true
        engine.loadPreviewHookRequest([
            "hook_event_name": "PermissionRequest", "session_id": Self.session, "turn_id": "turn-demo-2", "cwd": folder,
            "transcript_path": Self.rollout, "model": "gpt-6", "permission_mode": "default", "tool_name": "Bash",
            "tool_input": ["command": Self.command, "description": "Apply the pending migration to the local database?"],
        ], source: "codex")
        for _ in 0..<200 where engine.attentionHead(for: Self.session) == nil { try await Task.sleep(for: .milliseconds(5)) }
        let request = try #require(engine.attentionHead(for: Self.session))
        #expect(request.isHeldForIsland && request.isConfirmed && request.tool == .codex)
        if window { engine.windowShows(requestIDs: [request.id]) } else { engine.islandShows(requestID: request.id) }
        if released { engine.islandShows(requestID: nil) }
        let settings = AppSettings.ephemeral()
        settings.answerCodexOnIsland = true
        configure(settings)
        let model = EngineSessionsModel(engine: engine, clock: { now + elapsed })
        return AppEnvironment(settings: settings, usage: DemoUsageModel(now: now), sessions: model)
    }

    private func island(_ name: String, env: AppEnvironment) throws {
        let view = OpenedIslandView(presentation: .card(sessionID: Self.session), notch: IslandTheme.Metrics.referenceNotch,
                                    ui: IslandUIState(), animated: false)
        let scene = DScene.island(view, notch: IslandTheme.Metrics.referenceNotch)
        let probe = NSHostingView(rootView: scene.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(scene, name, size: probe.fittingSize, env: env)
    }

    private func card(_ name: String, style: CardStyle, env: AppEnvironment) throws {
        let card = try #require(env.sessions.card(for: Self.session))
        let content = VStack(spacing: 0) {
            Color.black.frame(height: 36)
            SessionCardView(card: card, style: style).padding(.top, style == .islandClean ? 4 : 6)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(width: 660)
        .background(Color.black)
        .environment(\.sessionGlyphsAnimated, false)
        let probe = NSHostingView(rootView: content.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(content, name, size: probe.fittingSize, env: env)
    }

    @Test func settingsRow() throws {
        let settings = AppSettings.ephemeral()
        settings.answerCodexOnIsland = true
        let env = AppEnvironment.demo(settings: settings)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .island), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.locale, Locale(identifier: "en_GB"))
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "O-settings-island-codex", size: CGSize(width: SettingsTheme.Metrics.width, height: height),
                                       env: env)
        #expect(IslandPaneText.answerCodex == "Codex's own prompt waits up to 12 s.")
    }

    @Test func heldCardIsland() async throws {
        let env = try await scene()
        guard case let .approval(card)? = env.sessions.card(for: Self.session) else { Issue.record("no approval card"); return }
        #expect(card.isAnswerable && card.alwaysAllowLabel == nil && !card.canStop && card.request?.holdEnds != nil)
        #expect(card.body == .command(Self.command))
        #expect(HoldCountdown.left(until: try #require(card.request?.holdEnds), now: env.sessions.now, total: CodexHold.limit) == 7)
        try island("O-card-codex-held-island", env: env)
    }

    @Test func heldCardDetailed() async throws {
        let env = try await scene { $0.islandStyle = .detailed }
        try card("O-card-codex-held-detailed", style: .islandDetailed, env: env)
    }

    /// Window mode (P1050): the window's Needs you card holds the request as the island's does, with the same No and
    /// Yes and the time left along Yes's foot.
    @Test func heldCardWindow() async throws {
        let env = try await scene(window: true) { $0.showAs = .window }
        guard case let .approval(card)? = env.sessions.card(for: Self.session) else { Issue.record("no approval card"); return }
        #expect(card.isAnswerable && card.request?.holdEnds != nil)
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true).environment(\.sessionGlyphsAnimated, false),
                                       "O-window-codex-held", size: CGSize(width: 1000, height: 560), env: env)
    }

    @Test func releasedCardIsland() async throws {
        let env = try await scene(elapsed: 12, released: true)
        guard case let .approval(card)? = env.sessions.card(for: Self.session) else { Issue.record("no approval card"); return }
        #expect(!card.isAnswerable && card.request?.dismissable == true && card.request?.holdEnds == nil)
        try island("O-card-codex-released-island", env: env)
    }
}
