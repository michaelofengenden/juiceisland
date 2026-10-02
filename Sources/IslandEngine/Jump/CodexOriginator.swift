import Foundation

/// Which app a Codex thread lives in, from its rollout's first `session_meta.originator` (P660).
///
/// The names, as Codex writes them:
/// - the Codex app, now the ChatGPT app (`/Applications/ChatGPT.app`, bundle id `com.openai.codex`, its URL scheme
///   `codex`): `Codex Desktop` (the `CODEX_INTERNAL_ORIGINATOR_OVERRIDE` its app-server runs with), `codex_desktop` (its
///   `clientInfo.name`); a Work thread's is the thread's service name (openai/codex `core/src/thread_manager.rs`,
///   `originator_from_service_name`): `codex_work_desktop`, `codex_work_web`, `codex_work_mobile`, `codex_work_cca`,
///   `chatgpt_cca`; and ChatGPT's own chat originator `codex_chatgpt_desktop` (`login/src/auth/default_client.rs`,
///   `is_first_party_chat_originator`);
/// - a terminal: the CLI's `codex_cli_rs` (`DEFAULT_ORIGINATOR`) and `codex-tui`, `codex exec`'s `codex_exec`, the SDKs'
///   `codex_sdk…` and the codex plugin for Claude Code's `Claude Code`;
/// - the IDE extension: `codex_vscode`.
///
/// `session_meta.source` cannot tell them apart: every app-server client's thread says `vscode`, the Codex app's too.
public enum CodexOriginator {
    public enum Host: Equatable, Sendable {
        /// The Codex app: its thread opens by `codex://threads/<id>`.
        case codexApp
        case terminal
        case ide
    }

    static let appNames: Set<String> = ["codex desktop", "codex_desktop", "codex_work_desktop", "codex_work_web", "codex_work_mobile",
                                        "codex_work_cca", "chatgpt_cca", "codex_chatgpt_desktop"]
    static let terminalNames: Set<String> = ["codex_cli_rs", "codex-tui", "codex_exec",
                                             SessionScopeRules.pluginOriginator.lowercased()]
    static let ideNames: Set<String> = ["codex_vscode"]

    /// The host a known originator names; nil for one not known (or none). Codex matches service names in any case.
    public static func host(of originator: String?) -> Host? {
        guard let name = originator?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty else { return nil }
        if appNames.contains(name) { return .codexApp }
        if terminalNames.contains(name) || name.hasPrefix(SessionScopeRules.scriptedCodexOriginatorPrefix) { return .terminal }
        if ideNames.contains(name) { return .ide }
        return nil
    }

    /// Whether the rollout scanner takes the thread for the Codex app's (P212, P214): a known app originator, or an
    /// unknown one that names the desktop, ChatGPT or a Work surface, as a new build of the app may.
    static func isAppThread(_ originator: String?) -> Bool {
        switch host(of: originator) {
        case .codexApp: return true
        case .terminal, .ide: return false
        case nil:
            guard let name = originator?.lowercased() else { return false }
            return name.contains("desktop") || name.contains("chatgpt") || name.hasPrefix("codex_work")
        }
    }
}
