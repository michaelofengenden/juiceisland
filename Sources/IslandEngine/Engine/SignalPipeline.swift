import Foundation
import OpenIslandCore

public enum EngineSignal: Equatable, Sendable {
    case needsYou(sessionID: String)
    case done(sessionID: String)

    public var sessionID: String {
        switch self {
        case let .needsYou(sessionID), let .done(sessionID): sessionID
        }
    }
}

/// Which events raise which signal, and when (P2, P4, P5 and P6). Pure and synchronous:
/// SessionEngine hands it every event it applied, with the session before and after and the time, and delivers what
/// comes back. A Done is held for 1.5 s and comes out of `due(now:session:)`, so tests drive the clock.
///
/// The table, as the engine sees upstream's events:
/// - an approval or a question: needs you once per request, when the engine's request book confirms it (the agent's
///   own notice, or its window), never on the request itself (C1, P162); the book, not this table, sends it;
/// - a Stop that is not an interrupt or a session end: done, after the hold. A StopFailure arrives as the same
///   completion, and its summary (the hook's optional `error`, or else the message text) cannot tell it from a Stop;
///   the context note names it by its raw hook event, and then `turnFailed` drops the held Done and needs you;
/// - everything else (a PermissionDenied, which the engine applies as activity; tool failures, subagent and
///   compaction activity, notifications, interrupts, session ends, subagent sessions): nothing.
struct SignalPipeline: Sendable {
    static let doneHold: TimeInterval = 1.5
    /// What the bridge puts before the text of a UserPromptSubmit, for Claude and Codex alike
    /// (BridgeServer.swift:516-530 and 666-681 at 1.2.1). SessionEngineBridgeTests pins it against the real bridge.
    static let promptPrefix = "Prompt: "
    /// What a `sessionCompleted` from the bridge stands for. Stop, StopFailure and PermissionDenied all arrive as that
    /// one event (BridgeServer.swift:845-860, 888-908 and 910-930 at 1.2.1). PermissionDenied's hook input has
    /// `reason`, not `error`, so its summary is always the bridge's fixed text, which tells it apart. Every other
    /// completion is a Stop, whatever its text: a StopFailure's summary is the hook's optional `error` or else the
    /// message text, which cannot tell it from a Stop.
    enum Completion: Equatable, Sendable {
        case stop, permissionDenied, interrupt, sessionEnd
    }

    /// One alert the pipeline lets out, and the key it goes out under. SessionEngine checks the key once more after
    /// its frontmost check, against the session as it is then (P5).
    struct Alert: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case needsYou, done
            /// A StopFailure: needs you, sounded as Needs you.
            case turnFailed
        }

        var kind: Kind
        var sessionID: String
        var key: String

        var signal: EngineSignal { kind == .done ? .done(sessionID: sessionID) : .needsYou(sessionID: sessionID) }
    }

    enum Rule: Equatable, Sendable {
        case needsYou(key: String)
        case done(key: String)
        case none
    }

    struct Held: Equatable, Sendable {
        var key: String
        var dueAt: Date
    }

    private(set) var turns: [String: Int] = [:]
    /// Sessions whose main agent ended a turn the pipeline never saw start (`wokenTurnEnded`): their next Stop holds a
    /// Done though the session read done before it (P375).
    private(set) var woken: Set<String> = []
    private(set) var held: [String: Held] = [:]
    private(set) var emittedKeys: Set<String> = []
    private(set) var hasSeenLiveEvent = false
    /// Sessions the bridge has spoken for. Their Done comes from the Stop hook, never from a rollout.
    private(set) var hookedSessions: Set<String> = []

    static func completion(_ payload: SessionCompleted, tool: AgentTool?, ingress: TrackedEventIngress) -> Completion {
        if payload.isSessionEnd == true { return .sessionEnd }
        if payload.isInterrupt == true { return .interrupt }
        // Codex has neither hook, and a rollout's summary is the agent's own text.
        guard ingress == .bridge, let tool, tool != .codex else { return .stop }
        if payload.summary == "\(tool.displayName) permission was denied." { return .permissionDenied }
        return .stop
    }

    /// A PermissionDenied is not a finished turn: Claude's permission check refused one tool and Claude goes on (P2).
    /// The engine applies it as running activity, "Denied · <tool>" (the tool the bridge just recorded from the
    /// hook's `tool_name`), so it holds no Done and drops a held one. Every other event passes unchanged.
    static func normalized(_ event: AgentEvent, ingress: TrackedEventIngress, current: AgentSession?) -> AgentEvent {
        guard case let .sessionCompleted(payload) = event,
              completion(payload, tool: current?.tool, ingress: ingress) == .permissionDenied else { return event }
        return .activityUpdated(SessionActivityUpdated(sessionID: payload.sessionID,
                                                       summary: StatusWord.deniedSummary(tool: current?.currentToolName),
                                                       phase: .running, timestamp: payload.timestamp))
    }

    /// A new turn: the bridge's UserPromptSubmit activity, whatever its text, or a rollout that runs again after it
    /// finished (its next `task_started` or user message, CodexSessionTracking.swift `events(from:to:)`), so a prompt
    /// with the same text as the last one still counts. The engine asks only about events its lifecycle let through,
    /// so a rollout's stale read after the bridge's Stop never counts.
    static func isNewPrompt(_ event: AgentEvent, ingress: TrackedEventIngress, before: AgentSession?) -> Bool {
        guard case let .activityUpdated(payload) = event else { return false }
        if ingress == .bridge { return payload.summary.hasPrefix(promptPrefix) }
        return payload.phase == .running && before?.phase == .completed
    }

    static func approvalKey(_ sessionID: String, _ request: PermissionRequest) -> String {
        "\(sessionID)|approval|\(request.toolUseID ?? request.id.uuidString)"
    }

    static func questionKey(_ sessionID: String, _ prompt: QuestionPrompt) -> String {
        "\(sessionID)|question|\(prompt.id.uuidString)"
    }

    static func doneKey(_ sessionID: String, turn: Int) -> String { "\(sessionID)|done|\(turn)" }

    static func failedKey(_ sessionID: String, turn: Int) -> String { "\(sessionID)|failed|\(turn)" }

    /// The event-to-signal table (P4), with the key each alert is sent under at most once (P5). An approval or a
    /// question gives nothing here: the request book sounds it once confirmed (C1).
    static func rule(for event: AgentEvent, ingress: TrackedEventIngress, after: AgentSession?, turn: Int) -> Rule {
        guard let after, !after.isSubagentSession else { return .none }
        switch event {
        case let .sessionCompleted(payload):
            switch completion(payload, tool: after.tool, ingress: ingress) {
            case .stop: return .done(key: doneKey(payload.sessionID, turn: turn))
            case .permissionDenied, .interrupt, .sessionEnd: return .none
            }
        default:
            return .none
        }
    }

    /// The key the session shows now for an alert of this kind, or nil when it shows none (P5): a resolved or
    /// replaced approval, an answered question, a new turn or an ended session never lets an older alert out.
    static func currentKey(_ kind: Alert.Kind, session: AgentSession?, turn: Int) -> String? {
        guard let session, !session.isSessionEnded else { return nil }
        switch kind {
        case .needsYou:
            if session.phase == .waitingForApproval, let request = session.permissionRequest {
                return approvalKey(session.id, request)
            }
            if session.phase == .waitingForAnswer, let prompt = session.questionPrompt {
                return questionKey(session.id, prompt)
            }
            return nil
        case .done:
            return session.phase == .completed ? doneKey(session.id, turn: turn) : nil
        case .turnFailed:
            return session.phase == .completed ? failedKey(session.id, turn: turn) : nil
        }
    }

    /// The agent went on working, so a held Done is dropped (P2): any running activity (PreToolUse,
    /// UserPromptSubmit, SubagentStart, a PermissionDenied and the other hooks the bridge turns into one), a new
    /// approval or question, and an interrupt or session end, neither of which is a Done.
    static func continuesTheTurn(_ event: AgentEvent) -> Bool {
        switch event {
        case let .activityUpdated(payload): payload.phase == .running
        case .permissionRequested, .questionAsked: true
        case let .sessionCompleted(payload): payload.isInterrupt == true || payload.isSessionEnd == true
        default: false
        }
    }

    /// Returns the alerts to deliver now; a Done is held.
    mutating func process(_ event: AgentEvent, sessionID: String, ingress: TrackedEventIngress, before: AgentSession?,
                          after: AgentSession?, now: Date, resolvingInitialSessions: Bool) -> [Alert] {
        if ingress == .bridge {
            hasSeenLiveEvent = true
            hookedSessions.insert(sessionID)
        }
        if Self.isNewPrompt(event, ingress: ingress, before: before) { turns[sessionID, default: 0] += 1 }
        if Self.continuesTheTurn(event) {
            held[sessionID] = nil
            woken.remove(sessionID)
        }
        // Nothing from restored or discovered state before the first live event (P6), no rollout signal while the
        // first process scan runs, and no rollout Done for a session whose hooks already report it (P5).
        guard hasSeenLiveEvent else { return [] }
        if ingress == .rollout, resolvingInitialSessions || hookedSessions.contains(sessionID) { return [] }

        let turn = turns[sessionID] ?? 0
        switch Self.rule(for: event, ingress: ingress, after: after, turn: turn) {
        case let .needsYou(key):
            guard Self.currentKey(.needsYou, session: after, turn: turn) == key, emittedKeys.insert(key).inserted else { return [] }
            return [Alert(kind: .needsYou, sessionID: sessionID, key: key)]
        case let .done(key):
            // The duplicate-completion check of upstream's AppModel (AppModel.swift:1542-1545 at 1.2.1), but for the
            // Stop of a turn the pipeline never saw start (P375).
            let wasWoken = woken.remove(sessionID) != nil
            guard before?.phase != .completed || wasWoken, after?.phase == .completed, !emittedKeys.contains(key) else { return [] }
            held[sessionID] = Held(key: key, dueAt: now.addingTimeInterval(Self.doneHold))
            return []
        case .none:
            return []
        }
    }

    /// The main agent's own Stop note came while its session read done: a turn it was woken to (a finished agent's
    /// result, with no prompt hook and no tool the bridge showed) ended. It is a turn of its own, and the bridge's Stop
    /// that follows gives its Done (P375).
    mutating func wokenTurnEnded(_ sessionID: String) {
        turns[sessionID, default: 0] += 1
        woken.insert(sessionID)
    }

    /// The session asks the owner something now (a request confirmed): a held Done is not a finished turn after all.
    mutating func dropHeld(_ sessionID: String) {
        held[sessionID] = nil
    }

    /// A request the engine's book just confirmed: needs you once per request id (P162), and nothing before the first
    /// live event (P6). The key starts with the session's id, so it is forgotten with the session.
    mutating func needsYou(sessionID: String, requestID: String) -> Alert? {
        held[sessionID] = nil
        let key = Self.requestKey(sessionID: sessionID, requestID: requestID)
        guard hasSeenLiveEvent, emittedKeys.insert(key).inserted else { return nil }
        return Alert(kind: .needsYou, sessionID: sessionID, key: key)
    }

    static let requestKeyMarker = "|request|"

    static func requestKey(sessionID: String, requestID: String) -> String { sessionID + requestKeyMarker + requestID }

    /// The request id a needs-you key stands for, if it is a request's.
    static func requestID(fromKey key: String) -> String? {
        key.range(of: requestKeyMarker).map { String(key[$0.upperBound...]) }
    }

    /// A live event the engine took without applying it (a request from the bridge goes to the book).
    mutating func noteLive(_ sessionID: String) {
        hasSeenLiveEvent = true
        hookedSessions.insert(sessionID)
    }

    /// The context note named this turn's end a StopFailure: its held Done is dropped, and it needs you once.
    mutating func turnFailed(sessionID: String, turn: Int) -> Alert? {
        held[sessionID] = nil
        let key = Self.failedKey(sessionID, turn: turn)
        guard hasSeenLiveEvent, emittedKeys.insert(key).inserted else { return nil }
        return Alert(kind: .turnFailed, sessionID: sessionID, key: key)
    }

    /// Held Dones whose hold has passed, each checked against the session as it is now (P5).
    mutating func due(now: Date, session: (String) -> AgentSession?) -> [Alert] {
        var alerts: [Alert] = []
        for (sessionID, entry) in held.sorted(by: { $0.value.dueAt < $1.value.dueAt }) where entry.dueAt <= now {
            held[sessionID] = nil
            guard Self.currentKey(.done, session: session(sessionID), turn: turn(for: sessionID)) == entry.key,
                  emittedKeys.insert(entry.key).inserted else { continue }
            alerts.append(Alert(kind: .done, sessionID: sessionID, key: entry.key))
        }
        return alerts
    }

    /// When this session's held Done falls due, if one is held.
    func dueAt(for sessionID: String) -> Date? { held[sessionID]?.dueAt }

    var nextDueAt: Date? { held.values.map(\.dueAt).min() }

    func turn(for sessionID: String) -> Int { turns[sessionID] ?? 0 }

    /// Every session it keeps anything for (a key starts with its session's id and "|").
    var sessionIDs: Set<String> {
        Set(turns.keys).union(held.keys).union(hookedSessions).union(woken)
            .union(emittedKeys.compactMap { $0.split(separator: "|", maxSplits: 1).first.map(String.init) })
    }

    /// Drops what is kept for a session whose tombstone expired, or that left the state
    /// (`SessionEngine.forgetSession`).
    mutating func forget(_ sessionID: String) {
        turns[sessionID] = nil
        woken.remove(sessionID)
        held[sessionID] = nil
        hookedSessions.remove(sessionID)
        emittedKeys = emittedKeys.filter { !$0.hasPrefix(sessionID + "|") }
    }
}
