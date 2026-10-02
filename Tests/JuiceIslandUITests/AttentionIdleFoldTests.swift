import Foundation
import Testing
@testable import JuiceIslandUI

/// P292: a card that needs you opened the island over the app already in front, and it stayed until the owner left
/// that app, answered or crossed the island (a click inside the app in front needs a global monitor to be seen, P270).
/// Now an island that something needing you opened by itself folds back into the pill after `attentionIdle` (6 s) with
/// no pointer on it: never under the pointer, never while a field holds a draft or the island has the keys (its time
/// starts again), never with Keep open. The fold is the normal one, and what waits stays on the pill (P272). The hover
/// machine is driven as the panel drives it (`BriefDoneCardTests.Timeline` fires every timer it asks for).
@MainActor
struct AttentionIdleFoldTests {
    typealias M = IslandHoverMachine
    typealias Timeline = BriefDoneCardTests.Timeline

    @Test func theTuningConstantIsSixSeconds() {
        #expect(M.attentionIdle == 6)
    }

    /// Left alone, it folds at 6 s with the normal fold, and nothing opens it again by itself.
    @Test func aCardThatOpenedByItselfFoldsWhenLeftAlone() {
        var timeline = Timeline()
        timeline.send(.attention(at: 0), at: 0)
        #expect(timeline.opens == [0] && timeline.machine.openReason == .attention)
        timeline.run(until: M.attentionIdle - 0.01)
        #expect(timeline.closes.isEmpty && timeline.machine.isOpen)
        timeline.run(until: M.attentionIdle)
        #expect(timeline.closes == [M.attentionIdle] && timeline.log.last?.effect == .close(.fold))
        #expect(timeline.machine.phase == .closed && timeline.machine.openReason == nil)
        // Not a pointer close: no reverse; a rest opens it again, and so does a click or a new request.
        #expect(timeline.machine.foldStartedAt == nil && !timeline.machine.mustLeaveBeforeReopen)
        timeline.run(until: 600)
        #expect(timeline.opens == [0] && timeline.closes == [M.attentionIdle])
        timeline.send(.attention(at: 700), at: 700)
        timeline.run(until: 700 + M.attentionIdle)
        #expect(timeline.opens == [0, 700] && timeline.closes == [M.attentionIdle, 700 + M.attentionIdle])
    }

    /// Never under the pointer: one that came onto it keeps it, and its leave closes it after the normal grace. One the
    /// island opened under (parked on the menu bar) keeps it too; the island moving off it starts the time again.
    @Test func neverUnderThePointer() {
        var visited = Timeline()
        visited.send(.attention(at: 0), at: 0)
        visited.send(.pointerEntered(at: 1), at: 1)
        visited.run(until: 60)
        #expect(visited.closes.isEmpty && visited.machine.isOpen)
        visited.send(.pointerExited(at: 60), at: 60)
        visited.run(until: 70)
        #expect(visited.closes == [60 + M.closeGrace])

        var parked = Timeline()
        parked.send(.attention(at: 0), at: 0)
        parked.send(.pointerRelocated(inside: true), at: 0.3)
        parked.run(until: 60)
        #expect(parked.closes.isEmpty && parked.machine.isOpen)
        parked.send(.pointerRelocated(inside: false), at: 60)
        parked.run(until: 60 + M.attentionIdle - 0.01)
        #expect(parked.closes.isEmpty)
        parked.run(until: 60 + M.attentionIdle)
        #expect(parked.closes == [60 + M.attentionIdle])

        // Resting on the pill when the request came: the island opens under the pointer and waits for it.
        var resting = Timeline()
        resting.send(.pointerEntered(at: 0), at: 0)
        resting.send(.attention(at: 0.05), at: 0.05)
        resting.run(until: 60)
        #expect(resting.closes.isEmpty && resting.machine.openReason == .attention)
    }

    /// Never once the owner asked for it (a widget's tap, P343): the card it opened holds as a click's open does, and a
    /// newer request keeps it so; a Done card keeps its own time.
    @Test func neverOnceTheOwnerAskedForIt() {
        var timeline = Timeline()
        timeline.send(.attention(at: 0), at: 0)
        timeline.machine.ownerAsked()
        #expect(timeline.machine.openReason == .click)
        timeline.run(until: 60)
        #expect(timeline.closes.isEmpty && timeline.machine.isOpen)
        timeline.send(.attention(at: 60), at: 60)
        timeline.run(until: 120)
        #expect(timeline.closes.isEmpty && timeline.machine.isOpen)

        var done = Timeline()
        done.send(.finished(at: 0), at: 0)
        done.machine.ownerAsked()
        done.run(until: M.doneCardLife)
        #expect(done.closes == [M.doneCardLife])
    }

    /// Never while the owner types: a field's draft or the keys start the time again, and it folds 6 s after the next
    /// look finds neither.
    @Test func neverWithADraftOrTheKeys() {
        var timeline = Timeline()
        timeline.send(.attention(at: 0), at: 0)
        timeline.machine.drafting = true
        timeline.run(until: 30)
        #expect(timeline.closes.isEmpty && timeline.machine.isOpen)
        timeline.machine.drafting = false
        timeline.run(until: 30 + M.attentionIdle)
        #expect(timeline.closes == [30 + M.attentionIdle])
    }

    /// A card the island can answer (an approval, a plan or a question it holds) never folds by itself: its Allow stays
    /// in sight. Once it takes no answer here (released to the agent's own prompt), the next look folds it.
    @Test func anAnswerableCardStaysInSight() {
        var timeline = Timeline()
        timeline.machine.answerable = true
        timeline.send(.attention(at: 0), at: 0)
        timeline.run(until: 600)
        #expect(timeline.closes.isEmpty && timeline.machine.isOpen)
        timeline.machine.answerable = false
        timeline.run(until: 600 + M.attentionIdle)
        #expect(timeline.closes.count == 1 && !timeline.machine.isOpen)
    }

    /// Keep approvals open until answered keeps it, as it keeps it through a leave.
    @Test func keepOpenHoldsIt() {
        var timeline = Timeline()
        timeline.machine.holdOpen = true
        timeline.send(.attention(at: 0), at: 0)
        timeline.run(until: 600)
        #expect(timeline.closes.isEmpty && timeline.machine.isOpen)
    }

    /// A newer request on the open island (the next card after an answer, another session's) starts the time again;
    /// one that comes in the leave grace takes the island over and folds when left alone.
    @Test func aNewRequestStartsTheTimeAgain() {
        var timeline = Timeline()
        timeline.send(.attention(at: 0), at: 0)
        timeline.send(.attention(at: 4), at: 4)
        timeline.run(until: 4 + M.attentionIdle - 0.01)
        #expect(timeline.closes.isEmpty)
        timeline.run(until: 4 + M.attentionIdle)
        #expect(timeline.closes == [4 + M.attentionIdle] && timeline.opens == [0])

        var grace = Timeline()
        grace.send(.pointerEntered(at: 0), at: 0)
        grace.send(.clicked(at: 0.05), at: 0.05)
        grace.send(.pointerExited(at: 1), at: 1)
        grace.send(.attention(at: 1.1), at: 1.1)
        grace.run(until: 1.1 + M.attentionIdle - 0.01)
        #expect(grace.closes.isEmpty && grace.machine.openReason == .attention)
        grace.run(until: 1.1 + M.attentionIdle)
        #expect(grace.closes == [1.1 + M.attentionIdle])
    }

    /// The brief Done card keeps its own 3 s; a request that takes it over folds on the request's time. An island the
    /// owner opened (a hover's rest, a click) never folds by itself.
    @Test func otherOpensKeepTheirOwnRules() {
        var done = Timeline()
        done.send(.finished(at: 0), at: 0)
        done.run(until: 10)
        #expect(done.closes == [M.doneCardLife])

        var takenOver = Timeline()
        takenOver.send(.finished(at: 0), at: 0)
        takenOver.send(.attention(at: 1), at: 1)
        takenOver.run(until: 1 + M.attentionIdle - 0.01)
        #expect(takenOver.closes.isEmpty)
        takenOver.run(until: 1 + M.attentionIdle)
        #expect(takenOver.closes == [1 + M.attentionIdle])

        var hovered = Timeline()
        hovered.send(.pointerEntered(at: 0), at: 0)
        hovered.run(until: 1)
        hovered.send(.attention(at: 1), at: 1)
        hovered.run(until: 60)
        #expect(hovered.opens == [M.openDelay] && hovered.closes.isEmpty && hovered.machine.openReason == .hover)
    }
}
