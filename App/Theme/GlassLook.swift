import Synchronization
import SwiftUI

// Three refinements of the island's look (the owner's "let's do all of them" of 2026-09-29, P630 to P639):
// - State tint (`StateTint`, Settings › Island › State tint, on): the island takes a faint colour of its lead state, the
//   one glyph the closed pill leads with (`PillLead`): what needs you in Needs you colour's (`NeedsYouColour`), a
//   finish's brief green that fades, the delegate teal while the main turn waits on its subagents; nothing while it
//   simply runs, rests or is idle. Glass takes it as a veil inside its glass (`StateTint.veil`), Black as a faint
//   coloured edge along its outline, its pure #000 body untouched (`StateTint.blackEdge`). Smoke takes none.
// - Frost (`GlassFrost`, Settings › Island › Frost, under Theme while Glass is chosen, 0): from today's Glass, the most
//   see-through glass that keeps its ink legible over any backdrop, to a frosted one, a veil of the look's own solid ground
//   inside the glass.
// - The pointer-lit rim (`RimLight`): while the pointer is over the island, Glass's rim brightens toward the pointer's
//   side, a soft light that follows it, eased, from the island's own tracking area; still at rest, gone when it leaves.
//
// All three are fills and lights of our own inside the outline: nothing draws past it in either engine, nothing ticks at
// rest, and with State tint off, Frost at 0 and no pointer, Black and Glass draw exactly as before. Every legibility bound
// is `GlassContrast`'s: a tint or a frost only ever moves a look's worst surface away from its ink (P631, P633).

// MARK: State tint

/// The island's lead state, as the tint shows it: nil (no tint) while it runs, rests or is idle.
enum StateTint: String, CaseIterable, Hashable, Sendable {
    /// An approval, a question or a failed turn: the needs-you colour (`NeedsYouColour`).
    case needsYou
    /// A session just finished (the pill's bright check, its 4 s): done's green, then a slow fade.
    case finished
    /// The main turn waits on its subagents: the delegate teal.
    case delegating

    /// The tint of the pill's lead (`PillLead`, the board's most urgent state): a waiting lead needs you, the bright
    /// check has finished, the delegate glyph delegates; a running one, a stalled run, the dim check and no lead tint
    /// nothing.
    init?(lead: PillLead?) {
        guard let lead else { return nil }
        switch lead.state {
        case .waiting: self = .needsYou
        case .done where !lead.dimmed: self = .finished
        case .delegating: self = .delegating
        default: return nil
        }
    }

    /// The state's own colour, the glyph's (`GlyphPalette.glyph`, by state), with `needsYou` chosen.
    func colour(_ needsYou: NeedsYouColour) -> Color {
        switch self {
        case .needsYou: needsYou.wait
        case .finished: IslandTheme.done
        case .delegating: IslandTheme.delegate
        }
    }

    // MARK: Glass: a veil in the glass

    /// The veil's strength on each look.
    static let veilLight = 0.26
    static let veilDark = 0.40

    /// Glass's veil for this state and contrast: a twin for each look, the state's hue and saturation kept, its lightness
    /// moved to stay on the ink's far side of the look's bound (`GlassContrast.bound`): lighter than the light look's
    /// floor, darker than the dark look's ceiling. Laid over any glass the look allows, it only ever moves the surface
    /// away from the ink, so every token keeps its ratio (P631). Worked out once per state, needs-you colour and
    /// contrast.
    func veil(_ contrast: ColorSchemeContrast = .standard, needsYou: NeedsYouColour) -> Color {
        let key = VeilKey(tint: self, needsYou: self == .needsYou ? needsYou : nil, increased: contrast == .increased)
        if let known = Self.veils.withLock({ $0[key] }) { return known }
        let colour = colour(needsYou)
        let made = Color.adaptive(light: Self.twin(colour, .light, contrast).opacity(Self.veilLight),
                                  dark: Self.twin(colour, .dark, contrast).opacity(Self.veilDark))
        Self.veils.withLock { $0[key] = made }
        return made
    }

    private struct VeilKey: Hashable { var tint: StateTint, needsYou: NeedsYouColour?, increased: Bool }
    private static let veils = Mutex<[VeilKey: Color]>([:])

    /// The luminance a veil's twin keeps on its side of `scheme`'s bound: 15 % past the light look's floor, 30 % under the
    /// dark look's ceiling, a margin for mixing in encoded sRGB (a mix of two colours of one luminance can fall a little
    /// under it).
    static func target(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast = .standard) -> Double {
        let grey = GlassContrast.bound(scheme, contrast)
        let bound = GlassContrast.luminance(r: grey, g: grey, b: grey)
        return scheme == .dark ? bound * 0.7 : min(0.95, bound * 1.15)
    }

    /// `colour` with its HSL lightness moved (hue and saturation kept) until its luminance is `target`'s: up for the
    /// light look, down for the dark.
    static func twin(_ colour: Color, _ scheme: ColorScheme, _ contrast: ColorSchemeContrast = .standard) -> Color {
        let c = GlassContrast.components(colour)
        let (h, s, l) = GlassTone.hsl(c.r, c.g, c.b)
        let goal = target(scheme, contrast)
        var lo = scheme == .dark ? 0 : l, hi = scheme == .dark ? l : 1
        for _ in 0..<32 {
            let mid = (lo + hi) / 2, m = GlassTone.rgb(h, s, mid)
            let lum = GlassContrast.luminance(r: m.r, g: m.g, b: m.b)
            if scheme == .dark { if lum <= goal { lo = mid } else { hi = mid } } else { if lum >= goal { hi = mid } else { lo = mid } }
        }
        let out = GlassTone.rgb(h, s, scheme == .dark ? lo : hi)
        return Color(.sRGB, red: out.r, green: out.g, blue: out.b)
    }

    // MARK: Black: an edge along the outline

    /// Black's edge: a line of the state's colour a point wide just inside the outline, lit from below as Glass's rim is
    /// (nothing at the screen's edge, its full strength down the sides and along the bottom curve). The body stays #000.
    static let blackEdge = GlassEdge(width: 1, top: 0, bottom: 0.55, reach: 26)

    // MARK: Its motion

    /// A tint comes in eased over this.
    static let fadeIn: TimeInterval = 0.35
    /// It goes over this: a finish's green lingers and fades slowly; the others clear briskly.
    func fadeOut() -> TimeInterval { self == .finished ? 1.2 : 0.45 }

    /// How a tint comes and goes: a cross-fade, the same under Reduce Motion (it is no motion).
    var transition: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: Self.fadeIn)),
                    removal: .opacity.animation(.easeInOut(duration: fadeOut())))
    }
}

// MARK: Frost

/// Settings › Island › Frost (Glass): 0, today's Glass exactly, to 1, frosted. The regular glass is already the most
/// see-through glass whose ink holds over any backdrop: the clear variant needs a dimming layer under it (the black the
/// owner asked away) and adapts to nothing, and a glass drawn at part strength lets the backdrop through as it is, under
/// every bound the ink is held on (P633). So the slider only frosts: a veil of the look's own solid ground, inside the
/// glass, under the content: Reduce Transparency's light one (`GlassAdapted.solidLight`), and on the dark look a step
/// darker than its (#2A2A2D is a hair brighter than Increase Contrast's dark ceiling, #292929). Each moves its look's
/// worst surface away from the ink, under either contrast, so the ink holds across the range (`GlassLookTests`).
enum GlassFrost {
    /// The veil at 1: most of the ground, some glass left.
    static let maximum = 0.65
    /// The grounds.
    static let light = GlassAdapted.solidLight
    static let dark = Color(hex: 0x242427)

    /// A stored or dragged value: 0 to 1, in hundredths.
    static func stored(_ value: Double) -> Double { (min(1, max(0, value)) * 100).rounded() / 100 }

    /// The veil for `frost` (0 to 1): the look's ground at `frost × maximum`.
    static func colour(_ frost: Double) -> Color {
        let a = stored(frost) * maximum
        return .adaptive(light: light.opacity(a), dark: dark.opacity(a))
    }

    /// Glass look Widget's veil (P873, P874): the dark ground, never the light one, from `widgetFloor` at Frost 0 to
    /// `widgetMaximum` at 1. The floor is there at every Frost: the glass's dark face over a white window is #B4B4B4
    /// (`GlassFaceModel.dark`), where white text is 2.1:1, and half of #242427 makes it #6C6C6E, where white text holds
    /// 5.2:1 and Widget's ink its ratios (`GlassTone.widget`). The wallpaper's colour still shows through, as the
    /// widgets' does: the owner's lavender comes out #535475. Over the apps' windows only (the island, the Settings
    /// preview): the desktop panel sits on the wallpaper, never over a window.
    static let widgetFloor = 0.5
    /// The desktop panel's floor while macOS dims its widgets (an app in front, P1214): a tenth of the dark ground, so
    /// the panel dims with the widgets and keeps the wallpaper's colour, as they do. The only measured dimmed widget
    /// (lavender #8A8CC8 under it came out #6F6FC4, P872) is ΔE 15.7 from the dark face alone, 17.1 at a tenth and 32.2
    /// at the half; over the dimmed widgets' model a tenth is the closest (mean ΔE 9.4, against 10.1 with none).
    static let widgetDimmedFloor = 0.1
    static let widgetMaximum = 0.6

    /// The veil for `frost` in Glass look `look`: Light and dark's as ever (`colour(_:)`); Widget's the dark ground, in
    /// either scheme, from the floor of the state it is in (`widgetOpacity`).
    static func colour(_ frost: Double, look: GlassLookChoice, state: WidgetGlassState = .overApps) -> Color {
        look == .widget ? dark.opacity(widgetOpacity(frost, state: state)) : colour(frost)
    }

    /// Widget's veil's strength at `frost`: from the state's floor at 0 to `widgetMaximum` at 1. Over the apps
    /// `widgetFloor`; on the desktop with the widgets dimmed `widgetDimmedFloor`; in full colour nothing (the widgets'
    /// own glass, the wallpaper's colour, P1205). Frost adds only the depth the owner asks for.
    static func widgetOpacity(_ frost: Double, state: WidgetGlassState = .overApps) -> Double {
        let floor = switch state {
        case .overApps: widgetFloor
        case .dimmed: widgetDimmedFloor
        case .fullColour: 0.0
        }
        return floor + stored(frost) * (widgetMaximum - floor)
    }
}

// MARK: The pointer-lit rim

/// Glass's rim catching the light where the pointer is: a soft radial light in the rim's own colour, its centre pushed from
/// the island's middle out through the pointer toward the rim on the pointer's side, so the side it is on brightens.
enum RimLight {
    /// How far past the pointer, from the island's middle, the light sits.
    static let push: CGFloat = 1.35
    /// The light's strength at its centre, over the rim's own.
    static let peak = 0.85
    /// It follows the pointer over this, eased out.
    static let follow: TimeInterval = 0.18
    /// It comes and goes over this.
    static let fade: TimeInterval = 0.3

    /// The light's centre and radius for a pointer at `pointer` (the canvas's space, y down from its top) over the island
    /// `target` hanging from the canvas's top, centred on `midX`: pushed out from the island's middle through the pointer,
    /// its reach a third of the island's width and height together (60 to 160 pt).
    static func place(pointer: CGPoint, target: SurfaceGeometry, midX: CGFloat) -> (centre: CGPoint, radius: CGFloat) {
        place(pointer: pointer, extent: target.extent, midX: midX)
    }

    /// The same over an island's whole `extent`: Motion: Liquid's union with its card's bud (`IslandUIState.budHit`), so
    /// a pointer over the bud lights the bud's own rim.
    static func place(pointer: CGPoint, extent: IslandExtent, midX: CGFloat) -> (centre: CGPoint, radius: CGFloat) {
        let middle = CGPoint(x: midX + (extent.right - extent.left) / 2, y: extent.height / 2)
        let centre = CGPoint(x: middle.x + (pointer.x - middle.x) * push, y: middle.y + (pointer.y - middle.y) * push)
        return (centre, min(160, max(60, (extent.width + extent.height) * 0.3)))
    }

    /// The light's stops, its colour at `peak` fading to nothing.
    static let stops: [(location: Double, alpha: Double)] = [(0, peak), (0.45, peak * 0.4), (1, 0)]

    /// Lit from below as the rim is: none of the light at the screen's edge, rising to all of it over the rim's reach, so
    /// the screen's edge never catches it and the walls do more the lower they are.
    static func profile(_ edge: GlassEdge) -> (top: Double, reach: CGFloat) { (0, edge.reach ?? 0) }
}

// MARK: The roots' values

extension EnvironmentValues {
    /// Settings › Island › State tint, as the island draws it. Off unless a root sets it (`juiceThemeFromSettings()`), so
    /// renders and previews stay as they were until they ask.
    @Entry var islandStateTint = false
    /// Settings › Island › Frost (Glass), 0 to 1. 0 unless a root sets it.
    @Entry var glassFrost = 0.0
}
