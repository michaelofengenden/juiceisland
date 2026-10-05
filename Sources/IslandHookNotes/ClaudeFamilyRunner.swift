import Foundation
import OpenIslandCore

/// Runs a Claude-format hook that upstream's helper would misread (P908, P924): GitHub Copilot CLI and Devin CLI, whose
/// `--source` words upstream does not know (it would decode them as Codex), Qwen Code, whose permission modes upstream's
/// decoder refuses, and a `--source claude` hook another agent fired (`HookCaller`). The input is decoded with
/// upstream's own Claude decoder, with the terminal context upstream's helper adds, and sent to the bridge under the
/// agent's `bridgeSource`: Qwen's own word, else a Claude-format fork's (`carrier`, CodeBuddy's), so the bridge keeps it
/// apart from Claude Code's sessions and no rule meant only for Claude Code applies; the engine labels the session with
/// its real agent from the context note. An answer goes back in the agent's own words:
/// - Copilot CLI: `{"behavior": "allow"}` or `{"behavior": "deny", "message": …}` (docs.github.com, hooks reference);
/// - Devin CLI: `{"decision": "approve"}` or `{"decision": "block", "reason": …}` (docs.devin.ai, hooks overview);
/// - Qwen Code: Claude's own output, never an `ask` (Qwen turns it into a deny, P921).
/// Anything it cannot read, or a bridge that does not answer, prints nothing: the agent goes on as without the hook.
public enum ClaudeFamilyRunner {
    /// The source the bridge is told: a Claude-format fork upstream knows, whose sessions no Claude-only rule touches.
    public static let carrier = "codebuddy"

    /// Below the registered hook timeouts (`AgentHookTable`: an hour, Qwen's 900 s), so the helper ends first and says
    /// nothing.
    public static let permissionTimeout: TimeInterval = 59 * 60
    public static let qwenPermissionTimeout: TimeInterval = 15 * 60 - 10
    public static let eventTimeout: TimeInterval = 45

    static func timeout(_ event: ClaudeHookEventName, kind: AgentKind) -> TimeInterval {
        guard event == .permissionRequest else { return eventTimeout }
        return kind == .qwen ? qwenPermissionTimeout : permissionTimeout
    }

    /// The bridge's answer to one command, or nil when it gives none (`BridgeCommandClient` in the helper).
    public typealias Send = @Sendable (BridgeCommand, TimeInterval) -> BridgeResponse?

    public static func live(bridgeURL: URL) -> Send {
        { command, timeout in try? BridgeCommandClient(socketURL: bridgeURL).send(command, timeout: timeout) }
    }

    /// One hook: what to print, nil for nothing.
    public static func run(object: [String: Any], kind: AgentKind, environment: [String: String], send: Send) -> Data? {
        // An approval of an agent the island cannot answer never reaches the bridge, which would hold it as a card with
        // Allow and Deny whose answer goes nowhere (P1129).
        if !answering.contains(kind), object["hook_event_name"] as? String == "PermissionRequest" { return nil }
        guard let payload = payload(object: object, kind: kind, environment: environment) else { return nil }
        guard let response = send(.processClaudeHook(payload), timeout(payload.hookEventName, kind: kind)) else { return nil }
        return output(for: response, kind: kind)
    }

    /// The agents whose approvals the island answers through this runner (Approve): each follows the answer in its own
    /// words. Factory Droid and Kimi are Watch; a `--source claude` hook of Grok, Cursor or VS Code is too (P907).
    public static let answering: Set<AgentKind> = [.copilot, .devin, .qwen, .qoder, .codebuddy]

    /// The hook's input as the engine and the bridge are to read it (P1127, P1131, P1133):
    /// - a value Claude has as text that an agent sends as something else (Qoder's `error_details`, Kimi Code's
    ///   `prompt` parts) is left out, so upstream's decoder reads the rest;
    /// - Kimi: its main agent's `agent_id` (`main`) is no subagent's; its PermissionRequest, which it fires and forgets
    ///   as its own prompt opens, is "needs you" (Claude's `permission_prompt` notification); its Interrupt ends the turn
    ///   as an interrupted Stop; a StopFailure's `error_message` is its `error`;
    /// - Qoder: an approval from its IDE, which answers in other words than its CLI's, is "needs you" too.
    public static func shaped(_ object: [String: Any], kind: AgentKind, environment: [String: String]) -> [String: Any] {
        var object = object
        for key in ["error", "error_details", "prompt", "message", "title", "last_assistant_message"]
            where object[key] != nil && !(object[key] is String) {
            object[key] = nil
        }
        switch kind {
        case .kimi:
            if object["agent_id"] as? String == "main" { object["agent_id"] = nil }
            switch object["hook_event_name"] as? String {
            case "PermissionRequest":
                object = needsYou(object, agent: kind.displayName)
            case "Interrupt":
                object["hook_event_name"] = "Stop"
                object["is_interrupt"] = true
            case "StopFailure":
                if object["error"] == nil { object["error"] = (object["error_message"] ?? object["error_type"]) as? String }
            default:
                break
            }
        case .qoder:
            if object["hook_event_name"] as? String == "PermissionRequest", !isQoderCLI(environment) {
                object = needsYou(object, agent: kind.displayName)
            }
        default:
            break
        }
        return object
    }

    /// An approval the agent shows itself, as Claude's `permission_prompt` notification: the island says "needs you" and
    /// jumps there, with no Allow or Deny.
    static func needsYou(_ object: [String: Any], agent: String) -> [String: Any] {
        var notice = object
        notice["hook_event_name"] = "Notification"
        notice["notification_type"] = "permission_prompt"
        notice["message"] = "\(agent) needs your permission" + ((object["tool_name"] as? String).map { " to use \($0)" } ?? "")
        return notice
    }

    /// The Qoder CLI marks its hooks with `QODER_HOOK_SOURCE`: `cli`, or `qoderwork` for QoderWork, which runs the same
    /// engine (@qoder-ai/qodercli 1.1.65). The IDE is not known to (P1127).
    static func isQoderCLI(_ environment: [String: String]) -> Bool {
        ["cli", "qoderwork"].contains(environment["QODER_HOOK_SOURCE"] ?? "")
    }

    /// Upstream's Claude payload, with the hook's folder filled in when the agent sends none (Devin's documented input
    /// has no `cwd`; upstream's decoder needs one), the terminal it runs in, and the agent's bridge source. Upstream decodes a SessionStart's
    /// `source` and the `permission_mode` as Claude's own words and fails on any other, so an agent's own word is read as
    /// Claude's nearest (Copilot's `new` is a `startup`) or left out (P924).
    public static func payload(object: [String: Any], kind: AgentKind, environment: [String: String]) -> ClaudeHookPayload? {
        var object = object
        if let source = object["source"] as? String, ClaudeSessionStartSource(rawValue: source) == nil {
            object["source"] = source == "new" ? ClaudeSessionStartSource.startup.rawValue : nil
        }
        if let mode = object["permission_mode"] as? String, ClaudePermissionMode(rawValue: mode) == nil {
            object["permission_mode"] = nil
        }
        if (object["cwd"] as? String ?? "").isEmpty {
            object["cwd"] = [environment["DEVIN_PROJECT_DIR"], environment["PWD"]].compactMap { $0 }.first { !$0.isEmpty }
                ?? FileManager.default.currentDirectoryPath
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let decoded = try? JSONDecoder().decode(ClaudeHookPayload.self, from: data) else { return nil }
        var payload = decoded.withRuntimeContext(environment: environment)
        payload.hookSource = kind.bridgeSource
        return payload
    }

    /// The bridge's answer in the agent's words; nil for an acknowledgement or an answer the agent has no words for.
    public static func output(for response: BridgeResponse, kind: AgentKind) -> Data? {
        guard case let .claudeHookDirective(directive) = response else { return nil }
        // Qwen, Qoder and CodeBuddy read Claude's own output; never an `ask` (Qwen turns it into a deny, P921).
        if [AgentKind.qwen, .qoder, .codebuddy].contains(kind) {
            if case let .preToolUse(answer) = directive, answer.permissionDecision == .ask { return nil }
            return try? ClaudeHookOutputEncoder.standardOutput(for: response)
        }
        var fields: [String: Any]
        switch (kind, directive) {
        case let (.copilot, .permissionRequest(decision)):
            switch decision {
            case .allow:
                fields = ["behavior": "allow"]
            case let .deny(message, interrupt):
                fields = ["behavior": "deny"]
                if let message, !message.isEmpty { fields["message"] = message }
                if interrupt { fields["interrupt"] = true }
            }
        case let (.devin, .permissionRequest(decision)):
            fields = decision.isAllow ? ["decision": "approve"] : ["decision": "block"]
            if case let .deny(message, _) = decision, let message, !message.isEmpty { fields["reason"] = message }
        case let (.devin, .preToolUse(directive)):
            switch directive.permissionDecision {
            case .allow: fields = ["decision": "approve"]
            case .deny: fields = ["decision": "block"]
            case .ask, nil: return nil
            }
            if let reason = directive.permissionDecisionReason, !reason.isEmpty { fields["reason"] = reason }
        default:
            return nil
        }
        guard var data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

extension ClaudePermissionRequestDecision {
    var isAllow: Bool {
        if case .allow = self { return true }
        return false
    }
}
