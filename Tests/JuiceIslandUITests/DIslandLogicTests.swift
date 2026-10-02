import Foundation
import IslandEngine
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// Stream D: the hover state machine (P35), the island's keys (P39, P40), what opens a card, the list and the Clean
/// money fitting. Pure values only; no panel is shown.
struct DIslandHoverMachineTests {
    typealias M = IslandHoverMachine

    /// Enters at `t` and rests (no sample faster than `restSpeed`) until the open delay fires; returns its effects.
    private func rest(_ m: inout M, at t: TimeInterval) -> [M.Effect] {
        let scheduled = m.handle(.pointerEntered(at: t))
        guard case let .schedule(delay, generation)? = scheduled.last else { return scheduled }
        #expect(delay == M.openDelay)
        return m.handle(.timerFired(generation: generation, at: t + delay))
    }

    /// Leaves at `t` once landed and waits out the grace.
    private func leaveAndWait(_ m: inout M, at t: TimeInterval) -> [M.Effect] {
        let scheduled = m.handle(.pointerExited(at: t))
        guard case let .schedule(delay, generation)? = scheduled.last else { return scheduled }
        #expect(delay == M.closeGrace)
        return m.handle(.timerFired(generation: generation, at: t + delay))
    }

    private func generation(_ effects: [M.Effect]) -> Int? {
        effects.compactMap { if case let .schedule(_, g) = $0 { g } else { nil } }.last
    }

    @Test func theTimingsAreTheSpecs() {
        #expect(M.openDelay == 0.15 && M.restSpeed == 120 && M.swellSpeed == 800 && M.closeGrace == 0.15 && M.band == 8)
        #expect(M.openingGrace == 0.04 && M.abortWindow == 0.12 && M.landedAfter == 0.35 && M.reverseWindow == 0.40)
    }

    @Test func aRestOpensAndLeavingCloses() {
        var m = M()
        #expect(rest(&m, at: 0) == [.open(.hover)])
        #expect(m.isOpen && m.landed(at: 0.6) && !m.landed(at: 0.3))
        #expect(leaveAndWait(&m, at: 2) == [.close(.fold)])
        #expect(m.phase == .closed && m.foldStartedAt == 2 + M.closeGrace)
    }

    @Test func passingOverWithoutRestingNeverOpens() {
        var m = M()
        let g = generation(m.handle(.pointerEntered(at: 0)))
        #expect(m.handle(.pointerExited(at: 0.05)).isEmpty)
        #expect(m.handle(.timerFired(generation: g ?? -1, at: 0.15)).isEmpty)
        #expect(m.phase == .closed)
    }

    @Test func fastMotionRestartsTheRest() {
        var m = M()
        let first = generation(m.handle(.pointerEntered(at: 0)))
        // 400 pt/s at 0.1 s: the rest starts again, so the first timer is stale.
        let moved = m.handle(.pointerMoved(speed: 400, at: 0.1))
        #expect(moved.contains(.swell(true)))
        let second = generation(moved)
        #expect(second != nil && second != first)
        #expect(m.handle(.timerFired(generation: first ?? -1, at: 0.15)).isEmpty)
        // A slow sample does not restart it.
        #expect(generation(m.handle(.pointerMoved(speed: 60, at: 0.2))) == nil)
        #expect(m.handle(.timerFired(generation: second ?? -1, at: 0.25)) == [.open(.hover)])
    }

    @Test func aSweepNeverOpensOrSwells() {
        var m = M()
        var g = generation(m.handle(.pointerEntered(at: 0)))
        for i in 1...20 {
            let t = Double(i) * 0.016
            let effects = m.handle(.pointerMoved(speed: 1500, at: t))
            #expect(!effects.contains(.swell(true)))
            // Each fast sample restarts the rest; the old timer fires stale.
            #expect(m.handle(.timerFired(generation: g ?? -1, at: t)).isEmpty)
            g = generation(effects)
        }
        #expect(m.handle(.pointerExited(at: 0.33)).isEmpty)
        #expect(m.phase == .closed && !m.swollen)
    }

    @Test func swellWaitsForASlowSample() {
        var m = M()
        let entered = m.handle(.pointerEntered(at: 0))
        #expect(!entered.contains(.swell(true)))
        #expect(m.handle(.pointerMoved(speed: 900, at: 0.01)).contains(.swell(true)) == false)
        #expect(m.handle(.pointerMoved(speed: 700, at: 0.02)).contains(.swell(true)))
        // Only once; leaving unswells.
        #expect(!m.handle(.pointerMoved(speed: 10, at: 0.03)).contains(.swell(true)))
        #expect(m.handle(.pointerExited(at: 0.05)) == [.swell(false)])
    }

    @Test func leavingWithin120msAborts() {
        var m = M()
        _ = rest(&m, at: 0)
        #expect(m.handle(.pointerExited(at: 0.15 + 0.09)) == [.close(.abort)])
        #expect(m.phase == .closed && m.foldStartedAt == 0.15 + 0.09)
    }

    @Test func leavingWhileOpeningRetreatsWithA40msGrace() {
        var m = M()
        _ = rest(&m, at: 0)
        let left = m.handle(.pointerExited(at: 0.15 + 0.2))
        #expect(left.first == .retreat)
        guard case let .schedule(delay, g)? = left.last else { Issue.record("no grace"); return }
        #expect(delay == M.openingGrace)
        #expect(m.handle(.timerFired(generation: g, at: 0.39)) == [.close(.fold)])
    }

    @Test func comingBackDuringTheRetreatResumes() {
        var m = M()
        _ = rest(&m, at: 0)
        let left = m.handle(.pointerExited(at: 0.35))
        #expect(m.handle(.pointerEntered(at: 0.37)) == [.resume])
        #expect(m.handle(.timerFired(generation: generation(left) ?? -1, at: 0.39)).isEmpty)
        #expect(m.phase == .open)
    }

    @Test func leavingAfterLandingWaits150ms() {
        var m = M()
        _ = rest(&m, at: 0)
        let left = m.handle(.pointerExited(at: 1))
        #expect(left == [.schedule(after: M.closeGrace, generation: m.generation)])
    }

    @Test func comingBackInsideTheGraceKeepsItOpen() {
        var m = M()
        _ = rest(&m, at: 0)
        let g = generation(m.handle(.pointerExited(at: 1)))
        #expect(m.handle(.pointerEntered(at: 1.05)).isEmpty)
        #expect(m.handle(.timerFired(generation: g ?? -1, at: 1.15)).isEmpty)
        #expect(m.phase == .open)
    }

    @Test func backWithinTheFoldReverses() {
        var m = M()
        _ = rest(&m, at: 0)
        _ = leaveAndWait(&m, at: 1)
        // The fold began at 1.15; back 0.3 s into it: the open runs at once, from where the fold is.
        #expect(m.handle(.pointerEntered(at: 1.45)) == [.open(.hover)])
    }

    @Test func afterTheFoldAFreshRestIsNeeded() {
        var m = M()
        _ = rest(&m, at: 0)
        _ = leaveAndWait(&m, at: 1)
        let entered = m.handle(.pointerEntered(at: 1.15 + 0.41))
        guard case .schedule(M.openDelay, _)? = entered.last else { Issue.record("expected the open delay"); return }
        #expect(m.phase == .opening)
    }

    @Test func afterEscThePointerMustLeaveAndComeBack() {
        var m = M()
        _ = rest(&m, at: 0)
        #expect(m.handle(.dismissed) == [.close(.dismiss)])
        #expect(m.mustLeaveBeforeReopen && m.foldStartedAt == nil)
        // Still inside (a spurious enter, a move): nothing opens.
        #expect(m.handle(.pointerEntered(at: 1)).isEmpty)
        #expect(m.handle(.pointerMoved(speed: 10, at: 1.1)).isEmpty)
        #expect(m.phase == .closed)
        // Leave, then come back: a normal rest opens it; no reverse after a dismissal.
        #expect(m.handle(.pointerExited(at: 2)).isEmpty)
        #expect(rest(&m, at: 2.2) == [.open(.hover)])
    }

    @Test func aClickOpensAtOnceAndClearsTheLeaveRule() {
        var m = M()
        _ = rest(&m, at: 0)
        _ = m.handle(.dismissed)
        #expect(m.handle(.clicked(at: 1)) == [.open(.click)])
        #expect(!m.mustLeaveBeforeReopen && m.openReason == .click)
    }

    /// It opens only when closed; on the open island a request only starts its idle time again (P292).
    @Test func attentionOpensOnlyWhenClosed() {
        var m = M()
        #expect(m.handle(.attention(at: 0)) == [.open(.attention), .schedule(after: M.attentionIdle, generation: m.generation)])
        #expect(m.handle(.attention(at: 0.1)) == [.schedule(after: M.attentionIdle, generation: m.generation)])
        _ = m.handle(.pointerEntered(at: 0.2))
        #expect(m.handle(.attention(at: 0.3)).isEmpty && m.phase == .open)
    }

    @Test func keepOpenUntilDecisionIgnoresLeaving() {
        var m = M()
        _ = m.handle(.attention(at: 0))
        _ = m.handle(.pointerEntered(at: 0))
        m.holdOpen = true
        #expect(m.handle(.pointerExited(at: 1)).isEmpty)
        #expect(m.phase == .open)
        m.holdOpen = false
        #expect(m.handle(.dismissed) == [.close(.dismiss)])
    }

    @Test func staleTimersAreIgnored() {
        var m = M()
        let first = generation(m.handle(.pointerEntered(at: 0)))
        _ = m.handle(.clicked(at: 0.05))
        #expect(m.handle(.timerFired(generation: first ?? -1, at: 0.15)).isEmpty)
        #expect(m.phase == .open && m.openReason == .click)
    }

    @Test func aRelocationNeverOpensOrCloses() {
        var m = M()
        // The pill grows under a still pointer: inside now, but nothing opens until it moves.
        #expect(m.handle(.pointerRelocated(inside: true)).isEmpty)
        #expect(m.phase == .closed && m.pointerInside)
        // Open, then the island shrinks away from a still pointer: it stays open.
        _ = m.handle(.clicked(at: 1))
        #expect(m.handle(.pointerRelocated(inside: false)).isEmpty)
        #expect(m.phase == .open)
    }

    @Test func aRelocationOutsideClearsTheLeaveRule() {
        var m = M()
        _ = rest(&m, at: 0)
        _ = m.handle(.dismissed)
        #expect(m.mustLeaveBeforeReopen)
        #expect(m.handle(.pointerRelocated(inside: false)).isEmpty)
        #expect(!m.mustLeaveBeforeReopen)
    }

    @Test func aMoveAfterARelocationInsideStartsTheRest() {
        var m = M()
        _ = m.handle(.pointerRelocated(inside: true))
        let moved = m.handle(.pointerMoved(speed: 30, at: 2))
        #expect(m.phase == .opening)
        #expect(moved.contains(.swell(true)))
        guard case let .schedule(M.openDelay, g)? = moved.first else { Issue.record("no rest"); return }
        #expect(m.handle(.timerFired(generation: g, at: 2.15)) == [.open(.hover)])
    }

    @Test func pointerSpeedIsTheMeanOverTheLast40ms() {
        var speed = PointerSpeed()
        _ = speed.add(CGPoint(x: 0, y: 0), at: 0)
        _ = speed.add(CGPoint(x: 4, y: 0), at: 0.01)
        #expect(abs(speed.add(CGPoint(x: 8, y: 0), at: 0.02) - 400) < 0.001)
        // A pause: the old samples fall out of the window.
        #expect(speed.add(CGPoint(x: 8, y: 0), at: 1) < 10)
        #expect(speed.add(CGPoint(x: 8, y: 0), at: 1.02) == 0)
    }
}

struct DIslandKeyTests {
    static let question = SessionCard.question(QuestionCardModel(
        sessionID: "q", agent: .claude, topic: "App name", question: "Which name?",
        options: [.init(label: "A", description: ""), .init(label: "B", description: ""), .init(label: "C", description: "")]))
    static let approval = SessionCard.approval(ApprovalCardModel(sessionID: "a", agent: .claude, tool: "Bash", body: .command("git push"),
                                                                  reason: nil, alwaysAllowLabel: "Yes, allow git push in this project"))
    static let approvalNoRule = SessionCard.approval(ApprovalCardModel(sessionID: "b", agent: .claude, tool: "Bash", body: .command("rm"),
                                                                        reason: nil, alwaysAllowLabel: nil))
    static let plan = SessionCard.plan(PlanCardModel(sessionID: "p", agent: .claude, plan: nil, steps: nil))

    private func key(_ c: String, control: Bool = false, shift: Bool = false, command: Bool = false, option: Bool = false,
                     marked: Bool = false) -> IslandKeyPress {
        IslandKeyPress(characters: c, control: control, shift: shift, command: command, option: option, hasMarkedText: marked)
    }

    @Test func commandQNeverQuitsWhateverElseIsHeld() {
        for control in [false, true] {
            for shift in [false, true] {
                for option in [false, true] {
                    let press = key(shift ? "Q" : "q", control: control, shift: shift, command: true, option: option)
                    #expect(IslandKeyRouter.command(for: press, card: Self.approval) == .swallow)
                }
            }
        }
    }

    @Test func everyBoundKeyMapsToAnIslandCommand() {
        #expect(IslandKeyRouter.command(for: key("\u{1b}"), card: Self.question) == .close)
        #expect(IslandKeyRouter.command(for: key("g", control: true), card: Self.question) == .jumpToNextNeedsYou)
        #expect(IslandKeyRouter.command(for: key("I", shift: true, command: true), card: Self.question) == .showAsWindow)
        #expect(IslandKeyRouter.command(for: key(",", command: true), card: Self.question) == .openSettings)
        #expect(IslandKeyRouter.command(for: key("a", control: true), card: Self.approval) == .approve(sessionID: "a", .allowOnce))
        #expect(IslandKeyRouter.command(for: key("d", control: true), card: Self.approval) == .approve(sessionID: "a", .deny))
        #expect(IslandKeyRouter.command(for: key("A", control: true, shift: true), card: Self.approval) == .approve(sessionID: "a", .alwaysAllow))
        #expect(IslandKeyRouter.command(for: key("2", control: true), card: Self.question) == .chooseOption(sessionID: "q", index: 1))
        // A card key the card cannot take does nothing: never another card's (P351).
        #expect(IslandKeyRouter.command(for: key("a", control: true), card: Self.question) == nil)
        #expect(IslandKeyRouter.command(for: key("2", control: true), card: Self.approval) == nil)
        // A letter without Control is typing, not a shortcut.
        #expect(IslandKeyRouter.command(for: key("a"), card: Self.approval) == nil)
    }

    @Test func alwaysAllowNeedsClaudesOwnRule() {
        #expect(IslandKeyRouter.command(for: key("A", control: true, shift: true), card: Self.approvalNoRule) == nil)
        #expect(IslandKeyRouter.command(for: key("a", control: true), card: Self.approvalNoRule) == .approve(sessionID: "b", .allowOnce))
    }

    @Test func optionKeysStopAtTheOptionCount() {
        #expect(IslandKeyRouter.command(for: key("3", control: true), card: Self.question) == .chooseOption(sessionID: "q", index: 2))
        #expect(IslandKeyRouter.command(for: key("4", control: true), card: Self.question) == nil)
        #expect(IslandKeyRouter.command(for: key("0", control: true), card: Self.question) == nil)
    }

    @Test func planTakesYesAndNo() {
        #expect(IslandKeyRouter.command(for: key("a", control: true), card: Self.plan) == .approve(sessionID: "p", .allowOnce))
        #expect(IslandKeyRouter.command(for: key("d", control: true), card: Self.plan) == .approve(sessionID: "p", .deny))
    }

    @Test func charactersNotKeyCodes() {
        // AZERTY: ⌃⇧& types "1"; Dvorak's G is wherever the layout puts it, and reads "g".
        #expect(IslandKeyRouter.command(for: key("1", control: true, shift: true), card: Self.question) == .chooseOption(sessionID: "q", index: 0))
        #expect(IslandKeyRouter.command(for: key("g", control: true), card: nil) == .jumpToNextNeedsYou)
    }

    @Test func markedTextBelongsToTheInputMethod() {
        for press in [key("\u{1b}"), key("g", control: true), key("a", control: true), key("q", command: true)] {
            var composing = press
            composing.hasMarkedText = true
            #expect(IslandKeyRouter.command(for: composing, card: Self.approval) == nil)
        }
    }

    @Test func optionModifiedKeysAreLeftAlone() {
        #expect(IslandKeyRouter.command(for: key("a", control: true, option: true), card: Self.approval) == nil)
        #expect(IslandKeyRouter.command(for: key("\u{1b}", option: true), card: nil) == nil)
    }
}

struct DIslandListTests {
    func row(_ id: String, _ agent: GlyphPalette.Agent, _ bucket: SessionBucket, status: StatusWord = .working) -> SessionRow {
        SessionRow(id: id, agent: agent, bucket: bucket, project: "p", task: id, status: status, detail: nil, lastPrompt: nil,
                   host: nil, accountAlias: nil, updatedAt: Date(timeIntervalSince1970: 0), isCodexApp: false, glyph: .eq,
                   glyphState: .running, hasCard: bucket == .needsYou)
    }

    @Test func fourRowsThenShowAll() {
        let rows = [row("q", .claude, .needsYou), row("r1", .claude, .running), row("r2", .codex, .running), row("r0", .claude, .running),
                    row("r3", .codex, .running), row("d2", .codex, .done, status: .done)]
        // Every row is as old as the clock: all of them active.
        let now = Date(timeIntervalSince1970: 0)
        let clean = IslandListLayout.make(rows: rows, style: .clean, showAll: false, now: now)
        // Needs you, what runs (Codex's running chats after the others), then what finished (Codex idle last, P291).
        #expect(clean.shown.map(\.id) == ["q", "r1", "r0", "r2"] && clean.hidden.map(\.id) == ["r3", "d2"] && clean.total == 6)
        #expect(clean.codexGroup.isEmpty)
        #expect(clean.footerMarks == [.running(.codex), .idle])
        #expect(clean.showsFooter && clean.footer == .more(2))

        // Detailed's Codex group shows both hidden rows: nothing is left for a footer, so none shows (not "Earlier").
        let detailed = IslandListLayout.make(rows: rows, style: .detailed, showAll: false, now: now)
        #expect(detailed.codexGroup.map(\.id) == ["r3", "d2"])
        #expect(!detailed.showsFooter)

        let all = IslandListLayout.make(rows: rows, style: .clean, showAll: true, now: now)
        #expect(all.shown.count == 6 && all.hidden.isEmpty)
    }

    @Test func whatOpensACard() {
        let running = [row("s", .claude, .running)]
        #expect(IslandAttention.signals(old: running, new: [row("s", .claude, .needsYou, status: .question)]) == [.needsYou("s")])
        #expect(IslandAttention.signals(old: running, new: [row("s", .claude, .done, status: .done)]) == [.finished("s")])
        // An interrupt is not a finish; a row that first appears done is old news; an unchanged question stays quiet.
        #expect(IslandAttention.signals(old: running, new: [row("s", .claude, .done, status: .interrupted)]).isEmpty)
        #expect(IslandAttention.signals(old: [], new: [row("s", .claude, .done, status: .done)]).isEmpty)
        let asking = [row("s", .claude, .needsYou, status: .question)]
        #expect(IslandAttention.signals(old: asking, new: asking).isEmpty)
    }

    @Test func finishFollowsTheSetting() {
        #expect(IslandAttention.outcome(.finished("s"), finish: .card) == .openCard("s"))
        #expect(IslandAttention.outcome(.finished("s"), finish: .glance) == .glance)
        #expect(IslandAttention.outcome(.needsYou("s"), finish: .glance) == .openCard("s"))
    }

    @Test func aCardAnsweredElsewhereFallsBackToTheList() {
        #expect(IslandAttention.validated(.card(sessionID: "s")) { _ in false } == .list)
        #expect(IslandAttention.validated(.card(sessionID: "s")) { _ in true } == .card(sessionID: "s"))
    }

    @Test func cleanMoneyDropsSourcesInOrderAndKeepsAnUrgentRunway() {
        func item(_ id: String, _ emphasis: MoneyRowModel.Emphasis = .normal) -> MoneyRowModel {
            MoneyRowModel(id: id, name: id, amount: "$1", emphasis: emphasis, hoverLabel: id, suffixIsRunway: id == "RunPod" || id == "Vast.ai")
        }
        let row = [item("OpenAI"), item("RunPod"), item("Hetzner")]
        let order = CleanMoneyLayout.dropOrder
        #expect(CleanMoneyLayout.fit(row, width: 400, dropOrder: order) { _ in 100 }.map(\.id) == ["OpenAI", "RunPod", "Hetzner"])
        #expect(CleanMoneyLayout.fit(row, width: 214, dropOrder: order) { _ in 100 }.map(\.id) == ["OpenAI", "RunPod"])
        #expect(CleanMoneyLayout.fit(row, width: 100, dropOrder: order) { _ in 100 }.map(\.id) == ["RunPod"])
        let urgent = [item("OpenAI"), item("RunPod", .attention), item("Hetzner")]
        #expect(CleanMoneyLayout.fit(urgent, width: 100, dropOrder: order) { _ in 100 }.map(\.id) == ["RunPod"])
        #expect(CleanMoneyLayout.fit(row, width: 10, dropOrder: order) { _ in 100 }.isEmpty)
        // Vast.ai's runway stays too while it is urgent; a new source leaves from the end.
        let vast = [item("Vast.ai", .attention), item("DeepSeek"), item("Hetzner")]
        #expect(CleanMoneyLayout.fit(vast, width: 100, dropOrder: order) { _ in 100 }.map(\.id) == ["Vast.ai"])
        #expect(CleanMoneyLayout.fit(vast, width: 214, dropOrder: order) { _ in 100 }.map(\.id) == ["Vast.ai", "DeepSeek"])
    }

    /// A source's further keys leave the island's Clean line where its first does, and before it (P149): Hetzner's
    /// second key never stays once Hetzner has gone, and neither do OpenAI's or RunPod's.
    @Test func cleanMoneyDropsASourcesFurtherKeysWithItsFirst() {
        func item(_ id: String) -> MoneyRowModel { MoneyRowModel(id: id, name: id, amount: "$1", hoverLabel: id) }
        let order = CleanMoneyLayout.dropOrder
        let hetzner = ["OpenRouter", "Hetzner", "Hetzner 2", "DeepSeek"].map(item)
        #expect(CleanMoneyLayout.fit(hetzner, width: 328, dropOrder: order) { _ in 100 }.map(\.id) == ["OpenRouter", "Hetzner", "DeepSeek"])
        #expect(CleanMoneyLayout.fit(hetzner, width: 214, dropOrder: order) { _ in 100 }.map(\.id) == ["OpenRouter", "DeepSeek"])
        for source in ["OpenAI", "RunPod"] {
            let row = [source, "\(source) 2", "DeepSeek"].map(item)
            #expect(CleanMoneyLayout.fit(row, width: 214, dropOrder: order) { _ in 100 }.map(\.id) == [source, "DeepSeek"])
            #expect(CleanMoneyLayout.fit(row, width: 100, dropOrder: order) { _ in 100 }.map(\.id) == ["DeepSeek"])
        }
        // A source out of the drop order leaves from the end, its further keys first.
        let openRouter = ["OpenRouter", "OpenRouter 2", "DeepSeek", "DeepSeek 2"].map(item)
        #expect(CleanMoneyLayout.fit(openRouter, width: 214, dropOrder: order) { _ in 100 }.map(\.id) == ["OpenRouter", "OpenRouter 2"])
    }

    @Test func onlyARunwayKeepsItsSuffixInClean() {
        #expect(CleanMoneyLayout.showsSuffix(MoneyRowModel(id: "RunPod", name: "RunPod", amount: "$2,310", suffix: "52d", hoverLabel: "",
                                                           suffixIsRunway: true)))
        #expect(CleanMoneyLayout.showsSuffix(MoneyRowModel(id: "Vast.ai 2", name: "GPU", amount: "$86", suffix: "63h", hoverLabel: "",
                                                           suffixIsRunway: true)))
        #expect(!CleanMoneyLayout.showsSuffix(MoneyRowModel(id: "Hetzner", name: "Hetzner", amount: "€153", suffix: "/mo", hoverLabel: "")))
        #expect(!CleanMoneyLayout.showsSuffix(MoneyRowModel(id: "RunPod", name: "RunPod", amount: "$2,310", suffix: "52d", hoverLabel: "")))
    }

    @Test func hoverIDsRoundTrip() {
        #expect(IslandHoverIDs.target(IslandHoverIDs.money("RunPod")) == .money("RunPod"))
        #expect(IslandHoverIDs.target(IslandHoverIDs.provider(.codex)) == .provider(.codex))
        #expect(IslandHoverIDs.target("acct-1") == .account("acct-1"))
    }

    @Test func usageShowsInTheStripOrTheBlockNeverBoth() {
        typealias F = IslandUsageFold
        // Header strip: folded into the header until clicked, then the block takes the strip's place.
        #expect(F(listing: true, showsUsage: true, placement: .headerStrip, stripOpen: false) == F.of(strip: true, block: false))
        #expect(F(listing: true, showsUsage: true, placement: .headerStrip, stripOpen: true) == F.of(strip: false, block: true))
        // Section: always the block.
        #expect(F(listing: true, showsUsage: true, placement: .section, stripOpen: false) == F.of(strip: false, block: true))
        // A card: the block goes; in Header strip placement the strip stays in the header, opened or not.
        for open in [false, true] {
            #expect(F(listing: false, showsUsage: true, placement: .headerStrip, stripOpen: open) == F.of(strip: true, block: false))
            #expect(F(listing: false, showsUsage: true, placement: .section, stripOpen: open) == F.of(strip: false, block: false))
        }
        // Usage off: neither.
        for placement in UsagePlacement.allCases {
            for open in [false, true] {
                for listing in [false, true] {
                    #expect(F(listing: listing, showsUsage: false, placement: placement, stripOpen: open) == F.of(strip: false, block: false))
                }
            }
        }
    }

    @MainActor @Test func theStripShowsTheNextBatteryWithoutItsBar() throws {
        let env = AppEnvironment.demo()
        let row = try #require(env.usage.claudeRow)
        let next = try #require(row.batteries.first { $0.isNext })
        let shown = try #require(HeaderStripPair.battery(row))
        #expect(shown.id == next.id)
        #expect(!shown.isNext)
    }
}

private extension IslandUsageFold {
    static func of(strip: Bool, block: Bool) -> IslandUsageFold {
        var fold = IslandUsageFold(listing: false, showsUsage: false, placement: .section, stripOpen: false)
        fold.strip = strip
        fold.block = block
        return fold
    }
}
