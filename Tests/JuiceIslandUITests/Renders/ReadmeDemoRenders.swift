import AppKit
import OpenIslandCore
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// The README's demo (P1575 to P1579): one loop of the island in the notch, headless, from the Demo sessions' made-up
/// sessions (`FixtureSessionFeed+DemoSessions.swift`), with no screen capture. The island is the app's own: its views
/// (`IslandRootView`, the cards) drawn by `ImageRenderer` into a Core Graphics bitmap at each frame's moment, its
/// motion the choreography the app runs (`IslandChoreography`, snapped by `IslandMotionDirector.snap`) fed the events
/// the panel controller sends for the story, at the times the hover machine's rules give them, its glyphs on a clock of
/// the frame's own (`GlyphClock`). The pointer is ours, drawn. The story: the closed pill while sessions work; Claude
/// Code asks to run a command and the island opens to its card; the pointer clicks Yes; the card folds back into its
/// row, which works on, and the island folds; the session finishes and the island shows its Done card; the pointer
/// clicks the card's row, the jump to its tab, and the island folds; a hold, and the loop starts again on the same
/// pill.
/// `JI_RENDER_DIR=<folder> swift test --filter ReadmeDemoRenders` writes `readme-demo.gif` and `readme-demo-poster.png`
/// there (`renders/` by default; the README's are in `docs/public/images`).
@MainActor
@Suite(.serialized)
struct ReadmeDemoRenders {
    typealias ID = FixtureSessionFeed.DemoSessionsID
    typealias Model = IslandChoreography

    /// The README's budget: a GIF a visitor waits for no longer than a screenshot or two.
    static let budget = 6_000_000
    /// Where the README's images are kept: `docs/public/images` here, `docs/images` in the public repository, whose
    /// `swift test` runs this suite too (P1597, P1599).
    static let readmeImages = RenderHarness.root.appendingPathComponent(
        ReadmePageTests.isPrivateTree ? "docs/public/images" : "docs/images", isDirectory: true)

    /// Whether this run draws the GIF: only when asked for renders (`JI_RENDER_DIR`, as `scripts/render-all.sh` sets it)
    /// or the GIF itself (`JI_DEMO_GIF=1`). It holds the main actor for a few minutes, which a whole parallel `swift test`
    /// cannot spare its UI suites (P293).
    nonisolated static var drawsTheGIF: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["JI_RENDER_DIR"] != nil || environment["JI_DEMO_GIF"] == "1"
    }

    /// The GIF and its poster, drawn and written: `readme-demo.gif` (looping, 30 frames a second, under the budget) and
    /// `readme-demo-poster.png` (the approval in the notch, the pointer on Yes; the README shows it to a visitor who
    /// asked for less motion). Every tenth frame is drawn again and must come out the same pixels, and the GIF read
    /// back must be every frame as it was mapped, with its delays. `JI_DEMO_SHEET=<file>` also writes a contact sheet.
    @Test(.enabled(if: drawsTheGIF, "draws the GIF only for renders: JI_RENDER_DIR=<folder> or JI_DEMO_GIF=1"))
    func demo() throws {
        let reel = DemoReel()
        let built = try reel.build()
        try FileManager.default.createDirectory(at: RenderHarness.directory, withIntermediateDirectories: true)
        try built.gif.write(to: RenderHarness.directory.appendingPathComponent("readme-demo.gif"))
        let poster = try #require(NSBitmapImageRep(cgImage: built.poster).representation(using: .png, properties: [:]))
        try poster.write(to: RenderHarness.directory.appendingPathComponent("readme-demo-poster.png"))

        #expect(built.gif.count <= Self.budget, "\(built.gif.count) bytes")
        let summary = try #require(DemoGIF.summary(built.gif))
        #expect(summary.width == 960 && summary.height == DemoReel.height)
        #expect(summary.loopCount == 0)
        #expect(summary.delays == built.frames.map(\.centiseconds))
        #expect(abs(summary.seconds - DemoReel.Beat.end) < 0.011, "\(summary.seconds) s")
        #expect((12...20).contains(summary.seconds))
        #expect(built.palette.count <= DemoGIF.maxColours)

        // ImageIO wrote each frame's colours exactly, over the last.
        let decoded = try DemoGIF.decodedFrames(built.gif)
        #expect(decoded.count == built.frames.count)
        let differing = zip(decoded, built.frames).enumerated().compactMap { i, pair in
            DemoGIF.difference(pair.0, DemoGIF.rgbx(pair.1.image, palette: built.palette)).map { "frame \(i): \($0)" }
        }
        #expect(differing.isEmpty, "\(differing.count) frames differ; \(differing.prefix(3))")
        // The same frames from the same code: every tenth drawn again.
        for i in stride(from: 0, to: built.drawn.count, by: 10) {
            #expect(DemoReel.digest(try reel.pixels(frame: i)) == built.drawn[i], "frame \(i) came out different")
        }
        if let sheet = ProcessInfo.processInfo.environment["JI_DEMO_SHEET"] {
            try reel.contactSheet(decoded: decoded, delays: summary.delays).write(to: URL(fileURLWithPath: sheet))
        }
    }

    /// The loop's last moment is its first: the island closed on the same pill, the pointer gone, the glyphs' clock
    /// brought round, so the frame after the last is the first, pixel for pixel.
    @Test func theLoopIsSeamless() throws {
        let reel = DemoReel()
        let first = try reel.pixels(frame: 0)
        let after = try reel.pixels(frame: reel.frameCount)
        #expect(DemoGIF.difference(first, after) == nil, "\(DemoGIF.difference(first, after) ?? "")")
        let (start, end) = (reel.state(at: 0).ui, reel.state(at: DemoReel.Beat.end).ui)
        #expect(!start.isOpen && !end.isOpen && start.pill == end.pill && start.target == end.target)
        #expect(reel.pointer(at: DemoReel.Beat.end) == nil && reel.pointer(at: 0) == nil)
    }

    /// The story is the island's own: at each beat the choreography the app runs is where the story says, from the
    /// events the panel controller sends (an approval opens the island on its card, an answer under the pointer shows
    /// the list, the pointer leaving folds it, a finish opens the Done card, a jump folds it).
    @Test func theStoryIsTheIslandsOwn() {
        let reel = DemoReel()
        typealias B = DemoReel.Beat
        func at(_ t: TimeInterval) -> (open: Bool, shows: IslandPresentation, card: SessionCard?) {
            let state = reel.state(at: t)
            return (state.ui.isOpen, state.ui.presentation, state.ui.card)
        }
        #expect(!at(0).open && !at(B.asks - 0.01).open)
        let asking = at(B.atYes)
        #expect(asking.open && asking.shows == .card(sessionID: DemoReel.ask))
        guard case .approval? = asking.card else {
            Issue.record("no approval card at Yes")
            return
        }
        #expect(at(B.answered + 0.5).open && at(B.answered + 0.5).shows == .list)
        #expect(!at(B.finishes - 0.01).open)
        let done = at(B.atRow)
        #expect(done.open && done.shows == .card(sessionID: DemoReel.ask))
        guard case .done? = done.card else {
            Issue.record("no Done card at the row")
            return
        }
        #expect(!at(B.jumps + 1).open)
        // The approval's card answers here, and its Yes is where the pointer clicks.
        #expect(reel.envs[.asks]!.sessions.card(for: DemoReel.ask)?.request?.answerable == true)
        #expect(reel.onCard(at: B.pressYes) && reel.onCard(at: B.pressRow) && !reel.onCard(at: B.asks + 0.5))
    }

    /// Every session the demo shows is one of Demo sessions', in its made-up folders, with its titles and its command
    /// (P842, P967): no real project, path or account.
    @Test func theReelShowsOnlyMadeUpSessions() {
        let reel = DemoReel()
        for phase in DemoReel.Phase.allCases {
            let rows = reel.envs[phase]!.sessions.rows
            #expect(Set(rows.map(\.id)) == [ID.approval, ID.edit, ID.codexRun, ID.codexDone, ID.copilot])
            #expect(Set(rows.compactMap(\.project)).isSubset(of: FixtureSessionFeed.demoSessionsFolders))
        }
        let titles = reel.envs[.asks]!.sessions.rows.map { SessionRowText.cleanTitle($0).task }
        #expect(titles.contains("Shoot the site's charts"))
        guard case let .approval(card)? = reel.envs[.asks]!.sessions.card(for: DemoReel.ask) else {
            Issue.record("no approval")
            return
        }
        #expect("\(card.body)".contains(FixtureSessionFeed.demoSessionsCommand))
    }

    /// The encoder: a palette fitted to the frames keeps a flat fill's exact colour, frames that come out the same are
    /// joined, and ImageIO writes every colour and delay as given, looping forever, the same bytes each time.
    @Test func theEncoderKeepsEveryColourAndDelay() throws {
        func frame(_ shift: Int) -> DemoGIF.Pixels {
            var bytes = [UInt8](repeating: 255, count: 64 * 32 * 4)
            for y in 0..<32 {
                for x in 0..<64 {
                    let i = (y * 64 + x) * 4
                    let inBox = x >= 20 + shift && x < 30 + shift && y >= 8 && y < 20
                    // Black ground, a white box that moves, and a gentle ramp along the bottom.
                    let v: UInt8 = inBox ? 255 : y >= 26 ? UInt8(120 + x) : 0
                    (bytes[i], bytes[i + 1], bytes[i + 2]) = (v, inBox ? 255 : v / 2, v)
                }
            }
            return DemoGIF.Pixels(width: 64, height: 32, bytes: bytes)
        }
        let raw = [frame(0), frame(0), frame(6), frame(12)]
        let palette = DemoGIF.palette(raw)
        #expect(palette.contains(DemoGIF.Colour(r: 0, g: 0, b: 0)) && palette.contains(DemoGIF.Colour(r: 255, g: 255, b: 255)))
        let mapper = DemoGIF.Mapper(palette: palette)
        let delays = DemoGIF.delays(count: raw.count, fps: 30)
        #expect(delays == [3, 4, 3, 3])
        let frames = DemoGIF.joined(zip(raw, delays).map { DemoGIF.Frame(image: mapper.map($0), centiseconds: $1) })
        #expect(frames.map(\.centiseconds) == [7, 3, 3])
        let gif = try DemoGIF.encode(frames, palette: palette)
        #expect(try DemoGIF.encode(frames, palette: palette) == gif)
        let summary = try #require(DemoGIF.summary(gif))
        #expect(summary.loopCount == 0 && summary.delays == [7, 3, 3] && summary.width == 64 && summary.height == 32)
        let decoded = try DemoGIF.decodedFrames(gif)
        for (read, frame) in zip(decoded, frames) {
            #expect(DemoGIF.difference(read, DemoGIF.rgbx(frame.image, palette: palette)) == nil)
        }
        #expect(DemoGIF.structure(gif)?.comments == 0 && DemoGIF.structure(gif)?.applications == ["NETSCAPE2.0"])
    }

    /// The README's own copy (`docs/public/images/readme-demo.gif`): under the budget, about 960 pixels wide, looping
    /// forever, 12 to 20 seconds long, carrying no text (no comment, no application block but the loop's), with its
    /// poster beside it.
    @Test func theREADMEsDemoIsWithinBudget() throws {
        let url = Self.readmeImages.appendingPathComponent("readme-demo.gif")
        let data = try Data(contentsOf: url)
        #expect(data.count <= Self.budget, "\(data.count) bytes, over the README's \(Self.budget)")
        let summary = try #require(DemoGIF.summary(data))
        #expect((800...960).contains(summary.width), "\(summary.width) pixels wide")
        #expect(summary.loopCount == 0)
        #expect((12...20).contains(summary.seconds), "\(summary.seconds) s")
        let structure = try #require(DemoGIF.structure(data))
        #expect(structure.comments == 0 && structure.applications == ["NETSCAPE2.0"])
        let poster = try #require(NSImage(contentsOf: Self.readmeImages.appendingPathComponent("readme-demo-poster.png")))
        #expect(poster.representations.first?.pixelsWide == summary.width)
    }
}

/// The demo's sessions, its timeline and its frames. Black over the lavender sunset (`GlassBackdrop.sunset`, the widget
/// shot's), not Glass: at 960 pixels the island has to read as the notch growing, and Black's surface joins the hardware
/// notch in one shape where Glass shows the notch as a black plate in a lilac glass; Black's surface is one flat colour,
/// so the GIF's palette goes to the wallpaper and the marks; and the README's other shots are Black.
@MainActor
final class DemoReel {
    typealias ID = FixtureSessionFeed.DemoSessionsID
    typealias Model = IslandChoreography

    /// What the sessions are doing: the asking session done (the loop's start and end), asking, or running the command
    /// it was allowed.
    enum Phase: Hashable, CaseIterable { case rest, asks, runs }

    static let ask = ID.approval
    /// The scene, in points, and how many pixels a point: 960 pixels wide.
    static let size = CGSize(width: 540, height: 252)
    static let scale: CGFloat = 960 / 540
    static let fps = 30
    static let backdrop = GlassBackdrop.sunset
    /// The glyphs' clock at the reel's start.
    static let glyphStart = Date(timeIntervalSinceReferenceDate: 800_000_000)

    let now = DemoClock.now
    private(set) var feeds: [Phase: FixtureSessionFeed] = [:]
    private(set) var envs: [Phase: AppEnvironment] = [:]
    private(set) var layouts: [Phase: ContentLayout] = [:]
    private(set) var pills: [Phase: PillContent] = [:]
    let settings: AppSettings
    let theme: JuiceTheme
    let scheme: ColorScheme

    init(theme: JuiceTheme = .black, scheme: ColorScheme = .dark) {
        self.theme = theme
        self.scheme = scheme
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = theme
        settings.islandStyle = .clean
        settings.glyphStyle = .pixel
        self.settings = settings
        for phase in Phase.allCases {
            let feed = FixtureSessionFeed(scenario: .empty, now: now)
            feed.engine.loadPreviewEvents(Self.events(phase, now: now))
            // The chats' titles, as Claude Code and Codex name them (the scenario's own did this before its events came).
            FixtureSessionFeed.loadTitles(into: feed.engine)
            if phase == .asks {
                FixtureSessionFeed.loadDemoSessions(into: feed.engine)
            } else {
                feed.engine.loadPreviewNote(event: "SessionStart", sessionID: ID.copilot, source: "copilot")
            }
            feeds[phase] = feed
            let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: now, variant: .showcase), sessions: feed.makeModel())
            envs[phase] = env
            layouts[phase] = DMotionRenders.measure(env: env, notch: IslandGlassRenders.notch, card: phase == .runs ? nil : Self.ask)
            pills[phase] = PillContent.make(rows: env.sessions.rows, settings: settings, glance: false, recentlyFinished: nil,
                                            now: env.sessions.now, notch: IslandGlassRenders.notch, menuBar: IslandGlassRenders.menuBar)
        }
    }

    /// The Demo sessions' events without its question (an approval answered with the island open would hand the island
    /// to the question's card next, P130), and the asking session as `phase` has it.
    static func events(_ phase: Phase, now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events = FixtureSessionFeed.demoSessionsEvents(now: now).filter { sessionID($0) != ID.question }
        switch phase {
        case .rest:
            events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: ask, claudeMetadata: ClaudeSessionMetadata(
                lastUserPrompt: "shoot the charts",
                lastAssistantMessage: "Made site/shots/light and site/shots/dark, so each chart has a light and a dark shot."),
                timestamp: now - 0.5 * m)))
            events.append(.sessionCompleted(SessionCompleted(sessionID: ask, summary: "Made the folders for the shots.", timestamp: now - 0.5 * m)))
        case .asks:
            break
        case .runs:
            events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: ask, claudeMetadata: ClaudeSessionMetadata(
                lastUserPrompt: "shoot the charts", currentTool: "Bash", currentToolInputPreview: FixtureSessionFeed.demoSessionsCommand),
                timestamp: now)))
            events.append(.activityUpdated(SessionActivityUpdated(sessionID: ask, summary: "Running Bash", phase: .running, timestamp: now)))
        }
        return events
    }

    static func sessionID(_ event: AgentEvent) -> String? {
        switch event {
        case let .sessionStarted(e): e.sessionID
        case let .activityUpdated(e): e.sessionID
        case let .permissionRequested(e): e.sessionID
        case let .questionAsked(e): e.sessionID
        case let .sessionCompleted(e): e.sessionID
        case let .sessionMetadataUpdated(e): e.sessionID
        case let .claudeSessionMetadataUpdated(e): e.sessionID
        default: nil
        }
    }

    // MARK: The story

    /// When each thing happens, in seconds from the loop's start.
    enum Beat {
        static let asks: TimeInterval = 1.6
        static let pointerIn: TimeInterval = 2.5
        static let atYes: TimeInterval = 3.7
        static let pressYes: TimeInterval = 4.1
        static let answered: TimeInterval = 4.25
        static let pointerOff: TimeInterval = 5.3
        static let leaves: TimeInterval = 5.55
        static let pointerGone: TimeInterval = 6.3
        static let finishes: TimeInterval = 7.6
        static let pointerBack: TimeInterval = 8.3
        static let atRow: TimeInterval = 9.3
        static let pressRow: TimeInterval = 9.65
        static let jumps: TimeInterval = 9.8
        static let pointerAway: TimeInterval = 10.6
        static let end: TimeInterval = 12.0
    }

    /// The phase the sessions are in at `t`.
    func phase(at t: TimeInterval) -> Phase {
        if t >= Beat.finishes { return .rest }
        if t >= Beat.answered { return .runs }
        if t >= Beat.asks { return .asks }
        return .rest
    }

    /// The events the panel controller sends the choreography for the story, at the times its rules give them: a
    /// request opens the island on its card a turn after the pill hears it (`openByItself`, P133); an answer with the
    /// pointer on the island shows the list (P130); the pointer leaving the landed island folds it after
    /// `closeGrace`; a finish opens its Done card the same way (`.finished` opens as attention does); a jump dismisses.
    var events: [(TimeInterval, Model.Event)] {
        let turn = 1.0 / 60
        let grace = IslandHoverMachine.closeGrace
        return [
            (Beat.asks, .content(layouts[.asks]!)),
            (Beat.asks, .pill(pills[.asks]!)),
            (Beat.asks + turn, .open(.attention, .card(sessionID: Self.ask))),
            (Beat.answered, .present(.list)),
            (Beat.answered, .pill(pills[.runs]!)),
            (Beat.answered + turn, .content(layouts[.runs]!)),
            (Beat.leaves + grace, .close(.fold)),
            (Beat.finishes, .content(layouts[.rest]!)),
            (Beat.finishes, .pill(pills[.rest]!)),
            (Beat.finishes + turn, .open(.attention, .card(sessionID: Self.ask))),
            (Beat.jumps, .close(.dismiss)),
        ]
    }

    var start: Model {
        let env = envs[.rest]!
        let targets = SurfaceTargets(notch: IslandGlassRenders.notch, pill: pills[.rest]!, islandWidth: IslandSize.standard.outer)
        let tuning = MotionTuning(motion: env.settings.islandMotion, hover: env.settings.islandHover)
        return Model(metrics: .init(targets: targets, layout: layouts[.rest]!, tuning: tuning), surface: .closed, presentation: .list)
    }

    /// The island's state at `t`, as the director leaves it: the model snapped, the card it holds (and the one leaving,
    /// as it was when it left) from the sessions of that moment.
    func state(at t: TimeInterval) -> (ui: IslandUIState, env: AppEnvironment) {
        let (model, _) = Model.replay(start, events, until: t)
        let env = envs[phase(at: t)]!
        let ui = IslandUIState()
        IslandMotionDirector.snap(ui, to: model, at: t)
        ui.presentation = model.presentation
        ui.card = model.cardMounted.flatMap { env.sessions.card(for: $0) }
        ui.leavingCard = model.cardLeaving.flatMap { envs[.asks]!.sessions.card(for: $0) }
        return (ui, env)
    }

    // MARK: The pointer

    /// Where the pointer is at `t` (nil: off the scene), how far its press has gone (0 up, 1 down), and the click's
    /// ring (0 to 1 as it spreads, nil when none).
    struct Pointer: Equatable {
        var at: CGPoint
        var press: Double
        var ring: Double?
    }

    /// Where the pointer clicks, in the scene: just right of Yes's label, and on the Done card's row past its title.
    static let yes = CGPoint(x: 396, y: 158)
    static let row = CGPoint(x: 384, y: 53)
    /// Where it comes from and goes to, past the scene's bottom right corner.
    static let offScene = CGPoint(x: 600, y: 320)

    func pointer(at t: TimeInterval) -> Pointer? {
        func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
        func glide(_ from: CGPoint, _ to: CGPoint, _ t0: TimeInterval, _ t1: TimeInterval, bend: CGFloat = 0.18) -> CGPoint {
            let k = ease(min(1, max(0, (t - t0) / (t1 - t0))))
            // A gentle arc: the control point off the straight line to its left.
            let mid = CGPoint(x: (from.x + to.x) / 2 - (to.y - from.y) * bend, y: (from.y + to.y) / 2 + (to.x - from.x) * bend)
            let a = 1 - k
            return CGPoint(x: a * a * from.x + 2 * a * k * mid.x + k * k * to.x, y: a * a * from.y + 2 * a * k * mid.y + k * k * to.y)
        }
        func click(_ down: TimeInterval, _ up: TimeInterval) -> (press: Double, ring: Double?) {
            let press = t < down ? 0 : t < up ? min(1, (t - down) / 0.06) : max(0, 1 - (t - up) / 0.08)
            let ring = t >= down && t < down + 0.45 ? (t - down) / 0.45 : nil
            return (press, ring)
        }
        switch t {
        case ..<Beat.pointerIn: return nil
        case ..<(Beat.answered + 0.4):
            let c = click(Beat.pressYes, Beat.answered)
            return Pointer(at: glide(Self.offScene, Self.yes, Beat.pointerIn, Beat.atYes), press: c.press, ring: c.ring)
        case ..<Beat.finishes:
            guard t < Beat.pointerGone + 0.2 else { return nil }
            return Pointer(at: glide(Self.yes, Self.offScene, Beat.pointerOff - 0.25, Beat.pointerGone, bend: -0.1), press: 0, ring: nil)
        case ..<Beat.pointerBack: return nil
        default:
            let c = click(Beat.pressRow, Beat.jumps)
            if t < Beat.jumps + 0.3 {
                return Pointer(at: glide(Self.offScene, Self.row, Beat.pointerBack, Beat.atRow), press: c.press, ring: c.ring)
            }
            guard t < Beat.pointerAway + 0.2 else { return nil }
            return Pointer(at: glide(Self.row, Self.offScene, Beat.jumps + 0.3, Beat.pointerAway, bend: -0.1), press: c.press, ring: c.ring)
        }
    }

    /// The card's frame in the scene while `phase`'s card shows: its header and body as measured, and the card's
    /// padding round them.
    func cardFrame(_ phase: Phase) -> CGRect? {
        guard let layout = layouts[phase], let header = layout.parts[.cardHeader], let body = layout.parts[.cardBody] else { return nil }
        let left = (Self.size.width - IslandSize.standard.outer) / 2
        return header.union(body).offsetBy(dx: left, dy: 0).insetBy(dx: -8, dy: -6)
    }

    /// Whether the pointer is on the card the island shows: the card lifts, as its own hover lifts it live.
    func onCard(at t: TimeInterval) -> Bool {
        guard let pointer = pointer(at: t) else { return false }
        let model = Model.replay(start, events, until: t).model
        guard model.isOpen, case .card = model.presentation, let frame = cardFrame(phase(at: t)) else { return false }
        return frame.contains(pointer.at)
    }

    // MARK: Frames

    /// The scene at `t`, its glyphs drawn at `glyphs` (the same moment unless the loop's end brings them round).
    func scene(at t: TimeInterval, glyphs: TimeInterval? = nil) -> some View {
        let (ui, env) = state(at: t)
        let pointer = pointer(at: t)
        return AppearanceRenders.islandScene(ui, size: Self.size, backdrop: Self.backdrop, theme: theme, scheme: scheme)
            .overlay(alignment: .topLeading) {
                if let pointer { DemoPointerView(pointer: pointer) }
            }
            .environment(\.previewCardHovered, onCard(at: t))
            .environment(\.glyphClock, GlyphClock(date: Self.glyphStart + (glyphs ?? t), start: Self.glyphStart))
            .environment(env)
    }

    /// The frame's pixels: 960 wide.
    static let width = Int((size.width * scale).rounded())
    static let height = Int((size.height * scale).rounded())

    // MARK: The loop

    /// The loop's frames, `fps` a second; frame `frameCount` would be the first again.
    var frameCount: Int { Int((Beat.end * Double(Self.fps)).rounded()) }
    /// Across the loop's last `blend` seconds the glyphs' clock is brought round: each frame is its moment with the
    /// glyphs where they are, faded into the same moment with the glyphs where the loop's start had them, so the last
    /// frame leads into the first (the closed pill's glyph moves all the time; nothing else differs).
    static let blend: TimeInterval = 0.6
    /// The poster's moment: the approval in the notch, the pointer resting on Yes.
    static let posterAt = Beat.atYes + 0.2

    enum FrameError: Error { case noImage(TimeInterval) }

    /// The scene at `t`, drawn by the render rig's `ImageRenderer` into a Core Graphics bitmap of our own: drawn there,
    /// the same moment always comes out the same pixels (drawn by the GPU, a gradient's dither and a glow's blur moved by
    /// a level from one draw to the next).
    func rendered(at t: TimeInterval, glyphs: TimeInterval? = nil) throws -> DemoGIF.Pixels {
        let env = envs[phase(at: t)]!
        let content = scene(at: t, glyphs: glyphs)
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(env)
            .environment(\.colorScheme, scheme)
            .environment(\.glassRendering, .standIn)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(Self.size)
        let (w, h) = (Self.width, Self.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.scaleBy(x: Self.scale, y: Self.scale)
            renderer.render(rasterizationScale: Self.scale) { _, draw in draw(context) }
            return true
        }
        guard drawn else { throw FrameError.noImage(t) }
        // The scene is opaque: the wallpaper fills it.
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        return DemoGIF.Pixels(width: w, height: h, bytes: bytes)
    }

    /// Frame `i` as drawn, in sRGB.
    func pixels(frame i: Int) throws -> DemoGIF.Pixels {
        let t = Double(i) / Double(Self.fps)
        let into = t - (Beat.end - Self.blend)
        guard into > 0 else { return try rendered(at: t) }
        let w = min(1, into / Self.blend)
        let k = w * w * (3 - 2 * w)
        let round = try rendered(at: t, glyphs: t - Beat.end)
        guard k < 1 else { return round }
        var out = try rendered(at: t)
        let a = Int((1 - k) * 256), b = 256 - a
        out.bytes.withUnsafeMutableBufferPointer { out in
            round.bytes.withUnsafeBufferPointer { round in
                for i in 0..<out.count { out[i] = UInt8((Int(out[i]) * a + Int(round[i]) * b + 128) >> 8) }
            }
        }
        return out
    }

    /// A 64-bit FNV-1a digest of the pixels.
    static func digest(_ pixels: DemoGIF.Pixels) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        pixels.bytes.withUnsafeBufferPointer { bytes in
            for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        }
        return hash
    }

    struct Built {
        var gif: Data
        /// The GIF's frames, each frame that came out the same as the one before it joined into it.
        var frames: [DemoGIF.Frame]
        var palette: [DemoGIF.Colour]
        var poster: CGImage
        /// Every frame's digest as drawn, before its colours were mapped.
        var drawn: [UInt64]
    }

    /// The whole GIF: a palette fitted to every third frame, then every frame drawn, mapped and joined, and encoded.
    func build() throws -> Built {
        let count = frameCount
        let histogram = DemoGIF.Histogram()
        for i in stride(from: 0, to: count, by: 3) { histogram.add(try pixels(frame: i)) }
        let palette = histogram.palette()
        let mapper = DemoGIF.Mapper(palette: palette)
        let delays = DemoGIF.delays(count: count, fps: Self.fps)
        var frames: [DemoGIF.Frame] = []
        var drawn: [UInt64] = []
        for i in 0..<count {
            let raw = try pixels(frame: i)
            drawn.append(Self.digest(raw))
            let image = mapper.map(raw)
            if let last = frames.last, last.image == image {
                frames[frames.count - 1].centiseconds += delays[i]
            } else {
                frames.append(DemoGIF.Frame(image: image, centiseconds: delays[i]))
            }
        }
        let poster = try DemoGIF.cgImage(rendered(at: Self.posterAt))
        return Built(gif: try DemoGIF.encode(frames, palette: palette), frames: frames, palette: palette, poster: poster, drawn: drawn)
    }

    /// Every tenth frame of the loop as the GIF shows it (`decoded`, each shown for `delays`), a third of its size, with
    /// its moment, the frame it is in the GIF and how long that frame shows.
    func contactSheet(decoded: [DemoGIF.Pixels], delays: [Int]) throws -> Data {
        guard let first = decoded.first else { throw FrameError.noImage(0) }
        var starts: [Int] = []
        var at = 0
        for delay in delays {
            starts.append(at)
            at += delay
        }
        let columns = 5, tileW = first.width / 3, tileH = first.height / 3, label = 16, gap = 6
        let moments = Array(stride(from: 0, to: frameCount, by: 10))
        let rows = (moments.count + columns - 1) / columns
        let width = columns * (tileW + gap) + gap, height = rows * (tileH + label + gap) + gap + 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { throw FrameError.noImage(0) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                                                         .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        let total = delays.reduce(0, +)
        ("\(frameCount) frames at \(Self.fps)/s, \(decoded.count) in the GIF, \(Double(total) / 100) s, every tenth below" as NSString)
            .draw(at: NSPoint(x: gap, y: height - 18), withAttributes: attributes)
        for (n, i) in moments.enumerated() {
            let cs = Int((Double(100 * i) / Double(Self.fps)).rounded())
            let shown = max(0, (starts.lastIndex { $0 <= cs }) ?? 0)
            let image = try DemoGIF.cgImage(decoded[shown])
            let column = n % columns, row = n / columns
            let x = gap + column * (tileW + gap)
            let y = height - 24 - (row + 1) * (tileH + label + gap)
            context.cgContext.interpolationQuality = .high
            context.cgContext.draw(image, in: CGRect(x: x, y: y, width: tileW, height: tileH))
            ("\(String(format: "%5.2f", Double(i) / Double(Self.fps))) s  gif \(shown)  \(delays[shown]) cs" as NSString)
                .draw(at: NSPoint(x: x, y: y + tileH + 2), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw FrameError.noImage(0) }
        return png
    }
}

/// The demo's pointer: an arrow of our own drawing (black, a white edge, a soft shadow), its tip at `pointer.at`; a press
/// shrinks it a little toward its tip, and a click sends a faint ring out from the tip.
struct DemoPointerView: View {
    let pointer: DemoReel.Pointer

    static func arrow(in rect: CGRect) -> Path {
        var path = Path()
        let s = rect.height / 18
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        path.move(to: p(0, 0))
        path.addLine(to: p(0, 15.2))
        path.addLine(to: p(3.6, 11.9))
        path.addLine(to: p(6.1, 17.6))
        path.addLine(to: p(8.6, 16.5))
        path.addLine(to: p(6.1, 10.9))
        path.addLine(to: p(10.9, 10.9))
        path.closeSubpath()
        return path
    }

    var body: some View {
        let scale = 1 - 0.12 * pointer.press
        ZStack(alignment: .topLeading) {
            if let ring = pointer.ring {
                let fade = 1 - ring
                Circle()
                    .stroke(Color.white.opacity(0.9 * fade), lineWidth: 2.5)
                    .frame(width: 12 + 34 * ring, height: 12 + 34 * ring)
                    .shadow(color: .black.opacity(0.5 * fade), radius: 2)
                    .position(pointer.at)
            }
            let arrow = Self.arrow(in: CGRect(x: 0, y: 0, width: 12, height: 19))
            ZStack(alignment: .topLeading) {
                arrow.fill(Color.black)
                arrow.stroke(Color.white, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            }
            .frame(width: 12, height: 19, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .offset(x: pointer.at.x, y: pointer.at.y)
        }
        .frame(width: DemoReel.size.width, height: DemoReel.size.height, alignment: .topLeading)
    }
}
