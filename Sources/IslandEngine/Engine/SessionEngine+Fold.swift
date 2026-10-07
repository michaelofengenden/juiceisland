import Foundation
import OpenIslandCore

/// A session the owner sent to the island (wave 6, P1300 to P1324): its terminal window tucked into the Dock when that
/// window held its tab alone, and its conversation card on the island until Open in terminal or ✕.
public struct FoldedSession: Equatable, Sendable {
    public var sessionID: String
    /// When it was sent: several folded sessions stack newest first.
    public var since: Date
    /// Juice put its window in the Dock (it held this tab alone): Open in terminal brings it back.
    public var tucked = false
    /// A reply typed while the turn ran: it goes once the turn ends, or never if the owner cancels it (P1306). A second
    /// one typed meanwhile joins it (P1358).
    public var held: String?
    /// The way the held reply was typed for: it goes only that way (P1356).
    public var heldWay: FoldWay?
    /// Where the last reply stands; nil before one, and again once the turn it started is under way.
    public var send: FoldSend?
    /// The last reply's text, for Retry.
    public var lastReply: String?
    /// The way the last reply went: Retry goes only that way (P1356).
    public var lastWay: FoldWay?
    /// A held reply (or a Retry) that did not go, given back to the card's field: only a new Return sends it (P1356,
    /// P1359).
    public var returned: ReturnedReply?
    /// A reply went through the agent's own resume since the fold: the resume's note is said only before the first.
    public var resumed = false
    /// Open in terminal could not open the conversation again (route b): "Not opened".
    public var notOpened = false
    /// Its session as last seen in the engine's state: upstream's process monitor drops an ended session on its next
    /// pass, and the card stays, drawn from this (P1355).
    public var session: AgentSession?
    /// Its agent in its tab as last seen while that agent held its terminal: never the island's own run (P1415).
    public var agentPID: Int32?
    /// That agent's short name then, so a pid the system gave another program since is not taken for it (P1420).
    public var agentName: String?
    /// The process its agent ran under (its shell): gone with it when its window closed, still there when the agent
    /// quit or crashed (P1415).
    public var shellPID: Int32?
    /// Its own turn in its tab is under way, as the fold saw it: from a prompt (or the phase it was sent in) to the main
    /// agent's own turn end (a Stop, a StopFailure or an interrupt), never a subagent's Stop or a Notification (P1418).
    public var turnOpen = false
    /// When that turn began, as the fold saw it (its last prompt, or the fold): Claude's idle notice ends it only a full
    /// minute after (P1438).
    public var turnOpenedAt: Date?
    /// Its agent ended while that turn ran (P1415): the card says so, and offers Continue.
    public var stopped: FoldStop?
    /// The stop the last reply through the resume was to carry on (Continue, or a reply typed on a stopped card): it comes
    /// back if Codex refuses that run because another process still writes the thread (P1440).
    public var continuedFrom: FoldStop?
    /// The terminal its tab is in ("Terminal"), for "Working in Terminal" while its window sits in the Dock (P1417).
    public var host: String?
    /// The way a reply went when the fold last looked, so the log says once when its tab went, and why (P1429).
    public var seenWay: FoldWay?
    /// In Claude Code's own background, or on its way there (wave 8, P1450): `/background` typed into its tab on Send to island.
    public var background: FoldBackground?
}

/// A folded session whose agent ended while its turn ran (P1415): its window closed, or the agent quit or crashed
/// mid-turn. Its card keeps the last answer and offers Continue (Claude Code and Codex), or Open in terminal.
public struct FoldStop: Equatable, Sendable {
    public var at: Date
    /// The shell its agent ran under went too: the window (or tab) closed. Otherwise the agent alone ended.
    public var windowClosed: Bool
    public var why: FoldGone

    public init(at: Date, windowClosed: Bool, why: FoldGone) {
        self.at = at
        self.windowClosed = windowClosed
        self.why = why
    }

    /// The card's one line for it.
    public var words: String { windowClosed ? "Stopped when its window closed" : "Stopped mid-turn" }
}

/// Why a folded session's tab no longer takes a reply, as the log and the stop's verdict say it (P1415, P1429).
public enum FoldGone: String, Equatable, Sendable {
    /// Its agent's process is gone (the window closed, the agent quit or crashed), whatever its hooks said.
    case processEnded = "its agent's process ended"
    /// Its agent said its session ended (SessionEnd), or the process monitor ended it.
    case sessionEnded = "its session ended"
    /// Upstream's monitor dropped the ended session.
    case dropped = "its session left the engine"
    /// Its agent still runs but no longer holds its terminal (stopped with Ctrl-Z, or in the background).
    case leftTerminal = "its agent left its terminal's controls"
    /// No agent was ever named for it.
    case noAgent = "no agent was named for it"
}

/// Where a folded session's last reply stands.
public enum FoldSend: Equatable, Sendable {
    case sending
    case sent
    case notSent
}

/// Which way a folded session's reply goes, whatever the resume's note says (`FoldReach.way`).
public enum FoldWay: Equatable, Sendable {
    case tab
    case resume
    /// Codex's shared background service, to the thread it holds (P1487).
    case daemon
    case nowhere
    /// Claude Code's own background session, through `claude attach` (wave 8, P1460).
    case background
}

/// A reply that did not go as it was typed, given back to the card's field (P1356, P1359).
public struct ReturnedReply: Equatable, Sendable {
    public enum Why: Equatable, Sendable {
        /// Its tab closed, or came back, while it waited: it would have gone another way than the one it was typed for.
        case wayChanged
        /// Its tab was in front as its turn ended, where the owner may be typing.
        case tabInFront
        /// A window attached to its background session was in front as its turn ended, where the owner may be typing
        /// (P1542).
        case windowInFront
    }

    /// The text: the card's field takes it back, and keeps it until the next Return or ✕.
    public var text: String
    public var why: Why
}

/// Where a folded session's reply goes now (P1303, P1304).
public enum FoldReach: Equatable, Sendable {
    /// Its tab is open and its agent still at the tab's controls: the reply is typed into the tab (route a).
    case tab
    /// Its tab is gone (closed, or its agent quit): the agent's own resume goes on with the conversation (route b).
    /// `note`: one line the card says before the first such reply.
    case resume(note: String?)
    /// Codex's shared background service holds its thread (P1487): a reply starts a turn there, whether its window is
    /// open, closed or never known. `note`: one line the card says before the first such reply.
    case daemon(note: String?)
    /// Nowhere from the island: "Open in terminal to reply".
    case openOnly
    /// In Claude Code's own background (wave 8): a reply goes through `claude attach` (P1460).
    case background

    public var way: FoldWay {
        switch self {
        case .tab: .tab
        case .resume: .resume
        case .daemon: .daemon
        case .openOnly: .nowhere
        case .background: .background
        }
    }
}

/// What sending a session to the island came to.
public enum FoldOutcome: Equatable, Sendable {
    /// Folded. `bounds`: its window's, when its terminal said where it was, whether the window went into the Dock or
    /// stayed (it holds other tabs; P1360): the motion starts there. nil when the terminal said nothing.
    case folded(bounds: TuckBounds?)
    /// Not folded: no known tab, already folded, or gone.
    case refused
}

extension SessionEngine {
    /// How long after a turn ends a held reply goes: the agent is back at its prompt by then (P1306).
    nonisolated static let heldReplySettle: TimeInterval = 1
    /// How many seconds a held reply keeps looking while a resumed run still has its process (P1306, contract R4).
    nonisolated static let heldReplyPatience = 120

    /// The folded sessions, newest first.
    public var foldedSessions: [FoldedSession] { folds.values.sorted { ($0.since, $0.sessionID) > ($1.since, $1.sessionID) } }

    /// A conversation that went on in the background under another id counts as folded too: the card of its new id
    /// stands for it (P1455).
    public func isFolded(_ sessionID: String) -> Bool { folds[sessionID] != nil || movedConversations[sessionID] != nil }

    /// A session goes to the island when its tab is known exactly (`ReplyRoute`: Terminal by its agent's tty, iTerm,
    /// Ghostty, a tmux pane), it has not ended and is not folded yet (P1300). Warp, the editors, Claude.app and the
    /// Codex app have no such tab.
    ///
    /// A Codex session its shared background service runs folds too once that service said it holds its thread (P1486):
    /// its tab is not known, so its window stays where it is (closing it ends nothing there), and a reply goes to the
    /// thread.
    public func canFold(sessionID: String) -> Bool {
        guard folds[sessionID] == nil, let session = state.session(id: sessionID), !session.isSessionEnded else { return false }
        if runsInCodexService(sessionID) { return conversationResume?.serviceStatus(sessionID)?.holds == true }
        // Or it runs in Claude Code's background, with no tab (wave 8, P1465).
        return replyRoute(for: session) != nil || foldsAsBackground(sessionID)
    }

    /// Send to island, on the owner's click or key only: the session's card goes on the island, and its window into the
    /// Dock when the window holds its tab alone (`TerminalTuck`, P1302); otherwise the window stays, and the motion plays
    /// from it (P1360). The tuck runs off the main thread; a headless engine (tests, the demo) tucks nothing unless it was
    /// given a tucker.
    public func fold(sessionID: String) async -> FoldOutcome {
        guard canFold(sessionID: sessionID), let session = state.session(id: sessionID) else { return .refused }
        // A Claude Code session whose tab is known from its notes' environment alone may run in Claude Code's background,
        // under a supervisor that terminal started: its list is read once first, so another session's window or pane is
        // never taken for its own (P1545).
        if await lookedForClaudeBackground(session) {
            guard folds[sessionID] == nil, canFold(sessionID: sessionID) else { return .refused }
        }
        // A session in Claude Code's background already folds as one: no tab, nothing tucked or typed (P1465).
        if foldsAsBackground(sessionID) { return foldKnownBackground(session) }
        var fold = FoldedSession(sessionID: sessionID, since: dependencies.now(), session: session)
        // A turn under way as it is sent is its own turn in its tab (P1418); its agent is kept from now on (P1415).
        fold.turnOpen = session.phase != .completed
        fold.turnOpenedAt = fold.turnOpen ? dependencies.now() : nil
        guard let route = replyRoute(for: session) else {
            guard runsInCodexService(sessionID) else { return .refused }
            // Codex's shared background service runs it (P1486): no tab to tuck or follow; the service says how it goes.
            fold.seenWay = .daemon
            folds[sessionID] = fold
            conversationResume?.keep(sessionID)
            noteFold(sessionID, .folded(tuck: nil, turnOpen: fold.turnOpen))
            if let resume = conversationResume { Task { await resume.lookAgain(sessionID) } }
            return .folded(bounds: nil)
        }
        fold.host = FoldedSession.hostWord(route)
        fold.seenWay = .tab
        folds[sessionID] = fold
        adoptFoldAgent(sessionID)
        conversationResume?.keep(sessionID)
        // With the switch on, a Claude Code session then moves into Claude Code's background (`/background`, P1450): after the
        // tuck, so the two scripts never cross.
        defer { startBackgroundMove(sessionID) }
        guard let tuck = dependencies.tuckWindow ?? (configuration.startBridge ? TerminalTuck.live : nil) else {
            noteFold(sessionID, .folded(tuck: nil, turnOpen: fold.turnOpen))
            return .folded(bounds: nil)
        }
        let outcome = await Self.runTuck(.tuck, route, tuck)
        // ✕ while the tuck was on its way: the card went; the window is wherever the script left it.
        guard folds[sessionID] != nil else { return .refused }
        noteFold(sessionID, .folded(tuck: outcome, turnOpen: fold.turnOpen))
        switch outcome {
        case let .tucked(bounds):
            folds[sessionID]?.tucked = true
            return .folded(bounds: bounds)
        case let .stayed(bounds):
            return .folded(bounds: bounds)
        case .kept, .restored, .failed:
            return .folded(bounds: nil)
        }
    }

    /// ✕: the card goes and the window stays where it is (in the Dock, if Juice put it there). A held reply goes with it.
    public func unfold(sessionID: String) {
        guard folds[sessionID] != nil else { return }
        noteFold(sessionID, .dismissed)
        dropFold(sessionID)
    }

    /// The card goes, with its held reply, its checks and its watch on the agent.
    func dropFold(_ sessionID: String) {
        folds[sessionID] = nil
        appHandoff?.forget(sessionID)
        foldChecks.remove(sessionID)
        backgroundMoveChecks.remove(sessionID)
        // The interactive session a background card stood for shows in the list again (P1455).
        if movedConversations.values.contains(sessionID) { movedConversations = movedConversations.filter { $0.value != sessionID } }
        foldStopChecks.remove(sessionID)
        foldExitWatches.removeValue(forKey: sessionID)?.token.cancel()
    }

    /// Open in terminal (P1305). With its tab open: its window comes out of the Dock and the exact jump lands on the tab;
    /// the card goes. With its tab gone: the agent's own resume opens the conversation in a new window (route b), and
    /// the card goes once it opened ("Not opened" otherwise); with no resume, the plain jump, and the card goes.
    @discardableResult
    public func openFolded(sessionID: String) async -> JumpOutcome? {
        guard folds[sessionID] != nil else { return nil }
        // A conversation an app holds goes back to a terminal only once that app no longer holds it; the card says why
        // it waits (P1517).
        if let handoff = appHandoff, foldIsInApp(sessionID) {
            guard await handoff.wayBack(sessionID), folds[sessionID] != nil else { return nil }
        }
        // A background session opens attached in a new window, and its card stays (P1462); a move under way or that did
        // not show never opens the resume (P1457).
        if let background = folds[sessionID]?.background {
            if background.stage == .moved {
                await openBackground(sessionID)
                // A terminal runs it now (P1541): the card is that terminal's, and only its own tab is opened, never a
                // resume beside it.
                guard folds[sessionID] != nil, folds[sessionID]?.background == nil else { return nil }
                guard foldReach(sessionID) == .tab else {
                    noteFold(sessionID, .opened(.notOpened))
                    folds[sessionID]?.notOpened = true
                    return nil
                }
            } else if background.stage == .moving || background.leftItUnsure {
                return await openUnsettledBackground(sessionID)
            }
        }
        // A tab whose agent still runs in it comes out of the Dock whoever put its window there (Juice, or the owner),
        // and whether or not its agent is at its prompt now; the script leaves a window that is not in the Dock as it
        // is (P1421).
        if let session = state.session(id: sessionID), let route = replyRoute(for: session),
           let agent = foldAgent(sessionID), foldAgentRuns(sessionID, pid: agent),
           let tuck = dependencies.tuckWindow ?? (configuration.startBridge ? TerminalTuck.live : nil) {
            _ = await Self.runTuck(.untuck, route, tuck)
        }
        let reach = foldReach(sessionID)
        if reach == .tab {
            noteFold(sessionID, .opened(.tab))
            dropFold(sessionID)
            return await jump(sessionID: sessionID)
        }
        if let resume = conversationResume {
            folds[sessionID]?.notOpened = false
            // A turn its window's close cut off goes on in the new window, with the words the card shows (P1439); never
            // into a turn Codex's background service still runs (P1488).
            let carries = (reach.way == .resume || reach.way == .daemon) && !resume.serviceTurnRuns(sessionID)
            let continuing: String? = carries && folds[sessionID]?.stopped != nil ? Self.continuePrompt : nil
            if await resume.openInTerminal(sessionID, continuing: continuing) {
                dropFold(sessionID)
                return nil
            }
            // A conversation the resume could open, and did not: the card stays and says so.
            if reach.way == .resume || reach.way == .daemon {
                noteFold(sessionID, .opened(.notOpened))
                if folds[sessionID] != nil { folds[sessionID]?.notOpened = true }
                return nil
            }
        }
        noteFold(sessionID, .opened(.jump))
        dropFold(sessionID)
        return await jump(sessionID: sessionID)
    }

    /// Where a folded session's reply goes now: its tab while the session has not ended and its agent still holds the
    /// tab (P139), else the agent's own resume where it offers one, else nowhere (P1303, P1304). A session upstream's
    /// monitor dropped has no tab: the resume, from what it kept (P1355).
    public func foldReach(_ sessionID: String) -> FoldReach {
        // An app holds the conversation, or is about to: no reply from the island reaches it (P1515).
        if foldIsInApp(sessionID) { return .openOnly }
        // In Claude Code's background, or on its way: never its old tab, which now holds a shell (P1455). A `/background` that did
        // not move it as seen: nothing goes until the owner looks (P1457).
        if let background = folds[sessionID]?.background {
            if background.holdsTheConversation { return .background }
            if background.leftItUnsure { return .openOnly }
        }
        if let session = state.session(id: sessionID), !session.isSessionEnded, replyRoute(for: session) != nil,
           agentPID(awaitingReply: session) != nil {
            return .tab
        }
        guard let resume = conversationResume else { return .openOnly }
        switch resume.availability(for: sessionID) {
        case let .resume(note): return .resume(note: folds[sessionID]?.resumed == true ? nil : note)
        case let .daemon(note): return .daemon(note: folds[sessionID]?.resumed == true ? nil : note)
        case .openOnly: return .openOnly
        }
    }

    /// The folded session's turn is under way, so a reply waits for its end (P1306): in its tab, while it runs or waits on
    /// an approval or a question; through the resume, while the island's run of it has its process.
    /// Through Codex's background service, while it says a turn runs there (P1487), or its hooks do.
    public func foldTurnRuns(_ sessionID: String) -> Bool {
        if let runs = backgroundTurnRuns(sessionID) { return runs }
        if let resume = conversationResume, resume.isRunning(sessionID) || resume.serviceTurnRuns(sessionID) { return true }
        let way = foldReach(sessionID).way
        // Codex's background service holds the thread and says no turn runs there: a phase its hooks left running (a Stop
        // lost) holds no reply; only a turn the hooks opened since it was asked does (P1491).
        if way == .daemon, conversationResume?.serviceStatus(sessionID)?.holds == true { return folds[sessionID]?.turnOpen == true }
        guard way == .tab || way == .daemon, let session = state.session(id: sessionID) else { return false }
        // A phase that reads finished is not enough: an idle Notification sets it, and so may a late hook; only the main
        // agent's own turn end closes the turn (P1418).
        return session.phase != .completed || folds[sessionID]?.turnOpen == true
    }

    /// A reply on a folded session's card, on the owner's Return only. While its turn runs it is held and goes once the
    /// turn ends (a second one typed meanwhile joins it, P1358); otherwise it is typed into the tab (route a) or goes on
    /// through the agent's own resume (route b). A held reply goes only the way it was typed for: when that changed (the
    /// tab closed, or came back), it and this one go back to the field, so the card says where a Return sends them now
    /// (Codex's line among it) before anything runs (P1356). One send at a time per session; the card shows where it
    /// stands.
    public func replyFolded(sessionID: String, text: String) async {
        guard let fold = folds[sessionID], let typed = ReplySender.line(text), fold.send != .sending else { return }
        folds[sessionID]?.returned = nil
        let way = foldReach(sessionID).way
        let line = fold.held.map { $0 + " " + typed } ?? typed
        if fold.held != nil, fold.heldWay != way {
            return giveBack(sessionID, line, why: .wayChanged)
        }
        if foldTurnRuns(sessionID) {
            folds[sessionID]?.held = line
            folds[sessionID]?.heldWay = way
            folds[sessionID]?.send = nil
            noteFold(sessionID, .held(way))
            scheduleHeldCheck(sessionID)
            return
        }
        await sendFolded(sessionID, line)
    }

    /// Cancel on a held reply: it never goes.
    public func cancelHeldReply(sessionID: String) {
        folds[sessionID]?.held = nil
        folds[sessionID]?.heldWay = nil
        foldChecks.remove(sessionID)
    }

    /// Stop on a resumed run (contract R4): the run ends, and a held reply with it, since sending it would start the run
    /// the owner just ended.
    public func stopFolded(sessionID: String) {
        // A background session: `claude stop <id>` (P1463).
        if folds[sessionID]?.background?.stage == .moved {
            Task { await stopBackground(sessionID) }
            return
        }
        cancelHeldReply(sessionID: sessionID)
        conversationResume?.stop(sessionID)
    }

    /// Retry on "Not sent": the last reply again, held if a turn runs now. When it would go another way than it was
    /// typed for (the tab closed since), it goes back to the field instead, so a Return sends it knowingly (P1356).
    public func retryFolded(sessionID: String) async {
        guard let fold = folds[sessionID], fold.send == .notSent, let text = fold.lastReply else { return }
        if let way = fold.lastWay, way != foldReach(sessionID).way {
            folds[sessionID]?.send = nil
            return giveBack(sessionID, text, why: .wayChanged)
        }
        await replyFolded(sessionID: sessionID, text: text)
    }

    /// The session's front tab, for the system-wide key's Send front tab to island: the first session that can fold
    /// whose tab is the one in front (the same check that keeps a focused session quiet, P17). Only on the owner's key.
    public func frontmostFoldable() async -> String? {
        for session in surfacedSessions where canFold(sessionID: session.id) {
            if await dependencies.isSessionFrontmost(withEffectiveJumpTarget(session)) { return session.id }
        }
        return nil
    }

    // MARK: Sending

    func sendFolded(_ sessionID: String, _ line: String) async {
        let reach = foldReach(sessionID)
        folds[sessionID]?.held = nil
        folds[sessionID]?.heldWay = nil
        folds[sessionID]?.lastReply = line
        folds[sessionID]?.lastWay = reach.way
        folds[sessionID]?.send = .sending
        let outcome: SendOutcome
        switch reach {
        case .tab:
            outcome = await reply(sessionID: sessionID, text: line)
        case .resume, .daemon:
            outcome = await conversationResume?.continueConversation(sessionID, text: line) ?? .notSent
            if outcome == .sent { folds[sessionID]?.resumed = true }
        case .openOnly:
            outcome = .notSent
        case .background:
            outcome = await replyBackground(sessionID, line)
            // Its own list says a turn runs there after all: the reply waits for its end, as any reply does (P1306).
            if outcome == .nothingToSend, folds[sessionID] != nil { return holdBackgroundReply(sessionID, line) }
        }
        noteFold(sessionID, .sent(reach.way, outcome))
        // ✕ while it was on its way: nothing is left to say. A reply whose turn is already under way says nothing
        // either: the card reads Working.
        guard folds[sessionID] != nil else { return }
        // Codex's background service still runs a turn of the thread (P1488): nothing ran; the reply waits for that
        // turn's end and then goes there, and Continue has nothing to carry on.
        if outcome == .notSent, reach.way == .resume || reach.way == .daemon, conversationResume?.serviceTurnRuns(sessionID) == true {
            return holdForService(sessionID, line)
        }
        // The conversation went on: it is stopped no longer (P1415), unless Codex refuses the run (P1440).
        if outcome == .sent {
            let carried = reach.way == .resume || reach.way == .daemon ? folds[sessionID]?.stopped : nil
            folds[sessionID]?.continuedFrom = carried
        }
        if outcome == .sent, folds[sessionID]?.stopped != nil { folds[sessionID]?.stopped = nil }
        if outcome == .sent, let session = state.session(id: sessionID), session.phase != .completed || foldTurnRuns(sessionID) {
            folds[sessionID]?.send = nil
        } else {
            folds[sessionID]?.send = outcome == .sent ? .sent : .notSent
        }
        // A move into Claude Code's background that waits for a turn's end looks again now that this reply is no longer on
        // its way: a turn's end that came while it was could not start it, and no other event may follow (P1538).
        if folds[sessionID]?.background?.stage == .waitsForTurnEnd { followBackgroundMove(sessionID) }
    }

    /// A held reply whose turn ended (`scheduleHeldCheck`): it goes the way it was typed for, and only that way (P1356);
    /// into a tab only while that tab is not the one in front, where the owner may be typing (P1359). Otherwise it goes
    /// back to the field. Anything that changed while the frontmost check looked (a cancel, a new turn) wins.
    func sendHeld(_ sessionID: String, _ held: String) async {
        guard let fold = folds[sessionID], fold.held == held, !foldTurnRuns(sessionID) else { return }
        let reach = foldReach(sessionID)
        guard reach.way == fold.heldWay else { return giveBack(sessionID, held, why: .wayChanged) }
        if reach == .tab, let session = state.session(id: sessionID) {
            let inFront = await dependencies.isSessionFrontmost(withEffectiveJumpTarget(session))
            guard folds[sessionID]?.held == held, !foldTurnRuns(sessionID) else { return }
            if inFront { return giveBack(sessionID, held, why: .tabInFront) }
            guard foldReach(sessionID) == .tab else { return giveBack(sessionID, held, why: .wayChanged) }
        }
        // A background session with a window attached: the reply is typed into that window's tab, so the same check
        // (P1359, P1542).
        if reach == .background, let window = await attachedWindow(sessionID) {
            let inFront = await dependencies.isSessionFrontmost(window)
            guard folds[sessionID]?.held == held, !foldTurnRuns(sessionID) else { return }
            if inFront { return giveBack(sessionID, held, why: .windowInFront) }
        }
        await sendFolded(sessionID, held)
    }

    /// A reply that did not go: out of the held slot and back to the card's field, with why.
    func giveBack(_ sessionID: String, _ text: String, why: ReturnedReply.Why) {
        guard folds[sessionID] != nil else { return }
        folds[sessionID]?.held = nil
        folds[sessionID]?.heldWay = nil
        folds[sessionID]?.returned = ReturnedReply(text: text, why: why)
        foldChecks.remove(sessionID)
        noteFold(sessionID, .givenBack(why))
    }

    /// One check per held reply: a second after its turn ends (or a second from now, while a resumed run still has its
    /// process), it goes, unless it was cancelled, replaced by a send, or its session unfolded meanwhile.
    func scheduleHeldCheck(_ sessionID: String, attempt: Int = 0) {
        guard foldChecks.insert(sessionID).inserted else { return }
        dependencies.scheduleFoldCheck(Self.heldReplySettle) { [weak self] in
            guard let self else { return }
            self.foldChecks.remove(sessionID)
            guard let held = self.folds[sessionID]?.held else { return }
            if self.foldTurnRuns(sessionID) {
                // A turn in its tab ends with an event, which looks again (`foldsFollowState`); a resumed run's process
                // ends with none, so it is looked at each second, for a while.
                if self.conversationResume?.isRunning(sessionID) == true, attempt < Self.heldReplyPatience {
                    self.scheduleHeldCheck(sessionID, attempt: attempt + 1)
                }
                return
            }
            Task { await self.sendHeld(sessionID, held) }
        }
    }

    /// After every change of the state: a folded session keeps its last copy of its session, which its card is drawn
    /// from once upstream's monitor drops it (it never unfolds by itself, P1355), and the resume keeps what it would run;
    /// a held reply whose turn ended gets its check; a reply that went stops saying "Sent" once the turn it started is
    /// under way (the card says Working then).
    func foldsFollowState() {
        guard !folds.isEmpty else { return }
        for (id, fold) in folds {
            if let session = state.session(id: id) {
                if fold.session != session {
                    folds[id]?.session = session
                    conversationResume?.keep(id)
                }
                if fold.send == .sent, session.phase != .completed { folds[id]?.send = nil }
            }
            followFoldAgent(id)
            followBackgroundMove(id)
            appHandoff?.followFold(id)
            if fold.held != nil, !foldChecks.contains(id), !foldTurnRuns(id) { scheduleHeldCheck(id) }
        }
    }

    /// Runs a tuck off the main thread and answers what it answered, however long the script took.
    nonisolated static func runTuck(_ move: TerminalTuck.Move, _ route: ReplyRoute,
                                    _ tuck: @escaping @Sendable (TerminalTuck.Move, ReplyRoute) -> TuckOutcome) async -> TuckOutcome {
        await withCheckedContinuation { continuation in
            TerminalTuck.queue.async { continuation.resume(returning: tuck(move, route)) }
        }
    }
}
