import AppKit
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Stream C, the answer flow: the island card that counts the others waiting ("· 1 more"), No's reason field and its
/// "No…" under ⌥, "Not sent · Retry" on an approval, a plan and a question, a reply's "Sent" and "Not sent", and a
/// failed turn's card. Headless; fixture engines whose commands and replies go to a recorder.
@MainActor
@Suite(.serialized)
struct CFlowRenders {
    typealias ID = FixtureSessionFeed.ID

    private func env(_ scenario: FixtureSessionFeed.Scenario, sendsFail: Bool = false, reply: Bool = false) -> (AppEnvironment, FixtureSessionFeed) {
        let settings = AppSettings.ephemeral()
        settings.replyFromCompletionCard = reply
        let feed = FixtureSessionFeed(scenario: scenario, sendsFail: sendsFail)
        return (AppEnvironment(settings: settings, usage: DemoUsageModel(now: DemoClock.now), sessions: feed.makeModel()), feed)
    }

    private func model(_ env: AppEnvironment) throws -> EngineSessionsModel {
        try #require(env.sessions as? EngineSessionsModel)
    }

    /// A card as tall as it is, under the island's 36 pt header (660 wide) or in the window's grid column (595).
    private func card(_ name: String, id: String, style: CardStyle, env: AppEnvironment, hovered: Bool = false, reason: Bool = false,
                      option: Bool = false) throws {
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
        .environment(\.previewReasonField, reason)
        .environment(\.optionKeyHeld, option)
        let probe = NSHostingView(rootView: content.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(content, name, size: probe.fittingSize, env: env)
    }

    // MARK: The next card

    /// The prototype's approval in the island while its question waits too: "Needs approval · Bash · 1 more".
    @Test func cleanApprovalMore() throws {
        try card("C-flow-clean-approval-more", id: ID.approval, style: .islandClean, env: env(.prototype).0)
    }
    /// Eight cards wait in the cards scenario: the Codex command's header counts the other seven.
    @Test func detailedCodexMore() throws {
        try card("C-flow-detailed-codex-more", id: ID.codexShort, style: .islandDetailed, env: env(.cards).0)
    }

    // MARK: No, with a reason

    @Test func cleanApprovalOption() throws {
        try card("C-flow-clean-approval-option", id: ID.approval, style: .islandClean, env: env(.prototype).0, option: true)
    }
    @Test func cleanApprovalReason() throws {
        try card("C-flow-clean-approval-reason", id: ID.approval, style: .islandClean, env: env(.prototype).0, reason: true)
    }
    @Test func windowApprovalReason() throws {
        try card("C-flow-window-approval-reason", id: ID.approval, style: .window, env: env(.prototype).0, reason: true)
    }
    @Test func cleanPlanReason() throws {
        try card("C-flow-clean-plan-reason", id: ID.plan, style: .islandClean, env: env(.allStates).0, reason: true)
    }

    // MARK: Not sent

    @Test func cleanApprovalNotSent() async throws {
        let (env, _) = env(.prototype, sendsFail: true)
        await try model(env).decide(ID.approval, .allowOnce)
        try card("C-flow-clean-approval-notsent", id: ID.approval, style: .islandClean, env: env)
    }
    @Test func windowApprovalNotSent() async throws {
        let (env, _) = env(.prototype, sendsFail: true)
        await try model(env).decide(ID.approval, .deny)
        try card("C-flow-window-approval-notsent", id: ID.approval, style: .window, env: env)
    }
    @Test func cleanPlanNotSent() async throws {
        let (env, _) = env(.allStates, sendsFail: true)
        await try model(env).decide(ID.plan, .allowOnce)
        try card("C-flow-clean-plan-notsent", id: ID.plan, style: .islandClean, env: env)
    }
    @Test func cleanQuestionNotSent() async throws {
        let (env, _) = env(.prototype, sendsFail: true)
        let model = try model(env)
        model.answerQuestion(ID.question, .option(0))
        for _ in 0..<200 {
            if case let .question(card)? = model.card(for: ID.question), card.send == .notSent { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try card("C-flow-clean-question-notsent", id: ID.question, style: .islandClean, env: env)
    }

    // MARK: Replies

    /// The demo's Ghostty turn, the pointer on its brief card: the field, then "Sent", then "Not sent · Retry" with the
    /// field kept for another try.
    @Test func cleanDoneReply() throws {
        try card("C-flow-clean-done-reply", id: ID.claudeDone, style: .islandClean, env: env(.allStates, reply: true).0, hovered: true)
    }
    @Test func cleanDoneReplySent() async throws {
        let (env, _) = env(.allStates, reply: true)
        await try model(env).sendReply(ID.claudeDone, "ship it")
        try card("C-flow-clean-done-reply-sent", id: ID.claudeDone, style: .islandClean, env: env, hovered: true)
    }
    @Test func cleanDoneReplyNotSent() async throws {
        let (env, _) = env(.allStates, sendsFail: true, reply: true)
        await try model(env).sendReply(ID.claudeDone, "ship it")
        try card("C-flow-clean-done-reply-notsent", id: ID.claudeDone, style: .islandClean, env: env, hovered: true)
    }
    /// A Terminal turn with the setting on: no field, as nothing could type into its tab.
    @Test func cleanDoneNoRoute() throws {
        try card("C-flow-clean-done-noroute", id: ID.markdownDone, style: .islandClean, env: env(.markdown, reply: true).0, hovered: true)
    }

    // MARK: A failed turn

    @Test func windowTurnFailed() throws {
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: DemoClock.now), sessions: TurnFailedTests.model())
        try card("C-flow-window-turn-failed", id: TurnFailedTests.failedID, style: .window, env: env)
    }
    @Test func cleanTurnFailed() throws {
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: DemoClock.now), sessions: TurnFailedTests.model())
        try card("C-flow-clean-turn-failed", id: TurnFailedTests.failedID, style: .islandClean, env: env)
    }
}
