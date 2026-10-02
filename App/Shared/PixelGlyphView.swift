import SwiftUI

/// Draws one `PixelGlyph`. Pixel size 2.5 pt (closed pill: 17.5 pt; 3 pt in a top bar on a 1× display), 2 pt
/// (header, island rows: 14 pt), 3 pt (window rows: 21 pt), 1.5 pt (Clean footer), 4 pt (About icon). Each pixel is
/// drawn `px − 0.5` square; the top pixel of a column is 100 %, lower ones 85 %; dimmed is 42 % (on Glass, opaque in `GlassGlyph.dimmed`). Glow: two shadows
/// (2.5 pt, then 6 pt at 55 %).
///
/// Motion runs off one clock (`GlyphTimeline`: at most 30 frames a second, none while its surface is hidden): the
/// equalizer's bars glide along `PixelGlyph.equalizerHeights`, their top pixels fading with the fraction, the agents
/// glyph's dots step up in turn (`HelperBeat`), and a needs-you glyph's glow breathes with `PixelGlyph.pulse`. Both are functions of the time alone, so a row that a
/// list update re-creates carries on where it was and every pulse is in step. Under Reduce Motion, or when `animated`
/// is false (renders pass false), a glyph holds still: the equalizer's still frame `frameOffset`, the glow at rest.
struct PixelGlyphView: View {
    let glyph: PixelGlyph
    var colour: Color = .white
    var pixel: CGFloat = 2
    var dimmed = false
    var glow = true
    var animated = true
    /// Equalizer offset: the still frame to show, and in motion a shift of the clock (a second equalizer is offset by 3).
    var frameOffset = 0
    /// Glass: the edge and the bloom for the glow (`GlassGlyphFinish`); plain, the glow as always.
    var finish: GlyphFinish = .plain

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.glyphsStill) private var still

    /// Moving or still, the glyph is one timeline over one drawing (a still one rests, drawing its still frame), so
    /// turning it still or moving (the island closing or opening) changes values, never the views; its frames are drawn
    /// in `glyphFrame`, so none of them lays out anything around it (P102).
    var body: some View {
        let moves = Self.moves(glyph, animated: animated && !still, reduceMotion: reduceMotion)
        GlyphTimeline(interval: PixelGlyph.motionInterval, resting: !moves) { date in
            let look = moves ? look(at: date) : (alphas: glyph.alphas(frame: frameOffset), pulse: 0)
            drawn(look.alphas, pulse: look.pulse)
        }
        .glyphFrame(width: pixel * 7, height: pixel * 7)
    }

    /// Whether a glyph moves: the equalizer, the agents glyph's dots and the needs-you glyphs do, unless Reduce Motion is
    /// on or `animated` is false.
    nonisolated static func moves(_ glyph: PixelGlyph, animated: Bool, reduceMotion: Bool) -> Bool {
        animated && !reduceMotion && (glyph == .eq || glyph == .agents || glyph.needsYou)
    }

    /// The moving glyph as it looks at `date` (the frame-strip render draws these directly).
    func moment(at date: Date) -> some View {
        let look = look(at: date)
        return drawn(look.alphas, pulse: look.pulse)
    }

    /// The moving glyph's pixels and glow at `date`.
    private func look(at date: Date) -> (alphas: [[Double]], pulse: Double) {
        let time = date.timeIntervalSinceReferenceDate
        let alphas = switch glyph {
        case .eq: PixelGlyph.equalizerAlphas(heights: PixelGlyph.equalizerHeights(at: time, offset: frameOffset))
        case .agents: PixelGlyph.helperAlphas(lifts: PixelGlyph.helperLifts(at: time))
        default: glyph.alphas(frame: frameOffset)
        }
        return (alphas, glyph.needsYou ? PixelGlyph.pulse(at: time) : 0)
    }

    @ViewBuilder private func drawn(_ alphas: [[Double]], pulse: Double) -> some View {
        switch finish {
        case .plain:
            GlyphCanvas(alphas: alphas, colour: colour, pixel: pixel, dimmed: dimmed)
                .frame(width: pixel * 7, height: pixel * 7)
                .modifier(GlyphGlow(colour: colour, enabled: glow && !dimmed, pulse: pulse))
        case .glass:
            GlassPixelCanvas(alphas: alphas, colour: colour, pixel: pixel, dimmed: dimmed)
                .modifier(GlassGlyphFinish(colour: colour, side: pixel * 7, edges: false, bloom: glow && !dimmed ? 1 : 0,
                                           radius: (6 + 5 * pulse) / 2))
        }
    }
}

private struct GlyphCanvas: View {
    let alphas: [[Double]]
    let colour: Color
    let pixel: CGFloat
    let dimmed: Bool

    var body: some View {
        Canvas { context, _ in
            let side = max(pixel - 0.5, 0.5)
            for x in 0..<7 {
                for y in 0..<7 {
                    let alpha = alphas[y][x] * (dimmed ? 0.42 : 1)
                    guard alpha > 0 else { continue }
                    context.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: side, height: side)),
                                 with: .color(colour.opacity(alpha)))
                }
            }
        }
    }
}

/// Pixel on Glass (P590): the cells as `GlyphCanvas` draws them, over the glyph's edge (`GlassGlyph.edge`, where its
/// colour needs one), a quarter point past the lit cells' outline, so the gaps between the cells read dark as Black's
/// do: on the light look the edge's dark shade fills them (a plate under the cells), on the dark look it is a ring and
/// the dark glass shows through them. A cell fading in or out (under half) takes no edge. At most one clip and one fill,
/// in colours worked out once a drawing (P567). The canvas reaches past the glyph's square by whole points, which lays
/// out nothing and keeps every cell on the device pixels (P595: a canvas padded by the edge's 0.75 pt sits half a device
/// pixel off at 2x, and every cell straddles two). Dimmed, the cells are opaque in `GlassGlyph.dimmed` over the full edge
/// (P594).
private struct GlassPixelCanvas: View {
    let alphas: [[Double]]
    let colour: Color
    let pixel: CGFloat
    let dimmed: Bool

    var body: some View {
        let reach = 0.25 + GlassGlyph.edgeWidth(side: pixel * 7)
        let pad = reach.rounded(.up)
        Canvas { context, _ in
            context.translateBy(x: pad, y: pad)
            let side = max(pixel - 0.5, 0.5)
            let look = context.environment.colorScheme
            let ink = dimmed ? GlassGlyph.dimmed(colour, look: look) : colour
            if let edge = GlassGlyph.edge(for: colour, look: look, widget: context.environment.glassWidgetInk) {
                var inner = Path(), outer = Path()
                for x in 0..<7 {
                    for y in 0..<7 where alphas[y][x] >= 0.5 {
                        let cell = CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: side, height: side)
                        inner.addRect(cell.insetBy(dx: -0.25, dy: -0.25))
                        outer.addRect(cell.insetBy(dx: -reach, dy: -reach))
                    }
                }
                // The gaps read dark, as Black's do: on the dark look the glass shows through them; on the light
                // look the edge's dark shade fills them.
                var ring = context
                if look == .dark { ring.clip(to: inner, options: .inverse) }
                ring.fill(outer, with: .color(edge))
            }
            for x in 0..<7 {
                for y in 0..<7 {
                    let alpha = alphas[y][x]
                    guard alpha > 0 else { continue }
                    context.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: side, height: side)),
                                 with: .color(ink.opacity(alpha)))
                }
            }
        }
        .frame(width: pixel * 7 + 2 * pad, height: pixel * 7 + 2 * pad)
        .padding(-pad)
    }
}

/// The glow's two shadows; `pulse` (0 rest … 1 bright) widens them from 2.5 and 6 pt to 4 and 11 pt.
private struct GlyphGlow: ViewModifier {
    let colour: Color
    let enabled: Bool
    let pulse: Double

    func body(content: Content) -> some View {
        if enabled {
            content
                .shadow(color: colour, radius: (2.5 + 1.5 * pulse) / 2)
                .shadow(color: colour.opacity(0.55), radius: (6 + 5 * pulse) / 2)
        } else {
            content
        }
    }
}
