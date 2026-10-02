import Foundation
import Synchronization

/// Notices a `/login` that puts another account into a Claude folder Juice reads (P29's Claude half, P80). Claude keeps
/// its login in the keychain, so no file holds it; `/login` rewrites the folder's `.claude.json` (`~/.claude.json` for
/// the default `~/.claude`, see `stamp`), and so does nearly every session, so the file's stamp (`stat`: inode and
/// modification time, the file is never opened here) only says that something may have changed. Who is signed in comes
/// from `claude auth status --json` alone (`CLIIdentityChecker`): a local CLI call that reads no usage.
///
/// It runs inside the folder's scheduled read, so the scheduler's floors, pauses and backoff decide when it can act, and
/// an ask costs one short process. A read asks before its usage read:
/// - on the folder's first read in a run: the login may have changed while the app was not running;
/// - whenever `.claude.json` changed since the last answer (P93): Juice Island reads a login through whichever of its
///   folders changed last, which is the one a `/login` just rewrote, so a read that did not ask could file another
///   account's usage under the login. A rewrite while a read runs counts too: a `stat` cannot tell a `/login` then from
///   the read's own rewrite. The login's floor (300 s, 120 s boosted) bounds this to one question per read;
/// - while the folder is signed out (its last answer or read said so), at most once a minute. A folder still signed out,
///   asked less than a minute ago with `.claude.json` unchanged since, ends the read with sign-in required, and no usage
///   read is made.
/// The answer goes to `login` before the usage read, as in `CodexIdentityWatch`, and a folder that holds another login
/// than the one its read is for is not read (`CodexIdentityWatch.held`). A question that fails ends the read with its
/// failure and no usage read: nobody could say whose usage it would be. It is asked again on the next read. A read that
/// did not ask and comes back on another plan than the folder's last reading asks right after it, so a switch between
/// plans shows at once. A reading carries the email only when its own read asked; the live model gives it the login's
/// otherwise, which the unchanged file still vouches for. The live model files a reading whose email names another login
/// under that login, and moves the folder to it.
///
/// Between reads the live model calls `check` on its clock for every enabled folder, those its logins are not read
/// through included: it asks only when `.claude.json` changed since the last ask, at most once a minute for a
/// signed-out folder and once every `recheckInterval` for a signed-in one (an active folder rewrites the file all the
/// time, and the next read through it asks anyway), with no usage read; a sign-out goes to `login` then. A check's first sight of a folder only notes its stamp. A folder no read has placed yet gets
/// `identify`: one question, whatever its file says, with no usage read.
///
/// The answer names the folder's login: its email and organization (P580). A folder whose last answer was an Anthropic
/// Console login (`SignInIdentity.usageBilled`) reads, through `get_usage`, like a signed-out one; a read that says so is
/// asked about at once (unless it just asked), and while the CLI still says it is that login the read is its answer that
/// it has no plan limits (`ReadError.noLimitsReported`, P581), never a sign-out.
///
/// A folder that is signing in is only read: the sign-in flow asks `claude auth status` itself and reports what it found.
/// When it finishes, its answer stands for the watch's own (`signedIn`), so a sign-out the watch heard before is not
/// repeated, and nothing is asked again.
public actor ClaudeIdentityWatch: AccountReader {
    public typealias StatProfile = @Sendable (_ folder: String) -> AuthFileStamp?
    public typealias Identity = @Sendable (Account) async -> Result<SignInIdentity, ReadError>
    public typealias Read = @Sendable (Account, Date) async -> Result<AccountReading, ReadError>
    public typealias Login = CodexIdentityWatch.Login
    public typealias IsSigningIn = @Sendable (Account) async -> Bool

    /// The shortest time between two asks by `check` of a signed-in folder whose `.claude.json` changed.
    public static let recheckInterval: TimeInterval = 1_800
    /// The shortest time between two asks of a signed-out folder, and before asking about a plan that changed.
    public static let minimumGap: TimeInterval = 60

    /// The stamp of the `.claude.json` the folder's CLI writes: `<folder>/.claude.json`, except for the default
    /// `~/.claude`, whose CLI runs without `CLAUDE_CONFIG_DIR` (`CLIEnvironment.make`) and writes `~/.claude.json`.
    public static func stamp(folder: String, home: String = NSHomeDirectory()) -> AuthFileStamp? {
        let parent = CLIEnvironment.isDefaultFolder(folder, for: .claude, home: home) ? home : folder
        return AuthFileStamp.of(path: (parent as NSString).appendingPathComponent(".claude.json"))
    }

    private struct Folder {
        /// `.claude.json` as last seen (after the folder's last read, a rewrite during it already counted as a change).
        var stamp: AuthFileStamp?
        /// It changed since the last ask that got an answer.
        var changed = false
        var askedAt: Date?
        var signedOut = false
        /// The plan of the folder's last good reading.
        var plan: String?
        /// The last answer was an Anthropic Console login (`SignInIdentity.usageBilled`).
        var usageBilled = false
    }

    private let statProfile: StatProfile
    private let identity: Identity
    private let readThrough: Read
    private let login: Login
    private let isSigningIn: IsSigningIn
    private var folders: [String: Folder] = [:]
    /// Folders the sign-in flow just signed in, with the time it asked; taken by the folder's next read or check.
    private let signIns = Mutex<[String: (at: Date, usageBilled: Bool)]>([:])

    public init(stat: @escaping StatProfile = { ClaudeIdentityWatch.stamp(folder: $0) }, identity: @escaping Identity,
                read: @escaping Read, isSigningIn: @escaping IsSigningIn = { _ in false }, login: @escaping Login) {
        self.statProfile = stat
        self.identity = identity
        self.readThrough = read
        self.isSigningIn = isSigningIn
        self.login = login
    }

    /// The sign-in flow signed the folder in, asking `claude auth status` itself at `at`: the folder's next read or check
    /// takes that as its last answer, a Console login's included (`usageBilled`, P581). Synchronous, so it lands before
    /// the read the flow's refresh brings.
    public nonisolated func signedIn(_ account: Account, at: Date, usageBilled: Bool = false) {
        signIns.withLock { $0[account.folder] = (at, usageBilled) }
    }

    public func read(_ account: Account, now: Date) async -> Result<AccountReading, ReadError> {
        if await isSigningIn(account) { return await readThrough(account, now) }
        let folder = account.folder
        takeSignIn(folder)
        noteStamp(folder)
        var who: LoginIdentity?
        let asked = shouldAsk(folder, now: now, reading: true)
        if asked {
            switch await ask(account, now: now) {
            case .success(let answer):
                who = answer.login
                if let who, !(await login(account, who)) { return .failure(CodexIdentityWatch.held) }
            case .failure(let error):
                // Signed out, or nobody could say who is signed in: no usage read.
                return .failure(error)
            }
        } else if folders[folder]?.signedOut == true {
            // Asked less than a minute ago, signed out then, and the file unchanged since: no usage read for an answer
            // already known.
            return .failure(.signInRequired)
        }
        let before = statProfile(folder)
        var result = await readThrough(account, now)
        // Rewritten while it read: the read's own rewrite, or a `/login` whose account the next reads would take for this
        // one. Counted before a question below, whose answer comes after it.
        let after = statProfile(folder)
        if after != before { folders[folder, default: Folder()].changed = true }
        // A Console login's `get_usage` is a signed-out folder's (P581): its CLI says which it is.
        if case .failure(.signInRequired) = result, folders[folder]?.usageBilled == true {
            var billed = asked
            if !asked {
                switch await ask(account, now: now) {
                case .success(let answer):
                    billed = answer.usageBilled
                    if let found = answer.login, !(await login(account, found)) { return .failure(CodexIdentityWatch.held) }
                case .failure(.signInRequired):
                    break
                case .failure(let error):
                    // Nobody could say whether it is signed in: the question's failure, as a read's question's is.
                    return .failure(error)
                }
            }
            if billed { result = .failure(.noLimitsReported) }
        }
        switch result {
        case .success(var reading):
            let otherPlan = folders[folder]?.plan.flatMap { last in reading.plan.map { $0 != last } } ?? false
            if !asked, otherPlan, isPast(Self.minimumGap, folder, now) {
                if case .success(let answer) = await ask(account, now: now) { who = answer.login }
            }
            if let who {
                reading.email = who.email
                reading.org = who.org
                reading.orgName = who.orgName
            }
            folders[folder, default: Folder()].plan = reading.plan
            folders[folder, default: Folder()].signedOut = false
            result = .success(reading)
        case .failure(.signInRequired):
            folders[folder, default: Folder()].signedOut = true
        case .failure:
            break
        }
        folders[folder, default: Folder()].stamp = after
        return result
    }

    /// Between reads: a waiting folder's `.claude.json` changed. A read's question, on the check's terms above, with no
    /// usage read.
    public func check(_ account: Account, now: Date) async {
        if await isSigningIn(account) { return }
        let folder = account.folder
        takeSignIn(folder)
        noteStamp(folder)
        guard shouldAsk(folder, now: now, reading: false) else { return }
        let wasSignedOut = folders[folder]?.signedOut ?? false
        switch await ask(account, now: now) {
        case .success(let who):
            if let found = who.login { _ = await login(account, found) }
        case .failure(.signInRequired):
            if !wasSignedOut { _ = await login(account, nil) }
        case .failure:
            break
        }
    }

    /// Who is signed in to a folder no read has placed yet: one question, with no usage read. The answer goes to `login`
    /// (nil: signed out) and comes back; the folder's next read asks again only on the terms above. A folder that is
    /// signing in is left to the sign-in flow.
    public func identify(_ account: Account, now: Date) async -> Result<SignInIdentity, ReadError> {
        if await isSigningIn(account) { return .failure(.failed("signing in")) }
        let folder = account.folder
        takeSignIn(folder)
        noteStamp(folder)
        let answer = await ask(account, now: now)
        switch answer {
        case .success(let who):
            if let found = who.login { _ = await login(account, found) }
        case .failure(.signInRequired):
            _ = await login(account, nil)
        case .failure:
            break
        }
        return answer
    }

    /// A sign-in the flow finished (`signedIn`): signed in, asked then, and the file as it is now. The plan starts over,
    /// since the login may be another one.
    private func takeSignIn(_ folder: String) {
        guard let signIn = signIns.withLock({ $0.removeValue(forKey: folder) }) else { return }
        folders[folder] = Folder(stamp: statProfile(folder), askedAt: signIn.at, usageBilled: signIn.usageBilled)
    }

    private func noteStamp(_ folder: String) {
        let stamp = statProfile(folder)
        guard let seen = folders[folder] else {
            folders[folder] = Folder(stamp: stamp)
            return
        }
        if seen.stamp != stamp {
            folders[folder]?.stamp = stamp
            folders[folder]?.changed = true
        }
    }

    /// A read asks first thing in a run, whenever the file changed since the last answer, and while signed out once a
    /// minute. A check asks only when the file changed since the last answer: once a minute signed out, once every
    /// `recheckInterval` signed in.
    private func shouldAsk(_ folder: String, now: Date, reading: Bool) -> Bool {
        guard let state = folders[folder] else { return reading }
        if reading {
            return state.askedAt == nil || state.changed || (state.signedOut && isPast(Self.minimumGap, folder, now))
        }
        guard state.changed else { return false }
        guard state.askedAt != nil else { return true }
        return isPast(state.signedOut ? Self.minimumGap : Self.recheckInterval, folder, now)
    }

    private func isPast(_ gap: TimeInterval, _ folder: String, _ now: Date) -> Bool {
        guard let asked = folders[folder]?.askedAt else { return true }
        return now.timeIntervalSince(asked) >= gap
    }

    /// Asks, noting the time before the await so a read or check arriving meanwhile does not ask again.
    private func ask(_ account: Account, now: Date) async -> Result<SignInIdentity, ReadError> {
        let folder = account.folder
        folders[folder, default: Folder()].askedAt = now
        let answer = await identity(account)
        switch answer {
        case .success(let who):
            folders[folder, default: Folder()].changed = false
            folders[folder, default: Folder()].signedOut = false
            folders[folder, default: Folder()].usageBilled = who.usageBilled
        case .failure(.signInRequired):
            folders[folder, default: Folder()].changed = false
            folders[folder, default: Folder()].signedOut = true
            folders[folder, default: Folder()].usageBilled = false
        case .failure:
            folders[folder, default: Folder()].changed = true
        }
        return answer
    }
}
