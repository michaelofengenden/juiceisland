import Foundation
import Testing
@testable import JuiceCore

/// One fixture parser test per endpoint (fictional figures), each through the stub; no test reaches the network.
@Suite struct MoneyReaderTests {
    /// 24 September 2026, 12:00 UTC (the demo clock).
    static let now = Date(timeIntervalSince1970: 1_790_251_200)
    static let september7 = Date(timeIntervalSince1970: 1_788_739_200)

    @Test func openRouterReadsTheKeyAndCreditsOnce() async throws {
        let server = MoneyStubServer()
        try server.on(.openRouterKey, fixture: "openrouter-key")
        try server.on(.openRouterCredits, fixture: "openrouter-credits")
        let reader = OpenRouterReader()
        let reading = try await reader.read(key: MoneyKey(FakeKeys.openRouter), context: MoneyReadContext(now: Self.now),
                                            client: server.client())
        guard case .balance(let figures) = reading.figures else { Issue.record("not a balance"); return }
        #expect(figures.spentToday == 38.2 && figures.spentThisMonth == 512.75 && figures.currency == .usd)
        #expect(figures.balance(topUp: nil) == 4_120)
        let parsed = try OpenRouterReader.parseKey(try moneyFixture("openrouter-key"))
        #expect(parsed.limitRemaining == nil)
        #expect(server.count(.openRouterKey) == 1 && server.count(.openRouterCredits) == 1)
        let auth = server.received.first?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer \(FakeKeys.openRouter)")
    }

    @Test func openRouterStopsAskingForCreditsWhenTheKeyMayNot() async throws {
        let server = MoneyStubServer()
        try server.on(.openRouterKey, fixture: "openrouter-key-limited")
        server.on(.openRouterCredits, status: 403, json: #"{"error":{"message":"forbidden"}}"#)
        let reader = OpenRouterReader()
        let client = server.client()
        for _ in 0..<3 {
            let reading = try await reader.read(key: MoneyKey(FakeKeys.openRouter), context: MoneyReadContext(now: Self.now), client: client)
            guard case .balance(let figures) = reading.figures else { Issue.record("not a balance"); return }
            #expect(figures.balance(topUp: nil) == 74.5)
            #expect(figures.spentToday == 3.1)
        }
        #expect(server.count(.openRouterKey) == 3)
        #expect(server.count(.openRouterCredits) == 1)
        // No limit and no credits: the configured top-up minus the key's usage.
        #expect(OpenRouterFigures(usageTotal: 25.5).balance(topUp: 100) == 74.5)
        #expect(OpenRouterFigures(usageTotal: 25.5).balance(topUp: nil) == nil)
    }

    @Test func anthropicReadsATwoPageCostReportThenTwoDays() async throws {
        let server = MoneyStubServer()
        try server.on(.anthropicCostReport, fixture: "anthropic-cost-page1")
        try server.on(.anthropicCostReport, fixture: "anthropic-cost-page2", query: "page=page_2")
        let reader = CostReportReader(format: AnthropicCostFormat())
        let client = server.client()
        let settings = MoneySourceSettings(credit: 1_400, creditDate: Self.september7)
        let first = try await reader.read(key: MoneyKey(FakeKeys.anthropicAdmin), context: MoneyReadContext(now: Self.now, settings: settings),
                                          client: client)
        guard case .spend(let costs) = first.figures else { Issue.record("not spend"); return }
        #expect(costs.coveredFrom == Self.september7)
        #expect(abs(costs.spent(from: Self.september7) - 1_046) < 0.001)
        #expect(abs(costs.today(Self.now) - 61) < 0.001)
        #expect(server.count(.anthropicCostReport) == 2)
        let queries = server.received.compactMap { $0.url?.query(percentEncoded: false) }
        #expect(queries[0].contains("starting_at=2026-09-07T00:00:00Z") && queries[0].contains("bucket_width=1d")
            && queries[0].contains("limit=31") && !queries[0].contains("page="))
        #expect(queries[1].contains("page=page_2"))

        // The next read asks for yesterday and today only.
        try server.on(.anthropicCostReport, fixture: "anthropic-cost-tick", query: "limit=2")
        let second = try await reader.read(key: MoneyKey(FakeKeys.anthropicAdmin),
                                           context: MoneyReadContext(now: Self.now + 300, settings: settings), client: client)
        guard case .spend(let later) = second.figures else { Issue.record("not spend"); return }
        let tick = try #require(server.received.last?.url?.query(percentEncoded: false))
        #expect(tick.contains("starting_at=2026-09-23T00:00:00Z") && tick.contains("limit=2"))
        #expect(abs(later.spent(from: Self.september7) - 1_056) < 0.001)
        #expect(abs(later.today(Self.now) - 71) < 0.001)
        #expect(server.count(.anthropicCostReport) == 3)
        #expect(server.unexpected.isEmpty)
    }

    @Test func anthropicReaderSendsNothingWithoutAnAdminKey() async throws {
        let server = MoneyStubServer()
        server.on(.anthropicCostReport, json: #"{"data":[],"has_more":false}"#)
        let reader = CostReportReader(format: AnthropicCostFormat())
        for key in [FakeKeys.anthropicAPI, FakeKeys.claudeOAuth, FakeKeys.claudeRefresh, FakeKeys.openRouter] {
            await #expect(throws: MoneyReadError.keyNotUsable) {
                try await reader.read(key: MoneyKey(key), context: MoneyReadContext(now: Self.now), client: server.client())
            }
        }
        #expect(server.received.isEmpty)
    }

    @Test func openAIReadsItsCostsBackToTheFirstOfTheMonth() async throws {
        let server = MoneyStubServer()
        try server.on(.openAICosts, fixture: "openai-costs")
        let reader = CostReportReader(format: OpenAICostFormat())
        let reading = try await reader.read(key: MoneyKey(FakeKeys.openAIAdmin), context: MoneyReadContext(now: Self.now),
                                            client: server.client())
        guard case .spend(let costs) = reading.figures else { Issue.record("not spend"); return }
        #expect(abs(costs.month(Self.now) - 212) < 0.001)
        #expect(abs(costs.today(Self.now) - 61.75) < 0.001)
        let query = try #require(server.received.first?.url?.query(percentEncoded: false))
        #expect(query.contains("start_time=1788220800") && query.contains("bucket_width=1d"))
        #expect(server.received.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(FakeKeys.openAIAdmin)")
        // A key without the admin role reads "Not available with this key".
        let refused = MoneyStubServer()
        refused.on(.openAICosts, status: 403, json: #"{"error":{"message":"insufficient permissions"}}"#)
        await #expect(throws: MoneyReadError.notAvailableWithThisKey) {
            try await CostReportReader(format: OpenAICostFormat()).read(key: MoneyKey("sk-proj-FAKE"), context: MoneyReadContext(now: Self.now),
                                                                        client: refused.client())
        }
    }

    @Test func runPodReadsBalanceAndBurnThroughGraphQL() async throws {
        let server = MoneyStubServer()
        try server.on(.runPodGraphQL, fixture: "runpod-myself")
        let reading = try await RunPodReader().read(key: MoneyKey(FakeKeys.runPod), context: MoneyReadContext(now: Self.now),
                                                    client: server.client())
        #expect(reading.figures == .balance(BalanceFigures(currency: .usd, amount: 2_310.42, burnPerHour: 1.84)))
        let pod = try RunPodGraphQLAPI.parse(try moneyFixture("runpod-myself"))
        #expect(pod.balance == 2_310.42 && pod.burnPerHour == 1.84 && pod.spendLimit == 80)
        #expect(pod.pods.map(\.name) == ["trainer", "notebook", "old"] && pod.pods.filter(\.running).count == 2)
        let request = try #require(server.received.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.query() == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(FakeKeys.runPod)")

        let unauthorized = MoneyStubServer()
        try unauthorized.on(.runPodGraphQL, fixture: "runpod-unauthorized")
        await #expect(throws: MoneyReadError.notAvailableWithThisKey) {
            try await RunPodReader().read(key: MoneyKey(FakeKeys.runPod), context: MoneyReadContext(now: Self.now), client: unauthorized.client())
        }
    }

    @Test func runPodSitsBehindAnInterface() async throws {
        struct Fixed: RunPodBalanceAPI {
            func figures(key: MoneyKey, client: MoneyHTTPClient) async throws -> RunPodFigures { RunPodFigures(balance: 33, burnPerHour: 1.84) }
        }
        let server = MoneyStubServer()
        let reading = try await RunPodReader(api: Fixed()).read(key: MoneyKey(FakeKeys.runPod), context: MoneyReadContext(now: Self.now),
                                                                client: server.client())
        #expect(reading.figures == .balance(BalanceFigures(currency: .usd, amount: 33, burnPerHour: 1.84)))
        #expect(server.received.isEmpty)
    }

    @Test func hetznerEstimatesTheMonthFromItsResources() async throws {
        let server = MoneyStubServer()
        try server.on(.hetznerServers, fixture: "hetzner-servers-page1")
        try server.on(.hetznerServers, fixture: "hetzner-servers-page2", query: "page=2")
        try server.on(.hetznerVolumes, fixture: "hetzner-volumes")
        try server.on(.hetznerPrimaryIPs, fixture: "hetzner-primary-ips")
        try server.on(.hetznerFloatingIPs, fixture: "hetzner-floating-ips")
        try server.on(.hetznerPricing, fixture: "hetzner-pricing")
        let reading = try await HetznerReader().read(key: MoneyKey(FakeKeys.hetzner), context: MoneyReadContext(now: Self.now),
                                                     client: server.client())
        guard case .spend(let cloud) = reading.figures, let items = cloud.estimate else { Issue.record("not an estimate"); return }
        #expect(cloud.currency == .eur)
        let byName = Dictionary(items.map { ("\($0.kind) \($0.name)", $0.monthly) }, uniquingKeysWith: +)
        // Running and stopped servers at their monthly price; one created on the 20th pays its hours only.
        #expect(abs((byName["server web-1"] ?? 0) - 3.79) < 0.0001)
        #expect(abs((byName["backup web-1"] ?? 0) - 0.758) < 0.0001)
        #expect(abs((byName["server db-1"] ?? 0) - 14.86) < 0.0001)
        #expect(abs((byName["server worker-1"] ?? 0) - 0.0503 * 264) < 0.0001)
        #expect(byName["server retired"] == nil)
        #expect(abs((byName["volume data"] ?? 0) - 4.4) < 0.0001)
        #expect(abs((byName["primaryIP ip-spare"] ?? 0) - 0.5) < 0.0001)
        #expect(byName["primaryIP ip-web"] == nil && byName["primaryIP ip6-spare"] == nil)
        #expect(abs((byName["floatingIP float-1"] ?? 0) - 3.0) < 0.0001)
        #expect(cloud.serverCount == 3)
        let expected: Double = 3.79 + 0.758 + 14.86 + 13.2792 + 4.4 + 0.5 + 3.0
        #expect(abs(cloud.monthlyEstimate - expected) < 0.0001)
        #expect(server.count(.hetznerServers) == 2)
        #expect(server.received.count == 6)
        #expect(server.unexpected.isEmpty)
    }

    /// A Hetzner list answer is read by the field that was asked for: another list beside it is never taken for it, and
    /// an answer without it is unreadable (the last good figure stays) rather than an empty list.
    @Test func hetznerReadsTheListItAskedFor() async throws {
        let server = MoneyStubServer()
        server.on(.hetznerServers, json: #"{"meta":{"pagination":{"next_page":null}},"servers":[]}"#)
        server.on(.hetznerVolumes, json: #"{"a_other":[{"id":1,"name":"not-a-volume","size":900,"server":null,"location":{"name":"fsn1"},"status":"available"}],"volumes":[]}"#)
        server.on(.hetznerPrimaryIPs, json: #"{"primary_ips":[]}"#)
        server.on(.hetznerFloatingIPs, json: #"{"floating_ips":[]}"#)
        try server.on(.hetznerPricing, fixture: "hetzner-pricing")
        let reading = try await HetznerReader().read(key: MoneyKey(FakeKeys.hetzner), context: MoneyReadContext(now: Self.now),
                                                     client: server.client())
        guard case .spend(let cloud) = reading.figures else { Issue.record("not spend"); return }
        #expect(cloud.estimate == [])

        let missing = MoneyStubServer()
        missing.on(.hetznerServers, json: #"{"meta":{"pagination":{"next_page":null}}}"#)
        await #expect(throws: MoneyReadError.unreadableResponse("Hetzner servers")) {
            try await HetznerReader().read(key: MoneyKey(FakeKeys.hetzner), context: MoneyReadContext(now: Self.now), client: missing.client())
        }
    }

    @Test func unreadableAnswersAreFailuresNotZeroes() async throws {
        let server = MoneyStubServer()
        server.on(.openRouterKey, json: "not json")
        await #expect(throws: MoneyReadError.unreadableResponse("OpenRouter key")) {
            try await OpenRouterReader().read(key: MoneyKey(FakeKeys.openRouter), context: MoneyReadContext(now: Self.now), client: server.client())
        }
        let limited = MoneyStubServer()
        limited.on(.hetznerServers, status: 429, headers: ["Retry-After": "120"])
        await #expect(throws: MoneyReadError.rateLimited(retryAfter: 120)) {
            try await HetznerReader().read(key: MoneyKey(FakeKeys.hetzner), context: MoneyReadContext(now: Self.now), client: limited.client())
        }
        // A number that is not finite, or too large to draw, is an unreadable answer, not a figure.
        for amount in ["inf", "nan", "1e400", "-infinity", "1e300"] {
            let odd = MoneyStubServer()
            odd.on(.anthropicCostReport, json: #"{"data":[{"starting_at":"2026-09-24T00:00:00Z","results":[{"currency":"USD","amount":"\#(amount)"}]}],"has_more":false}"#)
            await #expect(throws: MoneyReadError.unreadableResponse("Anthropic cost report")) {
                try await CostReportReader(format: AnthropicCostFormat()).read(key: MoneyKey(FakeKeys.anthropicAdmin),
                                                                              context: MoneyReadContext(now: Self.now), client: odd.client())
            }
        }
        let huge = MoneyStubServer()
        huge.on(.openRouterKey, json: #"{"data":{"usage":1e300,"usage_daily":1,"usage_monthly":1}}"#)
        await #expect(throws: MoneyReadError.unreadableResponse("OpenRouter key")) {
            try await OpenRouterReader().read(key: MoneyKey(FakeKeys.openRouter), context: MoneyReadContext(now: Self.now), client: huge.client())
        }
    }

    @Test func aCostBackfillNeverStopsShortOfToday() async throws {
        // A credit bought more than six pages of 31 days ago: refused before anything is sent, rather than a credit
        // that reads as more than is left.
        let server = MoneyStubServer()
        server.on(.anthropicCostReport, json: #"{"data":[],"has_more":false}"#)
        let old = MoneySourceSettings(credit: 1_400, creditDate: Self.now - 200 * 86_400)
        await #expect(throws: MoneyReadError.unreadableResponse("more than 6 pages")) {
            try await CostReportReader(format: AnthropicCostFormat()).read(key: MoneyKey(FakeKeys.anthropicAdmin),
                                                                          context: MoneyReadContext(now: Self.now, settings: old),
                                                                          client: server.client())
        }
        #expect(server.received.isEmpty)

        // A server whose pages still run before today after six of them: a failure, not a short figure.
        let endless = MoneyStubServer()
        endless.on(.openAICosts, json: #"{"data":[{"start_time":1788220800,"results":[]}],"has_more":true,"next_page":"more"}"#)
        await #expect(throws: MoneyReadError.unreadableResponse("more than 6 pages")) {
            try await CostReportReader(format: OpenAICostFormat()).read(key: MoneyKey(FakeKeys.openAIAdmin),
                                                                       context: MoneyReadContext(now: Self.now), client: endless.client())
        }
        #expect(endless.count(.openAICosts) == 6)

        // Pages left only past today (a tick that crossed midnight UTC) do not matter.
        let midnight = MoneyStubServer()
        midnight.on(.openAICosts, json: #"{"data":[{"start_time":1790208000,"results":[]}],"has_more":true,"next_page":"tomorrow"}"#)
        let reading = try await CostReportReader(format: OpenAICostFormat()).read(
            key: MoneyKey(FakeKeys.openAIAdmin), context: MoneyReadContext(now: Self.now, settings: MoneySourceSettings(
                credit: 10, creditDate: Self.now)), client: midnight.client())
        #expect(reading.source == .openAI && midnight.count(.openAICosts) == 1)
    }
}
