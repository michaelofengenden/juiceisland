import AppKit
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Lane c14/cards: a row's branch and a compaction's time (P433 to P436) in the opened island (Clean and Detailed), a
/// Clean row's peek and the window's list; Done cards whose messages hold a table, fenced code, links and a table wider
/// than the card (P430 to P432), in the island's brief card (Clean and Detailed) and the window's. Sessions:
/// `FixtureSessionFeed.Scenario.details` and `.replies`. Names `cl-…`: `zsh scripts/render-all.sh CardsLaneRenders`.
@MainActor
@Suite(.serialized)
struct CardsLaneRenders {
    static let notch = IslandTheme.Metrics.referenceNotch

    static func env(_ scenario: FixtureSessionFeed.Scenario, _ style: IslandStyle = .clean) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        return AppEnvironment.demo(settings: settings, sessions: scenario)
    }

    // MARK: Branches and the compaction's time

    @Test(arguments: [IslandStyle.clean, .detailed])
    func island(_ style: IslandStyle) throws {
        let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "cl-island-\(style.rawValue)", env: Self.env(.details, style))
    }

    /// Clean: the Codex row's peek says its branch (Clean rows leave it to the peek, as the facts).
    @Test func peekCleanBranch() async throws {
        let env = Self.env(.details)
        let peek = try #require(await env.sessions.peek(FixtureSessionFeed.DetailsID.codexBranch, clean: true))
        try renderPeek(env, peek, "cl-peek-clean-branch")
    }

    /// A peek as the island shows it, measured and placed before the picture (`RowsRenders.renderPeek`).
    private func renderPeek(_ env: AppEnvironment, _ peek: SessionPeek, _ name: String) throws {
        let ui = IslandUIState()
        ui.peek = peek
        let view = DScene.island(OpenedIslandView(presentation: .list, notch: Self.notch, ui: ui, animated: false), notch: Self.notch)
            .environment(\.sessionGlyphsAnimated, false)
        let hosting = NSHostingView(rootView: view.environment(env).environment(\.colorScheme, .dark))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: 920, height: ceil(hosting.fittingSize.height)), env: env)
    }

    @Test func window() throws {
        let view = SessionListView()
            .frame(width: 1_000, height: 360)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, "cl-window", size: CGSize(width: 1_016, height: 376), env: Self.env(.details))
    }

    // MARK: Done cards

    static let replies: [(name: String, id: String)] = [
        ("table", FixtureSessionFeed.RepliesID.table), ("code", FixtureSessionFeed.RepliesID.code),
        ("links", FixtureSessionFeed.RepliesID.links), ("wide", FixtureSessionFeed.RepliesID.wide),
    ]

    /// A card as the island draws it: 660 wide, 12 pt sides, under a 36 pt header (`CRenders.islandCard`).
    @Test(arguments: [CardStyle.islandClean, .islandDetailed])
    func islandDone(_ style: CardStyle) throws {
        let env = Self.env(.replies, style == .islandClean ? .clean : .detailed)
        for reply in Self.replies {
            let card = try #require(env.sessions.card(for: reply.id))
            let view = VStack(spacing: 0) {
                Color.black.frame(height: 36)
                SessionCardView(card: card, style: style).padding(.top, style == .islandClean ? 4 : 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(width: 660, height: 190)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
            let name = "cl-done-\(reply.name)-\(style == .islandClean ? "clean" : "detailed")"
            try RenderHarness.renderHosted(view, name, size: CGSize(width: 660, height: 190), env: env)
        }
    }

    @Test func windowDone() throws {
        let env = Self.env(.replies)
        for reply in Self.replies {
            let card = try #require(env.sessions.card(for: reply.id))
            let view = SessionCardView(card: card, style: .window)
                .frame(width: 579)
                .frame(height: 330, alignment: .top)
                .padding(8)
                .background(Color.black)
                .environment(\.sessionGlyphsAnimated, false)
            try RenderHarness.renderHosted(view, "cl-done-\(reply.name)-window", size: CGSize(width: 595, height: 346), env: env)
        }
    }
}
