import AppKit
import Darwin
import Foundation
import IslandEngine
import OpenIslandCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// What each frame of the island's motion costs the main thread, measured headless (P102): the real `IslandRootView` on
/// a real `IslandMotionDirector`, in an `NSHostingView` at the canvas's size in a borderless panel-sized window that is
/// never ordered on screen, snapped to each extent the choreography asks for as the live panel is; and the Window
/// mode's `WindowRootView` in a window-sized one. Every transition plays on the real clock (open, close, list → card,
/// card → list, the usage strip, the swell, and list updates: a row inserted at the top, reordered, pushed out, a
/// glyph's mood changing), and a run-loop observer times each turn of the main thread from its wake to the Core
/// Animation commit: its CPU time (the thread's own, so other work on the Mac does not count), the SwiftUI layout passes
/// in it and the island's measurements it reported. A turn that laid the view out is a frame; one over `hitch` (8.3 ms,
/// a frame at 120 Hz) is a hitch.
///
/// The test is async and waits with `Task.sleep`, so the main run loop turns on its own and the main actor runs what
/// the app runs on it: the director's timer for the choreography's next step, the measurements it gathers, the
/// sessions model's publish. (Spinning the run loop inside the test would hold the main actor: none of those would run,
/// and the island would open with no rows to reveal.) A window that is not on a display has no display link, so SwiftUI
/// steps its animations as fast as the run loop turns: the frames here are more and closer than a display's, and the
/// cost of each one is what counts. The glyphs draw from a `GlyphClock` ticked at their own rate (30 a second), or
/// stand still (`JI_MEASURE_GLYPHS=0`). Skipped unless `JI_MEASURE_FRAMES=1`; `JI_MEASURE_OUT` names a Markdown file
/// for the table, `JI_MEASURE_RUNS` how many times each transition plays (5), `JI_MEASURE_MAXHEIGHT=none` draws the
/// list with no height to keep to (so outside its scroll view, as renders do), `JI_MEASURE_ONLY` keeps the transitions
/// whose name contains it, `JI_MEASURE_THEME=glass` (or `smoke`) draws the island in Glass (or Smoke), `JI_MEASURE_TINT=1`
/// with State tint and `JI_MEASURE_FROST=<0 to 1>` with Glass's Frost:
///   JI_MEASURE_FRAMES=1 swift test -c release -Xswiftc -enable-testing --filter IslandFrameMeasurements
/// `JI_MEASURE_LOOP=<seconds>` instead plays open, a card, the list and close over and over (`JI_MEASURE_LOOP_CARD=1`:
/// list ⇄ card; `JI_MEASURE_LOOP_ATTENTION=1`: open to a card and close; `JI_MEASURE_LOOP_OPEN=1`: the open island at
/// rest) for a profiler such as `sample`.
@MainActor
@Suite(.serialized, .enabled(if: FramePerf.enabled))
struct IslandFrameMeasurements {
    @Test func everyTransition() async throws {
        _ = NSApplication.shared
        if let seconds = FramePerf.environment["JI_MEASURE_LOOP"].flatMap(Double.init) {
            await FramePerf.loop(seconds)
            return
        }
        var results: [FramePerf.Result] = []
        for style in [IslandStyle.clean, .detailed] {
            results += await FramePerf.islandTransitions(style: style)
        }
        results += await FramePerf.hover()
        results += await FramePerf.windowTransitions()
        let table = FramePerf.table(results)
        print(table)
        if let out = FramePerf.environment["JI_MEASURE_OUT"] {
            try table.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}

extension IslandFrameMeasurements {
    /// What a trigger's turn is made of (`JI_MEASURE_TURNS=1`): the model's handling of the event, the outline's play
    /// (Core Animation's plan and its layers), the director's send in all (the model, the writes, the panel's snaps, the
    /// play) and the whole turn to its first frame (SwiftUI's update and commit too), thread CPU, median of
    /// `JI_MEASURE_RUNS`, for each outline and feel. `JI_MEASURE_ONLY` keeps the triggers whose name contains one of its
    /// `|`-separated parts, `JI_MEASURE_OUTLINE=ca` (or `swiftui`) one outline, `JI_MEASURE_MOTION=refined|liquid` those feels.
    @Test func triggerTurns() async throws {
        guard FramePerf.environment["JI_MEASURE_TURNS"] == "1" else { return }
        _ = NSApplication.shared
        typealias Rig = FramePerf.IslandRig
        let card = FixtureSessionFeed.ID.approval
        let every: [(String, @MainActor (Rig) async -> Void, TimeInterval, IslandChoreography.Event, IslandPresentation?)] = [
            ("open", { _ in }, 0, .open(.hover, .list), .list),
            ("reversing open", { rig in rig.open(); await FramePerf.wait(0.8); rig.director.send(.close(.fold)) }, 0.13, .open(.hover, .list), .list),
            ("close", { rig in rig.open() }, 0.8, .close(.fold), nil),
            ("list → card", { rig in rig.open() }, 0.8, .present(.card(sessionID: card)), .card(sessionID: card)),
            // Motion: Liquid's merge back: the card at rest in its bud goes back into the list.
            ("card → list", { rig in rig.open(); await FramePerf.wait(0.8); rig.present(.card(sessionID: card)) }, 1.0, .present(.list), .list),
        ]
        let only = FramePerf.environment["JI_MEASURE_ONLY"]?.split(separator: "|").map(String.init)
        let triggers = every.filter { trigger in only.map { $0.contains { trigger.0.contains($0) } } ?? true }
        var lines = ["| Outline · Motion · trigger | Model | Plan | Layers | Send | Turn |", "|---|---:|---:|---:|---:|---:|"]
        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        let outlines: [IslandOutline] = switch FramePerf.environment["JI_MEASURE_OUTLINE"] {
        case "ca": [.coreAnimation]
        case "swiftui": [.swiftUI]
        default: [.swiftUI, .coreAnimation]
        }
        for outline in outlines {
            for tuning in [MotionTuning(), MotionTuning(motion: .refined, hover: .quick), MotionTuning(motion: .liquid, hover: .quick)]
                where FramePerf.environment["JI_MEASURE_MOTION"].map({ $0.split(separator: "|").contains(Substring("\(tuning.motion)")) }) ?? true {
                for (name, setUp, delay, event, presentation) in triggers {
                    var model: [Double] = [], plan: [Double] = [], layers: [Double] = [], send: [Double] = [], turn: [Double] = []
                    for _ in 0..<FramePerf.runs {
                        let rig = Rig(style: .clean, glyphsMove: false, outline: outline, tuning: tuning)
                        await rig.start()
                        await setUp(rig)
                        await FramePerf.wait(delay)
                        var mark: UInt64 = 0
                        FramePerf.inTurn {
                            mark = FramePerf.wallNanos()
                            var copy = rig.director.model
                            let t = IslandMotionDirector.now
                            model.append(Double(FramePerf.cpuTime { _ = copy.advance(to: t); _ = copy.handle(event, at: t) }.components.attoseconds) / 1e15)
                            if let presentation { rig.ui.presentation = presentation }
                            send.append(Double(FramePerf.cpuTime { rig.director.send(event) }.components.attoseconds) / 1e15)
                            let cpu = rig.canvas.layers.lastPlayCPU
                            plan.append(cpu.plan)
                            layers.append(cpu.install)
                        }
                        await FramePerf.wait(0.5)
                        if let at = rig.probe.turns.firstIndex(where: { $0.wall <= mark && $0.end >= mark }) {
                            let drawn = rig.probe.turns[at...].firstIndex(where: { $0.layouts > 0 && $0.cpuMS > 1 }) ?? at
                            turn.append(rig.probe.turns[at...drawn].map(\.cpuMS).reduce(0, +))
                        }
                        rig.stop()
                    }
                    let tag = "\(outline == .coreAnimation ? "CA" : "SwiftUI") · \(tuning.motion) · \(name)"
                    lines.append("| \(tag) | " + [model, plan, layers, send, turn].map { String(format: "%.2f", median($0)) }.joined(separator: " | ") + " |")
                }
            }
        }
        let table = lines.joined(separator: "\n") + "\n"
        print(table)
        if let out = FramePerf.environment["JI_MEASURE_OUT"] { try table.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}

@MainActor
enum FramePerf {
    nonisolated static var environment: [String: String] { ProcessInfo.processInfo.environment }
    nonisolated static var enabled: Bool { environment["JI_MEASURE_FRAMES"] == "1" }
    static var runs: Int { environment["JI_MEASURE_RUNS"].flatMap(Int.init) ?? 5 }
    static var glyphsMove: Bool { environment["JI_MEASURE_GLYPHS"] != "0" }
    static var dumps: Bool { environment["JI_MEASURE_DUMP"] == "1" }
    /// One frame at 120 Hz.
    nonisolated static let hitch: Double = 1000.0 / 120
    /// The outline the island's transitions are measured on: `JI_MEASURE_OUTLINE=ca` for Core Animation's (the app's
    /// default), SwiftUI's otherwise (round A's and B's tables).
    static var outline: IslandOutline { environment["JI_MEASURE_OUTLINE"] == "ca" ? .coreAnimation : .swiftUI }
    /// The feel they play: `JI_MEASURE_MOTION=refined` for Motion: Refined and Hover: Quick (the app's defaults),
    /// `liquid` for Motion: Liquid and Hover: Quick, Original and Calm otherwise.
    static var tuning: MotionTuning {
        switch environment["JI_MEASURE_MOTION"] {
        case "refined": MotionTuning(motion: .refined, hover: .quick)
        case "liquid": MotionTuning(motion: .liquid, hover: .quick)
        default: MotionTuning()
        }
    }
    /// The theme the island draws in: `JI_MEASURE_THEME=glass` for Glass, `smoke` for Smoke (their live glass, which
    /// headless the window server never composites: the app's side of its cost only), Black otherwise.
    static var theme: JuiceTheme { environment["JI_MEASURE_THEME"].flatMap(JuiceTheme.init(rawValue:)) ?? .black }
    /// The Glyph style the island's rig draws: `JI_MEASURE_GLYPH=liquid` or `sand`, Pixel otherwise.
    static var glyph: GlyphStyle { environment["JI_MEASURE_GLYPH"].flatMap(GlyphStyle.init(rawValue:)) ?? .pixel }
    /// Settings › Island › State tint on (`JI_MEASURE_TINT=1`: Black's edge, Glass's veil), as the app's default; off
    /// otherwise, as every table before it.
    static var stateTint: Bool { environment["JI_MEASURE_TINT"] == "1" }
    /// Glass's Frost (`JI_MEASURE_FROST=<0 to 1>`); 0 otherwise.
    static var frost: Double { environment["JI_MEASURE_FROST"].flatMap(Double.init).map(GlassFrost.stored) ?? 0 }

    nonisolated static func threadNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
    nonisolated static func wallNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// The calling thread's CPU time for `body`: what a budget test's work costs, whatever else the machine runs (other
    /// suites, other builds), which a wall clock counts too.
    nonisolated static func cpuTime(_ body: () -> Void) -> Duration {
        let start = threadNanos()
        body()
        return .nanoseconds(Int64(threadNanos() - start))
    }

    /// Lets the main run loop turn for `seconds`, the main actor free.
    /// The moment every rig's held glyphs draw (`Rig.clock`).
    static let heldMoment = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Lays `rig`'s window out and commits its layers now, as a display frame would: a window never on screen gets no
    /// display frame, and under a full run's load the main run loop commits only between long drains of the main queue.
    static func frame(_ rig: Rig) {
        rig.window.contentView?.layoutSubtreeIfNeeded()
        CATransaction.flush()
    }

    /// Waits until `settled`, a frame (`frame`) before each look, for `limit` seconds' worth of looks 50 ms apart
    /// (`Looks`): a set wait on the clock ended, under load, with the motion or the layout it waited for not yet run,
    /// and a wall-clock limit with few looks taken (P1258).
    @discardableResult
    static func settle(_ rig: Rig, limit: TimeInterval = 30, _ settled: () -> Bool) async -> Bool {
        await Looks.until(limit, every: 0.05) {
            frame(rig)
            return settled()
        }
    }

    /// Waits until the rig's island is at rest: no job left in its model (`IslandChoreography.inMotion`).
    @discardableResult
    static func rest(_ rig: IslandRig, limit: TimeInterval = 30) async -> Bool {
        await settle(rig, limit: limit) { !rig.director.model.inMotion }
    }

    /// Runs `body` in a turn of the main run loop of its own, as an event would arrive.
    static func inTurn(_ body: @escaping @MainActor () -> Void) {
        RunLoop.main.perform { MainActor.assumeIsolated { body() } }
    }

    /// When a transition's later event ran (uptime, ns): the turn it ran in is its "marked" turn (a reversing open's).
    static var marks: [UInt64] = []

    /// Runs `body` in a turn of its own after `seconds`, marking that turn.
    static func later(_ seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            inTurn {
                marks.append(wallNanos())
                body()
            }
        }
    }

    // MARK: Probe

    /// A hosting view that counts its layout passes.
    final class Host: NSHostingView<AnyView> {
        var layouts = 0
        override func layout() {
            super.layout()
            layouts += 1
        }
    }

    /// Times each turn of the main run loop: from its wake (or entry) to the end of its work (after Core Animation's
    /// commit, which runs before it waits).
    @MainActor
    final class Probe {
        struct Turn {
            /// When it began and ended (uptime, ns).
            var wall: UInt64
            var end: UInt64
            var cpu: UInt64
            var layouts: Int
            var reports: Int
            var cpuMS: Double { Double(cpu) / 1e6 }
        }

        private(set) var turns: [Turn] = []
        var reports = 0
        let host: Host
        private var observers: [CFRunLoopObserver] = []
        private var begun: (wall: UInt64, cpu: UInt64, layouts: Int, reports: Int)?

        init(host: Host) {
            self.host = host
            let begin = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.entry, .afterWaiting]).rawValue, true, CFIndex.min) {
                [unowned self] _, _ in MainActor.assumeIsolated { self.begin() }
            }
            let end = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.beforeWaiting, .exit]).rawValue, true, CFIndex.max) {
                [unowned self] _, _ in MainActor.assumeIsolated { self.end() }
            }
            for observer in [begin, end].compactMap({ $0 }) {
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                observers.append(observer)
            }
        }

        private func begin() {
            guard begun == nil else { return }
            begun = (FramePerf.wallNanos(), FramePerf.threadNanos(), host.layouts, reports)
        }

        private func end() {
            guard let begun else { return }
            self.begun = nil
            turns.append(Turn(wall: begun.wall, end: FramePerf.wallNanos(), cpu: FramePerf.threadNanos() &- begun.cpu,
                              layouts: host.layouts - begun.layouts, reports: reports - begun.reports))
        }

        func clear() { turns = [] }

        func stop() {
            for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observers = []
        }
    }

    // MARK: Rigs

    /// A surface under measurement: its sessions, its hosting view and probe, and the glyph clock it draws from.
    @MainActor
    class Rig {
        let env: AppEnvironment
        let feed: FixtureSessionFeed
        let host: Host
        let window: NSWindow
        let probe: Probe
        /// Held glyphs and edge lines draw its `start`, one moment for every rig: the moment a rig was made put Liquid's
        /// edge line anywhere in its flow, so what a held line covered changed from run to run (P1259). Moving glyphs
        /// draw `date`, which the rig's timer keeps at now.
        let clock = GlyphClock(date: FramePerf.heldMoment)
        /// False holds the glyphs still (`SurfaceMotion(.hidden)`), for a check that runs beside the suites counting
        /// glyph frames (`GlyphFrames`).
        var glyphsMove = FramePerf.glyphsMove
        private var timer: Timer?

        /// `prepare`: more sessions fed to the engine before anything reads it (a scene the scenarios have not got).
        /// `sessionsClock`: the sessions' clock (the wall clock unless a test pins it: each minute's turn redraws the rows,
        /// and the island with them, P1261).
        init(style: IslandStyle, glyph: GlyphStyle, placement: UsagePlacement, scenario: FixtureSessionFeed.Scenario,
             events: [AgentEvent], size: CGSize, host: Host? = nil, sessionsClock: @escaping @MainActor () -> Date = { Date() },
             prepare: (FixtureSessionFeed) -> Void = { _ in }) {
            let settings = AppSettings.ephemeral()
            settings.islandStyle = style
            settings.glyphStyle = glyph
            settings.islandUsagePlacement = placement
            let feed = FixtureSessionFeed(scenario: scenario, now: Date())
            feed.engine.loadPreviewEvents(events)
            prepare(feed)
            self.feed = feed
            env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: Date()),
                                 sessions: EngineSessionsModel(engine: feed.engine, clock: sessionsClock))
            self.host = host ?? Host(rootView: AnyView(EmptyView()))
            window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            probe = Probe(host: self.host)
        }

        /// The surface's clock starts (when the glyphs move) and it settles.
        func start() async {
            if glyphsMove {
                let clock = clock
                timer = Timer.scheduledTimer(withTimeInterval: PixelGlyph.motionInterval, repeats: true) { _ in
                    MainActor.assumeIsolated { clock.date = Date() }
                }
            }
            await FramePerf.wait(0.6)
        }

        func stop() {
            timer?.invalidate()
            probe.stop()
            host.rootView = AnyView(EmptyView())
            window.contentView = nil
            window.close()
        }

        var rowIDs: [String] { env.sessions.rows.map(\.id) }
    }

    /// The live island: the root view, the director, and a window standing in for its panel, snapped to each extent as
    /// the panel is.
    @MainActor
    final class IslandRig: Rig {
        let ui = IslandUIState()
        let director: IslandMotionDirector
        var panelSnaps = 0
        /// The canvas's views as the panel's (`IslandCanvas`): with Core Animation's outline, the black, the masked
        /// content and the edge line's carrier.
        let canvas: IslandCanvas
        /// This island's own outline work (`OutlineProbe`).
        let outlines = OutlineProbe()
        /// Each snap, after the canvas checked its layers (`IslandCanvas.ensure`): whether they were sound.
        var afterSnap: ((IslandExtent, Bool) -> Void)?

        static let notch = IslandTheme.Metrics.referenceNotch
        /// A 14-inch display: 1512 × 982 points.
        static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        /// The tallest the island may be on it, with no Dock at the bottom.
        static let maxHeight = IslandPanelSizing.maxIslandHeight(IslandScreen(id: "perf", frame: screen, safeAreaTop: notch.height))

        init(style: IslandStyle, glyph: GlyphStyle = FramePerf.glyph, placement: UsagePlacement = .section,
             scenario: FixtureSessionFeed.Scenario = .allStates, events: [AgentEvent] = [], glyphsMove: Bool = FramePerf.glyphsMove,
             outline: IslandOutline = .swiftUI, tuning: MotionTuning = MotionTuning(), clock: any IslandJobClock = StrictJobClock(),
             theme: JuiceTheme = FramePerf.theme, stateTint: Bool = FramePerf.stateTint, glassLook: GlassLookChoice = .lightAndDark,
             sessionsClock: @escaping @MainActor () -> Date = { Date() }, prepare: (FixtureSessionFeed) -> Void = { _ in }) {
            let model = IslandChoreography(metrics: .init(targets: SurfaceTargets(notch: Self.notch, pill: .empty)), surface: .closed,
                                           at: clock.now)
            director = IslandMotionDirector(model: model, ui: ui, clock: clock)
            let canvasSize = CGSize(width: IslandPanelSizing.canvasWidth, height: Self.screen.height)
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
            container.autoresizesSubviews = false
            let host = Host(rootView: AnyView(EmptyView()))
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.autoresizingMask = []
            canvas = IslandCanvas(ui: ui, hosting: host, container: container, size: canvasSize)
            super.init(style: style, glyph: glyph, placement: placement, scenario: scenario, events: events,
                       size: CGSize(width: 200, height: 40), host: host, sessionsClock: sessionsClock, prepare: prepare)
            self.glyphsMove = glyphsMove
            // As the island's panel (`IslandPanel.configureKeyViewLoop`); `JI_MEASURE_KEYLOOP=auto` lets AppKit work the
            // loop out on every change, as before round A.
            if FramePerf.environment["JI_MEASURE_KEYLOOP"] != "auto" { IslandPanel.configureKeyViewLoop(window) }
            // As the live island: a stopped glyph clock holds its glyphs where they are.
            ui.holdsGlyphs = true
            // A list change's own turn (E6: written once what leaves has faded) is the transition's marked turn.
            director.onJob = { _, _, steps in
                if steps.contains(where: { if case .listSwap = $0 { true } else { false } }) { FramePerf.marks.append(FramePerf.wallNanos()) }
            }
            // A build ahead the island's motion put off runs once it rests, as the panel's (`islandRested`).
            director.rested = { [weak self] in
                guard let self, let id = self.buildWaits else { return }
                self.buildWaits = nil
                self.buildAhead(id)
            }
            let pill = PillContent.make(rows: env.sessions.rows, settings: env.settings, glance: false, recentlyFinished: nil,
                                        now: env.sessions.now, notch: Self.notch, menuBar: 33)
            let rest = IslandChoreography(metrics: .init(targets: SurfaceTargets(notch: Self.notch, pill: pill), tuning: tuning,
                                                         outline: outline),
                                          surface: .closed, at: clock.now)
            let canvasRect = IslandPanelSizing.canvasRect(centreX: Self.screen.midX, top: Self.screen.maxY, screenHeight: Self.screen.height)
            window.contentView = container
            director.applyPanel = { [weak self] extent in
                guard let self else { return }
                let frame = NotchGeometry.frame(extent, centreX: Self.screen.midX, top: Self.screen.maxY)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.canvas.place(IslandPanelSizing.hostingOrigin(canvas: canvasRect, panel: frame))
                if self.window.frame != frame { self.window.setFrame(frame, display: true) }
                let sound = self.canvas.ensure()
                CATransaction.commit()
                self.panelSnaps += 1
                self.afterSnap?(extent, sound)
            }
            director.perform = { [weak self] effect in
                guard let self else { return }
                switch effect {
                case let .cardSnapshot(id):
                    // As the panel controller does.
                    let card = id.flatMap { self.env.sessions.card(for: $0) ?? self.ui.card }
                    if self.ui.card != card { self.ui.card = card }
                    if self.ui.aheadCard != nil, self.ui.aheadCard?.sessionID == id || id == nil { self.ui.aheadCard = nil }
                case .resetAfterFold:
                    guard !self.ui.isOpen else { return }
                    self.ui.presentation = .list
                    self.ui.showAll = false
                    self.ui.stripOpen = false
                    self.ui.hover = nil
                default:
                    break
                }
            }
            let probe = probe
            host.rootView = AnyView(
                IslandRootView(ui: ui, notch: Self.notch, canvas: canvasSize,
                               maxHeight: FramePerf.environment["JI_MEASURE_MAXHEIGHT"] == "none" ? nil : Self.maxHeight,
                               actions: IslandViewActions(), pillClicked: {},
                               measured: { [weak director] in
                                   probe.reports += 1
                                   director?.measured($0)
                               })
                    .environment(env).glyphMotion(SurfaceMotion(glyphsMove ? .shown : .hidden)).environment(\.glyphClock, self.clock)
                    .environment(\.outlineProbe, outlines).environment(\.juiceTheme, theme)
                    .environment(\.islandStateTint, stateTint).environment(\.glassFrost, FramePerf.frost).environment(\.glassLook, glassLook))
            canvas.setRimRoot(AnyView(IslandRimView(ui: ui, notch: Self.notch, width: canvasSize.width)
                .environment(env).glyphMotion(SurfaceMotion(glyphsMove ? .shown : .hidden)).environment(\.glyphClock, self.clock)
                .environment(\.juiceTheme, theme).environment(\.glassLook, glassLook)))
            canvas.setNotch(Self.notch)
            canvas.setTheme(theme)
            canvas.setStateTint(stateTint)
            ui.tuning = tuning
            if outline == .coreAnimation {
                canvas.setOutline(.coreAnimation)
                director.surface = canvas.layers
            }
            director.reset(rest)
        }

        /// The panel's list ⇄ card: the presentation, then the choreography.
        func present(_ presentation: IslandPresentation) {
            ui.presentation = presentation
            director.send(.present(presentation))
        }

        func open(_ presentation: IslandPresentation = .list) {
            ui.presentation = presentation
            director.send(.open(presentation == .list ? .hover : .attention, presentation))
        }

        /// As the panel builds a card ahead of showing it (`IslandPanelController.mountAhead`, P133): in the card layer,
        /// or beside the card that shows; one built for later only while the island is not in motion, one the next turn
        /// presents at once (E4; `JI_MEASURE_AHEAD=always`: as before round A, whenever asked).
        func buildAhead(_ id: String, presenting: Bool = false) {
            guard let card = env.sessions.card(for: id) else { return }
            guard IslandPanelController.buildsAhead(director.model, presenting: presenting)
                || FramePerf.environment["JI_MEASURE_AHEAD"] == "always" else {
                buildWaits = id
                return
            }
            if director.model.cardMounted == nil { ui.card = card } else { ui.aheadCard = card }
            host.layoutSubtreeIfNeeded()
        }

        /// A card to build ahead that waits for the island to rest.
        private var buildWaits: String?

        /// The footer pressed: every row, as the panel's action plays it (through the choreography, E6).
        func showAll() {
            director.send(.list(.showAll))
        }

        /// A header strip pair or the usage block clicked, as the panel's action plays it.
        func toggleStrip() {
            director.send(.list(.strip(!(director.model.stripAfterSwap ?? ui.stripOpen))))
        }
    }

    /// Window mode: the real window content at 1200 × 760.
    @MainActor
    final class WindowRig: Rig {
        init(events: [AgentEvent]) {
            super.init(style: .clean, glyph: .pixel, placement: .section, scenario: .empty, events: events,
                       size: CGSize(width: 1200, height: 760))
            host.rootView = AnyView(WindowRootView().environment(env).glyphMotion(SurfaceMotion(.shown)).environment(\.glyphClock, clock))
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: CGSize(width: 1200, height: 760))
        }
    }

    // MARK: Transitions

    struct Transition<R: Rig> {
        var name: String
        /// Brings the rig to the transition's start (untimed; the rig then rests 1 s).
        var setUp: @MainActor (R) async -> Void = { _ in }
        /// The transition's trigger, run in a run-loop turn of its own, as an event would.
        var run: @MainActor (R) -> Void
        /// How long it plays.
        var seconds: TimeInterval = 0.8
    }

    struct Result {
        var name: String
        var frames: [Probe.Turn]
        var runs: Int
        /// Each run's frames up to and including the first that draws after the trigger: what stands before it shows.
        var firstFrames: [Double] = []
        /// Each run's marked turn (`FramePerf.later`): its CPU up to and including the first frame it draws.
        var markedFrames: [Double] = []
        var medianMarked: Double? {
            let sorted = markedFrames.sorted()
            return sorted.isEmpty ? nil : sorted[sorted.count / 2]
        }
        /// A frame that does more than step an animation: a new body, a layout, a glyph's frame.
        static let heavy = 2.0
        var worst: Double { frames.map(\.cpuMS).max() ?? 0 }
        func perRun(_ n: Int) -> Double { Double(n) / Double(max(runs, 1)) }
        var hitches: Double { perRun(frames.filter { $0.cpuMS > FramePerf.hitch }.count) }
        var heavyFrames: Double { perRun(frames.filter { $0.cpuMS > Self.heavy }.count) }
        /// The CPU of the frames over 0.25 ms a run: the work beyond stepping animations, which a window with no display
        /// link steps as fast as the run loop turns (thousands of 0.1 ms frames).
        var work: Double { frames.filter { $0.cpuMS > 0.25 }.map(\.cpuMS).reduce(0, +) / Double(max(runs, 1)) }
        var reportsPerRun: Double { perRun(frames.map(\.reports).reduce(0, +)) }
        /// The median heavy frame: with the glyphs moving, mostly a glyph frame.
        var heavyMedian: Double {
            let heavy = frames.map(\.cpuMS).filter { $0 > Self.heavy }.sorted()
            return heavy.isEmpty ? 0 : heavy[heavy.count / 2]
        }
        var medianFirst: Double {
            let sorted = firstFrames.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        /// The median frame: what stepping the motion costs a frame, the steady per-frame cost (with the glyphs still,
        /// `JI_MEASURE_GLYPHS=0`, nothing else draws).
        var step: Double {
            let sorted = frames.map(\.cpuMS).sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        /// The frames a run: a window with no display link steps its animations as fast as the run loop turns.
        var framesPerRun: Double { perRun(frames.count) }
    }

    static func islandTransitions(style: IslandStyle) async -> [Result] {
        let tag = style == .clean ? "Clean" : "Detailed"
        let card = FixtureSessionFeed.ID.approval
        typealias T = Transition<IslandRig>
        let transitions: [T] = [
            // Nothing happens: the open island's glyphs move, and nothing else.
            T(name: "open at rest", setUp: { $0.open() }, run: { _ in }, seconds: 1),
            T(name: "open", run: { $0.open() }),
            T(name: "close", setUp: { $0.open() }, run: { $0.director.send(.close(.fold)) }),
            T(name: "list → card", setUp: { $0.open() }, run: { $0.present(.card(sessionID: card)) }),
            T(name: "card → list", setUp: { rig in
                rig.open()
                await FramePerf.wait(0.8)
                rig.present(.card(sessionID: card))
            }, run: { $0.present(.list) }),
            T(name: "open → card (needs you)", run: { $0.open(.card(sessionID: card)) }),
            // Back 130 ms into a fold: the open reverses in place (its turn is the marked one).
            T(name: "reversing open", setUp: { $0.open() }, run: { rig in
                rig.director.send(.close(.fold))
                FramePerf.later(0.13) { rig.open() }
            }, seconds: 1.0),
            // As the panel opens to a card that needs you (P133): the card is built while the island rests closed, and
            // the island opens to it a turn later. The first is that build alone, the second the open that follows.
            T(name: "card built ahead (closed)", run: { $0.buildAhead(card) }),
            T(name: "open → card built ahead", setUp: { $0.buildAhead(card) }, run: { $0.open(.card(sessionID: card)) }),
            // As a click opens a row the pointer rested on: its card was built during the rest.
            T(name: "list → card built ahead", setUp: { rig in
                rig.open()
                await FramePerf.wait(0.8)
                rig.buildAhead(card)
            }, run: { $0.present(.card(sessionID: card)) }),
            // Another session's card takes the place of the one showing: the old one fades out as the new comes in.
            T(name: "card → card", setUp: { rig in
                rig.open()
                await FramePerf.wait(0.8)
                rig.present(.card(sessionID: card))
            }, run: { $0.present(.card(sessionID: FixtureSessionFeed.ID.question)) }),
            T(name: "card → card built ahead", setUp: { rig in
                rig.open()
                await FramePerf.wait(0.8)
                rig.present(.card(sessionID: card))
                await FramePerf.wait(0.8)
                rig.buildAhead(FixtureSessionFeed.ID.question)
            }, run: { $0.present(.card(sessionID: FixtureSessionFeed.ID.question)) }),
            // The pointer rests on a row 120 ms into the open (E4): the card is built once the island rests, not in the
            // middle of the unfold (`JI_MEASURE_AHEAD=always`: at once, as before).
            T(name: "row's card built ahead mid-open", run: { rig in
                rig.open()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    rig.buildAhead(card)
                }
            }, seconds: 1.2),
            // Something needs you 120 ms into a close: the card is built at once, in its own turn, and the open that
            // follows a turn later finds it measured.
            T(name: "needs you mid-fold", setUp: { $0.open() }, run: { rig in
                rig.director.send(.close(.fold))
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    rig.buildAhead(card, presenting: true)
                    Task { @MainActor in rig.open(.card(sessionID: card)) }
                }
            }, seconds: 1.0),
            // The footer pressed: every row, the list taller than the display allows scrolling inside it.
            T(name: "show all", setUp: { $0.open() }, run: { $0.showAll() }, seconds: 1.0),
            // The queue (P130): resting on a card that waits, the island builds the next that waits beside it, and the
            // answer swaps that one in.
            T(name: "card → next that waits, built ahead", setUp: { rig in
                rig.open()
                await FramePerf.wait(0.8)
                rig.present(.card(sessionID: card))
                await FramePerf.wait(0.8)
                if let next = IslandAttention.buildAhead(shown: card, waits: true, waiting: rig.env.sessions.waiting) {
                    rig.buildAhead(next)
                }
            }, run: { rig in
                guard let next = IslandAttention.buildAhead(shown: card, waits: true, waiting: rig.env.sessions.waiting) else { return }
                rig.present(.card(sessionID: next))
            }),
        ]
        var results: [Result] = []
        for transition in transitions {
            results.append(await measure(transition, tag: tag) { IslandRig(style: style, outline: outline, tuning: tuning) })
        }
        // List updates on a list that shows every row (`smallList`: two running, one done), so each change moves what
        // shows; two sessions asking at once push the last of five rows out of the four that show.
        for transition in listUpdates() as [T] {
            results.append(await measure(transition, tag: tag) {
                IslandRig(style: style, scenario: .empty, events: FramePerf.smallList(), outline: outline, tuning: tuning)
            })
        }
        // The usage strip: Header strip placement, the pair clicked open and folded back.
        let strip: [T] = [
            T(name: "usage strip opens", setUp: { $0.open() }, run: { $0.toggleStrip() }),
            T(name: "usage strip folds", setUp: { rig in
                rig.open()
                await FramePerf.wait(0.8)
                rig.toggleStrip()
            }, run: { $0.toggleStrip() }),
        ]
        for transition in strip {
            results.append(await measure(transition, tag: tag) { IslandRig(style: style, placement: .headerStrip, outline: outline, tuning: tuning) })
        }
        // Many sessions (P400): Show all over `manyCount`, the open list at rest there, and the keys' row scrolled far
        // down and back, as ↓ and ↑ scroll it.
        let deep: @MainActor (IslandRig) -> String? = { rig in
            let order = SessionListLayout.displayOrder(rig.env.sessions.rows, now: rig.env.sessions.now)
            return order.count > 60 ? order[60].id : order.last?.id
        }
        let showingAll: @MainActor (IslandRig) async -> Void = { rig in
            rig.open()
            await FramePerf.wait(0.8)
            rig.showAll()
            await FramePerf.wait(1.2)
        }
        let many: [T] = [
            T(name: "show all (\(manyCount) sessions)", setUp: { $0.open() }, run: { $0.showAll() }, seconds: 1.2),
            T(name: "show all at rest (\(manyCount) sessions)", setUp: showingAll, run: { _ in }, seconds: 1),
            T(name: "scroll down (\(manyCount) sessions)", setUp: showingAll, run: { rig in rig.ui.selectedRow = deep(rig) }, seconds: 1),
            T(name: "scroll back (\(manyCount) sessions)", setUp: { rig in
                await showingAll(rig)
                rig.ui.selectedRow = deep(rig)
                await FramePerf.wait(1)
            }, run: { rig in
                rig.ui.selectedRow = SessionListLayout.displayOrder(rig.env.sessions.rows, now: rig.env.sessions.now).first?.id
            }, seconds: 1),
            T(name: "close from show all (\(manyCount) sessions)", setUp: showingAll, run: { $0.director.send(.close(.fold)) }),
            // ↓ held (the keys move one row a press): from the 16th row, a row every 40 ms for 30 rows, each press scrolling
            // the list by about a row, as a trackpad's steady scroll does.
            T(name: "walk down (\(manyCount) sessions)", setUp: { rig in
                await showingAll(rig)
                rig.ui.selectedRow = SessionListLayout.displayOrder(rig.env.sessions.rows, now: rig.env.sessions.now).dropFirst(15).first?.id
                await FramePerf.wait(0.8)
            }, run: { rig in
                let order = SessionListLayout.displayOrder(rig.env.sessions.rows, now: rig.env.sessions.now).map(\.id)
                for step in 1...30 where 15 + step < order.count {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04 * Double(step)) { rig.ui.selectedRow = order[15 + step] }
                }
            }, seconds: 1.4),
        ]
        for transition in many {
            results.append(await measure(transition, tag: tag) {
                IslandRig(style: style, scenario: .empty, events: FramePerf.manySessions(), outline: outline, tuning: tuning)
            })
        }
        return results
    }

    /// How many sessions the many-sessions transitions list (`JI_MEASURE_MANY`, 120).
    static var manyCount: Int { environment["JI_MEASURE_MANY"].flatMap(Int.init) ?? 120 }

    /// `count` Claude sessions, one every 20 s back from now: a third running, the rest done. (A Codex session the bridge
    /// alone tells of, with no rollout behind it, is not listed.)
    static func manySessions(_ count: Int = manyCount) -> [AgentEvent] {
        let now = Date()
        return (0..<count).flatMap { i -> [AgentEvent] in
            let id = "perf-many-\(i)", at = now - Double(i * 20 + 30)
            var events = newSession(id, title: "Session \(i + 1) of the many", at: at)
            if i % 3 != 0 { events.append(.sessionCompleted(SessionCompleted(sessionID: id, summary: "Done \(i + 1).", timestamp: at + 10))) }
            return events
        }
    }

    /// The list updates both surfaces play, on `smallList`.
    static func listUpdates<R: Rig>() -> [Transition<R>] {
        let open: @MainActor (R) async -> Void = { rig in (rig as? IslandRig)?.open() }
        return [
            Transition(name: "row inserted (asks, at the top)", setUp: open, run: { rig in
                rig.feed.engine.loadPreviewEvents(FramePerf.newSession("perf-new", title: "Ship the release") + [FramePerf.approval("perf-new")])
            }),
            Transition(name: "row reordered (asks)", setUp: open, run: { rig in
                rig.feed.engine.loadPreviewEvents([FramePerf.approval("perf-a")])
            }),
            Transition(name: "glyph mood (done)", setUp: open, run: { rig in
                rig.feed.engine.loadPreviewEvents([.sessionCompleted(SessionCompleted(sessionID: "perf-a", summary: "Parsed.",
                                                                                      timestamp: Date()))])
            }),
            Transition(name: "row pushed out (two ask)", setUp: open, run: { rig in
                rig.feed.engine.loadPreviewEvents(FramePerf.newSession("perf-x", title: "Tag the build") + [FramePerf.approval("perf-x")]
                    + FramePerf.newSession("perf-y", title: "Bump the version") + [FramePerf.approval("perf-y")])
            }),
        ]
    }

    /// The pointer onto the pill (the swell) and off it.
    static func hover() async -> [Result] {
        typealias T = Transition<IslandRig>
        let swell = T(name: "swell", run: { $0.director.send(.swell(true)) }, seconds: 0.6)
        let unswell = T(name: "unswell", setUp: { $0.director.send(.swell(true)) }, run: { $0.director.send(.swell(false)) }, seconds: 0.6)
        return [await measure(swell, tag: "pill") { IslandRig(style: .clean, outline: outline, tuning: tuning) },
                await measure(unswell, tag: "pill") { IslandRig(style: .clean, outline: outline, tuning: tuning) }]
    }

    /// Window mode's list updates.
    static func windowTransitions() async -> [Result] {
        var results: [Result] = []
        for transition in listUpdates() as [Transition<WindowRig>] {
            results.append(await measure(transition, tag: "window") { WindowRig(events: FramePerf.smallList()) })
        }
        return results
    }

    /// Plays `transition` `runs` times on fresh rigs and keeps the frames of each run.
    static func measure<R: Rig>(_ transition: Transition<R>, tag: String, rig make: () -> R) async -> Result {
        let name = "\(tag) · \(transition.name)"
        // `|` between alternatives.
        if let only = environment["JI_MEASURE_ONLY"], !only.split(separator: "|").contains(where: { name.contains($0) }) {
            return Result(name: name, frames: [], runs: 0)
        }
        var frames: [Probe.Turn] = []
        var firsts: [Double] = [], marked: [Double] = []
        for _ in 0..<runs {
            let rig = make()
            await rig.start()
            await transition.setUp(rig)
            await wait(1.0)
            rig.probe.clear()
            let rowsBefore = rig.rowIDs
            let t0 = wallNanos()
            marks = []
            inTurn { transition.run(rig) }
            await wait(transition.seconds)
            if let mark = marks.first, let at = rig.probe.turns.firstIndex(where: { $0.wall <= mark && $0.end >= mark }) {
                let turns = rig.probe.turns[at...]
                let drawn = turns.firstIndex(where: { $0.layouts > 0 && $0.cpuMS > 1 }) ?? at
                marked.append(rig.probe.turns[at...drawn].map(\.cpuMS).reduce(0, +))
            }
            // Every turn that ended after the trigger was asked for: the trigger's own turn may have begun before it.
            let window = rig.probe.turns.filter { $0.end >= t0 }
            frames += window.filter { $0.layouts > 0 }
            // The trigger's turn and every turn up to the first that draws the change (over 1 ms): a change the sessions
            // model publishes in a turn of its own draws a turn later.
            if let drawn = window.firstIndex(where: { $0.layouts > 0 && $0.cpuMS > 1 }) ?? window.firstIndex(where: { $0.layouts > 0 }) {
                firsts.append(window[...drawn].map(\.cpuMS).reduce(0, +))
            }
            if dumps {
                print("\(name): rows \(rowsBefore.prefix(5)) → \(rig.rowIDs.prefix(5)), \(window.count) turns")
                for turn in window where turn.cpu > 250_000 {
                    print(String(format: "  +%6.1f ms  cpu %6.2f  layouts %d  reports %d", (Double(turn.end) - Double(t0)) / 1e6, turn.cpuMS,
                                 turn.layouts, turn.reports))
                }
            }
            rig.stop()
        }
        var result = Result(name: name, frames: frames, runs: runs)
        result.firstFrames = firsts
        result.markedFrames = marked
        return result
    }

    // MARK: A loop for a profiler

    static func loop(_ seconds: TimeInterval) async {
        let rig = IslandRig(style: environment["JI_MEASURE_STYLE"] == "detailed" ? .detailed : .clean)
        await rig.start()
        let end = Date().addingTimeInterval(seconds)
        if environment["JI_MEASURE_LOOP_OPEN"] == "1" {
            rig.open()
            await wait(seconds)
        } else if environment["JI_MEASURE_LOOP_ATTENTION"] == "1" {
            while Date() < end {
                rig.open(.card(sessionID: FixtureSessionFeed.ID.approval))
                await wait(0.6)
                rig.director.send(.close(.fold))
                await wait(0.6)
            }
        } else if environment["JI_MEASURE_LOOP_CARD"] == "1" {
            rig.open()
            await wait(0.5)
            while Date() < end {
                rig.present(.card(sessionID: FixtureSessionFeed.ID.approval))
                await wait(0.5)
                rig.present(.list)
                await wait(0.5)
            }
        } else {
            while Date() < end {
                rig.open()
                await wait(0.35)
                rig.present(.card(sessionID: FixtureSessionFeed.ID.approval))
                await wait(0.35)
                rig.present(.list)
                await wait(0.35)
                rig.director.send(.close(.fold))
                await wait(0.35)
            }
        }
        rig.stop()
    }

    // MARK: Fixtures

    /// Three sessions the island shows in full: two running (Claude and Codex) and one done two minutes ago.
    static func smallList() -> [AgentEvent] {
        let now = Date()
        return newSession("perf-a", title: "Build the parser", at: now - 300)
            + newSession("perf-b", title: "Resize the images", tool: .codex, at: now - 200)
            + newSession("perf-c", title: "Write the tests", at: now - 400)
            + [.sessionCompleted(SessionCompleted(sessionID: "perf-c", summary: "Wrote them.", timestamp: now - 120))]
    }

    static func newSession(_ id: String, title: String, tool: AgentTool = .claudeCode, at now: Date = Date()) -> [AgentEvent] {
        [
            .sessionStarted(SessionStarted(sessionID: id, title: title, tool: tool, origin: .live, initialPhase: .running,
                                           summary: "Started.", timestamp: now,
                                           jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "perf", paneTitle: "perf",
                                                                  workingDirectory: "/tmp/perf-" + id, terminalTTY: "/dev/ttys009"),
                                           codexMetadata: tool == .codex ? CodexSessionMetadata(lastUserPrompt: title) : nil,
                                           claudeMetadata: tool == .claudeCode
                                               ? ClaudeSessionMetadata(lastUserPrompt: title, startupSource: .startup) : nil)),
            .activityUpdated(SessionActivityUpdated(sessionID: id, summary: FixtureSessionFeed.promptPrefix + title, phase: .running,
                                                    timestamp: now + 1)),
            .activityUpdated(SessionActivityUpdated(sessionID: id, summary: "Running Edit", phase: .running, timestamp: now + 2)),
        ]
    }

    static func approval(_ id: String) -> AgentEvent {
        .permissionRequested(PermissionRequested(sessionID: id, request: PermissionRequest(
            title: "Bash", summary: "git push -u origin perf", affectedPath: "/tmp/perf", toolName: "Bash", toolUseID: "toolu_perf_\(id)"),
            timestamp: Date()))
    }

    // MARK: Report

    static func table(_ results: [Result]) -> String {
        var lines = ["Frames, headless release build, \(runs) runs each, glyphs \(glyphsMove ? "moving (30 a second)" : "still"): "
                     + "main-thread CPU in ms. First: the trigger's turn to the first frame drawn (median); worst: any frame of any "
                     + "run; hitches (> 8.3 ms) and heavy frames (> 2 ms) a run and their median; work: the CPU of every frame over "
                     + "0.25 ms a run; reports: the island's measurements a run; step: the median frame; frames: a run's. "
                     + "Outline \(outline == .coreAnimation ? "Core Animation" : "SwiftUI"), Motion \(tuning.motion), Theme \(theme.title).",
                     "",
                     "| Transition | First | Worst | Hitches | Heavy | Heavy median | Work | Reports | Step | Frames |",
                     "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        for r in results where r.runs > 0 {
            // At rest there is no trigger: its first frame would be a glyph's.
            let first = r.name.hasSuffix("at rest") ? "–" : r.medianMarked.map { "\(f(r.medianFirst)) (then \(f($0)))" } ?? f(r.medianFirst)
            lines.append("| \(r.name) | \(first) | \(f(r.worst)) | \(f(r.hitches)) | \(f(r.heavyFrames)) | \(f(r.heavyMedian)) | "
                         + "\(f(r.work)) | \(f(r.reportsPerRun)) | \(String(format: "%.3f", r.step)) | \(Int(r.framesPerRun.rounded())) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
