import Foundation
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// The needs-you pipeline's UI (the needs-you design §3.5): rows, glyphs, counts and cards from the engine's book of
/// requests only; read-only cards with Open and ✕; answers keyed by the request the card showed (P170); machine text
/// never on a row (P155); the needs-you sound only while the session still needs you. Demo engines fed through the
/// live paths (`FixtureSessionFeed+Attention.swift`); nothing leaves the process.
@MainActor
struct NeedsYouUITests {
    typealias ID = FixtureSessionFeed.AttentionID

    private func model(_ scenario: FixtureSessionFeed.Scenario) -> EngineSessionsModel {
        FixtureSessionFeed(scenario: scenario).makeModel()
    }

    // MARK: The owner's two situations

    /// Screenshot 1, left: the Codex app thread that asks with `request_user_input_async` and reasons on reads
    /// "Question" with "?", never "Thinking", and its card is the question with its options, read-only, Open and ✕.
    @Test
    func theCodexAppQuestionIsAReadOnlyCard() throws {
        let model = model(.owner)
        let row = try #require(model.row(id: ID.codexQuestion))
        #expect(row.glyph == .ques && row.glyphState == .waiting && row.status == .question && row.bucket == .needsYou)
        #expect(row.hasCard && row.isCodexApp && row.waitingRequests == 1)
        #expect(model.needsYouCount == 1)
        guard case let .question(card)? = model.card(for: ID.codexQuestion) else {
            Issue.record("no question card")
            return
        }
        let request = try #require(card.request)
        #expect(!card.isAnswerable && request.place == .codexApp && request.dismissable && !request.isNotice)
        #expect(card.shown == [.init(topic: nil, question: FixtureSessionFeed.paperQuestion,
                                     options: FixtureSessionFeed.paperOptions.map { .init(label: $0, description: "") })])
        let status = CardText.status(.question(card), host: row.host)
        #expect(status.word == "Question" && status.text == "in Codex")
        // Nothing on it answers: a pick or a typed answer goes nowhere.
        #expect(!model.answerQuestion(ID.codexQuestion, .option(0)))
        #expect(!model.answerQuestion(ID.codexQuestion, .text("Keep it")))
        #expect(model.row(id: ID.codexQuestion)?.hasCard == true)
    }

    /// Screenshot 1, right: a background task's notice arrived as the Claude row's last "prompt"; the row keeps the
    /// owner's own prompt, as its title (the session has no title of Claude's yet), which its status line in Clean,
    /// Detailed and the window then does not say again (P203); never the notice.
    @Test
    func theRetrospectionRowKeepsTheOwnersPrompt() throws {
        let model = model(.owner)
        let row = try #require(model.row(id: ID.retro))
        #expect(row.lastPrompt == FixtureSessionFeed.retroPrompt)
        #expect(row.task == FixtureSessionFeed.retroPrompt && row.titleSource == .prompt)
        #expect(row.glyph == .eq && row.bucket == .running && !row.hasCard)
        #expect(SessionRowText.cleanStatus(row).text == "Working")
        #expect(IslandRowText.status(row).text == "Working")
        #expect(DetailedRowText.status(row).prompt == nil)
        let detailed = SessionRowText.detailedStatus(row)
        #expect(!detailed.isPrompt && detailed.text == "Working")
        #expect(!DetailedRowView.statusHelp(detailed, limit: 0).contains("<"))
        #expect(!SessionRowText.titleHelp(row, limit: 0).contains("<"))
    }

    /// No row, in any scenario, says machine text: nothing a row, its tooltip or a Done card shows starts with a tag.
    @Test
    func noRowShowsMachineText() {
        for scenario: FixtureSessionFeed.Scenario in [.owner, .attention, .allStates, .cards, .agents, .codexApproval] {
            let model = model(scenario)
            for row in model.rows {
                let texts = [SessionRowText.cleanStatus(row).text, IslandRowText.status(row).text, SessionRowText.detailedStatus(row).text,
                             DetailedRowText.status(row).prompt, DetailedRowText.status(row).text, row.lastPrompt, row.task]
                for text in texts.compactMap({ $0 }) { #expect(!text.hasPrefix("<"), "\(row.id): \(text)") }
                if case let .done(card)? = model.card(for: row.id) { #expect(!card.message.hasPrefix("<"), "\(row.id)") }
            }
        }
    }

    @Test
    func aPromptOnARowIsOneLine() {
        #expect(EngineSessionsModel.oneLine("fix the tests\n\n  then push\n") == "fix the tests then push")
        #expect(EngineSessionsModel.oneLine("one line") == "one line")
    }

    // MARK: Glyphs and counts from the book

    /// "!" and "?" only for a confirmed request, "×" for a failed turn, and a waiting phase with nothing behind it
    /// reads as running (P161).
    @Test
    func glyphsComeFromTheBookOnly() {
        typealias M = EngineSessionsModel
        #expect(M.glyph(head: .approval, failed: false, phase: .waitingForApproval, interrupted: false) == (.bang, .waiting))
        #expect(M.glyph(head: .plan, failed: false, phase: .waitingForApproval, interrupted: false) == (.bang, .waiting))
        #expect(M.glyph(head: .question, failed: false, phase: .running, interrupted: false) == (.ques, .waiting))
        #expect(M.glyph(head: .elicitation, failed: true, phase: .completed, interrupted: false) == (.ques, .waiting))
        #expect(M.glyph(head: nil, failed: true, phase: .completed, interrupted: false) == (.cross, .waiting))
        #expect(M.glyph(head: nil, failed: false, phase: .waitingForApproval, interrupted: false) == (.eq, .running))
        #expect(M.glyph(head: nil, failed: false, phase: .waitingForAnswer, interrupted: false) == (.eq, .running))
        #expect(M.glyph(head: nil, failed: false, phase: .completed, interrupted: true) == (.check, .idle))
        #expect(M.glyph(head: nil, failed: false, phase: .completed, interrupted: false) == (.check, .done))
        #expect(M.status(.needsApproval(tool: "Bash"), head: nil) == .working)
        #expect(M.status(.question, head: nil) == .working)
        #expect(M.status(.thinking, head: nil) == .thinking)
    }

    /// A session whose phase says it waits, with no request in the book (a restored record, a request released or
    /// never confirmed): no "!", no card, not counted, and it can be archived only once it is done.
    @Test
    func aWaitingPhaseWithNoRequestDrawsNothing() throws {
        let feed = FixtureSessionFeed(scenario: .owner)
        var session = try #require(feed.engine.state.session(id: ID.retro))
        session.phase = .waitingForApproval
        session.permissionRequest = PermissionRequest(title: "Allow Bash", summary: "", affectedPath: "git push")
        feed.engine.replace(session)
        let model = feed.makeModel()
        let row = try #require(model.row(id: ID.retro))
        #expect(row.glyph != .bang && row.bucket != .needsYou && !row.hasCard)
        #expect(model.card(for: ID.retro) == nil && model.needsYouCount == 1)
    }

    /// Every confirmed request counts, read-only ones too (the agent really waits), and a failed turn: six rows.
    @Test
    func theRequestsAndAFailedTurnAreWhatNeedsYou() throws {
        let model = model(.attention)
        #expect(model.needsYouCount == 6)
        let failed = try #require(model.row(id: ID.failed))
        #expect(failed.glyph == .cross && failed.glyphState == .waiting && failed.status == .failed && !failed.hasCard)
        let queue = try #require(model.row(id: ID.claudeQueue))
        #expect(queue.glyph == .bang && queue.waitingRequests == 2)
        #expect(model.waiting.map(\.id).count == 5)
    }

    // MARK: Cards

    /// Claude in a terminal: the island holds both hooks, so the card answers, and says one more waits behind it.
    @Test
    func anAnswerableCardCountsTheRequestsBehindIt() throws {
        let model = model(.attention)
        guard case let .approval(card)? = model.card(for: ID.claudeQueue) else {
            Issue.record("no approval card")
            return
        }
        #expect(card.isAnswerable && card.request?.more == 1 && card.request?.dismissable == false && card.tool == "Bash")
        let row = try #require(model.row(id: ID.claudeQueue))
        #expect(CardText.status(.approval(card), more: 1, host: row.host).text == "Bash · 1 more")
    }

    /// Codex in a terminal: released to Codex's own prompt, the card read-only: no answers, no Always allow, no No and
    /// stop, where it is answered on its status line.
    @Test
    func aCodexRequestHandedBackToCodexIsReadOnly() throws {
        let model = model(.attention)
        guard case let .approval(card)? = model.card(for: ID.codexApproval) else {
            Issue.record("no approval card")
            return
        }
        #expect(!card.isAnswerable && card.alwaysAllowLabel == nil && !card.canStop && card.send == nil)
        #expect(card.request?.place == .terminal && card.request?.dismissable == true)
        if case let .command(command) = card.body { #expect(command == FixtureSessionFeed.codexMigration) } else { Issue.record("\(card.body)") }
        let row = try #require(model.row(id: ID.codexApproval))
        #expect(CardText.status(.approval(card), host: row.host).text == "Bash · in Terminal")
    }

    /// A subagent's request sits on its parent's row, named before the tool on the row and the card.
    @Test
    func aSubagentIsNamedBeforeTheTool() throws {
        let model = model(.attention)
        let row = try #require(model.row(id: ID.subagent))
        #expect(row.asker == "link-checker" && row.glyph == .bang)
        #expect(SessionRowText.cleanStatus(row).text == "link-checker · Bash: curl -sI https://example.com/docs/setup")
        #expect(DetailedRowText.status(row).text == "link-checker · Bash: curl -sI https://example.com/docs/setup")
        let card = try #require(model.card(for: ID.subagent))
        #expect(!card.isAnswerable)
        #expect(CardText.status(card, host: row.host).text == "link-checker · Bash · in iTerm")
    }

    /// Claude Desktop's own session, and a prompt no hook stood for: read-only, where they wait, and nothing else.
    @Test
    func aDesktopRequestAndANoticeSayWhereTheyWait() throws {
        let model = model(.attention)
        let desktop = try #require(model.card(for: ID.desktop))
        #expect(!desktop.isAnswerable && desktop.request?.place == .claudeApp)
        #expect(CardText.status(desktop).text == "Write · in Claude")
        guard case let .approval(notice)? = model.card(for: ID.notice) else {
            Issue.record("no notice card")
            return
        }
        #expect(notice.isNotice && !notice.isAnswerable)
        let row = try #require(model.row(id: ID.notice))
        #expect(CardText.status(.approval(notice), host: row.host) == .init(word: "Needs approval", tone: .approval, isPrompt: false,
                                                                            text: "in Terminal"))
        #expect(SessionRowText.cleanStatus(row).word == "Needs approval" && SessionRowText.cleanStatus(row).text == nil)
    }

    @Test
    func placesAreSaidInAFewWords() {
        #expect(CardText.place(.codexApp, host: "Codex.app") == "in Codex")
        #expect(CardText.place(.claudeApp, host: nil) == "in Claude")
        #expect(CardText.place(.terminal, host: "Ghostty") == "in Ghostty")
        #expect(CardText.place(.terminal, host: nil) == "in the terminal")
        #expect(CardText.place(.ide, host: nil) == "in the editor")
    }

    // MARK: Actions

    /// P170: a click goes to the request its card showed, by id; once that one is gone, the same click answers nothing,
    /// never the request that took its place in the session's queue.
    @Test
    func aClickNeverAnswersTheRequestThatTookItsPlace() async throws {
        let model = model(.attention)
        let first = try #require(model.card(for: ID.claudeQueue)?.request?.id)
        await model.decide(ID.claudeQueue, .allowOnce, request: "not-the-one-shown")
        #expect(model.card(for: ID.claudeQueue)?.request?.id == first)
        await model.decide(ID.claudeQueue, .allowOnce, request: first)
        // No broker listens in the demo: the request closes as its hook ended, and the edit behind it shows.
        let second = try #require(model.card(for: ID.claudeQueue)?.request?.id)
        #expect(second != first)
        await model.decide(ID.claudeQueue, .deny, request: first)
        #expect(model.card(for: ID.claudeQueue)?.request?.id == second)
        guard case let .approval(card)? = model.card(for: ID.claudeQueue) else {
            Issue.record("no card")
            return
        }
        #expect(card.tool == "Edit" && card.request?.more == 0)
    }

    /// Answers made on one question never go to another that took its place; on the question itself they go.
    @Test
    func answersGoOnlyToTheQuestionTheyWereMadeOn() async throws {
        let feed = FixtureSessionFeed(scenario: .cards)
        let model = feed.makeModel()
        let id = FixtureSessionFeed.ID.questions
        let shown = try #require(model.card(for: id)?.request?.id)
        #expect(!model.answerQuestion(id, .option(0), request: "not-the-one-shown"))
        await model.sendAnswers(id, QuestionPromptResponse(answer: "Beta"), request: "not-the-one-shown")
        #expect(feed.sentCommands.isEmpty && model.card(for: id) != nil)
        await model.sendAnswers(id, QuestionPromptResponse(answer: "Beta"), request: shown)
        #expect(feed.sentCommands.count == 1)
    }

    /// ✕ lets a read-only notice go (the agent keeps its prompt); on a card the island holds it does nothing.
    @Test
    func dismissLetsOnlyAReadOnlyRequestGo() throws {
        let model = model(.attention)
        model.dismissRequest(ID.codexApproval)
        #expect(model.card(for: ID.codexApproval) == nil && model.row(id: ID.codexApproval)?.bucket != .needsYou)
        model.dismissRequest(ID.claudeQueue)
        #expect(model.card(for: ID.claudeQueue) != nil)
        // An archive is refused while a request waits.
        model.dismiss(ID.subagent)
        #expect(model.row(id: ID.subagent) != nil)
    }

    /// P174: ✕ and Open act on the request their card showed, by id. Two read-only subagent requests wait on one row;
    /// the first closes by its own evidence while the owner's ✕ on its card is on the way: the second, never seen,
    /// stays, and Open from the first card finds nothing to close (a plain jump). On the second's own card ✕ lets it go.
    @Test
    func theReadOnlyButtonsActOnTheRequestTheirCardShowed() throws {
        let feed = FixtureSessionFeed(scenario: .attention)
        feed.engine.loadPreviewHookRequest(FixtureSessionFeed.claudeRequest(ID.subagent, tool: "Bash", useID: "toolu_second_check", input: [
            "command": "curl -sI https://example.com/docs/other", "description": "Check the other link"],
            agent: "agent-second-check", agentType: "link-checker"), source: "claude", entrypoint: "cli")
        let model = feed.makeModel()
        #expect(model.row(id: ID.subagent)?.waitingRequests == 2)
        let first = try #require(model.card(for: ID.subagent)?.request?.id)
        #expect(model.requestShown(ID.subagent, first)?.id == first)
        // The first closes on its own evidence (a PostToolUse, a SubagentStop), then the click made on its card lands.
        feed.engine.dismissRequest(requestID: first)
        model.dismissRequest(ID.subagent, request: first)
        let second = try #require(model.card(for: ID.subagent)?.request?.id)
        #expect(second != first)
        #expect(model.requestShown(ID.subagent, first) == nil)
        model.openRequest(ID.subagent, request: first)
        #expect(model.card(for: ID.subagent)?.request?.id == second)
        // Another session's request id never acts here.
        let other = try #require(model.card(for: ID.codexApproval)?.request?.id)
        model.dismissRequest(ID.subagent, request: other)
        #expect(model.card(for: ID.subagent)?.request?.id == second && model.card(for: ID.codexApproval) != nil)
        model.dismissRequest(ID.subagent, request: second)
        #expect(model.row(id: ID.subagent)?.hasCard == false)
    }

    /// P171: the app's sessions model hands Open and ✕ to the model that shows, not the protocol's plain jump.
    @Test
    func liveSessionsForwardsTheReadOnlyButtons() throws {
        let settings = AppSettings.ephemeral()
        let live = LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .owner).makeModel() }, engine: {
            SessionEngine.preview()
        }, profiles: { LiveProfiles(accounts: [], discovered: []) }, identity: .other)
        live.apply()
        #expect(live.row(id: ID.codexQuestion)?.hasCard == true)
        live.dismissRequest(ID.codexQuestion, request: "not-the-one-shown")
        #expect(live.row(id: ID.codexQuestion)?.hasCard == true)
        live.dismissRequest(ID.codexQuestion, request: live.card(for: ID.codexQuestion)?.request?.id)
        #expect(live.row(id: ID.codexQuestion)?.hasCard == false)
        live.shutdown()
    }

    /// Card keys never reach a read-only card, and never pass one for another card (P351): in the island and the window
    /// they act on the one card the owner sees, with the request that card shows.
    @Test
    func cardKeysSkipReadOnlyCards() throws {
        let model = model(.attention)
        let readOnly = try #require(model.card(for: ID.codexApproval))
        let answerable = try #require(model.card(for: ID.claudeQueue))
        let control = IslandKeyPress(characters: "a", control: true)
        #expect(IslandKeyRouter.command(for: control, card: readOnly) == nil)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "d", control: true), card: readOnly) == nil)
        #expect(IslandKeyRouter.command(for: control, card: answerable) == .approve(sessionID: ID.claudeQueue, .allowOnce))
        let question = try #require(FixtureSessionFeed(scenario: .owner).makeModel().card(for: ID.codexQuestion))
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "1", control: true), card: question) == nil)

        let spy = SpySessions(model)
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: DemoClock.now), sessions: spy)
        env.windowSelection = ID.codexApproval
        #expect(!WindowKeyRouter.perform(.decide(.allowOnce), env: env) && spy.approvals.isEmpty)
        env.windowSelection = ID.claudeQueue
        #expect(WindowKeyRouter.perform(.decide(.allowOnce), env: env))
        #expect(spy.approvals.count == 1)
        #expect(spy.approvals.first?.sessionID == ID.claudeQueue && spy.approvals.first?.request == answerable.request?.id)
        let owner = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: DemoClock.now), sessions: SpySessions(self.model(.owner)))
        #expect(!WindowKeyRouter.perform(.option(0), env: owner))
    }

    /// P173, P351: with the list showing, a card key acts only on a row the island shows: the keys' row, else the first
    /// waiting row. When that row is read-only (a Codex approval, a released subagent), ⌃A answers nothing: never the
    /// answerable request in a row behind "Show N more", nor one further down the rows shown; with every row shown, it
    /// answers that request only once the keys rest on its row.
    @Test
    func aListKeyNeverAnswersARowTheIslandDoesNotShow() throws {
        let feed = FixtureSessionFeed(scenario: .attention)
        for n in 1...3 {
            feed.engine.loadPreviewHookRequest(FixtureSessionFeed.claudeRequest("released-\(n)", tool: "Bash", useID: "toolu_released_\(n)",
                input: ["command": "ls -la", "description": "List"], agent: "agent-released-\(n)", agentType: "worker"),
                source: "claude", entrypoint: "cli")
        }
        let model = feed.makeModel()
        let shown = IslandListLayout.make(rows: model.rows, style: .clean, showAll: false, now: model.now).shown.map(\.id)
        #expect(!shown.contains(ID.claudeQueue) && model.card(for: ID.claudeQueue)?.isAnswerable == true)
        let control = IslandKeyPress(characters: "a", control: true)
        let card = IslandKeyRouter.targetCard(presentation: .list, sessions: model)
        #expect(card?.sessionID == shown.first { model.row(id: $0)?.bucket == .needsYou } && card?.isAnswerable == false)
        #expect(IslandKeyRouter.command(for: control, card: card) == nil)
        // A row behind the footer cannot be the keys' row until it shows.
        #expect(IslandKeyRouter.targetCard(presentation: .list, sessions: model, selected: ID.claudeQueue)?.sessionID != ID.claudeQueue)
        let all = IslandKeyRouter.targetCard(presentation: .list, sessions: model, showAll: true)
        #expect(IslandKeyRouter.command(for: control, card: all) == nil)
        let selected = IslandKeyRouter.targetCard(presentation: .list, sessions: model, showAll: true, selected: ID.claudeQueue)
        #expect(IslandKeyRouter.command(for: control, card: selected) == .approve(sessionID: ID.claudeQueue, .allowOnce))
    }

    /// P172: the island shows session S's card for request A; A is answered and B, the next request of S's queue, takes
    /// its place. While another session's card waits, the one that has waited longest takes the card's place with the
    /// swap (P130: S went to the back); with none, B comes in where A was as a card that has just come in, which takes
    /// no click and no card key (P138). Until the island draws B, card keys act on A as drawn, and so answer nothing.
    @Test
    func theNextRequestOfTheSameSessionComesInAsANewCard() async throws {
        let model = model(.attention)
        let s = ID.claudeQueue
        let a = try #require(model.card(for: s))
        await model.decide(s, .allowOnce, request: a.request?.id)
        let b = try #require(model.card(for: s))
        #expect(a.request?.id != b.request?.id && b.isAnswerable)
        let waiting = model.waiting
        #expect(waiting.last?.id == s && waiting.count > 1)
        #expect(IslandAttention.shownCardChanged(drawn: a, current: b, waiting: waiting) == .next(waiting[0].id))
        #expect(IslandAttention.shownCardChanged(drawn: a, current: b, waiting: waiting.filter { $0.id == s }) == .arrives)
        // A Done card that became a request comes in the same way; it waited for nothing, so no other card takes its place.
        let done = SessionCard.done(DoneCardModel(sessionID: s, agent: .claude, message: "Pushed.", interrupted: false))
        #expect(IslandAttention.shownCardChanged(drawn: done, current: b, waiting: waiting) == .arrives)
        // The same request drawn again, or a finished turn's card of a later turn: nothing comes in.
        #expect(IslandAttention.shownCardChanged(drawn: b, current: b, waiting: waiting) == .none)
        #expect(IslandAttention.shownCardChanged(drawn: done, current: done, waiting: waiting) == .none)
        #expect(IslandAttention.shownCardChanged(drawn: nil, current: b, waiting: waiting) == .none)

        // Keys: the card as drawn (A) until the island draws B; A's id answers nothing now.
        let control = IslandKeyPress(characters: "a", control: true)
        let drawn = IslandKeyRouter.targetCard(presentation: .card(sessionID: s), sessions: model, drawn: a)
        #expect(drawn?.request?.id == a.request?.id)
        await model.decide(s, .allowOnce, request: drawn?.request?.id)
        #expect(model.card(for: s)?.request?.id == b.request?.id)
        // Drawn, B has just come in: the second press and the second click are eaten.
        #expect(IslandKeyRouter.command(for: control, card: b, arriving: s) == .swallow)
        #expect(!IslandCardLayer.takesClicks(s, role: .live, presentation: .card(sessionID: s), arriving: s))
    }

    // MARK: Sounds and the pill

    /// A needs-you signal plays only while its session still needs you (answered at the agent's own prompt on the way:
    /// silence); a Done is unchanged.
    @Test
    func theNeedsYouSoundNeedsAStandingRequest() {
        let settings = AppSettings.ephemeral()
        settings.needsYouSound = .system("Glass")
        #expect(SignalSounds.sound(for: .needsYou(sessionID: "s"), isCodexAppThread: false, stillNeedsYou: true, settings: settings) == "Glass")
        #expect(SignalSounds.sound(for: .needsYou(sessionID: "s"), isCodexAppThread: false, stillNeedsYou: false, settings: settings) == nil)
        settings.doneSound = .system("Hero")
        #expect(SignalSounds.sound(for: .done(sessionID: "s"), isCodexAppThread: false, stillNeedsYou: false, settings: settings) == "Hero")
    }

    /// The pill leads with an approval, then a question, then a failed turn.
    @Test
    func thePillLeadsWithWhatWaitsBeforeAFailedTurn() {
        let failed = DStub.row("f", .claude, .needsYou, glyph: .cross, status: .failed)
        let question = DStub.row("q", .codex, .needsYou, glyph: .ques)
        let approval = DStub.row("a", .claude, .needsYou, glyph: .bang)
        #expect(PillLead.make(rows: [failed, question], recentlyFinished: nil)?.glyph == .ques)
        #expect(PillLead.make(rows: [failed, question, approval], recentlyFinished: nil)?.glyph == .bang)
        #expect(PillLead.make(rows: [failed], recentlyFinished: nil)?.glyph == .cross)
        #expect(GlyphMood(.cross) == .done && !PixelGlyph.cross.needsYou)
    }
}

/// Records the card actions a key sends, over a real model's rows and cards.
@MainActor
@Observable
final class SpySessions: SessionsModel {
    let inner: EngineSessionsModel
    var approvals: [(sessionID: String, decision: ApprovalDecision, request: String?)] = []
    var answers: [(sessionID: String, input: QuestionInput, request: String?)] = []

    init(_ inner: EngineSessionsModel) { self.inner = inner }

    var rows: [SessionRow] { inner.rows }
    var now: Date { inner.now }
    func card(for sessionID: String) -> SessionCard? { inner.card(for: sessionID) }
    func approve(_ sessionID: String, _ decision: ApprovalDecision, request: String?) { approvals.append((sessionID, decision, request)) }
    func answerQuestion(_ sessionID: String, _ input: QuestionInput, request: String?) -> Bool {
        answers.append((sessionID, input, request))
        return false
    }
    func reply(_ sessionID: String, text: String) {}
    func jump(_ sessionID: String) {}
    func jumpToNextNeedsYou() {}
    func dismiss(_ sessionID: String) {}
}
