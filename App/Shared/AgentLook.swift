import OpenIslandCore
import SwiftUI

/// How a session's agent shows: its name (a row's tooltip and spoken label, a card's "Tell Kimi what to do
/// instead…"), its mark, in its colour, before every title (the row's one word on whose it is, P204), and its colour
/// (the running glyph under Island › Glyph colour › By agent: `runningColour`).
/// Claude and Codex keep their own marks and colours. Every other agent Open Island's engine knows (`AgentTool`: its
/// hooks for them are already installed, and their events reach the bridge) has a monochrome mark drawn here, never a
/// vendor's logo: a plain shape where the agent has one (Gemini's four-point spark, Cursor's pointer), else its letter
/// cut out of a small tile; and upstream's own colour for it (`AgentTool.brandColorHex`), but for two that sit too
/// close to another's to tell apart (`colourOverrides`). An agent a later engine adds that `others` does not list shows
/// the name its engine gives it, its initial on a tile and a neutral grey (P151).
struct AgentLook: Equatable, Sendable {
    enum Mark: Equatable, Sendable {
        case claude, openAI
        /// A four-point spark (Gemini).
        case spark
        /// A pointer arrow (Cursor).
        case pointer
        /// A letter cut out of a rounded tile.
        case tile(String)
        /// A letter cut out of a disc: the second agent with a letter a tile already has (Qoder after Qwen, Oh My Pi
        /// after Pi).
        case disc(String)
    }

    struct Entry: Sendable {
        var name: String
        var mark: Mark
    }

    var name: String
    var mark: Mark
    var colour: Color

    /// The colour By agent draws the agent's running glyph in with `needsYou` chosen: its own, but Claude's redder tint,
    /// which never reads as what needs you (P207); and the running blue, as By state draws it, for an agent whose colour
    /// sits within 12 of the needs-you colour or its tint, so its running glyph never reads as one that needs you
    /// (P782): Qoder's pink and Oh My Pi's under Pink, Qwen's purple and Oh My Pi's under Violet, none under Orange.
    /// Its mark keeps its colour; its shape says whose it is.
    func runningColour(_ needsYou: NeedsYouColour) -> Color {
        if mark == .claude { return IslandTheme.agentClaudeRunning }
        return Self.nearNeedsYou[needsYou, default: []].contains(colour) ? IslandTheme.run : colour
    }

    /// The agents' colours within CIEDE2000 12 of each needs-you colour or its tint (`AgentLookTests` works them out).
    static let nearNeedsYou: [NeedsYouColour: Set<Color>] = [
        .pink: [Color(hex: 0xFF6B9F), Color(hex: 0xE6A8D9)],
        .violet: [Color(hex: 0xC084FC), Color(hex: 0xE6A8D9)],
    ]

    static func of(_ agent: GlyphPalette.Agent) -> AgentLook {
        switch agent {
        case .claude: AgentLook(name: "Claude", mark: .claude, colour: IslandTheme.agentClaude)
        case .codex: AgentLook(name: "Codex", mark: .openAI, colour: IslandTheme.agentCodex)
        case let .other(tool): of(tool)
        }
    }

    /// Any tool; `table` is `others` (tests pass another to see an agent it does not list).
    static func of(_ tool: AgentTool, table: [AgentTool: Entry] = others) -> AgentLook {
        switch tool {
        case .claudeCode: return of(.claude)
        case .codex: return of(.codex)
        default: break
        }
        guard let entry = table[tool] else {
            let name = tool.displayName.trimmingCharacters(in: .whitespaces)
            return AgentLook(name: name, mark: .tile(name.first.map { String($0).uppercased() } ?? "?"), colour: neutral)
        }
        return AgentLook(name: entry.name, mark: entry.mark, colour: brandColours[tool] ?? neutral)
    }

    /// Where upstream's colour sits too close to another agent's, or to a state colour it could stand for (CIEDE2000
    /// 5.9 from Qoder's pink for Oh My Pi, 9.1 from Codex's blue for Factory; OpenCode's amber 3.6 from the brand amber
    /// and 8.8 from the orange question tint, so it read as needs you; Grok's cyan 9.4 from Codex's): a colour at least
    /// 12 from every other agent's and every state's (P207). OpenCode's own brand is monochrome: silver. A mark near Pink
    /// or Violet keeps its colour (Qoder's, Qwen's, Oh My Pi's); only its running glyph moves (`runningColour`, P782).
    static let colourOverrides: [AgentTool: String] = [.ohMyPi: "#e6a8d9", .factory: "#a8b4e6", .openCode: "#c8c8ce",
                                                       .grokBuild: "#5ee6d8"]

    /// The `#rrggbb` By agent draws `tool` in.
    static func colourHex(_ tool: AgentTool) -> String { colourOverrides[tool] ?? tool.brandColorHex }

    /// Each tool's colour, read once (rows ask at every draw).
    private static let brandColours: [AgentTool: Color] = Dictionary(uniqueKeysWithValues: AgentTool.allCases.compactMap { tool in
        colour(hex: colourHex(tool)).map { (tool, $0) }
    })

    /// Every agent the engine knows besides Claude and Codex. Names as the owner types them (Qwen, not "Qwen Code").
    static let others: [AgentTool: Entry] = [
        .geminiCLI: Entry(name: "Gemini", mark: .spark),
        .cursor: Entry(name: "Cursor", mark: .pointer),
        .openCode: Entry(name: "OpenCode", mark: .tile("O")),
        .kimiCLI: Entry(name: "Kimi", mark: .tile("K")),
        .grokBuild: Entry(name: "Grok", mark: .tile("G")),
        .pi: Entry(name: "Pi", mark: .tile("π")),
        .ohMyPi: Entry(name: "Oh My Pi", mark: .disc("π")),
        .factory: Entry(name: "Factory", mark: .tile("F")),
        .qwenCode: Entry(name: "Qwen", mark: .tile("Q")),
        .qoder: Entry(name: "Qoder", mark: .disc("Q")),
        .codebuddy: Entry(name: "CodeBuddy", mark: .tile("C")),
    ]

    /// An agent `others` does not list, in By agent: the idle grey.
    static let neutral = IslandTheme.ink2

    /// Upstream's `#rrggbb`; nil for anything else.
    static func colour(hex: String) -> Color? {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(hex: value)
    }
}

/// A session's agent mark at a row's size (`Theme.Mark.sessionRow`, 10 pt, or the window's 11), in the agent's colour:
/// Claude's and OpenAI's marks for Claude and Codex, `AgentLook`'s own for the others. Its shape backs up its colour.
struct AgentMarkView: View {
    let agent: GlyphPalette.Agent
    var size: CGFloat
    /// Its parent's theme, passed down rather than read here (P559): Glass draws the agent's colour as its twin for the
    /// glass's look (P562).
    var theme = JuiceTheme.black

    var body: some View {
        let look = AgentLook.of(agent)
        let colour = theme.island.tone(look.colour)
        Group {
            switch look.mark {
            case .claude: ProviderMarkView(provider: .claude, size: size, tint: colour)
            case .openAI: ProviderMarkView(provider: .codex, size: size, tint: colour)
            default: AgentShapeMark(mark: look.mark, side: size, ink: colour)
            }
        }
        .accessibilityLabel(look.name)
    }
}

/// The drawn marks, in a square: the spark and the pointer fill it as Claude's mark does; a tile or a disc is a
/// touch smaller, so its weight matches, with the letter cut out (the row's background shows through it, whatever it
/// is: black, a hover fill or a card).
struct AgentShapeMark: View {
    let mark: AgentLook.Mark
    let side: CGFloat
    var ink: Color = Theme.ink

    var body: some View {
        content.frame(width: side, height: side)
    }

    @ViewBuilder private var content: some View {
        switch mark {
        case .spark: SparkShape().fill(ink)
        case .pointer: PointerShape().fill(ink)
        case let .tile(letter): cutOut(letter, side: side) { RoundedRectangle(cornerRadius: side * 0.24, style: .continuous) }
        case let .disc(letter): cutOut(letter, side: side) { Circle() }
        case .claude, .openAI: EmptyView()
        }
    }

    private func cutOut<S: Shape>(_ letter: String, side: CGFloat, _ shape: () -> S) -> some View {
        let box = side * 0.9
        return ZStack {
            shape().fill(ink)
            Text(verbatim: letter)
                .font(.system(size: box * Self.letterScale(letter), weight: .heavy, design: .rounded))
                .foregroundStyle(Color.black)
                .offset(y: box * Self.letterRise(letter))
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: box, height: box)
    }

    /// A lowercase letter (π) sits on the x-height, so it is drawn larger to read as large as a capital.
    static func letterScale(_ letter: String) -> CGFloat { letter == letter.uppercased() ? 0.74 : 0.9 }

    /// A text box centres its line, descender included, so a capital sits a little high: this lowers it onto the
    /// tile's middle.
    static func letterRise(_ letter: String) -> CGFloat { letter == letter.uppercased() ? 0.02 : -0.02 }
}

/// Four points, the sides curving in (a sparkle, as the `✦` character draws it).
struct SparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let c = CGPoint(x: rect.midX, y: rect.midY), r = side / 2, pull = side * 0.08
        let top = CGPoint(x: c.x, y: c.y - r), right = CGPoint(x: c.x + r, y: c.y)
        let bottom = CGPoint(x: c.x, y: c.y + r), left = CGPoint(x: c.x - r, y: c.y)
        var path = Path()
        path.move(to: top)
        path.addQuadCurve(to: right, control: CGPoint(x: c.x + pull, y: c.y - pull))
        path.addQuadCurve(to: bottom, control: CGPoint(x: c.x + pull, y: c.y + pull))
        path.addQuadCurve(to: left, control: CGPoint(x: c.x - pull, y: c.y + pull))
        path.addQuadCurve(to: top, control: CGPoint(x: c.x - pull, y: c.y - pull))
        path.closeSubpath()
        return path
    }
}

/// A plain pointer arrow, tip at the top left (on a 24-unit grid, centred).
struct PointerShape: Shape {
    static let points: [CGPoint] = [
        CGPoint(x: 5.5, y: 1.5), CGPoint(x: 19, y: 15), CGPoint(x: 13, y: 15), CGPoint(x: 16.2, y: 21.4),
        CGPoint(x: 13.4, y: 22.6), CGPoint(x: 10.3, y: 16.2), CGPoint(x: 5.5, y: 20.5),
    ]

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height), unit = side / 24
        let origin = CGPoint(x: rect.midX - side / 2 + 0.25 * unit, y: rect.midY - side / 2 - 0.05 * unit)
        var path = Path()
        path.addLines(Self.points.map { CGPoint(x: origin.x + $0.x * unit, y: origin.y + $0.y * unit) })
        path.closeSubpath()
        return path
    }
}
