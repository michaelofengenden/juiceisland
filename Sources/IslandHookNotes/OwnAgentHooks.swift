import Foundation

/// Whether an agent's own config already carries Juice's hooks (P909). Devin CLI runs Claude Code's `settings.json`
/// hooks as well as its own, and Cursor can load them, so once its own config is connected every event would arrive
/// twice: the Claude-format copy then ends silent. Reads one small file, never follows more than the path, and says
/// false for anything it cannot read.
public enum OwnAgentHooks {
    /// The agents' own config files, from the home folder, for the agents that also run Claude's hooks.
    public static let configFiles: [AgentKind: String] = [
        .devin: ".config/devin/config.json",
        .cursor: ".cursor/hooks.json",
    ]

    /// Grok Build also runs Claude Code's `~/.claude/settings.json` hooks (P1111): Juice's own file in its hooks folder,
    /// either flavor's (`HookHome.ownFileStem`), says its own hooks are connected.
    public static let ownFiles: [AgentKind: [String]] = [
        .grok: [".grok/hooks/juice-island.json", ".grok/hooks/juice.json"],
    ]

    static let readLimit = 1 << 20

    public static func connected(_ kind: AgentKind, home: String) -> Bool {
        let files = configFiles[kind].map { [$0] } ?? ownFiles[kind] ?? []
        return files.contains { file in
            let url = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(file)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: readLimit) else { return false }
            return names(data, kind: kind)
        }
    }

    /// The text names Juice's helper with this agent's `--source`.
    static func names(_ data: Data, kind: AgentKind) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return text.contains(HookHome.helperName) && text.contains("--source \(kind.rawValue)")
    }
}
