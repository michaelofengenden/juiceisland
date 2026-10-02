import Foundation

// MARK: Readings

/// One successful read of an account, parsed into plain figures. Never holds a key or a raw response.
public struct MoneyReading: Codable, Sendable, Equatable {
    public var source: MoneySource
    public var readAt: Date
    public var figures: Figures

    public init(source: MoneySource, readAt: Date, figures: Figures) {
        self.source = source
        self.readAt = readAt
        self.figures = figures
    }

    /// Every figure is one of three kinds (Juice Island spec §8 decision 14), so a new source needs only its endpoint and
    /// a parser: money held (`balance`), money spent over a period (`spend`), or a quota used out of a limit (`quota`).
    /// Written as `{"balance": {…}}`; the four shapes builds wrote before the kinds (`openRouter`, `costs`, `runPod`,
    /// `hetzner`) still read, as their kinds.
    public enum Figures: Codable, Sendable, Equatable {
        case balance(BalanceFigures)
        case spend(SpendFigures)
        case quota(QuotaFigures)

        private enum Kind: String, CodingKey { case balance, spend, quota, openRouter, costs, runPod, hetzner }
        /// The key Swift gives an enum case's one unnamed value, as the older builds wrote it.
        private enum Unnamed: String, CodingKey { case value = "_0" }

        /// A cost report's days as the builds before the kinds kept them: dollars, no currency.
        private struct OlderCosts: Decodable {
            var daily: [String: Double]
            var coveredFrom: Date
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Kind.self)
            func older<T: Decodable>(_ type: T.Type, _ key: Kind) throws -> T {
                try container.nestedContainer(keyedBy: Unnamed.self, forKey: key).decode(type, forKey: .value)
            }
            if container.contains(.balance) {
                self = .balance(try container.decode(BalanceFigures.self, forKey: .balance))
            } else if container.contains(.spend) {
                self = .spend(try container.decode(SpendFigures.self, forKey: .spend))
            } else if container.contains(.quota) {
                self = .quota(try container.decode(QuotaFigures.self, forKey: .quota))
            } else if container.contains(.openRouter) {
                self = .balance(try older(OpenRouterFigures.self, .openRouter).kind)
            } else if container.contains(.runPod) {
                self = .balance(try older(RunPodFigures.self, .runPod).kind)
            } else if container.contains(.hetzner) {
                self = .spend(try older(HetznerFigures.self, .hetzner).spend)
            } else if container.contains(.costs) {
                let costs = try older(OlderCosts.self, .costs)
                self = .spend(SpendFigures(currency: .usd, daily: costs.daily, coveredFrom: costs.coveredFrom))
            } else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no figure kind"))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Kind.self)
            switch self {
            case .balance(let figures): try container.encode(figures, forKey: .balance)
            case .spend(let figures): try container.encode(figures, forKey: .spend)
            case .quota(let figures): try container.encode(figures, forKey: .quota)
            }
        }
    }
}

/// Money held: a prepaid balance (RunPod, DeepSeek, Moonshot, xAI, fal.ai, Vast.ai, a DigitalOcean credit) or what an
/// OpenRouter key may see of one, with what burns it when the source says.
public struct BalanceFigures: Codable, Sendable, Equatable {
    public var currency: MoneyCurrency
    /// The balance; nil when only a configured top-up can tell it (an OpenRouter key with no limit that may not read
    /// `/credits`: top-up minus `spentTotal`).
    public var amount: Double?
    /// Dollars an hour running now (RunPod's `currentSpendPerHr`, Vast.ai's running instances); nil when not known.
    public var burnPerHour: Double?
    public var spentToday: Double?
    public var spentThisMonth: Double?
    /// Everything the key has spent (OpenRouter's `usage`), for the top-up measure.
    public var spentTotal: Double?
    /// Why a balance that may burn (Vast.ai's) has no burn this read, so no runway: said, never drawn as "nothing
    /// runs".
    public var runwayGap: RunwayGap?

    /// A burn the source could not give: the key may not see what runs (a 401 or 403), or what runs was not read.
    public enum RunwayGap: String, Codable, Sendable, Equatable {
        case notAllowed, notRead
    }

    public init(currency: MoneyCurrency, amount: Double?, burnPerHour: Double? = nil, spentToday: Double? = nil,
                spentThisMonth: Double? = nil, spentTotal: Double? = nil, runwayGap: RunwayGap? = nil) {
        self.currency = currency
        self.amount = amount
        self.burnPerHour = burnPerHour
        self.spentToday = spentToday
        self.spentThisMonth = spentThisMonth
        self.spentTotal = spentTotal
        self.runwayGap = runwayGap
    }

    /// The balance, or the configured top-up minus what the key spent (Juice spec §11 item 4); nil when neither is known.
    public func balance(topUp: Double?) -> Double? {
        if let amount { return amount }
        if let topUp, let spentTotal { return topUp - spentTotal }
        return nil
    }
}

/// Money spent over a period: daily UTC buckets from `coveredFrom` (Anthropic's and OpenAI's cost reports), the month so
/// far as one total (DigitalOcean, Fireworks), or the month estimated from what runs (Hetzner).
public struct SpendFigures: Codable, Sendable, Equatable {
    public var currency: MoneyCurrency
    /// Money per UTC day (`yyyy-MM-dd`) from `coveredFrom` to the read; empty when the source gives a total only.
    public var daily: [String: Double]
    /// The first UTC day the figures cover (the credit date, or the first of the month).
    public var coveredFrom: Date
    /// The month so far, when the source gives it as one total.
    public var monthToDate: Double?
    /// What runs, each at its monthly price, when the figure is the month's estimate (Hetzner's resources).
    public var estimate: [Item]?

    public struct Item: Codable, Sendable, Equatable {
        /// `server`, `backup`, `volume`, `primaryIP`, `floatingIP`.
        public var kind: String
        public var name: String
        public var monthly: Double

        public init(kind: String, name: String, monthly: Double) {
            self.kind = kind
            self.name = name
            self.monthly = monthly
        }
    }

    public init(currency: MoneyCurrency = .usd, daily: [String: Double], coveredFrom: Date, monthToDate: Double? = nil,
                estimate: [Item]? = nil) {
        self.currency = currency
        self.daily = daily
        self.coveredFrom = coveredFrom
        self.monthToDate = monthToDate
        self.estimate = estimate
    }

    /// The month's estimate: every item's monthly price.
    public var monthlyEstimate: Double { (estimate ?? []).reduce(0) { $0 + $1.monthly } }
    public var serverCount: Int { (estimate ?? []).filter { $0.kind == "server" }.count }
}

/// Anthropic's and OpenAI's spend before the kinds: the same days, in dollars.
public typealias CostFigures = SpendFigures

/// A quota used out of a limit that resets (ElevenLabs' characters): not money, so it reads as the share left, like a
/// battery.
public struct QuotaFigures: Codable, Sendable, Equatable {
    public var used: Double
    public var limit: Double
    /// What is counted, plural (`characters`).
    public var unit: String
    public var resetsAt: Date?

    public init(used: Double, limit: Double, unit: String, resetsAt: Date? = nil) {
        self.used = used
        self.limit = limit
        self.unit = unit
        self.resetsAt = resetsAt
    }

    /// The share left, 0 to 1; 0 when there is no limit to measure against.
    public var leftShare: Double { limit > 0 ? min(1, max(0, 1 - used / limit)) : 0 }
}

// MARK: What some readers parse before it becomes a kind

/// OpenRouter's `/api/v1/key` and, when the key may read it, `/api/v1/credits`. Dollars.
public struct OpenRouterFigures: Codable, Sendable, Equatable {
    public var usageDaily: Double?
    public var usageMonthly: Double?
    public var usageTotal: Double?
    public var limit: Double?
    public var limitRemaining: Double?
    /// From `/credits`: everything bought and everything used on the account.
    public var totalCredits: Double?
    public var totalUsage: Double?

    public init(usageDaily: Double? = nil, usageMonthly: Double? = nil, usageTotal: Double? = nil, limit: Double? = nil,
                limitRemaining: Double? = nil, totalCredits: Double? = nil, totalUsage: Double? = nil) {
        self.usageDaily = usageDaily
        self.usageMonthly = usageMonthly
        self.usageTotal = usageTotal
        self.limit = limit
        self.limitRemaining = limitRemaining
        self.totalCredits = totalCredits
        self.totalUsage = totalUsage
    }

    /// The balance kind: credits bought minus used when `/credits` answered, else what the key's limit leaves (Juice
    /// spec §11 item 4); with neither, the top-up minus the key's usage is left to the presentation.
    public var kind: BalanceFigures {
        let amount: Double? = if let totalCredits, let totalUsage { totalCredits - totalUsage } else { limitRemaining }
        return BalanceFigures(currency: .usd, amount: amount, spentToday: usageDaily, spentThisMonth: usageMonthly, spentTotal: usageTotal)
    }
}

public struct RunPodFigures: Codable, Sendable, Equatable {
    public var balance: Double
    /// `currentSpendPerHr`; nil when the API left it out.
    public var burnPerHour: Double?
    public var spendLimit: Double?
    public var pods: [Pod]

    public struct Pod: Codable, Sendable, Equatable {
        public var name: String
        public var costPerHour: Double
        public var running: Bool
        public var gpu: String?

        public init(name: String, costPerHour: Double, running: Bool, gpu: String? = nil) {
            self.name = name
            self.costPerHour = costPerHour
            self.running = running
            self.gpu = gpu
        }
    }

    public init(balance: Double, burnPerHour: Double?, spendLimit: Double? = nil, pods: [Pod] = []) {
        self.balance = balance
        self.burnPerHour = burnPerHour
        self.spendLimit = spendLimit
        self.pods = pods
    }
}

extension RunPodFigures {
    /// The balance kind: the balance and its burn (the pods and the spend limit are not drawn, so not kept).
    public var kind: BalanceFigures { BalanceFigures(currency: .usd, amount: balance, burnPerHour: burnPerHour) }
}

/// Hetzner's running resources, each with its monthly net price in euros (Juice spec §8.1).
public struct HetznerFigures: Codable, Sendable, Equatable {
    public var items: [Item]

    public struct Item: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case server, backup, volume, primaryIP, floatingIP }
        public var kind: Kind
        public var name: String
        public var monthly: Double

        public init(kind: Kind, name: String, monthly: Double) {
            self.kind = kind
            self.name = name
            self.monthly = monthly
        }
    }

    public init(items: [Item]) { self.items = items }

    public var monthlyEstimate: Double { items.reduce(0) { $0 + $1.monthly } }
    public var serverCount: Int { items.filter { $0.kind == .server }.count }

    /// The spend kind: the month's estimate in euros, from the first of the month.
    public func spend(from monthStart: Date) -> SpendFigures {
        SpendFigures(currency: .eur, daily: [:], coveredFrom: monthStart,
                     estimate: items.map { SpendFigures.Item(kind: $0.kind.rawValue, name: $0.name, monthly: $0.monthly) })
    }

    /// As `spend(from:)`, for a reading whose month is not known (one the builds before the kinds saved).
    var spend: SpendFigures { spend(from: .distantPast) }
}
