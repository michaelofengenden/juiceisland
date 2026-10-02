import Foundation
import IslandHookNotes

/// The tool calls each session has started and not yet finished, from the context notes (P440): a PreToolUse names its
/// call by `tool_use_id` (Claude's and Codex's alike, note version 2), and its PostToolUse, PostToolUseFailure or
/// PermissionDenied names the same id when the call is over. A long build says nothing between the two, so its session
/// is at work however quiet it is; a stall is measured on a session with nothing in flight (`SessionEngine.toolInFlightSince`).
///
/// A call refused at the agent's own prompt or on the island ends with its request (`end`). One whose end never came (a
/// lost datagram, an Esc that ended the call without a hook) goes at its turn's end: the session's own Stop,
/// StopFailure, next prompt or Codex's Interrupt ends the main agent's calls, a SubagentStop that subagent's, a
/// SessionStart or SessionEnd all of them. Pure; ids and times only, never a tool's input.
struct ToolFlightBook: Sendable {
    struct Flight: Equatable, Sendable {
        /// The subagent that runs it; nil for the session's own agent.
        var agentID: String?
        var startedAt: Date
    }

    /// Calls kept per session, at most: parallel reads are a handful; the oldest goes first past this.
    static let perSessionLimit = 32

    private(set) var flights: [String: [String: Flight]] = [:]
    /// Sessions whose helper has named a call's id: for them the book alone says what is in flight.
    private(set) var noted: Set<String> = []

    static let startEvents: Set<String> = ["PreToolUse"]
    static let endEvents: Set<String> = ["PostToolUse", "PostToolUseFailure", "PermissionDenied"]
    /// The main agent's turn is over (or a new one began): its calls are no longer running.
    static let turnEvents: Set<String> = ["Stop", "StopFailure", "UserPromptSubmit", "Interrupt"]
    static let sessionEvents: Set<String> = ["SessionStart", "SessionEnd"]

    mutating func record(_ note: HookContextNote, at now: Date) {
        let id = note.sessionID
        if Self.startEvents.contains(note.event) {
            guard let call = note.toolUseID else { return }
            noted.insert(id)
            var calls = flights[id] ?? [:]
            // A call's start is its first PreToolUse: a repeated one does not move it.
            if calls[call] == nil { calls[call] = Flight(agentID: note.agentID, startedAt: now) }
            while calls.count > Self.perSessionLimit, let oldest = calls.min(by: { $0.value.startedAt < $1.value.startedAt })?.key {
                calls[oldest] = nil
            }
            flights[id] = calls
        } else if Self.endEvents.contains(note.event) {
            guard let call = note.toolUseID else { return }
            noted.insert(id)
            remove(in: id) { key, _ in key == call }
        } else if note.event == "SubagentStop", let agent = note.agentID {
            remove(in: id) { _, flight in flight.agentID == agent }
        } else if Self.turnEvents.contains(note.event), note.agentID == nil {
            // A subagent that runs on in the background keeps its calls (its own SubagentStop ends them).
            remove(in: id) { _, flight in flight.agentID == nil }
        } else if Self.sessionEvents.contains(note.event), note.agentID == nil {
            if flights[id] != nil { flights[id] = nil }
        }
    }

    /// The call is over by other evidence: its transcript wrote its result (a No or an Esc at the agent's own prompt fires
    /// no hook), or the island said No, so it never ran.
    mutating func end(_ sessionID: String, call: String) {
        remove(in: sessionID) { key, _ in key == call }
    }

    /// When the oldest call still in flight began; nil when none is.
    func inFlightSince(_ sessionID: String) -> Date? {
        flights[sessionID]?.values.map(\.startedAt).min()
    }

    mutating func forget(_ sessionID: String) {
        flights[sessionID] = nil
        noted.remove(sessionID)
    }

    var sessionIDs: Set<String> { Set(flights.keys).union(noted) }

    private mutating func remove(in sessionID: String, where gone: (String, Flight) -> Bool) {
        guard var calls = flights[sessionID] else { return }
        calls = calls.filter { !gone($0.key, $0.value) }
        flights[sessionID] = calls.isEmpty ? nil : calls
    }
}
