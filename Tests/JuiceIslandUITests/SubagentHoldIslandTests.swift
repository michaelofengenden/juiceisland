import Foundation
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// The island's side of Answer subagents on the island (P350): what it tells the engine it shows, how the card settles
/// when a hold runs out under the owner's pointer, the idle fold around it, and the switch itself.
@MainActor
struct SubagentHoldIslandTests {
    typealias M = IslandHoverMachine
    typealias Timeline = BriefDoneCardTests.Timeline

    static func card(_ session: String, request: String, answerable: Bool, holdEnds: Date? = nil) -> SessionCard {
        .approval(ApprovalCardModel(sessionID: session, agent: .claude, tool: "Bash", body: .command("rm -f shots/*"),
                                    request: CardRequest(id: request, answerable: answerable, place: .claudeApp,
                                                         agentType: "workflow-subagent", more: 0, isNotice: false,
                                                         dismissable: !answerable, holdEnds: holdEnds)))
    }

    /// The engine hears of a request only while its card is what the open island shows as drawn: not the list, not a
    /// card built for another session, not a fold under way, Window mode or no display (`open` false).
    @Test
    func theIslandReportsOnlyTheCardTheOwnerSees() {
        let shown = Self.card("s1", request: "A", answerable: true)
        #expect(IslandAttention.requestOnScreen(open: true, presentation: .card(sessionID: "s1"), drawn: shown) == "A")
        #expect(IslandAttention.requestOnScreen(open: false, presentation: .card(sessionID: "s1"), drawn: shown) == nil)
        #expect(IslandAttention.requestOnScreen(open: true, presentation: .list, drawn: shown) == nil)
        #expect(IslandAttention.requestOnScreen(open: true, presentation: .card(sessionID: "s2"), drawn: shown) == nil)
        #expect(IslandAttention.requestOnScreen(open: true, presentation: .card(sessionID: "s1"), drawn: nil) == nil)
        let done = SessionCard.done(DoneCardModel(sessionID: "s1", agent: .claude, message: "Done.", interrupted: false))
        #expect(IslandAttention.requestOnScreen(open: true, presentation: .card(sessionID: "s1"), drawn: done) == nil)
    }

    /// The owner goes to another app with the pointer resting on the island: P270 keeps the island open until the
    /// pointer leaves, but the owner no longer looks at it, so the engine hears that no card shows and the hold ends at
    /// once (P350, P353); the card then settles read-only in place under the pointer. Without the pointer the island
    /// folds, as before.
    @Test
    func anAppSwitchWithThePointerOnTheIslandEndsTheHold() {
        let held = Self.card("s1", request: "S", answerable: true, holdEnds: DemoClock.now + 10)
        func shown(_ machine: M) -> String? {
            IslandAttention.requestOnScreen(open: IslandAttention.ownerSees(machine, visible: true), presentation: .card(sessionID: "s1"),
                                            drawn: held)
        }
        var machine = M()
        machine.answerable = true
        _ = machine.handle(.attention(at: 0))
        _ = machine.handle(.pointerEntered(at: 1))
        #expect(shown(machine) == "S")
        #expect(!IslandAttention.ownerSees(machine, visible: false))
        #expect(machine.handle(.focusLeft(pointerHolds: true, at: 2)).isEmpty && machine.isOpen && machine.focusAway)
        #expect(shown(machine) == nil)
        // The pointer leaves: the island yields, still nothing shown.
        #expect(machine.handle(.pointerRelocated(inside: false)) == [.close(.fold)] && shown(machine) == nil)

        var away = M()
        away.answerable = true
        _ = away.handle(.attention(at: 0))
        #expect(shown(away) == "S")
        #expect(away.handle(.focusLeft(pointerHolds: false, at: 2)) == [.close(.fold)] && shown(away) == nil)
    }

    /// The hold runs out under the owner's eyes: the same request, now read-only, settles where it was (no click on Open
    /// or ✕ for the settle, P138, P172), never as a new arrival that would open the island again; any other change is
    /// what it was.
    @Test
    func aHoldThatRunsOutSettlesTheCardInPlace() {
        let held = Self.card("s1", request: "A", answerable: true, holdEnds: DemoClock.now + 7)
        let released = Self.card("s1", request: "A", answerable: false)
        #expect(IslandAttention.shownCardChanged(drawn: held, current: released, waiting: []) == .settles)
        #expect(IslandAttention.shownCardChanged(drawn: released, current: released, waiting: []) == .none)
        #expect(IslandAttention.shownCardChanged(drawn: held, current: held, waiting: []) == .none)
        #expect(IslandAttention.shownCardChanged(drawn: released, current: held, waiting: []) == .none)
        #expect(IslandAttention.shownCardChanged(drawn: held, current: Self.card("s1", request: "B", answerable: false),
                                                 waiting: []) == .arrives)
        #expect(!IslandCardLayer.takesClicks("s1", role: .live, presentation: .card(sessionID: "s1"), arriving: "s1"))
    }

    /// The idle fold never folds a held card early: the card takes an answer on the island, so its 6 s start again
    /// (P292). When the hold runs out, an island that opened by itself and was left alone folds at once, as the idle fold
    /// would have; under the pointer, with a draft or the keys, or with Keep open, it stays read-only, and one that
    /// opened less than 6 s before gets its 6 s again from the hold's end.
    @Test
    func theIdleFoldWaitsForTheHoldAndFoldsWhenItEnds() {
        var timeline = Timeline()
        timeline.machine.answerable = true
        timeline.send(.attention(at: 0), at: 0)
        timeline.run(until: SubagentHold.limit - 0.01)
        #expect(timeline.closes.isEmpty && timeline.machine.isOpen)
        timeline.machine.answerable = false
        timeline.send(.answerEnded(at: SubagentHold.limit), at: SubagentHold.limit)
        #expect(timeline.closes == [SubagentHold.limit] && timeline.log.last?.effect == .close(.fold))
        #expect(timeline.machine.phase == .closed && timeline.machine.foldStartedAt == nil && !timeline.machine.mustLeaveBeforeReopen)
        // The idle timer asked for before goes stale: nothing folds or opens again.
        timeline.run(until: 60)
        #expect(timeline.closes == [SubagentHold.limit] && timeline.opens == [0])

        for keeper in ["pointer", "draft", "keep open"] {
            var kept = Timeline()
            kept.machine.answerable = true
            kept.send(.attention(at: 0), at: 0)
            switch keeper {
            case "pointer": kept.send(.pointerEntered(at: 1), at: 1)
            case "draft": kept.machine.drafting = true
            default: kept.machine.holdOpen = true
            }
            kept.machine.answerable = false
            kept.send(.answerEnded(at: SubagentHold.limit), at: SubagentHold.limit)
            #expect(kept.closes.isEmpty && kept.machine.isOpen, "\(keeper)")
        }

        // Still answerable (another request of it took over), or not opened by itself: nothing.
        var answerable = Timeline()
        answerable.machine.answerable = true
        answerable.send(.attention(at: 0), at: 0)
        answerable.send(.answerEnded(at: SubagentHold.limit), at: SubagentHold.limit)
        #expect(answerable.closes.isEmpty)
        var clicked = Timeline()
        clicked.send(.clicked(at: 0), at: 0)
        clicked.send(.answerEnded(at: SubagentHold.limit), at: SubagentHold.limit)
        #expect(clicked.closes.isEmpty && clicked.machine.isOpen)

        // Opened for it less than 6 s before: its idle time runs from here.
        var late = Timeline()
        late.send(.attention(at: 0), at: 0)
        late.send(.answerEnded(at: 2), at: 2)
        #expect(late.closes.isEmpty)
        late.run(until: 2 + M.attentionIdle)
        #expect(late.closes == [2 + M.attentionIdle])
    }

    /// Off by default; on only in Island mode (the window shows no card a hold could wait on); kept in defaults.
    @Test
    func theSwitchIsOffByDefaultAndOnlyForTheIsland() throws {
        let settings = AppSettings.ephemeral()
        #expect(!settings.answerSubagentsOnIsland)
        settings.showAs = .island
        #expect(!LiveSessions.answersSubagents(settings))
        settings.answerSubagentsOnIsland = true
        #expect(LiveSessions.answersSubagents(settings))
        settings.showAs = .window
        #expect(!LiveSessions.answersSubagents(settings))

        let suite = "ji-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!AppSettings(defaults: defaults, identity: .development).answerSubagentsOnIsland)
        AppSettings(defaults: defaults, identity: .development).answerSubagentsOnIsland = true
        #expect(defaults.bool(forKey: AppSettings.Key.answerSubagents))
        #expect(AppSettings(defaults: defaults, identity: .development).answerSubagentsOnIsland)
        #expect(IslandPaneText.answerSubagents == "Claude's own prompt waits up to 12 s.")
    }

    /// The live engine follows the switch and Show as as they change: on in Island mode only.
    @Test
    func theLiveEngineFollowsTheSwitchAndShowAs() async throws {
        let settings = AppSettings.ephemeral()
        settings.liveSessions = true
        settings.showAs = .island
        let live = LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .owner).makeModel() },
                                engine: { SessionEngine.preview() }, profiles: { LiveProfiles(accounts: [], discovered: []) },
                                identity: .other)
        live.activate()
        defer { live.shutdown() }
        let engine = try #require(live.engine)
        #expect(!engine.answersSubagents)
        settings.answerSubagentsOnIsland = true
        for _ in 0..<100 where !engine.answersSubagents { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.answersSubagents)
        settings.showAs = .window
        for _ in 0..<100 where engine.answersSubagents { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!engine.answersSubagents)
    }
}
