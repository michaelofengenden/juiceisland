import Foundation
import Testing
@testable import JuiceCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let side = Account(provider: .codex, folder: "/h/.codex-side", alias: "side")
private let fresh = Account(provider: .codex, folder: "/h/.codex-fresh", alias: "fresh")
private let signedInAsA: Result<SignInIdentity, ReadError> = .success(SignInIdentity(email: "a@example.com", plan: "pro"))

private func stamp(_ inode: UInt64, _ seconds: Int) -> AuthFileStamp {
    AuthFileStamp(inode: inode, modifiedSeconds: seconds)
}

/// A watch whose stat, restart, question and read are stand-ins. `log` gets one line per call, in order. Every home
/// is signing in while `signingIn` holds true.
private func makeWatch(stamps: LockedBox<[String: AuthFileStamp]>, log: LockedBox<[String]>,
                       answer: LockedBox<Result<SignInIdentity, ReadError>> = LockedBox(signedInAsA),
                       signingIn: LockedBox<Bool> = LockedBox(false)) -> CodexIdentityWatch {
    CodexIdentityWatch(
        stat: { folder in stamps.withValue { $0[folder] } },
        restart: { folder in log.withValue { $0.append("restart \(folder)") } },
        identity: { account in
            log.withValue { $0.append("ask \(account.folder)") }
            return answer.withValue { $0 }
        },
        read: { account, _ in
            log.withValue { $0.append("read \(account.folder)") }
            return .failure(.timeout)
        },
        isSigningIn: { _ in signingIn.withValue { $0 } },
        found: { account, email in log.withValue { $0.append("found \(account.folder) \(email)") } })
}

/// The stamp comes from `stat` alone: it needs no read permission, sees an in-place rewrite (a new modification time,
/// to the nanosecond, so a second rewrite within the same second counts) and a replacement by rename (a new inode), and
/// follows a symlink. No file, no stamp.
@Test func anAuthFileStampIsTakenWithStatAlone() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("juice-stamp-\(UUID().uuidString)")
    let home = dir.appendingPathComponent(".codex-side")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let auth = home.appendingPathComponent("auth.json")
    #expect(AuthFileStamp.of(folder: home.path) == nil)

    try Data("{}".utf8).write(to: auth)
    let first = try #require(AuthFileStamp.of(folder: home.path))
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: auth.path)
    #expect(AuthFileStamp.of(folder: home.path) == first)
    try fm.setAttributes([.posixPermissions: 0o600, .modificationDate: t0], ofItemAtPath: auth.path)
    let touched = try #require(AuthFileStamp.of(folder: home.path))
    #expect(touched.inode == first.inode)
    #expect(touched.modifiedSeconds == 1_800_000_000 && touched != first)
    try fm.setAttributes([.modificationDate: t0.addingTimeInterval(0.5)], ofItemAtPath: auth.path)
    let sameSecond = try #require(AuthFileStamp.of(folder: home.path))
    #expect(sameSecond.modifiedSeconds == touched.modifiedSeconds && sameSecond.inode == touched.inode)
    #expect(sameSecond.modifiedNanoseconds == 500_000_000 && sameSecond != touched)

    try Data("{}".utf8).write(to: auth, options: .atomic)
    #expect(try #require(AuthFileStamp.of(folder: home.path)).inode != first.inode)

    let shared = dir.appendingPathComponent("shared.json")
    try fm.moveItem(at: auth, to: shared)
    try fm.createSymbolicLink(at: auth, withDestinationURL: shared)
    let target = try #require(try fm.attributesOfItem(atPath: shared.path)[.systemFileNumber] as? NSNumber)
    #expect(AuthFileStamp.of(folder: home.path)?.inode == target.uint64Value)
}

/// A home's first read, a new modification time and a new inode each restart that home's server and ask who is signed
/// in, before the read. An unchanged auth.json only reads. Every tick is exactly one read.
@Test func aHomeIsRestartedAndAskedOnlyWhenItsAuthFileChanges() async {
    let stamps = LockedBox([side.folder: stamp(1, 100)])
    let log = LockedBox<[String]>([])
    let watch = makeWatch(stamps: stamps, log: log)
    _ = await watch.read(side, now: t0)
    _ = await watch.read(side, now: t0)
    stamps.withValue { $0[side.folder] = stamp(1, 101) }
    _ = await watch.read(side, now: t0)
    stamps.withValue { $0[side.folder] = stamp(2, 101) }
    _ = await watch.read(side, now: t0)
    _ = await watch.read(side, now: t0)
    #expect(log.withValue { $0 } == [
        "restart /h/.codex-side", "ask /h/.codex-side", "found /h/.codex-side a@example.com", "read /h/.codex-side",
        "read /h/.codex-side",
        "restart /h/.codex-side", "ask /h/.codex-side", "found /h/.codex-side a@example.com", "read /h/.codex-side",
        "restart /h/.codex-side", "ask /h/.codex-side", "found /h/.codex-side a@example.com", "read /h/.codex-side",
        "read /h/.codex-side",
    ])
}

/// A home without auth.json is only read. A login creates the file: restart and ask. A sign-out removes it: one
/// restart, so the old login stops answering, and nothing asked, not even a question that had failed before it. While
/// it stays missing, only reads. The next login is asked as usual.
@Test func aMissingAuthFileIsASignOutNotAChangeToChase() async {
    let stamps = LockedBox<[String: AuthFileStamp]>([:])
    let log = LockedBox<[String]>([])
    let answer = LockedBox<Result<SignInIdentity, ReadError>>(.failure(.timeout))
    let watch = makeWatch(stamps: stamps, log: log, answer: answer)
    _ = await watch.read(fresh, now: t0)
    _ = await watch.read(fresh, now: t0)
    stamps.withValue { $0[fresh.folder] = stamp(7, 200) }
    _ = await watch.read(fresh, now: t0)
    stamps.withValue { $0[fresh.folder] = nil }
    _ = await watch.read(fresh, now: t0)
    _ = await watch.read(fresh, now: t0)
    answer.withValue { $0 = signedInAsA }
    stamps.withValue { $0[fresh.folder] = stamp(8, 300) }
    _ = await watch.read(fresh, now: t0)
    #expect(log.withValue { $0 } == [
        "read /h/.codex-fresh", "read /h/.codex-fresh",
        "restart /h/.codex-fresh", "ask /h/.codex-fresh", "read /h/.codex-fresh",
        "restart /h/.codex-fresh", "read /h/.codex-fresh",
        "read /h/.codex-fresh",
        "restart /h/.codex-fresh", "ask /h/.codex-fresh", "found /h/.codex-fresh a@example.com", "read /h/.codex-fresh",
    ])
}

/// Two reads of one home at once (the schedule's and a Refresh, say) restart its server once: the first records what
/// it saw before its first await, so the second finds nothing new.
@Test func twoReadsOfOneHomeAtOnceRestartItOnce() async {
    let log = LockedBox<[String]>([])
    let watch = CodexIdentityWatch(
        stat: { _ in stamp(1, 100) },
        restart: { _ in
            log.withValue { $0.append("restart") }
            // Held until the other read has been through the watch (5 s at most).
            for _ in 0..<500 where !log.withValue({ $0.contains("read") }) { try? await Task.sleep(for: .milliseconds(10)) }
        },
        identity: { _ in
            log.withValue { $0.append("ask") }
            return signedInAsA
        },
        read: { _, _ in
            log.withValue { $0.append("read") }
            return .failure(.timeout)
        },
        found: { _, _ in })
    async let first = watch.read(side, now: t0)
    async let second = watch.read(side, now: t0)
    _ = await (first, second)
    #expect(log.withValue { $0.filter { $0 == "restart" }.count } == 1)
    #expect(log.withValue { $0.filter { $0 == "read" }.count } == 2)
}

/// A question that fails is asked again on the home's next read, without another restart. Signed out, or signed in
/// without an email (an API key), is an answer: not asked again, nothing reported. Each home keeps its own question.
@Test func aFailedQuestionIsAskedAgainOnTheNextRead() async {
    let stamps = LockedBox([side.folder: stamp(1, 100), fresh.folder: stamp(5, 100)])
    let log = LockedBox<[String]>([])
    let answer = LockedBox<Result<SignInIdentity, ReadError>>(.failure(.timeout))
    let watch = makeWatch(stamps: stamps, log: log, answer: answer)
    _ = await watch.read(side, now: t0)
    _ = await watch.read(fresh, now: t0)
    answer.withValue { $0 = .failure(.signInRequired) }
    _ = await watch.read(side, now: t0)
    _ = await watch.read(side, now: t0)
    answer.withValue { $0 = .success(SignInIdentity(email: nil, plan: nil)) }
    _ = await watch.read(fresh, now: t0)
    _ = await watch.read(fresh, now: t0)
    #expect(log.withValue { $0 } == [
        "restart /h/.codex-side", "ask /h/.codex-side", "read /h/.codex-side",
        "restart /h/.codex-fresh", "ask /h/.codex-fresh", "read /h/.codex-fresh",
        "ask /h/.codex-side", "read /h/.codex-side", "read /h/.codex-side",
        "ask /h/.codex-fresh", "read /h/.codex-fresh", "read /h/.codex-fresh",
    ])
}

/// A question still pending when its home starts signing in waits out the flow. During the flow the watch neither asks
/// it nor forgets it. An answer then would reach AppModel's `codexAccountFound` while `signingIn` holds the home, and
/// be dropped there. A forgotten question stays forgotten if the flow is cancelled without a login, because auth.json
/// has not changed. The first read after the flow asks it, with no restart, since auth.json is as it was.
@Test func aPendingQuestionWaitsOutASignIn() async {
    let stamps = LockedBox([side.folder: stamp(1, 100)])
    let log = LockedBox<[String]>([])
    let answer = LockedBox<Result<SignInIdentity, ReadError>>(.failure(.timeout))
    let signingIn = LockedBox(false)
    let watch = makeWatch(stamps: stamps, log: log, answer: answer, signingIn: signingIn)
    _ = await watch.read(side, now: t0)
    answer.withValue { $0 = signedInAsA }
    signingIn.withValue { $0 = true }
    _ = await watch.read(side, now: t0)
    signingIn.withValue { $0 = false }
    _ = await watch.read(side, now: t0)
    #expect(log.withValue { $0 } == [
        "restart /h/.codex-side", "ask /h/.codex-side", "read /h/.codex-side",
        "read /h/.codex-side",
        "ask /h/.codex-side", "found /h/.codex-side a@example.com", "read /h/.codex-side",
    ])
}

/// Another account in a home forgets the home's record and moves a known email along, so duplicate detection counts
/// the account the home holds now; a home that had no known email gets none. The same account in any case, a home with
/// no identity yet, a Claude folder and an unknown id change nothing.
@MainActor
@Test func aDifferentAccountForgetsTheRecordAndCountsDuplicatesAgain() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("juice-found-\(UUID().uuidString)")
    let accounts = AccountsStore(fileURL: dir.appendingPathComponent("accounts.json"))
    let readings = ReadingsStore(fileURL: dir.appendingPathComponent("readings.json"))
    let preset = Account(provider: .codex, folder: "/h/.codex-preset", alias: "preset", knownEmail: "a@example.com")
    let lab = Account(provider: .claude, folder: "/h/.claude-lab", alias: "lab", knownEmail: "c@example.com")
    accounts.replaceAll([preset, side, fresh, lab])
    func reading(_ email: String) -> AccountReading {
        AccountReading(accountID: side.id, readAt: t0, email: email, windows: [UsageWindow(seconds: 18_000, usedPercent: 30, resetsAt: nil)])
    }
    readings.apply(.success(reading("b@example.com")), for: side.id, at: t0)

    #expect(!AccountIdentity.accountFound("B@example.com", for: side.id, accounts: accounts, readings: readings))
    #expect(!AccountIdentity.accountFound("a@example.com", for: fresh.id, accounts: accounts, readings: readings))
    #expect(!AccountIdentity.accountFound("z@example.com", for: lab.id, accounts: accounts, readings: readings))
    #expect(!AccountIdentity.accountFound("z@example.com", for: "codex:/h/.codex-gone", accounts: accounts, readings: readings))
    #expect(readings.records.count == 1)
    #expect(accounts.accounts.map(\.knownEmail) == ["a@example.com", nil, nil, "c@example.com"])

    // `codex login` in .codex-side as preset's account: its record goes, and its next reading makes it preset's duplicate.
    #expect(AccountIdentity.accountFound("a@example.com", for: side.id, accounts: accounts, readings: readings))
    #expect(readings.records[side.id] == nil)
    #expect(accounts.accounts[1].knownEmail == nil)
    readings.apply(.success(reading("a@example.com")), for: side.id, at: t0 + 60)
    #expect(AccountIdentity.duplicateOf(side, in: accounts.accounts, records: readings.records)?.alias == "preset")

    // A known email moves with a switch, so the old one no longer makes .codex-side a duplicate.
    #expect(AccountIdentity.accountFound("d@example.com", for: preset.id, accounts: accounts, readings: readings))
    #expect(accounts.accounts[0].knownEmail == "d@example.com")
    #expect(AccountIdentity.duplicateOf(side, in: accounts.accounts, records: readings.records) == nil)
}

/// Pitfall P29's check, end to end: `codex login` as another account inside a home Juice reads. The server that is up
/// keeps answering for the old login; the auth.json change restarts it, the old account's reading is gone even though
/// the new account's first usage read fails, and the new account's reading follows.
@MainActor
@Test func aCodexLoginSwitchKeepsOnlyTheNewAccount() async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("juice-switch-\(UUID().uuidString)")
    let home = dir.appendingPathComponent(".codex-side")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let who = dir.appendingPathComponent("account.json"), limits = dir.appendingPathComponent("limits.json")
    func login(_ email: String) throws {
        try Data(#"{"account":{"type":"chatgpt","email":"\#(email)","planType":"pro"},"requiresOpenaiAuth":true}"#.utf8).write(to: who)
        // What a login leaves in the home. The watch only ever stats it.
        try Data("{}".utf8).write(to: home.appendingPathComponent("auth.json"), options: .atomic)
    }
    func usage(_ used: Int?) throws {
        let window = used.map { #"{"usedPercent":\#($0),"windowDurationMins":300,"resetsAt":null}"# } ?? "null"
        try Data(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":\#(window),"planType":"pro"}}"#.utf8).write(to: limits)
    }
    try login("a@example.com")
    try usage(70)
    let account = Account(provider: .codex, folder: home.path, alias: "side", knownEmail: "a@example.com")
    let accounts = AccountsStore(fileURL: dir.appendingPathComponent("accounts.json"))
    let readings = ReadingsStore(fileURL: dir.appendingPathComponent("readings.json"))
    accounts.replaceAll([account])
    let pool = CodexReaderPool(executable: try fixtureURL("fake-codex-sticky", "sh"), timeout: .seconds(10),
                               extraEnvironment: ["FAKE_ACCOUNT": who.path, "FAKE_LIMITS": limits.path])
    let watch = CodexIdentityWatch(pool: pool) { account, email in
        await MainActor.run { _ = AccountIdentity.accountFound(email, for: account.id, accounts: accounts, readings: readings) }
    }
    func tick() async {
        let result = await watch.read(account, now: t0)
        readings.apply(result, for: account.id, at: t0)
    }

    await tick()
    #expect(readings.record(for: account.id).lastGood?.windows.map(\.usedPercent) == [70])
    let before = try #require(await pool.processIdentifier(folder: home.path))

    try login("b@example.com")
    try usage(nil)
    #expect(try await pool.identity(for: account).get().email == "a@example.com")
    await tick()
    let record = readings.record(for: account.id)
    #expect(record.lastGood == nil)
    #expect(record.lastError == .incomplete("no windows reported"))
    #expect(accounts.accounts[0].knownEmail == "b@example.com")
    let after = try #require(await pool.processIdentifier(folder: home.path))
    #expect(after != before)

    try usage(20)
    await tick()
    #expect(readings.record(for: account.id).lastGood?.email == "b@example.com")
    #expect(readings.record(for: account.id).lastGood?.windows.map(\.usedPercent) == [20])
    #expect(await pool.processIdentifier(folder: home.path) == after)
    await pool.shutdownAll()
}

/// The question goes to the home's own server with `account/read {refreshToken:false}` alone (the fake refuses a
/// refresh), and the next read uses that same server: the server hears exactly one question, then one read. A
/// signed-out home answers sign-in required.
@Test func thePoolAsksWhoIsSignedInThroughTheHomesServer() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("juice-ask-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let limits = dir.appendingPathComponent("limits.json"), signedOut = dir.appendingPathComponent("signed-out.json")
    let methods = dir.appendingPathComponent("methods.log")
    try Data(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":null}}}"#.utf8).write(to: limits)
    try Data(#"{"account":null,"requiresOpenaiAuth":true}"#.utf8).write(to: signedOut)
    let home = Account(provider: .codex, folder: dir.appendingPathComponent(".codex-side").path, alias: "side")
    let pool = CodexReaderPool(executable: try fixtureURL("fake-codex-sticky", "sh"), timeout: .seconds(10),
                               extraEnvironment: ["FAKE_ACCOUNT": try fixtureURL("codex-account", "json").path,
                                                  "FAKE_LIMITS": limits.path, "FAKE_LOG": methods.path])
    #expect(try await pool.identity(for: home).get() == SignInIdentity(email: "someone@example.com", plan: "pro"))
    let server = await pool.processIdentifier(folder: home.folder)
    #expect(try await pool.read(home, now: t0).get().windows.map(\.usedPercent) == [12])
    #expect(await pool.processIdentifier(folder: home.folder) == server)
    #expect(await pool.readerCount == 1)
    await pool.shutdownAll()
    #expect(try String(contentsOf: methods, encoding: .utf8).split(separator: "\n") ==
            ["initialize", "initialized", "account/read", "account/read", "account/rateLimits/read"])

    let out = CodexReaderPool(executable: try fixtureURL("fake-codex-sticky", "sh"), timeout: .seconds(10),
                              extraEnvironment: ["FAKE_ACCOUNT": signedOut.path, "FAKE_LIMITS": limits.path])
    #expect(await out.identity(for: home) == .failure(.signInRequired))
    await out.shutdownAll()
}

/// The sign-in flow's check restarts the home's reader and reads through it (`CLIIdentityChecker`). A scheduled read
/// of that home while the check waits for its answer goes through the watch, which leaves the server alone while the
/// home signs in, so the check gets its answer instead of "shut down". The first read after the flow compares
/// auth.json with what the watch saw before the flow: one restart, one question.
@Test func aReadDuringTheSignInCheckLeavesTheCheckItsServer() async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("juice-signin-\(UUID().uuidString)")
    let home = dir.appendingPathComponent(".codex-side")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let who = dir.appendingPathComponent("account.json"), limits = dir.appendingPathComponent("limits.json")
    let methods = dir.appendingPathComponent("methods.log"), slow = dir.appendingPathComponent("slow")
    func login(_ email: String) throws {
        try Data(#"{"account":{"type":"chatgpt","email":"\#(email)","planType":"pro"},"requiresOpenaiAuth":true}"#.utf8).write(to: who)
        try Data("{}".utf8).write(to: home.appendingPathComponent("auth.json"), options: .atomic)
    }
    try login("a@example.com")
    try Data(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":null}}}"#.utf8).write(to: limits)
    let account = Account(provider: .codex, folder: home.path, alias: "side")
    let pool = CodexReaderPool(executable: try fixtureURL("fake-codex-sticky", "sh"), timeout: .seconds(10),
                               extraEnvironment: ["FAKE_ACCOUNT": who.path, "FAKE_LIMITS": limits.path,
                                                  "FAKE_LOG": methods.path, "FAKE_SLOW": slow.path])
    let signingIn = LockedBox(false)
    let found = LockedBox<[String]>([])
    let watch = CodexIdentityWatch(pool: pool, isSigningIn: { _ in signingIn.withValue { $0 } }) { _, email in
        found.withValue { $0.append(email) }
    }
    _ = await watch.read(account, now: t0)

    // Sign In: `codex login` as b, then the flow's check, whose question the fake answers a second late.
    signingIn.withValue { $0 = true }
    try login("b@example.com")
    try Data().write(to: methods)
    try Data().write(to: slow)
    let check = Task { await CLIIdentityChecker(claudeExecutable: nil, codexPool: pool).identity(for: account) }
    for _ in 0..<250 where !((try? String(contentsOf: methods, encoding: .utf8)) ?? "").contains("account/read") {
        try await Task.sleep(for: .milliseconds(20))
    }
    let server = try #require(await pool.processIdentifier(folder: home.path))
    let tick = await watch.read(account, now: t0)
    #expect(await check.value.map(\.email) == .success("b@example.com"))
    #expect(try tick.get().email == "b@example.com")
    #expect(await pool.processIdentifier(folder: home.path) == server)
    #expect(found.withValue { $0 } == ["a@example.com"])

    signingIn.withValue { $0 = false }
    try fm.removeItem(at: slow)
    _ = await watch.read(account, now: t0)
    #expect(found.withValue { $0 } == ["a@example.com", "b@example.com"])
    #expect(await pool.processIdentifier(folder: home.path) != server)
    await pool.shutdownAll()
}

/// P80, P93: `login` answers whether the read may go on. A home found holding another login than the one its read is for
/// is asked about and not read: the read ends with `held`, and the live model reads the login through another folder.
@Test func aHomeHoldingAnotherLoginIsNotRead() async {
    let log = LockedBox<[String]>([])
    let watch = CodexIdentityWatch(
        stat: { _ in stamp(1, 100) },
        restart: { folder in log.withValue { $0.append("restart \(folder)") } },
        identity: { account in
            log.withValue { $0.append("ask \(account.folder)") }
            return signedInAsA
        },
        read: { account, _ in
            log.withValue { $0.append("read \(account.folder)") }
            return .failure(.timeout)
        },
        login: { account, email in
            log.withValue { $0.append("login \(account.folder) \(email?.email ?? "none")") }
            return false
        })
    #expect(await watch.read(side, now: t0) == .failure(CodexIdentityWatch.held))
    #expect(log.withValue { $0 } == ["restart /h/.codex-side", "ask /h/.codex-side", "login /h/.codex-side a@example.com"])
}

/// Between reads (`check`, for a home that waits out a pause or the sign-in delay, restored at launch included): a check's
/// first sight of a home only notes its stamp, so no server starts early. An unchanged auth.json does nothing; a changed
/// one restarts and asks, with no usage read, and the next read, its first included, asks nothing more; one that went
/// away restarts once and reports the sign-out, which a read would have reported itself.
@Test func aCheckBetweenReadsRestartsAndAsksOnlyWhenTheFileChanged() async {
    let stamps = LockedBox([side.folder: stamp(1, 100)])
    let log = LockedBox<[String]>([])
    let answer = LockedBox<Result<SignInIdentity, ReadError>>(signedInAsA)
    let watch = CodexIdentityWatch(
        stat: { folder in stamps.withValue { $0[folder] } },
        restart: { folder in log.withValue { $0.append("restart \(folder)") } },
        identity: { account in
            log.withValue { $0.append("ask \(account.folder)") }
            return answer.withValue { $0 }
        },
        read: { account, _ in
            log.withValue { $0.append("read \(account.folder)") }
            return .failure(.timeout)
        },
        login: { account, email in
            log.withValue { $0.append("login \(account.folder) \(email?.email ?? "none")") }
            return true
        })
    await watch.check(side)
    stamps.withValue { $0[side.folder] = stamp(1, 101) }
    await watch.check(side)
    _ = await watch.read(side, now: t0)
    await watch.check(side)
    answer.withValue { $0 = .success(SignInIdentity(email: "b@example.com", plan: "pro")) }
    stamps.withValue { $0[side.folder] = stamp(2, 200) }
    await watch.check(side)
    _ = await watch.read(side, now: t0)
    stamps.withValue { $0[side.folder] = nil }
    await watch.check(side)
    await watch.check(side)
    #expect(log.withValue { $0 } == [
        "restart /h/.codex-side", "ask /h/.codex-side", "login /h/.codex-side a@example.com",
        "read /h/.codex-side",
        "restart /h/.codex-side", "ask /h/.codex-side", "login /h/.codex-side b@example.com",
        "read /h/.codex-side",
        "restart /h/.codex-side", "login /h/.codex-side none",
    ])
}

/// A home signed out at launch (the hour's sign-in delay restored) has not been read in this run: `codex login`
/// creates its auth.json, and the next check asks at once.
@Test func aCheckNoticesALoginInAHomeNotReadYet() async {
    let stamps = LockedBox<[String: AuthFileStamp]>([:])
    let log = LockedBox<[String]>([])
    let watch = CodexIdentityWatch(
        stat: { folder in stamps.withValue { $0[folder] } },
        restart: { folder in log.withValue { $0.append("restart \(folder)") } },
        identity: { account in
            log.withValue { $0.append("ask \(account.folder)") }
            return signedInAsA
        },
        read: { _, _ in .failure(.timeout) },
        login: { account, email in
            log.withValue { $0.append("login \(account.folder) \(email?.email ?? "none")") }
            return true
        })
    await watch.check(fresh)
    await watch.check(fresh)
    stamps.withValue { $0[fresh.folder] = stamp(4, 400) }
    await watch.check(fresh)
    #expect(log.withValue { $0 } == ["restart /h/.codex-fresh", "ask /h/.codex-fresh", "login /h/.codex-fresh a@example.com"])
}

/// P93: a home no read has placed yet is asked who is signed in (`identify`): a restart and a question, with no usage
/// read, whatever its auth.json says (a keychain login has none). Its next read asks nothing more, and a check of an
/// unchanged file does nothing. A failed question is asked again on the home's next read, without another restart; a
/// signed-out home is reported. `check` says when it restarted the home's server.
@Test func identifyAsksAHomeNoReadHasPlaced() async {
    let stamps = LockedBox<[String: AuthFileStamp]>([side.folder: stamp(1, 100)])
    let log = LockedBox<[String]>([])
    let answer = LockedBox<Result<SignInIdentity, ReadError>>(signedInAsA)
    let watch = CodexIdentityWatch(
        stat: { folder in stamps.withValue { $0[folder] } },
        restart: { folder in log.withValue { $0.append("restart \(folder)") } },
        identity: { account in
            log.withValue { $0.append("ask \(account.folder)") }
            return answer.withValue { $0 }
        },
        read: { account, _ in
            log.withValue { $0.append("read \(account.folder)") }
            return .failure(.timeout)
        },
        login: { account, email in
            log.withValue { $0.append("login \(account.folder) \(email?.email ?? "none")") }
            return true
        })
    #expect(await watch.identify(side) == signedInAsA)
    _ = await watch.read(side, now: t0)
    #expect(await watch.check(side) == false)
    stamps.withValue { $0[side.folder] = stamp(1, 101) }
    #expect(await watch.check(side) == true)
    #expect(log.withValue { $0 } == [
        "restart /h/.codex-side", "ask /h/.codex-side", "login /h/.codex-side a@example.com",
        "read /h/.codex-side",
        "restart /h/.codex-side", "ask /h/.codex-side", "login /h/.codex-side a@example.com",
    ])

    log.withValue { $0 = [] }
    answer.withValue { $0 = .failure(.timeout) }
    stamps.withValue { $0[fresh.folder] = stamp(5, 500) }
    #expect(await watch.identify(fresh) == .failure(.timeout))
    answer.withValue { $0 = .failure(.signInRequired) }
    _ = await watch.read(fresh, now: t0)
    stamps.withValue { $0[fresh.folder] = nil }
    #expect(await watch.identify(fresh) == .failure(.signInRequired))            // no auth.json: asked all the same
    #expect(log.withValue { $0 } == [
        "restart /h/.codex-fresh", "ask /h/.codex-fresh",
        "ask /h/.codex-fresh", "read /h/.codex-fresh",
        "restart /h/.codex-fresh", "ask /h/.codex-fresh", "login /h/.codex-fresh none",
    ])
}
