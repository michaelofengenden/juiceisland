import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore

/// What the fold decided, as its log (`JuiceLog.fold`) and Diagnostics' Copy Report say it (P1429, P1430): states only,
/// never a reply's, an answer's or a prompt's text.
public enum FoldDecision: Equatable, Sendable {
    /// Sent to the island: what the tuck answered (nil: no tucker), and whether a turn ran then.
    case folded(tuck: TuckOutcome?, turnOpen: Bool)
    /// ✕: the card went, the window stayed.
    case dismissed
    /// A reply held for its turn's end, for the way it was typed for.
    case held(FoldWay)
    /// A reply went (or not) one way.
    case sent(FoldWay, SendOutcome)
    /// A held reply went back to the card's field.
    case givenBack(ReturnedReply.Why)
    /// Its tab no longer takes a reply, and why.
    case tabGone(FoldGone)
    /// Its tab takes a reply again (the agent is back at its controls).
    case tabBack
    /// Its agent ended while its turn ran (P1415).
    case stopped(windowClosed: Bool, why: FoldGone)
    /// The owner clicked Continue (P1419).
    case continued
    /// The resume's run started (P1419).
    case resumeStarted
    /// The resume's run could not start.
    case resumeNotStarted(ResumeMiss)
    /// The resume refused to start: the session's agent still runs (P1420).
    case resumeRefused(agentPID: Int32)
    /// The resume's run ended: its exit status, and whether Stop ended it.
    case resumeExited(status: Int32, stopped: Bool)
    /// Codex refused the resume: another process still writes its thread (P1440).
    case resumeHeld
    /// Open in terminal, and the path it took.
    case opened(FoldOpenPath)
    /// Claude Code's own background session: the move and its card's commands (wave 8, P1450 on).
    case background(FoldBackgroundDecision)
    /// What Codex's background service said of the thread, when that changed (P1487).
    case service(CodexDaemonStatus)
    /// A resume met a turn Codex's background service still runs: nothing ran, Continue has nothing to carry on (P1488).
    case serviceFinishing
    /// The island's own turn on Codex's background service ended; whether Stop ended it.
    case serviceTurnEnded(stopped: Bool)

    /// One plain line, ids and states only.
    public var said: String {
        switch self {
        case let .folded(tuck, turnOpen):
            let window: String = switch tuck {
            case nil: "no tuck"
            case .tucked?: "window into the Dock"
            case .stayed?: "window stayed"
            case .kept?: "window already in the Dock"
            case .restored?: "window restored"
            case .failed?: "tuck failed"
            }
            return "sent to the island · \(window) · \(turnOpen ? "turn running" : "at its prompt")"
        case .dismissed: return "dismissed"
        case let .held(way): return "reply held · for \(way.said)"
        case let .sent(way, outcome):
            let what: String = switch outcome {
            case .sent: "sent"
            case .notSent: "not sent"
            case .nothingToSend: "nothing sent"
            }
            return "reply \(what) · \(way.said)"
        case let .givenBack(why):
            let words = switch why {
            case .tabInFront: "its tab was in front"
            case .windowInFront: "its attached window was in front"
            case .wayChanged: "its way changed"
            }
            return "held reply given back · \(words)"
        case let .tabGone(why): return "tab gone · \(why.rawValue)"
        case .tabBack: return "tab back"
        case let .stopped(windowClosed, why):
            return "stopped mid-turn · \(windowClosed ? "its window closed" : "its agent ended alone") · \(why.rawValue)"
        case .continued: return "Continue"
        case .resumeStarted: return "resume started"
        case let .resumeNotStarted(miss): return "resume not started · \(miss.rawValue)"
        case let .resumeRefused(pid): return "resume refused · its agent still runs (pid \(pid))"
        case let .resumeExited(status, stopped): return "resume exited · status \(status)\(stopped ? " · stopped" : "")"
        case .resumeHeld: return "resume refused · Codex still holds the conversation"
        case let .opened(path): return path.rawValue
        case let .background(decision): return decision.said
        case let .service(status): return "background service · " + Self.said(status)
        case .serviceFinishing: return "resume held back · Codex is still finishing in the background"
        case let .serviceTurnEnded(stopped): return "background turn ended\(stopped ? " · stopped" : "")"
        }
    }

    static func said(_ status: CodexDaemonStatus) -> String {
        switch status {
        case .noDaemon: "not running"
        case .notHeld: "does not hold it"
        case .idle: "holds it, idle"
        case let .active(waitsOnYou): waitsOnYou ? "holds it, waits on you" : "holds it, a turn runs"
        case .failed: "could not be asked"
        }
    }
}

/// Why the resume's run did not start.
public enum ResumeMiss: String, Equatable, Sendable {
    case toolMissing = "its CLI was not found"
    case couldNotStart = "it could not start"
    case noRunner = "no runner"
}

/// The path Open in terminal took (P1421).
public enum FoldOpenPath: String, Equatable, Sendable {
    case tab = "opened · its tab"
    case newWindow = "opened · a new window with the resume"
    /// On a stopped card: the new window's resume carries the cut turn on (P1439).
    case newWindowContinuing = "opened · a new window with the resume, carrying the turn on"
    case agentRuns = "opened · the plain jump, its agent still runs"
    case jump = "opened · the plain jump"
    case notOpened = "not opened"
}

/// One of the fold's decisions, kept for Diagnostics' Copy Report (P1430).
public struct FoldNote: Equatable, Sendable {
    public var at: Date
    public var sessionID: String
    public var said: String
}

extension FoldWay {
    var said: String {
        switch self {
        case .tab: "its tab"
        case .resume: "the resume"
        case .daemon: "Codex's background service"
        case .nowhere: "nowhere"
        case .background: "the background"
        }
    }
}

extension FoldedSession {
    /// The terminal a tab of `route` is in, as the card names it; nil for a tmux pane, whose window is not known.
    static func hostWord(_ route: ReplyRoute) -> String? {
        switch route {
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .ghostty: "Ghostty"
        case .tmux: nil
        }
    }
}

/// Watches a process for its exit (kqueue, through Dispatch): a folded session's agent, so its card learns at once that
/// its window closed mid-turn instead of at the process monitor's next pass, up to a minute later (P1416). It reads no
/// process and signals none.
enum AgentExitWatch {
    final class Token: HookWatchToken, @unchecked Sendable {
        private let source: any DispatchSourceProcess

        init(_ source: any DispatchSourceProcess) {
            self.source = source
        }

        func cancel() { source.cancel() }
    }

    static let live: @MainActor @Sendable (Int32, @escaping @MainActor @Sendable () -> Void) -> (any HookWatchToken)? = { pid, exited in
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        let token = Token(source)
        source.setEventHandler { [weak token] in
            MainActor.assumeIsolated {
                token?.cancel()
                exited()
            }
        }
        source.resume()
        return token
    }
}

extension SessionEngine {
    /// What Continue sends, shown on the card before the click (P1419).
    public nonisolated static let continuePrompt = "Continue where you left off."
    /// From the first sign that a folded session's agent is gone mid-turn to the verdict: long enough for its shell to
    /// go too when its window closed (P1415).
    nonisolated static let stopSettle: TimeInterval = 1
    /// How many of the fold's decisions Copy Report keeps (P1430).
    nonisolated static let foldNoteLimit = 12
    /// Claude's idle notice (`idle_prompt`) comes about a minute after its prompt went quiet: one sooner than this after
    /// a turn began was sent before it (P1438).
    nonisolated static let idleNoticeAfter: TimeInterval = 60

    // MARK: Continue (P1419)

    /// Continue, on the owner's click only: a folded session that stopped mid-turn goes on through its agent's own
    /// resume (`claude -p --resume`, `codex exec resume`), with `continuePrompt`, which the card shows before the click.
    /// Never by itself; never while a reply is on its way or held, while a turn runs, or where the resume is not
    /// offered (another agent, or its agent still runs: P1420).
    public func continueFolded(sessionID: String) async {
        guard let fold = folds[sessionID], fold.stopped != nil, fold.send != .sending, fold.held == nil,
              case .resume = foldReach(sessionID), !foldTurnRuns(sessionID) else { return }
        noteFold(sessionID, .continued)
        folds[sessionID]?.returned = nil
        await sendFolded(sessionID, Self.continuePrompt)
    }

    // MARK: The turn and the agent (P1415 to P1418)

    /// Every event applied to a folded session: a prompt opens its turn in its tab, and only the main agent's own turn
    /// end closes it (a Stop, a StopFailure, an interrupt). A subagent's Stop and a Notification are activity here, and
    /// a PermissionDenied was made activity before (P2), so neither closes it, whatever the phase reads (P1418). The
    /// island's own resumed run is no turn in the tab.
    func noteFoldTurn(_ event: AgentEvent, sessionID: String, ingress: TrackedEventIngress, before: AgentSession?) {
        guard let fold = folds[sessionID], !islandResumes.isRunning(sessionID) else { return }
        if SignalPipeline.isNewPrompt(event, ingress: ingress, before: before) {
            openFoldTurn(sessionID)
        } else if case let .sessionCompleted(payload) = event, fold.turnOpen {
            switch SignalPipeline.completion(payload, tool: state.session(id: sessionID)?.tool ?? before?.tool, ingress: ingress) {
            case .stop, .interrupt:
                endFoldTurn(sessionID)
            case .sessionEnd, .permissionDenied:
                break
            }
        }
    }

    /// A context note of a folded session's: a turn begun with no prompt opens its turn, a new agent at the tab's
    /// controls is the one the fold follows from now on, and Claude's idle notice ends a turn that ended with no Stop
    /// (P1438). The island's own run's notes are not its tab's.
    func noteFoldAgent(_ note: HookContextNote, turnBegins: Bool) {
        let id = note.sessionID
        guard folds[id] != nil, note.agentID == nil, !islandResumes.isRunning(id) else { return }
        if turnBegins { return openFoldTurn(id) }
        if let pid = note.agentPID, pid != folds[id]?.agentPID {
            adoptFoldAgent(id, pid: pid)
        }
        if note.event == "Notification", Self.notificationType(note) == "idle_prompt" { foldIdleNotice(id) }
    }

    func openFoldTurn(_ sessionID: String) {
        adoptFoldAgent(sessionID)
        if folds[sessionID]?.turnOpen == false { folds[sessionID]?.turnOpen = true }
        // Every prompt, so an idle notice sent before it is told apart (P1438).
        folds[sessionID]?.turnOpenedAt = dependencies.now()
        // It goes on in a tab again: it is stopped no longer.
        if folds[sessionID]?.stopped != nil { folds[sessionID]?.stopped = nil }
        if folds[sessionID]?.continuedFrom != nil { folds[sessionID]?.continuedFrom = nil }
    }

    /// The fold's own turn ended: a held reply gets its check.
    func endFoldTurn(_ sessionID: String) {
        guard folds[sessionID]?.turnOpen == true else { return }
        folds[sessionID]?.turnOpen = false
        foldsFollowState()
    }

    /// A turn the engine ended itself, which no hook will end: No and stop on the island (Claude sends no Stop for an
    /// interrupt, P1437), the stop's verdict (P1423), a restored wait (P8). It reads interrupted, with no signal, and the
    /// fold's own turn ends with it.
    func applyOwnInterrupt(_ sessionID: String, summary: String, at timestamp: Date) {
        state.apply(.sessionCompleted(SessionCompleted(sessionID: sessionID, summary: summary, timestamp: timestamp, isInterrupt: true)))
        interruptedSessionIDs.insert(sessionID)
        endFoldTurn(sessionID)
    }

    /// Claude says it waits at its prompt (`idle_prompt`): a turn it ended with no Stop (Esc in its tab) is over (P1438).
    /// Only while its agent holds its terminal, and only a notice a full minute after the turn began: a sooner one was
    /// sent before it began.
    func foldIdleNotice(_ sessionID: String) {
        guard let fold = folds[sessionID], fold.turnOpen, foldReach(sessionID) == .tab else { return }
        if let opened = fold.turnOpenedAt, dependencies.now().timeIntervalSince(opened) < Self.idleNoticeAfter { return }
        endFoldTurn(sessionID)
    }

    /// Codex refused the resume's run: another process still writes its thread (its shared daemon keeps one up to 30
    /// minutes after its tab closed; P1440). Nothing went on: a stop the run was to carry on comes back with Continue,
    /// and a reply the owner typed keeps its Retry.
    ///
    /// When Codex's shared background service turns out to hold the thread (P1488), a typed reply waits for its turn's end
    /// and goes there (nothing ran, so it goes once), and a Continue whose turn still runs there has nothing to carry on.
    func foldResumeHeld(_ sessionID: String) {
        guard let fold = folds[sessionID] else { return }
        noteFold(sessionID, .resumeHeld)
        if let service = conversationResume?.serviceStatus(sessionID), service.holds, let line = fold.lastReply {
            folds[sessionID]?.continuedFrom = nil
            if line == Self.continuePrompt, service.turnRuns {
                noteFold(sessionID, .serviceFinishing)
                return
            }
            if line == Self.continuePrompt, let carried = fold.continuedFrom, fold.stopped == nil {
                // Its turn is over there too: Continue stays offered, and now goes to the service.
                folds[sessionID]?.stopped = carried
                return
            }
            folds[sessionID]?.send = nil
            folds[sessionID]?.held = line
            folds[sessionID]?.heldWay = .daemon
            noteFold(sessionID, .held(.daemon))
            return scheduleHeldCheck(sessionID)
        }
        let carried = fold.continuedFrom
        if let carried, fold.stopped == nil { folds[sessionID]?.stopped = carried }
        folds[sessionID]?.continuedFrom = nil
        // Continue is its own retry; a reply the owner typed keeps Retry.
        if carried == nil || fold.lastReply != Self.continuePrompt { folds[sessionID]?.send = .notSent }
    }

    /// Keeps the agent at the tab's controls (the notes' pid, or `pid`), its name and its shell, while it runs there, and
    /// watches it for its exit. A pid that does not hold its terminal (the island's own run, a stopped agent) is not
    /// taken.
    func adoptFoldAgent(_ sessionID: String, pid given: Int32? = nil) {
        // A background session's process runs under Claude Code's supervisor, in no tab of the owner's (P1455).
        guard folds[sessionID] != nil, !islandResumes.isRunning(sessionID), folds[sessionID]?.background?.holdsTheConversation != true,
              let pid = given ?? hookNotes.contexts[sessionID]?.agentPID else { return }
        if folds[sessionID]?.agentPID != pid {
            // Codex's shared daemon holds no tab, whatever terminal its parent holds (P1485).
            guard !agentIsCodexServer(pid), dependencies.agentAtPrompt(pid) else { return }
            folds[sessionID]?.agentPID = pid
            folds[sessionID]?.agentName = dependencies.processName(pid)
            folds[sessionID]?.shellPID = dependencies.parentPID(pid)
        }
        watchFoldAgent(sessionID)
    }

    /// The agent the fold follows now: the notes' latest, but while the island's own run is under way.
    func foldAgent(_ sessionID: String) -> Int32? {
        let kept = folds[sessionID]?.agentPID
        return islandResumes.isRunning(sessionID) ? kept : hookNotes.contexts[sessionID]?.agentPID ?? kept
    }

    /// Whether the agent at `pid` still runs: alive, and, for the agent the fold kept, still that program (a pid the
    /// system gave another one since is not its agent, P1420). A name that cannot be read counts as the same.
    public func foldAgentRuns(_ sessionID: String, pid: Int32) -> Bool {
        guard dependencies.processExists(pid) else { return false }
        guard let fold = folds[sessionID], fold.agentPID == pid, let name = fold.agentName,
              let now = dependencies.processName(pid) else { return true }
        return now == name
    }

    /// Why a folded session's tab takes no reply now; nil while its agent holds it.
    func foldGoneWhy(_ sessionID: String) -> FoldGone? {
        guard folds[sessionID] != nil else { return nil }
        guard let session = state.session(id: sessionID) else { return .dropped }
        if session.isSessionEnded { return .sessionEnded }
        guard let pid = foldAgent(sessionID) else { return .noAgent }
        if !foldAgentRuns(sessionID, pid: pid) { return .processEnded }
        // Codex's shared daemon runs it: no tab to leave; it ends only with the daemon (P1486).
        if agentIsCodexServer(pid) { return nil }
        return dependencies.agentAtPrompt(pid) ? nil : .leftTerminal
    }

    /// After every change of the state, for each folded session: the log says once when its tab went, and why, or came
    /// back (P1429); and an agent gone while its own turn ran gets the stop's verdict a moment later (P1415).
    func followFoldAgent(_ sessionID: String) {
        // In the background, on its way there, or maybe (a move that did not show): its tab's agent leaving is the move,
        // never a stop (P1456, P1457).
        guard let fold = folds[sessionID], fold.background?.keepsTheStopOut != true else { return }
        let way = foldReach(sessionID).way
        if fold.seenWay != way {
            folds[sessionID]?.seenWay = way
            if fold.seenWay == nil {
                // First look (a preview's fold): nothing changed yet.
            } else if fold.seenWay == .tab {
                noteFold(sessionID, .tabGone(foldGoneWhy(sessionID) ?? .leftTerminal))
            } else if way == .tab {
                noteFold(sessionID, .tabBack)
            }
        }
        if fold.turnOpen, fold.stopped == nil, Self.endsTheAgent(foldGoneWhy(sessionID)) { scheduleStopCheck(sessionID) }
    }

    /// What says the agent ended: its process gone, its session ended, or dropped. An agent stopped with Ctrl-Z or in
    /// the background still runs, and is no stop.
    nonisolated static func endsTheAgent(_ why: FoldGone?) -> Bool {
        why == .processEnded || why == .sessionEnded || why == .dropped
    }

    func scheduleStopCheck(_ sessionID: String) {
        guard !islandResumes.isRunning(sessionID), foldStopChecks.insert(sessionID).inserted else { return }
        dependencies.scheduleFoldCheck(Self.stopSettle) { [weak self] in
            guard let self else { return }
            self.foldStopChecks.remove(sessionID)
            self.settleFoldStop(sessionID)
        }
    }

    /// The verdict: its agent ended while its own turn ran (P1415). Its window closed when the shell its agent ran under
    /// went too; otherwise the agent alone ended (it quit or crashed). The card keeps its last answer, and stays.
    func settleFoldStop(_ sessionID: String) {
        guard let fold = folds[sessionID], fold.turnOpen, fold.stopped == nil, !islandResumes.isRunning(sessionID),
              fold.background?.keepsTheStopOut != true else { return }
        // Its CLI quit for an app that took the conversation (`/desktop`, `/quit`): no stop (P1515).
        guard !foldIsInApp(sessionID) else { return }
        let why = foldGoneWhy(sessionID)
        guard Self.endsTheAgent(why), let why else { return }
        // A turn Codex's shared daemon ran ended with the daemon, not with a window (P1486).
        let closed = notesNameACodexServer(sessionID) ? false : fold.shellPID.map { !dependencies.processExists($0) } ?? true
        folds[sessionID]?.turnOpen = false
        folds[sessionID]?.stopped = FoldStop(at: dependencies.now(), windowClosed: closed, why: why)
        foldExitWatches.removeValue(forKey: sessionID)?.token.cancel()
        noteFold(sessionID, .stopped(windowClosed: closed, why: why))
        // Its turn reads interrupted, no longer working: no hook will say so, and the process monitor ends a session only
        // ten minutes after its last hook (P7), so its glyph and the counts would read working till then. No signal.
        if let session = state.session(id: sessionID), session.phase != .completed {
            applyOwnInterrupt(sessionID, summary: Self.stoppedSummary, at: dependencies.now())
        }
        // A reply held for its tab goes back to the field now (P1356).
        foldsFollowState()
    }

    /// The summary a stopped turn is left with.
    nonisolated static let stoppedSummary = "Interrupted (its agent ended mid-turn)."


    /// Watches the folded session's agent for its exit, one watch per session on the pid it follows now.
    func watchFoldAgent(_ sessionID: String) {
        let pid = folds[sessionID]?.agentPID
        if let current = foldExitWatches[sessionID], current.pid == pid { return }
        foldExitWatches.removeValue(forKey: sessionID)?.token.cancel()
        guard let pid, let watch = dependencies.watchProcessExit ?? (configuration.startBridge ? AgentExitWatch.live : nil),
              let token = watch(pid, { [weak self] in self?.foldAgentExited(sessionID, pid: pid) }) else { return }
        foldExitWatches[sessionID] = (pid, token)
    }

    /// The agent the fold watched exited: the verdict's check, whatever the process table says this instant (a process
    /// not reaped yet still answers `kill(pid, 0)`), and the log's word on its tab.
    func foldAgentExited(_ sessionID: String, pid: Int32) {
        guard folds[sessionID] != nil else { return }
        if foldExitWatches[sessionID]?.pid == pid { foldExitWatches[sessionID] = nil }
        // The tab's agent left after `/background`: the move's next look sees it, and a move that did not show while it
        // stayed is looked at again (P1456, P1457).
        if folds[sessionID]?.background?.keepsTheStopOut == true { return followBackgroundMove(sessionID, agentExited: true) }
        if folds[sessionID]?.turnOpen == true, folds[sessionID]?.stopped == nil { scheduleStopCheck(sessionID) }
        followFoldAgent(sessionID)
    }

    // MARK: The log (P1429, P1430)

    /// One line in `JuiceLog.fold` (`log show --predicate 'category == "fold"'`) and one note for Copy Report: the
    /// session's id and the decision's words, never a reply's or an answer's text.
    func noteFold(_ sessionID: String, _ decision: FoldDecision) {
        let said = decision.said
        JuiceLog.fold.notice("\(sessionID, privacy: .public) \(said, privacy: .public)")
        foldNotes.append(FoldNote(at: dependencies.now(), sessionID: sessionID, said: said))
        if foldNotes.count > Self.foldNoteLimit { foldNotes.removeFirst(foldNotes.count - Self.foldNoteLimit) }
    }
}
