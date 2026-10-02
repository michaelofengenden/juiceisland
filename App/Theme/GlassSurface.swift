import SwiftUI

// Theme Smoke's and Glass's surfaces (P520 to P529, P560 to P563). Smoke: one shape-parametric view draws it wherever
// SwiftUI hosts a surface: the real glass live (SwiftUI's `glassEffect` in the shape: the window server blurs what is
// behind the window), a dark floor over it heavy enough to keep every token legible over a white window
// (`GlassStyle.floor`, P522), and a thin rim of light just inside the edge. Glass: the content itself goes in the
// system's glass (`inGlass`), with no floor, so the glass's own light or dark adaptation reaches the ink inside it
// (`Color.adaptive`, P561), and Reduce Transparency and Increase Contrast are the system's own (P563). Everything either
// draws is clipped to its shape: glass, floor and rim, so a glass surface never draws past its outline (P523).
// Offscreen, where the window server composites nothing, a render draws a stand-in (`GlassRendering.standIn`: the
// render's backdrop blurred behind the same floor and rim, or, for Glass, our model of the system's adaptation,
// `GlassStage`), so the look can be judged headless; it is never the live path (P524). Where AppKit hosts a surface
// (a Core Animation outline), the same look is `GlassSurfaceNSView`.

/// How a glass surface looks over the live glass: its floor, its rim, what it draws under Reduce Transparency, and what
/// its render-suite stand-in does to the backdrop.
struct GlassStyle: Equatable, Sendable {
    /// The black laid over the glass, 0 to 1. Its worst backdrop is white (a white window behind the island): 0.82 makes
    /// that #2E2E2E, where the glass palette's text holds 4.5:1 and every state and agent colour 3.6:1 (P522).
    var floor: Double
    /// Increase Contrast's floor.
    var floorIncreased: Double
    var edge: GlassEdge
    /// Whether the glass (and its floor) take the surface's shape, or fill the frame and are only clipped by it. A glass
    /// that takes a moving shape is reshaped every frame, about 0.6 ms of the main thread's frame; a still one clipped
    /// by the moving outline costs about half that, and loses only the glass's own lensing at the edge, which the rim
    /// draws instead (P527).
    var glassFollowsShape: Bool
    /// Reduce Transparency: no glass and no floor, this opaque colour in the shape.
    var solid: Color
    /// The stand-in's blur radius and saturation: what the system's glass does to the backdrop, near enough to judge
    /// the look (renders only).
    var standInBlur: CGFloat
    var standInSaturation: Double
    /// Glass: no floor of ours; the content sits in the glass (`inGlass`) and the stand-in draws our model of the
    /// system's adaptation (`GlassAdaptedStandIn`). false: Smoke.
    var adaptive = false

    /// The island and the closed pill: they hang from the top edge, so the rim is lit from below: nothing along the top
    /// (the screen's own edge), coming up over the pill's height to its full light down the sides and along the bottom
    /// curve. They move, so their glass is still and their outline clips it.
    static let island = GlassStyle(floor: 0.82, floorIncreased: 0.9, edge: GlassEdge(width: 1, top: 0.03, bottom: 0.30, reach: 26),
                                   glassFollowsShape: false, solid: Color(hex: 0x1C1C1E), standInBlur: 14, standInSaturation: 1.35)
    /// A free-standing surface that never moves (the desktop panel, the widget): lit from above, its glass in its shape.
    static let panel = GlassStyle(floor: 0.82, floorIncreased: 0.9, edge: GlassEdge(width: 1, top: 0.32, bottom: 0.10),
                                  glassFollowsShape: true, solid: Color(hex: 0x1C1C1E), standInBlur: 14, standInSaturation: 1.35)

    /// The same surface in Glass: no floor at all (the system's regular glass keeps its own legibility), the system's
    /// own Reduce Transparency and Increase Contrast, the rim unchanged.
    var clear: GlassStyle {
        var style = self
        style.floor = 0
        style.floorIncreased = 0
        style.adaptive = true
        return style
    }

    func floor(_ contrast: ColorSchemeContrast) -> Double { contrast == .increased ? floorIncreased : floor }

    /// Increase Contrast draws the rim as an even, brighter line: the outline reads on any backdrop.
    func edge(_ contrast: ColorSchemeContrast) -> GlassEdge {
        guard contrast == .increased else { return edge }
        let even = max(edge.top, edge.bottom, 0.4)
        return GlassEdge(width: edge.width, top: even, bottom: even, reach: edge.reach)
    }
}

/// The rim: a line of white `width` wide just inside the edge, `top` at the frame's top going to `bottom`: across the
/// whole frame, or with `reach` over that many points from the top and `bottom` from there down (a surface whose frame is
/// a whole canvas, as the moving island's, so its light follows the outline rather than the canvas).
struct GlassEdge: Equatable, Sendable {
    var width: CGFloat
    var top: Double
    var bottom: Double
    var reach: CGFloat? = nil
}

/// Whether a glass surface draws the real glass or the render suites' stand-in.
enum GlassRendering: Sendable {
    /// The system's glass, composited by the window server over what is behind the window (the app).
    case live
    /// Offscreen renders: the nearest `GlassStage`'s backdrop blurred and saturated in the shape, under the same floor
    /// and rim (`RenderHarness` sets it for every render).
    case standIn
}

extension EnvironmentValues {
    @Entry var glassRendering: GlassRendering = .live
    /// The backdrop a stand-in blurs, and its size, from the nearest `GlassStage`.
    @Entry var glassStage: GlassStageInfo? = nil
}

extension View {
    /// Draws the surface behind this view in the environment's theme: Black, `black` in `shape` exactly as the surface
    /// was always drawn; Smoke, a `GlassSurface` in `shape`; Glass, this view in the system's glass in `shape`; Solid,
    /// the window material in `shape` with its hairline (`SolidGround`).
    func themedSurface<S: Shape>(_ shape: S, style: GlassStyle = .island, black: Color = IslandTheme.bg) -> some View {
        modifier(ThemedSurface(shape: shape, style: style, black: black))
    }

    /// Theme Glass: this view in the system's glass, in `shape` when the style's glass takes it, else in its frame (for
    /// the owner to clip, as the island's outline does): the glass behind it and the glass's foreground treatment over
    /// it, so the glass's light or dark adaptation reaches the ink it holds (P561). Renders draw the stand-in: our model
    /// of that adaptation for the stage's backdrop (`GlassBackdrop.adaptation`), its ink in that colour scheme. Glass look
    /// Widget draws it all in the dark scheme, face and ink (`GlassLookFace`, P870).
    func inGlass<S: Shape>(_ shape: S, style: GlassStyle) -> some View {
        modifier(InFrost(shape: shape, style: style)).modifier(InGlass(shape: shape, style: style)).modifier(GlassLookFace())
    }

    /// Always glass, whatever the theme (the Settings preview).
    func glassSurface<S: Shape>(in shape: S, style: GlassStyle = .island) -> some View {
        background { GlassSurface(shape: shape, style: style) }
    }
}

/// A surface in the environment's theme (`themedSurface(_:style:black:)`).
struct ThemedSurface<S: Shape>: ViewModifier {
    var shape: S
    var style: GlassStyle = .island
    var black: Color = IslandTheme.bg
    @Environment(\.juiceTheme) private var theme

    func body(content: Content) -> some View {
        switch theme {
        case .black: content.background { shape.fill(black) }
        case .smoke: content.background { GlassSurface(shape: shape, style: style) }
        case .glass:
            // Nothing moves it: its glass takes the shape.
            content.inGlass(shape, style: { var s = style.clear; s.glassFollowsShape = true; return s }())
        case .solid:
            content
                .background { SolidGround(shape: shape) }
                .overlay { GlassRim(shape: shape, edge: SolidLook.islandEdge, colour: SolidLook.edgeColour).clipShape(shape).allowsHitTesting(false) }
        }
    }
}

/// `inGlass(_:style:)`. The glass's look is the colour scheme it is drawn in, which is the window's, and so Settings ›
/// General › Appearance's (P764): SwiftUI's glass takes its light or dark face from the environment's scheme, whatever is
/// behind it, and the scheme is said again inside the glass so the content's twins are that look's too, never one the
/// glass might hand its content from what is behind it.
struct InGlass<S: Shape>: ViewModifier {
    var shape: S
    var style: GlassStyle
    @Environment(\.glassRendering) private var rendering
    @Environment(\.glassStage) private var stage
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var look
    @Environment(\.glassLook) private var glassLook

    func body(content: Content) -> some View {
        switch rendering {
        case .live:
            // The system's regular glass, which keeps its own legibility; Reduce Transparency and Increase Contrast are
            // its own. A glass that fills the frame is cut by the owner's outline.
            if style.glassFollowsShape {
                content.environment(\.colorScheme, look).glassEffect(.regular, in: shape)
            } else {
                content.environment(\.colorScheme, look).glassEffect(.regular, in: Rectangle())
            }
        case .standIn:
            // The stage's look (a render that asks for the Appearance's), or the backdrop's for the renders made before it.
            let adaptation = stage?.look ?? stage?.backdrop.adaptation ?? .dark
            if glassLook == .widget || stage?.face != nil {
                // Widget: the dark face, its ink dark (P870); or the face the stage asks for, in the stage's look.
                let scheme = glassLook == .widget ? ColorScheme.dark : adaptation
                content
                    .background {
                        GlassFaceStandIn(shape: shape, style: style, face: stage?.face ?? .dark, scheme: scheme,
                                         reduceTransparency: reduceTransparency, contrast: contrast)
                    }
                    .environment(\.colorScheme, scheme)
            } else {
                content
                    .background {
                        GlassAdaptedStandIn(shape: shape, style: style, adaptation: adaptation, reduceTransparency: reduceTransparency,
                                            contrast: contrast)
                    }
                    .environment(\.colorScheme, adaptation)
            }
        }
    }
}

/// Settings › Island › Frost (`GlassFrost`) for `inGlass(_:style:)`: the look's ground as a veil behind the content, so
/// inside the glass and under the content, in the glass's shape (or its frame, for the owner's outline to cut), resolved
/// in the look the glass hands its content. Under Light and dark it is the owner's choice, not an accessibility floor:
/// at 0, nothing. Under Widget the dark ground is there at every Frost, from `GlassFrost.widgetFloor` (P874); a render's
/// reference of the desktop widgets (`GlassStageInfo.bare`) has none.
struct InFrost<S: Shape>: ViewModifier {
    var shape: S
    var style: GlassStyle
    @Environment(\.glassFrost) private var frost
    @Environment(\.glassLook) private var glassLook
    @Environment(\.glassStage) private var stage

    func body(content: Content) -> some View {
        content.background {
            if frost > 0 || glassLook == .widget, stage?.bare != true {
                let colour = GlassFrost.colour(frost, look: glassLook)
                if style.glassFollowsShape {
                    shape.fill(colour)
                } else {
                    Rectangle().fill(colour)
                }
            }
        }
    }
}

/// What the Glass stand-ins share.
enum GlassAdapted {
    /// Reduce Transparency's grounds: the system's own frostier, opaque look, stood in for.
    static let solidLight = Color(hex: 0xECECEF)
    static let solidDark = Color(hex: 0x2A2A2D)
    /// The rim's light on each look: white on the dark glass, the ink on the light one (a white line on a light glass
    /// would not show), at half the white's strength.
    static let rimColour = Color.adaptive(light: GlassVeil.lightInk.opacity(0.5), dark: .white)
}

/// The stand-in for the system's glass on Glass (renders only): the stage's backdrop blurred and saturated as Smoke's
/// stand-in does, then our model of the regular glass's luminosity shift (`GlassContrast`, `GlassAdaptedBackdrop`): on
/// the dark look nothing brighter than `darkCeiling` comes through, on the light look nothing darker than `lightFloor`,
/// each point's hue kept. No floor: the dark parts of a backdrop come through as they are on the dark look, the bright
/// parts on the light look. Reduce Transparency: the system's frostier opaque ground for the look; Increase Contrast: the
/// stronger shift and an even rim. Where the glass takes the surface's shape, the rim stands in for the system glass's
/// own edge; where it fills the frame (the island), the island draws its rim itself.
struct GlassAdaptedStandIn<S: Shape>: View {
    var shape: S
    var style: GlassStyle
    var adaptation: ColorScheme
    var reduceTransparency: Bool
    var contrast: ColorSchemeContrast

    var body: some View {
        let base = style.glassFollowsShape ? AnyShape(shape) : AnyShape(Rectangle())
        ZStack {
            if reduceTransparency {
                base.fill(adaptation == .dark ? GlassAdapted.solidDark : GlassAdapted.solidLight)
            } else {
                GlassAdaptedBackdrop.Slice(style: style, adaptation: adaptation, contrast: contrast).clipShape(base)
            }
            if style.glassFollowsShape, style.edge.width > 0 {
                GlassRim(shape: shape, edge: style.edge(contrast), colour: GlassAdapted.rimColour)
            }
        }
        .clipShape(style.glassFollowsShape ? AnyShape(shape) : AnyShape(Rectangle()))
        .environment(\.colorScheme, adaptation)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The stand-in's glass (renders only): the stage's whole backdrop, blurred and saturated, then shifted into the look's
/// bounds point by point (`GlassContrast.bound`: on the dark look a point brighter than the ceiling is scaled down to it
/// in linear light, its hue kept; on the light look a point darker than the floor is mixed toward white up to it), drawn
/// once for a stage, a look and a style and kept. Headless only: the live glass is the window server's.
@MainActor
enum GlassAdaptedBackdrop {
    private struct Key: Hashable {
        var backdrop: GlassBackdrop
        var width: CGFloat, height: CGFloat
        var blur: CGFloat, saturation: Double
        var dark: Bool, increased: Bool
    }

    private static var images: [Key: CGImage] = [:]

    /// Points a pixel: the backdrop is blurred, so one pixel a point loses nothing.
    static let scale: CGFloat = 1

    static func image(_ stage: GlassStageInfo, style: GlassStyle, adaptation: ColorScheme, contrast: ColorSchemeContrast) -> CGImage? {
        let key = Key(backdrop: stage.backdrop, width: stage.size.width, height: stage.size.height, blur: style.standInBlur,
                      saturation: style.standInSaturation, dark: adaptation == .dark, increased: contrast == .increased)
        if let image = images[key] { return image }
        let renderer = ImageRenderer(content: stage.backdrop.view
            .frame(width: stage.size.width, height: stage.size.height)
            .clipped()
            .saturation(style.standInSaturation)
            .blur(radius: style.standInBlur, opaque: true))
        renderer.scale = scale
        guard let blurred = renderer.cgImage, let shifted = shift(blurred, adaptation: adaptation, contrast: contrast) else { return nil }
        images[key] = shifted
        return shifted
    }

    /// `image` shifted into `adaptation`'s bounds (see the type).
    static func shift(_ image: CGImage, adaptation: ColorScheme, contrast: ColorSchemeContrast) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let toLinear = (0..<256).map { i -> Double in
            let c = Double(i) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func encode(_ l: Double) -> UInt8 {
            let l = min(1, max(0, l))
            let c = l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055
            return UInt8((c * 255).rounded())
        }
        let grey = GlassContrast.bound(adaptation, contrast)
        let bound = GlassContrast.luminance(r: grey, g: grey, b: grey)
        let dark = adaptation == .dark
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let r = toLinear[Int(pixels[i])], g = toLinear[Int(pixels[i + 1])], b = toLinear[Int(pixels[i + 2])]
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if dark {
                guard l > bound else { continue }
                let k = bound / l
                pixels[i] = encode(r * k); pixels[i + 1] = encode(g * k); pixels[i + 2] = encode(b * k)
            } else {
                guard l < bound else { continue }
                let t = (bound - l) / (1 - l)
                pixels[i] = encode(r + (1 - r) * t); pixels[i + 1] = encode(g + (1 - g) * t); pixels[i + 2] = encode(b + (1 - b) * t)
            }
        }
        return context.makeImage()
    }

    /// This view's slice of the stage's shifted backdrop (a neutral grey of the look's bound without a stage).
    struct Slice: View {
        var style: GlassStyle
        var adaptation: ColorScheme
        var contrast: ColorSchemeContrast
        @Environment(\.glassStage) private var stage

        var body: some View {
            GeometryReader { proxy in
                if let stage, let image = GlassAdaptedBackdrop.image(stage, style: style, adaptation: adaptation, contrast: contrast) {
                    let origin = proxy.frame(in: .named(GlassStageInfo.space)).origin
                    Image(decorative: image, scale: GlassAdaptedBackdrop.scale)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: stage.size.width, height: stage.size.height)
                        .offset(x: -origin.x, y: -origin.y)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                } else {
                    Color(white: GlassContrast.bound(adaptation, contrast))
                }
            }
        }
    }
}

/// Glass in `shape`: the glass (or the stand-in, or Reduce Transparency's solid), the floor and the rim, all clipped to
/// the shape. Takes no click and says nothing to VoiceOver. It holds no state and no clock: nothing ticks at rest.
struct GlassSurface<S: Shape>: View {
    var shape: S
    var style: GlassStyle = .island
    @Environment(\.glassRendering) private var rendering
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GlassSurfaceBody(shape: shape, style: style, rendering: rendering, reduceTransparency: reduceTransparency, contrast: contrast)
    }
}

/// `GlassSurface` with what it reads from the environment given outright (tests draw Reduce Transparency and Increase
/// Contrast with it, which the environment only reads).
struct GlassSurfaceBody<S: Shape>: View {
    var shape: S
    var style: GlassStyle
    var rendering: GlassRendering
    var reduceTransparency: Bool
    var contrast: ColorSchemeContrast

    var body: some View {
        ZStack {
            if style.glassFollowsShape { base(shape) } else { base(Rectangle()) }
            // A rim of no width: the surface draws its rim itself (the island's rides its outline, `IslandGlassRim`).
            if style.edge.width > 0 { GlassRim(shape: shape, edge: style.edge(contrast)) }
        }
        .clipShape(shape)
        // Smoke's glass is dark whatever the Appearance, as `GlassSurfaceNSView`'s is (P760, P767).
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The glass (the stand-in, or the solid) and the floor, in `base`: the surface's shape, or the frame its outline clips.
    @ViewBuilder private func base<B: Shape>(_ base: B) -> some View {
        if reduceTransparency {
            base.fill(style.solid)
        } else {
            switch rendering {
            case .live: base.fill(Color.clear).glassEffect(.regular, in: base)
            case .standIn: GlassStandIn(shape: base, style: style)
            }
            base.fill(Color.black.opacity(style.floor(contrast)))
        }
    }
}

/// The rim: the shape's outline stroked twice its width in plain white and clipped by the surface, so only the inner
/// half shows, its light laid on by a still mask. (A gradient stroke of a moving outline costs the main thread six times
/// a plain one each frame; the mask does not move, P527.)
struct GlassRim<S: Shape>: View {
    var shape: S
    var edge: GlassEdge
    /// The light's colour (white; the Glass widget's is its dark ink where the appearance is light).
    var colour = Color.white

    var body: some View {
        shape.stroke(colour, lineWidth: edge.width * 2)
            .mask {
                if let reach = edge.reach {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.white.opacity(edge.top), .white.opacity(edge.bottom)], startPoint: .top, endPoint: .bottom)
                            .frame(height: reach)
                        Color.white.opacity(edge.bottom)
                    }
                } else {
                    LinearGradient(colors: [.white.opacity(edge.top), .white.opacity(edge.bottom)], startPoint: .top, endPoint: .bottom)
                }
            }
    }
}

/// The render suites' glass: the stage's backdrop, as far as it reaches under this surface, saturated and blurred (the
/// whole backdrop is blurred, then this surface's part of it shown, so its edges blur into their surroundings as the
/// glass's do). With no stage, a neutral grey.
struct GlassStandIn<S: Shape>: View {
    var shape: S
    var style: GlassStyle
    /// The backdrop as it is, neither blurred nor saturated: what shows through a surface with no glass (the widget).
    var sharp = false
    @Environment(\.glassStage) private var stage

    var body: some View {
        GeometryReader { proxy in
            if let stage {
                let origin = proxy.frame(in: .named(GlassStageInfo.space)).origin
                stage.backdrop.view
                    .frame(width: stage.size.width, height: stage.size.height)
                    .clipped()
                    .saturation(sharp ? 1 : style.standInSaturation)
                    .blur(radius: sharp ? 0 : style.standInBlur, opaque: true)
                    .offset(x: -origin.x, y: -origin.y)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            } else {
                Color(white: 0.5)
            }
        }
        .clipShape(shape)
    }
}

// MARK: Backdrops and the stage (renders and the Settings preview)

/// What is behind a surface in a render or the Settings preview: the three backdrops the look is judged on (a white
/// window, a black desktop, a busy photo), and the preview's calm wallpaper. Drawn in code, so a render is the same on
/// every Mac and nothing of the owner's (a wallpaper, a window) is ever read.
enum GlassBackdrop: String, CaseIterable, Sendable {
    case white, black, busy, preview
    /// Glass look's sample wallpapers (P870): a night photo (a dark sky, a moon's glow, stars, a city's lights), a purple
    /// to pink gradient (lavender #8A8CC8 in its middle, where the owner's widgets stood) and a near-white one.
    case night, gradient, nearWhite

    /// Glass look's three, the owner's two first.
    static let wallpapers: [GlassBackdrop] = [.night, .gradient, .nearWhite]

    /// The three the legibility checks use (P522).
    static let judged: [GlassBackdrop] = [.white, .black, .busy]

    /// Which way the system's glass adapts over this backdrop, as the Glass stand-in draws it (`GlassAdaptedStandIn`):
    /// light over the white window; dark over the black desktop, the busy photo (its mean is darker than mid grey) and
    /// the preview's dusk.
    var adaptation: ColorScheme { self == .white || self == .nearWhite ? .light : .dark }

    @ViewBuilder var view: some View {
        switch self {
        case .white: Color.white
        case .black: Color.black
        case .busy: Canvas { context, size in Self.drawBusy(&context, size) }
        case .preview: Canvas { context, size in Self.drawPreview(&context, size) }
        case .night: Canvas { context, size in Self.drawNight(&context, size) }
        case .gradient:
            LinearGradient(colors: [Color(hex: 0x6C63C9), Color(hex: 0x8A8CC8), Color(hex: 0xC48FC6), Color(hex: 0xF08BB8)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .nearWhite:
            LinearGradient(colors: [Color(hex: 0xF7F5F2), Color(hex: 0xEEF0F5)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// A night photo's worth: a navy sky darkening upward, a moon's soft glow, a scatter of stars, and a city's warm
    /// lights along the bottom. Fixed points, so a render is the same every time.
    private static func drawNight(_ context: inout GraphicsContext, _ size: CGSize) {
        let all = Path(CGRect(origin: .zero, size: size))
        context.fill(all, with: .linearGradient(Gradient(colors: [Color(hex: 0x0A0F24), Color(hex: 0x1B2440), Color(hex: 0x2E3558)]),
                                                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        let moon = CGPoint(x: size.width * 0.78, y: size.height * 0.16)
        context.fill(all, with: .radialGradient(Gradient(colors: [Color(hex: 0xDDE4F5, alpha: 0.55), Color(hex: 0xDDE4F5, alpha: 0)]),
                                                center: moon, startRadius: 0, endRadius: max(size.width, size.height) * 0.22))
        context.fill(Path(ellipseIn: CGRect(x: moon.x - 7, y: moon.y - 7, width: 14, height: 14)), with: .color(Color(hex: 0xF4F1E6)))
        let stars: [(x: CGFloat, y: CGFloat)] = [(0.05, 0.08), (0.14, 0.22), (0.23, 0.05), (0.31, 0.17), (0.42, 0.09), (0.47, 0.27),
                                                 (0.55, 0.04), (0.61, 0.21), (0.69, 0.33), (0.88, 0.07), (0.93, 0.26), (0.36, 0.38),
                                                 (0.09, 0.41), (0.73, 0.45), (0.19, 0.31)]
        for star in stars {
            context.fill(Path(ellipseIn: CGRect(x: star.x * size.width, y: star.y * size.height, width: 1.6, height: 1.6)), with: .color(.white))
        }
        let horizon = size.height * 0.82
        context.fill(Path(CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon)),
                     with: .linearGradient(Gradient(colors: [Color(hex: 0x3A2C3A), Color(hex: 0x15121C)]),
                                           startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: size.height)))
        for i in 0..<14 {
            let x = size.width * (0.03 + 0.07 * CGFloat(i)), y = horizon + CGFloat((i * 7) % 5) * 3 + 4
            let colour = Color(hex: i.isMultiple(of: 3) ? 0xF5C26B : 0xF2A65A)
            context.fill(Path(ellipseIn: CGRect(x: x - 10, y: y - 6, width: 20, height: 12)),
                         with: .radialGradient(Gradient(colors: [colour, colour.opacity(0)]), center: CGPoint(x: x, y: y), startRadius: 0, endRadius: 10))
        }
    }

    /// A photo's worth of trouble: saturated blobs of every hue, a white-hot spot, hard black-and-white stripes and a
    /// checkerboard, on a blue-to-orange sky.
    private static func drawBusy(_ context: inout GraphicsContext, _ size: CGSize) {
        let all = Path(CGRect(origin: .zero, size: size))
        context.fill(all, with: .linearGradient(Gradient(colors: [Color(hex: 0x1B3A8C), Color(hex: 0xC2327A), Color(hex: 0xF59E2A)]),
                                                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        let reach = max(size.width, size.height)
        let blobs: [(x: CGFloat, y: CGFloat, r: CGFloat, hex: UInt32)] = [
            (0.10, 0.30, 0.20, 0xFFF36B), (0.34, 0.05, 0.16, 0x3FE0D0), (0.62, 0.60, 0.22, 0xFFFFFF),
            (0.86, 0.15, 0.15, 0x7CFF6B), (0.26, 0.85, 0.18, 0x2A6BFF), (0.95, 0.75, 0.14, 0xFF3B30),
        ]
        for blob in blobs {
            let centre = CGPoint(x: blob.x * size.width, y: blob.y * size.height), radius = blob.r * reach
            let colour = Color(hex: blob.hex)
            context.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)),
                         with: .radialGradient(Gradient(colors: [colour, colour.opacity(0)]), center: centre, startRadius: 0, endRadius: radius))
        }
        let stripe: CGFloat = 6
        var x = size.width * 0.44
        var white = true
        while x < size.width * 0.58 {
            context.fill(Path(CGRect(x: x, y: 0, width: stripe, height: size.height)), with: .color(white ? .white : .black))
            x += stripe
            white.toggle()
        }
        let cell: CGFloat = 8
        for row in 0..<Int(size.height / cell) + 1 {
            for col in 0..<6 where (row + col).isMultiple(of: 2) {
                context.fill(Path(CGRect(x: size.width * 0.04 + CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                             with: .color(.white))
            }
        }
    }

    /// The Settings preview's wallpaper: a calm dusk with one bright band, so the glass has something to show.
    private static func drawPreview(_ context: inout GraphicsContext, _ size: CGSize) {
        let all = Path(CGRect(origin: .zero, size: size))
        context.fill(all, with: .linearGradient(Gradient(colors: [Color(hex: 0x2B5876), Color(hex: 0x4E4376), Color(hex: 0xE96443)]),
                                                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        let centre = CGPoint(x: size.width * 0.62, y: size.height * 0.2)
        context.fill(all, with: .radialGradient(Gradient(colors: [Color(hex: 0xFFE29F), Color(hex: 0xFFE29F, alpha: 0)]), center: centre,
                                                startRadius: 0, endRadius: size.width * 0.35))
    }
}

/// A stage's backdrop and size, for the stand-ins under it.
struct GlassStageInfo: Equatable, Sendable {
    var backdrop: GlassBackdrop
    var size: CGSize
    /// The look Glass's stand-in takes on this stage: the Appearance a render (or the Settings preview) asks for, as the
    /// live glass takes the window's (P764, P765). nil: the backdrop's own (`GlassBackdrop.adaptation`), as every render
    /// made before the Appearance drew it.
    var look: ColorScheme? = nil
    /// A render's own model of the glass's face (`GlassFaceModel`): Glass's stand-in draws the backdrop through it, in the
    /// stage's look (Widget's, dark): the measured light face for Light and dark beside Widget's, or a reference's. nil:
    /// Widget's dark face under Widget, the model of bounds otherwise, as every render before it.
    var face: GlassFaceModel? = nil
    /// A reference of the desktop widgets' look (renders only): the glass's stand-in with no Frost of ours at all.
    var bare = false

    /// The stage's coordinate space: a stand-in finds its place on the backdrop in it.
    static let space = "juice.glass.stage"
}

/// A backdrop with content over it: the content's glass surfaces see this backdrop behind them, live (the real glass
/// blurs what the window draws under it) or as the stand-in (`GlassRendering.standIn`). It fills the size it is given.
struct GlassStage<Content: View>: View {
    var backdrop: GlassBackdrop
    /// The look its glass stand-ins take (`GlassStageInfo.look`); nil, the backdrop's.
    var look: ColorScheme? = nil
    /// The face its glass stand-ins draw the backdrop through (`GlassStageInfo.face`); nil, the stand-ins' own.
    var face: GlassFaceModel? = nil
    /// No Frost of ours on its glass (`GlassStageInfo.bare`).
    var bare = false
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                backdrop.view.frame(width: proxy.size.width, height: proxy.size.height).clipped()
                content.environment(\.glassStage, GlassStageInfo(backdrop: backdrop, size: proxy.size, look: look, face: face, bare: bare))
            }
        }
        .coordinateSpace(.named(GlassStageInfo.space))
    }
}
