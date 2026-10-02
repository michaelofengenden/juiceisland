import Synchronization
import SwiftUI

// Theme Glass's ink (P561, P562). Content inside the system's glass takes the glass's look: the regular glass "adjusts
// its content based on the luminosity of the content beneath" (SwiftUI's `Glass.regular`), and a glass that goes light
// or dark with what is behind it takes its content with it, "symbols and text ... becoming darker when the underlying
// content is light, and lighter when it's dark" (HIG, Liquid Glass color); a large glass keeps the system's appearance
// and shifts its luminosity instead (WWDC25 "Meet Liquid Glass"). SwiftUI hands that look to the content as its colour
// scheme, so every Glass ink is a pair of twins resolved by the colour scheme it is drawn in, never by anything we
// sample: dark ink where the glass is light, light ink where it is dark. Black and Smoke never draw one.

extension Color {
    /// `light` where the view's appearance is light, `dark` where it is dark (the glass's look, or the system's
    /// appearance outside a glass), resolved by SwiftUI in the colour scheme it draws in (`AdaptivePair`).
    static func adaptive(light: Color, dark: Color) -> Color {
        var lit = EnvironmentValues(), dim = EnvironmentValues()
        lit.colorScheme = .light
        dim.colorScheme = .dark
        return Color(AdaptivePair(light: light.resolve(in: lit), dark: dark.resolve(in: dim)))
    }

    /// `adaptive(light:dark:)` with a third twin for Glass look Widget's glass (`\.glassWidgetInk`, P879): the dark look
    /// on the glass's dark face over any backdrop, a lighter ground than the dark look's model of bounds, so a grey or a
    /// colour that holds there is lighter.
    static func adaptive(light: Color, dark: Color, widget: Color) -> Color {
        var lit = EnvironmentValues(), dim = EnvironmentValues()
        lit.colorScheme = .light
        dim.colorScheme = .dark
        return Color(AdaptivePair(light: light.resolve(in: lit), dark: dark.resolve(in: dim), widget: widget.resolve(in: dim)))
    }

    /// `adaptive(light:dark:)` from two sRGB hex values.
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color { .adaptive(light: Color(hex: light), dark: Color(hex: dark)) }

    /// A Glass ink from two sRGB hex values, with its Widget twin worked out from the dark one for `use`
    /// (`GlassTone.widget`, P879).
    static func glassInk(_ light: UInt32, _ dark: UInt32, _ use: GlassTone.Use = .text) -> Color {
        .adaptive(light: Color(hex: light), dark: Color(hex: dark), widget: GlassTone.widget(Color(hex: dark), use))
    }
}

extension EnvironmentValues {
    /// Inside Glass look Widget's glass (`GlassLookFace`, P879): an ink with a Widget twin draws it. False everywhere
    /// else (the window, Settings, Solid, Light and dark), so they draw as before.
    @Entry var glassWidgetInk = false
}

/// The twins of an adaptive colour, as a colour SwiftUI resolves itself (`ShapeStyle.resolve(in:)`): a read of the
/// colour scheme and a pick of the stored values. An AppKit dynamic colour (`NSColor(name:dynamicProvider:)`) resolved
/// the same way cost the main thread its provider, an appearance match and a conversion at every fill, and a glyph fills
/// up to 49 cells a frame: Glass's 120-row list at rest took its heavy frames from 2.8 to 9.4 ms (P567). A pair with a
/// Widget twin reads one more value, and only on the dark look.
private struct AdaptivePair: ShapeStyle, Hashable {
    let light: Color.Resolved
    let dark: Color.Resolved
    var widget: Color.Resolved? = nil

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        guard environment.colorScheme == .dark else { return light }
        if let widget, environment.glassWidgetInk { return widget }
        return dark
    }
}

/// Glass's veils: the ink at a little opacity where the glass is light, white where it is dark, as the system's own
/// fills on glass are (HIG: on glass, "use fills, transparency, and vibrancy", never glass on glass). A hover, a card, a
/// peek's ground or a key is a veil, never a dark plate.
enum GlassVeil {
    /// The ink the light look's veils are made of.
    static let lightInk = Color(hex: 0x1D1D1F)

    static func colour(light: Double, dark: Double) -> Color {
        .adaptive(light: lightInk.opacity(light), dark: Color.white.opacity(dark))
    }

    /// The fills every Glass text token is checked on (a hovered row or card lift, a card), as opacities (light, dark).
    static let hover = (light: 0.05, dark: 0.05)
    static let card = (light: 0.04, dark: 0.06)

    /// Those fills as colours.
    static let judged: [Color] = [colour(light: hover.light, dark: hover.dark), colour(light: card.light, dark: card.dark)]
}

/// A state's or an agent's colour on Glass (P562): the same hue, its lightness nudged only where a pair fails: a little
/// lighter where the glass is dark, darker where it is light, until it keeps its ratio on that look's worst surface
/// (`GlassContrast.worstAdapted`) and on a hover over it: a mark's 3:1, or a word's 4.5:1 (4:1 on a fill). Worked out once
/// for each colour and use.
enum GlassTone {
    /// What the colour is: a mark (a glyph, a dot, a battery's fill) or a word (a status word, an amount).
    enum Use: Hashable, Sendable {
        case mark, text
    }

    private struct Key: Hashable {
        var colour: Color
        var use: Use
    }

    private static let cache = Mutex<[Key: Color]>([:])

    /// `colour`'s adaptive twin pair for `use`, with its Widget twin (`widget(_:_:)`, P879).
    static func adapted(_ colour: Color, _ use: Use = .mark) -> Color {
        let key = Key(colour: colour, use: use)
        if let known = cache.withLock({ $0[key] }) { return known }
        let made = Color.adaptive(light: nudged(colour, .light, use), dark: nudged(colour, .dark, use), widget: widget(colour, use))
        cache.withLock { $0[key] = made }
        return made
    }

    /// Whether luminance `l` keeps `use`'s ratios on `scheme`'s worst surface, bare and under the judged fills, `margin`
    /// over them (a nudged colour aims a hair past the line, so rounding it to a colour never lands it under).
    static func holds(_ l: Double, _ scheme: ColorScheme, _ use: Use, margin: Double = 1) -> Bool {
        let bare = (use == .text ? GlassContrast.text : GlassContrast.mark) * margin
        let onFill = (use == .text ? GlassContrast.textOnFill : GlassContrast.mark) * margin
        guard GlassContrast.ratio(l, GlassContrast.worstAdapted(scheme)) >= bare else { return false }
        return GlassVeil.judged.allSatisfy { GlassContrast.ratio(l, GlassContrast.worstAdapted(scheme, fills: [$0])) >= onFill }
    }

    /// `colour` for one look: itself when it already holds there, else the nearest lightness (in HSL, hue and
    /// saturation kept) that does.
    static func nudged(_ colour: Color, _ scheme: ColorScheme, _ use: Use = .mark) -> Color {
        let c = GlassContrast.components(colour)
        guard !holds(GlassContrast.luminance(r: c.r, g: c.g, b: c.b), scheme, use) else { return colour }
        var (h, s, l) = hsl(c.r, c.g, c.b)
        // Dark glass: lighter, toward white; light glass: darker, toward black. Bisect the lightness.
        var lo = scheme == .dark ? l : 0, hi = scheme == .dark ? 1 : l
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            let m = rgb(h, s, mid)
            let ok = holds(GlassContrast.luminance(r: m.r, g: m.g, b: m.b), scheme, use, margin: 1.01)
            if scheme == .dark { if ok { hi = mid } else { lo = mid } } else { if ok { lo = mid } else { hi = mid } }
        }
        l = scheme == .dark ? hi : lo
        let out = rgb(h, s, l)
        return Color(.sRGB, red: out.r, green: out.g, blue: out.b, opacity: c.a)
    }

    // MARK: Glass look Widget (P879)

    /// Whether luminance `l` keeps `use`'s ratios on Glass look Widget's worst surface (`GlassContrast.worstWidget`: the
    /// glass's dark face over a white window under Widget's least Frost), bare and under the judged fills.
    static func holdsWidget(_ l: Double, _ use: Use, margin: Double = 1) -> Bool {
        let bare = (use == .text ? GlassContrast.text : GlassContrast.mark) * margin
        let onFill = (use == .text ? GlassContrast.textOnFill : GlassContrast.mark) * margin
        guard GlassContrast.ratio(l, widgetWorst) >= bare else { return false }
        return widgetWorstOnFills.allSatisfy { GlassContrast.ratio(l, $0) >= onFill }
    }

    /// Widget's worst surface, bare and under each judged fill, worked out once.
    private static let widgetWorst = GlassContrast.worstWidget()
    private static let widgetWorstOnFills = GlassVeil.judged.map { GlassContrast.worstWidget(fills: [$0]) }

    /// `colour` on Glass look Widget's glass (its Widget twin): itself where it already holds there, else the nearest
    /// lighter shade that does (hue and saturation kept). The glass's dark face over a light backdrop is a mid grey, far
    /// lighter than the dark look's bound, so a dark twin's grey would fade there; this is white or nearly, as the
    /// desktop widgets' ink is (they tint their content white).
    static func widget(_ colour: Color, _ use: Use = .mark) -> Color {
        let c = GlassContrast.components(colour, .dark)
        guard !holdsWidget(GlassContrast.luminance(r: c.r, g: c.g, b: c.b), use) else { return colour }
        let (h, s, l) = hsl(c.r, c.g, c.b)
        var lo = l, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            let m = rgb(h, s, mid)
            if holdsWidget(GlassContrast.luminance(r: m.r, g: m.g, b: m.b), use, margin: 1.01) { hi = mid } else { lo = mid }
        }
        let out = rgb(h, s, hi)
        return Color(.sRGB, red: out.r, green: out.g, blue: out.b, opacity: c.a)
    }

    static func hsl(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, l: Double) {
        let hi = max(r, g, b), lo = min(r, g, b), l = (hi + lo) / 2
        guard hi > lo else { return (0, 0, l) }
        let d = hi - lo
        let s = l > 0.5 ? d / (2 - hi - lo) : d / (hi + lo)
        var h: Double
        switch hi {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h /= 6
        return (h, s, l)
    }

    static func rgb(_ h: Double, _ s: Double, _ l: Double) -> (r: Double, g: Double, b: Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }
}
