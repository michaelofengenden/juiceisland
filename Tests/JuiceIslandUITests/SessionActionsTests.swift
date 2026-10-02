import AppKit
import Foundation
import IslandEngine
import Observation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Lane c11/actions: a session's right-click menu (P320), the keys' row in the island and the window (P321), a held
/// Return (P322) and the system-wide key's Open action (P323). Pure routing and models only: no panel or window is
/// ordered in, no menu pops up, the clipboard is a private pasteboard and the Finder a spy.
@MainActor
struct SessionActionsTests {
    typealias ID = FixtureSessionFeed.ID
    typealias WindowKey = WindowKeyRouter.KeyPress

    // MARK: The menu (P320)

    @Test
    func theMenuOffersWhatTheRowCanDo() {
        let done = Self.row("d", bucket: .done, folder: "/Users/demo/Developer/notes-site")
        #expect(SessionMenuModel.groups(done, card: nil) == [[.jump], [.copyTitle, .copyFolder, .openFolder], [.archive]])
        // No folder known, nothing to archive or stop: the jump and the title only.
        #expect(SessionMenuModel.groups(Self.row("r", bucket: .running), card: nil) == [[.jump], [.copyTitle]])
        // A row whose card waits is never archived, finished or not (P131).
        var failed = Self.row("f", bucket: .done)
        failed.hasCard = true
        #expect(!SessionMenuModel.groups(failed, card: nil).joined().contains(.archive))
        #expect(SessionMenuItem.jump.title == "Jump to session" && SessionMenuItem.openFolder.title == "Open in Finder")
    }

    @Test
    func stopOnlyWhereTheIslandCanStopTheAgentSafely() {
        let held = CardRequest(id: "r1", answerable: true, place: .terminal, agentType: nil, more: 0, isNotice: false, dismissable: false)
        let readOnly = CardRequest(id: "r2", answerable: false, place: .terminal, agentType: nil, more: 0, isNotice: false, dismissable: true)
        let claude = ApprovalCardModel(sessionID: "c", agent: .claude, tool: "Bash", body: .command("ls"), canStop: true, request: held)
        #expect(SessionMenuModel.stop(.approval(claude)) == .init(sessionID: "c", request: "r1"))
        let row = Self.row("c", bucket: .needsYou)
        #expect(SessionMenuModel.groups(row, card: .approval(claude)).last == [.stop])
        // Codex cannot stop from here; a request the island does not hold is answered where it asks; an answer on its way
        // is not answered twice; a question has no stop; a running session has no safe stop at all.
        let codex = ApprovalCardModel(sessionID: "x", agent: .codex, tool: "shell", body: .command("ls"), canStop: false, request: held)
        var shown = claude
        shown.request = readOnly
        var sending = claude
        sending.send = .sending
        let question = QuestionCardModel(sessionID: "q", agent: .claude, question: "Which?", options: [])
        for card in [SessionCard.approval(codex), .approval(shown), .approval(sending), .question(question)] {
            #expect(SessionMenuModel.stop(card) == nil)
        }
        #expect(SessionMenuModel.stop(nil) == nil)
        let plan = PlanCardModel(sessionID: "p", agent: .claude, plan: nil, steps: nil, canStop: true, request: held)
        #expect(SessionMenuModel.stop(.plan(plan)) == .init(sessionID: "p", request: "r1"))
    }

    @Test
    func theMenuCopiesOpensArchivesAndStops() throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        let spy = MenuSpy(env.sessions)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ji-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var opened: [String] = []
        var jumped: [String] = []
        let performer = SessionMenuPerformer(sessions: spy, jump: { jumped.append($0) }, pasteboard: pasteboard,
                                             openFolder: { opened.append($0) })
        let done = try #require(env.sessions.row(id: ID.codexDone))
        let folder = try #require(done.folder)
        #expect(folder.hasSuffix("/Developer/MarathonTrainingLog"))
        performer.perform(.copyTitle, row: done, card: nil)
        #expect(pasteboard.string(forType: .string) == done.task)
        performer.perform(.copyFolder, row: done, card: nil)
        #expect(pasteboard.string(forType: .string) == folder)
        performer.perform(.openFolder, row: done, card: nil)
        #expect(opened == [folder])
        performer.perform(.jump, row: done, card: nil)
        #expect(jumped == [ID.codexDone])
        performer.perform(.archive, row: done, card: nil)
        #expect(spy.dismissed == [ID.codexDone])
        // Archive on a running row does nothing, whoever asks (P131).
        let running = try #require(env.sessions.row(id: ID.running))
        performer.perform(.archive, row: running, card: nil)
        #expect(spy.dismissed == [ID.codexDone])

        // Stop answers the request the menu was built for, No and stop (P170).
        let approval = try #require(env.sessions.row(id: ID.approval))
        let card = env.sessions.card(for: ID.approval)
        guard case let .approval(model)? = card else { Issue.record("no approval card"); return }
        performer.perform(.stop, row: approval, card: card)
        #expect(spy.approvals.count == 1)
        #expect(spy.approvals.first?.decision == .denyAndStop && spy.approvals.first?.request == model.request?.id)
        // A question's row has no stop: nothing is sent.
        let question = try #require(env.sessions.row(id: ID.question))
        performer.perform(.stop, row: question, card: env.sessions.card(for: ID.question))
        #expect(spy.approvals.count == 1)
    }

    @Test
    func rowsCarryTheirFolderFromTheEngine() {
        let env = AppEnvironment.demo(sessions: .allStates)
        #expect(env.sessions.rows.allSatisfy { $0.folder?.hasPrefix(NSHomeDirectory() + "/Developer/") == true })
    }

    // MARK: The keys' row (P321)

    @Test
    func theSelectionMovesAndStopsAtEitherEnd() {
        let ids = ["a", "b", "c"]
        #expect(RowSelection.moved(nil, in: ids, by: 1) == "a")
        #expect(RowSelection.moved(nil, in: ids, by: -1) == "c")
        #expect(RowSelection.moved("a", in: ids, by: 1) == "b")
        #expect(RowSelection.moved("c", in: ids, by: 1) == "c")
        #expect(RowSelection.moved("a", in: ids, by: -1) == "a")
        // A row that left the list starts over.
        #expect(RowSelection.moved("gone", in: ids, by: 1) == "a")
        #expect(RowSelection.moved("a", in: [], by: 1) == nil)
    }

    @Test
    func theIslandsArrowsAndReturnActOnlyOverTheList() {
        let up = IslandKeyPress(characters: IslandKeyRouter.upArrow)
        let down = IslandKeyPress(characters: IslandKeyRouter.downArrow)
        let enter = IslandKeyPress(characters: "\r")
        #expect(IslandKeyRouter.command(for: up, card: nil, listing: true) == .moveSelection(-1))
        #expect(IslandKeyRouter.command(for: down, card: nil, listing: true) == .moveSelection(1))
        #expect(IslandKeyRouter.command(for: enter, card: nil, listing: true) == .openSelection)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "\u{3}"), card: nil, listing: true) == .openSelection)
        // Held ↓ keeps moving; a held Return opens once, and its repeats submit no field of the card it opened (P322).
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: IslandKeyRouter.downArrow, isRepeat: true), card: nil,
                                        listing: true) == .moveSelection(1))
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "\r", isRepeat: true), card: nil, listing: true) == .swallow)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "\r", editing: true, isRepeat: true), card: nil)
            == .swallow)
        // Over a card, in a field being edited, with a modifier, or composing: the keys are not the list's.
        #expect(IslandKeyRouter.command(for: down, card: nil) == nil)
        #expect(IslandKeyRouter.command(for: enter, card: nil, listing: false) == nil)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "\r", editing: true), card: nil, listing: true) == nil)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: IslandKeyRouter.downArrow, shift: true), card: nil,
                                        listing: true) == nil)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: IslandKeyRouter.upArrow, option: true), card: nil,
                                        listing: true) == nil)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "\r", hasMarkedText: true), card: nil, listing: true) == nil)
        // Esc still closes, ⌘Q is still eaten, and the card keys are unchanged.
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "\u{1b}"), card: nil, listing: true) == .close)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "q", command: true), card: nil, listing: true) == .swallow)
        let claude = ApprovalCardModel(sessionID: "c", agent: .claude, tool: "Bash", body: .command("ls"), canStop: true)
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "a", control: true), card: .approval(claude), listing: true)
            == .approve(sessionID: "c", .allowOnce))
    }

    /// P351: over the list a card key acts on the keys' row's card only, and with none selected on the first waiting
    /// row's; over a card, on that card whatever row the keys rest on.
    @Test
    func aCardKeyActsOnTheKeysRowOnly() {
        let env = AppEnvironment.demo(sessions: .allStates)
        #expect(IslandKeyRouter.targetCard(presentation: .list, sessions: env.sessions)?.sessionID == ID.plan)
        let selected = IslandKeyRouter.targetCard(presentation: .list, sessions: env.sessions, selected: ID.approval)
        #expect(selected?.sessionID == ID.approval)
        // ⌃A with the approval's row selected answers it, not the plan above it.
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "a", control: true), card: selected)?.sessionID == ID.approval)
        // A selected row without a card: nothing, never the first waiting card; over a card, only that card.
        #expect(IslandKeyRouter.targetCard(presentation: .list, sessions: env.sessions, selected: ID.running) == nil)
        #expect(IslandKeyRouter.targetCard(presentation: .card(sessionID: ID.question), sessions: env.sessions,
                                           selected: ID.approval)?.sessionID == ID.question)
    }

    @Test
    func theIslandsArrowsWalkTheShownRowsThenShowTheRest() {
        let env = AppEnvironment.demo(sessions: .allStates)
        let shown = RowSelection.islandOrder(env.sessions, style: .clean, showAll: false)
        #expect(shown.shown.map(\.id) == [ID.plan, ID.approval, ID.question, ID.running])
        #expect(shown.showsFooter)
        var move = RowSelection.islandMove(nil, sessions: env.sessions, style: .clean, showAll: false, by: 1)
        #expect(move.row?.id == ID.plan && !move.showsAll)
        move = RowSelection.islandMove(ID.question, sessions: env.sessions, style: .clean, showAll: false, by: 1)
        #expect(move.row?.id == ID.running && !move.showsAll)
        // ↓ from the last row shows the rows behind the footer and moves on to the next.
        move = RowSelection.islandMove(ID.running, sessions: env.sessions, style: .clean, showAll: false, by: 1)
        #expect(move.showsAll && move.row?.id == ID.thinking)
        // ↑ never opens the footer; with every row shown, ↓ stops at the last.
        move = RowSelection.islandMove(ID.running, sessions: env.sessions, style: .clean, showAll: false, by: -1)
        #expect(!move.showsAll && move.row?.id == ID.question)
        let all = RowSelection.islandOrder(env.sessions, style: .clean, showAll: true).shown.map(\.id)
        move = RowSelection.islandMove(all.last, sessions: env.sessions, style: .clean, showAll: true, by: 1)
        #expect(!move.showsAll && move.row?.id == all.last)
        // ↑ with nothing selected starts at the last row shown.
        #expect(RowSelection.islandMove(nil, sessions: env.sessions, style: .clean, showAll: false, by: -1).row?.id == ID.running)
    }

    // MARK: The window's keys (P321)

    @Test
    func theWindowsArrowsAndReturnMapToTheList() {
        #expect(WindowKeyRouter.command(for: WindowKey(character: IslandKeyRouter.upArrow)) == .move(-1))
        #expect(WindowKeyRouter.command(for: WindowKey(character: IslandKeyRouter.downArrow)) == .move(1))
        #expect(WindowKeyRouter.command(for: WindowKey(character: "\r")) == .open)
        #expect(WindowKeyRouter.command(for: WindowKey(character: IslandKeyRouter.downArrow, shift: true)) == nil)
        #expect(WindowKeyRouter.command(for: WindowKey(character: "\r", command: true)) == nil)
        // A field being edited keeps its arrows and Return.
        #expect(!WindowKeyRouter.takesWhileEditing(.move(1)) && !WindowKeyRouter.takesWhileEditing(.open))
        #expect(WindowKeyRouter.isListKey(.move(-1)) && WindowKeyRouter.isListKey(.open))
        #expect(!WindowKeyRouter.isListKey(.escape) && !WindowKeyRouter.isListKey(.decide(.allowOnce)))
        #expect(!WindowKeyRouter.answersACard(.move(1)) && !WindowKeyRouter.answersACard(.open))
    }

    @Test
    func theWindowsSelectionFollowsItsOrderAndReturnJumps() throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        let order = RowSelection.windowOrder(env)
        #expect(order == [ID.approval, ID.question, ID.running, ID.codexRunning, ID.codexIdle, ID.codexDone])
        // Return with nothing selected is left to the window.
        #expect(!WindowKeyRouter.perform(.open, env: env))
        #expect(WindowKeyRouter.perform(.move(1), env: env))
        #expect(env.windowSelection == ID.approval)
        #expect(WindowKeyRouter.perform(.move(1), env: env))
        #expect(WindowKeyRouter.perform(.move(1), env: env))
        #expect(env.windowSelection == ID.running)
        #expect(WindowKeyRouter.perform(.open, env: env))
        let model = try #require(env.sessions as? EngineSessionsModel)
        #expect(model.requestedJumps.last == ID.running)
        // A held Return jumps once.
        #expect(WindowKeyRouter.handle(WindowKey(character: "\r", isRepeat: true), .open, env: env))
        #expect(model.requestedJumps.count == 1)
        // Esc lets the row go first, then leaves Needs you.
        env.windowFilter = .needsYou
        #expect(RowSelection.windowOrder(env) == [ID.approval, ID.question])
        #expect(WindowKeyRouter.perform(.escape, env: env))
        #expect(env.windowSelection == nil && env.windowFilter == .needsYou)
        #expect(WindowKeyRouter.perform(.escape, env: env))
        #expect(env.windowFilter == .all)
        // Nothing listed: the arrows are left alone.
        let empty = AppEnvironment.demo(sessions: .empty)
        #expect(!WindowKeyRouter.perform(.move(1), env: empty))
    }

    @Test
    func theWindowsCardKeysActOnTheSelectedCardFirst() async throws {
        let env = AppEnvironment.demo(sessions: .allStates)
        let feed = try #require(env.fixtureFeed)
        // The plan waits above the approval; with the approval's card selected, ⌃A answers the approval.
        env.windowSelection = ID.approval
        #expect(WindowKeyRouter.perform(.decide(.allowOnce), env: env))
        for _ in 0..<100 where feed.sentCommands.isEmpty || env.sessions.card(for: ID.approval) != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(env.sessions.card(for: ID.approval) == nil)
        #expect(env.sessions.card(for: ID.plan) != nil)
    }

    // MARK: The system-wide key's action (P323)

    @Test
    func theSystemWideKeyJumpsUnlessSetToOpen() {
        let settings = AppSettings.ephemeral()
        #expect(settings.globalKeyAction == .jump)
        settings.globalJumpEnabled = true
        settings.globalJumpKey = "ctrl+opt+j"
        #expect(SessionCardView.showsJumpHint(settings, problem: nil))
        #expect(!SessionCardView.showsJumpHint(settings, problem: "Another app uses ⌃⌥J."))
        // Set to open the island, the key jumps nowhere: no row shows its hint.
        settings.globalKeyAction = .open
        #expect(!SessionCardView.showsJumpHint(settings, problem: nil))
        #expect(GlobalKeyAction.allCases.map(\.title) == ["Jump to what needs you", "Open Juice Island", "Switch sessions"])
    }

    /// The Action row shows only while a key is recorded and on: otherwise it would change nothing (no dead controls).
    @Test
    func theActionShowsOnlyWithAKeyThatIsOn() throws {
        let combo = try #require(KeyCombo(storage: "ctrl+opt+j"))
        #expect(ShortcutsPane.showsAction(combo: combo, enabled: true))
        #expect(!ShortcutsPane.showsAction(combo: combo, enabled: false))
        #expect(!ShortcutsPane.showsAction(combo: nil, enabled: true))
        #expect(!ShortcutsPane.showsAction(combo: nil, enabled: false))
    }

    /// The window's Needs-you card the keys are on is plain to see: it takes the rows' lift as well as the ring, so its
    /// ground is lighter than an unselected card's, not only its 1 pt edge.
    @Test
    func theSelectedWindowCardIsLifted() throws {
        func centre(selected: Bool) throws -> CGFloat {
            let env = AppEnvironment.demo(sessions: .allStates)
            env.windowSelection = selected ? "a" : nil
            let renderer = ImageRenderer(content: WindowCardGround(id: "a", radius: 12).frame(width: 80, height: 40).environment(env)
                .environment(\.colorScheme, .dark))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let rep = NSBitmapImageRep(cgImage: image)
            return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceGray)?.whiteComponent ?? 0
        }
        let plain = try centre(selected: false), lifted = try centre(selected: true)
        #expect(lifted > plain + 0.05)
    }

    @Test
    func theActionIsKeptInDefaults() throws {
        let suite = "ji-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, identity: .development)
        settings.globalKeyAction = .open
        #expect(defaults.string(forKey: AppSettings.Key.globalKeyAction) == "open")
        #expect(AppSettings(defaults: defaults, identity: .development).globalKeyAction == .open)
    }

    // MARK: Helpers

    static func row(_ id: String, bucket: SessionBucket, folder: String? = nil) -> SessionRow {
        SessionRow(id: id, agent: .claude, bucket: bucket, project: "p", folder: folder, task: "Title \(id)",
                   status: bucket == .done ? .done : .thinking, detail: nil, lastPrompt: nil, host: nil, accountAlias: nil,
                   updatedAt: DemoClock.now, isCodexApp: false, glyph: .bang, glyphState: .waiting, hasCard: false)
    }
}

/// Records what the menu asks of the model, over a real model's rows and cards.
@MainActor
@Observable
final class MenuSpy: SessionsModel {
    let inner: any SessionsModel
    var approvals: [(sessionID: String, decision: ApprovalDecision, request: String?)] = []
    var dismissed: [String] = []
    var opened: [(sessionID: String, alternative: LimitAlternative)] = []

    init(_ inner: any SessionsModel) { self.inner = inner }

    var rows: [SessionRow] { inner.rows }
    var now: Date { inner.now }
    func card(for sessionID: String) -> SessionCard? { inner.card(for: sessionID) }
    func approve(_ sessionID: String, _ decision: ApprovalDecision, request: String?) { approvals.append((sessionID, decision, request)) }
    func answerQuestion(_ sessionID: String, _ input: QuestionInput, request: String?) -> Bool { false }
    func reply(_ sessionID: String, text: String) {}
    func jump(_ sessionID: String) {}
    func jumpToNextNeedsYou() {}
    func dismiss(_ sessionID: String) { dismissed.append(sessionID) }
    func openFresh(_ sessionID: String, in alternative: LimitAlternative) { opened.append((sessionID, alternative)) }
}
