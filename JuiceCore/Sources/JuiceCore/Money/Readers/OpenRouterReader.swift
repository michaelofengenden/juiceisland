import Foundation

/// OpenRouter (Juice spec §8.1): `GET /api/v1/key` every read; `GET /api/v1/credits` is tried once and used while the
/// key is allowed to read it. A 401 or 403 there stops asking for the rest of the run, and the balance comes from the
/// key's limit or the configured top-up instead (Juice spec §11 item 4).
public actor OpenRouterReader: MoneyReader {
    public nonisolated let source = MoneySource.openRouter
    /// nil until `/credits` has answered once.
    private(set) var creditsAllowed: Bool?

    public init() {}

    /// A new key may be allowed `/credits` where the old one was not: it is asked again.
    public func forget() async { creditsAllowed = nil }

    public func read(key: MoneyKey, context: MoneyReadContext, client: MoneyHTTPClient) async throws -> MoneyReading {
        var figures = try Self.parseKey(try await client.send(MoneyRequest(.openRouterKey, key: key)).ok())
        if creditsAllowed != false {
            do {
                let credits = try Self.parseCredits(try await client.send(MoneyRequest(.openRouterCredits, key: key)).ok())
                figures.totalCredits = credits.totalCredits
                figures.totalUsage = credits.totalUsage
                creditsAllowed = true
            } catch MoneyReadError.notAvailableWithThisKey {
                creditsAllowed = false
            } catch let error as MoneyReadError {
                if case .rateLimited = error { throw error }
                // Anything else: try again on the next read.
            }
        }
        return MoneyReading(source: source, readAt: context.now, figures: .balance(figures.kind))
    }

    struct KeyAnswer: Decodable {
        struct Data: Decodable {
            var usage: MoneyJSON.Number?
            var usage_daily: MoneyJSON.Number?
            var usage_monthly: MoneyJSON.Number?
            var limit: MoneyJSON.Number?
            var limit_remaining: MoneyJSON.Number?
        }
        var data: Data
    }

    struct CreditsAnswer: Decodable {
        struct Data: Decodable {
            var total_credits: MoneyJSON.Number
            var total_usage: MoneyJSON.Number
        }
        var data: Data
    }

    static func parseKey(_ data: Data) throws -> OpenRouterFigures {
        let answer = try MoneyJSON.decode(KeyAnswer.self, data, "OpenRouter key")
        return OpenRouterFigures(usageDaily: answer.data.usage_daily?.value, usageMonthly: answer.data.usage_monthly?.value,
                                 usageTotal: answer.data.usage?.value, limit: answer.data.limit?.value,
                                 limitRemaining: answer.data.limit_remaining?.value)
    }

    static func parseCredits(_ data: Data) throws -> (totalCredits: Double, totalUsage: Double) {
        let answer = try MoneyJSON.decode(CreditsAnswer.self, data, "OpenRouter credits")
        return (answer.data.total_credits.value, answer.data.total_usage.value)
    }
}
