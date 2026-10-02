import Foundation
import IslandHookNotes

/// The truth tables of the needs-you design (§2) as functions. Pure: the broker asks `holds` on its own queue and
/// replies before anything else is read; the engine asks the rest when it enters a request.
enum AttentionPolicy {
    /// The only Claude surfaces a request may be held for: each shows its own prompt at the same time as the hook, and
    /// takes the first answer, so the hold blocks nothing (Claude Code #82150; the desktop card, seen live) (C10).
    static let holdableEntrypoints: Set<String> = ["cli", "claude-desktop", "claude-desktop-3p", "claude-vscode"]
    /// No person at a prompt: the hook decides or the call is denied.
    static let headlessEntrypoints: Set<String> = ["sdk-cli", "sdk-ts", "sdk-py"]

    struct ClaudeDecision: Equatable, Sendable {
        /// The broker keeps the connection open so an island click can answer.
        var hold: Bool
        /// The request is shown (read-only when not held) once confirmed.
        var show: Bool
        var place: AttentionRequest.Place
    }

    /// The surface a Claude request comes from: its entrypoint, "cli" when none is given but the agent has a
    /// terminal, "missing" otherwise (Diagnostics names it so).
    static func claudeSurface(entrypoint: String?, hasTerminal: Bool) -> String {
        if let entrypoint, !entrypoint.isEmpty { return entrypoint }
        return hasTerminal ? "cli" : "missing"
    }

    /// Claude (§2.1): held only on the main thread of the four interactive surfaces; released at once and shown
    /// read-only for a subagent (its hook is awaited before Claude builds the prompt, so holding would hide it: a
    /// background subagent's decision is honoured, but Claude shows no prompt and sends no `permission_prompt` while
    /// the hook holds, claude-code#82150, unchanged through 2.1.283; nothing in the hook's input tells a foreground
    /// subagent apart; P280; only the owner's opt-in, Answer subagents on the island, holds one, bounded and while its card
    /// shows: `brokerHold`, P350),
    /// `local-agent` and any unknown or missing-without-a-terminal entrypoint; released and not shown at all for a
    /// headless run or `dontAsk` (the call is the SDK host's, or denied).
    static func claude(entrypoint: String?, hasTerminal: Bool, agentID: String?, permissionMode: String?) -> ClaudeDecision {
        let surface = claudeSurface(entrypoint: entrypoint, hasTerminal: hasTerminal)
        let place = claudePlace(surface)
        if permissionMode == "dontAsk" || headlessEntrypoints.contains(surface) {
            return ClaudeDecision(hold: false, show: false, place: place)
        }
        let isSubagent = !(agentID ?? "").isEmpty
        return ClaudeDecision(hold: !isSubagent && holdableEntrypoints.contains(surface), show: true, place: place)
    }

    static func claudePlace(_ surface: String) -> AttentionRequest.Place {
        switch surface {
        case "claude-desktop", "claude-desktop-3p", "local-agent": .claudeApp
        case "claude-vscode": .ide
        default: .terminal
        }
    }

    /// Codex (§2.2): every request is released at once (Codex runs PermissionRequest hooks before its own reviewer and
    /// prompt, so a hold hides both), unless the owner's opt-in holds it while its card shows (`codexHoldable`, P470). It
    /// is shown only when Codex will ask a person: not in bypass (policy `never`:
    /// Guardian or the policy decides), not on a thread whose latest reviewer is `auto_review`, not in a turn under
    /// strict auto review. An unknown reviewer counts as the user: a non-blocking notice at worst (C6).
    static func codexShows(permissionMode: String?, reviewer: String?, strictAutoReview: Bool) -> Bool {
        if permissionMode == "bypassPermissions" { return false }
        if reviewer == "auto_review" { return false }
        return !strictAutoReview
    }

    /// The broker's reply, from the request alone, before any rollout or state is read, with Answer subagents on the
    /// island off.
    static func holds(_ line: HookRequestLine, _ object: [String: Any]) -> Bool {
        brokerHold(line, object, answersSubagents: false).held
    }

    /// The broker's reply, from the request alone, before any rollout or state is read: a Claude main-thread request
    /// on a holdable surface is held until the engine ends it; with Answer subagents on the island on, a subagent's tool
    /// approval from the same surfaces is held too, and the broker ends that hold by itself after `backstop` whatever the
    /// main thread does (P350); with Answer Codex on the island on, a Codex main-thread shell command or patch in
    /// Codex's `default` mode is held the same way, bounded, until the engine has read its thread's reviewer and where the
    /// owner looks (P470); everything else is released at once.
    static func brokerHold(_ line: HookRequestLine, _ object: [String: Any], answersSubagents: Bool, answersCodex: Bool = false,
                           backstop: TimeInterval = SubagentHold.limit + SubagentHold.backstopMargin) -> BrokerHold {
        if line.source == "codex" {
            let input = object["tool_input"] as? [String: Any]
            guard answersCodex,
                  codexHoldable(agentID: object["agent_id"] as? String, permissionMode: object["permission_mode"] as? String,
                                toolName: object["tool_name"] as? String, description: input?["description"] as? String) else {
                return .released
            }
            return BrokerHold(held: true, bound: backstop)
        }
        guard line.source == "claude" else { return .released }
        let agentID = object["agent_id"] as? String
        let mode = object["permission_mode"] as? String
        if claude(entrypoint: line.entrypoint, hasTerminal: line.hasTerminal, agentID: agentID, permissionMode: mode).hold {
            return BrokerHold(held: true)
        }
        guard answersSubagents,
              subagentHoldable(entrypoint: line.entrypoint, hasTerminal: line.hasTerminal, agentID: agentID, permissionMode: mode,
                               toolName: object["tool_name"] as? String) else { return .released }
        return BrokerHold(held: true, bound: backstop)
    }

    /// A subagent's request the opt-in may hold for the island (P350): a tool approval (a question or a plan would take
    /// longer to answer than the hold lasts) from one of the four surfaces a main-thread request is held for, never in
    /// `dontAsk`, a headless run, `local-agent` or an unknown surface, whose ordering nobody measured.
    static func subagentHoldable(entrypoint: String?, hasTerminal: Bool, agentID: String?, permissionMode: String?,
                                 toolName: String?) -> Bool {
        guard let agentID, !agentID.isEmpty, permissionMode != "dontAsk" else { return false }
        guard holdableEntrypoints.contains(claudeSurface(entrypoint: entrypoint, hasTerminal: hasTerminal)) else { return false }
        return toolName != "AskUserQuestion" && toolName != "ExitPlanMode"
    }

    /// A Codex request the opt-in may hold for the island (P470): Codex awaits its PermissionRequest hook before its
    /// reviewer and before its own prompt (openai/codex `core/src/tools/approvals.rs`, "1. Hooks 2. … Guardian. Else,
    /// user"), so only a request Codex would put to a person, whose whole content the card shows and whose own call closes
    /// it: the main thread (a subagent's is filed under its chat and read from its own rollout), Codex's `default` mode
    /// (`bypassPermissions` is policy `never`: nobody is asked; a missing mode is a Codex too old to say), and a shell
    /// command (not a network approval, which Codex asks as Bash with `network-access <target>`) or a patch. An MCP or
    /// connector call (its reviewer is set per server), `request_permissions` (a grant for the turn), `write_stdin` and
    /// anything unknown are released at once, as with the switch off.
    static func codexHoldable(agentID: String?, permissionMode: String?, toolName: String?, description: String?) -> Bool {
        guard (agentID ?? "").isEmpty, permissionMode == "default", let toolName, CodexHold.tools.contains(toolName) else { return false }
        return !codexIsUnmatched(toolName: toolName, description: description)
    }

    /// Bundle ids of the IDEs whose extensions run Codex or Claude (Open goes to the IDE).
    static let ideBundleIDs: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
                                            "com.exafunction.windsurf", "com.trae.app", "dev.zed.Zed"]

    static func codexPlace(isCodexApp: Bool, hostBundleID: String?) -> AttentionRequest.Place {
        if isCodexApp || hostBundleID.map(JumpHosts.canonical(bundleID:)) == ExactJump.codexBundleID { return .codexApp }
        if let hostBundleID, ideBundleIDs.contains(hostBundleID) { return .ide }
        return .terminal
    }

    /// Codex tool families: a PermissionRequest's `tool_name` and the rollout call names that can be its call (C7). A
    /// code-mode cell (`exec`, `js`) runs its commands and patches as nested calls with no line of their own, and a
    /// patch run through a shell tool is intercepted and asked as `apply_patch` under that call's id (P183). An MCP
    /// call is named as its hook names it (`CodexAttention.callName`).
    static func codexCallNames(forHookTool tool: String?) -> Set<String>? {
        switch tool {
        case "Bash": Set(["exec_command", "shell", "shell_command", "local_shell_call", "container.exec"]).union(CodexAttention.codeModeCells)
        case "apply_patch": Set(["apply_patch", "exec_command", "shell", "shell_command", "local_shell_call"]).union(CodexAttention.codeModeCells)
        case "request_permissions": ["request_permissions"]
        case nil, "write_stdin": nil
        case let name?: [name]
        }
    }

    /// A shell call is an `apply_patch` request's only when Codex intercepted a patch in it.
    static func codexCallFits(_ call: CodexAttention.Call, hookTool: String?) -> Bool {
        guard hookTool == "apply_patch", call.name != "apply_patch", !CodexAttention.codeModeCells.contains(call.name) else { return true }
        return call.command?.contains("*** Begin Patch") == true
    }

    /// A Codex request with no call of its own to wait for: a network approval (`network-access <target>`), a
    /// `write_stdin`, a tool with no name. It closes on turn end, Open or ✕ only, and is never matched to a call.
    static func codexIsUnmatched(toolName: String?, description: String?) -> Bool {
        if (description ?? "").hasPrefix("network-access ") { return true }
        return codexCallNames(forHookTool: toolName) == nil
    }
}
