import Foundation
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// P351, the owner's "what's best?" of 2026-09-28: a card key (⌃A, ⌃D, ⌃⇧A, ⌃⇧D, ⌃1-⌃4) acts only on what the owner
/// sees: the card on show, its exact request; else the keys' row (the ↑ ↓ ring), that row's request; else the first
/// waiting card, the list's top "!" or "?". Never another card behind the one it lands on: a key that card cannot take
/// does nothing. In the island and in the window.
@MainActor
struct CardKeyRuleTests {
    typealias ID = FixtureSessionFeed.ID
    typealias AID = FixtureSessionFeed.AttentionID

    static let yes = IslandKeyPress(characters: "a", control: true)
    static let optionTwo = IslandKeyPress(characters: "2", control: true)

    /// A card on show wins over the keys' row, whichever row that is and wherever it moves while the card shows.
    @Test
    func aCardOnShowWinsOverTheKeysRow() throws {
        let env = AppEnvironment.demo(sessions: .allStates)
        let sessions = env.sessions
        let order = RowSelection.islandOrder(sessions, style: .clean, showAll: true).shown.map(\.id)
        #expect(order.contains(ID.plan) && order.contains(ID.question))
        for selected in [nil] + order {
            let card = IslandKeyRouter.targetCard(presentation: .card(sessionID: ID.approval), sessions: sessions, showAll: true,
                                                  selected: selected)
            #expect(card?.sessionID == ID.approval, "\(String(describing: selected))")
            #expect(IslandKeyRouter.command(for: Self.yes, card: card) == .approve(sessionID: ID.approval, .allowOnce))
            // The card on show takes no option key, and none goes to the question the keys may rest on.
            #expect(IslandKeyRouter.command(for: Self.optionTwo, card: card) == nil)
        }
        // A question on show with the approval's row selected: ⌃A answers nothing.
        let question = IslandKeyRouter.targetCard(presentation: .card(sessionID: ID.question), sessions: sessions, selected: ID.approval)
        #expect(question?.sessionID == ID.question && IslandKeyRouter.command(for: Self.yes, card: question) == nil)
    }

    /// Over the list with no row selected: the first waiting row's card only. ⌃1-⌃4 never pass the plan at the top for
    /// the question below it; ⌃A answers the plan.
    @Test
    func withNoRowSelectedOnlyTheFirstWaitingCard() throws {
        let env = AppEnvironment.demo(sessions: .allStates)
        let sessions = env.sessions
        let shown = RowSelection.islandOrder(sessions, style: .clean, showAll: false).shown
        let first = try #require(shown.first { $0.bucket == .needsYou })
        #expect(first.id == ID.plan)
        let card = IslandKeyRouter.targetCard(presentation: .list, sessions: sessions)
        #expect(card?.sessionID == ID.plan)
        #expect(IslandKeyRouter.command(for: Self.optionTwo, card: card) == nil)
        #expect(IslandKeyRouter.command(for: Self.yes, card: card) == .approve(sessionID: ID.plan, .allowOnce))

        // A read-only card at the top: `NeedsYouUITests.aListKeyNeverAnswersARowTheIslandDoesNotShow`.
    }

    /// The keys' row: its card only; a row without one (running) answers nothing, never the first waiting card; a
    /// row the list no longer shows is no ring, and the first waiting card counts again.
    @Test
    func theKeysRowOnly() throws {
        let env = AppEnvironment.demo(sessions: .allStates)
        let sessions = env.sessions
        for (selected, expected) in [(ID.approval, ID.approval), (ID.question, ID.question), (ID.plan, ID.plan)] {
            #expect(IslandKeyRouter.targetCard(presentation: .list, sessions: sessions, selected: selected)?.sessionID == expected)
        }
        #expect(IslandKeyRouter.command(for: Self.yes, card: IslandKeyRouter.targetCard(presentation: .list, sessions: sessions,
                                                                                          selected: ID.question)) == nil)
        #expect(IslandKeyRouter.command(for: Self.optionTwo, card: IslandKeyRouter.targetCard(presentation: .list, sessions: sessions,
                                                                                                selected: ID.question))
            == .chooseOption(sessionID: ID.question, index: 1))
        #expect(IslandKeyRouter.targetCard(presentation: .list, sessions: sessions, selected: ID.running) == nil)
        #expect(IslandKeyRouter.targetCard(presentation: .list, sessions: sessions, selected: "gone")?.sessionID == ID.plan)
    }

    /// The window: the keys' row's card only, else the first card of Needs you; a read-only card takes no key and no
    /// other card takes it in its place.
    @Test
    func theWindowFollowsTheSameRule() throws {
        let model = FixtureSessionFeed(scenario: .allStates).makeModel()
        let spy = SpySessions(model)
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: DemoClock.now), sessions: spy)
        let first = try #require(spy.needsYou.first { spy.card(for: $0.id) != nil })
        #expect(WindowKeyRouter.targetCard(env)?.sessionID == first.id)
        env.windowSelection = ID.running
        #expect(WindowKeyRouter.targetCard(env) == nil && !WindowKeyRouter.perform(.decide(.allowOnce), env: env))
        env.windowSelection = ID.question
        #expect(!WindowKeyRouter.perform(.decide(.allowOnce), env: env) && spy.approvals.isEmpty)
        env.windowSelection = ID.approval
        #expect(!WindowKeyRouter.perform(.option(0), env: env) && spy.answers.isEmpty)
        #expect(WindowKeyRouter.perform(.decide(.deny), env: env))
        #expect(spy.approvals.map(\.sessionID) == [ID.approval]
            && spy.approvals.first?.request == model.card(for: ID.approval)?.request?.id)

        let attention = FixtureSessionFeed(scenario: .attention).makeModel()
        let readOnly = SpySessions(attention)
        let window = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: DemoClock.now), sessions: readOnly)
        window.windowSelection = AID.codexApproval
        #expect(!WindowKeyRouter.perform(.decide(.allowOnce), env: window) && readOnly.approvals.isEmpty)
    }

    /// A card replaced under the keys, through the built helper, the broker and the model: session s1 holds two
    /// requests; the first is answered from the card as drawn, the second takes its place in the engine before the
    /// island draws it. A second ⌃A from the card as drawn carries the first's id and answers nothing; once drawn, the
    /// new card takes no key while it comes in, then ⌃A answers exactly it.
    @Test
    func aCardReplacedUnderTheKeysAnswersNothing() async throws {
        typealias E = AttentionEndToEndTests
        let rig = try await AttentionRig()
        defer { rig.stop() }
        await rig.finished(E.claude(rig, "SessionStart", extra: ["source": "startup"]),
                           events: [E.started("s1", transcript: E.transcript(rig, "s1"))])
        await rig.finished(E.claude(rig, "UserPromptSubmit", extra: ["prompt": "ship it"]),
                           events: E.prompt("s1", "ship it", transcript: E.transcript(rig, "s1")))
        let edit: [String: Any] = ["file_path": "/tmp/project/CHANGELOG.md", "old_string": "## Unreleased", "new_string": "## 0.4"]
        let push = rig.hook(E.claude(rig, "PermissionRequest", tool: "Bash", input: E.push))
        await rig.waitUntil { rig.engine.openRequests.count == 1 }
        rig.advance(1)
        let change = rig.hook(E.claude(rig, "PermissionRequest", tool: "Edit", input: edit))
        await rig.waitUntil { rig.engine.openRequests.count == 2 }
        rig.advance(5)
        await rig.finished(E.claude(rig, "Notification", extra: ["notification_type": "permission_prompt", "message": "Claude needs your permission"]))
        rig.advance(1)
        await rig.finished(E.claude(rig, "Notification", extra: ["notification_type": "permission_prompt", "message": "Claude needs your permission"]))

        let drawn = try #require(rig.card("s1"))
        #expect(drawn.request?.more == 1)
        let card = IslandKeyRouter.targetCard(presentation: .card(sessionID: "s1"), sessions: rig.model, drawn: drawn)
        guard case let .approve(id, decision)? = IslandKeyRouter.command(for: Self.yes, card: card) else {
            Issue.record("⌃A took nothing")
            return
        }
        await rig.model.decide(id, decision, request: card?.request?.id)
        #expect(await push.result(within: 30)?.printed.contains(#""behavior":"allow""#) == true)
        await rig.settle()
        let next = try #require(rig.card("s1"))
        #expect(next.request?.id != drawn.request?.id && change.isRunning)

        // The island has not drawn the edit yet: the key acts on the push card as drawn, whose request is gone.
        let stale = IslandKeyRouter.targetCard(presentation: .card(sessionID: "s1"), sessions: rig.model, drawn: drawn)
        #expect(stale?.request?.id == drawn.request?.id)
        if case let .approve(id, decision)? = IslandKeyRouter.command(for: Self.yes, card: stale) {
            await rig.model.decide(id, decision, request: stale?.request?.id)
        }
        await rig.settle()
        #expect(change.isRunning && rig.card("s1")?.request?.id == next.request?.id)
        // Drawn, it has just come in (P172): the key is eaten.
        #expect(IslandKeyRouter.command(for: Self.yes, card: next, arriving: "s1") == .swallow)
        // Settled: ⌃A answers exactly it.
        let settled = IslandKeyRouter.targetCard(presentation: .card(sessionID: "s1"), sessions: rig.model, drawn: next)
        if case let .approve(id, decision)? = IslandKeyRouter.command(for: Self.yes, card: settled) {
            await rig.model.decide(id, decision, request: settled?.request?.id)
        }
        let answered = try #require(await change.result(within: 30))
        #expect(answered.printed.contains(#""behavior":"allow""#) && answered.printed.contains("CHANGELOG.md"))
    }
}
