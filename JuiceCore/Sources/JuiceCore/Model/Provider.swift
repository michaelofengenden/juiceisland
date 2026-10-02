import Foundation

public enum Provider: String, Codable, Sendable, CaseIterable, Hashable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// The environment variable that points the CLI at a profile folder.
    public var folderEnvironmentKey: String {
        switch self {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        }
    }

    /// The provider's default profile folder name, directly under the user's home directory.
    public var defaultFolderName: String {
        switch self {
        case .claude: ".claude"
        case .codex: ".codex"
        }
    }

    /// Spec §8.2: a reading older than this is stale.
    public var freshnessLimit: TimeInterval {
        switch self {
        case .claude: 20 * 60
        case .codex: 2 * 60
        }
    }
}
