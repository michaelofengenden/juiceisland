import Foundation
import os

/// P111: how the app's JSON files (accounts.json, readings.json, logins.json, forgotten.json, money.json) are read
/// and written. Another build writes some of them too (standalone Juice, the previous app after a rollback, a build with
/// an error case this one does not know), so one record this build cannot read costs only that record, never the
/// file: the stores decode record by record (`SalvagedRecord`, `LossyDictionary`, `LossyArray`). And a file this build cannot
/// read whole is never written over as it is: before the first write over it, it is kept beside it as
/// `<name>.unreadable-<date>` (`keep`), once per content, at most `keptLimit` of them. Writes are atomic and compact.
public enum StoreFile {
    /// Copies kept per file; an older one goes when a new one is kept.
    public static let keptLimit = 5

    /// Writes `data` over `url` atomically. When the file there does not read whole (`isReadable` is false for its
    /// bytes), it is kept first; when that fails, nothing is written and the error is thrown, so the file stays.
    public static func write(_ data: Data, to url: URL, isReadable: (Data) -> Bool, now: Date = Date()) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let current = try? Data(contentsOf: url), current != data, !isReadable(current) {
            do {
                try keep(current, of: url, now: now)
            } catch {
                JuiceLog.stores.error("""
                    \(JuiceLog.file(url), privacy: .public) was not written: it does not read whole and no copy of it \
                    could be kept (\(JuiceLog.code(error), privacy: .public))
                    """)
                throw error
            }
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            JuiceLog.stores.error("\(JuiceLog.file(url), privacy: .public) could not be written (\(JuiceLog.code(error), privacy: .public))")
            throw error
        }
    }

    /// Keeps `data`, the bytes of `url` this build could not read whole, as `<name>.unreadable-<date>` beside it,
    /// unless a kept copy already holds exactly these bytes. Returns the copy's URL (the one already kept, or nil when
    /// one was).
    @discardableResult
    public static func keep(_ data: Data, of url: URL, now: Date = Date()) throws -> URL? {
        let manager = FileManager.default
        let kept = keptCopies(of: url)
        if kept.contains(where: { (try? Data(contentsOf: $0)) == data }) { return nil }
        var copy = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".unreadable-" + stamp(now))
        var suffix = 2
        while manager.fileExists(atPath: copy.path) {
            copy = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".unreadable-" + stamp(now) + "-\(suffix)")
            suffix += 1
        }
        try data.write(to: copy, options: .atomic)
        JuiceLog.stores.notice("\(JuiceLog.file(url), privacy: .public) does not read whole: kept as \(JuiceLog.file(copy), privacy: .public)")
        for old in keptCopies(of: url).dropLast(keptLimit) { try? manager.removeItem(at: old) }
        return copy
    }

    /// The copies kept of `url`, oldest first.
    public static func keptCopies(of url: URL) -> [URL] {
        let folder = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".unreadable-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted().map { folder.appendingPathComponent($0) }
    }

    /// `20260925-073012`, UTC, so the copies sort by when they were kept.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Notes a load that could not take everything in: what the store then holds is what could be read. Once per
    /// content of the file, so a store read again and again (the mirror of standalone Juice's files) logs it once.
    static func noteLoss(_ url: URL, data: Data, lost: Int, unreadable: Bool) {
        guard unreadable || lost > 0, noted.withLock({ $0.updateValue(data.hashValue, forKey: url.path) != data.hashValue }) else { return }
        if unreadable {
            JuiceLog.stores.error("\(JuiceLog.file(url), privacy: .public) could not be read; it is kept before it is written again")
        } else {
            JuiceLog.stores.error("""
                \(JuiceLog.file(url), privacy: .public): \(lost, privacy: .public) records could not be read whole; the rest \
                were, and the file is kept before it is written again
                """)
        }
    }

    private static let noted = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])
}

/// A coding key for any name: the stores read a file's records by name, one at a time.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Something decoded as well as it could be: `damaged` when a part of it could not be read and was left out or
/// replaced.
protocol Salvageable: Decodable {
    var damaged: Bool { get }
}

/// A JSON object's entries decoded one by one: an entry that does not decode is left out and counted, and one that
/// decoded only in part counts too.
struct LossyDictionary<Value: Decodable>: Decodable {
    var values: [String: Value] = [:]
    var lost = 0

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        for key in container.allKeys {
            if let value = try? container.decode(Value.self, forKey: key) {
                values[key.stringValue] = value
                if (value as? any Salvageable)?.damaged == true { lost += 1 }
            } else {
                lost += 1
            }
        }
    }
}

/// A JSON array's elements decoded one by one, the same way.
struct LossyArray<Value: Decodable>: Decodable {
    var values: [Value] = []
    var lost = 0

    /// Steps over an element whatever it holds: it reads nothing.
    private struct Skip: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            let index = container.currentIndex
            if (try? container.decodeNil()) == true {
                lost += 1
            } else if let value = try? container.decode(Value.self) {
                values.append(value)
                if (value as? any Salvageable)?.damaged == true { lost += 1 }
            } else {
                // A failed element is not consumed.
                lost += 1
                _ = try? container.decode(Skip.self)
            }
            if container.currentIndex == index { throw DecodingError.dataCorruptedError(in: container, debugDescription: "stuck") }
        }
    }
}

/// An `AccountRecord` from a file another build may have written: whole when it can be, else field by field. A
/// reading it cannot read is left out; an error it cannot read (a case this build does not know) is kept as a failure,
/// `.failed("unknown")`, at its time and count, so the wait it set still holds as a backoff. A 429 is a case every
/// build knows, so its pause survives whatever else in the record cannot be read.
struct SalvagedRecord: Salvageable {
    var record: AccountRecord
    var damaged = false

    static let unknownError = ReadError.failed("unknown")

    private enum Key: String, CodingKey {
        case lastGood, lastError, lastErrorAt, lastAttemptAt, consecutiveFailures, restored, noPlan
    }

    init(from decoder: any Decoder) throws {
        if let whole = try? AccountRecord(from: decoder) {
            record = whole
            return
        }
        let container = try decoder.container(keyedBy: Key.self)
        func field<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
            guard container.contains(key), (try? container.decodeNil(forKey: key)) == false else { return nil }
            return try? container.decode(type, forKey: key)
        }
        var error = field(ReadError.self, .lastError)
        if error == nil, container.contains(.lastError), (try? container.decodeNil(forKey: .lastError)) == false {
            error = Self.unknownError
        }
        record = AccountRecord(lastGood: field(AccountReading.self, .lastGood), lastError: error,
                               lastErrorAt: field(Date.self, .lastErrorAt), lastAttemptAt: field(Date.self, .lastAttemptAt),
                               consecutiveFailures: field(Int.self, .consecutiveFailures) ?? (error == nil ? 0 : 1),
                               restored: field(Bool.self, .restored), noPlan: field(NoPlanStreak.self, .noPlan))
        damaged = true
    }
}
