import CryptoKit
import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore

/// The needs-you book in the engine (the needs-you design §3.4): requests come in from the broker (a helper that
/// speaks to it), the bridge (a helper not yet updated, another agent's plugin), Codex rollouts (questions) and
/// Claude's notices; each waits unconfirmed until the agent itself says the owner is away (Claude's
/// `permission_prompt`) or its 8 s window passes; evidence tied to that one request closes it; and the book alone
/// applies the oldest confirmed request to the session state, so "!" and "?" are never drawn without one (P161).
extension SessionEngine {
    // MARK: Reading

    /// What the session's glyph and card show: its oldest confirmed request (invariant 1); nil draws nothing.
    public func attentionHead(for sessionID: String) -> AttentionRequest? { attention.head(of: sessionID) }

    /// The session's confirmed requests, oldest first: its card and the ones waiting behind it.
    public func attentionQueue(for sessionID: String) -> [AttentionRequest] { attention.confirmed(in: sessionID) }

    /// Every open request, pending and dormant ones too (Diagnostics, tests).
    public var openRequests: [AttentionRequest] { attention.all }

    /// The tool input an answerable Claude request's hook carried (the whole command, the edit, the plan).
    public func attentionInput(for requestID: String) -> ClaudeHookJSONValue? { attentionPayloads[requestID]?.toolInput }

    static func requestID(fromKey key: String) -> String? { SignalPipeline.requestID(fromKey: key) }

    // MARK: The request broker

    /// Starts the request broker with the bridge (live mode only). A failure leaves the rest running: the superset
    /// helper then finds no broker and runs upstream's helper as before (C16).
    func startHookRequests() {
        guard hookRequestBroker == nil, let url = configuration.hookRequestsSocketURL else { return }
        let start = dependencies.startHookRequests ?? Self.startHookRequestBroker
        let holdSwitch = subagentHoldSwitch, codexSwitch = codexHoldSwitch, backstop = dependencies.subagentHoldBackstop
        let resumes = islandResumes
        let holds: HookRequestBroker.Holds = { line, object in
            AttentionPolicy.brokerHold(line, object, answersSubagents: holdSwitch.isOn, answersCodex: codexSwitch.isOn, backstop: backstop,
                                       islandRun: resumes.isRunning)
        }
        do {
            hookRequestBroker = try start(url, holds, { [weak self] request in
                Task { @MainActor [weak self] in self?.takeBrokeredRequest(request) }
            }, { [weak self] id in
                Task { @MainActor [weak self] in self?.brokeredRequestEnded(id) }
            })
            hookRequestsProblem = nil
        } catch {
            hookRequestsProblem = error.localizedDescription
        }
    }

    /// Stopping ends every held connection: each helper exits silent and its agent keeps its own prompt.
    func stopHookRequests() {
        hookRequestBroker?.stop()
        hookRequestBroker = nil
    }

    nonisolated static func startHookRequestBroker(at url: URL, holds: @escaping HookRequestBroker.Holds,
                                                   onRequest: @escaping @Sendable (BrokeredRequest) -> Void,
                                                   onEnded: @escaping @Sendable (String) -> Void) throws -> any HookRequestReceiving {
        let broker = HookRequestBroker(url: url, holds: holds, onRequest: onRequest, onEnded: onEnded)
        try broker.start()
        return broker
    }

    // MARK: Opening

    /// A request the bridge holds (upstream's helper, not yet updated, or another agent's plugin): the book's, never
    /// the state's (invariant 3). The bridge keeps one per session, so a newer one supersedes the older, which it can no
    /// longer answer. Claude's waits for its confirmation like a brokered one; every other agent's (Codex behind the
    /// old helper, which waits on the island and shows nothing; OpenCode; the forks; Cursor) is shown at once, as today.
    func takeBridgeRequest(_ event: AgentEvent, now: Date) {
        guard let sessionID = Self.sessionID(of: event), let session = state.session(id: sessionID) else { return }
        let content: AttentionRequest.Content
        let kind: AttentionRequest.Kind
        let uuid: UUID
        let askedAt: Date
        switch event {
        case let .permissionRequested(payload):
            content = .approval(payload.request)
            kind = Self.isPlanTool(payload.request.toolName ?? payload.request.title) ? .plan : .approval
            uuid = payload.request.id
            askedAt = payload.timestamp
        case let .questionAsked(payload):
            content = .question(payload.prompt)
            kind = .question
            uuid = payload.prompt.id
            askedAt = payload.timestamp
        default:
            return
        }
        let id = "bridge:\(sessionID):\(uuid.uuidString)"
        // The same request again (a replay) is the one already open.
        guard attention.request(id) == nil else { return }
        finishClosed(attention.close(in: sessionID, cause: .superseded) { $0.holdsBridgeSlot }, cause: .superseded)
        let isClaude = session.tool == .claudeCode
        let context = hookNotes.contexts[sessionID]
        // OpenCode 2's questions show read-only: no answer given here could reach OpenCode (P481). So does every request
        // of an agent the table marks Watch (Amp's waiting thread, P1159): its own prompt decides, never an island answer.
        let watched = AgentHookTable.spec(agent(of: session))?.answers == .watch
        let answers = !watched && (session.tool != .openCode || OpenCodeAPI.islandAnswers(sessionID: sessionID, isQuestion: kind.isQuestion))
        // A Claude request follows the Claude rules, the transcript's result for its call included (§2.5): the bridge
        // never holds a subagent's, so the session's transcript is the one (P182).
        var request = AttentionRequest(
            id: id, sessionID: sessionID, kind: kind, channel: answers ? .answer(.bridge) : .open,
            source: .bridge, tool: session.tool, toolName: content.toolName, toolUseID: content.toolUseID,
            transcriptPath: isClaude ? session.claudeMetadata?.transcriptPath : nil, content: content,
            openedAt: min(askedAt, now), state: dependencies.confirmsRequestsAtOnce || !isClaude ? .confirmed : .pending,
            agentPID: context?.agentPID, entrypoint: context?.entrypoint, place: place(for: session, entrypoint: context?.entrypoint),
            windowReleases: isClaude && isArmed(sessionID))
        if isClaude { request.permissionMode = context?.permissionMode }
        attentionTally.count("\(Self.agentName(session.tool)).bridge.\(request.place.rawValue)", in: \.opened)
        openRequest(request)
    }

    /// A request the broker took (its hold is already replied, from the request alone). Here it is read, shown or
    /// not, and entered.
    func takeBrokeredRequest(_ incoming: BrokeredRequest) {
        // The broker stamps on its own thread; a request never opens after the engine's now, so its window runs 8 s
        // from what the engine's clock says, as a bridge request's does.
        var brokered = incoming
        brokered.at = min(incoming.at, dependencies.now())
        if brokered.held { attentionTally.held += 1 } else { attentionTally.released += 1 }
        switch brokered.line.source {
        case "claude": takeClaudeRequest(brokered)
        case "codex": takeCodexRequest(brokered)
        default: releaseBrokered(brokered.id)
        }
    }

    private func takeClaudeRequest(_ brokered: BrokeredRequest) {
        guard let payload = Self.decodeClaude(brokered.line.input) else {
            attentionTally.unreadable += 1
            return releaseBrokered(brokered.id)
        }
        guard ignoredSessionIDs[payload.sessionID] == nil else { return releaseBrokered(brokered.id) }
        let mode = brokered.object["permission_mode"] as? String
        // The island's own resume of the session (P1328): its card is the only place to answer.
        let islandRun = islandResumes.isRunning(payload.sessionID)
        let surface = AttentionPolicy.claudeSurface(entrypoint: brokered.line.entrypoint, hasTerminal: brokered.line.hasTerminal,
                                                    islandRun: islandRun)
        let decision = AttentionPolicy.claude(entrypoint: brokered.line.entrypoint, hasTerminal: brokered.line.hasTerminal,
                                              agentID: payload.agentID, permissionMode: mode, islandRun: islandRun)
        attentionTally.count("claude.broker.\(surface)", in: \.opened)
        guard decision.show else {
            attentionTally.count(mode == "dontAsk" ? "dontAsk" : "headless", in: \.notShown)
            return releaseBrokered(brokered.id)
        }
        ensureSession(claude: payload, at: brokered.at)
        guard state.session(id: payload.sessionID) != nil else { return releaseBrokered(brokered.id) }

        let kind: AttentionRequest.Kind
        let content: AttentionRequest.Content
        if payload.toolName == "AskUserQuestion", let prompt = payload.questionPrompt {
            kind = .question
            content = .question(prompt)
        } else {
            kind = Self.isPlanTool(payload.toolName) ? .plan : .approval
            content = .approval(PermissionRequest(
                title: payload.permissionRequestTitle, summary: payload.permissionRequestSummary,
                affectedPath: payload.permissionAffectedPath, primaryActionTitle: "Allow Once", secondaryActionTitle: "Deny",
                toolName: payload.toolName, toolUseID: payload.toolUseID, suggestedUpdates: payload.permissionSuggestions ?? []))
        }
        // A subagent's approval the broker held for the island (P350): only while Answer subagents on the island is
        // still on (it may have gone off since the broker replied). It is confirmed and sounds at once: Claude sends no
        // notice while its hook holds.
        var held = brokered.held
        let forIsland = held && brokered.bound != nil
        if forIsland, !(answersSubagents && payload.agentID?.isEmpty == false && kind == .approval) {
            releaseBrokered(brokered.id)
            held = false
        }
        let holdsForIsland = forIsland && held
        // A print-mode run shows no prompt and sends no `permission_prompt`: nothing would confirm its request, and an
        // armed profile's window would release it unanswered, which Claude takes as a No. It is confirmed at once (P1328).
        let confirmsAtOnce = holdsForIsland || (islandRun && held) || dependencies.confirmsRequestsAtOnce
        var request = AttentionRequest(
            id: brokered.id, sessionID: payload.sessionID, agentID: payload.agentID, agentType: payload.agentType, kind: kind,
            channel: held ? .answer(.broker) : .open, source: .broker, tool: .claudeCode, toolName: payload.toolName,
            toolUseID: payload.toolUseID, inputDigest: brokered.line.digest,
            transcriptPath: Self.claudeTranscriptPath(payload), content: content, openedAt: brokered.at,
            state: confirmsAtOnce ? .confirmed : .pending, agentPID: brokered.line.agentPID,
            entrypoint: surface, place: decision.place, windowReleases: isArmed(payload.sessionID) && !islandRun)
        if holdsForIsland { request.holdEndsAt = brokered.at.addingTimeInterval(SubagentHold.limit) }
        request.permissionMode = mode
        attentionPayloads[request.id] = payload
        openRequest(request)
        if holdsForIsland, let opened = attention.request(request.id) { scheduleSubagentHold(opened) }
    }

    private func takeCodexRequest(_ brokered: BrokeredRequest) {
        // Held only for Answer Codex in Juice (P470): the reviewer and where the owner looks are read first, within
        // `showGrace`; every other Codex request is handed back at once (decision 15).
        if brokered.held { awaitCodexHold(brokered.id) } else { releaseBrokered(brokered.id) }
        guard var payload = Self.decodeCodex(brokered.line.input) else {
            attentionTally.unreadable += 1
            return skipCodexHold(brokered.id, .notEntered)
        }
        guard ignoredSessionIDs[payload.sessionID] == nil else { return skipCodexHold(brokered.id, .notEntered) }
        // An SSH host's Codex (P753): its own prompt is in the ssh tab, and with no rollout on this Mac nothing here
        // would ever see the call settled (C7), so a card would sound and stay for the turn. Handed back, no card.
        guard remoteSessions.entry(for: payload.sessionID) == nil else {
            attentionTally.count("remote", in: \.notShown)
            return skipCodexHold(brokered.id, .notEntered)
        }
        // A subagent's request waits on its chat's row, under its name; a reviewer's or a helper's is never shown (P212).
        guard let requester = codexRequester(sessionID: payload.sessionID,
                                             agentID: (brokered.object["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                             agentType: brokered.object["agent_type"] as? String) else {
            attentionTally.count("internalThread", in: \.notShown)
            return skipCodexHold(brokered.id, .notEntered)
        }
        payload.sessionID = requester.sessionID
        let agentID = requester.agentID
        let agentType = requester.agentType
        let mode = brokered.object["permission_mode"] as? String
        // A Codex app thread is the app's whatever its hooks' target says (P660): the app's app-server names no host.
        let isApp = state.session(id: payload.sessionID).map(isCodexAppThread) ?? false
        let place = AttentionPolicy.codexPlace(isCodexApp: isApp, hostBundleID: brokered.line.hostBundleID)
        attentionTally.count("codex.broker.\(place.rawValue)", in: \.opened)
        guard mode != "bypassPermissions" else {
            attentionTally.count("bypass", in: \.notShown)
            return skipCodexHold(brokered.id, .notEntered)
        }
        discovery?.codexRolloutWatcher.pollNow(sessionID: payload.sessionID)
        // The reviewer and the turn's strict review: the tracker's view of that thread's rollout, else one bounded
        // read of its tail, off the main thread (C6). A subagent's is its own rollout (C5).
        // A held one (P470) is always read fresh: the tracker may not have read this turn's `turn_context` yet, and an
        // island Allow must never settle what a reviewer switched on since would decide.
        let path = payload.transcriptPath
        let known = agentID == nil ? codexAttention[payload.sessionID] : nil
        if !brokered.held, let known {
            enterCodexRequest(brokered, payload: payload, agentID: agentID, agentType: agentType, place: place, settings: known)
            return
        }
        let read = dependencies.readCodexSettings
        Task { [weak self] in
            let settings = await Task.detached(priority: .userInitiated) { path.flatMap(read) }.value
            self?.enterCodexRequest(brokered, payload: payload, agentID: agentID, agentType: agentType, place: place,
                                    settings: settings ?? known, known: known)
        }
    }

    private func enterCodexRequest(_ brokered: BrokeredRequest, payload: CodexHookPayload, agentID: String?, agentType: String?,
                                   place: AttentionRequest.Place, settings: CodexAttention?, known: CodexAttention? = nil) {
        // The reviewer the tail names, else the tracker's (a turn whose `turn_context` is older than the tail's 256 KB was
        // read long since); strict review from either.
        let reviewer = settings?.reviewer ?? known?.reviewer
        let strict = settings?.strictAutoReview == true || known?.strictAutoReview == true
        guard AttentionPolicy.codexShows(permissionMode: nil, reviewer: reviewer, strictAutoReview: strict) else {
            attentionTally.count(reviewer == "auto_review" ? "autoReview" : "strictReview", in: \.notShown)
            return skipCodexHold(brokered.id, .reviewer)
        }
        ensureSession(codex: payload, at: brokered.at, subagent: agentID != nil)
        guard state.session(id: payload.sessionID) != nil else { return skipCodexHold(brokered.id, .notEntered) }
        let description = payload.toolInput?.description
        var request = AttentionRequest(
            id: brokered.id, sessionID: payload.sessionID, agentID: agentID, agentType: agentType, kind: .approval, channel: .open,
            source: .broker, tool: .codex, toolName: payload.toolName, inputDigest: brokered.line.digest, turnID: payload.turnID,
            rolloutPath: payload.transcriptPath, command: payload.commandText,
            content: .approval(PermissionRequest(title: payload.permissionRequestTitle, summary: payload.permissionRequestSummary,
                                                 affectedPath: payload.permissionRequestAffectedPath, toolName: payload.toolName)),
            openedAt: brokered.at, state: dependencies.confirmsRequestsAtOnce ? .confirmed : .pending,
            agentPID: brokered.line.agentPID, place: place)
        request.hasOwnCall = !AttentionPolicy.codexIsUnmatched(toolName: payload.toolName, description: description)
        if !request.hasOwnCall { attentionTally.codexUnmatched += 1 }
        let sessionID = payload.sessionID
        let afterEntry: @MainActor () -> Void = { [weak self] in
            if agentID != nil { self?.syncChildRollouts() } else { self?.matchCodexCalls(sessionID: sessionID) }
        }
        guard brokered.held else {
            openRequest(request)
            return afterEntry()
        }
        enterHeldCodexRequest(request, reviewer: reviewer, strictAutoReview: strict, afterEntry: afterEntry)
    }

    /// Enters a request, schedules its window (or confirms it at once), and applies the session's head.
    func openRequest(_ incoming: AttentionRequest) {
        guard attention.insert(incoming), let request = attention.request(incoming.id) else { return }
        if request.state == .confirmed {
            noteConfirmed(request, revived: false)
        } else {
            scheduleAttentionWindow(request)
        }
        watchTranscript(for: request)
        syncAttentionHead(request.sessionID)
    }

    /// A notice with no hook behind it (a sandbox network prompt, an MCP form): confirmed by definition, read-only. It
    /// takes its note's agent pid, so it closes when that agent is gone (C11).
    func openNotice(sessionID: String, kind: AttentionRequest.Kind, agentID: String?, now: Date) {
        guard let session = state.session(id: sessionID) else { return }
        let context = hookNotes.contexts[sessionID]
        let request = AttentionRequest(
            id: "note:\(sessionID):\(UUID().uuidString)", sessionID: sessionID, agentID: agentID, kind: kind, channel: .open,
            source: .notification, tool: session.tool, content: .notice, openedAt: now, state: .confirmed,
            agentPID: context?.agentPID, place: place(for: session, entrypoint: context?.entrypoint))
        attentionTally.count("\(Self.agentName(session.tool)).notification.\(request.place.rawValue)", in: \.opened)
        openRequest(request)
    }

    // MARK: Confirming

    func scheduleAttentionWindow(_ request: AttentionRequest) {
        guard attentionWindows.insert(request.id).inserted else { return }
        let due = request.openedAt.addingTimeInterval(AttentionBook.window)
        let id = request.id
        dependencies.scheduleAttentionCheck(max(0, due.timeIntervalSince(dependencies.now()))) { [weak self] in
            self?.attentionWindowElapsed(id)
        }
    }

    /// The request's one check, 8 s after its own `openedAt` (C2): still pending, it is confirmed where the agent sends
    /// no notice of its own, or released (dormant, its hook ended with no decision) where it would have.
    func attentionWindowElapsed(_ id: String) {
        attentionWindows.remove(id)
        switch attention.windowElapsed(id, at: dependencies.now()) {
        case let .confirmed(request):
            noteConfirmed(request, revived: false)
        case let .released(request):
            attentionTally.count(request.entrypoint ?? "missing", in: \.releasedByWindow)
            if request.channel == .answer(.broker) {
                hookRequestBroker?.release(request.id)
                attention.update(id) { $0.channel = .open }
            }
            syncAttentionHead(request.sessionID)
        case .none:
            break
        }
    }

    /// Claude's `permission_prompt` for the session (C2, C3): the oldest unconfirmed request, else the newest dormant
    /// one with its own kind, else a prompt with no hook behind it. A prompt Claude built as a subagent's hold ended is
    /// matched first, by when its notice is due (P352).
    func noticePermissionPrompt(sessionID: String, agentID: String?, now: Date) {
        if takeReleasedHoldNotice(sessionID: sessionID, agentID: agentID, now: now) { return }
        switch attention.notice(sessionID: sessionID, at: now) {
        case let .confirmed(request):
            noteConfirmed(request, revived: false)
        case let .revived(request):
            attentionTally.revivals += 1
            noteConfirmed(request, revived: true)
        case .none:
            attentionTally.noticesWithoutRequest += 1
            // A request already shown is what the notice is about; only a session with none gets a notice of its own.
            guard attention.confirmed(in: sessionID).isEmpty else { return }
            openNotice(sessionID: sessionID, kind: .approval, agentID: agentID, now: now)
        }
    }

    /// A request just confirmed: it counts, surfaces its session, drops a held Done, is applied if it is the head,
    /// and sounds once (never again for a revival).
    func noteConfirmed(_ request: AttentionRequest, revived: Bool) {
        attentionTally.count(request.entrypoint ?? request.place.rawValue, in: \.confirmed)
        promptedSessionIDs.insert(request.sessionID)
        interruptedSessionIDs.remove(request.sessionID)
        signals.dropHeld(request.sessionID)
        syncAttentionHead(request.sessionID)
        guard !request.sounded else { return }
        attention.update(request.id) { $0.sounded = true }
        // Nothing sounds before the first live event, nor for what a rollout shows while the launch's sessions are
        // being resolved (P6); a request id sounds once, a replay of it never again.
        if request.source == .rollout, monitoring?.isResolvingInitialLiveSessions == true { return }
        guard let alert = signals.needsYou(sessionID: request.sessionID, requestID: request.id) else { return }
        deliver(alert)
    }

    // MARK: Closing

    /// `summary`: what the session reads once nothing waits (an island answer's outcome).
    func closeRequest(_ id: String, cause: AttentionCloseCause, fromBridge: Bool = false, summary: String? = nil) {
        finishClosed([attention.close(id, cause: cause, fromBridge: fromBridge)].compactMap { $0 }, cause: cause, summary: summary)
    }

    func closeRequests(in sessionID: String, cause: AttentionCloseCause, fromBridge: Bool = false,
                       where matches: (AttentionRequest) -> Bool) {
        finishClosed(attention.close(in: sessionID, cause: cause, fromBridge: fromBridge, where: matches), cause: cause)
    }

    /// What closing does besides the book (invariant 4): a held hook is released with no decision, its watches end,
    /// it is counted, and each session's head is applied again.
    func finishClosed(_ closed: [AttentionRequest], cause: AttentionCloseCause, summary: String? = nil) {
        guard !closed.isEmpty else { return }
        let now = dependencies.now()
        var children = false
        for request in closed {
            if request.source == .broker { hookRequestBroker?.release(request.id) }
            subagentHoldsSeen.remove(request.id)
            noteReleasedHoldClosed(request, cause: cause)
            attentionPayloads[request.id] = nil
            transcriptWatches.removeValue(forKey: request.id)?.stop()
            // The call it stood for is over when its transcript wrote its result or the island said No (P440).
            if let call = request.toolUseID, cause == .transcript || (cause == .islandAnswer && islandDecisions[call] == true) {
                toolFlights.end(request.sessionID, call: call)
            }
            attentionTally.count(cause.rawValue, in: \.closes)
            if request.state == .pending { attentionTally.neverConfirmed += 1 }
            if request.tool == .codex, request.source == .broker, now.timeIntervalSince(request.openedAt) < AttentionBook.window {
                attentionTally.codexClosedEarly += 1
            }
            if request.source == .rollout { attentionTally.count(cause.rawValue, in: \.codexQuestionsClosed) }
            if request.tool == .codex, request.agentID != nil { children = true }
        }
        if children { syncChildRollouts() }
        for sessionID in Set(closed.map(\.sessionID)) { syncAttentionHead(sessionID, summary: summary) }
    }

    /// Everything the book keeps for a session that is gone (tombstone expired, left the state, archived).
    func forgetAttention(_ sessionID: String) {
        finishClosed(attention.forget(sessionID), cause: .sessionGone)
        releasedHoldPrompts = releasedHoldPrompts.filter { $0.value.sessionID != sessionID }
        noteVersions[sessionID] = nil
        restingPhases[sessionID] = nil
        codexAttention[sessionID] = nil
        if codexWork[sessionID] != nil { codexWork[sessionID] = nil }
        islandAnswers[sessionID] = nil
    }

    func releaseBrokered(_ id: String) {
        hookRequestBroker?.release(id)
    }

    /// The helper of a held request ended (Claude or a timeout killed it, the agent moved on).
    func brokeredRequestEnded(_ id: String) {
        if noteCodexHoldEnded(id) { return }
        closeRequest(id, cause: .hookEnded)
    }

    // MARK: The session state

    /// Applies the session's head to the state as upstream's event, so `approve`, the plan reader and the tool-call
    /// read keep working; with no head, a waiting phase goes back to where upstream's own events left the session:
    /// running, or finished when the main thread had stopped (a background subagent's request, P182) (invariant 3).
    /// Called after every change of the book and after every event, so upstream's own clears (a Stop's) never hide a
    /// request still open (C14).
    func syncAttentionHead(_ sessionID: String, summary: String? = nil) {
        guard let session = state.session(id: sessionID) else { return }
        guard let head = attention.head(of: sessionID) else {
            if session.phase.requiresAttention {
                state.apply(.actionableStateResolved(ActionableStateResolved(sessionID: sessionID, summary: summary ?? session.summary,
                                                                               timestamp: dependencies.now())))
                if restingPhases[sessionID] == .completed, var resolved = state.session(id: sessionID) {
                    resolved.phase = .completed
                    replace(resolved)
                }
            }
            forgetToolCallIfResolved(sessionID)
            return
        }
        // The request's own time, as upstream applies it: the row reads as waiting since the agent asked.
        let now = head.openedAt
        switch head.content {
        case let .approval(request):
            guard session.phase != .waitingForApproval || session.permissionRequest != request else { return }
            state.apply(.permissionRequested(PermissionRequested(sessionID: sessionID, request: request, timestamp: now)))
            if let input = attentionPayloads[head.id]?.toolInput {
                toolCalls[sessionID] = ToolCallRecord(requestID: request.id, input: input)
            } else if head.tool != .codex {
                readToolCall(sessionID: sessionID, request: request)
            }
        case let .question(prompt):
            guard session.phase != .waitingForAnswer || session.questionPrompt != prompt else { return }
            state.apply(.questionAsked(QuestionAsked(sessionID: sessionID, prompt: prompt, timestamp: now)))
        case .notice:
            let uuid = Self.stableUUID(head.id)
            if head.kind.isQuestion {
                guard session.phase != .waitingForAnswer || session.questionPrompt?.id != uuid else { return }
                state.apply(.questionAsked(QuestionAsked(sessionID: sessionID, prompt: QuestionPrompt(id: uuid, title: "", options: []),
                                                         timestamp: now)))
            } else {
                guard session.phase != .waitingForApproval || session.permissionRequest?.id != uuid else { return }
                state.apply(.permissionRequested(PermissionRequested(sessionID: sessionID, request: PermissionRequest(
                    id: uuid, title: "", summary: "", affectedPath: ""), timestamp: now)))
            }
        }
    }

    // MARK: Helpers

    /// Where Open goes for a session's request.
    func place(for session: AgentSession, entrypoint: String?) -> AttentionRequest.Place {
        switch session.tool {
        case .codex:
            return AttentionPolicy.codexPlace(isCodexApp: isCodexAppThread(session), hostBundleID: hookNotes.contexts[session.id]?.hostBundleID)
        default:
            if let entrypoint { return AttentionPolicy.claudePlace(entrypoint) }
            return session.jumpTarget?.terminalApp == "Claude.app" ? .claudeApp : .terminal
        }
    }

    /// The window releases a request (instead of confirming it) only where Claude's own notice would have come: our
    /// helper speaks note version 2 for the session (it forwards `notification_type`), and the session's profile runs
    /// it on `permission_prompt` (C19). A session in no known profile takes the default profile's reading.
    func isArmed(_ sessionID: String) -> Bool {
        guard (noteVersions[sessionID] ?? 0) >= 2 else { return false }
        if let tag = accountTags[sessionID], let armed = armedProfiles[tag.targetID] { return armed }
        if let armed = profileTargets.first(where: { $0.provider == .claude && $0.isDefaultFolder }).flatMap({ armedProfiles[$0.id] }) {
            return armed
        }
        // No profile read (a headless engine, tests): every Claude profile on this Mac registers `*` for our helper.
        return armedProfiles.isEmpty
    }

    /// Reads each Claude profile's hook config for the notification our window relies on (C19); config only.
    func refreshAttentionArming() {
        let arming = dependencies.notificationArming
        armedProfiles = Dictionary(uniqueKeysWithValues: profileTargets.filter { $0.provider == .claude }.map { ($0.id, arming($0)) })
    }

    /// A Claude session the engine does not know yet starts as the bridge would start it (`ensureClaudeSessionExists`).
    private func ensureSession(claude payload: ClaudeHookPayload, at date: Date) {
        guard state.session(id: payload.sessionID) == nil else { return }
        ingest(.sessionStarted(SessionStarted(
            sessionID: payload.sessionID, title: payload.sessionTitle, tool: payload.resolvedAgentTool, origin: .live,
            initialPhase: .completed, summary: payload.implicitStartSummary, timestamp: date, jumpTarget: payload.defaultJumpTarget,
            claudeMetadata: payload.defaultClaudeMetadata.isEmpty ? nil : payload.defaultClaudeMetadata)), ingress: .bridge)
    }

    /// A subagent's hook names its own rollout, which is never filed under its chat (P167, P212).
    private func ensureSession(codex payload: CodexHookPayload, at date: Date, subagent: Bool = false) {
        guard state.session(id: payload.sessionID) == nil else { return }
        let metadata = subagent || payload.defaultCodexMetadata.isEmpty ? nil : payload.defaultCodexMetadata
        ingest(.sessionStarted(SessionStarted(
            sessionID: payload.sessionID, title: payload.sessionTitle, tool: .codex, origin: .live, summary: payload.implicitStartSummary,
            timestamp: date, jumpTarget: payload.defaultJumpTarget, codexMetadata: metadata)), ingress: .bridge)
    }

    /// Upstream's payload, forgiving a field its enums do not know yet (a new permission mode, a new start source): the
    /// request is still shown rather than lost. Nonisolated: the SSH relay decodes a remote hook on its own queue (P742).
    nonisolated static func decodeClaude(_ input: Data) -> ClaudeHookPayload? {
        if let payload = try? JSONDecoder().decode(ClaudeHookPayload.self, from: input) { return payload }
        guard var object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
        object["permission_mode"] = nil
        object["source"] = nil
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(ClaudeHookPayload.self, from: data)
    }

    nonisolated static func decodeCodex(_ input: Data) -> CodexHookPayload? {
        if let payload = try? JSONDecoder().decode(CodexHookPayload.self, from: input) { return payload }
        guard var object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
        object["permission_mode"] = "default"
        if object["model"] == nil { object["model"] = "" }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(CodexHookPayload.self, from: data)
    }

    /// A subagent's own transcript (the hooks docs' `agent_transcript_path` shape), else the session's.
    static func claudeTranscriptPath(_ payload: ClaudeHookPayload) -> String? {
        if let agentPath = payload.agentTranscriptPath, !agentPath.isEmpty { return agentPath }
        guard let path = payload.transcriptPath, !path.isEmpty else { return nil }
        guard let agentID = payload.agentID, !agentID.isEmpty else { return path }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent(payload.sessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("agent-\(agentID).jsonl").path
    }

    static func isPlanTool(_ name: String?) -> Bool { name == "ExitPlanMode" }

    static func agentName(_ tool: AgentTool) -> String {
        switch tool {
        case .claudeCode: "claude"
        case .codex: "codex"
        default: "other"
        }
    }

    /// A UUID made from a string, the same each time (a notice's synthetic request, a rollout question).
    static func stableUUID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
                           bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

extension AttentionRequest.Content {
    var toolName: String? {
        if case let .approval(request) = self { request.toolName } else { nil }
    }

    var toolUseID: String? {
        if case let .approval(request) = self { request.toolUseID } else { nil }
    }
}
