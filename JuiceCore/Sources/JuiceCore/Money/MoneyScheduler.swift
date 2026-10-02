import Foundation

/// The money cadences and waits (Juice spec §8.1, §9.5), as numbers with no clock attached.
public struct MoneySchedulePolicy: Sendable, Equatable {
    /// Added to a 429's Retry-After (and to 60 s when it has none), as for the accounts.
    public var retryAfterMargin: TimeInterval = 900
    /// Waits after consecutive failures; never shorter than the source's own interval.
    public var failureBackoff: [TimeInterval] = [120, 300, 600, 1_200, 1_800]
    /// A 401 or 403: the key lacks the role. Asking again soon changes nothing.
    public var keyRoleDelay: TimeInterval = 1_800
    /// A manual refresh within this long of the last attempt joins it instead.
    public var manualFloor: TimeInterval = 30
    /// Seconds between the sources' first reads at launch.
    public var launchStagger: TimeInterval = 2

    public init() {}

    public func delay(for source: MoneySource, after error: MoneyReadError?, consecutiveFailures: Int) -> TimeInterval {
        guard let error else { return source.interval }
        switch error {
        case .rateLimited(let retryAfter): return (retryAfter ?? 60) + retryAfterMargin
        case .notAvailableWithThisKey: return keyRoleDelay
        // Nothing was sent: the next look is only at the key file.
        case .notConfigured, .keyFileRefused, .keyFileUnreadable, .keyNotUsable, .refusedByPolicy, .idMissing, .idInvalid:
            return source.interval
        case .http, .timeout, .offline, .unreadableResponse:
            let backoff = failureBackoff[min(max(consecutiveFailures, 1) - 1, failureBackoff.count - 1)]
            return max(source.interval, backoff)
        }
    }
}

/// Reads each money account on its source's cadence (Juice Island spec §3.9: MoneyScheduler → readers → MoneyHTTPClient):
/// every source's first key, and the further keys the settings name (`OpenRouter 2`). Each read resolves the key file
/// (the picked one or the default lookup), reads the key for that read only, refuses a key that may not go to that
/// source, and hands it to the account's own reader. A failure never replaces the last good reading. A 429 pauses the
/// account for Retry-After plus the margin (60 s plus the margin when the answer gives none), also across relaunches
/// (the saved records carry the pause).
public actor MoneyScheduler {
    public typealias Update = @Sendable (MoneyAccount, MoneySourceRecord) async -> Void

    nonisolated let client: MoneyHTTPClient
    let makeReader: @Sendable (MoneySource) -> any MoneyReader
    let policy: MoneySchedulePolicy
    let clock: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let fence: @Sendable () async -> MoneyKeyFileGuard
    let onUpdate: Update

    public private(set) var records: [MoneyAccount: MoneySourceRecord]
    private var settings: [MoneyAccount: MoneySourceSettings] = [:]
    /// One reader per account, so two keys of a source never share what a reader keeps (P99, P146).
    private var readers: [MoneyAccount: any MoneyReader] = [:]
    private var loops: [MoneyAccount: Task<Void, Never>] = [:]
    private var inFlight: [MoneyAccount: Task<MoneySourceRecord, Never>] = [:]
    private var started = false

    public init(client: MoneyHTTPClient, makeReader: @escaping @Sendable (MoneySource) -> any MoneyReader = MoneyScheduler.standardReader,
                policy: MoneySchedulePolicy = MoneySchedulePolicy(), records: [MoneyAccount: MoneySourceRecord] = [:],
                clock: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                fence: @escaping @Sendable () async -> MoneyKeyFileGuard = { MoneyKeyFileGuard() },
                onUpdate: @escaping Update = { _, _ in }) {
        self.client = client
        self.makeReader = makeReader
        self.policy = policy
        self.records = records
        self.clock = clock
        self.sleep = sleep
        self.fence = fence
        self.onUpdate = onUpdate
    }

    /// A new reader for one of `source`'s accounts.
    public static func standardReader(_ source: MoneySource) -> any MoneyReader {
        switch source {
        case .openRouter: OpenRouterReader()
        case .anthropic: CostReportReader(format: AnthropicCostFormat())
        case .openAI: CostReportReader(format: OpenAICostFormat())
        case .runPod: RunPodReader()
        case .hetzner: HetznerReader()
        case .deepSeek: DeepSeekReader()
        case .moonshot: MoonshotReader()
        case .xAI: XAIReader()
        case .fireworks: FireworksReader()
        case .fal: FalReader()
        case .elevenLabs: ElevenLabsReader()
        case .vastAI: VastReader()
        case .digitalOcean: DigitalOceanReader()
        }
    }

    /// The accounts read with `settings`: every source's first key, then the further keys it names, in the panel's order.
    static func accounts(_ settings: [MoneyAccount: MoneySourceSettings]) -> [MoneyAccount] {
        Array(Set(MoneyAccount.firsts).union(settings.keys)).sorted()
    }

    private func reader(_ account: MoneyAccount) -> any MoneyReader {
        if let reader = readers[account] { return reader }
        let reader = makeReader(account.source)
        readers[account] = reader
        return reader
    }

    /// Starts every account's loop, staggered, each waiting out a saved pause first.
    public func start(settings: [MoneyAccount: MoneySourceSettings]) {
        self.settings = settings
        guard !started else { return }
        started = true
        let now = clock()
        for (index, account) in Self.accounts(settings).enumerated() {
            let paused = records[account]?.pausedUntil.map { max(0, $0.timeIntervalSince(now)) } ?? 0
            startLoop(account, after: max(paused, Double(index) * policy.launchStagger))
        }
    }

    /// New settings: an account whose key file changed, whose credit or its date changed (the cost readers read back to
    /// it), or whose id changed (another team's or account's figures) is read again soon; a pause and the 30 s floor
    /// still hold (the floor only after a read that reached the API: an id set after `Team ID not set` reads at once).
    /// Another key file may hold another account's key, and another id is another account, so the reader forgets what
    /// it kept. A top-up or a label only changes what is drawn. A further key the settings no longer name (its key file
    /// gone) stops, with its record but for a 429 pause still running (`MoneySourceRecord.pauseOnly`); one they name
    /// for the first time starts, after that pause.
    public func update(settings new: [MoneyAccount: MoneySourceSettings]) async {
        let old = settings
        settings = new
        let wanted = Set(Self.accounts(new))
        for account in Self.accounts(old) where !wanted.contains(account) {
            loops.removeValue(forKey: account)?.cancel()
            var last = records[account]
            // A read in flight ends first; a 429 it met is kept although its record is not.
            if let running = inFlight[account] { last = await running.value }
            readers.removeValue(forKey: account)
            records[account] = last?.pauseOnly(now: clock())
        }
        for account in Self.accounts(new) where old[account] != new[account] {
            let (before, after) = (old[account] ?? MoneySourceSettings(), new[account] ?? MoneySourceSettings())
            let isNew = !account.isFirst && old[account] == nil
            let keyMoved = before.keyPath != after.keyPath || before.accountID != after.accountID
            let moved = isNew || keyMoved
                || (account.source.takesCredit && (before.credit != after.credit || before.creditDate != after.creditDate))
            guard moved else { continue }
            if keyMoved { await readers[account]?.forget() }
            guard started else { continue }
            startLoop(account, after: max(pauseLeft(account), floorLeft(account)))
        }
    }

    /// A key saved or removed in Settings › Money (`settings` is the account's settings from now on, its picked key
    /// file dropped). A read already running ends first. Then the last reading and the failures go (they were another
    /// key's; `MoneySourceRecord.afterKeyChange`), the reader forgets what it kept, and the account is read again soon: a
    /// 429 pause still holds, and so does the 30 s floor after a read that reached the API.
    public func keyChanged(_ account: MoneyAccount, settings accountSettings: MoneySourceSettings) async {
        settings[account] = accountSettings
        if let running = inFlight[account] { _ = await running.value }
        let old = records[account] ?? MoneySourceRecord()
        let record = old.afterKeyChange(now: clock())
        records[account] = record
        await readers[account]?.forget()
        await onUpdate(account, record)
        guard started else { return }
        startLoop(account, after: max(pauseLeft(account), floorLeft(account, after: old)))
    }

    /// Refresh source: reads now unless paused or read within the last 30 s.
    public func refresh(_ account: MoneyAccount) {
        guard started, pauseLeft(account) == 0 else { return }
        if let last = records[account]?.lastAttemptAt, clock().timeIntervalSince(last) < policy.manualFloor { return }
        startLoop(account, after: 0)
    }

    public func stop() {
        loops.values.forEach { $0.cancel() }
        loops = [:]
        started = false
    }

    private func pauseLeft(_ account: MoneyAccount) -> TimeInterval {
        records[account]?.pausedUntil.map { max(0, $0.timeIntervalSince(clock())) } ?? 0
    }

    /// What is left of the 30 s floor after the account's last attempt (`record`, else its saved one), when that attempt
    /// reached the API; none after one that sent nothing (no key file, a refused key, no id).
    private func floorLeft(_ account: MoneyAccount, after record: MoneySourceRecord? = nil) -> TimeInterval {
        guard let last = record ?? records[account], last.lastError?.sentNothing != true, let attempt = last.lastAttemptAt else { return 0 }
        return max(0, policy.manualFloor - clock().timeIntervalSince(attempt))
    }

    private func startLoop(_ account: MoneyAccount, after delay: TimeInterval) {
        loops[account]?.cancel()
        loops[account] = Task { [weak self] in
            var wait = delay
            while !Task.isCancelled {
                guard let self else { return }
                if wait > 0 {
                    await self.noteNext(account, in: wait)
                    do { try await self.sleep(wait) } catch { return }
                }
                if Task.isCancelled { return }
                let record = await self.readNow(account)
                wait = await self.nextDelay(account, record)
            }
        }
    }

    private func nextDelay(_ account: MoneyAccount, _ record: MoneySourceRecord) -> TimeInterval {
        if let paused = record.pausedUntil, paused > clock() { return paused.timeIntervalSince(clock()) }
        return policy.delay(for: account.source, after: record.isFailing ? record.lastError : nil,
                            consecutiveFailures: record.consecutiveFailures)
    }

    private func noteNext(_ account: MoneyAccount, in wait: TimeInterval) async {
        var record = records[account] ?? MoneySourceRecord()
        record.nextReadAt = clock().addingTimeInterval(wait)
        records[account] = record
        await onUpdate(account, record)
    }

    /// One read of `account` now; joins a read that is already running.
    @discardableResult
    public func readNow(_ account: MoneyAccount) async -> MoneySourceRecord {
        if let running = inFlight[account] { return await running.value }
        let task = Task { await self.performRead(account) }
        inFlight[account] = task
        let record = await task.value
        inFlight[account] = nil
        return record
    }

    private func performRead(_ account: MoneyAccount) async -> MoneySourceRecord {
        let now = clock()
        var record = records[account] ?? MoneySourceRecord()
        record.nextReadAt = nil
        if let paused = record.pausedUntil, paused > now { return record }
        let accountSettings = settings[account] ?? MoneySourceSettings()
        let fence = await self.fence()
        do {
            guard let path = MoneyKeyFile.path(for: account, picked: accountSettings.keyPath, guard: fence) else {
                record.keyFileName = nil
                throw MoneyReadError.notConfigured
            }
            record.keyFileName = MoneyKeyFile.displayName(path)
            let key = try MoneyKeyFile.read(path, guard: fence)
            if let refusal = MoneyHostPolicy.keyRefusal(key, for: account.source) { throw refusal }
            let reader = reader(account)
            let context = MoneyReadContext(now: now, settings: accountSettings)
            let reading = try await MoneyHTTPClient.$account.withValue(account) {
                try await reader.read(key: key, context: context, client: client)
            }
            record.lastGood = reading
            record.lastError = nil
            record.lastErrorAt = nil
            record.consecutiveFailures = 0
            record.pausedUntil = nil
        } catch {
            let failure = (error as? MoneyReadError) ?? .unreadableResponse("read failed")
            record.lastError = failure
            record.lastErrorAt = now
            record.consecutiveFailures = failure == .notConfigured ? 0 : record.consecutiveFailures + 1
            if case .rateLimited(let retryAfter) = failure {
                record.pausedUntil = now.addingTimeInterval((retryAfter ?? 60) + policy.retryAfterMargin)
            }
        }
        record.lastAttemptAt = now
        Self.noteOutcome(account, before: records[account], after: record)
        // A further key removed while this read ran is not brought back.
        if account.isFirst || Self.accounts(settings).contains(account) {
            records[account] = record
            await onUpdate(account, record)
        }
        return record
    }

    /// Logs an account starting to fail (or failing another way), a 429's pause, and its first good read after failures;
    /// nothing for the reads in between, and never a key, a label or an answer's words.
    static func noteOutcome(_ account: MoneyAccount, before: MoneySourceRecord?, after: MoneySourceRecord) {
        let failing = (before?.consecutiveFailures ?? 0) > 0 ? before?.lastError : nil
        guard let error = after.lastError, after.lastErrorAt == after.lastAttemptAt else {
            if let failing {
                JuiceLog.money.notice("\(account.rawValue, privacy: .public): read again after \(failing.logName, privacy: .public)")
            }
            return
        }
        guard error != .notConfigured, failing?.logName != error.logName else { return }
        if case .rateLimited = error, let pausedUntil = after.pausedUntil {
            let pause = Int(pausedUntil.timeIntervalSince(after.lastAttemptAt ?? pausedUntil))
            JuiceLog.money.error("\(account.rawValue, privacy: .public): rate limited, paused \(pause, privacy: .public) s")
        } else {
            JuiceLog.money.error("\(account.rawValue, privacy: .public): read failed, \(error.logName, privacy: .public)")
        }
    }
}

/// The money records between launches (`~/Library/Application Support/Juice Island/money.json` in the app), one per
/// account (`OpenRouter`, `OpenRouter 2`): readings and pauses, never a key. Read account by account (a record this
/// build cannot read costs only itself, and a pause survives an error case it does not know, `SalvagedMoneyRecord`),
/// and written through `writer` when one is set (off the main thread, `StoreWriter`), never over a file this build
/// cannot read whole without keeping it first (`StoreFile`): an account this build does not know is kept that way too.
public struct MoneyStore: Sendable {
    public let url: URL
    public var writer: StoreWriter?

    public init(url: URL, writer: StoreWriter? = nil) {
        self.url = url
        self.writer = writer
    }

    private struct File: Codable {
        var version = 1
        var records: [String: MoneySourceRecord]
    }

    private struct SalvagedFile: Decodable {
        var records: LossyDictionary<SalvagedMoneyRecord>
    }

    public func load() -> [MoneyAccount: MoneySourceRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let whole = try? JSONDecoder.juice.decode(File.self, from: data)
        let salvaged = whole == nil ? try? JSONDecoder.juice.decode(SalvagedFile.self, from: data) : nil
        let records = whole?.records ?? salvaged?.records.values.mapValues(\.record) ?? [:]
        let known = records.compactMap { key, value in MoneyAccount(rawValue: key).map { ($0, value) } }
        let lost = (salvaged?.records.lost ?? 0) + records.count - known.count
        StoreFile.noteLoss(url, data: data, lost: lost, unreadable: whole == nil && salvaged == nil)
        return Dictionary(uniqueKeysWithValues: known)
    }

    public func save(_ records: [MoneyAccount: MoneySourceRecord]) {
        let file = File(records: Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value) }))
        if let writer {
            writer.write(url, isReadable: Self.isReadable) { try JSONEncoder.juice.encode(file) }
        } else if let data = try? JSONEncoder.juice.encode(file) {
            try? StoreFile.write(data, to: url, isReadable: Self.isReadable)
        }
    }

    /// The file reads whole, every account in it one this build knows.
    static func isReadable(_ data: Data) -> Bool {
        guard let file = try? JSONDecoder.juice.decode(File.self, from: data) else { return false }
        return file.records.keys.allSatisfy { MoneyAccount(rawValue: $0) != nil }
    }
}

/// A `MoneySourceRecord` from a file another build may have written: whole when it can be, else field by field. A
/// reading it cannot read is left out; an error case it does not know is kept as an unexpected answer at its time and
/// count, so its backoff still holds; a 429's pause is its own field (`pausedUntil`) and survives either way.
struct SalvagedMoneyRecord: Salvageable {
    var record: MoneySourceRecord
    var damaged = false

    static let unknownError = MoneyReadError.unreadableResponse("unknown")

    private enum Key: String, CodingKey {
        case lastGood, lastError, lastErrorAt, lastAttemptAt, pausedUntil, consecutiveFailures, nextReadAt, keyFileName
    }

    init(from decoder: any Decoder) throws {
        if let whole = try? MoneySourceRecord(from: decoder) {
            record = whole
            return
        }
        let container = try decoder.container(keyedBy: Key.self)
        func field<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
            guard container.contains(key), (try? container.decodeNil(forKey: key)) == false else { return nil }
            return try? container.decode(type, forKey: key)
        }
        var error = field(MoneyReadError.self, .lastError)
        if error == nil, container.contains(.lastError), (try? container.decodeNil(forKey: .lastError)) == false {
            error = Self.unknownError
        }
        record = MoneySourceRecord(lastGood: field(MoneyReading.self, .lastGood), lastError: error, lastErrorAt: field(Date.self, .lastErrorAt),
                                   lastAttemptAt: field(Date.self, .lastAttemptAt), pausedUntil: field(Date.self, .pausedUntil),
                                   consecutiveFailures: field(Int.self, .consecutiveFailures) ?? (error == nil ? 0 : 1),
                                   nextReadAt: field(Date.self, .nextReadAt), keyFileName: field(String.self, .keyFileName))
        damaged = true
    }
}
