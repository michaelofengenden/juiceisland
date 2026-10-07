import Foundation
import IslandEngine
import JuiceCore

/// A Codex home's app-server, as the live model uses it: one `codex app-server` per home (`CodexReaderPool`), asked
/// `account/read {refreshToken:false}` and `account/rateLimits/read` only. A server asked nothing for 2 min stops, at most
/// four run at once, and a stopped one starts again on the home's next read or question (P110).
struct CodexBackend: Sendable {
    var read: @Sendable (Account, Date) async -> Result<AccountReading, ReadError>
    /// Who is signed in to the account's home (`account/read` only, no usage read).
    var identity: @Sendable (Account) async -> Result<SignInIdentity, ReadError>
    /// Stops one home's app-server; the next read of that home starts a fresh one.
    var shutdown: @Sendable (_ folder: String) async -> Void
    var shutdownAll: @Sendable () async -> Void
    /// The identity watch's `stat` of a home's login file (inode and modification time only; never opened).
    var stat: CodexIdentityWatch.StatAuthFile = { AuthFileStamp.of(folder: $0) }

    /// JuiceCore's pool for the found `codex`: one app-server per monitored home.
    static func pool(executable: URL) -> CodexBackend {
        let pool = readerPool(executable: executable)
        return CodexBackend(read: { await pool.read($0, now: $1) }, identity: { await pool.identity(for: $0) },
                            shutdown: { await pool.shutdown(folder: $0) }, shutdownAll: { await pool.shutdownAll() })
    }

    /// The pool itself, with JuiceCore's release values: servers stop after 2 min asked nothing, four at most (P110).
    static func readerPool(executable: URL) -> CodexReaderPool {
        CodexReaderPool(executable: executable)
    }
}

/// Everything the live model starts or touches outside itself, in one value, so tests hand it fakes and never run a
/// real reader, a CLI, a login shell, a browser or discovery over the real home folder. `LiveReaders.app` is the only
/// real one; only `AppEnvironment.app` in the release identity uses it (`UsageModelKind`).
struct LiveReaders {
    /// Finds `claude` or `codex` (`ToolLocator`, which may ask a login shell for PATH). Called off the main actor.
    var locate: @Sendable (Provider) -> URL?
    /// The Claude reader for a found `claude`: one process per read, the `get_usage` control request only.
    var claude: @Sendable (URL) -> ClaudeIdentityWatch.Read
    /// The Codex app-servers for a found `codex`.
    var codex: @Sendable (URL) -> CodexBackend
    /// Claude's sign-in identity check (`claude auth status --json`).
    var claudeIdentity: @Sendable (URL?) -> any IdentityChecker
    /// Profile folders found on this Mac (Juice spec §6), by which files exist: no login file is opened (P66).
    var discover: @Sendable () -> [DiscoveredProfile]
    /// The `BROWSER` helper sign-in pages open through, written next to `accounts.json`; nil to open the default browser.
    var browserHelper: @MainActor (_ directory: URL) -> URL?
    /// The Chrome profile folder sign-in pages open in (Settings › Accounts); nil for the default browser.
    var browserProfile: @MainActor () -> String?
    var setBrowserProfile: @MainActor (String?) -> Void
    /// Chrome's profiles, for the pop-up.
    var browserProfiles: @MainActor () -> [ChromeProfile]
    /// Sleep, wake and app launch/quit notifications; nil installs nothing (tests call the model directly).
    var systemEvents: LiveSystemEvents?
    /// Seconds between clock ticks (ages, and the mirror while standalone Juice runs); nil in tests (`tick()` by hand).
    var tickInterval: TimeInterval?
    /// The Claude identity watch's `stat` of a folder's `.claude.json` (inode and modification time only).
    var claudeStamp: ClaudeIdentityWatch.StatProfile = { ClaudeIdentityWatch.stamp(folder: $0) }
    /// The home folder the providers' default folders (`~/.claude`, `~/.codex`) live in.
    var home: String = NSHomeDirectory()
    /// Refresh login's terminal (P1551): the owner's usual one, and the opener that types its line into a new window of it,
    /// on the owner's click only. The defaults open nothing: only `LiveReaders.app` opens a window.
    var usualHost: @Sendable () -> FreshSessionLaunch.Host = { .terminal }
    var openTerminal: @Sendable (FreshSessionLaunch) async -> Bool = { _ in false }

    /// The real readers. Only the release build may make them: a dev build, a test or a render that got here is a bug,
    /// stopped before anything is read.
    @MainActor
    static var app: LiveReaders {
        precondition(AppIdentity.current == .production, "the live readers run only in the release build")
        return LiveReaders(
            locate: { ToolLocator.locate($0 == .claude ? "claude" : "codex") },
            claude: { executable in
                let reader = ClaudeCLIReader(executable: executable)
                return { account, now in await reader.read(account, now: now) }
            },
            codex: { CodexBackend.pool(executable: $0) },
            claudeIdentity: { CLIIdentityChecker(claudeExecutable: $0, codexPool: nil) },
            discover: { LiveReaders.discoverProfiles() },
            browserHelper: { BrowserHelper.install(in: $0) },
            browserProfile: { ChromeProfiles.selectedDirectory },
            setBrowserProfile: { ChromeProfiles.selectedDirectory = $0 },
            browserProfiles: { ChromeProfiles.list() },
            systemEvents: LiveSystemEvents(),
            tickInterval: 5,
            usualHost: { FreshSessionLaunch.liveUsualHost() },
            openTerminal: { await FreshSessionLaunch.openLive($0) })
    }

    /// Settings › Accounts' discovery: `ProfileFolderDiscovery`, which only asks whether a folder's `.claude.json`,
    /// `config.toml` or Codex login file exists and names each alias from the folder, never from what a file says. Who is
    /// signed in comes only from the CLIs (`claude auth status`, `account/read`), so a folder added from here carries no
    /// email until one answers (P66).
    static func discoverProfiles(home: String = NSHomeDirectory()) -> [DiscoveredProfile] {
        ProfileFolderDiscovery.discover(home: home)
    }
}

/// The sign-in check (Juice spec §7 step 3): Claude through `claude auth status --json`; Codex through the home's own
/// reader, restarted first, because the server that is up started before the login and answers for the session it
/// had then. The Codex check is `account/read` alone, never a usage read: the login it finds may have been read
/// through another folder moments ago, and its floor is the login's (P93).
struct LiveIdentityChecker: IdentityChecker {
    var claude: any IdentityChecker
    var codex: CodexBackend?

    func identity(for account: Account) async -> Result<SignInIdentity, ReadError> {
        switch account.provider {
        case .claude:
            return await claude.identity(for: account)
        case .codex:
            guard let codex else { return .failure(.cliNotFound) }
            await codex.shutdown(account.folder)
            return await codex.identity(account)
        }
    }
}
