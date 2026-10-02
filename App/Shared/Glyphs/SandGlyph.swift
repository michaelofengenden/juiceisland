import SwiftUI

/// Draws the Sand glyph (`SandGlyph`) for a `GlyphMood` in a `side`-point square: 28 pt in the closed pill (24 in the
/// top bar), 20 pt in the island's rows and 24 in the window's, 14 pt at the smallest. Every grain is a vector dot
/// drawn at the screen's scale, in `colour` and lighter or darker mixes of it, on a transparent square. Dimmed is 42 %
/// (on Glass, opaque in `GlassGlyph.dimmed`, P594), with no glow and no motion. Glow: two soft shadows behind the sand, fainter and wider than Pixel's so the fine
/// grains stay sharp.
///
/// Motion runs off one clock (`GlyphTimeline`: at most 30 frames a second, none while its surface is hidden): every
/// grain is a function of the time, shifted by `frameOffset`, and of the last mood change, which the view keeps with
/// the mood before it. A glyph that appears starts settled in its mood, so a row that a list update re-creates never
/// replays an entrance. Done and idle settle within `SandGlyph.settleTime` of a change, and their timeline then pauses;
/// a colour change runs it again for the crossfade. Under Reduce Motion, or when `animated` is false (renders pass
/// false), the glyph draws `SandGlyph.stillFrame` and has no timeline.
struct SandGlyphView: View {
    let mood: GlyphMood
    var colour: Color
    var side: CGFloat = 20
    var dimmed = false
    var glow = true
    var animated = true
    /// Shifts the clock by `SandGlyph.offsetShift` a step, so two glyphs side by side move differently.
    var frameOffset = 0
    /// Glass: its lights kept short of washing the colour out, the edge and the bloom for the glow (`GlyphFinish`).
    var finish: GlyphFinish = .plain

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.glyphsStill) private var still
    /// The mood the glyph last saw and the change that led to it (none while it is in the mood it appeared in).
    @State private var history: SandMoodHistory?
    /// The still mood (done or idle) that has settled since its change, so the timeline can pause.
    @State private var restingMood: GlyphMood?
    /// The colour before the last colour change and when it changed, while its crossfade runs (nil once it has).
    @State private var colourChange: SandColourChange?

    var body: some View {
        content
            .glyphFrame(width: side, height: side)
            .onAppear {
                if history == nil { history = SandMoodHistory(mood: mood) }
                restingMood = mood
            }
            .onChange(of: mood) { old, new in
                history = (history ?? SandMoodHistory(mood: old)).changed(to: new, at: Date().timeIntervalSinceReferenceDate)
                restingMood = nil
            }
            .onChange(of: colour) { old, _ in
                colourChange = SandColourChange(from: old, at: Date().timeIntervalSinceReferenceDate)
            }
            .task(id: history?.at) {
                guard let history, history.from != nil, !SandGlyph.keepsMoving(history.mood) else { return }
                let wait = history.at + SandGlyph.settleTime - Date().timeIntervalSinceReferenceDate
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if !Task.isCancelled { restingMood = history.mood }
            }
            .task(id: colourChange?.at) {
                // Dropping the change once it has faded lets a resting glyph pause again, on the new colour whatever
                // moment its paused timeline redraws.
                guard let at = colourChange?.at else { return }
                let wait = at + SandColourChange.fadeTime - Date().timeIntervalSinceReferenceDate
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if !Task.isCancelled { colourChange = nil }
            }
    }

    /// Moving or still, one timeline over one frame view (a still glyph rests on its still frame), so turning it still or
    /// moving (the island closing or opening) changes values, never the views (P102).
    private var content: some View {
        let moves = Self.moves(animated: animated && !still, dimmed: dimmed, reduceMotion: reduceMotion)
        return GlyphTimeline(interval: SandGlyph.motionInterval, resting: !moves || resting) { date in
            moves ? moment(at: date) : drawn(SandGlyph.stillFrame(mood: mood, side: side, offset: frameOffset))
        }
    }

    /// Whether the glyph moves: not when dimmed, under Reduce Motion or when `animated` is false (its timeline then rests
    /// on the still frame).
    nonisolated static func moves(animated: Bool, dimmed: Bool, reduceMotion: Bool) -> Bool {
        animated && !dimmed && !reduceMotion
    }

    /// A done or idle glyph whose change has played out: it draws its settled frame and its timeline pauses.
    private var resting: Bool { Self.rests(mood: mood, restingMood: restingMood, fading: colourChange != nil) }

    /// Whether a glyph in `mood` can pause: a still mood that has settled (`restingMood`), with no colour crossfade
    /// running, since a paused timeline would hold the old colour.
    nonisolated static func rests(mood: GlyphMood, restingMood: GlyphMood?, fading: Bool) -> Bool {
        !SandGlyph.keepsMoving(mood) && restingMood == mood && !fading
    }

    /// The glyph as it looks at `date`.
    private func moment(at date: Date) -> SandFrameView {
        let now = date.timeIntervalSinceReferenceDate
        // A mood that `onChange` has not recorded yet changed just now.
        let seen = history.map { $0.mood == mood ? $0 : $0.changed(to: mood, at: now) }
        var age = seen.map { now - $0.at } ?? .infinity
        if resting { age = max(age, SandGlyph.settleTime) }
        let frame = SandGlyph.frame(mood: mood, from: seen?.from, changeAge: age,
                                    time: now + Double(frameOffset) * SandGlyph.offsetShift, side: side,
                                    fromLasted: seen?.fromLasted)
        let fade = colourChange.map { min(1, max(0, (now - $0.at) / SandColourChange.fadeTime)) } ?? 1
        return drawn(frame, fromColour: fade < 1 ? colourChange?.from : nil, colourMix: fade)
    }

    private func drawn(_ frame: SandFrame, fromColour: Color? = nil, colourMix: Double = 1) -> SandFrameView {
        SandFrameView(frame: frame, colour: colour, side: side, dimmed: dimmed, glow: glow, fromColour: fromColour,
                      colourMix: colourMix, finish: finish)
    }
}

/// What a Sand glyph remembers of its moods: the mood it last saw, and the change that led to it (the mood before,
/// when it changed in reference-date seconds, and how long the mood before had lasted: nil when that was the mood the
/// glyph appeared in, whose needs-you beat ran on the clock).
struct SandMoodHistory: Equatable {
    var mood: GlyphMood
    var from: GlyphMood?
    var at: TimeInterval = 0
    var fromLasted: TimeInterval?

    func changed(to new: GlyphMood, at now: TimeInterval) -> SandMoodHistory {
        SandMoodHistory(mood: new, from: mood, at: now, fromLasted: from == nil ? nil : now - at)
    }
}

/// One frame of the Sand glyph as the app draws it: the grains, 42 % when dimmed (on Glass, opaque in
/// `GlassGlyph.dimmed`), and the glow unless dimmed, both in the colour crossfaded from `fromColour` by `colourMix`. The
/// glyph view draws its frames with this; renders draw `SandGlyph.frame` at explicit times with it.
struct SandFrameView: View {
    let frame: SandFrame
    let colour: Color
    var side: CGFloat = 20
    var dimmed = false
    var glow = true
    var fromColour: Color?
    var colourMix: Double = 1
    var finish: GlyphFinish = .plain

    var body: some View {
        switch finish {
        case .plain:
            SandGrainCanvas(grains: frame.grains, solids: frame.solids, sparkle: frame.sparkle, colour: colour,
                            fromColour: fromColour, colourMix: colourMix, opacity: dimmed ? 0.42 : 1)
                .frame(width: side, height: side)
                .modifier(SandGlow(colour: glowColour, strength: glow && !dimmed ? frame.glow : 0, side: side))
        case .glass:
            // Dimmed: opaque, in the colour stepped toward the glass and matte, over the full edge (P594).
            SandGrainCanvas(grains: frame.grains, solids: frame.solids, sparkle: frame.sparkle, colour: colour,
                            fromColour: fromColour, colourMix: colourMix, light: dimmed ? GlassGlyph.matte : GlassGlyph.light,
                            glassDimmed: dimmed)
                .frame(width: side, height: side)
                .modifier(GlassGlyphFinish(colour: glowColour, side: side, bloom: glow && !dimmed ? frame.glow : 0,
                                           radius: min(8, side * 0.22)))
        }
    }

    /// The glow's colour: the grains' crossfade while one runs, so the glow never snaps ahead of them.
    private var glowColour: Color {
        guard let fromColour, colourMix < 1 else { return colour }
        return fromColour.mix(with: colour, by: colourMix)
    }
}

/// Draws the Sand rim (`SandRim`) in the closed pill's bottom band, `width` × `height` points (the body's lowest 3 pt):
/// a dense bed of grains flowing along the edge, brighter grains riding its crests and a few hopping, while `running`;
/// when it turns false they slow, drain from both ends and are gone within `SandRim.drainTime`, and the timeline
/// pauses. Its glow stays inside the band. Under Reduce Motion, or when `animated` is false, a running rim holds one
/// still frame and a stopped one draws nothing.
struct SandRimView: View {
    var running: Bool
    var colour: Color
    var width: CGFloat
    var height: CGFloat = IslandTheme.Metrics.pillEdgeLine
    /// How much of the line shows from each end (nil: all of it).
    var ends: RimEnds?
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What `running` last was and when it changed (nil while it is what it was when the rim appeared).
    @State private var seen: Bool?
    @State private var changedAt: TimeInterval?
    /// The stop (its `changedAt`) whose drain has finished, so the timeline can pause.
    @State private var drainedStop: TimeInterval?

    var body: some View {
        content
            .glyphFrame(width: width, height: height)
            .onAppear { if seen == nil { seen = running } }
            .onChange(of: running) { _, new in
                seen = new
                changedAt = Date().timeIntervalSinceReferenceDate
            }
            .task(id: changedAt) {
                guard let changedAt, seen == false else { return }
                let wait = changedAt + SandRim.drainTime - Date().timeIntervalSinceReferenceDate
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if !Task.isCancelled { drainedStop = changedAt }
            }
    }

    @ViewBuilder private var content: some View {
        if animated && !reduceMotion {
            GlyphTimeline(interval: SandGlyph.motionInterval, resting: drained) { date in
                let now = date.timeIntervalSinceReferenceDate
                // A change that `onChange` has not recorded yet happened just now.
                let age = drained ? .infinity : seen.map { $0 == running } == false ? 0 : changedAt.map { now - $0 } ?? .infinity
                SandRimFrame(grains: SandRim.frame(running: running, changeAge: age, time: now, width: width, height: height, ends: ends),
                             glow: SandRim.glow(running: running, changeAge: age, time: now, width: width, height: height, ends: ends),
                             colour: colour)
            }
        } else {
            SandRimFrame(grains: SandRim.stillFrame(running: running, width: width, height: height, ends: ends),
                         glow: SandRim.stillGlow(running: running, width: width, height: height, ends: ends), colour: colour)
        }
    }

    /// A stopped rim that has drained (or was stopped when it appeared): it draws nothing and its timeline pauses.
    private var drained: Bool { !running && seen != true && (changedAt == nil || drainedStop == changedAt) }
}

/// One frame of the Sand rim: the grains over their glow (`SandRim.glow`, blurred by `SandRim.glowBlur`), which never
/// leaves the band. The rim view draws its frames with this; renders draw the model's frames through it at explicit
/// times.
struct SandRimFrame: View {
    let grains: [SandGrain]
    let glow: SandSolid?
    let colour: Color

    var body: some View {
        SandGrainCanvas(grains: grains, colour: colour, bloom: glow, bloomBlur: SandRim.glowBlur, bloomFeather: SandRim.glowFeather)
    }
}

/// A colour change the glyph crossfades over.
struct SandColourChange: Equatable {
    /// How long the crossfade takes.
    static let fadeTime: TimeInterval = 0.35

    var from: Color
    var at: TimeInterval
}

/// Draws grains as anti-aliased dots in `colour` (crossfaded from `fromColour` by `colourMix`), each grain's shade a
/// mix toward black or white, and the marks' solid bodies between the stream's grains and the marks'. Grains are
/// batched by layer, shade and opacity, so a frame of a few hundred grains is a few dozen fills. A `bloom` (the rim's
/// glow) is filled first, blurred by `bloomBlur` points and faded in over the canvas's top `bloomFeather` points, and
/// then nothing is drawn past the canvas's frame.
struct SandGrainCanvas: View {
    let grains: [SandGrain]
    var solids: [SandSolid] = []
    var sparkle: SandSparkle?
    let colour: Color
    var fromColour: Color?
    var colourMix: Double = 1
    var opacity: Double = 1
    var bloom: SandSolid?
    var bloomBlur: CGFloat = 0
    var bloomFeather: CGFloat = 0
    /// Maps each shade first (Glass's `GlassGlyph.light`); nil draws it as it is.
    var light: ((Double) -> Double)? = nil
    /// Glass's dimmed glyph: the colours stepped toward the glass (`GlassGlyph.dimmed`, P594).
    var glassDimmed = false

    /// Opacity steps and shade steps (−1 … +1) a grain is snapped to for batching.
    private static let opacitySteps = 20
    private static let shadeSteps = 16

    var body: some View {
        Canvas { context, size in
            let look = context.environment.colorScheme
            func glass(_ colour: Color) -> Color { glassDimmed ? GlassGlyph.dimmed(colour, look: look) : colour }
            var ink = glass(colour).resolve(in: context.environment)
            if let fromColour, colourMix < 1 {
                ink = Self.mix(glass(fromColour).resolve(in: context.environment), ink, colourMix)
            }
            let batches = self.batches()
            if let bloom {
                let bounds = CGRect(origin: .zero, size: size)
                context.clip(to: Path(bounds))
                var layer = context
                if bloomFeather > 0 {
                    // The mask's alpha: nothing at the top, all of it `bloomFeather` points down.
                    layer.clipToLayer { mask in
                        mask.fill(Path(bounds), with: .linearGradient(Gradient(colors: [.black.opacity(0), .black]),
                                                                      startPoint: .zero, endPoint: CGPoint(x: 0, y: bloomFeather)))
                    }
                }
                layer.addFilter(.blur(radius: bloomBlur))
                layer.fill(bloom.path, with: .color(Color(Self.shaded(ink, bloom.shade)).opacity(bloom.alpha * opacity)))
            }
            draw(batches, ink: ink, in: &context)
        }
    }

    /// The grains as one path per layer, shade and opacity step, in drawing order (the key sorts by layer first).
    private func batches() -> [(key: Int, path: Path)] {
        let levels = Self.opacitySteps + 1, tones = Self.shadeSteps + 1
        var batches: [Int: Path] = [:]
        for grain in grains {
            let level = Int((grain.alpha * opacity * Double(Self.opacitySteps)).rounded())
            guard level > 0 else { continue }
            let tone = Int(((grain.shade + 1) / 2 * Double(Self.shadeSteps)).rounded())
            let key = (grain.layer.rawValue * tones + tone) * levels + level
            let r = grain.size / 2
            batches[key, default: Path()].addEllipse(in: CGRect(x: grain.x - r, y: grain.y - r, width: grain.size, height: grain.size))
        }
        return batches.keys.sorted().map { ($0, batches[$0]!) }
    }

    private func draw(_ batches: [(key: Int, path: Path)], ink: Color.Resolved, in context: inout GraphicsContext) {
        let levels = Self.opacitySteps + 1, tones = Self.shadeSteps + 1
        let marks = SandGrain.Layer.mark.rawValue * tones * levels
        var solidsDrawn = false
        let light = self.light
        func mapped(_ shade: Double) -> Double { light.map { $0(shade) } ?? shade }
        func drawSolids(_ context: inout GraphicsContext) {
            solidsDrawn = true
            for solid in solids {
                context.fill(solid.path, with: .color(Color(Self.shaded(ink, mapped(solid.shade))).opacity(solid.alpha * opacity)))
            }
        }
        for (key, path) in batches {
            if !solidsDrawn, key >= marks { drawSolids(&context) }
            let level = key % levels, tone = (key / levels) % tones
            let shade = Double(tone) / Double(Self.shadeSteps) * 2 - 1
            context.fill(path, with: .color(Color(Self.shaded(ink, mapped(shade))).opacity(Double(level) / Double(Self.opacitySteps))))
        }
        if !solidsDrawn { drawSolids(&context) }
        if let sparkle, sparkle.alpha * opacity > 0.01 {
            context.fill(Self.star(sparkle), with: .color(Color(Self.shaded(ink, mapped(0.82))).opacity(sparkle.alpha * opacity)))
        }
    }

    /// `ink` mixed toward black (shade < 0) or white (shade > 0).
    static func shaded(_ ink: Color.Resolved, _ shade: Double) -> Color.Resolved {
        let target: Float = shade < 0 ? 0 : 1, t = Float(min(1, abs(shade)))
        return Color.Resolved(red: ink.red + (target - ink.red) * t, green: ink.green + (target - ink.green) * t,
                              blue: ink.blue + (target - ink.blue) * t, opacity: ink.opacity)
    }

    static func mix(_ a: Color.Resolved, _ b: Color.Resolved, _ t: Double) -> Color.Resolved {
        let t = Float(t)
        return Color.Resolved(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t,
                              blue: a.blue + (b.blue - a.blue) * t, opacity: a.opacity + (b.opacity - a.opacity) * t)
    }

    /// A four-point star: long points up, down and sideways, pinched to a quarter of its radius between them.
    private static func star(_ sparkle: SandSparkle) -> Path {
        let c = CGPoint(x: sparkle.x, y: sparkle.y), r = sparkle.radius, w = r * 0.24
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addLine(to: CGPoint(x: c.x + w, y: c.y - w))
        path.addLine(to: CGPoint(x: c.x + r, y: c.y))
        path.addLine(to: CGPoint(x: c.x + w, y: c.y + w))
        path.addLine(to: CGPoint(x: c.x, y: c.y + r))
        path.addLine(to: CGPoint(x: c.x - w, y: c.y + w))
        path.addLine(to: CGPoint(x: c.x - r, y: c.y))
        path.addLine(to: CGPoint(x: c.x - w, y: c.y - w))
        path.closeSubpath()
        return path
    }
}

/// The Sand glyph's glow: two soft shadows behind the grains (about 2.2 and 6.2 pt at 28 pt), scaled by `strength`.
private struct SandGlow: ViewModifier {
    let colour: Color
    let strength: Double
    let side: CGFloat

    func body(content: Content) -> some View {
        if strength > 0 {
            content
                .shadow(color: colour.opacity(0.5 * strength), radius: min(3, side * 0.08))
                .shadow(color: colour.opacity(0.32 * strength), radius: min(8, side * 0.22))
        } else {
            content
        }
    }
}
