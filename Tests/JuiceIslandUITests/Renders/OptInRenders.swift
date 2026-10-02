import AppKit
import Foundation
@testable import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Answer subagents on the island (P350), headless. `O-settings-island-subagents`: Settings › Island with the switch
/// on, under Sessions. `O-card-subagent-held-{island,detailed,window}`: the screenshot's request (a workflow's subagent
/// asks for Bash in the desktop app) held for the island, 7 s of its 12 left: No and Yes, the time left a thin line
/// along Yes's foot; `O-card-subagent-held-reason-island`: the owner ⌥-clicked No to say why, and the line runs along
/// the reason field's foot instead. `O-card-subagent-released-island`: the same request once its hold ended, read-only
/// where it was (Open, ✕). Demo engines fed through the live paths; nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct OptInRenders {
    static let session = "demo-claude-workflow"

    /// The attention demo with the screenshot's session and its subagent's request, held for the island and shown; the
    /// model's clock `elapsed` seconds on.
    private func scene(elapsed: TimeInterval = 5, released: Bool = false,
                       configure: (AppSettings) -> Void = { _ in }) throws -> (env: AppEnvironment, feed: FixtureSessionFeed) {
        let now = DemoClock.now
        let feed = FixtureSessionFeed(scenario: .attention, now: now)
        feed.engine.loadPreviewEvents(FixtureSessionFeed.start(Self.session, title: "Shoot the site's charts", project: "notes-site",
                                                               prompt: "run the site workflow", at: now - 180, terminal: "Claude.app"))
        feed.engine.answersSubagents = true
        feed.engine.loadPreviewHookRequest(FixtureSessionFeed.claudeRequest(Self.session, tool: "Bash", useID: "toolu_demo_shots", input: [
            "command": "cd ~/Developer/notes-site/site && rm -f shots/* && node probe.cjs",
            "description": "Shoot pinned charts in light and dark"], agent: "agent-demo-wf1", agentType: "workflow-subagent"),
                                           source: "claude", entrypoint: "claude-desktop")
        let request = try #require(feed.engine.attentionHead(for: Self.session))
        #expect(request.isHeldForIsland && request.isConfirmed)
        feed.engine.islandShows(requestID: request.id)
        if released { feed.engine.islandShows(requestID: nil) }
        let settings = AppSettings.ephemeral()
        settings.answerSubagentsOnIsland = true
        configure(settings)
        let model = EngineSessionsModel(engine: feed.engine, clock: { now + elapsed })
        return (AppEnvironment(settings: settings, usage: DemoUsageModel(now: now), sessions: model), feed)
    }

    /// The opened island at the reference notch, hosted, at its own height.
    private func island(_ name: String, env: AppEnvironment) throws {
        let view = OpenedIslandView(presentation: .card(sessionID: Self.session), notch: IslandTheme.Metrics.referenceNotch,
                                    ui: IslandUIState(), animated: false)
        let scene = DScene.island(view, notch: IslandTheme.Metrics.referenceNotch)
        let probe = NSHostingView(rootView: scene.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(scene, name, size: probe.fittingSize, env: env)
    }

    /// A card as tall as it is, as the island (660 wide) or the window (595) draws it.
    private func card(_ name: String, style: CardStyle, env: AppEnvironment) throws {
        let card = try #require(env.sessions.card(for: Self.session))
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

    @Test func settingsRow() throws {
        let settings = AppSettings.ephemeral()
        settings.answerSubagentsOnIsland = true
        let env = AppEnvironment.demo(settings: settings)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .island), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.locale, Locale(identifier: "en_GB"))
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "O-settings-island-subagents", size: CGSize(width: SettingsTheme.Metrics.width, height: height),
                                       env: env)
    }

    @Test func heldCardIsland() throws {
        let (env, _) = try scene()
        guard case let .approval(card)? = env.sessions.card(for: Self.session) else { Issue.record("no approval card"); return }
        #expect(card.isAnswerable && card.alwaysAllowLabel == nil && !card.canStop && card.request?.holdEnds != nil)
        #expect(HoldCountdown.left(until: try #require(card.request?.holdEnds), now: env.sessions.now, total: SubagentHold.limit) == 7)
        try island("O-card-subagent-held-island", env: env)
    }

    @Test func heldCardDetailed() throws {
        let (env, _) = try scene { $0.islandStyle = .detailed }
        try card("O-card-subagent-held-detailed", style: .islandDetailed, env: env)
    }

    @Test func heldCardWindow() throws {
        let (env, _) = try scene()
        try card("O-card-subagent-held-window", style: .window, env: env)
    }

    /// ⌥-click on No: the reason's field takes No and Yes's place, and the time left runs along its foot, from its
    /// leading edge, as it did along Yes; the same card with no hold draws no line there (P350).
    @Test func heldCardReasonIsland() throws {
        let (env, _) = try scene()
        guard case let .approval(held)? = env.sessions.card(for: Self.session) else { Issue.record("no approval card"); return }
        #expect(held.request?.holdEnds != nil)
        var plain = held
        plain.request?.holdEnds = nil
        func view(_ card: ApprovalCardModel) -> some View {
            SessionCardView(card: .approval(card), style: .islandClean)
                .environment(\.previewReasonField, true)
                .padding(12)
                .frame(width: 660)
                .background(Color.black)
                .environment(\.sessionGlyphsAnimated, false)
        }
        let size = NSHostingView(rootView: view(held).environment(env).environment(\.colorScheme, .dark)).fittingSize
        try RenderHarness.renderHosted(view(held), "O-card-subagent-held-reason-island", size: size, env: env)
        let a = try RenderHarness.hostedBitmap(view(held), "held", size: size, env: env)
        let b = try RenderHarness.hostedBitmap(view(plain), "plain", size: size, env: env)
        var rows = Set<Int>(), columns = Set<Int>()
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                let p = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray)?.whiteComponent ?? 0
                let q = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray)?.whiteComponent ?? 0
                if abs(p - q) > 0.05 {
                    rows.insert(y)
                    columns.insert(x)
                }
            }
        }
        // One thin line (2 pt, 4 px at 2x, give or take a pixel of blending) in the card's lower part, from the field's
        // leading edge to about 7/12 of the way.
        #expect(!rows.isEmpty, "no line along the reason field")
        #expect((rows.max() ?? 0) - (rows.min() ?? 0) <= 5 && (rows.min() ?? 0) > a.pixelsHigh / 2)
        #expect((columns.min() ?? 0) < a.pixelsWide / 8 && (columns.max() ?? a.pixelsWide) < a.pixelsWide * 3 / 4)
    }

    @Test func releasedCardIsland() throws {
        let (env, _) = try scene(elapsed: 12, released: true)
        guard case let .approval(card)? = env.sessions.card(for: Self.session) else { Issue.record("no approval card"); return }
        #expect(!card.isAnswerable && card.request?.dismissable == true && card.request?.holdEnds == nil)
        try island("O-card-subagent-released-island", env: env)
    }
}
