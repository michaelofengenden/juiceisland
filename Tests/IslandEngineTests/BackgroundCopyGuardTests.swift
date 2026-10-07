import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine

/// What the ship's review of wave 8 found (P1541, P1542, P1545): a background card never attaches to its copy while a
/// terminal runs the conversation, a held reply never lands in an attached window in front, and a session in Claude
/// Code's background has no tab, whatever terminal its notes name. Headless, as `ClaudeBackgroundTests`: every
/// command, window, scan and process is a stand-in.
@MainActor
struct BackgroundCopyGuardTests {
    typealias C = ClaudeBackgroundTests
    typealias F = EngineFixtures

    static let stopped = C.json([C.row("background", id: C.short, session: C.newID, state: "stopped", status: nil, pid: nil)])
    static let idle = C.json([C.row("background", id: C.short, session: C.newID, state: "done", status: "idle")])
    /// The owner ran `claude --resume <id>` in a terminal once its copy stopped: Claude Code lists that interactive copy.
    static let resumedByHand = C.json([C.row("background", id: C.short, session: C.newID, state: "stopped", status: nil, pid: nil),
                                       C.row("interactive", session: C.newID, status: "idle", pid: 6060)])
    static let terminalPID: Int32 = 6060

    // MARK: P1541 never two live copies

    /// The review's probe A: Stop, then `claude --resume <id>` by hand. A reply from the card, and its Open in terminal,
    /// would wake the stopped copy beside the terminal's: neither attaches, and the card says why.
    @Test
    func aStoppedCopyIsNeverWokenWhileATerminalRunsItsConversation() async {
        let rig = await C.moved(lists: [C.after, Self.stopped, Self.resumedByHand])
        await rig.engine.stopBackground(C.newID)
        #expect(rig.engine.folds[C.newID]?.background?.stoppedByOwner == true)
        await rig.engine.replyFolded(sessionID: C.newID, text: "carry on")
        #expect(rig.attaches.current.isEmpty && rig.terminals.current.isEmpty)
        #expect(rig.engine.folds[C.newID]?.send == .notSent)
        #expect(rig.engine.claudeBackground?.problem(C.newID) == "Not sent · it is open in a terminal")
        _ = await rig.engine.openFolded(sessionID: C.newID)
        #expect(rig.windows.current.isEmpty)
        #expect(rig.engine.claudeBackground?.problem(C.newID) == "Not opened · it is open in a terminal")
        #expect(rig.engine.folds[C.newID]?.background?.stage == .moved)
        #expect(rig.engine.foldNotes.map(\.said).contains("background · not opened"))
    }

    /// Once the terminal's copy is listed and alive, the card is that terminal's: no background line, no attach, no
    /// `claude stop`; a reply goes into its tab and Open in terminal brings that tab, never a new window (P1541).
    @Test
    func aCardWhoseConversationATerminalRunsBecomesThatTerminalsCard() async {
        let rig = await C.moved(lists: [C.after, Self.stopped, Self.resumedByHand])
        await rig.engine.stopBackground(C.newID)
        // Its hooks speak from the terminal's tab: its agent at that tab's controls.
        rig.base.alive.update { $0.insert(Self.terminalPID) }
        rig.engine.ingest(F.started(C.newID, source: .resume), ingress: .bridge)
        rig.engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: C.newID, agentPID: Self.terminalPID,
                                                hostBundleID: ExactJumpTests.terminal))
        rig.engine.ingest(F.prompt(C.newID), ingress: .bridge)
        rig.engine.ingest(F.completed(C.newID), ingress: .bridge)
        await rig.engine.readBackgroundLists()
        #expect(rig.engine.folds[C.newID]?.background == nil)
        #expect(rig.engine.foldNotes.map(\.said).contains("background · a terminal runs it now · the card follows it there"))
        #expect(rig.engine.foldReach(C.newID) == .tab)
        await rig.engine.replyFolded(sessionID: C.newID, text: "and push")
        #expect(rig.typed.last.map { $0.1 } == "and push" && rig.attaches.current.isEmpty)
        let stops = rig.claude.commands.filter { $0.arguments.first == "stop" }.count
        rig.engine.stopFolded(sessionID: C.newID)
        await Task.yield()
        #expect(rig.claude.commands.filter { $0.arguments.first == "stop" }.count == stops)
        _ = await rig.engine.openFolded(sessionID: C.newID)
        #expect(rig.windows.current.isEmpty && rig.base.resume.opened.isEmpty)
        #expect(rig.engine.folds[C.newID] == nil)
    }

    /// The same card while a card's Open in terminal finds the terminal's copy first: it opens no window and no resume.
    @Test
    func openInTerminalFindingATerminalsCopyOpensNoWindowOfItsOwn() async {
        let rig = await C.moved(lists: [C.after, Self.stopped, Self.resumedByHand])
        await rig.engine.stopBackground(C.newID)
        rig.base.alive.update { $0.insert(Self.terminalPID) }
        _ = await rig.engine.openFolded(sessionID: C.newID)
        #expect(rig.engine.folds[C.newID]?.background == nil)
        #expect(rig.windows.current.isEmpty && rig.base.resume.opened.isEmpty)
        #expect(rig.engine.folds[C.newID]?.notOpened == true)
    }

    /// A live agent its hooks name that is not the copy's process, or a process whose arguments name its id, holds the
    /// conversation too: nothing attaches. The copy's own process, and its own children, are not holders (P1541).
    @Test
    func aLiveAgentItsHooksNameOrAProcessNamingItKeepsTheAttachShut() async {
        let rig = await C.moved(lists: [C.after, Self.stopped])
        await rig.engine.stopBackground(C.newID)
        rig.base.alive.update { $0.insert(6070) }
        rig.engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: C.newID, agentPID: 6070,
                                                hostBundleID: ExactJumpTests.terminal))
        await rig.engine.replyFolded(sessionID: C.newID, text: "carry on")
        #expect(rig.attaches.current.isEmpty)
        #expect(rig.engine.claudeBackground?.problem(C.newID) == "Not sent · it is open in a terminal")
        // That agent is gone; a process names the id (`claude --resume <id>` before its hooks spoke).
        rig.base.alive.update { $0.remove(6070) }
        rig.found.update { $0 = [6080] }
        await rig.engine.replyFolded(sessionID: C.newID, text: "carry on")
        #expect(rig.attaches.current.isEmpty)
        #expect(rig.engine.claudeBackground?.problem(C.newID) == "Not sent · it is open in a terminal")
        // Nothing but the copy and its own children: the reply goes, and wakes it.
        let own = C.json([C.row("background", id: C.short, session: C.newID, state: "done", status: "idle",
                                pid: Int(FoldStopTests.shell))])
        rig.claude.answer([own])
        rig.found.update { $0 = [FoldStopTests.shell, FoldStopTests.agent] }
        await rig.engine.replyFolded(sessionID: C.newID, text: "carry on")
        #expect(rig.terminals.current.first?.typed == "carry on")
        #expect(rig.engine.claudeBackground?.problem(C.newID) == nil)
    }

    // MARK: P1542 a held reply and an attached window in front

    /// The review's probe B: a reply held while the background turn runs, with a window attached to it (Open in
    /// terminal): at the turn's end it goes into that window's tab only while that window is not the one in front.
    @Test(arguments: [true, false])
    func aHeldReplyNeverGoesIntoAnAttachedWindowInFront(inFront: Bool) async throws {
        let busy = C.json([C.row("background", id: C.short, session: C.newID, state: "working", status: "busy")])
        let rig = await C.moved(lists: [C.after, busy, Self.idle], attached: [5150])
        rig.base.alive.update { $0.insert(5150) }
        await rig.engine.replyFolded(sessionID: C.newID, text: "then push")
        #expect(rig.engine.folds[C.newID]?.held == "then push")
        rig.inFront.update { $0 = inFront }
        rig.base.clock.update { $0 = $0.addingTimeInterval(30) }
        await rig.engine.readBackgroundLists()
        await rig.engine.readBackgroundLists()
        rig.base.runChecks(2)
        try await C.until { rig.engine.folds[C.newID]?.held == nil && rig.engine.folds[C.newID]?.send != .sending }
        if inFront {
            try await C.until { rig.engine.folds[C.newID]?.returned != nil }
            #expect(rig.typed.map(\.1) == ["/background"])
            #expect(rig.engine.folds[C.newID]?.returned == ReturnedReply(text: "then push", why: .windowInFront))
            #expect(rig.engine.foldNotes.map(\.said).contains("held reply given back · its attached window was in front"))
        } else {
            try await C.until { rig.typed.count == 2 }
            #expect(rig.typed.last.map { $0.0 } == .terminal(tty: FoldStopTests.tty) && rig.typed.last?.1 == "then push")
        }
        #expect(rig.attaches.current.isEmpty)
    }

    // MARK: P1545 a background session has no tab

    /// A session started under Claude Code's supervisor, which was started in a tmux pane: its notes carry that pane.
    static func paneSession(_ rig: ClaudeBackgroundTests.Rig) {
        rig.base.alive.update { $0.insert(4242) }
        rig.engine.ingest(F.started("bgpane"), ingress: .bridge)
        rig.engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: "bgpane", tmux: "/tmp/ji-tmux/default,1234,0",
                                                tmuxPane: "%3", agentPID: 4242))
        rig.engine.ingest(F.prompt("bgpane"), ingress: .bridge)
        rig.engine.ingest(F.completed("bgpane"), ingress: .bridge)
    }

    static let paneRow = C.json([C.row("background", id: C.short, session: "bgpane", state: "done", status: "idle", pid: 4242)])

    /// Its Done card's reply looks at the list once and types nothing into that pane; from then on it has no tab: no
    /// reply field, no pane in its jump, and it folds as a background session with nothing tucked or typed.
    @Test
    func aSessionItsListNamesAsBackgroundHasNoTabWhateverPaneItsNotesName() async throws {
        let rig = C.rig(lists: [Self.paneRow])
        Self.paneSession(rig)
        #expect(rig.engine.canReply(sessionID: "bgpane"))
        #expect(await rig.engine.reply(sessionID: "bgpane", text: "ship it") == .notSent)
        #expect(rig.typed.isEmpty && rig.claude.lists.count == 1)
        #expect(!rig.engine.canReply(sessionID: "bgpane"))
        let session = try #require(rig.engine.state.session(id: "bgpane"))
        #expect(rig.engine.effectiveJumpTarget(for: session)?.tmuxTarget == nil)
        #expect(rig.engine.jumpContext(for: "bgpane") == nil)
        #expect(await rig.engine.fold(sessionID: "bgpane") == .folded(bounds: nil))
        #expect(rig.engine.folds["bgpane"]?.background?.stage == .moved && rig.engine.foldReach("bgpane") == .background)
        #expect(rig.base.tucks.current.isEmpty && rig.typed.isEmpty)
    }

    /// Sent to the island before the list knew it: the list is read once first, so its card is a background card from
    /// the start, and the pane is never taken for its tab.
    @Test
    func aFoldOfAPaneItsNotesAloneNameLooksAtTheListFirst() async {
        let rig = C.rig(lists: [Self.paneRow])
        Self.paneSession(rig)
        #expect(await rig.engine.fold(sessionID: "bgpane") == .folded(bounds: nil))
        #expect(rig.engine.folds["bgpane"]?.background?.stage == .moved)
        #expect(rig.engine.foldReach("bgpane") == .background)
        #expect(rig.base.tucks.current.isEmpty && rig.typed.isEmpty)
        #expect(rig.engine.foldNotes.map(\.said).contains("background · sent to the island as a background session"))
    }

    /// An interactive session in a tmux pane, which the list names as interactive: its tab stays its own, and the list is
    /// read once for it, not at every reply.
    @Test
    func anInteractiveSessionInAPaneKeepsItsTabAndIsLookedForOnce() async {
        let interactive = C.json([C.row("interactive", session: "bgpane", status: "idle", pid: 4242)])
        let rig = C.rig(lists: [interactive])
        Self.paneSession(rig)
        #expect(await rig.engine.reply(sessionID: "bgpane", text: "ship it") == .sent)
        #expect(await rig.engine.reply(sessionID: "bgpane", text: "and tag it") == .sent)
        #expect(rig.typed.map(\.1) == ["ship it", "and tag it"])
        #expect(rig.typed.first.map { $0.0 } == .tmux(pane: "%3", socket: "/tmp/ji-tmux/default"))
        #expect(rig.claude.lists.count == 1)
    }
}
