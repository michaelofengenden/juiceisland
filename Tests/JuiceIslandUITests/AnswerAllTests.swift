import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore
@testable import JuiceIslandUI

/// Lane c37/keys, Allow all and Deny all (P1031): while two or more approvals wait, each approval the island can answer
/// is answered as its own Yes or No would be, oldest first, and one line says so. Never a question or a plan, never a
/// read-only card, never an agent marked Watch. Fixture engines only: what is sent lands in the feed's recorder.
@MainActor
struct AnswerAllTests {
    typealias ID = FixtureSessionFeed.ID
    typealias AID = FixtureSessionFeed.AttentionID

    /// Until `count` commands went and every card in `gone` went with them (sent first, resolved once sent: P129), for
    /// 30 s worth of looks at most (`Looks`, P1253).
    @discardableResult
    private func settle(_ feed: FixtureSessionFeed, count: Int, gone ids: [String], in env: AppEnvironment) async -> Bool {
        await Looks.until(30) { feed.sentCommands.count >= count && !ids.contains(where: { env.sessions.card(for: $0) != nil }) }
    }

    /// The cards scenario: five Claude approvals, a Codex one (Codex is Watch while the island does not answer it), a
    /// plan and a question. Allow all covers the five, in the order they began to wait.
    @Test
    func itCoversOnlyApprovalsTheIslandAnswersInTheOrderTheyWaited() {
        let env = AppEnvironment.demo(sessions: .cards)
        let targets = BatchAnswer.targets(env).map(\.sessionID)
        #expect(targets == [ID.write, ID.unreadBash, ID.longBash, ID.fetch, ID.edit])
        let waiting = env.sessions.waiting.map(\.id)
        #expect(targets == waiting.filter(targets.contains))
        #expect(!targets.contains(ID.longPlan) && !targets.contains(ID.questions) && !targets.contains(ID.codexShort))
        // Answering Codex on the island (Island mode) makes Codex Approve: its card is covered then.
        env.settings.answerCodexOnIsland = true
        env.settings.showAs = .island
        #expect(BatchAnswer.targets(env).map(\.sessionID).contains(ID.codexShort))
    }

    /// Read-only cards (Codex released to its own prompt, a subagent's, Claude Desktop's, a prompt with no hook) are never
    /// covered: one answerable approval is left, too few to batch.
    @Test
    func readOnlyCardsAreNeverCovered() {
        let env = AppEnvironment.demo(sessions: .attention)
        #expect(BatchAnswer.targets(env).map(\.sessionID) == [AID.claudeQueue])
        let card = env.sessions.card(for: AID.claudeQueue)
        #expect(BatchAnswer.islandTargets(drawn: card, env: env).isEmpty)
    }

    @Test
    func watchAgentsAreNeverCoveredEvenWhereTheirCardCouldTakeAYes() {
        let settings = AppSettings.ephemeral()
        let watch = BatchAnswer.watchAgents(settings)
        #expect(watch.contains(.codex))
        for spec in AgentHookTable.wave1 where spec.answers == .watch { #expect(watch.contains(EngineSessionsModel.agent(spec.kind))) }
        for spec in AgentHookTable.wave1 where spec.answers == .approve { #expect(!watch.contains(EngineSessionsModel.agent(spec.kind))) }
        let cursor = ApprovalCardModel(sessionID: "c", agent: EngineSessionsModel.agent(.cursor), tool: "Shell", body: .command("ls"),
                                       reason: nil, alwaysAllowLabel: nil)
        #expect(!BatchAnswer.covers(cursor, watch: watch))
        var claude = cursor
        claude.agent = .claude
        #expect(BatchAnswer.covers(claude, watch: watch))
        claude.send = .sending
        #expect(!BatchAnswer.covers(claude, watch: watch))
    }

    /// Each card gets exactly what its own Yes sends: the same commands, in the same order, as five clicks on Yes.
    @Test
    func allowAllSendsWhatEachYesWouldInOrder() async throws {
        let env = AppEnvironment.demo(sessions: .cards)
        let feed = try #require(env.fixtureFeed)
        let cards = BatchAnswer.targets(env)
        let note = BatchAnswer.answer(.allowOnce, cards, env: env)
        #expect(note.text == "Allowed 5 approvals." && env.answerAllNote == note)
        await settle(feed, count: 5, gone: cards.map(\.sessionID), in: env)

        let byHand = AppEnvironment.demo(sessions: .cards)
        let handFeed = try #require(byHand.fixtureFeed)
        for card in BatchAnswer.targets(byHand) {
            byHand.sessions.approve(card.sessionID, .allowOnce, request: card.request?.id)
            await settle(handFeed, count: handFeed.sentCommands.count + 1, gone: [card.sessionID], in: byHand)
        }
        #expect(feed.sentCommands.count == 5)
        #expect(Self.sessions(feed.sentCommands) == cards.map(\.sessionID))
        #expect(Self.shapes(feed.sentCommands) == Self.shapes(handFeed.sentCommands))
        // What is left waits on the owner: the plan, the question and Codex's.
        #expect(Set(env.sessions.waiting.map(\.id)) == [ID.longPlan, ID.questions, ID.codexShort])
    }

    /// While the answers are on their way the five still wait in the model; the island's next card comes from the rest,
    /// so none of the five passes by on the way to the list (P1035).
    @Test
    func theIslandsNextCardIsNeverOneAllowAllJustAnswered() async throws {
        let env = AppEnvironment.demo(sessions: .cards)
        let feed = try #require(env.fixtureFeed)
        let cards = BatchAnswer.targets(env)
        BatchAnswer.answer(.allowOnce, cards, env: env)
        let rest = BatchAnswer.stillWaiting(env.sessions.waiting, env: env).map(\.id)
        #expect(Set(rest) == [ID.longPlan, ID.questions, ID.codexShort])
        #expect(IslandAttention.next(after: ID.write, wasWaiting: true, waiting: BatchAnswer.stillWaiting(env.sessions.waiting, env: env))
            == ID.longPlan)
        await settle(feed, count: 5, gone: cards.map(\.sessionID), in: env)
        #expect(BatchAnswer.stillWaiting(env.sessions.waiting, env: env).map(\.id) == env.sessions.waiting.map(\.id))
    }

    @Test
    func denyAllSendsWhatEachNoWould() async throws {
        let env = AppEnvironment.demo(sessions: .cards)
        let feed = try #require(env.fixtureFeed)
        let cards = BatchAnswer.targets(env)
        #expect(BatchAnswer.answer(.deny, cards, env: env).text == "Denied 5 approvals.")
        await settle(feed, count: 5, gone: cards.map(\.sessionID), in: env)

        let byHand = AppEnvironment.demo(sessions: .cards)
        let handFeed = try #require(byHand.fixtureFeed)
        for card in BatchAnswer.targets(byHand) {
            byHand.sessions.approve(card.sessionID, .deny, request: card.request?.id)
            await settle(handFeed, count: handFeed.sentCommands.count + 1, gone: [card.sessionID], in: byHand)
        }
        #expect(Self.shapes(feed.sentCommands) == Self.shapes(handFeed.sentCommands))
    }

    /// A card answered elsewhere between the drawing and the click is left alone and counted in the line.
    @Test
    func aCardAnsweredMeanwhileIsLeftAlone() async throws {
        let env = AppEnvironment.demo(sessions: .cards)
        let feed = try #require(env.fixtureFeed)
        let cards = BatchAnswer.targets(env)
        env.sessions.approve(ID.fetch, .deny, request: cards[3].request?.id)
        await settle(feed, count: 1, gone: [ID.fetch], in: env)
        let note = BatchAnswer.answer(.allowOnce, cards, env: env)
        #expect(note.text == "Allowed 4 approvals; 1 was already answered.")
        await settle(feed, count: 5, gone: cards.map(\.sessionID), in: env)
        #expect(feed.sentCommands.count == 5)
        #expect(BatchAnswer.report(.deny, answered: 1, gone: 2) == "Denied 1 approval; 2 were already answered.")
    }

    /// W3R-1 (P1032): another session's approval arrives between the drawing and the press. The line redraws with it in
    /// the same frame ("6 approvals wait"), so a press 40 ms later would answer a card the owner never saw: the click,
    /// the island's key and the window's key are eaten until it has waited `IslandMotion.cardSettle`, then answer all six.
    @Test
    func anApprovalThatArrivesJustBeforeThePressIsNotAnswered() async throws {
        let env = AppEnvironment.demo(sessions: .cards)
        let feed = try #require(env.fixtureFeed)
        // The five were there when the model first looked: none of them has just come in.
        let drawn = BatchAnswer.targets(env)
        #expect(drawn.count == 5 && drawn.allSatisfy { env.sessions.waitingSince($0.sessionID) == nil })
        #expect(!BatchAnswer.justArrived(drawn, env: env))
        feed.engine.loadPreviewEvents(FixtureSessionFeed.start(Self.late, title: "Clear the dist folder", project: "notes-site",
                                                               prompt: "clean up", at: feed.now)
            + [FixtureSessionFeed.claudeApproval(Self.late, "Bash", useID: "toolu_late", shown: "rm -rf dist", at: feed.now)])
        let redrawn = BatchAnswer.targets(env)
        #expect(redrawn.map(\.sessionID).last == Self.late)
        let since = try #require(env.sessions.waitingSince(Self.late))
        let soon = since + 0.040
        // The row's click.
        #expect(BatchAnswer.justArrived(redrawn, env: env, now: soon))
        #expect(BatchAnswer.press(.allowOnce, redrawn, env: env, now: soon) == nil)
        // The island's key from the card on show, which is not the one that came in.
        let card = try #require(env.sessions.card(for: ID.longBash))
        let batch = BatchAnswer.islandTargets(drawn: card, env: env)
        #expect(batch.count == 6)
        let allow = IslandKeyPress(characters: "Y", control: true, shift: true)
        #expect(IslandKeyRouter.command(for: allow, card: card, batch: batch.count,
                                        batchArriving: BatchAnswer.justArrived(batch, env: env, now: soon)) == .swallow)
        // The window's key: taken, so it goes nowhere else, and nothing is answered.
        #expect(WindowKeyRouter.perform(.answerAll(.allowOnce), env: env, now: soon))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(feed.sentCommands.isEmpty && env.answerAllNote == nil)
        // Once it has waited as long as a card on show must, a press answers all six.
        let later = since + IslandMotion.cardSettle + 0.010
        #expect(IslandKeyRouter.command(for: allow, card: card, batch: batch.count,
                                        batchArriving: BatchAnswer.justArrived(batch, env: env, now: later)) == .answerAll(.allowOnce))
        #expect(BatchAnswer.press(.allowOnce, redrawn, env: env, now: later)?.text == "Allowed 6 approvals.")
        await settle(feed, count: 6, gone: redrawn.map(\.sessionID), in: env)
        // Each answer goes out on its own, so under load they may land in any order (the order is pinned above).
        #expect(Set(Self.sessions(feed.sentCommands)) == Set(redrawn.map(\.sessionID)) && feed.sentCommands.count == 6)
    }

    static let late = "late-approval"

    // MARK: The keys (P1031)

    @Test
    func theKeyActsFromAnApprovalCardWhileTwoOrMoreWait() throws {
        let env = AppEnvironment.demo(sessions: .cards)
        let card = try #require(env.sessions.card(for: ID.longBash))
        let batch = BatchAnswer.islandTargets(drawn: card, env: env)
        #expect(batch.count == 5)
        let allow = IslandKeyPress(characters: "Y", control: true, shift: true)
        let deny = IslandKeyPress(characters: "N", control: true, shift: true)
        #expect(IslandKeyRouter.command(for: allow, card: card, batch: batch.count) == .answerAll(.allowOnce))
        #expect(IslandKeyRouter.command(for: deny, card: card, batch: batch.count) == .answerAll(.deny))
        // Fewer than two, no Allow all on show: nothing.
        #expect(IslandKeyRouter.command(for: allow, card: card, batch: 1) == nil)
        // A question or a plan on show has no Allow all.
        let question = try #require(env.sessions.card(for: ID.questions))
        #expect(BatchAnswer.islandTargets(drawn: question, env: env).isEmpty)
        #expect(BatchAnswer.islandTargets(drawn: env.sessions.card(for: ID.longPlan), env: env).isEmpty)
        #expect(IslandKeyRouter.command(for: allow, card: question, batch: 5) == nil)
        // A held key's repeat and a card that has just come in take nothing (P138).
        var held = allow
        held.isRepeat = true
        #expect(IslandKeyRouter.command(for: held, card: card, batch: 5) == .swallow)
        #expect(IslandKeyRouter.command(for: allow, card: card, arriving: ID.longBash, batch: 5) == .swallow)
        // The card on show is answered as drawn: a Codex card (Watch) on show offers none.
        #expect(BatchAnswer.islandTargets(drawn: env.sessions.card(for: ID.codexShort), env: env).isEmpty)
    }

    @Test
    func theWindowsKeyAnswersWhatItsLineOffers() async throws {
        let env = AppEnvironment.demo(sessions: .cards)
        let feed = try #require(env.fixtureFeed)
        #expect(WindowKeyRouter.command(for: .init(character: "Y", control: true, shift: true)) == .answerAll(.allowOnce))
        #expect(WindowKeyRouter.command(for: .init(character: "N", control: true, shift: true)) == .answerAll(.deny))
        let cards = BatchAnswer.targets(env)
        #expect(WindowKeyRouter.perform(.answerAll(.allowOnce), env: env))
        // The line the press leaves, read before anything else has a turn: it lives `AnswerAllNote.lifetime` (6 s) on
        // the wall clock, which a full run's main actor outlasted between the press and a look after the settle (P1260).
        #expect(env.answerAllNote?.text == "Allowed 5 approvals.")
        #expect(await settle(feed, count: 5, gone: cards.map(\.sessionID), in: env))
        // Nothing left to batch: the key is not taken.
        #expect(!WindowKeyRouter.perform(.answerAll(.allowOnce), env: env))
        let one = AppEnvironment.demo(sessions: .prototype)
        #expect(!WindowKeyRouter.perform(.answerAll(.deny), env: one))
        #expect(one.fixtureFeed?.sentCommands.isEmpty == true)
    }

    // MARK: Helpers

    /// The session each command answers.
    static func sessions(_ commands: [BridgeCommand]) -> [String] {
        commands.compactMap { if case let .resolvePermission(id, _) = $0 { id } else { nil } }
    }

    /// Each command's resolution, without its session: what the decision said.
    static func shapes(_ commands: [BridgeCommand]) -> [String] {
        commands.compactMap { if case let .resolvePermission(_, resolution) = $0 { String(describing: resolution) } else { nil } }
    }
}
