import Foundation
@testable import IslandEngine
import Testing
@testable import JuiceIslandUI

/// The folded card as one design across wave 8's three lanes (P1535): at most two of Continue, Stop, Open in <App> and
/// Open in terminal show at once, whatever the card is at (its tab, the resume, Claude Code's background, Codex's
/// daemon, an app); Open in <App> goes to the header's menu whenever anything else on the card asks for a click; and a
/// background card shows no Stop while an app holds or takes its conversation. Headless, on the fold fixtures: nothing
/// is run, typed or opened.
@MainActor
struct FoldCardActionsTests {
    typealias ID = FoldFixtures.ID
    typealias Line = FoldedCardLine

    /// The actions a card shows outside its line's words: Continue, Stop, Open in <App>, Open in terminal.
    static func actions(_ card: FoldedCardModel) -> [String] {
        var shown: [String] = []
        if card.continuePrompt != nil { shown.append("Continue") }
        if card.stoppable { shown.append("Stop") }
        if Line.showsAppLink(card), let app = card.app { shown.append(app.title) }
        if Line.showsOpen(card) { shown.append(Line.openTitle(card)) }
        return shown
    }

    static func card(_ id: String, states: [String: HandoffState] = [:], background: FoldBackground? = nil) throws -> FoldedCardModel {
        let feed = FoldFixtures.feed(folded: [id], resume: FoldFixtures.Resume(offer: .resume(note: nil)))
        FoldFixtures.handoff(feed, states: states)
        if let background { feed.engine.folds[id]?.background = background }
        let env = FoldFixtures.env(feed)
        return try #require(env.sessions.foldedCard(id))
    }

    /// The card, when the fixture folds alone.
    static func cardIfFolded(_ id: String, states: [String: HandoffState], background: FoldBackground?) -> FoldedCardModel? {
        let feed = FoldFixtures.feed(folded: [id], resume: FoldFixtures.Resume(offer: .resume(note: nil)))
        FoldFixtures.handoff(feed, states: states)
        if let background { feed.engine.folds[id]?.background = background }
        return FoldFixtures.env(feed).sessions.foldedCard(id)
    }

    static func moved(stopped: Bool = false) -> FoldBackground {
        var background = FoldBackground(stage: .moved, shortID: "0ca371e5", profile: NSHomeDirectory() + "/.claude", folder: "/tmp/juice-island")
        background.stoppedByOwner = stopped
        return background
    }

    /// Every card the fixtures make, in every hand-over state, and as a background card: never more than two actions.
    @Test
    func noCardShowsMoreThanTwoActions() throws {
        let states: [HandoffState?] = [nil, .pending(.claude), .opening(.claude), .inApp(.claude, note: nil),
                                       .inApp(.claude, note: HandoffWords.quitApp("Claude")), .pick(.opencode),
                                       .blocked(.claude, HandoffWords.updateClaude)]
        let ids = [ID.idle, ID.working, ID.held, ID.sending, ID.sent, ID.notSent, ID.gone, ID.long, ID.waits, ID.stopped, ID.app, ID.openCode]
        var checked = Set<String>()
        for id in ids {
            for state in states {
                for background in [nil, Self.moved(), Self.moved(stopped: true)] {
                    // A fixture that folds only beside others (its scene's) is left out here.
                    guard var card = Self.cardIfFolded(id, states: state.map { [id: $0] } ?? [:], background: background) else { continue }
                    checked.insert(id)
                    #expect(Self.actions(card).count <= 2, "\(id) \(String(describing: state)): \(Self.actions(card))")
                    // Continue offers to carry on a stopped turn, so no run is under way beside it.
                    #expect(card.continuePrompt == nil || !card.stoppable)
                    // A run the island holds, on top of whatever else it is at.
                    guard card.continuePrompt == nil else { continue }
                    card.stoppable = true
                    #expect(Self.actions(card).count <= 2, "\(id) \(String(describing: state)) running: \(Self.actions(card))")
                }
            }
        }
        #expect(checked.count >= 9, "\(checked.sorted())")
    }

    /// Open in <App> is on the line only while nothing else asks for a click there; otherwise the header's menu has it.
    @Test
    func openInAppGoesToTheMenuWhileAnythingElseAsksForAClick() throws {
        let quiet = try Self.card(ID.app)
        #expect(Self.actions(quiet) == ["Open in Claude", "Open in terminal"])
        var stopped = quiet
        stopped.continuePrompt = SessionEngine.continuePrompt
        #expect(!Line.showsAppLink(stopped))
        for (held, problem, send) in [("then push", nil, nil), (nil, "Failed · it ended", CardSend.notSent), (nil, nil, CardSend.notSent)]
            as [(String?, String?, CardSend?)] {
            var card = quiet
            card.held = held
            card.problem = problem
            card.send = send
            #expect(!Line.showsAppLink(card), "\(String(describing: Line.left(card, row: card.row)))")
        }
        // The header's menu offers it then (the engine offers nothing while a reply is held: `FoldTogetherRenders`).
        #expect(quiet.row.appOffer == "Open in Claude")
        var running = quiet
        running.stoppable = true
        #expect(Self.actions(running) == ["Stop", "Open in terminal"])
    }

    /// A background card's Stop shows while it runs there, and goes while an app holds or takes its conversation: the
    /// hand-over stops the copy itself, and Claude has it after.
    @Test
    func aBackgroundCardShowsNoStopWhileAnAppHoldsIt() throws {
        let background = try Self.card(ID.app, background: Self.moved())
        #expect(background.stoppable && Self.actions(background) == ["Stop", "Open in terminal"])
        for state in [HandoffState.opening(.claude), .inApp(.claude, note: nil)] {
            let card = try Self.card(ID.app, states: [ID.app: state], background: Self.moved())
            #expect(!card.stoppable, "\(state)")
        }
        // Waiting for its turn's end, Stop stays: it ends that turn, and the hand-over goes then.
        let pending = try Self.card(ID.app, states: [ID.app: .pending(.claude)], background: Self.moved())
        #expect(pending.stoppable && Self.actions(pending) == ["Stop", "Open in terminal"])
    }
}
