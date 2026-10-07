import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore

/// A folded Claude Code session in Claude Code's own background (wave 8, P1450 to P1484): Send to island typed `/background`
/// into its tab, or it ran there already (`claude --bg`, a session Juice started). Its window can close and the work
/// goes on; its card replies through `claude attach`, opens it with `claude attach <id>` in a new window, and stops it
/// with `claude stop <id>`.
public struct FoldBackground: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        /// Something waits on the owner in its tab (an approval, a question): nothing is typed now, and `/background` goes once
        /// its turn ends.
        case waitsForTurnEnd
        /// `/background` was typed: the island waits to see its tab's agent gone and its background row listed.
        case moving
        /// In Claude Code's background, as its profile's list says.
        case moved
        /// The move did not happen; the card is a tab's card again.
        case notMoved(FoldMoveMiss)
    }

    public var stage: Stage
    /// The id `claude attach`, `stop` and `logs` take.
    public var shortID: String?
    /// The config folder whose supervisor runs it.
    public var profile: String
    /// Its working folder.
    public var folder: String
    /// The interactive session's id, when the conversation went on in the background under another id (Claude Code
    /// resumes a fork of the transcript there): the fold is keyed by the new one.
    public var movedFrom: String?
    /// The terminal app a window attached to it runs in ("Terminal"), while one is attached.
    public var attachedIn: String?
    /// Stop ran (`claude stop`): its conversation is kept, and a reply wakes it.
    public var stoppedByOwner = false
    /// When `/background` was typed.
    public var typedAt: Date?
    /// Its background row as the last list showed it.
    public var listed: ClaudeBackgroundEntry?
    /// The background rows its profile listed before `/background`, by short id: the new one is the one not among them.
    public var before: Set<String> = []
    /// Its name as its interactive row gave it: the background copy is listed under it (or "<name> (2)").
    public var name: String?

    public init(stage: Stage, shortID: String? = nil, profile: String, folder: String) {
        self.stage = stage
        self.shortID = shortID
        self.profile = profile
        self.folder = folder
    }

    /// In the background or on its way there: its tab no longer takes a reply, and its tab's agent leaving is the move,
    /// never a stop.
    public var holdsTheConversation: Bool { stage == .moved || stage == .moving }

    /// `/background` was typed and did not move it as seen: its tab may hold a dialog Claude Code asked first, or the line
    /// unsent, or the conversation may run in the background under an id the island could not tell. Nothing more is
    /// typed into the tab, no resume runs and no stop is said; Open in terminal shows the owner what is there (P1457).
    public var leftItUnsure: Bool { waitsInItsTab || stage == .notMoved(.cannotTell) }

    /// Unsure while its tab's agent stays there: when that agent ends, the move is looked at again.
    public var waitsInItsTab: Bool { stage == .notMoved(.stillInTab) || stage == .notMoved(.asksInItsTab) }

    /// Its tab's agent leaving says nothing of a stop: it moved, is moving, or may have (P1456, P1457).
    public var keepsTheStopOut: Bool { holdsTheConversation || leftItUnsure }
}

/// Why `/background` did not move a folded session.
public enum FoldMoveMiss: String, Equatable, Sendable {
    /// Its tab's agent still runs there (a dialog in the tab may ask first).
    case stillInTab = "it is still in its tab"
    /// Its own row says a dialog is open in its tab: Claude Code asks first ("Background this session?"), and only the
    /// owner answers it there.
    case asksInItsTab = "Claude asks something in its tab"
    /// Its tab's agent went, and no new background row was listed at all: it did not move (the owner quit it, or its
    /// window closed first), and the card is a tab's card whose tab is gone (P1457).
    case notListed = "Claude did not list it"
    /// Its tab's agent went, and the list could not tell which new background row is it (more than one could be, or the
    /// list could not be read): it may run there, so nothing goes from the island (P1454, P1457).
    case cannotTell = "Claude did not say which session it is"
    /// `/background` could not be typed.
    case notTyped = "it could not be typed"
    /// Its tab was in front when its turn ended, where the owner may be typing.
    case tabInFront = "its tab was in front"
    /// Its agent ended mid-turn (its window closed) before its turn's end: the stop's card takes over.
    case stoppedFirst = "it stopped first"
}

/// What the background move and its card did, as the fold's log says it (P1429): ids and states only.
public enum FoldBackgroundDecision: Equatable, Sendable {
    case unavailable
    case waits
    case typed(Bool)
    /// Its tab's agent ended after a move that did not show: the move is looked at again.
    case looksAgain
    case moved(sameID: Bool)
    case notMoved(FoldMoveMiss)
    case known
    case reply(AttachOutcome)
    case typedInAttached(Bool)
    case opened(Bool)
    case stopped(Bool)
    /// A terminal runs the conversation now: the card is that terminal's (P1541).
    case inATerminal

    var said: String {
        switch self {
        case .unavailable: "background · not offered by this Claude Code"
        case .waits: "background · moves when its turn ends"
        case let .typed(sent): sent ? "background · /background typed" : "background · /background not typed"
        case .looksAgain: "background · its tab's agent ended · looking again"
        case let .moved(sameID): sameID ? "background · moved" : "background · moved, under a new id"
        case let .notMoved(miss): "background · not moved · \(miss.rawValue)"
        case .known: "background · sent to the island as a background session"
        case let .reply(outcome):
            switch outcome {
            case .sent: "background · reply typed through the attach"
            case .notReady: "background · reply not typed · it never settled"
            case .ended: "background · reply not typed · the attach ended"
            case .notWritten: "background · reply not typed"
            }
        case let .typedInAttached(sent): sent ? "background · reply typed into its attached window" : "background · reply not typed into its attached window"
        case let .opened(opened): opened ? "background · opened attached in a new window" : "background · not opened"
        case let .stopped(stopped): stopped ? "background · stopped" : "background · not stopped"
        case .inATerminal: "background · a terminal runs it now · the card follows it there"
        }
    }
}

extension FoldDecision {
    static func backgroundReply(_ outcome: AttachOutcome) -> FoldDecision { .background(.reply(outcome)) }
}

extension SessionEngine {
    /// What Send to island types into a Claude Code tab to move its conversation into Claude Code's background.
    public nonisolated static let backgroundCommand = "/background"
    /// How many times the move is looked at, and how far apart: the tab's agent gone, its background row listed. A look
    /// while its turn still runs in its tab does not count (Claude Code may hold a command typed mid-turn until the turn
    /// ends, P1451), up to `moveLookLimit` looks in all.
    nonisolated static let moveLooks = 20
    nonisolated static let moveLookEvery: TimeInterval = 1.5
    nonisolated static let moveLookLimit = 2_400
    /// How often a background session's list is read while its card is on the island.
    nonisolated static let backgroundListEvery: TimeInterval = 60

    /// The folded session's background state, if any.
    public func foldBackground(_ sessionID: String) -> FoldBackground? { folds[sessionID]?.background }

    /// The id a conversation went on under in the background, for the interactive session it left.
    public func movedConversation(from sessionID: String) -> String? { movedConversations[sessionID] }

    /// The profile folder a Claude session runs in: its account tag, else its transcript's, else the default folder.
    func claudeProfile(for session: AgentSession) -> String {
        if let folder = accountTags[session.id]?.folder { return ResumeCommand.expanded(folder) }
        if let folder = SessionResumer.profile(of: session, provider: .claude) { return ResumeCommand.expanded(folder) }
        return ResumeCommand.expanded(NSHomeDirectory() + "/" + Provider.claude.defaultFolderName)
    }

    /// Whether Send to island moves this session into Claude Code's background: the switch is on, it is a Claude Code
    /// session on this Mac with a working folder here, and the app has a backgrounder.
    func movesToBackground(_ session: AgentSession) -> Bool {
        keepsClaudeRunning && claudeBackground != nil && session.tool == .claudeCode && !session.isSessionEnded
            && remoteSessions.entry(for: session.id) == nil && ExactJump.nonEmpty(session.jumpTarget?.workingDirectory) != nil
    }

    /// A session the list knows as a live background one folds as one, with no tab (P1465).
    func foldsAsBackground(_ sessionID: String) -> Bool {
        keepsClaudeRunning && claudeBackground?.isLiveBackground(sessionID) == true
    }

    /// Send to island of a session that runs in the background already: its card is a background card from the start.
    func foldKnownBackground(_ session: AgentSession) -> FoldOutcome {
        guard let backgrounder = claudeBackground, let known = backgrounder.known[session.id] else { return .refused }
        var fold = FoldedSession(sessionID: session.id, since: dependencies.now(), session: session)
        fold.turnOpen = session.phase != .completed || known.entry.isBusy
        fold.turnOpenedAt = fold.turnOpen ? dependencies.now() : nil
        fold.seenWay = .background
        var background = FoldBackground(stage: .moved, shortID: known.entry.id, profile: known.profile,
                                        folder: known.entry.cwd ?? session.jumpTarget?.workingDirectory ?? NSHomeDirectory())
        background.listed = known.entry
        fold.background = background
        folds[session.id] = fold
        noteFold(session.id, .background(.known))
        scheduleBackgroundReads()
        return .folded(bounds: nil)
    }

    /// After a Claude session folded with its tab (switch on): its profile's list is read; a session listed as a
    /// background one already is one; else `/background` is typed into its tab now, or once its turn ends when something waits on
    /// the owner there (P1450, P1452). Nothing is typed when the list cannot be read: this Claude Code may not have
    /// background sessions, and a move that cannot be seen is never made.
    func beginBackgroundMove(_ sessionID: String) async {
        // Never beside a hand-over to Claude, which types its own command into the tab (P1533).
        guard let backgrounder = claudeBackground, backgrounder.canRun, let fold = folds[sessionID], fold.background == nil,
              appHandoff?.state(for: sessionID) == nil,
              let session = state.session(id: sessionID) ?? fold.session, movesToBackground(session),
              let folder = ExactJump.nonEmpty(session.jumpTarget?.workingDirectory) else { return }
        let profile = claudeProfile(for: session)
        guard let rows = await backgrounder.list(profile: profile) else {
            noteFold(sessionID, .background(.unavailable))
            return
        }
        guard folds[sessionID] != nil, folds[sessionID]?.background == nil else { return }
        var background = FoldBackground(stage: .waitsForTurnEnd, profile: profile, folder: ResumeCommand.expanded(folder))
        background.before = Set(rows.filter(\.isBackground).compactMap(\.id))
        let own = rows.first { $0.sessionID == sessionID }
        if let own, own.isBackground {
            // It runs in the background already (it was started there, or moved before): no `/background`.
            background.stage = .moved
            background.shortID = own.id
            background.listed = own
            folds[sessionID]?.background = background
            folds[sessionID]?.seenWay = .background
            noteFold(sessionID, .background(.known))
            scheduleBackgroundReads()
            return
        }
        background.name = own?.name
        // The folder it was started in, as its own row says: the background copy runs there (P1454).
        if let cwd = own?.cwd.flatMap(ExactJump.nonEmpty) { background.folder = ResumeCommand.expanded(cwd) }
        folds[sessionID]?.background = background
        // Its own row waits on the owner too when a dialog is open in its tab with no hook behind it (a picker, a
        // setting): typing there would choose in it (P1453).
        if ownerMustAnswerFirst(sessionID) || own?.waitsOnSomeone == true {
            noteFold(sessionID, .background(.waits))
            return
        }
        await typeBackgroundCommand(sessionID)
    }

    /// Something waits on the owner in the session's tab: an approval, a question, a plan, a prompt with no hook behind
    /// it. Typing then would answer that, not move it (P1453).
    func ownerMustAnswerFirst(_ sessionID: String) -> Bool {
        if attentionHead(for: sessionID) != nil { return true }
        return state.session(id: sessionID)?.phase.requiresAttention == true
    }

    /// Types `/background` into the folded session's tab, while its agent holds the tab, through the tab's own route (the same
    /// sender a reply goes by). On the owner's click (Send to island), or at the end of the turn it waited for.
    func typeBackgroundCommand(_ sessionID: String) async {
        guard folds[sessionID]?.background != nil, let session = state.session(id: sessionID),
              let route = replyRoute(for: session), let pid = hookNotes.contexts[sessionID]?.agentPID,
              dependencies.agentAtPrompt(pid),
              let sender = dependencies.sendReply ?? (configuration.startBridge ? ReplySender.live : nil) else {
            return backgroundMoveFailed(sessionID, .notTyped)
        }
        let atPrompt = dependencies.agentAtPrompt, command = Self.backgroundCommand
        folds[sessionID]?.background?.stage = .moving
        folds[sessionID]?.background?.typedAt = dependencies.now()
        let sent = await ReplySender.run { atPrompt(pid) && sender(route, command) }
        noteFold(sessionID, .background(.typed(sent)))
        guard folds[sessionID]?.background?.stage == .moving else { return }
        guard sent else { return backgroundMoveFailed(sessionID, .notTyped) }
        scheduleMoveCheck(sessionID, look: 0)
    }

    func backgroundMoveFailed(_ sessionID: String, _ miss: FoldMoveMiss) {
        guard folds[sessionID]?.background != nil else { return }
        folds[sessionID]?.background?.stage = .notMoved(miss)
        noteFold(sessionID, .background(.notMoved(miss)))
        foldsFollowState()
    }

    /// One look at the move, `moveLookEvery` apart: `look` counted ones, `total` in all.
    func scheduleMoveCheck(_ sessionID: String, look: Int, total: Int = 0) {
        dependencies.scheduleFoldCheck(total == 0 ? 0.5 : Self.moveLookEvery) { [weak self] in
            guard let self else { return }
            self.backgroundMoves[sessionID] = Task { @MainActor [weak self] in await self?.checkMove(sessionID, look: look, total: total) }
        }
    }

    /// The move is seen once its tab's agent is gone and its profile's list names a background row for the
    /// conversation: under the same id, or (as Claude Code does now) a new row of its name or folder that was not there
    /// before. Never while its tab's agent still runs: two live copies of one conversation lose turns (P1454). While its
    /// turn runs in its tab the looks go on uncounted: a `/background` Claude Code held runs as that turn ends (P1451).
    func checkMove(_ sessionID: String, look: Int, total: Int = 0) async {
        guard let background = folds[sessionID]?.background, background.stage == .moving,
              let backgrounder = claudeBackground else { return }
        let agentGone = folds[sessionID]?.agentPID.map { !foldAgentRuns(sessionID, pid: $0) } ?? true
        // While its agent stays, every few looks its own row says whether a dialog asks first in its tab.
        let reads = agentGone || (total + 1) % Self.stayingListEvery == 0
        let rows = reads ? await backgrounder.list(profile: background.profile) : nil
        guard let current = folds[sessionID]?.background, current.stage == .moving else { return }
        if agentGone, let rows, let entry = Self.movedRow(rows, sessionID: sessionID, background: current) {
            return settleMove(sessionID, entry: entry)
        }
        if !agentGone, let rows, Self.asksInItsTab(rows, sessionID: sessionID) {
            return backgroundMoveFailed(sessionID, .asksInItsTab)
        }
        let counts = agentGone || folds[sessionID]?.turnOpen != true
        let next = counts ? look + 1 : look
        guard next < Self.moveLooks, total + 1 < Self.moveLookLimit else {
            return backgroundMoveFailed(sessionID, Self.moveMiss(agentGone: agentGone, rows: rows, background: current))
        }
        scheduleMoveCheck(sessionID, look: next, total: total + 1)
    }

    /// Every how many looks the list is read while the tab's agent stays.
    nonisolated static let stayingListEvery = 4

    /// Its interactive row says a dialog is open: Claude Code asks before it moves work that cannot move (agent view
    /// docs, "Background this session?").
    nonisolated static func asksInItsTab(_ rows: [ClaudeBackgroundEntry], sessionID: String) -> Bool {
        rows.contains { $0.kind == .interactive && $0.sessionID == sessionID && $0.waitingFor == "dialog open" }
    }

    /// Why the looks ran out: its tab's agent still there; else no new background row at all (it did not move, sure);
    /// else rows that could be it and none the island can tell, or no list (P1457).
    nonisolated static func moveMiss(agentGone: Bool, rows: [ClaudeBackgroundEntry]?, background: FoldBackground) -> FoldMoveMiss {
        guard agentGone else { return .stillInTab }
        guard let rows else { return .cannotTell }
        return possibleRows(rows, background: background).isEmpty ? .notListed : .cannotTell
    }

    /// Every background row that could be the conversation's: new since `/background` (not listed before it, and not
    /// started well before it was typed), with or without its name, folder or session id.
    nonisolated static func possibleRows(_ rows: [ClaudeBackgroundEntry], background: FoldBackground) -> [ClaudeBackgroundEntry] {
        let earliest = background.typedAt?.addingTimeInterval(-moveStartSlack)
        return rows.filter { row in
            guard row.isBackground, let id = row.id, ClaudeBackgroundCommand.isShortID(id), !background.before.contains(id) else {
                return false
            }
            if let earliest, let started = row.startedAt, started < earliest { return false }
            return true
        }
    }

    /// The background row the conversation went on in: one under its own id; else, among the rows that are new (not
    /// listed before `/background`, and not started well before it), the one under its name ("<name>" or "<name> (2)"), the one
    /// of those in its folder, else the one new row of its folder. nil when none, or when more than one could be it: the
    /// island never guesses which conversation is whose (P1454).
    nonisolated static func movedRow(_ rows: [ClaudeBackgroundEntry], sessionID: String, background: FoldBackground) -> ClaudeBackgroundEntry? {
        let candidates = rows.filter { $0.isBackground && $0.id.map(ClaudeBackgroundCommand.isShortID) == true }
        if let same = candidates.first(where: { $0.sessionID == sessionID }) { return same }
        let folder = ResumeCommand.expanded(background.folder)
        let earliest = background.typedAt?.addingTimeInterval(-moveStartSlack)
        let fresh = candidates.filter { row in
            guard !background.before.contains(row.id ?? ""), row.sessionID != nil else { return false }
            if let earliest, let started = row.startedAt, started < earliest { return false }
            return true
        }
        let inFolder = { (row: ClaudeBackgroundEntry) in row.cwd.map(ResumeCommand.expanded) == folder }
        if let name = background.name {
            let named = fresh.filter { $0.name == name || $0.name?.hasPrefix(name + " (") == true }
            if named.count == 1 { return named[0] }
            if named.count > 1 {
                let here = named.filter(inFolder)
                return here.count == 1 ? here[0] : nil
            }
        }
        let here = fresh.filter(inFolder)
        return here.count == 1 ? here[0] : nil
    }

    /// How long before `/background` was typed a new row may say it started (the two clocks are the same Mac's; a second's
    /// rounding either way).
    nonisolated static let moveStartSlack: TimeInterval = 5

    /// The conversation is in the background: the card follows its row, keyed by the conversation's id there (P1455).
    /// Its tab's agent is gone, so nothing watches it; the window it left holds a shell and stays where it is.
    func settleMove(_ sessionID: String, entry: ClaudeBackgroundEntry) {
        guard var fold = folds[sessionID], var background = fold.background else { return }
        background.stage = .moved
        background.shortID = entry.id
        background.listed = entry
        if let cwd = entry.cwd.flatMap(ExactJump.nonEmpty) { background.folder = ResumeCommand.expanded(cwd) }
        foldExitWatches.removeValue(forKey: sessionID)?.token.cancel()
        fold.agentPID = nil
        fold.agentName = nil
        fold.shellPID = nil
        fold.tucked = false
        fold.seenWay = .background
        let newID = entry.sessionID ?? sessionID
        noteFold(sessionID, .background(.moved(sameID: newID == sessionID)))
        if newID != sessionID {
            background.movedFrom = sessionID
            fold.background = background
            fold.sessionID = newID
            dropFold(sessionID)
            movedConversations[sessionID] = newID
            // A held reply was typed for the tab: it goes back to the field, as any held reply whose way changed (P1356).
            folds[newID] = fold
        } else {
            fold.background = background
            folds[sessionID] = fold
        }
        scheduleBackgroundReads()
        followBackgroundRows()
        foldsFollowState()
    }

    /// While a background session's card is on the island, its profile's list is read once a minute (P1458).
    func scheduleBackgroundReads() {
        guard !backgroundReadScheduled, folds.values.contains(where: { $0.background?.stage == .moved }) else { return }
        backgroundReadScheduled = true
        dependencies.scheduleFoldCheck(Self.backgroundListEvery) { [weak self] in
            guard let self else { return }
            self.backgroundReadScheduled = false
            Task { @MainActor in
                await self.readBackgroundLists()
                self.scheduleBackgroundReads()
            }
        }
    }

    /// Reads each background card's profile list once, lets each card follow its row, and looks for a terminal attached
    /// to each.
    public func readBackgroundLists() async {
        guard let backgrounder = claudeBackground else { return }
        let profiles = Set(folds.values.compactMap { $0.background?.stage == .moved ? $0.background?.profile : nil })
        for profile in profiles.sorted() { await backgrounder.list(profile: profile) }
        followBackgroundRows()
        for (id, fold) in folds {
            guard fold.background?.stage == .moved, let shortID = fold.background?.shortID else { continue }
            let pid = await backgrounder.lookForAttached(id, shortID: shortID)
            guard folds[id]?.background != nil else { continue }
            let host: String? = pid == nil ? nil : folds[id]?.background?.attachedIn ?? "a terminal"
            if folds[id]?.background?.attachedIn != host { folds[id]?.background?.attachedIn = host }
        }
        // A held reply whose turn the rows say is over gets its check.
        foldsFollowState()
    }

    /// Each background card takes its row's latest state. A row read since the card's turn began that says its last turn
    /// is done (or stopped, or failed) ends that turn, for a session whose hooks said nothing (P1459); one read before a
    /// new prompt says nothing of that prompt's turn.
    func followBackgroundRows() {
        guard let backgrounder = claudeBackground else { return }
        for (id, fold) in folds {
            guard let background = fold.background, background.stage == .moved else { continue }
            // A terminal runs the conversation now (P1541): the owner's `claude --resume <id>` once its copy stopped.
            if let other = backgrounder.elsewhere[id]?.entry.pid, dependencies.processExists(other) {
                backgroundCopyLeftForATerminal(id)
                continue
            }
            guard let known = backgrounder.known[id] else { continue }
            if known.entry != background.listed { folds[id]?.background?.listed = known.entry }
            let over = !known.entry.isBusy && ["done", "stopped", "failed"].contains(known.entry.state ?? "")
            let since = fold.turnOpenedAt.map { known.seenAt > $0 } ?? true
            if over, since, fold.turnOpen { endFoldTurn(id) }
        }
    }

    /// Claude Code lists a live copy of the conversation that is not its background one (P1541): a terminal runs it now.
    /// The card is no background card from then on: a reply goes to that terminal's tab as a tab's does, its agent there is
    /// followed for its stop, and nothing attaches to the background copy, which would wake it beside the terminal's. Its
    /// Stop and its once-a-minute list go with it.
    func backgroundCopyLeftForATerminal(_ sessionID: String) {
        guard folds[sessionID]?.background != nil else { return }
        folds[sessionID]?.background = nil
        folds[sessionID]?.seenWay = nil
        claudeBackground?.clearProblem(sessionID)
        noteFold(sessionID, .background(.inATerminal))
        adoptFoldAgent(sessionID)
    }

    /// Whether a folded background session's turn runs: the fold's own turn, else its hooks' phase, else (for a session
    /// whose hooks said nothing) its row's `busy`; and all the while its move is being confirmed (a reply then waits).
    func backgroundTurnRuns(_ sessionID: String) -> Bool? {
        guard let fold = folds[sessionID], let background = fold.background, background.holdsTheConversation else { return nil }
        if background.stage == .moving { return true }
        // A turn its hooks opened, even in a session the list last saw stopped: a reply woke it.
        if fold.turnOpen { return true }
        if background.stoppedByOwner || background.listed?.hasEnded == true { return false }
        if let session = state.session(id: sessionID), !session.isSessionEnded { return session.phase != .completed }
        return background.listed?.isBusy == true
    }

    /// A reply its row turned away because a turn runs there: the turn counts as open from now, so the reply waits for
    /// its end (a Stop, or a row read after now that says it is done), as any held reply does (P1306, P1459).
    func holdBackgroundReply(_ sessionID: String, _ line: String) {
        guard folds[sessionID] != nil else { return }
        if folds[sessionID]?.turnOpen == false {
            folds[sessionID]?.turnOpen = true
            folds[sessionID]?.turnOpenedAt = dependencies.now()
        }
        folds[sessionID]?.held = line
        folds[sessionID]?.heldWay = .background
        folds[sessionID]?.send = nil
        noteFold(sessionID, .held(.background))
        scheduleBackgroundReads()
    }

    /// After every change of the state: a move that waited for its turn's end goes, a second after it (P1452). Its window
    /// closed first: wave 7's stop and Continue take over, and nothing is typed (P1415).
    func followBackgroundMove(_ sessionID: String, agentExited: Bool = false) {
        if folds[sessionID]?.background?.stage == .waitsForTurnEnd, folds[sessionID]?.stopped != nil {
            folds[sessionID]?.background = nil
            noteFold(sessionID, .background(.notMoved(.stoppedFirst)))
            return
        }
        // A move that did not show while its tab's agent stayed, whose agent has now ended: it may have moved late (a
        // dialog answered, the line sent), so it is looked at again, once (P1457).
        if folds[sessionID]?.background?.waitsInItsTab == true, let pid = folds[sessionID]?.agentPID,
           agentExited || !foldAgentRuns(sessionID, pid: pid) {
            folds[sessionID]?.background?.stage = .moving
            noteFold(sessionID, .background(.looksAgain))
            return scheduleMoveCheck(sessionID, look: 0)
        }
        // A reply held for its tab, or on its way, goes first; the move waits for the end of the turn it starts.
        guard let background = folds[sessionID]?.background, background.stage == .waitsForTurnEnd,
              folds[sessionID]?.turnOpen == false, folds[sessionID]?.held == nil, folds[sessionID]?.send != .sending,
              !ownerMustAnswerFirst(sessionID), backgroundMoveChecks.insert(sessionID).inserted else { return }
        dependencies.scheduleFoldCheck(Self.heldReplySettle) { [weak self] in
            guard let self else { return }
            self.backgroundMoveChecks.remove(sessionID)
            self.backgroundMoves[sessionID] = Task { @MainActor [weak self] in await self?.typeWaitingBackgroundCommand(sessionID) }
        }
    }

    /// The move that waited: typed now, unless a turn runs again, something waits on the owner, or its tab is in front,
    /// where the owner may be typing (P1359).
    func typeWaitingBackgroundCommand(_ sessionID: String) async {
        guard waitingMoveCanGo(sessionID), let session = state.session(id: sessionID) else { return }
        let inFront = await dependencies.isSessionFrontmost(withEffectiveJumpTarget(session))
        guard waitingMoveCanGo(sessionID) else { return }
        if inFront { return backgroundMoveFailed(sessionID, .tabInFront) }
        // Its own row once more: a dialog still open in its tab keeps the move waiting, as does a list that could not be
        // read (P1453).
        guard let profile = folds[sessionID]?.background?.profile, let rows = await claudeBackground?.list(profile: profile),
              waitingMoveCanGo(sessionID),
              rows.first(where: { $0.kind == .interactive && $0.sessionID == sessionID })?.waitsOnSomeone != true else { return }
        await typeBackgroundCommand(sessionID)
    }

    /// The move that waited may go now: its turn over, nothing waiting on the owner, no reply held or on its way.
    func waitingMoveCanGo(_ sessionID: String) -> Bool {
        guard let fold = folds[sessionID] else { return false }
        return fold.background?.stage == .waitsForTurnEnd && !fold.turnOpen && fold.held == nil && fold.send != .sending
            && !ownerMustAnswerFirst(sessionID) && appHandoff?.state(for: sessionID) == nil
    }

    // MARK: The card's reply, Open in terminal and Stop

    /// The line when a reply could not be typed into the window attached to it.
    nonisolated static let typeInItsWindow = "Not sent · type it in its window"

    /// A reply to a background session (P1460, P1461): into the tab of a window attached to it, when one is (two
    /// attaches at once are never made); else through `claude attach` in a pseudo-terminal of the app's.
    func replyBackground(_ sessionID: String, _ line: String) async -> SendOutcome {
        guard let background = folds[sessionID]?.background, background.stage == .moved, let shortID = background.shortID,
              let backgrounder = claudeBackground else { return .notSent }
        backgrounder.clearProblem(sessionID)
        if let pid = await backgrounder.lookForAttached(sessionID, shortID: shortID) {
            // As a tab's reply: into the Terminal tab whose tty is the attach's (another terminal's window takes it there).
            guard let tty = dependencies.ttyForPID(pid).flatMap(ExactJump.nonEmpty),
                  let sender = dependencies.sendReply ?? (configuration.startBridge ? ReplySender.live : nil) else {
                backgrounder.say(sessionID, Self.typeInItsWindow)
                return .notSent
            }
            let sent = await ReplySender.run { sender(.terminal(tty: tty), line) }
            noteFold(sessionID, .background(.typedInAttached(sent)))
            if !sent { backgrounder.say(sessionID, Self.typeInItsWindow) }
            return sent ? .sent : .notSent
        }
        let outcome = await backgrounder.reply(sessionID: sessionID, shortID: shortID, line: line, folder: background.folder,
                                              profile: background.profile)
        if outcome == .sent, folds[sessionID]?.background?.stoppedByOwner == true {
            // A reply wakes a stopped session.
            folds[sessionID]?.background?.stoppedByOwner = false
        }
        return outcome
    }

    /// The window attached to a background session, as the frontmost check sees a tab (P1542): the session with the
    /// attach's terminal and tty for its jump target. nil when none is attached, or its tty is not known.
    func attachedWindow(_ sessionID: String) async -> AgentSession? {
        guard let background = folds[sessionID]?.background, background.stage == .moved, let shortID = background.shortID,
              let backgrounder = claudeBackground, let pid = await backgrounder.lookForAttached(sessionID, shortID: shortID),
              let tty = dependencies.ttyForPID(pid).flatMap(ExactJump.nonEmpty),
              var session = state.session(id: sessionID) ?? folds[sessionID]?.session else { return nil }
        let folder = folds[sessionID]?.background?.folder ?? background.folder
        session.jumpTarget = JumpTarget(terminalApp: "Terminal", workspaceName: URL(fileURLWithPath: folder).lastPathComponent,
                                        paneTitle: session.title, workingDirectory: folder, terminalTTY: tty)
        return session
    }

    /// Open in terminal for a background session: a new window attached to it (`claude attach <id>`); the card stays
    /// (P1462). Never while something else holds the conversation (P1541); when its list shows a terminal running it, the
    /// card is that terminal's from now on (`followBackgroundRows`), and Open in terminal goes there as a tab's does.
    func openBackground(_ sessionID: String) async {
        guard let background = folds[sessionID]?.background, background.stage == .moved, let shortID = background.shortID,
              let backgrounder = claudeBackground else { return }
        // Its row as it is now (P1458): the card's line follows it.
        let rows = await backgrounder.list(profile: background.profile)
        followBackgroundRows()
        guard folds[sessionID]?.background?.stage == .moved else { return }
        let host = SessionResumer.host(bundleID: hookNotes.contexts[background.movedFrom ?? sessionID]?.hostBundleID)
            ?? folds[sessionID]?.host.flatMap(FreshSessionLaunch.Host.init(name:))
        let opened = await backgrounder.open(sessionID: sessionID, shortID: shortID, folder: background.folder,
                                             profile: background.profile, host: host, rows: rows)
        noteFold(sessionID, .background(.opened(opened)))
        guard folds[sessionID] != nil else { return }
        folds[sessionID]?.notOpened = !opened
        if opened { folds[sessionID]?.background?.attachedIn = (host ?? backgrounder.dependencies.usualHost()).name }
    }

    /// Open in terminal while the move is under way or did not show (P1457): never the resume, which would make a second
    /// live copy of a conversation that may run in the background. Its tab, while its agent still runs there (the card
    /// stays while the move is looked at); else one look at its profile's list, and attached in a new window when it shows
    /// there now; else "Not opened", and the card stays.
    func openUnsettledBackground(_ sessionID: String) async -> JumpOutcome? {
        guard let background = folds[sessionID]?.background else { return nil }
        if let session = state.session(id: sessionID), let route = replyRoute(for: session), let agent = foldAgent(sessionID),
           foldAgentRuns(sessionID, pid: agent) {
            if let tuck = dependencies.tuckWindow ?? (configuration.startBridge ? TerminalTuck.live : nil) {
                _ = await Self.runTuck(.untuck, route, tuck)
            }
            noteFold(sessionID, .opened(.tab))
            if background.stage != .moving { dropFold(sessionID) }
            return await jump(sessionID: sessionID)
        }
        if let backgrounder = claudeBackground, let rows = await backgrounder.list(profile: background.profile),
           let current = folds[sessionID]?.background, current.stage == background.stage,
           let entry = Self.movedRow(rows, sessionID: sessionID, background: current) {
            settleMove(sessionID, entry: entry)
            let id = movedConversations[sessionID] ?? sessionID
            await openBackground(id)
            return nil
        }
        noteFold(sessionID, .background(.opened(false)))
        if folds[sessionID] != nil { folds[sessionID]?.notOpened = true }
        return nil
    }

    /// Stop on a background session's card: `claude stop <id>` (its conversation is kept, P1463). A held reply goes too,
    /// as sending it would wake the session the owner just stopped.
    func stopBackground(_ sessionID: String) async {
        guard let background = folds[sessionID]?.background, background.stage == .moved, let shortID = background.shortID,
              let backgrounder = claudeBackground else { return }
        cancelHeldReply(sessionID: sessionID)
        let stopped = await backgrounder.stop(sessionID: sessionID, shortID: shortID, profile: background.profile)
        noteFold(sessionID, .background(.stopped(stopped)))
        guard folds[sessionID] != nil else { return }
        if stopped {
            folds[sessionID]?.background?.stoppedByOwner = true
            if folds[sessionID]?.turnOpen == true { folds[sessionID]?.turnOpen = false }
        }
        followBackgroundRows()
    }

    /// At launch: each Claude profile whose supervisor kept a roster has its list read once, so a background session
    /// the island sees can be sent to the island as one (P1458).
    public func readBackgroundAtLaunch() async {
        guard keepsClaudeRunning, let backgrounder = claudeBackground else { return }
        let profiles = profileTargets.filter { $0.provider == .claude }.map(\.folder)
        await backgrounder.readKnownProfiles(profiles)
    }
}

extension FreshSessionLaunch.Host {
    init?(name: String) {
        switch name {
        case "Terminal": self = .terminal
        case "iTerm": self = .iterm
        case "Ghostty": self = .ghostty
        default: return nil
        }
    }
}

extension SessionEngine {
    /// Starts the move as a task of its own once the fold is made, so the card shows meanwhile (P1450).
    func startBackgroundMove(_ sessionID: String) {
        guard folds[sessionID] != nil, folds[sessionID]?.background == nil, let session = state.session(id: sessionID),
              movesToBackground(session) else { return }
        backgroundMoves[sessionID] = Task { @MainActor [weak self] in await self?.beginBackgroundMove(sessionID) }
    }

    /// Waits for the move a fold started, until it typed `/background` or chose not to (tests).
    func backgroundMoveStarted(_ sessionID: String) async {
        await backgroundMoves[sessionID]?.value
    }
}

extension SessionEngine {
    /// The line a new window types for a Claude session Juice starts (Open in <account>, P1470): with the switch on,
    /// the attach of a session `claude --bg` started in that folder and profile; else, or when it could not start one,
    /// `plain`. On the owner's click only.
    func backgroundStartLine(folder: String, profile: String, plain: String) async -> String {
        guard keepsClaudeRunning, let backgrounder = claudeBackground,
              let run = backgrounder.dependencies.run ?? (configuration.startBridge && ClaudeLive.allowed ? ClaudeCommandRun.live : nil)
        else { return plain }
        let environment = backgrounder.dependencies.environment()
        let started = await Task.detached(priority: .userInitiated) {
            ClaudeBackgroundStart.line(folder: folder, profile: profile, fallback: plain, run: run, environment: environment)
        }.value
        // Its row, so its session can be sent to the island as a background one once its hooks speak (P1458, P1465).
        if started.started { readAfterStart(profile: profile) }
        return started.line
    }

    /// The profile's list, read twice after a session Juice started there: soon, and once its first prompt went.
    func readAfterStart(profile: String) {
        for delay in Self.startReads {
            dependencies.scheduleFoldCheck(delay) { [weak self] in
                guard let self, let backgrounder = self.claudeBackground else { return }
                Task { @MainActor in await backgrounder.list(profile: profile) }
            }
        }
    }

    nonisolated static let startReads: [TimeInterval] = [10, 60]
}
