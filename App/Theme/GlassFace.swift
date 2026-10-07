import SwiftUI

// Settings › Island › Glass look (the owner's "ideally the glass of the panel and the island should be similar to the
// glass of the widgets" of 2026-10-02; P870 to P879). macOS draws a desktop widget, whenever the desktop is not in front,
// in accented rendering: its content tinted white, its background taken away and replaced with the system's themed
// glass or tinted colour (WWDC25 "What's new in widgets"), a deeper and more saturated version of the wallpaper behind
// it with white ink and a faint lighter edge, in light mode as in dark. The public glass that does the same is the
// system's regular glass in its dark face: SwiftUI takes the face from the colour scheme in force where `glassEffect`
// is applied, and the dark face saturates its backdrop (1.3) and keeps it under a luma ceiling (0.6). So Widget is
// Glass drawn in the dark scheme, whatever the Appearance: the glass's dark face, Frost's dark ground inside it at half
// at the least (the face is a mid grey over a white window, `GlassFrost.widgetFloor`, P874), and every ink in its Widget
// twin, held on that (white text, the greys near white, the glyphs at full colour with an edge that holds there, P879).
// Light and dark is Glass as it was, the Appearance's look. Nothing is sampled.

/// Settings › Island › Glass look, under Theme while Glass is chosen: Widget (the default) or Light and dark.
enum GlassLookChoice: String, CaseIterable, Codable, Sendable {
    /// The desktop widgets' look: the glass's dark face and white ink, in either macOS mode.
    case widget
    /// The Appearance's look (Settings › General › Appearance), light or dark, as Glass always was.
    case lightAndDark

    var title: String {
        switch self {
        case .widget: "Widget"
        case .lightAndDark: "Light and dark"
        }
    }

    /// The look Glass's surfaces take where the Appearance's is `appearance`.
    func scheme(appearance: ColorScheme) -> ColorScheme { self == .widget ? .dark : appearance }
}

extension EnvironmentValues {
    /// Settings › Island › Glass look, as Glass's surfaces draw it. Light and dark unless a root sets it
    /// (`juiceThemeFromSettings()`), so renders and previews stay as they were until they ask (P637).
    @Entry var glassLook: GlassLookChoice = .lightAndDark
}

/// `inGlass`'s look: under Widget the dark scheme where the glass is applied, so SwiftUI draws the glass's dark face and
/// hands its content the dark look, each ink in its Widget twin where it has one (`\.glassWidgetInk`, P879); under Light
/// and dark nothing (the Appearance's, as before).
struct GlassLookFace: ViewModifier {
    @Environment(\.glassLook) private var glassLook
    @Environment(\.widgetGlassState) private var widgetState

    func body(content: Content) -> some View {
        content
            .transformEnvironment(\.colorScheme) { if glassLook == .widget { $0 = .dark } }
            .transformEnvironment(\.glassWidgetInk) { if glassLook == .widget { $0 = true } }
            // The desktop's widgets dimmed: their content tinted white, so the panel's (P1227).
            .transformEnvironment(\.glassWidgetMono) { if glassLook == .widget, widgetState == .dimmed { $0 = true } }
    }
}

// MARK: The glass's faces, as Core Animation draws them (renders only)

/// One face of the system's regular glass over a flat colour, as Core Animation itself renders the glass's own filter
/// (`glassBackground`, measured once on macOS 27, offscreen): a grey comes out as `tone` says, and a colour as the grey
/// of its luma plus its distance from it times the chroma, `chromaAtBlack` for a dark colour going to `chromaAtWhite`
/// for a light one. The live glass also blurs, refracts at its edge and lights its
/// rim, which a flat colour cannot show. The stand-in for the glass's look over a sample wallpaper in renders, beside a
/// reference made the same way (`GlassStageInfo.face`), and the ground Widget's ink is held on (`GlassContrast.widgetSurface`,
/// P879). Never drawn live, where the glass is the window server's.
struct GlassFaceModel: Hashable, Sendable {
    /// What a grey comes out as (encoded sRGB, 0 to 1), for greys 0, 1/15, 2/15 … 1.
    var tone: [Double]
    /// How much of a colour's distance from its grey comes through, for a colour of luma 0 and of luma 1.
    var chromaAtBlack: Double
    var chromaAtWhite: Double

    /// The dark face, Widget's: black comes out as #141414, a mid grey as itself, white as #B4B4B4; the owner's lavender
    /// #8A8CC8 as #8285C5, pink #E58BC0 as #D97BB2.
    static let dark = GlassFaceModel(tone: [0x14, 0x26, 0x36, 0x45, 0x54, 0x61, 0x6E, 0x7A, 0x84, 0x8E, 0x97, 0x9F, 0xA5, 0xAB, 0xB0, 0xB4]
        .map { Double($0) / 255 }, chromaAtBlack: 1.30, chromaAtWhite: 0.87)
    /// The light face, Light and dark's in a light Appearance: black comes out as #6F6F6F, white as #EDEDEE; the lavender
    /// as #B2B4F6, a night sky's #1B2440 as #7882A1.
    static let light = GlassFaceModel(tone: [0x6F, 0x78, 0x81, 0x89, 0x92, 0x9B, 0xA3, 0xAC, 0xB4, 0xBD, 0xC5, 0xCD, 0xD5, 0xDD, 0xE5, 0xED]
        .map { Double($0) / 255 }, chromaAtBlack: 1.10, chromaAtWhite: 1.10)

    /// The face of `scheme`.
    static func of(_ scheme: ColorScheme) -> GlassFaceModel { scheme == .dark ? .dark : .light }

    /// A colour (encoded sRGB, 0 to 1) through this face.
    func apply(_ r: Double, _ g: Double, _ b: Double) -> (r: Double, g: Double, b: Double) {
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let grey = tone(luma), chroma = chromaAtBlack + (chromaAtWhite - chromaAtBlack) * luma
        func channel(_ c: Double) -> Double { min(1, max(0, grey + chroma * (c - luma))) }
        return (channel(r), channel(g), channel(b))
    }

    /// The grey `luma` comes out as, between the measured greys.
    func tone(_ luma: Double) -> Double {
        let steps = Double(tone.count - 1)
        let x = min(1, max(0, luma)) * steps
        let i = min(tone.count - 2, Int(x))
        return tone[i] + (tone[i + 1] - tone[i]) * (x - Double(i))
    }
}

/// A stage's backdrop blurred as the stand-ins blur it, then put through a face (`GlassFaceModel`), drawn once for a
/// stage, a style and a face and kept. Headless only.
@MainActor
enum GlassFaceBackdrop {
    private struct Key: Hashable {
        var backdrop: GlassBackdrop
        var width: CGFloat, height: CGFloat
        var blur: CGFloat
        var face: GlassFaceModel
    }

    private static var images: [Key: CGImage] = [:]

    static func image(_ stage: GlassStageInfo, style: GlassStyle, face: GlassFaceModel) -> CGImage? {
        let key = Key(backdrop: stage.backdrop, width: stage.size.width, height: stage.size.height, blur: style.standInBlur, face: face)
        if let image = images[key] { return image }
        let renderer = ImageRenderer(content: stage.backdrop.view
            .frame(width: stage.size.width, height: stage.size.height)
            .clipped()
            .blur(radius: style.standInBlur, opaque: true))
        renderer.scale = GlassAdaptedBackdrop.scale
        guard let blurred = renderer.cgImage, let faced = apply(face, to: blurred) else { return nil }
        images[key] = faced
        return faced
    }

    /// `image` through `face`, pixel by pixel.
    static func apply(_ face: GlassFaceModel, to image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let out = face.apply(Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255)
            pixels[i] = UInt8((out.r * 255).rounded())
            pixels[i + 1] = UInt8((out.g * 255).rounded())
            pixels[i + 2] = UInt8((out.b * 255).rounded())
        }
        return context.makeImage()
    }

    /// This view's slice of the stage's backdrop through `face` (the face's mid grey without a stage).
    struct Slice: View {
        var style: GlassStyle
        var face: GlassFaceModel
        @Environment(\.glassStage) private var stage

        var body: some View {
            GeometryReader { proxy in
                if let stage, let image = GlassFaceBackdrop.image(stage, style: style, face: face) {
                    let origin = proxy.frame(in: .named(GlassStageInfo.space)).origin
                    Image(decorative: image, scale: GlassAdaptedBackdrop.scale)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: stage.size.width, height: stage.size.height)
                        .offset(x: -origin.x, y: -origin.y)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                } else {
                    Color(white: face.tone(0.5))
                }
            }
        }
    }
}

/// The glass's stand-in through a face (renders only): Widget's (the dark face, its content dark), or the face a stage
/// asks for (`GlassStageInfo.face`). Reduce Transparency: the look's opaque ground. Where the glass takes the surface's
/// shape (the panel, the chip) the rim stands in for the system glass's own lighter edge, as `GlassAdaptedStandIn`'s.
struct GlassFaceStandIn<S: Shape>: View {
    var shape: S
    var style: GlassStyle
    var face: GlassFaceModel
    var scheme: ColorScheme
    var reduceTransparency: Bool
    var contrast: ColorSchemeContrast

    var body: some View {
        let base = style.glassFollowsShape ? AnyShape(shape) : AnyShape(Rectangle())
        ZStack {
            if reduceTransparency {
                base.fill(scheme == .dark ? GlassAdapted.solidDark : GlassAdapted.solidLight)
            } else {
                GlassFaceBackdrop.Slice(style: style, face: face).clipShape(base)
            }
            if style.glassFollowsShape, style.edge.width > 0 {
                GlassRim(shape: shape, edge: style.edge(contrast), colour: GlassAdapted.rimColour)
            }
        }
        .clipShape(base)
        .environment(\.colorScheme, scheme)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
