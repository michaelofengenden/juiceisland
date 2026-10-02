import Foundation
import Observation

/// Decides when each account is read and runs the reads. Time and sleeping are injected so tests drive it by hand. An
/// account here is a `ReadTarget`: a login in Juice Island, a profile folder in standalone Juice.
@MainActor
@Observable
public final class RefreshScheduler {
    public typealias Reader = @Sendable (ReadTarget, Date) async -> Result<AccountReading, ReadError>

    /// What a reader returns when it found nothing to read the account through (every folder that held it holds another
    /// login now, or is signed out): the read is dropped, recording nothing, and the account is tried again after its
    /// provider's stagger if it is still listed.
    public nonisolated static let skipped = ReadError.incomplete("no folder holds this login")

    public let policy: RefreshPolicy
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    private var readers: [Provider: Reader] = [:]
    private var accounts: [ReadTarget] = []
    private var due: [String: Date] = [:]
    private var lastReading: [String: AccountReading] = [:]
    private var failures: [String: Int] = [:]
    private var boostedUntil: [String: Date] = [:]
    /// Spec §9.5: after a 429 the account stays quiet until Retry-After plus the margin, even if the user asks for a read.
    private var pausedUntil: [String: Date] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// Accounts whose last read found no CLI to run (`cliFound(for:)`).
    private var missingCLI: Set<String> = []
    /// Each account's reads that said it has no plan limits, in a row (P360), as its record keeps them: once the streak
    /// holds, the account is read only every `NoPlanStreak.interval` and stays out of Refresh all and the boost.
    private var noPlan: [String: NoPlanStreak] = [:]
    /// When each account was last tried, read or failed: this run's reads, a reading made outside the schedule, or the
    /// last attempt or reading saved in readings.json, whichever came last. `refreshAllWithinFloors()` counts its floor
    /// from here.
    private var lastAttempt: [String: Date] = [:]
    /// Accounts whose schedule is already this run's own: `seed(from:)` has taken their record from readings.json,
    /// or this scheduler has read them.
    private var seededFromRecords: Set<String> = []
    private var loop: Task<Void, Never>?
    private var batch: Set<String> = []

    public private(set) var isPaused = false
    public private(set) var batchTotal = 0
    public private(set) var batchDone = 0
    /// Called on the main actor after every read, before the next due time is computed.
    public var onResult: ((ReadTarget, Result<AccountReading, ReadError>, Date) -> Void)?

    public init(policy: RefreshPolicy = RefreshPolicy(), now: @escaping () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.policy = policy
        self.now = now
        self.sleep = sleep
    }

    public func setReader(_ reader: @escaping Reader, for provider: Provider) { readers[provider] = reader }

    /// The provider's CLI is gone: its accounts' reads fail at once as "CLI not found", launching nothing.
    public func removeReader(for provider: Provider) { readers[provider] = nil }

    /// Replaces the account list with profile folders (standalone Juice's unit): `setTargets` of their targets.
    public func setAccounts(_ newAccounts: [Account]) { setTargets(newAccounts.map(\.target)) }

    /// Replaces the account list. Accounts seen for the first time are due now, staggered per provider; an account
    /// that already has a schedule keeps it, even if it briefly left the list (its failure count and boost persist too).
    public func setTargets(_ newAccounts: [ReadTarget]) {
        let current = now()
        var offsets: [Provider: TimeInterval] = [:]
        for account in newAccounts where due[account.id] == nil {
            let offset = offsets[account.provider] ?? 0
            due[account.id] = current.addingTimeInterval(offset)
            offsets[account.provider] = offset + policy.stagger(for: account.provider)
        }
        accounts = newAccounts
        // An account that left the list (or was unmonitored) no longer counts toward a running batch.
        batch = batch.filter { id in newAccounts.contains { $0.id == id && $0.monitored } }
        if batchTotal > 0 { batchTotal = batchDone + batch.count }
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                guard let sleep = self?.sleep else { return }
                try? await sleep(.seconds(1))
            }
        }
    }

    public var isRunning: Bool { loop != nil }

    /// Stops the loop and drops every read still running. A read cancelled here records nothing: no result is
    /// delivered, the due time, failure count and rate-limit pause are all left as they were, and it does not move
    /// a batch's progress. Quitting must not wait for a CLI that has stopped answering.
    public func stop() {
        loop?.cancel()
        loop = nil
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    /// Takes a reading made outside the schedule — first run checks every profile it found — as this account's
    /// last one, so its next read follows that reading instead of happening again moments later. It only ever
    /// pushes the read later, so a rate-limit pause or a boost already in place still wins; an account the
    /// scheduler does not know is ignored.
    public func seed(reading: AccountReading, for id: String) {
        seed(reading: reading, readAt: reading.readAt, for: id)
    }

    /// `seed(reading:for:)` counting the interval from `readAt` instead of the reading's own date. The reading was an
    /// attempt too, so Refresh all counts its floor from it.
    private func seed(reading: AccountReading, readAt: Date, for id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        keepNewest(reading, for: id)
        lastAttempt[id] = max(lastAttempt[id] ?? .distantPast, readAt)
        let next = readAt.addingTimeInterval(policy.interval(for: account.provider, reading: reading, boosted: false))
        due[id] = max(due[id] ?? .distantPast, next)
    }

    /// A date from readings.json, as a restored wait counts from it. The file keeps whole seconds (JSONEncoder's
    /// `.iso8601` drops the fraction), so the real instant was up to a second after the saved one: counting from a
    /// second later never ends a wait before its rule, Retry-After + 900 s included. A date later than now means the
    /// clock was moved back after it was saved; counting from now keeps the wait no longer than its rule.
    private func restoredInstant(_ saved: Date) -> Date {
        min(saved.addingTimeInterval(1), now())
    }

    /// Takes a failure saved in readings.json as this account's latest outcome, so a relaunch keeps the wait it
    /// would have had: a 429 stays paused until Retry-After plus the margin, sign-in-needed waits the user-fixable
    /// delay, other failures keep their backoff. A missing or outdated CLI is not restored: launch looks for the CLI
    /// again. Only ever pushes a read later; an account the scheduler does not know is ignored.
    public func restore(error: ReadError, at saved: Date, consecutiveFailures: Int, for id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        switch error {
        case .cliNotFound, .cliUpdateNeeded: return
        default: break
        }
        let at = restoredInstant(saved)
        let count = max(consecutiveFailures, 1)
        failures[id] = max(failures[id] ?? 0, count)
        let next = at.addingTimeInterval(policy.delay(after: error, consecutiveFailures: count, provider: account.provider))
        due[id] = max(due[id] ?? .distantPast, next)
        if case .rateLimited = error { pausedUntil[id] = max(pausedUntil[id] ?? .distantPast, next) }
    }

    /// Launch and every account-list change: an account's schedule continues from readings.json the first time this
    /// finds a record for it. The last good reading sets the next read, and a failure that is newer than it, or that
    /// was the last attempt, restores its wait (see `restore`). The last attempt counts even when its date is earlier
    /// than the reading's: the clock was set back in between, and `ReadingsStore.apply` dates a failure and its attempt
    /// from one instant and clears the failure on success, so the failure really came last. An account with no record
    /// yet, such as one whose first-run check was still running when the list was saved, is taken once its record
    /// appears, unless this scheduler has read it by then. An account seeded or read before keeps the schedule it has:
    /// from then on its record only holds what this scheduler read, and seeding it again would undo a Refresh, a
    /// Refresh all or a boost made since.
    public func seed(from records: [String: AccountRecord]) {
        for account in accounts where !seededFromRecords.contains(account.id) {
            guard let record = records[account.id] else { continue }
            seededFromRecords.insert(account.id)
            take(record, for: account.id)
        }
    }

    /// A record made outside this scheduler that may say more than the one it was seeded from (Juice Island: a folder's
    /// old record, merged into its login when the folder is first placed). Taken as `seed(from:)` takes a record, whether
    /// or not the account was seeded or read before, so it only ever pushes the next read later.
    public func seed(record: AccountRecord, for id: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        take(record, for: id)
    }

    private func take(_ record: AccountRecord, for id: String) {
        if let tried = record.lastAttemptAt ?? record.lastGood?.readAt {
            lastAttempt[id] = max(lastAttempt[id] ?? .distantPast, restoredInstant(tried))
        }
        if let reading = record.lastGood { seed(reading: reading, readAt: restoredInstant(reading.readAt), for: id) }
        if let error = record.lastError, let at = record.lastErrorAt,
           at >= (record.lastGood?.readAt ?? .distantPast) || at == record.lastAttemptAt {
            restore(error: error, at: at, consecutiveFailures: record.consecutiveFailures, for: id)
        }
        // A No plan login's 6-hour wait comes back with it, counted from its last such answer (P360).
        if let streak = record.noPlan, streak.last >= (record.lastGood?.readAt ?? .distantPast),
           streak.last >= (noPlan[id]?.last ?? .distantPast) {
            noPlan[id] = streak
            if streak.holds { due[id] = max(due[id] ?? .distantPast, restoredInstant(streak.last).addingTimeInterval(NoPlanStreak.interval)) }
        }
    }

    /// The account is No plan (P360): its reads said it has no plan limits, often enough and long enough.
    public func isNoPlan(_ id: String) -> Bool { noPlan[id]?.holds == true }

    public func pause() { isPaused = true }

    /// After sleep: an account still within its interval keeps its due time; an overdue one is staggered from now.
    public func resume() {
        isPaused = false
        let current = now()
        for (index, account) in accounts.filter(\.monitored).enumerated() {
            due[account.id] = max(due[account.id] ?? current, current.addingTimeInterval(TimeInterval(index) * policy.resumeStagger))
        }
    }

    public func nextDue(for id: String) -> Date? { due[id] }
    public func isInFlight(_ id: String) -> Bool { inFlight[id] != nil }
    public var inFlightCount: Int { inFlight.count }
    public var isBatchRunning: Bool { batchTotal > 0 && batchDone < batchTotal }

    /// Every monitored account now, staggered per provider. An account inside a rate-limit pause keeps its due time
    /// and stays out of the batch, so the progress count only tracks the reads this actually starts.
    public func refreshAll() { refreshAll(where: { _ in true }) }

    /// Refresh all that keeps to the floors (Juice Island's toolbar and menus): an account tried less than its boosted
    /// interval ago (Claude 120 s; Codex 60, 30 or 15 s by use) stays out of the batch and only gets the boost, its next
    /// read moved up to that floor at the earliest. Everything else is `refreshAll()`.
    public func refreshAllWithinFloors() {
        let current = now()
        refreshAll { account in
            guard let tried = self.lastAttempt[account.id] else { return true }
            return current.timeIntervalSince(tried) >= self.floor(for: account)
        }
    }

    /// The shortest time between two reads of an account on a manual refresh: its boosted interval.
    private func floor(for account: ReadTarget) -> TimeInterval {
        policy.interval(for: account.provider, reading: lastReading[account.id], boosted: true)
    }

    private func refreshAll(where eligible: (ReadTarget) -> Bool) {
        let current = now()
        // A No plan account keeps its 6-hour wait: Refresh all neither reads nor boosts it (P360).
        let unpaused = accounts.filter { $0.monitored && (pausedUntil[$0.id] ?? .distantPast) <= current && !isNoPlan($0.id) }
        let monitored = unpaused.filter(eligible)
        for account in unpaused where !monitored.contains(account) {
            boostedUntil[account.id] = current.addingTimeInterval(policy.boostDuration)
            let floorEnd = (lastAttempt[account.id] ?? current).addingTimeInterval(floor(for: account))
            due[account.id] = max(earliestRead(for: account.id), min(due[account.id] ?? .distantFuture, floorEnd))
        }
        batch = Set(monitored.map(\.id))
        batchTotal = monitored.count
        batchDone = 0
        var offsets: [Provider: TimeInterval] = [:]
        for account in monitored {
            boostedUntil[account.id] = current.addingTimeInterval(policy.boostDuration)
            if inFlight[account.id] == nil {
                let offset = offsets[account.provider] ?? 0
                due[account.id] = current.addingTimeInterval(offset)
                offsets[account.provider] = offset + policy.stagger(for: account.provider)
            }
        }
    }

    /// What a click on one account's Refresh would do (#12): read it now, join the read running, or wait for its floor (its
    /// boosted interval since it was last tried) or a 429 pause (Retry-After + 900 s), whichever ends later. A No plan
    /// account (P360) is read on this click like any other, within the same floor: the owner asks after resubscribing,
    /// the schedule never does sooner than its 6 hours.
    public enum ManualRead: Sendable, Equatable {
        case now
        case reading
        case floor(until: Date)
        case paused(until: Date)
        /// Not an account this scheduler reads (not listed, or switched off).
        case unavailable
    }

    public func manualRead(for id: String) -> ManualRead {
        guard let account = accounts.first(where: { $0.id == id }), account.monitored else { return .unavailable }
        if inFlight[id] != nil { return .reading }
        let current = now()
        if let paused = pausedUntil[id], paused > current { return .paused(until: paused) }
        if let tried = lastAttempt[id] {
            let floorEnd = tried.addingTimeInterval(floor(for: account))
            if floorEnd > current { return .floor(until: floorEnd) }
        }
        return .now
    }

    /// One account on a click, within the floors (#12): read now when `manualRead` says so; otherwise it only gets the
    /// boost, its next read moved up to where the floor or the pause ends, never earlier. Returns whether a read was
    /// made due now.
    @discardableResult
    public func refreshWithinFloors(id: String) -> Bool {
        let read = manualRead(for: id)
        guard read != .unavailable, read != .reading else { return false }
        let current = now()
        boostedUntil[id] = current.addingTimeInterval(policy.boostDuration)
        switch read {
        case .now:
            due[id] = current
            return true
        case .floor(let until), .paused(let until):
            due[id] = max(earliestRead(for: id), min(due[id] ?? .distantFuture, until))
            return false
        case .reading, .unavailable:
            return false
        }
    }

    /// One account now; a running read is joined rather than duplicated, and a rate-limit pause is still respected.
    public func refresh(id: String) {
        boostedUntil[id] = now().addingTimeInterval(policy.boostDuration)
        if inFlight[id] == nil { due[id] = earliestRead(for: id) }
    }

    public func boost(id: String, until: Date) {
        boostedUntil[id] = until
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        tightenForBoost(id, provider: account.provider)
    }

    public func boost(provider: Provider, until: Date) {
        for account in accounts where account.provider == provider {
            boostedUntil[account.id] = until
            tightenForBoost(account.id, provider: provider)
        }
    }

    /// Pulls a pending read forward to the boosted cadence; never earlier than the earliest allowed read, never later
    /// than it already was. An account whose last read failed keeps its wait: sessions at work are no reason to try a
    /// read that may have reached the vendor again sooner (P106); a good reading puts it back on its boosted cadence.
    private func tightenForBoost(_ id: String, provider: Provider) {
        guard (failures[id] ?? 0) == 0, !isNoPlan(id) else { return }
        let current = now()
        let boostedInterval = policy.interval(for: provider, reading: lastReading[id], boosted: true)
        due[id] = max(earliestRead(for: id), min(due[id] ?? .distantFuture, current.addingTimeInterval(boostedInterval)))
    }

    /// The provider's CLI was found again after reads found none: every account whose last read failed for want of it is
    /// read again now (or when its 429 pause ends) instead of after the hour a missing CLI waits. That read ran no process
    /// and reached no vendor, and it came when the account was due, so the floor is kept.
    public func cliFound(for provider: Provider) {
        for account in accounts where account.provider == provider && missingCLI.contains(account.id) {
            missingCLI.remove(account.id)
            if inFlight[account.id] == nil, !isNoPlan(account.id) { due[account.id] = earliestRead(for: account.id) }
        }
    }

    /// Now, or the end of a rate-limit pause if one is still running.
    private func earliestRead(for id: String) -> Date { max(now(), pausedUntil[id] ?? .distantPast) }

    /// The account's reading the floors follow: the newest by when its read began. A read that began before a newer reading
    /// was handed on, or one handed on late, never sets a Codex floor from an older use (P731). A held reading dated after
    /// now was read before a clock set back, and never outlasts it.
    private func keepNewest(_ reading: AccountReading, for id: String) {
        let held = lastReading[id]?.readAt ?? .distantPast
        if reading.readAt >= held || held > now() { lastReading[id] = reading }
    }

    /// Launches every due, monitored, not-in-flight account, oldest due first, within the concurrency limit.
    public func tick() async {
        guard !isPaused else { return }
        let current = now()
        // Oldest due first; ties keep the user's order (a plain sort is not stable).
        let ready = accounts.enumerated()
            .filter { $0.element.monitored && inFlight[$0.element.id] == nil && (due[$0.element.id] ?? .distantFuture) <= current }
            .sorted { ((due[$0.element.id] ?? current), $0.offset) < ((due[$1.element.id] ?? current), $1.offset) }
            .map(\.element)
        for account in ready.prefix(max(0, policy.maxConcurrentReads - inFlight.count)) {
            launch(account, at: current)
        }
    }

    public func waitForInFlight() async {
        while let task = inFlight.values.first { await task.value }
    }

    private func launch(_ account: ReadTarget, at start: Date) {
        guard let reader = readers[account.provider] else {
            finish(account, result: .failure(.cliNotFound), at: start)
            return
        }
        inFlight[account.id] = Task { [weak self] in
            let result = await reader(account, start)
            // `stop()` cancelled this read: the answer is thrown away and nothing about the account is touched.
            guard !Task.isCancelled else { return }
            self?.finish(account, result: result, at: self?.now() ?? start)
        }
    }

    private func finish(_ account: ReadTarget, result: Result<AccountReading, ReadError>, at end: Date) {
        inFlight[account.id] = nil
        // Nothing was read: nothing is recorded, and the account waits its stagger so a list that still names it cannot
        // spin.
        if case .failure(Self.skipped) = result {
            due[account.id] = max(due[account.id] ?? end, end.addingTimeInterval(policy.stagger(for: account.provider)))
            if batch.remove(account.id) != nil { batchDone += 1 }
            return
        }
        // Ran alongside a newer reading handed on meanwhile (P731): it ends after every attempt before it. One that ends
        // before the last attempt did comes after a clock set back, and is the newest.
        let alongside = end >= (lastAttempt[account.id] ?? .distantPast)
        lastAttempt[account.id] = end
        if case .failure(.cliNotFound) = result { missingCLI.insert(account.id) } else { missingCLI.remove(account.id) }
        noPlan[account.id] = NoPlanStreak.after(result, at: end, previous: noPlan[account.id])
        // From here on the account's record holds what this scheduler read: `seed(from:)` must not take it back.
        seededFromRecords.insert(account.id)
        onResult?(account, result, end)
        switch result {
        case .success(let reading):
            if alongside { keepNewest(reading, for: account.id) } else { lastReading[account.id] = reading }
            failures[account.id] = 0
            pausedUntil[account.id] = nil
            let boosted = (boostedUntil[account.id] ?? .distantPast) > end
            due[account.id] = end.addingTimeInterval(policy.interval(for: account.provider, reading: lastReading[account.id], boosted: boosted))
        case .failure(let error):
            let count = (failures[account.id] ?? 0) + 1
            failures[account.id] = count
            let next = end.addingTimeInterval(policy.delay(after: error, consecutiveFailures: count, provider: account.provider))
            // A No plan account is read every 6 hours whatever its last failure (P360), a 429's longer wait included.
            due[account.id] = isNoPlan(account.id) ? max(next, end.addingTimeInterval(NoPlanStreak.interval)) : next
            // Only a 429 holds the account down; ordinary backoff may still be bypassed by a manual refresh.
            if case .rateLimited = error { pausedUntil[account.id] = next } else { pausedUntil[account.id] = nil }
        }
        // `isBatchRunning` already goes false once batchDone reaches batchTotal, so the finished count
        // is left in place for callers to read (e.g. "3/3 done"); refreshAll() resets both for the next batch.
        if batch.remove(account.id) != nil { batchDone += 1 }
    }
}
