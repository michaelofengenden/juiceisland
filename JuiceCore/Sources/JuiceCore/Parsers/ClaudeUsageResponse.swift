import Foundation

extension ISO8601DateFormatter {
    /// Parses the CLI's timestamps, which carry fractional seconds; falls back to whole seconds.
    nonisolated(unsafe) public static let juice: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let wholeSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    public static func juiceDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return juice.date(from: string) ?? wholeSeconds.date(from: string)
    }
}

/// The `response` object of the CLI's `get_usage` control response. Every field is optional because
/// Anthropic renames windows without notice. `rate_limits` is read as a keyed map, so a new per-model week becomes
/// a window of its own instead of being dropped (P30).
public struct ClaudeUsageResponse: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public var utilization: Double?
        public var resets_at: String?

        public init(utilization: Double?, resets_at: String?) {
            self.utilization = utilization
            self.resets_at = resets_at
        }
    }
    /// Every object-shaped entry of `rate_limits`, by key. Entries of another shape (`limits` is an array) are
    /// skipped and their keys kept in `unreadable`; entries that are not windows (`extra_usage`) are left out by
    /// `ClaudeWindowTable`.
    public struct RateLimits: Decodable, Sendable {
        public var entries: [String: Window]
        /// Keys whose value is there but does not decode as a window. `reading` fails on a counted one.
        public var unreadable: Set<String>

        public init(entries: [String: Window], unreadable: Set<String> = []) {
            self.entries = entries
            self.unreadable = unreadable
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            var entries: [String: Window] = [:]
            var unreadable: Set<String> = []
            for key in container.allKeys {
                do {
                    if let window = try container.decodeIfPresent(Window.self, forKey: key) { entries[key.stringValue] = window }
                } catch {
                    unreadable.insert(key.stringValue)
                }
            }
            self.entries = entries
            self.unreadable = unreadable
        }

        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }
    public var subscription_type: String?
    public var rate_limits_available: Bool?
    public var rate_limits: RateLimits?

    /// An organization's plan (`subscription_type` "team" or "enterprise"): its limits, when it has any, are the
    /// organization's, and one billed by usage has none (P581).
    public static let organizationPlans: Set<String> = ["team", "enterprise"]

    var isOrganizationPlan: Bool { subscription_type.map { Self.organizationPlans.contains($0.lowercased()) } ?? false }

    public func reading(accountID: String, readAt: Date) throws(ReadError) -> AccountReading {
        guard rate_limits_available != false, let limits = rate_limits else {
            // The CLI must explicitly say `rate_limits_available:false` with no plan at all before this counts as
            // "no login": a missing/absent `rate_limits_available` field, or a `rate_limits` shape that's simply
            // malformed or not present yet, stays `.incomplete` rather than being read as a sign-in problem. The same
            // explicit answer with a plan named is the account's own (its subscription ended, P360), kept apart so the
            // login can be told No plan after a streak of them (`NoPlanStreak`). An organization's plan is no exception
            // (P583): the CLI says false only without its inference scope (an API key, Bedrock, Vertex, or a scope
            // gone), which is what a seat taken away looks like; a seat billed by usage keeps the scope and says true.
            if rate_limits_available == false {
                if subscription_type == nil { throw ReadError.signInRequired }
                throw ReadError.noPlanLimits
            }
            throw ReadError.incomplete("plan limits missing")
        }
        // A counted window whose shape changed could hide a used-up limit: dropping it would let the account read as
        // available on the other windows (P30), so the whole reading is incomplete instead.
        if let changed = ClaudeWindowTable.known.first(where: { $0.counted && limits.unreadable.contains($0.key) }) {
            throw ReadError.incomplete("\(changed.key) window unreadable")
        }
        let windows = ClaudeWindowTable.windows(from: limits.entries)
        // All-null windows (or only windows that do not count) are "no reading yet", never 0%; for an organization's plan
        // whose CLI says it has limits to report (`rate_limits_available:true`), they are its answer that it has none: a
        // seat billed by usage (P581, P583).
        guard windows.contains(where: \.isCounted) else {
            throw isOrganizationPlan && rate_limits_available == true ? ReadError.noLimitsReported : ReadError.incomplete("no windows reported")
        }
        return AccountReading(accountID: accountID, readAt: readAt, plan: subscription_type?.lowercased(), windows: windows)
    }
}

/// Which Claude windows count toward the battery. Every `five_hour…` or `seven_day…` key with a utilization becomes a
/// window; the known keys below keep their names, and a model's own week counts, because an account out of its Opus
/// week is out of Opus and must not be offered as Next. The OAuth-apps week and keys Juice does not know yet do not
/// count: they show in the hover and Diagnostics only.
public enum ClaudeWindowTable {
    public struct Entry: Sendable, Equatable {
        public var key: String
        public var label: String?
        public var counted: Bool
    }

    public static let known: [Entry] = [
        Entry(key: "five_hour", label: nil, counted: true),
        Entry(key: "seven_day", label: nil, counted: true),
        Entry(key: "seven_day_opus", label: "week · Opus", counted: true),
        Entry(key: "seven_day_sonnet", label: "week · Sonnet", counted: true),
        Entry(key: "seven_day_fable", label: "week · Fable", counted: true),
        Entry(key: "seven_day_oauth_apps", label: "week · OAuth apps", counted: false),
    ]

    /// Known keys in table order, then unknown ones by name.
    public static func windows(from entries: [String: ClaudeUsageResponse.Window]) -> [UsageWindow] {
        let knownKeys = Set(known.map(\.key))
        let unknown = entries.keys.filter { !knownKeys.contains($0) && seconds(forKey: $0) != nil }.sorted()
        let ordered = known.map { ($0.key, $0.label, $0.counted) } + unknown.map { ($0, name(forUnknownKey: $0), false) }
        return ordered.compactMap { key, label, counted in
            guard let window = entries[key], let used = window.utilization, let seconds = seconds(forKey: key) else { return nil }
            return UsageWindow(seconds: seconds, usedPercent: used, resetsAt: ISO8601DateFormatter.juiceDate(window.resets_at),
                               label: label, counted: counted ? nil : false)
        }
    }

    static func seconds(forKey key: String) -> Int? {
        if key == "five_hour" || key.hasPrefix("five_hour_") { return 5 * 3_600 }
        if key == "seven_day" || key.hasPrefix("seven_day_") { return 7 * 86_400 }
        return nil
    }

    /// `seven_day_new_model` → "week · new model"; `five_hour_x` → "5h · x".
    static func name(forUnknownKey key: String) -> String {
        let prefix = key.hasPrefix("five_hour_") ? "five_hour_" : "seven_day_"
        let length = prefix == "five_hour_" ? "5h" : "week"
        return "\(length) · " + key.dropFirst(prefix.count).replacingOccurrences(of: "_", with: " ")
    }
}
