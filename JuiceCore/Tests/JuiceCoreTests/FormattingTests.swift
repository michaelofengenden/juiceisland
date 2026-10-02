import Foundation
import Testing
@testable import JuiceCore

private let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:33:20 UTC, a Monday

@Test func windowLabels() {
    #expect(Formatting.windowLabel(seconds: 5 * 3_600) == "5h")
    #expect(Formatting.windowLabel(seconds: 24 * 3_600) == "24h")
    #expect(Formatting.windowLabel(seconds: 7 * 86_400) == "week")
    #expect(Formatting.windowLabel(seconds: 10_080 * 60) == "week")
    #expect(Formatting.windowLabel(seconds: 3 * 86_400) == "3d")
    #expect(Formatting.windowLabel(seconds: 90 * 60) == "90m")
}

@Test func refillLabelInsideAnHourIsMinutes() {
    #expect(Formatting.refillLabel(now.addingTimeInterval(22 * 60 + 5), now: now) == "22m")
    #expect(Formatting.refillLabel(now.addingTimeInterval(30), now: now) == "1m")
}

@Test func refillLabelUnderADayIsHoursAndMinutes() {
    #expect(Formatting.refillLabel(now.addingTimeInterval(3_600 + 12 * 60), now: now) == "1:12")
    #expect(Formatting.refillLabel(now.addingTimeInterval(23 * 3_600 + 59 * 60), now: now) == "23:59")
}

@Test func refillLabelBetweenOneAndTwoDaysIsDays() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    #expect(Formatting.refillLabel(now.addingTimeInterval(30 * 3_600), now: now, calendar: utc) == "1d")
    #expect(Formatting.refillLabel(now.addingTimeInterval(47 * 3_600 + 59 * 60), now: now, calendar: utc) == "1d")
    #expect(Formatting.refillLabel(now.addingTimeInterval(48 * 3_600), now: now, calendar: utc) == "2d")
    #expect(Formatting.refillLabel(now.addingTimeInterval(49 * 3_600), now: now, calendar: utc) == "Wed")
}

/// Hover labels and lists word a reset as a span ("in 1h 40m"), never as "1:40", which reads like a time of day.
@Test func refillPhraseIsASpanNeverAClockTime() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    #expect(Formatting.refillPhrase(now.addingTimeInterval(22 * 60 + 5), now: now) == "in 22m")
    #expect(Formatting.refillPhrase(now.addingTimeInterval(30), now: now) == "in 1m")
    #expect(Formatting.refillPhrase(now.addingTimeInterval(3_600 + 40 * 60 + 30), now: now) == "in 1h 40m")
    #expect(Formatting.refillPhrase(now.addingTimeInterval(5 * 3_600), now: now) == "in 5h")
    #expect(Formatting.refillPhrase(now.addingTimeInterval(27 * 3_600), now: now, calendar: utc) == "in 1d 3h")
    #expect(Formatting.refillPhrase(now.addingTimeInterval(4 * 86_400), now: now, calendar: utc) == "Fri")
    #expect(Formatting.refillPhrase(now.addingTimeInterval(-5), now: now) == "now")
    #expect(Formatting.refillPhrase(nil, now: now) == "?")
    #expect(!Formatting.refillPhrase(now.addingTimeInterval(3_600 + 40 * 60), now: now).contains(":"))
}

@Test func refillLabelBeyondADayIsAWeekday() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    #expect(Formatting.refillLabel(now.addingTimeInterval(4 * 86_400), now: now, calendar: utc) == "Fri")
}

@Test func refillLabelAfterResetIsDue() {
    #expect(Formatting.refillLabel(now.addingTimeInterval(-1), now: now) == "due")
    #expect(Formatting.refillLabel(nil, now: now) == "?")
}

@Test func durations() {
    #expect(Formatting.duration(45) == "45s")
    #expect(Formatting.duration(22 * 60) == "22m")
    #expect(Formatting.duration(3_600 + 12 * 60) == "1h 12m")
    #expect(Formatting.duration(2 * 86_400 + 3 * 3_600) == "2d 3h")
}

@Test func ages() {
    #expect(Formatting.age(of: now.addingTimeInterval(-12), now: now) == "12s ago")
    #expect(Formatting.age(of: now.addingTimeInterval(-8 * 60), now: now) == "8m ago")
    #expect(Formatting.age(of: now.addingTimeInterval(-3 * 3_600), now: now) == "3h ago")
    #expect(Formatting.age(of: now, now: now) == "just now")
}

@Test func percentLeftOfWindow() {
    #expect(UsageWindow(seconds: 18_000, usedPercent: 31, resetsAt: nil).percentLeft == 69)
    #expect(UsageWindow(seconds: 18_000, usedPercent: 120, resetsAt: nil).percentLeft == 0)
}
