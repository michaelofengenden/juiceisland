import Foundation
import Testing
@testable import JuiceCore

private let account = Account(provider: .codex, folder: "/tmp/juice-test-codex", alias: "default")

private func env(limits: String) throws -> [String: String] {
    ["FAKE_ACCOUNT": try fixtureURL("codex-account", "json").path, "FAKE_LIMITS": try fixtureURL(limits, "json").path]
}

@Test func readsThroughOneLongLivedProcess() async throws {
    let reader = CodexAppServerReader(executable: try fixtureURL("fake-codex", "sh"), folder: account.folder,
                                      timeout: .seconds(10), extraEnvironment: try env(limits: "codex-ratelimits"))
    let first = try await reader.read(account, now: Date()).get()
    #expect(first.plan == "pro")
    #expect(first.email == "someone@example.com")
    #expect(first.windows.map(\.usedPercent) == [99])
    let pidBefore = await reader.processIdentifier
    let second = try await reader.read(account, now: Date()).get()
    #expect(second.windows.count == 1)
    #expect(await reader.processIdentifier == pidBefore)
    await reader.shutdown()
}

@Test func signedOutHomeIsSignInRequired() async throws {
    let signedOut = FileManager.default.temporaryDirectory.appendingPathComponent("juice-signedout-\(UUID().uuidString).json")
    try Data(#"{"account":null,"requiresOpenaiAuth":true}"#.utf8).write(to: signedOut)
    let reader = CodexAppServerReader(executable: try fixtureURL("fake-codex", "sh"), folder: account.folder, timeout: .seconds(10),
                                      extraEnvironment: ["FAKE_ACCOUNT": signedOut.path, "FAKE_LIMITS": try fixtureURL("codex-ratelimits", "json").path])
    let result = await reader.read(account, now: Date())
    #expect(result == .failure(.signInRequired))
    await reader.shutdown()
}

@Test func exhaustedHomeReadsAsBlocked() async throws {
    let reader = CodexAppServerReader(executable: try fixtureURL("fake-codex", "sh"), folder: account.folder,
                                      timeout: .seconds(10), extraEnvironment: try env(limits: "codex-ratelimits-exhausted"))
    let reading = try await reader.read(account, now: Date()).get()
    #expect(!reading.ordinaryUsageAllowed)
    await reader.shutdown()
}

@Test func restartsAfterTheServerDies() async throws {
    let reader = CodexAppServerReader(executable: try fixtureURL("fake-codex", "sh"), folder: account.folder,
                                      timeout: .seconds(10), extraEnvironment: try env(limits: "codex-ratelimits"))
    _ = try await reader.read(account, now: Date()).get()
    let pidBefore = await reader.processIdentifier
    await reader.simulateCrashForTesting()
    let again = try await reader.read(account, now: Date()).get()
    #expect(again.windows.count == 1)
    #expect(await reader.processIdentifier != pidBefore)
    await reader.shutdown()
}

@Test func unansweredRequestTimesOut() async throws {
    let reader = CodexAppServerReader(executable: try fixtureURL("fake-codex-silent", "sh"), folder: account.folder,
                                      timeout: .milliseconds(300), extraEnvironment: try env(limits: "codex-ratelimits"))
    let started = Date()
    let result = await reader.read(account, now: Date())
    #expect(result == .failure(.timeout))
    #expect(Date().timeIntervalSince(started) < 3)
    await reader.shutdown()
}

@Test func timedOutServerIsRecycled() async throws {
    let reader = CodexAppServerReader(executable: try fixtureURL("fake-codex-silent", "sh"), folder: account.folder,
                                      timeout: .milliseconds(300), extraEnvironment: try env(limits: "codex-ratelimits"))
    let result = await reader.read(account, now: Date())
    #expect(result == .failure(.timeout))
    // The mute child was stopped, so the next tick starts a fresh server instead of writing into a pipe
    // nobody drains. `processIdentifier` is nil only because the reader let go of the process it killed.
    #expect(await reader.processIdentifier == nil)
    await reader.shutdown()
}

@Test func emptyRateLimitsIsIncomplete() async throws {
    let reader = CodexAppServerReader(executable: try fixtureURL("fake-codex", "sh"), folder: account.folder,
                                      timeout: .seconds(10), extraEnvironment: try env(limits: "codex-ratelimits-empty"))
    let result = await reader.read(account, now: Date())
    #expect(result == .failure(.incomplete("no windows reported")))
    await reader.shutdown()
}

@Test func poolKeepsOneReaderPerHome() async throws {
    let pool = CodexReaderPool(executable: try fixtureURL("fake-codex", "sh"), timeout: .seconds(10), extraEnvironment: try env(limits: "codex-ratelimits"))
    let other = Account(provider: .codex, folder: "/tmp/juice-test-codex-2", alias: "side")
    _ = try await pool.read(account, now: Date()).get()
    _ = try await pool.read(other, now: Date()).get()
    _ = try await pool.read(account, now: Date()).get()
    #expect(await pool.readerCount == 2)
    await pool.shutdownAll()
}

@Test func shuttingDownOneHomeMakesTheNextReadStartAFreshServer() async throws {
    let pool = CodexReaderPool(executable: try fixtureURL("fake-codex", "sh"), timeout: .seconds(10), extraEnvironment: try env(limits: "codex-ratelimits"))
    let other = Account(provider: .codex, folder: "/tmp/juice-test-codex-3", alias: "side")
    _ = try await pool.read(account, now: Date()).get()
    _ = try await pool.read(other, now: Date()).get()
    let pidBefore = await pool.processIdentifier(folder: account.folder)

    await pool.shutdown(folder: account.folder)
    #expect(await pool.readerCount == 1)                    // only this home's server was stopped
    #expect(await pool.processIdentifier(folder: other.folder) != nil)

    let again = try await pool.read(account, now: Date()).get()
    #expect(again.windows.count == 1)
    #expect(await pool.readerCount == 2)
    #expect(await pool.processIdentifier(folder: account.folder) != pidBefore)
    await pool.shutdownAll()
}

/// A temp file holding one JSON-RPC error object, for `$FAKE_LIMITS_ERROR`.
private func errorFile(_ json: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("juice-rpc-error-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url)
    return url
}

/// P105: the app-server's usage read answers a 429 with a JSON-RPC error. That is a rate limit, not a failure: the login
/// waits Retry-After + 900 s instead of a failure's backoff.
@Test func aRateLimitedUsageReadIsARateLimit() async throws {
    let error = try errorFile(#"{"code":-32603,"message":"failed to fetch codex rate limits: unexpected status 429 Too Many Requests"}"#)
    defer { try? FileManager.default.removeItem(at: error) }
    var environment = try env(limits: "codex-ratelimits")
    environment["FAKE_LIMITS_ERROR"] = error.path
    let reader = CodexAppServerReader(executable: try fixtureURL("fake-codex", "sh"), folder: account.folder,
                                      timeout: .seconds(10), extraEnvironment: environment)
    #expect(await reader.read(account, now: Date()) == .failure(.rateLimited(retryAfter: nil)))
    #expect(await reader.processIdentifier != nil)                    // the server is fine; only the vendor said no
    await reader.shutdown()
}

/// How an error reply reads: the vendor's text is classified like a CLI's stderr, and masked when it is kept.
@Test func errorRepliesAreClassifiedLikeCLIText() {
    typealias E = JSONRPC.RPCError
    #expect(CodexAppServerReader.readError(E(code: 429, message: "slow down")) == .rateLimited(retryAfter: nil))
    #expect(CodexAppServerReader.readError(E(code: -32603, message: "rate_limit_exceeded")) == .rateLimited(retryAfter: nil))
    #expect(CodexAppServerReader.readError(E(code: -32603, message: "request failed", data: #"{"httpStatusCode":429}"#))
            == .rateLimited(retryAfter: nil))
    #expect(CodexAppServerReader.readError(E(code: -32603, message: "Too Many Requests\nretry-after: 120")) == .rateLimited(retryAfter: 120))
    #expect(CodexAppServerReader.readError(E(code: -32603, message: "Not logged in")) == .signInRequired)
    #expect(CodexAppServerReader.readError(E(code: -32601, message: "unknown method account/rateLimits/read"))
            == .cliUpdateNeeded("unknown method account/rateLimits/read"))
    #expect(CodexAppServerReader.readError(E(code: -32000, message: "boom Bearer abc.def")) == .failed("boom \(ReadError.redactionMark)"))
    #expect(CodexAppServerReader.readError(E(code: -32000)) == .failed("JSON-RPC error -32000"))
    // A duration or an id with 429 in it is not a rate limit.
    #expect(CodexAppServerReader.readError(E(code: -32000, message: "took 1429 ms")) == .failed("took 1429 ms"))
}

/// P105: a Codex 429 holds the login across a relaunch. The scheduler reads through the reader, readings.json keeps the
/// outcome, and a new scheduler seeded from the saved file waits out Retry-After + 900 s from the 429.
@MainActor
@Test func aCodexRateLimitPausesAcrossARelaunch() async throws {
    let error = try errorFile(#"{"code":-32603,"message":"unexpected status 429 Too Many Requests"}"#)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("juice-readings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: error); try? FileManager.default.removeItem(at: url) }
    var environment = try env(limits: "codex-ratelimits")
    environment["FAKE_LIMITS_ERROR"] = error.path
    let reader = CodexAppServerReader(executable: try fixtureURL("fake-codex", "sh"), folder: account.folder,
                                      timeout: .seconds(10), extraEnvironment: environment)
    let start = Date(timeIntervalSince1970: 1_900_000_000)
    let store = ReadingsStore(fileURL: url)
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { start }, sleep: { _ in })
    scheduler.setReader({ target, now in await reader.read(account, now: now) }, for: .codex)
    scheduler.onResult = { target, result, at in store.apply(result, for: target.id, at: at) }
    scheduler.setAccounts([account])
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(scheduler.nextDue(for: account.id) == start + 900)
    await reader.shutdown()
    try store.save()

    let reloaded = ReadingsStore(fileURL: url)
    reloaded.load()
    #expect(reloaded.record(for: account.id).lastError == .rateLimited(retryAfter: nil))
    let relaunched = RefreshScheduler(policy: RefreshPolicy(), now: { start + 60 }, sleep: { _ in })
    relaunched.setAccounts([account])
    relaunched.seed(from: reloaded.records)
    #expect(relaunched.nextDue(for: account.id) == start + 1 + 900)
    relaunched.refreshAll()
    #expect(relaunched.nextDue(for: account.id) == start + 1 + 900)
}

/// P109: a request from the server is never taken for the reply to one of ours, even under the same id, and is refused
/// with JSON-RPC's "method not found" under its own id, a string one too, so the server never waits on it and nothing is
/// granted. The read then gets its real reply.
@Test func theServersOwnRequestsAreRefusedAndNeverTakenForReplies() async throws {
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("juice-asks-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: log) }
    var environment = try env(limits: "codex-ratelimits")
    environment["FAKE_LOG"] = log.path
    let reader = CodexAppServerReader(executable: try fixtureURL("fake-codex-asks", "sh"), folder: account.folder,
                                      timeout: .seconds(10), extraEnvironment: environment)
    let reading = try await reader.read(account, now: Date()).get()
    #expect(reading.windows.map(\.usedPercent) == [99])
    await reader.shutdown()

    let answers = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(answers.count == 2)
    let first = try JSONRPC.Envelope.decode(Data(answers[0].utf8))
    #expect(first.id == .text("srv-1") && first.error?.code == JSONRPC.methodNotFound && first.method == nil)
    // The second went out under the usage read's own id: initialize was 1, account/read 2, account/rateLimits/read 3.
    let second = try JSONRPC.Envelope.decode(Data(answers[1].utf8))
    #expect(second.id == 3 && second.error?.code == JSONRPC.methodNotFound && second.method == nil)
    #expect(!answers.joined().contains("result"))
}

@Test func jsonRPCErrorsKeepTheirDataAndIDsMayBeStrings() throws {
    let request = try JSONRPC.Envelope.decode(Data(#"{"id":"srv-9","method":"item/tool/call","params":{}}"#.utf8))
    #expect(request.id == .text("srv-9") && request.method == "item/tool/call")
    let notification = try JSONRPC.Envelope.decode(Data(#"{"method":"remoteControl/status/changed","params":{}}"#.utf8))
    #expect(notification.id == nil && notification.method != nil)
    let failed = try JSONRPC.Envelope.decode(Data(#"{"id":4,"error":{"code":-32603,"message":"x","data":{"httpStatusCode":429,"retry":[1,true,null]}}}"#.utf8))
    #expect(failed.id == 4 && failed.error?.data == #"{"httpStatusCode":429,"retry":[1,true,null]}"#)
    #expect(JSONRPC.errorResponse(id: .text("a/b"), code: -32601, message: "no") == #"{"error":{"code":-32601,"message":"no"},"id":"a/b","jsonrpc":"2.0"}"#)
    #expect(JSONRPC.errorResponse(id: 7, code: -32601, message: "no").contains(#""id":7,"#))
}

/// Polls `condition` for up to five seconds.
private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<250 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// P110: a server asked nothing for its idle time stops, and the next read starts a fresh one at once (a stop for
/// idleness is no crash, so no restart delay). Reads closer together than that keep the one server.
@Test func anIdleServerStopsAndTheNextReadStartsOne() async throws {
    let reader = CodexAppServerReader(executable: try fixtureURL("fake-codex", "sh"), folder: account.folder, timeout: .seconds(10),
                                      idleTimeout: .milliseconds(400), extraEnvironment: try env(limits: "codex-ratelimits"))
    _ = try await reader.read(account, now: Date()).get()
    let pid = try #require(await reader.processIdentifier)
    try await Task.sleep(for: .milliseconds(150))
    _ = try await reader.read(account, now: Date()).get()
    #expect(await reader.processIdentifier == pid)
    #expect(await eventually { await reader.processIdentifier == nil })
    #expect(await eventually { kill(pid, 0) != 0 })                     // the process is gone, not just forgotten
    let again = try await reader.read(account, now: Date()).get()
    #expect(again.windows.map(\.usedPercent) == [99])
    let newPID = await reader.processIdentifier
    #expect(newPID != nil && newPID != pid)
    await reader.shutdown()
}

/// P110 as the app runs it: a pool built with nothing but its executable stops a home's server after 2 min asked
/// nothing and runs at most four; and the pool hands its idle time to each home's reader, so a server read through the
/// pool stops once idle.
@Test func thePoolStopsIdleServersAsTheAppBuildsIt() async throws {
    let defaults = CodexReaderPool(executable: try fixtureURL("fake-codex", "sh"))
    #expect(defaults.idleTimeout == .seconds(120) && defaults.maxServers == 4)
    #expect(CodexReaderPool.defaultIdleTimeout == .seconds(120) && CodexReaderPool.defaultMaxServers == 4)
    let pool = CodexReaderPool(executable: try fixtureURL("fake-codex", "sh"), timeout: .seconds(10), idleTimeout: .milliseconds(400),
                               extraEnvironment: try env(limits: "codex-ratelimits"))
    _ = try await pool.read(account, now: Date()).get()
    let pid = try #require(await pool.processIdentifier(folder: account.folder))
    #expect(await eventually { await pool.processIdentifier(folder: account.folder) == nil })
    #expect(await eventually { kill(pid, 0) != 0 })
    await pool.shutdownAll()
}

/// P110: however many homes are read, no more than `maxServers` servers run: before another home's server starts, the
/// one asked nothing longest stops, and it starts again when its home is read.
@Test func thePoolRunsAtMostItsServers() async throws {
    let pool = CodexReaderPool(executable: try fixtureURL("fake-codex", "sh"), timeout: .seconds(10), idleTimeout: nil, maxServers: 2,
                               extraEnvironment: try env(limits: "codex-ratelimits"))
    let homes = (1...4).map { Account(provider: .codex, folder: "/tmp/juice-test-codex-cap-\($0)", alias: "cap\($0)") }
    func up() async -> [Bool] {
        var up: [Bool] = []
        for home in homes { up.append(await pool.processIdentifier(folder: home.folder) != nil) }
        return up
    }
    for home in homes { _ = try await pool.read(home, now: Date()).get() }
    #expect(await pool.servingCount() == 2)
    #expect(await up() == [false, false, true, true])
    _ = try await pool.read(homes[0], now: Date()).get()
    #expect(await up() == [true, false, false, true])
    _ = try await pool.identity(for: homes[1]).get()
    #expect(await up() == [true, true, false, false])
    #expect(await pool.readerCount == 4)
    await pool.shutdownAll()
}

/// Making room never cuts a read short: a server with a read under way stays, and an idle one stops instead.
@Test func makingRoomNeverStopsAServerThatIsReading() async throws {
    let slow = FileManager.default.temporaryDirectory.appendingPathComponent("juice-slow-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: slow) }
    var environment = try env(limits: "codex-ratelimits")
    environment["FAKE_SLOW"] = slow.path
    let pool = CodexReaderPool(executable: try fixtureURL("fake-codex-sticky", "sh"), timeout: .seconds(10), idleTimeout: nil,
                               maxServers: 2, extraEnvironment: environment)
    let idle = Account(provider: .codex, folder: "/tmp/juice-test-codex-idle", alias: "idle")
    let busy = Account(provider: .codex, folder: "/tmp/juice-test-codex-busy", alias: "busy")
    let third = Account(provider: .codex, folder: "/tmp/juice-test-codex-third", alias: "third")
    _ = try await pool.read(idle, now: Date()).get()
    try Data().write(to: slow)                                          // account/read now answers a second late
    let reading = Task { await pool.read(busy, now: Date()) }
    #expect(await eventually { await pool.processIdentifier(folder: busy.folder) != nil })
    try FileManager.default.removeItem(at: slow)
    _ = try await pool.read(third, now: Date()).get()
    #expect(await pool.processIdentifier(folder: idle.folder) == nil)
    #expect(try await reading.value.get().windows.map(\.usedPercent) == [99])
    let busyPID = await pool.processIdentifier(folder: busy.folder), thirdPID = await pool.processIdentifier(folder: third.folder)
    #expect(busyPID != nil && thirdPID != nil)
    await pool.shutdownAll()
}

/// P732: `codex login` as another account in a home whose usage read is under way. A home's server answers for the login
/// it started with, and the identity watch restarts it and asks the fresh one when `auth.json` changes
/// (`CodexIdentityWatch`, P29). The read under way ends with its server: it never returns the old account's email with
/// the new account's limits or reset credits. The next read names the new account, with its own.
@Test func aRestartForAnotherLoginNeverMixesTwoAccountsInOneReading() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("juice-switch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let accountFile = dir.appendingPathComponent("account.json"), limitsFile = dir.appendingPathComponent("limits.json")
    let slow = dir.appendingPathComponent("slow"), log = dir.appendingPathComponent("log")
    func signIn(_ email: String, used: Int, credits: Int) throws {
        try Data(#"{"account":{"type":"chatgpt","email":"\#(email)","planType":"plus"},"requiresOpenaiAuth":true}"#.utf8)
            .write(to: accountFile)
        try Data(#"{"rateLimits":{"primary":{"usedPercent":\#(used),"windowDurationMins":300,"resetsAt":1790603043},"planType":"plus"},"rateLimitResetCredits":{"availableCount":\#(credits),"credits":[]}}"#.utf8)
            .write(to: limitsFile)
    }
    try signIn("a@example.com", used: 20, credits: 2)
    let pool = CodexReaderPool(executable: try fixtureURL("fake-codex-sticky", "sh"), timeout: .seconds(10), idleTimeout: nil,
                               extraEnvironment: ["FAKE_ACCOUNT": accountFile.path, "FAKE_LIMITS": limitsFile.path, "FAKE_STICKY_LIMITS": "1",
                                                  "FAKE_SLOW_LIMITS": slow.path, "FAKE_LOG": log.path])
    let first = try await pool.read(account, now: Date()).get()
    #expect(first.email == "a@example.com" && first.resetCredits == 2 && first.windows.first?.usedPercent == 20)

    try Data().write(to: slow)
    let reading = Task { await pool.read(account, now: Date()) }
    let usageReads = { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == "account/rateLimits/read" }.count }
    #expect(await eventually { usageReads() == 2 })                     // past `account/read`, waiting on its usage
    try signIn("b@example.com", used: 80, credits: 5)
    await pool.shutdown(folder: account.folder)
    try FileManager.default.removeItem(at: slow)
    #expect(try await pool.identity(for: account).get().email == "b@example.com")
    if case .success(let mixed) = await reading.value {
        Issue.record("a reading across the restart: \(mixed.email ?? "no email"), \(mixed.resetCredits ?? 0) credits")
    }
    let next = try await pool.read(account, now: Date()).get()
    #expect(next.email == "b@example.com" && next.resetCredits == 5 && next.windows.first?.usedPercent == 80)
    await pool.shutdownAll()
}
