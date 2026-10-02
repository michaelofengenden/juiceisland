import Foundation
import SwiftUI

/// Snooze (P724 to P726): a right-click on the island or the closed pill, or the gear's menu in either mode, mutes Juice
/// Island for an hour or until 08:00 next, and Unmute ends it early. While it lasts nothing sounds, nothing opens the island by itself (a card that needs
/// you, a finish's Done card, a stall's or a quota notice, a catch-up after a lock), no reminder pulses or plays and no
/// banner pops up: it holds attention as Quiet hours do (`QuietMode.holdsAttention`). What waits still lists, counts and
/// shows on the pill, and a hover or a click opens the island as ever. The pill wears a small moon while it lasts
/// (`ClosedPillView`). The end is a moment on the wall clock kept in the defaults (`AppSettings.snoozedUntil`), so it
/// survives a relaunch; one timer at that moment clears it (`SnoozeEnd`), and nothing ticks meanwhile.
enum Snooze {
    enum Choice: Equatable, Sendable { case hour, tomorrow }

    /// Mute until tomorrow ends at this hour of the owner's clock.
    static let morningHour = 8

    /// When `choice`, taken at `now`, ends: an hour on, or the next 08:00 on `calendar`'s clock (today's while it is not
    /// yet 08:00, so a night's snooze ends in the morning, never a day later).
    static func end(_ choice: Choice, now: Date, calendar: Calendar = .current) -> Date {
        switch choice {
        case .hour:
            return now.addingTimeInterval(60 * 60)
        case .tomorrow:
            let morning = DateComponents(hour: morningHour, minute: 0, second: 0)
            return calendar.nextDate(after: now, matching: morning, matchingPolicy: .nextTime) ?? now.addingTimeInterval(12 * 60 * 60)
        }
    }

    /// Muted at `now`: an end is set and has not come.
    static func isOn(_ until: Date?, now: Date) -> Bool { until.map { now < $0 } ?? false }

    /// The menu's lines, in order (`Item.header` is a heading, not a control): while muted, when it ends and Unmute; then
    /// both choices, which start it again from now.
    enum Item: Equatable, Sendable {
        case header(String)
        case mute(Choice)
        case unmute

        /// "Mute until 08:00" says the morning choice's end on the owner's clock (12 or 24 hours): before 08:00 it
        /// ends today, so "tomorrow" would promise a night that may be minutes long.
        func title(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
            switch self {
            case let .header(text): text
            case .mute(.hour): "Mute for 1 hour"
            case .mute(.tomorrow): "Mute until " + Snooze.morningText(locale: locale, timeZone: timeZone)
            case .unmute: "Unmute"
            }
        }

        var title: String { title() }
    }

    static func items(until: Date?, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> [Item] {
        let choices: [Item] = [.mute(.hour), .mute(.tomorrow)]
        guard let until, isOn(until, now: now) else { return choices }
        return [.header(endText(until, locale: locale, timeZone: timeZone)), .unmute] + choices
    }

    /// "Muted until 14:32" (or "2:32 PM" in a 12-hour locale): an end is never a day away, so the time alone says it.
    static func endText(_ until: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        "Muted until " + timeText(until, locale: locale, timeZone: timeZone)
    }

    /// 08:00 (or 8:00 AM) as the owner's clock writes it.
    static func morningText(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let morning = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: morningHour)) ?? Date()
        return timeText(morning, locale: locale, timeZone: timeZone)
    }

    private static func timeText(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    /// What a menu line does: a choice mutes from `now`, Unmute ends it.
    @MainActor static func perform(_ item: Item, settings: AppSettings, now: Date = Date(), calendar: Calendar = .current) {
        switch item {
        case let .mute(choice): settings.snoozedUntil = end(choice, now: now, calendar: calendar)
        case .unmute: settings.snoozedUntil = nil
        case .header: break
        }
    }
}

/// The right-click menu of the island's header and of the closed pill (`Snooze.items`; the gear's menu carries the same
/// lines, `GearMenu`): read at the moment it opens, so its lines say where the snooze stands then.
struct SnoozeMenuItems: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let settings = env.settings
        ForEach(Snooze.items(until: settings.snoozedUntil, now: Date()), id: \.title) { item in
            switch item {
            case let .header(text):
                Text(text)
            case .mute, .unmute:
                Button(item.title) { Snooze.perform(item, settings: settings) }
            }
        }
    }
}

/// The one timer a snooze needs (P725): set for its end while one is set, and none otherwise. At the end it clears
/// `snoozedUntil`, so the pill's moon goes on its own; at launch a snooze that ended while the app was quit is cleared
/// at once. The end is a wall-clock moment: a Mac asleep through it clears it as it wakes (`WallClockTimer`).
@MainActor
final class SnoozeEnd {
    private let settings: AppSettings
    private let scheduler: any WallScheduling
    private let clock: @MainActor () -> Date
    private var timer: (any IslandTimerToken)?
    private var timerEnd: Date?
    private var started = false

    init(settings: AppSettings, scheduler: any WallScheduling = WallClockScheduler(), clock: @escaping @MainActor () -> Date = { Date() }) {
        self.settings = settings
        self.scheduler = scheduler
        self.clock = clock
    }

    /// Follows the setting from now on: the shell calls this once, at launch.
    func start() {
        guard !started else { return }
        started = true
        apply()
        observe()
    }

    /// A timer is set (tests: nothing waits while no snooze is set).
    var isArmed: Bool { timer != nil }

    private func observe() {
        withObservationTracking { _ = settings.snoozedUntil } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.apply()
                self?.observe()
            }
        }
    }

    /// One timer for the end that is set; an end already past clears it now.
    func apply() {
        guard let until = settings.snoozedUntil else { return cancel() }
        guard Snooze.isOn(until, now: clock()) else {
            cancel()
            settings.snoozedUntil = nil
            return
        }
        guard until != timerEnd || timer == nil else { return }
        cancel()
        timerEnd = until
        timer = scheduler.schedule(at: until) { [weak self] in self?.fired() }
    }

    private func fired() {
        timer = nil
        timerEnd = nil
        apply()
    }

    private func cancel() {
        timer?.cancel()
        timer = nil
        timerEnd = nil
    }
}

/// A timer for a moment on the wall clock: the app's is a dispatch source on the wall clock (`WallClockTimer`), which a
/// Mac asleep through its moment fires as it wakes; tests fire theirs by hand.
@MainActor
protocol WallScheduling: AnyObject {
    func schedule(at date: Date, _ fire: @escaping @MainActor @Sendable () -> Void) -> any IslandTimerToken
}

@MainActor
final class WallClockScheduler: WallScheduling {
    func schedule(at date: Date, _ fire: @escaping @MainActor @Sendable () -> Void) -> any IslandTimerToken {
        WallClockTimer(at: date, fire)
    }
}

/// Fires once at `date` on the wall clock (`DispatchWallTime`), on the main queue, with a second of leeway: nothing here
/// needs a closer moment. It stops when cancelled or released.
final class WallClockTimer: IslandTimerToken, @unchecked Sendable {
    private let source: DispatchSourceTimer

    init(at date: Date, _ fire: @escaping @MainActor @Sendable () -> Void) {
        source = DispatchSource.makeTimerSource(queue: .main)
        let seconds = max(0, date.timeIntervalSince1970)
        let whole = seconds.rounded(.down)
        let wall = DispatchWallTime(timespec: timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1e9)))
        source.schedule(wallDeadline: wall, repeating: .never, leeway: .seconds(1))
        source.setEventHandler { MainActor.assumeIsolated { fire() } }
        source.resume()
    }

    func cancel() { source.cancel() }

    deinit { source.cancel() }
}
