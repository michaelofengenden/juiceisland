import SwiftUI

/// The widget's container background in the snapshot's theme (spec §4.8, P540, P566). Black: the pure black it always
/// was. Glass: no black at all (`WidgetGlass`): the island's light glass as a white veil, the dark ink and the rim.
/// Smoke: the panel's smoked glass (`GlassStyle.panel`), less the glass itself. WidgetKit composites no glass inside a
/// widget (no `glassEffect` in its archived view; `WidgetTexture.glass` is visionOS's only), so the widget draws the
/// floor and the rim and nothing else, translucent: what the system puts under a widget (its platter, the desktop)
/// shows through the 18 % the floor leaves (P541). The system takes this background away in its tinted, clear and
/// vibrant looks (accented and vibrant rendering, P346), and draws its own there, in either theme (P542). The rim and
/// the renders' stand-in are the island's own (`GlassRim`, `GlassStandIn`). Solid: the window's own ground for the
/// widget's look, opaque (`WidgetSolid`, P777).
struct WidgetBackground: View {
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        switch theme {
        case .black: IslandTheme.bg
        case .glass: WidgetGlass()
        case .smoke: WidgetSmoke()
        case .solid: WidgetSolid()
        }
    }
}

/// Solid in a widget (P777): WidgetKit draws no window material and the system's desktop tint never reaches a widget, so
/// Solid there is the window background's own ground for the look the widget is drawn in (the Appearance the app wrote
/// in the snapshot when it pins Light or Dark, else the system's light or dark mode, which WidgetKit hands it), with the
/// hairline in the widget's shape, and its content in Glass's twins for that look. Nothing in it moves, holds state or
/// reads a clock.
struct WidgetSolid: View {
    var body: some View {
        let shape = ContainerRelativeShape()
        ZStack {
            Rectangle().fill(SolidLook.ground)
            GlassRim(shape: shape, edge: GlassEdge(width: SolidLook.panelEdgeWidth, top: 1, bottom: 1), colour: SolidLook.edgeColour)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Smoke's container background, reading what it draws from the environment.
struct WidgetSmoke: View {
    @Environment(\.glassRendering) private var rendering
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        WidgetSmokeBody(rendering: rendering, reduceTransparency: reduceTransparency, contrast: contrast)
    }
}

/// `WidgetSmoke` with what it reads given outright (tests). In the widget's own shape (`ContainerRelativeShape`: the
/// widget's rounded corners where WidgetKit draws it; the render scene sets the same shape): the floor, 82 % black
/// (Increase Contrast 90 %), which keeps every colour the widget draws legible over any desktop, white included
/// (P543), and the rim lit from above. Reduce Transparency: the opaque solid. Renders (`GlassRendering.standIn`) add,
/// under the floor, the stage's backdrop blurred, standing in for what shows through live; the live widget never draws
/// it, nor any `glassEffect`. Nothing in it moves, holds state or reads a clock.
struct WidgetSmokeBody: View {
    var rendering: GlassRendering
    var reduceTransparency: Bool
    var contrast: ColorSchemeContrast

    /// The desktop panel's look: a free-standing surface that never moves.
    static let style = GlassStyle.panel

    var body: some View {
        let style = Self.style, shape = ContainerRelativeShape()
        ZStack {
            if reduceTransparency {
                Rectangle().fill(style.solid)
            } else {
                if rendering == .standIn { GlassStandIn(shape: Rectangle(), style: style) }
                Rectangle().fill(Color.black.opacity(style.floor(contrast)))
            }
            GlassRim(shape: shape, edge: style.edge(contrast))
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Glass's container background, reading what it draws from the environment.
struct WidgetGlass: View {
    @Environment(\.glassRendering) private var rendering
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        WidgetGlassBody(rendering: rendering, reduceTransparency: reduceTransparency, contrast: contrast)
    }
}

/// Glass in a widget, with what it reads given outright (tests). WidgetKit composites no glass inside a widget, and a
/// widget can neither blur nor see what is behind it (P541, P566), so its full colour look cannot adapt: it is the
/// light look of the island's glass (P561), held for any wallpaper: a white veil that lets nothing behind it show darker
/// than the light look's bound (`GlassContrast.lightFloor`: a black wallpaper shows as that grey, a white one as white),
/// under the dark ink (`IslandWidgetEntryView` draws its content in the light scheme), with the panel's rim in the
/// widget's own shape: never a black plate. Everything behind it comes through that veil, sharp. Reduce Transparency:
/// the system's opaque light ground; Increase Contrast: the stronger bound and an even rim. The system's real Liquid
/// Glass for a widget is its own: Clear or Tinted under System Settings › Appearance › Icon & widget style (accented
/// rendering, P542), and the vibrant look it gives every widget while windows cover the desktop. Renders
/// (`GlassRendering.standIn`) draw the stage's backdrop under the veil, unblurred, as the live widget shows it. Nothing
/// in it moves, holds state or reads a clock.
struct WidgetGlassBody: View {
    var rendering: GlassRendering
    var reduceTransparency: Bool
    var contrast: ColorSchemeContrast

    static let style = GlassStyle.panel.clear

    /// The veil's white: the light look's bound, so over black it is exactly that grey.
    static func veil(_ contrast: ColorSchemeContrast) -> Double { GlassContrast.bound(.light, contrast) }

    var body: some View {
        let shape = ContainerRelativeShape()
        ZStack {
            if reduceTransparency {
                Rectangle().fill(GlassAdapted.solidLight)
            } else {
                if rendering == .standIn { GlassStandIn(shape: Rectangle(), style: Self.style, sharp: true) }
                Rectangle().fill(Color.white.opacity(Self.veil(contrast)))
            }
            GlassRim(shape: shape, edge: Self.style.edge(contrast), colour: GlassAdapted.rimColour)
        }
        .clipShape(shape)
        .environment(\.colorScheme, .light)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
