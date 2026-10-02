import AppKit
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Themes Glass and Smoke on the island (P550 to P555, P560 to P563), headless: the real `IslandRootView` (SwiftUI's
/// outline) snapped to the choreography's states, on a white window, a black desktop and a busy photo
/// (`GlassBackdrop.judged`), with the hardware notch drawn over it. Offscreen the window server composites no glass, so
/// the glass is the stand-in (Smoke: the backdrop blurred in the outline under the same floor, rim and notch plate as
/// the live glass; Glass: the backdrop blurred under our model of the system's adaptation, its ink in that scheme):
/// every file is named `is-standin-*` so no one takes it for a screenshot. Smoke's files are Glass's before
/// 2026-09-29, byte for byte, under `is-standin-smoke-*`.
@MainActor
@Suite(.serialized)
struct IslandGlassRenders {
    typealias Model = IslandChoreography

    static let notch = IslandTheme.Metrics.referenceNotch
    static let menuBar = IslandTheme.Metrics.referenceMenuBar

    /// The prototype's sessions in Clean, Header strip placement, Pixel unless `configure` says otherwise.
    static func environment(_ configure: (AppSettings) -> Void = { _ in }) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .clean
        settings.islandUsagePlacement = .headerStrip
        settings.glyphStyle = .pixel
        configure(settings)
        return AppEnvironment.demo(settings: settings, sessions: .prototype)
    }

    /// The island's state at `t` of `events` from `surface`, snapped with still glyphs.
    static func state(_ env: AppEnvironment, notch: CGSize? = notch, surface: Model.Surface = .closed,
                      presentation: IslandPresentation = .list, card: String? = nil, events: [(TimeInterval, Model.Event)] = [],
                      at t: TimeInterval = 0, tuning: MotionTuning = MotionTuning(), layout: ContentLayout? = nil,
                      island: IslandSize = .standard) -> IslandUIState {
        let menuBar: CGFloat = notch == nil ? IslandTheme.Metrics.topBarFallbackHeight : Self.menuBar
        let pill = PillContent.make(rows: env.sessions.rows, settings: env.settings, glance: false, recentlyFinished: nil,
                                    now: env.sessions.now, notch: notch, menuBar: menuBar)
        let layout = layout ?? DMotionRenders.measure(env: env, notch: notch, card: card, island: island)
        let targets = SurfaceTargets(notch: notch, pill: pill, islandWidth: island.outer)
        let start = Model(metrics: .init(targets: targets, layout: layout, tuning: tuning),
                          surface: surface, presentation: presentation)
        let (model, _) = Model.replay(start, events, until: t)
        let ui = IslandUIState()
        IslandMotionDirector.snap(ui, to: model, at: t)
        ui.presentation = model.presentation
        ui.card = model.cardMounted.flatMap { env.sessions.card(for: $0) }
        ui.islandLive = false
        ui.pillLive = false
        return ui
    }

    /// The island on `backdrop` in `theme`: the canvas centred, a menu bar's faint veil beside it, the notch over it.
    static func scene(_ ui: IslandUIState, notch: CGSize? = notch, size: CGSize, backdrop: GlassBackdrop, theme: JuiceTheme,
                      island: IslandSize = .standard) -> some View {
        let menuBar: CGFloat = notch == nil ? IslandTheme.Metrics.topBarFallbackHeight : Self.menuBar
        return GlassStage(backdrop: backdrop) {
            ZStack(alignment: .top) {
                Rectangle().fill(Color.black.opacity(0.1)).frame(height: menuBar)
                IslandRootView(ui: ui, notch: notch, canvas: CGSize(width: island.canvasWidth, height: size.height), size: island,
                               actions: IslandViewActions(), pillClicked: {}, measured: { _ in })
                if let notch { DScene.hardwareNotch(notch) }
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.juiceTheme, theme)
    }

    static let openSize = CGSize(width: 540, height: 330)
    static let pillSize = CGSize(width: 360, height: 60)

    /// The states the look is judged on: the closed pill (Pixel; Liquid with its edge line), the opened list (the header
    /// strip; the usage block with batteries and money), an approval's card (needs you), a question's, a Done card.
    static func states() -> [(name: String, env: AppEnvironment, ui: IslandUIState, size: CGSize)] {
        let strip = Self.environment()
        let section = Self.environment { $0.islandUsagePlacement = .section; $0.islandShowsMoney = true }
        let liquid = Self.environment { $0.glyphStyle = .liquid; $0.glyphEdgeLine = true }
        let detailed = Self.environment { $0.islandStyle = .detailed }
        func card(_ env: AppEnvironment, _ id: String) -> IslandUIState {
            Self.state(env, surface: .island, card: id, events: [(0, .present(.card(sessionID: id)))], at: 1.5)
        }
        return [
            ("closed", strip, Self.state(strip), Self.pillSize),
            ("closed-liquid", liquid, Self.state(liquid), Self.pillSize),
            ("open", strip, Self.state(strip, surface: .island), Self.openSize),
            ("open-usage", section, Self.state(section, surface: .island), CGSize(width: 540, height: 470)),
            ("open-detailed", detailed, Self.state(detailed, surface: .island), CGSize(width: 540, height: 470)),
            ("card-approval", strip, card(strip, FixtureSessionFeed.ID.approval), CGSize(width: 540, height: 330)),
            ("card-question", strip, card(strip, FixtureSessionFeed.ID.question), CGSize(width: 540, height: 330)),
            ("card-done", strip, card(strip, FixtureSessionFeed.ID.codexDone), CGSize(width: 540, height: 330)),
        ]
    }

    /// No notch: the top bar, all glass.
    static func topBar() -> (env: AppEnvironment, closed: IslandUIState, open: IslandUIState) {
        let env = Self.environment()
        return (env, Self.state(env, notch: nil), Self.state(env, notch: nil, surface: .island))
    }

    // MARK: Renders

    /// The glass themes, as the files name them.
    nonisolated static let glassThemes: [JuiceTheme] = [.glass, .smoke]

    /// Every state on each judged backdrop, in Glass and Smoke: `is-standin-<theme>-<state>-<backdrop>`. A question's
    /// card is drawn hosted (its answer field is AppKit's, which `ImageRenderer` leaves as a placeholder), where the
    /// stand-in's blur comes out weaker: a harsher backdrop than the live glass's.
    @Test(arguments: glassThemes)
    func everyStateOnEachBackdrop(_ theme: JuiceTheme) throws {
        for state in Self.states() {
            for backdrop in GlassBackdrop.judged {
                let scene = Self.scene(state.ui, size: state.size, backdrop: backdrop, theme: theme)
                let name = "is-standin-\(theme.rawValue)-\(state.name)-\(backdrop.rawValue)"
                if state.name == "card-question" {
                    try RenderHarness.renderHosted(scene, name, size: state.size, env: state.env)
                } else {
                    try RenderHarness.render(scene, name, env: state.env)
                }
            }
        }
        let bar = Self.topBar()
        for backdrop in GlassBackdrop.judged {
            try RenderHarness.render(Self.scene(bar.closed, notch: nil, size: CGSize(width: 360, height: 50), backdrop: backdrop, theme: theme),
                                     "is-standin-\(theme.rawValue)-topbar-closed-\(backdrop.rawValue)", env: bar.env)
            try RenderHarness.render(Self.scene(bar.open, notch: nil, size: Self.openSize, backdrop: backdrop, theme: theme),
                                     "is-standin-\(theme.rawValue)-topbar-open-\(backdrop.rawValue)", env: bar.env)
        }
    }

    /// Black, Glass and Smoke on the three backdrops, for the opened list, a needs-you card and a Done card, and the
    /// closed pill under them: `is-standin-sheet`.
    @Test func sheet() throws {
        let states = Self.states()
        let picked = ["open", "card-approval", "card-done"].compactMap { name in states.first { $0.name == name } }
        let closed = try #require(states.first { $0.name == "closed" })
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(picked.enumerated()), id: \.offset) { _, state in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(GlassBackdrop.judged, id: \.self) { backdrop in
                        VStack(spacing: 4) {
                            ForEach(JuiceTheme.allCases, id: \.self) { theme in
                                Self.scene(state.ui, size: CGSize(width: 520, height: 300), backdrop: backdrop, theme: theme)
                                    .environment(state.env)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(GlassBackdrop.judged, id: \.self) { backdrop in
                    VStack(spacing: 4) {
                        ForEach(JuiceTheme.allCases, id: \.self) { theme in
                            Self.scene(closed.ui, size: CGSize(width: 520, height: 50), backdrop: backdrop, theme: theme)
                                .environment(closed.env)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(white: 0.2))
        try RenderHarness.render(sheet, "is-standin-sheet", env: closed.env)
    }

    // MARK: Width and text size

    /// Wave 6's Width and Text size (P401, P402) in Glass: at the narrowest width and smallest text and at the widest and
    /// largest, the opened list and a Done card with a table and code (`DoneMessageView`, P556), on the busy photo and a
    /// white window: the glass, its rim and the notch plate follow the island's own width, and the text reads on it.
    /// `is-standin-size-<width>-<text>-<state>-<backdrop>`.
    @Test(arguments: glassThemes)
    func theNarrowestAndTheWidestIsland(_ theme: JuiceTheme) throws {
        for (width, text) in [(460, 12), (640, 15)] {
            let island = IslandSize(width: width, text: text)
            let list = Self.environment { $0.islandWidth = width; $0.islandTextSize = text }
            let settings = AppSettings.ephemeral()
            settings.islandStyle = .clean
            settings.islandUsagePlacement = .headerStrip
            settings.islandWidth = width
            settings.islandTextSize = text
            let markdown = AppEnvironment.demo(settings: settings, sessions: .markdown)
            let done = FixtureSessionFeed.ID.markdownDone
            let states: [(String, AppEnvironment, IslandUIState, CGFloat)] = [
                ("open", list, Self.state(list, surface: .island, island: island), 360),
                ("card-done", markdown, Self.state(markdown, surface: .island, card: done, events: [(0, .present(.card(sessionID: done)))],
                                                   at: 1.5, island: island), 560),
            ]
            for (name, env, ui, height) in states {
                for backdrop in [GlassBackdrop.busy, .white] {
                    let size = CGSize(width: island.outer + 60, height: height)
                    try RenderHarness.render(Self.scene(ui, size: size, backdrop: backdrop, theme: theme, island: island),
                                             "is-standin-\(theme.rawValue)-size-\(width)-\(text)-\(name)-\(backdrop.rawValue)", env: env)
                }
            }
        }
    }

    // MARK: The peek

    /// A row's peek over the rows below it (P558), Black and Glass, on a white window and the busy photo: on glass its
    /// ground is the island's own glass under the hovered row's veil, the rows under it not drawn there, so the row and
    /// its peek read as one, as in Black. Hosted, so the peek is measured and placed. The stand-in cannot show what a
    /// glass of the peek's own would have done live (it would sample the island's darkened surface, not the wallpaper),
    /// which is why the peek has none. `is-standin-peek-<theme>-<backdrop>`.
    @Test func aPeekOverTheRows() throws {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .clean
        settings.islandUsagePlacement = .headerStrip
        settings.glyphStyle = .pixel
        let env = AppEnvironment.demo(settings: settings, sessions: .rows, stalledAfter: 600)
        // The first row's peek (a Claude turn still running, its transcript tail a fixture read) over the rows below it.
        let row = try #require(env.sessions.row(id: FixtureSessionFeed.RowsID.claudePlan))
        let read = SessionPeekRead(prompt: "how should search index the notes? plan it first",
                                   reply: "The index is rebuilt on every save; a tokenizer per locale would halve it.",
                                   tool: "Read", toolDetail: "search/index.ts", model: "claude-opus-5-5")
        let peek = try #require(SessionPeek.make(row: row, clean: true, prompt: row.lastPrompt, reply: nil, replyIsCurrent: false, read: read))
        for theme in JuiceTheme.allCases {
            for backdrop in [GlassBackdrop.white, .busy] {
                let ui = Self.state(env, surface: .island)
                // Drawn as it rests: no fade caught half way.
                ui.reduceMotion = true
                ui.peek = peek
                try RenderHarness.renderHosted(Self.scene(ui, size: CGSize(width: 540, height: 360), backdrop: backdrop, theme: theme)
                    .environment(\.sessionGlyphsAnimated, false),
                                               "is-standin-peek-\(theme.rawValue)-\(backdrop.rawValue)", size: CGSize(width: 540, height: 360), env: env)
            }
        }
    }

    // MARK: Motion

    /// Open and close (Motion: Refined, the app's), and list → card, as frame strips on `backdrop` in Glass, each frame
    /// drawn at its time from the model (still glyphs): the glass, its rim and the notch plate move with the outline.
    @Test(arguments: [GlassBackdrop.busy, .white], glassThemes)
    func strips(_ backdrop: GlassBackdrop, _ theme: JuiceTheme) throws {
        let env = Self.environment()
        let refined = MotionTuning(motion: .refined, hover: .quick)
        let layout = DMotionRenders.measure(env: env, notch: Self.notch, card: nil)
        let cardID = FixtureSessionFeed.ID.approval
        let cardLayout = DMotionRenders.measure(env: env, notch: Self.notch, card: cardID)
        let open: [(TimeInterval, Model.Event)] = [(0, .open(.hover, .list))], close: [(TimeInterval, Model.Event)] = [(0, .close(.fold))]
        let rows: [(String, Model.Surface, [(TimeInterval, Model.Event)], [TimeInterval], ContentLayout, String?)] = [
            ("open, Refined", .closed, open, [0, 0.03, 0.06, 0.1, 0.15, 0.2, 0.26, 0.34, 0.6], layout, nil),
            ("close, Refined", .island, close, [0, 0.03, 0.06, 0.1, 0.15, 0.2, 0.26, 0.34, 0.6], layout, nil),
            ("list → card, Refined", .island, [(0, .present(.card(sessionID: cardID)))], [0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5],
             cardLayout, cardID),
        ]
        let tile = CGSize(width: 500, height: 300)
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: row.0).font(Fonts.sys(11)).foregroundStyle(IslandTheme.ink2)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(row.3.enumerated()), id: \.offset) { _, t in
                            VStack(alignment: .leading, spacing: 4) {
                                Self.scene(Self.state(env, surface: row.1, card: row.5, events: row.2, at: t, tuning: refined, layout: row.4),
                                           size: tile, backdrop: backdrop, theme: theme)
                                Text(verbatim: "\(Int((t * 1000).rounded())) ms").font(Fonts.mono(10)).foregroundStyle(IslandTheme.ink3)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(hex: 0x0B0D0D))
        try RenderHarness.render(view, "is-standin-\(theme.rawValue)-strip-\(backdrop.rawValue)", env: env)
    }

    // MARK: Window mode

    /// Window mode keeps its own look whatever the theme (spec §4.8): with Glass or Smoke picked, the window is Black's,
    /// pixel for pixel. `is-window-glass-setting`.
    @Test(arguments: glassThemes)
    func windowModeIsUnchangedByGlass(_ theme: JuiceTheme) throws {
        func bitmap(_ theme: JuiceTheme) throws -> NSBitmapImageRep {
            let settings = AppSettings.ephemeral()
            settings.juiceTheme = theme
            let env = AppEnvironment.demo(settings: settings)
            return try RenderHarness.hostedBitmap(WindowRootView(drawsTrafficLights: true).environment(\.sessionGlyphsAnimated, false),
                                                  "is-window", size: CGSize(width: 900, height: 620), env: env)
        }
        let black = try bitmap(.black), glass = try bitmap(theme)
        var differing = 0
        for y in 0..<black.pixelsHigh {
            for x in 0..<black.pixelsWide where black.colorAt(x: x, y: y) != glass.colorAt(x: x, y: y) { differing += 1 }
        }
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = theme
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true).environment(\.sessionGlyphsAnimated, false),
                                       "is-window-\(theme.rawValue)-setting", size: CGSize(width: 900, height: 620), env: .demo(settings: settings))
        #expect(differing == 0, "\(differing) pixels differ")
    }
}
