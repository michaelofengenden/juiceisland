import Foundation

/// The inode and modification time of a Codex home's `auth.json`, and nothing else about it. The file holds the home's
/// login, so Juice never opens it (Juice spec §8.3): `stat(2)` reads the inode, not the contents, and needs no read
/// permission on the file.
public struct AuthFileStamp: Sendable, Equatable, Hashable {
    public var inode: UInt64
    public var modifiedSeconds: Int
    public var modifiedNanoseconds: Int

    public init(inode: UInt64, modifiedSeconds: Int, modifiedNanoseconds: Int = 0) {
        self.inode = inode
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
    }

    /// When the file last changed: a lapsed Codex login (`Rules.loginLapsed`, P1550) is told by it.
    public var modified: Date {
        Date(timeIntervalSince1970: TimeInterval(modifiedSeconds) + TimeInterval(modifiedNanoseconds) / 1_000_000_000)
    }

    /// `stat` of `<folder>/auth.json`, following a symlink to the file it names; nil when it cannot be stat-ed, which
    /// in practice means there is none.
    public static func of(folder: String) -> AuthFileStamp? {
        of(path: (folder as NSString).appendingPathComponent("auth.json"))
    }

    /// `stat` of any file a login rewrites (a Claude folder's `.claude.json`, see `ClaudeIdentityWatch`), the same way.
    public static func of(path: String) -> AuthFileStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return AuthFileStamp(inode: UInt64(info.st_ino), modifiedSeconds: Int(info.st_mtimespec.tv_sec),
                             modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec))
    }
}

/// Notices a `codex login` that puts another account into a Codex home Juice reads (Juice Island spec, amendment 8;
/// pitfalls P29 and P80). A home's long-lived app-server keeps answering for the login it started with, because Codex
/// reloads `auth.json` only for the same account, so without this a switched home would go on showing the old account.
///
/// It runs inside the scheduled read of a home, so the scheduler's floors, pauses and backoff decide when it can act.
/// Each read stats the home's `auth.json`. When the inode or the modification time differs from what the home's
/// previous read saw, the home's app-server is restarted and the fresh one is asked who is signed in
/// (`account/read {refreshToken:false}`). The answer goes to `login` before the read goes on through that same server,
/// so the check adds no usage read; `login` answers whether the read may go on. Juice Island reads a login through one
/// of the folders that hold it, so a home found holding another login than the one its read is for is not read: the
/// read ends with `held`, and the live model reads that login through another folder. The first read of a home in a run
/// counts as a change, because the login may have changed while Juice was not running (at launch the home has no server
/// yet, so the restart does nothing). A question that fails is asked again on the home's next read, without another
/// restart; signed out, or signed in without an email, is an answer, with nothing to report: the read that follows
/// reports a sign-out itself.
///
/// A home no read has placed yet (a folder Juice Island has not asked in this run) gets `identify`: the same restart
/// and question, with no usage read, whatever its `auth.json` says (a login kept in the keychain has none).
///
/// A home that is not read soon (its login waits out a pause, or is read through another folder) would notice a login
/// only at its next read, so the live model calls `check` for every enabled home on its clock: a `stat`, and when
/// `auth.json` changed, the same restart and question as a read's, with no usage read (amendment 8 as revised for P80
/// and P93). A check's first sight of
/// a home only notes its stamp, so no server starts early; a home a check has not asked about is still asked on its first
/// read. A question a check could not get answered is asked on the home's next read.
///
/// A missing `auth.json` is a sign-out, not a change to chase. When it disappears the server is restarted once, so it
/// stops answering for the old login, and nothing is asked; a `check` reports the sign-out to `login` (no read follows
/// to report it). While it stays missing nothing happens. A home whose login lives in the keychain has no `auth.json`,
/// so the watch never acts on it.
///
/// A home that is signing in is only read. The sign-in flow's check restarts that home's reader and reads through it
/// (`CLIIdentityChecker`), so a restart here would cut the check short with "shut down". Nothing is restarted, asked
/// or recorded then, so the first read after the flow compares `auth.json` with what the watch saw before it.
public actor CodexIdentityWatch: AccountReader {
    public typealias StatAuthFile = @Sendable (_ folder: String) -> AuthFileStamp?
    public typealias Restart = @Sendable (_ folder: String) async -> Void
    public typealias Identity = @Sendable (Account) async -> Result<SignInIdentity, ReadError>
    public typealias Read = @Sendable (Account, Date) async -> Result<AccountReading, ReadError>
    public typealias Found = @Sendable (_ account: Account, _ email: String) async -> Void
    /// The login the question found (nil: the home signed out); returns whether the read may go on to its usage read.
    /// Codex's `account/read` names an email only, no workspace (P582), so a Codex login is its email's.
    public typealias Login = @Sendable (_ account: Account, _ who: LoginIdentity?) async -> Bool
    public typealias IsSigningIn = @Sendable (Account) async -> Bool

    /// What a read returns when `login` held it back: the home holds another login than the one the read is for.
    public static let held = ReadError.incomplete("held: the folder holds another login")

    private enum Seen: Equatable {
        case missing
        case present(AuthFileStamp)
    }

    private let statAuthFile: StatAuthFile
    private let restart: Restart
    private let identity: Identity
    private let readThrough: Read
    private let login: Login
    private let isSigningIn: IsSigningIn
    /// What each home's previous read or check saw.
    private var seen: [String: Seen] = [:]
    /// Homes read, or restarted and asked by a check, in this run: a home's first read counts as a change until then.
    private var followed: Set<String> = []
    /// Homes whose current `auth.json` has no answer yet.
    private var unanswered: Set<String> = []

    public init(stat: @escaping StatAuthFile = { AuthFileStamp.of(folder: $0) }, restart: @escaping Restart,
                identity: @escaping Identity, read: @escaping Read, isSigningIn: @escaping IsSigningIn = { _ in false },
                login: @escaping Login) {
        self.statAuthFile = stat
        self.restart = restart
        self.identity = identity
        self.readThrough = read
        self.isSigningIn = isSigningIn
        self.login = login
    }

    /// Standalone Juice's form: `found` hears each email found, and every read goes on.
    public init(stat: @escaping StatAuthFile = { AuthFileStamp.of(folder: $0) }, restart: @escaping Restart,
                identity: @escaping Identity, read: @escaping Read, isSigningIn: @escaping IsSigningIn = { _ in false },
                found: @escaping Found) {
        self.init(stat: stat, restart: restart, identity: identity, read: read, isSigningIn: isSigningIn, login: { account, who in
            if let who { await found(account, who.email) }
            return true
        })
    }

    /// The pool's way: a restart is `shutdown(folder:)`, and the question and the read go to the home's reader.
    public init(pool: CodexReaderPool, isSigningIn: @escaping IsSigningIn = { _ in false }, found: @escaping Found) {
        self.init(restart: { await pool.shutdown(folder: $0) }, identity: { await pool.identity(for: $0) },
                  read: { await pool.read($0, now: $1) }, isSigningIn: isSigningIn, found: found)
    }

    public func read(_ account: Account, now: Date) async -> Result<AccountReading, ReadError> {
        if await isSigningIn(account) { return await readThrough(account, now) }
        guard await follow(account, reading: true) else { return .failure(Self.held) }
        return await readThrough(account, now)
    }

    /// Between reads: the home's `auth.json` changed. The same restart and question as a read's, and no usage read.
    /// Returns whether it restarted the home's app-server, which then runs until someone stops it.
    @discardableResult
    public func check(_ account: Account) async -> Bool {
        if await isSigningIn(account) { return false }
        var started = false
        _ = await follow(account, reading: false, started: &started)
        return started
    }

    /// Who is signed in to a home no read has placed yet: its app-server restarted and asked, with no usage read. The
    /// answer goes to `login` (nil: signed out) and comes back; a question that fails is asked again on the home's next
    /// read, without another restart. A home that is signing in is left to the sign-in flow.
    public func identify(_ account: Account) async -> Result<SignInIdentity, ReadError> {
        if await isSigningIn(account) { return .failure(.failed("signing in")) }
        let folder = account.folder
        seen[folder] = statAuthFile(folder).map(Seen.present) ?? .missing
        followed.insert(folder)
        unanswered.insert(folder)
        await restart(folder)
        let answer = await identity(account)
        switch answer {
        case .success(let who):
            unanswered.remove(folder)
            if let found = who.login { _ = await login(account, found) }
        case .failure(.signInRequired):
            unanswered.remove(folder)
            _ = await login(account, nil)
        case .failure:
            break
        }
        return answer
    }

    /// Stats the home's `auth.json`, restarts and asks as above. False when the login found must not be read. A check
    /// reports a sign-out itself; a read leaves that to its own answer. `started` says whether the home's app-server was
    /// restarted.
    private func follow(_ account: Account, reading: Bool) async -> Bool {
        var started = false
        return await follow(account, reading: reading, started: &started)
    }

    private func follow(_ account: Account, reading: Bool, started: inout Bool) async -> Bool {
        let folder = account.folder
        let current = statAuthFile(folder).map(Seen.present) ?? .missing
        // Recorded before any await, so a second read of the same home arriving meanwhile does not restart it again.
        let previous = seen.updateValue(current, forKey: folder)
        let changed = previous != current
        // A check acts on a change only; its first sight of a home just notes the stamp.
        if !reading && (previous == nil || !changed) { return true }
        let first = followed.insert(folder).inserted
        if current == .missing {
            unanswered.remove(folder)
            guard case .present? = previous else { return true }
            await restart(folder)
            return reading ? true : await login(account, nil)
        }
        if changed || first {
            unanswered.insert(folder)
            await restart(folder)
            started = true
        }
        guard unanswered.contains(folder) else { return true }
        return await ask(account, reportingSignOut: !reading)
    }

    private func ask(_ account: Account, reportingSignOut: Bool) async -> Bool {
        switch await identity(account) {
        case .success(let who):
            unanswered.remove(account.folder)
            guard let found = who.login else { return true }
            return await login(account, found)
        case .failure(.signInRequired):
            unanswered.remove(account.folder)
            return reportingSignOut ? await login(account, nil) : true
        case .failure:
            return true
        }
    }
}

extension AccountIdentity {
    /// Standalone Juice's rule. `email` was just found signed in to the Codex home `id` (amendment 8). When the home
    /// had another account before (its known email, else its last reading's), that account's record is forgotten, so
    /// its battery never shows for the new one, and a known email becomes the new one, so duplicate detection
    /// (`duplicateOf`, `uniqueAccounts`) counts the account the home holds now. Returns whether the home changed
    /// account; the caller then saves both stores. The same account, a home with no identity yet, a Claude folder and
    /// an unknown id change nothing. Juice Island keeps every login's record instead (`LoginsStore`, P80, P93).
    @MainActor
    @discardableResult
    public static func accountFound(_ email: String, for id: String, accounts: AccountsStore, readings: ReadingsStore) -> Bool {
        guard let account = accounts.accounts.first(where: { $0.id == id }), account.provider == .codex,
              let before = self.email(for: account, records: readings.records), before != email.lowercased() else { return false }
        readings.forget(id: id)
        if account.knownEmail != nil { accounts.setKnownEmail(id: id, email) }
        return true
    }
}
