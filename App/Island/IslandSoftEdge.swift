import SwiftUI

/// Motion: Refined (F6). The opened island's content fades out over `MotionTuning.softEdge` points inside the outline's
/// sides and bottom, never its top (the top is the screen's edge): the black surface stays hard and exactly the outline,
/// and only what it reveals goes soft, so a row the unfolding edge uncovers, or the rising edge takes away, fades into
/// it instead of being cut by a line. At rest the fade lies in the island's padding (10 pt a side, 8 below) and touches
/// no content.
///
/// A mask of three fixed ramps multiplied together (nested masks), each moved by a geometry effect on the curve its side
/// moves on: the two walls on the width's, the bottom on the height's (F5's two springs), so nothing is built in a frame
/// and no path is drawn, only three translations. It masks the opened island alone (the closed pill, whose edge line lives in its
/// lowest points, keeps its hard edge), inside the outline's own clip: SwiftUI's clip, or Core Animation's mask, which
/// still cuts at the edge whatever the fade does, so nothing ever spills. With Core Animation's outline the ramps move on
/// SwiftUI's clock from the same boxes, so a stalled main thread holds the fade where the content it fades is held
/// (P242), never the black or the edge. Original draws no mask at all, so switching Motion builds the opened island
/// again (at a settings change, never in motion): its parts' old and new views both report for that update (P307).
struct IslandSoftEdge: ViewModifier {
    let ui: IslandUIState
    /// How tall the canvas is: the ramps reach that far.
    var extent: CGFloat
    /// The opened island's width, shoulders included (`IslandSize.outer`).
    var outer = IslandSize.standard.outer

    func body(content: Content) -> some View {
        let depth = ui.tuning.softEdge
        if depth > 0 {
            content.mask(alignment: .topLeading) {
                SoftEdgeMask(surface: ui.live.surface, depth: depth, extent: extent, middle: outer / 2, bud: ui.budBase)
            }
        } else {
            content
        }
    }
}

/// The soft edge's mask in the opened island's own space (its left edge at the island's, as wide as it, its middle the
/// canvas's), from `margin` outside it all round: opaque inside, fading to nothing at each wall and at the bottom edge.
struct SoftEdgeMask: View {
    let surface: SurfaceBox
    var depth: CGFloat
    var extent: CGFloat
    /// The island's middle in its own space: half its width, shoulders included.
    var middle: CGFloat = IslandSize.standard.outer / 2
    /// Motion: Liquid's bud (L2): the card in its bud sits outside the fade, which is opaque from the gap below the body
    /// down (the body's height the card rides from, `LiquidBudRide`); nil: no bud.
    var bud: CGFloat? = nil

    /// How far outside the opened island the mask reaches (the parts' drift and a row's glide stay inside it).
    static let margin: CGFloat = 24
    /// Nothing at the edge to all at `depth` inside it, eased at both ends so the fade has no line of its own.
    static func ramp(_ from: UnitPoint, _ to: UnitPoint) -> LinearGradient {
        LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0.1), location: 0.2),
                               .init(color: .black.opacity(0.5), location: 0.5), .init(color: .black.opacity(0.9), location: 0.8),
                               .init(color: .black, location: 1)], startPoint: from, endPoint: to)
    }

    /// The fade's alpha `inside` points inside an edge (the ramp's own curve, for the tests).
    static func alpha(inside: CGFloat, depth: CGFloat) -> Double {
        guard depth > 0 else { return inside >= 0 ? 1 : 0 }
        let u = Double(inside / depth)
        let stops: [(Double, Double)] = [(0, 0), (0.2, 0.1), (0.5, 0.5), (0.8, 0.9), (1, 1)]
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }
        for (a, b) in zip(stops, stops.dropFirst()) where u <= b.0 {
            return a.1 + (b.1 - a.1) * (u - a.0) / (b.0 - a.0)
        }
        return 1
    }

    var body: some View {
        let g = surface.value, m = Self.margin
        let width = 2 * middle + 2 * m, height = extent + 2 * m
        // The walls and the bottom in the mask's space (its origin `margin` above and left of the island's).
        let left = middle - g.left + g.ear + m, right = middle + g.right - g.ear + m, bottom = g.height + m
        let bottomRamp = VStack(spacing: 0) {
            Color.black.frame(height: height)
            Self.ramp(.bottom, .top).frame(height: depth)
        }
        .frame(width: width)
        .animation(surface.heightMotion.animation) { $0.modifier(ScopedOffset(y: bottom - height - depth)) }
        let leftRamp = HStack(spacing: 0) {
            Self.ramp(.leading, .trailing).frame(width: depth)
            Color.black.frame(width: width)
        }
        .frame(height: height)
        .animation(surface.widthMotion.animation) { $0.modifier(ScopedOffset(x: left)) }
        let rightRamp = HStack(spacing: 0) {
            Color.black.frame(width: width)
            Self.ramp(.trailing, .leading).frame(width: depth)
        }
        .frame(height: height)
        .animation(surface.widthMotion.animation) { $0.modifier(ScopedOffset(x: right - width - depth)) }
        // Nothing drawn is nothing shown: each ramp is transparent past its edge, and the three multiply.
        ZStack(alignment: .topLeading) {
            Self.layer(bottomRamp, width: width, height: height)
                .mask(alignment: .topLeading) {
                    Self.layer(leftRamp, width: width, height: height)
                        .mask(alignment: .topLeading) { Self.layer(rightRamp, width: width, height: height) }
                }
            if let bud {
                // The bud's card, opaque: from the gap below the body, riding the body's height as the card does.
                Color.black.frame(width: width, height: height)
                    .animation(surface.heightMotion.animation) { $0.modifier(ScopedOffset(y: g.height - bud)) }
                    .offset(y: bud + LiquidMotion.restGap + m)
            }
        }
        .offset(x: -m, y: -m)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One ramp in the mask's frame, cut to it.
    private static func layer(_ ramp: some View, width: CGFloat, height: CGFloat) -> some View {
        Color.clear.frame(width: width, height: height).overlay(alignment: .topLeading) { ramp }.clipped()
    }
}
