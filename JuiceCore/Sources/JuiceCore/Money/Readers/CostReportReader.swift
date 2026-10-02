import Foundation

/// How one cost API asks for daily buckets and answers them.
public protocol CostReportFormat: Sendable {
    var source: MoneySource { get }
    var endpoint: MoneyEndpoint { get }
    /// The query for daily buckets from the UTC day `start`, at most `limit` of them, from `page` on.
    func query(start: Date, limit: Int, page: String?) -> [URLQueryItem]
    /// Dollars per UTC day, and the next page when there is one.
    func parse(_ data: Data) throws -> (days: [String: Double], nextPage: String?)
}

/// Anthropic's and OpenAI's spend (Juice spec §8.1): daily UTC buckets kept as daily totals. At launch and whenever
/// the first day it must cover moves (a credit or its date changed, or a new month without a credit) it reads back to
/// that day, following the next page on the same path (31 days a page, at most 6 pages). Every other read asks for
/// yesterday and today only (`limit=2`), or from the last day it read when it missed some (after a sleep).
public actor CostReportReader: MoneyReader {
    public nonisolated let source: MoneySource
    let format: any CostReportFormat
    static let backfillLimit = 31
    static let maximumPages = 6

    private var daily: [String: Double] = [:]
    /// The first UTC day `daily` covers, and the last day a read reached.
    private var coveredFrom: Date?
    private var reachedDay: Date?

    public init(format: any CostReportFormat) {
        self.format = format
        source = format.source
    }

    /// A new key may belong to another organization: its days are read back from the start.
    public func forget() async {
        daily = [:]
        coveredFrom = nil
        reachedDay = nil
    }

    public func read(key: MoneyKey, context: MoneyReadContext, client: MoneyHTTPClient) async throws -> MoneyReading {
        if source == .anthropic, let refusal = MoneyHostPolicy.keyRefusal(key, for: .anthropic) { throw refusal }
        let from = MoneyRules.costsFrom(settings: context.settings, now: context.now)
        let today = MoneyRules.startOfDay(context.now)
        let yesterday = MoneyRules.utc.date(byAdding: .day, value: -1, to: today) ?? today
        if coveredFrom != from || reachedDay == nil {
            let days = try await fetch(start: from, through: today, limit: Self.backfillLimit, pages: Self.maximumPages, key: key,
                                       client: client)
            daily = days
            coveredFrom = from
        } else {
            let start = min(yesterday, reachedDay ?? yesterday)
            let span = (MoneyRules.utc.dateComponents([.day], from: start, to: today).day ?? 1) + 1
            let days = try await fetch(start: start, through: today, limit: min(span, Self.backfillLimit),
                                       pages: span > Self.backfillLimit ? Self.maximumPages : 1, key: key, client: client)
            daily.merge(days) { _, new in new }
        }
        reachedDay = today
        let first = MoneyRules.dayKey(from)
        let kept = daily.filter { $0.key >= first }
        return MoneyReading(source: source, readAt: context.now, figures: .spend(SpendFigures(currency: .usd, daily: kept, coveredFrom: from)))
    }

    private func fetch(start: Date, through today: Date, limit: Int, pages: Int, key: MoneyKey,
                       client: MoneyHTTPClient) async throws -> [String: Double] {
        // Pages run forward from `start`, so pages that stop short of today would drop the newest days, the ticks would
        // never ask for them again, and a credit would read as more than is left. A span the pages cannot cover is a
        // failure before anything is sent (the last good figure stays), and so is an answer that still has pages left
        // before today; pages left past today (a tick that crossed midnight UTC) do not matter.
        let pages = max(1, pages)
        let needed = (MoneyRules.utc.dateComponents([.day], from: start, to: today).day ?? 0) + 1
        guard pages * limit >= needed else { throw MoneyReadError.unreadableResponse("more than \(pages) pages") }
        let todayKey = MoneyRules.dayKey(today)
        var days: [String: Double] = [:]
        var page: String?
        for _ in 0..<pages {
            let request = MoneyRequest(format.endpoint, query: format.query(start: start, limit: limit, page: page), key: key)
            let answer = try format.parse(try await client.send(request).ok())
            days.merge(answer.days) { old, new in old + new }
            guard let next = answer.nextPage, !next.isEmpty, (days.keys.max() ?? "") < todayKey else { return days }
            page = next
        }
        throw MoneyReadError.unreadableResponse("more than \(pages) pages")
    }
}

/// Anthropic's Usage and Cost Admin API cost report: `starting_at` in RFC 3339, amounts in cents as decimal strings.
public struct AnthropicCostFormat: CostReportFormat {
    public init() {}
    public var source: MoneySource { .anthropic }
    public var endpoint: MoneyEndpoint { .anthropicCostReport }

    public func query(start: Date, limit: Int, page: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "starting_at", value: MoneyRules.dayKey(start) + "T00:00:00Z"),
                     URLQueryItem(name: "bucket_width", value: "1d"),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let page { items.append(URLQueryItem(name: "page", value: page)) }
        return items
    }

    struct Answer: Decodable {
        struct Bucket: Decodable {
            struct Result: Decodable {
                var amount: MoneyJSON.Number
                var currency: String?
            }
            var starting_at: String
            var results: [Result]
        }
        var data: [Bucket]
        var has_more: Bool?
        var next_page: String?
    }

    public func parse(_ data: Data) throws -> (days: [String: Double], nextPage: String?) {
        let answer = try MoneyJSON.decode(Answer.self, data, "Anthropic cost report")
        var days: [String: Double] = [:]
        for bucket in answer.data {
            guard bucket.starting_at.count >= 10 else { throw MoneyReadError.unreadableResponse("Anthropic cost report") }
            let day = String(bucket.starting_at.prefix(10))
            let cents = bucket.results.filter { ($0.currency ?? "USD").uppercased() == "USD" }.reduce(0) { $0 + $1.amount.value }
            days[day, default: 0] += cents / 100
        }
        return (days, answer.has_more == true ? answer.next_page : nil)
    }
}

/// OpenAI's organization costs: `start_time` in Unix seconds, amounts in dollars.
public struct OpenAICostFormat: CostReportFormat {
    public init() {}
    public var source: MoneySource { .openAI }
    public var endpoint: MoneyEndpoint { .openAICosts }

    public func query(start: Date, limit: Int, page: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                     URLQueryItem(name: "bucket_width", value: "1d"),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let page { items.append(URLQueryItem(name: "page", value: page)) }
        return items
    }

    struct Answer: Decodable {
        struct Bucket: Decodable {
            struct Result: Decodable {
                struct Amount: Decodable {
                    var value: MoneyJSON.Number
                    var currency: String?
                }
                var amount: Amount?
            }
            var start_time: Double
            var results: [Result]
        }
        var data: [Bucket]
        var has_more: Bool?
        var next_page: String?
    }

    public func parse(_ data: Data) throws -> (days: [String: Double], nextPage: String?) {
        let answer = try MoneyJSON.decode(Answer.self, data, "OpenAI costs")
        var days: [String: Double] = [:]
        for bucket in answer.data {
            let day = MoneyRules.dayKey(Date(timeIntervalSince1970: bucket.start_time))
            let dollars = bucket.results.compactMap(\.amount).filter { ($0.currency ?? "usd").lowercased() == "usd" }
                .reduce(0) { $0 + $1.value.value }
            days[day, default: 0] += dollars
        }
        return (days, answer.has_more == true ? answer.next_page : nil)
    }
}
