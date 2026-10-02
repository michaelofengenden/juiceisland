import Synchronization
import SwiftUI

/// How a session glyph is finished for the surface it sits on (P590 to P592). Plain (Black, Smoke, the window, the
/// widget's tinted looks): as it always was, lit from within, its highlights toward white and its glow a soft shadow of
/// its colour, which reads as light on a black ground. Glass: the same glyph at its colour's full strength (the state's
/// or the agent's own colour, never `GlassTone`'s lighter or darker twin), its highlights and depth kept short of
/// washing the colour out (`GlassGlyph.light`), a thin edge that carries its contrast (`GlassGlyph.edge`), and for its
/// glow a bloom lighter than the glass: a coloured shadow is darker than a light glass and reads as mud there.
enum GlyphFinish: Sendable, Equatable {
    case plain, glass

    init(_ theme: JuiceTheme) { self = theme.adapts ? .glass : .plain }
}

/// Theme Glass's glyph finish (P590 to P592).
enum GlassGlyph {
    /// The edge around a glyph of `colour` on `look`: the colour's own shade that holds a mark's 3:1 on the look's worst
    /// surface and on a hover or card veil over it (`GlassTone.nudged`: the same hue and saturation, darker where the glass
    /// is light, lighter where it is dark), or nil where the colour holds by itself and needs no edge. So the glyph keeps
    /// its colour at full strength and its outline carries the contrast. Worked out once for each colour and look. Inside
    /// Glass look Widget's glass (`widget`, `\.glassWidgetInk`) the shade holds on Widget's ground instead, the glass's
    /// dark face under Widget's least Frost (`GlassTone.widget`, P879): lighter, since that ground is.
    static func edge(for colour: Color, look: ColorScheme, widget: Bool = false) -> Color? {
        let onWidget = widget && look == .dark
        return worked(onWidget ? .widgetEdge : .edge, colour, look) { plain in
            let shade = onWidget ? GlassTone.widget(plain) : GlassTone.nudged(plain, look)
            return shade == plain ? nil : shade
        }
    }

    /// How far a dimmed glyph's colour steps toward the glass (P594).
    static let dimStep = 0.25

    /// A dimmed glyph's colour on `look` (the closed pill's resting check, P594): the colour a quarter of the way toward
    /// the glass (white on the light look, black on the dark), so it keeps its hue and most of its strength, and the glyph
    /// is drawn opaque in it, over its edge at full strength (`edge(for:)` of the colour as given), matte (`matte`) and
    /// with no bloom. Never Black's 42 % alpha: over a light glass that is a pale mint (1.05:1 on #BFBFBF), and a
    /// translucent glyph over its edge's copies shows them through, a solid dark core. Worked out once, like the edge.
    static func dimmed(_ colour: Color, look: ColorScheme) -> Color {
        worked(.dim, colour, look) { plain in
            var environment = EnvironmentValues()
            environment.colorScheme = look
            return Color(plain.mix(with: look == .dark ? .black : .white, by: dimStep, in: .device).resolve(in: environment))
        } ?? colour
    }

    private enum Kind { case edge, widgetEdge, dim }

    /// Looked up by the colour as given: a moving glyph asks every frame, and resolving it each time cost more than the
    /// lookup (the colours are the few state and agent statics and the idle grey). `make` gets the colour resolved for
    /// `look`.
    private static func worked(_ kind: Kind, _ colour: Color, _ look: ColorScheme, _ make: (Color) -> Color?) -> Color? {
        let key = Key(kind: kind, colour: colour, dark: look == .dark)
        if let known = table.withLock({ $0[key] }) { return known }
        var environment = EnvironmentValues()
        environment.colorScheme = look
        let worked = make(Color(colour.resolve(in: environment)))
        // A colour crossfading between two states passes through colours no glyph rests on: keep the table small.
        table.withLock {
            if $0.count >= 256 { $0.removeAll() }
            $0[key] = worked
        }
        return worked
    }

    private struct Key: Hashable {
        var kind: Kind
        var colour: Color
        var dark: Bool
    }

    private static let table = Mutex<[Key: Color?]>([:])

    /// The edge's width for a glyph `side` points square: half a point up to the rows' 20 pt (one pixel on a Retina
    /// display), three quarters in the pill's 28.
    static func edgeWidth(side: CGFloat) -> CGFloat { side >= 24 ? 0.75 : 0.5 }

    /// A shade's light (−1 black … 0 the colour … 1 white) as Glass draws it: a highlight a fraction as far toward white
    /// (the brightest, a glint, stays a highlight; the pale marks and the meniscus come back to the colour), a depth a
    /// little shallower. Black draws the light as it is.
    static func light(_ light: Double) -> Double { light > 0 ? 0.45 * light * light : 0.7 * light }

    /// A dimmed glyph's light (P594): matte, its highlights gone and its depth as `light`'s, so it reads at rest.
    static func matte(_ light: Double) -> Double { light > 0 ? 0 : 0.7 * light }

    /// The bloom that stands in for the glow, lighter than the glass under it so it reads as light: white where the glass
    /// is light, the colour faint where it is dark (Black's outer glow; the edge takes its inner one's place).
    static func bloom(_ colour: Color, look: ColorScheme) -> Color {
        look == .dark ? colour.opacity(0.3) : Color.white.opacity(0.7)
    }
}

/// Glass's edge and bloom around a Liquid or Sand glyph's drawing (`GlassGlyph`): where the colour needs an edge, hard
/// copies of the glyph in it under the glyph, `edgeWidth` out in six directions (three nested hard shadows 120° apart:
/// each shadows the copies before it, so their offsets sum to the six and the centre), flattened, then the bloom under
/// that (a shadow of the unflattened copies would be one shadow per copy, eight times as strong). The copies lie under
/// the glyph too, so a glyph drawn translucent shows them through: a dimmed glyph is drawn opaque in `GlassGlyph.dimmed`
/// instead (P594). Pixel draws its edge in its canvas instead (its cells' gaps must stay open), and passes
/// `edges: false`. The colours are worked out here, once a drawing, never per fill (P567).
struct GlassGlyphFinish: ViewModifier {
    let colour: Color
    let side: CGFloat
    /// Whether this modifier draws the edge (Liquid, Sand) or the canvas does (Pixel).
    var edges = true
    /// 0 for no bloom (a dimmed glyph, the widget, a glyph asked for no glow), else the glow's strength.
    var bloom: Double
    /// The bloom's radius.
    var radius: CGFloat

    @Environment(\.colorScheme) private var look
    @Environment(\.glassWidgetInk) private var widget

    func body(content: Content) -> some View {
        let edge = edges ? GlassGlyph.edge(for: colour, look: look, widget: widget) : nil
        let w = GlassGlyph.edgeWidth(side: side)
        let edged = Group {
            if let edge {
                let h = w * 0.866
                content
                    .shadow(color: edge, radius: 0, x: w, y: 0)
                    .shadow(color: edge, radius: 0, x: -w / 2, y: h)
                    .shadow(color: edge, radius: 0, x: -w / 2, y: -h)
                    .compositingGroup()
            } else {
                content
            }
        }
        if bloom > 0 {
            edged.shadow(color: GlassGlyph.bloom(colour, look: look).opacity(min(1, bloom)), radius: radius)
        } else {
            edged
        }
    }
}
