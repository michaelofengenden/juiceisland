import AppKit
import Foundation
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Stream C: the card buttons' shared widths, the always-allow wording, the cards' one status line and their tooltips.
@MainActor
struct CCardTests {
    typealias ID = FixtureSessionFeed.ID

    @Test
    func flexButtonsShareEquallyUntilOneIsWider() {
        // Three short buttons in 636 pt: (636 − 16) / 3 each.
        let equal = FlexRowLayout.widths(mins: [40, 50, 60], total: 636, spacing: 8)
        #expect(equal.allSatisfy { abs($0 - 620.0 / 3) < 0.001 })
        // A long third label keeps its width; No and Yes share the rest.
        #expect(FlexRowLayout.widths(mins: [40, 50, 240], total: 636, spacing: 8) == [190, 190, 240])
        // Too narrow for everyone: the widest give way first, down to a width they share, and the row never overflows.
        #expect(FlexRowLayout.widths(mins: [100, 100], total: 150, spacing: 8) == [71, 71])
        #expect(FlexRowLayout.widths(mins: [40, 50, 300], total: 300, spacing: 8) == [40, 50, 194])
        #expect(FlexRowLayout.widths(mins: [], total: 100, spacing: 8).isEmpty)
    }

    /// P490: a row wider than the card's lane (No, Yes, Always allow's rule and a mode button in the island at Width 480,
    /// ⌃ held) puts the buttons that give way (the mode buttons, layout priority −1) on a line of their own, and each
    /// line fits the lane, so the card never grows past the island.
    @Test
    func aCrowdedRowWrapsItsModeButtonsAndNeverWidensTheCard() {
        // Fits: one line.
        #expect(FlexRowLayout.lines(mins: [40, 50, 100, 90], priorities: [0, 0, 0, -1], total: 428, spacing: 6) == [[0, 1, 2, 3]])
        // Too wide: the answers first, the mode buttons on their own line.
        #expect(FlexRowLayout.lines(mins: [60, 70, 250, 130], priorities: [0, 0, 0, -1], total: 428, spacing: 6) == [[0, 1, 2], [3]])
        // Nothing gives way: one line, which shrinks.
        #expect(FlexRowLayout.lines(mins: [200, 300], priorities: [0, 0], total: 428, spacing: 6) == [[0, 1]])

        for lane: CGFloat in [408, 428] {
            for hints in [false, true] {
                let row = CardActionsRow(fills: true, top: 0) {
                    CardActionButton(title: "No", key: "⌃D", fills: true) {}
                    CardActionButton(title: "Yes", key: "⌃A", primary: true, fills: true) {}
                    CardActionButton(title: "Always allow mkdir -p site/shots/light:*", key: "⌃⇧A", fills: true) {}
                    ModeButtons(modes: [.acceptEdits, .bypassPermissions], plan: false, fills: true) { _ in }
                }
                .environment(\.showsShortcutHints, hints)
                let host = NSHostingController(rootView: row)
                let size = host.sizeThatFits(in: CGSize(width: lane, height: 1000))
                #expect(size.width <= lane, "lane \(lane), hints \(hints): \(size.width)")
                // Two lines of 28 pt buttons.
                #expect(size.height > 50, "lane \(lane), hints \(hints): \(size.height)")
            }
        }
    }

    @Test
    func alwaysAllowKeepsClaudesWordsWithoutTheFolderSlash() {
        #expect(ApprovalCardView.buttonTitle("Yes, allow running git push:*/") == "Yes, allow running git push:*")
        #expect(ApprovalCardView.buttonTitle("Yes, allow writing to src/") == "Yes, allow writing to src/")
        #expect(ApprovalCardView.buttonTitle("Yes, always allow Bash") == "Yes, always allow Bash")
        let model = FixtureSessionFeed(scenario: .prototype).makeModel()
        guard case let .approval(card) = model.card(for: ID.approval) else { Issue.record("no approval card"); return }
        #expect(card.alwaysAllowLabel.map(ApprovalCardView.buttonTitle) == "Yes, allow running git push:*")
    }

    @Test
    func alwaysAllowButtonIsShortButKeepsTheRule() {
        #expect(ApprovalCardView.shortTitle("Yes, allow running git push:*/") == "Always allow git push:*")
        #expect(ApprovalCardView.shortTitle("Yes, allow running git push:*/ from this project") == "Always allow git push:*")
        #expect(ApprovalCardView.shortTitle("Yes, allow writing to src/") == "Always allow writes to src/")
        #expect(ApprovalCardView.shortTitle("Yes, allow reading from docs/ for this session") == "Always allow reads from docs/ for this session")
        // A wider scope is never dropped from the button.
        #expect(ApprovalCardView.shortTitle("Yes, always allow Bash globally") == "Always allow Bash globally")
        #expect(ApprovalCardView.shortTitle("Yes, allow webfetch domain:example.com/") == "Always allow webfetch domain:example.com/")
        #expect(ApprovalCardView.shortTitle("Yes, always allow") == "Always allow")
        // The tooltip keeps Claude's whole sentence and the key.
        #expect(CardActionButton.tooltip(help: ApprovalCardView.buttonTitle("Yes, allow running git push:*/ from this project"), key: "⌃⇧A")
            == "Yes, allow running git push:* from this project  ⌃⇧A")
        #expect(CardActionButton.tooltip(help: nil, key: "⌃A") == "⌃A")
        #expect(CardActionButton.tooltip(help: nil, key: nil).isEmpty)
    }

    @Test
    func cardStatusSaysEachFactOnce() {
        let model = FixtureSessionFeed(scenario: .allStates).makeModel()
        func status(_ id: String) -> SessionRowText.DetailedStatus? { model.card(for: id).map { CardText.status($0) } }
        // The header names the tool, the step count or the topic; the body shows the command, the plan or the question.
        #expect(status(ID.approval) == .init(word: "Needs approval", tone: .approval, isPrompt: false, text: "Bash"))
        #expect(status(ID.plan) == .init(word: "Plan ready", tone: .approval, isPrompt: false, text: "4 steps"))
        #expect(status(ID.question) == .init(word: "Question", tone: .approval, isPrompt: false, text: "App name"))
        #expect(status(ID.claudeDone) == .init(word: "Done", tone: .done, isPrompt: false, text: nil))
        let done = DoneCardModel(sessionID: "x", agent: .claude, message: "", interrupted: true)
        #expect(CardText.status(.done(done)).word == "Interrupted")
        let untitled = QuestionCardModel(sessionID: "q", agent: .claude, topic: " ", question: "Which?", options: [])
        #expect(CardText.status(.question(untitled)).text == nil)
    }

    @Test
    func optionTooltipCarriesTheWholeOption() {
        let option = QuestionCardModel.Option(label: "Juice Island", description: "Reads like a place.")
        #expect(QuestionOptionButton.tooltip(option, index: 0) == "Juice Island — Reads like a place.  ⌃1")
        #expect(QuestionOptionButton.tooltip(.init(label: "Later", description: ""), index: 4) == "Later")
    }

    /// A command that fits its box is drawn without a scroll view, so `ImageRenderer` (the motion renders) draws it
    /// too; it left the box blank when the box was always a scroll view.
    @Test
    func aCommandThatFitsDrawsInEveryRenderer() throws {
        let renderer = ImageRenderer(content: CodeBlockView(code: "git push -u origin window-mode", maxLines: 6)
            .frame(width: 300).environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var light = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) where (bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > 0.6 {
                light += 1
            }
        }
        #expect(light > 40)
    }

    @Test
    func aCommandOfSeveralLinesKeepsItsHashes() {
        #expect(CodeBlockView.split("git push # why") == ("git push", "# why"))
        let heredoc = "git commit -m \"$(cat <<'EOF'\nFix # 12\nEOF\n)\""
        #expect(CodeBlockView.split(heredoc) == (heredoc, nil))
    }

    @Test
    func doneCardHeaderReadsDoneAndTheAge() {
        let model = FixtureSessionFeed(scenario: .allStates).makeModel()
        let done = SessionRowText.doneCardStatus(model.row(id: ID.claudeDone)!, now: model.now)
        #expect(done == .init(word: "Done", tone: .done, isPrompt: false, text: "5m"))
        #expect(SessionRowText.doneCardStatus(model.row(id: ID.interrupted)!, now: model.now).word == "Interrupted")
    }
}
