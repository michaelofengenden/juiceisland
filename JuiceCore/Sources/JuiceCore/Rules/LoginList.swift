import Foundation

/// One login as Settings › Accounts lists it: the account, whichever folders hold it.
public struct LoginRow: Sendable, Equatable, Identifiable {
    /// The login's id (`LoginsStore.id`), also its battery's.
    public var id: String
    public var provider: Provider
    /// The email its CLI reported: the row's label.
    public var email: String
    /// Its organization's name, beside the email, when it is not the personal one (P580: `Login.orgName`).
    public var org: String?
    /// "Max", "Pro", "Plus" from its last reading; nil before one.
    public var plan: String?
    /// Its battery, named as the panel names it.
    public var battery: BatteryModel
    /// The login's Monitor switch.
    public var monitored: Bool
    /// The enabled folders signed in to it, the provider's default folder first, then in the account list's order.
    public var folders: [Account]

    /// "email · Organization", or the email alone (P580).
    public var title: String { org.map { email + " · " + $0 } ?? email }

    public init(id: String, provider: Provider, email: String, org: String? = nil, plan: String?, battery: BatteryModel, monitored: Bool,
                folders: [Account]) {
        self.id = id
        self.provider = provider
        self.email = email
        self.org = org
        self.plan = plan
        self.battery = battery
        self.monitored = monitored
        self.folders = folders
    }
}

/// An enabled folder no login row lists: signed out, or not asked yet.
public struct LooseFolder: Sendable, Equatable, Identifiable {
    public var folder: Account
    /// `.signedOut` or `.unknown`.
    public var state: FolderState

    public init(folder: Account, state: FolderState) {
        self.folder = folder
        self.state = state
    }

    public var id: String { folder.id }
}

/// One provider's part of Settings › Accounts.
public struct ProviderLogins: Sendable, Equatable, Identifiable {
    public var provider: Provider
    /// The logins an enabled folder holds, in the account list's order of their first folder. A login no folder holds
    /// is not listed: nothing can read it, and its record waits in `LoginsStore` for a folder to sign in to it again.
    public var logins: [LoginRow]
    /// In the account list's order, the default folder first.
    public var folders: [LooseFolder]

    public init(provider: Provider, logins: [LoginRow], folders: [LooseFolder]) {
        self.provider = provider
        self.logins = logins
        self.folders = folders
    }

    public var id: String { provider.rawValue }
}

/// Builds the per-login lists and the batteries the panel draws for them. Pure, like `PanelModelBuilder`.
public enum LoginList {
    public static func build(accounts: [Account], logins: [String: Login], folders: [String: FolderState], signingIn: Set<String>,
                             now: Date, home: String = NSHomeDirectory()) -> [ProviderLogins] {
        let enabled = accounts.filter(\.monitored)
        return Provider.allCases.compactMap { provider in
            let mine = enabled.filter { $0.provider == provider }
                .enumerated()
                .sorted { a, b in
                    let (da, db) = (CLIEnvironment.isDefaultFolder(a.element.folder, for: provider, home: home),
                                    CLIEnvironment.isDefaultFolder(b.element.folder, for: provider, home: home))
                    return da != db ? da : a.offset < b.offset
                }
                .map(\.element)
            var held: [String: [Account]] = [:]
            var order: [String] = []
            var loose: [LooseFolder] = []
            for folder in mine {
                switch folders[folder.id] ?? .unknown {
                case .signedIn(let id) where logins[id] != nil:
                    if held[id] == nil { order.append(id) }
                    held[id, default: []].append(folder)
                case .signedIn, .unknown:
                    loose.append(LooseFolder(folder: folder, state: .unknown))
                case .signedOut:
                    loose.append(LooseFolder(folder: folder, state: .signedOut))
                }
            }
            // The account list's order, by each login's first folder there (the default folder counts from its own place).
            let position = Dictionary(mine.map { ($0.id, enabled.firstIndex(of: $0) ?? 0) }, uniquingKeysWith: { a, _ in a })
            order.sort { (held[$0]?.compactMap { position[$0.id] }.min() ?? 0) < (held[$1]?.compactMap { position[$0.id] }.min() ?? 0) }
            let shown = order.compactMap { logins[$0] }
            guard !shown.isEmpty || !loose.isEmpty else { return nil }
            let names = self.names(shown, folders: held)
            var states: [String: AccountState] = [:]
            let records = Dictionary(shown.compactMap { login in login.record.map { (login.id, $0) } }, uniquingKeysWith: { a, _ in a })
            for login in shown {
                states[login.id] = PanelModelBuilder.state(of: login.id, records: records, signingIn: signingIn, provider: provider, now: now)
            }
            let next = shown.first { $0.monitored && (states[$0.id] ?? .unknown).isAvailable }?.id
            let rows = shown.map { login in
                let name = names[login.id] ?? login.email
                let state = states[login.id] ?? .unknown
                return LoginRow(id: login.id, provider: provider, email: login.email, org: login.orgName, plan: login.record?.planWord,
                                battery: BatteryModel(id: login.id, alias: name, state: state, isNext: login.id == next,
                                                      hoverLabel: PanelModelBuilder.batteryLabel(alias: name, state: state, record: login.record, now: now)),
                                monitored: login.monitored, folders: held[login.id] ?? [])
            }
            return ProviderLogins(provider: provider, logins: rows, folders: loose)
        }
    }

    /// The batteries the panel draws: every monitored login, in the lists' order.
    public static func panelEntries(_ lists: [ProviderLogins]) -> [PanelEntry] {
        lists.flatMap { list in
            list.logins.filter(\.monitored).map { PanelEntry(id: $0.id, alias: $0.battery.alias, provider: list.provider) }
        }
    }

    /// Whether any enabled folder is signed out: the sign-in badge, with no battery of its own.
    public static func needsSignIn(_ lists: [ProviderLogins]) -> Bool {
        lists.contains { $0.folders.contains { $0.state == .signedOut } }
    }

    /// A login's short name, for its battery: its email's local part, or the whole email where another email of the list
    /// has the same local part, then its organization's name when it is not the personal one ("sam · Research Lab",
    /// P580). Two logins of one email that show no organization's name (the personal one, and one whose name is not
    /// shown) take their plan words instead ("sam · Max", "sam · Team"), or, while those do not tell them apart, their
    /// first folders' names (P587).
    static func names(_ logins: [Login], folders held: [String: [Account]] = [:]) -> [String: String] {
        var emails: [String: Set<String>] = [:]
        for login in logins { emails[ProfileDiscovery.localPart(login.email), default: []].insert(login.email) }
        var words: [String: String] = [:]
        for group in Dictionary(grouping: logins, by: \.email).values {
            let unnamed = group.filter { $0.orgName == nil }
            guard unnamed.count > 1 else { continue }
            func distinct(_ all: [String?]) -> [String]? {
                let found = all.compactMap { $0 }
                return found.count == all.count && Set(found).count == found.count ? found : nil
            }
            let picked = distinct(unnamed.map { $0.record?.planWord }) ?? distinct(unnamed.map { held[$0.id]?.first?.alias })
            for (login, word) in zip(unnamed, picked ?? []) { words[login.id] = word }
        }
        return Dictionary(logins.map { login in
            let local = ProfileDiscovery.localPart(login.email)
            let base = (emails[local]?.count ?? 0) > 1 ? login.email : local
            return (login.id, ([base] + [login.orgName ?? words[login.id]].compactMap { $0 }).joined(separator: " · "))
        }, uniquingKeysWith: { a, _ in a })
    }
}
