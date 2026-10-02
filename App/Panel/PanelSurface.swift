import SwiftUI

/// The desktop panel's surface and its hover chip's (Juice spec §2.1, §2.5), in the environment's theme (P530, P565).
///
/// Black is today's surface, modifier for modifier: the black fill, the 0.5 pt edge and the soft shadow around it all.
/// Glass is the panel's content in the system's glass in the rounded shape (`inGlass`): no floor, no shadow of ours (the
/// system's glass draws its own edge and depth), its ink adapting with the glass (`PanelPalette.glass`, P561).
/// Smoke is the system's glass in the rounded shape (`GlassStyle.panel`: the panel never moves, so its glass takes its
/// shape, lit from above), under the dark floor that keeps every battery and money row legible over any wallpaper; the
/// glass's rim draws the edge. The shadow no longer wraps the surface: SwiftUI would draw it from the composited view,
/// glass and all, and whatever the window draws behind a live glass is what the glass blurs. So on glass the same
/// shadow is cast by a shape just inside the outline and kept outside it (`PanelGlassShadow`): behind the glass the
/// window is empty, and the glass blurs the desktop alone. Solid is the window material in the rounded shape, light or
/// dark with the Appearance (`SolidSurface`, P770): its hairline inside the outline and Black's shadow outside it, cast
/// the same way. Nothing here holds state or a clock.
struct PanelSurface: ViewModifier {
    var radius: CGFloat
    @Environment(\.juiceTheme) private var theme

    /// Black's shadow, kept on glass outside the outline.
    static let shadowColour = Color.black.opacity(0.14)
    static let shadowRadius: CGFloat = 8
    static let shadowY: CGFloat = 2

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        switch theme {
        case .black:
            content
                .background { shape.fill(Theme.surface) }
                .overlay { shape.strokeBorder(Theme.edge, lineWidth: 0.5) }
                .shadow(color: Self.shadowColour, radius: Self.shadowRadius, y: Self.shadowY)
        case .smoke:
            content
                .background { GlassSurface(shape: shape, style: .panel) }
                .background { PanelGlassShadow(shape: shape) }
        case .glass:
            content.inGlass(shape, style: GlassStyle.panel.clear)
        case .solid:
            content.modifier(SolidSurface(shape: shape))
        }
    }
}

/// The panel's shadow on Smoke and Solid: Black's shadow, cast by the shape inset 1 pt (its soft edge then falls wholly inside the
/// outline) and masked to outside the outline, so nothing of it lies behind the glass. It takes no click and says
/// nothing to VoiceOver.
struct PanelGlassShadow<S: InsettableShape>: View {
    var shape: S

    /// How far past the outline the mask reaches: the panel's window margin (`PanelGeometry.margin`), which holds the
    /// shadow.
    static var reach: CGFloat { PanelGeometry.margin }

    var body: some View {
        shape.inset(by: 1)
            .fill(Color.black)
            .shadow(color: PanelSurface.shadowColour, radius: PanelSurface.shadowRadius, y: PanelSurface.shadowY)
            .mask { Outside(shape: shape, reach: Self.reach).fill(style: FillStyle(eoFill: true)) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Everything within `reach` of the frame but the shape itself.
    private struct Outside: Shape {
        var shape: S
        var reach: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path(rect.insetBy(dx: -reach, dy: -reach))
            path.addPath(shape.path(in: rect))
            return path
        }
    }
}
