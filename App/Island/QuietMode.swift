import Foundation

/// Settings › Island › Quiet hours: a daily span of the owner's local time, from `from` to `to` minutes after midnight,
/// over midnight when `to` comes first (22:00 to 08:00, the default). `from` is in it and `to` is not, so 22:00 to 08:00
/// is quiet at 22:00 and at 07:59, and not at 08:00. The same time twice is the whole day: the switch being on always
/// quiets something (P332). Read on the wall clock at the moment a sound or a card would come, never on a timer: the
/// pill shows the same either side of the span, so nothing has to change when it starts or ends.
struct QuietHours: Equatable, Sendable {
    static let defaultFrom = 22 * 60
    static let defaultTo = 8 * 60
    static let day = 24 * 60
    /// The pop-ups' step: every half hour.
    static let step = 30

    var from: Int
    var to: Int

    init(from: Int, to: Int) {
        self.from = Self.stored(from)
        self.to = Self.stored(to)
    }

    /// A minute of the day (0 ..< 1440): a value written into the defaults by hand outside it wraps onto the day.
    static func stored(_ minutes: Int) -> Int { ((minutes % day) + day) % day }

    /// The minute of the day `date` falls on, on `calendar`'s wall clock (its time zone, daylight saving included).
    static func minute(of date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        contains(minute: Self.minute(of: date, calendar: calendar))
    }

    func contains(minute: Int) -> Bool {
        let m = Self.stored(minute)
        if from == to { return true }
        return from < to ? (m >= from && m < to) : (m >= from || m < to)
    }

    /// Every half hour of the day, the pop-ups' choices.
    static let choices: [Int] = Array(stride(from: 0, to: day, by: step))

    /// A minute of the day as the owner's clock writes it: "22:00", or "10:00 PM" in a 12-hour locale.
    static func label(_ minutes: Int, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: Date(timeIntervalSinceReferenceDate: TimeInterval(stored(minutes) * 60)))
    }

    /// A pop-up's choices around `value`: the half hours, and `value` in its place when it is off that grid (a time
    /// written into the defaults by hand), so the pop-up always names what is set.
    static func options(around value: Int, locale: Locale = .current) -> [(Int, String)] {
        let value = stored(value)
        let minutes = choices.contains(value) ? choices : (choices + [value]).sorted()
        return minutes.map { ($0, label($0, locale: locale)) }
    }
}

/// Settings › Island › Quiet (P330 to P333, P422, P423). Hide in full screen: while the frontmost app is in full screen
/// on the island's display (`FullScreenWatch`), the closed pill hides (with Show needs you, it shows only what needs you)
/// and nothing opens the island by itself. Quiet hours: no sounds, and nothing opens the island by itself; the pill still
/// shows "!", "?" and the rest. Quiet while locked: while the screen is locked or the owner's session switched out
/// (`ScreenLockWatch`), no sounds and nothing opens the island by itself; back, the island opens on what came meanwhile
/// (`LockCatchUp`). Either way a hover or a click opens it as ever, where the pill shows. Follow Focus is not built: macOS
/// exposes Focus to an app only through `INFocusStatusCenter`, which needs the restricted Communication Notifications
/// entitlement and a provisioning profile, which this app's signing has not (P333). Screen sharing and recording are not
/// heard either: no public macOS API tells an app that another one captures the screen (P424). A snooze (`Snooze`, P724)
/// quiets as Quiet hours do, until its end.
enum QuietMode {
    /// Quiet hours are on and `now` falls in them.
    @MainActor static func inQuietHours(_ settings: AppSettings, now: Date, calendar: Calendar = .current) -> Bool {
        settings.quietHours && QuietHours(from: settings.quietFrom, to: settings.quietTo).contains(now, calendar: calendar)
    }

    /// A snooze is set and has not ended at `now` (`Snooze`, P724).
    @MainActor static func snoozed(_ settings: AppSettings, now: Date) -> Bool {
        Snooze.isOn(settings.snoozedUntil, now: now)
    }

    /// Quiet while locked is on and the owner is away (`ScreenLockWatch.isAway`).
    @MainActor static func lockQuiets(_ settings: AppSettings, away: Bool) -> Bool {
        away && settings.quietWhileLocked
    }

    /// Nothing opens the island by itself: a card that needs you, a finish's Done card, a quota notice. `fullScreen`: the
    /// frontmost app is in full screen on the island's display; `away`: the screen is locked or the owner's session
    /// switched out. A snooze holds it too (P724).
    @MainActor static func holdsAttention(_ settings: AppSettings, fullScreen: Bool, away: Bool = false, now: Date,
                                          calendar: Calendar = .current) -> Bool {
        (fullScreen && settings.hideInFullScreen) || lockQuiets(settings, away: away) || inQuietHours(settings, now: now, calendar: calendar)
            || snoozed(settings, now: now)
    }

    /// One batch of signals as the island hears it.
    struct Batch: Equatable, Sendable {
        var signals: [IslandSignal]
        /// How a finish shows: the owner's choice, or Glance's dot while quiet.
        var finish: FinishBehaviour
        /// Something that needs you came while quiet: what waits is put away, so it stays on the pill and never opens
        /// the island by itself later, once quiet is over (P272, P331).
        var putsAway = false
    }

    /// While quiet, a needs-you signal opens nothing (the pill shows it), a finish lights Glance's dot instead of
    /// opening its Done card, and a stall's notice is dropped (its row says Stalled, P312); otherwise the batch is as it
    /// came.
    static func quieted(_ signals: [IslandSignal], finish: FinishBehaviour, quiet: Bool) -> Batch {
        guard quiet else { return Batch(signals: signals, finish: finish) }
        let kept = signals.filter { if case .finished = $0 { true } else { false } }
        let needsYou = signals.contains { if case .needsYou = $0 { true } else { false } }
        return Batch(signals: kept, finish: .glance, putsAway: needsYou)
    }
}
