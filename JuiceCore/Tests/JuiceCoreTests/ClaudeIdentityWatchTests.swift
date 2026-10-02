import Foundation
import Testing
@testable import JuiceCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let lab = Account(provider: .claude, folder: "/h/.claude-lab", alias: "lab")
private let asA: Result<SignInIdentity, ReadError> = .success(SignInIdentity(email: "a@example.com", plan: "max"))

/// A watch on stand-ins: `stamps` is the folder's `.claude.json` stamp, `answer` what `claude auth status` says, `plan`
/// the plan the usage read reports (nil: the read fails with sign-in required). While `rewrites` holds, a usage read
/// rewrites `.claude.json` (the CLI may, and so does a `/login` made while it runs). `log` gets one line per call.
private func makeWatch(stamps: LockedBox<AuthFileStamp?>, log: LockedBox<[String]>, answer: LockedBox<Result<SignInIdentity, ReadError>>,
                       plan: LockedBox<String?> = LockedBox("max"), rewrites: LockedBox<Bool> = LockedBox(false), mayRead: Bool = true,
                       signingIn: LockedBox<Bool> = LockedBox(false)) -> ClaudeIdentityWatch {
    ClaudeIdentityWatch(
        stat: { _ in stamps.withValue { $0 } },
        identity: { _ in
            log.withValue { $0.append("ask") }
            return answer.withValue { $0 }
        },
        read: { account, now in
            log.withValue { $0.append("read") }
            if rewrites.withValue({ $0 }) { touch(stamps) }
            guard let plan = plan.withValue({ $0 }) else { return .failure(.signInRequired) }
            return .success(AccountReading(accountID: account.id, readAt: now, plan: plan,
                                           windows: [UsageWindow(seconds: 18_000, usedPercent: 20, resetsAt: nil)]))
        },
        isSigningIn: { _ in signingIn.withValue { $0 } },
        login: { _, email in
            log.withValue { $0.append("login \(email?.email ?? "none")") }
            return mayRead
        })
}

private func touch(_ stamps: LockedBox<AuthFileStamp?>) {
    stamps.withValue { $0 = $0.map { AuthFileStamp(inode: $0.inode, modifiedSeconds: $0.modifiedSeconds + 1) } }
}

/// The default `~/.claude` runs its CLI without `CLAUDE_CONFIG_DIR`, and that CLI writes `~/.claude.json`, so that file
/// is the one stat-ed for it; any other folder's is inside the folder. A fake home, with both files present.
@Test func theDefaultFolderIsStampedByTheClaudeJSONInTheHome() throws {
    let files = FileManager.default
    let home = files.temporaryDirectory.appendingPathComponent("claude-home-\(UUID().uuidString)").path
    defer { try? files.removeItem(atPath: home) }
    for folder in [".claude", ".claude-lab"] {
        try files.createDirectory(atPath: "\(home)/\(folder)", withIntermediateDirectories: true)
        #expect(files.createFile(atPath: "\(home)/\(folder)/.claude.json", contents: Data()))
    }
    #expect(files.createFile(atPath: "\(home)/.claude.json", contents: Data()))
    let homeFile = try #require(AuthFileStamp.of(path: "\(home)/.claude.json"))
    #expect(AuthFileStamp.of(path: "\(home)/.claude/.claude.json") != homeFile)
    #expect(ClaudeIdentityWatch.stamp(folder: "\(home)/.claude", home: home) == homeFile)
    #expect(ClaudeIdentityWatch.stamp(folder: "\(home)/.claude/", home: home) == homeFile)
    #expect(ClaudeIdentityWatch.stamp(folder: "\(home)/.claude-lab", home: home) == AuthFileStamp.of(path: "\(home)/.claude-lab/.claude.json"))
    #expect(ClaudeIdentityWatch.stamp(folder: "\(home)/.claude-lab", home: home) != nil)
}

/// The first read in a run asks; the reading carries the email found. After that a read asks whenever `.claude.json`
/// changed since the last answer, however soon (the login's floor bounds how often). A check between reads asks about a
/// change at most once every half hour.
@Test func aClaudeReadAsksFirstAndWheneverItsFileChanged() async throws {
    let stamps = LockedBox<AuthFileStamp?>(AuthFileStamp(inode: 1, modifiedSeconds: 100))
    let log = LockedBox<[String]>([])
    let answer = LockedBox(asA)
    let watch = makeWatch(stamps: stamps, log: log, answer: answer)
    #expect(try await watch.read(lab, now: t0).get().email == "a@example.com")
    #expect(try await watch.read(lab, now: t0 + 300).get().email == nil)           // unchanged since
    #expect(log.withValue { $0 } == ["ask", "login a@example.com", "read", "read"])

    touch(stamps)                                                                  // a session, or a /login
    answer.withValue { $0 = .success(SignInIdentity(email: "b@example.com", plan: "max")) }
    #expect(try await watch.read(lab, now: t0 + 420).get().email == "b@example.com")
    #expect(log.withValue { Array($0.suffix(3)) } == ["ask", "login b@example.com", "read"])

    touch(stamps)
    await watch.check(lab, now: t0 + 600)                                          // a check waits its half hour
    #expect(log.withValue { $0.count } == 7)
    #expect(try await watch.read(lab, now: t0 + 720).get().email == "b@example.com")   // a read does not
    #expect(log.withValue { Array($0.suffix(3)) } == ["ask", "login b@example.com", "read"])
    touch(stamps)
    await watch.check(lab, now: t0 + 720 + 1_800)
    #expect(log.withValue { Array($0.suffix(2)) } == ["ask", "login b@example.com"])
}

/// `.claude.json` rewritten while a read runs: a `/login` then, or the read's own rewrite, which a `stat` cannot tell
/// apart. Either way the next read asks before it reads, so the other account's usage is never filed under this login,
/// whether or not the read asked. A read that rewrote nothing leaves the next one to its file.
@Test func aRewriteWhileAReadRunsIsAskedAboutByTheNextRead() async throws {
    let stamps = LockedBox<AuthFileStamp?>(AuthFileStamp(inode: 1, modifiedSeconds: 100))
    let log = LockedBox<[String]>([])
    let answer = LockedBox(asA)
    let rewrites = LockedBox(false)
    let watch = makeWatch(stamps: stamps, log: log, answer: answer, rewrites: rewrites)
    _ = try await watch.read(lab, now: t0)
    rewrites.withValue { $0 = true }                                               // a /login to b while it reads
    #expect(try await watch.read(lab, now: t0 + 300).get().email == nil)
    rewrites.withValue { $0 = false }
    answer.withValue { $0 = .success(SignInIdentity(email: "b@example.com", plan: "max")) }
    #expect(try await watch.read(lab, now: t0 + 600).get().email == "b@example.com")
    #expect(try await watch.read(lab, now: t0 + 900).get().email == nil)
    #expect(log.withValue { $0 } == ["ask", "login a@example.com", "read", "read", "ask", "login b@example.com", "read", "read"])

    touch(stamps)                                                                  // a read that asks
    rewrites.withValue { $0 = true }                                               // and a /login back to a meanwhile
    #expect(try await watch.read(lab, now: t0 + 1_200).get().email == "b@example.com")
    rewrites.withValue { $0 = false }
    answer.withValue { $0 = asA }
    #expect(try await watch.read(lab, now: t0 + 1_500).get().email == "a@example.com")
    #expect(log.withValue { Array($0.suffix(6)) } == ["ask", "login b@example.com", "read", "ask", "login a@example.com", "read"])
}

/// A read whose question fails makes no usage read, since nobody could say whose usage it would be; the next read asks
/// again.
@Test func aReadWhoseQuestionFailsReadsNothing() async {
    let log = LockedBox<[String]>([])
    let answer = LockedBox<Result<SignInIdentity, ReadError>>(.failure(.timeout))
    let watch = makeWatch(stamps: LockedBox(AuthFileStamp(inode: 1, modifiedSeconds: 100)), log: log, answer: answer)
    #expect(await watch.read(lab, now: t0) == .failure(.timeout))
    answer.withValue { $0 = asA }
    #expect(await watch.read(lab, now: t0 + 30).map(\.plan) == .success("max"))
    #expect(log.withValue { $0 } == ["ask", "ask", "login a@example.com", "read"])
}

/// A read that did not ask and comes back on another plan asks right after it (a switch between plans shows at once);
/// the reading carries the email found. The live model moves it to that login.
@Test func anotherPlanAsksRightAfterTheRead() async throws {
    let stamps = LockedBox<AuthFileStamp?>(nil)
    let log = LockedBox<[String]>([])
    let answer = LockedBox(asA)
    let plan = LockedBox<String?>("max")
    let watch = makeWatch(stamps: stamps, log: log, answer: answer, plan: plan)
    _ = await watch.read(lab, now: t0)
    plan.withValue { $0 = "pro" }
    answer.withValue { $0 = .success(SignInIdentity(email: "b@example.com", plan: "pro")) }
    #expect(try await watch.read(lab, now: t0 + 300).get().email == "b@example.com")
    #expect(log.withValue { $0 } == ["ask", "login a@example.com", "read", "read", "ask"])
}

/// Signed out: the answer ends the read with sign-in required and no usage read. A signed-out folder is asked on each
/// read, at most once a minute; inside that minute it is not read either.
@Test func aSignedOutFolderIsAskedAndNeverReadForUsage() async {
    let stamps = LockedBox<AuthFileStamp?>(nil)
    let log = LockedBox<[String]>([])
    let answer = LockedBox<Result<SignInIdentity, ReadError>>(.failure(.signInRequired))
    let watch = makeWatch(stamps: stamps, log: log, answer: answer)
    #expect(await watch.read(lab, now: t0) == .failure(.signInRequired))
    #expect(await watch.read(lab, now: t0 + 30) == .failure(.signInRequired))
    answer.withValue { $0 = asA }
    #expect(await watch.read(lab, now: t0 + 3_600).map(\.plan) == .success("max"))
    #expect(log.withValue { $0 } == ["ask", "ask", "login a@example.com", "read"])
}

/// Signed out, asked less than a minute ago, and `.claude.json` changed since (a `/login` in a terminal): the read asks
/// before its usage read, so the reading carries the email.
@Test func aSignedOutFolderWhoseFileChangedIsAskedBeforeItsRead() async throws {
    let stamps = LockedBox<AuthFileStamp?>(AuthFileStamp(inode: 1, modifiedSeconds: 100))
    let log = LockedBox<[String]>([])
    let answer = LockedBox<Result<SignInIdentity, ReadError>>(.failure(.signInRequired))
    let watch = makeWatch(stamps: stamps, log: log, answer: answer)
    #expect(await watch.read(lab, now: t0) == .failure(.signInRequired))
    touch(stamps)
    answer.withValue { $0 = asA }
    #expect(try await watch.read(lab, now: t0 + 20).get().email == "a@example.com")
    #expect(log.withValue { $0 } == ["ask", "ask", "login a@example.com", "read"])
}

/// Sign In finished less than a minute after the folder was found signed out, with `.claude.json` unchanged: the flow's
/// own answer stands, so the next read neither ends signed out nor asks again.
@Test func aSignInStandsForTheWatchsOwnAnswer() async throws {
    let log = LockedBox<[String]>([])
    let answer = LockedBox<Result<SignInIdentity, ReadError>>(.failure(.signInRequired))
    let watch = makeWatch(stamps: LockedBox(AuthFileStamp(inode: 1, modifiedSeconds: 100)), log: log, answer: answer)
    #expect(await watch.read(lab, now: t0) == .failure(.signInRequired))
    answer.withValue { $0 = asA }
    watch.signedIn(lab, at: t0 + 20)
    #expect(try await watch.read(lab, now: t0 + 30).get().plan == "max")
    await watch.check(lab, now: t0 + 40)
    #expect(log.withValue { $0 } == ["ask", "read"])
}

/// `login` says the folder holds another login than the one its read is for: no usage read.
@Test func aClaudeFolderHoldingAnotherLoginIsNotRead() async {
    let log = LockedBox<[String]>([])
    let watch = makeWatch(stamps: LockedBox(nil), log: log, answer: LockedBox(asA), mayRead: false)
    #expect(await watch.read(lab, now: t0) == .failure(CodexIdentityWatch.held))
    #expect(log.withValue { $0 } == ["ask", "login a@example.com"])
}

/// Between reads (`check`): a folder seen first only has its stamp noted. After that it asks only when the file changed,
/// on the read's terms, and reports what it found, a sign-out included, once. A failed question is asked again later.
/// A folder signing in is left alone, read or check.
@Test func aCheckAsksOnlyWhenTheFileChanged() async {
    let stamps = LockedBox<AuthFileStamp?>(AuthFileStamp(inode: 1, modifiedSeconds: 100))
    let log = LockedBox<[String]>([])
    let answer = LockedBox(asA)
    let signingIn = LockedBox(false)
    let watch = makeWatch(stamps: stamps, log: log, answer: answer, signingIn: signingIn)
    await watch.check(lab, now: t0)
    #expect(log.withValue { $0 }.isEmpty)
    _ = await watch.read(lab, now: t0)                                              // ask, login, read
    await watch.check(lab, now: t0 + 2_000)                                         // unchanged
    stamps.withValue { $0 = AuthFileStamp(inode: 1, modifiedSeconds: 900) }
    answer.withValue { $0 = .failure(.signInRequired) }
    await watch.check(lab, now: t0 + 2_000)                                         // `/logout`
    await watch.check(lab, now: t0 + 2_100)                                         // unchanged, still signed out
    stamps.withValue { $0 = AuthFileStamp(inode: 1, modifiedSeconds: 950) }
    answer.withValue { $0 = .failure(.timeout) }
    await watch.check(lab, now: t0 + 2_200)                                         // fails: asked again later
    answer.withValue { $0 = .success(SignInIdentity(email: "b@example.com", plan: "max")) }
    await watch.check(lab, now: t0 + 2_230)                                         // within the minute
    await watch.check(lab, now: t0 + 2_260)
    signingIn.withValue { $0 = true }
    stamps.withValue { $0 = AuthFileStamp(inode: 2, modifiedSeconds: 990) }
    await watch.check(lab, now: t0 + 9_000)
    _ = await watch.read(lab, now: t0 + 9_000)
    #expect(log.withValue { $0 } == [
        "ask", "login a@example.com", "read",
        "ask", "login none",
        "ask",
        "ask", "login b@example.com",
        "read",
    ])
}

/// A folder that waits from launch (a pause or a sign-out restored from readings.json) has not been read in this run.
/// Its first change still gets asked by a check, so a login made meanwhile shows before the wait ends.
@Test func aCheckAsksAFolderNotReadYetOnceItsFileChanges() async {
    let stamps = LockedBox<AuthFileStamp?>(AuthFileStamp(inode: 1, modifiedSeconds: 100))
    let log = LockedBox<[String]>([])
    let watch = makeWatch(stamps: stamps, log: log, answer: LockedBox(asA))
    await watch.check(lab, now: t0)
    await watch.check(lab, now: t0 + 5)
    touch(stamps)
    await watch.check(lab, now: t0 + 10)
    #expect(log.withValue { $0 } == ["ask", "login a@example.com"])
}

/// P93: a folder no read has placed yet is asked once (`identify`), with no usage read, and its next read does not ask
/// again. A signed-out answer is reported.
@Test func identifyAsksAFolderNoReadHasPlaced() async {
    let stamps = LockedBox<AuthFileStamp?>(AuthFileStamp(inode: 1, modifiedSeconds: 100))
    let log = LockedBox<[String]>([])
    let answer = LockedBox(asA)
    let watch = makeWatch(stamps: stamps, log: log, answer: answer)
    #expect(await watch.identify(lab, now: t0) == asA)
    _ = await watch.read(lab, now: t0 + 300)
    await watch.check(lab, now: t0 + 600)
    answer.withValue { $0 = .failure(.signInRequired) }
    #expect(await watch.identify(lab, now: t0 + 900) == .failure(.signInRequired))
    #expect(log.withValue { $0 } == ["ask", "login a@example.com", "read", "ask", "login none"])
}

/// P580: the reading of a read that asked names the organization the answer named, as it names the email.
@Test func aReadCarriesTheOrganizationItsQuestionFound() async throws {
    let stamps = LockedBox<AuthFileStamp?>(AuthFileStamp(inode: 1, modifiedSeconds: 100))
    let log = LockedBox<[String]>([])
    let answer = LockedBox<Result<SignInIdentity, ReadError>>(.success(SignInIdentity(email: "a@example.com", plan: "team", org: "00000000000000a1",
                                                                                    orgName: "Research Lab")))
    let watch = makeWatch(stamps: stamps, log: log, answer: answer, plan: LockedBox("team"))
    let reading = try await watch.read(lab, now: t0).get()
    #expect(reading.login == LoginIdentity(email: "a@example.com", org: "00000000000000a1", orgName: "Research Lab"))
    #expect(try await watch.read(lab, now: t0 + 300).get().org == nil)          // not asked: the live model fills it in
}

/// P581: an Anthropic Console login's `get_usage` is a signed-out folder's. Its folder's CLI says it is signed in, so
/// the read is its answer that it has no plan limits, asked again on each read that did not ask; once the CLI says
/// signed out, it is a sign-out as before.
@Test func aConsoleLoginsReadIsNoLimitsNeverASignOut() async throws {
    let stamps = LockedBox<AuthFileStamp?>(AuthFileStamp(inode: 1, modifiedSeconds: 100))
    let log = LockedBox<[String]>([])
    let console = SignInIdentity(email: "a@example.com", plan: nil, org: "00000000000000a1", orgName: "Research Lab", usageBilled: true)
    let answer = LockedBox<Result<SignInIdentity, ReadError>>(.success(console))
    let watch = makeWatch(stamps: stamps, log: log, answer: answer, plan: LockedBox(nil))
    #expect(await watch.read(lab, now: t0) == .failure(.noLimitsReported))
    #expect(log.withValue { $0 } == ["ask", "login a@example.com", "read"])
    #expect(await watch.read(lab, now: t0 + 300) == .failure(.noLimitsReported))
    #expect(log.withValue { Array($0.suffix(3)) } == ["read", "ask", "login a@example.com"])
    // A question that fails says nothing either way: its failure, never a sign-out.
    answer.withValue { $0 = .failure(.timeout) }
    #expect(await watch.read(lab, now: t0 + 600) == .failure(.timeout))
    answer.withValue { $0 = .success(console) }
    #expect(await watch.read(lab, now: t0 + 900) == .failure(.noLimitsReported))
    answer.withValue { $0 = .failure(.signInRequired) }
    #expect(await watch.read(lab, now: t0 + 1_200) == .failure(.signInRequired))
    // A claude.ai login's sign-in failure is asked about only on the watch's own terms, as before.
    let other = LockedBox<[String]>([])
    let plain = makeWatch(stamps: LockedBox(AuthFileStamp(inode: 2, modifiedSeconds: 100)), log: other, answer: LockedBox(asA), plan: LockedBox(nil))
    #expect(await plain.read(lab, now: t0) == .failure(.signInRequired))
    #expect(other.withValue { $0 } == ["ask", "login a@example.com", "read"])
}
