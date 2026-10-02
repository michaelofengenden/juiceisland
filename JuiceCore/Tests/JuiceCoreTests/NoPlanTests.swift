import Foundation
import Testing
@testable import JuiceCore

/// P360: a Claude login whose CLI says it has no plan limits (`rate_limits_available:false` with a plan named), as when its
/// subscription ended. Fixtures and fictional folders only.
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let work = Account(provider: .claude, folder: "/h/.claude-work", alias: "Work")
private let lab = Account(provider: .claude, folder: "/h/.claude-lab", alias: "Lab")
private let noPlan: Result<AccountReading, ReadError> = .failure(.noPlanLimits)

private func good(_ id: String, at date: Date) -> Result<AccountReading, ReadError> {
    .success(AccountReading(accountID: id, readAt: date, plan: "pro", windows: [UsageWindow(seconds: 18_000, usedPercent: 30, resetsAt: date + 3_600)]))
}

/// The streak after `outcomes`, each at its own time.
private func streak(_ outcomes: [(TimeInterval, Result<AccountReading, ReadError>)]) -> NoPlanStreak? {
    outcomes.reduce(nil) { streak, outcome in NoPlanStreak.after(outcome.1, at: t0 + outcome.0, previous: streak) }
}

// MARK: The answer

@Test func theExplicitNoPlanAnswerIsItsOwnError() throws {
    func read(_ json: String) -> ReadError? {
        do {
            _ = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8)).reading(accountID: work.id, readAt: t0)
            return nil
        } catch {
            return error as? ReadError
        }
    }
    let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: fixture("claude-get-usage-no-plan"))
    #expect(throws: ReadError.noPlanLimits) { try response.reading(accountID: work.id, readAt: t0) }
    // Limits merely missing, or no answer about them, are another incomplete reading; no plan at all is signed out.
    #expect(read(#"{"subscription_type":"max","rate_limits_available":true,"rate_limits":null}"#) == .incomplete("plan limits missing"))
    #expect(read(#"{"subscription_type":"max"}"#) == .incomplete("plan limits missing"))
    #expect(read(#"{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}"#) == .signInRequired)
    #expect(ReadError.noPlanLimits != .incomplete("plan limits missing"))
}

/// Through the CLI: the fake answers the no-plan fixture, and the read fails with the no-plan error, nothing else.
@Test func aReadThroughTheCLISaysNoPlan() async throws {
    let reader = ClaudeCLIReader(executable: try fixtureURL("fake-claude", "sh"), timeout: .seconds(10),
                                 extraEnvironment: ["FAKE_FIXTURE": try fixtureURL("claude-get-usage-no-plan", "json").path])
    #expect(await reader.read(work, now: t0) == .failure(.noPlanLimits))
}

// MARK: The streak

@Test func oneAnswerIsNeverNoPlan() {
    #expect(streak([(0, noPlan)]) == NoPlanStreak(since: t0, last: t0, reads: 1))
    #expect(streak([(0, noPlan)])?.holds == false)
    // Three answers inside half an hour are not enough either: the span keeps a passing state out.
    #expect(streak([(0, noPlan), (120, noPlan), (1_799, noPlan)])?.holds == false)
    // Two answers an hour apart are not enough: three looks.
    #expect(streak([(0, noPlan), (3_600, noPlan)])?.holds == false)
}

@Test func threeAnswersOverHalfAnHourAreNoPlan() {
    let backoff = streak([(0, noPlan), (300, noPlan), (900, noPlan), (2_100, noPlan)])
    #expect(backoff == NoPlanStreak(since: t0, last: t0 + 2_100, reads: 4) && backoff?.holds == true)
    #expect(streak([(0, noPlan), (900, noPlan), (1_800, noPlan)])?.holds == true)
}

/// A read that says nothing about the plan keeps the streak as it is; a good read, a sign-in failure or another
/// incomplete answer ends it.
@Test func onlyAnAnswerAboutTheAccountEndsTheStreak() {
    let three: [(TimeInterval, Result<AccountReading, ReadError>)] = [(0, noPlan), (900, noPlan), (1_800, noPlan)]
    for kept in [ReadError.timeout, .offline, .cliNotFound, .cliUpdateNeeded("x"), .failed("exit 1"), .rateLimited(retryAfter: 60),
                 RefreshScheduler.skipped] {
        #expect(streak(three + [(2_000, .failure(kept))]) == streak(three), "\(kept)")
    }
    for ended in [good(work.id, at: t0 + 2_000), .failure(.signInRequired), .failure(.incomplete("plan limits missing")),
                  .failure(.incomplete("no windows reported"))] {
        #expect(streak(three + [(2_000, ended)]) == nil)
    }
    // A streak that started again counts from its new first answer.
    #expect(streak(three + [(2_000, good(work.id, at: t0)), (2_100, noPlan)]) == NoPlanStreak(since: t0 + 2_100, last: t0 + 2_100, reads: 1))
}

// MARK: The record

@MainActor
@Test func aLoginsRecordKeepsItsStreakAndFilesCarryIt() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("juice-noplan-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let logins = LoginsStore(fileURL: dir.appendingPathComponent("logins.json"))
    let id = logins.place("work@example.com", in: work, now: t0).login
    for at in [0.0, 900, 1_800] { logins.apply(noPlan, to: id, at: t0 + at) }
    let record = try #require(logins.logins[id]?.record)
    #expect(record.isNoPlan && record.noPlan == NoPlanStreak(since: t0, last: t0 + 1_800, reads: 3))
    #expect(record.lastError == .noPlanLimits && record.consecutiveFailures == 3)
    try logins.save()
    let again = LoginsStore(fileURL: logins.fileURL)
    again.load()
    #expect(again.logins[id]?.record == record)

    // readings.json's record by folder carries it the same way, and a record from before it decodes with none.
    let readings = ReadingsStore(fileURL: dir.appendingPathComponent("readings.json"))
    for at in [0.0, 900, 1_800] { readings.apply(noPlan, for: work.id, at: t0 + at) }
    #expect(readings.record(for: work.id).isNoPlan)
    let old = #"{"lastError":{"incomplete":{"_0":"plan limits not available"}},"lastErrorAt":"2027-01-15T08:00:00Z","consecutiveFailures":66}"#
    let decoded = try JSONDecoder.juice.decode(AccountRecord.self, from: Data(old.utf8))
    #expect(decoded.noPlan == nil && !decoded.isNoPlan && decoded.consecutiveFailures == 66)
    // A record salvaged field by field keeps it too.
    let damaged = #"{"lastGood":7,"lastError":{"incomplete":{"_0":"plan limits not available"}},"noPlan":{"since":"2027-01-15T08:00:00Z","last":"2027-01-15T08:40:00Z","reads":3}}"#
    let salvaged = try JSONDecoder.juice.decode(SalvagedRecord.self, from: Data(damaged.utf8))
    #expect(salvaged.damaged && salvaged.record.isNoPlan)

    // A good read clears it.
    logins.apply(good(id, at: t0 + 2_000), to: id, at: t0 + 2_000)
    #expect(logins.logins[id]?.record?.noPlan == nil)
}

/// Two folders' records of one login: the streak still running comes with the merge, and a good read after it ends it.
@Test func aMergeKeepsAStreakNoGoodReadEnded() throws {
    let id = LoginsStore.id(provider: .claude, email: "work@example.com")
    let held = NoPlanStreak(since: t0, last: t0 + 1_800, reads: 3)
    let failing = AccountRecord(lastError: .noPlanLimits, lastErrorAt: t0 + 1_800, lastAttemptAt: t0 + 1_800, consecutiveFailures: 3, noPlan: held)
    let older = AccountRecord(lastGood: try good(id, at: t0 - 3_600).get(), lastAttemptAt: t0 - 3_600)
    let merged = try #require(LoginsStore.merge([older, failing], as: id, now: t0 + 1_900))
    #expect(merged.noPlan == held && merged.isNoPlan && merged.lastError == .noPlanLimits)
    let newer = AccountRecord(lastGood: try good(id, at: t0 + 2_000).get(), lastAttemptAt: t0 + 2_000)
    #expect(LoginsStore.merge([failing, newer], as: id, now: t0 + 2_100)?.noPlan == nil)
}

// MARK: The battery

@Test func aNoPlanBatteryIsDimmedNeverNextAndNeverAttention() throws {
    let noPlanID = LoginsStore.id(provider: .claude, email: "work@example.com"), okID = LoginsStore.id(provider: .claude, email: "lab@example.com")
    let now = t0 + 1_900
    let records = [
        noPlanID: AccountRecord(lastGood: try good(noPlanID, at: now - 60).get(), lastError: .noPlanLimits, lastErrorAt: now - 100,
                                lastAttemptAt: now - 100, consecutiveFailures: 3, noPlan: NoPlanStreak(since: t0, last: now - 100, reads: 3)),
        okID: AccountRecord(lastGood: try good(okID, at: now - 60).get(), lastAttemptAt: now - 60),
    ]
    let panel = PanelModelBuilder.build(entries: [PanelEntry(id: noPlanID, alias: "work", provider: .claude),
                                                  PanelEntry(id: okID, alias: "lab", provider: .claude)],
                                        records: records, signingIn: [], money: [], now: now)
    let row = try #require(panel.rows.first)
    #expect(row.batteries.map(\.state) == [.noPlan, .available(percentLeft: 70, isLow: false)])
    #expect(row.batteries.map(\.isNext) == [false, true] && !panel.attentionNeeded)
    #expect(row.batteries[0].hoverLabel == "work · " + NoPlanStreak.hover)
    // Not a battery that could be available: out of the count, and no doubt about the rest.
    #expect(row.availability == Rules.Availability(available: 1, total: 1, isKnown: true))
    // A streak that does not hold yet leaves the battery as it was (its reading is fresh here).
    var young = records
    young[noPlanID]?.noPlan = NoPlanStreak(since: now - 200, last: now - 100, reads: 3)
    #expect(PanelModelBuilder.state(of: noPlanID, records: young, signingIn: [], provider: .claude, now: now) == .available(percentLeft: 70, isLow: false))
    // Signing in still comes first.
    #expect(PanelModelBuilder.state(of: noPlanID, records: records, signingIn: [noPlanID], provider: .claude, now: now) == .signingIn)
}

// MARK: The schedule

@MainActor
private final class Clock { var now = t0 }

@MainActor
private func scheduler(_ clock: Clock, answer: LockedBox<Result<AccountReading, ReadError>>, log: LockedBox<[String]>) -> RefreshScheduler {
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    scheduler.setReader({ target, now in
        log.withValue { $0.append(target.id) }
        return answer.withValue { $0 }
    }, for: .claude)
    return scheduler
}

@MainActor
private func tick(_ scheduler: RefreshScheduler) async {
    await scheduler.tick()
    await scheduler.waitForInFlight()
}

/// Every read: the backoff until the streak holds, then every 6 hours; Refresh all and a boost leave it there; its own
/// Refresh reads it within the floor, and a good read puts it back on the floor.
@MainActor
@Test func aNoPlanLoginIsReadEverySixHoursUntilAGoodRead() async throws {
    let clock = Clock(), log = LockedBox<[String]>([]), answer = LockedBox(noPlan)
    let scheduler = scheduler(clock, answer: answer, log: log)
    scheduler.setTargets([work.target])
    await tick(scheduler)                                                   // 0
    #expect(scheduler.nextDue(for: work.id) == t0 + 300 && !scheduler.isNoPlan(work.id))
    for at in [300.0, 900] {                                                 // the backoff: 5 and 15 minutes
        clock.now = t0 + at
        await tick(scheduler)
    }
    #expect(scheduler.nextDue(for: work.id) == t0 + 900 + 1_200 && !scheduler.isNoPlan(work.id))
    clock.now = t0 + 2_100                                                   // 35 minutes: three answers over half an hour
    await tick(scheduler)
    #expect(scheduler.isNoPlan(work.id) && scheduler.nextDue(for: work.id) == t0 + 2_100 + NoPlanStreak.interval)
    #expect(log.withValue { $0.count } == 4)

    // Refresh all and a boost neither read it nor move it up.
    clock.now = t0 + 3_000
    scheduler.refreshAllWithinFloors()
    scheduler.boost(id: work.id, until: clock.now + 600)
    await tick(scheduler)
    #expect(scheduler.batchTotal == 0 && log.withValue { $0.count } == 4)
    #expect(scheduler.nextDue(for: work.id) == t0 + 2_100 + NoPlanStreak.interval)

    // A timeout at its 6-hour read keeps it No plan and waits 6 hours again.
    clock.now = t0 + 2_100 + NoPlanStreak.interval
    answer.withValue { $0 = .failure(.timeout) }
    await tick(scheduler)
    #expect(scheduler.isNoPlan(work.id) && scheduler.nextDue(for: work.id) == clock.now + NoPlanStreak.interval)

    // Its own Refresh (the owner resubscribed) reads it within the floor; a good read ends it and the floor is back.
    clock.now += 200
    #expect(scheduler.manualRead(for: work.id) == .now)
    answer.withValue { $0 = good(work.id, at: t0) }
    scheduler.refreshWithinFloors(id: work.id)
    await tick(scheduler)
    #expect(!scheduler.isNoPlan(work.id) && scheduler.nextDue(for: work.id) == clock.now + 120)
}

/// A relaunch: the record's streak brings the 6-hour wait back, counted from its last answer, and only a streak that
/// holds does.
@MainActor
@Test func aRelaunchKeepsTheSixHourWait() async throws {
    let clock = Clock(), log = LockedBox<[String]>([]), answer = LockedBox(noPlan)
    clock.now = t0 + 7_200
    let held = AccountRecord(lastError: .noPlanLimits, lastErrorAt: t0 + 1_800, lastAttemptAt: t0 + 1_800, consecutiveFailures: 3,
                             noPlan: NoPlanStreak(since: t0, last: t0 + 1_800, reads: 3))
    let young = AccountRecord(lastError: .noPlanLimits, lastErrorAt: t0 + 1_800, lastAttemptAt: t0 + 1_800, consecutiveFailures: 2,
                              noPlan: NoPlanStreak(since: t0 + 900, last: t0 + 1_800, reads: 2))
    let scheduler = scheduler(clock, answer: answer, log: log)
    scheduler.setTargets([lab.target, work.target])
    scheduler.seed(from: [work.id: held, lab.id: young])
    #expect(scheduler.isNoPlan(work.id) && !scheduler.isNoPlan(lab.id))
    #expect(scheduler.nextDue(for: work.id) == t0 + 1_801 + NoPlanStreak.interval)
    #expect(scheduler.nextDue(for: lab.id) == clock.now)                    // its backoff ended long ago
    await tick(scheduler)
    #expect(log.withValue { $0 } == [lab.id])
    // That third answer, well over half an hour after its first, makes it No plan too.
    #expect(scheduler.isNoPlan(lab.id) && scheduler.nextDue(for: lab.id) == clock.now + NoPlanStreak.interval)
}

// MARK: No limits (P581)

/// A login billed by usage (an organization with no limits, a Console login) runs the same streak and waits, and is
/// No limits in its own words, never "subscription ended?"; the latest answer decides which.
@Test func aLoginBilledByUsageIsNoLimitsAfterTheSameStreak() throws {
    let usage: Result<AccountReading, ReadError> = .failure(.noLimitsReported)
    let held = try #require(streak([(0, usage), (900, usage), (1_800, usage)]))
    #expect(held.holds && held.usageBased == true && held.reads == 3)
    #expect(streak([(0, usage), (900, usage)])?.holds == false)
    #expect(streak([(0, usage), (900, usage), (1_800, noPlan)])?.usageBased == nil)
    #expect(streak([(0, usage), (900, usage), (1_800, usage), (2_000, .failure(.timeout))]) == held)
    #expect(streak([(0, usage), (900, usage), (1_800, usage), (2_000, good(lab.id, at: t0 + 2_000))]) == nil)

    let usageID = LoginsStore.id(provider: .claude, email: "lab@example.com"), okID = LoginsStore.id(provider: .claude, email: "work@example.com")
    let now = t0 + 1_900
    let records = [
        usageID: AccountRecord(lastError: .noLimitsReported, lastErrorAt: now - 100, lastAttemptAt: now - 100, consecutiveFailures: 3, noPlan: held),
        okID: AccountRecord(lastGood: try good(okID, at: now - 60).get(), lastAttemptAt: now - 60),
    ]
    #expect(records[usageID]?.isNoLimits == true && records[usageID]?.isNoPlan == true)
    let panel = PanelModelBuilder.build(entries: [PanelEntry(id: usageID, alias: "lab · Research Lab", provider: .claude),
                                                  PanelEntry(id: okID, alias: "work", provider: .claude)],
                                        records: records, signingIn: [], money: [], now: now)
    let row = try #require(panel.rows.first)
    #expect(row.batteries.map(\.state) == [.noLimits, .available(percentLeft: 70, isLow: false)])
    #expect(row.batteries.map(\.isNext) == [false, true] && !panel.attentionNeeded)
    #expect(row.batteries[0].hoverLabel == "lab · Research Lab · " + NoPlanStreak.usageHover)
    #expect(!row.batteries[0].hoverLabel.contains("subscription"))
    #expect(row.availability == Rules.Availability(available: 1, total: 1, isKnown: true))
    // Before the streak holds it is a reading still to come, as No plan's is.
    var young = records
    young[usageID]?.noPlan = NoPlanStreak(since: now - 200, last: now - 100, reads: 2, usageBased: true)
    #expect(PanelModelBuilder.state(of: usageID, records: young, signingIn: [], provider: .claude, now: now) == .unknown)
}

/// Its reads: the backoff until the streak holds, then every 6 hours, as No plan's.
@MainActor
@Test func aNoLimitsLoginIsReadEverySixHours() async throws {
    let clock = Clock(), log = LockedBox<[String]>([]), answer = LockedBox<Result<AccountReading, ReadError>>(.failure(.noLimitsReported))
    let scheduler = scheduler(clock, answer: answer, log: log)
    scheduler.setTargets([lab.target])
    for at in [0.0, 300, 900, 2_100] {
        clock.now = t0 + at
        await tick(scheduler)
    }
    #expect(scheduler.isNoPlan(lab.id) && scheduler.nextDue(for: lab.id) == t0 + 2_100 + NoPlanStreak.interval)
    clock.now = t0 + 3_000
    scheduler.refreshAllWithinFloors()
    await tick(scheduler)
    #expect(log.withValue { $0.count } == 4)
}
