import Foundation

public struct CodexAccount: Decodable, Sendable, Equatable {
    public var type: String?
    public var email: String?
    public var planType: String?
}

/// `result` of `account/read`. `account` is null when the home is signed out.
public struct CodexAccountReadResult: Decodable, Sendable {
    public var account: CodexAccount?
    public var requiresOpenaiAuth: Bool?
}

/// `result` of `account/rateLimits/read`. Windows are classified by their duration, never by slot (spec §8.1).
public struct CodexRateLimitsResult: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public var usedPercent: Double
        public var windowDurationMins: Int?
        public var resetsAt: Double?
    }
    public struct Credits: Decodable, Sendable {
        public var hasCredits: Bool?
        public var balance: String?
    }
    public struct Limits: Decodable, Sendable {
        public var primary: Window?
        public var secondary: Window?
        public var credits: Credits?
        public var planType: String?
        public var rateLimitReachedType: String?
    }
    /// Rate-limit reset credits (`rateLimitResetCredits`), in the same response: their count and the first expiry.
    /// Read leniently: a shape Juice does not know leaves them out and never fails the reading.
    public struct ResetCredits: Decodable, Sendable {
        public var availableCount: Int?
        public var nextExpiry: Date?

        private enum CodingKeys: String, CodingKey { case availableCount, credits }

        private struct Credit: Decodable {
            var expiresAt: Date?
            private enum CodingKeys: String, CodingKey { case expiresAt }

            init(from decoder: Decoder) {
                let container = try? decoder.container(keyedBy: CodingKeys.self)
                if let seconds = try? container?.decode(Double.self, forKey: .expiresAt) {
                    // Seconds, or milliseconds when it is that large.
                    expiresAt = Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1_000 : seconds)
                } else if let text = try? container?.decode(String.self, forKey: .expiresAt) {
                    expiresAt = ISO8601DateFormatter().date(from: text)
                }
            }
        }

        public init(from decoder: Decoder) {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            availableCount = try? container?.decode(Int.self, forKey: .availableCount)
            let credits = (try? container?.decode([Credit].self, forKey: .credits)) ?? []
            nextExpiry = credits.compactMap(\.expiresAt).min()
        }
    }

    public var ordinaryUsageAllowed: Bool?
    public var rateLimits: Limits?
    public var rateLimitResetCredits: ResetCredits?

    /// "Not allowed", or a rate-limit-reached type, with no window at all is a used-up account (refill unknown),
    /// not a missing reading (P31).
    public func reading(accountID: String, readAt: Date, email: String?) -> AccountReading {
        let windows = [rateLimits?.primary, rateLimits?.secondary].compactMap { $0 }.map { Self.window($0, readAt: readAt) }
        let reachedWithNoWindow = windows.isEmpty && rateLimits?.rateLimitReachedType != nil
        let balance = rateLimits?.credits?.balance.flatMap(Double.init)
        let resets = rateLimitResetCredits?.availableCount.flatMap { $0 > 0 ? $0 : nil }
        return AccountReading(accountID: accountID, readAt: readAt, plan: rateLimits?.planType?.lowercased(), email: email,
                              windows: windows, ordinaryUsageAllowed: (ordinaryUsageAllowed ?? true) && !reachedWithNoWindow,
                              creditsBalance: balance, resetCredits: resets,
                              resetCreditExpires: resets == nil ? nil : rateLimitResetCredits?.nextExpiry)
    }

    /// The length comes from `windowDurationMins`. Codex reports two lengths today, 5 hours and a week, so when the
    /// length is missing a reset more than 5 hours and at most a week away is the week's. Anything nearer could be
    /// either, and anything further is a length Codex did not have: that window is called "window", never "5h".
    static func window(_ w: Window, readAt: Date) -> UsageWindow {
        let resetsAt = w.resetsAt.map { Date(timeIntervalSince1970: $0) }
        if let minutes = w.windowDurationMins {
            return UsageWindow(seconds: minutes * 60, usedPercent: w.usedPercent, resetsAt: resetsAt)
        }
        if let resetsAt {
            let untilReset = resetsAt.timeIntervalSince(readAt)
            if untilReset > 5 * 3_600 + 60, untilReset <= 7 * 86_400 + 3_600 {
                return UsageWindow(seconds: 7 * 86_400, usedPercent: w.usedPercent, resetsAt: resetsAt)
            }
        }
        return UsageWindow(seconds: 0, usedPercent: w.usedPercent, resetsAt: resetsAt, label: "window")
    }
}
