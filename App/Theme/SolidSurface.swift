import AppKit
import SwiftUI

// Theme Solid (P770 to P779; the owner's "a mode that is ... not glass but more solid like black but takes color perhaps
// from the background or is white or light" of 2026-10-01). Opaque, not glass: the system's window background, light or
// dark with Settings › General › Appearance, tinted by the wallpaper the way macOS tints its own windows. Its ink is
// Glass's twins for the look in force (`IslandPalette.glass`, `Color.adaptive`, `GlyphFinish.glass`); a hairline keeps
// it apart from a light menu bar or wallpaper (and a soft shadow, where its window has room for one: the desktop panel
// and its chip); under the hardware notch, a black plate in the notch's own shape.
//
// The material, read off its layers on macOS 27 (P770): the window background (`NSVisualEffectView.Material
// .windowBackground`, and SwiftUI's own `.windowBackground` style, which builds the same layers) is an opaque fill, white
// in the light look and #1E1E1E in the dark one, and in the dark one the system lays its desktop tint over it (a
// `CAChameleonLayer` named "desktop tint" at 10 %), which is what System Settings › Appearance › "Allow wallpaper tinting
// in windows" switches. The light window background carries no tint on macOS 27, so Solid's light look is white, as the
// system's own windows are. Under-window background is translucent (a backdrop blur under an 84 % fill: it shows the
// windows behind it, so it is not solid); under-page background is opaque and tinted in both looks but darker than any
// window (#F6F6F6, #141414) and has no SwiftUI style, so SwiftUI's outline could not draw it.
//
// Nothing is sampled: the tint is the window server's, and no screen or wallpaper file is read.

/// Solid's numbers.
enum SolidLook {
    /// The system material Solid is made of where AppKit hosts the surface (Core Animation's outline,
    /// `GlassSurfaceNSView.Backdrop.window`), blended behind the window and always active.
    static let material = NSVisualEffectView.Material.windowBackground

    /// The window background's own fill on each look (macOS 27): what Solid shows with the tint off, under Reduce
    /// Transparency, and in a render, which has no wallpaper behind it.
    static let lightGround: UInt32 = 0xFFFFFF
    static let darkGround: UInt32 = 0x1E1E1E
    static let ground = Color.adaptive(lightGround, darkGround)

    /// The desktop tint the system lays over the dark window background (its layer's opacity on macOS 27); the light one
    /// takes none.
    static let darkTint = 0.10

    /// The brightest the dark ground gets: #1E1E1E under a white wallpaper's 10 % (encoded sRGB, as the window server
    /// blends), and the darkest the light ground gets (white, untinted). Both lie inside Glass's bounds (#404040 and
    /// #BFBFBF, `GlassContrast.bound`), so every one of Glass's twins holds its ratio on Solid too (P775).
    static var worstDark: Double { Double((darkGround >> 16) & 0xFF) / 255 * (1 - darkTint) + darkTint }
    static let worstLight = 1.0

    /// The hairline just inside the outline, as a macOS window's edge: the ink at a little strength where it is light,
    /// white where it is dark (P774).
    static let edgeColour = Color.adaptive(light: Color.black.opacity(lightEdge), dark: Color.white.opacity(0.18))
    /// The light hairline's strength: the island has no shadow (below), so its edge alone keeps it apart from a light
    /// menu bar.
    static let lightEdge = 0.24
    /// The island's hairline: half a point inside the outline, nothing along the screen's edge and its full strength from
    /// 6 pt down, so the top bar's 24 pt pill has it at full strength along its sides and its bottom.
    ///
    /// The island casts no shadow on either outline: its window is exactly its outline at rest (P36) and draws no window
    /// shadow, so a shadow past the outline would be cut at the window's edges and show only as wedges under the ears.
    /// The desktop panel and its chip, whose windows have room, keep Black's (`PanelGlassShadow`).
    static let islandEdge = GlassEdge(width: 0.5, top: 0, bottom: 1, reach: 6)
    /// The panel's and the chip's hairline width (Black's edge's).
    static let panelEdgeWidth: CGFloat = 0.5

    /// The notch plate on Solid (`SolidNotchPlate`, P790 to P797): the hardware notch's own shape in pure black, this
    /// far inside the notch's rect on each side and at its foot, so on the built-in display it lies wholly under the
    /// hardware and the ground meets the notch's own curve, even where a scaled display mode rounds the safe area past
    /// the cut-out (P796); in a screenshot or on a mirrored display it shows as the notch, never a box.
    static let plateInset: CGFloat = 0.5

    /// The plate's bottom corners: 3/8 of the notch's height, 12 pt at the 14-inch MacBook Pro's 32 pt. Public
    /// measurements give the hardware's own as about 8 pt at 32 (NotchBay, measured on the hardware with the screen's
    /// safe area); a plate rounder than the notch stays hidden under it, and one less round would show its corners as
    /// black beside the notch's curve, so it rounds half again as much. It scales with the notch's height: at another
    /// display scale the notch takes more points, and its corners take more with it (P791).
    static func plateRadius(_ notch: CGSize) -> CGFloat { notch.height * 3 / 8 }

    /// The plate's cut out of the edge line (`SolidNotchPlateCut`, P797) reaches this far past the pill's sides and top,
    /// and `cutReach` below its top: further than any opened island, so the line keeps its fade as it rides down.
    static let cutMargin: CGFloat = 64
    static let cutReach: CGFloat = 4_000

    /// Core Animation's outline: the cut as the mask of the edge line's carrier (`IslandCanvas`), a layer `band` tall at
    /// the top of a canvas `canvas` big whose middle is the notch's. Its frame in the carrier's space, over all the canvas
    /// the line can ride into, and its path in its own, running down the screen or up it as the carrier's space does.
    static func plateCut(_ notch: CGSize, canvas: CGSize, band: CGFloat, yDown: Bool) -> (frame: CGRect, path: CGPath) {
        let size = CGSize(width: canvas.width + 2 * cutMargin, height: canvas.height + 2 * cutMargin)
        let path = SolidNotchPlateCut(notchMinX: canvas.width / 2 - notch.width / 2 + cutMargin, notch: notch)
            .path(in: CGRect(x: 0, y: cutMargin, width: size.width, height: size.height - 2 * cutMargin))
        let frame = CGRect(x: -cutMargin, y: yDown ? -cutMargin : band + cutMargin - size.height, width: size.width, height: size.height)
        guard !yDown else { return (frame, path.cgPath) }
        return (frame, path.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)).cgPath)
    }
}

/// Solid's notch plate (P790 to P797): the notch's rect less `SolidLook.plateInset` each side and at its foot, its bottom
/// corners `SolidLook.plateRadius` round; hung from the rect's top, centred on its middle (the notch's). Filled pure #000 over everything else of the surface (the ground, the State tint's veil, the hairline) and
/// under the content, which never draws in the notch (`SolidNotchPlateView`). Nothing of it falls below the notch, so
/// the opened island is light right up to the notch's curve, and the closed pill's light wraps under it (P792).
struct SolidNotchPlate: Shape {
    var notch: CGSize

    func path(in rect: CGRect) -> Path {
        let width = max(0, notch.width - 2 * SolidLook.plateInset)
        let plate = SurfaceGeometry(width: width, height: max(0, notch.height - SolidLook.plateInset), ear: 0,
                                    radius: SolidLook.plateRadius(notch))
        return NotchSurfaceShape.path(plate, originX: rect.midX - width / 2, top: rect.minY)
    }
}

/// Everything but Solid's plate, for an even-odd clip (P797): the closed pill's edge line (Liquid and Sand, Pill edge line
/// on) runs from corner to corner under the notch, and cut by the plate it passes under the plate as it passes under the
/// hardware, so the plate stays pure #000 where the line crosses the notch's foot and the line shows beside the notch's
/// curve and below it. The notch starts `notchMinX` into the rect, at its top; everything else stays, well past the
/// rect's sides and far below it, where the line rides down as the island opens.
struct SolidNotchPlateCut: Shape {
    var notchMinX: CGFloat
    var notch: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path(CGRect(x: rect.minX - SolidLook.cutMargin, y: rect.minY - SolidLook.cutMargin,
                               width: rect.width + 2 * SolidLook.cutMargin, height: rect.height + SolidLook.cutReach))
        path.addPath(SolidNotchPlate(notch: notch).path(in: CGRect(x: rect.minX + notchMinX, y: rect.minY, width: notch.width,
                                                                   height: notch.height)))
        return path
    }
}

/// The plate, filled: pure black, still, no click, nothing for VoiceOver. Both outlines draw it last of the surface
/// (P793): SwiftUI's in `SolidIslandBody`, over the veil; Core Animation's in the content's background, over the veil the
/// content lays there and over the window material and its hairline under the content (`IslandGlassContent`).
struct SolidNotchPlateView: View, Equatable {
    var notch: CGSize

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.notch == rhs.notch }

    var body: some View {
        SolidNotchPlate(notch: notch)
            .fill(Color.black)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Solid's ground in `shape`: the window background, as SwiftUI draws it (`.windowBackground`: the system's fill and its
/// desktop tint, resolved in the colour scheme of the view, which is the Appearance's); in a render, the untinted ground
/// of the look (`SolidLook.ground`). Takes no click and says nothing to VoiceOver.
struct SolidGround<S: Shape>: View {
    var shape: S
    @Environment(\.glassRendering) private var rendering

    var body: some View {
        Group {
            switch rendering {
            case .live: shape.fill(.windowBackground)
            case .standIn: shape.fill(SolidLook.ground)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A free-standing Solid surface that never moves (the desktop panel, its chip, the Settings preview, a render of the
/// opened island alone): the ground in the shape, the hairline inside it, and the panel's soft shadow outside it
/// (`PanelGlassShadow`, cast by a shape of its own so the window material is never drawn into a shadow's group).
struct SolidSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var shadow = true

    func body(content: Content) -> some View {
        content
            .background { SolidGround(shape: shape) }
            .overlay { shape.strokeBorder(SolidLook.edgeColour, lineWidth: SolidLook.panelEdgeWidth).allowsHitTesting(false) }
            .background { if shadow { PanelGlassShadow(shape: shape) } }
    }
}

/// SwiftUI's outline on Solid: the ground filling the canvas (the outline clips it), the State tint's veil over it, the
/// hairline on the outline's two curves, and the notch plate over them all at the top. Core Animation's draws the ground
/// and the hairline from `GlassSurfaceNSView.Backdrop.window`, and the veil and the plate in the content's background.
struct SolidIslandBody: View {
    let ui: IslandUIState
    var notch: CGSize?
    /// Settings › Island › State tint: the lead state's veil over the ground (`IslandTintVeil`, P776).
    @Environment(\.islandStateTint) private var stateTint

    var body: some View {
        ZStack(alignment: .top) {
            SolidGround(shape: Rectangle())
            if stateTint { IslandTintVeil(ui: ui) }
            IslandGlassRim(surface: ui.live.surface, continuous: ui.tuning.continuousCorners, edge: SolidLook.islandEdge,
                           colour: SolidLook.edgeColour, liquid: ui.tuning.liquid ? ui.liquid : nil)
            if let notch { SolidNotchPlateView(notch: notch).equatable() }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
