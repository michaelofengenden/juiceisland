import Foundation
import IslandHookNotes
import OpenIslandCore

/// The Codex threads that are not the owner's chats, in the engine (P1, P212). Codex's approvals reviewer ("auto-review",
/// Guardian) writes a rollout of its own per reviewed chat, a chat's subagents one each, and `/review`, compaction and
/// memory consolidation run helpers of their own; each once became a row of its own, titled by its system prompt,
/// with its JSON verdict as its status and a Done sound per review, and they pushed the owner's chats out of the list.
///
/// Now a thread's kind comes from its rollout's `session_meta` (`CodexThreadKind`): the scans leave the reviewer's and
/// the helpers' rollouts out before their cap and hand subagents on as `CodexChildThread`s; the launch drops restored
/// records of theirs; the tracker reports any other one it is asked to watch instead of its events. A thread found so
/// is taken out of the state and never enters it again (`codexThreads`). A subagent stays on its chat's row: "3
/// subagents" while they run, its approval (the hook names the root chat and the subagent) and its question (read from
/// its own rollout, watched while it runs or its question waits) on the chat's row and card under its name. A review's
/// thread is folded into its chat once the chat is a row, and is a row of its own until then (P217).
extension SessionEngine {
    /// Everything a launch found of the Codex threads that are not chats.
    struct CodexThreadsFound: Sendable {
        var children: [CodexChildThread] = []
        /// Restored records of threads that are not chats, by id.
        var hidden: [String: CodexThreadKind] = [:]
    }

    /// How many of a Codex chat's subagents run now (its row's "3 subagents").
    public func runningSubagents(for sessionID: String) -> Int {
        codexThreads.running(in: sessionID, now: dependencies.now()).count
    }

    /// Codex threads kept out of the rows (Diagnostics, tests).
    public var hiddenCodexThreadCount: Int { codexThreads.hiddenCount }

    // MARK: Hiding

    /// Changes the book only when the change changes it: the lists observe it, and a Codex app rescan every 10 s hands
    /// the same subagents again.
    func updateCodexThreads(_ change: (inout CodexThreadBook) -> Void) {
        var book = codexThreads
        change(&book)
        if book != codexThreads { codexThreads = book }
    }

    /// A thread found not to be a chat: out of the state and every list, never back. A subagent is kept on its chat,
    /// with `child`, else what its session showed. A review is kept the same way, and leaves the rows only once it is
    /// folded into its chat (`foldsReview`).
    func hideCodexThread(_ id: String, kind: CodexThreadKind, child: CodexChildThread? = nil) {
        guard !kind.isChat else { return }
        let now = dependencies.now()
        let session = state.session(id: id)
        if let review = kind.review {
            let known = child ?? codexThreads.child(id) ?? CodexChildThread(
                id: id, parentID: review.parentID, rootID: review.rootID, isRunning: session?.phase == .running,
                updatedAt: session?.updatedAt ?? now, transcriptPath: session?.codexMetadata?.transcriptPath ?? "", isReview: true)
            updateCodexThreads { $0.take([known], at: now) }
            guard foldsReview(id) else { return }
        }
        updateCodexThreads { book in
            if let subagent = kind.subagent, book.child(id) == nil {
                book.take([child ?? CodexChildThread(
                    id: id, parentID: subagent.parentID, rootID: subagent.rootID, name: subagent.name,
                    isRunning: session?.phase == .running, updatedAt: session?.updatedAt ?? now,
                    transcriptPath: session?.codexMetadata?.transcriptPath ?? "")], at: now)
            }
            book.hide(id, at: now)
        }
        if session != nil { state = SessionState(sessions: state.sessions.filter { $0.id != id }) }
        forgetSession(id)
        syncSubagentRollouts()
    }

    /// The tracker's report of a watched rollout that is not a chat. Only a rollout that is the session's own counts:
    /// a root whose metadata names its subagent's rollout (P167) stays.
    func takeCodexThreadKind(sessionID: String, threadID: String?, kind: CodexThreadKind) {
        guard threadID == nil || threadID == sessionID else { return }
        hideCodexThread(sessionID, kind: kind)
    }

    /// Whether a review's thread is folded into its chat: the chat is a session the lists show (P217). Until then (a
    /// review that is a chat's first action runs before Codex writes the chat's rollout, and leaves it only Codex's own
    /// text) the review is a row of its own.
    func foldsReview(_ id: String) -> Bool {
        guard let owner = codexThreads.owner(of: id), let chat = state.session(id: owner) else { return false }
        return isSurfaced(chat)
    }

    /// A scan's subagents and reviews (the launch's, then every Codex app rescan's). A subagent the scan found finished
    /// waits on nothing (P218).
    func takeCodexChildren(_ children: [CodexChildThread]) {
        guard !children.isEmpty else { return }
        let now = dependencies.now()
        let wasRunning = Set(children.compactMap { codexThreads.child($0.id)?.isRunning == true ? $0.id : nil })
        updateCodexThreads { $0.take(children, at: now) }
        for id in wasRunning where codexThreads.child(id)?.isRunning == false { noteCodexSubagentFinished(id, now: now) }
        for child in children where state.session(id: child.id) != nil {
            let thread = CodexSubagent(id: child.id, parentID: child.parentID, rootID: child.rootID, name: child.name)
            hideCodexThread(child.id, kind: child.isReview ? .review(thread) : .subagent(thread), child: child)
        }
        for child in children where !child.isReview && codexThreads.child(child.id)?.isRunning == false {
            closeSubagentQuestions(child.id)
        }
        syncSubagentRollouts()
    }

    /// The questions a subagent's rollout opened on its chat's row, closed: its turn is over.
    private func closeSubagentQuestions(_ childID: String) {
        guard let owner = codexThreads.owner(of: childID),
              attention.all.contains(where: { $0.sessionID == owner && $0.agentID == childID && $0.source == .rollout }) else { return }
        closeRequests(in: owner, cause: .turnEnd) { $0.agentID == childID && $0.source == .rollout }
    }

    /// Every state discovery writes (the launch's records, the Codex app rescan's, which upstream writes directly):
    /// no hidden thread comes back through it.
    func takeDiscoveredState(_ newState: SessionState) {
        guard !codexThreads.hidden.isEmpty, newState.sessions.contains(where: { codexThreads.isHidden($0.id) }) else {
            state = newState
            return
        }
        state = SessionState(sessions: newState.sessions.filter { !codexThreads.isHidden($0.id) })
    }

    /// The launch's own: the scans' subagents, the restored records it dropped.
    func takeStartupCodexThreads(_ found: CodexThreadsFound) {
        let now = dependencies.now()
        updateCodexThreads { book in
            for id in found.hidden.keys { book.hide(id, at: now) }
            book.take(found.children, at: now)
        }
    }

    /// Restored records of threads that are not chats (a store written before P212 kept them) are dropped, by their
    /// rollouts' first lines; the store is written again without them. Off the main thread, at launch.
    nonisolated static func dropInternalRecords(_ payload: inout SessionDiscoveryCoordinator.StartupDiscoveryPayload) -> [String: CodexThreadKind] {
        var hidden: [String: CodexThreadKind] = [:]
        // A review's record stays: it is folded into its chat once the tracker reads it, if the chat is a row (P217).
        func isChat(_ record: CodexTrackedSessionRecord) -> Bool {
            guard let path = record.codexMetadata?.transcriptPath, !path.isEmpty,
                  let kind = CodexRolloutKinds.kind(atPath: path), !kind.isChat, kind.review == nil else { return true }
            hidden[record.sessionID] = kind
            return false
        }
        let restored = payload.codexRecords.filter(isChat)
        if restored.count != payload.codexRecords.count {
            payload.codexRecords = restored
            payload.codexRecordsNeedPrune = true
        }
        payload.discoveredCodexRecords = payload.discoveredCodexRecords.filter(isChat)
        return hidden
    }

    // MARK: Subagents

    /// The running subagents' rollouts, watched for their turn ends and their questions, and those of subagents whose
    /// question waits however long they are quiet (P218); nothing when none runs or waits. A one-shot check re-syncs
    /// when the first one watched for its running alone goes quiet past the limit, so no watch outlives it at rest.
    func syncSubagentRollouts() {
        let now = dependencies.now()
        let holding = subagentsHoldingQuestions
        let targets = codexThreads.watched(now: now, holding: holding).map {
            CodexRolloutWatchTarget(sessionID: $0.id, transcriptPath: $0.transcriptPath)
        }
        defer { if subagentRollouts != nil { scheduleSubagentLapse(codexThreads.nextLapse(now: now, holding: holding), now: now) } }
        if subagentRollouts == nil {
            guard !targets.isEmpty, dependencies.watchesSubagentRollouts else { return }
            let tracker = CodexRolloutTracker()
            tracker.eventHandler = { [weak self] event in
                Task { @MainActor [weak self] in self?.ingestSubagentEvent(event) }
            }
            tracker.attentionHandler = { [weak self] update in
                Task { @MainActor [weak self] in self?.ingestSubagentAttention(update) }
            }
            subagentRollouts = tracker
        }
        subagentRollouts?.sync(targets: targets)
    }

    /// Subagents a question read from their own rollout waits on: only that rollout closes it (P218).
    var subagentsHoldingQuestions: Set<String> {
        Set(attention.all.compactMap { $0.tool == .codex && $0.source == .rollout ? $0.agentID : nil })
    }

    private func scheduleSubagentLapse(_ due: Date?, now: Date) {
        guard let due, pendingSubagentChecks.allSatisfy({ $0 > due }) else { return }
        pendingSubagentChecks.insert(due)
        // A second past it: a subagent is fresh up to the limit itself.
        dependencies.scheduleSubagentCheck(max(0, due.timeIntervalSince(now)) + 1) { [weak self] in
            self?.pendingSubagentChecks.remove(due)
            self?.syncSubagentRollouts()
        }
    }

    /// A watched subagent's own turn: running while its reducer says so, over once it completes.
    func ingestSubagentEvent(_ event: AgentEvent) {
        guard let id = Self.sessionID(of: event), let known = codexThreads.child(id) else { return }
        defer {
            if known.isRunning, codexThreads.child(id)?.isRunning == false { noteCodexSubagentFinished(id, now: dependencies.now()) }
        }
        switch event {
        case let .sessionCompleted(payload):
            updateCodexThreads { $0.setRunning(id, false, at: payload.timestamp) }
        case let .activityUpdated(payload):
            updateCodexThreads { $0.setRunning(id, payload.phase != .completed, at: payload.timestamp) }
        default:
            return
        }
        if codexThreads.child(id)?.isRunning == false { syncSubagentRollouts() }
    }

    /// A watched subagent's questions wait on its chat's row, under its name; its own turn end, or the question's
    /// answer, closes them, never the chat's (C5).
    func ingestSubagentAttention(_ update: CodexAttentionUpdate) {
        let childID = update.sessionID
        guard let child = codexThreads.child(childID), let owner = codexThreads.owner(of: childID),
              let session = state.session(id: owner) else { return }
        let now = dependencies.now()
        var closed = false
        for event in update.events {
            switch event {
            case let .questionOpened(question):
                guard let open = update.state.questions[question.callID] else { continue }
                let id = Self.questionID(childID, open.callID)
                guard attention.request(id) == nil else { continue }
                openQuestion(open, session: session, now: now, id: id, agentID: childID, agentType: child.name)
            case let .questionClosed(callID, _):
                closeRequest(Self.questionID(childID, callID), cause: .rolloutOutput)
                closed = true
            case .turnEnded:
                closeRequests(in: owner, cause: .turnEnd) { $0.agentID == childID && $0.source == .rollout }
                closed = true
            default:
                break
            }
        }
        // A subagent watched only for its question leaves the watch once it is answered.
        if closed { syncSubagentRollouts() }
    }

    // MARK: The wake-up (P513)

    /// A subagent's turn ended while its chat's own turn had: its result is to wake the chat.
    private func noteCodexSubagentFinished(_ childID: String, now: Date) {
        guard let owner = codexThreads.owner(of: childID), let chat = state.session(id: owner), chat.tool == .codex,
              chat.phase == .completed, !chat.isSessionEnded else { return }
        codexWakes[owner] = now
    }

    /// A Codex chat's own Stop note while it reads done and waits on its subagents, or on the result of one that finished
    /// (in the last `ClaudeSubagentBook.quietLimit`): the wake-up turn their results started (its
    /// `<subagent_notification>`) ended, which may have shown no prompt hook or tool to the bridge. It is a turn of its
    /// own, so the bridge's Stop that follows gives its Done (P513, as P375 for Claude); a Stop that leaves the chat
    /// still waiting when its hold passes gives none. Every Stop note of the chat's reads its running subagents' rollouts
    /// at once (P514).
    func noteCodexWake(_ note: HookContextNote, now: Date) {
        guard note.event == "Stop", note.agentID == nil, note.agentSource == HookContextNote.codexSource else { return }
        readRunningSubagents(of: note.sessionID)
        let woke = codexWakes.removeValue(forKey: note.sessionID).map { now.timeIntervalSince($0) < ClaudeSubagentBook.quietLimit } ?? false
        guard let chat = state.session(id: note.sessionID), chat.tool == .codex, chat.phase == .completed, !chat.isSessionEnded,
              woke || waitingSubagents(for: chat) > 0 else { return }
        signals.wokenTurnEnded(note.sessionID)
    }

    /// The chat's running subagents' rollouts, read now rather than at the watch's next poll (P514): a subagent's turn
    /// end reaches the engine only from its rollout, and a `wait` that returned with its result lets the chat end its
    /// turn within a second, before that poll; the chat's Done is held 1.5 s. Off the main thread, as every read.
    func readRunningSubagents(of chatID: String) {
        guard let tracker = subagentRollouts else { return }
        for child in codexThreads.running(in: chatID, now: dependencies.now()) where !child.transcriptPath.isEmpty {
            tracker.pollNow(sessionID: child.id)
        }
    }

    /// A Codex request's hook, named as its row shows it: a subagent's by its role, else the name its rollout gives
    /// (the hook says only `default` for a subagent with no role, which is never shown: the row then says "subagent",
    /// P219), and one from a subagent's own session id (a Codex that named the subagent instead of its root) on its
    /// chat's row. nil: a reviewer's or a helper's, which is never shown.
    func codexRequester(sessionID: String, agentID: String?, agentType: String?) -> (sessionID: String, agentID: String?, agentType: String?)? {
        if agentID == nil, let child = codexThreads.child(sessionID), !child.isReview, let owner = codexThreads.owner(of: sessionID) {
            return (owner, child.id, child.name)
        }
        guard !codexThreads.isHidden(sessionID) else { return nil }
        guard let agentID else { return (sessionID, nil, agentType) }
        return (sessionID, agentID, Self.subagentRole(agentType) ?? codexThreads.child(agentID)?.name)
    }

    /// A hook's `agent_type` as a name: Codex's `default` (a subagent with no role) and an empty one say nothing.
    static func subagentRole(_ type: String?) -> String? {
        guard let trimmed = type?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty, trimmed != "default" else { return nil }
        return trimmed
    }
}
