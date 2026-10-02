import Foundation
import Observation

/// One login as its CLI reported it (Codex `account/read`, `claude auth status`): the account Juice Island reads and
/// shows, whichever profile folders hold it. Two folders signed in to the same account are one login, read once; one
/// email signed in to two Claude organizations (a personal plan and a Team or Enterprise one, P580) is two logins.
public struct Login: Codable, Sendable, Equatable, Identifiable {
    public var provider: Provider
    /// Trimmed and lowercased, as the key is made from it.
    public var email: String
    /// The organization's key (`LoginOrganization.key`: a hash of its id, never the id), when the CLI named one (Claude's
    /// `claude auth status`); nil for a Codex login, and for a Claude login none named yet, whose id is its email's alone.
    public var org: String?
    /// The organization's name as it may be shown (`LoginOrganization.shownName`): nil for the personal one, which is
    /// named after the email, and when none was named.
    public var orgName: String?
    /// The kind of plan its CLI last named with it (P586): personal or an organization's; nil before one did.
    public var kind: LoginIdentity.PlanKind?
    /// The Monitor switch: a login switched off is read through none of its folders.
    public var monitored: Bool
    /// Its reads, wherever they were made: the last good reading, the last failure, the waits they set. Kept while no
    /// folder holds the login, so it comes back with its waits when one signs in to it again.
    public var record: AccountRecord?

    public init(provider: Provider, email: String, org: String? = nil, orgName: String? = nil, kind: LoginIdentity.PlanKind? = nil,
                monitored: Bool = true, record: AccountRecord? = nil) {
        self.provider = provider
        self.email = LoginsStore.normalized(email)
        self.org = org
        self.orgName = orgName
        self.kind = kind
        self.monitored = monitored
        self.record = record
    }

    public var id: String { LoginsStore.id(provider: provider, email: email, org: org) }

    /// Who the login is, as its CLI reported it.
    public var identity: LoginIdentity { LoginIdentity(email: email, org: org, orgName: orgName, kind: planKind) }

    /// Its plan's kind: as its CLI last named it, else as its last reading names it.
    var planKind: LoginIdentity.PlanKind? { kind ?? LoginIdentity.PlanKind(plan: record?.lastGood?.plan) }
}

/// What a profile folder holds, as its CLI last answered.
public enum FolderState: Codable, Sendable, Equatable, Hashable {
    /// Signed in to the login with this id.
    case signedIn(login: String)
    case signedOut
    /// Not asked yet: a folder added since, or one kept from before logins were tracked.
    case unknown
}

/// Where a folder's answer put it.
public struct Placement: Sendable, Equatable {
    /// The login the folder holds now.
    public var login: String
    /// What it held before.
    public var previous: FolderState
    /// The login was new to Juice Island.
    public var isNew: Bool
    /// The id the login had until this answer named its organization (P580): its record, Monitor switch and history
    /// go by `login` from now on. Nil when nothing was renamed.
    public var renamed: String?

    public init(login: String, previous: FolderState, isNew: Bool, renamed: String? = nil) {
        self.login = login
        self.previous = previous
        self.isNew = isNew
        self.renamed = renamed
    }

    /// The folder holds another login than before, or held none.
    public var moved: Bool { previous != .signedIn(login: login) }
}

/// `logins.json`, next to accounts.json (P29, P80, P93): every login Juice Island has seen, each with its own record and
/// Monitor switch, and which login each profile folder holds. The owner signs folders out and into other accounts
/// (`codex logout` and `codex login` in `~/.codex`, `/login` in a Claude folder), and signs one account into several
/// folders, so a reading, a wait and a name belong to a login, never to a folder: a login is read once per floor window,
/// through one of its folders, and a folder that changes login joins the other one.
///
/// A login's key is a hash of the email its CLI reported (`key(for:)`), its id the provider and that key, and the key of
/// the organization when the CLI names one (P580: `claude auth status`'s `orgId`, hashed the same way). Identity comes
/// only from what the CLIs report. A login kept from before organizations were named has its email's id alone, and
/// keeps it until a folder holding it names its organization: then it takes that organization's id with everything it
/// had (`place`). readings.json stays standalone Juice's per-folder file: each folder's record there is
/// its login's (`projection`), and what standalone Juice or an older Juice Island wrote there is folded back in (`fold`).
/// Standalone Juice never reads or writes this file.
@MainActor
@Observable
public final class LoginsStore {
    struct File: Codable, Equatable, Sendable {
        var version: Int
        var logins: [String: Login]
        var folders: [String: FolderState]
    }

    private struct Version: Decodable {
        var version: Int
    }

    private struct SalvagedFile: Decodable {
        var logins: LossyDictionary<SalvagedLogin>
        var folders: LossyDictionary<FolderState>
    }

    /// logins.json as P80 first wrote it (version 1): per folder, the login it held and what it kept of the others.
    private struct LegacyFile: Codable {
        var version: Int
        var folders: [String: LegacyFolder]
    }

    struct LegacyFolder: Codable {
        var current: String?
        var logins: [String: LegacyLogin]
    }

    struct LegacyLogin: Codable {
        var email: String
        var alias: String
        var parked: AccountRecord?
    }

    public let fileURL: URL
    /// Writes off the main thread when set; `save()` writes at once when nil.
    @ObservationIgnored public var writer: StoreWriter?
    /// What the file holds as far as this store knows; a save of the same is skipped.
    @ObservationIgnored private var saved: File?
    /// By login id.
    public private(set) var logins: [String: Login] = [:]
    /// By folder id (`Account.id`); a folder not here has not been asked yet.
    public private(set) var folders: [String: FolderState] = [:]
    /// A version 1 file, until `fold` takes it in.
    private var legacy: [String: LegacyFolder]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Reads the file: whole, or login by login and folder by folder when it does not read whole (a login or a folder
    /// this build cannot read costs only itself, and a login's record is read as readings.json's are,
    /// `SalvagedRecord`). A version 1 file waits for `fold`. A missing or unreadable file leaves everything as it is.
    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let version = (try? JSONDecoder.juice.decode(Version.self, from: data))?.version
        if let version, version < 2, let file = try? JSONDecoder.juice.decode(LegacyFile.self, from: data) {
            legacy = file.folders
            saved = nil
            return
        }
        if let file = try? JSONDecoder.juice.decode(File.self, from: data), file.version >= 2 {
            logins = file.logins
            folders = file.folders
            legacy = nil
            saved = file
            return
        }
        saved = nil
        let salvaged = version.map { $0 >= 2 } == true ? try? JSONDecoder.juice.decode(SalvagedFile.self, from: data) : nil
        if let salvaged {
            logins = salvaged.logins.values.mapValues(\.login)
            folders = salvaged.folders.values
            legacy = nil
        }
        StoreFile.noteLoss(fileURL, data: data, lost: (salvaged?.logins.lost ?? 0) + (salvaged?.folders.lost ?? 0),
                           unreadable: salvaged == nil)
    }

    /// Written only when it changed, through `writer` when one is set, never over a file this build cannot read whole
    /// without keeping it first (`StoreFile`; a version 1 file reads whole: `fold` took it in).
    public func save() throws {
        let file = File(version: 2, logins: logins, folders: folders)
        if file == saved, FileManager.default.fileExists(atPath: fileURL.path) { return }
        if let writer {
            writer.write(fileURL, isReadable: Self.isReadable) { try JSONEncoder.juice.encode(file) }
        } else {
            try StoreFile.write(JSONEncoder.juice.encode(file), to: fileURL, isReadable: Self.isReadable)
        }
        saved = file
    }

    /// The file reads whole: a version 2 file, or a version 1 file `fold` takes in.
    nonisolated static func isReadable(_ data: Data) -> Bool {
        if let file = try? JSONDecoder.juice.decode(File.self, from: data), file.version >= 2 { return true }
        return (try? JSONDecoder.juice.decode(LegacyFile.self, from: data)) != nil
    }

    // MARK: Keys

    /// A login's key: 16 hex digits of the 64-bit FNV-1a hash of its trimmed, lowercased email, the same on every run and
    /// every Mac. It hides nothing: the email is kept beside it (`Login.email`), as accounts.json and readings.json keep
    /// theirs.
    public nonisolated static func key(for email: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized(email).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// A login's id, `codex#<key>`, or `claude#<key>@<org key>` when its CLI named its organization (P580): never a
    /// folder's (`codex:<path>`). `org` is already a key (`LoginOrganization.key`).
    public nonisolated static func id(provider: Provider, email: String, org: String? = nil) -> String {
        let id = "\(provider.rawValue)#\(key(for: email))"
        return org.map { id + "@" + $0 } ?? id
    }

    public nonisolated static func id(provider: Provider, _ who: LoginIdentity) -> String {
        id(provider: provider, email: who.email, org: who.org)
    }

    public nonisolated static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Reading

    public func state(of folderID: String) -> FolderState { folders[folderID] ?? .unknown }

    /// The login a folder holds, if it is signed in.
    public func login(holding folderID: String) -> Login? {
        guard case .signedIn(let id) = state(of: folderID) else { return nil }
        return logins[id]
    }

    /// The enabled folders signed in to the login, in `accounts`' order.
    public func folders(of loginID: String, in accounts: [Account]) -> [Account] {
        accounts.filter { $0.monitored && folders[$0.id] == .signedIn(login: loginID) }
    }

    // MARK: Changes

    /// The folder's CLI answered that it is signed in to `email` (no organization named).
    @discardableResult
    public func place(_ email: String, in folder: Account, record: AccountRecord? = nil, now: Date) -> Placement {
        place(LoginIdentity(email: email), in: folder, record: record, now: now)
    }

    /// The folder's CLI answered that it is signed in to `who`. The folder joins that login, which is created if Juice
    /// Island had not seen it. `record` is the folder's own record in readings.json: for a folder not placed before, it
    /// was that login's (a store from before logins were keyed by account, or standalone Juice's read), unless its reading
    /// names another login, and is folded into it.
    ///
    /// An answer that names an organization goes with the email's login from before organizations were named (P580), so
    /// nothing a login had is lost when its id gains the organization: its record (reading, waits, 429 pause, backoff, No
    /// plan streak), its Monitor switch, and every folder that held it, which is taken to be in the same organization
    /// until it answers otherwise. The old login is the organization's when its plan is of the answer's kind, a personal
    /// plan's or an organization's, or either is not known (P586), and this folder held it, or no folder holds it and no
    /// other organization of the email seen may be its (it is then this one's for all anyone knows).
    /// It takes the organization's id, or is merged into the organization's login when another folder named that first
    /// (P585: the newest reading, the stricter wait, Monitor off when either was off). Otherwise the folder starts a
    /// login of its own, and the old one stays with the folders that hold it; a login of the email started so keeps the
    /// old one's wait while it lasts (P586), since until the old one's folders answer, either may be the other.
    @discardableResult
    public func place(_ who: LoginIdentity, in folder: Account, record: AccountRecord? = nil, now: Date) -> Placement {
        let id = Self.id(provider: folder.provider, who)
        let previous = state(of: folder.id)
        let plain = Self.id(provider: folder.provider, email: who.email)
        var renamed: String?
        if who.org != nil, let old = logins[plain], takes(old, id: id, who: who, previous: previous) {
            if logins[id] == nil { rehome(plain, as: id, who: who) } else { join(plain, to: id, who: who, now: now) }
            renamed = plain
        }
        let isNew = logins[id] == nil
        var login = logins[id] ?? Login(provider: folder.provider, email: who.email, org: who.org, orgName: who.orgName)
        // An organization renamed since: the name its CLI gives now.
        if who.org != nil, login.orgName != who.orgName { login.orgName = who.orgName }
        if let kind = who.kind { login.kind = kind }
        if isNew, who.org != nil, let wait = Self.pendingWait(logins[plain]?.record, provider: folder.provider, now: now) {
            login.record = Self.merge([login.record, wait].compactMap { $0 }, as: id, now: now)
        }
        if previous == .unknown, let record, record.lastGood.map({ Self.names($0, who) }) ?? true {
            login.record = Self.merge([login.record, record].compactMap { $0 }, as: id, now: now)
        }
        logins[id] = login
        folders[folder.id] = .signedIn(login: id)
        return Placement(login: id, previous: previous, isNew: isNew, renamed: renamed)
    }

    /// The email's old login `old` goes with the answer `who` (`place`).
    private func takes(_ old: Login, id: String, who: LoginIdentity, previous: FolderState) -> Bool {
        guard Self.mayBe(old, who.kind) else { return false }
        if previous == .signedIn(login: old.id) { return true }
        if folders.values.contains(.signedIn(login: old.id)) { return false }
        return !logins.values.contains { other in
            other.provider == old.provider && other.email == old.email && other.org != nil && other.id != id && Self.mayBe(old, other.planKind)
        }
    }

    /// The old login may be in an organization whose plan is of `kind`: its own plan (as its CLI last named it, else its
    /// last reading) is of that kind, or either is not known.
    nonisolated static func mayBe(_ old: Login, _ kind: LoginIdentity.PlanKind?) -> Bool {
        guard let kind, let was = old.planKind else { return true }
        return was == kind
    }

    /// The login `plain` takes the id `id` and the organization `who` names, with everything it had; the folders that
    /// held it hold it under its new id.
    private func rehome(_ plain: String, as id: String, who: LoginIdentity) {
        guard var login = logins.removeValue(forKey: plain) else { return }
        login.org = who.org
        login.orgName = who.orgName
        login.record?.lastGood?.accountID = id
        login.record?.lastGood?.org = who.org
        login.record?.lastGood?.orgName = who.orgName
        logins[id] = login
        for (folder, state) in folders where state == .signedIn(login: plain) { folders[folder] = .signedIn(login: id) }
    }

    /// The login `plain` is merged into `id`, the organization's login another folder named first (P585): the newest
    /// reading and the stricter wait (`merge`), Monitor off when either was off; the folders that held it hold `id`.
    private func join(_ plain: String, to id: String, who: LoginIdentity, now: Date) {
        guard let old = logins.removeValue(forKey: plain), var login = logins[id] else { return }
        login.record = Self.merge([login.record, old.record].compactMap { $0 }, as: id, now: now)
        login.record?.lastGood?.org = who.org
        login.record?.lastGood?.orgName = who.orgName
        login.monitored = login.monitored && old.monitored
        logins[id] = login
        for (folder, state) in folders where state == .signedIn(login: plain) { folders[folder] = .signedIn(login: id) }
    }

    /// The record's wait, alone, while it lasts (P586): a 429 pause or a read backoff that is its latest outcome (a 429
    /// also when a reading came after it), until `RefreshPolicy.delay` from it has passed. A sign-in failure is its
    /// folder's, a missing CLI is looked for again, and a plan's answer is its own login's: none is handed on.
    nonisolated static func pendingWait(_ record: AccountRecord?, provider: Provider, now: Date,
                                        policy: RefreshPolicy = RefreshPolicy()) -> AccountRecord? {
        guard let record, let error = record.lastError, let at = record.lastErrorAt else { return nil }
        let isPause = if case .rateLimited = error { true } else { false }
        switch error {
        case .signInRequired, .cliNotFound, .cliUpdateNeeded: return nil
        case .incomplete where error.saysNoPlanLimits: return nil
        default: break
        }
        guard isPause || at >= (record.lastGood?.readAt ?? .distantPast) || at == record.lastAttemptAt else { return nil }
        let failures = max(record.consecutiveFailures, 1)
        guard at.addingTimeInterval(policy.delay(after: error, consecutiveFailures: failures, provider: provider)) > now else { return nil }
        return AccountRecord(lastError: error, lastErrorAt: at, lastAttemptAt: at, consecutiveFailures: failures)
    }

    /// The reading names the login `who`: its email, and its organization when it names one.
    nonisolated static func names(_ reading: AccountReading, _ who: LoginIdentity) -> Bool {
        guard let email = reading.email else { return true }
        return normalized(email) == normalized(who.email) && (reading.org == nil || reading.org == who.org)
    }

    /// The folder's CLI answered that nobody is signed in. Returns what it held before.
    @discardableResult
    public func signOut(_ folderID: String) -> FolderState {
        let previous = state(of: folderID)
        folders[folderID] = .signedOut
        return previous
    }

    /// The folder left the account list: it holds nothing Juice Island knows about.
    public func forget(folder folderID: String) { folders[folderID] = nil }

    public func setMonitored(_ loginID: String, _ monitored: Bool) { logins[loginID]?.monitored = monitored }

    /// A read of the login, through whichever folder: its record moves on as readings.json's does
    /// (`AccountRecord.take`: a reading whose read began before the newest one's never replaces it, P731). A reading that
    /// names no login (Claude's, unless its read asked) is given the login's email and organization, so readings.json
    /// names its login too: its folder's login file has not changed since the CLI named that login
    /// (`ClaudeIdentityWatch` asks before any read after a change).
    public func apply(_ result: Result<AccountReading, ReadError>, to loginID: String, at now: Date) {
        guard var login = logins[loginID] else { return }
        var record = login.record ?? AccountRecord()
        var result = result
        if case .success(var reading) = result {
            reading.accountID = loginID
            if reading.email == nil { reading.email = login.email }
            if reading.org == nil { reading.org = login.org }
            if reading.org == login.org { reading.orgName = login.orgName }
            result = .success(reading)
        }
        record.take(result, at: now)
        login.record = record
        logins[loginID] = login
    }

    // MARK: readings.json

    /// Takes in what readings.json holds for the account list's folders: at the first launch after logins were keyed by
    /// account, and whenever standalone Juice wrote it. A folder's record goes to the login its reading names, else to the
    /// login the folder holds; one whose folder was not asked yet and names no login waits for the folder's first answer
    /// (`place`). A reading that names the email of the login its folder holds is that login's, whatever organization it
    /// is in: standalone Juice's readings name no organization (P580). A folder never asked whose record says signed out
    /// is signed out. A version 1 logins.json is taken in first: each folder's current login, and every login it held
    /// before with the record it kept.
    public func fold(_ records: [String: AccountRecord], accounts: [Account], now: Date) {
        if let legacy {
            takeLegacy(legacy, records: records, now: now)
            self.legacy = nil
        }
        for account in accounts {
            guard let record = records[account.id] else { continue }
            if folders[account.id] == nil, Self.isSignedOut(record) {
                folders[account.id] = .signedOut
                continue
            }
            let held = login(holding: account.id)
            var named: String?
            if let reading = record.lastGood, let who = reading.login {
                named = held.map { Self.names(reading, $0.identity) } == true ? held?.id
                    : Self.id(provider: account.provider, who)
            }
            guard let owner = named ?? held?.id else { continue }
            if logins[owner] == nil, let who = record.lastGood?.login {
                logins[owner] = Login(provider: account.provider, email: who.email, org: who.org, orgName: who.orgName)
            }
            guard var login = logins[owner] else { continue }
            let merged = Self.merge([login.record, record].compactMap { $0 }, as: owner, now: now)
            if merged != login.record {
                login.record = merged
                logins[owner] = login
            }
        }
    }

    private func takeLegacy(_ legacy: [String: LegacyFolder], records: [String: AccountRecord], now: Date) {
        for (folderID, folder) in legacy {
            guard let provider = Self.provider(ofFolder: folderID) else { continue }
            for stored in folder.logins.values {
                let id = Self.id(provider: provider, email: stored.email)
                var login = logins[id] ?? Login(provider: provider, email: stored.email)
                if let parked = stored.parked {
                    login.record = Self.merge([login.record, parked].compactMap { $0 }, as: id, now: now)
                }
                logins[id] = login
            }
            guard folders[folderID] == nil else { continue }
            if let current = folder.current, let stored = folder.logins[current] {
                folders[folderID] = .signedIn(login: Self.id(provider: provider, email: stored.email))
            } else if let record = records[folderID], Self.isSignedOut(record) {
                folders[folderID] = .signedOut
            }
        }
    }

    /// readings.json for the account list's folders, as standalone Juice and dev builds read it: an enabled folder signed
    /// in has its login's record, a signed-out one its sign-in failure (the one it has, or one dated `now`), and every
    /// other folder keeps what `current` holds for it.
    public func projection(of accounts: [Account], onto current: [String: AccountRecord], now: Date) -> [String: AccountRecord] {
        var records = current
        for account in accounts where account.monitored {
            switch state(of: account.id) {
            case .signedIn(let id):
                var record = logins[id]?.record
                record?.lastGood?.accountID = account.id
                if let login = logins[id], record?.lastGood?.email.map(Self.normalized) == login.email {
                    record?.lastGood?.org = login.org
                    record?.lastGood?.orgName = login.orgName
                }
                records[account.id] = record
            case .signedOut:
                if let kept = current[account.id], Self.isSignedOut(kept) { continue }
                records[account.id] = AccountRecord(lastError: .signInRequired, lastErrorAt: now, lastAttemptAt: now, consecutiveFailures: 1)
            case .unknown:
                continue
            }
        }
        return records
    }

    // MARK: Records

    /// One login's records from several places (two folders held it, standalone Juice read it through a folder): the
    /// newest reading, and the stricter wait. A sign-in failure is its folder's, not the login's, and is left out. A
    /// failure counts when it came last in its own record (the scheduler's rule); one from before the newest reading still
    /// counts only as a 429 pause that has not ended, and then it is dated the last attempt, so a relaunch restores it,
    /// here and in standalone Juice, whose scheduler reads readings.json by the same rule. The scheduler still counts
    /// Refresh all's floor from the newest reading (`RefreshScheduler.seed(reading:)`).
    public nonisolated static func merge(_ records: [AccountRecord], as loginID: String, now: Date,
                                         policy: RefreshPolicy = RefreshPolicy()) -> AccountRecord? {
        let kept = records.compactMap(withoutSignIn)
        guard !kept.isEmpty else { return nil }
        let provider = Provider.allCases.first { loginID.hasPrefix($0.rawValue) } ?? .claude
        var newest = kept.compactMap(\.lastGood).max { $0.readAt < $1.readAt }
        newest?.accountID = loginID
        let newestAt = newest?.readAt ?? .distantPast
        var merged = AccountRecord(lastGood: newest, lastAttemptAt: kept.compactMap(lastUsed).max())
        // A No plan streak goes on unless a good read came after it (P360): the latest one still running.
        merged.noPlan = kept.compactMap(\.noPlan).filter { $0.last >= newestAt }.max { $0.last < $1.last }
        let waits = kept.compactMap { record -> (record: AccountRecord, at: Date, end: Date)? in
            guard let error = record.lastError, let at = record.lastErrorAt,
                  at >= (record.lastGood?.readAt ?? .distantPast) || at == record.lastAttemptAt else { return nil }
            var end = at.addingTimeInterval(policy.delay(after: error, consecutiveFailures: max(record.consecutiveFailures, 1), provider: provider))
            if let streak = record.noPlan, streak.holds { end = max(end, streak.last.addingTimeInterval(NoPlanStreak.interval)) }
            return (record, at, end)
        }
        let counted = waits.filter { wait in
            if wait.at >= newestAt { return true }
            if case .rateLimited? = wait.record.lastError { return wait.end > now }
            return false
        }
        if let strictest = counted.max(by: { $0.end < $1.end }) {
            merged.lastError = strictest.record.lastError
            merged.lastErrorAt = strictest.at
            merged.consecutiveFailures = strictest.record.consecutiveFailures
            if strictest.at < newestAt { merged.lastAttemptAt = strictest.at }
        }
        return merged
    }

    /// The record without a sign-in failure, which is its folder's; nil when nothing is left.
    nonisolated static func withoutSignIn(_ record: AccountRecord) -> AccountRecord? {
        var kept = record
        kept.restored = nil
        if kept.lastError == .signInRequired {
            kept.lastError = nil
            kept.lastErrorAt = nil
            kept.consecutiveFailures = 0
        }
        return kept.lastGood != nil || kept.lastError != nil ? kept : nil
    }

    /// The record's last read or attempt.
    nonisolated static func lastUsed(_ record: AccountRecord) -> Date? {
        [record.lastAttemptAt, record.lastGood?.readAt].compactMap { $0 }.max()
    }

    /// Its latest outcome is a sign-in failure.
    public nonisolated static func isSignedOut(_ record: AccountRecord) -> Bool {
        guard record.lastError == .signInRequired, let at = record.lastErrorAt else { return false }
        return at >= (record.lastGood?.readAt ?? .distantPast) || at == record.lastAttemptAt
    }

    nonisolated static func provider(ofFolder id: String) -> Provider? {
        id.split(separator: ":", maxSplits: 1).first.flatMap { Provider(rawValue: String($0)) }
    }
}

/// A `Login` from a file another build may have written: whole when it can be, else its provider and email (without
/// them it is not a login) with its switch and what could be read of its record (`SalvagedRecord`).
struct SalvagedLogin: Salvageable {
    var login: Login
    var damaged = false

    private enum Key: String, CodingKey { case provider, email, org, orgName, kind, monitored, record }

    init(from decoder: any Decoder) throws {
        if let whole = try? Login(from: decoder) {
            login = whole
            return
        }
        let container = try decoder.container(keyedBy: Key.self)
        let record = try? container.decodeIfPresent(SalvagedRecord.self, forKey: .record)
        login = Login(provider: try container.decode(Provider.self, forKey: .provider), email: try container.decode(String.self, forKey: .email),
                      org: try? container.decodeIfPresent(String.self, forKey: .org),
                      orgName: try? container.decodeIfPresent(String.self, forKey: .orgName),
                      kind: try? container.decodeIfPresent(LoginIdentity.PlanKind.self, forKey: .kind),
                      monitored: (try? container.decodeIfPresent(Bool.self, forKey: .monitored)) ?? true, record: record?.record)
        damaged = true
    }
}
