import Foundation

/// Hetzner Cloud (Juice spec §8.1): servers, volumes, primary IPs, floating IPs and the price list, every 5 minutes
/// (5 to 10 requests, well inside 3,600 an hour). The month is estimated from net prices: each server that is not
/// being deleted costs its hourly price for the hours it runs this month, capped at its monthly price, plus 20 % (the
/// price list's backup share) when backups are on; volumes per GB-month; unassigned primary IPv4s and floating IPs at
/// their monthly price. Snapshots need `/v1/images`, which §8.1 does not list, so they are not counted yet.
public struct HetznerReader: MoneyReader {
    public let source = MoneySource.hetzner
    static let perPage = 50
    static let maximumPages = 5

    public init() {}

    /// Each read stands alone: nothing is kept.
    public func forget() async {}

    public func read(key: MoneyKey, context: MoneyReadContext, client: MoneyHTTPClient) async throws -> MoneyReading {
        let servers: [Server] = try await list(.hetznerServers, field: "servers", key: key, client: client)
        let volumes: [Volume] = try await list(.hetznerVolumes, field: "volumes", key: key, client: client)
        let primaryIPs: [PrimaryIP] = try await list(.hetznerPrimaryIPs, field: "primary_ips", key: key, client: client)
        let floatingIPs: [FloatingIP] = try await list(.hetznerFloatingIPs, field: "floating_ips", key: key, client: client)
        let pricing = try MoneyJSON.decode(PricingAnswer.self, try await client.send(MoneyRequest(.hetznerPricing, key: key)).ok(),
                                           "Hetzner pricing").pricing
        let figures = Self.estimate(servers: servers, volumes: volumes, primaryIPs: primaryIPs, floatingIPs: floatingIPs,
                                    pricing: pricing, now: context.now)
        return MoneyReading(source: source, readAt: context.now, figures: .spend(figures.spend(from: MoneyRules.startOfMonth(context.now))))
    }

    private func list<Item: Decodable>(_ endpoint: MoneyEndpoint, field: String, key: MoneyKey,
                                       client: MoneyHTTPClient) async throws -> [Item] {
        var items: [Item] = []
        var page = 1
        for _ in 0..<Self.maximumPages {
            let query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "per_page", value: String(Self.perPage))]
            let data = try await client.send(MoneyRequest(endpoint, query: query, key: key)).ok()
            let answer = try MoneyJSON.decode(ListAnswer<Item>.self, data, "Hetzner \(field)")
            // The list asked for, never another list-shaped field of the same answer; without it the answer is unread.
            guard let found = answer.lists[field] else { throw MoneyReadError.unreadableResponse("Hetzner \(field)") }
            items += found
            guard let next = answer.nextPage, next > page else { break }
            page = next
        }
        return items
    }

    // MARK: Answers

    struct Price: Decodable {
        var net: MoneyJSON.Number
    }

    struct LocationName: Decodable { var name: String }

    struct Server: Decodable {
        struct ServerType: Decodable {
            struct LocationPrice: Decodable {
                var location: String
                var price_hourly: Price
                var price_monthly: Price
            }
            var name: String?
            var prices: [LocationPrice]
        }
        struct Datacenter: Decodable { var location: LocationName }
        var name: String
        var status: String
        var created: String?
        var server_type: ServerType
        var datacenter: Datacenter?
        var backup_window: String?
    }

    struct Volume: Decodable {
        var name: String
        var size: Double
        var location: LocationName?
    }

    struct PrimaryIP: Decodable {
        struct Datacenter: Decodable { var location: LocationName }
        var name: String
        var type: String
        var assignee_id: Int?
        var datacenter: Datacenter?
    }

    struct FloatingIP: Decodable {
        var name: String
        var type: String
        var home_location: LocationName?
    }

    struct Pricing: Decodable {
        struct PerGB: Decodable { var price_per_gb_month: Price }
        struct Backup: Decodable { var percentage: MoneyJSON.Number }
        struct IPType: Decodable {
            struct LocationPrice: Decodable {
                var location: String
                var price_monthly: Price
            }
            var type: String
            var prices: [LocationPrice]
        }
        var currency: String?
        var volume: PerGB
        var server_backup: Backup
        var primary_ips: [IPType]?
        var floating_ips: [IPType]?
    }

    struct PricingAnswer: Decodable { var pricing: Pricing }

    struct ListAnswer<Item: Decodable>: Decodable {
        /// Every field that reads as a list of `Item`, by name.
        var lists: [String: [Item]]
        var nextPage: Int?

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        struct Meta: Decodable {
            struct Pagination: Decodable { var next_page: Int? }
            var pagination: Pagination?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            lists = Dictionary(uniqueKeysWithValues: container.allKeys.filter { $0.stringValue != "meta" }.compactMap { key in
                (try? container.decode([Item].self, forKey: key)).map { (key.stringValue, $0) }
            })
            nextPage = (try? container.decode(Meta.self, forKey: Key(stringValue: "meta")))?.pagination?.next_page
        }
    }

    // MARK: Estimate

    static func estimate(servers: [Server], volumes: [Volume], primaryIPs: [PrimaryIP], floatingIPs: [FloatingIP],
                         pricing: Pricing, now: Date) -> HetznerFigures {
        let calendar = MoneyRules.utc
        let monthStart = MoneyRules.startOfMonth(now)
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let backupShare = pricing.server_backup.percentage.value / 100
        var items: [HetznerFigures.Item] = []
        for server in servers where server.status != "deleting" {
            let location = server.datacenter?.location.name
            guard let price = server.server_type.prices.first(where: { $0.location == location }) ?? server.server_type.prices.first else {
                continue
            }
            let created = server.created.flatMap(parseDate) ?? monthStart
            let hours = max(0, monthEnd.timeIntervalSince(max(created, monthStart)) / 3_600)
            let cost = min(price.price_hourly.net.value * hours, price.price_monthly.net.value)
            items.append(.init(kind: .server, name: server.name, monthly: cost))
            if server.backup_window != nil {
                items.append(.init(kind: .backup, name: server.name, monthly: cost * backupShare))
            }
        }
        let perGB = pricing.volume.price_per_gb_month.net.value
        items += volumes.map { .init(kind: .volume, name: $0.name, monthly: $0.size * perGB) }
        func ipPrice(_ table: [Pricing.IPType]?, type: String, location: String?) -> Double {
            let prices = table?.first { $0.type == type }?.prices ?? []
            return (prices.first { $0.location == location } ?? prices.first)?.price_monthly.net.value ?? 0
        }
        for ip in primaryIPs where ip.assignee_id == nil && ip.type == "ipv4" {
            items.append(.init(kind: .primaryIP, name: ip.name,
                               monthly: ipPrice(pricing.primary_ips, type: ip.type, location: ip.datacenter?.location.name)))
        }
        for ip in floatingIPs {
            items.append(.init(kind: .floatingIP, name: ip.name,
                               monthly: ipPrice(pricing.floating_ips, type: ip.type, location: ip.home_location?.name)))
        }
        return HetznerFigures(items: items)
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
