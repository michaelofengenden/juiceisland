import Foundation
import Testing
@testable import JuiceCore

private func reading(_ id: String, at date: Date, used: Double = 40) -> AccountReading {
    AccountReading(accountID: id, readAt: date, plan: "max", windows: [UsageWindow(seconds: 18_000, usedPercent: used, resetsAt: date.addingTimeInterval(3_000))])
}

@MainActor
@Test func failuresNeverLoseTheLastGoodReading() {
    let store = ReadingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("juice-readings-\(UUID().uuidString).json"))
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    store.apply(.success(reading("claude:/a", at: t0)), for: "claude:/a", at: t0)
    store.apply(.failure(.timeout), for: "claude:/a", at: t0 + 300)
    store.apply(.failure(.offline), for: "claude:/a", at: t0 + 600)
    let record = store.record(for: "claude:/a")
    #expect(record.lastGood?.readAt == t0)
    #expect(record.lastError == .offline)
    #expect(record.lastErrorAt == t0 + 600)
    #expect(record.lastAttemptAt == t0 + 600)
    #expect(record.consecutiveFailures == 2)
    store.apply(.success(reading("claude:/a", at: t0 + 900, used: 50)), for: "claude:/a", at: t0 + 900)
    let after = store.record(for: "claude:/a")
    #expect(after.lastGood?.readAt == t0 + 900)
    #expect(after.lastError == nil)
    #expect(after.consecutiveFailures == 0)
}

@MainActor
@Test func storeRoundTripsToDisk() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("juice-readings-\(UUID().uuidString).json")
    let store = ReadingsStore(fileURL: url)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    store.apply(.success(reading("codex:/b", at: t0)), for: "codex:/b", at: t0)
    store.apply(.failure(.signInRequired), for: "claude:/c", at: t0)
    try store.save()
    let reloaded = ReadingsStore(fileURL: url)
    reloaded.load()
    #expect(reloaded.record(for: "codex:/b").lastGood?.windows.first?.usedPercent == 40)
    #expect(reloaded.record(for: "claude:/c").lastError == .signInRequired)
    reloaded.forget(id: "claude:/c")
    #expect(reloaded.records["claude:/c"] == nil)
}

/// P731, standalone Juice's file: a reading that began before the last good one and ended after it never replaces it.
@MainActor
@Test func aReadingOlderThanTheLastGoodOneNeverReplacesIt() {
    let store = ReadingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("juice-readings-\(UUID().uuidString).json"))
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    store.apply(.success(reading("codex:/a", at: t0 + 10, used: 40)), for: "codex:/a", at: t0 + 12)
    store.apply(.success(reading("codex:/a", at: t0, used: 90)), for: "codex:/a", at: t0 + 20)
    #expect(store.record(for: "codex:/a").lastGood?.readAt == t0 + 10)
    #expect(store.record(for: "codex:/a").lastAttemptAt == t0 + 20)
    // A clock set back an hour with a failure first: the next read is the newest, though it began before t0 + 10.
    store.apply(.failure(.offline), for: "codex:/a", at: t0 - 3_590)
    store.apply(.success(reading("codex:/a", at: t0 - 3_580, used: 70)), for: "codex:/a", at: t0 - 3_579)
    #expect(store.record(for: "codex:/a").lastGood?.readAt == t0 - 3_580)
    #expect(store.record(for: "codex:/a").lastError == nil)
}
