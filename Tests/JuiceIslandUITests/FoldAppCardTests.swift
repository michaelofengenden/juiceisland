import AppKit
@testable import IslandEngine
import Observation
import Testing
@testable import JuiceIslandUI

/// Open in <App> on a folded card and a row's menu (wave 8, P1510 to P1519): what the card offers and says, at most two
/// actions on its line, no field while an app holds the conversation, and the menu's item. The demo's headless engine:
/// nothing is run, typed or opened.
@MainActor
struct FoldAppCardTests {
    typealias ID = FoldFixtures.ID
    typealias Line = FoldedCardLine

    static func card(_ id: String, folded: [String]? = nil, states: [String: HandoffState] = [:]) throws -> (AppEnvironment, FoldedCardModel) {
        let feed = FoldFixtures.feed(folded: folded ?? [id])
        FoldFixtures.handoff(feed, states: states)
        let env = FoldFixtures.env(feed)
        return (env, try #require(env.sessions.foldedCard(id)))
    }

    @Test
    func aCardAtItsPromptOffersOpenInClaudeBesideOpenInTerminal() throws {
        let (_, card) = try Self.card(ID.app)
        #expect(card.app == FoldedAppModel(app: .claude, state: .offered, offered: true))
        #expect(Line.showsAppLink(card) && Line.showsOpen(card))
        #expect(card.app?.title == "Open in Claude")
        // Offered, it says nothing on the left: the link is enough.
        if case .app = Line.left(card, row: card.row) { Issue.record("an offer has no words") }
        #expect(FoldedCardView.showsField(card))
    }

    @Test
    func stopTakesTheAppsPlaceOnTheLineSoTwoShowAtMost() throws {
        let (_, offered) = try Self.card(ID.app)
        var running = offered
        running.stoppable = true
        #expect(!Line.showsAppLink(running) && Line.showsOpen(running))
    }

    @Test
    func aPendingHandOverSaysSoWithCancelAndTakesTheFieldAway() throws {
        let (_, card) = try Self.card(ID.working, states: [ID.working: .pending(.claude)])
        #expect(Line.left(card, row: card.row) == .app("Opens in Claude when this turn ends", warns: false, cancel: true))
        #expect(!FoldedCardView.showsField(card) && !Line.showsAppLink(card) && Line.showsOpen(card))
    }

    @Test
    func whileClaudeHoldsItTheFieldGoesAndOpenInTerminalIsTheWayBack() throws {
        let (_, card) = try Self.card(ID.idle, states: [ID.idle: .inApp(.claude, note: nil)])
        #expect(card.reach == .openOnly && !FoldedCardView.showsField(card))
        #expect(Line.left(card, row: card.row) == .app("In Claude", warns: false, cancel: false))
        #expect(Line.openTitle(card) == "Open in terminal" && Line.showsOpen(card) && !Line.showsAppLink(card))
        #expect(card.continuePrompt == nil)
        let (_, held) = try Self.card(ID.idle, states: [ID.idle: .inApp(.claude, note: HandoffWords.quitApp("Claude"))])
        #expect(Line.left(held, row: held.row) == .app("Quit Claude first", warns: true, cancel: false))
    }

    @Test
    func anAppThatPicksItLeavesNoOpenInTerminal() throws {
        let (_, offered) = try Self.card(ID.openCode)
        #expect(offered.app?.title == "Open in OpenCode" && Line.showsAppLink(offered))
        let (_, card) = try Self.card(ID.openCode, states: [ID.openCode: .pick(.opencode)])
        #expect(Line.left(card, row: card.row) == .app("Pick this session in OpenCode", warns: false, cancel: false))
        #expect(!Line.showsOpen(card) && !Line.showsAppLink(card) && !FoldedCardView.showsField(card))
    }

    @Test
    func aRefusalWarnsAndCanBeClickedAgain() throws {
        let (_, card) = try Self.card(ID.app, states: [ID.app: .blocked(.claude, HandoffWords.updateClaude)])
        #expect(Line.left(card, row: card.row) == .app("Update Claude Code to open this in Claude", warns: true, cancel: false))
        // The words take the link's place on the line; the header's menu offers it again.
        #expect(!Line.showsAppLink(card) && FoldedCardView.showsField(card) && card.row.appOffer == "Open in Claude")
    }

    @Test
    func whileItOpensNeitherLinkShows() throws {
        let (_, card) = try Self.card(ID.idle, states: [ID.idle: .opening(.claude)])
        #expect(Line.left(card, row: card.row) == .app("Opening in Claude…", warns: false, cancel: false))
        #expect(!Line.showsOpen(card) && !Line.showsAppLink(card))
    }

    @Test
    func theRowsMenuOffersItAfterSendToIslandAndAsksTheModel() throws {
        let feed = FoldFixtures.feed(folded: [ID.app])
        FoldFixtures.handoff(feed)
        let env = FoldFixtures.env(feed)
        let row = try #require(env.sessions.row(id: ID.app))
        #expect(row.appOffer == "Open in Claude")
        #expect(SessionMenuModel.groups(row, card: nil, sends: true).first == [.jump, .sendToIsland, .openInApp("Open in Claude")])
        let spy = AppSpy(env.sessions)
        SessionMenuPerformer(sessions: spy, jump: { _ in }).perform(.openInApp("Open in Claude"), row: row, card: nil)
        #expect(spy.opened == [ID.app])
        // A row with nothing to offer asks nothing.
        var none = row
        none.appOffer = nil
        SessionMenuPerformer(sessions: spy, jump: { _ in }).perform(.openInApp("Open in Claude"), row: none, card: nil)
        #expect(spy.opened == [ID.app])
        // Another agent's session, or one whose app cannot open it, offers nothing.
        #expect(env.sessions.row(id: ID.idle)?.appOffer == nil)
    }

    @Test
    func theDemoOpensNothing() throws {
        let feed = FoldFixtures.feed(folded: [ID.app])
        let handoff = FoldFixtures.handoff(feed)
        let env = FoldFixtures.env(feed)
        env.sessions.openInApp(ID.app)
        #expect(handoff.state(for: ID.app) == nil)
    }
}

/// Records Open in <App>, over a real model's rows.
@MainActor
@Observable
final class AppSpy: SessionsModel {
    let inner: any SessionsModel
    var opened: [String] = []

    init(_ inner: any SessionsModel) { self.inner = inner }

    var rows: [SessionRow] { inner.rows }
    var now: Date { inner.now }
    func card(for sessionID: String) -> SessionCard? { inner.card(for: sessionID) }
    func approve(_ sessionID: String, _ decision: ApprovalDecision, request: String?) {}
    func answerQuestion(_ sessionID: String, _ input: QuestionInput, request: String?) -> Bool { false }
    func reply(_ sessionID: String, text: String) {}
    func jump(_ sessionID: String) {}
    func jumpToNextNeedsYou() {}
    func dismiss(_ sessionID: String) {}
    func openInApp(_ sessionID: String) { opened.append(sessionID) }
}
