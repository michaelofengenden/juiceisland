import Foundation
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore
import SwiftUI

/// The answer flow on the cards: a send that fails keeps its card with Retry (P129), the next waiting card in order of
/// arrival (P130), No with a reason or a stop, Archive only on finished rows (P131), a failed turn in plain words
/// (P132) and replies only where the terminal is known exactly (P128). Headless fixture engines; commands and replies
/// go to the feed's recorder, never a bridge or a terminal.
@MainActor
struct CardFlowTests {
    typealias ID = FixtureSessionFeed.ID

    /// Waits for the model's queued work (a card's send runs in a task) until `done` holds.
    private func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: Sent first (P129)

    @Test
    func aDecisionThatCouldNotBeSentKeepsItsCardWithRetry() async throws {
        let feed = FixtureSessionFeed(scenario: .prototype, sendsFail: true)
        let model = feed.makeModel()
        await model.decide(ID.approval, .allowOnce)
        guard case let .approval(card)? = model.card(for: ID.approval) else { Issue.record("the card went"); return }
        #expect(card.send == .notSent)
        #expect(model.needsYou.contains { $0.id == ID.approval })

        // Retry sends the same decision again; once it went, the card goes.
        feed.sendsFail = false
        model.retry(ID.approval)
        await settle { model.card(for: ID.approval) == nil }
        #expect(model.card(for: ID.approval) == nil)
        #expect(feed.sentCommands.count == 1)
        guard case let .resolvePermission(_, resolution)? = feed.sentCommands.first else { Issue.record("no decision sent"); return }
        #expect(resolution == .allowOnce())
    }

    @Test
    func answersThatCouldNotBeSentKeepTheQuestionAsItWas() async {
        let feed = FixtureSessionFeed(scenario: .prototype, sendsFail: true)
        let model = feed.makeModel()
        #expect(model.answerQuestion(ID.question, .option(1)))
        await settle { if case let .question(card)? = model.card(for: ID.question) { card.send == .notSent } else { false } }
        guard case let .question(card)? = model.card(for: ID.question) else { Issue.record("the card went"); return }
        #expect(card.send == .notSent && card.picked == [1])

        feed.sendsFail = false
        model.retry(ID.question)
        await settle { model.card(for: ID.question) == nil }
        #expect(model.card(for: ID.question) == nil)
        guard case let .answerQuestion(_, response)? = feed.sentCommands.first else { Issue.record("no answer sent"); return }
        #expect(response.answers.values.contains("Juice Bar"))
    }

    /// Retry goes to the request its failed send was for, never to one that took its place before Retry's task ran
    /// (P170, P186).
    @Test
    func aRetryNeverAnswersARequestItsFailedSendWasNotFor() async {
        let feed = FixtureSessionFeed(scenario: .prototype, sendsFail: true)
        let model = feed.makeModel()
        await model.decide(ID.approval, .allowOnce)
        guard case let .approval(card)? = model.card(for: ID.approval), card.send == .notSent else {
            Issue.record("no Retry on the card")
            return
        }
        let first = feed.engine.attentionHead(for: ID.approval)?.id

        // The owner clicks Retry; before its task runs, the session asks again and that request takes the card's place.
        feed.sendsFail = false
        model.retry(ID.approval)
        feed.engine.loadPreviewEvents([Self.permission(ID.approval, at: feed.now)])
        #expect(feed.engine.attentionHead(for: ID.approval)?.id != first)
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(feed.sentCommands.isEmpty, "Retry answered \(feed.sentCommands)")
    }

    // MARK: The next card (P130)

    /// Another Claude session asks later: it waits behind the ones already waiting, and a session that asks again
    /// goes to the back.
    @Test
    func waitingCardsComeInTheOrderTheyArrived() async {
        let feed = FixtureSessionFeed(scenario: .prototype)
        let model = feed.makeModel()
        let first = model.waiting.map(\.id)
        #expect(Set(first) == [ID.question, ID.approval])
        feed.engine.loadPreviewEvents([Self.started("demo-late", at: feed.now), Self.permission("demo-late", at: feed.now)])
        #expect(model.waiting.map(\.id) == first + ["demo-late"])

        await model.decide(ID.approval, .allowOnce)
        #expect(model.waiting.map(\.id) == [ID.question, "demo-late"])
        feed.engine.loadPreviewEvents([Self.permission(ID.approval, at: feed.now)])
        #expect(model.waiting.map(\.id) == [ID.question, "demo-late", ID.approval])
    }

    static func started(_ id: String, at now: Date) -> AgentEvent {
        .sessionStarted(SessionStarted(sessionID: id, title: "Tag the release", tool: .claudeCode, origin: .live, initialPhase: .running,
                                       summary: "Started.", timestamp: now - 60,
                                       jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "notes-site", paneTitle: "claude")))
    }

    static func permission(_ id: String, at now: Date) -> AgentEvent {
        .permissionRequested(PermissionRequested(sessionID: id, request: PermissionRequest(
            title: "Allow Bash", summary: "Claude Code wants to run Bash.", affectedPath: "git tag v2",
            primaryActionTitle: "Allow Once", secondaryActionTitle: "Deny", toolName: "Bash", toolUseID: nil), timestamp: now - 10))
    }

    @Test
    func theIslandShowsTheNextWaitingCardAfterAnAnswer() {
        let rows = [Self.row("a"), Self.row("b"), Self.row("c")]
        #expect(IslandAttention.next(after: "a", wasWaiting: true, waiting: rows) == "b")
        #expect(IslandAttention.next(after: "b", wasWaiting: true, waiting: rows) == "a")
        // None left, or a Done card went: back to the list (or a close, the pointer away).
        #expect(IslandAttention.next(after: "a", wasWaiting: true, waiting: [Self.row("a")]) == nil)
        #expect(IslandAttention.next(after: "a", wasWaiting: false, waiting: rows) == nil)
    }

    /// A new approval never takes the place of one the owner may be about to answer on the open island; it waits its
    /// turn. It still shows over the list, a Done card or a closed island.
    @Test
    func aNewApprovalWaitsBehindTheCardThatShows() {
        let rows = [Self.row("a"), Self.row("b")]
        let queued = IslandAttention.respond(to: [.needsYou("b")], rows: rows, finish: .card, cardInUse: true, waitingCardShows: true)
        #expect(queued.card == nil)
        #expect(IslandAttention.respond(to: [.needsYou("b")], rows: rows, finish: .card, cardInUse: true).card == "b")
    }

    @Test
    func theIslandCardCountsTheOthersThatWait() throws {
        let model = FixtureSessionFeed(scenario: .prototype).makeModel()
        let card = try #require(model.card(for: ID.approval))
        #expect(CardText.status(card, more: 1).text == "Bash · 1 more")
        #expect(CardText.status(card).text == "Bash")
        let done = SessionCard.done(DoneCardModel(sessionID: "d", agent: .claude, message: "ok", interrupted: false))
        #expect(CardText.status(done, more: 3).text == nil)
    }

    static func row(_ id: String, bucket: SessionBucket = .needsYou, hasCard: Bool = true) -> SessionRow {
        SessionRow(id: id, agent: .claude, bucket: bucket, project: "p", task: "t", status: bucket == .done ? .done : .needsApproval(tool: "Bash"),
                   detail: nil, lastPrompt: nil, host: nil, accountAlias: nil, updatedAt: DemoClock.now, isCodexApp: false,
                   glyph: .bang, glyphState: .waiting, hasCard: hasCard)
    }

    // MARK: No, with a reason or a stop

    @Test
    func aReasonGoesBackWithTheNo() async {
        let feed = FixtureSessionFeed(scenario: .prototype)
        let model = feed.makeModel()
        await model.decide(ID.approval, .denyWithReason("push to a branch instead"))
        guard case let .resolvePermission(_, resolution)? = feed.sentCommands.first else { Issue.record("nothing sent"); return }
        #expect(resolution == .deny(message: "push to a branch instead", interrupt: false))
    }

    @Test
    func controlShiftDIsNoAndStopOnClaudeOnly() {
        let claude = ApprovalCardModel(sessionID: "c", agent: .claude, tool: "Bash", body: .command("ls"), canStop: true)
        let codex = ApprovalCardModel(sessionID: "x", agent: .codex, tool: "shell", body: .command("ls"), canStop: false)
        let stop = IslandKeyPress(characters: "D", control: true, shift: true)
        #expect(IslandKeyRouter.command(for: stop, card: .approval(claude)) == .approve(sessionID: "c", .denyAndStop))
        #expect(IslandKeyRouter.command(for: stop, card: .approval(codex)) == nil)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "d", control: true), card: .approval(codex))
            == .approve(sessionID: "x", .deny))
        let plan = PlanCardModel(sessionID: "p", agent: .claude, plan: nil, steps: nil, canStop: true)
        #expect(IslandKeyRouter.command(for: stop, card: .plan(plan)) == .approve(sessionID: "p", .denyAndStop))
        #expect(WindowKeyRouter.command(for: .init(character: "D", control: true, shift: true)) == .decide(.denyAndStop))
        #expect(WindowKeyRouter.command(for: .init(character: "d", control: true)) == .decide(.deny))
        #expect(DenyChoices<EmptyView>.tip(canStop: true) == "⌥-click to say why · ⌃⇧D to stop the turn")
        #expect(DenyChoices<EmptyView>.tip(canStop: false) == "⌥-click to say why")
    }

    @Test
    func onlyClaudesCardsOfferAStop() throws {
        let model = FixtureSessionFeed(scenario: .cards).makeModel()
        guard case let .approval(claude)? = model.card(for: ID.longBash), case let .approval(codex)? = model.card(for: ID.codexShort),
              case let .plan(plan)? = model.card(for: ID.longPlan) else { Issue.record("missing cards"); return }
        #expect(claude.canStop && plan.canStop && !codex.canStop)
    }

    // MARK: Archive (P131)

    @Test
    func archiveIsOnlyForFinishedRows() {
        #expect(Self.row("d", bucket: .done, hasCard: false).canArchive)
        #expect(!Self.row("w").canArchive)
        #expect(!Self.row("r", bucket: .running, hasCard: false).canArchive)
        // A failed turn needs you: it is not archived either.
        #expect(!Self.row("f", bucket: .needsYou, hasCard: false).canArchive)

        // The model refuses it too: the approval stays, and its agent is not left waiting with no card.
        let model = FixtureSessionFeed(scenario: .prototype).makeModel()
        model.dismiss(ID.approval)
        #expect(model.card(for: ID.approval) != nil && model.needsYou.contains { $0.id == ID.approval })
    }

    // MARK: A failed turn (P132)

    @Test
    func aFailedTurnSaysWhyInPlainWords() throws {
        #expect(TurnFailure.words("rate_limit") == "Rate limited")
        #expect(TurnFailure.words("authentication_failed") == "Signed out")
        #expect(TurnFailure.words(" max_output_tokens ") == "Hit the output limit")
        #expect(TurnFailure.words("API Error: 529 Overloaded") == "API Error: 529 Overloaded")

        // A failure that is no limit or API error (P700): "Turn failed" and why.
        let signedOut = SessionCard.done(DoneCardModel(sessionID: "o", agent: .claude, message: "Signed out", interrupted: false, failed: true))
        #expect(CardText.status(signedOut) == .init(word: "Turn failed", tone: .approval, isPrompt: false, text: "Signed out"))
        // A rate limit: the API's, said as its kind.
        let model = TurnFailedTests.model()
        let card = try #require(model.card(for: TurnFailedTests.failedID))
        let status = CardText.status(card)
        #expect(status == .init(word: "API error", tone: .approval, isPrompt: false, text: "rate limited"))
        guard case let .done(done) = card else { Issue.record("not a done card"); return }
        // The reason is on the status line, so the card has no message box, and nothing at all below its header
        // without a reply.
        #expect(DoneCardView.message(done) == nil)
        #expect(card.isHeaderOnly(replySetting: true))

        let long = DoneCardModel(sessionID: "l", agent: .claude, message: "API Error: 500 the server had an error while processing",
                                 interrupted: false, failed: true)
        #expect(CardText.status(.done(long)).text == nil)
        #expect(DoneCardView.message(long) == long.message)
    }

    // MARK: Replies (P128)

    @Test
    func aReplyIsOfferedOnlyWhereItsTerminalIsKnown() async throws {
        let feed = FixtureSessionFeed(scenario: .allStates)
        let model = feed.makeModel()
        guard case let .done(ghostty)? = model.card(for: ID.claudeDone), case let .done(terminal)? = model.card(for: ID.codexDone) else {
            Issue.record("no done cards"); return
        }
        #expect(ghostty.canReply && !terminal.canReply)

        await model.sendReply(ID.claudeDone, "  ship it ")
        guard case let .done(sent)? = model.card(for: ID.claudeDone) else { Issue.record("the card went"); return }
        #expect(sent.send == .sent)
        #expect(feed.sentReplies.map(\.text) == ["ship it"])
        #expect(feed.sentReplies.first?.route == .ghostty(terminalID: "3F2A9C1E-0000-4000-8000-00000000D0E1"))
        // Nowhere to type it: nothing is sent, and the card says nothing.
        await model.sendReply(ID.codexDone, "hello")
        #expect(feed.sentReplies.count == 1)
        guard case let .done(untouched)? = model.card(for: ID.codexDone) else { Issue.record("the card went"); return }
        #expect(untouched.send == nil)
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var current: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// P139: the agent left its prompt after the card was drawn (Ctrl-Z, a crash): a reply typed then goes nowhere, and
    /// the card is drawn again without its field, so nothing offers a Retry that could not go either.
    @Test
    func aReplyAfterTheAgentLeftItsPromptRedrawsTheCardWithoutItsField() async throws {
        let atPrompt = Flag(true), typed = Flag(false)
        var configuration = SessionEngine.Configuration.headless
        configuration.excludedWorkingDirectories = []
        var dependencies = SessionEngine.Dependencies()
        dependencies.sendCommand = { _ in }
        dependencies.updateProcessRoots = { _ in }
        dependencies.ttyForPID = { _ in nil }
        dependencies.appForPID = { _ in nil }
        dependencies.sendReply = { _, _ in
            typed.current = true
            return true
        }
        dependencies.agentAtPrompt = { _ in atPrompt.current }
        let engine = SessionEngine(configuration: configuration, dependencies: dependencies)
        engine.loadPreviewEvents(FixtureSessionFeed.events(.allStates, now: DemoClock.now))
        engine.loadPreviewAgents([ID.claudeDone: 4242])
        let model = EngineSessionsModel(engine: engine, clock: { DemoClock.now })
        guard case let .done(before)? = model.card(for: ID.claudeDone) else { Issue.record("no done card"); return }
        #expect(before.canReply)
        atPrompt.current = false
        await model.sendReply(ID.claudeDone, "rm -rf build")
        guard case let .done(after)? = model.card(for: ID.claudeDone) else { Issue.record("the card went"); return }
        #expect(!after.canReply)
        #expect(!typed.current)
    }

    @Test
    func aReplyThatCouldNotBeSentSaysSoAndRetries() async {
        let feed = FixtureSessionFeed(scenario: .allStates, sendsFail: true)
        let model = feed.makeModel()
        await model.sendReply(ID.claudeDone, "ship it")
        guard case let .done(card)? = model.card(for: ID.claudeDone) else { Issue.record("the card went"); return }
        #expect(card.send == .notSent)
        feed.sendsFail = false
        model.retry(ID.claudeDone)
        await settle { if case let .done(card)? = model.card(for: ID.claudeDone) { card.send == .sent } else { false } }
        #expect(feed.sentReplies.map(\.text) == ["ship it"])
    }
}
