import AppKit
import Foundation
@testable import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The owner's screenshot of 2026-09-30 (P660, P661), fixed: a Codex app thread's question card whose prompt was the
/// app's in-app browser context shows the owner's words and the question, "in Codex", in the island (Clean and
/// Detailed), its list and the window. Demo engine fed through the live paths (`FixtureSessionFeed+CodexApp.swift`);
/// nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct CodexJumpRenders {
    typealias ID = FixtureSessionFeed.CodexAppID

    private func env(configure: (AppSettings) -> Void = { _ in }) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        configure(settings)
        return AppEnvironment.demo(settings: settings, sessions: .codexAppContext)
    }

    private func island(_ name: String, _ presentation: IslandPresentation, env: AppEnvironment) throws {
        let view = OpenedIslandView(presentation: presentation, notch: IslandTheme.Metrics.referenceNotch, ui: IslandUIState(), animated: false)
        let scene = DScene.island(view, notch: IslandTheme.Metrics.referenceNotch)
        let probe = NSHostingView(rootView: scene.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(scene, name, size: probe.fittingSize, env: env)
    }

    private func card(_ name: String, style: CardStyle, env: AppEnvironment) throws {
        let card = try #require(env.sessions.card(for: ID.thread))
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

    @Test func questionIsland() throws { try island("CJ-codex-app-question-island", .card(sessionID: ID.thread), env: env()) }
    @Test func questionIslandDetailed() throws {
        try island("CJ-codex-app-question-island-detailed", .card(sessionID: ID.thread), env: env { $0.islandStyle = .detailed })
    }
    @Test func questionCardDetailed() throws { try card("CJ-codex-app-question-detailed", style: .islandDetailed, env: env()) }
    @Test func questionCardWindow() throws { try card("CJ-codex-app-question-window", style: .window, env: env()) }
    @Test func islandList() throws { try island("CJ-codex-app-island-list", .list, env: env()) }
    @Test func islandListDetailed() throws {
        try island("CJ-codex-app-island-list-detailed", .list, env: env { $0.islandStyle = .detailed })
    }
}
