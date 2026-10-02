import Foundation
import JuiceCore
import OpenIslandCore

/// Which profile a session runs in, worked out from its transcript path alone (no file is opened).
public struct SessionAccountTag: Equatable, Sendable {
    public let provider: Provider
    /// `ProfileHookTarget.id` of the matching profile.
    public let targetID: String
    public let folder: String
    public let accountID: String?
    public let alias: String
}

enum AccountResolver {
    static func provider(for tool: AgentTool) -> Provider? {
        switch tool {
        case .claudeCode: .claude
        case .codex: .codex
        default: nil
        }
    }

    /// The profile whose transcript folder holds `path`: `<root>/projects/` for Claude, `<root>/sessions/` or
    /// `<root>/archived_sessions/` for Codex. The whole root plus the marker is compared, so `~/.claude/projects/`
    /// never matches a path in `~/.claude-work/projects/`.
    static func target(forTranscript path: String, provider: Provider, targets: [ProfileHookTarget]) -> ProfileHookTarget? {
        let markers = provider == .claude ? ["/projects/"] : ["/sessions/", "/archived_sessions/"]
        let candidates = Set([path, ProfileHookTargets.normalized(path)])
        return targets.first { target in
            target.provider == provider && markers.contains { marker in
                candidates.contains { $0.hasPrefix(target.folder + marker) }
            }
        }
    }

    /// From the session's transcript path only; a session without one stays untagged (never guessed from its cwd).
    static func tag(transcriptPath: String?, tool: AgentTool, targets: [ProfileHookTarget]) -> SessionAccountTag? {
        guard let provider = provider(for: tool), let transcriptPath, !transcriptPath.isEmpty,
              let target = target(forTranscript: transcriptPath, provider: provider, targets: targets) else { return nil }
        return SessionAccountTag(provider: provider, targetID: target.id, folder: target.folder,
                                 accountID: target.accountID, alias: target.alias)
    }
}
