import SwiftUI

/// Draws one mood in the Liquid style (`LiquidGlyph`) in a `side` × `side` square: vectors in a `Canvas` at the
/// screen's scale, in `colour` and lighter and darker shades of it, on a transparent square. Dimmed is 42 % with no
/// glow and no motion, like Pixel's (on Glass, opaque in `GlassGlyph.dimmed`, P594); the glow is two soft shadows behind
/// the shapes, which stay sharp.
///
/// Motion runs off one clock (`GlyphTimeline`: at most 30 frames a second, none while its surface is hidden): the frame
/// is a function of the time, shifted by `frameOffset`, and of the last mood change this view saw. A glyph starts
/// settled in its mood (a list that re-creates a row replays nothing); a change plays the engine's own transition from
/// the old mood. Running, delegating and a needs-you mark keep moving; done and idle settle, and
/// `LiquidGlyph.pauseAfter` after a change the timeline pauses. `running` is Settings › Island › Running's look. Under Reduce Motion, or when `animated` is false (renders pass false), the glyph is the
/// still frame of its mood.
struct LiquidGlyphView: View {
    let mood: GlyphMood
    var colour: Color
    var side: CGFloat = 20
    var dimmed = false
    var glow = true
    var animated = true
    var frameOffset = 0
    var running: LiquidRunningLook = .slim
    /// Glass: its lights kept short of washing the colour out, the edge and the bloom for the glow (`GlyphFinish`).
    var finish: GlyphFinish = .plain

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.glyphsStill) private var still
    /// The last mood change: the mood before it and when (nil until the mood first changes).
    @State private var change: (from: GlyphMood, at: Date)?
    /// The last colour change, faded in over 0.35 s.
    @State private var tint: (from: Color, at: Date)?
    /// Whether the last change has played out (then a done or idle glyph stops redrawing).
    @State private var settled = true

    /// Moving or still, one timeline over one frame view (a still glyph rests on its still frame), so turning it still
    /// or moving (the island closing or opening) changes values, never the views (P102).
    var body: some View {
        let moves = animated && !still && !reduceMotion && !dimmed
        GlyphTimeline(interval: LiquidGlyph.motionInterval, resting: !moves || Self.paused(mood, settled: settled)) { date in
            moves ? frame(at: date)
                : LiquidGlyphFrame(primitives: LiquidGlyph.still(mood, side: side, frameOffset: frameOffset, running: running), colour: colour,
                                   side: side, dimmed: dimmed, glow: glow, finish: finish)
        }
        .glyphFrame(width: side, height: side)
        .onChange(of: mood) { old, _ in
            change = (old, .now)
            settled = false
        }
        .onChange(of: colour) { old, _ in
            tint = (old, .now)
            settled = false
        }
        .task(id: lastChange) {
            guard let lastChange else { return }
            let wait = LiquidGlyph.pauseAfter - Date.now.timeIntervalSince(lastChange)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if !Task.isCancelled { settled = true }
        }
    }

    /// Whether the timeline can pause: a done or idle glyph whose last change has played out.
    nonisolated static func paused(_ mood: GlyphMood, settled: Bool) -> Bool {
        settled && !LiquidGlyph.keepsMoving(mood)
    }

    private var lastChange: Date? {
        [change?.at, tint?.at].compactMap { $0 }.max()
    }

    /// The moving glyph as it looks at `date`.
    func moment(at date: Date) -> some View { frame(at: date) }

    private func frame(at date: Date) -> LiquidGlyphFrame {
        let now = date.timeIntervalSinceReferenceDate
        let age = change.map { now - $0.at.timeIntervalSinceReferenceDate } ?? .infinity
        let primitives = LiquidGlyph.frame(mood: mood, from: change?.from, changeAge: age,
                                           time: now + Double(frameOffset) * LiquidGlyph.offsetShift, side: side, running: running)
        var shown = colour
        if let tint {
            let fade = min(1, max(0, (now - tint.at.timeIntervalSinceReferenceDate) / 0.35))
            if fade < 1 { shown = tint.from.mix(with: colour, by: fade * fade * (3 - 2 * fade)) }
        }
        return LiquidGlyphFrame(primitives: primitives, colour: shown, side: side, dimmed: dimmed, glow: glow, finish: finish)
    }
}

/// One frame of the Liquid glyph: fills `primitives` in `colour` and its shades. Renders draw the model's frames
/// through this directly, at explicit times.
struct LiquidGlyphFrame: View {
    let primitives: [LiquidGlyph.Primitive]
    let colour: Color
    let side: CGFloat
    var dimmed = false
    var glow = true
    var finish: GlyphFinish = .plain

    var body: some View {
        switch finish {
        case .plain:
            Canvas { context, _ in
                LiquidGlyph.fill(primitives, in: context, colour: colour)
            }
            .frame(width: side, height: side)
            .opacity(dimmed ? 0.42 : 1)
            .modifier(LiquidGlow(colour: colour, side: side, enabled: glow && !dimmed))
        case .glass:
            // Dimmed: opaque, in the colour stepped toward the glass and matte, over the full edge (P594).
            Canvas { context, _ in
                if dimmed {
                    LiquidGlyph.fill(primitives, in: context, colour: GlassGlyph.dimmed(colour, look: context.environment.colorScheme),
                                     light: GlassGlyph.matte)
                } else {
                    LiquidGlyph.fill(primitives, in: context, colour: colour, light: GlassGlyph.light)
                }
            }
            .frame(width: side, height: side)
            .modifier(GlassGlyphFinish(colour: colour, side: side, bloom: glow && !dimmed ? 1 : 0, radius: max(3, side * 0.18)))
        }
    }
}

/// The glow: two soft shadows of the colour behind the shapes, lighter than Pixel's near one so the edges stay crisp.
private struct LiquidGlow: ViewModifier {
    let colour: Color
    let side: CGFloat
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .shadow(color: colour.opacity(0.35), radius: max(1.2, side * 0.07))
                .shadow(color: colour.opacity(0.3), radius: max(3, side * 0.18))
        } else {
            content
        }
    }
}

/// Draws `LiquidRim` along the bottom of the closed pill, inside a `width` × `height` band (the body's lowest 3 pt).
/// While `running`, the line lives on one clock like the glyph; when running stops it drains away and then the rim
/// draws nothing and stops redrawing. A rim that first appears not running draws nothing at all. Its glow is blurred
/// inside the band and never reaches past it.
struct LiquidRimView: View {
    var running: Bool
    var colour: Color
    var width: CGFloat
    var height: CGFloat = IslandTheme.Metrics.pillEdgeLine
    /// How much of the line shows from each end (nil: all of it).
    var ends: RimEnds?
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When `running` last changed (nil until it first changes).
    @State private var changedAt: Date?
    /// Whether the last change has played out.
    @State private var settled = true

    var body: some View {
        Group {
            if !animated || reduceMotion {
                LiquidRimFrame(primitives: running ? LiquidRim.frame(running: true, time: LiquidRim.stillTime, width: width, height: height,
                                                                     ends: ends) : [],
                               colour: colour)
            } else if running || !settled {
                GlyphTimeline(interval: LiquidGlyph.motionInterval) { date in
                    let now = date.timeIntervalSinceReferenceDate
                    let age = changedAt.map { now - $0.timeIntervalSinceReferenceDate } ?? .infinity
                    LiquidRimFrame(primitives: LiquidRim.frame(running: running, changeAge: age, time: now, width: width, height: height,
                                                               ends: ends),
                                   colour: colour)
                }
            } else {
                Color.clear
            }
        }
        .glyphFrame(width: width, height: height)
        .onChange(of: running) {
            changedAt = .now
            settled = false
        }
        .task(id: changedAt) {
            guard let changedAt else { return }
            let wait = LiquidGlyph.pauseAfter - Date.now.timeIntervalSince(changedAt)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if !Task.isCancelled { settled = true }
        }
    }
}

/// One frame of the rim; renders draw the model's frames through this at explicit times. Nothing it draws leaves its
/// frame, so the glow never spills out of the pill.
struct LiquidRimFrame: View {
    let primitives: [LiquidGlyph.Primitive]
    let colour: Color

    var body: some View {
        Canvas { context, _ in
            LiquidGlyph.fill(primitives, in: context, colour: colour)
        }
        .clipped()
    }
}

extension LiquidRim {
    /// The moment a still rim shows (renders, Reduce Motion).
    static let stillTime: TimeInterval = 1.15
}

extension LiquidGlyph {
    /// Fills each primitive inside its clips (faded in under a feathered clip's top), blurred when it asks, its tones
    /// resolved against `colour`.
    static func fill(_ primitives: [Primitive], in context: GraphicsContext, colour: Color, light: ((Double) -> Double)? = nil) {
        for primitive in primitives {
            var layer = context
            for clip in primitive.clips {
                layer.clip(to: clip.path, options: clip.inverse ? .inverse : [])
                guard clip.feather > 0, !clip.inverse else { continue }
                let box = clip.path.boundingRect
                // The mask's alpha: nothing at the top of the box, all of it `feather` points down.
                layer.clipToLayer { mask in
                    mask.fill(Path(box), with: .linearGradient(Gradient(colors: [.black.opacity(0), .black]),
                                                               startPoint: CGPoint(x: box.midX, y: box.minY),
                                                               endPoint: CGPoint(x: box.midX, y: box.minY + clip.feather)))
                }
            }
            if primitive.blur > 0 { layer.addFilter(.blur(radius: primitive.blur)) }
            layer.fill(primitive.path, with: shading(primitive.paint, colour: colour, light: light))
        }
    }

    /// `light` maps each tone's light first (Glass's `GlassGlyph.light`); nil draws it as it is.
    static func shading(_ paint: Paint, colour: Color, light: ((Double) -> Double)? = nil) -> GraphicsContext.Shading {
        switch paint {
        case .solid(let tone):
            return .color(shade(tone, colour: colour, light: light))
        case .linear(let stops, let from, let to):
            let gradient = Gradient(stops: stops.map { .init(color: shade($0.tone, colour: colour, light: light), location: $0.location) })
            return .linearGradient(gradient, startPoint: from, endPoint: to)
        }
    }

    /// `colour` mixed toward white or black by the tone's light (mapped by `light` when given), at its opacity.
    static func shade(_ tone: Tone, colour: Color, light: ((Double) -> Double)? = nil) -> Color {
        let amount = light.map { $0(tone.light) } ?? tone.light
        let mixed = amount > 0 ? colour.mix(with: .white, by: amount)
            : amount < 0 ? colour.mix(with: .black, by: -amount) : colour
        return tone.opacity < 1 ? mixed.opacity(max(0, tone.opacity)) : mixed
    }
}
