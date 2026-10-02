import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Session glyphs on Glass (P590 to P594), headless: every mood of every Glyph style (and the pill's dimmed resting
/// check) at the rows' and the closed pill's size, with the status word the row writes beside it, on Black and on
/// Glass's light and dark looks. Offscreen the window server composites no glass, so the looks are the stand-in over a
/// white window, a black desktop and the busy photo, and each look's worst surface flat (#BFBFBF, the light look at its darkest; #404040, the dark look at its
/// brightest: `GlassContrast`). Named `gg-standin-*` so no one takes them for screenshots.
@MainActor
@Suite(.serialized)
struct GlassGlyphRenders {
    /// A mood as a row draws it: its glyph, the state its colour comes from, whose it is and its word.
    struct Mood {
        var name: String
        var glyph: PixelGlyph
        var state: GlyphPalette.State
        var agent: GlyphPalette.Agent = .claude
        var mode: GlyphColourMode = .byState
        var word: String?
        var tone: SessionRowText.Status.Tone = .plain
        var wordColour: Color? = nil
        /// Dimmed, as the closed pill's resting check (P594).
        var dimmed = false
    }

    static let moods: [Mood] = [
        Mood(name: "running", glyph: .eq, state: .running, word: "Running"),
        Mood(name: "delegating", glyph: .agents, state: .delegating, word: "Waiting on 2 agents",
             wordColour: IslandTheme.delegate),
        Mood(name: "approval", glyph: .bang, state: .waiting, word: "Needs approval", tone: .approval),
        Mood(name: "question", glyph: .ques, state: .waiting, word: "Question", tone: .question),
        Mood(name: "done", glyph: .check, state: .done, word: "Done", tone: .done),
        Mood(name: "done, dimmed", glyph: .check, state: .done, word: "Done, resting", tone: .done, dimmed: true),
        Mood(name: "idle", glyph: .brand, state: .idle, word: "Idle"),
        Mood(name: "claude", glyph: .eq, state: .running, agent: .claude, mode: .byAgent, word: "Claude"),
        Mood(name: "codex", glyph: .eq, state: .running, agent: .codex, mode: .byAgent, word: "Codex",
             wordColour: IslandTheme.agentCodex),
    ]

    /// Where a column's glyphs sit: Black; Glass's stand-in over a backdrop; or a look's worst surface, flat.
    enum Ground: Hashable {
        case black
        case glass(GlassBackdrop)
        case worst(ColorScheme)

        var title: String {
            switch self {
            case .black: "Black"
            case .glass(let backdrop): "Glass · \(backdrop.rawValue)"
            case .worst(let look): look == .light ? "Glass · light #BFBFBF" : "Glass · dark #404040"
            }
        }
    }

    static let grounds: [Ground] = [.black, .glass(.white), .worst(.light), .glass(.black), .worst(.dark), .glass(.busy)]

    /// One mood on one ground: the row's glyph, the pill's, and the word.
    struct Cell: View {
        let mood: Mood
        let style: GlyphStyle

        @Environment(\.juiceTheme) private var theme

        var body: some View {
            let palette = theme.island
            let colour = GlassGlyphRenders.colour(mood, palette: palette)
            HStack(spacing: 8) {
                StateGlyphView(glyph: mood.glyph, colour: colour, pixel: IslandTheme.Metrics.rowGlyphPixel, dimmed: mood.dimmed,
                               glow: !mood.dimmed, animated: false, style: style, engineSide: IslandTheme.Metrics.rowGlyphEngine)
                StateGlyphView(glyph: mood.glyph, colour: colour, pixel: 2.5, dimmed: mood.dimmed, glow: !mood.dimmed, animated: false,
                               style: style, engineSide: 28)
                if let word = mood.word {
                    Text(verbatim: word)
                        .font(Fonts.sys(12, .medium))
                        .foregroundStyle(mood.wordColour.map { palette.toneText($0) } ?? IslandRowColours.word(mood.tone, palette: palette, needsYou: .pink))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(width: GlassGlyphRenders.cell.width, height: GlassGlyphRenders.cell.height, alignment: .leading)
        }
    }

    /// The glyph's colour as the rows ask for it.
    static func colour(_ mood: Mood, palette: IslandPalette) -> Color {
        GlyphPalette.glyph(agent: mood.agent, state: mood.state, mode: mood.mode, needsYou: .pink, idle: palette.idleMark)
    }

    static let cell = CGSize(width: 196, height: 44)

    @ViewBuilder static func grounded<V: View>(_ content: V, on ground: Ground) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        switch ground {
        case .black:
            content.themedSurface(shape).environment(\.juiceTheme, .black)
        case .glass(let backdrop):
            GlassStage(backdrop: backdrop) { content.themedSurface(shape) }
                .frame(width: cell.width + 8, height: cell.height + 8)
                .environment(\.juiceTheme, .glass)
        case .worst(let look):
            content
                .background(shape.fill(look == .light ? Color(hex: 0xBFBFBF) : Color(hex: 0x404040)))
                .environment(\.colorScheme, look)
                .environment(\.juiceTheme, .glass)
        }
    }

    static func sheet(_ style: GlyphStyle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(grounds, id: \.self) { ground in
                    Text(verbatim: ground.title).font(Fonts.sys(11, .semibold)).foregroundStyle(.white)
                        .frame(width: cell.width + 8, alignment: .leading)
                }
            }
            ForEach(Array(moods.enumerated()), id: \.offset) { _, mood in
                HStack(spacing: 4) {
                    ForEach(grounds, id: \.self) { ground in
                        grounded(Cell(mood: mood, style: style), on: ground)
                            .frame(width: cell.width + 8, height: cell.height + 8)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(white: 0.16))
    }

    /// Every mood of `style` on every ground: `gg-standin-glyphs-<style>`.
    @Test(arguments: GlyphStyle.allCases)
    func glyphs(_ style: GlyphStyle) throws {
        try RenderHarness.render(Self.sheet(style), "gg-standin-glyphs-\(style.rawValue)")
    }

    /// The real island in Liquid (the owner's style, colour by state) on Black and Glass over each judged backdrop: the
    /// closed pill, the opened list and a Done card. `gg-standin-island-<state>-<theme>-<backdrop>`.
    @Test func islandInLiquid() throws {
        let env = IslandGlassRenders.environment { $0.glyphStyle = .liquid; $0.glyphEdgeLine = true }
        let states: [(String, IslandUIState, CGSize)] = [
            ("closed", IslandGlassRenders.state(env), IslandGlassRenders.pillSize),
            ("open", IslandGlassRenders.state(env, surface: .island), IslandGlassRenders.openSize),
            ("card-done", IslandGlassRenders.state(env, surface: .island, card: FixtureSessionFeed.ID.codexDone,
                                                   events: [(0, .present(.card(sessionID: FixtureSessionFeed.ID.codexDone)))], at: 1.5),
             CGSize(width: 540, height: 330)),
        ]
        for (name, ui, size) in states {
            for theme in [JuiceTheme.black, .glass] {
                for backdrop in GlassBackdrop.judged {
                    try RenderHarness.render(IslandGlassRenders.scene(ui, size: size, backdrop: backdrop, theme: theme),
                                             "gg-standin-island-\(name)-\(theme.rawValue)-\(backdrop.rawValue)", env: env)
                }
            }
        }
    }
}
