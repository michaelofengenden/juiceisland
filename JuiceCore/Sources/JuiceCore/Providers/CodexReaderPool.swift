import Foundation

/// Hands each Codex account to the long-lived reader for its home, creating readers on first use.
///
/// Memory stays bounded however many Codex logins there are (P110): a home's server stops once it has been asked
/// nothing for `idleTimeout` (2 min by default, so a login on the 60, 30 or 15 s cadence keeps its server and one that
/// waits longer does not), and no more than `maxServers` run at once: before another home's server starts, the idle ones
/// asked nothing longest are stopped. A stopped server starts again on the next read or question, which is no extra read,
/// so the floors are the scheduler's as before.
public actor CodexReaderPool: AccountReader {
    /// The release build's values (P110): the app builds its pool with these.
    public static let defaultIdleTimeout: Duration = .seconds(120)
    public static let defaultMaxServers = 4

    private let executable: URL
    private let timeout: Duration
    /// Each home's server stops once asked nothing this long; nil never.
    public nonisolated let idleTimeout: Duration?
    /// At most this many servers run at once.
    public nonisolated let maxServers: Int
    private let extraEnvironment: [String: String]
    private var readers: [String: CodexAppServerReader] = [:]

    public init(executable: URL, timeout: Duration = .seconds(20), idleTimeout: Duration? = CodexReaderPool.defaultIdleTimeout,
                maxServers: Int = CodexReaderPool.defaultMaxServers, extraEnvironment: [String: String] = [:]) {
        self.executable = executable
        self.timeout = timeout
        self.idleTimeout = idleTimeout
        self.maxServers = max(1, maxServers)
        self.extraEnvironment = extraEnvironment
    }

    public var readerCount: Int { readers.count }

    public func read(_ account: Account, now: Date) async -> Result<AccountReading, ReadError> {
        let reader = reader(for: account.folder)
        await makeRoom(for: reader)
        return await reader.read(account, now: now)
    }

    /// Who is signed in to the account's home, asked of that home's app-server (`account/read` only, no usage read).
    public func identity(for account: Account) async -> Result<SignInIdentity, ReadError> {
        let reader = reader(for: account.folder)
        await makeRoom(for: reader)
        return await reader.identity()
    }

    private func reader(for folder: String) -> CodexAppServerReader {
        if let existing = readers[folder] { return existing }
        let reader = CodexAppServerReader(executable: executable, folder: folder, timeout: timeout, idleTimeout: idleTimeout,
                                          extraEnvironment: extraEnvironment)
        readers[folder] = reader
        return reader
    }

    /// Before `reader` starts a server: while `maxServers` others run, the idle one asked nothing longest stops. A server
    /// with a read or question under way is never stopped, so reads running at once may briefly go over.
    private func makeRoom(for reader: CodexAppServerReader) async {
        guard await !reader.isServing else { return }
        var running: [(reader: CodexAppServerReader, lastUsed: ContinuousClock.Instant)] = []
        for other in readers.values where other !== reader {
            if await other.isServing { running.append((other, await other.lastUsed)) }
        }
        var count = running.count
        for other in running.sorted(by: { $0.lastUsed < $1.lastUsed }) where count >= maxServers {
            if await other.reader.stopIfIdle() { count -= 1 }
        }
    }

    /// For tests: how many homes have a server up.
    func servingCount() async -> Int {
        var count = 0
        for reader in readers.values {
            if await reader.isServing { count += 1 }
        }
        return count
    }

    /// Stops the app-server for one home and forgets it, so the next read for that folder starts a fresh one.
    /// A sign-in needs this: the server that is up was started before the login and answers from the session it
    /// had then, so an identity check through it could still report the account the folder had before.
    public func shutdown(folder: String) async {
        guard let reader = readers.removeValue(forKey: folder) else { return }
        await reader.shutdown()
    }

    /// For tests: the app-server's process id for a home, or nil when this pool has no reader for it.
    func processIdentifier(folder: String) async -> Int32? {
        await readers[folder]?.processIdentifier
    }

    public func shutdownAll() async {
        for (_, reader) in readers { await reader.shutdown() }
        readers.removeAll()
    }
}
