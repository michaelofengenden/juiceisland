import SwiftUI
import WidgetKit

/// The sessions widget (spec §4.7), second in the gallery after the Usage widget (`JuiceIslandUsageWidget`), in the same
/// extension (`Widget/`, the Xcode target `JuiceIslandWidget`). It reads the App Group's snapshot and nothing else: no
/// socket, no engine, no network, no file outside the container. A timeline is the snapshot now, and the same snapshot
/// again at each used-up battery's refill, so it flips to "due" with no reload (P347); the app asks for a reload when
/// what it draws changes (`WidgetFeed`). Its kind is its own since wave A5: the app's first widget's kind is the Usage
/// widget's now, so one already on the desktop shows the batteries (P1220).
public struct JuiceIslandWidget: Widget {
    public static let kind = WidgetKind.sessions.rawValue

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: IslandWidgetProvider()) { entry in
            IslandWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Sessions")
        .description("What needs you, and what runs.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct IslandWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
    var scheme: String?

    /// What it stands on (P1401): the snapshot's choice, Glass with none.
    var background: WidgetBackgroundChoice { snapshot?.backgroundChoice ?? .glass }
}

struct IslandWidgetProvider: TimelineProvider {
    /// The widget's own bundle names the group and the scheme (`JIAppGroup`, `JIURLScheme`).
    private var identity: WidgetIdentity? { .main }

    func placeholder(in context: Context) -> IslandWidgetEntry {
        IslandWidgetEntry(date: Date(), snapshot: .preview(at: Date()), scheme: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (IslandWidgetEntry) -> Void) {
        let now = Date()
        // The gallery shows the real rows once the app wrote them, else the fictional preview.
        let snapshot = read() ?? (context.isPreview ? .preview(at: now) : nil)
        completion(IslandWidgetEntry(date: now, snapshot: snapshot, scheme: identity?.scheme))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<IslandWidgetEntry>) -> Void) {
        completion(Self.timeline(read(), scheme: identity?.scheme, now: Date()))
    }

    /// The entries for `snapshot`: now, then each refill still ahead. `.never`: only the app's reload brings the next.
    static func timeline(_ snapshot: WidgetSnapshot?, scheme: String?, now: Date) -> Timeline<IslandWidgetEntry> {
        let dates = [now] + (snapshot?.refills(after: now) ?? [])
        return Timeline(entries: dates.map { IslandWidgetEntry(date: $0, snapshot: snapshot, scheme: scheme) }, policy: .never)
    }

    private func read() -> WidgetSnapshot? {
        guard let identity else { return nil }
        return WidgetStore.appGroup(identity.appGroup)?.read()
    }
}

/// One entry in its family and the system's rendering, as the Usage widget's (P1224): full colour on the background the
/// owner chose (`WidgetBackdrop`, P1401), whatever the island's theme, its ink Glass look Widget's white twins and lifted
/// (`SessionsWidgetInk`); in the desktop's tinted, clear or vibrant looks the system takes that background away and the
/// view draws in one colour (P346, P542). A tap outside the rows (the small face: anywhere) opens the first row, or the
/// island (`WidgetLink.open`).
struct IslandWidgetEntryView: View {
    let entry: IslandWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        // The content's size, inside the margins the system gives this family where it shows.
        GeometryReader { proxy in
            IslandWidgetView(snapshot: entry.snapshot, face: Self.face(family), size: proxy.size, date: entry.date,
                             tinted: renderingMode != .fullColor, scheme: entry.scheme)
                .modifier(SessionsWidgetInk(fullColour: renderingMode == .fullColor))
        }
        // No environment of ours reaches the container background: WidgetKit draws it apart from the view (P1224), so the
        // choice comes from the snapshot the App Group holds (P1401).
        .containerBackground(for: .widget) { WidgetBackdrop(choice: entry.background) }
        .widgetURL(entry.scheme.flatMap { Self.tapLink(entry.snapshot, face: Self.face(family)).url(scheme: $0) })
    }

    static func face(_ family: WidgetFamily) -> WidgetFace {
        switch family {
        case .systemSmall: .small
        case .systemLarge, .systemExtraLarge: .large
        default: .medium
        }
    }

    /// Where a tap that hits no row goes: on the small face (one tap target) its first row, else the island.
    static func tapLink(_ snapshot: WidgetSnapshot?, face: WidgetFace) -> WidgetLink {
        guard face == .small, let snapshot, snapshot.appRunning, let first = snapshot.rows.first else { return .open }
        return .session(first.id)
    }
}

extension WidgetSnapshot {
    /// The gallery's preview and the placeholder: fictional sessions (spec §4.6), a request, a question, two runs, and
    /// batteries of every kind.
    static func preview(at date: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            written: date, appRunning: true,
            rows: [
                Row(id: "preview-approval", agent: "claude", kind: .needsYou, title: "Tidy the release notes", glyph: "bang",
                    word: "Needs approval", detail: "Bash"),
                Row(id: "preview-question", agent: "codex", kind: .needsYou, title: "Pick a chart", glyph: "ques",
                    word: "Question", detail: nil),
                Row(id: "preview-run-1", agent: "claude", kind: .running, title: "Name the app", glyph: "eq"),
                Row(id: "preview-run-2", agent: "codex", kind: .running, title: "Fix the flaky test", glyph: "eq"),
            ],
            more: 0,
            claude: [Battery(state: .available(left: 82, low: false), isNext: true), Battery(state: .available(left: 64, low: false), isNext: false),
                     Battery(state: .available(left: 11, low: true), isNext: false), Battery(state: .usedUp(refill: date.addingTimeInterval(4_500)), isNext: false),
                     Battery(state: .available(left: 97, low: false), isNext: false), Battery(state: .signIn, isNext: false)],
            codex: [Battery(state: .available(left: 71, low: false), isNext: true), Battery(state: .available(left: 45, low: false), isNext: false),
                    Battery(state: .stale(last: 30), isNext: false), Battery(state: .available(left: 100, low: false), isNext: false),
                    Battery(state: .signIn, isNext: false)],
            glyphStyle: GlyphStyle.pixel.rawValue, glyphColour: GlyphColourMode.byState.rawValue)
    }
}

/// The sessions widget's ink in full colour (P1224): the island's Glass look Widget, white twins on the dark look
/// whatever the island's theme, the glyphs at their full colour, lifted as the Usage widget's ink is (`UsageInkLift`).
/// The one-colour looks keep the view's own white (`tinted`) and draw no lift.
struct SessionsWidgetInk: ViewModifier {
    let fullColour: Bool

    func body(content: Content) -> some View {
        if fullColour {
            content
                .modifier(UsageInkLift(enabled: true))
                .environment(\.juiceTheme, .glass)
                .environment(\.colorScheme, .dark)
                .environment(\.glassWidgetInk, true)
        } else {
            content.environment(\.juiceTheme, .black)
        }
    }
}
