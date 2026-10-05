import Foundation
import IslandHookNotes
import OpenIslandCore

/// Evidence that closes requests, each tied to the request it is about (the needs-you design §2): never a sibling's
/// PostToolUse, never a Notification, never a parent's event for a subagent's request.
extension SessionEngine {
    // MARK: Bridge events

    /// What an event the engine just applied says about the session's requests. Called by `ingest` for every event.
    func attentionEvidence(for event: AgentEvent, sessionID: String, ingress: TrackedEventIngress, tool: AgentTool?) {
        switch event {
        case let .sessionCompleted(payload):
            let fromBridge = ingress == .bridge
            if payload.isSessionEnd == true {
                // SessionEnd: every request of the session, a subagent's too.
                closeRequests(in: sessionID, cause: .turnEnd, fromBridge: fromBridge) { _ in true }
                return
            }
            // Stop, StopFailure, an interrupt, a rollout's turn end: the root's turn is over; a background subagent's
            // request waits on (C8), and so does a Codex child's (C5). A Codex request the old helper holds closes only
            // on the bridge's own Stop (invariant 6).
            closeRequests(in: sessionID, cause: .turnEnd, fromBridge: fromBridge) { $0.isRoot }
        case let .activityUpdated(payload) where ingress == .bridge && payload.phase == .completed:
            // A tool interrupted (PostToolUseFailure with `is_interrupt`), `idle_prompt`: the main thread's turn is over.
            // The echo of any other Notification carries the bridge's own phase, which reads completed after the main
            // Stop or a relaunch: it ends nothing, least of all the notice its own note just opened (P181). A version 1
            // note names no type: its echo reads as before.
            if isNotificationEcho(sessionID, now: dependencies.now()),
               let type = hookNotes.contexts[sessionID]?.lastNotificationType, type != "idle_prompt" { break }
            closeRequests(in: sessionID, cause: .turnEnd, fromBridge: true) { $0.isRoot && $0.tool != .codex }
        case let .activityUpdated(payload) where ingress == .bridge && payload.summary.hasPrefix(SignalPipeline.promptPrefix):
            let text = String(payload.summary.dropFirst(SignalPipeline.promptPrefix.count))
            let isHuman = PromptText.human(text) != nil
            if tool == .codex {
                // An async question's reply envelope closes the questions it names at once (CX10), a call of several
                // questions once each is answered (P184); the next human prompt every async question (Skip leaves no
                // trace).
                let named = CodexAttention.replyItems(Self.replyBody(text))
                if !named.isEmpty {
                    takeReplies(named, sessionID: sessionID)
                } else if isHuman {
                    closeRequests(in: sessionID, cause: .turnEnd) { $0.source == .rollout && $0.kind == .question && $0.isRoot }
                }
            } else if isHuman {
                // A human prompt ends the main thread's waits; a `<task-notification>` turn never does, and a
                // background subagent keeps waiting while the owner chats (C8).
                closeRequests(in: sessionID, cause: .turnEnd) { $0.isRoot }
            }
        case let .actionableStateResolved(payload) where ingress == .bridge:
            // The bridge dropped its request (answered elsewhere, its hook disconnected, a newer event cleared it).
            // "Handled outside" is upstream dropping its one slot on any PostToolUse, PermissionDenied or
            // UserPromptSubmit of the session, without answering or ending the helper, while Claude's prompt stays up.
            // With version 2 notes, the request's own call has already closed it: one still open waits on, read-only
            // now that the bridge cannot answer it (CL5, C8, P182).
            let keeps = payload.summary == Self.handledOutsideSummary && (noteVersions[sessionID] ?? 0) >= 2
            for request in attention.open(in: sessionID) where keeps && request.channel == .answer(.bridge)
                && request.tool == .claudeCode && request.toolUseID != nil {
                attention.update(request.id) { $0.channel = .open }
            }
            closeRequests(in: sessionID, cause: .hookEnded, fromBridge: true) { $0.holdsBridgeSlot }
        default:
            break
        }
    }

    /// Upstream's summary when it drops its Claude slot for another event of the session
    /// (`clearStaleClaudeInteractionIfNeeded`).
    static let handledOutsideSummary = "Approval was handled outside Open Island."

    /// The answers a reply envelope carries: a question named whole, or whose every item is now answered, closes.
    private func takeReplies(_ named: [(callID: String, index: Int?)], sessionID: String) {
        for request in attention.open(in: sessionID) where request.source == .rollout {
            let mine = named.filter { $0.callID == request.callID }
            guard !mine.isEmpty else { continue }
            let answered = request.answeredItems.union(mine.compactMap(\.index))
            let count = max(1, request.questionPrompt?.questions.count ?? 1)
            if mine.contains(where: { $0.index == nil }) || answered.count >= count {
                closeRequest(request.id, cause: .rolloutOutput)
            } else {
                attention.update(request.id) { $0.answeredItems = answered }
            }
        }
    }

    static func replyBody(_ text: String) -> String {
        guard let open = text.range(of: CodexAttention.replyOpen) else { return "" }
        let rest = text[open.upperBound...]
        return String(rest.range(of: CodexAttention.replyClose).map { rest[..<$0.lowerBound] } ?? rest)
    }

    // MARK: Notes

    /// What a context note says about the session's requests (note version 2; a version 1 note only tells the
    /// helper's generation).
    func attentionEvidence(note: HookContextNote, now: Date) {
        noteVersions[note.sessionID] = note.version
        attentionTally.noteVersions[note.version, default: 0] += 1
        attentionTally.lastNoteVersion = note.version
        let sessionID = note.sessionID
        // A Codex hook: its rollout is read now, not at the next poll (P290: "codex" whichever helper sent it).
        if note.agentSource == HookContextNote.codexSource { discovery?.codexRolloutWatcher.pollNow(sessionID: sessionID) }
        guard note.version >= 2 else { return }
        let isRoot = note.agentID == nil
        // A notice with no hook behind it lasts until the main thread moves on.
        if isRoot, note.event != "Notification" {
            closeRequests(in: sessionID, cause: .noticeCleared) { $0.source == .notification && $0.isRoot }
        }
        switch note.event {
        case "PreToolUse":
            guard let toolUseID = note.toolUseID else { return }
            attention.noteToolUse(sessionID: sessionID, AttentionBook.ToolUse(agentID: note.agentID, toolName: note.toolName,
                                                                              digest: note.inputDigest, toolUseID: toolUseID, at: now))
            for request in attention.open(in: sessionID) where request.toolUseID == toolUseID {
                takeToolUseID(request)
            }
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            let closed = attention.closeForToolEvidence(sessionID: sessionID, agentID: note.agentID, toolUseID: note.toolUseID,
                                                        toolName: note.toolName, digest: note.inputDigest)
            finishClosed(closed, cause: .toolEvidence)
            noteLostRace(toolUseID: note.toolUseID, ran: note.event != "PermissionDenied")
        case "SubagentStop":
            guard let agentID = note.agentID else { return }
            closeRequests(in: sessionID, cause: .turnEnd) { $0.agentID == agentID }
        case "SessionStart":
            if ["clear", "resume", "compact"].contains(note.sessionStartSource ?? "") {
                closeRequests(in: sessionID, cause: .turnEnd) { $0.isRoot && $0.tool != .codex }
            }
        case "UserPromptSubmit":
            // Codex fires it for input steered into a running turn too: only a new turn ends the root's approvals (C8).
            if note.agentSource == HookContextNote.codexSource, isRoot, let turn = note.turnID {
                closeRequests(in: sessionID, cause: .turnEnd) { request in
                    request.tool == .codex && request.source == .broker && request.isRoot && request.turnID != nil && request.turnID != turn
                }
            }
        case "Notification":
            // Claude's notification types, and the Watch agents' words for the same prompts (P1103, P1112); any other
            // agent's Notification says nothing here (OT2).
            guard let type = Self.notificationType(note) else { return }
            notification(note, type: type, now: now)
        default:
            break
        }
    }

    /// The sources that send Claude Code's hooks, with its Notification types: Claude and its forks.
    static let claudeFormatSources: Set<String> = ["claude", "qoder", "qwen", "factory", "droid", "codebuddy", "kimi",
                                                   "copilot", "devin"]

    /// The note's notification type as Claude names it: Claude's and its forks' own; Grok Build's, which are Claude's
    /// words (`permission_prompt`, `elicitation_dialog`, `idle_prompt`; xai-org/grok-build `updates.rs`, `spawn.rs`);
    /// Gemini CLI's `ToolPermission`, sent just before its own prompt shows (gemini-cli `scheduler/confirmation.ts`), as
    /// a `permission_prompt`. nil for any other.
    static func notificationType(_ note: HookContextNote) -> String? {
        switch note.agentSource ?? "claude" {
        case let source where claudeFormatSources.contains(source): note.notificationType
        case AgentKind.grok.rawValue: note.notificationType
        case AgentKind.gemini.rawValue: note.notificationType == "ToolPermission" ? "permission_prompt" : nil
        default: nil
        }
    }

    private func notification(_ note: HookContextNote, type: String?, now: Date) {
        let sessionID = note.sessionID
        switch type {
        case "permission_prompt":
            noticePermissionPrompt(sessionID: sessionID, agentID: note.agentID, now: now)
        case "idle_prompt":
            // About a minute after Claude finished with nobody typing: the main thread waits on nothing but a prompt.
            closeRequests(in: sessionID, cause: .turnEnd) { $0.isRoot && $0.tool != .codex }
        case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
            if !attention.open(in: sessionID).contains(where: { $0.source == .notification && $0.kind == .elicitation }) {
                openNotice(sessionID: sessionID, kind: .elicitation, agentID: note.agentID, now: now)
            }
        case "elicitation_response", "elicitation_complete":
            closeRequests(in: sessionID, cause: .noticeCleared) { $0.source == .notification && $0.kind == .elicitation }
        default:
            break
        }
    }

    /// A request learned its call's id (a PreToolUse noted before or after it): upstream's request carries it too, and
    /// its transcript can be watched for the call's result.
    private func takeToolUseID(_ request: AttentionRequest) {
        guard let toolUseID = request.toolUseID else { return }
        if case var .approval(permission) = request.content, permission.toolUseID != toolUseID {
            permission.toolUseID = toolUseID
            attention.update(request.id) { $0.content = .approval(permission) }
        }
        if let updated = attention.request(request.id) { watchTranscript(for: updated) }
        syncAttentionHead(request.sessionID)
    }

    /// An island answer the agent did not follow (a PostToolUse after an island Deny): counted, never acted on (C18).
    private func noteLostRace(toolUseID: String?, ran: Bool) {
        guard let toolUseID, let denied = islandDecisions.removeValue(forKey: toolUseID) else { return }
        if denied == ran { attentionTally.lostRaces += 1 }
    }

    // MARK: Transcripts (Claude)

    /// While a Claude request with a call id is open, its transcript (a subagent's own) is watched for that call's
    /// `tool_result`: a deny or an Esc at Claude's prompt fires no hook but writes it (C9).
    func watchTranscript(for request: AttentionRequest) {
        guard request.tool == .claudeCode, transcriptWatches[request.id] == nil, let toolUseID = request.toolUseID,
              let path = request.transcriptPath else { return }
        let id = request.id
        let watch = dependencies.watchTranscript(path, toolUseID) { [weak self] in
            Task { @MainActor [weak self] in self?.closeRequest(id, cause: .transcript) }
        }
        if let watch { transcriptWatches[id] = watch }
    }

    // MARK: Codex rollouts

    /// A watched rollout's news: its questions open and close, its calls' outputs close the approvals handed back to
    /// Codex, its turn end closes the rest (C5-C7, C15). `update.sessionID` is a session's id for its own rollout, or a
    /// request's id for a subagent's rollout watched for that request.
    func ingestCodexAttention(_ update: CodexAttentionUpdate) {
        if attention.request(update.sessionID) != nil { return ingestChildAttention(update) }
        let sessionID = update.sessionID
        codexAttention[sessionID] = update.state
        noteRolloutScope(update.state, for: sessionID)
        guard let session = state.session(id: sessionID) else { return }
        if update.events.contains(.factsChanged) { keepLabels(sessionID) }
        let now = dependencies.now()
        for event in update.events {
            switch event {
            case let .questionOpened(question):
                // Opened only if still open after this read: a question asked and answered within it was never waiting.
                guard let open = update.state.questions[question.callID], attention.request(Self.questionID(sessionID, open.callID)) == nil else { continue }
                openQuestion(open, session: session, now: now)
            case let .questionClosed(callID, _):
                closeRequest(Self.questionID(sessionID, callID), cause: .rolloutOutput)
            case let .output(callID):
                closeRequests(in: sessionID, cause: .rolloutOutput) { $0.tool == .codex && $0.isRoot && $0.source == .broker && $0.callID == callID }
            case let .callSeen(call):
                // The state is the one after the whole read: a call whose output came in the same read is no longer
                // open there, so the call just seen is added back for the match.
                matchCodexCalls(requests: attention.open(in: sessionID).filter { $0.isRoot }, calls: Self.withCall(call, update.state.openCalls))
            case let .turnEnded(turnID, at):
                closeRequests(in: sessionID, cause: .turnEnd) { request in
                    request.tool == .codex && request.isRoot && request.source != .bridge
                        && Self.isOwnTurnEnd(request, turnID: turnID, at: at, events: update.events)
                }
            case let .settingsChanged(at):
                closeReviewed(in: sessionID, state: update.state, at: at, events: update.events) { $0.isRoot }
            case .turnStarted, .factsChanged:
                break
            }
        }
    }

    static func questionID(_ sessionID: String, _ callID: String) -> String { "rollout:\(sessionID):\(callID)" }

    /// A rollout's turn end is the request's own (§2.2): the same turn when both name one, else not one that came before
    /// the request's own call started, read late in the same read (a previous turn's, a reused subagent's history)
    /// (P183). A call matched in an earlier read started before any turn end read now.
    static func isOwnTurnEnd(_ request: AttentionRequest, turnID: String?, at: Date?, events: [CodexAttention.Event]) -> Bool {
        guard request.source == .broker else { return true }
        if let turnID, let own = request.turnID { return turnID == own }
        guard let at, let started = callTime(request.callID, in: events) else { return true }
        return at >= started
    }

    /// When a call seen in this read started (rollout time).
    static func callTime(_ callID: String?, in events: [CodexAttention.Event]) -> Date? {
        guard let callID else { return nil }
        for case let .callSeen(call) in events where call.callID == callID { return call.at }
        return nil
    }

    /// What hides a Codex request is what its rollout says when it asks (C6): a strict-review grant or a switch to auto
    /// review read after the request entered, from before it asked (before its call, else before the engine took it),
    /// hides it still, however stale the tracker's view was when it entered (P183).
    private func closeReviewed(in sessionID: String, state: CodexAttention, at: Date?, events: [CodexAttention.Event],
                               where scope: (AttentionRequest) -> Bool) {
        guard !AttentionPolicy.codexShows(permissionMode: nil, reviewer: state.reviewer, strictAutoReview: state.strictAutoReview)
        else { return }
        let reason = state.reviewer == "auto_review" ? "autoReview" : "strictReview"
        let closed = attention.close(in: sessionID, cause: .reviewed) { request in
            let asked = Self.callTime(request.callID, in: events) ?? request.openedAt
            return request.tool == .codex && request.source == .broker && scope(request) && (at.map { asked >= $0 } ?? true)
        }
        for _ in closed { attentionTally.count(reason, in: \.notShown) }
        finishClosed(closed, cause: .reviewed)
    }

    /// A Codex question from the rollout: shown at once (Codex already waits), read-only, always signalled (C15). A
    /// subagent's (`agentID`, P212) waits on its chat's row under its name, with an id of its own rollout's.
    func openQuestion(_ question: CodexAttention.Question, session: AgentSession, now: Date, id givenID: String? = nil,
                      agentID: String? = nil, agentType: String? = nil) {
        let id = givenID ?? Self.questionID(session.id, question.callID)
        let items = question.items.map { item in
            QuestionPromptItem(question: item.question, header: item.header ?? "",
                               options: item.options.map { QuestionOption(label: $0, description: "") }, multiSelect: false)
        }
        let prompt = QuestionPrompt(id: Self.stableUUID(id), title: question.items.first?.question ?? "", questions: items)
        // "in Codex" for a Codex app thread whose flag a hook's target took off (P660), as its Open goes there.
        let place = AttentionPolicy.codexPlace(isCodexApp: isCodexAppThread(session), hostBundleID: hookNotes.contexts[session.id]?.hostBundleID)
        let request = AttentionRequest(id: id, sessionID: session.id, agentID: agentID, agentType: agentType, kind: .question,
                                       channel: .open, source: .rollout, tool: .codex, callID: question.callID,
                                       content: .question(prompt), openedAt: now, state: .confirmed, place: place)
        attentionTally.codexQuestionsOpened += 1
        attentionTally.count("codex.rollout.\(place.rawValue)", in: \.opened)
        openRequest(request)
    }

    /// Codex approvals handed back to Codex are matched to their call lazily: the rollout writer is asynchronous, so
    /// the call's line can land after the hook (C7). A tool family's newest call with no output, the same command
    /// when there are several, and never one already matched or one that started well after the request.
    func matchCodexCalls(sessionID: String) {
        guard let state = codexAttention[sessionID] else { return }
        matchCodexCalls(requests: attention.open(in: sessionID).filter { $0.isRoot }, calls: state.openCalls)
    }

    /// The open calls with `call` among them, oldest first by their own time (a call seen in a read may be older than
    /// the calls still open after it).
    static func withCall(_ call: CodexAttention.Call, _ calls: [CodexAttention.Call]) -> [CodexAttention.Call] {
        (calls.filter { $0.callID != call.callID } + [call]).enumerated()
            .sorted { ($0.element.at ?? .distantPast, $0.offset) < ($1.element.at ?? .distantPast, $1.offset) }
            .map(\.element)
    }

    private func matchCodexCalls(requests: [AttentionRequest], calls: [CodexAttention.Call]) {
        var taken = Set(requests.compactMap(\.callID))
        for request in requests where request.tool == .codex && request.source == .broker && request.callID == nil && request.hasOwnCall {
            guard let names = AttentionPolicy.codexCallNames(forHookTool: request.toolName) else { continue }
            let latest = request.openedAt.addingTimeInterval(5)
            let candidates = calls.filter { call in
                names.contains(call.name) && !taken.contains(call.callID) && (call.at.map { $0 <= latest } ?? true)
                    && AttentionPolicy.codexCallFits(call, hookTool: request.toolName)
            }
            let command = CodexAttention.clipped(request.command?.trimmingCharacters(in: .whitespacesAndNewlines))
            // The same command; else a cell's script or an intercepted patch that holds it; else the newest. A call still
            // running comes before one whose output this read already holds: a sandboxed first run or an earlier turn's
            // call with the same command had finished before the request's own (P183).
            func pick(_ pool: [CodexAttention.Call]) -> CodexAttention.Call? {
                pool.last { command != nil && $0.command == command }
                    ?? pool.last { call in command.map { !$0.isEmpty && call.command?.contains($0) == true } ?? false }
            }
            let running = candidates.filter { $0.outputAt == nil }
            guard let call = pick(running) ?? pick(candidates) ?? running.last ?? candidates.last else { continue }
            taken.insert(call.callID)
            attention.update(request.id) { $0.callID = call.callID }
        }
    }

    /// A Codex subagent's own rollout, watched for its request: its call's output or its own turn end closes it,
    /// never the root's Stop (C5).
    private func ingestChildAttention(_ update: CodexAttentionUpdate) {
        let id = update.sessionID
        for event in update.events {
            guard let request = attention.request(id) else { return }
            switch event {
            case let .callSeen(call):
                matchCodexCalls(requests: [request], calls: Self.withCall(call, update.state.openCalls))
            case let .output(callID) where request.callID == callID:
                closeRequest(id, cause: .rolloutOutput)
            case let .turnEnded(turnID, at):
                // The watch's first read replays the child's history: an earlier turn's end is not this request's.
                if Self.isOwnTurnEnd(request, turnID: turnID, at: at, events: update.events) { closeRequest(id, cause: .turnEnd) }
            case let .settingsChanged(at):
                closeReviewed(in: request.sessionID, state: update.state, at: at, events: update.events) { $0.id == id }
            default:
                break
            }
        }
    }

    /// The subagents' rollouts watched: one per open Codex subagent request, nothing when none is open.
    func syncChildRollouts() {
        let targets = attention.all.compactMap { request -> CodexRolloutWatchTarget? in
            guard request.tool == .codex, request.agentID != nil, let path = request.rolloutPath else { return nil }
            return CodexRolloutWatchTarget(sessionID: request.id, transcriptPath: path)
        }
        if targets.isEmpty, childRollouts == nil { return }
        if childRollouts == nil {
            let tracker = CodexRolloutTracker()
            tracker.attentionHandler = { [weak self] update in
                Task { @MainActor [weak self] in self?.ingestCodexAttention(update) }
            }
            childRollouts = tracker
        }
        childRollouts?.sync(targets: targets)
    }

    // MARK: Agents gone

    /// A request whose agent's pid no longer runs is over (C11: a crashed agent sends no SessionEnd, and its helper
    /// would be held for hours). Checked on the process monitor's pass, no timer of its own.
    func closeRequestsOfGoneAgents() {
        let exists = dependencies.processExists
        for request in attention.all {
            guard let pid = request.agentPID, pid > 1, !exists(pid) else { continue }
            closeRequest(request.id, cause: .pidGone)
        }
    }
}
