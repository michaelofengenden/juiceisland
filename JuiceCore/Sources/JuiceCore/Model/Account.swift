import Foundation

/// A profile folder Juice monitors. The folder is the identity; the alias is what the user sees.
public struct Account: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var provider: Provider
    /// Expanded absolute path of the CLAUDE_CONFIG_DIR / CODEX_HOME folder.
    public var folder: String
    public var alias: String
    public var monitored: Bool
    /// Email the folder last belonged to, read from `.claude.json` or learned from a reading. Used to pre-fill sign-in and to detect a different identity.
    public var knownEmail: String?

    public init(provider: Provider, folder: String, alias: String, monitored: Bool = true, knownEmail: String? = nil) {
        self.provider = provider
        self.folder = folder
        self.alias = alias
        self.monitored = monitored
        self.knownEmail = knownEmail
    }

    public var id: String { Account.id(provider: provider, folder: folder) }

    public static func id(provider: Provider, folder: String) -> String {
        "\(provider.rawValue):\(folder)"
    }
}
