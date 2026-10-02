import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// R6, the owner's choice of 2026-09-28 (P350): Settings › Island › Answer subagents on the island, on. The screenshot's
/// request again (a workflow's subagent asks for Bash in the desktop app), now held for the island while its card shows,
/// for at most `SubagentHold.limit`: confirmed and sounded at once (Claude sends no notice while its hook holds), Yes and
/// No (with a reason) answer that request's own helper; left alone, not shown, or no longer shown, it is released, the
/// helper exits silent (Claude builds its own prompt) and the card turns read-only. With the switch off, R5 holds as
/// it was (`SubagentAllowReplayTests`). Through the built helper, the engine's real sockets, the engine and the session
/// model (`AttentionRig`); the island's report of what it shows is `EngineSessionsModel.islandShows`, as the panel's
/// `syncShownRequest` sends it. Fixtures shaped from the hooks docs.
extension SubagentAllowReplayTests {
    typealias Hold = SubagentHold

    /// A rig with Answer subagents on the island on, its session begun.
    private func optedIn(backstop: TimeInterval = 600) async throws -> AttentionRig {
        let rig = try await AttentionRig(subagentBackstop: backstop)
        rig.engine.answersSubagents = true
        await begin(rig)
        return rig
    }

    /// The card the island shows for s1 now, as the model maps it, and its request.
    private func held(_ rig: AttentionRig) throws -> (card: ApprovalCardModel, request: CardRequest) {
        let card = try #require(approval(rig))
        return (card, try #require(card.request))
    }

    private func printed(_ run: HelperRun) async -> [String: Any]? { Self.decision(await run.result(within: 30)) }

    /// The seconds left on the hold the card shows, on the rig's clock: a request opens at the earlier of the broker's
    /// real stamp and the rig's clock (`AttentionRig.base`), so once the clock has moved on its hold ends sooner than
    /// `limit` from now.
    private func left(_ rig: AttentionRig) throws -> TimeInterval {
        try #require(held(rig).request.holdEnds).timeIntervalSince(rig.now)
    }

    /// The helper ended with nothing printed: Claude builds its own prompt (a release, a quit: fail open).
    private func silent(_ run: HelperRun) async -> Bool {
        guard let result = await run.result(within: 30) else { return false }
        return result.status == 0 && result.stdout.isEmpty
    }

    // MARK: Answered on the island

    /// Held, confirmed and sounded at once, answerable with its countdown; the island's Yes, five seconds in, reaches
    /// that subagent's own helper with its own command. No Always allow and no No and stop reach it.
    @Test
    func r6AllowOnTheIslandReachesTheSubagentsOwnHelper() async throws {
        let rig = try await optedIn()
        defer { rig.stop() }
        let run = await ask(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        #expect(await rig.released(1) == false && run.isRunning)
        let shown = try held(rig)
        let opened = try #require(rig.engine.openRequests.first)
        #expect(shown.request.answerable && shown.request.agentType == Self.workflowAgent && !shown.request.dismissable)
        #expect(shown.request.holdEnds == opened.openedAt.addingTimeInterval(Hold.limit) && opened.isConfirmed)
        #expect(shown.card.alwaysAllowLabel == nil && !shown.card.canStop && shown.card.body == .command(Self.shots["command"] as! String))
        // No notice will come while the hook holds: it sounds at once.
        #expect(rig.needsYou.count == 1 && rig.row("s1")?.glyph == .bang)
        rig.model.islandShows(requestID: shown.request.id)

        rig.advance(5)
        for refused in [ApprovalDecision.alwaysAllow, .denyAndStop] {
            #expect(await rig.engine.approve(requestID: shown.request.id, decision: refused) == .nothingToSend)
        }
        #expect(run.isRunning)
        await rig.model.decide("s1", .allowOnce, request: shown.request.id)
        let decision = try #require(await printed(run))
        #expect(decision["behavior"] as? String == "allow")
        #expect((decision["updatedInput"] as? [String: Any])?["command"] as? String == Self.shots["command"] as? String)
        await rig.settle()
        #expect(rig.card("s1") == nil && rig.engine.openRequests.isEmpty && rig.needsYou.count == 1)
        // The call runs: its PostToolUse finds nothing left, and nothing else sounds.
        await ran(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        rig.advance(20)
        #expect(rig.needsYou.count == 1 && rig.dones.isEmpty && rig.engine.attentionTally.subagentHolds.isEmpty)
    }

    /// No, and No with a reason, from the island within the hold: Claude gets the deny, with the reason as its message.
    @Test
    func r6NoAndNoWithAReasonOnTheIsland() async throws {
        let rig = try await optedIn()
        defer { rig.stop() }
        let first = await ask(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        rig.model.islandShows(requestID: try held(rig).request.id)
        rig.advance(3)
        await rig.model.decide("s1", .deny, request: try held(rig).request.id)
        let no = try #require(await printed(first))
        #expect(no["behavior"] as? String == "deny" && no["message"] as? String == ApprovalChoices.denyMessage)
        #expect(no["interrupt"] as? Bool != true)
        await rig.settle()

        let second = await ask(rig, Self.lint, toolUseID: "UB", agent: "wf-b")
        let request = try held(rig).request
        rig.model.islandShows(requestID: request.id)
        rig.advance(try left(rig) - 1)
        await rig.model.decide("s1", .denyWithReason("keep the cache, it is shared"), request: request.id)
        let reason = try #require(await printed(second))
        #expect(reason["behavior"] as? String == "deny" && reason["message"] as? String == "keep the cache, it is shared")
        await rig.settle()
        #expect(rig.engine.openRequests.isEmpty && rig.card("s1") == nil)
    }

    // MARK: Released: Claude builds its own prompt

    /// No answer: at 12 s the hold ends, the helper exits silent and the card turns read-only where it is (Open, ✕),
    /// still confirmed; the island's buttons send nothing, Claude's notice six seconds later sounds nothing again, and the
    /// call's own evidence ends it.
    @Test
    func r6LeftAloneItIsReleasedAtTheLimitAndTurnsReadOnly() async throws {
        let rig = try await optedIn()
        defer { rig.stop() }
        let run = await ask(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        let id = try held(rig).request.id
        rig.model.islandShows(requestID: id)
        rig.advance(try left(rig) - 0.5)
        #expect(run.isRunning && approval(rig)?.isAnswerable == true)
        rig.advance(1)
        #expect(await silent(run))
        let after = try held(rig)
        #expect(after.request.id == id && !after.request.answerable && after.request.dismissable && after.request.holdEnds == nil)
        // The island settles it where it is: Open and ✕ take no click yet, and nothing opens the island.
        #expect(IslandAttention.shownCardChanged(drawn: .approval(after.card.with(answerable: true)), current: .approval(after.card),
                                                 waiting: rig.model.waiting) == .settles)
        for decision in [ApprovalDecision.allowOnce, .deny, .denyWithReason("no")] {
            #expect(await rig.engine.approve(requestID: id, decision: decision) == .nothingToSend)
        }
        rig.advance(6)
        await notice(rig)
        #expect(rig.needsYou.count == 1 && approval(rig)?.request?.id == id)
        await ran(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        #expect(rig.card("s1") == nil && rig.engine.openRequests.isEmpty)
        #expect(rig.engine.attentionTally.subagentHolds == ["timeUp": 1])
    }

    /// ✕ on the read-only card before Claude's own notice (P352): Claude builds its prompt only as the hold ends, so its
    /// `permission_prompt` comes about six seconds after the release, not after the request; it is the dismissed prompt's
    /// own, so nothing comes back ("!" with an empty card) and nothing sounds again.
    @Test
    func r6ADismissBeforeClaudesNoticeStaysDismissed() async throws {
        let rig = try await optedIn()
        defer { rig.stop() }
        let run = await ask(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        let id = try held(rig).request.id
        rig.model.islandShows(requestID: id)
        rig.advance(try left(rig) + 0.1)
        #expect(await silent(run))
        let released = try held(rig).request
        #expect(released.id == id && released.dismissable && !released.answerable && rig.needsYou.count == 1)
        // A second on, ✕ (or a late click aimed at Yes's right end, once the settle has passed).
        rig.advance(1)
        rig.model.dismissRequest("s1", request: id)
        await rig.settle()
        #expect(rig.card("s1") == nil)
        rig.advance(5)
        await notice(rig)
        #expect(rig.card("s1") == nil && rig.engine.openRequests.isEmpty && rig.needsYou.count == 1)
        #expect(rig.engine.attentionTally.subagentHolds == ["timeUp": 1])
    }

    /// Held only while the island shows it: never shown within the grace (another card up, Quiet, the island hidden),
    /// released at `showGrace`; shown, then no longer (a fold, the owner going to another app, Esc), released at once;
    /// Open releases it at once; a held card draws no ✕, and one sent for it anyway does nothing; the switch going off
    /// (or Window mode) releases every hold at once.
    @Test
    func r6ItIsHeldOnlyWhileTheIslandShowsIt() async throws {
        let rig = try await optedIn()
        defer { rig.stop() }
        // Not shown.
        let unseen = await ask(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        rig.advance(Hold.showGrace - 0.5)
        #expect(unseen.isRunning)
        rig.advance(1)
        #expect(await silent(unseen) && approval(rig)?.isAnswerable == false)
        await ran(rig, Self.shots, toolUseID: "UA", agent: "wf-a")

        // Shown, then folded away (or the owner went to another app, or Esc): at once, the clock standing still.
        let folded = await ask(rig, Self.lint, toolUseID: "UB", agent: "wf-b")
        rig.model.islandShows(requestID: try held(rig).request.id)
        rig.advance(4)
        #expect(folded.isRunning)
        rig.model.islandShows(requestID: nil)
        #expect(await silent(folded) && approval(rig)?.isAnswerable == false)
        await ran(rig, Self.lint, toolUseID: "UB", agent: "wf-b")

        // Open: released before the jump, so Claude's prompt is there.
        let opened = await ask(rig, Self.shots, toolUseID: "UC", agent: "wf-c")
        let openedID = try held(rig).request.id
        rig.model.islandShows(requestID: openedID)
        rig.model.openRequest("s1", request: openedID)
        #expect(await silent(opened) && approval(rig)?.isAnswerable == false)
        rig.model.islandShows(requestID: nil)
        await ran(rig, Self.shots, toolUseID: "UC", agent: "wf-c")

        // No ✕ on a held card (it draws none, only No and Yes): a ✕ sent for it anyway does nothing, and the hold goes on
        // until the island stops showing it. The ✕ the owner can press comes after a release (`r6ADismissBefore…`).
        let undismissed = await ask(rig, Self.lint, toolUseID: "UD", agent: "wf-d")
        let undismissedCard = try held(rig).request
        #expect(!undismissedCard.dismissable && undismissedCard.answerable)
        rig.model.islandShows(requestID: undismissedCard.id)
        rig.model.dismissRequest("s1", request: undismissedCard.id)
        await rig.settle()
        #expect(rig.engine.openRequests.first { $0.id == undismissedCard.id }?.isHeldForIsland == true)
        #expect(undismissed.isRunning && approval(rig)?.isAnswerable == true)
        rig.model.islandShows(requestID: nil)
        #expect(await silent(undismissed))
        await ran(rig, Self.lint, toolUseID: "UD", agent: "wf-d")

        // The switch off (Window mode turns it off too): every hold ends at once.
        let switched = await ask(rig, Self.shots, toolUseID: "UE", agent: "wf-e")
        rig.model.islandShows(requestID: try held(rig).request.id)
        rig.engine.answersSubagents = false
        #expect(await silent(switched) && approval(rig)?.isAnswerable == false)
        #expect(rig.engine.attentionTally.subagentHolds == ["notShown": 1, "hidden": 2, "opened": 1, "switchedOff": 1])
        // Off, the next one is handed back at once, as R5.
        await ran(rig, Self.shots, toolUseID: "UE", agent: "wf-e")
        let after = await ask(rig, Self.lint, toolUseID: "UF", agent: "wf-f")
        #expect(await rig.released(6))
        #expect(await silent(after))
    }

    /// Two subagents at once: the island shows the first; the second, not shown within the grace, is released and
    /// waits read-only behind it; the first's Yes reaches only its own helper. When the first is answered quickly, the
    /// second's card comes in while its own hold still runs, answerable with its own time.
    @Test
    func r6TwoSubagentsAreEachHeldOnlyWhileTheirOwnCardShows() async throws {
        let rig = try await optedIn()
        defer { rig.stop() }
        let a = await ask(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        let b = await ask(rig, Self.lint, toolUseID: "UB", agent: "wf-b")
        let first = try held(rig).request
        #expect(first.more == 1 && rig.engine.openRequests.first?.agentID == "wf-a" && rig.needsYou.count == 2)
        rig.model.islandShows(requestID: first.id)
        rig.advance(Hold.showGrace)
        #expect(await silent(b) && a.isRunning)
        await rig.model.decide("s1", .allowOnce, request: first.id)
        #expect((try #require(await printed(a)))["behavior"] as? String == "allow")
        await rig.settle()
        let next = try held(rig).request
        #expect(next.id != first.id && !next.answerable && next.agentType == Self.workflowAgent)
        rig.model.islandShows(requestID: next.id)
        await ran(rig, Self.lint, toolUseID: "UB", agent: "wf-b")
        #expect(rig.engine.openRequests.isEmpty)
        rig.model.islandShows(requestID: nil)

        // Answered within the grace: the second shows next, still held, and answers its own helper.
        let c = await ask(rig, Self.shots, toolUseID: "UC", agent: "wf-c")
        let d = await ask(rig, Self.lint, toolUseID: "UD", agent: "wf-d")
        let third = try held(rig).request
        rig.model.islandShows(requestID: third.id)
        await rig.model.decide("s1", .allowOnce, request: third.id)
        #expect((try #require(await printed(c)))["behavior"] as? String == "allow")
        await rig.settle()
        let fourth = try held(rig).request
        let fourthOpened = try #require(rig.engine.openRequests.first { $0.id == fourth.id }?.openedAt)
        #expect(fourth.answerable && fourth.holdEnds == fourthOpened.addingTimeInterval(Hold.limit))
        rig.model.islandShows(requestID: fourth.id)
        rig.advance(Hold.showGrace)
        #expect(d.isRunning)
        await rig.model.decide("s1", .deny, request: fourth.id)
        #expect((try #require(await printed(d)))["behavior"] as? String == "deny")
    }

    /// A subagent and the main thread: the subagent's card shows first (the main thread's waits for Claude's notice),
    /// and its Yes reaches its own helper only; asked again, the main thread's request, confirmed by its notice, takes
    /// the card's place as the older, the subagent's is released as the island stops showing it, and the island's Yes
    /// on the main thread's reaches the main helper only.
    @Test
    func r6ASubagentBesideTheMainThread() async throws {
        let rig = try await optedIn()
        defer { rig.stop() }
        let main = await ask(rig, E.push, toolUseID: "UM")
        rig.advance(1)
        let sub = await ask(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        let subCard = try held(rig).request
        #expect(subCard.answerable && subCard.agentType == Self.workflowAgent && rig.needsYou.count == 1)
        rig.model.islandShows(requestID: subCard.id)
        rig.advance(2)
        await rig.model.decide("s1", .allowOnce, request: subCard.id)
        #expect((try #require(await printed(sub)))["behavior"] as? String == "allow" && main.isRunning)
        await rig.settle()
        rig.model.islandShows(requestID: nil)
        await ran(rig, Self.shots, toolUseID: "UA", agent: "wf-a")

        // Again, and Claude's notice for the main thread comes while the subagent's card shows.
        let again = await ask(rig, Self.lint, toolUseID: "UB", agent: "wf-b")
        let againID = try held(rig).request.id
        rig.model.islandShows(requestID: againID)
        rig.advance(3)
        await notice(rig)
        let head = try held(rig).request
        #expect(head.agentType == nil && head.answerable && head.more == 1)
        // The island draws the main thread's card in the subagent's place: the subagent's hold ends.
        rig.model.islandShows(requestID: head.id)
        #expect(await silent(again) && main.isRunning)
        await rig.model.decide("s1", .allowOnce, request: head.id)
        let decision = try #require(await printed(main))
        #expect((decision["updatedInput"] as? [String: Any])?["command"] as? String == "git push origin main")
        await rig.settle()
        let behind = try held(rig).request
        #expect(behind.id == againID && !behind.answerable)
    }

    // MARK: Fail open

    /// The app quits mid-hold (the engine stops, as `LiveSessions.shutdown`): the helper exits silent at once and Claude
    /// builds its own prompt. A crash ends the connection the same way (the kernel closes it).
    @Test
    func r6QuittingMidHoldFailsOpen() async throws {
        let rig = try await optedIn()
        defer { rig.stop() }
        let run = await ask(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        rig.model.islandShows(requestID: try held(rig).request.id)
        rig.advance(4)
        #expect(run.isRunning)
        rig.engine.stop()
        #expect(await silent(run))
    }

    /// The main thread stuck past the hold (the engine's clock never reaches it here): the broker ends the hold by
    /// itself at its bound, the helper exits silent; the island's Yes then finds it gone, sends nothing, and turns the
    /// card read-only.
    @Test
    func r6TheBrokerEndsAHoldTheEngineCouldNot() async throws {
        let rig = try await optedIn(backstop: 1)
        defer { rig.stop() }
        let run = await ask(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        let id = try held(rig).request.id
        rig.model.islandShows(requestID: id)
        #expect(await silent(run))
        #expect(approval(rig)?.isAnswerable == true)
        await rig.model.decide("s1", .allowOnce, request: id)
        #expect(approval(rig)?.isAnswerable == false && approval(rig)?.request?.id == id)
        #expect(rig.engine.attentionTally.subagentHolds == ["brokerEnded": 1])
    }

    /// A click at the instant the hold ends: a Yes whose send runs just after the release reaches nothing (the helper
    /// ended silent, nothing is printed, and no "Not sent" shows); one just before it answers. Never a stray answer.
    @Test
    func r6AClickAtTheInstantTheHoldEndsAnswersNothing() async throws {
        let rig = try await optedIn()
        defer { rig.stop() }
        let late = await ask(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        let id = try held(rig).request.id
        rig.model.islandShows(requestID: id)
        rig.advance(try left(rig) - 0.5)
        // The click's send is on its way (a Task) as the hold ends.
        rig.model.approve("s1", .allowOnce, request: id)
        rig.advance(1)
        await rig.settle()
        #expect(await silent(late))
        let card = try #require(approval(rig))
        #expect(card.request?.id == id && !card.isAnswerable && card.send == nil)
        await ran(rig, Self.shots, toolUseID: "UA", agent: "wf-a")
        rig.model.islandShows(requestID: nil)

        let early = await ask(rig, Self.lint, toolUseID: "UB", agent: "wf-b")
        let earlyID = try held(rig).request.id
        rig.model.islandShows(requestID: earlyID)
        rig.advance(try left(rig) - 0.5)
        await rig.model.decide("s1", .allowOnce, request: earlyID)
        rig.advance(1)
        #expect((try #require(await printed(early)))["behavior"] as? String == "allow")
        #expect(rig.engine.attentionTally.subagentHolds == ["timeUp": 1])
    }
}

private extension ApprovalCardModel {
    /// The same card as the island drew it before its hold ended.
    func with(answerable: Bool) -> ApprovalCardModel {
        var card = self
        card.request?.answerable = answerable
        return card
    }
}
