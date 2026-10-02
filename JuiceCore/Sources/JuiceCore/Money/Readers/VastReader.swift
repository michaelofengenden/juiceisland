import Foundation

/// Vast.ai (Juice spec §4.5's C-list source, added with the figure kinds): the balance from
/// `GET https://console.vast.ai/api/v0/users/current` and the burn from `GET /api/v1/instances`, both with the key as a
/// bearer token (never the documented `?api_key=`), so the runway reads like RunPod's. The user answer also carries the
/// account's email, SSH key and ids: only `balance` is decoded. The instances are asked for two columns only
/// (`select_cols`), so no instance's tokens or addresses are even sent back, 25 a page and at most `maximumPages`
/// pages; the burn is the dollars an hour of those running. A key allowed the balance but not the instances (a key
/// scoped to `user_read` alone) is asked for them once: after a 401 or 403 the balance reads without a burn until the
/// key changes, and says so (`RunwayGap.notAllowed`). Instances that fail another way keep the last burn while it is
/// fresh (`MoneyRules.freshness`), so one failed read never drops an amber or red runway; past that the balance says
/// its runway was not read (`RunwayGap.notRead`), never drawn as nothing running. Vast.ai sends no Retry-After with a
/// 429, so its pause is the scheduler's fixed one. A read that keeps the balance but loses the runway is logged when
/// that starts and when the runway is back (P115), never at every read.
public actor VastReader: MoneyReader {
    public nonisolated let source = MoneySource.vastAI
    static let perPage = 25
    static let maximumPages = 4
    static let columns = #"["actual_status","dph_total"]"#

    /// nil until the instances have answered once.
    private(set) var instancesAllowed: Bool?
    /// The last read asked for the instances and they failed another way than a refusal.
    private(set) var instancesFailing = false
    /// The last burn the instances gave, and the read that gave it.
    private var lastBurn: (perHour: Double, at: Date)?

    public init() {}

    /// A new key may be allowed the instances where the old one was not: they are asked again. Its burn is its own.
    public func forget() async {
        instancesAllowed = nil
        instancesFailing = false
        lastBurn = nil
    }

    public func read(key: MoneyKey, context: MoneyReadContext, client: MoneyHTTPClient) async throws -> MoneyReading {
        let balance = try MoneyJSON.decode(UserAnswer.self, try await client.send(MoneyRequest(.vastUser, key: key)).ok(),
                                           "Vast.ai user").balance.value
        var burn: Double?
        var gap: BalanceFigures.RunwayGap?
        if instancesAllowed != false {
            let account = (MoneyHTTPClient.account ?? MoneyAccount(source)).rawValue
            do {
                let running = try await burnPerHour(key: key, client: client)
                burn = running
                lastBurn = (running, context.now)
                instancesAllowed = true
                if instancesFailing { JuiceLog.money.notice("\(account, privacy: .public): instances read again, the runway is back") }
                instancesFailing = false
            } catch MoneyReadError.notAvailableWithThisKey {
                instancesAllowed = false
                lastBurn = nil
                JuiceLog.money.notice("\(account, privacy: .public): instances not allowed, the balance reads without a runway")
            } catch let error as MoneyReadError {
                if case .rateLimited = error { throw error }
                // Anything else: the last burn while it is fresh, else no runway, said; asked again on the next read.
                if let last = lastBurn, context.now.timeIntervalSince(last.at) <= MoneyRules.freshness {
                    burn = last.perHour
                } else {
                    gap = .notRead
                }
                if !instancesFailing {
                    JuiceLog.money.error("\(account, privacy: .public): instances failed, \(error.logName, privacy: .public)")
                }
                instancesFailing = true
            }
        }
        if instancesAllowed == false { gap = .notAllowed }
        return MoneyReading(source: source, readAt: context.now, figures: .balance(BalanceFigures(currency: .usd, amount: balance,
                                                                                                    burnPerHour: burn, runwayGap: gap)))
    }

    private func burnPerHour(key: MoneyKey, client: MoneyHTTPClient) async throws -> Double {
        var total = 0.0
        var after: String?
        for _ in 0..<Self.maximumPages {
            var query = [URLQueryItem(name: "limit", value: String(Self.perPage)), URLQueryItem(name: "select_cols", value: Self.columns)]
            if let after { query.append(URLQueryItem(name: "after_token", value: after)) }
            let answer = try MoneyJSON.decode(InstancesAnswer.self, try await client.send(MoneyRequest(.vastInstances, query: query, key: key)).ok(),
                                              "Vast.ai instances")
            total += Self.burn(answer.instances)
            guard let next = answer.next_token, !next.isEmpty else { return total }
            after = next
        }
        // More instances than the pages cover: a runway from part of them would read longer than it is.
        throw MoneyReadError.unreadableResponse("Vast.ai instances")
    }

    static func burn(_ instances: [InstancesAnswer.Instance]) -> Double {
        instances.filter { $0.actual_status == "running" }.reduce(0) { $0 + ($1.dph_total?.value ?? 0) }
    }

    struct UserAnswer: Decodable { var balance: MoneyJSON.Number }

    struct InstancesAnswer: Decodable {
        struct Instance: Decodable {
            var actual_status: String?
            var dph_total: MoneyJSON.Number?
        }
        var instances: [Instance]
        var next_token: String?
    }
}
