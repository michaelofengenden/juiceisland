import Foundation

/// Who fired a Claude-format hook (P905). Claude Code's `settings.json` hooks are run by other agents too: Devin CLI
/// reads them by default, Grok Build runs them (and ignores their verdicts), Cursor can load them, and VS Code's
/// Copilot agent reads them. Upstream's helper takes every `--source claude` hook for Claude Code, so such a session
/// showed as a Claude row and its approvals as cards whose answer nobody followed.
///
/// The helper looks at the agent's own process (the first ancestor that is not a shell, its short name from the
/// kernel) and at the hook's environment. Only a positive sign names another agent: an unknown caller stays Claude
/// Code, as before, because dropping Claude's own hooks on a wrong guess would lose every Claude session (P906).
public enum HookCaller {
    /// What the hook ran under: the agent process's short name (`p_comm`, at most 16 bytes), its executable's path and its
    /// environment.
    public struct Signs: Equatable, Sendable {
        public var agentName: String?
        /// The agent process's executable (`proc_pidpath`): a Node agent is named `node`, and only its path says whose.
        public var agentPath: String?
        public var environment: [String: String]

        public init(agentName: String?, agentPath: String? = nil, environment: [String: String]) {
            self.agentName = agentName
            self.agentPath = agentPath
            self.environment = environment
        }
    }

    /// The agent behind a `--source claude` hook; nil when it is Claude Code (or nobody this knows).
    public static func agent(_ signs: Signs) -> AgentKind? {
        if let name = signs.agentName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            if let kind = byProcessName(name) { return kind == .claude ? nil : kind }
        }
        if let path = signs.agentPath, let kind = byExecutablePath(path) { return kind }
        let environment = signs.environment
        // Grok Build sets `GROK_HOOK_EVENT` on every hook it runs, and on nothing else (its `GROK_SESSION_ID` also reaches
        // the MCP servers it starts): a hook of Claude's or Cursor's it runs says so even when Grok runs as its `agent`
        // alias (P1110).
        if nonEmpty(environment["GROK_HOOK_EVENT"]) { return .grok }
        // Claude Code marks its own children; Devin marks its hooks with the project's folder. A Devin started from a
        // Claude session's shell carries both, so the process name above decides that case.
        if nonEmpty(environment["CLAUDE_CODE_ENTRYPOINT"]) || environment["CLAUDECODE"] == "1" { return nil }
        if nonEmpty(environment["DEVIN_PROJECT_DIR"]) { return .devin }
        return nil
    }

    /// Agents whose process is named for them. A Node install of Claude Code or of any other agent is `node`, which
    /// says nothing; the environment decides then.
    static func byProcessName(_ name: String) -> AgentKind? {
        let lowered = name.lowercased()
        switch lowered {
        case "claude": return .claude
        case "devin": return .devin
        case "grok": return .grok
        case "cursor-agent", "cursor": return .cursor
        default: break
        }
        // Editors run their agents' hooks from their extension host: "Cursor Helper (Plugin)", "Code Helper (Plugin)"
        // (VS Code, whose agent is Copilot's), cut to 16 bytes by the kernel.
        if lowered.hasPrefix("cursor helper") { return .cursor }
        if lowered.hasPrefix("code helper") || lowered.hasPrefix("code - insiders") { return .copilot }
        return nil
    }

    /// Agents whose process is a `node` of their own: the Cursor CLI's `cursor-agent` is a script that ends in
    /// `exec "$NODE_BIN" … index.js`, its Node inside its own install, `…/cursor-agent/versions/<version>/node`.
    static func byExecutablePath(_ path: String) -> AgentKind? {
        let parts = path.split(separator: "/")
        for index in parts.indices.dropLast() where parts[index] == "cursor-agent" && parts[index + 1] == "versions" {
            return .cursor
        }
        // Grok Build's installer links `~/.grok/bin/grok` and `agent` to `~/.grok/downloads/grok-<platform>`: started as
        // `agent`, its process name says nothing, its path does (P1110).
        for index in parts.indices.dropLast(2) where parts[index] == ".grok" && parts[index + 1] == "downloads"
            && parts[index + 2].hasPrefix("grok-") {
            return .grok
        }
        return nil
    }

    /// Whether the island answers this caller's approvals through a Claude-format hook: only Devin documents an answer
    /// it follows (`{"decision": "approve" | "block"}`). Grok ignores verdicts; Cursor's and VS Code's handling of a
    /// Claude hook's answer is not documented, so their approvals stay in the agent (Watch, P907).
    public static func answersThroughClaudeHook(_ kind: AgentKind) -> Bool { kind == .devin }

    private static func nonEmpty(_ value: String?) -> Bool { !(value ?? "").isEmpty }
}
