import Foundation
import IslandHookNotes
import OpenIslandCore

/// What the context notes have told the engine about one session: its exact jump handles and its last hook event
/// (spec §3.4, §3.8). A later note replaces a handle only with a value; an absent one keeps what was known.
public struct HookContext: Equatable, Sendable {
    /// The session's iTerm session UUID: the part of `ITERM_SESSION_ID` after the colon (P17).
    public var itermSessionID: String?
    public var tmuxSocketPath: String?
    public var tmuxPane: String?
    public var agentPID: Int32?
    public var hostBundleID: String?
    public var termProgram: String?
    /// The raw hook event name of the last note.
    public var lastEvent: String?
    /// The last note's `notification_type` when that note was a Notification that named one (note version 2).
    public var lastNotificationType: String?
    /// The last Stop's `stop_hook_active`: true when that Stop ended a continuation a Stop hook asked for.
    public var stopHookActive: Bool?
    /// `CLAUDE_CODE_ENTRYPOINT` as the last note that had one named it (note version 2).
    public var entrypoint: String?
    public var permissionMode: String?
    /// Claude's reasoning effort (`effort.level`) as the session's own last note that had one named it (P443).
    public var effort: String?
    /// The session's agent was seen in Bypass permissions (a main-thread note said `bypassPermissions`): it was launched
    /// with bypass available, so Claude takes a switch back to it; in any other session Claude ignores that switch, and
    /// the card offers none (P451). Only this agent process's: a resume may be launched without it (P454).
    public var bypassSeen = false
    /// The note version the session's helper speaks: 1 is a helper not yet updated (P163).
    public var noteVersion: Int?
    public var updatedAt: Date

    public init(itermSessionID: String? = nil, tmuxSocketPath: String? = nil, tmuxPane: String? = nil,
                agentPID: Int32? = nil, hostBundleID: String? = nil, termProgram: String? = nil,
                lastEvent: String? = nil, stopHookActive: Bool? = nil, updatedAt: Date) {
        self.itermSessionID = itermSessionID
        self.tmuxSocketPath = tmuxSocketPath
        self.tmuxPane = tmuxPane
        self.agentPID = agentPID
        self.hostBundleID = hostBundleID
        self.termProgram = termProgram
        self.lastEvent = lastEvent
        self.stopHookActive = stopHookActive
        self.updatedAt = updatedAt
    }

    /// Merges one note into what was known.
    ///
    /// A note from another agent process (the session resumed in another tab, outside tmux or in another app) tells
    /// where the session is now, so its handles replace every known one and a jump never goes to the old pane or tab.
    func merging(_ note: HookContextNote, at now: Date) -> HookContext {
        if let pid = note.agentPID, let known = agentPID, pid != known {
            var moved = HookContext(stopHookActive: stopHookActive, updatedAt: now)
            moved.entrypoint = entrypoint
            moved.permissionMode = permissionMode
            moved.effort = effort
            // Bypass stays with the process that was launched with it (P454).
            return moved.merging(note, at: now)
        }
        var next = self
        next.itermSessionID = Self.itermUUID(note.itermSessionID) ?? itermSessionID
        if let tmux = note.tmux, let socket = Self.tmuxSocketPath(tmux) {
            next.tmuxSocketPath = socket
            next.tmuxPane = note.tmuxPane ?? tmuxPane
        } else if note.tmuxPane != nil {
            next.tmuxPane = note.tmuxPane
        }
        next.agentPID = note.agentPID ?? agentPID
        next.hostBundleID = note.hostBundleID.map(JumpHosts.canonical(bundleID:)) ?? hostBundleID
        next.termProgram = note.termProgram ?? termProgram
        next.lastEvent = note.event
        next.lastNotificationType = note.event == "Notification" ? note.notificationType : nil
        if note.event == "Stop" { next.stopHookActive = note.stopHookActive }
        // A subagent's note speaks for its subagent, not for the session's own surface, mode or effort (a subagent runs
        // at its own `effort:`, P444).
        if note.agentID == nil {
            next.entrypoint = note.entrypoint ?? entrypoint
            next.permissionMode = note.permissionMode ?? permissionMode
            next.effort = note.effort ?? effort
            if note.permissionMode == "bypassPermissions" { next.bypassSeen = true }
        }
        next.noteVersion = note.version
        next.updatedAt = now
        return next
    }

    static func from(_ note: HookContextNote, at now: Date) -> HookContext {
        HookContext(updatedAt: now).merging(note, at: now)
    }

    /// `w0t1p2:5F1B…` → `5F1B…`; a value without the prefix is taken whole.
    static func itermUUID(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard let colon = value.lastIndex(of: ":") else { return value }
        let uuid = value[value.index(after: colon)...]
        return uuid.isEmpty ? nil : String(uuid)
    }

    /// `TMUX` is `<socket>,<server pid>,<session index>`; the socket path may itself hold commas, so the last two
    /// fields are taken off the end.
    static func tmuxSocketPath(_ value: String) -> String? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let socket = parts.dropLast(2).joined(separator: ",")
        return socket.hasPrefix("/") ? socket : nil
    }

    /// The exact handles a jump uses; the tty is looked up from the agent's pid when the jump runs.
    var jumpContext: JumpContext {
        JumpContext(hostBundleID: hostBundleID, itermSessionID: itermSessionID, tmuxSocketPath: tmuxSocketPath,
                    tmuxPane: tmuxPane, agentPID: agentPID)
    }
}

/// The engine's bookkeeping for context notes: contexts per session, StopFailure notes waiting for their Stop, and
/// when each session's last Stop arrived from the bridge. Pure; `SessionEngine` owns one.
struct HookNoteBook: Sendable {
    /// How long a StopFailure note and the bridge's completion may be apart and still be one failed turn. The helper
    /// sends the note first, so it is normally a few milliseconds.
    static let failureWindow: TimeInterval = 10
    /// Contexts kept for sessions the engine does not track, and at most this many in all.
    static let contextLimit = 400

    private(set) var contexts: [String: HookContext] = [:]
    private(set) var pendingFailures: [String: Date] = [:]
    private(set) var completedAt: [String: Date] = [:]
    /// SubagentStart notes whose echo from the bridge has not come yet, by session, within `failureWindow` (P511): a
    /// workflow's agents start side by side, and their tools' notes come between a SubagentStart's note and its echo.
    private(set) var subagentStarts: [String: [Date]] = [:]
    /// Claude SubagentStop notes whose echo from the bridge has not come yet, by session, within `failureWindow`
    /// (P516): upstream echoes one as running activity only while its own copy of the parent reads running.
    private(set) var subagentStops: [String: [Date]] = [:]

    mutating func record(_ note: HookContextNote, at now: Date) {
        if note.event == "SubagentStart" {
            subagentStarts[note.sessionID] = (subagentStarts[note.sessionID] ?? []).filter { Self.isRecent($0, now: now) } + [now]
        } else if note.event == "SubagentStop", note.agentSource != HookContextNote.codexSource {
            subagentStops[note.sessionID] = (subagentStops[note.sessionID] ?? []).filter { Self.isRecent($0, now: now) } + [now]
        }
        contexts[note.sessionID] = contexts[note.sessionID].map { $0.merging(note, at: now) } ?? .from(note, at: now)
        if contexts.count > Self.contextLimit,
           let oldest = contexts.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            contexts[oldest] = nil
        }
    }

    mutating func notePendingFailure(_ sessionID: String, at now: Date) { pendingFailures[sessionID] = now }

    mutating func clearPendingFailure(_ sessionID: String) { pendingFailures[sessionID] = nil }

    /// A Stop from the bridge; true when a StopFailure note for this session came just before it.
    mutating func noteCompletion(_ sessionID: String, at now: Date) -> Bool {
        completedAt[sessionID] = now
        guard let noted = pendingFailures.removeValue(forKey: sessionID) else { return false }
        return now.timeIntervalSince(noted) <= Self.failureWindow
    }

    /// Whether the session's last Stop arrived just now, so a StopFailure note that follows it names that Stop.
    func completedRecently(_ sessionID: String, now: Date) -> Bool {
        completedAt[sessionID].map { now.timeIntervalSince($0) <= Self.failureWindow } ?? false
    }

    /// A SubagentStart the bridge echoes: true, and the oldest such note is spent, when one came within `failureWindow`.
    mutating func takeSubagentStart(_ sessionID: String, now: Date) -> Bool {
        Self.take(&subagentStarts, sessionID, now: now)
    }

    /// A SubagentStop the bridge echoes: true, and the oldest such note is spent, when one came within `failureWindow`.
    mutating func takeSubagentStop(_ sessionID: String, now: Date) -> Bool {
        Self.take(&subagentStops, sessionID, now: now)
    }

    private static func take(_ notes: inout [String: [Date]], _ sessionID: String, now: Date) -> Bool {
        var recent = (notes[sessionID] ?? []).filter { isRecent($0, now: now) }
        let taken = !recent.isEmpty
        if taken { recent.removeFirst() }
        notes[sessionID] = recent.isEmpty ? nil : recent
        return taken
    }

    private static func isRecent(_ date: Date, now: Date) -> Bool { now.timeIntervalSince(date) <= failureWindow }

    mutating func forget(_ sessionID: String) {
        contexts[sessionID] = nil
        pendingFailures[sessionID] = nil
        completedAt[sessionID] = nil
        subagentStarts[sessionID] = nil
        subagentStops[sessionID] = nil
    }

    /// Every session it keeps anything for.
    var sessionIDs: Set<String> {
        Set(contexts.keys).union(pendingFailures.keys).union(completedAt.keys).union(subagentStarts.keys).union(subagentStops.keys)
    }
}
