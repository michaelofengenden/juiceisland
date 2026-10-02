import Foundation
import Observation

/// `usage-history.json` (P125): each account's recent readings (`UsageHistory`) and the quota notices already given
/// (`QuotaAlertState`), for the forecasts, the sparklines and the island's quota notices. Juice Island's own file, like
/// logins.json: standalone Juice never reads or writes it. A store with no file (a dev build's mirror, tests) keeps it
/// all in memory.
///
/// It takes the readings the app already has (`observe`), never asks for one. The file is written on its own queue, one
/// write after another, at most every `saveInterval` and at `flush` (quitting, which waits for it), pruned first, so it
/// stays within `UsageHistory`'s bounds; nothing ticks: a save is scheduled only by a new reading.
@MainActor
@Observable
public final class UsageHistoryStore {
    private struct File: Codable, Sendable {
        var version: Int
        var history: UsageHistory
        var alerts: QuotaAlertState
    }

    public private(set) var history = UsageHistory()
    /// The newest notice, for the island; nil until a reading raises one.
    public private(set) var notice: QuotaNotice?

    public let fileURL: URL?
    public nonisolated static let saveInterval: TimeInterval = 60

    @ObservationIgnored private var alerts = QuotaAlertState()
    /// The newest reading taken per account in this run: a notice needs the one before.
    @ObservationIgnored private var seen: [String: AccountReading] = [:]
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var lastSave: Date?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// Every write, in order, off the main actor.
    private nonisolated static let writes = DispatchQueue(label: "juice.usage-history", qos: .utility)

    public init(fileURL: URL?, clock: @escaping () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.clock = clock
    }

    public static func file(in directory: URL) -> URL { directory.appendingPathComponent("usage-history.json") }

    /// A file this build cannot read starts an empty history; it is kept beside it before the first write (P111).
    public func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let file = Self.decode(data) else {
            StoreFile.noteLoss(fileURL, data: data, lost: 0, unreadable: true)
            return
        }
        var loaded = file.history
        loaded.prune(now: clock())
        history = loaded
        alerts = file.alerts
    }

    /// Takes every account's newest reading. A reading newer than the last one taken becomes a sample, and is judged
    /// against it for a notice; the first one an account shows in a run (at launch, a reading restored from disk) only
    /// becomes a sample, if the history does not hold it yet, and says nothing.
    public func observe(_ records: [String: AccountRecord], providers: [String: Provider]) {
        var changed = history
        var recorded = false
        var raised: QuotaNotice?
        for (account, record) in records.sorted(by: { $0.key < $1.key }) {
            guard let reading = record.lastGood, let provider = providers[account] else { continue }
            let previous = seen[account]
            if let previous, previous.readAt >= reading.readAt { continue }
            seen[account] = reading
            guard let previous else {
                if (changed.latest(account) ?? .distantPast) < reading.readAt {
                    changed.record(reading, for: account)
                    recorded = true
                }
                continue
            }
            changed.record(reading, for: account)
            recorded = true
            let runOut = UsageForecast.runOut(reading, account: account, history: changed)
            if let notice = QuotaAlerts.evaluate(account: account, provider: provider, previous: previous, current: reading,
                                                 runOut: runOut, state: &alerts) {
                raised = notice
            }
        }
        if recorded {
            history = changed
            scheduleSave()
        }
        if let raised { notice = raised }
    }

    /// The account `old` goes by `new` from now on (a login that took its organization's id, P580): its samples, the
    /// notices given for it and the reading last taken move with it, so its forecasts and sparklines go on and no notice
    /// is given twice.
    public func rename(_ old: String, to new: String) {
        guard old != new else { return }
        var changed = history
        changed.rename(old, to: new)
        alerts.rename(old, to: new)
        if let reading = seen.removeValue(forKey: old), reading.readAt >= seen[new]?.readAt ?? .distantPast { seen[new] = reading }
        if changed != history {
            history = changed
            scheduleSave()
        }
    }

    /// Writes now and waits for it (quitting, a usage source switch), after any write still queued.
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        save()
        Self.writes.sync {}
    }

    /// A store with no file prunes on the same terms, so it keeps to the bounds too.
    private func scheduleSave() {
        guard pendingSave == nil else { return }
        let wait = lastSave.map { max(0, Self.saveInterval - clock().timeIntervalSince($0)) } ?? 0
        pendingSave = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            self.save()
        }
    }

    /// Prunes, then encodes and writes the file on the writes' queue.
    private func save() {
        let now = clock()
        var pruned = history
        pruned.prune(now: now)
        if pruned != history { history = pruned }
        alerts.prune(now: now)
        lastSave = now
        guard let fileURL else { return }
        let file = File(version: 1, history: history, alerts: alerts)
        Self.writes.async {
            guard let data = try? JSONEncoder().encode(file) else { return }
            try? StoreFile.write(data, to: fileURL, isReadable: { Self.decode($0) != nil })
        }
    }

    private nonisolated static func decode(_ data: Data) -> File? {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { return nil }
        return file
    }
}
