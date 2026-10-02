import AppKit
import Foundation
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Lane FOCUS (P270 to P273), the owner: "there's a wierd moment when I'm back on another app but the pill is still
/// showing the cards". When another app becomes active, or a click outside takes the panel's keys, an open island folds
/// back into the pill with the normal fold, unless the pointer is on it, having moved there; what waits stays on the
/// pill and opens the island again on hover, on a click or on a new request, never by itself; a field's draft is
/// kept. The hover machine is driven as the panel drives it (`BriefDoneCardTests.Timeline` fires every timer it asks
/// for), the choreography plays the close it asks for, and the watch hears fake notices from centers of its own. The
/// one panel here is never ordered in: nothing is drawn on screen.
@MainActor
struct FocusYieldTests {
    typealias M = IslandHoverMachine
    typealias Timeline = BriefDoneCardTests.Timeline

    // MARK: The machine (P270)

    /// Every way the island stays open while nothing of the pointer's comes: a card that needs you (opened by itself,
    /// answerable or read-only alike, the machine does not tell them apart), the same with Keep open until answered,
    /// the brief Done card, and a list or card opened by a click the pointer then left the island from with Keep open.
    @Test func anOpenIslandFoldsWhenTheOwnerGoesElsewhere() {
        struct Case { var name: String; var holdOpen = false; var events: [(TimeInterval, M.Event)] }
        let cases = [
            Case(name: "needs you", events: [(0, .attention(at: 0))]),
            Case(name: "needs you, Keep open", holdOpen: true, events: [(0, .attention(at: 0))]),
            Case(name: "Done card", events: [(0, .finished(at: 0))]),
            Case(name: "clicked, left, Keep open", holdOpen: true,
                 events: [(0, .pointerEntered(at: 0)), (0.05, .clicked(at: 0.05)), (1, .pointerExited(at: 1))]),
        ]
        for c in cases {
            var timeline = Timeline()
            timeline.machine.holdOpen = c.holdOpen
            for (t, event) in c.events { timeline.send(event, at: t) }
            timeline.run(until: 2)
            #expect(timeline.closes.isEmpty && timeline.machine.isOpen, "\(c.name)")
            timeline.send(.focusLeft(pointerHolds: false, at: 2), at: 2)
            // The normal fold, at once: the choreography brings the pill back about 0.27 s later.
            #expect(timeline.closes == [2] && timeline.log.last?.effect == .close(.fold), "\(c.name)")
            #expect(timeline.machine.phase == .closed && !timeline.machine.brief && timeline.machine.openReason == nil, "\(c.name)")
            // Not a pointer close: no reverse; with the pointer away, a rest opens it again.
            #expect(timeline.machine.foldStartedAt == nil && !timeline.machine.mustLeaveBeforeReopen, "\(c.name)")
            // Nothing opens it again by itself: no timer it asked for before comes to anything.
            timeline.run(until: 600)
            #expect(timeline.closes == [2] && timeline.opens.count == 1, "\(c.name)")
        }
    }

    /// After the fold it opens again on a hover's rest, on a click, or for a new request (`.attention`), as before.
    @Test func itOpensAgainOnHoverClickOrSomethingNew() {
        func folded() -> Timeline {
            var timeline = Timeline()
            timeline.send(.attention(at: 0), at: 0)
            timeline.send(.focusLeft(pointerHolds: false, at: 5), at: 5)
            return timeline
        }
        var hover = folded()
        hover.send(.pointerEntered(at: 5.1), at: 5.1)
        // No reverse of the fold: a fresh rest (Calm, 150 ms).
        #expect(hover.opens == [0])
        hover.run(until: 5.1 + M.openDelay)
        #expect(hover.opens == [0, 5.1 + M.openDelay] && hover.machine.openReason == .hover)

        var click = folded()
        click.send(.clicked(at: 6), at: 6)
        #expect(click.opens == [0, 6] && click.machine.openReason == .click)

        var request = folded()
        request.send(.attention(at: 9), at: 9)
        #expect(request.opens == [0, 9] && request.machine.openReason == .attention)
    }

    /// The pointer on the island, where it moved, keeps it: the owner may be reading it with ⌘Tab pressed. Its next leave
    /// then closes it after the normal grace, Keep open or not, and so does the island moving off the still pointer.
    @Test func thePointerOnTheIslandKeepsItUntilItLeaves() {
        var timeline = Timeline()
        timeline.machine.holdOpen = true
        timeline.send(.pointerEntered(at: 0), at: 0)
        timeline.send(.clicked(at: 0.05), at: 0.05)
        timeline.send(.focusLeft(pointerHolds: true, at: 1), at: 1)
        timeline.run(until: 30)
        #expect(timeline.closes.isEmpty && timeline.machine.isOpen && timeline.machine.focusAway)
        timeline.send(.pointerExited(at: 30), at: 30)
        timeline.run(until: 31)
        #expect(timeline.closes == [30 + M.closeGrace])

        // Without the owner going elsewhere, Keep open holds it through the leave, as before.
        var kept = Timeline()
        kept.machine.holdOpen = true
        kept.send(.pointerEntered(at: 0), at: 0)
        kept.send(.clicked(at: 0.05), at: 0.05)
        kept.send(.pointerExited(at: 30), at: 30)
        kept.run(until: 60)
        #expect(kept.closes.isEmpty)

        // The island moving off the still pointer after the owner went elsewhere folds it too.
        var moved = Timeline()
        moved.send(.attention(at: 0), at: 0)
        moved.send(.pointerEntered(at: 1), at: 1)
        moved.send(.focusLeft(pointerHolds: true, at: 2), at: 2)
        moved.send(.pointerRelocated(inside: false), at: 3)
        #expect(moved.closes == [3] && moved.log.last?.effect == .close(.fold))

        // A new open forgets it: Keep open holds a later island again.
        var later = Timeline()
        later.machine.holdOpen = true
        later.send(.pointerEntered(at: 0), at: 0)
        later.send(.clicked(at: 0.05), at: 0.05)
        later.send(.focusLeft(pointerHolds: true, at: 1), at: 1)
        later.send(.dismissed, at: 2)
        later.send(.clicked(at: 3), at: 3)
        later.send(.pointerExited(at: 4), at: 4)
        later.run(until: 10)
        #expect(later.closes == [2] && !later.machine.focusAway)
    }

    /// The Done card under a pointer parked on the menu bar (P271): P95 still holds it there while the owner stays, but a
    /// still pointer the island opened under is not the owner's, so going elsewhere folds it. The pointer, still inside,
    /// must leave before a rest opens it again: it never opens by itself under the parked pointer.
    @Test func theDoneCardUnderAParkedPointerFoldsWhenTheOwnerGoesElsewhere() {
        var timeline = Timeline()
        timeline.send(.finished(at: 0), at: 0)
        timeline.send(.pointerRelocated(inside: true), at: 0.3)
        timeline.run(until: 10)
        #expect(timeline.closes.isEmpty)
        timeline.send(.focusLeft(pointerHolds: false, at: 10), at: 10)
        #expect(timeline.closes == [10] && timeline.machine.mustLeaveBeforeReopen)
        timeline.send(.pointerMoved(speed: 20, at: 11), at: 11)
        timeline.run(until: 20)
        #expect(timeline.opens == [0])
        timeline.send(.pointerExited(at: 20), at: 20)
        timeline.send(.pointerEntered(at: 21), at: 21)
        timeline.run(until: 22)
        #expect(timeline.opens == [0, 21 + M.openDelay])
    }

    /// Resting on the pill as the owner switches with the keyboard: the rest goes on under the pointer; a pointer the
    /// read after the change finds away ends it. Closed, nothing happens.
    @Test func aRestOnThePillAndAClosedIsland() {
        var resting = Timeline()
        resting.send(.pointerEntered(at: 0), at: 0)
        resting.send(.focusLeft(pointerHolds: true, at: 0.05), at: 0.05)
        resting.run(until: 1)
        #expect(resting.opens == [M.openDelay])

        var away = Timeline()
        away.send(.pointerEntered(at: 0), at: 0)
        away.send(.pointerMoved(speed: 10, at: 0.01), at: 0.01)
        #expect(away.machine.swollen)
        away.send(.focusLeft(pointerHolds: false, at: 0.05), at: 0.05)
        away.run(until: 1)
        #expect(away.opens.isEmpty && away.machine.phase == .closed && away.log.last?.effect == .swell(false))

        var closed = M()
        #expect(closed.handle(.focusLeft(pointerHolds: false, at: 0)) == [])
        #expect(closed.handle(.focusLeft(pointerHolds: true, at: 0)) == [])
    }

    /// Leaving just before the switch (the leave grace running): the fold starts at once, not after the grace.
    @Test func aSwitchInTheLeaveGraceFoldsAtOnce() {
        var timeline = Timeline()
        timeline.send(.pointerEntered(at: 0), at: 0)
        timeline.send(.clicked(at: 0.05), at: 0.05)
        timeline.send(.pointerExited(at: 2), at: 2)
        timeline.send(.focusLeft(pointerHolds: false, at: 2.05), at: 2.05)
        timeline.run(until: 5)
        #expect(timeline.closes == [2.05])
    }

    // MARK: The fold it plays

    /// The machine's close is the choreography's normal fold (the one a pointer's leave plays): the target closes at
    /// once, so nothing on the island takes a click, and the pill is back within about 0.3 s, from the list or a card,
    /// with Motion Original or Refined.
    @Test(arguments: [IslandPresentation.list, .card(sessionID: "r1")], [MotionFeel.original, .refined])
    func theFoldIsTheNormalCloseAndThePillIsBackWithinAboutThreeTenths(_ presentation: IslandPresentation, _ feel: MotionFeel) {
        var machine = M()
        _ = machine.handle(.attention(at: 0))
        let effects = machine.handle(.focusLeft(pointerHolds: false, at: 1))
        #expect(effects == [.close(.fold)])
        let start = IslandChoreography(metrics: .init(targets: SurfaceTargets(notch: DIslandMotionTests.notch, pill: DIslandMotionTests.referencePill),
                                                      layout: DIslandPanelSizingTests.layout(),
                                                      tuning: MotionTuning(motion: feel, hover: .calm)),
                                       surface: .island, presentation: presentation)
        var model = start
        let commands = model.handle(.close(.fold), at: 0)
        #expect(commands.contains { if case let .target(_, isOpen) = $0 { !isOpen } else { false } })
        let back = DIslandMotionTests.first(start, [(0, .close(.fold))]) { m, _ in m.values[.pill]?.target == 1 }
        #expect(back.map { $0 <= 0.3 } == true, "\(DIslandMotionTests.ms(back)) ms")
        // It folds all the way: the surface is the pill's once the fold has played.
        let end = DIslandMotionTests.first(start, [(0, .close(.fold))], until: 1.5) { m, t in
            let g = m.surface(at: t), rest = m.restGeometry
            return abs(g.height - rest.height) < 0.5 && abs(g.left - rest.left) < 0.5 && abs(g.right - rest.right) < 0.5
        }
        #expect(end != nil)
    }

    // MARK: Where the owner is (P270)

    @Test func theOwnerLeftOnAnotherAppOrAClickOutside() {
        #expect(IslandFocus.ownerLeft(.appActivated(42), frontAtOpen: 7))
        #expect(IslandFocus.ownerLeft(.appActivated(nil), frontAtOpen: 7))
        #expect(IslandFocus.ownerLeft(.appActivated(42), frontAtOpen: nil))
        #expect(IslandFocus.ownerLeft(.panelResignedKey, frontAtOpen: 7))
        // The app in front when the island opened: its notice came after an open that came after the switch.
        #expect(!IslandFocus.ownerLeft(.appActivated(7), frontAtOpen: 7))
    }

    /// The watch hears the workspace's activations and the panel's own loss of the keys (fake notices on centers of its
    /// own), nothing about another window, and nothing once stopped.
    @Test func theWatchHearsFakeWorkspaceAndPanelNotices() async {
        _ = NSApplication.shared
        final class Heard { var changes: [IslandFocusChange] = [] }
        let heard = Heard()
        let workspace = NotificationCenter(), local = NotificationCenter()
        let panel = IslandPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
        let other = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 20, height: 20), styleMask: [.borderless], backing: .buffered, defer: true)
        let watch = IslandFocusWatch(window: panel, workspace: workspace, local: local) { heard.changes.append($0) }
        func settle(_ count: Int) async {
            for _ in 0..<200 where heard.changes.count < count { try? await Task.sleep(for: .milliseconds(2)) }
        }
        let me = NSRunningApplication.current
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                       userInfo: [NSWorkspace.applicationUserInfoKey: me])
        await settle(1)
        #expect(heard.changes == [.appActivated(me.processIdentifier)])
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared)
        await settle(2)
        #expect(heard.changes.last == .appActivated(nil))
        local.post(name: NSWindow.didResignKeyNotification, object: other)
        local.post(name: NSWindow.didResignKeyNotification, object: panel)
        await settle(3)
        #expect(heard.changes.count == 3 && heard.changes.last == .panelResignedKey)
        // Another of the workspace's notices is not heard.
        workspace.post(name: NSWorkspace.didDeactivateApplicationNotification, object: NSWorkspace.shared,
                       userInfo: [NSWorkspace.applicationUserInfoKey: me])
        watch.stop()
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                       userInfo: [NSWorkspace.applicationUserInfoKey: me])
        local.post(name: NSWindow.didResignKeyNotification, object: panel)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(heard.changes.count == 3)
    }

    /// Fake notices through the watch, the rule and the machine, as the panel wires them: the owner in the terminal,
    /// a request opens the island over it (the terminal's own late notice folds nothing), then a switch to the
    /// browser folds it.
    @Test func fakeNoticesFoldTheIslandThroughTheRule() async {
        _ = NSApplication.shared
        final class Rig {
            var timeline = Timeline()
            var now: TimeInterval = 0
            var frontAtOpen: pid_t?
        }
        let rig = Rig()
        let workspace = NotificationCenter(), local = NotificationCenter()
        let panel = IslandPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
        let watch = IslandFocusWatch(window: panel, workspace: workspace, local: local) { change in
            guard rig.timeline.machine.phase != .closed, IslandFocus.ownerLeft(change, frontAtOpen: rig.frontAtOpen) else { return }
            rig.timeline.send(.focusLeft(pointerHolds: false, at: rig.now), at: rig.now)
        }
        defer { watch.stop() }
        let terminal: pid_t = 501, browser = NSRunningApplication.current
        rig.frontAtOpen = terminal
        rig.timeline.send(.attention(at: 0), at: 0)
        rig.now = 0.02
        // The terminal's own notice cannot be faked with its process (tests start no app): the rule decides it above.
        #expect(!IslandFocus.ownerLeft(.appActivated(terminal), frontAtOpen: rig.frontAtOpen))
        rig.now = 4
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                       userInfo: [NSWorkspace.applicationUserInfoKey: browser])
        for _ in 0..<200 where rig.timeline.closes.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(rig.timeline.closes == [4] && rig.timeline.log.last?.effect == .close(.fold))
        // Closed: a click outside (the panel losing its keys) does nothing more.
        local.post(name: NSWindow.didResignKeyNotification, object: panel)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.timeline.closes == [4])
    }

    // MARK: The owner's pointer (P271)

    @Test func onlyAPointerThatMovedOntoTheIslandIsTheOwners() {
        var pointer = PointerEngagement()
        // The island opened under a parked pointer: not the owner's, and an entry AppKit makes up in the same place
        // (or a poll sample of the still pointer) does not change that.
        pointer.relocated(to: CGPoint(x: 700, y: 1100))
        #expect(!pointer.engaged)
        pointer.sample(CGPoint(x: 700, y: 1100), inside: true)
        pointer.sample(CGPoint(x: 700.4, y: 1100), inside: true)
        #expect(!pointer.engaged)
        // It moves on the island: the owner's.
        pointer.sample(CGPoint(x: 704, y: 1098), inside: true)
        #expect(pointer.engaged)
        // Off the island: not; back on by moving: the owner's again.
        pointer.sample(CGPoint(x: 900, y: 800), inside: false)
        #expect(!pointer.engaged)
        pointer.sample(CGPoint(x: 720, y: 1090), inside: true)
        #expect(pointer.engaged)
        // The island moving under it ends it, inside or out.
        pointer.relocated(to: CGPoint(x: 720, y: 1090))
        #expect(!pointer.engaged)
        // The first sample ever, inside: it came from the tracking area, so it moved there.
        var fresh = PointerEngagement()
        fresh.sample(CGPoint(x: 1, y: 2), inside: true)
        #expect(fresh.engaged)
    }

    /// The owner clicked the pill (the pointer moved there), pressed Esc and left the pointer where it was: the island
    /// shrank around it, so nothing relocated it. A request later opens the island by itself under that still pointer:
    /// it is not the owner's, and going to another app folds the island (it held it there until the mouse moved). A
    /// pointer that moves on the island after the open is the owner's again; an open by a rest or a click, or anything
    /// that came while the pointer rested on the pill, keeps what the pointer did. The panel's order: the machine's phase
    /// before the event, then `opened` on its open.
    @Test func aStillPointerFromBeforeARequestOpenedTheIslandHoldsNothing() {
        let notch = CGPoint(x: 756, y: 975)
        var pointer = PointerEngagement()
        var timeline = Timeline()
        func send(_ event: M.Event, at t: TimeInterval, pointerAt location: CGPoint = notch) {
            timeline.run(until: t)
            let fromClosed = timeline.machine.phase == .closed
            let before = timeline.log.count
            timeline.send(event, at: t)
            for entry in timeline.log.dropFirst(before) {
                if case let .open(reason) = entry.effect { pointer.opened(reason, fromClosed: fromClosed, at: location) }
            }
        }
        pointer.sample(CGPoint(x: 700, y: 960), inside: false)
        pointer.sample(notch, inside: true)
        send(.pointerEntered(at: 0), at: 0)
        send(.clicked(at: 0.05), at: 0.05)
        #expect(timeline.machine.openReason == .click && pointer.engaged)
        send(.dismissed, at: 1)
        #expect(pointer.engaged)
        send(.attention(at: 30), at: 30)
        #expect(timeline.machine.openReason == .attention && !pointer.engaged)
        // `focusChanged` reads the pointer where it is (`resyncPointer`): still.
        pointer.sample(notch, inside: true)
        send(.focusLeft(pointerHolds: pointer.engaged, at: 40), at: 40)
        #expect(timeline.closes == [1, 40] && timeline.log.last?.effect == .close(.fold), "\(timeline.log.map(\.effect))")

        // The same, but the owner moves on the island after it opened: theirs, and it holds.
        var moved = PointerEngagement()
        moved.sample(notch, inside: true)
        moved.opened(.attention, fromClosed: true, at: notch)
        moved.sample(CGPoint(x: notch.x + 6, y: notch.y), inside: true)
        #expect(moved.engaged)

        // A rest or a click keeps the pointer that moved there; so does a request that came while it rested on the pill.
        for (reason, fromClosed) in [(M.OpenReason.hover, false), (.click, true), (.attention, false)] {
            var kept = PointerEngagement()
            kept.sample(CGPoint(x: 700, y: 960), inside: true)
            kept.sample(notch, inside: true)
            kept.opened(reason, fromClosed: fromClosed, at: notch)
            #expect(kept.engaged, "\(reason), from closed \(fromClosed)")
        }
    }

    // MARK: What waits stays on the pill (P272)

    static func approval(_ session: String, request: String) -> SessionCard {
        .approval(ApprovalCardModel(sessionID: session, agent: .claude, tool: "Bash", body: .command("ls"),
                                    request: CardRequest(id: request, answerable: true, place: .terminal, agentType: nil, more: 0,
                                                         isNotice: false, dismissable: false)))
    }

    /// The island's side of the rows as the panel runs it: each batch heard through `IslandPutAway.hear` against the
    /// last (`IslandPanelController.sessionsChanged`), a close's `folded()`, and the card a batch opens.
    struct Batches {
        var putAway = IslandPutAway()
        var last: [SessionRow] = []
        var cards: [String: SessionCard] = [:]

        /// A batch: the card it opens, if any.
        mutating func hear(_ rows: [SessionRow]) -> String? {
            let signals = putAway.hear(IslandAttention.signals(old: last, new: rows), rows: rows,
                                       pending: IslandAttention.pendingKeys(rows) { cards[$0] })
            last = rows
            return IslandAttention.respond(to: signals, rows: rows, finish: .card, cardInUse: false).card
        }

        mutating func fold() { putAway.folded() }
    }

    /// The owner goes to the terminal to answer: the island folds with A waiting. A repeat of A's needs-you never opens
    /// it again: its row dropping out of one batch or of several (a batch without it, a Live model's restart with no
    /// rows at all) forgets nothing. A new request does, another session's or A's own next one; once A no longer waits
    /// it is forgotten. The pill keeps A's "!" all along (it is drawn from the rows).
    @Test func aRequestTheIslandFoldedAwayFromNeverOpensItAgainByItself() {
        let a = DStub.row("a", .claude, .needsYou), b = DStub.row("b", .claude, .needsYou), c = DStub.row("c", .codex, .running)
        var island = Batches(cards: ["a": Self.approval("a", request: "A1")])
        #expect(island.hear([a, c]) == "a")
        island.fold()
        #expect(island.putAway.keys == ["a": "request:A1"])

        // A Live restart (no rows), then A back with A1: the rows alone would open the island for it again.
        #expect(island.hear([]) == nil)
        #expect(IslandAttention.signals(old: [], new: [a, c]) == [.needsYou("a")])
        #expect(island.hear([a, c]) == nil)
        // A batch without A's row, then A back.
        #expect(island.hear([c]) == nil)
        #expect(island.hear([a, c]) == nil)
        #expect(island.putAway.keys == ["a": "request:A1"])
        let lead = HideWhenIdleTests.pill([a], hide: false).lead
        #expect(lead?.glyph == .bang && lead?.state == .waiting)

        // A new session that needs you opens it, as before.
        island.cards["b"] = Self.approval("b", request: "B1")
        #expect(island.hear([a, b, c]) == "b")

        // A answered at its own prompt (its row runs), then A's session asks again: A2, a new request, opens it.
        #expect(island.hear([DStub.row("a", .claude, .running), b, c]) == nil)
        #expect(island.putAway.keys.isEmpty)
        island.cards["a"] = Self.approval("a", request: "A2")
        #expect(island.hear([a, b, c]) == "a")

        // The next request in the same batch as the last one's status word (A2 folded away, A3 as a question): new.
        island.fold()
        island.cards["a"] = Self.approval("a", request: "A3")
        #expect(island.hear([DStub.row("a", .claude, .needsYou, status: .question), b, c]) == "a")
        #expect(island.putAway.keys["a"] == nil)

        // Finishes are never filtered; a failed turn is kept by its session and status, until the session runs again.
        let failed = DStub.row("f", .claude, .needsYou, status: .failed)
        #expect(IslandAttention.requestKey(failed, card: nil) == "row:f:failed")
        var turns = Batches()
        #expect(turns.hear([failed]) == "f")
        turns.fold()
        #expect(turns.putAway.hear([.finished("d"), .needsYou("f")], rows: [failed], pending: ["f": "row:f:failed"]) == [.finished("d")])
        #expect(turns.hear([]) == nil && turns.hear([failed]) == nil)
        #expect(turns.hear([DStub.row("f", .claude, .running)]) == nil && turns.putAway.keys.isEmpty)
        #expect(turns.hear([failed]) == "f")
    }

    /// A close puts away what the island last heard, never a request the engine has that no batch has brought yet (the
    /// sessions observer's turn still queued behind the close: a leave's grace timer, a focus notice): that request's
    /// first needs-you still opens the island. The rows the island found as it showed count as heard.
    @Test func aCloseBeforeTheBatchPutsAwayOnlyWhatTheIslandHeard() {
        let a = DStub.row("a", .claude, .needsYou), b = DStub.row("b", .claude, .needsYou)
        var island = Batches(cards: ["a": Self.approval("a", request: "A1"), "b": Self.approval("b", request: "B1")])
        #expect(island.hear([a]) == "a")
        // B1 is in the engine; the close runs first.
        island.fold()
        #expect(island.putAway.keys == ["a": "request:A1"])
        #expect(island.hear([a, b]) == "b")

        // Shown with A waiting (Window mode, then Island): a close before any batch puts A away.
        var shown = Batches(cards: island.cards)
        #expect(shown.putAway.hear([], rows: [a], pending: IslandAttention.pendingKeys([a]) { shown.cards[$0] }).isEmpty)
        shown.last = [a]
        shown.fold()
        #expect(shown.hear([]) == nil && shown.hear([a]) == nil)
    }

    // MARK: Drafts (P273)

    @Test func draftsAreKeptPerCardRequestAndField() {
        let drafts = CardDrafts()
        let a1 = Self.approval("a", request: "A1"), a2 = Self.approval("a", request: "A2")
        let slot = try! #require(drafts.slot(for: a1))
        slot.keep("keep the old API", for: "Why not?")
        #expect(slot.text(for: "Why not?") == "keep the old API" && slot.text(for: "Reply…") == nil)
        // The same session's next request, another session, a quota notice: none of them has it.
        #expect(drafts.slot(for: a2)?.text(for: "Why not?") == nil)
        #expect(drafts.slot(for: Self.approval("b", request: "A1"))?.text(for: "Why not?") == nil)
        let question = { (step: Int) in
            SessionCard.question(QuestionCardModel(sessionID: "q", agent: .claude, topic: nil, question: "Which?", options: [], step: step,
                                                   count: 2))
        }
        drafts.slot(for: question(0))?.keep("the second", for: "Type your answer…")
        #expect(drafts.slot(for: question(1))?.text(for: "Type your answer…") == nil)
        // Sent (the field emptied): gone.
        slot.keep("", for: "Why not?")
        #expect(slot.text(for: "Why not?") == nil)
        slot.keep("again", for: "Why not?")
        // Pruned with its card: A1 answered, the question on to its second step.
        drafts.prune(keeping: [a1, question(0)])
        #expect(!drafts.isEmpty)
        drafts.prune(keeping: [a2, question(1)])
        #expect(drafts.isEmpty)
    }

    /// The live island's field keeps what it holds in its card's drafts and has it again when the card's views come
    /// back after a fold; a field with no drafts (the window, a render) starts empty. Hosted in a panel never ordered in.
    @Test func aFieldHasItsDraftAgainAfterItsCardCameBack() async throws {
        _ = NSApplication.shared
        let drafts = CardDrafts()
        let card = Self.approval("a", request: "A1")
        let slot = try #require(drafts.slot(for: card))
        let panel = IslandPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 60), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
        func host(_ slot: CardDraftSlot?) -> NSHostingView<AnyView> {
            let view = NSHostingView(rootView: AnyView(AnswerFieldView(placeholder: "Why not?") { _ in }
                .environment(\.cardDraftSlot, slot).frame(width: 400)))
            view.frame = CGRect(x: 0, y: 0, width: 420, height: 60)
            panel.contentView = view
            view.layoutSubtreeIfNeeded()
            return view
        }
        func field(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            for sub in view.subviews { if let found = field(sub) { return found } }
            return nil
        }
        func settle(_ done: () -> Bool) async {
            for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
        }

        // The owner types into the field.
        let first = host(slot)
        let typed = try #require(field(first))
        #expect(panel.makeFirstResponder(typed))
        let editor = try #require(panel.firstResponder as? NSTextView)
        editor.insertText("keep the old API", replacementRange: NSRange(location: 0, length: 0))
        await settle { slot.text(for: "Why not?") == "keep the old API" }
        #expect(slot.text(for: "Why not?") == "keep the old API")

        // The island folds: the card's views go. They come back with the draft.
        panel.makeFirstResponder(nil)
        panel.contentView = NSView()
        let second = host(slot)
        await settle { field(second)?.stringValue == "keep the old API" }
        #expect(field(second)?.stringValue == "keep the old API")

        // The same session's next request takes the card's place in the same views: never the text typed for the one
        // before; back to the first request (a render of both, as a test can), its own draft again.
        let next = try #require(drafts.slot(for: Self.approval("a", request: "A2")))
        second.rootView = AnyView(AnswerFieldView(placeholder: "Why not?") { _ in }.environment(\.cardDraftSlot, next).frame(width: 400))
        await settle { field(second)?.stringValue.isEmpty == true }
        #expect(field(second)?.stringValue.isEmpty == true && next.text(for: "Why not?") == nil)
        second.rootView = AnyView(AnswerFieldView(placeholder: "Why not?") { _ in }.environment(\.cardDraftSlot, slot).frame(width: 400))
        await settle { field(second)?.stringValue == "keep the old API" }
        #expect(field(second)?.stringValue == "keep the old API")

        // With no drafts (the window's card, a render): empty.
        let plain = host(nil)
        await settle { false }
        #expect(field(plain)?.stringValue.isEmpty == true)
    }

    /// In the live island only the live card layer hands its fields their drafts (`IslandCardRole`, with its reporters,
    /// P231): a card built ahead keeps its field empty, and takes its draft as it goes live, in the switch that is a write
    /// of the channels and the roles (E4(c)). The live island as the panel hosts it, never ordered in.
    @Test func aCardBuiltAheadTakesItsDraftAsItGoesLive() throws {
        let island = LiveIslandHarness(presenting: FixtureSessionFeed.ID.approval)
        defer { island.close() }
        let question = try #require(island.env.card(for: FixtureSessionFeed.ID.question))
        let placeholder = "Type your answer…"
        try #require(island.ui.drafts.slot(for: question)).keep("the staging one", for: placeholder)
        func fields(_ view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []) + view.subviews.flatMap(fields)
        }
        island.ui.aheadCard = question
        island.settle(0.2)
        let ahead = fields(island.hosting)
        #expect(!ahead.isEmpty && ahead.allSatisfy { $0.stringValue.isEmpty }, "\(ahead.map(\.stringValue))")
        island.present(.card(sessionID: FixtureSessionFeed.ID.question))
        island.settle(0.3)
        let live = fields(island.hosting).map(\.stringValue)
        #expect(island.ui.card?.sessionID == FixtureSessionFeed.ID.question && live.contains("the staging one"), "\(live)")
    }
}
