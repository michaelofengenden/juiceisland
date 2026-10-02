import Foundation

/// What the superset helper tells the engine about one hook event, besides what upstream's helper sends the bridge
/// (spec §3.4, §3.8). Upstream's payload types stay untouched, so this goes to a second socket as one datagram.
///
/// Only an allowlist is sent: the raw hook event name, the session id and `stop_hook_active` from the hook's input;
/// `ITERM_SESSION_ID`, `TMUX`, `TMUX_PANE`, `TERM_PROGRAM` and `__CFBundleIdentifier` from the environment; and the
/// agent's pid. Never the environment as a whole, never a prompt, a tool input or a path.
///
/// Version 2 (the needs-you pipeline, P156 to P169) adds ids, names and counts the engine matches requests and their
/// evidence by: `tool_use_id`, `tool_name`, `agent_id`, `agent_type`, `notification_type`, `permission_mode`, Codex's
/// `turn_id`, SessionStart's `source`, how many background tasks a Stop names, `CLAUDE_CODE_ENTRYPOINT`, the helper's
/// `--source`, and a digest of `tool_input` (the first 16 hex digits of a SHA-256 over its canonical JSON), which
/// correlates a PreToolUse, a PermissionRequest and a PostToolUse without carrying the input. Still never text or a
/// path. The engine reads version 1 and 2 alike. Within version 2, Claude's `effort.level` (a word such as `high`, P443)
/// and how many of each kind of background work a Stop or a SubagentStop names (`background_tasks`' `type`, counted,
/// P510) were added later as optional fields: an older helper sends none, and an older engine ignores them.
public struct HookContextNote: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    /// Every version the engine reads: the helper and the app may be a build apart (P163).
    public static let readableVersions: ClosedRange<Int> = 1...2

    public var version: Int
    /// The hook's raw `hook_event_name` ("Stop", "StopFailure", "PreToolUse", …).
    public var event: String
    public var sessionID: String
    /// A Stop's `stop_hook_active`; nil for every other event, or when the hook's input has no such field.
    public var stopHookActive: Bool?
    /// `ITERM_SESSION_ID` as iTerm sets it: `w0t1p2:<session UUID>`.
    public var itermSessionID: String?
    /// `TMUX`: `<socket path>,<server pid>,<session index>`.
    public var tmux: String?
    /// `TMUX_PANE`: `%<pane id>`.
    public var tmuxPane: String?
    /// The agent (`claude`, `codex`) the hook ran for: the helper's parent, past any shell in between.
    public var agentPID: Int32?
    /// `__CFBundleIdentifier`: the app that started the agent's shell (Terminal, iTerm, Ghostty, VS Code, …).
    public var hostBundleID: String?
    /// `TERM_PROGRAM`.
    public var termProgram: String?

    // Version 2.

    /// The hook's `tool_use_id` (PreToolUse, PostToolUse, PostToolUseFailure, PermissionDenied; Claude's
    /// PermissionRequest has none).
    public var toolUseID: String?
    public var toolName: String?
    /// Set inside a subagent (Claude and Codex alike); its session id is the root's.
    public var agentID: String?
    public var agentType: String?
    /// A Notification's type (`permission_prompt`, `idle_prompt`, `elicitation_dialog`, …).
    public var notificationType: String?
    public var permissionMode: String?
    /// `CLAUDE_CODE_ENTRYPOINT`: `cli`, `claude-desktop`, `claude-vscode`, `sdk-cli`, `local-agent`, …
    public var entrypoint: String?
    /// Codex's `turn_id`.
    public var turnID: String?
    /// The agent the hook ran for: the helper's `--source`, "codex" when it has none, as upstream's helper reads it
    /// (upstream's installer gives Codex's hooks no `--source`, P290). A helper before P290 sent none for Codex:
    /// `agentSource` reads it.
    public var source: String?
    /// A SessionStart's `source` (`startup`, `resume`, `clear`, `compact`, `fork`).
    public var sessionStartSource: String?
    /// How many background tasks a Stop names (`background_tasks`).
    public var backgroundTaskCount: Int?
    /// `HookInputDigest` of `tool_input`, for tool events.
    public var inputDigest: String?
    /// Claude's `effort.level` (the reasoning effort the turn runs at, on its tool and Stop events; P443): a word such as
    /// `high`, never text. Optional within version 2: an older helper sends none, an older engine ignores it.
    public var effort: String?
    /// How many of each kind of in-flight background work a Stop or a SubagentStop names (`background_tasks`, P510):
    /// Claude's own `type` labels (`subagent`, `workflow`, `shell`, `monitor`, …, `knownBackgroundKinds`), any other as
    /// `other`; a SubagentStop's leaves out its own agent, which Claude still lists as running while its hook runs.
    /// Counts only, never a description, a command or a name. Empty when nothing is in flight; nil when the hook names
    /// no such list (an older Claude) or the helper is older (optional within version 2).
    public var backgroundTaskKinds: [String: Int]?
    /// A SubagentStop's own agent was one of the background agents its `background_tasks` names (type `subagent`,
    /// P515): a background agent, whose result wakes the main agent, which Claude still lists while its hook runs. False
    /// for an agent it does not list (a workflow's agent, whose workflow is listed instead; an agent of a background
    /// agent's own). A boolean, never an id; nil on any other hook, with no list, or from an older helper.
    public var agentInBackground: Bool?

    public init(version: Int = HookContextNote.currentVersion, event: String, sessionID: String,
                stopHookActive: Bool? = nil, itermSessionID: String? = nil, tmux: String? = nil,
                tmuxPane: String? = nil, agentPID: Int32? = nil, hostBundleID: String? = nil,
                termProgram: String? = nil, toolUseID: String? = nil, toolName: String? = nil, agentID: String? = nil,
                agentType: String? = nil, notificationType: String? = nil, permissionMode: String? = nil,
                entrypoint: String? = nil, turnID: String? = nil, source: String? = nil, sessionStartSource: String? = nil,
                backgroundTaskCount: Int? = nil, inputDigest: String? = nil, effort: String? = nil,
                backgroundTaskKinds: [String: Int]? = nil, agentInBackground: Bool? = nil) {
        self.version = version
        self.event = event
        self.sessionID = sessionID
        self.stopHookActive = stopHookActive
        self.itermSessionID = itermSessionID
        self.tmux = tmux
        self.tmuxPane = tmuxPane
        self.agentPID = agentPID
        self.hostBundleID = hostBundleID
        self.termProgram = termProgram
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.agentID = agentID
        self.agentType = agentType
        self.notificationType = notificationType
        self.permissionMode = permissionMode
        self.entrypoint = entrypoint
        self.turnID = turnID
        self.source = source
        self.sessionStartSource = sessionStartSource
        self.backgroundTaskCount = backgroundTaskCount
        self.inputDigest = inputDigest
        self.effort = effort
        self.backgroundTaskKinds = backgroundTaskKinds
        self.agentInBackground = agentInBackground
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case event
        case sessionID = "session_id"
        case stopHookActive = "stop_hook_active"
        case itermSessionID = "iterm_session_id"
        case tmux
        case tmuxPane = "tmux_pane"
        case agentPID = "agent_pid"
        case hostBundleID = "host_bundle_id"
        case termProgram = "term_program"
        case toolUseID = "tool_use_id"
        case toolName = "tool_name"
        case agentID = "agent_id"
        case agentType = "agent_type"
        case notificationType = "notification_type"
        case permissionMode = "permission_mode"
        case entrypoint
        case turnID = "turn_id"
        case source
        case sessionStartSource = "session_start_source"
        case backgroundTaskCount = "background_task_count"
        case inputDigest = "input_digest"
        case effort
        case backgroundTaskKinds = "background_task_kinds"
        case agentInBackground = "agent_in_background"
    }

    /// What a Codex hook's note names as its source (P290).
    public static let codexSource = "codex"

    /// The agent the note is for, whichever helper sent it: a version-2 note with no source came from a helper before
    /// P290 running a Codex hook, which is the only hook upstream's installer gives no `--source`; nil only for a
    /// version-1 note, which never said.
    public var agentSource: String? { source ?? (version >= 2 ? Self.codexSource : nil) }

    /// The only environment variables a note ever carries.
    public static let environmentAllowlist = ["ITERM_SESSION_ID", "TMUX", "TMUX_PANE", "TERM_PROGRAM", "__CFBundleIdentifier",
                                              "CLAUDE_CODE_ENTRYPOINT"]
    /// The kinds of background work a note counts by name (`background_tasks`' `type`, Claude Code 2.1's friendly labels:
    /// `local_agent` is `subagent`, `local_workflow` `workflow`, `local_bash` `shell`, …); any other counts as `other`.
    public static let knownBackgroundKinds: Set<String> = ["subagent", "workflow", "shell", "monitor", "MCP task", "teammate",
                                                           "cloud session", "dream", "auto-mode scan"]
    public static let otherBackgroundKind = "other"
    /// The kinds a main agent is woken by, which the engine waits on (P510): Claude's background agents and workflows.
    public static let waitedKinds: Set<String> = ["subagent", "workflow"]
    /// The hook events whose `background_tasks` are counted by kind.
    public static let backgroundEvents: Set<String> = ["Stop", "SubagentStop"]

    /// The hook events whose `tool_input` is digested.
    public static let toolEvents: Set<String> = ["PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure",
                                                 "PermissionDenied"]

    /// Longest value kept for any field; a longer one is dropped rather than cut, so a handle is never half a handle.
    public static let fieldLimit = 256
    /// The receiver's datagram limit is 2,048 bytes (`net.local.dgram.maxdgram`); a note stays well under it.
    public static let maximumSize = 2_000

    /// The note for one hook event: its input (the JSON the agent wrote to the helper's stdin), the helper's
    /// environment and the agent's pid. nil when the input is not a JSON object with a string `hook_event_name` and
    /// `session_id`: such a hook gets no note, and upstream's helper handles it as before.
    public static func make(input: Data, environment: [String: String], agentPID: Int32?,
                            source: String? = nil) -> HookContextNote? {
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
        return make(object: object, environment: environment, agentPID: agentPID, source: source)
    }

    /// As `make(input:…)`, for input already parsed.
    public static func make(object: [String: Any], environment: [String: String], agentPID: Int32?,
                            source: String? = nil) -> HookContextNote? {
        guard let event = kept(object["hook_event_name"] as? String, limit: 64),
              let sessionID = kept(object["session_id"] as? String, limit: 128) else { return nil }
        return HookContextNote(
            event: event, sessionID: sessionID,
            stopHookActive: event == "Stop" ? (object["stop_hook_active"] as? NSNumber).flatMap(boolean) : nil,
            itermSessionID: kept(environment["ITERM_SESSION_ID"]), tmux: kept(environment["TMUX"]),
            tmuxPane: kept(environment["TMUX_PANE"]), agentPID: agentPID.flatMap { $0 > 1 ? $0 : nil },
            hostBundleID: kept(environment["__CFBundleIdentifier"]), termProgram: kept(environment["TERM_PROGRAM"]),
            toolUseID: kept(object["tool_use_id"] as? String, limit: 128), toolName: kept(object["tool_name"] as? String, limit: 64),
            agentID: kept(object["agent_id"] as? String, limit: 128), agentType: kept(object["agent_type"] as? String, limit: 64),
            notificationType: kept(object["notification_type"] as? String, limit: 64),
            permissionMode: kept(object["permission_mode"] as? String, limit: 32),
            entrypoint: kept(environment["CLAUDE_CODE_ENTRYPOINT"], limit: 32),
            turnID: kept(object["turn_id"] as? String, limit: 128), source: kept(source, limit: 32),
            sessionStartSource: event == "SessionStart" ? kept(object["source"] as? String, limit: 32) : nil,
            backgroundTaskCount: event == "Stop" ? (object["background_tasks"] as? [Any])?.count : nil,
            inputDigest: toolEvents.contains(event) ? object["tool_input"].flatMap(HookInputDigest.of) : nil,
            effort: kept((object["effort"] as? [String: Any])?["level"] as? String, limit: 16),
            backgroundTaskKinds: backgroundEvents.contains(event)
                ? backgroundKindCounts(object["background_tasks"], leavingOut: object["agent_id"] as? String) : nil,
            agentInBackground: event == "SubagentStop" ? listsBackgroundAgent(object["background_tasks"], object["agent_id"] as? String) : nil)
    }

    /// Whether `background_tasks` names `agentID` as a background agent (P515): nil when it is not a list or there is
    /// no agent id.
    static func listsBackgroundAgent(_ value: Any?, _ agentID: String?) -> Bool? {
        guard let items = value as? [Any], let agentID, !agentID.isEmpty else { return nil }
        return items.contains { item in
            guard let item = item as? [String: Any] else { return false }
            return item["id"] as? String == agentID && item["type"] as? String == "subagent"
        }
    }

    /// `background_tasks` counted by kind (P510): nil when it is not a list. An item whose `id` is `leavingOut` (a
    /// SubagentStop's own agent) is not counted; an item with no known `type` counts as `other`.
    static func backgroundKindCounts(_ value: Any?, leavingOut agentID: String?) -> [String: Int]? {
        guard let items = value as? [Any] else { return nil }
        var counts: [String: Int] = [:]
        for case let item as [String: Any] in items {
            if let agentID, !agentID.isEmpty, item["id"] as? String == agentID { continue }
            let type = item["type"] as? String
            let kind = type.flatMap { knownBackgroundKinds.contains($0) ? $0 : nil } ?? otherBackgroundKind
            counts[kind, default: 0] += 1
        }
        return counts
    }

    /// The datagram: compact JSON, or nil when it would not fit. A note whose handles are all at their longest could
    /// pass the limit with every version-2 field set; then the names the engine only shows go first, and the ids it
    /// matches by stay.
    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var note = self
        for trim in Self.trims {
            if let data = try? encoder.encode(note), data.count <= Self.maximumSize { return data }
            trim(&note)
        }
        guard let data = try? encoder.encode(note), data.count <= Self.maximumSize else { return nil }
        return data
    }

    private static let trims: [@Sendable (inout HookContextNote) -> Void] = [
        // Only the kinds the engine waits on stay (P510); the rest are counted for nothing else yet.
        { $0.backgroundTaskKinds = $0.backgroundTaskKinds?.filter { waitedKinds.contains($0.key) } },
        { $0.effort = nil }, { $0.termProgram = nil }, { $0.agentType = nil }, { $0.permissionMode = nil }, { $0.sessionStartSource = nil },
        { $0.toolName = nil }, { $0.itermSessionID = nil },
    ]

    public static func decode(_ data: Data) -> HookContextNote? {
        guard data.count <= maximumSize, let note = try? JSONDecoder().decode(HookContextNote.self, from: data),
              readableVersions.contains(note.version), !note.event.isEmpty, !note.sessionID.isEmpty else { return nil }
        return note
    }

    private static func kept(_ value: String?, limit: Int = fieldLimit) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= limit else { return nil }
        return value
    }

    /// JSON booleans only: a number such as 1 is not a boolean.
    private static func boolean(_ number: NSNumber) -> Bool? {
        CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : nil
    }
}
