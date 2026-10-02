import Foundation
import JuiceCore
@testable import JuiceIslandUI

/// Fakes for `LiveUsageModel`: no CLI, no login shell, no app-server, no browser, no discovery over the real home
/// folder, no `NSWorkspace` observer and no timer. Every call a real reader would make is logged instead, and the
/// store lives in a temp folder. Fictional folders and emails only.
@MainActor
final class LiveFakes {
    static let home = "/Users/person1"
    static let work = Account(provider: .claude, folder: home + "/.claude-work", alias: "Work", knownEmail: "work@example.com")
    static let lab = Account(provider: .claude, folder: home + "/.claude-lab", alias: "Lab")
    static let side = Account(provider: .codex, folder: home + "/.codex-side", alias: "Side")
    static let fresh = Account(provider: .codex, folder: home + "/.codex-fresh", alias: "Fresh")
    static let juiceApp = RunningAppInfo(processIdentifier: 4_242, bundleIdentifier: "com.ofengenden.juice",
                                         bundleURL: URL(fileURLWithPath: "/Applications/Juice.app"))

    final class Clock { var now = DemoClock.now }

    let directory: URL
    let clock = Clock()
    /// The home folder the model makes new folders in and shortens paths against; a test that makes folders points it at
    /// a temp folder (`tempHome`).
    var home = LiveFakes.home
    /// Everything a reader, the locator or an app-server would have done, in order ("read claude:/…", "locate codex").
    let log = LockedBox<[String]>([])
    var running: [RunningAppInfo] = []
    var located: [Provider: URL] = [.claude: URL(fileURLWithPath: "/fake/bin/claude"), .codex: URL(fileURLWithPath: "/fake/bin/codex")]
    var discovered: [DiscoveredProfile] = []
    /// What a Codex home's `auth.json` stat returns (nil: no file), and who `account/read` answers (nil: each home its own
    /// login, `ownEmail`). Both may change while the model runs (a `codex logout` or `codex login` in the home).
    let authStampBox = LockedBox<AuthFileStamp?>(nil)
    let codexEmailBox = LockedBox<String?>(nil)
    var authStamp: AuthFileStamp? {
        get { authStampBox.withValue { $0 } }
        set { authStampBox.withValue { $0 = newValue } }
    }
    var codexEmail: String? {
        get { codexEmailBox.withValue { $0 } }
        set { codexEmailBox.withValue { $0 = newValue } }
    }
    /// Percent used per Codex login (10 for one not listed); every home reads as sign-in required while
    /// `signedOutWithoutEmail` is on and `codexEmail` is nil.
    let codexUsed = LockedBox<[String: Double]>([:])
    let codexFailure = LockedBox<ReadError?>(nil)
    let signedOutWithoutEmail = LockedBox(false)
    /// Who `claude auth status` answers (nil: each folder its own login, `ownEmail`), the stamp of a Claude folder's
    /// `.claude.json`, and the plan Claude's readings report (nil keeps `claudeResult`'s).
    let claudeWho = LockedBox<Result<SignInIdentity, ReadError>?>(nil)
    let claudeStamp = LockedBox<AuthFileStamp?>(nil)
    let claudePlan = LockedBox<String?>(nil)

    /// One Codex home of its own: who its `account/read` answers (nil: signed out, `account/read` and the usage read say
    /// sign-in required) and its `auth.json` stamp (nil: no file).
    struct CodexHome: Sendable {
        var email: String?
        var stamp: AuthFileStamp?
    }

    /// One Claude folder of its own: what its `claude auth status` answers (a sign-in failure also fails its usage read)
    /// and its `.claude.json` stamp.
    struct ClaudeFolder: Sendable {
        var who: Result<SignInIdentity, ReadError>
        var stamp: AuthFileStamp?
    }

    /// Folders listed here answer for themselves; every other folder answers with the shared values above.
    let codexHomes = LockedBox<[String: CodexHome]>([:])
    let claudeFolders = LockedBox<[String: ClaudeFolder]>([:])
    /// While on, every question (`claude auth status`, Codex `account/read`) waits, until it is turned off or its task is
    /// cancelled: a render can show folders being asked.
    let holdQuestions = LockedBox(false)

    /// Waits while `holdQuestions` is on.
    nonisolated static func waitWhileHeld(_ hold: LockedBox<Bool>) async {
        while hold.withValue({ $0 }), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Claude folders whose usage reads wait while listed, once logged, until the folder leaves the list or the read is
    /// cancelled: a read under way while something else happens.
    let heldReads = LockedBox<Set<String>>([])

    nonisolated static func waitWhileHeld(_ held: LockedBox<Set<String>>, folder: String) async {
        while held.withValue({ $0.contains(folder) }), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func codex(_ account: Account, _ email: String?, stamp: AuthFileStamp?) {
        codexHomes.withValue { $0[account.folder] = CodexHome(email: email, stamp: stamp) }
    }

    func claude(_ account: Account, _ email: String?, stamp: AuthFileStamp?) {
        let who: Result<SignInIdentity, ReadError> = email.map { .success(SignInIdentity(email: $0, plan: "max")) } ?? .failure(.signInRequired)
        claudeFolders.withValue { $0[account.folder] = ClaudeFolder(who: who, stamp: stamp) }
    }
    /// Claude's answer; the default is a fresh reading with 40 % used.
    var claudeResult: @Sendable (Account, Date) -> Result<AccountReading, ReadError> = { account, now in
        .success(AccountReading(accountID: account.id, readAt: now, plan: "max", windows: [
            UsageWindow(seconds: 18_000, usedPercent: 40, resetsAt: now + 3_600),
            UsageWindow(seconds: 604_800, usedPercent: 20, resetsAt: now + 86_400),
        ]))
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("juice-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    /// A fake login CLI in the temp folder, never a real login: `script` runs after the check every CLI fake makes,
    /// that both island skip switches arrived.
    func loginCLI(_ name: String, _ script: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let guardLine = #"[ "$OPEN_ISLAND_SKIP_HOOKS" = 1 ] && [ "$VIBE_ISLAND_SKIP" = 1 ] || { echo "island skip vars missing" >&2; exit 97; }"#
        try ("#!/bin/sh\n" + guardLine + "\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    var entries: [String] { log.withValue { $0 } }
    var reads: [String] { entries.filter { $0.hasPrefix("read ") } }

    private struct AccountsFile: Encodable { var version = 1; var accounts: [Account] }
    private struct ReadingsFile: Encodable { var version = 1; var records: [String: AccountRecord] }

    func writeStore(accounts: [Account], records: [String: AccountRecord] = [:]) throws {
        try JSONEncoder.juice.encode(AccountsFile(accounts: accounts)).write(to: directory.appendingPathComponent("accounts.json"), options: .atomic)
        try JSONEncoder.juice.encode(ReadingsFile(records: records)).write(to: directory.appendingPathComponent("readings.json"), options: .atomic)
    }

    func storeBytes() -> [Data?] {
        ["accounts.json", "readings.json"].map { try? Data(contentsOf: directory.appendingPathComponent($0)) }
    }

    /// A fresh home folder in the temp store, for a test that makes profile folders.
    func tempHome() throws -> String {
        let url = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        home = url.path
        return url.path
    }

    var readers: LiveReaders {
        let log = log, located = located, discovered = discovered, claudeResult = claudeResult, home = home
        let stamp = authStampBox, email = codexEmailBox, used = codexUsed, failure = codexFailure, signedOut = signedOutWithoutEmail
        let claudeWho = claudeWho, claudeStamp = claudeStamp, claudePlan = claudePlan
        let homes = codexHomes, claudeFolders = claudeFolders, hold = holdQuestions, heldReads = heldReads
        /// Who a home answers for, and whether that is "signed out".
        let codexWho: @Sendable (String) -> (email: String?, signedOut: Bool) = { folder in
            if let home = homes.withValue({ $0[folder] }) { return (home.email, home.email == nil) }
            if let who = email.withValue({ $0 }) { return (who, false) }
            return signedOut.withValue { $0 } ? (nil, true) : (LiveFakes.ownEmail(folder), false)
        }
        let backend = CodexBackend(
            read: { account, now in
                log.withValue { $0.append("read \(account.id)") }
                let (who, isSignedOut) = codexWho(account.folder)
                if isSignedOut { return .failure(.signInRequired) }
                if let error = failure.withValue({ $0 }) { return .failure(error) }
                let percent = who.flatMap { name in used.withValue { $0[name] } } ?? 10
                return .success(AccountReading(accountID: account.id, readAt: now, plan: "plus", email: who, windows: [
                    UsageWindow(seconds: 18_000, usedPercent: percent, resetsAt: now + 3_600),
                    UsageWindow(seconds: 604_800, usedPercent: 5, resetsAt: now + 86_400),
                ]))
            },
            identity: { account in
                await LiveFakes.waitWhileHeld(hold)
                log.withValue { $0.append("identity \(account.folder)") }
                let (who, isSignedOut) = codexWho(account.folder)
                if isSignedOut { return .failure(.signInRequired) }
                return .success(SignInIdentity(email: who, plan: "plus"))
            },
            shutdown: { folder in log.withValue { $0.append("shutdown \(folder)") } },
            shutdownAll: { log.withValue { $0.append("shutdownAll") } },
            stat: { folder in
                if let home = homes.withValue({ $0[folder] }) { return home.stamp }
                return stamp.withValue { $0 }
            })
        return LiveReaders(
            locate: { provider in
                log.withValue { $0.append("locate \(provider.rawValue)") }
                return located[provider]
            },
            claude: { _ in
                { account, now in
                    log.withValue { $0.append("read \(account.id)") }
                    await LiveFakes.waitWhileHeld(heldReads, folder: account.folder)
                    if claudeFolders.withValue({ $0[account.folder]?.who }) == .failure(.signInRequired) { return .failure(.signInRequired) }
                    guard case .success(var reading) = claudeResult(account, now), let plan = claudePlan.withValue({ $0 }) else {
                        return claudeResult(account, now)
                    }
                    reading.plan = plan
                    return .success(reading)
                }
            },
            codex: { _ in backend },
            claudeIdentity: { _ in AnsweringIdentity(answer: claudeWho, folders: claudeFolders, log: log, hold: hold) },
            discover: { discovered },
            browserHelper: { _ in nil },
            browserProfile: { nil },
            setBrowserProfile: { _ in },
            browserProfiles: { [ChromeProfile(directory: "Profile 1", name: "Work")] },
            systemEvents: nil,
            tickInterval: nil,
            claudeStamp: { folder in
                if let own = claudeFolders.withValue({ $0[folder] }) { return own.stamp }
                return claudeStamp.withValue { $0 }
            },
            home: home)
    }

    /// A scheduler on the fake clock whose loop ticks once and then sleeps for an hour: tests tick by hand.
    func scheduler() -> RefreshScheduler {
        let clock = clock
        return RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
    }

    var juiceGuard: StandaloneJuiceGuard {
        StandaloneJuiceGuard(ownProcessIdentifier: 1, runningApps: { [unowned self] in self.running })
    }

    /// The model on these fakes. Its files are written at each save (no `StoreWriter`), so a test reads them at once;
    /// a test of the writer passes one.
    func model(storeWriter: StoreWriter? = nil) -> LiveUsageModel {
        let clock = clock
        return LiveUsageModel(directory: directory, readers: readers, juiceGuard: juiceGuard, clock: { clock.now },
                              makeScheduler: { [unowned self] in self.scheduler() }, storeWriter: storeWriter)
    }

    /// The email a folder's CLI answers with when no test says otherwise: its own, from its name (`.codex-side` and
    /// `.claude-side` answer side@example.com, `.codex` and `.claude` default@example.com).
    nonisolated static func ownEmail(_ folder: String) -> String {
        let name = (folder as NSString).lastPathComponent
        let suffix = name.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init) ?? "default"
        return suffix + "@example.com"
    }

    /// `claude auth status`, answered from the folder's own entry, `claudeWho` or the folder's own email; logged as
    /// "auth <folder>" once it answers anything but "no CLI".
    struct AnsweringIdentity: IdentityChecker {
        let answer: LockedBox<Result<SignInIdentity, ReadError>?>
        let folders: LockedBox<[String: ClaudeFolder]>
        let log: LockedBox<[String]>
        let hold: LockedBox<Bool>
        func identity(for account: Account) async -> Result<SignInIdentity, ReadError> {
            await LiveFakes.waitWhileHeld(hold)
            let result = folders.withValue { $0[account.folder]?.who } ?? answer.withValue { $0 }
                ?? .success(SignInIdentity(email: LiveFakes.ownEmail(account.folder), plan: "max"))
            if result != .failure(.cliNotFound) { log.withValue { $0.append("auth \(account.folder)") } }
            return result
        }
    }
}

extension LiveUsageModel {
    /// Waits for the CLI search and the questions it started, then runs one scheduler tick and every read it started.
    func settle() async {
        await wiring?.value
        await loginCheck?.value
        await stopping?.value
        await scheduler.tick()
        await scheduler.waitForInFlight()
        await stopping?.value
    }

    /// One clock tick, and the folder questions and checks it started, and the app-servers they stopped.
    func look() async {
        await wiring?.value
        tick()
        await loginCheck?.value
        await stopping?.value
    }

    /// The login a folder holds.
    func loginID(of folder: Account) -> String? { loginsStore.login(holding: folder.id)?.id }

    func list(_ provider: Provider) -> ProviderLogins? { logins.first { $0.provider == provider } }
}
