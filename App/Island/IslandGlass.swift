import AppKit
import QuartzCore
import SwiftUI

// Theme Smoke on the island (P550 to P555, Glass until 2026-09-29): the closed pill and the opened island made of the
// glass `GlassSurface` draws, in both outline engines. The glass itself never moves: it fills the canvas and the outline cuts it (SwiftUI's
// clip, or Core Animation's mask on `GlassSurfaceNSView`), so the island's own springs are what morph it, frame for
// frame with the black they replace. Three things are the island's own:
// - the rim, a thin line of light just inside the outline, lit from below (the island hangs from the screen's edge),
//   riding the outline on its own two curves (`IslandGlassRim`; Core Animation's plays the plan's keyframes);
// - the notch plate (`NotchPlate`): the hardware notch is black, so the glass turns black where it meets it, through a
//   soft fall beside the notch and below it. The notch then reads as the glass's own dark source rather than a hole in
//   it, and the one point of the pill under the notch stays black. Without a notch (the top bar) it is all glass;
// - covers (`IslandCover`): what hid the rows under it with the black lays only its veil on glass, and the rows under it
//   are not drawn there (`IslandPeekCovered`): its ground is the island's own glass (P558).
// Black draws none of this: its surface is the pure black it always was.
//
// Theme Glass on the island (P560 to P563): no floor, no plate, no shade. The island's content goes in the system's
// glass (`IslandGlassContent`: still, filling the canvas, cut by the outline in either engine as Smoke's is), so the
// glass's light or dark adaptation reaches its ink; the rim is Smoke's; the glass runs right up to the hardware notch,
// which is the one black left, and the top bar is all glass.

extension GlassStyle {
    /// The island's glass and floor with no rim of its own: the island draws its rim on its outline (`IslandGlassRim`,
    /// Core Animation's `GlassSurfaceNSView` rim), where a rim of the still frame would run along the canvas's edges.
    static let islandBody: GlassStyle = {
        var style = GlassStyle.island
        style.edge = GlassEdge(width: 0, top: 0, bottom: 0, reach: nil)
        return style
    }()
}

// MARK: The notch plate

/// Where the glass meets the hardware notch: black over the notch and the pill's one point under it, falling to nothing
/// `side` points beside the notch and `drop` points below it, eased at both ends so the fall has no line of its own.
/// It hangs from the canvas's top, centred on the notch (the canvas's middle). Drawn over the glass, its floor and its
/// rim, inside the outline, so it never shows beyond the island; with nothing but the notch showing (the idle rest) the
/// island is all plate, black inside the hardware as the Black theme's is.
struct NotchPlate: Equatable, Sendable {
    var notch: CGSize
    /// The fall beside the notch, into the pill's wings and the island's header.
    var side: CGFloat = Self.side
    /// The fall below it.
    var drop: CGFloat = Self.drop

    /// Black this far below the notch before the fall: the closed pill's body is the notch + 1 tall (P72).
    static let below: CGFloat = 1
    static let side: CGFloat = 12
    static let drop: CGFloat = 8

    /// The plate's box: the notch and its fall.
    var size: CGSize { CGSize(width: notch.width + 2 * side, height: notch.height + Self.below + drop) }

    /// Its box in a canvas `width` wide whose middle is the notch's, from the canvas's top (y down).
    func frame(inCanvasWidth width: CGFloat) -> CGRect {
        CGRect(x: (width - size.width) / 2, y: 0, width: size.width, height: size.height)
    }

    /// The plate's black, 0 to 1, at a point of its box (from its top-left, y down): how far the point lies beyond the
    /// notch, beside it in `side`s and below it in `drop`s, taken together (so the fall rounds the notch's corners),
    /// eased.
    func alpha(x: CGFloat, y: CGFloat) -> Double {
        let dx = max(0, side - x, x - (side + notch.width)) / side
        let dy = max(0, y - (notch.height + Self.below)) / drop
        return Self.ease(1 - Double((dx * dx + dy * dy).squareRoot()))
    }

    /// The shade: the glass darkens toward the screen's edge across the whole surface, `shade` of the floor's light
    /// taken away at the top, none from `shadeReach` below the notch's bottom on, eased; so the top the notch sits in
    /// leans to its black and the glass is clearest where the rim is lit, at the bottom.
    static let shade: Double = 0.6
    static let shadeReach: CGFloat = 14

    /// How far down the shade reaches: the notch, then `shadeReach`.
    var shadeHeight: CGFloat { notch.height + Self.shadeReach }

    /// The shade's black at `y` from the top.
    func shadeAlpha(y: CGFloat) -> Double { Self.shade * Self.ease(1 - Double(y / shadeHeight)) }

    /// The shade as gradient stops, top to bottom (SwiftUI's and Core Animation's alike).
    var shadeStops: [(location: Double, alpha: Double)] {
        (0...8).map { i in let u = Double(i) / 8; return (u, shadeAlpha(y: CGFloat(u) * shadeHeight)) }
    }

    /// Smoothstep: no slope at either end.
    static func ease(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return t * t * (3 - 2 * t)
    }

    /// The plate as an image at `scale` pixels a point (drawn once for a notch and a scale, and kept): black with the
    /// plate's alpha at each pixel's middle, its first row the top.
    @MainActor func image(scale: CGFloat) -> CGImage? {
        let key = Key(width: notch.width, height: notch.height, side: side, drop: drop, scale: scale)
        if let image = Self.images[key] { return image }
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let y = (CGFloat(row) + 0.5) / scale
            for column in 0..<width {
                let a = alpha(x: (CGFloat(column) + 0.5) / scale, y: y)
                pixels[(row * width + column) * 4 + 3] = UInt8((a * 255).rounded())
            }
        }
        let image = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return context.makeImage()
        }
        if let image { Self.images[key] = image }
        return image
    }

    private struct Key: Hashable {
        var width: CGFloat, height: CGFloat, side: CGFloat, drop: CGFloat, scale: CGFloat
    }

    @MainActor private static var images: [Key: CGImage] = [:]

    /// Core Animation's outline: the plate as a layer of `GlassSurfaceNSView.marksLayer` (y up, the canvas's top at its
    /// bounds' top), at `scale`.
    @MainActor func layer(canvas: CGSize, scale: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.name = "island.glass.notchPlate"
        layer.actions = IslandSurfaceLayers.still
        place(layer, canvas: canvas, scale: scale)
        return layer
    }

    /// Core Animation's outline: the shade as a layer of `GlassSurfaceNSView.marksLayer`, across the canvas's top.
    @MainActor func shadeLayer(canvas: CGSize) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.name = "island.glass.shade"
        layer.actions = IslandSurfaceLayers.still
        placeShade(layer, canvas: canvas)
        return layer
    }

    @MainActor func placeShade(_ layer: CAGradientLayer, canvas: CGSize) {
        let stops = shadeStops
        layer.frame = CGRect(x: 0, y: canvas.height - shadeHeight, width: canvas.width, height: shadeHeight)
        layer.colors = stops.map { CGColor(gray: 0, alpha: $0.alpha) }
        layer.locations = stops.map { NSNumber(value: $0.location) }
        // Unit space, y up: its top first.
        layer.startPoint = CGPoint(x: 0.5, y: 1)
        layer.endPoint = CGPoint(x: 0.5, y: 0)
    }

    /// Puts `layer` where the plate goes in a canvas of `canvas` (y up) and draws it at `scale`.
    @MainActor func place(_ layer: CALayer, canvas: CGSize, scale: CGFloat) {
        let box = frame(inCanvasWidth: canvas.width)
        layer.frame = CGRect(x: box.minX, y: canvas.height - box.maxY, width: box.width, height: box.height)
        layer.contents = image(scale: scale)
        layer.contentsScale = scale
        layer.contentsGravity = .resize
    }
}

/// The plate in SwiftUI (SwiftUI's outline, renders): its image, at the display's scale.
struct NotchPlateView: View, Equatable {
    var plate: NotchPlate
    @Environment(\.displayScale) private var scale

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.plate == rhs.plate }

    var body: some View {
        if let image = plate.image(scale: scale) {
            Image(decorative: image, scale: scale).resizable().frame(width: plate.size.width, height: plate.size.height)
        }
    }
}

// MARK: SwiftUI's outline

/// What the island's canvas lays under its content, clipped by the outline (`IslandSurfaceClip`): Black's pure black as
/// it always was, or nothing where Core Animation's outline draws the surface; Smoke, `IslandGlassBody`; Solid, the
/// window material with its hairline and notch plate (`SolidIslandBody`); Glass, nothing (its content holds the glass).
struct IslandSurfaceBackground: View {
    let ui: IslandUIState
    var notch: CGSize?
    /// Core Animation's outline: the render server draws the surface (its black, or `GlassSurfaceNSView`).
    var outside: Bool
    @Environment(\.juiceTheme) private var theme
    /// Settings › Island › State tint: Black's edge along the outline (`IslandStateEdge`; Core Animation's draws it on its
    /// plan, `IslandStateEdgeLayers`).
    @Environment(\.islandStateTint) private var stateTint

    var body: some View {
        switch theme {
        case .smoke where !outside: IslandGlassBody(ui: ui, notch: notch)
        case .solid where !outside: SolidIslandBody(ui: ui, notch: notch)
        // Glass: the content carries the glass (`IslandGlassContent`); nothing under it.
        case .glass: Color.clear
        default:
            if outside {
                Color.clear
            } else {
                IslandTheme.bg.overlay {
                    if stateTint, theme == .black { IslandStateEdge(ui: ui) }
                }
            }
        }
    }
}

/// The island's content as its theme draws it, inside the outline's clip: Black and Smoke, in the dark colour scheme the
/// island always drew in; Glass, in the system's glass (still, filling the canvas: the outline cuts it, SwiftUI's clip or
/// Core Animation's mask), with the rim over the glass on SwiftUI's outline (Core Animation's draws it on its plan,
/// `GlassSurfaceNSView.Backdrop.rimOnly`), in the window's colour scheme, which is Settings › General › Appearance's (or,
/// under Glass look Widget, the dark one, `inGlass`): it decides the glass's look and which twin of each ink shows (P561,
/// P764, P870); Solid, over the window material in that same
/// scheme, its State tint a veil as Glass's (P776), and on Core Animation's outline its notch plate over the veil (P793).
/// On Core Animation's outline the content says which look that is (`IslandGlassSchemeReader`), for the edge line and
/// the rim drawn outside it (P568).
struct IslandGlassContent: ViewModifier {
    let ui: IslandUIState
    /// The notch Solid's plate takes on Core Animation's outline (nil: none, the top bar).
    var notch: CGSize? = nil
    /// Core Animation's outline: its rim is the render server's.
    var outside: Bool
    @Environment(\.juiceTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    /// Settings › Island › State tint: the lead state's veil in the glass, under the content (`IslandTintVeil`).
    @Environment(\.islandStateTint) private var stateTint

    func body(content: Content) -> some View {
        if theme == .solid {
            // SwiftUI's outline lays the veil and the plate over its ground itself (`SolidIslandBody`); Core Animation's
            // ground is the material under the content, so the veil goes under the content here, and the notch plate
            // over the veil: pure black, never the veil's tint (P793).
            content
                .background {
                    if outside {
                        if stateTint { IslandTintVeil(ui: ui) }
                        if let notch { SolidNotchPlateView(notch: notch).equatable() }
                        IslandGlassSchemeReader(ui: ui)
                    }
                }
        } else if theme.adapts {
            content
                .background {
                    if stateTint { IslandTintVeil(ui: ui) }
                    if outside {
                        IslandGlassSchemeReader(ui: ui)
                    } else {
                        // Its light where the pointer is (`IslandRimLight`); Core Animation's is `GlassSurfaceNSView`'s.
                        IslandGlassRim(surface: ui.live.surface, continuous: ui.tuning.continuousCorners,
                                       edge: GlassStyle.island.edge(contrast), colour: GlassAdapted.rimColour, light: ui.rimLight,
                                       liquid: ui.tuning.liquid ? ui.liquid : nil)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .inGlass(Rectangle(), style: GlassStyle.island.clear)
        } else {
            content.environment(\.colorScheme, .dark)
        }
    }
}

/// Glass on Core Animation's outline: the colour scheme the glass hands the island's content, read inside the glass and
/// kept on `IslandUIState.glassScheme` for the edge line and the rim, which are drawn outside it (P568). Draws nothing.
struct IslandGlassSchemeReader: View {
    let ui: IslandUIState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: scheme, initial: true) { _, new in
                if ui.glassScheme != new { ui.glassScheme = new }
            }
    }
}

/// The island's ink scheme where no glass holds it (the edge line's own canvas on Core Animation's outline): dark, as it
/// always was; Glass and Solid, the look the content draws in (`IslandUIState.glassScheme`, the Appearance's), so the
/// edge line takes the same twin as the glyph and the count beside it (P568), or the window's until the content has
/// said; under Glass look Widget the Widget twin, as the glass's content (P879).
struct IslandInkScheme: ViewModifier {
    let ui: IslandUIState
    @Environment(\.juiceTheme) private var theme
    @Environment(\.glassLook) private var glassLook

    func body(content: Content) -> some View {
        if theme.adapts {
            let glass = ui.glassScheme
            let widget = theme == .glass && glassLook == .widget
            content
                .transformEnvironment(\.colorScheme) { if let glass { $0 = glass } }
                .transformEnvironment(\.glassWidgetInk) { if widget { $0 = true } }
        } else {
            content.environment(\.colorScheme, .dark)
        }
    }
}

/// SwiftUI's outline in Glass: the glass and its floor, still, filling the canvas (the outline clips them); the rim on
/// the outline's two curves; the notch plate at the top.
struct IslandGlassBody: View {
    let ui: IslandUIState
    var notch: CGSize?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack(alignment: .top) {
            GlassSurface(shape: Rectangle(), style: .islandBody)
            IslandGlassRim(surface: ui.live.surface, continuous: ui.tuning.continuousCorners, edge: GlassStyle.island.edge(contrast),
                           liquid: ui.tuning.liquid ? ui.liquid : nil)
            if let notch {
                let plate = NotchPlate(notch: notch)
                LinearGradient(stops: plate.shadeStops.map { Gradient.Stop(color: .black.opacity($0.alpha), location: $0.location) },
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: plate.shadeHeight)
                NotchPlateView(plate: plate).equatable()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The rim on SwiftUI's outline: the light (`edge`: `top` at the screen's edge coming up to `bottom` over `reach`, then
/// `bottom` all the way down: brightest along the walls and the bottom curve) cut to the outline's line, twice the rim's
/// width, on the width's curve and the height's (as `IslandSurfaceClip` cuts the canvas), so the rim is exactly the
/// clip's edge in every frame; the canvas's clip keeps its inner half. The light is still: only the line's path moves,
/// one path a frame (a gradient stroke of the moving outline costs six times a plain one, P527).
struct IslandGlassRim: View {
    let surface: SurfaceBox
    var continuous: Bool
    var edge: GlassEdge
    /// The light's colour: white (Smoke); Glass's adapts to its look (`GlassAdapted.rimColour`).
    var colour = Color.white
    /// Glass: where the rim catches the light, near the pointer (`IslandRimLight`), inside the same line.
    var light: IslandRimLight? = nil
    /// Motion: Liquid: the rim on the union (`IslandSurfaceClip.liquid`), the pointer's light cut to it with the rim.
    var liquid: LiquidBox? = nil

    var body: some View {
        let geometry = surface.value
        let line = VStack(spacing: 0) {
            LinearGradient(colors: [colour.opacity(edge.top), colour.opacity(edge.bottom)], startPoint: .top, endPoint: .bottom)
                .frame(height: edge.reach ?? 0)
            colour.opacity(edge.bottom)
        }
        .overlay {
            if let light { IslandRimLightView(light: light, colour: colour, edge: edge) }
        }
        let clip = SurfaceRimClip(geometry: geometry, continuous: continuous, width: edge.width, height: surface.heightMotion.animation)
        // Liquid off: today's rim exactly (the rim holds no state, so switching the feel only rebuilds it).
        if let liquid {
            line.animation(liquid.clock) {
                $0.modifier(LiquidClock(pulse: Double(liquid.pulse), frame: liquid.frame, clip: clip, width: surface.widthMotion.animation))
            }
        } else {
            line.animation(surface.widthMotion.animation) { $0.modifier(clip) }
        }
    }
}

/// `SurfaceClip`'s twin for the rim: the width animated here, the height in the shape, each on its own curve.
nonisolated struct SurfaceRimClip: ViewModifier, Animatable, LiquidClipping {
    var geometry: SurfaceGeometry
    var continuous = false
    var width: CGFloat = 1
    var height: Animation? = nil
    var liquid: LiquidParams? = nil

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(geometry.left, geometry.right), geometry.ear) }
        set {
            geometry.left = newValue.first.first
            geometry.right = newValue.first.second
            geometry.ear = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let shape = SurfaceRimShape(geometry: geometry, continuous: continuous, width: width, liquid: liquid)
        return content.animation(height) { $0.clipShape(shape) }
    }
}

/// The outline's line, `2 × width` wide (so `width` of it lies inside), its height and bottom corners animatable. Never
/// recorded or counted: the outline's own shape (`SurfaceHeightShape`) is.
nonisolated struct SurfaceRimShape: Shape {
    var geometry: SurfaceGeometry
    var continuous = false
    var width: CGFloat = 1
    var liquid: LiquidParams? = nil

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(geometry.height, AnimatablePair(geometry.radius, geometry.meniscus)) }
        set {
            geometry.height = newValue.first
            geometry.radius = newValue.second.first
            geometry.meniscus = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        if let liquid, !liquid.isRest {
            return LiquidPath.path(geometry, liquid, in: rect).strokedPath(StrokeStyle(lineWidth: 2 * width))
        }
        return NotchSurfaceShape.path(geometry, originX: rect.midX - geometry.left, top: rect.minY, continuous: continuous)
            .strokedPath(StrokeStyle(lineWidth: 2 * width))
    }
}

// MARK: Covers

/// What a view lays over the island's surface to hide what is under it (a row's peek over the rows below): Black, the
/// black and `fill` over it, as it always was; Glass and Smoke, `fill` alone, never a black patch on the glass (P526), and never
/// glass of its own (P558): live, a glass in the island's window samples the island's surface under it, already
/// darkened by the floor, and its own floor darkens that again (about #17 over a white window, under a #3B row). On
/// glass what it hides is not drawn under it instead (`IslandPeekCovered`), so its ground is the island's own glass and
/// the hovered row's veil, the row and its peek one colour, as in Black.
struct IslandCover<S: Shape>: View {
    var shape: S
    var fill: Color
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        if theme.knocksOut {
            shape.fill(fill)
        } else {
            shape.fill(IslandTheme.bg).overlay(shape.fill(fill))
        }
    }
}
