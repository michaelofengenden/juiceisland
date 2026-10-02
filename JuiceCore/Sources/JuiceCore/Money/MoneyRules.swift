import Foundation

/// The money rules (Juice spec §2.3, §8.2; Juice Island spec §7 amendment 11), pure and clock-free.
public enum MoneyRules {
    /// A money reading older than this is stale: rails on the surfaces, and no runway (Juice spec §8.2).
    public static let freshness: TimeInterval = 600
    /// Runway reads whole hours below this and whole days from it, whatever the amber and red thresholds say.
    public static let runwayDaysFrom: Double = 72

    // MARK: Runway

    /// Runway longer than this (about 114 years) is shown as this, so the labels' whole numbers always fit an `Int`.
    static let runwayLimit: Double = 1_000_000

    /// Hours of compute left: balance ÷ burn per hour. nil when burn is 0 or unknown, or the reading is stale.
    public static func runwayHours(balance: Double, burnPerHour: Double?, stale: Bool) -> Double? {
        guard !stale, let burnPerHour, burnPerHour > 0, balance.isFinite, burnPerHour.isFinite else { return nil }
        let hours = max(0, balance) / burnPerHour
        return hours.isFinite ? min(hours, runwayLimit) : runwayLimit
    }

    /// `<1h`, `18h`, `71h` below 72 h; `3d`, `52d` from 72 h. Both round down.
    public static func runwayLabel(hours: Double) -> String {
        if hours < 1 { return "<1h" }
        if hours < runwayDaysFrom { return "\(Int(hours.rounded(.down)))h" }
        return "\(Int((hours / 24).rounded(.down)))d"
    }

    /// The hover label's `about 60 hours`, `about 52 days`.
    public static func runwayHover(hours: Double) -> String {
        if hours < 1 { return "under an hour" }
        if hours < runwayDaysFrom {
            let whole = Int(hours.rounded(.down))
            return "about \(whole) hour\(whole == 1 ? "" : "s")"
        }
        return "about \(Int((hours / 24).rounded(.down))) days"
    }

    /// The inspector's `~60h`, `~52d`.
    public static func runwayInspector(hours: Double) -> String {
        hours < 1 ? "<1h" : "~" + runwayLabel(hours: hours)
    }

    /// Amber under `amber` hours, red under `red`, on the unrounded hours.
    public static func runwayEmphasis(hours: Double?, amber: Int, red: Int) -> MoneyRowModel.Emphasis {
        guard let hours else { return .normal }
        if hours < Double(red) { return .attention }
        if hours < Double(amber) { return .warn }
        return .normal
    }

    // MARK: Amounts

    /// Amounts at or past this (or not finite) read as a dash rather than trap in the `Int` conversion below.
    static let amountLimit: Double = 1e15

    /// `$4,120` from $100 up (no decimals), `$38.20` below, `−$12` when negative.
    public static func amount(_ value: Double, _ currency: MoneyCurrency) -> String {
        guard value.isFinite, abs(value) < amountLimit else { return "\u{2014}" }
        let cents = (abs(value) * 100).rounded()
        let sign = value < 0 && cents > 0 ? "\u{2212}" : ""
        if cents >= 10_000 {
            return sign + currency.symbol + grouped(Int((abs(value)).rounded()))
        }
        return sign + currency.symbol + String(format: "%.2f", cents / 100)
    }

    /// `$1.84/h`, `€0.21/h`: always two decimals.
    public static func rate(_ perHour: Double, _ currency: MoneyCurrency) -> String {
        currency.symbol + String(format: "%.2f", max(0, perHour)) + "/h"
    }

    /// A share as whole percent, rounded down like the batteries (`74%`; `0%` only when nothing is left).
    public static func percent(_ share: Double) -> String {
        guard share.isFinite else { return "\u{2014}" }
        let clamped = min(1, max(0, share))
        let whole = Int((clamped * 100).rounded(.down))
        return "\(whole == 0 && clamped > 0 ? 1 : whole)%"
    }

    /// A count with thousands grouped (`2,600`), or a dash when out of range.
    public static func count(_ value: Double) -> String {
        guard value.isFinite, abs(value) < amountLimit else { return "\u{2014}" }
        let whole = Int(value.rounded())
        return (whole < 0 ? "\u{2212}" : "") + grouped(abs(whole))
    }

    static func grouped(_ value: Int) -> String {
        let digits = String(value)
        var out = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return out
    }

    // MARK: Days (UTC, as the cost reports bucket them)

    public static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `2026-09-24`.
    public static func dayKey(_ date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func startOfDay(_ date: Date) -> Date { utc.startOfDay(for: date) }

    public static func startOfMonth(_ date: Date) -> Date {
        utc.date(from: utc.dateComponents([.year, .month], from: date)) ?? startOfDay(date)
    }

    /// `7 Sep`.
    public static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = utc.timeZone
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    /// `September`.
    public static func monthName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = utc.timeZone
        formatter.dateFormat = "LLLL"
        return formatter.string(from: date)
    }

    /// The first day a cost reader must cover: the credit date when a credit is set, else the first of the month.
    public static func costsFrom(settings: MoneySourceSettings, now: Date) -> Date {
        if settings.credit != nil, let date = settings.creditDate { return startOfDay(min(date, now)) }
        return startOfMonth(now)
    }
}

extension CostFigures {
    /// Spend on the UTC days from `start` on.
    public func spent(from start: Date) -> Double {
        let first = MoneyRules.dayKey(start)
        return daily.filter { $0.key >= first }.reduce(0) { $0 + $1.value }
    }

    public func today(_ now: Date) -> Double { daily[MoneyRules.dayKey(now)] ?? 0 }

    public func month(_ now: Date) -> Double { spent(from: MoneyRules.startOfMonth(now)) }
}

extension OpenRouterFigures {
    /// The balance: credits bought minus used when `/credits` answered; else what the key's limit leaves; else the
    /// configured top-up minus the key's usage (Juice spec §11 item 4). nil when none of these is known.
    public func balance(topUp: Double?) -> Double? {
        if let totalCredits, let totalUsage { return totalCredits - totalUsage }
        if let limitRemaining { return limitRemaining }
        if let topUp, let usageTotal { return topUp - usageTotal }
        return nil
    }
}
