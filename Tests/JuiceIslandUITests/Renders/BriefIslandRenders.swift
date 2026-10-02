import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The owner's brief island: a finished session's Done card is brief (the title line, two lines of its last message, no
/// reply field until the pointer is on it; P95), and the list's footer counts only the active sessions it hides
/// ("Show 2 more") or reads "Earlier" when it hides only older finished ones (P94).
@MainActor
@Suite(.serialized)
struct BriefIslandRenders {
    /// Six active sessions and a day of older finished ones: the four rows hide two active ones, a running Codex session
    /// (after the other running ones, before what finished, P291), which Detailed's Codex group shows, and a finished one.
    static var activeHidden: [SessionRow] {
        [DStub.row("q", .claude, .needsYou, task: "Ship the update"), DStub.row("r1", .claude, .running, task: "Refactor the pill"),
         DStub.row("r2", .claude, .running, task: "Write the tests"), DStub.row("r3", .claude, .running, task: "Draft the notes"),
         DStub.row("cx", .codex, .running, project: "notes-site", task: "Fix the build"),
         DStub.row("d2", .claude, .done, task: "Tidy the docs", minutesAgo: 12)] + older
    }

    /// Two active sessions and the day's older finished ones: the four rows hide only older ones.
    static var onlyOlderHidden: [SessionRow] {
        [DStub.row("q", .claude, .needsYou, task: "Ship the update"), DStub.row("r", .codex, .running, project: "notes-site", task: "Fix the build")]
            + older
    }

    private static var older: [SessionRow] {
        (0..<24).map { index -> SessionRow in
            let agent: GlyphPalette.Agent = index % 2 == 0 ? .claude : .codex
            let minutes = Double(40 + index * 45)
            return DStub.row("old-\(index)", agent, .done, task: "Earlier task \(index)", minutesAgo: minutes)
        }
    }

    @Test(arguments: [IslandStyle.clean, .detailed])
    func footerShowsTheActiveRowsItHides(_ style: IslandStyle) throws {
        try island("D-island-\(style.rawValue)-footer-more", rows: Self.activeHidden, style: style)
    }

    @Test(arguments: [IslandStyle.clean, .detailed])
    func footerReadsEarlierForOlderRows(_ style: IslandStyle) throws {
        try island("D-island-\(style.rawValue)-footer-earlier", rows: Self.onlyOlderHidden, style: style)
    }

    // MARK: The brief Done card

    /// Codex's Markdown answer (the owner's Done card of 2026-09-24): two lines of it, cut with "…".
    @Test(arguments: [IslandStyle.clean, .detailed])
    func doneCardIsBrief(_ style: IslandStyle) throws {
        try card("D-island-\(style.rawValue)-done-brief", FixtureSessionFeed.ID.markdownDone, scenario: .markdown, style: style)
    }

    /// Reply from completion card on: no field as it opens; the pointer on the card uncovers it. The demo's Ghostty turn,
    /// whose terminal is known (P128): a Terminal turn never shows the field.
    @Test(arguments: [false, true])
    func doneCardReplyWaitsForThePointer(_ hovered: Bool) throws {
        try card("D-island-clean-done-brief-reply\(hovered ? "-hover" : "")", FixtureSessionFeed.ID.claudeDone, scenario: .allStates,
                 style: .clean, reply: true, hovered: hovered)
    }

    /// A failed turn needs you: its card keeps its status line, six lines and its field.
    @Test func failedTurnCardIsNotBrief() throws {
        let settings = AppSettings.ephemeral()
        settings.replyFromCompletionCard = true
        let env = AppEnvironment.demo(settings: settings, sessions: .allStates)
        let id = FixtureSessionFeed.ID.claudeDone
        let card = try #require(env.sessions.card(for: id))
        guard case var .done(model) = card else { Issue.record("not a Done card"); return }
        model.failed = true
        #expect(!SessionCard.done(model).isBrief(in: .islandClean) && card.isBrief(in: .islandClean))
    }

    // MARK: Helpers

    private func card(_ name: String, _ id: String, scenario: FixtureSessionFeed.Scenario, style: IslandStyle,
                      reply: Bool = false, hovered: Bool = false) throws {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        settings.replyFromCompletionCard = reply
        let env = AppEnvironment.demo(settings: settings, sessions: scenario)
        let notch = IslandTheme.Metrics.referenceNotch
        let view = OpenedIslandView(presentation: .card(sessionID: id), notch: notch, ui: IslandUIState(), animated: false)
            .environment(\.previewCardHovered, hovered)
        let scene = DScene.island(view, notch: notch)
        // Cards hold AppKit text fields, which `ImageRenderer` leaves blank: draw them hosted, at the scene's own size.
        let probe = NSHostingView(rootView: scene.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(scene, name, size: probe.fittingSize, env: env)
    }

    private func island(_ name: String, rows: [SessionRow], style: IslandStyle, ui: IslandUIState = IslandUIState()) throws {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        settings.islandShowsUsage = false
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: rows))
        let notch = IslandTheme.Metrics.referenceNotch
        let view = OpenedIslandView(presentation: .list, notch: notch, ui: ui, animated: false)
        try RenderHarness.render(DScene.island(view, notch: notch), name, env: env)
    }
}
