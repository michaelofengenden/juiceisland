import Foundation
import Testing
@testable import JuiceCore

/// P1550 to P1553: a Codex login whose reads keep failing while its login file has not changed in over 9 days is "login
/// lapsed", never "rate limited"; one over 8 days old whose reads still work says so in its hover; and a lapsed login whose
/// file changes is read again at its floor, not after its pause. Every login file here is a fake in a temporary home,
/// dated with `touch -t`; only its modification date is looked at (a `stat`), never what it holds.
@Suite(.serialized)
struct LoginLapseTests {
    /// A temporary home with a Codex folder whose fake login file was last changed `daysAgo` days before `now`.
    struct Home {
        let url: URL
        let folder: String

        init(daysAgo: Double, now: Date = Date()) throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("juice-lapse-\(UUID().uuidString)", isDirectory: true)
            folder = url.appendingPathComponent(".codex-side").path
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let file = folder + "/auth.json"
            try Data("fake".utf8).write(to: URL(fileURLWithPath: file))
            try Self.touch(file, at: now.addingTimeInterval(-daysAgo * 86_400))
        }

        /// `touch -t [[CC]YY]MMDDhhmm[.SS]`, in this Mac's time zone, as `touch` reads it.
        static func touch(_ path: String, at date: Date) throws {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = .current
            format.dateFormat = "yyyyMMddHHmm.ss"
            let touch = Process()
            touch.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
            touch.arguments = ["-t", format.string(from: date), path]
            try touch.run()
            touch.waitUntilExit()
            guard touch.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        }

        /// The login file's date, by `stat` alone (`AuthFileStamp`, the identity watch's).
        var changed: Date? { AuthFileStamp.of(folder: folder)?.modified }

        func cleanUp() { try? FileManager.default.removeItem(at: url) }
    }

    static let side = Account(provider: .codex, folder: "/Users/person1/.codex-side", alias: "Side")

    static func reading(at date: Date, used: Double = 30) -> AccountReading {
        AccountReading(accountID: side.id, readAt: date, plan: "plus", windows: [
            UsageWindow(seconds: 18_000, usedPercent: used, resetsAt: date + 3_600),
            UsageWindow(seconds: 604_800, usedPercent: 10, resetsAt: date + 86_400),
        ])
    }

    /// A good reading a day ago, then `failures` reads that failed with `error`, the last a minute ago.
    static func record(failures: Int, error: ReadError = .rateLimited(retryAfter: nil), now: Date) -> AccountRecord {
        var record = AccountRecord()
        record.take(.success(reading(at: now - 86_400)), at: now - 86_400)
        for index in 0..<failures { record.take(.failure(error), at: now - 60 - Double(failures - 1 - index) * 900) }
        return record
    }

    static func panel(_ record: AccountRecord, changed: Date?, now: Date) -> BatteryModel? {
        let entry = PanelEntry(id: side.id, alias: "Side", provider: .codex)
        return PanelModelBuilder.build(entries: [entry], records: [side.id: record], signingIn: [], money: [], now: now,
                                       loginFiles: changed.map { [side.id: $0] } ?? [:]).rows.first?.batteries.first
    }

    @Test func aLoginFileTenDaysOldWithReadsFailingTwiceIsLapsedNeverRateLimited() throws {
        let now = Date()
        let home = try Home(daysAgo: 10, now: now)
        defer { home.cleanUp() }
        let changed = try #require(home.changed)
        #expect(abs(changed.timeIntervalSince(now - 10 * 86_400)) < 2)
        for error in [ReadError.rateLimited(retryAfter: nil), .failed("401"), .timeout, .incomplete("no windows reported")] {
            let record = Self.record(failures: 2, error: error, now: now)
            #expect(Rules.loginLapsed(provider: .codex, record: record, loginFileChanged: changed, now: now))
            let battery = try #require(Self.panel(record, changed: changed, now: now))
            #expect(battery.state == .loginLapsed)
            #expect(battery.hoverLabel == "Side · Open Codex once to refresh this login")
            #expect(!battery.hoverLabel.lowercased().contains("rate"))
        }
    }

    @Test func aRateLimitOnAFreshLoginStaysARateLimit() throws {
        let now = Date()
        let home = try Home(daysAgo: 2, now: now)
        defer { home.cleanUp() }
        let record = Self.record(failures: 5, now: now)
        #expect(!Rules.loginLapsed(provider: .codex, record: record, loginFileChanged: home.changed, now: now))
        let battery = try #require(Self.panel(record, changed: home.changed, now: now))
        guard case .stale = battery.state else { Issue.record("\(battery.state) is not stale"); return }
        #expect(!battery.hoverLabel.contains(Rules.loginLapsedWords))
        #expect(record.lastError == .rateLimited(retryAfter: nil))
    }

    @Test func oneFailureNineDaysExactlyOrACauseOfItsOwnIsNoLapse() throws {
        let now = Date()
        let old = now - 12 * 86_400
        #expect(!Rules.loginLapsed(provider: .codex, record: Self.record(failures: 1, now: now), loginFileChanged: old, now: now))
        #expect(!Rules.loginLapsed(provider: .codex, record: Self.record(failures: 3, now: now), loginFileChanged: now - Rules.loginLapseAge,
                                   now: now))
        #expect(Rules.loginLapsed(provider: .codex, record: Self.record(failures: 3, now: now),
                                  loginFileChanged: now - Rules.loginLapseAge - 60, now: now))
        for error in [ReadError.signInRequired, .cliNotFound, .cliUpdateNeeded("old"), .offline] {
            #expect(!Rules.loginLapsed(provider: .codex, record: Self.record(failures: 3, error: error, now: now), loginFileChanged: old, now: now))
        }
        // No login file (a login kept in the keychain), and a Claude login, never lapse.
        #expect(!Rules.loginLapsed(provider: .codex, record: Self.record(failures: 3, now: now), loginFileChanged: nil, now: now))
        #expect(!Rules.loginLapsed(provider: .claude, record: Self.record(failures: 3, now: now), loginFileChanged: old, now: now))
        // Sign-in needed comes first.
        let signedOut = Self.record(failures: 3, error: .signInRequired, now: now)
        #expect(Self.panel(signedOut, changed: old, now: now)?.state == .signInNeeded)
    }

    /// P1553: over 8 days old, its reads working, the hover ends with the early word; nothing else changes.
    @Test func anAgingLoginSaysItRefreshesWhenCodexIsNextUsed() throws {
        let now = Date()
        let home = try Home(daysAgo: 8.5, now: now)
        defer { home.cleanUp() }
        var record = AccountRecord()
        record.take(.success(Self.reading(at: now - 30)), at: now - 30)
        let battery = try #require(Self.panel(record, changed: home.changed, now: now))
        #expect(battery.state == .available(percentLeft: 70, isLow: false) && battery.loginAging)
        #expect(battery.hoverLabel.hasSuffix(" · Login refreshes when you next use Codex"))
        let plain = try #require(Self.panel(record, changed: now - 7 * 86_400, now: now))
        #expect(!plain.loginAging && plain.state == battery.state)
        #expect(plain.hoverLabel + " · " + Rules.loginAgingWords == battery.hoverLabel)
        // Failing, it is lapsed (or not yet) instead, never both.
        #expect(!Rules.loginAging(provider: .codex, record: Self.record(failures: 1, now: now), loginFileChanged: home.changed, now: now))
    }

    /// P1552 across a relaunch: a login whose reads kept failing while its file changed after the last of them was
    /// refreshed while the app was not running. A file that changed before the last failure, one failure, a cause of its
    /// own, a record with no attempt, and a Claude login say nothing.
    @Test func aLoginFileThatChangedAfterTheFailedReadsWasRefreshedWhileAway() throws {
        let now = Date()
        let home = try Home(daysAgo: 0, now: now)
        defer { home.cleanUp() }
        let changed = try #require(home.changed)
        let failing = Self.record(failures: 2, now: now - 120)
        #expect(Rules.loginRefreshedSinceFailures(provider: .codex, record: failing, loginFileChanged: changed))
        let last = try #require(failing.lastAttemptAt)
        #expect(!Rules.loginRefreshedSinceFailures(provider: .codex, record: failing, loginFileChanged: last))
        #expect(!Rules.loginRefreshedSinceFailures(provider: .codex, record: failing, loginFileChanged: last - 10 * 86_400))
        #expect(!Rules.loginRefreshedSinceFailures(provider: .codex, record: Self.record(failures: 1, now: now - 120), loginFileChanged: changed))
        for error in [ReadError.signInRequired, .cliNotFound, .cliUpdateNeeded("old"), .offline] {
            let own = Self.record(failures: 3, error: error, now: now - 120)
            #expect(!Rules.loginRefreshedSinceFailures(provider: .codex, record: own, loginFileChanged: changed))
        }
        #expect(!Rules.loginRefreshedSinceFailures(provider: .codex, record: AccountRecord(consecutiveFailures: 2), loginFileChanged: changed))
        #expect(!Rules.loginRefreshedSinceFailures(provider: .claude, record: failing, loginFileChanged: changed))
        #expect(!Rules.loginRefreshedSinceFailures(provider: .codex, record: failing, loginFileChanged: nil))
    }

    @Test func settingsRowsShowTheLapseToo() throws {
        let now = Date()
        let login = Login(provider: .codex, email: "side@example.com", record: Self.record(failures: 2, now: now))
        let lists = LoginList.build(accounts: [Self.side], logins: [login.id: login], folders: [Self.side.id: .signedIn(login: login.id)],
                                    signingIn: [], now: now, home: "/Users/person1", loginFiles: [login.id: now - 10 * 86_400])
        let row = try #require(lists.first?.logins.first)
        #expect(row.battery.state == .loginLapsed)
        #expect(row.battery.hoverLabel == "side · Open Codex once to refresh this login")
        // A lapsed login may have use left: the row's availability is not known, not "0 of 1".
        #expect(Rules.availability(states: [.loginLapsed]).isKnown == false)
    }
}

/// A clock the scheduler tests move by hand.
@MainActor
private final class LapseClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

/// P1552: the read after a lapsed login's file changed comes at the floor, not after the pause.
@MainActor
@Test func aLapsedLoginIsReadAtItsFloorOnceItsFileChanges() async {
    let clock = LapseClock()
    let account = ReadTarget(id: "codex:side", provider: .codex, monitored: true)
    let failing = LockedBox(true), reads = LockedBox(0)
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    scheduler.setReader({ _, now in
        reads.withValue { $0 += 1 }
        if failing.withValue({ $0 }) { return .failure(.rateLimited(retryAfter: nil)) }
        return .success(AccountReading(accountID: "codex:side", readAt: now, windows: [UsageWindow(seconds: 18_000, usedPercent: 20, resetsAt: nil)]))
    }, for: .codex)
    scheduler.setTargets([account])
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(reads.withValue { $0 } == 1)
    #expect(scheduler.manualRead(for: account.id) == .paused(until: clock.now + 900))
    // The owner ran Codex 10 s later: the read waits only for the 60 s floor, counted from the failed read.
    let failedAt = clock.now
    clock.now += 10
    failing.withValue { $0 = false }
    #expect(scheduler.readAfterLoginRefresh(id: account.id))
    #expect(scheduler.nextDue(for: account.id) == failedAt + 60)
    #expect(scheduler.manualRead(for: account.id) == .floor(until: failedAt + 60))
    clock.now = failedAt + 59
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(reads.withValue { $0 } == 1)
    clock.now = failedAt + 60
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(reads.withValue { $0 } == 2)
    #expect(scheduler.nextDue(for: account.id) == clock.now + 60)
    // Long after its last read, it is read at once; an unknown or switched-off login is left alone.
    clock.now += 3_600
    #expect(scheduler.readAfterLoginRefresh(id: account.id) && scheduler.nextDue(for: account.id) == clock.now)
    #expect(!scheduler.readAfterLoginRefresh(id: "codex:unknown"))
    scheduler.setTargets([ReadTarget(id: account.id, provider: .codex, monitored: false)])
    #expect(!scheduler.readAfterLoginRefresh(id: account.id))
}
