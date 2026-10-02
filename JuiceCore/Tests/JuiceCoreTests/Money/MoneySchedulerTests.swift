import Foundation
import Synchronization
import Testing
@testable import JuiceCore

/// Juice spec §8.1 cadences, §9.5 waits; Juice Island spec §7 amendment 10 (keys read per request, never stored).
@Suite struct MoneySchedulerTests {
    static let now = MoneyReaderTests.now

    /// A clock the test moves.
    final class Clock: Sendable {
        private let value = Mutex(MoneySchedulerTests.now)
        var now: Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
    }

    private func scheduler(_ server: MoneyStubServer, home: MoneyTempDir, clock: Clock,
                           records: [MoneyAccount: MoneySourceRecord] = [:]) -> MoneyScheduler {
        MoneyScheduler(client: server.client(clock: { clock.now }), records: records, clock: { clock.now },
                       sleep: { _ in throw CancellationError() }, fence: { home.fence() })
    }

    @Test func cadencesAndWaits() {
        let policy = MoneySchedulePolicy()
        #expect(policy.delay(for: .openRouter, after: nil, consecutiveFailures: 0) == 120)
        #expect(policy.delay(for: .runPod, after: nil, consecutiveFailures: 0) == 120)
        #expect(policy.delay(for: .anthropic, after: nil, consecutiveFailures: 0) == 300)
        #expect(policy.delay(for: .openAI, after: nil, consecutiveFailures: 0) == 300)
        #expect(policy.delay(for: .hetzner, after: nil, consecutiveFailures: 0) == 300)
        #expect(policy.delay(for: .openRouter, after: .rateLimited(retryAfter: 30), consecutiveFailures: 1) == 930)
        #expect(policy.delay(for: .openRouter, after: .rateLimited(retryAfter: nil), consecutiveFailures: 1) == 960)
        #expect(policy.delay(for: .openAI, after: .notAvailableWithThisKey, consecutiveFailures: 1) == 1_800)
        #expect(policy.delay(for: .openRouter, after: .offline, consecutiveFailures: 1) == 120)
        #expect(policy.delay(for: .openRouter, after: .offline, consecutiveFailures: 3) == 600)
        #expect(policy.delay(for: .hetzner, after: .timeout, consecutiveFailures: 9) == 1_800)
        #expect(policy.delay(for: .anthropic, after: .keyNotUsable, consecutiveFailures: 4) == 300)
        #expect(MoneyHTTPClient.timeout == 15)
        #expect(MoneyRules.freshness == 600)
    }

    @Test func noKeyFileMeansNotConnectedAndNothingSent() async throws {
        let server = MoneyStubServer()
        let home = try MoneyTempDir()
        let clock = Clock()
        let money = scheduler(server, home: home, clock: clock)
        for account in MoneyAccount.firsts + [MoneyAccount(.openRouter, slot: 2)] {
            let record = await money.readNow(account)
            #expect(record.lastError == .notConfigured && record.lastGood == nil && record.consecutiveFailures == 0)
        }
        #expect(server.received.isEmpty)
    }

    @Test func moneyKeyIsReadPerRequestAndNeverStored() async throws {
        let server = MoneyStubServer()
        try server.on(.openRouterKey, fixture: "openrouter-key")
        try server.on(.openRouterCredits, fixture: "openrouter-credits")
        let home = try MoneyTempDir()
        let path = try home.write(".config/openrouter/key", FakeKeys.openRouter)
        let clock = Clock()
        let storeURL = home.url.appendingPathComponent("store/money.json")
        let money = scheduler(server, home: home, clock: clock)
        let first = await money.readNow(.openRouter)
        #expect(first.lastGood != nil)
        #expect(server.received.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(FakeKeys.openRouter)")

        // The owner swaps the key: the next read sends the new one.
        let newKey = "sk-or-v1-" + String(repeating: "1", count: 64)
        try Data(newKey.utf8).write(to: URL(fileURLWithPath: path))
        clock.advance(120)
        let second = await money.readNow(.openRouter)
        #expect(server.received.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(newKey)")

        // The key's text is in no reading, no saved file, no Diagnostics line and no error.
        let store = MoneyStore(url: storeURL)
        store.save(await money.records)
        let saved = try String(contentsOf: storeURL, encoding: .utf8)
        let texts = [saved, "\(first)", "\(second)", String(reflecting: second), money.client.recentRequests.map(\.line).joined()]
            + MoneySource.allCases.compactMap { source in
                MoneyPresentation.make(source: source, record: second, settings: MoneySourceSettings(), now: clock.now, amber: 72, red: 24)
                    .map { "\($0)" }
            }
            + [MoneyReadError.keyNotUsable, .keyFileRefused("x"), .notAvailableWithThisKey].map { "\($0) \($0.statusWord) \($0.hoverReason)" }
        for text in texts {
            #expect(!text.contains(FakeKeys.openRouter) && !text.contains(newKey) && !text.contains("sk-or-v1"))
        }
        #expect(store.load()[.openRouter]?.lastGood == second.lastGood)
    }

    @Test func aClaudeTokenInAnyKeyFileSendsNothing() async throws {
        let server = MoneyStubServer()
        let home = try MoneyTempDir()
        try home.write(".config/openrouter/key", FakeKeys.claudeOAuth)
        try home.write(".config/openai/admin-key", FakeKeys.claudeRefresh)
        try home.write(".config/anthropic/admin-key", FakeKeys.claudeOAuth)
        try home.write(".config/hcloud/token", FakeKeys.anthropicAdmin)
        try home.write(".config/runpod/key", FakeKeys.anthropicAPI)
        let money = scheduler(server, home: home, clock: Clock())
        for account in MoneySource.allCases.prefix(5).map({ MoneyAccount($0) }) {
            let record = await money.readNow(account)
            #expect(record.lastError == .keyNotUsable, "\(account)")
        }
        #expect(server.received.isEmpty)
    }

    @Test func aRefusedKeyFileIsNeverOpenedAndNothingIsSent() async throws {
        let server = MoneyStubServer()
        let home = try MoneyTempDir()
        let credential = try home.write(".codex-side/auth.json", "{}")
        let money = scheduler(server, home: home, clock: Clock())
        await money.update(settings: [.openAI: MoneySourceSettings(keyPath: credential)])
        let record = await money.readNow(.openAI)
        #expect(record.lastError == .keyFileRefused("a CLI credential file"))
        #expect(server.received.isEmpty)
    }

    @Test func rateLimitPausesAcrossRelaunches() async throws {
        let server = MoneyStubServer()
        server.on(.openRouterKey, status: 429, headers: ["Retry-After": "60"])
        let home = try MoneyTempDir()
        try home.write(".config/openrouter/key", FakeKeys.openRouter)
        let clock = Clock()
        let money = scheduler(server, home: home, clock: clock)
        let limited = await money.readNow(.openRouter)
        #expect(limited.lastError == .rateLimited(retryAfter: 60))
        #expect(limited.pausedUntil == Self.now + 960)
        // Paused: no request, even on a direct read.
        clock.advance(300)
        _ = await money.readNow(.openRouter)
        #expect(server.count(.openRouterKey) == 1)

        // A relaunch restores the pause from the saved records.
        let relaunched = scheduler(server, home: home, clock: clock, records: await money.records)
        _ = await relaunched.readNow(.openRouter)
        #expect(server.count(.openRouterKey) == 1)
        clock.advance(700)
        try server.on(.openRouterKey, fixture: "openrouter-key")
        try server.on(.openRouterCredits, fixture: "openrouter-credits")
        let after = await relaunched.readNow(.openRouter)
        #expect(after.lastGood != nil && after.lastError == nil && after.pausedUntil == nil)
    }

    @Test func aFailureKeepsTheLastGoodReading() async throws {
        let server = MoneyStubServer()
        try server.on(.runPodGraphQL, fixture: "runpod-myself")
        let home = try MoneyTempDir()
        try home.write(".config/runpod/key", FakeKeys.runPod)
        let clock = Clock()
        let money = scheduler(server, home: home, clock: clock)
        let good = await money.readNow(.runPod)
        server.on(.runPodGraphQL, status: 502)
        clock.advance(120)
        let failed = await money.readNow(.runPod)
        #expect(failed.lastGood == good.lastGood)
        #expect(failed.lastError == .http(502) && failed.consecutiveFailures == 1 && failed.isFailing)
    }

    @Test func theLoopReadsOnItsCadence() async throws {
        let server = MoneyStubServer()
        try server.on(.hetznerServers, fixture: "hetzner-servers-page2")
        try server.on(.hetznerVolumes, fixture: "hetzner-volumes")
        try server.on(.hetznerPrimaryIPs, fixture: "hetzner-primary-ips")
        try server.on(.hetznerFloatingIPs, fixture: "hetzner-floating-ips")
        try server.on(.hetznerPricing, fixture: "hetzner-pricing")
        let home = try MoneyTempDir()
        try home.write(".config/hetzner/token", FakeKeys.hetzner)
        let waits = Mutex<[TimeInterval]>([])
        let updates = Mutex<Int>(0)
        let clock = Clock()
        let money = MoneyScheduler(client: server.client(clock: { clock.now }), clock: { clock.now },
                                   sleep: { seconds in
                                       let count = waits.withLock { $0.append(seconds); return $0.count }
                                       clock.advance(seconds)
                                       if count > 2_000 { throw CancellationError() }
                                       try await Task.sleep(for: .milliseconds(2))
                                   },
                                   fence: { home.fence() },
                                   onUpdate: { source, _ in if source == .hetzner { updates.withLock { $0 += 1 } } })
        await money.start(settings: [:])
        for _ in 0..<300 where server.count(.hetznerPricing) < 2 { try await Task.sleep(for: .milliseconds(10)) }
        await money.stop()
        // Hetzner, the fifth source, first waits out the launch stagger (8 s), then reads every 300 s.
        #expect(waits.withLock { $0 }.contains(8))
        #expect(server.count(.hetznerPricing) >= 2)
        #expect(updates.withLock { $0 } >= 2)
        #expect(waits.withLock { $0 }.contains(300))
    }
}
