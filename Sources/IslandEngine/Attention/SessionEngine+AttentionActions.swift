import Foundation
import OpenIslandCore

/// The owner's clicks on a request's card, by request id. Nothing auto-answers: a decision goes out only for a click
/// on an answerable, confirmed request, over that request's own channel, while it is still open; every other ending is
/// "no decision" (the needs-you design §4.2). After an island answer the session reads running, or waiting for a prompt
/// after No and stop, never Done (C12, P169).
extension SessionEngine {
    /// Allow, Deny, No and stop, Always allow on an approval or a plan. Sends first; the request closes only once the
    /// decision went (P129). A late click (the request closed meanwhile) sends nothing.
    @discardableResult
    public func approve(requestID: String, decision: ApprovalDecision) async -> SendOutcome {
        guard let request = attention.request(requestID), request.isConfirmed, request.isAnswerable,
              let permission = request.permissionRequest,
              decision != .denyAndStop || ApprovalChoices.canStop(request.tool),
              // A subagent's (held for the island, P350): Allow once and No only. Always allow would take Claude's
              // suggestions, which may widen the whole session's permissions; No and stop would stop the turn, not the
              // subagent. Codex's (P470): the same two, all its hook can say.
              request.isRoot || (decision != .alwaysAllow && decision != .denyAndStop),
              // A mode goes out only from its own button, and only while the card still offers it (P450, P451).
              Self.modeAllowed(decision, choices: modeChoices(for: request)),
              request.tool != .codex || (decision != .alwaysAllow && decision != .denyAndStop),
              let resolution = ApprovalChoices.resolution(for: decision, request: permission),
              sendingSessionIDs.insert(request.sessionID).inserted else { return .nothingToSend }
        defer { sendingSessionIDs.remove(request.sessionID) }
        let sessionID = request.sessionID
        switch request.channel {
        case .answer(.bridge):
            // The bridge answers by session: only the request it holds, the one the state shows.
            guard state.session(id: sessionID)?.permissionRequest?.id == permission.id else { return .nothingToSend }
            islandAnswers[sessionID] = IslandAnswer(resolution: Self.kind(of: resolution), summary: nil, at: dependencies.now())
            guard await send(.resolvePermission(sessionID: sessionID, resolution: resolution)) else {
                islandAnswers[sessionID] = nil
                return .notSent
            }
        case .answer(.broker):
            // Codex's hook output for a Codex request (P470), Claude's for a Claude one: the helper prints each through
            // upstream's encoder for its source, and a response of the other agent's kind would print nothing.
            let response: BridgeResponse
            if request.tool == .codex {
                guard let decision = Self.codexDecision(for: resolution) else { return .nothingToSend }
                response = .codexHookDirective(.permissionRequest(decision))
            } else {
                response = .claudeHookDirective(.permissionRequest(Self.decision(for: resolution, input: attentionPayloads[requestID]?.toolInput)))
            }
            guard let broker = hookRequestBroker, broker.answer(requestID, response) else {
                // A subagent's hold the broker already ended (a main thread stuck past its bound, P350): Claude builds its
                // own prompt now, so the card turns read-only. Any other: the connection is gone, the agent moved on
                // without the island.
                if request.isHeldForIsland { endSubagentHold(requestID, .brokerEnded) } else { closeRequest(requestID, cause: .hookEnded) }
                return .nothingToSend
            }
        case .open:
            return .nothingToSend
        }
        if let toolUseID = request.toolUseID { rememberIslandDecision(toolUseID, denied: !resolution.isApproved) }
        // Allow or No: the session runs on (Denied · tool for a No); No and stop: it waits for a prompt (C12).
        let summary = resolution.isApproved ? "Permission approved." : StatusWord.deniedSummary(tool: permission.toolName)
        closeRequest(requestID, cause: .islandAnswer, fromBridge: true, summary: summary)
        if case .deny(_, true) = resolution { stopAfterIslandAnswer(sessionID: sessionID) }
        return .sent
    }

    /// A decision that switches the session's mode is allowed only for a mode the request offers; every other decision
    /// carries no mode.
    nonisolated static func modeAllowed(_ decision: ApprovalDecision, choices: [ClaudePermissionMode]) -> Bool {
        guard case let .allowSwitchingMode(mode) = decision else { return true }
        return choices.contains(mode)
    }

    /// A question card's answers. As `approve`: sends first, closes once they went.
    @discardableResult
    public func answer(requestID: String, response: QuestionPromptResponse) async -> SendOutcome {
        guard let request = attention.request(requestID), request.isConfirmed, request.isAnswerable,
              let prompt = request.questionPrompt, sendingSessionIDs.insert(request.sessionID).inserted else { return .nothingToSend }
        defer { sendingSessionIDs.remove(request.sessionID) }
        let sessionID = request.sessionID
        switch request.channel {
        case .answer(.bridge):
            guard state.session(id: sessionID)?.questionPrompt?.id == prompt.id else { return .nothingToSend }
            islandAnswers[sessionID] = IslandAnswer(resolution: .answered, summary: nil, at: dependencies.now())
            guard await send(.answerQuestion(sessionID: sessionID, response: response)) else {
                islandAnswers[sessionID] = nil
                return .notSent
            }
        case .answer(.broker):
            let input = Self.mergedQuestionInput(attentionPayloads[requestID]?.toolInput, prompt: prompt, response: response)
            let reply = BridgeResponse.claudeHookDirective(.permissionRequest(.allow(updatedInput: input)))
            guard let broker = hookRequestBroker, broker.answer(requestID, reply) else {
                closeRequest(requestID, cause: .hookEnded)
                return .nothingToSend
            }
        case .open:
            return .nothingToSend
        }
        closeRequest(requestID, cause: .islandAnswer, fromBridge: true,
                     summary: response.displaySummary.isEmpty ? "Answered." : "Answered: \(response.displaySummary)")
        return .sent
    }

    /// The ✕ on a read-only card: the notice goes, the agent keeps its own prompt. Never for an answerable request,
    /// and never for a Codex request the old helper holds (the island is the only place it can be answered, C4). A
    /// subagent's held for the island has no ✕ (the model sends none for it); asked anyway, its hold ends first, so Claude
    /// builds its own prompt (P350). Claude's notice for a prompt built as a hold ended brings nothing back (P352).
    public func dismissRequest(requestID: String) {
        endSubagentHold(requestID, .opened)
        guard let request = attention.request(requestID), request.channel == .open else { return }
        closeRequest(requestID, cause: .dismissed)
    }

    /// Open on a read-only card: the jump to where the agent asks. A Codex request with no call of its own to wait for
    /// (a network approval, a call not matched) closes then: the owner has been handed to Codex (C7).
    @discardableResult
    public func openRequest(requestID: String) async -> JumpOutcome? {
        guard let request = attention.request(requestID) else { return nil }
        // The owner goes to Claude: a subagent's hold ends first, so its prompt is there when they arrive (P350).
        endSubagentHold(requestID, .opened)
        if request.tool == .codex, request.source == .broker, request.callID == nil {
            closeRequest(requestID, cause: .opened)
        }
        return await jump(sessionID: request.sessionID)
    }

    // MARK: After an island answer

    /// No and stop: Claude ends the turn, so every main-thread request goes and the session waits for a prompt,
    /// interrupted (Claude fires no Stop for an interrupt); never Done, no Done card, no Done sound.
    private func stopAfterIslandAnswer(sessionID: String) {
        closeRequests(in: sessionID, cause: .islandAnswer, fromBridge: true) { $0.isRoot }
        guard attention.head(of: sessionID) == nil, state.session(id: sessionID) != nil else { return }
        signals.dropHeld(sessionID)
        state.apply(.sessionCompleted(SessionCompleted(sessionID: sessionID, summary: "Interrupted.", timestamp: dependencies.now(),
                                                       isInterrupt: true)))
        interruptedSessionIDs.insert(sessionID)
    }

    /// The bridge's own echo of an island answer to a request it held: its "denied" completion (which reads as a Done
    /// in upstream's model, probe S4) becomes running activity, or an interrupt for No and stop (C12, P169).
    func normalizedIslandAnswer(_ event: AgentEvent, sessionID: String, ingress: TrackedEventIngress, current: AgentSession?,
                                now: Date) -> AgentEvent {
        guard ingress == .bridge, let answer = islandAnswers[sessionID] else { return event }
        guard now.timeIntervalSince(answer.at) <= IslandAnswer.echoWindow else {
            islandAnswers[sessionID] = nil
            return event
        }
        switch event {
        case let .sessionCompleted(payload) where payload.isSessionEnd != true:
            islandAnswers[sessionID] = nil
            switch answer.resolution {
            case .denyAndStop:
                return .sessionCompleted(SessionCompleted(sessionID: sessionID, summary: payload.summary, timestamp: payload.timestamp,
                                                          isInterrupt: true))
            case .deny, .allow, .answered:
                return .activityUpdated(SessionActivityUpdated(sessionID: sessionID,
                                                               summary: StatusWord.deniedSummary(tool: current?.currentToolName),
                                                               phase: .running, timestamp: payload.timestamp))
            }
        case let .activityUpdated(payload) where payload.phase == .running:
            islandAnswers[sessionID] = nil
            return event
        default:
            return event
        }
    }

    private func rememberIslandDecision(_ toolUseID: String, denied: Bool) {
        islandDecisions[toolUseID] = denied
        if islandDecisions.count > 64, let first = islandDecisions.keys.first { islandDecisions[first] = nil }
    }

    nonisolated static func kind(of resolution: PermissionResolution) -> IslandAnswer.PermissionResolutionKind {
        switch resolution {
        case .allowOnce: .allow
        case let .deny(_, interrupt): interrupt ? .denyAndStop : .deny
        }
    }

    /// Claude's decision for a resolution, as upstream's bridge builds it (`resolvePendingClaudeInteraction`): an
    /// Allow echoes the original input as `updatedInput` (with only Claude's own suggested rule for Always allow); a No
    /// carries its message and, for No and stop, `interrupt`.
    nonisolated static func decision(for resolution: PermissionResolution, input: ClaudeHookJSONValue?) -> ClaudePermissionRequestDecision {
        switch resolution {
        case let .allowOnce(updatedInput, updatedPermissions):
            .allow(updatedInput: updatedInput ?? input, updatedPermissions: updatedPermissions)
        case let .deny(message, interrupt):
            .deny(message: message ?? ApprovalChoices.denyMessage, interrupt: interrupt)
        }
    }

    /// AskUserQuestion's answer, as upstream's bridge merges it (`mergedClaudeQuestionInput`): the original input with
    /// `answers` (question text → label, multi-select labels joined with ", "), required by Claude 2.1.121 and later.
    nonisolated static func mergedQuestionInput(_ input: ClaudeHookJSONValue?, prompt: QuestionPrompt,
                                    response: QuestionPromptResponse) -> ClaudeHookJSONValue {
        var answers = response.answers
        if answers.isEmpty, let raw = response.rawAnswer, !raw.isEmpty, let first = prompt.questions.first?.question {
            answers[first] = raw
        }
        var annotations: [String: ClaudeHookJSONValue] = [:]
        for key in response.annotations.keys.sorted() {
            guard let annotation = response.annotations[key] else { continue }
            var object: [String: ClaudeHookJSONValue] = [:]
            if let preview = annotation.preview, !preview.isEmpty { object["preview"] = .string(preview) }
            if let notes = annotation.notes, !notes.isEmpty { object["notes"] = .string(notes) }
            if !object.isEmpty { annotations[key] = .object(object) }
        }
        guard case var .object(fields) = input else {
            return .object(["answers": .object(answers.mapValues { .string($0) }), "annotations": .object(annotations)])
        }
        fields["answers"] = .object(answers.mapValues { .string($0) })
        if !annotations.isEmpty { fields["annotations"] = .object(annotations) }
        return .object(fields)
    }
}
