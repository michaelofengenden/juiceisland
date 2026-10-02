import Darwin
import Foundation
import Synchronization
import Testing
@testable import JuiceCore

/// Several keys per source (Juice Island spec §8 decision 14): each further key is its own account, with its own key
/// file beside the source's (`key-2`, written 0600 like the first), its own reader, record, pause and Diagnostics lines.
/// Temporary homes and fake keys only.
@Suite struct MoneyAccountsTests {
    static let first = "sk-or-v1-" + String(repeating: "1", count: 64)
    static let second = "sk-or-v1-" + String(repeating: "2", count: 64)
    let lab = MoneyAccount(.openRouter, slot: 2)

    @Test func aFurtherKeyIsItsOwnFile0600BesideTheFirst() throws {
        let home = try MoneyTempDir()
        let fence = home.fence()
        #expect(MoneyKeyFile.furtherAccounts(of: .openRouter, guard: fence).isEmpty)
        #expect(try MoneyKeyFile.write(Self.first, for: .openRouter, guard: fence) == "~/.config/openrouter/key")
        #expect(try MoneyKeyFile.write(Self.second, for: lab, guard: fence) == "~/.config/openrouter/key-2")
        var info = stat()
        #expect(lstat(home.path + "/.config/openrouter/key-2", &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(MoneyKeyFile.furtherAccounts(of: .openRouter, guard: fence) == [lab])
        #expect(try MoneyKeyFile.read(MoneyKeyFile.path(for: lab, picked: nil, guard: fence)!, guard: fence).value == Self.second)
        #expect(try MoneyKeyFile.read(MoneyKeyFile.path(for: .openRouter, picked: nil, guard: fence)!, guard: fence).value == Self.first)
        // The first key's lookup never takes the further key's file, nor the further key another name.
        #expect(!MoneySource.openRouter.lookupPaths.contains("~/.config/openrouter/key-2"))
        try home.write(".config/openrouter/api-key", "sk-or-v1-OTHERTOOL")
        #expect(MoneyKeyFile.next(after: "~/.config/openrouter/key-2", for: lab, guard: fence) == nil)
        // Remove deletes that one file; the first key stays.
        #expect(MoneyKeyFile.removal(for: lab, picked: nil, guard: fence) == .delete("~/.config/openrouter/key-2"))
        try MoneyKeyFile.delete("~/.config/openrouter/key-2", for: lab, guard: fence)
        #expect(MoneyKeyFile.furtherAccounts(of: .openRouter, guard: fence).isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.path + "/.config/openrouter/key"))
        #expect(throws: MoneyKeyEditError.refused("not this source's key file")) {
            try MoneyKeyFile.delete("~/.config/openrouter/key", for: lab, guard: fence)
        }
        // A further Anthropic key is still only an Admin key.
        #expect(throws: MoneyKeyEditError.notAnAdminKey) {
            try MoneyKeyFile.write(FakeKeys.anthropicAPI, for: MoneyAccount(.anthropic, slot: 3), guard: fence)
        }
    }

    @Test func twoKeysOfOneSourceReadApart() async throws {
        let home = try MoneyTempDir()
        try MoneyKeyFile.write(Self.first, for: .openRouter, guard: home.fence())
        try MoneyKeyFile.write(Self.second, for: lab, guard: home.fence())
        let server = MoneyStubServer()
        try server.on(.openRouterKey, fixture: "openrouter-key")
        server.on(.openRouterCredits, status: 403)
        let clock = MoneySchedulerTests.Clock()
        let money = MoneyScheduler(client: server.client(clock: { clock.now }), clock: { clock.now }, sleep: { _ in throw CancellationError() },
                                   fence: { home.fence() })
        await money.update(settings: [lab: MoneySourceSettings(label: "OR lab")])
        let one = await money.readNow(.openRouter)
        let two = await money.readNow(lab)
        #expect(one.lastGood != nil && two.lastGood != nil && one.keyFileName == "key" && two.keyFileName == "key-2")
        let keys = server.received.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(keys == ["Bearer \(Self.first)", "Bearer \(Self.first)", "Bearer \(Self.second)", "Bearer \(Self.second)"])
        // Each account's requests are its own in Diagnostics.
        let lines = money.client.recentRequests
        #expect(lines.filter { $0.account == lab }.count == 2 && lines.filter { $0.account == .openRouter }.count == 2)
        // Each keeps its own reader: the first key's refused /credits is not the second's.
        clock.advance(120)
        _ = await money.readNow(.openRouter)
        #expect(server.count(.openRouterCredits) == 2)
        // A 429 on one pauses that one only.
        server.on(.openRouterKey, status: 429, headers: ["Retry-After": "30"])
        clock.advance(120)
        #expect(await money.readNow(lab).pausedUntil == clock.now + 930)
        #expect(await money.records[.openRouter]?.pausedUntil == nil)
        // Its key file gone and the settings no longer naming it, the account stops and its record goes, but for the
        // pause still running.
        try MoneyKeyFile.delete("~/.config/openrouter/key-2", for: lab, guard: home.fence())
        await money.update(settings: [:])
        let records = await money.records
        #expect(records[lab] == MoneySourceRecord(lastError: .rateLimited(retryAfter: 30), lastErrorAt: clock.now, lastAttemptAt: clock.now,
                                                  pausedUntil: clock.now + 930, consecutiveFailures: 1))
        #expect(records[.openRouter] != nil)
    }

    /// A further key removed and added again inside its 429 pause waits the pause out, as the first key does across
    /// Remove (Retry-After + 900 s); once the pause is over it reads at once, and a key removed with no pause running
    /// leaves no record.
    @Test func aFurtherKeysPauseOutlivesRemoveAndAddAgain() async throws {
        let home = try MoneyTempDir()
        let server = MoneyStubServer()
        server.on(.openRouterKey, status: 429, headers: ["Retry-After": "30"])
        let clock = MoneySchedulerTests.Clock()
        let start = clock.now
        let waits = Mutex<[TimeInterval]>([])
        let money = MoneyScheduler(client: server.client(clock: { clock.now }), records: Dictionary(uniqueKeysWithValues: MoneyAccount.firsts.map {
            ($0, MoneySourceRecord(pausedUntil: start + 5_000))
        }), clock: { clock.now }, sleep: { seconds in
            waits.withLock { $0.append(seconds) }
            throw CancellationError()
        }, fence: { home.fence() })
        await money.start(settings: [:])
        for _ in 0..<300 where waits.withLock({ $0.count }) < MoneySource.allCases.count { try await Task.sleep(for: .milliseconds(10)) }
        try MoneyKeyFile.write(Self.second, for: lab, guard: home.fence())
        await money.update(settings: [lab: MoneySourceSettings()])
        for _ in 0..<300 where await money.records[lab]?.pausedUntil == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await money.records[lab]?.pausedUntil == start + 930)

        // Remove, a minute later Add the same key in the same place: nothing is sent, the loop waits the 870 s left.
        try MoneyKeyFile.delete("~/.config/openrouter/key-2", for: lab, guard: home.fence())
        await money.update(settings: [:])
        let kept = await money.records[lab]
        #expect(kept?.pausedUntil == start + 930 && kept?.lastError == .rateLimited(retryAfter: 30) && kept?.lastGood == nil)
        clock.advance(60)
        try MoneyKeyFile.write(Self.second, for: lab, guard: home.fence())
        waits.withLock { $0 = [] }
        await money.update(settings: [lab: MoneySourceSettings()])
        for _ in 0..<300 where waits.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(waits.withLock { $0 } == [870])
        #expect(server.count(.openRouterKey) == 1)

        // After the pause: Remove and Add read at once, and a removal with no pause running keeps nothing.
        try MoneyKeyFile.delete("~/.config/openrouter/key-2", for: lab, guard: home.fence())
        await money.update(settings: [:])
        clock.advance(900)
        try server.on(.openRouterKey, fixture: "openrouter-key")
        try server.on(.openRouterCredits, fixture: "openrouter-credits")
        try MoneyKeyFile.write(Self.second, for: lab, guard: home.fence())
        await money.update(settings: [lab: MoneySourceSettings()])
        for _ in 0..<300 where await money.records[lab]?.lastGood == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await money.records[lab]?.lastGood != nil && server.count(.openRouterKey) == 2)
        try MoneyKeyFile.delete("~/.config/openrouter/key-2", for: lab, guard: home.fence())
        await money.update(settings: [:])
        #expect(await money.records[lab] == nil)
        await money.stop()
    }

    @Test func aFurtherKeyStartsItsOwnLoopWhenTheSettingsFirstNameIt() async throws {
        let home = try MoneyTempDir()
        let server = MoneyStubServer()
        try server.on(.openRouterKey, fixture: "openrouter-key")
        try server.on(.openRouterCredits, fixture: "openrouter-credits")
        let waits = Mutex<[TimeInterval]>([])
        let money = MoneyScheduler(client: server.client(), records: Dictionary(uniqueKeysWithValues: MoneyAccount.firsts.map {
            ($0, MoneySourceRecord(pausedUntil: MoneyReaderTests.now + 5_000))
        }), clock: { MoneyReaderTests.now }, sleep: { seconds in
            waits.withLock { $0.append(seconds) }
            throw CancellationError()
        }, fence: { home.fence() })
        await money.start(settings: [:])
        for _ in 0..<300 where waits.withLock({ $0.count }) < MoneySource.allCases.count { try await Task.sleep(for: .milliseconds(10)) }
        #expect(waits.withLock { $0 }.allSatisfy { $0 == 5_000 })
        try MoneyKeyFile.write(Self.second, for: lab, guard: home.fence())
        await money.update(settings: [lab: MoneySourceSettings()])
        for _ in 0..<300 where await money.records[lab]?.lastGood == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await money.records[lab]?.lastGood != nil)
        #expect(server.received.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.second)")
        // A label changes nothing that is read.
        let before = server.received.count
        await money.update(settings: [lab: MoneySourceSettings(label: "OR lab")])
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.received.count == before)
        await money.stop()
    }

    /// An id typed after `Team ID not set` reads at once: the look that found none sent nothing, so no floor holds. An id
    /// changed right after a read that reached the API waits out the 30 s floor.
    @Test func anIDSetAfterItWasMissingReadsAtOnceAndAChangeAfterAReadWaitsTheFloor() async throws {
        let home = try MoneyTempDir()
        try MoneyKeyFile.write("xai-FAKEmanagement0000000000", for: .xAI, guard: home.fence())
        let team = "00000000-0000-4000-8000-000000000000", other = "00000000-0000-4000-8000-000000000001"
        let server = MoneyStubServer()
        for id in [team, other] {
            server.on("GET", "management-api.x.ai", "/v1/billing/teams/\(id)/prepaid/balance", json: #"{"changes":[],"total":{"val":"-100"}}"#)
        }
        let now = MoneyReaderTests.now
        var records = Dictionary(uniqueKeysWithValues: MoneyAccount.firsts.map { ($0, MoneySourceRecord(pausedUntil: now + 5_000)) })
        records[.xAI] = MoneySourceRecord(lastError: .idMissing("Team ID"), lastErrorAt: now - 5, lastAttemptAt: now - 5)
        let waits = Mutex<[TimeInterval]>([])
        let money = MoneyScheduler(client: server.client(), records: records, clock: { now }, sleep: { seconds in
            waits.withLock { $0.append(seconds) }
            throw CancellationError()
        }, fence: { home.fence() })
        await money.start(settings: [:])
        for _ in 0..<300 where waits.withLock({ $0.count }) < MoneySource.allCases.count { try await Task.sleep(for: .milliseconds(10)) }
        waits.withLock { $0 = [] }

        await money.update(settings: [.xAI: MoneySourceSettings(accountID: team)])
        for _ in 0..<300 where await money.records[.xAI]?.lastGood == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await money.records[.xAI]?.lastGood?.figures == .balance(BalanceFigures(currency: .usd, amount: 1)))
        #expect(server.received.count == 1)
        for _ in 0..<300 where waits.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(waits.withLock { $0 } == [300])

        waits.withLock { $0 = [] }
        await money.update(settings: [.xAI: MoneySourceSettings(accountID: other)])
        for _ in 0..<300 where waits.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(waits.withLock { $0 } == [30])
        #expect(server.received.count == 1)
        await money.stop()
    }
}
