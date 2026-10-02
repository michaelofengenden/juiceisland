import SwiftUI

/// The app icon in a Glyph style, for the Dock (`DockIcon`) and Settings › About: `scripts/make-icon.swift`'s squircle,
/// ground and island pill on Apple's 1024 grid, with the style's own drawing under the pill.
///
/// - Pixel: the bundle's icon (make-icon's `glyph` variant): the brand juice box in pixels, a done dot and an equalizer
///   in the pill.
/// - Liquid: juice pouring out of the pill into a pool (`liquidTime`). The running body alone, floating mid-roll,
///   reads as a bun at the Dock's sizes; a pour reads as juice at any size.
/// - Sand: a stream pouring out of the pill onto a pile, the island as the neck of an hourglass: the running mood's
///   still frame, its stream unbroken.
///
/// Liquid and Sand both pour from the island, and all three share the ground and the pill: one family at a glance.
///
/// The hero is the engines' own frame in the brand orange: the icon is the app's mark, not a session's, so Glyph colour
/// never tints it (the brand glyph is brand orange in both colour modes). Every part is a still frame with no timeline,
/// so the art draws once. `side` is the whole square, margins and shadow included; the body is 824/1024 of it.
struct AppIconArt: View {
    var style: GlyphStyle
    var side: CGFloat

    var body: some View {
        let u = side / 1024
        ZStack {
            IconBody()
                .fill(LinearGradient(stops: [.init(color: Color(hex: 0x2A2A2E), location: 0),
                                             .init(color: Color(hex: 0x0C0C0D), location: 0.45),
                                             .init(color: .black, location: 1)],
                                     startPoint: UnitPoint(x: Self.gradientStart, y: Self.inset / 1024),
                                     endPoint: UnitPoint(x: 1 - Self.gradientStart, y: 1 - Self.inset / 1024)))
                .shadow(color: .black.opacity(0.45), radius: 16 * u, y: 12 * u)
            ZStack {
                hero(u)
                pill(u)
            }
            .clipShape(IconBody())
            IconBody(inset: 2)
                .stroke(Color.white(0.16), lineWidth: 3 * u)
        }
        .frame(width: side, height: side)
    }

    /// The body's margin on the 1024 grid, and where its gradient runs from (a share of the square across, at the top).
    nonisolated static let inset: CGFloat = 100
    static let gradientStart: CGFloat = (inset + 824 * 0.3) / 1024

    /// The brand colour every hero is drawn in.
    static let colour = IslandTheme.brand

    // MARK: The hero

    /// Liquid's moment: 0.075 of the needs-you beat, the jet nearly risen and not yet pinched into a mark. Its top sits
    /// inside the pill, so what shows is a column of juice poured out of the island, narrowing as it falls, and the
    /// mound it raises in the pool it lands in. The fifth beat's clock leaves the pool's waves level.
    static let liquidTime: TimeInterval = (4 + 0.075) * LiquidGlyph.beat
    /// Where a pour starts on the 1024 grid: inside the pill, a third of its height above its bottom edge.
    static let pourTop: CGFloat = pill.maxY - 31
    /// The heroes' squares on the 1024 grid: each pour starts at `pourTop`, and both land about 785 down. Liquid's is
    /// placed by its jet's top in the frame itself (at a side where the engine draws its full-size waves); Sand's
    /// stream starts at `SandGlyph.streamTop`.
    static let liquidSquare: CGRect = {
        let side = 680.0
        let top = LiquidGlyph.frame(mood: .approval, time: liquidTime, side: side).map(\.path.boundingRect.minY).min() ?? 0
        return CGRect(x: 512 - side / 2, y: pourTop - top, width: side, height: side)
    }()
    static let sandSquare = CGRect(x: 512 - 320, y: pourTop - SandGlyph.streamTop * 640, width: 640, height: 640)

    @ViewBuilder private func hero(_ u: CGFloat) -> some View {
        switch style {
        case .pixel:
            PixelIconArt(rows: PixelGlyph.patterns[.brand]!, colour: Self.colour, pixel: 58 * u)
                .position(x: 512 * u, y: (512 + 48) * u)
        case .liquid:
            let square = Self.liquidSquare, s = square.width * u
            LiquidGlyphFrame(primitives: LiquidGlyph.frame(mood: .approval, time: Self.liquidTime, side: s), colour: Self.colour, side: s)
                .position(x: square.midX * u, y: square.midY * u)
        case .sand:
            let square = Self.sandSquare, s = square.width * u
            SandFrameView(frame: SandGlyph.stillFrame(mood: .running, side: s), colour: Self.colour, side: s)
                .position(x: square.midX * u, y: square.midY * u)
        }
    }

    // MARK: The pill

    /// The island hanging from the body's top edge: pure black with a hairline; in Pixel, a done dot and an equalizer
    /// as the closed pill shows a finished and a working session.
    private func pill(_ u: CGFloat) -> some View {
        let height = Self.pill.height
        return ZStack {
            Capsule().fill(.black)
            Capsule().stroke(Color.white(0.14), lineWidth: 3 * u)
            if style == .pixel {
                HStack(spacing: 0) {
                    Circle().fill(IslandTheme.done)
                        .frame(width: height * 0.3 * u, height: height * 0.3 * u)
                        .shadow(color: IslandTheme.done, radius: 3 * u)
                        .shadow(color: IslandTheme.done.opacity(0.55), radius: 8 * u)
                    Spacer(minLength: 0)
                    PixelIconArt(rows: Self.equalizerRows, colour: IslandTheme.run, pixel: height * 0.52 / 7 * u)
                }
                .padding(.horizontal, height * 0.42 * u)
            }
        }
        .frame(width: Self.pill.width * u, height: height * u)
        .position(x: Self.pill.midX * u, y: Self.pill.midY * u)
    }

    /// The pill on the 1024 grid: 330 × 92, 34 under the body's top edge.
    static let pill = CGRect(x: 512 - 165, y: inset + 34, width: 330, height: 92)

    /// The equalizer's first still frame with no caps, as make-icon draws it.
    static let equalizerRows: [String] = (0..<7).map { y in
        String((0..<7).map { x -> Character in
            guard x % 2 == 0 else { return "." }
            return 6 - y < PixelGlyph.equalizerFrames[0][x / 2] ? "#" : "."
        })
    }
}

/// The icon's body: make-icon's squircle (Apple's continuous corners, each three cubics reaching 1.528 radii along
/// both edges) at the 824 px body of the 1024 grid, or `inset` grid units inside it.
struct IconBody: Shape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let u = rect.width / 1024
        let body = rect.insetBy(dx: (AppIconArt.inset + inset) * u, dy: (AppIconArt.inset + inset) * u)
        let r = (185.4 - inset) * u
        var path = Path()
        // Corner, the edge direction into it and the edge direction out of it, clockwise from the top right (y down).
        let corners: [(CGPoint, CGVector, CGVector)] = [
            (CGPoint(x: body.maxX, y: body.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
            (CGPoint(x: body.maxX, y: body.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
            (CGPoint(x: body.minX, y: body.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
            (CGPoint(x: body.minX, y: body.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
        ]
        for (index, (corner, into, out)) in corners.enumerated() {
            // (distance before the corner along `into`, distance past the edge along `out`), in radii.
            func p(_ t: CGFloat, _ n: CGFloat) -> CGPoint {
                CGPoint(x: corner.x - t * r * into.dx + n * r * out.dx, y: corner.y - t * r * into.dy + n * r * out.dy)
            }
            if index == 0 { path.move(to: p(1.52866483, 0)) } else { path.addLine(to: p(1.52866483, 0)) }
            path.addCurve(to: p(0.66993427, 0.06549600), control1: p(1.08849323, 0), control2: p(0.86840689, 0))
            path.addCurve(to: p(0.06549569, 0.66993493), control1: p(0.37260046, 0.17941168), control2: p(0.17941097, 0.37260121))
            path.addCurve(to: p(0, 1.52866483), control1: p(0, 0.86840689), control2: p(0, 1.08849323))
        }
        path.closeSubpath()
        return path
    }
}

/// Pixel art at an icon's size, as make-icon draws it: gaps an eighth of a pixel, the top pixel of a column 100 % and
/// the ones under it 85 %, under two glows that grow with the pixel (the app's 2.5 and 6 at 55 % per 4 pt pixel).
private struct PixelIconArt: View {
    let rows: [String]
    let colour: Color
    let pixel: CGFloat

    var body: some View {
        let alphas = PixelGlyph.alphas(rows: rows)
        Canvas { context, _ in
            let side = pixel * 0.875
            for (y, row) in alphas.enumerated() {
                for (x, alpha) in row.enumerated() where alpha > 0 {
                    context.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: side, height: side)),
                                 with: .color(colour.opacity(alpha)))
                }
            }
        }
        .frame(width: pixel * 7, height: pixel * 7)
        .shadow(color: colour, radius: 2.5 * pixel / 4 * 0.8)
        .shadow(color: colour.opacity(0.55), radius: 6 * pixel / 4 * 0.8)
    }
}
