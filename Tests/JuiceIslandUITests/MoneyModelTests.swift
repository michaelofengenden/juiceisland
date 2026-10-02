import Foundation
import JuiceCore
import Synchronization
import Testing
@testable import JuiceIslandUI

/// The money readers in the app: rows from the scheduler's records into every surface's usage model, unconfigured
/// sources hidden, Settings › Money's values, and no real reader in tests (in-memory settings never start one). Fake
/// keys, temporary folders and a stub `URLProtocol` only.
@MainActor
@Suite struct MoneyModelTests {
    static let now = DemoClock.now

    static func reading(_ source: MoneySource, _ figures: MoneyReading.Figures, ago: TimeInterval = 120) -> MoneySourceRecord {
        MoneySourceRecord(lastGood: MoneyReading(source: source, readAt: now - ago, figures: figures), keyFileName: "key")
    }

    /// OpenRouter and RunPod read, Anthropic's key lacks the role, OpenAI and Hetzner have no key file.
    static let mixed: [MoneyAccount: MoneySourceRecord] = [
        .openRouter: reading(.openRouter, .balance(OpenRouterFigures(usageDaily: 38.2, totalCredits: 5_000, totalUsage: 880).kind)),
        .anthropic: MoneySourceRecord(lastError: .keyNotUsable, lastErrorAt: now - 60, keyFileName: "admin-key"),
        .openAI: MoneySourceRecord(lastError: .notConfigured, lastErrorAt: now - 60),
        .runPod: reading(.runPod, .balance(RunPodFigures(balance: 110, burnPerHour: 1.84).kind)),
        .hetzner: MoneySourceRecord(lastError: .notConfigured, lastErrorAt: now - 60),
    ]

    /// `home` holds the key files Settings › Money finds (none by default).
    static func live(_ records: [MoneyAccount: MoneySourceRecord], settings: AppSettings = .ephemeral(),
                     home: String = "/nonexistent-home") -> (AppEnvironment, LiveMoneyModel) {
        let money = LiveMoneyModel(settings: settings, client: MoneyHTTPClient(protocolClasses: [AppMoneyStub.self]), store: nil,
                                   home: home, clock: { DemoClock.now })
        for (source, record) in records { money.apply(source, record) }
        let env = AppEnvironment.demo(settings: settings)
        env.followUsageSource { _ in MoneyUsageModel(base: DemoUsageModel(now: now), money: money) }
        return (env, money)
    }

    @Test func noRealReaderInTestsOrForInMemorySettings() {
        #expect(LiveMoneyModel.app(settings: .ephemeral()) == nil)
        #expect(LiveMoneyModel.runningUnderTests)
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(LiveMoneyModel.app(settings: AppSettings(defaults: defaults)) == nil)
    }

    /// P363: a key OpenAI or Hetzner refused (401, 403) says what to do, in Settings › Money and Diagnostics alike (both
    /// draw the detail's status).
    @Test func aRefusedKeySaysWhatToDo() {
        let refused = MoneySourceRecord(lastError: .notAvailableWithThisKey, lastErrorAt: Self.now - 60, keyFileName: "key")
        let (env, _) = Self.live([.openAI: refused, .hetzner: refused, .anthropic: refused])
        #expect(env.usage.moneyDetails["OpenAI"]?.status == "Needs an Admin key (sk-admin-…)")
        #expect(env.usage.moneyDetails["Hetzner"]?.status == "Token rejected · make a Read token")
        #expect(env.usage.moneyDetails["Anthropic"]?.status == "Not available with this key")
    }

    @Test func unconfiguredSourcesAreHiddenAndTheRestShow() throws {
        let (env, _) = Self.live(Self.mixed)
        let usage = env.usage
        #expect(usage.panel.money.map(\.id) == ["OpenRouter", "Anthropic", "RunPod"])
        let openRouter = try #require(usage.panel.money.first { $0.id == "OpenRouter" })
        #expect(openRouter.amount == "$4,120" && openRouter.hoverLabel == "OpenRouter · $4,120 balance · $38.20 today · read 2m ago")
        let anthropic = try #require(usage.panel.money.first { $0.id == "Anthropic" })
        #expect(anthropic.amount == nil)
        #expect(usage.moneyDetails["Anthropic"]?.status == "Not available with this key")
        #expect(usage.moneyDetails["Anthropic"]?.isReadable == false)
        let runPod = try #require(usage.panel.money.first { $0.id == "RunPod" })
        #expect(runPod.suffix == "59h" && runPod.emphasis == .warn)
        #expect(usage.moneyDetails["RunPod"]?.keyFile == "key")
        // The batteries are the base model's.
        #expect(usage.panel.rows.count == 2 && usage.accounts.count == 11)
        // The header strip's figure: the unreadable source first.
        #expect(MoneyDetail.urgent(usage.shownMoney(env.settings), details: usage.moneyDetails, amber: 72, red: 24)?.id == "Anthropic")
    }

    @Test func thresholdsRetoneAtOnce() throws {
        let (env, _) = Self.live(Self.mixed)
        env.settings.runwayRedHours = 60
        #expect(env.usage.panel.money.first { $0.id == "RunPod" }?.emphasis == .attention)
        env.settings.runwayAmberHours = 48
        env.settings.runwayRedHours = 24
        #expect(env.usage.panel.money.first { $0.id == "RunPod" }?.emphasis == .normal)
        // The switch from hours to days stays at 72 h.
        #expect(env.usage.panel.money.first { $0.id == "RunPod" }?.suffix == "59h")
    }

    @Test func nothingConfiguredShowsNoMoneyAnywhere() {
        let (env, _) = Self.live([:])
        #expect(env.usage.panel.money.isEmpty)
        #expect(env.usage.shownMoney(env.settings).isEmpty)
        #expect(env.usage.moneyDetails.isEmpty)
        #expect(!env.usage.canRefreshMoney("OpenRouter"))
    }

    @Test func creditsAndTopUpsShapeTheFigures() throws {
        let settings = AppSettings.ephemeral()
        let september7 = Date(timeIntervalSince1970: 1_788_739_200)
        settings.money.credits[.anthropic] = 1_400
        settings.money.creditDates[.anthropic] = september7
        settings.money.topUps[.openRouter] = 5_000
        let costs = CostFigures(daily: ["2026-09-07": 985, "2026-09-24": 61], coveredFrom: september7)
        let (env, money) = Self.live([.anthropic: Self.reading(.anthropic, .spend(costs)),
                                  .openRouter: Self.reading(.openRouter, .balance(OpenRouterFigures(totalCredits: 5_000, totalUsage: 880).kind))],
                                 settings: settings)
        let anthropic = try #require(env.usage.panel.money.first { $0.id == "Anthropic" })
        #expect(anthropic.amount == "$354" && !anthropic.isSpent)
        #expect(env.usage.moneyDetails["Anthropic"]?.denominator == "of $1,400 · 7 Sep")
        #expect(env.usage.moneyDetails["OpenRouter"]?.creditLeftShare.map { abs($0 - 0.824) < 0.0001 } == true)
        // The credit removed: rails until the next read reaches back to the first of the month, then this month's
        // spend, grey.
        settings.money.credits[.anthropic] = nil
        #expect(env.usage.panel.money.first { $0.id == "Anthropic" }?.amount == nil)
        #expect(env.usage.moneyDetails["Anthropic"]?.status == "Reading…")
        let month = CostFigures(daily: costs.daily, coveredFrom: Date(timeIntervalSince1970: 1_788_220_800))
        money.apply(.anthropic, Self.reading(.anthropic, .spend(month)))
        #expect(env.usage.panel.money.first { $0.id == "Anthropic" }?.isSpent == true)
        #expect(env.usage.panel.money.first { $0.id == "Anthropic" }?.amount == "$1,046")
    }

    @Test func moneySettingsPersistUnderTheirOwnKeys() throws {
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.money.keyFiles[.openRouter] = "~/.config/openrouter/key"
        settings.money.credits[.openAI] = 500
        settings.money.topUps[.runPod] = 250
        #expect(defaults.string(forKey: "ji.money.keyFile.OpenRouter") == "~/.config/openrouter/key")
        #expect(defaults.double(forKey: "ji.money.credit.OpenAI") == 500)
        #expect(defaults.double(forKey: "ji.money.topUp.RunPod") == 250)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.money.source(.openRouter).keyPath == "~/.config/openrouter/key")
        #expect(reloaded.money.source(.openAI).credit == 500)
        #expect(reloaded.money.source(.runPod).topUp == 250)
        // A credit on a source that takes none is ignored.
        reloaded.money.credits[.hetzner] = 9
        #expect(reloaded.money.source(.hetzner).credit == nil)
        settings.money.keyFiles[.openRouter] = nil
        #expect(defaults.object(forKey: "ji.money.keyFile.OpenRouter") == nil)
        // The existing keys are untouched.
        #expect(AppSettings.Key.runwayAmberHours == "ji.money.runwayAmberHours" && AppSettings.Key.moneyShown(.hetzner) == "ji.money.shown.Hetzner")
    }

    @Test func amountFieldsParseLoosely() {
        #expect(MoneyAmountField.parse("1400") == 1_400)
        #expect(MoneyAmountField.parse("$1,400.50") == 1_400.5)
        #expect(MoneyAmountField.parse("") == nil && MoneyAmountField.parse("abc") == nil && MoneyAmountField.parse("0") == nil)
        #expect(MoneyAmountField.format(1_400) == "1400" && MoneyAmountField.format(12.5) == "12.50" && MoneyAmountField.format(nil) == "")
        // An absurd amount is no amount, and formatting one never traps.
        #expect(MoneyAmountField.parse("100000000000000000000") == nil)
        #expect(MoneyAmountField.format(1e20) == "" && MoneyAmountField.format(.infinity) == "")
    }

    @Test func theLiveModelReadsAKeyFileThroughTheStub() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("money-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let keyFolder = home.appendingPathComponent(".config/openrouter", isDirectory: true)
        try FileManager.default.createDirectory(at: keyFolder, withIntermediateDirectories: true)
        try Data("sk-or-v1-FAKEFAKEFAKEFAKEFAKEFAKE".utf8).write(to: keyFolder.appendingPathComponent("key"))
        let agent = AppMoneyStub.register([
            "/api/v1/key": #"{"data":{"usage":10,"usage_daily":1.5,"usage_monthly":10,"limit":null,"limit_remaining":null}}"#,
            "/api/v1/credits": #"{"data":{"total_credits":100,"total_usage":10}}"#,
        ])
        let settings = AppSettings.ephemeral()
        let money = LiveMoneyModel(settings: settings, client: MoneyHTTPClient(protocolClasses: [AppMoneyStub.self], userAgent: agent),
                                   store: nil, home: home.path)
        let usage = MoneyUsageModel(base: DemoUsageModel(), money: money)
        money.start()
        defer { money.stop() }
        for _ in 0..<300 where money.records[.openRouter]?.lastGood == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(usage.panel.money.map(\.id) == ["OpenRouter"])
        #expect(usage.panel.money.first?.amount == "$90.00")
        #expect(usage.moneyDetails["OpenRouter"]?.status == "Connected")
        #expect(usage.moneyDetails["OpenRouter"]?.keyFile == "key")
        #expect(money.requests.map(\.line).contains("GET openrouter.ai/api/v1/key · 200"))
        #expect(usage.canRefreshMoney("OpenRouter") && !usage.canRefreshMoney("Hetzner"))
        #expect(AppMoneyStub.unexpected(agent).isEmpty)
    }
}

/// The UI tests' stub: answers a test's own paths (found by the client's User-Agent) and fails everything else.
final class AppMoneyStub: URLProtocol, @unchecked Sendable {
    private static let routes = Mutex<[String: [String: String]]>([:])
    private static let misses = Mutex<[String: [String]]>([:])

    static func register(_ paths: [String: String]) -> String {
        let agent = "JuiceIsland-ui-test-\(UUID().uuidString)"
        routes.withLock { $0[agent] = paths }
        return agent
    }

    static func unexpected(_ agent: String) -> [String] { misses.withLock { $0[agent] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        let path = request.url?.path() ?? ""
        guard let url = request.url, let body = Self.routes.withLock({ $0[agent]?[path] }) else {
            Self.misses.withLock { $0[agent, default: []].append(path) }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
