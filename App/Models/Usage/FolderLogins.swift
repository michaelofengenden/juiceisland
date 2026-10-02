import Foundation
import JuiceCore

/// Accounts for the usage models that ask no CLI themselves (the demo, and Juice's readings in a dev build): a folder's
/// account is the email its last reading names, which a CLI reported, and the organization it names (P580: Juice
/// Island's readings name one for a Claude login in an organization), so folders holding one account share its row and
/// its battery, as `LoginList` gives the release build. Only the demo's fixtures fall back on a folder's known email
/// (`knownEmails`): for a real folder that comes from discovery, not from a CLI. A folder whose last outcome is a sign-in
/// failure is signed out; one with no email is not placed. An account is monitored while any of its folders is; a
/// folder switched off stays listed, under its dimmed account.
enum FolderLogins {
    struct Built: Equatable {
        var lists: [ProviderLogins]
        /// Each account's record by login id: the newest reading of its folders, and the stricter wait.
        var records: [String: AccountRecord]
    }

    static func build(accounts: [Account], records: [String: AccountRecord], now: Date, home: String = NSHomeDirectory(),
                      knownEmails: Bool = false) -> Built {
        var logins: [String: Login] = [:]
        var folders: [String: FolderState] = [:]
        var held: [String: [AccountRecord]] = [:]
        for account in accounts {
            let record = records[account.id]
            if let record, LoginsStore.isSignedOut(record) {
                folders[account.id] = .signedOut
                continue
            }
            guard let who = record?.lastGood?.login ?? (knownEmails ? account.knownEmail.map { LoginIdentity(email: $0) } : nil) else { continue }
            let id = LoginsStore.id(provider: account.provider, who)
            var login = logins[id] ?? Login(provider: account.provider, email: who.email, org: who.org, orgName: who.orgName, monitored: false)
            login.monitored = login.monitored || account.monitored
            logins[id] = login
            folders[account.id] = .signedIn(login: id)
            if let record { held[id, default: []].append(record) }
        }
        for (id, list) in held { logins[id]?.record = LoginsStore.merge(list, as: id, now: now) }
        let listed = accounts.map { account in
            var folder = account
            folder.monitored = true
            return folder
        }
        let lists = LoginList.build(accounts: listed, logins: logins, folders: folders, signingIn: [], now: now, home: home)
        return Built(lists: lists, records: logins.compactMapValues(\.record))
    }

    /// The batteries for `built`: one per monitored account a folder holds; a signed-out folder raises the sign-in badge.
    static func panel(_ built: Built, money: [MoneyRowModel], now: Date, history: UsageHistory = .empty) -> PanelModel {
        PanelModelBuilder.build(entries: LoginList.panelEntries(built.lists), records: built.records, signingIn: [],
                                attention: LoginList.needsSignIn(built.lists), money: money, now: now, history: history)
    }
}
