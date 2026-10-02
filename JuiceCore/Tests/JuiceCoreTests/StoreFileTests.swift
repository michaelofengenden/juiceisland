import Foundation
import Testing
@testable import JuiceCore

/// P111: one record this build cannot read (an error case another build added, a reading of another shape) costs only
/// that record, a 429's wait survives it, and a file this build cannot read whole is kept before it is written over.
/// Fictional folders and example.com emails only.
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("juice-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A value as the JSON object the app writes, to change by hand.
private func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder.juice.encode(value))
}

private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }

private func reading(_ id: String, used: Double = 40) -> AccountReading {
    AccountReading(accountID: id, readAt: t0, plan: "max", windows: [UsageWindow(seconds: 18_000, usedPercent: used, resetsAt: t0 + 3_600)])
}

/// readings.json as a newer build might leave it: a 429, a failure of a case this build does not know, a reading of
/// another shape, and a record that is not a record at all.
private func mixedReadings() throws -> Data {
    let limited = AccountRecord(lastError: .rateLimited(retryAfter: 60), lastErrorAt: t0, lastAttemptAt: t0, consecutiveFailures: 1)
    var unknown = try object(AccountRecord(lastError: .timeout, lastErrorAt: t0 - 60, lastAttemptAt: t0 - 60, consecutiveFailures: 3))
        as! [String: Any]
    unknown["lastError"] = ["quotaExhausted": ["until": 5]]
    var reshaped = try object(AccountRecord(lastGood: reading("claude:/h/.claude-work"), lastAttemptAt: t0)) as! [String: Any]
    var good = reshaped["lastGood"] as! [String: Any]
    good["windows"] = "several"
    reshaped["lastGood"] = good
    return try json(["version": 1, "records": ["codex:/h/.codex-side": try object(limited), "claude:/h/.claude-lab": unknown,
                                               "claude:/h/.claude-work": reshaped, "codex:/h/.codex": "not a record"]])
}

@MainActor
@Test func aRecordThisBuildCannotReadCostsOnlyItselfAndThe429Stays() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("readings.json")
    let original = try mixedReadings()
    try original.write(to: url)

    let store = ReadingsStore(fileURL: url)
    store.load()
    #expect(store.records.count == 3)
    let limited = store.record(for: "codex:/h/.codex-side")
    #expect(limited.lastError == .rateLimited(retryAfter: 60) && limited.lastErrorAt == t0 && limited.consecutiveFailures == 1)
    // A case this build does not know is a failure at its time and count: its backoff still holds.
    let unknown = store.record(for: "claude:/h/.claude-lab")
    #expect(unknown.lastError == .failed("unknown") && unknown.lastErrorAt == t0 - 60 && unknown.consecutiveFailures == 3)
    #expect(RefreshPolicy().delay(after: unknown.lastError!, consecutiveFailures: unknown.consecutiveFailures, provider: .claude) == 1_200)
    let reshaped = store.record(for: "claude:/h/.claude-work")
    #expect(reshaped.lastGood == nil && reshaped.lastAttemptAt == t0)

    // The first write keeps the file as it was, then writes what was read; the next write keeps nothing more.
    try store.save()
    let kept = StoreFile.keptCopies(of: url)
    #expect(kept.count == 1 && kept.first?.lastPathComponent.hasPrefix("readings.json.unreadable-") == true)
    #expect(try Data(contentsOf: kept[0]) == original)
    #expect(ReadingsStore.isReadable(try Data(contentsOf: url)))
    store.apply(.failure(.timeout), for: "codex:/h/.codex-side", at: t0 + 1_000)
    try store.save()
    #expect(StoreFile.keptCopies(of: url).count == 1)

    let reloaded = ReadingsStore(fileURL: url)
    reloaded.load()
    #expect(reloaded.records.count == 3 && reloaded.record(for: "claude:/h/.claude-lab").lastError == .failed("unknown"))
}

/// A file that is not JSON at all is read as nothing, and kept whole before the first write.
@MainActor
@Test func anUnreadableFileIsKeptBeforeItIsWrittenOver() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("readings.json")
    let junk = Data("{ \"version\": 1, \"records\": ".utf8)
    try junk.write(to: url)
    let store = ReadingsStore(fileURL: url)
    store.load()
    #expect(store.records.isEmpty)
    store.apply(.success(reading("codex:/h/.codex")), for: "codex:/h/.codex", at: t0)
    try store.save()
    #expect(try StoreFile.keptCopies(of: url).map { try Data(contentsOf: $0) } == [junk])
    #expect(ReadingsStore.isReadable(try Data(contentsOf: url)))
}

/// When no copy can be kept (the folder is read-only), nothing is written: the file stays as it was.
@MainActor
@Test func noCopyNoWrite() throws {
    let dir = try folder()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    let url = dir.appendingPathComponent("readings.json")
    let original = try mixedReadings()
    try original.write(to: url)
    let store = ReadingsStore(fileURL: url)
    store.load()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    #expect(throws: (any Error).self) { try store.save() }
    #expect(try Data(contentsOf: url) == original)
    #expect(StoreFile.keptCopies(of: url).isEmpty)
}

/// The same bytes are kept once, and at most `keptLimit` copies of a file are kept, the newest.
@Test func copiesAreKeptOnceAndAtMostFive() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("logins.json")
    #expect(try StoreFile.keep(Data("a".utf8), of: url, now: t0) != nil)
    #expect(try StoreFile.keep(Data("a".utf8), of: url, now: t0 + 1) == nil)
    for n in 1...6 { _ = try StoreFile.keep(Data("b\(n)".utf8), of: url, now: t0 + TimeInterval(n * 60)) }
    let kept = StoreFile.keptCopies(of: url)
    #expect(kept.count == StoreFile.keptLimit)
    #expect(try kept.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) } == ["b2", "b3", "b4", "b5", "b6"])
}

/// logins.json: a login of a provider this build does not know and a folder state it cannot read are left out; a
/// login's record is read as readings.json's are; the rest is whole.
@MainActor
@Test func loginsAreReadLoginByLogin() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("logins.json")
    let a = "a@example.com", b = "b@example.com"
    let idA = LoginsStore.id(provider: .codex, email: a), idB = LoginsStore.id(provider: .claude, email: b)
    let loginA = Login(provider: .codex, email: a, record: AccountRecord(lastError: .rateLimited(retryAfter: 30), lastErrorAt: t0,
                                                                       lastAttemptAt: t0, consecutiveFailures: 1))
    var loginB = try object(Login(provider: .claude, email: b, record: AccountRecord(lastError: .offline, lastErrorAt: t0,
                                                                                     lastAttemptAt: t0, consecutiveFailures: 2)))
        as! [String: Any]
    var record = loginB["record"] as! [String: Any]
    record["lastError"] = ["someNewCase": [String: Any]()]
    loginB["record"] = record
    var other = try object(Login(provider: .codex, email: "c@example.com")) as! [String: Any]
    other["provider"] = "gemini"
    let folders: [String: Any] = ["codex:/h/.codex": try object(FolderState.signedIn(login: idA)),
                                  "claude:/h/.claude-lab": ["somewhere": [String: Any]()],
                                  "claude:/h/.claude": try object(FolderState.signedIn(login: idB))]
    try json(["version": 2, "logins": [idA: try object(loginA), idB: loginB, "gemini#1": other], "folders": folders]).write(to: url)

    let store = LoginsStore(fileURL: url)
    store.load()
    #expect(Set(store.logins.keys) == [idA, idB])
    #expect(store.logins[idA] == loginA)
    #expect(store.logins[idB]?.record?.lastError == .failed("unknown") && store.logins[idB]?.record?.consecutiveFailures == 2)
    #expect(store.folders == ["codex:/h/.codex": .signedIn(login: idA), "claude:/h/.claude": .signedIn(login: idB)])
    try store.save()
    #expect(StoreFile.keptCopies(of: url).count == 1)
    #expect(LoginsStore.isReadable(try Data(contentsOf: url)))
}

/// accounts.json: an account of a provider this build does not know is left out, the others keep their order.
@MainActor
@Test func accountsAreReadAccountByAccount() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("accounts.json")
    let lab = Account(provider: .claude, folder: "/h/.claude-lab", alias: "Lab")
    let side = Account(provider: .codex, folder: "/h/.codex-side", alias: "Side")
    var other = try object(Account(provider: .codex, folder: "/h/.gemini", alias: "Gemini")) as! [String: Any]
    other["provider"] = "gemini"
    try json(["version": 1, "accounts": [try object(lab), other, try object(side), 7]]).write(to: url)
    let store = AccountsStore(fileURL: url)
    store.load()
    #expect(store.accounts == [lab, side])
    #expect(AccountsStore.accounts(in: try Data(contentsOf: url)) == [lab, side])
}

/// money.json: a source this build does not know is left out and the file is kept before a write; a record whose error
/// case it does not know keeps its 429 pause and its count.
@Test func moneyRecordsAreReadSourceBySourceAndPausesStay() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("money.json")
    var paused = try object(MoneySourceRecord(lastError: .timeout, lastErrorAt: t0, lastAttemptAt: t0, pausedUntil: t0 + 960,
                                              consecutiveFailures: 2)) as! [String: Any]
    paused["lastError"] = ["tooManyRequests": [String: Any]()]
    let fine = MoneySourceRecord(lastAttemptAt: t0, consecutiveFailures: 0)
    let original = try json(["version": 1, "records": ["OpenRouter": paused, "Anthropic": try object(fine), "Stripe": try object(fine)]])
    try original.write(to: url)

    let store = MoneyStore(url: url)
    let records = store.load()
    #expect(Set(records.keys) == [.openRouter, .anthropic])
    #expect(records[.openRouter]?.pausedUntil == t0 + 960 && records[.openRouter]?.consecutiveFailures == 2)
    #expect(records[.openRouter]?.lastError == .unreadableResponse("unknown"))
    #expect(records[.anthropic] == fine)
    store.save(records)
    #expect(try StoreFile.keptCopies(of: url).map { try Data(contentsOf: $0) } == [original])
    #expect(MoneyStore.isReadable(try Data(contentsOf: url)))
}

/// P113: the writer takes a file's changes within its delay as one write, the last one, off the caller's thread; a
/// store writes only when what it holds changed; the files are compact.
@MainActor
@Test func theWriterWritesAFilesChangesOnceOffTheMainThread() async throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("readings.json")
    let writer = StoreWriter(delay: 0.2)
    let onMain = LockedBox<[Bool]>([])
    for n in 1...3 {
        writer.write(url, isReadable: { _ in true }) {
            onMain.withValue { $0.append(Thread.isMainThread) }
            return Data("\(n)".utf8)
        }
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
    for _ in 0..<100 where writer.writeCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(try Data(contentsOf: url) == Data("3".utf8))
    #expect(writer.writeCount == 1 && onMain.withValue { $0 } == [false])

    let store = ReadingsStore(fileURL: url)
    store.writer = writer
    store.apply(.success(reading("codex:/h/.codex")), for: "codex:/h/.codex", at: t0)
    try store.save()
    writer.flush()
    #expect(writer.writeCount == 2)
    try store.save()
    writer.flush()
    #expect(writer.writeCount == 2)                                   // nothing changed, nothing written
    store.apply(.failure(.timeout), for: "codex:/h/.codex", at: t0 + 60)
    try store.save()
    writer.flush()
    #expect(writer.writeCount == 3)
    let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    #expect(!text.contains("\n") && text.contains("\"version\":1"))
}
