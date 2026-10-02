import Foundation

public struct DiscoveredProfile: Sendable, Equatable, Identifiable {
    public var provider: Provider
    public var folder: String
    public var suggestedAlias: String
    public var knownEmail: String?
    public var knownPlan: String?
    /// Codex only: `auth.json` exists, so the home is probably signed in. Claude logins live in the Keychain and are not checked.
    public var hasAuthFile: Bool

    public init(provider: Provider, folder: String, suggestedAlias: String, knownEmail: String? = nil,
                knownPlan: String? = nil, hasAuthFile: Bool = false) {
        self.provider = provider
        self.folder = folder
        self.suggestedAlias = suggestedAlias
        self.knownEmail = knownEmail
        self.knownPlan = knownPlan
        self.hasAuthFile = hasAuthFile
    }

    public var id: String { Account.id(provider: provider, folder: folder) }

    public func account() -> Account {
        Account(provider: provider, folder: folder, alias: suggestedAlias, monitored: true, knownEmail: knownEmail)
    }
}

/// Profile folders by name: `~/.claude` and `~/.claude-*`, `~/.codex` and `~/.codex-*`. Juice Island finds them with
/// `ProfileFolderDiscovery` (IslandEngine), which only asks which files exist. Juice's own discovery, which decoded each
/// Claude folder's `.claude.json` for an email and an organisation, is gone: no login file is ever opened (P66), and who
/// is signed in comes only from the CLIs.
public enum ProfileDiscovery {
    /// Folders that have a `.claude.json` but are not profiles, in this build's flavor. Public so the island's stat-only
    /// discovery skips them too.
    public static var ignoredClaudePrefixes: [String] { ignoredClaudePrefixes(for: .current) }

    /// The private app's are benchmark folders on its owner's Mac; the public flavor skips no Claude folder by name, so a
    /// stranger's `~/.claude-db…` is an ordinary profile there (P858).
    public static func ignoredClaudePrefixes(for flavor: AppFlavor) -> [String] {
        flavor.isPublic ? [] : [".claude-db", ".claude-samplebench"]
    }

    static func localPart(_ email: String) -> String {
        email.split(separator: "@").first.map(String.init) ?? email
    }
}
