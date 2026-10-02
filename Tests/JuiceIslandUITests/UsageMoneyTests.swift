import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// Money is the same over every usage model the app runs: the release build's own readers and a dev build's mirror of
/// Juice's readings both get the money model's rows (`MoneyUsageModel`), only the release build reads money, and a dev
/// build mirrors the release build's `money.json` read-only. Temporary folders, fake readers and a stub `URLProtocol`
/// that fails every request; no key file exists.
@MainActor
@Suite struct UsageMoneyTests {
    typealias F = LiveFakes

    static func stubClient() -> (MoneyHTTPClient, String) {
        let agent = AppMoneyStub.register([:])
        return (MoneyHTTPClient(protocolClasses: [AppMoneyStub.self], userAgent: agent), agent)
    }

    @Test func onlyTheReleaseBuildReadsMoney() {
        #expect(LiveMoneyModel.role(identity: .production) == .reads)
        #expect(LiveMoneyModel.role(identity: .development) == .mirrors)
        #expect(LiveMoneyModel.role(identity: .other) == nil)
        // And never in a test process, whatever the identity.
        for identity in [AppIdentity.production, .development, .other] {
            #expect(LiveMoneyModel.app(settings: .ephemeral(), identity: identity) == nil)
        }
    }

    @Test func theReleaseBuildPutsMoneyOverItsOwnReaders() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work])
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("money-release-\(UUID().uuidString)", isDirectory: true)
        let (client, agent) = Self.stubClient()
        let settings = AppSettings.ephemeral()
        settings.usageSource = .juiceReadings
        var identities: [AppIdentity] = []
        let money = LiveMoneyModel(settings: settings, client: client, store: nil, home: home.path, clock: { DemoClock.now })
        let env = AppEnvironment.app(settings: settings, juiceDirectory: fakes.directory, identity: .production,
                                     live: { fakes.model() }, money: { _, identity in identities.append(identity); return money })
        #expect(identities == [.production])
        let wrapped = try #require(env.usage as? MoneyUsageModel)
        let live = try #require(env.liveUsage)
        #expect(wrapped.base === live && live.phase == .reading)
        #expect(money.isRunning)
        await live.settle()
        // The batteries are the readers'; money is the money model's (nothing configured: no row, no request).
        #expect(env.usage.accounts.map(\.id) == [F.work.id] && fakes.reads == ["read \(F.work.id)"])
        #expect(env.usage.panel.money.isEmpty && env.usage.moneyDetails.isEmpty)
        #expect(env.usage.refreshTotal == live.refreshTotal)
        // Demo: both stop.
        settings.usageSource = .demo
        for _ in 0..<100 where !(env.usage is DemoUsageModel) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(env.usage is DemoUsageModel && env.liveUsage == nil)
        #expect(!money.isRunning && live.phase == .idle)
        #expect(AppMoneyStub.unexpected(agent).isEmpty)
    }

    @Test func aDevBuildMirrorsTheReleaseBuildsMoneyReadOnly() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.work, F.side])
        let url = fakes.directory.appendingPathComponent("money.json")
        let store = MoneyStore(url: url)
        store.save(MoneyModelTests.mixed)
        let before = try Data(contentsOf: url)
        let (client, agent) = Self.stubClient()
        let settings = AppSettings.ephemeral()
        settings.usageSource = .juiceReadings
        let money = LiveMoneyModel(settings: settings, client: client, store: store, home: fakes.directory.path,
                                   clock: { DemoClock.now }, mirrorsOnly: true)
        let env = AppEnvironment.app(settings: settings, juiceDirectory: fakes.directory, identity: .development,
                                     live: { Issue.record("live model made in a dev build"); return fakes.model() },
                                     money: { _, _ in money })
        let wrapped = try #require(env.usage as? MoneyUsageModel)
        #expect(wrapped.base is JuiceReadingsUsageModel && env.liveUsage == nil)
        #expect(env.usage.panel.money.map(\.id) == ["OpenRouter", "Anthropic", "RunPod"])
        #expect(env.usage.panel.money.first?.amount == "$4,120")
        #expect(env.usage.moneyDetails["Anthropic"]?.status == "Not available with this key")
        // Read only: no reader, no refresh, nothing sent, the file untouched.
        #expect(!money.isRunning)
        for source in MoneySource.allCases { #expect(!env.usage.canRefreshMoney(source.rawValue)) }
        env.usage.refreshAll()
        env.usage.refreshMoney("OpenRouter")
        money.apply(.hetzner, MoneySourceRecord(lastError: .http(500), lastErrorAt: DemoClock.now))
        #expect(try Data(contentsOf: url) == before)
        // The release build's next write shows on the mirror's next tick.
        var next = MoneyModelTests.mixed
        next[.hetzner] = MoneyModelTests.reading(.hetzner, .spend(HetznerFigures(items: [.init(kind: .server, name: "cx22", monthly: 153)]).spend(from: MoneyRules.startOfMonth(DemoClock.now))))
        store.save(next)
        money.reloadMirror()
        #expect(env.usage.panel.money.map(\.id) == ["OpenRouter", "Anthropic", "RunPod", "Hetzner"])
        settings.usageSource = .demo
        for _ in 0..<100 where !(env.usage is DemoUsageModel) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fakes.entries.isEmpty && money.requests.isEmpty)
        #expect(AppMoneyStub.unexpected(agent).isEmpty)
    }

    /// P113: the app's money.json goes through a `StoreWriter` like the other stores, off the main thread, and what
    /// waits is on disk once the readers stop (another usage source, a quit), a 429's pause with it.
    @Test func theAppsMoneyStoreWritesOffTheMainThreadAndStopWritesWhatWaits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("money-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("money.json")
        let store = LiveMoneyModel.store(at: url)
        #expect(store.writer != nil)
        let (client, agent) = Self.stubClient()
        let money = LiveMoneyModel(settings: .ephemeral(), client: client, store: store, home: folder.path, clock: { DemoClock.now })
        let paused = MoneySourceRecord(lastError: .rateLimited(retryAfter: 30), lastErrorAt: DemoClock.now,
                                       pausedUntil: DemoClock.now.addingTimeInterval(930))
        money.apply(.openRouter, paused)
        money.stop()
        #expect(MoneyStore(url: url).load()[.openRouter]?.pausedUntil == paused.pausedUntil)
        #expect(store.writer?.writeCount == 1)
        #expect(AppMoneyStub.unexpected(agent).isEmpty)
    }

    @Test func theDesktopPanelRefreshesOneSourceWhereMoneyReads() {
        let env = AppEnvironment.demo()
        let actions = PanelActions.desktop(env: env)
        // Demo money reads nothing, so Refresh source is off; with nothing wired (the island's rows) it is off too.
        #expect(!actions.canRefreshSource("OpenRouter"))
        #expect(!PanelActions().canRefreshSource("OpenRouter"))
        let (live, _) = MoneyModelTests.live(MoneyModelTests.mixed)
        // Not started: nothing to refresh.
        #expect(!PanelActions.desktop(env: live).canRefreshSource("OpenRouter"))
    }
}
