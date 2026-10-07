import AppKit
@testable import IslandEngine
import OpenIslandCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// A session sent to the island, as the app shows it (P1300 to P1312): its card from the engine's fold, the list without
/// it, Send to island where the tab is known (the row's menu and hover button, the island's S, the system-wide key), the
/// card's line, the stack and the card's actions. Every send goes to the demo feed's recorder; nothing is tucked, typed
/// or opened.
@MainActor
struct FoldCardTests {
    typealias ID = FoldFixtures.ID

    @Test
    func aFoldedSessionLeavesTheListButKeepsCounting() throws {
        let feed = FoldFixtures.feed(folded: [ID.idle])
        let env = FoldFixtures.env(feed)
        let row = try #require(env.sessions.row(id: ID.idle))
        #expect(row.isFolded && !row.canFold)
        // Not among the island's rows (its card stands for it), still among the model's, so every count and the pill
        // still tell of it.
        let layout = IslandListLayout.make(rows: env.sessions.rows, style: .clean, showAll: true, now: env.sessions.now)
        #expect(!layout.shown.contains { $0.id == ID.idle })
        #expect(env.sessions.rows.contains { $0.id == ID.idle })
        let card = try #require(env.sessions.folded.first)
        #expect(env.sessions.folded.map(\.sessionID) == [ID.idle])
        #expect(card.message == FoldFixtures.idleMessage && card.reach == .tab && !card.working && card.held == nil)
        #expect(FoldedCardView.showsField(card))
    }

    @Test
    func theCardFollowsWhereItsSessionIs() throws {
        let feed = FoldFixtures.feed(folded: [ID.working, ID.held, ID.sending, ID.notSent, ID.gone])
        let env = FoldFixtures.env(feed)
        func card(_ id: String) throws -> FoldedCardModel { try #require(env.sessions.foldedCard(id)) }
        // A turn that runs keeps the answer before it on show.
        #expect(try card(ID.working).working && card(ID.working).message == FoldFixtures.workingMessage)
        #expect(try card(ID.held).held == "then push the branch")
        #expect(try card(ID.sending).send == .sending && !FoldedCardView.showsField(card(ID.sending)))
        #expect(try card(ID.notSent).send == .notSent)
        // Its tab closed and its session ended: no list shows it, its card stays, and with no resume it only opens.
        let gone = try card(ID.gone)
        #expect(gone.reach == .openOnly && !FoldedCardView.showsField(gone) && gone.row.agent == .codex)
        #expect(env.sessions.row(id: ID.gone) == nil)
        #expect(FoldedCardLine.openTitle(gone) == "Open in terminal to reply")
        #expect(FoldedCardLine.openTitle(try card(ID.working)) == "Open in terminal")
        // Newest first: the last one sent.
        #expect(env.sessions.folded.first?.sessionID == ID.gone)
    }

    /// Upstream's metadata can come without the last answer once a new turn starts: the card keeps the one it showed.
    @Test
    func theLastAnswerStaysWhileTheNextTurnRuns() async throws {
        let feed = FoldFixtures.feed(folded: [ID.idle])
        let env = FoldFixtures.env(feed)
        #expect(env.sessions.foldedCard(ID.idle)?.message == FoldFixtures.idleMessage)
        feed.engine.loadPreviewEvents([
            .activityUpdated(SessionActivityUpdated(sessionID: ID.idle, summary: FixtureSessionFeed.promptPrefix + "open the PR",
                                                    phase: .running, timestamp: feed.now)),
            .claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: ID.idle, claudeMetadata: ClaudeSessionMetadata(
                lastUserPrompt: "open the PR", currentTool: "Bash", currentToolInputPreview: "gh pr create"), timestamp: feed.now)),
        ])
        try await Self.until { env.sessions.foldedCard(ID.idle)?.working == true }
        #expect(env.sessions.foldedCard(ID.idle)?.message == FoldFixtures.idleMessage)
    }

    @Test
    func aGoneTabWithTheResumeTakesARepliesAndSaysItsNote() throws {
        let resume = FoldFixtures.Resume(offer: .resume(note: "Codex runs this without asking, within its sandbox."))
        let env = FoldFixtures.env(FoldFixtures.feed(folded: [ID.gone], resume: resume))
        let card = try #require(env.sessions.foldedCard(ID.gone))
        #expect(card.reach == .resume && card.note == "Codex runs this without asking, within its sandbox.")
        #expect(FoldedCardView.showsField(card) && FoldedCardLine.left(card, row: card.row) == .note(card.note!))
        // While the island's run of it is under way: Working, with Stop.
        let running = FoldFixtures.Resume(offer: .resume(note: nil))
        running.running = [ID.gone]
        let mapped = try #require(FoldFixtures.env(FoldFixtures.feed(folded: [ID.gone], resume: running)).sessions.foldedCard(ID.gone))
        #expect(mapped.stoppable && mapped.working && mapped.note == nil)
    }

    @Test
    func theLineSaysWhatMattersMost() throws {
        let env = FoldFixtures.env(FoldFixtures.feed(folded: [ID.idle]))
        var card = try #require(env.sessions.folded.first)
        let row = card.row
        #expect(FoldedCardLine.left(card, row: row) == .none)
        card.working = true
        #expect(FoldedCardLine.left(card, row: row) == .working(inTerminal: nil))
        card.note = "Not opened"
        #expect(FoldedCardLine.left(card, row: row) == .note("Not opened"))
        var waiting = row
        waiting.hasCard = true
        #expect(FoldedCardLine.left(card, row: waiting) == .waits)
        card.send = .notSent
        #expect(FoldedCardLine.left(card, row: waiting) == .send(.notSent))
        card.held = "later"
        #expect(FoldedCardLine.left(card, row: waiting) == .held("later"))
    }

    /// P1358: the held reply's own text is on the line, a second reply joined to it.
    @Test
    func theHeldReplysTextIsOnTheLine() async throws {
        let feed = FoldFixtures.feed(folded: [ID.working])
        let env = FoldFixtures.env(feed)
        env.sessions.replyFolded(ID.working, text: "run the tests")
        try await Self.until { feed.engine.folds[ID.working]?.held != nil }
        env.sessions.replyFolded(ID.working, text: "and push if green")
        try await Self.until { feed.engine.folds[ID.working]?.held == "run the tests and push if green" }
        let card = try #require(env.sessions.foldedCard(ID.working))
        #expect(FoldedCardLine.left(card, row: card.row) == .held("run the tests and push if green"))
        #expect(feed.sentReplies.isEmpty)
    }

    /// P1356, P1359: a held reply that did not go is back for the field, and the line says why; the resume's note (Codex's
    /// line) goes first, as it must be read before a Return runs Codex.
    @Test
    func aReplyThatCameBackSaysWhyAndCodexsLineGoesFirst() async throws {
        let feed = FoldFixtures.feed(folded: [ID.idle, ID.gone], resume: FoldFixtures.Resume(offer: .resume(note: SessionResumer.codexNote)))
        let env = FoldFixtures.env(feed)
        feed.engine.folds[ID.idle]?.returned = ReturnedReply(text: "open the PR", why: .tabInFront)
        var card = try #require(env.sessions.foldedCard(ID.idle))
        #expect(card.returned == "open the PR" && card.unsent == "Not sent · its tab was in front")
        #expect(FoldedCardLine.left(card, row: card.row) == .unsent("Not sent · its tab was in front"))
        #expect(FoldedCardView.showsField(card))
        // The next Return sends it and the words go.
        env.sessions.replyFolded(ID.idle, text: "open the PR")
        try await Self.until { feed.engine.folds[ID.idle]?.returned == nil }
        card = try #require(env.sessions.foldedCard(ID.idle))
        #expect(card.returned == nil && card.unsent == nil)
        #expect(feed.sentReplies.map(\.text) == ["open the PR"])
        feed.engine.folds[ID.gone]?.returned = ReturnedReply(text: "also delete the build folder", why: .wayChanged)
        let gone = try #require(env.sessions.foldedCard(ID.gone))
        #expect(gone.unsent == "Not sent · its tab closed" && gone.returned == "also delete the build folder")
        #expect(FoldedCardLine.left(gone, row: gone.row) == .note(SessionResumer.codexNote))
        #expect(EngineSessionsModel.unsentWords(.wayChanged, reach: .tab) == "Not sent · its tab is back")
        #expect(EngineSessionsModel.unsentWords(.wayChanged, reach: .openOnly) == "Not sent")
    }

    /// P1355: upstream's monitor drops the ended session on its next pass; its card stays, drawn from the fold's copy.
    @Test
    func aFoldedCardOutlastsTheMonitorDroppingItsSession() throws {
        let resume = FoldFixtures.Resume(offer: .resume(note: nil))
        let feed = FoldFixtures.feed(folded: [ID.gone], resume: resume)
        let env = FoldFixtures.env(feed)
        let before = try #require(env.sessions.foldedCard(ID.gone))
        // The pass as upstream's monitor leaves it: the ended session gone (the demo's sessions are never invisible).
        feed.engine.applyMonitoredState(SessionState(sessions: feed.engine.state.sessions.filter { $0.id != ID.gone }))
        #expect(feed.engine.state.session(id: ID.gone) == nil)
        let card = try #require(env.sessions.foldedCard(ID.gone))
        #expect(card.message == FoldFixtures.codexMessage && card.row.task == before.row.task && card.row.agent == .codex)
        #expect(card.reach == .resume && FoldedCardView.showsField(card))
    }

    /// Why a resumed reply did not go, or its run failed, takes the note's place; a reply that did not go keeps its Retry
    /// (P1352). Only where the reply goes on through the resume, and only once this fold tried one.
    @Test
    func theResumesProblemTakesTheNotesPlace() throws {
        let resume = FoldFixtures.Resume(offer: .resume(note: "Codex runs this without asking, within its sandbox."))
        resume.problems[ID.gone] = "Failed · usage limit reached"
        let feed = FoldFixtures.feed(folded: [ID.gone], resume: resume)
        let env = FoldFixtures.env(feed)
        // A problem from before this fold is not this card's.
        var card = try #require(env.sessions.foldedCard(ID.gone))
        #expect(card.problem == nil && card.note == "Codex runs this without asking, within its sandbox.")
        feed.engine.folds[ID.gone]?.resumed = true
        card = try #require(env.sessions.foldedCard(ID.gone))
        #expect(card.problem == "Failed · usage limit reached" && card.note == nil)
        #expect(FoldedCardLine.left(card, row: card.row) == .problem("Failed · usage limit reached", retry: false))
        card.send = .notSent
        #expect(FoldedCardLine.left(card, row: card.row) == .problem("Failed · usage limit reached", retry: true))
        card.send = .sending
        #expect(FoldedCardLine.left(card, row: card.row) == .send(.sending))
        card.send = nil
        card.held = "later"
        #expect(FoldedCardLine.left(card, row: card.row) == .held("later"))
        // Its tab back, or nowhere to reply: no problem line.
        resume.offer = .openOnly
        #expect(env.sessions.foldedCard(ID.gone)?.problem == nil)
    }

    @Test
    func theStackOpensTheNewestUnlessAnotherWasChosen() throws {
        let env = FoldFixtures.env(FoldFixtures.feed(folded: [ID.held, ID.idle, ID.working]))
        let cards = env.sessions.folded
        #expect(cards.map(\.sessionID) == [ID.working, ID.idle, ID.held])
        #expect(FoldedStackView.open(cards, chosen: nil) == ID.working)
        #expect(FoldedStackView.open(cards, chosen: ID.held) == ID.held)
        #expect(FoldedStackView.open(cards, chosen: "gone") == ID.working)
        #expect(FoldedStackView.open([], chosen: nil) == nil)
    }

    // MARK: Send to island

    @Test
    func sendToIslandIsOfferedOnlyWhereTheTabIsKnownAndOnlyInIslandMode() throws {
        let env = FoldFixtures.env(FoldFixtures.feed(folded: [ID.working]))
        let idle = try #require(env.sessions.row(id: ID.idle))
        let folded = try #require(env.sessions.row(id: ID.working))
        #expect(env.offersSendToIsland(idle) && !env.offersSendToIsland(folded))
        #expect(SessionMenuModel.groups(idle, card: nil, sends: env.offersSendToIsland(idle)).first == [.jump, .sendToIsland])
        #expect(SessionMenuModel.groups(folded, card: nil, sends: env.offersSendToIsland(folded)).first == [.jump])
        #expect(SessionMenuItem.sendToIsland.title == "Send to island")
        env.settings.showAs = .window
        #expect(!env.offersSendToIsland(idle))
        // A tab that is not known exactly (Warp, an editor, a session whose agent the notes never named) has none.
        let demo = AppEnvironment.demo(settings: .ephemeral())
        demo.settings.showAs = .island
        for row in demo.sessions.rows where row.id != FixtureSessionFeed.ID.claudeDone {
            #expect(!row.canFold, "\(row.id)")
        }
    }

    @Test
    func theMenuSendsOnlyARowThatCanFold() throws {
        let env = FoldFixtures.env(FoldFixtures.feed(folded: [ID.working]))
        var sent: [String] = []
        let performer = SessionMenuPerformer(sessions: env.sessions, jump: { _ in }, pasteboard: NSPasteboard(name: .init("juice-fold-test")),
                                             openFolder: { _ in }, sendToIsland: { sent.append($0) })
        performer.perform(.sendToIsland, row: try #require(env.sessions.row(id: ID.idle)), card: nil)
        performer.perform(.sendToIsland, row: try #require(env.sessions.row(id: ID.working)), card: nil)
        #expect(sent == [ID.idle])
    }

    @Test
    func sOverTheListSendsTheKeysRow() {
        let s = IslandKeyPress(characters: "s")
        #expect(IslandKeyRouter.command(for: s, card: nil, listing: true) == .sendSelection)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "S", shift: true), card: nil, listing: true) == .sendSelection)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "s", isRepeat: true), card: nil, listing: true) == .swallow)
        // Typing in a field, over a card, or with every key off: the S is not Send to island's.
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "s", editing: true), card: nil, listing: true) == nil)
        #expect(IslandKeyRouter.command(for: s, card: nil, listing: false) == nil)
        var off = CardKeys.standard
        off.enabled = false
        #expect(IslandKeyRouter.command(for: s, card: nil, listing: true, keys: off) == nil)
        #expect(ShortcutsPane.localKeys.contains { $0 == ("Send a session to the island", "S") })
    }

    @Test
    func theSystemWideKeyCanSendTheTabInFront() {
        #expect(GlobalKeyAction.send.title == "Send to island")
        #expect(GlobalKeyAction.send.detail == "The agent's tab in front folds into the island.")
        #expect(GlobalKeyAction(rawValue: "send") == .send)
    }

    // MARK: The card's actions

    @Test
    func aReplyAtThePromptIsTypedIntoItsTerminalTab() async throws {
        let feed = FoldFixtures.feed(folded: [ID.idle])
        let env = FoldFixtures.env(feed)
        env.sessions.replyFolded(ID.idle, text: "open the PR")
        try await Self.until { !feed.sentReplies.isEmpty }
        #expect(feed.sentReplies.map(\.text) == ["open the PR"])
        #expect(feed.sentReplies.map(\.route) == [.terminal(tty: "/dev/ttys301")])
    }

    @Test
    func aReplyWhileItWorksIsHeldAndCancelled() async throws {
        let feed = FoldFixtures.feed(folded: [ID.working])
        let env = FoldFixtures.env(feed)
        env.sessions.replyFolded(ID.working, text: "and the docs")
        try await Self.until { feed.engine.folds[ID.working]?.held != nil }
        #expect(env.sessions.foldedCard(ID.working)?.held == "and the docs" && feed.sentReplies.isEmpty)
        env.sessions.cancelHeld(ID.working)
        #expect(env.sessions.foldedCard(ID.working)?.held == nil)
    }

    @Test
    func sendingFoldsHeadlessWithNoWindowAndTheDemoOnlyNotesItsOpen() async throws {
        let feed = FoldFixtures.feed(folded: [])
        let env = FoldFixtures.env(feed)
        #expect(await env.sessions.sendToIsland(ID.idle) == nil)
        #expect(env.sessions.row(id: ID.idle)?.isFolded == true)
        env.sessions.openFolded(ID.idle)
        #expect(env.sessions.folded.isEmpty)
        #expect(env.sessions.jumpNote?.text == JumpNote.demo)
        _ = await env.sessions.sendToIsland(ID.idle)
        env.sessions.unfold(ID.idle)
        #expect(env.sessions.folded.isEmpty && env.sessions.row(id: ID.idle)?.isFolded == false)
    }

    /// Waits for `condition`, a turn at a time, for at most 2 s.
    static func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    // MARK: A window closed mid-turn (P1415 to P1419)

    /// Its card says so in one line, keeps the last answer, and offers Continue with the words it sends, shown before the
    /// click; with no resume, Open in terminal to continue.
    @Test
    func aStoppedSessionsCardSaysSoAndOffersContinue() throws {
        let env = FoldFixtures.env(FoldFixtures.feed(folded: [ID.stopped], resume: FoldFixtures.Resume(offer: .resume(note: nil))))
        let card = try #require(env.sessions.foldedCard(ID.stopped))
        #expect(card.stopped == "Stopped when its window closed" && card.continuePrompt == "Continue where you left off.")
        #expect(card.message?.hasPrefix("Split the retries out of the client") == true && !card.working && card.reach == .resume)
        #expect(FoldedCardLine.left(card, row: card.row) == .stopped("Stopped when its window closed"))
        // Open in terminal carries the turn on in the new window, and says so (P1439).
        #expect(FoldedCardView.showsField(card) && FoldedCardLine.openTitle(card) == "Continue in terminal")
        #expect(FoldedCardLine.openHelp(card) == "Open it in a new window and send “Continue where you left off.”")
        // Nothing to resume it with: no Continue, and Open in terminal says what it is for.
        let open = try #require(FoldFixtures.env(FoldFixtures.feed(folded: [ID.stopped])).sessions.foldedCard(ID.stopped))
        #expect(open.reach == .openOnly && open.continuePrompt == nil && !FoldedCardView.showsField(open))
        #expect(FoldedCardLine.openTitle(open) == "Open in terminal to continue")
        #expect(FoldedCardLine.left(open, row: open.row) == .stopped("Stopped when its window closed"))
    }

    /// Codex's note shows under Continue, before the click that runs it without asking (P1304, P1419).
    @Test
    func codexsNoteShowsBeforeContinue() throws {
        let feed = FoldFixtures.feed(folded: [ID.gone], resume: FoldFixtures.Resume(offer: .resume(note: SessionResumer.codexNote)))
        FoldFixtures.stop(feed.engine, ID.gone)
        let card = try #require(FoldFixtures.env(feed).sessions.foldedCard(ID.gone))
        #expect(card.continuePrompt != nil && card.note == SessionResumer.codexNote && card.stopped != nil)
    }

    /// Continue on the card goes through the resume with the shown words; the card then reads Working, with Stop.
    @Test
    func continueOnTheCardCarriesItOn() async throws {
        let resume = FoldFixtures.Resume(offer: .resume(note: nil))
        let feed = FoldFixtures.feed(folded: [ID.stopped], resume: resume)
        let env = FoldFixtures.env(feed)
        env.sessions.continueFolded(ID.stopped)
        try await Self.until { feed.engine.folds[ID.stopped]?.stopped == nil }
        #expect(resume.continued.map(\.1) == ["Continue where you left off."] && resume.continued.first?.0 == ID.stopped)
        resume.running = [ID.stopped]
        feed.engine.folds[ID.stopped]?.send = nil
        let card = try #require(env.sessions.foldedCard(ID.stopped))
        #expect(card.working && card.stoppable && card.continuePrompt == nil && card.stopped == nil)
        #expect(FoldedCardLine.left(card, row: card.row) == .working(inTerminal: nil))
        // While it held a reply, or one was on its way, Continue is not offered.
        feed.engine.folds[ID.stopped]?.stopped = FoldStop(at: feed.now, windowClosed: true, why: .processEnded)
        resume.running = []
        feed.engine.folds[ID.stopped]?.held = "later"
        #expect(env.sessions.foldedCard(ID.stopped)?.continuePrompt == nil)
    }

    // MARK: Codex's background service (P1485 to P1509)

    /// A session Codex's background service runs folds once the service says it holds its thread, tucks nothing, and
    /// reads Working while a turn runs there, whatever became of its window; its note shows at idle; the island's own
    /// turn there has Stop; Open in terminal joins the thread in a new window.
    @Test
    func codexsBackgroundServiceKeepsTheCardWorkingAndTakesTheReply() throws {
        let feed = FoldFixtures.feed(folded: [ID.daemon], resume: FoldFixtures.daemonResume(.active(waitsOnYou: false)))
        let env = FoldFixtures.env(feed)
        #expect(feed.engine.folds[ID.daemon]?.tucked == false && feed.engine.runsInCodexService(ID.daemon))
        let card = try #require(env.sessions.foldedCard(ID.daemon))
        #expect(card.reach == .daemon && card.working && !card.stoppable && card.note == nil && !card.finishing)
        #expect(FoldedCardLine.left(card, row: card.row) == .working(inTerminal: nil) && FoldedCardView.showsField(card))
        #expect(FoldedCardLine.openTitle(card) == "Open in terminal" && FoldedCardLine.openHelp(card) == "Open the conversation in a terminal")
        // At idle: the note says where a reply goes.
        let resume = try #require(feed.engine.conversationResume as? FoldFixtures.Resume)
        resume.service[ID.daemon] = .idle
        FoldFixtures.endTurn(feed.engine, ID.daemon)
        let idle = try #require(env.sessions.foldedCard(ID.daemon))
        #expect(!idle.working && idle.note == SessionResumer.serviceNote && FoldedCardLine.left(idle, row: idle.row) == .note(SessionResumer.serviceNote))
        // The island's own turn there: Working with Stop.
        resume.running = [ID.daemon]
        resume.service[ID.daemon] = .active(waitsOnYou: false)
        let island = try #require(env.sessions.foldedCard(ID.daemon))
        #expect(island.working && island.stoppable && !island.finishing)
        // Not held by the service: nothing to fold.
        let notHeld = FoldFixtures.feed(folded: [ID.daemon], resume: FoldFixtures.daemonResume(.notHeld))
        #expect(notHeld.engine.folds[ID.daemon] == nil && !notHeld.engine.canFold(sessionID: ID.daemon))
    }

    /// Continue, or a reply, that met a turn still running there says so in one line, never as a failure (P1488), until
    /// that turn ends; a stopped card there offers Continue and Continue in terminal.
    @Test
    func continueThatMetTheServicesTurnSaysItIsStillFinishing() throws {
        let resume = FoldFixtures.daemonResume(.active(waitsOnYou: false))
        let feed = FoldFixtures.feed(folded: [ID.daemon], resume: resume)
        let env = FoldFixtures.env(feed)
        resume.problems[ID.daemon] = SessionResumer.finishingWords
        feed.engine.folds[ID.daemon]?.resumed = true
        let card = try #require(env.sessions.foldedCard(ID.daemon))
        #expect(card.finishing && card.problem == nil && card.working)
        #expect(FoldedCardLine.left(card, row: card.row) == .finishing)
        // Its turn ended there: the words go.
        resume.service[ID.daemon] = .idle
        FoldFixtures.endTurn(feed.engine, ID.daemon)
        let ended = try #require(env.sessions.foldedCard(ID.daemon))
        #expect(!ended.finishing && ended.problem == nil && !ended.working)
        // Stopped there (its hooks said the turn ended while its window closed): Continue, carried on in a new window.
        FoldFixtures.stop(feed.engine, ID.daemon)
        let stopped = try #require(env.sessions.foldedCard(ID.daemon))
        #expect(stopped.continuePrompt == SessionEngine.continuePrompt && FoldedCardLine.openTitle(stopped) == "Continue in terminal")
    }

    /// While a folded session works and its window sits in the Dock, the line says the window still holds the run.
    @Test
    func workingInTerminalWhileItsWindowSitsInTheDock() throws {
        let feed = FoldFixtures.feed(folded: [ID.working])
        let env = FoldFixtures.env(feed)
        #expect(env.sessions.foldedCard(ID.working)?.inTerminal == nil)
        feed.engine.folds[ID.working]?.tucked = true
        let card = try #require(env.sessions.foldedCard(ID.working))
        #expect(card.inTerminal == "Terminal" && FoldedCardLine.left(card, row: card.row) == .working(inTerminal: "Terminal"))
    }

    /// Copy Report's fold section (P1430): each decision's time, the id cut to 8 characters, and its words; none when the
    /// fold decided nothing.
    @Test
    func copyReportHasAShortFoldSection() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let notes = [FoldNote(at: at, sessionID: "8f2c3a1e-5b7d-4a6b-9c1d-2e3f4a5b6c7d", said: "stopped mid-turn · its window closed · its agent's process ended"),
                     FoldNote(at: at, sessionID: "8f2c3a1e-5b7d-4a6b-9c1d-2e3f4a5b6c7d", said: "Continue")]
        let lines = DiagnosticsText.folds(notes)
        #expect(lines == ["\(DiagnosticsText.hhmm(at)) 8f2c3a1e stopped mid-turn · its window closed · its agent's process ended",
                          "\(DiagnosticsText.hhmm(at)) 8f2c3a1e Continue"])
        let report = DiagnosticsText.report(lines: [], money: [], folds: lines)
        #expect(report.hasSuffix("\nIsland folds\n  " + lines.joined(separator: "\n  ")))
        #expect(!DiagnosticsText.report(lines: [], money: []).contains("Island folds"))
    }
}
