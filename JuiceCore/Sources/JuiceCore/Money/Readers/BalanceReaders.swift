import Foundation

/// The prepaid balances read with one `GET` each (Juice Island spec §8 decision 14): DeepSeek, Moonshot, xAI and fal.ai.
/// Each read stands alone, so nothing is kept. Every decoder takes the fields it draws and nothing else: fal.ai's answer
/// carries the account's username, which is never decoded.

/// DeepSeek: `GET https://api.deepseek.com/user/balance`, the key as a bearer token. Its `balance_infos` hold one total
/// per currency (yuan or dollars, as decimal strings); the balance drawn is the first with money in it, else the first.
public struct DeepSeekReader: MoneyReader {
    public let source = MoneySource.deepSeek

    public init() {}

    public func forget() async {}

    public func read(key: MoneyKey, context: MoneyReadContext, client: MoneyHTTPClient) async throws -> MoneyReading {
        let data = try await client.send(MoneyRequest(.deepSeekBalance, key: key)).ok()
        return MoneyReading(source: source, readAt: context.now, figures: .balance(try Self.parse(data)))
    }

    struct Answer: Decodable {
        struct Info: Decodable {
            var currency: String
            var total_balance: MoneyJSON.Number
        }
        var balance_infos: [Info]
    }

    static func parse(_ data: Data) throws -> BalanceFigures {
        let answer = try MoneyJSON.decode(Answer.self, data, "DeepSeek balance")
        let known = answer.balance_infos.compactMap { info in MoneyCurrency(code: info.currency).map { ($0, info.total_balance.value) } }
        guard let (currency, amount) = known.first(where: { $0.1 > 0 }) ?? known.first else {
            throw MoneyReadError.unreadableResponse("DeepSeek balance")
        }
        return BalanceFigures(currency: currency, amount: amount)
    }
}

/// Moonshot (the Kimi API): `GET https://api.moonshot.ai/v1/users/me/balance`, the key as a bearer token. The balance is
/// `data.available_balance` in dollars (cash plus vouchers; cash alone can be below zero). An answer that says it failed
/// (`status` false, a `code` other than 0) is an unexpected answer, never a zero.
public struct MoonshotReader: MoneyReader {
    public let source = MoneySource.moonshot

    public init() {}

    public func forget() async {}

    public func read(key: MoneyKey, context: MoneyReadContext, client: MoneyHTTPClient) async throws -> MoneyReading {
        let data = try await client.send(MoneyRequest(.moonshotBalance, key: key)).ok()
        return MoneyReading(source: source, readAt: context.now, figures: .balance(try Self.parse(data)))
    }

    struct Answer: Decodable {
        struct Payload: Decodable { var available_balance: MoneyJSON.Number }
        var code: Int?
        var status: Bool?
        var data: Payload?
    }

    static func parse(_ data: Data) throws -> BalanceFigures {
        let answer = try MoneyJSON.decode(Answer.self, data, "Moonshot balance")
        guard answer.status != false, (answer.code ?? 0) == 0, let payload = answer.data else {
            throw MoneyReadError.unreadableResponse("Moonshot balance")
        }
        return BalanceFigures(currency: .usd, amount: payload.available_balance.value)
    }
}

/// xAI: `GET https://management-api.x.ai/v1/billing/teams/{team}/prepaid/balance` with a management key (never the
/// inference key) as a bearer token, and the team id from Settings › Money in the path. `total.val` is in cents and
/// counts credit bought as negative (a $10 purchase is `-1000`), so the balance is its opposite.
public struct XAIReader: MoneyReader {
    public let source = MoneySource.xAI

    public init() {}

    public func forget() async {}

    public func read(key: MoneyKey, context: MoneyReadContext, client: MoneyHTTPClient) async throws -> MoneyReading {
        let team = try MoneyReadContext.id(context.settings.accountID, for: .xAIPrepaidBalance)
        let data = try await client.send(MoneyRequest(.xAIPrepaidBalance, id: team, key: key)).ok()
        return MoneyReading(source: source, readAt: context.now, figures: .balance(try Self.parse(data)))
    }

    struct Answer: Decodable {
        struct Cents: Decodable { var val: MoneyJSON.Number }
        var total: Cents
    }

    static func parse(_ data: Data) throws -> BalanceFigures {
        let answer = try MoneyJSON.decode(Answer.self, data, "xAI prepaid balance")
        return BalanceFigures(currency: .usd, amount: -answer.total.val.value / 100)
    }
}

/// fal.ai: `GET https://api.fal.ai/v1/account/billing?expand=credits` with an admin key as `Authorization: Key …`. The
/// balance is `credits.current_balance` in `credits.currency`; the answer's `username` is never decoded.
public struct FalReader: MoneyReader {
    public let source = MoneySource.fal

    public init() {}

    public func forget() async {}

    public func read(key: MoneyKey, context: MoneyReadContext, client: MoneyHTTPClient) async throws -> MoneyReading {
        let request = MoneyRequest(.falBilling, query: [URLQueryItem(name: "expand", value: "credits")], key: key)
        return MoneyReading(source: source, readAt: context.now, figures: .balance(try Self.parse(try await client.send(request).ok())))
    }

    struct Answer: Decodable {
        struct Credits: Decodable {
            var current_balance: MoneyJSON.Number
            var currency: String?
        }
        var credits: Credits?
    }

    static func parse(_ data: Data) throws -> BalanceFigures {
        let answer = try MoneyJSON.decode(Answer.self, data, "fal.ai billing")
        guard let credits = answer.credits, let currency = MoneyCurrency(code: credits.currency ?? "USD") else {
            throw MoneyReadError.unreadableResponse("fal.ai billing")
        }
        return BalanceFigures(currency: currency, amount: credits.current_balance.value)
    }
}
