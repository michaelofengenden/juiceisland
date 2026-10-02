import SwiftUI

/// WCAG 2 contrast on glass (P522): what a token reads against where a glass surface is brightest. Smoke: the glass can
/// only blur and tint what is behind it, so over a white window the surface is at most the floor laid over white
/// (`worstSurface`), with any fill (a hover, a card) laid over that; a token that holds its contrast there holds it over
/// any wallpaper. Glass lays no floor: its bounds are the model below (`worstAdapted`). Colours composite in sRGB's
/// encoded values, as the window server blends them.
enum GlassContrast {
    /// The ratios every theme keeps (text 4.5:1, marks and state colours 3:1; text on a hover or card fill 4:1).
    static let text = 4.5
    static let textOnFill = 4.0
    static let mark = 3.0

    /// A colour's sRGB components (0 to 1, encoded) and opacity, resolved in `scheme` (an adaptive colour's twin for it;
    /// any other colour is the same in both).
    /// `widget`: inside Glass look Widget's glass, where a colour with a Widget twin draws it (P879).
    static func components(_ colour: Color, _ scheme: ColorScheme = .light, widget: Bool = false) -> (r: Double, g: Double, b: Double, a: Double) {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        environment.glassWidgetInk = widget
        let resolved = colour.resolve(in: environment)
        return (Double(resolved.red), Double(resolved.green), Double(resolved.blue), Double(resolved.opacity))
    }

    /// Relative luminance of opaque sRGB components.
    static func luminance(r: Double, g: Double, b: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    static func luminance(_ colour: Color, _ scheme: ColorScheme = .light) -> Double {
        let c = components(colour, scheme)
        return luminance(r: c.r, g: c.g, b: c.b)
    }

    static func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// `top` (with its opacity) over opaque `base`, in encoded sRGB.
    static func over(_ top: Color, _ base: (r: Double, g: Double, b: Double), _ scheme: ColorScheme = .light) -> (r: Double, g: Double, b: Double) {
        let t = components(top, scheme)
        return (t.r * t.a + base.r * (1 - t.a), t.g * t.a + base.g * (1 - t.a), t.b * t.a + base.b * (1 - t.a))
    }

    /// The surface over a backdrop of this colour: the floor's black at `floor`, then each fill in turn.
    static func surface(over backdrop: (r: Double, g: Double, b: Double), floor: Double, fills: [Color] = []) -> (r: Double, g: Double, b: Double) {
        var colour = over(Color.black.opacity(floor), backdrop)
        for fill in fills { colour = over(fill, colour) }
        return colour
    }

    /// The brightest the surface gets: over white.
    static func worstSurface(floor: Double, fills: [Color] = []) -> Double {
        let c = surface(over: (1, 1, 1), floor: floor, fills: fills)
        return luminance(r: c.r, g: c.g, b: c.b)
    }

    /// `colour`'s contrast on the surface at its brightest.
    static func worstRatio(_ colour: Color, floor: Double, fills: [Color] = []) -> Double {
        ratio(luminance(colour), worstSurface(floor: floor, fills: fills))
    }

    // MARK: Glass: the system's glass, adapting (P561)

    /// Theme Glass lays no floor. The system's regular glass "automatically maintains legibility of content by adjusting
    /// its content based on the luminosity of the content beneath the glass" (SwiftUI's `Glass.regular`), shifting its
    /// tint and dynamic range so what sits on it stays legible while as much of the backdrop as possible comes through
    /// (WWDC25 "Meet Liquid Glass"), and goes light or dark with what is behind it. How far it shifts is the window
    /// server's and cannot be measured headless, so the tokens are held against a model of it, which the renders'
    /// stand-in also draws (`GlassAdaptedBackdrop`): the dark glass lets nothing brighter than a grey of `darkCeiling`
    /// (encoded sRGB) through, the light glass nothing darker than `lightFloor`; darker (lighter) parts come through as
    /// they are. The worst surface of each look is then that grey, whatever the backdrop, and whichever look the system
    /// picks, its ink twin holds there. Increase Contrast shifts further.
    static let darkCeiling = 0.25
    static let lightFloor = 0.75
    static let darkCeilingIncreased = 0.16
    static let lightFloorIncreased = 0.86

    /// The grey that bounds `scheme`'s look (encoded sRGB).
    static func bound(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast = .standard) -> Double {
        switch (scheme, contrast) {
        case (.dark, .increased): darkCeilingIncreased
        case (.dark, _): darkCeiling
        case (_, .increased): lightFloorIncreased
        default: lightFloor
        }
    }

    /// `scheme`'s worst surface (encoded sRGB): its bounding grey, then each fill (resolved in that scheme) in turn.
    static func adapted(_ scheme: ColorScheme, fills: [Color] = [], contrast: ColorSchemeContrast = .standard) -> (r: Double, g: Double, b: Double) {
        let grey = bound(scheme, contrast)
        var colour = (r: grey, g: grey, b: grey)
        for fill in fills { colour = over(fill, colour, scheme) }
        return colour
    }

    /// The adaptation's worst surface (its luminance), with `fills`.
    static func worstAdapted(_ scheme: ColorScheme, fills: [Color] = [], contrast: ColorSchemeContrast = .standard) -> Double {
        let c = adapted(scheme, fills: fills, contrast: contrast)
        return luminance(r: c.r, g: c.g, b: c.b)
    }

    /// `colour`'s twin for `scheme` against that adaptation's worst surface.
    static func worstAdaptedRatio(_ colour: Color, _ scheme: ColorScheme, fills: [Color] = []) -> Double {
        ratio(luminance(colour, scheme), worstAdapted(scheme, fills: fills))
    }

    // MARK: Glass look Widget: the glass's dark face, measured (P874, P879)

    /// Glass look Widget draws the glass's dark face over any backdrop, which is no model of bounds: over a white window
    /// Core Animation draws it #B4B4B4 (`GlassFaceModel.dark`), far lighter than `darkCeiling`, and over the owner's
    /// lavender #8285C5. So Widget lays its Frost's dark ground at `GlassFrost.widgetFloor` at the least, and its ink
    /// (each colour's Widget twin, `GlassTone.widget`) is held on that: the face as it comes out over a backdrop (encoded
    /// sRGB; over a white window, the brightest it gets, unless said) under Widget's Frost at `frost`, then each fill.
    static func widgetSurface(face: (r: Double, g: Double, b: Double) = darkFaceOverWhite, frost: Double = 0,
                              fills: [Color] = []) -> (r: Double, g: Double, b: Double) {
        var colour = over(GlassFrost.colour(frost, look: .widget), face, .dark)
        for fill in fills { colour = over(fill, colour, .dark) }
        return colour
    }

    /// The glass's dark face over a white window: #B4B4B4.
    static let darkFaceOverWhite: (r: Double, g: Double, b: Double) = {
        let c = GlassFaceModel.dark.apply(1, 1, 1)
        return (c.r, c.g, c.b)
    }()

    /// Widget's worst surface (its luminance): the face over a white window under Widget's least Frost, with `fills`.
    static func worstWidget(fills: [Color] = []) -> Double {
        let c = widgetSurface(fills: fills)
        return luminance(r: c.r, g: c.g, b: c.b)
    }
}
