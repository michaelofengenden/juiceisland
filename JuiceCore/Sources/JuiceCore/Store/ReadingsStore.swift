import Foundation
import Observation

/// What the app remembers about one account's reads. `lastGood` only ever moves forward.
public struct AccountRecord: Codable, Sendable, Equatable {
    public var lastGood: AccountReading?
    public var lastError: ReadError?
    public var lastErrorAt: Date?
    public var lastAttemptAt: Date?
    public var consecutiveFailures: Int
    /// True when this record came back with its login (P80's per-folder logins, before P93 kept each login's record
    /// whole): its last good reading shows as stale until the next good read clears this. Nothing sets it any more;
    /// `LoginsStore` drops it. Optional so records written before this existed, and by standalone Juice, still decode.
    public var restored: Bool?
    /// A Claude login's reads that said it has no plan limits, in a row (`NoPlanStreak`, P360); nil when the last answer
    /// was anything else. Optional so records written before this existed, and by standalone Juice, still decode.
    public var noPlan: NoPlanStreak?

    public init(lastGood: AccountReading? = nil, lastError: ReadError? = nil, lastErrorAt: Date? = nil,
                lastAttemptAt: Date? = nil, consecutiveFailures: Int = 0, restored: Bool? = nil, noPlan: NoPlanStreak? = nil) {
        self.lastGood = lastGood
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
        self.lastAttemptAt = lastAttemptAt
        self.consecutiveFailures = consecutiveFailures
        self.restored = restored
        self.noPlan = noPlan
    }
}

extension AccountRecord {
    /// One read's outcome, at `now`, when the read ended. A reading is dated when its read began, and two reads of one
    /// login can run at once (one under the id it had before its organization was named and one under the new id, a folder
    /// that answered for the login while another folder read it), so the one that began first may end last (P731). A
    /// read that ran alongside a newer outcome (it began before that outcome and ends after the last attempt ended) never
    /// replaces a newer reading, and never clears a failure that ended after it began (a 429's pause then still holds after
    /// a relaunch): it counts as an attempt only. A read that ends before the last attempt did comes after a clock set
    /// back, and is the newest outcome, as before; so does one that ends before the held reading or failure is dated,
    /// which only a clock set back makes (the first outcome after it a failure). A failure is taken as before.
    public mutating func take(_ result: Result<AccountReading, ReadError>, at now: Date) {
        let alongside = now >= (lastAttemptAt ?? .distantPast)
        lastAttemptAt = now
        // Whether this read is newer than a held outcome dated `held`.
        func newer(_ began: Date, than held: Date?) -> Bool {
            let held = held ?? .distantPast
            return !alongside || began >= held || held > now
        }
        switch result {
        case .success(let reading):
            if newer(reading.readAt, than: lastGood?.readAt) {
                lastGood = reading
                restored = nil
            }
            guard newer(reading.readAt, than: lastErrorAt) else { return }
            noPlan = nil
            lastError = nil
            lastErrorAt = nil
            consecutiveFailures = 0
        case .failure(let error):
            noPlan = NoPlanStreak.after(result, at: now, previous: noPlan)
            lastError = error
            lastErrorAt = now
            consecutiveFailures += 1
        }
    }

    /// The last good reading's plan as the app shows it, its first letter capitalised ("max" → "Max"); nil without one.
    public var planWord: String? {
        guard let plan = lastGood?.plan, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }
}

/// `readings.json`: the last good reading and last error per account, so the panel shows real ages after a relaunch.
/// Read record by record (a record this build cannot read costs only itself, `SalvagedRecord`), and written only when
/// it changed, through `writer` when one is set (off the main thread, `StoreWriter`), never over a file this build
/// cannot read whole without keeping it first (`StoreFile`).
@MainActor
@Observable
public final class ReadingsStore {
    struct File: Codable, Equatable, Sendable {
        var version: Int
        var records: [String: AccountRecord]
    }

    private struct SalvagedFile: Decodable {
        var records: LossyDictionary<SalvagedRecord>
    }

    public let fileURL: URL
    public private(set) var records: [String: AccountRecord] = [:]
    /// Writes off the main thread when set; `save()` writes at once when nil.
    @ObservationIgnored public var writer: StoreWriter?
    /// What the file holds as far as this store knows: what it read whole or last wrote. A save of the same is skipped.
    @ObservationIgnored private var saved: File?

    public nonisolated static var defaultFileURL: URL {
        AccountsStore.defaultFileURL.deletingLastPathComponent().appendingPathComponent("readings.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func record(for id: String) -> AccountRecord { records[id] ?? AccountRecord() }

    public func apply(_ result: Result<AccountReading, ReadError>, for id: String, at now: Date) {
        var record = records[id] ?? AccountRecord()
        record.take(result, at: now)
        records[id] = record
    }

    public func forget(id: String) { records[id] = nil }

    /// Puts `record` in as the account's record, or none.
    public func set(_ record: AccountRecord?, for id: String) { records[id] = record }

    /// Every record at once (Juice Island writes each folder's login's record, `LoginsStore.projection`); a list equal
    /// to the one held changes nothing.
    public func replace(_ newRecords: [String: AccountRecord]) {
        if newRecords != records { records = newRecords }
    }

    /// Reads the file: whole, or record by record when it does not read whole. A missing or unreadable file leaves the
    /// records as they are.
    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let file = try? JSONDecoder.juice.decode(File.self, from: data) {
            records = file.records
            saved = file
            return
        }
        saved = nil
        let salvaged = try? JSONDecoder.juice.decode(SalvagedFile.self, from: data)
        if let salvaged { records = salvaged.records.values.mapValues(\.record) }
        StoreFile.noteLoss(fileURL, data: data, lost: salvaged?.records.lost ?? 0, unreadable: salvaged == nil)
    }

    public func save() throws {
        let file = File(version: 1, records: records)
        if file == saved, FileManager.default.fileExists(atPath: fileURL.path) { return }
        if let writer {
            writer.write(fileURL, isReadable: Self.isReadable) { try JSONEncoder.juice.encode(file) }
        } else {
            try StoreFile.write(JSONEncoder.juice.encode(file), to: fileURL, isReadable: Self.isReadable)
        }
        saved = file
    }

    /// The file reads whole.
    nonisolated static func isReadable(_ data: Data) -> Bool {
        (try? JSONDecoder.juice.decode(File.self, from: data)) != nil
    }
}

extension JSONEncoder {
    /// ISO 8601 dates and sorted keys, compact, for every file Juice writes.
    public static var juice: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    public static var juice: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
