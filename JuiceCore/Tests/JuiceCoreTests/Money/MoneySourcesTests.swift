import Foundation
import Testing
@testable import JuiceCore

/// The sources added with the figure kinds (Juice Island spec §8 decision 14): one fixture per endpoint, shaped from the
/// vendor's documentation, read through the stub. Each request goes to its source's one host, with the key in its
/// source's one place; fields the rules skip (Vast.ai's email and SSH key, fal.ai's username) are never kept. Fake keys
/// only; nothing reaches the network.
@Suite struct MoneySourcesTests {
    static let now = MoneyReaderTests.now
    static let key = "FAKE-money-key-0000000000000000"
    static let team = "00000000-0000-4000-8000-000000000000"

    func headers(_ request: URLRequest?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (request?.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
    }

    func read(_ reader: any MoneyReader, _ server: MoneyStubServer, settings: MoneySourceSettings = MoneySourceSettings(),
              now: Date = MoneySourcesTests.now) async throws -> MoneyReading {
        try await reader.read(key: MoneyKey(Self.key), context: MoneyReadContext(now: now, settings: settings), client: server.client())
    }

    @Test func deepSeekReadsTheBalanceInItsCurrency() async throws {
        let server = MoneyStubServer()
        try server.on(.deepSeekBalance, fixture: "deepseek-balance")
        let reading = try await read(DeepSeekReader(), server)
        #expect(reading.figures == .balance(BalanceFigures(currency: .cny, amount: 110)))
        let request = try #require(server.received.first)
        #expect(request.url?.absoluteString == "https://api.deepseek.com/user/balance")
        #expect(headers(request)["authorization"] == "Bearer \(Self.key)")
        let dollars = MoneyStubServer()
        try dollars.on(.deepSeekBalance, fixture: "deepseek-balance-usd")
        #expect(try await read(DeepSeekReader(), dollars).figures == .balance(BalanceFigures(currency: .usd, amount: 1_234.56)))
        // Only currencies Juice draws; none of them is an unexpected answer, never a zero.
        let odd = MoneyStubServer()
        odd.on(.deepSeekBalance, json: #"{"is_available":true,"balance_infos":[{"currency":"JPY","total_balance":"5"}]}"#)
        await #expect(throws: MoneyReadError.unreadableResponse("DeepSeek balance")) { try await read(DeepSeekReader(), odd) }
        #expect(server.unexpected.isEmpty && dollars.unexpected.isEmpty)
    }

    @Test func moonshotReadsTheAvailableBalance() async throws {
        let server = MoneyStubServer()
        try server.on(.moonshotBalance, fixture: "moonshot-balance")
        guard case .balance(let held) = try await read(MoonshotReader(), server).figures else { Issue.record("not a balance"); return }
        #expect(held.currency == .usd && abs((held.amount ?? 0) - 49.58894) < 1e-9)
        #expect(server.received.first?.url?.absoluteString == "https://api.moonshot.ai/v1/users/me/balance")
        #expect(headers(server.received.first)["authorization"] == "Bearer \(Self.key)")
        let failed = MoneyStubServer()
        failed.on(.moonshotBalance, json: #"{"code":1,"status":false,"data":{"available_balance":0}}"#)
        await #expect(throws: MoneyReadError.unreadableResponse("Moonshot balance")) { try await read(MoonshotReader(), failed) }
    }

    @Test func xAIReadsTheTeamsPrepaidBalanceWithItsIDInThePath() async throws {
        let server = MoneyStubServer()
        server.on("GET", "management-api.x.ai", "/v1/billing/teams/\(Self.team)/prepaid/balance",
                  json: String(decoding: try moneyFixture("xai-prepaid-balance"), as: UTF8.self))
        let reading = try await read(XAIReader(), server, settings: MoneySourceSettings(accountID: " \(Self.team.uppercased()) "))
        #expect(reading.figures == .balance(BalanceFigures(currency: .usd, amount: 37.25)))
        let request = try #require(server.received.first)
        #expect(request.url?.absoluteString == "https://management-api.x.ai/v1/billing/teams/\(Self.team)/prepaid/balance")
        #expect(headers(request)["authorization"] == "Bearer \(Self.key)")
        // Diagnostics names the path without the team.
        let client = server.client()
        _ = try await XAIReader().read(key: MoneyKey(Self.key), context: MoneyReadContext(now: Self.now, settings: MoneySourceSettings(accountID: Self.team)),
                                       client: client)
        #expect(client.recentRequests.first?.line == "GET management-api.x.ai/v1/billing/teams/{id}/prepaid/balance · 200")
        #expect(!client.recentRequests.map(\.line).joined().contains(Self.team))
        // No team (`Team ID not set`), or one that is not a team id (`Team ID not valid`, never "not set" beside a
        // filled field): nothing is sent.
        let quiet = MoneyStubServer()
        for id in [nil, "", "  "] as [String?] {
            await #expect(throws: MoneyReadError.idMissing("Team ID"), "\(id ?? "nil")") {
                try await read(XAIReader(), quiet, settings: MoneySourceSettings(accountID: id))
            }
        }
        for id in ["not-a-uuid", "../../v1/organizations", "\(Self.team)/x", "\(Self.team)?a=1", "%30" + Self.team.dropFirst(),
                   "{\(Self.team)}", "xai-FAKEmanagementKEY0000"] {
            await #expect(throws: MoneyReadError.idInvalid("Team ID"), "\(id)") {
                try await read(XAIReader(), quiet, settings: MoneySourceSettings(accountID: id))
            }
        }
        #expect(quiet.received.isEmpty)
        #expect(MoneyReadError.idMissing("Team ID").statusWord == "Team ID not set")
        #expect(MoneyReadError.idMissing("Team ID").hoverReason == "team ID not set" && MoneyReadError.idMissing("Team ID").sentNothing)
        #expect(MoneyReadError.idInvalid("Team ID").statusWord == "Team ID not valid")
        #expect(MoneyReadError.idInvalid("Account ID").hoverReason == "account ID not valid" && MoneyReadError.idInvalid("Team ID").sentNothing)
    }

    @Test func fireworksSumsTheMonthsLineItems() async throws {
        let server = MoneyStubServer()
        server.on("GET", "api.fireworks.ai", "/v1/accounts/fictional-account/billing/summary",
                  json: String(decoding: try moneyFixture("fireworks-billing-summary"), as: UTF8.self))
        let reading = try await read(FireworksReader(), server, settings: MoneySourceSettings(accountID: "fictional-account"))
        guard case .spend(let spent) = reading.figures else { Issue.record("not spend"); return }
        #expect(spent.currency == .usd && abs((spent.monthToDate ?? 0) - 35.925) < 1e-9)
        #expect(spent.coveredFrom == MoneyRules.startOfMonth(Self.now) && spent.daily.isEmpty && spent.estimate == nil)
        let query = try #require(server.received.first?.url?.query(percentEncoded: false))
        #expect(query == "startTime=2026-09-01T00:00:00Z&endTime=2026-09-25T00:00:00Z")
        #expect(headers(server.received.first)["authorization"] == "Bearer \(Self.key)")
        // An empty month may leave the items out: nothing spent.
        let empty = MoneyStubServer()
        empty.on("GET", "api.fireworks.ai", "/v1/accounts/fictional-account/billing/summary", json: "{}")
        guard case .spend(let none) = try await read(FireworksReader(), empty, settings: MoneySourceSettings(accountID: "fictional-account")).figures
        else { Issue.record("not spend"); return }
        #expect(none.monthToDate == 0)
        // Two currencies in one month: unexpected, never a sum of both.
        let mixed = MoneyStubServer()
        mixed.on("GET", "api.fireworks.ai", "/v1/accounts/fictional-account/billing/summary",
                 json: #"{"lineItems":[{"totalCost":{"currencyCode":"USD","units":"1"}},{"totalCost":{"currencyCode":"EUR","units":"1"}}]}"#)
        await #expect(throws: MoneyReadError.unreadableResponse("Fireworks billing")) {
            try await read(FireworksReader(), mixed, settings: MoneySourceSettings(accountID: "fictional-account"))
        }
        await #expect(throws: MoneyReadError.idInvalid("Account ID")) {
            try await read(FireworksReader(), mixed, settings: MoneySourceSettings(accountID: "Has Spaces"))
        }
        await #expect(throws: MoneyReadError.idMissing("Account ID")) {
            try await read(FireworksReader(), mixed, settings: MoneySourceSettings(accountID: nil))
        }
        // The id as Fireworks' console and firectl write it: `accounts/` goes, the rest must still be one segment.
        let prefixed = MoneyStubServer()
        prefixed.on("GET", "api.fireworks.ai", "/v1/accounts/fictional-account/billing/summary", json: "{}")
        _ = try await read(FireworksReader(), prefixed, settings: MoneySourceSettings(accountID: " accounts/Fictional-Account "))
        #expect(prefixed.received.count == 1)
        for id in ["accounts/", "accounts/a/b", "accounts/../x", "accounts/accounts/x", "users/fictional-account"] {
            await #expect(throws: MoneyReadError.idInvalid("Account ID"), "\(id)") {
                try await read(FireworksReader(), prefixed, settings: MoneySourceSettings(accountID: id))
            }
        }
        #expect(prefixed.received.count == 1)
    }

    /// What Settings › Money keeps of a typed id: only one of the source's pattern, as the path takes it; the word for
    /// anything else names the field.
    @Test func settingsKeepOnlyAnIDOfItsSourcesPattern() {
        #expect(MoneySource.xAI.acceptedID(" \(Self.team.uppercased())\n") == Self.team)
        #expect(MoneySource.xAI.acceptedID("xai-FAKEmanagementKEY0000") == nil && MoneySource.xAI.acceptedID("team-00000000") == nil)
        #expect(MoneySource.fireworks.acceptedID("accounts/my-team") == "my-team" && MoneySource.fireworks.acceptedID("my_team") == nil)
        #expect(MoneySource.openRouter.acceptedID("anything") == nil && MoneySource.openRouter.notAnIDWord == nil)
        #expect(MoneySource.xAI.notAnIDWord == "Not a team ID" && MoneySource.fireworks.notAnIDWord == "Not an account ID")
    }

    @Test func falSendsItsAdminKeyAsKeyAndDropsTheUsername() async throws {
        let server = MoneyStubServer()
        try server.on(.falBilling, fixture: "fal-billing")
        let reading = try await read(FalReader(), server)
        #expect(reading.figures == .balance(BalanceFigures(currency: .usd, amount: 24.5)))
        let request = try #require(server.received.first)
        #expect(request.url?.absoluteString == "https://api.fal.ai/v1/account/billing?expand=credits")
        #expect(headers(request)["authorization"] == "Key \(Self.key)")
        #expect(!"\(reading)".contains("fictional-team") && !String(reflecting: reading).contains("fictional-team"))
    }

    @Test func elevenLabsSendsItsKeyInItsOwnHeaderAndReadsAQuota() async throws {
        let server = MoneyStubServer()
        try server.on(.elevenLabsSubscription, fixture: "elevenlabs-subscription")
        let reading = try await read(ElevenLabsReader(), server)
        #expect(reading.figures == .quota(QuotaFigures(used: 2_600, limit: 10_000, unit: "characters",
                                                       resetsAt: Date(timeIntervalSince1970: 1_790_899_200))))
        let sent = headers(server.received.first)
        #expect(sent["xi-api-key"] == Self.key && sent["authorization"] == nil)
        #expect(Set(sent.keys) == ["xi-api-key", "accept", "user-agent"])
    }

    @Test func vastReadsTheBalanceAndTheRunningBurnAndKeepsNothingPersonal() async throws {
        let server = MoneyStubServer()
        try server.on(.vastUser, fixture: "vast-user")
        try server.on(.vastInstances, fixture: "vast-instances-page1")
        try server.on(.vastInstances, fixture: "vast-instances-page2", query: "after_token=")
        let reader = VastReader()
        let reading = try await read(reader, server)
        guard case .balance(let held) = reading.figures else { Issue.record("not a balance"); return }
        #expect(held.amount == 86.25 && abs((held.burnPerHour ?? 0) - 1.75) < 1e-9)
        #expect(server.count(.vastUser) == 1 && server.count(.vastInstances) == 2)
        let first = try #require(server.received.first { $0.url?.path() == "/api/v1/instances" }?.url?.query(percentEncoded: false))
        #expect(first.contains("limit=25") && first.contains(#"select_cols=["actual_status","dph_total"]"#) && !first.contains("api_key"))
        for request in server.received { #expect(headers(request)["authorization"] == "Bearer \(Self.key)") }
        // Nothing of the user's email, SSH key or ids is in the reading, its saved form or its drawing.
        let record = MoneySourceRecord(lastGood: reading)
        let home = try MoneyTempDir()
        let store = MoneyStore(url: home.url.appendingPathComponent("money.json"))
        store.save([.vastAI: record])
        let saved = try String(contentsOf: store.url, encoding: .utf8)
        let drawn = "\(MoneyPresentation.make(account: .vastAI, record: record, settings: MoneySourceSettings(), now: Self.now, amber: 72, red: 24)!)"
        for text in [saved, drawn, "\(reading)", String(reflecting: reading)] {
            #expect(!text.contains("@") && !text.contains("ssh-ed25519") && !text.contains("FAKESESSIONID") && !text.contains("654321"))
        }
        let presentation = MoneyPresentation.make(account: .vastAI, record: record, settings: MoneySourceSettings(), now: Self.now,
                                                  amber: 72, red: 24)
        #expect(presentation?.row.amount == "$86.25" && presentation?.row.suffix == "49h" && presentation?.row.emphasis == .warn)
        #expect(presentation?.row.suffixIsRunway == true)
        #expect(presentation?.row.hoverLabel == "Vast.ai · $86.25 balance · $1.75/h · about 49 hours · read just now")
    }

    @Test func vastWithoutTheInstancesScopeReadsTheBalanceAndStopsAsking() async throws {
        let server = MoneyStubServer()
        try server.on(.vastUser, fixture: "vast-user")
        server.on(.vastInstances, status: 403, json: #"{"success":false,"error":"forbidden"}"#)
        let reader = VastReader()
        for _ in 0..<3 {
            #expect(try await read(reader, server).figures == .balance(BalanceFigures(currency: .usd, amount: 86.25, runwayGap: .notAllowed)))
        }
        #expect(server.count(.vastInstances) == 1)
        await reader.forget()
        _ = try await read(reader, server)
        #expect(server.count(.vastInstances) == 2)
        // A 429 on either request pauses the source; Vast.ai sends no Retry-After.
        let limited = MoneyStubServer()
        try limited.on(.vastUser, fixture: "vast-user")
        limited.on(.vastInstances, status: 429)
        await #expect(throws: MoneyReadError.rateLimited(retryAfter: nil)) { try await read(VastReader(), limited) }
    }

    /// Instances that fail another way (a 500) leave the balance with no runway, said (`notRead`), asked again at each
    /// read; the reader knows it is failing, so the log says so once and again only when the runway is back (P115).
    @Test func vastInstancesThatFailLeaveTheBalanceAndAreAskedAgain() async throws {
        let server = MoneyStubServer()
        try server.on(.vastUser, fixture: "vast-user")
        server.on(.vastInstances, status: 500)
        let reader = VastReader()
        for _ in 0..<2 {
            #expect(try await read(reader, server).figures == .balance(BalanceFigures(currency: .usd, amount: 86.25, runwayGap: .notRead)))
        }
        let failing = await reader.instancesFailing
        #expect(server.count(.vastInstances) == 2 && failing)
        try server.on(.vastInstances, fixture: "vast-instances-page2")
        _ = try await read(reader, server)
        let (stillFailing, allowed) = (await reader.instancesFailing, await reader.instancesAllowed)
        #expect(!stillFailing && allowed == true)
        #expect(server.unexpected.isEmpty)
    }

    /// One failed instances read keeps the last burn while it is fresh, so an amber or red runway stays; past that the
    /// balance says its runway was not read, and a key without the instances' scope says so for good, never drawn as a
    /// plain balance with nothing running.
    @Test func vastKeepsItsLastBurnThroughAFailedInstancesReadAndSaysWhenItHasNone() async throws {
        let server = MoneyStubServer()
        server.on(.vastUser, json: #"{"balance":5}"#)
        server.on(.vastInstances, json: #"{"instances":[{"actual_status":"running","dph_total":2}]}"#)
        let reader = VastReader()
        func drawn(_ reading: MoneyReading) -> MoneyPresentation? {
            MoneyPresentation.make(account: .vastAI, record: MoneySourceRecord(lastGood: reading), settings: MoneySourceSettings(),
                                   now: reading.readAt + 60, amber: 72, red: 24)
        }
        let burning = try await read(reader, server)
        #expect(drawn(burning)?.row.suffix == "2h" && drawn(burning)?.row.emphasis == .attention)
        server.on(.vastInstances, status: 503)
        let kept = try await read(reader, server, now: Self.now + 300)
        #expect(kept.figures == .balance(BalanceFigures(currency: .usd, amount: 5, burnPerHour: 2)))
        #expect(drawn(kept)?.row.suffix == "2h" && drawn(kept)?.row.emphasis == .attention && drawn(kept)?.status == "Connected")
        let lost = try await read(reader, server, now: Self.now + 900)
        #expect(lost.figures == .balance(BalanceFigures(currency: .usd, amount: 5, runwayGap: .notRead)))
        #expect(drawn(lost)?.row.suffix == nil && drawn(lost)?.status == "Runway not read")
        #expect(drawn(lost)?.row.hoverLabel == "Vast.ai · $5.00 balance · runway not read · read 1m ago")
        #expect(drawn(lost)?.shortParts == ["runway not read"])
        server.on(.vastInstances, status: 403)
        let refused = try await read(reader, server, now: Self.now + 1_200)
        #expect(drawn(refused)?.status == "No runway with this key")
        #expect(drawn(refused)?.row.hoverLabel == "Vast.ai · $5.00 balance · no runway with this key · read 1m ago")
        // Nothing running is still a plain balance.
        let idle = MoneyStubServer()
        idle.on(.vastUser, json: #"{"balance":5}"#)
        idle.on(.vastInstances, json: #"{"instances":[]}"#)
        let quiet = try await read(VastReader(), idle)
        #expect(drawn(quiet)?.status == "Connected" && drawn(quiet)?.row.hoverLabel == "Vast.ai · $5.00 balance · $0.00/h · read 1m ago")
    }

    @Test func digitalOceanReadsTheMonthOrTheCreditLeft() async throws {
        let server = MoneyStubServer()
        try server.on(.digitalOceanBalance, fixture: "digitalocean-balance")
        let reading = try await read(DigitalOceanReader(), server)
        #expect(reading.figures == .spend(SpendFigures(currency: .usd, daily: [:], coveredFrom: MoneyRules.startOfMonth(Self.now),
                                                       monthToDate: 11.21)))
        #expect(server.received.first?.url?.absoluteString == "https://api.digitalocean.com/v2/customers/my/balance")
        let credit = MoneyStubServer()
        try credit.on(.digitalOceanBalance, fixture: "digitalocean-balance-credit")
        #expect(try await read(DigitalOceanReader(), credit).figures
            == .balance(BalanceFigures(currency: .usd, amount: 188.79, spentThisMonth: 11.21)))
    }

    /// Juice spec §9.5 for the new sources: a 429 pauses the account for Retry-After plus 900 s, or 60 s plus 900 s when
    /// the answer gives none, and the pause is kept in the saved records.
    @Test func theNewSourcesPauseOnA429() async throws {
        let home = try MoneyTempDir()
        try home.write(".config/deepseek/key", Self.key)
        try home.write(".config/vastai/key", Self.key)
        let server = MoneyStubServer()
        server.on(.deepSeekBalance, status: 429, headers: ["Retry-After": "120"])
        server.on(.vastUser, status: 429)
        let clock = MoneySchedulerTests.Clock()
        let money = MoneyScheduler(client: server.client(clock: { clock.now }), clock: { clock.now }, sleep: { _ in throw CancellationError() },
                                   fence: { home.fence() })
        #expect(await money.readNow(.deepSeek).pausedUntil == Self.now + 1_020)
        #expect(await money.readNow(.vastAI).pausedUntil == Self.now + 960)
        clock.advance(600)
        _ = await money.readNow(.deepSeek)
        _ = await money.readNow(.vastAI)
        #expect(server.count(.deepSeekBalance) == 1 && server.count(.vastUser) == 1)
        #expect(MoneySource.allCases.dropFirst(5).allSatisfy { $0.interval == 300 })
    }

    /// Every key the new sources take is read from its own file and never shows anywhere else: not in a reading, a
    /// record, a saved file, a Diagnostics line or a drawn row.
    @Test func aNewSourcesKeyIsNeverKeptOrShown() async throws {
        let home = try MoneyTempDir()
        let keys: [MoneySource: String] = [.deepSeek: "sk-FAKEdeepseek000000000000", .moonshot: "sk-FAKEmoonshot000000000000",
                                           .xAI: "xai-FAKEmanagement0000000000", .fal: "FAKEfal:admin000000000000",
                                           .elevenLabs: "FAKEelevenlabs00000000000", .vastAI: "FAKEvast000000000000000000",
                                           .digitalOcean: "dop_v1_FAKE0000000000000000", .fireworks: "fw_FAKE00000000000000000000"]
        for (source, key) in keys { try MoneyKeyFile.write(key, for: MoneyAccount(source), guard: home.fence()) }
        let server = MoneyStubServer()
        try server.on(.deepSeekBalance, fixture: "deepseek-balance")
        try server.on(.moonshotBalance, fixture: "moonshot-balance")
        server.on("GET", "management-api.x.ai", "/v1/billing/teams/\(Self.team)/prepaid/balance",
                  json: String(decoding: try moneyFixture("xai-prepaid-balance"), as: UTF8.self))
        try server.on(.falBilling, fixture: "fal-billing")
        try server.on(.elevenLabsSubscription, fixture: "elevenlabs-subscription")
        try server.on(.vastUser, fixture: "vast-user")
        try server.on(.vastInstances, fixture: "vast-instances-page2")
        try server.on(.digitalOceanBalance, fixture: "digitalocean-balance")
        server.on("GET", "api.fireworks.ai", "/v1/accounts/fictional-account/billing/summary",
                  json: String(decoding: try moneyFixture("fireworks-billing-summary"), as: UTF8.self))
        let money = MoneyScheduler(client: server.client(), clock: { Self.now }, sleep: { _ in throw CancellationError() }, fence: { home.fence() })
        await money.update(settings: [.xAI: MoneySourceSettings(accountID: Self.team), .fireworks: MoneySourceSettings(accountID: "fictional-account")])
        for source in keys.keys { #expect(await money.readNow(MoneyAccount(source)).lastGood != nil, "\(source)") }
        #expect(server.unexpected.isEmpty)
        let store = MoneyStore(url: home.url.appendingPathComponent("store/money.json"))
        store.save(await money.records)
        let texts = [try String(contentsOf: store.url, encoding: .utf8), "\(await money.records)", String(reflecting: await money.records),
                     money.client.recentRequests.map(\.line).joined(separator: "\n"), "\(money.client.recentRequests)"]
            + MoneyAccount.firsts.compactMap { account in
                MoneyPresentation.make(account: account, record: nil, settings: MoneySourceSettings(), now: Self.now, amber: 72, red: 24).map { "\($0)" }
            }
        for text in texts {
            for key in keys.values { #expect(!text.contains(key)) }
        }
        // Each request carried its key in its source's place only.
        for request in server.received {
            let host = request.url?.host() ?? ""
            let source = try #require(MoneyEndpoint.allCases.first { $0.host == host }?.source)
            let key = try #require(keys[source])
            let place = MoneyEndpoint.allCases.first { $0.source == source }!.keyPlacement
            #expect(headers(request)[place.headerName] == place.value(MoneyKey(key)), "\(source)")
            #expect(request.url?.absoluteString.contains(key) == false)
        }
    }
}
