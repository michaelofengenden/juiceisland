import Foundation
import OpenIslandCore

/// Gemini CLI's, Antigravity CLI's and Grok Build's hooks as the helper reads them (wave 4, P1100 to P1124). All three
/// are Watch: the island shows their sessions, says "needs you" where the agent says it waits, and jumps to them; no
/// hook of theirs ever prints a verdict.

/// Gemini CLI (`--source gemini`). Upstream's helper decodes SessionStart, SessionEnd, BeforeAgent, AfterAgent and
/// Notification; its tool events it cannot decode, and it would say so on stderr, which Gemini CLI turns into a message
/// to the owner (`hookRunner.ts`: with no stdout, stderr is the hook's output). So the helper ends those with their note
/// alone (P1101).
public enum GeminiHooks {
    /// Gemini CLI's tool events (`packages/core/src/hooks/types.ts`, `HookEventName`).
    public static let toolEvents: Set<String> = ["BeforeTool", "AfterTool"]
}

/// Antigravity CLI (`agy`), Gemini CLI's successor (P1105 to P1108). Its hooks.json maps a hook's name to its events, and
/// its stdin names no event: only `conversationId`, `workspacePaths`, `transcriptPath`, `artifactDirectoryPath` and
/// `modelName`, then the event's own fields (antigravity.google/docs/hooks). Juice registers only events whose fields
/// tell them apart: PreInvocation (`invocationNum`), PostToolUse (`toolCall`) and Stop (`fullyIdle`,
/// `terminationReason`, `executionNum`). Never PreToolUse, whose output's `decision` is required and decides the call,
/// nor PostInvocation, whose fields are PreInvocation's.
public enum AntigravityHooks {
    public enum Event: String, CaseIterable, Sendable {
        case preInvocation = "PreInvocation"
        case postToolUse = "PostToolUse"
        case stop = "Stop"
    }

    /// The bridge's answer is never waited on for long: agy runs each hook for at most its `timeout`
    /// (`AgentHookTable.antigravity`, 10 s).
    public static let bridgeTimeout: TimeInterval = 8

    /// The event the input is, from its fields; nil for anything else (a PreToolUse or PostInvocation someone else's
    /// entry runs through this helper is left alone).
    public static func event(of object: [String: Any]) -> Event? {
        if object["toolCall"] != nil { return .postToolUse }
        if object["fullyIdle"] != nil || object["terminationReason"] != nil || object["executionNum"] != nil { return .stop }
        if object["invocationNum"] != nil { return .preInvocation }
        return nil
    }

    /// The input with Claude's field names, so `HookContextNote.make` reads it: the event, the conversation as the
    /// session, the tool's name. Nothing else (P1107).
    public static func noteObject(_ object: [String: Any]) -> [String: Any]? {
        guard let event = event(of: object), let id = object["conversationId"] as? String, !id.isEmpty else { return nil }
        var note: [String: Any] = ["hook_event_name": event.rawValue, "session_id": id]
        if let name = (object["toolCall"] as? [String: Any])?["name"] as? String { note["tool_name"] = name }
        return note
    }

    /// What the bridge is told, in Gemini CLI's words: a model call or a finished tool is the turn at work
    /// (BeforeAgent), a Stop with nothing left running is the turn done (AfterAgent). A Stop whose background work still
    /// runs (`fullyIdle` false) tells nothing: agy goes on with it. The folder is the first workspace, since agy runs
    /// its hooks in `~/.gemini/config` (google-antigravity/antigravity-cli#1005); no prompt, reply or transcript, which
    /// agy's hooks do not carry (P1106). The terminal it runs in is added by the helper (`withRuntimeContext`), as
    /// upstream's helper adds it to Gemini CLI's.
    public static func payload(_ object: [String: Any]) -> GeminiHookPayload? {
        guard let event = event(of: object), let id = object["conversationId"] as? String, !id.isEmpty else { return nil }
        let name: GeminiHookEventName
        switch event {
        case .preInvocation, .postToolUse:
            name = .beforeAgent
        case .stop:
            guard (object["fullyIdle"] as? Bool) != false else { return nil }
            name = .afterAgent
        }
        let folder = (object["workspacePaths"] as? [Any])?.compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
        return GeminiHookPayload(cwd: folder, hookEventName: name, sessionID: id)
    }
}

/// Grok Build (P1110 to P1113). Its hook input is camelCase (`hookEventName`, `sessionId`, `notificationType`), with
/// Claude's snake_case names added for some keys (`hook_event_name` in PascalCase, `session_id`, `tool_name`, …) but
/// not for `notificationType` (xai-org/grok-build, `crates/codegen/xai-grok-hooks/src/event.rs`,
/// `SNAKE_CASE_ALIASES`). The note reads Claude's names, so they are filled in from Grok's own.
public enum GrokHookFields {
    public static func noteObject(_ object: [String: Any]) -> [String: Any] {
        var object = object
        if object["hook_event_name"] == nil, let event = (object["hookEventName"] as? String).flatMap(pascal) {
            object["hook_event_name"] = event
        }
        if object["session_id"] == nil, let session = object["sessionId"] { object["session_id"] = session }
        if object["notification_type"] == nil, let type = object["notificationType"] { object["notification_type"] = type }
        if object["tool_name"] == nil, let tool = object["toolName"] { object["tool_name"] = tool }
        return object
    }

    /// The input as upstream's Grok decoder reads it (camelCase keys): Grok sends both spellings, so this only fills in
    /// a camelCase key from its snake_case alias where one is missing.
    public static func payloadObject(_ object: [String: Any]) -> [String: Any] {
        var object = object
        for (camel, snake) in [("hookEventName", "hook_event_name"), ("sessionId", "session_id"), ("toolName", "tool_name"),
                               ("toolInput", "tool_input"), ("toolUseId", "tool_use_id"), ("notificationType", "notification_type"),
                               ("permissionMode", "permission_mode")] where object[camel] == nil {
            if let value = object[snake] { object[camel] = value }
        }
        return object
    }

    /// Grok's event name in any of its spellings (`session_start`, `sessionStart`, `SessionStart`) as Claude spells it.
    static func pascal(_ raw: String) -> String? {
        let squashed = raw.replacingOccurrences(of: "_", with: "").lowercased()
        return GrokHookEventName.allCases.first { $0.rawValue.lowercased() == squashed }?.rawValue
    }
}
