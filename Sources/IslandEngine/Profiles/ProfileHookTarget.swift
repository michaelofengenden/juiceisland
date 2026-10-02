import Foundation
import JuiceCore

/// One profile folder the island can hook: every Juice account plus every profile discovery finds.
public struct ProfileHookTarget: Identifiable, Hashable, Sendable {
    public let provider: Provider
    /// Standardized, symlink-resolved absolute path, no trailing slash.
    public let folder: String
    public let alias: String
    public let isDefaultFolder: Bool
    /// The Juice account this folder belongs to, when it is one (`Account.id`, as stored in accounts.json).
    public let accountID: String?
    public let isMonitored: Bool

    public var id: String { Account.id(provider: provider, folder: folder) }

    public init(provider: Provider, folder: String, alias: String, isDefaultFolder: Bool, accountID: String?, isMonitored: Bool) {
        self.provider = provider
        self.folder = folder
        self.alias = alias
        self.isDefaultFolder = isDefaultFolder
        self.accountID = accountID
        self.isMonitored = isMonitored
    }
}

public enum ProfileHookTargets {
    /// Juice accounts and discovered profiles, one entry per folder. Claude first, then Codex; inside each
    /// provider the default folder first, then the accounts in the user's order, then discovered-only folders.
    public static func make(accounts: [Account], discovered: [DiscoveredProfile],
                            home: String = NSHomeDirectory()) -> [ProfileHookTarget] {
        var result: [ProfileHookTarget] = []
        for provider in Provider.allCases {
            let defaultFolder = normalized(home + "/" + provider.defaultFolderName)
            var seen: Set<String> = []
            var group: [ProfileHookTarget] = []
            for account in accounts where account.provider == provider {
                let folder = normalized(account.folder)
                guard seen.insert(folder).inserted else { continue }
                group.append(ProfileHookTarget(provider: provider, folder: folder, alias: account.alias,
                                               isDefaultFolder: folder == defaultFolder, accountID: account.id,
                                               isMonitored: account.monitored))
            }
            for profile in discovered where profile.provider == provider {
                let folder = normalized(profile.folder)
                guard seen.insert(folder).inserted else { continue }
                group.append(ProfileHookTarget(provider: provider, folder: folder, alias: profile.suggestedAlias,
                                               isDefaultFolder: folder == defaultFolder, accountID: nil,
                                               isMonitored: false))
            }
            result += group.filter(\.isDefaultFolder) + group.filter { !$0.isDefaultFolder }
        }
        return result
    }

    public static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
