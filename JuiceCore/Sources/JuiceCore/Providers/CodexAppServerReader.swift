import Foundation

/// One long-lived `codex app-server` for one CODEX_HOME (spec §8.1). Requests are matched to responses by id.
/// If the server exits, every pending request fails and the next read restarts it with a growing delay.
///
/// With an `idleTimeout`, a server that is asked nothing for that long stops, and the next read or question starts a
/// fresh one (P110): a home read on the 60, 30 or 15 s cadence keeps its server, one whose login waits out a 429 pause,
/// the sign-in delay or a long backoff does not hold 60 to 70 MB meanwhile. A stop for idleness is not a crash: the next
/// start waits no restart delay.
public actor CodexAppServerReader {
    public let folder: String
    private let executable: URL
    private let timeout: Duration
    private let idleTimeout: Duration?
    private let extraEnvironment: [String: String]
    /// Reads and questions under way: a stop for idleness or for room (`stopIfIdle`) never cuts one short.
    private var busy = 0
    private var idleStop: Task<Void, Never>?
    /// When the last read or question ended (or this reader was made).
    public private(set) var lastUsed = ContinuousClock.now

    private var process: CLIProcess?
    private var readerTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Result<Data, ReadError>, Never>] = [:]
    private var initialized = false
    private var restartAttempts = 0
    private var notBefore = Date.distantPast
    /// The file `executable` led to when the running server started, links followed. The PATH entry an installer points
    /// at the current version (`~/.local/bin/codex`) leads elsewhere after an update, and the next read then starts the
    /// current version instead of keeping the old one running, or one the installer has since pruned (P107).
    private var startedFrom: String?
    private static let backoff: [TimeInterval] = [1, 2, 5, 10, 30, 60]

    public init(executable: URL, folder: String, timeout: Duration = .seconds(20), idleTimeout: Duration? = nil,
                extraEnvironment: [String: String] = [:]) {
        self.executable = executable
        self.folder = folder
        self.timeout = timeout
        self.idleTimeout = idleTimeout
        self.extraEnvironment = extraEnvironment
    }

    public var processIdentifier: Int32? { process?.processIdentifier }

    /// Whether a server is up for this home (started, or starting).
    public var isServing: Bool { process != nil }

    public func read(_ account: Account, now: Date) async -> Result<AccountReading, ReadError> {
        begin()
        defer { end() }
        let codexAccount: CodexAccount
        switch await signedInAccount() {
        case .failure(let error): return .failure(error)
        case .success(let found): codexAccount = found
        }
        switch await call("account/rateLimits/read", params: [:]) {
        case .failure(let error): return .failure(recycleIfTimedOut(error))
        case .success(let data):
            guard let limits = try? JSONRPC.decodeResult(data, as: CodexRateLimitsResult.self) else {
                return .failure(.cliUpdateNeeded("account/rateLimits/read: unexpected shape"))
            }
            var reading = limits.reading(accountID: account.id, readAt: now, email: codexAccount.email)
            if reading.plan == nil { reading.plan = codexAccount.planType?.lowercased() }
            // No window and still allowed is a reading in progress; no window and not allowed is used up.
            guard !reading.windows.isEmpty || !reading.ordinaryUsageAllowed else { return .failure(.incomplete("no windows reported")) }
            return .success(reading)
        }
    }

    /// Who is signed in to this home, from `account/read {refreshToken:false}` alone: no usage read. The identity
    /// watch asks this of a server it has just restarted, so the answer is the login `auth.json` holds now.
    public func identity() async -> Result<SignInIdentity, ReadError> {
        begin()
        defer { end() }
        return await signedInAccount().map { SignInIdentity(email: $0.email, plan: $0.planType?.lowercased()) }
    }

    /// Stops the server if nothing is under way and nothing was asked for `idle`; true when no server is left running.
    /// The idle timer calls it, and the pool to make room for another home's server.
    @discardableResult
    public func stopIfIdle(for idle: Duration = .zero) -> Bool {
        guard busy == 0, pending.isEmpty else { return false }
        guard process != nil else { return true }
        guard ContinuousClock.now - lastUsed >= idle else { return false }
        stopProcess()
        return true
    }

    private func begin() {
        busy += 1
        idleStop?.cancel()
        idleStop = nil
    }

    /// A read or question ended: with nothing else under way, the idle timer starts.
    private func end() {
        busy -= 1
        lastUsed = .now
        guard busy == 0, let idleTimeout, process != nil else { return }
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle(for: idleTimeout)
        }
    }

    /// Starts the server when needed, then `account/read {refreshToken:false}`: the signed-in account, or
    /// `.signInRequired` when the home has none.
    private func signedInAccount() async -> Result<CodexAccount, ReadError> {
        if let failure = await ensureStarted() { return .failure(failure) }
        let accountData: Data
        switch await call("account/read", params: ["refreshToken": false]) {
        case .failure(let error): return .failure(recycleIfTimedOut(error))
        case .success(let data): accountData = data
        }
        guard let accountResult = try? JSONRPC.decodeResult(accountData, as: CodexAccountReadResult.self) else {
            return .failure(.cliUpdateNeeded("account/read: unexpected shape"))
        }
        guard let codexAccount = accountResult.account else { return .failure(.signInRequired) }
        return .success(codexAccount)
    }

    public func shutdown() {
        idleStop?.cancel()
        idleStop = nil
        stopProcess()
        failAllPending(.failed("shut down"))
    }

    /// Test hook: kills the server so the next read must restart it.
    public func simulateCrashForTesting() async {
        process?.kill()
        while process != nil { try? await Task.sleep(for: .milliseconds(20)) }
        notBefore = .distantPast
    }

    // MARK: - Process lifecycle

    private func ensureStarted() async -> ReadError? {
        if let process, process.isRunning, initialized {
            if executable.resolvingSymlinksInPath().path == startedFrom { return nil }
            // The CLI was updated under the running server: its replacement starts below, with no restart delay.
            stopProcess()
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .cliNotFound }
        if Date() < notBefore { return .failed("app-server restarting, next attempt \(Formatting.duration(notBefore.timeIntervalSinceNow)) from now") }
        // A half-started server (the handshake timed out, say) would otherwise be left running forever.
        stopProcess()
        let env = CLIEnvironment.make(provider: .codex, folder: folder, extra: extraEnvironment)
        let p = CLIProcess(executable: executable, arguments: ["app-server"], environment: env)
        startedFrom = executable.resolvingSymlinksInPath().path
        do {
            try p.start()
        } catch {
            scheduleRestart()
            return .failed("could not launch codex: \(error.localizedDescription)")
        }
        process = p
        initialized = false
        let lines = p.lines
        readerTask = Task { [weak self] in
            for await line in lines {
                guard let self else { return }
                await self.route(line)
            }
            await self?.processEnded(p)
        }
        switch await call("initialize", params: ["clientInfo": ["name": "juice", "title": "Juice", "version": Juice.version]]) {
        case .failure(let error):
            // A server that cannot complete the handshake is no use to anyone: stop it and wait out the backoff.
            stopProcess()
            scheduleRestart()
            return error
        case .success: break
        }
        do {
            try p.write(line: JSONRPC.notification(method: "initialized"))
        } catch {
            stopProcess()
            scheduleRestart()
            return .failed("could not write to app-server")
        }
        initialized = true
        restartAttempts = 0
        return nil
    }

    private func stopProcess() {
        readerTask?.cancel()
        readerTask = nil
        process?.terminate()
        process = nil
        initialized = false
    }

    /// Holds the next launch off for 1, 2, 5, 10, 30 then 60 seconds. Every path that gives up on a server —
    /// it exited, it would not launch, it never finished the handshake, it went mute — goes through here.
    private func scheduleRestart() {
        let delay = Self.backoff[min(restartAttempts, Self.backoff.count - 1)]
        restartAttempts += 1
        notBefore = Date().addingTimeInterval(delay)
    }

    /// A server that answered nothing is presumed wedged. Stopping it matters more than the failed read:
    /// `CLIProcess.write(line:)` blocks on the actor, so piling further requests into a pipe nobody drains
    /// would eventually hang the actor for good, `shutdown()` included.
    private func recycleIfTimedOut(_ error: ReadError) -> ReadError {
        if error == .timeout {
            stopProcess()
            scheduleRestart()
        }
        return error
    }

    private func processEnded(_ p: CLIProcess) async {
        // The child has already exited (its output stream finished), so this returns its status at once.
        let status = await p.waitForExit()
        guard process === p else { return }
        let stderr = p.stderrOutput
        process = nil
        initialized = false
        scheduleRestart()
        failAllPending(ReadError.classify(exitStatus: status, stdout: "", stderr: stderr.isEmpty ? "app-server exited" : stderr))
    }

    private func route(_ line: String) {
        guard let data = line.data(using: .utf8), let envelope = try? JSONRPC.Envelope.decode(data) else { return }
        if let method = envelope.method {
            // A notification needs nothing. A request from the server (a method and an id) is never the reply to one of
            // ours, though its id is the server's own count and may equal one (P109). Juice starts no thread and grants
            // nothing, so it is refused at once, as JSON-RPC asks, and the server never waits on it.
            if let id = envelope.id { refuse(id, method: method) }
            return
        }
        guard case .number(let id)? = envelope.id else { return }
        // No continuation means a late reply to a request that already timed out; drop it.
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let error = envelope.error {
            continuation.resume(returning: .failure(Self.readError(error)))
        } else {
            continuation.resume(returning: .success(data))
        }
    }

    /// An error reply, read the way a CLI's stderr is (`ReadError.classify`): its message and data are the vendor's text.
    /// A 429 or a rate-limit word is a rate limit, so the login waits Retry-After + 900 s, across a relaunch too, instead
    /// of a failure's backoff (P105); a sign-in phrase is sign-in required; anything else is a failure, masked, because it
    /// is stored on the account. A code of 429 is a rate limit too, and a method the server does not know means its CLI is
    /// too old for Juice.
    static func readError(_ error: JSONRPC.RPCError) -> ReadError {
        if error.code == 429 { return .rateLimited(retryAfter: nil) }
        let text = [error.message, error.data].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        if error.code == JSONRPC.methodNotFound {
            return .cliUpdateNeeded(String(ReadError.redact(text.isEmpty ? "method not found" : text).suffix(300)))
        }
        guard !text.isEmpty else { return .failed("JSON-RPC error \(error.code ?? 0)") }
        return ReadError.classify(exitStatus: 0, stdout: "", stderr: text)
    }

    /// Answers a request from the server with JSON-RPC's "method not found": no approval, no token, nothing else.
    private func refuse(_ id: JSONRPC.ID, method: String) {
        try? process?.write(line: JSONRPC.errorResponse(id: id, code: JSONRPC.methodNotFound, message: "Juice does not handle \(method)"))
    }

    private func failAllPending(_ error: ReadError) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting { continuation.resume(returning: .failure(error)) }
    }

    private func fail(id: Int, with error: ReadError) {
        pending.removeValue(forKey: id)?.resume(returning: .failure(error))
    }

    private func call(_ method: String, params: [String: any Sendable]) async -> Result<Data, ReadError> {
        do {
            return try await withTimeout(timeout) { await self.send(method, params: params) }
        } catch is TimeoutError {
            return .failure(.timeout)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    /// Writes one request and waits for its reply. Cancellation (the timeout firing) resumes the
    /// continuation itself, so `withTimeout` can never be left waiting for a task that cannot finish.
    private func send(_ method: String, params: [String: any Sendable]) async -> Result<Data, ReadError> {
        guard let process, process.isRunning else { return .failure(.failed("app-server not running")) }
        let id = nextID
        nextID += 1
        let line = JSONRPC.request(id: id, method: method, params: params)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, ReadError>, Never>) in
                pending[id] = continuation
                do {
                    try process.write(line: line)
                } catch {
                    pending.removeValue(forKey: id)?.resume(returning: .failure(.failed("could not write to app-server")))
                }
            }
        } onCancel: {
            Task { await self.fail(id: id, with: .timeout) }
        }
    }
}
