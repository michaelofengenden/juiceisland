import Foundation
import JuiceCore

/// The profile folders in a home folder, found by name and by which files exist, never by what a file says: it only
/// asks whether files exist (a stat) and never opens one (spec §3.5, §5.1). It is the only discovery: Setup, drift, the
/// live engine's tags and Settings › Accounts all use it, and who is signed in comes only from the CLIs (P66).
///
/// A Claude profile is `~/.claude` or `~/.claude-*` holding a `.claude.json`; a Codex profile is `~/.codex` or
/// `~/.codex-*` holding a `config.toml` or the Codex login file. A folder with neither is not a profile, and Setup
/// never lists it (spec §8 decision 6). The alias is the folder's suffix, or the provider's name for the default.
public enum ProfileFolderDiscovery {
    public static func discover(home: String = NSHomeDirectory(), fileManager: FileManager = .default,
                                flavor: AppFlavor = .current) -> [DiscoveredProfile] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: home) else { return [] }
        var found: [DiscoveredProfile] = []
        for name in names.sorted() {
            let folder = home + "/" + name
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if let provider = provider(ofFolderNamed: name, flavor: flavor), isProfile(folder, provider: provider, fileManager: fileManager) {
                found.append(DiscoveredProfile(provider: provider, folder: folder, suggestedAlias: alias(forFolderNamed: name, provider: provider),
                                               hasAuthFile: provider == .codex && hasCodexLogin(folder, fileManager: fileManager)))
            }
        }
        return found
    }

    static func provider(ofFolderNamed name: String, flavor: AppFlavor = .current) -> Provider? {
        for provider in Provider.allCases where name == provider.defaultFolderName || name.hasPrefix(provider.defaultFolderName + "-") {
            if provider == .claude, ProfileDiscovery.ignoredClaudePrefixes(for: flavor).contains(where: name.hasPrefix) { return nil }
            return provider
        }
        return nil
    }

    static func alias(forFolderNamed name: String, provider: Provider) -> String {
        name == provider.defaultFolderName ? provider.displayName : String(name.dropFirst(provider.defaultFolderName.count + 1))
    }

    static func isProfile(_ folder: String, provider: Provider, fileManager: FileManager) -> Bool {
        switch provider {
        case .claude: fileManager.fileExists(atPath: folder + "/.claude.json")
        case .codex: fileManager.fileExists(atPath: folder + "/config.toml") || hasCodexLogin(folder, fileManager: fileManager)
        }
    }

    /// Existence only: the file is never opened.
    static func hasCodexLogin(_ folder: String, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: folder + "/auth.json")
    }
}
