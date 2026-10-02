import Foundation
import Testing
@testable import JuiceCore

/// A clock the tests move by hand.
@MainActor
private final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

private let claudeA = Account(provider: .claude, folder: "/h/.claude", alias: "a")
private let claudeB = Account(provider: .claude, folder: "/h/.claude-b", alias: "b")
private let codexA = Account(provider: .codex, folder: "/h/.codex", alias: "default")

private func ok(_ account: some Identifiable<String>, at date: Date, used: Double = 20) -> Result<AccountReading, ReadError> {
    .success(AccountReading(accountID: account.id, readAt: date, windows: [UsageWindow(seconds: 18_000, usedPercent: used, resetsAt: nil)]))
}

@MainActor
private func makeScheduler(clock: FakeClock, log: LockedBox<[String]>, codexUsed: Double = 20) -> RefreshScheduler {
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    scheduler.setReader({ account, now in log.withValue { $0.append(account.id) }; return ok(account, at: now) }, for: .claude)
    scheduler.setReader({ account, now in log.withValue { $0.append(account.id) }; return ok(account, at: now, used: codexUsed) }, for: .codex)
    return scheduler
}

@MainActor
@Test func firstTickReadsEveryAccountWithClaudeStaggered() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    scheduler.setAccounts([claudeA, claudeB, codexA])
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(Set(log.withValue { $0 }) == Set([claudeA.id, codexA.id]))
    #expect(log.withValue { $0.count } == 2)
    clock.advance(20)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 3)
    #expect(log.withValue { $0.last } == claudeB.id)
}

@MainActor
@Test func nextDueFollowsTheIntervalAndTightensNearALimit() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log, codexUsed: 92)
    scheduler.setAccounts([claudeA, codexA])
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now + 300)
    #expect(scheduler.nextDue(for: codexA.id) == clock.now + 15)
    #expect(Set(log.withValue { $0 }) == Set([claudeA.id, codexA.id]))
    clock.advance(14)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 2)
    clock.advance(1)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 3)
    #expect(log.withValue { $0.last } == codexA.id)
}

@MainActor
@Test func retryAfterPausesTheAccountAndResultsAreDelivered() async {
    let clock = FakeClock()
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    scheduler.setReader({ _, _ in .failure(.rateLimited(retryAfter: 60)) }, for: .claude)
    let delivered = LockedBox<[ReadError?]>([])
    scheduler.onResult = { _, result, _ in
        if case .failure(let error) = result { delivered.withValue { $0.append(error) } } else { delivered.withValue { $0.append(nil) } }
    }
    scheduler.setAccounts([claudeA])
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(delivered.withValue { $0 } == [.rateLimited(retryAfter: 60)])
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now + 960)
}

@MainActor
@Test func rateLimitPauseSurvivesAManualRefreshAndABoost() async {
    let clock = FakeClock()
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    scheduler.setReader({ _, _ in .failure(.rateLimited(retryAfter: 60)) }, for: .claude)
    scheduler.setAccounts([claudeA])
    await scheduler.tick(); await scheduler.waitForInFlight()
    let pausedUntil = clock.now + 960                                // Retry-After plus the 15-minute margin
    #expect(scheduler.nextDue(for: claudeA.id) == pausedUntil)
    scheduler.refresh(id: claudeA.id)
    #expect(scheduler.nextDue(for: claudeA.id) == pausedUntil)       // a manual refresh may not read inside the pause
    scheduler.boost(id: claudeA.id, until: clock.now + 600)
    #expect(scheduler.nextDue(for: claudeA.id) == pausedUntil)       // nor may a boost pull the read forward
    clock.advance(960)
    scheduler.refresh(id: claudeA.id)
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now)         // once the pause is over, a manual refresh reads now
}

@MainActor
@Test func refreshAllLeavesARateLimitedAccountOutOfTheBatch() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    scheduler.setReader({ account, now in
        log.withValue { $0.append(account.id) }
        return account.id == claudeA.id ? .failure(.rateLimited(retryAfter: 60)) : ok(account, at: now)
    }, for: .claude)
    scheduler.setAccounts([claudeA, claudeB])
    await scheduler.tick(); await scheduler.waitForInFlight()        // claudeA reads first and is rate limited
    let pausedUntil = clock.now + 960
    #expect(scheduler.nextDue(for: claudeA.id) == pausedUntil)
    scheduler.refreshAll()
    #expect(scheduler.nextDue(for: claudeA.id) == pausedUntil)       // the pause survives a refresh-all
    #expect(scheduler.batchTotal == 1)                               // and the paused account isn't counted
    #expect(scheduler.nextDue(for: claudeB.id) == clock.now)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 } == [claudeA.id, claudeB.id])
    #expect(scheduler.batchDone == 1)
    #expect(!scheduler.isBatchRunning)                               // the batch isn't held open by the pause
    clock.advance(960)
    scheduler.refreshAll()
    #expect(scheduler.batchTotal == 2)                               // once the pause is over it joins again
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now)
}

@MainActor
@Test func manualRefreshJoinsARunningReadAndBoosts() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let gate = AsyncGate()
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    scheduler.setReader({ account, now in
        log.withValue { $0.append(account.id) }
        await gate.wait()
        return ok(account, at: now)
    }, for: .claude)
    scheduler.setAccounts([claudeA])
    await scheduler.tick()
    #expect(scheduler.isInFlight(claudeA.id))
    scheduler.refresh(id: claudeA.id)          // joins; no second launch
    await scheduler.tick()
    #expect(scheduler.inFlightCount == 1)
    await gate.open()
    await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 1)
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now + 120)   // boosted for 10 minutes after a manual refresh
    clock.advance(601)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now + 300)
}

@MainActor
@Test func refreshAllTracksProgressAndPauseStopsReads() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    scheduler.setAccounts([claudeA, claudeB, codexA])
    scheduler.pause()
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.isEmpty })
    scheduler.resume()
    scheduler.refreshAll()
    #expect(scheduler.isBatchRunning)
    #expect(scheduler.batchTotal == 3)
    await scheduler.tick(); await scheduler.waitForInFlight()
    clock.advance(20); await scheduler.tick(); await scheduler.waitForInFlight()
    clock.advance(20); await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(scheduler.batchDone == 3)
    #expect(!scheduler.isBatchRunning)
    #expect(Set(log.withValue { $0 }) == Set([claudeA.id, claudeB.id, codexA.id]))
}

@MainActor
@Test func resumeNeverReadsEarlierThanTheInterval() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    let t0 = clock.now
    scheduler.setAccounts([claudeA])
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 1)
    scheduler.pause()
    clock.advance(10)
    scheduler.resume()
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 1)                 // resume didn't force an early read
    #expect(scheduler.nextDue(for: claudeA.id) == t0 + 300)
    clock.advance(290)                                        // now at t0 + 300
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 2)
}

@MainActor
@Test func reAddedAccountKeepsItsSchedule() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    let t0 = clock.now
    scheduler.setAccounts([claudeA])
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(scheduler.nextDue(for: claudeA.id) == t0 + 300)
    scheduler.setAccounts([])
    clock.advance(10)
    scheduler.setAccounts([claudeA])
    #expect(scheduler.nextDue(for: claudeA.id) == t0 + 300)   // schedule survived the account briefly leaving
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 1)                  // still not due, so no read
}

@MainActor
@Test func boostPullsThePendingReadForward() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    let t0 = clock.now
    scheduler.setAccounts([claudeA, codexA])
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(scheduler.nextDue(for: claudeA.id) == t0 + 300)
    let codexDueBefore = scheduler.nextDue(for: codexA.id)
    scheduler.boost(provider: .claude, until: t0 + 600)
    scheduler.boost(id: codexA.id, until: t0 + 600)
    #expect(scheduler.nextDue(for: claudeA.id) == t0 + 120)
    #expect(scheduler.nextDue(for: codexA.id) == codexDueBefore)   // codex's boosted interval equals its normal one
    clock.advance(119)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.filter { $0 == claudeA.id }.count } == 1)
    clock.advance(1)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.filter { $0 == claudeA.id }.count } == 2)
}

@MainActor
@Test func removingAnAccountEndsTheBatch() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    scheduler.setAccounts([claudeA, claudeB, codexA])
    scheduler.refreshAll()
    await scheduler.tick(); await scheduler.waitForInFlight()     // claudeA and codexA finish; claudeB is staggered 20s out
    scheduler.setAccounts([claudeA, codexA])
    #expect(!scheduler.isBatchRunning)
    #expect(scheduler.batchTotal == 2)
    #expect(scheduler.batchDone == 2)
}

/// Quitting must not wait for a read that will not come back, and the read it drops must leave nothing behind.
@MainActor
@Test func stopCancelsInFlightReadsAndTheyRecordNothing() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let gate = AsyncGate()
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    let delivered = LockedBox(0)
    scheduler.onResult = { _, _, _ in delivered.withValue { $0 += 1 } }
    scheduler.setReader({ account, now in
        log.withValue { $0.append(account.id) }
        await gate.wait()
        return ok(account, at: now)
    }, for: .claude)
    scheduler.setAccounts([claudeA])
    let dueBefore = scheduler.nextDue(for: claudeA.id)
    await scheduler.tick()
    #expect(scheduler.inFlightCount == 1)

    scheduler.stop()
    #expect(scheduler.inFlightCount == 0)
    await gate.open()                                        // the reader answers after the cancellation
    for _ in 0..<50 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(50))

    #expect(delivered.withValue { $0 } == 0)                 // no result recorded
    #expect(scheduler.inFlightCount == 0)
    #expect(scheduler.nextDue(for: claudeA.id) == dueBefore) // and no new due time, so nothing was rescheduled
    #expect(log.withValue { $0 } == [claudeA.id])            // the read really did run, and only once
}

/// A read cancelled by `stop()` must not move the batch's progress either.
@MainActor
@Test func aCancelledReadDoesNotCountTowardTheBatch() async {
    let clock = FakeClock()
    let gate = AsyncGate()
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    scheduler.setReader({ account, now in await gate.wait(); return ok(account, at: now) }, for: .claude)
    scheduler.setAccounts([claudeA])
    scheduler.refreshAll()
    await scheduler.tick()
    #expect(scheduler.batchTotal == 1)
    scheduler.stop()
    await gate.open()
    for _ in 0..<50 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(scheduler.batchDone == 0)
}

/// A reading taken outside the schedule (first run's checks) has to count: the account's next read follows it
/// instead of happening again seconds later.
@MainActor
@Test func aSeededReadingSetsTheNextReadInsteadOfReadingAgain() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    let t0 = clock.now
    scheduler.setAccounts([claudeA])
    #expect(scheduler.nextDue(for: claudeA.id) == t0)               // brand new, so due now

    let readAt = t0.addingTimeInterval(-10)
    scheduler.seed(reading: AccountReading(accountID: claudeA.id, readAt: readAt,
                                           windows: [UsageWindow(seconds: 18_000, usedPercent: 20, resetsAt: nil)]),
                   for: claudeA.id)
    #expect(scheduler.nextDue(for: claudeA.id) == readAt + 300)     // the interval counts from the read, not from now

    // An older reading never pulls the read forward again.
    scheduler.seed(reading: AccountReading(accountID: claudeA.id, readAt: t0.addingTimeInterval(-3_600),
                                           windows: [UsageWindow(seconds: 18_000, usedPercent: 20, resetsAt: nil)]),
                   for: claudeA.id)
    #expect(scheduler.nextDue(for: claudeA.id) == readAt + 300)

    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.isEmpty })                           // nothing launched: the seeded reading is current
    clock.advance(290)                                              // now at readAt + 300
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 } == [claudeA.id])
}

@MainActor
@Test func seedingAnAccountTheSchedulerDoesNotKnowIsANoOp() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    scheduler.setAccounts([claudeA])
    scheduler.seed(reading: AccountReading(accountID: claudeB.id, readAt: clock.now,
                                           windows: [UsageWindow(seconds: 18_000, usedPercent: 20, resetsAt: nil)]),
                   for: claudeB.id)
    #expect(scheduler.nextDue(for: claudeB.id) == nil)
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now)
}

/// A 429 saved before a relaunch keeps the account quiet until Retry-After plus the margin, whatever the user clicks.
@MainActor
@Test func restoredRateLimitHoldsUntilRetryAfterPlusMargin() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    scheduler.setAccounts([claudeA])
    let at = clock.now - 100
    scheduler.restore(error: .rateLimited(retryAfter: 60), at: at, consecutiveFailures: 1, for: claudeA.id)
    let until = at + 1 + 60 + 900                                   // a saved date counts from a second later
    #expect(scheduler.nextDue(for: claudeA.id) == until)
    scheduler.refresh(id: claudeA.id)
    scheduler.refreshAll()
    #expect(scheduler.nextDue(for: claudeA.id) == until)
    #expect(scheduler.batchTotal == 0)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 }.isEmpty)
    clock.advance(until.timeIntervalSince(clock.now))
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 } == [claudeA.id])
}

/// A saved sign-in failure waits the hourly retry, but a manual refresh still reads (it is not a 429 pause).
@MainActor
@Test func restoredSignInRequiredWaitsButManualRefreshStillReads() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    scheduler.setAccounts([claudeA])
    scheduler.restore(error: .signInRequired, at: clock.now - 60, consecutiveFailures: 3, for: claudeA.id)
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now - 60 + 1 + 3_600)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 }.isEmpty)
    scheduler.refresh(id: claudeA.id)
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 } == [claudeA.id])
}

/// Restoring never moves a read earlier, ignores a missing or outdated CLI and ignores unknown accounts.
@MainActor
@Test func restoreNeverPullsAReadEarlier() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    scheduler.setAccounts([claudeA, claudeB])
    scheduler.seed(reading: AccountReading(accountID: claudeA.id, readAt: clock.now,
                                           windows: [UsageWindow(seconds: 18_000, usedPercent: 10, resetsAt: nil)]), for: claudeA.id)
    scheduler.restore(error: .timeout, at: clock.now - 10, consecutiveFailures: 1, for: claudeA.id)
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now + 300)
    let before = scheduler.nextDue(for: claudeB.id)
    scheduler.restore(error: .cliNotFound, at: clock.now, consecutiveFailures: 5, for: claudeB.id)
    scheduler.restore(error: .cliUpdateNeeded("x"), at: clock.now, consecutiveFailures: 5, for: claudeB.id)
    #expect(scheduler.nextDue(for: claudeB.id) == before)
    scheduler.restore(error: .rateLimited(retryAfter: 0), at: clock.now, consecutiveFailures: 1, for: "claude:/unknown")
    #expect(scheduler.nextDue(for: "claude:/unknown") == nil)
}

/// readings.json at launch: a failure newer than the last good reading wins; an older one is history.
/// Dates are saved to the whole second, so a failure in the same second as the good reading counts as newer.
@MainActor
@Test func seedFromRecordsRestoresTheNewerFailureOnly() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    scheduler.setAccounts([claudeA, claudeB, codexA])
    let t = clock.now - 30
    let good = { (id: String) in AccountReading(accountID: id, readAt: t, windows: [UsageWindow(seconds: 18_000, usedPercent: 10, resetsAt: nil)]) }
    scheduler.seed(from: [
        claudeA.id: AccountRecord(lastGood: good(claudeA.id), lastError: .rateLimited(retryAfter: 120), lastErrorAt: t + 10,
                                  lastAttemptAt: t + 10, consecutiveFailures: 1),
        claudeB.id: AccountRecord(lastGood: good(claudeB.id), lastError: .rateLimited(retryAfter: 120), lastErrorAt: t - 60,
                                  lastAttemptAt: t, consecutiveFailures: 0),
        codexA.id: AccountRecord(lastGood: good(codexA.id), lastError: .rateLimited(retryAfter: 120), lastErrorAt: t,
                                 lastAttemptAt: t, consecutiveFailures: 1),
    ])
    // Saved dates count from a second later: readings.json drops their fraction (see aRelaunchNeverEndsAWaitBeforeItsRule).
    #expect(scheduler.nextDue(for: claudeA.id) == t + 10 + 1 + 120 + 900)
    #expect(scheduler.nextDue(for: claudeB.id) == t + 1 + 300)          // the older 429 would have held it to t + 961
    #expect(scheduler.nextDue(for: codexA.id) == t + 1 + 120 + 900)     // same second as the good reading: restored
    scheduler.refreshAll()
    #expect(scheduler.batchTotal == 1)                                  // claudeB only: the older 429 left no pause
    #expect(scheduler.nextDue(for: claudeB.id) == clock.now)
}

/// An ordinary failure saved in readings.json keeps its place in the backoff: after two timeouts in a row the
/// relaunched account waits the second step (600 s, Claude's floor doubled) from the failure, not the old good
/// reading's interval, and the next timeout goes on to the third step (1,200 s) instead of starting again at the floor.
@MainActor
@Test func seedFromRecordsKeepsTheSavedBackoffStep() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    scheduler.setReader({ account, _ in log.withValue { $0.append(account.id) }; return .failure(.timeout) }, for: .claude)
    scheduler.setAccounts([claudeA])
    let good = AccountReading(accountID: claudeA.id, readAt: clock.now - 3_600,
                              windows: [UsageWindow(seconds: 18_000, usedPercent: 10, resetsAt: nil)])
    let at = clock.now - 10
    scheduler.seed(from: [claudeA.id: AccountRecord(lastGood: good, lastError: .timeout, lastErrorAt: at,
                                                    lastAttemptAt: at, consecutiveFailures: 2)])
    #expect(scheduler.nextDue(for: claudeA.id) == at + 1 + 600)        // a saved date counts from a second later
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 }.isEmpty)
    clock.advance(591)                                                  // now at + 601
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 } == [claudeA.id])
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now + 1_200)
}

/// A 429 on an account's first read leaves no good reading, and after a relaunch it still holds until Retry-After
/// plus the margin. An account listed before it with no record at all (one just added) does not stop the restore.
@MainActor
@Test func seedFromRecordsRestoresA429ThatHasNoGoodReading() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    scheduler.setAccounts([claudeA, claudeB])
    scheduler.seed(from: [claudeB.id: AccountRecord(lastError: .rateLimited(retryAfter: 60), lastErrorAt: clock.now,
                                                    lastAttemptAt: clock.now, consecutiveFailures: 1)])
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now)            // no record: due now, like any new account
    #expect(scheduler.nextDue(for: claudeB.id) == clock.now + 960)
    scheduler.refresh(id: claudeB.id)
    scheduler.refreshAll()
    #expect(scheduler.nextDue(for: claudeB.id) == clock.now + 960)
    #expect(scheduler.batchTotal == 1)                                  // claudeA only
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 } == [claudeA.id])
}

/// A readings.json the tests fill in memory, as the app's store is filled by `onResult`. It is never saved.
@MainActor
private func memoryReadings() -> ReadingsStore {
    ReadingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unsaved-\(UUID().uuidString)/readings.json"))
}

/// The app seeds after every account-list edit. An account already on the schedule keeps the schedule it has: after
/// signing in again outside Juice and clicking Refresh all, a rename made while the batch is still staggered does
/// not put the saved sign-in wait back on the account, nor the plain interval back on a boosted read, and the
/// batch completes.
@MainActor
@Test func anAccountListEditKeepsARefreshAllRead() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    let readings = memoryReadings()
    let t0 = clock.now
    readings.apply(ok(claudeA, at: t0 - 7_200), for: claudeA.id, at: t0 - 7_200)
    readings.apply(.failure(.signInRequired), for: claudeB.id, at: t0 - 1_200)
    readings.apply(.failure(.signInRequired), for: claudeB.id, at: t0 - 600)
    scheduler.onResult = { account, result, at in readings.apply(result, for: account.id, at: at) }

    scheduler.setAccounts([claudeA, claudeB]); scheduler.seed(from: readings.records)          // launch
    #expect(scheduler.nextDue(for: claudeB.id) == t0 - 600 + 1 + 3_600)
    scheduler.refreshAll()
    #expect(scheduler.nextDue(for: claudeB.id) == t0 + 20)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 } == [claudeA.id])
    #expect(scheduler.nextDue(for: claudeA.id) == t0 + 120)                                     // boosted

    clock.advance(5)
    let renamed = Account(provider: .claude, folder: claudeA.folder, alias: "renamed")
    scheduler.setAccounts([renamed, claudeB]); scheduler.seed(from: readings.records)          // accountsDidChange()
    #expect(scheduler.nextDue(for: claudeB.id) == t0 + 20)
    #expect(scheduler.nextDue(for: claudeA.id) == t0 + 120)

    clock.advance(15)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 } == [claudeA.id, claudeB.id])
    #expect(!scheduler.isBatchRunning)
    #expect(scheduler.batchDone == 2)
}

/// Review F5 of Task 2: a manual Refresh bypasses a saved backoff, and an account-list edit before the next tick
/// (here a Monitor toggle on another account) does not push that read back to the saved failure's backoff.
@MainActor
@Test func anAccountListEditKeepsAManualRefreshRead() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    let readings = memoryReadings()
    for _ in 1...5 { readings.apply(.failure(.timeout), for: claudeA.id, at: clock.now - 30) }
    scheduler.onResult = { account, result, at in readings.apply(result, for: account.id, at: at) }

    scheduler.setAccounts([claudeA, claudeB]); scheduler.seed(from: readings.records)          // launch
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now - 30 + 1 + 1_200)
    scheduler.refresh(id: claudeA.id)
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now)

    let unmonitored = Account(provider: .claude, folder: claudeB.folder, alias: claudeB.alias, monitored: false)
    scheduler.setAccounts([claudeA, unmonitored]); scheduler.seed(from: readings.records)      // accountsDidChange()
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 } == [claudeA.id])
}

/// An account added after launch (first run's profiles, or one added in Settings) is new to the schedule, so its
/// saved failure still sets its wait.
@MainActor
@Test func anAccountAddedAfterLaunchStillTakesItsSavedWait() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    let readings = memoryReadings()
    scheduler.setAccounts([claudeA]); scheduler.seed(from: readings.records)                   // launch, no records
    readings.apply(.failure(.signInRequired), for: claudeB.id, at: clock.now)                    // first run's check
    scheduler.setAccounts([claudeA, claudeB]); scheduler.seed(from: readings.records)          // accountsDidChange()
    #expect(scheduler.nextDue(for: claudeB.id) == clock.now + 3_600)
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 } == [claudeA.id])
}

/// First run: "Show dashboard" can put an account on the schedule while its check is still running, so it has no
/// record yet. When that check lands, the next seed takes its reading and the account is not read again seconds
/// later. An account this scheduler has read itself keeps its schedule: a Refresh made since survives that seed.
@MainActor
@Test func aCheckThatLandsAfterTheListWasSavedStillSetsTheSchedule() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    let readings = memoryReadings()
    let t0 = clock.now
    scheduler.onResult = { account, result, at in readings.apply(result, for: account.id, at: at) }
    scheduler.setAccounts([claudeA, claudeB]); scheduler.seed(from: readings.records)          // "Show dashboard"
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 } == [claudeA.id])
    readings.apply(ok(claudeB, at: t0), for: claudeB.id, at: t0)                                // claudeB's check lands
    scheduler.refresh(id: claudeA.id)

    scheduler.setAccounts([claudeA, claudeB]); scheduler.seed(from: readings.records)          // accountsDidChange()
    #expect(scheduler.nextDue(for: claudeB.id) == t0 + 300)
    #expect(scheduler.nextDue(for: claudeA.id) == t0)
    await scheduler.tick(); await scheduler.waitForInFlight()
    clock.advance(20)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 } == [claudeA.id, claudeA.id])
}

/// A saved date later than now means the Mac's clock was moved back after it was written. The wait then counts
/// from now, so a restored 429, backoff or reading interval is never longer than its rule, and a 429 pause that
/// Refresh cannot lift does not hold the account for the clock's error on top.
@MainActor
@Test func aSavedDateInTheFutureCountsFromNow() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    scheduler.setAccounts([claudeA, claudeB, codexA])
    let ahead = clock.now + 3_600
    scheduler.seed(from: [
        claudeA.id: AccountRecord(lastError: .rateLimited(retryAfter: 60), lastErrorAt: ahead, lastAttemptAt: ahead, consecutiveFailures: 1),
        claudeB.id: AccountRecord(lastGood: AccountReading(accountID: claudeB.id, readAt: ahead,
                                                           windows: [UsageWindow(seconds: 18_000, usedPercent: 10, resetsAt: nil)]),
                                  lastAttemptAt: ahead),
    ])
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now + 60 + 900)
    #expect(scheduler.nextDue(for: claudeB.id) == clock.now + 300)
    scheduler.restore(error: .timeout, at: ahead, consecutiveFailures: 1, for: codexA.id)
    #expect(scheduler.nextDue(for: codexA.id) == clock.now + 60)
    scheduler.refresh(id: claudeA.id)
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now + 60 + 900)
}

/// readings.json keeps whole seconds (JSONEncoder's `.iso8601` drops the fraction), so a saved date can be up to a
/// second before the real one. After a save and reload, a 429, a backoff and a good reading that fell 0.7 s into
/// their second still wait their full rule from the real time: Retry-After + 900 s holds across a relaunch.
@MainActor
@Test func aRelaunchNeverEndsAWaitBeforeItsRule() async throws {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("juice-readings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let saved = ReadingsStore(fileURL: url)
    let limited = clock.now - 99.3, read = clock.now - 199.3, failed = clock.now - 9.3
    saved.apply(.failure(.rateLimited(retryAfter: 60)), for: claudeA.id, at: limited)
    saved.apply(ok(claudeB, at: read), for: claudeB.id, at: read)
    saved.apply(.failure(.timeout), for: codexA.id, at: failed)
    try saved.save()
    let reloaded = ReadingsStore(fileURL: url)
    reloaded.load()
    #expect(reloaded.record(for: claudeA.id).lastErrorAt == limited - 0.7)          // the fraction was dropped

    let scheduler = makeScheduler(clock: clock, log: log)
    scheduler.setAccounts([claudeA, claudeB, codexA])
    scheduler.seed(from: reloaded.records)
    let paused = try #require(scheduler.nextDue(for: claudeA.id))
    #expect(paused >= limited + 60 + 900 && paused <= limited + 60 + 900 + 1)
    let interval = try #require(scheduler.nextDue(for: claudeB.id))
    #expect(interval >= read + 300 && interval <= read + 300 + 1)
    let backoff = try #require(scheduler.nextDue(for: codexA.id))
    #expect(backoff >= failed + 60 && backoff <= failed + 60 + 1)
    scheduler.refresh(id: claudeA.id)
    #expect(scheduler.nextDue(for: claudeA.id) == paused)
}

/// The clock was ahead when a good reading was saved and was set back before a 429, so the 429's saved date is
/// earlier than the reading's. The 429 was still the account's last attempt (readings.json dates the failure and the
/// attempt from one instant, and a success clears the failure), so a relaunch restores its pause: Retry-After + 900 s
/// holds from the real 429, and Refresh does not lift it. Cases: an hour ahead, a day ahead, and 5 s ahead with the
/// 429 2.5 s after the reading.
@MainActor
@Test func a429AfterTheClockWentBackHoldsAcrossARelaunch() async throws {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("juice-readings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let saved = ReadingsStore(fileURL: url)
    let t = clock.now
    let cases: [(account: Account, read: Date, limited: Date)] = [
        (claudeA, t + 3_600, t + 300),
        (codexA, t + 86_400, t + 300),
        (claudeB, t + 100.4, t + 97.9),
    ]
    for (account, read, limited) in cases {
        saved.apply(ok(account, at: read), for: account.id, at: read)
        saved.apply(.failure(.rateLimited(retryAfter: 60)), for: account.id, at: limited)
    }
    try saved.save()
    let reloaded = ReadingsStore(fileURL: url)
    reloaded.load()

    clock.advance(420)                                                                          // relaunch
    let scheduler = makeScheduler(clock: clock, log: log)
    scheduler.setAccounts([claudeA, claudeB, codexA])
    scheduler.seed(from: reloaded.records)
    for (account, _, limited) in cases {
        let paused = try #require(scheduler.nextDue(for: account.id))
        #expect(paused >= limited + 60 + 900 && paused <= limited + 60 + 900 + 1, "\(account.alias)")
        scheduler.refresh(id: account.id)
        #expect(scheduler.nextDue(for: account.id) == paused, "\(account.alias)")
    }
    scheduler.refreshAll()
    #expect(scheduler.batchTotal == 0)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 }.isEmpty)
}

/// Lets a test hold a reader open until it decides to release it.
actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Juice Island's Refresh all keeps to the floors (Diagnostics: "Never read faster than this, even on Refresh all"):
/// an account read less than its boosted interval ago stays out of the batch and only gets the boost, so a second
/// click right after a batch reads nothing again. An account never read, or read long enough ago, joins the batch.
@MainActor
@Test func refreshAllWithinFloorsNeverReadsSoonerThanTheBoostedInterval() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    let t0 = clock.now
    scheduler.setAccounts([claudeA, codexA])
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 2)

    clock.advance(30)
    scheduler.refreshAllWithinFloors()
    #expect(scheduler.batchTotal == 0 && !scheduler.isBatchRunning)
    #expect(scheduler.nextDue(for: claudeA.id) == t0 + 120)          // boosted, counted from its last read
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 2)                         // nothing read again

    clock.advance(30)                                                 // t0 + 60: Codex's floor has passed
    scheduler.refreshAllWithinFloors()
    #expect(scheduler.batchTotal == 1)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.last } == codexA.id && log.withValue { $0.count } == 3)
    #expect(scheduler.batchDone == 1 && !scheduler.isBatchRunning)

    clock.advance(60)                                                 // t0 + 120: Claude's boosted floor has passed
    scheduler.refreshAllWithinFloors()
    #expect(scheduler.batchTotal == 2)
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now)
}

/// A relaunch counts the floor from the last attempt saved in readings.json, failures included.
@MainActor
@Test func refreshAllWithinFloorsCountsFromTheSavedLastAttempt() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    let readings = memoryReadings()
    let t0 = clock.now
    readings.apply(ok(claudeA, at: t0 - 3_600), for: claudeA.id, at: t0 - 3_600)
    readings.apply(.failure(.signInRequired), for: claudeA.id, at: t0 - 40)
    readings.apply(ok(claudeB, at: t0 - 600), for: claudeB.id, at: t0 - 600)
    scheduler.setAccounts([claudeA, claudeB]); scheduler.seed(from: readings.records)
    scheduler.refreshAllWithinFloors()
    #expect(scheduler.batchTotal == 1)                               // claudeB only: claudeA tried 40 s ago
    #expect(scheduler.nextDue(for: claudeB.id) == t0)
    #expect(scheduler.nextDue(for: claudeA.id) == t0 - 40 + 1 + 120)  // boosted, never before its floor
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 } == [claudeB.id])
}

/// P93: a reading from outside the schedule was an attempt too, so Refresh all counts its floor from the newest one: a
/// merged record whose 429, dated its last attempt, came before its newest reading; a reading filed from another read;
/// and a folder's record taken when the folder is first placed, after the login was seeded.
@MainActor
@Test func refreshAllWithinFloorsCountsFromTheNewestReadingFromAnywhere() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    let t0 = clock.now
    func reading(_ account: Account, at date: Date) -> AccountReading {
        AccountReading(accountID: account.id, readAt: date, windows: [UsageWindow(seconds: 18_000, usedPercent: 20, resetsAt: nil)])
    }
    let merged = AccountRecord(lastGood: reading(claudeA, at: t0 - 60), lastError: .rateLimited(retryAfter: 60),
                               lastErrorAt: t0 - 1_000, lastAttemptAt: t0 - 1_000, consecutiveFailures: 1)
    scheduler.setAccounts([claudeA, claudeB, codexA])
    scheduler.seed(from: [claudeA.id: merged, claudeB.id: AccountRecord(lastGood: reading(claudeB, at: t0 - 3_600), lastAttemptAt: t0 - 3_600)])
    scheduler.seed(reading: reading(codexA, at: t0 - 10), for: codexA.id)
    scheduler.seed(record: AccountRecord(lastGood: reading(claudeB, at: t0 - 30), lastAttemptAt: t0 - 30), for: claudeB.id)
    scheduler.refreshAllWithinFloors()
    #expect(scheduler.batchTotal == 0)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0 }.isEmpty)

    clock.now = t0 + 61                                               // claudeA's and codexA's floors have passed
    scheduler.refreshAllWithinFloors()
    #expect(scheduler.batchTotal == 2 && scheduler.nextDue(for: claudeB.id) == t0 - 29 + 120)
}

/// A read that found no folder to read the login through is dropped: nothing is delivered, it leaves the batch counted,
/// and the login is tried again after its stagger, not on the next tick.
@MainActor
@Test func aSkippedReadRecordsNothingAndWaitsItsStagger() async {
    let clock = FakeClock()
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    let login = ReadTarget(id: "codex#0000000000000001", provider: .codex)
    let reads = LockedBox(0)
    scheduler.setReader({ _, _ in reads.withValue { $0 += 1 }; return .failure(RefreshScheduler.skipped) }, for: .codex)
    let delivered = LockedBox(0)
    scheduler.onResult = { _, _, _ in delivered.withValue { $0 += 1 } }
    scheduler.setTargets([login])
    scheduler.refreshAll()
    await scheduler.tick(); await scheduler.waitForInFlight()
    let t0 = clock.now
    #expect(reads.withValue { $0 } == 1 && delivered.withValue { $0 } == 0)
    #expect(scheduler.batchDone == 1 && !scheduler.isBatchRunning)
    #expect(scheduler.nextDue(for: login.id) == t0 + 2)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(reads.withValue { $0 } == 1)
    scheduler.refreshAllWithinFloors()                                // never tried: no floor holds it
    #expect(scheduler.batchTotal == 1)
}

/// P106: a read that failed after it may have reached the vendor is tried again no sooner than a normal read. A Codex
/// login at 92 % reads every 15 s, but after a timeout it waits Codex's normal floor (60 s) and then 120 s; Claude waits
/// 300 s, then 600 s. A good reading puts the account back on its cadence.
@MainActor
@Test func aFailedReadWaitsAtLeastTheNormalFloor() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let failing = LockedBox(false)
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    scheduler.setReader({ account, now in
        log.withValue { $0.append(account.id) }
        return failing.withValue { $0 } ? .failure(.timeout) : ok(account, at: now, used: 92)
    }, for: .codex)
    scheduler.setReader({ account, now in
        log.withValue { $0.append(account.id) }
        return failing.withValue { $0 } ? .failure(.failed("exit 1")) : ok(account, at: now)
    }, for: .claude)
    scheduler.setAccounts([claudeA, codexA])
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(scheduler.nextDue(for: codexA.id) == clock.now + 15)

    failing.withValue { $0 = true }
    clock.advance(15)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(scheduler.nextDue(for: codexA.id) == clock.now + 60)
    clock.advance(59)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 3)
    clock.advance(1)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 4)
    #expect(scheduler.nextDue(for: codexA.id) == clock.now + 120)

    let before = log.withValue { $0.count }
    clock.advance(300 - 75)                                           // Claude's floor since its first read
    await scheduler.tick(); await scheduler.waitForInFlight()
    // Codex, due since 195, reads at the same tick: the two reads run side by side, so the log's order between them
    // is not fixed (it was `last == Claude`, which failed when Codex's read finished second).
    #expect(log.withValue { Array($0[before...]) }.sorted() == [claudeA.id, codexA.id].sorted())
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now + 300)
    clock.advance(300)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now + 600)

    failing.withValue { $0 = false }
    clock.advance(600)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now + 300)
    #expect(scheduler.nextDue(for: codexA.id) == clock.now + 15)
}

/// P106 with the activity boost: sessions at work boost their login once a minute, and a boost pulls the next read up
/// to the boosted cadence, but never a failed read's wait. Claude's failed read waits its 300 s whatever the boosts; once
/// a read is good again, the boost holds it at 120 s.
@MainActor
@Test func aBoostNeverShortensAFailedReadsWait() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let failing = LockedBox(true)
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    scheduler.setReader({ account, now in
        log.withValue { $0.append(account.id) }
        return failing.withValue { $0 } ? .failure(.timeout) : ok(account, at: now)
    }, for: .claude)
    scheduler.setAccounts([claudeA])
    await scheduler.tick(); await scheduler.waitForInFlight()
    let failedAt = clock.now
    #expect(scheduler.nextDue(for: claudeA.id) == failedAt + 300)
    for _ in 0..<4 {
        clock.advance(60)
        scheduler.boost(id: claudeA.id, until: clock.now + 600)
        #expect(scheduler.nextDue(for: claudeA.id) == failedAt + 300)
        await scheduler.tick(); await scheduler.waitForInFlight()
    }
    #expect(log.withValue { $0.count } == 1)
    failing.withValue { $0 = false }
    clock.advance(60)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 2)
    #expect(scheduler.nextDue(for: claudeA.id) == clock.now + 120)   // good again, and still boosted
}

/// #12: Refresh on one account keeps to the floors and a 429 pause. Read too recently, the click only moves the next
/// read up to where the floor ends and says when; paused, it says when the pause ends and reads nothing sooner; a read
/// running is joined. A Codex account's floor follows its use (15 s at 90 % or more).
@MainActor
@Test func refreshOneAccountWithinFloorsSaysWhenItCanRead() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log, codexUsed: 92)
    let t0 = clock.now
    scheduler.setAccounts([claudeA, codexA])
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.count } == 2)

    clock.advance(30)
    #expect(scheduler.manualRead(for: claudeA.id) == .floor(until: t0 + 120))
    #expect(scheduler.manualRead(for: codexA.id) == .now)          // 92 % used: its floor is 15 s
    #expect(!scheduler.refreshWithinFloors(id: claudeA.id))
    #expect(scheduler.nextDue(for: claudeA.id) == t0 + 120)         // moved up from t0 + 300, never before the floor
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.filter { $0 == claudeA.id }.count } == 1)

    clock.advance(90)                                                // t0 + 120: the floor has passed
    #expect(scheduler.manualRead(for: claudeA.id) == .now)
    #expect(scheduler.refreshWithinFloors(id: claudeA.id))
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(log.withValue { $0.filter { $0 == claudeA.id }.count } == 2)
    #expect(scheduler.manualRead(for: "claude:/nowhere") == .unavailable)
}

@MainActor
@Test func refreshOneAccountNeverBreaksARateLimitPause() async {
    let clock = FakeClock()
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    let reads = LockedBox(0)
    scheduler.setReader({ _, _ in reads.withValue { $0 += 1 }; return .failure(.rateLimited(retryAfter: 60)) }, for: .claude)
    scheduler.setAccounts([claudeA])
    await scheduler.tick(); await scheduler.waitForInFlight()
    let pausedUntil = clock.now + 960
    clock.advance(200)
    #expect(scheduler.manualRead(for: claudeA.id) == .paused(until: pausedUntil))
    #expect(!scheduler.refreshWithinFloors(id: claudeA.id))
    #expect(scheduler.nextDue(for: claudeA.id) == pausedUntil)
    clock.advance(700)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(reads.withValue { $0 } == 1)
}

/// P731: a reading older than the one the scheduler holds never sets the login's floor. Codex's floor follows its newest
/// reading's use (60 s under 75 %, 15 s at 90 % or more), so a reading from before a window reset, at 95 %, handed on
/// after a newer one at 20 % (a folder that answered for the login while another folder read it), or a read that began
/// before a newer reading was handed on and ended after it, would read the login every 15 s instead of every 60.
@MainActor
@Test func anOlderReadingNeverSetsTheFloorOfANewerOne() async {
    let clock = FakeClock(), log = LockedBox<[String]>([])
    let scheduler = makeScheduler(clock: clock, log: log)
    @Sendable func reading(at date: Date, used: Double) -> AccountReading {
        AccountReading(accountID: codexA.id, readAt: date, windows: [UsageWindow(seconds: 18_000, usedPercent: used, resetsAt: nil)])
    }
    scheduler.setAccounts([codexA])
    await scheduler.tick(); await scheduler.waitForInFlight()         // 20 % used: the next read in 60 s
    let t0 = clock.now
    scheduler.seed(reading: reading(at: t0 - 5, used: 95), for: codexA.id)
    clock.advance(20)
    #expect(scheduler.manualRead(for: codexA.id) == .floor(until: t0 + 60))

    let hold = LockedBox(true)
    scheduler.setReader({ _, now in
        while hold.withValue({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        return .success(reading(at: now, used: 95))
    }, for: .codex)
    clock.now = t0 + 60
    await scheduler.tick()
    #expect(scheduler.isInFlight(codexA.id))
    scheduler.seed(reading: reading(at: t0 + 61, used: 20), for: codexA.id)
    clock.now = t0 + 62
    hold.withValue { $0 = false }
    await scheduler.waitForInFlight()
    #expect(scheduler.nextDue(for: codexA.id) == t0 + 62 + 60)
    // A clock set back an hour: the read that begins and ends then is the newest, as before (95 %: 15 s).
    clock.now = t0 - 3_600
    scheduler.refresh(id: codexA.id)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(scheduler.nextDue(for: codexA.id) == t0 - 3_600 + 15)
}

/// P731: after a clock set back, the reading from before it is dated later than any read after it. When the first outcome
/// after the set back is a failure (offline right after a wake), every later read counts as ending after the last
/// attempt; it is still the newest, so the floor follows it (20 %: 60 s), not the 95 % from before the set back (15 s).
@MainActor
@Test func aClockSetBackThenAFailureNeverKeepsTheFloorFromBeforeIt() async {
    let clock = FakeClock()
    let used = LockedBox<Double>(95), fail = LockedBox(false)
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { clock.now }, sleep: { _ in })
    scheduler.setReader({ account, now in
        if fail.withValue({ $0 }) { return .failure(.offline) }
        return ok(account, at: now, used: used.withValue { $0 })
    }, for: .codex)
    scheduler.setAccounts([codexA])
    let t0 = clock.now
    await scheduler.tick(); await scheduler.waitForInFlight()        // 95 % used: 15 s
    #expect(scheduler.nextDue(for: codexA.id) == t0 + 15)
    clock.now = t0 - 3_600
    fail.withValue { $0 = true }
    scheduler.refresh(id: codexA.id)
    await scheduler.tick(); await scheduler.waitForInFlight()
    fail.withValue { $0 = false }
    used.withValue { $0 = 20 }
    clock.now = max(scheduler.nextDue(for: codexA.id) ?? clock.now, clock.now)
    scheduler.refresh(id: codexA.id)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(scheduler.nextDue(for: codexA.id) == clock.now + 60)
}

/// P731: a relaunch after a clock set back. The record's last good reading (95 %) was read before the clock went back;
/// the seed clamps its attempt to now, and the first read after the relaunch (20 %) is the newest, so the floor is 60 s.
@MainActor
@Test func aRelaunchAfterAClockSetBackNeverKeepsTheFloorFromBeforeIt() async {
    let clock = FakeClock()
    let t0 = clock.now
    let old = AccountReading(accountID: codexA.id, readAt: t0, windows: [UsageWindow(seconds: 18_000, usedPercent: 95, resetsAt: nil)])
    clock.now = t0 - 3_600
    let scheduler = makeScheduler(clock: clock, log: LockedBox<[String]>([]), codexUsed: 20)
    scheduler.setAccounts([codexA])
    scheduler.seed(from: [codexA.id: AccountRecord(lastGood: old, lastAttemptAt: t0 + 2)])
    clock.now = scheduler.nextDue(for: codexA.id) ?? clock.now
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(scheduler.nextDue(for: codexA.id) == clock.now + 60)
}
