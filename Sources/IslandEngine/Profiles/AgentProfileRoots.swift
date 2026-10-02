import Foundation
import os

/// The transcript folders the patched process discovery recognises (Patches/active-agent-profiles.patch).
/// Upstream matches only `/.claude/projects/` and `/.codex/sessions/`, so a Codex session running in a
/// `~/.codex-<name>` home never matched its process and was ended after two polls. SessionEngine sets the
/// non-default roots whenever the profile list changes; with none set, discovery behaves exactly like upstream.
enum AgentProfileRoots {
    static let defaultClaudeFragment = "/.claude/projects/"
    static let defaultCodexFragment = "/.codex/sessions/"

    private struct Roots: Sendable {
        var claude: [String] = []
        var codex: [String] = []
    }

    private static let roots = OSAllocatedUnfairLock(initialState: Roots())

    /// Absolute profile folders without a trailing slash, non-default profiles only.
    static func update(claudeRoots: [String], codexRoots: [String]) {
        roots.withLock { $0 = Roots(claude: claudeRoots, codex: codexRoots) }
    }

    static func update(targets: [ProfileHookTarget]) {
        let extra = targets.filter { !$0.isDefaultFolder }
        update(claudeRoots: extra.filter { $0.provider == .claude }.map(\.folder),
               codexRoots: extra.filter { $0.provider == .codex }.map(\.folder))
    }

    static var claudeProjectFragments: [String] {
        [defaultClaudeFragment] + roots.withLock { $0.claude }.map { $0 + "/projects/" }
    }

    static var codexSessionFragments: [String] {
        [defaultCodexFragment] + roots.withLock { $0.codex }.map { $0 + "/sessions/" }
    }

    /// Keeps the first occurrence of each path, in order, so a path two fragments both match counts once.
    static func uniquePaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }
}
