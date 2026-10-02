import AppKit
import Foundation
import IslandEngine
import OpenIslandCore
import Testing
@testable import JuiceIslandUI

/// P138: a key or a click never answers a card the owner did not mean it for. A field being edited keeps its ⌃A and ⌃D
/// (the island's panel takes keys before the field editor); a held key's repeats answer nothing, in the island and in
/// the window; a card that has just come in takes no key and no click yet. The panel here is never ordered in: nothing
/// is drawn on screen.
@MainActor
struct KeyGuardTests {
    typealias ID = FixtureSessionFeed.ID

    private static func event(_ characters: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags, window: Int,
                              repeat isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window, context: nil,
                         characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: isRepeat, keyCode: 0)!
    }

    private static func panel() -> IslandPanel {
        IslandPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: true)
    }

    private func settle(_ done: () -> Bool) async {
        for _ in 0..<400 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// The owner ⌥-clicked No on the plan and types why: ⌃A (start of line) and ⌃D (delete forward) are the field's,
    /// and no decision goes; ⌃G and Esc still act, as in the window.
    @Test
    func aFieldBeingEditedKeepsControlAAndControlD() throws {
        _ = NSApplication.shared
        let feed = FixtureSessionFeed(scenario: .cards)
        let model = feed.makeModel()
        guard case .plan? = model.card(for: ID.longPlan) else { Issue.record("no plan card"); return }
        let panel = Self.panel()
        let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 300, height: 24))
        panel.contentView?.addSubview(field)
        field.stringValue = "keep the old API"
        var commands: [IslandKeyCommand] = []
        // As `IslandPanelController.handleKey`, with the plan on show.
        panel.keyHandler = { key in
            let card = IslandKeyRouter.targetCard(presentation: .card(sessionID: ID.longPlan), sessions: model)
            guard let command = IslandKeyRouter.command(for: key, card: card) else { return false }
            commands.append(command)
            return true
        }
        #expect(panel.makeFirstResponder(field))
        #expect(panel.firstResponder is NSText)
        let window = panel.windowNumber
        for (characters, ignoring, flags) in [("\u{01}", "a", NSEvent.ModifierFlags.control), ("\u{04}", "d", .control),
                                              ("\u{01}", "A", [.control, .shift]), ("\u{04}", "D", [.control, .shift])] {
            panel.sendEvent(Self.event(characters, ignoring, flags, window: window))
        }
        #expect(commands.isEmpty)
        // The field had them: ⌃A went to the start of the line and ⌃D deleted the letter after it.
        #expect(field.currentEditor()?.string == "eep the old API")
        panel.sendEvent(Self.event("\u{07}", "g", .control, window: window))
        panel.sendEvent(Self.event("\u{1b}", "\u{1b}", [], window: window))
        #expect(commands == [.jumpToNextNeedsYou, .close])

        // With no field being edited, ⌃A is Yes on the card that shows.
        commands = []
        #expect(panel.makeFirstResponder(nil))
        panel.sendEvent(Self.event("\u{01}", "a", .control, window: window))
        #expect(commands == [.approve(sessionID: ID.longPlan, .allowOnce)])
    }

    /// ⌃A held a little long on card A: A goes once its answer is sent and the next card that waits takes its place;
    /// the key's auto-repeat is eaten and never answers that card.
    @Test
    func aHeldKeysRepeatNeverAnswersTheNextCard() async throws {
        _ = NSApplication.shared
        let feed = FixtureSessionFeed(scenario: .cards)
        let model = feed.makeModel()
        let approvals = model.waiting.filter { if case .approval = model.card(for: $0.id) { true } else { false } }.map(\.id)
        let first = try #require(approvals.first)
        #expect(approvals.count >= 2)
        let panel = Self.panel()
        var presentation = IslandPresentation.card(sessionID: first)
        var answered: [String] = []
        var eaten = 0
        panel.keyHandler = { key in
            let card = IslandKeyRouter.targetCard(presentation: presentation, sessions: model)
            switch IslandKeyRouter.command(for: key, card: card) {
            case let .approve(id, decision)?:
                answered.append(id)
                model.approve(id, decision)
                return true
            case .swallow?:
                eaten += 1
                return true
            default:
                return false
            }
        }
        let before = model.rows
        panel.sendEvent(Self.event("\u{01}", "a", .control, window: panel.windowNumber))
        await settle { model.card(for: first) == nil }
        let next = try #require(IslandAttention.next(after: first, wasWaiting: before.first { $0.id == first }?.hasCard == true,
                                                     waiting: model.waiting))
        presentation = .card(sessionID: next)
        panel.sendEvent(Self.event("\u{01}", "a", .control, window: panel.windowNumber, repeat: true))
        #expect(answered == [first])
        #expect(eaten == 1)
        #expect(model.card(for: next) != nil)
    }

    /// Every card key's repeat is eaten, on a question too (a held ⌃1 would pick option 1 on every question after).
    @Test
    func everyCardKeysRepeatIsEaten() {
        let question = SessionCard.question(QuestionCardModel(sessionID: "q", agent: .claude, topic: nil, question: "Which?",
                                                              options: [.init(label: "A", description: "")]))
        let approval = SessionCard.approval(ApprovalCardModel(sessionID: "a", agent: .claude, tool: "Bash", body: .command("ls"),
                                                              alwaysAllowLabel: "Yes, allow ls", canStop: true))
        for key in ["a", "A", "d", "D"] {
            let press = IslandKeyPress(characters: key, control: true, shift: key == key.uppercased(), isRepeat: true)
            #expect(IslandKeyRouter.command(for: press, card: approval) == .swallow, "\(key)")
        }
        let heldOne = IslandKeyPress(characters: "1", control: true, isRepeat: true)
        #expect(IslandKeyRouter.command(for: heldOne, card: question) == .swallow)
        // Keys that answer nothing still repeat.
        #expect(IslandKeyRouter.command(for: IslandKeyPress(characters: "g", control: true, isRepeat: true), card: approval)
            == .jumpToNextNeedsYou)
    }

    /// A card that has just come in (the next that waits, swapped in tens of milliseconds after an answer) takes no key
    /// and no click until it has; built ahead or leaving, a card never takes clicks.
    @Test
    func aCardThatHasJustComeInTakesNoKeyAndNoClick() {
        let approval = SessionCard.approval(ApprovalCardModel(sessionID: "b", agent: .claude, tool: "Bash", body: .command("rm -rf dist")))
        let press = IslandKeyPress(characters: "a", control: true)
        #expect(IslandKeyRouter.command(for: press, card: approval, arriving: "b") == .swallow)
        #expect(IslandKeyRouter.command(for: press, card: approval, arriving: "a") == .approve(sessionID: "b", .allowOnce))
        #expect(IslandKeyRouter.command(for: press, card: approval) == .approve(sessionID: "b", .allowOnce))

        let shows = IslandPresentation.card(sessionID: "b")
        #expect(!IslandCardLayer.takesClicks("b", role: .live, presentation: shows, arriving: "b"))
        #expect(IslandCardLayer.takesClicks("b", role: .live, presentation: shows, arriving: nil))
        #expect(!IslandCardLayer.takesClicks("b", role: .ahead, presentation: shows, arriving: nil))
        #expect(!IslandCardLayer.takesClicks("b", role: .leaving, presentation: shows, arriving: nil))
        #expect(!IslandCardLayer.takesClicks("b", role: .live, presentation: .list, arriving: nil))
    }

    /// The window: ⌃A held on the first approval answers it once; once it goes, the approval that is first now is not
    /// answered by the repeats. A held ⌃1 picks nothing either.
    @Test
    func theWindowEatsAHeldKeysRepeats() async throws {
        let env = AppEnvironment.demo(sessions: .cards)
        let feed = try #require(env.fixtureFeed)
        let first = try #require(env.sessions.needsYou.first { if case .approval = env.sessions.card(for: $0.id) { true } else { false } })
        var held = WindowKeyRouter.KeyPress(character: "a", control: true)
        #expect(WindowKeyRouter.handle(held, .decide(.allowOnce), env: env))
        await settle { feed.sentCommands.count == 1 && env.sessions.card(for: first.id) == nil }
        #expect(env.sessions.card(for: first.id) == nil)
        let next = try #require(env.sessions.needsYou.first { if case .approval = env.sessions.card(for: $0.id) { true } else { false } })
        held.isRepeat = true
        #expect(WindowKeyRouter.handle(held, .decide(.allowOnce), env: env))
        #expect(WindowKeyRouter.handle(held, .decide(.deny), env: env))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(feed.sentCommands.count == 1)
        #expect(env.sessions.card(for: next.id) != nil)

        let prototype = AppEnvironment.demo(sessions: .prototype)
        let asked = try #require(prototype.fixtureFeed)
        let heldOne = WindowKeyRouter.KeyPress(character: "1", control: true, isRepeat: true)
        #expect(WindowKeyRouter.handle(heldOne, .option(0), env: prototype))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(asked.sentCommands.isEmpty)
        #expect(WindowKeyRouter.answersACard(.decide(.deny)) && WindowKeyRouter.answersACard(.option(1)))
        #expect(!WindowKeyRouter.answersACard(.jumpToNeedsYou) && !WindowKeyRouter.answersACard(.escape))
    }

    /// While the open island rests on a card that waits, the one an answer would bring is built ahead (P133); on a
    /// card that does not wait, none is.
    @Test
    func theNextCardThatWaitsIsBuiltAhead() {
        let rows = [CardFlowTests.row("a"), CardFlowTests.row("b"), CardFlowTests.row("c")]
        #expect(IslandAttention.buildAhead(shown: "a", waits: true, waiting: rows) == "b")
        #expect(IslandAttention.buildAhead(shown: "b", waits: true, waiting: rows) == "a")
        #expect(IslandAttention.buildAhead(shown: "done", waits: false, waiting: rows) == nil)
        #expect(IslandAttention.buildAhead(shown: "a", waits: true, waiting: [CardFlowTests.row("a")]) == nil)
    }
}
