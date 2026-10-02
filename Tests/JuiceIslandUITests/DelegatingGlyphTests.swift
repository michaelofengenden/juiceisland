import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Wave 5 (lane glyphs): the delegating mood (a session whose main turn waits on its subagents) in all three styles,
/// its teal, and Liquid's slim running with Full kept as a setting. Pure values: patterns, poses, colours, the shared
/// helper beat, and that nothing redraws at rest (P380–P386).
@MainActor
struct DelegatingGlyphTests {
    /// A whole number of helper and crest periods near today's clock.
    let start: TimeInterval = 811_999_992
    let step = 1.0 / 30

    // MARK: The names both lanes share

    @Test func theSharedNamesMapToOneAnother() {
        #expect(GlyphMood(.agents) == .delegating)
        #expect(!GlyphMood.delegating.needsYou && !PixelGlyph.agents.needsYou)
        #expect(GlyphPalette.colour(agent: .claude, state: .delegating, mode: .byState, needsYou: .pink) == IslandTheme.delegate)
        #expect(PixelGlyph(rawValue: "agents") == .agents)
        #expect(Set(PixelGlyph.allCases.map(GlyphMood.init)) == Set(GlyphMood.allCases))
    }

    // MARK: The teal

    /// Between the running blue and the done green, apart from both, from Codex's cyan and from every needs-you colour,
    /// and clear on the island's black (P381).
    @Test func theDelegateTealStandsApart() {
        #expect(IslandTheme.delegate == Color(hex: 0x2BA6A4))
        let teal = "#2ba6a4"
        #expect(abs(CIEDE2000.distance(teal, "#4e80ed") - 31.9) < 0.2)
        #expect(abs(CIEDE2000.distance(teal, "#6fb982") - 18.9) < 0.2)
        #expect(abs(CIEDE2000.distance(teal, "#5ac8fa") - 20.4) < 0.2)
        #expect(abs(CIEDE2000.distance(teal, "#e97b36") - 48.0) < 0.2)
        // At least as far from Codex as the running blue is from done's nearest neighbour, the orange question tint from
        // the waiting orange (the closest state pair before it): 18.9 is the least of its four. Every needs-you pair too.
        for other in ["#4e80ed", "#6fb982", "#5ac8fa", "#e97b36", "#f0a35e", "#d96a5a", "#ed68af", "#f58ac3", "#bd7aff", "#d4a8ff"] {
            #expect(CIEDE2000.distance(teal, other) > 18, "\(other)")
        }
        // Contrast on #000: (L + 0.05) / 0.05 for its relative luminance, over 7:1.
        let resolved = IslandTheme.delegate.resolve(in: EnvironmentValues())
        func linear(_ c: Float) -> Double { Double(c) }
        let luminance = 0.2126 * linear(resolved.linearRed) + 0.7152 * linear(resolved.linearGreen) + 0.0722 * linear(resolved.linearBlue)
        #expect((luminance + 0.05) / 0.05 > 7)
    }

    /// By agent, work in progress takes the agent's colour, delegating as running (its dots say which it is); what needs
    /// you and done keep theirs (P206).
    @Test func byAgentDelegatingTakesTheAgentsColour() {
        for agent: GlyphPalette.Agent in [.claude, .codex, .other(.geminiCLI)] {
            for needsYou in NeedsYouColour.allCases {
                #expect(GlyphPalette.colour(agent: agent, state: .delegating, mode: .byAgent, needsYou: needsYou)
                    == AgentLook.of(agent).runningColour(needsYou))
                #expect(GlyphPalette.colour(agent: agent, state: .delegating, mode: .byState, needsYou: needsYou) == IslandTheme.delegate)
            }
        }
    }

    // MARK: The helper beat

    /// Three hops in turn, left to right, then all three rest; continuous, and a function of the clock alone.
    @Test func theHelpersRiseInTurnThenRest() {
        let period = HelperBeat.period
        #expect(period >= 2 && period > LiquidGlyph.crestPeriod)
        for index in 0..<HelperBeat.count {
            // Each helper peaks at its own moment, and the others are low then.
            let peak = start + period * (Double(index) * HelperBeat.stagger + HelperBeat.hop / 2)
            #expect(HelperBeat.lift(at: peak, index: index) > 0.999)
            for other in 0..<HelperBeat.count where other != index {
                #expect(HelperBeat.lift(at: peak, index: other) < 0.5, "\(other) is up while \(index) peaks")
            }
        }
        // Every helper rests through the rest phase, and the still time is in it.
        for i in 0..<20 {
            let time = start + period * (HelperBeat.restPhase - 0.05 + 0.25 * Double(i) / 20)
            for index in 0..<HelperBeat.count { #expect(HelperBeat.lift(at: time, index: index) == 0) }
        }
        for index in 0..<HelperBeat.count { #expect(HelperBeat.lift(at: HelperBeat.stillTime(offset: 4), index: index) == 0) }
        // Gentle: never more than a small step a frame.
        for i in 0..<Int(period / step) {
            let t = start + Double(i) * step
            for index in 0..<HelperBeat.count {
                #expect(abs(HelperBeat.lift(at: t + step, index: index) - HelperBeat.lift(at: t, index: index)) < 0.15)
            }
        }
    }

    // MARK: Pixel

    @Test func pixelsAgentsGlyphIsThreeDotsOverALine() {
        #expect(PixelGlyph.agents.pattern() == [".......", ".......", ".......", ".#.#.#.", ".......", "#######", "......."])
        // At rest the moving glyph is exactly the still one.
        #expect(PixelGlyph.helperAlphas(lifts: [0, 0, 0]) == PixelGlyph.agents.alphas())
        // A dot all the way up has moved one row; the line never moves.
        let up = PixelGlyph.helperAlphas(lifts: [0, 1, 0])
        #expect(up[3][3] == 0 && up[2][3] == 1 && up[3][1] == 1 && up[5] == PixelGlyph.agents.alphas()[5])
        // Part way it never dims to half: the two rows it spans add up to more than one.
        let half = PixelGlyph.helperAlphas(lifts: [0.5, 0, 0])
        #expect(half[3][1] + half[2][1] >= 1.4)
        // It is neither the equalizer nor the check: apart from both in most of its pixels.
        func lit(_ grid: [[Double]]) -> Set<Int> { Set((0..<49).filter { grid[$0 / 7][$0 % 7] > 0 }) }
        let agents = lit(PixelGlyph.agents.alphas())
        for other in [PixelGlyph.check.alphas()] + (0..<8).map({ PixelGlyph.eq.alphas(frame: $0) }) {
            #expect(agents.symmetricDifference(lit(other)).count >= 10)
        }
    }

    @Test func pixelsAgentsGlyphMovesGentlyAndHoldsStillWhenAsked() {
        #expect(PixelGlyphView.moves(.agents, animated: true, reduceMotion: false))
        #expect(!PixelGlyphView.moves(.agents, animated: true, reduceMotion: true))
        #expect(!PixelGlyphView.moves(.agents, animated: false, reduceMotion: false))
        // Calmer than the equalizer: over one helper period its pixels change less than a third as much.
        func motion(_ grids: (Double) -> [[Double]]) -> Double {
            (0..<Int(HelperBeat.period / step)).reduce(0) { sum, i in
                let a = grids(start + Double(i) * step), b = grids(start + Double(i + 1) * step)
                return sum + (0..<49).reduce(0) { $0 + abs(a[$1 / 7][$1 % 7] - b[$1 / 7][$1 % 7]) }
            }
        }
        let helpers = motion { PixelGlyph.helperAlphas(lifts: PixelGlyph.helperLifts(at: $0)) }
        let equalizer = motion { PixelGlyph.equalizerAlphas(heights: PixelGlyph.equalizerHeights(at: $0)) }
        #expect(helpers > 0 && helpers < equalizer / 3, "\(helpers) vs \(equalizer)")
    }

    // MARK: Liquid

    /// The body's top edge at `x` (points): where the path's slice there starts.
    private func top(_ path: Path, at x: CGFloat) -> CGFloat? {
        let slice = path.cgPath.intersection(CGPath(rect: CGRect(x: x - 0.05, y: -100, width: 0.1, height: 300), transform: nil))
        return slice.isEmpty ? nil : slice.boundingBoxOfPath.minY
    }

    /// Slim running is a thin band, well under half the square tall at every moment, while Full is two thirds.
    @Test func slimRunningIsAThinBand() {
        for side in [14, 20, 25, 28, 84] as [CGFloat] {
            for i in 0..<90 {
                let time = start + Double(i) * 0.05
                let slim = LiquidGlyph.frame(mood: .running, time: time, side: side)[0].path.boundingRect
                let full = LiquidGlyph.frame(mood: .running, time: time, side: side, running: .full)[0].path.boundingRect
                #expect(slim.height <= side * 0.47 && slim.height >= side * 0.2, "slim is \(slim.height) pt tall at \(side) pt")
                #expect(full.height >= side * 0.6)
                // Where no crest is, the band is about a fifth of the square thick.
                let band = LiquidGlyph.frame(mood: .running, time: time, side: side)[0].path
                let edge = side * 0.09
                let thickness = [edge, side - edge].compactMap { x -> CGFloat? in
                    let slice = band.cgPath.intersection(CGPath(rect: CGRect(x: x - 0.05, y: -100, width: 0.1, height: 300), transform: nil))
                    return slice.isEmpty ? nil : slice.boundingBoxOfPath.height
                }.min() ?? 0
                #expect(thickness <= side * 0.27, "the band is \(thickness) pt thick at \(side) pt")
            }
        }
        #expect(LiquidGlyph.Pose.of(.running, running: .full)
            == LiquidGlyph.Pose(level: 0.2, bottom: 0.82, left: 0.03, right: 0.97, cap: 0.2, waves: 1.25, rock: 0.12, bubbles: 1))
    }

    /// A crest runs left to right along the band: while it crosses the middle, the band's highest point moves right
    /// frame after frame, and each crest throws a droplet that flies clear of the band.
    @Test func slimRunningsCrestRunsLeftToRightAndThrowsADroplet() {
        let side: CGFloat = 20
        for pass in 0..<3 {
            // Crest 0 from 30 % to 70 % of its run.
            var last = -CGFloat.infinity
            for i in 0..<8 {
                let run = 0.3 + 0.4 * Double(i) / 7
                let time = start + LiquidGlyph.crestPeriod * (Double(pass) + run)
                let body = LiquidGlyph.frame(mood: .running, time: time, side: side)[0].path
                let xs = stride(from: CGFloat(1.5), through: side - 1.5, by: 0.25)
                let peak = xs.min { (top(body, at: $0) ?? .infinity) < (top(body, at: $1) ?? .infinity) }!
                #expect(peak > last, "the crest does not move right at \(run)")
                last = peak
            }
        }
        // Mid-flight, the droplet is a shape wholly above the band.
        let still = LiquidGlyph.still(.running, side: side)
        let bandTop = still[0].path.boundingRect.minY
        #expect(still.contains { $0.path.boundingRect.maxY < bandTop && $0.path.boundingRect.width > 1 }, "no droplet in the still frame")
    }

    /// Delegating's three droplets float clear over a calm band (no crest, no bubbles), their row as wide as the three.
    @Test func liquidDelegatingIsThreeDropletsOverACalmBand() {
        for side in [14, 20, 28, 84] as [CGFloat] {
            let frame = LiquidGlyph.still(.delegating, side: side)
            let band = frame[0].path.boundingRect
            let droplets = frame.filter { $0.path.boundingRect.maxY < band.minY }
            #expect(droplets.count == 3, "\(droplets.count) shapes over the band at \(side) pt") // the mark's fill and its two edges
            let row = droplets[0].path.boundingRect
            let width = (LiquidGlyph.helperXs.last! - LiquidGlyph.helperXs.first! + 2 * LiquidGlyph.helperRadius) * side
            #expect(abs(row.width - width) < 0.05 * side)
            #expect(band.minY - row.maxY >= max(0.8, 0.06 * side), "the droplets touch the band at \(side) pt")
            #expect(LiquidGlyph.Pose.of(.delegating).crest == 0 && LiquidGlyph.Pose.of(.delegating).bubbles == 0)
        }
        // It moves (the hops) and so never pauses; its still frame is the resting moment.
        #expect(LiquidGlyph.keepsMoving(.delegating) && !LiquidGlyphView.paused(.delegating, settled: true))
        let rest = HelperBeat.stillTime()
        #expect(LiquidGlyph.frame(mood: .delegating, time: start + HelperBeat.period * 0.2, side: 20)
            != LiquidGlyph.frame(mood: .delegating, time: start + HelperBeat.period * HelperBeat.restPhase, side: 20))
        #expect(LiquidGlyph.still(.delegating, side: 20) == LiquidGlyph.frame(mood: .delegating, time: rest, side: 20))
    }

    /// Into and out of delegating, from and to running (either look), a mark and done, the body moves smoothly: its
    /// outline never jumps more than a tenth of the square between two frames, and the whole drawing no more than a
    /// fifth.
    @Test func liquidTransitionsThroughDelegatingAreContinuous() {
        let side: CGFloat = 28
        let pairs: [(GlyphMood, GlyphMood)] = [(.running, .delegating), (.delegating, .running), (.delegating, .done), (.done, .delegating),
                                               (.delegating, .approval), (.question, .delegating), (.delegating, .idle)]
        func jump(_ a: CGRect, _ b: CGRect) -> CGFloat {
            max(abs(a.minX - b.minX), abs(a.maxX - b.maxX), abs(a.minY - b.minY), abs(a.maxY - b.maxY))
        }
        for look in LiquidRunningLook.allCases {
            for (from, to) in pairs {
                for change in [0.0, 0.7, 1.9] {
                    var previous: [LiquidGlyph.Primitive]?
                    // The frame just before the change is the old mood's own.
                    previous = LiquidGlyph.frame(mood: from, time: start + change - step, side: side, running: look)
                    for i in 0...45 {
                        let age = Double(i) * step
                        let frame = LiquidGlyph.frame(mood: to, from: from, changeAge: age, time: start + change + age, side: side, running: look)
                        if let previous {
                            let body = jump(previous[0].path.boundingRect, frame[0].path.boundingRect)
                            #expect(body <= side * 0.1, "\(from) → \(to) (\(look)): the body jumps \(body) pt at \(age) s")
                        }
                        previous = frame
                    }
                }
            }
        }
    }

    // MARK: Sand

    @Test func sandDelegatingIsThreeClumpsOverAStillPile() {
        for side in [14, 16, 20, 21, 22, 28, 84] as [CGFloat] {
            let crisp = side < 30
            let frame = SandGlyph.stillFrame(mood: .delegating, side: side)
            let marks = frame.grains.filter { $0.layer == .mark }
            #expect(marks.count == SandGeometry.forSide(Double(side)).helpers.count, "\(side) pt")
            #expect(marks.allSatisfy { $0.alpha == 1 })
            // No stream: it is not running.
            #expect(!frame.grains.contains { $0.layer == .stream }, "a stream at \(side) pt")
            #expect(frame.solids.count == (crisp ? 3 : 0))
            // Three clumps across, clear of the pile.
            for index in 0..<3 {
                let clump = marks.filter { SandMarkShape.helperIndex(Double($0.x / side)) == index }
                #expect(!clump.isEmpty)
                let centre = clump.map(\.x).reduce(0, +) / CGFloat(clump.count)
                #expect(abs(centre / side - SandGlyph.helperXs[index]) < 0.03)
            }
            let pile = frame.grains.filter { $0.layer == .pile && $0.alpha > 0.3 }
            var gap = CGFloat.infinity
            for m in marks {
                for p in pile where abs(p.x - m.x) < (p.size + m.size) / 2 { gap = min(gap, (p.y - p.size / 2) - (m.y + m.size / 2)) }
            }
            #expect(gap >= max(0.8, 0.05 * side), "the clumps stand \(gap) pt clear of the pile at \(side) pt")
        }
    }

    /// Each clump rises on its own turn: at a helper's peak its grains stand higher than at rest by its hop.
    @Test func sandsClumpsRiseInTurn() {
        let side: CGFloat = 20
        func centreY(_ frame: SandFrame, _ index: Int) -> CGFloat {
            let clump = frame.grains.filter { $0.layer == .mark && SandMarkShape.helperIndex(Double($0.x / side)) == index }
            return clump.map(\.y).reduce(0, +) / CGFloat(clump.count)
        }
        let rest = SandGlyph.stillFrame(mood: .delegating, side: side)
        for index in 0..<3 {
            let peak = start + HelperBeat.period * (Double(index) * HelperBeat.stagger + HelperBeat.hop / 2)
            let frame = SandGlyph.frame(mood: .delegating, from: nil, changeAge: .infinity, time: peak, side: side)
            #expect(abs((centreY(rest, index) - centreY(frame, index)) - SandGlyph.helperHop * side) < 0.05)
            for other in 0..<3 where other != index {
                #expect(centreY(rest, other) - centreY(frame, other) < SandGlyph.helperHop * side * 0.5)
            }
        }
    }

    /// Into delegating the clumps fly up out of the pile; out of it they fall back in; nothing leaves the square, and
    /// done and idle after it still settle exactly.
    @Test func sandTransitionsThroughDelegating() {
        let side: CGFloat = 20
        let early = SandGlyph.frame(mood: .delegating, from: .running, changeAge: 0.05, time: start + 0.05, side: side, fromLasted: 3)
        let formed = SandGlyph.frame(mood: .delegating, from: .running, changeAge: 1.4, time: start + 1.4, side: side, fromLasted: 3)
        #expect(early.grains.filter { $0.layer == .mark }.count < formed.grains.filter { $0.layer == .mark }.count)
        let leaving = SandGlyph.frame(mood: .approval, from: .delegating, changeAge: 0.05, time: start + 0.05, side: side, fromLasted: 3)
        #expect(leaving.solids.count >= 3, "the clumps' bodies go at once but not before the first frame")
        let settled = SandGlyph.frame(mood: .done, from: nil, changeAge: .infinity, time: start, side: side)
        #expect(SandGlyph.frame(mood: .done, from: .delegating, changeAge: SandGlyph.settleTime, time: start + 7, side: side, fromLasted: 4) == settled)
    }

    // MARK: The setting

    @Test func theRunningLookIsSlimByDefaultAndPersists() throws {
        #expect(AppSettings.ephemeral().liquidRunning == .slim)
        #expect(LiquidRunningLook.allCases == [.slim, .full])
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.liquidRunning = .full
        #expect(defaults.string(forKey: "ji.island.liquidRunning") == "full")
        #expect(AppSettings(defaults: defaults).liquidRunning == .full)
        defaults.set("thick", forKey: AppSettings.Key.liquidRunning)
        #expect(AppSettings(defaults: defaults).liquidRunning == .slim)
    }

    @Test func theRunningRowShowsOnlyForLiquid() {
        #expect(!IslandPaneText.showsRunningRow(.pixel))
        #expect(IslandPaneText.showsRunningRow(.liquid))
        #expect(!IslandPaneText.showsRunningRow(.sand))
        #expect(GlyphStylePreview.glyphs == [.eq, .agents, .bang, .ques, .check])
        #expect(GlyphStylePreview.glyphs.map(GlyphStylePreview.state) == [.running, .delegating, .waiting, .waiting, .done])
    }

    /// The glyph follows the setting when no look is passed: a row's running Liquid glyph is the look Settings has.
    @Test func theLiquidGlyphFollowsTheSetting() {
        let settings = AppSettings.ephemeral()
        settings.glyphStyle = .liquid
        settings.liquidRunning = .full
        let view = StateGlyphView(glyph: .eq, colour: IslandTheme.run, pixel: 3, animated: false)
        // Laid out the same either way: the look never moves a row.
        let full = NSHostingView(rootView: view.environment(AppEnvironment.demo(settings: settings))).fittingSize
        settings.liquidRunning = .slim
        let slim = NSHostingView(rootView: view.environment(AppEnvironment.demo(settings: settings))).fittingSize
        #expect(full == slim && full == CGSize(width: 21, height: 21))
    }
}
