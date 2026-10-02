import Foundation
import Testing
@testable import JuiceCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let readAt = Date(timeIntervalSince1970: 1_790_082_000)

@Test func claudeUsageResponseBecomesAReading() throws {
    let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: fixture("claude-get-usage"))
    let reading = try response.reading(accountID: "claude:/x", readAt: readAt)
    #expect(reading.plan == "max")
    #expect(reading.windows.count == 2)
    #expect(reading.windows[0].seconds == 18_000)
    #expect(reading.windows[0].usedPercent == 5)
    #expect(reading.windows[0].resetsAt == ISO8601DateFormatter.juice.date(from: "2026-09-22T17:00:00.644898+00:00"))
    #expect(reading.windows[1].seconds == 604_800)
    #expect(reading.windows[1].usedPercent == 13)
    #expect(Rules.percentLeft(reading) == 87)
    // The two windows every plan reports carry no label of their own; their text comes from their length.
    #expect(reading.windows.allSatisfy { $0.label == nil })
    #expect(reading.windows.map(\.displayLabel) == ["5h", "week"])
}

/// A Max capture also carries the per-model weeks. Blocked on the Opus week, the account is used up even though
/// every other window still has room — leaving them undecoded showed it as available and picked it as Next.
@Test func maxPlanPerModelWeeksAreDecodedAndCanBlock() throws {
    let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: fixture("claude-get-usage-max"))
    let reading = try response.reading(accountID: "claude:/x", readAt: readAt)
    #expect(reading.windows.count == 4)
    #expect(reading.windows.map(\.seconds) == [18_000, 604_800, 604_800, 604_800])
    #expect(reading.windows.map(\.usedPercent) == [5, 13, 100, 30])
    #expect(reading.windows.map(\.label) == [nil, nil, "week · Opus", "week · Sonnet"])
    #expect(Rules.percentLeft(reading) == 0)

    let opusReset = ISO8601DateFormatter.juice.date(from: "2026-09-26T09:00:00.000000+00:00")
    #expect(reading.windows[2].resetsAt == opusReset)
    #expect(Rules.isExhausted(reading))
    #expect(Rules.refillDate(reading) == opusReset)          // the blocking window's reset, not the latest of all
    #expect(Rules.state(reading: reading, lastError: nil, signingIn: false, provider: .claude, now: readAt)
            == .usedUp(refill: opusReset))

    let hover = PanelModelBuilder.batteryLabel(alias: "work", state: .usedUp(refill: opusReset),
                                               record: AccountRecord(lastGood: reading), now: readAt)
    #expect(hover.contains("0% left, week · Opus"))
}

/// readings.json files written before the label existed have to keep decoding.
@Test func aStoredReadingWithoutWindowLabelsStillDecodes() throws {
    let json = #"""
    {"accountID":"claude:/x","readAt":"2026-09-22T17:00:00Z","ordinaryUsageAllowed":true,
     "windows":[{"seconds":18000,"usedPercent":5},{"seconds":604800,"usedPercent":13}]}
    """#
    let reading = try JSONDecoder.juice.decode(AccountReading.self, from: Data(json.utf8))
    #expect(reading.windows.count == 2)
    #expect(reading.windows.allSatisfy { $0.label == nil })
    #expect(reading.windows.map(\.displayLabel) == ["5h", "week"])
}

@Test func claudeUsageWithoutPlanLimitsFails() throws {
    let json = #"{"subscription_type":"max","rate_limits_available":false,"rate_limits":null}"#
    let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
    #expect(throws: ReadError.incomplete("plan limits not available")) {
        try response.reading(accountID: "claude:/x", readAt: readAt)
    }
}

@Test func claudeUsageWithoutAnyAccountIsSignInRequired() throws {
    let json = #"{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}"#
    let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
    #expect(throws: ReadError.signInRequired) {
        try response.reading(accountID: "claude:/x", readAt: readAt)
    }
}

@Test func claudeUsageWithLimitsButNoPlanIsStillARead() throws {
    let json = #"""
    {"subscription_type":null,"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":10,"resets_at":"2026-09-22T17:00:00Z"},"seven_day":{"utilization":20,"resets_at":"2026-09-25T17:00:00Z"}}}
    """#
    let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
    let reading = try response.reading(accountID: "claude:/x", readAt: readAt)
    #expect(reading.plan == nil)
    #expect(reading.windows.count == 2)
}

@Test func codexAccountRead() throws {
    let result = try JSONDecoder().decode(CodexAccountReadResult.self, from: fixture("codex-account"))
    #expect(result.account?.email == "someone@example.com")
    #expect(result.account?.planType == "pro")
    let signedOut = try JSONDecoder().decode(CodexAccountReadResult.self, from: Data(#"{"account":null,"requiresOpenaiAuth":true}"#.utf8))
    #expect(signedOut.account == nil)
}

@Test func codexRateLimitsBecomeAReading() throws {
    let result = try JSONDecoder().decode(CodexRateLimitsResult.self, from: fixture("codex-ratelimits"))
    let reading = result.reading(accountID: "codex:/x", readAt: readAt, email: "someone@example.com")
    #expect(reading.plan == "pro")
    #expect(reading.windows.count == 1)
    #expect(reading.windows[0].seconds == 10_080 * 60)
    #expect(reading.windows[0].usedPercent == 99)
    #expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_790_603_043))
    #expect(reading.ordinaryUsageAllowed)
    #expect(reading.creditsBalance == 0)
}

@Test func codexExhaustedReading() throws {
    let result = try JSONDecoder().decode(CodexRateLimitsResult.self, from: fixture("codex-ratelimits-exhausted"))
    let reading = result.reading(accountID: "codex:/x", readAt: readAt, email: nil)
    #expect(!reading.ordinaryUsageAllowed)
    #expect(reading.creditsBalance.map { abs($0 - 579.163592) < 0.001 } == true)
    #expect(Rules.isExhausted(reading))
}

@Test func jsonRPCEnvelopeAndHelpers() throws {
    let line = #"{"id":3,"result":{"ordinaryUsageAllowed":true,"rateLimits":null}}"#
    let envelope = try JSONRPC.Envelope.decode(Data(line.utf8))
    #expect(envelope.id == 3)
    #expect(envelope.error == nil)
    let typed = try JSONRPC.decodeResult(Data(line.utf8), as: CodexRateLimitsResult.self)
    #expect(typed.ordinaryUsageAllowed == true)
    let request = JSONRPC.request(id: 7, method: "account/read", params: ["refreshToken": false])
    #expect(request.contains(#""id":7"#) && request.contains(#""method":"account\/read""#) || request.contains(#""method":"account/read""#))
    #expect(!request.contains("\n"))
    let failed = try JSONRPC.Envelope.decode(Data(#"{"id":2,"error":{"code":-32000,"message":"boom"}}"#.utf8))
    #expect(failed.error?.message == "boom")
}
