import JuiceCore
import SwiftUI
import WidgetKit

/// The Usage widget (spec §4.7, wave A5): the desktop panel's content in WidgetKit, first in the gallery, and the
/// panel's replacement on the desktop (the owner's "we should replace the panel with widget version of Juice Island" of
/// 2026-10-05). Each provider's mark and its accounts' batteries as the panel draws them, a number or a countdown, the
/// account in use with its dot and the next one with its bar, then the money rows; never a session. It keeps the kind
/// the app's only widget had (`WidgetKind.usage`), so a widget already on the desktop becomes this one (P1220).
public struct JuiceIslandUsageWidget: Widget {
    public static let kind = WidgetKind.usage.rawValue

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UsageWidgetProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Usage")
        .description("What is left in each account, and your money.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct UsageWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?

    /// What it stands on (P1401): the snapshot's choice, Glass with none.
    var background: WidgetBackgroundChoice { snapshot?.backgroundChoice ?? .glass }
}

/// The Usage widget's timeline (P1222, P1223): the snapshot now, then the moments its picture changes by the clock alone,
/// so nothing reloads for them: each used-up battery's countdown changing its shape (`Countdown.boundaries`; between
/// them WidgetKit's own timer text ticks) and its refill, and the moment the snapshot goes stale. WidgetKit is asked for
/// a new timeline a little before that moment, when the app, if it runs, has written the file again
/// (`UsageFreshness`).
struct UsageWidgetProvider: TimelineProvider {
    private var identity: WidgetIdentity? { .main }

    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(date: Date(), snapshot: .usagePreview(at: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (UsageWidgetEntry) -> Void) {
        let now = Date()
        let snapshot = read() ?? (context.isPreview ? .usagePreview(at: now) : nil)
        completion(UsageWidgetEntry(date: now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<UsageWidgetEntry>) -> Void) {
        completion(Self.timeline(read(), now: Date()))
    }

    static func timeline(_ snapshot: WidgetSnapshot?, now: Date) -> Timeline<UsageWidgetEntry> {
        guard let snapshot, snapshot.appRunning else {
            return Timeline(entries: [UsageWidgetEntry(date: now, snapshot: snapshot)], policy: .never)
        }
        var dates = Set([now])
        for battery in snapshot.claude + snapshot.codex {
            guard case let .usedUp(refill?) = battery.state else { continue }
            dates.formUnion(Countdown.boundaries(refill: refill).filter { $0 > now })
        }
        let stale = UsageFreshness.staleAt(snapshot)
        if stale > now { dates.insert(stale) }
        // Past the moment it goes stale nothing changes but the countdowns, which stale batteries no longer show.
        let entries = dates.filter { $0 <= max(now, stale) }.sorted().map { UsageWidgetEntry(date: $0, snapshot: snapshot) }
        // A file past the hour while the app runs: a reload WidgetKit refused or put off, or a Mac that slept before the
        // app wrote again. Asked again a heartbeat on, never `.never`, so the app's next write is read (P1282).
        let reload = UsageFreshness.reloadAt(snapshot)
        return Timeline(entries: entries, policy: .after(reload > now ? reload : now.addingTimeInterval(UsageFreshness.heartbeat)))
    }

    private func read() -> WidgetSnapshot? {
        guard let identity else { return nil }
        return WidgetStore.appGroup(identity.appGroup)?.read()
    }
}

/// How long the Usage widget shows a snapshot as live (P1223). The readings' own rule (Juice: a Claude reading is stale
/// after 20 minutes, a Codex one after 2) is the app's: while it runs, a battery that goes stale changes its kind and the
/// widget reloads at once. What the app cannot say is that it stopped (a crash, a hang): the widget learns nothing
/// without a reload, and WidgetKit gives a widget some 40 to 70 a day. So the app writes the file again at least every
/// ten minutes while it runs (`heartbeat`, no reload), WidgetKit is asked for a new timeline an hour after the last
/// write, and five minutes later, if that brought nothing newer, the widget says "Not updated" and draws every battery
/// as not read lately, its number gone: old numbers never pass as live. WidgetKit can refuse or put off that request, so
/// the app also reloads the widget itself once its last reload is `appReloadAfter` old (ahead of the widget's own, which
/// a granted reload replaces), and a timeline read from a file past the hour asks again a heartbeat on (P1282).
enum UsageFreshness {
    static let staleAfter: TimeInterval = 3_600
    static let grace: TimeInterval = 300
    static let heartbeat: TimeInterval = 600
    /// The app's own freshness reload: 50 minutes after the last, so about 29 a day while nothing else reloads.
    static let appReloadAfter: TimeInterval = staleAfter - heartbeat
    /// The word the widget says when it is stale.
    static let word = "Not updated"

    static func reloadAt(_ snapshot: WidgetSnapshot) -> Date { snapshot.written.addingTimeInterval(staleAfter) }
    static func staleAt(_ snapshot: WidgetSnapshot) -> Date { snapshot.written.addingTimeInterval(staleAfter + grace) }
    static func isStale(_ snapshot: WidgetSnapshot, at date: Date) -> Bool { snapshot.appRunning && date >= staleAt(snapshot) }
}

/// A used-up battery's countdown in the widget (P1225): the panel's own label (`Formatting.refillLabel`: `45m`, `2:04`,
/// `1d`, `Fri`), ticking by itself between timeline entries. WidgetKit's timer text counts in seconds (`2:04:33`,
/// `45:12`), which the 42 pt battery cannot hold and the panel never shows; so where the label ticks, the timer is drawn
/// whole and clipped to its leading hours and minutes (`prefix`, a template of the part that shows, in tabular digits),
/// and `m` follows under an hour. The shape of the label changes only at the boundaries the timeline adds an entry at.
enum Countdown: Equatable, Sendable {
    /// A label that holds until the next boundary: `due`, `1m`, `1d`, a weekday, `?`.
    case fixed(String)
    /// The timer to `refill`, clipped to `prefix`'s width, then `suffix`.
    case ticking(refill: Date, prefix: String, suffix: String)

    /// Where the label's shape changes: a second past each threshold, so the timer on either side of it is whole, and
    /// the refill itself.
    static let thresholds: [TimeInterval] = [172_800, 86_400, 36_000, 3_600, 600, 60]

    static func boundaries(refill: Date) -> [Date] {
        thresholds.map { refill.addingTimeInterval(-$0 + 1) } + [refill]
    }

    static func at(_ date: Date, refill: Date?) -> Countdown {
        guard let refill else { return .fixed("?") }
        let remaining = refill.timeIntervalSince(date)
        switch remaining {
        case ...0: return .fixed("due")
        case ..<60: return .fixed("1m")
        case ..<600: return .ticking(refill: refill, prefix: "0", suffix: "m")
        case ..<3_600: return .ticking(refill: refill, prefix: "00", suffix: "m")
        case ..<36_000: return .ticking(refill: refill, prefix: "0:00", suffix: "")
        case ..<86_400: return .ticking(refill: refill, prefix: "00:00", suffix: "")
        default: return .fixed(Formatting.refillLabel(refill, now: date))
        }
    }

    /// The label as it reads at `date`, as the panel would draw it (renders, which cannot run a timer).
    func text(at date: Date) -> String {
        switch self {
        case let .fixed(label): label
        case let .ticking(refill, _, _): Formatting.refillLabel(refill, now: date)
        }
    }
}

/// One Usage entry in its family and the system's rendering: full colour on the background the owner chose
/// (`WidgetBackdrop`: Glass, the system's material, or Black), its ink white and lifted as the desktop's labels are; in the
/// dimmed desktop's accented or vibrant rendering the system takes that background away and lays its own glass, and the
/// widget draws in white alone, its fills accentable (P1224, P1401). A tap opens the app.
struct UsageWidgetEntryView: View {
    let entry: UsageWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        GeometryReader { proxy in
            UsageWidgetView(snapshot: entry.snapshot, face: IslandWidgetEntryView.face(family), size: proxy.size, date: entry.date,
                            mono: renderingMode != .fullColor, live: true)
        }
        // No environment of ours reaches the container background: WidgetKit draws it apart from the view (P1224), so the
        // choice comes from the snapshot the App Group holds (P1401).
        .containerBackground(for: .widget) { WidgetBackdrop(choice: entry.background) }
        .widgetURL(WidgetIdentity.main.flatMap { WidgetLink.open.url(scheme: $0.scheme) })
    }
}

extension WidgetSnapshot {
    /// The gallery's preview and the placeholder: fictional accounts (spec §4.6) of every kind, one in use, and money.
    static func usagePreview(at date: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            written: date, appRunning: true, rows: [], more: 0,
            claude: [Battery(state: .available(left: 83, low: false), isNext: true, inUse: true),
                     Battery(state: .usedUp(refill: date.addingTimeInterval(7_440)), isNext: false),
                     Battery(state: .available(left: 100, low: false), isNext: false)],
            codex: [Battery(state: .available(left: 99, low: false), isNext: true, inUse: true),
                    Battery(state: .available(left: 64, low: false), isNext: false),
                    Battery(state: .available(left: 11, low: true), isNext: false),
                    Battery(state: .available(left: 100, low: false), isNext: false)],
            glyphStyle: GlyphStyle.pixel.rawValue, glyphColour: GlyphColourMode.byState.rawValue,
            money: [Money(id: "OpenRouter", name: "OpenRouter", amount: "$412.80"),
                    Money(id: "OpenAI", name: "OpenAI", amount: "$38.20", isSpent: true),
                    Money(id: "RunPod", name: "RunPod", amount: "$0.00", suffix: "0h", emphasis: .attention)])
    }
}
