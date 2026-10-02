import Foundation

/// DigitalOcean: `GET https://api.digitalocean.com/v2/customers/my/balance` with a `billing:read` token as a bearer token.
/// `month_to_date_balance` is what the account would owe if billed now (`account_balance` plus `month_to_date_usage`),
/// so below zero it is a credit left: then the figure is that credit, a balance; otherwise it is the month's usage, spend.
/// Each read stands alone.
public struct DigitalOceanReader: MoneyReader {
    public let source = MoneySource.digitalOcean

    public init() {}

    public func forget() async {}

    public func read(key: MoneyKey, context: MoneyReadContext, client: MoneyHTTPClient) async throws -> MoneyReading {
        let data = try await client.send(MoneyRequest(.digitalOceanBalance, key: key)).ok()
        return MoneyReading(source: source, readAt: context.now, figures: try Self.parse(data, now: context.now))
    }

    struct Answer: Decodable {
        var month_to_date_balance: MoneyJSON.Number
        var month_to_date_usage: MoneyJSON.Number
    }

    static func parse(_ data: Data, now: Date) throws -> MoneyReading.Figures {
        let answer = try MoneyJSON.decode(Answer.self, data, "DigitalOcean balance")
        let owed = answer.month_to_date_balance.value
        if owed < 0 { return .balance(BalanceFigures(currency: .usd, amount: -owed, spentThisMonth: answer.month_to_date_usage.value)) }
        return .spend(SpendFigures(currency: .usd, daily: [:], coveredFrom: MoneyRules.startOfMonth(now),
                                   monthToDate: answer.month_to_date_usage.value))
    }
}

/// Fireworks: `GET https://api.fireworks.ai/v1/accounts/{account}/billing/summary?startTime&endTime` with the API key as a
/// bearer token and the account id from Settings › Money in the path: the month so far, from the first of the month (UTC)
/// to tomorrow (the end is exclusive and only its date counts), as the sum of the line items' `totalCost`
/// (`{currencyCode, units, nanos}`). An empty month may leave `lineItems` out. Each read stands alone.
public struct FireworksReader: MoneyReader {
    public let source = MoneySource.fireworks

    public init() {}

    public func forget() async {}

    public func read(key: MoneyKey, context: MoneyReadContext, client: MoneyHTTPClient) async throws -> MoneyReading {
        let account = try MoneyReadContext.id(context.settings.accountID, for: .fireworksBillingSummary)
        let start = MoneyRules.startOfMonth(context.now)
        let end = MoneyRules.utc.date(byAdding: .day, value: 1, to: MoneyRules.startOfDay(context.now)) ?? context.now
        let query = [URLQueryItem(name: "startTime", value: MoneyRules.dayKey(start) + "T00:00:00Z"),
                     URLQueryItem(name: "endTime", value: MoneyRules.dayKey(end) + "T00:00:00Z")]
        let data = try await client.send(MoneyRequest(.fireworksBillingSummary, query: query, id: account, key: key)).ok()
        let (currency, total) = try Self.parse(data)
        return MoneyReading(source: source, readAt: context.now,
                            figures: .spend(SpendFigures(currency: currency, daily: [:], coveredFrom: start, monthToDate: total)))
    }

    struct Answer: Decodable {
        struct Item: Decodable {
            struct Money: Decodable {
                var currencyCode: String?
                var units: MoneyJSON.Number?
                var nanos: MoneyJSON.Number?
            }
            var totalCost: Money?
        }
        var lineItems: [Item]?
    }

    static func parse(_ data: Data) throws -> (MoneyCurrency, Double) {
        let answer = try MoneyJSON.decode(Answer.self, data, "Fireworks billing")
        var currency: MoneyCurrency?
        var total = 0.0
        for cost in (answer.lineItems ?? []).compactMap(\.totalCost) {
            // One currency for the month; an item in another, or in one Juice cannot draw, makes the answer unreadable.
            guard let this = MoneyCurrency(code: cost.currencyCode ?? "USD"), currency == nil || currency == this else {
                throw MoneyReadError.unreadableResponse("Fireworks billing")
            }
            currency = this
            total += (cost.units?.value ?? 0) + (cost.nanos?.value ?? 0) / 1e9
        }
        return (currency ?? .usd, total)
    }
}

/// ElevenLabs: `GET https://api.elevenlabs.io/v1/user/subscription` with the key in `xi-api-key`. Not money but a quota:
/// characters used of the plan's limit, and when the count resets. Only those three fields are decoded. Each read stands
/// alone.
public struct ElevenLabsReader: MoneyReader {
    public let source = MoneySource.elevenLabs

    public init() {}

    public func forget() async {}

    public func read(key: MoneyKey, context: MoneyReadContext, client: MoneyHTTPClient) async throws -> MoneyReading {
        let data = try await client.send(MoneyRequest(.elevenLabsSubscription, key: key)).ok()
        return MoneyReading(source: source, readAt: context.now, figures: .quota(try Self.parse(data)))
    }

    struct Answer: Decodable {
        var character_count: MoneyJSON.Number
        var character_limit: MoneyJSON.Number
        var next_character_count_reset_unix: MoneyJSON.Number?
    }

    static func parse(_ data: Data) throws -> QuotaFigures {
        let answer = try MoneyJSON.decode(Answer.self, data, "ElevenLabs subscription")
        guard answer.character_count.value >= 0, answer.character_limit.value >= 0 else {
            throw MoneyReadError.unreadableResponse("ElevenLabs subscription")
        }
        return QuotaFigures(used: answer.character_count.value, limit: answer.character_limit.value, unit: "characters",
                            resetsAt: answer.next_character_count_reset_unix.map { Date(timeIntervalSince1970: $0.value) })
    }
}
