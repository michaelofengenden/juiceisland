import Foundation

/// Who started a session, which decides what it may tell the owner (P250-P257). Only the owner's own top-level
/// sessions notify: the Done card, the Done sound, the pill's count and "Show N more". A request that waits on the
/// owner (an approval, a question) is not a notification of this kind: it surfaces from any of them, where the
/// needs-you book puts it.
public enum SessionScope: Equatable, Sendable {
    /// A top-level session the owner started: a terminal, the Claude or Codex app, an editor. A session nothing
    /// speaks for is this.
    case owner
    /// A child of another session: a Codex thread another thread spawned, an auto-review (Guardian) thread, Codex's
    /// own internal threads, a Claude subagent's transcript. Its parent's turn end is its Done.
    case subagent
    /// A run nobody sits at: `claude -p`, `codex exec`, a Codex SDK app, the Claude Code codex plugin's Codex
    /// Companion Tasks. Hidden unless Settings › Island › Show scripted runs; never notifies.
    case scripted
}

/// What a Codex thread's own hooks showed of the process that runs it (P257). Only the absence of
/// `CLAUDE_CODE_ENTRYPOINT` is read: no process started under Claude lacks it, while a shared app-server keeps whichever
/// environment first started it, so its presence proves nothing.
enum CodexHand: Comparable, Sendable {
    /// A hook of the thread ran outside Claude: not the codex plugin, whose app-server a Claude session starts.
    case outsideClaude
    /// A `resume` SessionStart ran outside Claude: someone took the thread up again (`codex resume` in a terminal, the
    /// Codex app).
    case resumedOutsideClaude
}

/// What tells the scopes apart, from what the engine already receives (the diagnosis of 2026-09-26). No new helper
/// field: the context note's `CLAUDE_CODE_ENTRYPOINT`, a Codex hook's transcript path and a rollout's `session_meta`.
enum SessionScopeRules {
    /// Claude Code's entrypoints of runs no one sits at. Claude Code 2.1.280 sets `sdk-cli` for `-p` and any other
    /// non-interactive start (an inherited `cli` included), `claude mcp serve` sets `mcp`, and GitHub's action its own.
    /// `cli`, `claude-desktop`, `claude-desktop-3p`, `claude-vscode`, `local-agent` and every other value are the
    /// owner's, the Agent SDK's `sdk-ts` and `sdk-py` too: an editor's agent panel is built on the SDK and sets no
    /// entrypoint of its own (Zed's Claude Agent over ACP, P256).
    static let scriptedClaudeEntrypoints: Set<String> = ["sdk-cli", "mcp", "claude-code-github-action"]

    /// A Claude root note's entrypoint (note v2); nil says nothing (a note v1, or no entrypoint).
    static func claude(entrypoint: String?) -> SessionScope? {
        guard let entrypoint, !entrypoint.isEmpty else { return nil }
        return scriptedClaudeEntrypoints.contains(entrypoint) ? .scripted : .owner
    }

    /// `session_meta.source` (openai/codex `protocol.rs` `SessionSource`, its string or its one key) of a child:
    /// `{"subagent": {"thread_spawn": …}}`, `{"subagent": "review"}`, `{"internal": "guardian"}`.
    static let childCodexSources: Set<String> = ["subagent", "internal"]
    /// `session_meta.thread_source` of a child (`ThreadSource`).
    static let childCodexThreadSources: Set<String> = ["subagent", "guardian_review", "memory_consolidation"]
    /// `session_meta.source` of a run no one sits at: `codex exec`, and `codex mcp-server` (another agent's tool).
    static let scriptedCodexSources: Set<String> = ["exec", "mcp"]
    /// `session_meta.originator` of a run no one sits at: `codex exec`, and the codex plugin for Claude Code, whose
    /// app-server client is named "Claude Code" (`scripts/lib/app-server.mjs`, which `initialize` makes the originator).
    /// The Codex SDKs' `codex_sdk_ts` and the like go by their prefix.
    static let scriptedCodexOriginators: Set<String> = ["codex_exec", pluginOriginator]
    static let scriptedCodexOriginatorPrefix = "codex_sdk"
    /// The codex plugin's client name, so its tasks' originator.
    static let pluginOriginator = "Claude Code"

    /// A rollout's verdict, weighed against the thread's hooks (P257). A resume outside Claude makes a scripted run the
    /// owner's whatever started it (Codex writes no new `session_meta` on resume); any hook outside Claude ends a claim
    /// that rests on the plugin's originator. A child stays a child.
    static func codex(_ rollout: SessionScope, originator: String?, hand: CodexHand?) -> SessionScope {
        guard rollout == .scripted, let hand else { return rollout }
        if hand == .resumedOutsideClaude || originator == pluginOriginator { return .owner }
        return rollout
    }

    /// A Codex rollout's `session_meta`; nil when none of the three was read.
    static func codex(source: String?, threadSource: String?, originator: String?) -> SessionScope? {
        guard source != nil || threadSource != nil || originator != nil else { return nil }
        if let source, childCodexSources.contains(source) { return .subagent }
        if let threadSource, childCodexThreadSources.contains(threadSource) { return .subagent }
        if let source, scriptedCodexSources.contains(source) { return .scripted }
        if let originator, scriptedCodexOriginators.contains(originator) || originator.hasPrefix(scriptedCodexOriginatorPrefix) {
            return .scripted
        }
        return .owner
    }
}
