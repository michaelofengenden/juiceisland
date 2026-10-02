import Foundation

/// Why a turn stopped on a limit or an API error (P700 to P709): the account's usage limit, with when it lifts when the
/// agent said, or the provider's own trouble. Read from the agent's own words and fields only, never guessed from a
/// battery:
/// - Claude: a failed turn (the StopFailure note, P4) whose hook `error` is `rate_limit`, `overloaded` or `server_error`.
///   A `rate_limit` is the account's limit when the CLI's message for it says so ("You've hit your session limit ·
///   resets 3pm (America/Los_Angeles)", Claude Code 2.1's `uh`; "You've reached your Fable limit.", P706), else a rate
///   limit that is not the account's ("Server is temporarily limiting requests (not your usage limit)").
/// - Codex: the turn end's `error` (`task_complete`'s `ErrorEvent`, whose `codex_error_info` names the kind and whose
///   message says "Try again at 3:45 PM."), or a rate-limit reading that says the limit was reached
///   (`rate_limit_reached_type`), with the windows' `resets_at`.
public struct SessionLimit: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// The account's usage limit: another account of the provider can go on.
        case usageLimit
        /// A rate limit that is not the account's: the provider's.
        case rateLimited
        case overloaded
        case serverError
    }

    public var kind: Kind
    /// When the usage limit lifts; nil when the agent did not say, and for every API error.
    public var resetsAt: Date?

    public init(kind: Kind, resetsAt: Date? = nil) {
        self.kind = kind
        self.resetsAt = kind == .usageLimit ? resetsAt : nil
    }

    /// The usage limit's reset has passed: the limit no longer holds (an API error never resets by itself).
    public func hasReset(at now: Date) -> Bool {
        guard kind == .usageLimit, let resetsAt else { return false }
        return now >= resetsAt
    }
}

/// Reads a limit from the agents' own words (P701). Pure.
public enum LimitText {
    /// A Claude failed turn: its StopFailure `error` (the bridge's completion summary) and its message (the hook's
    /// `last_assistant_message`, which upstream's bridge keeps as the session's last message). `at`: when the turn
    /// failed, which the message's clock time counts from.
    public static func claude(error: String?, message: String?, at: Date, localZone: TimeZone = .current) -> SessionLimit? {
        switch error?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rate_limit":
            guard let message, isClaudeUsageLimit(message) else { return SessionLimit(kind: .rateLimited) }
            return SessionLimit(kind: .usageLimit, resetsAt: claudeReset(message, at: at, localZone: localZone))
        case "overloaded": return SessionLimit(kind: .overloaded)
        case "server_error": return SessionLimit(kind: .serverError)
        default: return nil
        }
    }

    /// Claude Code's own words for the account's limit (P706): every opening on 2.1.280's list of them (`fvr`, "You've
    /// hit your session limit", "You've reached your Fable limit", "Your seat type doesn't include usage credits", …),
    /// its Fable pattern beside it ("Fable 5 requires usage credits."), and "This service is disabled for your org", which
    /// the same message builder sends for the account. Its warnings on the lists beside them ("You've used 90% …",
    /// "You're now using usage credits") never stop a turn, and its other rate limits name the server ("Server is
    /// temporarily limiting requests (not your usage limit)", "Request rejected (429)").
    static func isClaudeUsageLimit(_ message: String) -> Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{2019}", with: "'")
        return claudeLimitOpenings.contains { text.hasPrefix($0) }
            || text.range(of: #"^Fable(?: [^·\n]{1,40})? requires usage credits\."#, options: .regularExpression) != nil
    }

    static let claudeLimitOpenings = [
        "You've hit your", "You've reached your", "You're out of usage", "Your org is out of usage",
        "Your seat type doesn't include usage", "Your seat type doesn't include extra usage",
        "Your usage allocation has been disabled", "Your group's usage limit", "Fable 5 requires usage credits",
        "You're out of extra usage", "This service is disabled for your org",
    ]

    /// Claude Code's reset, as its `Pc` writes it after "resets ": "3pm" or "3:30pm" within a day, "Oct 7, 3pm" or
    /// "Oct 7, 2027, 3pm" further out, each followed by its time zone in brackets ("(America/Los_Angeles)") when the CLI
    /// gave one. A time alone is the first such time after `at`.
    static func claudeReset(_ message: String, at: Date, localZone: TimeZone) -> Date? {
        let pattern = #"resets (?:([A-Za-z]{3}) (\d{1,2}),(?: (\d{4}),)? )?(\d{1,2})(?::(\d{2}))?\s?([ap]m)(?: \(([^)]+)\))?"#
        guard let groups = match(pattern, in: message) else { return nil }
        let zone = groups[6].flatMap { TimeZone(identifier: $0) } ?? localZone
        return resolve(month: groups[0], day: groups[1].flatMap { Int($0) }, year: groups[2].flatMap { Int($0) },
                       hour: groups[3].flatMap { Int($0) }, minute: groups[4].flatMap { Int($0) } ?? 0,
                       pm: groups[5]?.lowercased() == "pm", zone: zone, after: at)
    }

    /// Codex's turn end `error` (`ErrorEvent`): `codex_error_info` is a word (`usage_limit_exceeded`) or, for the kinds
    /// that carry a status, an object keyed by the word (`{"http_connection_failed":{"http_status_code":429}}`). `at`:
    /// the line's time, which the message's "Try again at 3:45 PM." counts from (Codex writes it in the Mac's zone).
    public static func codex(error: [String: Any], at: Date, localZone: TimeZone = .current) -> SessionLimit? {
        let info = error["codex_error_info"]
        let word = (info as? String) ?? (info as? [String: Any])?.keys.first
        let status = ((info as? [String: Any])?.values.first as? [String: Any])?["http_status_code"] as? Int
        switch word {
        case "usage_limit_exceeded":
            return SessionLimit(kind: .usageLimit, resetsAt: (error["message"] as? String).flatMap { codexReset($0, at: at, localZone: localZone) })
        case "rate_limit_exceeded": return SessionLimit(kind: .rateLimited)
        case "server_overloaded": return SessionLimit(kind: .overloaded)
        case "internal_server_error": return SessionLimit(kind: .serverError)
        case "http_connection_failed", "response_stream_connection_failed", "response_stream_disconnected",
             "response_too_many_failed_attempts":
            guard let status else { return nil }
            if status == 429 { return SessionLimit(kind: .rateLimited) }
            if status == 529 { return SessionLimit(kind: .overloaded) }
            return status >= 500 ? SessionLimit(kind: .serverError) : nil
        default:
            return nil
        }
    }

    /// Codex's reset in its usage-limit message (`format_retry_timestamp`): "Try again at 3:45 PM." the same day,
    /// "… try again at Jan 15th, 2027 3:45 PM." another, in the Mac's zone.
    static func codexReset(_ message: String, at: Date, localZone: TimeZone) -> Date? {
        let pattern = #"(?i)try again at (?:([A-Za-z]{3}) (\d{1,2})(?:st|nd|rd|th), (\d{4}) )?(\d{1,2}):(\d{2}) ?([AP]M)"#
        guard let groups = match(pattern, in: message) else { return nil }
        return resolve(month: groups[0], day: groups[1].flatMap { Int($0) }, year: groups[2].flatMap { Int($0) },
                       hour: groups[3].flatMap { Int($0) }, minute: groups[4].flatMap { Int($0) } ?? 0,
                       pm: groups[5]?.lowercased() == "pm", zone: localZone, after: at)
    }

    /// A Codex rate-limit reading (`token_count`'s `rate_limits`) that says the limit was reached: the windows used up
    /// lift at the latest of their resets (every one of them has to); with none at 100 %, the latest reset of any.
    public static func codexReading(_ rateLimits: [String: Any], at: Date) -> SessionLimit? {
        guard let reached = rateLimits["rate_limit_reached_type"] as? String, !reached.isEmpty else { return nil }
        let windows = ["primary", "secondary"].compactMap { rateLimits[$0] as? [String: Any] }
        func reset(_ window: [String: Any]) -> Date? {
            if let seconds = number(window["resets_at"]) { return Date(timeIntervalSince1970: seconds) }
            return number(window["resets_in_seconds"]).map { at.addingTimeInterval($0) }
        }
        let full = windows.filter { (number($0["used_percent"]) ?? 0) >= 100 }
        let resets = (full.isEmpty ? windows : full).compactMap(reset)
        return SessionLimit(kind: .usageLimit, resetsAt: resets.max())
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let number as Double: number
        case let number as Int: Double(number)
        default: nil
        }
    }

    /// The groups of the first match, each nil where it took no part.
    private static func match(_ pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// The date a reset names in `zone`: a month and day (and year) as given, the next year when no year was given
    /// and that day is more than a day behind `after`; a time alone is its first occurrence after `after`.
    private static func resolve(month: String?, day: Int?, year: Int?, hour: Int?, minute: Int, pm: Bool,
                                zone: TimeZone, after: Date) -> Date? {
        guard let hour, (1...12).contains(hour), (0..<60).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hour24 = hour % 12 + (pm ? 12 : 0)
        if let month, let day, let index = months.firstIndex(of: month.lowercased()) {
            var components = DateComponents(year: year ?? calendar.component(.year, from: after), month: index + 1, day: day,
                                            hour: hour24, minute: minute)
            guard var date = calendar.date(from: components) else { return nil }
            if year == nil, date < after.addingTimeInterval(-86_400) {
                components.year = (components.year ?? 0) + 1
                date = calendar.date(from: components) ?? date
            }
            return date
        }
        guard let today = calendar.date(bySettingHour: hour24, minute: minute, second: 0, of: after) else { return nil }
        return today > after ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
}
