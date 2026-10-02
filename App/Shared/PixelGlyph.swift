import OpenIslandCore
import SwiftUI

/// Our 7 × 7 pixel glyphs (prototype.md §5.3, L1044-1059). `#` on, `.` off, `+` a 38 % pixel (above an equalizer bar).
enum PixelGlyph: String, CaseIterable, Sendable {
    case brand, bang, ques, check, eq
    /// A turn that failed (a StopFailure): it needs you, in the waiting tone, but nothing waits on an answer, so it
    /// never pulses (P159).
    case cross
    /// A session whose main turn waits on its subagents: three dots that step up in turn (`HelperBeat`), calmer than
    /// the equalizer. It asks nothing of you.
    case agents

    static let size = 7

    static let patterns: [PixelGlyph: [String]] = [
        .brand: [".....#.", "....#..", ".#####.", ".#...#.", ".#####.", ".#####.", "..###.."],
        .bang: ["..###..", "..###..", "..###..", "..###..", "...#...", ".......", "..###.."],
        .ques: [".#####.", "##...##", ".....##", "...###.", "..##...", ".......", "..##..."],
        .check: [".......", "......#", ".....##", "#...##.", "##.##..", ".###...", "..#...."],
        .cross: ["##...##", ".##.##.", "..###..", "...#...", "..###..", ".##.##.", "##...##"],
        .agents: [".......", ".......", ".......", ".#.#.#.", ".......", "#######", "......."],
    ]

    /// Equalizer bar heights for columns 0, 2, 4, 6: the eight still frames (renders, Reduce Motion; `frame` picks one).
    static let equalizerFrames: [[Int]] = [
        [3, 5, 2, 6], [4, 6, 3, 5], [6, 4, 4, 3], [5, 2, 6, 4], [3, 4, 5, 6], [2, 6, 3, 5], [4, 5, 6, 2], [6, 3, 4, 4],
    ]

    /// The rows for this glyph; `frame` picks the equalizer frame (ignored by the others).
    func pattern(frame: Int = 0) -> [String] {
        guard self == .eq else { return Self.patterns[self]! }
        let heights = Self.equalizerFrames[((frame % 8) + 8) % 8]
        return (0..<7).map { y in
            String((0..<7).map { x -> Character in
                guard x % 2 == 0 else { return "." }
                let height = heights[x / 2], fromBottom = 6 - y
                return fromBottom < height ? "#" : (fromBottom == height ? "+" : ".")
            })
        }
    }

    /// Whether this glyph asks for you (it blinks: its glow pulses).
    var needsYou: Bool { self == .bang || self == .ques }

    // MARK: Opacities

    /// Each pixel's opacity, row by row (0 off), for the still glyph: the top pixel of a column 100 %, lower ones 85 %,
    /// a `+` 38 % (it is the top of its column, so an equalizer's bars are 85 % under a 38 % cap).
    func alphas(frame: Int = 0) -> [[Double]] { Self.alphas(rows: pattern(frame: frame)) }

    static func alphas(rows: [String]) -> [[Double]] {
        var grid = Array(repeating: Array(repeating: 0.0, count: 7), count: 7)
        for x in 0..<7 {
            var top = true
            for y in 0..<7 {
                let character = Array(rows[y])[x]
                guard character != "." else { continue }
                grid[y][x] = character == "+" ? 0.38 : (top ? 1 : 0.85)
                top = false
            }
        }
        return grid
    }

    // MARK: Motion

    /// How often a moving glyph redraws: 30 times a second, smooth at 2–3 pt pixels and light on the CPU.
    static let motionInterval: TimeInterval = 1.0 / 30

    /// Bar sines: amplitudes (they add up to 2, so a bar stays in 2…6 around 4), and per bar its periods (s) and
    /// phases (turns). Periods differ from bar to bar and never share a short common multiple, so the dance never
    /// reads as a loop.
    private static let barAmplitudes: [Double] = [1.2, 0.5, 0.3]
    private static let barPeriods: [[Double]] = [[0.93, 0.57, 2.71], [0.81, 0.63, 3.13], [1.07, 0.53, 2.37], [0.87, 0.67, 2.89]]
    private static let barPhases: [[Double]] = [[0.0, 0.31, 0.65], [0.35, 0.11, 0.21], [0.64, 0.49, 0.89], [0.18, 0.83, 0.45]]
    /// The tallest bar is never below this: when all four sink under it they are lifted together.
    static let equalizerLowestPeak: Double = 3
    /// A second equalizer's `offset` shifts its clock by this much a step, so two side by side move differently.
    static let equalizerOffsetShift: TimeInterval = 0.77

    /// The moving equalizer's bar heights (columns 0, 2, 4, 6) at `time`, each in 2…6 and continuous in time: 4 plus
    /// three sines of the bar's own periods and phases. When all four are under `equalizerLowestPeak` they are lifted
    /// together until the tallest reaches it, so the bars never rest on the floor at once. A function of the clock
    /// alone: every redraw, and a view re-created mid-motion, lands on the same curve.
    static func equalizerHeights(at time: TimeInterval, offset: Int = 0) -> [Double] {
        let clock = time + Double(offset) * equalizerOffsetShift
        let raw = (0..<4).map { bar in
            (0..<3).reduce(4.0) { height, k in
                let turns = (clock / barPeriods[bar][k] + barPhases[bar][k]).truncatingRemainder(dividingBy: 1)
                return height + barAmplitudes[k] * sin(2 * .pi * turns)
            }
        }
        let lift = max(0, equalizerLowestPeak - (raw.max() ?? equalizerLowestPeak))
        return raw.map { min(6, max(2, $0 + lift)) }
    }

    /// The equalizer's opacities for fractional bar heights: a bar of height n + f is the still bar of height n
    /// blended toward n + 1 by f, so its top pixel fades in (38 % → 85 %) while the dim cap above it fades in
    /// (0 → 38 %). At whole heights this is exactly the still frame's grid.
    static func equalizerAlphas(heights: [Double]) -> [[Double]] {
        func still(_ bar: Int, _ fromBottom: Int) -> Double {
            fromBottom < bar ? 0.85 : (fromBottom == bar ? 0.38 : 0)
        }
        var grid = Array(repeating: Array(repeating: 0.0, count: 7), count: 7)
        for (column, height) in heights.prefix(4).enumerated() {
            let clamped = min(6, max(0, height))
            let whole = Int(clamped.rounded(.down)), fraction = clamped - Double(whole)
            for y in 0..<7 {
                let fromBottom = 6 - y
                grid[y][column * 2] = (1 - fraction) * still(whole, fromBottom) + fraction * still(whole + 1, fromBottom)
            }
        }
        return grid
    }

    /// Delegating's dots: columns 1, 3 and 5, resting on `helperRow` over the calm line of row 5 (the main turn); a hop
    /// lifts one a row (`HelperBeat.lift`).
    static let helperColumns = [1, 3, 5], helperRow = 3

    /// The delegating glyph's opacities for its dots' lifts (0 resting … 1 a row up): the line as the still pattern
    /// has it, and a dot part way split between its two rows, each eased (1 − lift², 1 − (1 − lift)²) so it never dims
    /// to half mid-hop. With every lift 0 this is exactly the still pattern's grid.
    static func helperAlphas(lifts: [Double]) -> [[Double]] {
        var grid = PixelGlyph.agents.alphas()
        for (index, column) in helperColumns.enumerated() {
            let lift = min(1, max(0, index < lifts.count ? lifts[index] : 0))
            grid[helperRow][column] = 1 - lift * lift
            grid[helperRow - 1][column] = 1 - (1 - lift) * (1 - lift)
        }
        return grid
    }

    /// The dots' lifts at `time`, from the one clock every delegating glyph shares.
    static func helperLifts(at time: TimeInterval) -> [Double] {
        (0..<HelperBeat.count).map { HelperBeat.lift(at: time, index: $0) }
    }

    /// The needs-you glow's breath: 0 (rest) to 1 (bright) and back once a period, an eased sine of the clock.
    static let pulsePeriod: TimeInterval = 3.2

    /// The pulse at `time`, 0…1. It depends on the clock alone, so every needs-you glyph breathes in step and a row
    /// re-created by a list update picks up mid-breath instead of starting over.
    static func pulse(at time: TimeInterval) -> Double {
        let turns = (time / pulsePeriod).truncatingRemainder(dividingBy: 1)
        return 0.5 - 0.5 * cos(2 * .pi * turns)
    }
}

/// The glyph colour rule (prototype L979, C20): by state, or by the session's own agent.
enum GlyphPalette {
    /// Whose session it is: Claude, Codex, or another agent Open Island's engine knows (Gemini CLI, Cursor, OpenCode,
    /// Kimi, Grok, Pi, …), by its own tool. A Claude Code fork (Kimi, Qwen, Factory, …) is itself, not Claude (P151).
    /// Its name, mark and colour: `AgentLook`.
    enum Agent: Hashable, Sendable {
        case claude, codex
        case other(AgentTool)
    }

    /// `delegating`: the main turn waits on its subagents (the `agents` glyph).
    enum State: Sendable { case running, waiting, done, idle, delegating }

    /// By state: the state's colour. By agent: the agent's colour for work in progress only, a running or a delegating
    /// glyph (P206; the agents glyph's dots say which of the two it is): approval, question and failed stay the
    /// needs-you colour (`needsYou`, Settings › Island › Needs you colour; Liquid and Sand draw a failed turn as done)
    /// and done stays green, so what needs you pops as it does by state. Claude's running glyph is its redder tint, and
    /// an agent whose colour sits near the needs-you colour runs in the running blue (`AgentLook.runningColour`, P207).
    /// `idle`: the idle mark's grey on the surface it is drawn on (`IslandPalette.idleMark`; Black's by default).
    /// `palette`: the theme it is drawn in; a mark that is not a glyph (a row's dot) on Glass is its colour's twin for
    /// the glass's look (`IslandPalette.tone`), Black and Smoke as it is.
    static func colour(agent: Agent, state: State, mode: GlyphColourMode, needsYou: NeedsYouColour, idle: Color = IslandTheme.idleMark,
                       palette: IslandPalette = .black) -> Color {
        state == .idle ? idle : palette.tone(glyph(agent: agent, state: state, mode: mode, needsYou: needsYou, idle: idle))
    }

    /// A session glyph's colour: the state's or the agent's own, at full strength in every theme. On Glass the glyph's
    /// edge carries its contrast (`GlyphFinish`, P590), so its colour is never nudged lighter or darker.
    static func glyph(agent: Agent, state: State, mode: GlyphColourMode, needsYou: NeedsYouColour,
                      idle: Color = IslandTheme.idleMark) -> Color {
        if mode == .byAgent, state == .running || state == .delegating { return AgentLook.of(agent).runningColour(needsYou) }
        switch state {
        case .running: return IslandTheme.run
        case .delegating: return IslandTheme.delegate
        case .waiting: return needsYou.wait
        case .done: return IslandTheme.done
        case .idle: return idle
        }
    }
}
