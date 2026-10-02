import Foundation
import Testing
@testable import JuiceCore

/// Juice Island spec §5.1 rule 2 and §7 amendment 10: each refusal sends nothing (the stub sees 0 requests).
@Suite struct MoneyPolicyTests {
    /// A request as the client would build it, then bent by `edit`.
    private func request(_ url: String, method: String = "GET", key: String = FakeKeys.anthropicAdmin,
                         asAPIKey: Bool = true, agent: String, edit: (inout URLRequest) -> Void = { _ in }) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        if asAPIKey {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        edit(&request)
        return request
    }

    private func expectRefusedAndUnsent(_ request: URLRequest, server: MoneyStubServer, client: MoneyHTTPClient,
                                        source: MoneySource = .anthropic, sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(MoneyHostPolicy.check(request) != nil, "\(request.url?.absoluteString ?? "")", sourceLocation: sourceLocation)
        do {
            _ = try await client.send(request, source: source)
            Issue.record("sent \(request.url?.absoluteString ?? "")", sourceLocation: sourceLocation)
        } catch {
            guard case .refusedByPolicy = error else {
                Issue.record("expected a refusal, got \(error)", sourceLocation: sourceLocation)
                return
            }
        }
    }

    @Test func moneyClientRefusesForbiddenHosts() async {
        let server = MoneyStubServer()
        let client = server.client()
        let urls = [
            "https://chatgpt.com/backend-api/wham/usage", "https://chatgpt.com/", "https://chatgpt.com/v1/organization/costs",
            "https://CHATGPT.COM/anything", "https://chatgpt.com./x", "https://api.chatgpt.com/x", "https://www.chatgpt.com/x",
            "https://api.openai.com/backend-api/wham/usage", "https://openrouter.ai/api/oauth/usage",
            "https://api.anthropic.com/api/oauth/usage", "https://api.hetzner.cloud/api/oauth/usage",
            "https://openrouter.ai/backend-api/wham/usage",
        ]
        for url in urls {
            await expectRefusedAndUnsent(request(url, key: FakeKeys.openRouter, asAPIKey: false, agent: server.agent), server: server,
                                         client: client, source: .openRouter)
        }
        #expect(server.received.isEmpty)
    }

    @Test func moneyClientRefusesEverythingButTheAdminCostPath() async {
        let server = MoneyStubServer()
        let client = server.client()
        let base = "https://api.anthropic.com"
        let paths = [
            "/api/oauth/usage", "/v1/messages", "/v1/organizations/users", "/v1/organizations/api_keys",
            "/v1/organizations/usage_report/messages", "/v1/organizations/cost_report/../users",
            "/v1/organizations/cost%5Freport", "/v1/organizations/%63ost_report", "/V1/ORGANIZATIONS/COST_REPORT",
            "/v1/organizations/Cost_Report", "/v1/organizations/cost_report/", "//v1/organizations/cost_report", "/v1/models",
        ]
        for path in paths {
            await expectRefusedAndUnsent(request(base + path, agent: server.agent), server: server, client: client)
        }
        let good = "/v1/organizations/cost_report?starting_at=2026-09-23T00:00:00Z&bucket_width=1d&limit=2"
        for method in ["POST", "DELETE", "PUT", "PATCH", "HEAD"] {
            await expectRefusedAndUnsent(request(base + good, method: method, agent: server.agent), server: server, client: client)
        }
        for url in ["http://api.anthropic.com" + good, "https://api.anthropic.com:8443" + good, "https://api.anthropic.com:443" + good,
                    "https://user:pass@api.anthropic.com" + good, "https://user@api.anthropic.com" + good,
                    "https://api.anthropic.com." + good, "https://api.anthropic.com.example.net" + good,
                    "https://API.ANTHROPIC.COM" + good, "https://api.anthropic.com" + good + "#frag",
                    base + good + "&api_key=x", base + "/v1/organizations/cost_report?group_by[]=workspace_id"] {
            await expectRefusedAndUnsent(request(url, agent: server.agent), server: server, client: client)
        }
        #expect(server.received.isEmpty)

        // The one request that goes out.
        server.on("GET", "api.anthropic.com", "/v1/organizations/cost_report", json: #"{"data":[],"has_more":false}"#)
        let response = try? await client.send(request(base + good, agent: server.agent), source: .anthropic)
        #expect(response?.status == 200)
        #expect(server.received.count == 1)
        #expect(server.unexpected.isEmpty)
    }

    @Test func anthropicRequestCarriesOnlyTheAdminKey() async throws {
        let server = MoneyStubServer()
        let client = server.client()
        server.on(.anthropicCostReport, json: #"{"data":[],"has_more":false}"#)
        let built = client.urlRequest(for: MoneyRequest(.anthropicCostReport, query: AnthropicCostFormat().query(
            start: Date(timeIntervalSince1970: 1_790_121_600), limit: 2, page: nil), key: MoneyKey(FakeKeys.anthropicAdmin)))
        let headers = Dictionary(uniqueKeysWithValues: (built.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
        #expect(Set(headers.keys) == ["x-api-key", "anthropic-version", "accept", "user-agent"])
        #expect(headers["anthropic-version"] == "2023-06-01")
        #expect(headers["authorization"] == nil && headers["cookie"] == nil && headers["anthropic-beta"] == nil)
        #expect(!(headers["user-agent"] ?? "claude").lowercased().contains("claude"))
        #expect(!MoneyHTTPClient.userAgent.lowercased().contains("claude"))
        #expect(built.url?.query()?.contains("sk-ant") == false)

        _ = try await client.send(MoneyRequest(.anthropicCostReport, query: [URLQueryItem(name: "limit", value: "2")],
                                               key: MoneyKey(FakeKeys.anthropicAdmin)))
        let seen = try #require(server.received.first)
        let sent = Dictionary(uniqueKeysWithValues: (seen.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
        #expect(sent["x-api-key"] == FakeKeys.anthropicAdmin)
        #expect(sent["authorization"] == nil && sent["cookie"] == nil && sent["anthropic-beta"] == nil)
        #expect(!(sent["user-agent"] ?? "claude").lowercased().contains("claude"))

        // Headers the policy refuses on that host, each sent nowhere.
        let good = "https://api.anthropic.com/v1/organizations/cost_report?limit=2"
        let bent: [(inout URLRequest) -> Void] = [
            { $0.setValue("Bearer \(FakeKeys.anthropicAdmin)", forHTTPHeaderField: "Authorization") },
            { $0.setValue("session=1", forHTTPHeaderField: "Cookie") },
            { $0.setValue("x", forHTTPHeaderField: "anthropic-beta") },
            { $0.setValue("claude-code/2.0", forHTTPHeaderField: "User-Agent") },
            { $0.setValue(nil, forHTTPHeaderField: "User-Agent") },
            { $0.setValue("2024-01-01", forHTTPHeaderField: "anthropic-version") },
            { $0.setValue(nil, forHTTPHeaderField: "anthropic-version") },
            { $0.httpShouldHandleCookies = true },
            { $0.httpBody = Data("{}".utf8) },
            // A second copy of the key, in another header: only x-api-key may carry it.
            { $0.setValue(FakeKeys.anthropicAdmin, forHTTPHeaderField: "Accept") },
            { $0.setValue(FakeKeys.anthropicAdmin, forHTTPHeaderField: "User-Agent") },
            // Not the app's own User-Agent.
            { $0.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent") },
        ]
        for edit in bent {
            await expectRefusedAndUnsent(request(good, agent: server.agent, edit: edit), server: server, client: client)
        }
        #expect(server.received.count == 1)
    }

    @Test func moneyClientNeverSendsAClaudeTokenElsewhere() async {
        let server = MoneyStubServer()
        let client = server.client()
        let hosts: [(MoneyEndpoint, String)] = [
            (.openRouterKey, ""), (.openAICosts, "?limit=2"), (.hetznerServers, "?page=1"), (.anthropicCostReport, "?limit=2"),
        ]
        for token in [FakeKeys.claudeOAuth, FakeKeys.claudeRefresh] {
            for (endpoint, query) in hosts {
                let url = "https://\(endpoint.host)\(endpoint.path)\(query)"
                await expectRefusedAndUnsent(request(url, key: token, asAPIKey: endpoint == .anthropicCostReport, agent: server.agent),
                                             server: server, client: client, source: endpoint.source)
            }
            #expect(MoneyHostPolicy.keyRefusal(MoneyKey(token), for: .anthropic) == .keyNotUsable)
            #expect(MoneyHostPolicy.keyRefusal(MoneyKey(token), for: .openAI) == .keyNotUsable)
            #expect(MoneyHostPolicy.keyRefusal(MoneyKey(token), for: .openRouter) == .keyNotUsable)
        }
        for key in [FakeKeys.anthropicAPI, FakeKeys.anthropicAdmin] {
            for (endpoint, query) in hosts where endpoint != .anthropicCostReport {
                let url = "https://\(endpoint.host)\(endpoint.path)\(query)"
                await expectRefusedAndUnsent(request(url, key: key, asAPIKey: false, agent: server.agent), server: server, client: client,
                                             source: endpoint.source)
                // An sk-ant- value anywhere else in the request (the URL or the body) is refused too.
                await expectRefusedAndUnsent(request(url + (query.isEmpty ? "?" : "&") + "page=\(key)", key: FakeKeys.openRouter,
                                                     asAPIKey: false, agent: server.agent),
                                             server: server, client: client, source: endpoint.source)
            }
            #expect(MoneyHostPolicy.keyRefusal(MoneyKey(key), for: .openAI) == .keyNotUsable)
            #expect(MoneyHostPolicy.keyRefusal(MoneyKey(key), for: .hetzner) == .keyNotUsable)
        }
        // RunPod's body may not carry one either.
        var runPod = request("https://api.runpod.io/graphql", method: "POST", key: FakeKeys.runPod, asAPIKey: false, agent: server.agent)
        runPod.httpBody = Data(#"{"query":"\#(FakeKeys.anthropicAdmin)"}"#.utf8)
        await expectRefusedAndUnsent(runPod, server: server, client: client, source: .runPod)
        #expect(MoneyHostPolicy.keyRefusal(MoneyKey(FakeKeys.anthropicAPI), for: .anthropic) == .keyNotUsable)
        #expect(MoneyHostPolicy.keyRefusal(MoneyKey(FakeKeys.anthropicAdmin), for: .anthropic) == nil)
        // A one-line file that wraps a token (compact JSON) is refused before a request is built, for every source.
        let wrapped = MoneyKey(#"{"claudeAiOauth":{"accessToken":"\#(FakeKeys.claudeOAuth)"}}"#)
        for source in MoneySource.allCases { #expect(MoneyHostPolicy.keyRefusal(wrapped, for: source) == .keyNotUsable, "\(source)") }
        #expect(MoneyHostPolicy.keyRefusal(MoneyKey("x" + FakeKeys.anthropicAPI), for: .openAI) == .keyNotUsable)
        #expect(server.received.isEmpty)
    }

    @Test func moneyClientNeverSendsASignInToken() async {
        let server = MoneyStubServer()
        let client = server.client()
        // A ChatGPT or Codex sign-in token (a JWT) in a key file: refused for every source before a request is built,
        // and by the policy if a request carried one anyway.
        for source in MoneySource.allCases {
            #expect(MoneyHostPolicy.keyRefusal(MoneyKey(FakeKeys.signInJWT), for: source) == .keyNotUsable, "\(source)")
        }
        for endpoint in [MoneyEndpoint.openRouterKey, .openAICosts, .hetznerPricing] {
            let url = "https://\(endpoint.host)\(endpoint.path)"
            await expectRefusedAndUnsent(request(url, key: FakeKeys.signInJWT, asAPIKey: false, agent: server.agent), server: server,
                                         client: client, source: endpoint.source)
        }
        #expect(MoneyHostPolicy.check(request("https://openrouter.ai/api/v1/key", key: FakeKeys.openRouter, asAPIKey: false,
                                              agent: server.agent)) == nil)
        #expect(server.received.isEmpty)
    }

    @Test func moneyClientNeverFollowsARedirect() async throws {
        let server = MoneyStubServer()
        let client = server.client()
        server.on("GET", "openrouter.ai", "/api/v1/key", status: 302, redirect: URL(string: "https://openrouter.ai/api/v1/other")!)
        server.on("GET", "api.hetzner.cloud", "/v1/pricing", status: 307, redirect: URL(string: "https://example.net/v1/pricing")!)
        let first = try await client.send(MoneyRequest(.openRouterKey, key: MoneyKey(FakeKeys.openRouter)))
        #expect(first.status == 302)
        let second = try await client.send(MoneyRequest(.hetznerPricing, key: MoneyKey(FakeKeys.hetzner)))
        #expect(second.status == 307)
        // The key went out once per request, and the redirect targets were never asked.
        #expect(server.received.count == 2)
        #expect(server.unexpected.isEmpty)
        #expect(throws: MoneyReadError.http(302)) { try first.ok() }
    }

    static let ids: [MoneyEndpoint: String] = [.xAIPrepaidBalance: "00000000-0000-4000-8000-000000000000",
                                               .fireworksBillingSummary: "fictional-account"]

    @Test func everyAllowedEndpointPassesAsTheClientBuildsIt() {
        let client = MoneyHTTPClient(protocolClasses: [MoneyStubProtocol.self])
        for endpoint in MoneyEndpoint.allCases {
            let key = endpoint == .anthropicCostReport ? FakeKeys.anthropicAdmin : FakeKeys.openRouter
            let query = endpoint.allowedQuery.sorted().map { URLQueryItem(name: $0, value: "1") }
            let body = endpoint.allowsBody ? Data("{}".utf8) : nil
            let built = client.urlRequest(for: MoneyRequest(endpoint, query: query, id: Self.ids[endpoint], key: MoneyKey(key), body: body))
            #expect(MoneyHostPolicy.check(built) == nil, "\(endpoint)")
            #expect(built.url?.absoluteString.contains(key) == false)
            // The key in its one place, and the headers exactly the endpoint's.
            let headers = Dictionary(uniqueKeysWithValues: (built.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
            #expect(Set(headers.keys) == endpoint.allowedHeaders.subtracting(body == nil ? ["content-type"] : []), "\(endpoint)")
            #expect(headers[endpoint.keyPlacement.headerName] == endpoint.keyPlacement.value(MoneyKey(key)), "\(endpoint)")
        }
        // One host per source, and every path an id can stand in has a pattern.
        for source in MoneySource.allCases {
            #expect(Set(MoneyEndpoint.allCases.filter { $0.source == source }.map(\.host)).count == 1, "\(source)")
        }
        #expect(MoneyEndpoint.allCases.allSatisfy { $0.path.contains("{id}") == ($0.idPattern != nil) })
        #expect(MoneyEndpoint.allCases.filter { $0.method != "GET" } == [.runPodGraphQL])
        // No endpoint may take a query name that could carry a key (P143).
        for endpoint in MoneyEndpoint.allCases {
            #expect(!endpoint.allowedQuery.contains(where: MoneyHostPolicy.keyLikeQuery), "\(endpoint)")
        }
        // Only one endpoint on Anthropic's host, and it is a GET.
        let anthropic = MoneyEndpoint.allCases.filter { $0.host == MoneyHostPolicy.anthropicHost }
        #expect(anthropic == [.anthropicCostReport] && anthropic.allSatisfy { $0.method == "GET" })
    }

    /// The query names the policy refuses even where an endpoint's allowlist would take them (P143), checked on their
    /// own: today's allowlists refuse every key-like name first, so the requests above never reach this rule.
    @Test func aQueryNameThatCouldCarryAKeyIsRefused() {
        for name in ["api_key", "key", "KEY", "token", "access_token", "auth", "Authorization", "x_secret", "password", "signature",
                     "apiKey", "refresh_token"] {
            #expect(MoneyHostPolicy.keyLikeQuery(name), "\(name)")
        }
        for name in ["after_token", "select_cols", "limit", "startTime", "endTime", "expand", "page", "per_page", "bucket_width"] {
            #expect(!MoneyHostPolicy.keyLikeQuery(name), "\(name)")
        }
    }

    /// Each source's key travels in its one place (Bearer, `x-api-key`, `xi-api-key`, `Authorization: Key`) and nowhere
    /// else; each refusal sends nothing (P143).
    @Test func aKeyGoesOnlyInItsSourcesPlace() async {
        let server = MoneyStubServer()
        let client = server.client()
        let key = "FAKEkey00000000000000000000"
        func built(_ endpoint: MoneyEndpoint, query: [URLQueryItem] = [], edit: (inout URLRequest) -> Void) -> URLRequest {
            var request = client.urlRequest(for: MoneyRequest(endpoint, query: query, id: Self.ids[endpoint], key: MoneyKey(key)))
            edit(&request)
            return request
        }
        #expect(MoneyEndpoint.elevenLabsSubscription.keyPlacement == .header("xi-api-key"))
        #expect(MoneyEndpoint.falBilling.keyPlacement == .scheme("Key"))
        #expect(MoneyEndpoint.anthropicCostReport.keyPlacement == .header("x-api-key"))
        #expect(MoneyEndpoint.deepSeekBalance.keyPlacement == .bearer && MoneyEndpoint.xAIPrepaidBalance.keyPlacement == .bearer)
        let bent: [(MoneyEndpoint, (inout URLRequest) -> Void)] = [
            // ElevenLabs: never as a bearer token, never beside one, never empty.
            (.elevenLabsSubscription, { $0.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }),
            (.elevenLabsSubscription, { $0.setValue(nil, forHTTPHeaderField: "xi-api-key") }),
            (.elevenLabsSubscription, { $0.setValue("", forHTTPHeaderField: "xi-api-key") }),
            (.elevenLabsSubscription, { $0.setValue(key, forHTTPHeaderField: "x-api-key") }),
            // fal.ai: only as `Key …`.
            (.falBilling, { $0.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }),
            (.falBilling, { $0.setValue(key, forHTTPHeaderField: "Authorization") }),
            (.falBilling, { $0.setValue("Key ", forHTTPHeaderField: "Authorization") }),
            // Bearer sources: only as `Bearer …`, and not in a header of another source's shape.
            (.deepSeekBalance, { $0.setValue("Key \(key)", forHTTPHeaderField: "Authorization") }),
            (.deepSeekBalance, { $0.setValue(key, forHTTPHeaderField: "Authorization") }),
            (.vastUser, { $0.setValue(key, forHTTPHeaderField: "xi-api-key") }),
            (.digitalOceanBalance, { $0.setValue("Bearer two words", forHTTPHeaderField: "Authorization") }),
            // A second copy of the key anywhere else.
            (.moonshotBalance, { $0.setValue(key, forHTTPHeaderField: "Accept") }),
            (.falBilling, { $0.url = URL(string: "https://api.fal.ai/v1/account/billing?expand=\(key)") }),
            (.vastInstances, { $0.url = URL(string: "https://console.vast.ai/api/v1/instances?after_token=\(key)") }),
            // A query name that could carry a key, even where a query is allowed.
            (.vastInstances, { $0.url = URL(string: "https://console.vast.ai/api/v1/instances?api_key=x") }),
            (.vastInstances, { $0.url = URL(string: "https://console.vast.ai/api/v1/instances?limit=25&token=x") }),
            (.fireworksBillingSummary, { $0.url = URL(string: "https://api.fireworks.ai/v1/accounts/fictional-account/billing/summary?key=x") }),
        ]
        for (endpoint, edit) in bent {
            await expectRefusedAndUnsent(built(endpoint, edit: edit), server: server, client: client, source: endpoint.source)
        }
        #expect(server.received.isEmpty)
    }

    /// A path with an id takes exactly an id of its pattern in that one segment: nothing that could reach another path.
    @Test func anIDIsOneSegmentOfItsPattern() async {
        let server = MoneyStubServer()
        let client = server.client()
        let good = "0a1b2c3d-0000-4000-8000-00000000abcd"
        for id in ["", "../organizations", "\(good)/..", good.uppercased(), good + "%2F", "a/b", good + "/prepaid",
                   String(good.dropLast()), good + "?x=1", good + "#x"] {
            let request = client.urlRequest(for: MoneyRequest(.xAIPrepaidBalance, id: id, key: MoneyKey(FakeKeys.openRouter)))
            await expectRefusedAndUnsent(request, server: server, client: client, source: .xAI)
        }
        for id in ["", "-leading", "UPPER", "has space", "a.b", String(repeating: "a", count: 64), "a_b"] {
            let request = client.urlRequest(for: MoneyRequest(.fireworksBillingSummary, id: id, key: MoneyKey(FakeKeys.openRouter)))
            await expectRefusedAndUnsent(request, server: server, client: client, source: .fireworks)
        }
        #expect(server.received.isEmpty)
        #expect(MoneyEndpoint.fireworksBillingSummary.accepts(id: "fictional-account") && MoneyEndpoint.xAIPrepaidBalance.accepts(id: good))
        #expect(!MoneyEndpoint.deepSeekBalance.accepts(id: "x"))
        // A refused id's path is recorded as the endpoint names it, never with what was typed.
        #expect(client.recentRequests.allSatisfy { !$0.line.contains("organizations") && !$0.line.contains("UPPER") })
    }

    @Test func retryAfterReadsSecondsAndDates() {
        let now = Date(timeIntervalSince1970: 1_790_251_200)
        #expect(MoneyHTTPClient.retryAfter("120", now: now) == 120)
        #expect(MoneyHTTPClient.retryAfter(nil, now: now) == nil)
        let date = MoneyHTTPClient.retryAfter("Thu, 24 Sep 2026 12:05:00 GMT", now: now)
        #expect(date == 300)
        // Whatever the server sends, the pause is finite, never negative and at most a week, so no sleep can trap.
        let week: TimeInterval = 7 * 86_400
        for (text, expected) in [("inf", week), ("infinity", week), ("1e400", week), ("99999999999", week), ("-5", 0), ("-inf", 0)] {
            #expect(MoneyHTTPClient.retryAfter(text, now: now) == expected, "\(text)")
        }
        #expect(MoneyHTTPClient.retryAfter("nan", now: now) == nil)
        #expect(MoneyHTTPClient.retryAfter("Fri, 31 Dec 9999 23:59:59 GMT", now: now) == week)
    }
}
