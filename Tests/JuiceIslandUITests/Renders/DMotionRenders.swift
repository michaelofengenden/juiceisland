import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The island's motion as frame strips (spec §9.5): `IslandRootView` drawn at explicit model times from
/// `IslandChoreography.replay`, set with no animation and with still glyphs (no live clock), on the board's wallpaper
/// and menu bar with the hardware notch drawn over the surface, each frame labelled with its time. The opened island's
/// layout comes from one offscreen measuring pass of the live view. Renders: `m-*.png`, one row per segment; Motion:
/// Refined and Hover: Quick as `m-refined-*.png` and `m-quick-hover.png`.
@MainActor
@Suite(.serialized)
struct DMotionRenders {
    typealias Model = IslandChoreography
    typealias Events = [(TimeInterval, Model.Event)]

    /// One row of a strip: a start, its events and the times drawn (each labelled from `zero`).
    struct Segment {
        var title: String
        var surface: Model.Surface = .closed
        var presentation: IslandPresentation = .list
        /// The pill it starts with: the sessions' own, or nothing (a first session arrives).
        var startsEmpty = false
        var events: Events
        var times: [TimeInterval]
        var zero: TimeInterval = 0
    }

    static let openTimes: [TimeInterval] = [0, 0.03, 0.06, 0.1, 0.15, 0.2, 0.26, 0.34, 0.6]

    // MARK: Strips

    @Test func open() throws {
        try strip("m-open", [Segment(title: "open: the pointer rests (swell), the dwell fires at 150",
                                     events: [(0, .swell(true)), (0.15, .open(.hover, .list))],
                                     times: [0.1] + Self.openTimes.map { 0.15 + $0 }, zero: 0.15)])
    }

    @Test func openLiquid() throws {
        try strip("m-open-liquid", [Segment(title: "open, Liquid with the edge line", events: [(0, .open(.hover, .list))],
                                            times: Self.openTimes)]) {
            $0.glyphStyle = .liquid
            $0.glyphEdgeLine = true
        }
    }

    @Test func close() throws {
        try strip("m-close", [Segment(title: "close: content out, the body folds (the pill's glyph back at the gate)", surface: .island,
                                      events: [(0, .close(.fold))],
                                      times: [0, 0.05, 0.1, 0.15, 0.2, 0.272, 0.33, 0.4, 0.46, 0.62])])
    }

    @Test func card() throws {
        try strip("m-card", Self.card(FixtureSessionFeed.ID.approval, "the approval"), card: FixtureSessionFeed.ID.approval)
    }

    @Test func cardRow4() throws {
        try strip("m-card-row4", Self.card(FixtureSessionFeed.ID.codexDone, "row 4"), card: FixtureSessionFeed.ID.codexDone)
    }

    static func card(_ id: String, _ name: String) -> [Segment] {
        let events: Events = [(0, .present(.card(sessionID: id))), (1, .present(.list))]
        return [Segment(title: "list → card (\(name))", surface: .island, events: events,
                        times: [0, 0.05, 0.103, 0.15, 0.2, 0.3]),
                Segment(title: "card → list", surface: .island, events: events,
                        times: [1, 1.05, 1.1, 1.15, 1.25, 1.4], zero: 1)]
    }

    @Test func arrive() throws {
        try strip("m-arrive", Self.arriveSegments, pill: true)
    }

    static var arriveSegments: [Segment] {
        [Segment(title: "a first session arrives", startsEmpty: true, events: [(0, .pill(.empty))],
                 times: [0, 0.04, 0.08, 0.12, 0.18, 0.26, 0.4]),
         Segment(title: "the last one departs", events: [(1, .pill(.empty))],
                 times: [1, 1.06, 1.12, 1.2, 1.3, 1.46], zero: 1)]
    }

    @Test func skim() throws {
        try strip("m-skim", [
            Segment(title: "a brush: in and out within 80 ms", events: [(0, .swell(true)), (0.08, .swell(false))],
                    times: [0, 0.04, 0.08, 0.15, 0.25, 0.4]),
            Segment(title: "a flick: the pointer leaves 90 ms after the open", events: [(0, .open(.hover, .list)), (0.09, .close(.abort))],
                    times: [0.06, 0.09, 0.15, 0.191, 0.26, 0.42]),
            Segment(title: "back 130 ms into the fold: it reverses in place", surface: .island,
                    events: [(0, .close(.fold)), (0.13, .open(.hover, .list))],
                    times: [0.1, 0.13, 0.2, 0.3, 0.4, 0.567]),
        ])
    }

    @Test func topBarOpen() throws {
        try strip("m-topbar-open", [Segment(title: "open, no notch: the top bar unfolds", events: [(0, .open(.hover, .list))],
                                            times: Self.openTimes)], notch: nil)
    }

    @Test func topBarArrive() throws {
        try strip("m-topbar-arrive", Self.arriveSegments, notch: nil, pill: true)
    }

    @Test func reduceOpen() throws {
        try strip("m-reduce-open", [Segment(title: "Reduce Motion: the pill fades, the outline snaps at 100, the island fades in",
                                            events: [(0, .open(.hover, .list))], times: [0, 0.05, 0.1, 0.12, 0.16, 0.22, 0.3, 0.45])],
                  reduceMotion: true)
    }

    @Test func reduceClose() throws {
        try strip("m-reduce-close", [Segment(title: "Reduce Motion: the island fades, the outline snaps once it has gone",
                                             surface: .island, events: [(0, .close(.fold))],
                                             times: [0, 0.06, 0.12, 0.18, 0.215, 0.26, 0.34, 0.45])],
                  reduceMotion: true)
    }

    // MARK: Motion: Refined and Hover: Quick (round A), beside the strips above

    static let refined = MotionTuning(motion: .refined, hover: .calm)

    @Test func refinedOpen() throws {
        try strip("m-refined-open", [Segment(title: "open, Refined: the parts come in behind the edge, no cap",
                                             events: [(0, .swell(true)), (0.15, .open(.hover, .list))],
                                             times: [0.1] + Self.openTimes.map { 0.15 + $0 }, zero: 0.15)], tuning: Self.refined)
    }

    @Test func refinedClose() throws {
        try strip("m-refined-close", [Segment(title: "close, Refined: height and width fold together, the glyph back sooner, and land",
                                              surface: .island, events: [(0, .close(.fold))],
                                              times: [0, 0.05, 0.1, 0.15, 0.2, 0.272, 0.33, 0.4, 0.46, 0.62])], tuning: Self.refined)
    }

    @Test func refinedCard() throws {
        try strip("m-refined-card", Self.card(FixtureSessionFeed.ID.approval, "the approval, Refined"), card: FixtureSessionFeed.ID.approval,
                  tuning: Self.refined)
    }

    @Test func quickHover() throws {
        try strip("m-quick-hover", [
            Segment(title: "Quick: the pill swells 5 pt a side, the dwell fires at 110 out of the swell", events: [(0, .swell(true)), (0.11, .open(.hover, .list))],
                    times: [0, 0.04, 0.08, 0.11, 0.14, 0.18, 0.24, 0.3, 0.4]),
            Segment(title: "Quick: a brush, in and out within 80 ms", events: [(0, .swell(true)), (0.08, .swell(false))],
                    times: [0, 0.04, 0.08, 0.15, 0.25, 0.4]),
        ], tuning: MotionTuning(motion: .refined, hover: .quick))
    }

    // MARK: The glyph clocks (round A's E2) beside the clocks before it

    @Test func glyphClocksLiquid() throws { try glyphClocks("m-glyph-clocks-liquid", style: .liquid) }

    @Test func glyphClocksSand() throws { try glyphClocks("m-glyph-clocks-sand", style: .sand) }

    /// An open and a close with every glyph drawn from a clock at its frame's time, the edge line on (the owner's
    /// setup): the clocks as they ran before round A (the pill's to 170 ms into an open, the island's from the open to
    /// the fit) over round A's (the pill held from the open's first frame, the island's from its first reveal, and held
    /// from the close's first frame). A clock that stops or starts where a glyph can be seen shows as a jump between
    /// neighbouring frames of a row.
    private func glyphClocks(_ name: String, style: GlyphStyle) throws {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .clean
        settings.islandUsagePlacement = .headerStrip
        settings.glyphStyle = style
        settings.glyphEdgeLine = true
        let env = AppEnvironment.demo(settings: settings, sessions: .prototype)
        let notch = IslandTheme.Metrics.referenceNotch, menuBar = IslandTheme.Metrics.referenceMenuBar
        let pill = PillContent.make(rows: env.sessions.rows, settings: settings, glance: false, recentlyFinished: nil,
                                    now: env.sessions.now, notch: notch, menuBar: menuBar)
        let layout = Self.measure(env: env, notch: notch, card: nil)
        let targets = SurfaceTargets(notch: notch, pill: pill)
        let base = Date(timeIntervalSinceReferenceDate: 780_000_000)
        let tile = CGSize(width: 500, height: 272)
        let open: Events = [(0, .open(.hover, .list))], close: Events = [(0, .close(.fold))]
        let openTimes: [TimeInterval] = [0, 0.017, 0.033, 0.05, 0.067, 0.1, 0.15, 0.2, 0.3]
        let closeTimes: [TimeInterval] = [0, 0.017, 0.033, 0.05, 0.067, 0.1, 0.15, 0.3, 0.4]
        typealias Clocks = (_ t: TimeInterval, _ roundA: (island: Bool, pill: Bool)) -> (island: Bool, pill: Bool)
        let rows: [(String, Model.Surface, Events, [TimeInterval], Clocks)] = [
            ("open, the clocks before round A: the pill's to 170 ms, the island's from the open", .closed, open, openTimes,
             { t, _ in (true, t < 0.17) }),
            ("open, round A: the pill held from the first frame, the island's from its first reveal", .closed, open, openTimes,
             { _, a in a }),
            ("close, the clocks before round A: the island's to the fit", .island, close, closeTimes, { _, a in (true, a.pill) }),
            ("close, round A: the island held from the first frame", .island, close, closeTimes, { _, a in a }),
        ]
        var drawn: [(String, [(String, IslandUIState, GlyphClock)])] = []
        for (title, surface, events, times, clocks) in rows {
            let start = Model(metrics: .init(targets: targets, layout: layout), surface: surface)
            var frames: [(String, IslandUIState, GlyphClock)] = []
            for t in times {
                var live = (island: start.isOpen, pill: !start.isOpen)
                let scenario = DIslandPanelSizingTests.Scenario(name: title, start: start, events: events)
                DIslandPanelSizingTests.play(scenario, until: t) { _, _, commands in
                    for command in commands {
                        if case let .effect(.islandLive(on)) = command { live.island = on }
                        if case let .effect(.pillLive(on)) = command { live.pill = on }
                    }
                }
                let (model, _) = Model.replay(start, events, until: t)
                let ui = IslandUIState()
                IslandMotionDirector.snap(ui, to: model, at: t)
                ui.presentation = model.presentation
                ui.holdsGlyphs = true
                (ui.islandLive, ui.pillLive) = clocks(t, live)
                frames.append(("\(Int((t * 1000).rounded())) ms", ui, GlyphClock(date: base + t, start: base)))
            }
            drawn.append((title, frames))
        }
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(drawn.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.0).font(Fonts.sys(11)).foregroundStyle(IslandTheme.ink2)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(row.1.enumerated()), id: \.offset) { _, frame in
                            VStack(alignment: .leading, spacing: 4) {
                                Self.frame(frame.1, notch: notch, menuBar: menuBar, size: tile).environment(\.glyphClock, frame.2)
                                Text(frame.0).font(Fonts.mono(10)).foregroundStyle(IslandTheme.ink3)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(hex: 0x0B0D0D))
        try RenderHarness.render(view, name, env: env)
    }

    // MARK: Drawing

    /// Draws `segments` as rows of frames into `name`: the prototype's sessions in Clean, Header strip placement,
    /// Pixel unless `configure` says otherwise.
    private func strip(_ name: String, _ segments: [Segment], notch: CGSize? = IslandTheme.Metrics.referenceNotch,
                       pill: Bool = false, card: String? = nil, reduceMotion: Bool = false, tuning: MotionTuning = MotionTuning(),
                       settings configure: (AppSettings) -> Void = { _ in }) throws {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .clean
        settings.islandUsagePlacement = .headerStrip
        settings.glyphStyle = .pixel
        configure(settings)
        let env = AppEnvironment.demo(settings: settings, sessions: .prototype)
        let menuBar: CGFloat = notch == nil ? IslandTheme.Metrics.topBarFallbackHeight : IslandTheme.Metrics.referenceMenuBar
        let content = PillContent.make(rows: env.sessions.rows, settings: settings, glance: false, recentlyFinished: nil,
                                       now: env.sessions.now, notch: notch, menuBar: menuBar)
        let empty = PillContent.make(lead: nil, count: nil, glance: false, style: settings.glyphStyle, edgeLine: settings.glyphEdgeLine,
                                     notch: notch, menuBar: menuBar)
        let layout = Self.measure(env: env, notch: notch, card: card)
        let tile = pill ? CGSize(width: 360, height: 64) : CGSize(width: 500, height: 272)
        var rows: [(String, [(String, IslandUIState)])] = []
        for segment in segments {
            let targets = SurfaceTargets(notch: notch, pill: segment.startsEmpty ? empty : content)
            let start = Model(metrics: .init(targets: targets, layout: layout, reduceMotion: reduceMotion, tuning: tuning),
                              surface: segment.surface, presentation: segment.presentation)
            // `.pill(.empty)` in a segment stands for "the pill it does not start with".
            let events = segment.events.map { time, event -> (TimeInterval, Model.Event) in
                guard case let .pill(p) = event, p == .empty else { return (time, event) }
                return (time, .pill(segment.startsEmpty ? content : empty))
            }
            var frames: [(String, IslandUIState)] = []
            for t in segment.times {
                let (model, _) = Model.replay(start, events, until: t)
                let ui = IslandUIState()
                IslandMotionDirector.snap(ui, to: model, at: t)
                ui.presentation = model.presentation
                ui.card = model.cardMounted.flatMap { env.sessions.card(for: $0) }
                ui.islandLive = false
                ui.pillLive = false
                frames.append(("\(Int(((t - segment.zero) * 1000).rounded())) ms", ui))
            }
            rows.append((segment.title, frames))
        }
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.0).font(Fonts.sys(11)).foregroundStyle(IslandTheme.ink2)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(row.1.enumerated()), id: \.offset) { _, frame in
                            VStack(alignment: .leading, spacing: 4) {
                                Self.frame(frame.1, notch: notch, menuBar: menuBar, size: tile)
                                Text(frame.0).font(Fonts.mono(10)).foregroundStyle(IslandTheme.ink3)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(hex: 0x0B0D0D))
        try RenderHarness.render(view, name, env: env)
    }

    /// One frame: the wallpaper, the menu bar, the island's canvas centred on the notch and the notch over it.
    static func frame(_ ui: IslandUIState, notch: CGSize?, menuBar: CGFloat, size: CGSize) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(stops: [.init(color: Color(hex: 0x161E1D), location: 0), .init(color: Color(hex: 0x1D2824), location: 0.4),
                                   .init(color: Color(hex: 0x2A3932), location: 1)], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(Color(red: 10 / 255, green: 14 / 255, blue: 13 / 255).opacity(0.28)).frame(height: menuBar)
            IslandRootView(ui: ui, notch: notch, canvas: CGSize(width: IslandPanelSizing.canvasWidth, height: size.height),
                           actions: IslandViewActions(), pillClicked: {}, measured: { _ in })
            if let notch { DScene.hardwareNotch(notch) }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// The live island's layout, measured once offscreen (a hosting view in a window that is never ordered in), with
    /// `card`'s card mounted when given.
    static func measure(env: AppEnvironment, notch: CGSize?, card: String?, island: IslandSize = .standard) -> ContentLayout {
        _ = NSApplication.shared
        let ui = IslandUIState()
        ui.isOpen = true
        ui.card = card.flatMap { env.sessions.card(for: $0) }
        ui.islandLive = false
        let targets = SurfaceTargets(notch: notch, pill: .empty, islandWidth: island.outer)
        let director = IslandMotionDirector(model: Model(metrics: .init(targets: targets)), ui: ui)
        let size = CGSize(width: island.canvasWidth, height: 700)
        let root = IslandRootView(ui: ui, notch: notch, canvas: size, size: island, actions: IslandViewActions(), pillClicked: {},
                                  measured: { [director] in director.measured($0) })
        let hosting = NSHostingView(rootView: AnyView(root.environment(env).environment(\.colorScheme, .dark)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        // A test runs inside the main queue, so the director's next-turn flush cannot run here: flush at once.
        director.flushMeasurements()
        window.contentView = nil
        return director.model.layout
    }
}
