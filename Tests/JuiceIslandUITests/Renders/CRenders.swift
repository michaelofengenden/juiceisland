import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Stream C: the session list (overview, needs you, 1200 and 900, glyphs by agent), the whole window in Needs you, and
/// every card in the window and both island styles. Refs: `refs/C-*.png`; the island cards compare with the card part
/// of `refs/D-island-{clean,detailed}-{question,approval,done}.png` (see `scripts/compare-c-cards.py`).
@MainActor
@Suite(.serialized)
struct CRenders {
    /// The prototype's six sessions; glyphs still; the first option drawn selected, as in the prototype.
    private func env(filter: WindowFilter = .all, glyphs: GlyphColourMode = .byState, scenario: FixtureSessionFeed.Scenario = .prototype,
                     reply: Bool = false) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.glyphColour = glyphs
        settings.replyFromCompletionCard = reply
        let env = AppEnvironment.demo(settings: settings, sessions: scenario)
        env.windowFilter = filter
        return env
    }

    /// The list crop: the list at `width` × `height`, inside the 8 pt pad the reference crop has.
    private func list(_ name: String, width: CGFloat, height: CGFloat, env: AppEnvironment) throws {
        let view = SessionListView()
            .frame(width: width, height: height)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.previewSelectedOption, 0)
        try RenderHarness.renderHosted(view, name, size: CGSize(width: width + 16, height: height + 16), env: env)
    }

    @Test func listOverview1200() throws { try list("C-list-overview-1200", width: 1200, height: 609, env: env()) }
    @Test func listOverview900() throws { try list("C-list-overview-900", width: 900, height: 520, env: env()) }
    @Test func listNeeds1200() throws { try list("C-list-needs-1200", width: 1200, height: 609, env: env(filter: .needsYou)) }
    @Test func listGlyphAgent() throws { try list("C-list-glyph-agent", width: 1200, height: 609, env: env(glyphs: .byAgent)) }
    @Test func listAllStates1200() throws { try list("C-list-allstates-1200", width: 1200, height: 900, env: env(scenario: .allStates)) }
    @Test func listEmpty1200() throws { try list("C-list-empty-1200", width: 1200, height: 200, env: env(scenario: .empty)) }

    @Test func windowNeeds1200() throws {
        let view = WindowRootView()
            .frame(width: 1200, height: 760)
            .padding(12)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.previewSelectedOption, 0)
        try RenderHarness.renderHosted(view, "C-window-needs-1200", size: CGSize(width: 1224, height: 784), env: env(filter: .needsYou))
    }

    // MARK: Cards

    /// A card as the island draws it: 660 wide, 12 pt sides, under a 36 pt header, 4 pt down in Clean and 6 in
    /// Detailed (`.sl.c` / `.sl` padding-top).
    private func islandCard(_ name: String, id: String, style: CardStyle, height: CGFloat, env: AppEnvironment) throws {
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
        .environment(\.previewSelectedOption, 0)
        try RenderHarness.renderHosted(view, name, size: CGSize(width: 660, height: height), env: env)
    }

    /// `hints`: drawn as while ⌃ is held (the keys on the buttons, options and jump tag).
    private func windowCard(_ name: String, id: String, width: CGFloat, height: CGFloat, env: AppEnvironment, hints: Bool = false) throws {
        let card = try #require(env.sessions.card(for: id))
        let view = SessionCardView(card: card, style: .window)
            .frame(width: width)
            .frame(height: height, alignment: .top)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.previewSelectedOption, 0)
            .environment(\.showsShortcutHints, hints)
        try RenderHarness.renderHosted(view, name, size: CGSize(width: width + 16, height: height + 16), env: env)
    }

    typealias ID = FixtureSessionFeed.ID

    @Test func cleanQuestion() throws { try islandCard("C-card-clean-question", id: ID.question, style: .islandClean, height: 360, env: env()) }
    @Test func cleanApproval() throws { try islandCard("C-card-clean-approval", id: ID.approval, style: .islandClean, height: 250, env: env()) }
    @Test func cleanDone() throws {
        try islandCard("C-card-clean-done", id: ID.claudeDone, style: .islandClean, height: 250, env: env(scenario: .allStates, reply: true))
    }
    @Test func cleanDoneNoReply() throws {
        try islandCard("C-card-clean-done-noreply", id: ID.claudeDone, style: .islandClean, height: 200, env: env(scenario: .allStates))
    }
    @Test func cleanPlan() throws { try islandCard("C-card-clean-plan", id: ID.plan, style: .islandClean, height: 280, env: env(scenario: .allStates)) }
    @Test func detailedQuestion() throws {
        try islandCard("C-card-detailed-question", id: ID.question, style: .islandDetailed, height: 400, env: env())
    }
    @Test func detailedApproval() throws {
        try islandCard("C-card-detailed-approval", id: ID.approval, style: .islandDetailed, height: 280, env: env())
    }
    @Test func detailedDone() throws {
        try islandCard("C-card-detailed-done", id: ID.claudeDone, style: .islandDetailed, height: 280, env: env(scenario: .allStates, reply: true))
    }
    @Test func detailedPlan() throws {
        try islandCard("C-card-detailed-plan", id: ID.plan, style: .islandDetailed, height: 300, env: env(scenario: .allStates))
    }
    @Test func windowPlan() throws { try windowCard("C-card-window-plan", id: ID.plan, width: 579, height: 280, env: env(scenario: .allStates)) }
    @Test func windowApproval() throws { try windowCard("C-card-window-approval", id: ID.approval, width: 579, height: 200, env: env()) }
    @Test func windowQuestion() throws { try windowCard("C-card-window-question", id: ID.question, width: 579, height: 330, env: env()) }
    @Test func windowApprovalHints() throws {
        try windowCard("C-card-window-approval-hints", id: ID.approval, width: 579, height: 200, env: env(), hints: true)
    }
    @Test func windowQuestionHints() throws {
        try windowCard("C-card-window-question-hints", id: ID.question, width: 579, height: 330, env: env(), hints: true)
    }
    /// Codex's last message in Markdown with a file citation (the owner's Done card, 2026-09-24): bold, italic, code
    /// and the cited file's name, no marks; the row's line is the same text, plain.
    @Test func cleanDoneMarkdown() throws {
        try islandCard("C-card-clean-done-markdown", id: ID.markdownDone, style: .islandClean, height: 200, env: env(scenario: .markdown))
    }
    @Test func detailedDoneMarkdown() throws {
        try islandCard("C-card-detailed-done-markdown", id: ID.markdownDone, style: .islandDetailed, height: 220, env: env(scenario: .markdown))
    }
    @Test func windowDoneMarkdown() throws {
        try windowCard("C-card-window-done-markdown", id: ID.markdownDone, width: 579, height: 190, env: env(scenario: .markdown))
    }
    @Test func listMarkdown() throws { try list("C-list-markdown", width: 900, height: 150, env: env(scenario: .markdown)) }

    // MARK: What is approved (live-shaped requests: the command, the change, the reason)

    /// A card as the island draws it, as tall as it is: under the 36 pt header, 660 wide.
    private func fittedCard(_ name: String, id: String, style: CardStyle, env: AppEnvironment, hovered: Bool = false) throws {
        let card = try #require(env.sessions.card(for: id))
        let content = VStack(spacing: 0) {
            Color.black.frame(height: 36)
            SessionCardView(card: card, style: style).padding(.top, style == .islandClean ? 4 : style == .window ? 0 : 6)
        }
        .padding(.horizontal, style == .window ? 8 : 12)
        .padding(.bottom, 12)
        .frame(width: style == .window ? 595 : 660)
        .background(Color.black)
        .environment(\.sessionGlyphsAnimated, false)
        .environment(\.previewCardHovered, hovered)
        let probe = NSHostingView(rootView: content.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(content, name, size: probe.fittingSize, env: env)
    }

    /// The owner's card (2026-09-25): the command in the box, wrapped whole; the justification under it.
    @Test func cleanCodexApproval() throws {
        try fittedCard("C-card-clean-codex-approval", id: ID.codexApproval, style: .islandClean, env: env(scenario: .codexApproval))
    }
    @Test func detailedCodexApproval() throws {
        try fittedCard("C-card-detailed-codex-approval", id: ID.codexApproval, style: .islandDetailed, env: env(scenario: .codexApproval))
    }
    @Test func windowCodexApproval() throws {
        try fittedCard("C-card-window-codex-approval", id: ID.codexApproval, style: .window, env: env(scenario: .codexApproval))
    }
    @Test func cleanCodexShort() throws { try fittedCard("C-card-clean-codex-short", id: ID.codexShort, style: .islandClean, env: env(scenario: .cards)) }
    @Test func cleanClaudeShort() throws { try fittedCard("C-card-clean-claude-short", id: ID.approval, style: .islandClean, env: env()) }
    /// A heredoc commit: every line, the box scrolling past six in the island.
    @Test func cleanClaudeLong() throws { try fittedCard("C-card-clean-claude-long", id: ID.longBash, style: .islandClean, env: env(scenario: .cards)) }
    @Test func windowClaudeLong() throws { try fittedCard("C-card-window-claude-long", id: ID.longBash, style: .window, env: env(scenario: .cards)) }
    /// Not in the transcript yet: the request's own 110 characters, ending "…".
    @Test func cleanClaudeUnread() throws {
        try fittedCard("C-card-clean-claude-unread", id: ID.unreadBash, style: .islandClean, env: env(scenario: .cards))
    }
    @Test func cleanEdit() throws { try fittedCard("C-card-clean-edit", id: ID.edit, style: .islandClean, env: env(scenario: .cards)) }
    @Test func windowEdit() throws { try fittedCard("C-card-window-edit", id: ID.edit, style: .window, env: env(scenario: .cards)) }
    @Test func cleanWrite() throws { try fittedCard("C-card-clean-write", id: ID.write, style: .islandClean, env: env(scenario: .cards)) }
    @Test func cleanFetch() throws { try fittedCard("C-card-clean-fetch", id: ID.fetch, style: .islandClean, env: env(scenario: .cards)) }
    @Test func cleanPlanLong() throws { try fittedCard("C-card-clean-plan-long", id: ID.longPlan, style: .islandClean, env: env(scenario: .cards)) }
    @Test func windowPlanLong() throws { try fittedCard("C-card-window-plan-long", id: ID.longPlan, style: .window, env: env(scenario: .cards)) }
    @Test func cleanPlanShort() throws { try fittedCard("C-card-clean-plan-short", id: ID.plan, style: .islandClean, env: env(scenario: .allStates)) }

    /// Three questions at once: the first; then the second, multi-select, two picked, with Back and Next.
    @Test func cleanQuestionsFirst() throws {
        try fittedCard("C-card-clean-questions-1", id: ID.questions, style: .islandClean, env: env(scenario: .cards))
    }
    @Test func cleanQuestionsMultiSelect() throws {
        let env = env(scenario: .cards)
        env.sessions.answerQuestion(ID.questions, .option(1))
        env.sessions.answerQuestion(ID.questions, .option(0))
        env.sessions.answerQuestion(ID.questions, .option(2))
        try fittedCard("C-card-clean-questions-2", id: ID.questions, style: .islandClean, env: env)
    }
    @Test func windowQuestionsMultiSelect() throws {
        let env = env(scenario: .cards)
        env.sessions.answerQuestion(ID.questions, .option(1))
        env.sessions.answerQuestion(ID.questions, .option(1))
        try fittedCard("C-card-window-questions-2", id: ID.questions, style: .window, env: env)
    }

    @Test func cleanApprovalHints() throws {
        let env = env()
        let card = try #require(env.sessions.card(for: ID.approval))
        let view = SessionCardView(card: card, style: .islandClean)
            .padding(12)
            .frame(width: 660, height: 200, alignment: .top)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.showsShortcutHints, true)
        try RenderHarness.renderHosted(view, "C-card-clean-approval-hints", size: CGSize(width: 660, height: 200), env: env)
    }
}
