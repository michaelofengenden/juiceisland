import Foundation

public enum Formatting {
    /// "5h", "24h", "week", "3d", "90m" from a window length in seconds. A week tolerates an hour either way.
    public static func windowLabel(seconds: Int) -> String {
        let week = 7 * 86_400
        if abs(seconds - week) <= 3_600 { return "week" }
        if seconds >= 2 * 86_400, seconds % 86_400 == 0 { return "\(seconds / 86_400)d" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)h" }
        return "\(seconds / 60)m"
    }

    /// The label inside a used-up battery: "22m", "1:12", "Fri", "due", or "?" when unknown.
    public static func refillLabel(_ resetsAt: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let resetsAt else { return "?" }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "due" }
        if remaining < 3_600 { return "\(max(1, Int(remaining / 60)))m" }
        if remaining < 24 * 3_600 {
            let hours = Int(remaining / 3_600)
            let minutes = Int(remaining.truncatingRemainder(dividingBy: 3_600) / 60)
            return String(format: "%d:%02d", hours, minutes)
        }
        if remaining <= 48 * 3_600 { return "\(Int(remaining / 86_400))d" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter.string(from: resetsAt)
    }

    /// When a window resets, in words, for hover labels and lists (the battery keeps its compact `refillLabel`): "in 22m",
    /// "in 1h 40m", "in 1d 3h" within two days, then the weekday ("Fri"); "now" once due, "?" when unknown. Never
    /// "1:40", which reads like a time of day.
    public static func refillPhrase(_ resetsAt: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let resetsAt else { return "?" }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "now" }
        if remaining <= 48 * 3_600 { return "in " + duration(max(60, remaining.rounded(.down))) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter.string(from: resetsAt)
    }

    /// "45s", "22m", "1h 12m", "2d 3h" for hover labels and inspectors.
    public static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        let days = hours / 24
        let restHours = hours % 24
        return restHours == 0 ? "\(days)d" : "\(days)d \(restHours)h"
    }

    /// "just now", "12s ago", "8m ago", "3h ago", "2d ago".
    public static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date).rounded()))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}
