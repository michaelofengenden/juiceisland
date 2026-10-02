import CoreGraphics
import Foundation

/// Motion: Liquid's curves, depths and beats (the liquid morph's build spec §4). Liquid is Refined plus the liquid
/// outline (`LiquidPath`): the body keeps Refined's springs, and these move what the union adds to it. A visible motion
/// larger than 3 pt is damped 0.74 or more; below 3 pt one soft wobble (0.62 to 0.7) is allowed.
enum LiquidMotion {
    typealias Curve = IslandMotion.Curve

    // MARK: The open

    /// The belly leading the edge out of the pill, and flattening as the body arrives: out sooner and critically damped,
    /// so it never lingers under rows already in focus nor overshoots into the bottom (a clamp would stop it dead).
    static let sagIn = Curve(response: 0.20, dampingFraction: 0.90)
    static let sagOut = Curve(response: 0.26, dampingFraction: 1)
    /// Extra bottom-corner roundness in, and out (also the bud's corner to the card's).
    static let roundIn = Curve(response: 0.18, dampingFraction: 1)
    static let firm = Curve(response: 0.34, dampingFraction: 0.80)

    // MARK: The close

    /// The body narrows under the pill (width), folds (height) and lands in it.
    static let narrow = Curve(response: 0.34, dampingFraction: 1)
    static let foldHeight = Curve(response: 0.42, dampingFraction: 0.95)
    /// The land's width: quick, with a soft splash just past the pill's walls (under a point) and back, so the body
    /// holds the pill before it has risen into it. Its corners firm quicker still.
    static let land = Curve(response: 0.26, dampingFraction: 0.80)
    static let landRound = Curve(response: 0.20, dampingFraction: 1)

    // MARK: The bud and the merge

    static let bead = Curve(response: 0.24, dampingFraction: 0.90)
    static let fall = Curve(response: 0.34, dampingFraction: 0.80)
    static let budRise = Curve(response: 0.42, dampingFraction: 0.78)
    static let spread = Curve(response: 0.44, dampingFraction: 0.80)
    /// The stubs retract once the bead has pinched off (the body's quickly, the bead's with one small wobble), and grow
    /// to meet as a bead rises to join.
    static let lipBody = Curve(response: 0.14, dampingFraction: 1)
    static let lipBead = Curve(response: 0.22, dampingFraction: 0.70)
    static let contract = Curve(response: 0.28, dampingFraction: 1)
    static let reach = Curve(response: 0.20, dampingFraction: 1)
    static let rise = Curve(response: 0.34, dampingFraction: 1)
    static let gulp = Curve(response: 0.36, dampingFraction: 0.66)
    /// A close with the bud out: the card contracts at once, and rises as soon as it is a bead, quick enough to be in
    /// before the body lands.
    static let closeContract = Curve(response: 0.17, dampingFraction: 1)
    static let closeRise = Curve(response: 0.21, dampingFraction: 1)

    // MARK: The hover

    /// The swell's width under Liquid: Hover's response, one soft overshoot (Quick's 5 pt a side peaks about 0.4 pt
    /// past; the rule's floor for a single wobble).
    static let swellDamping = 0.62

    // MARK: Depths (points)

    static let openSag: CGFloat = 24
    static let gulpSag: CGFloat = 12
    static let openRound: CGFloat = 12
    static let closeRound: CGFloat = 36
    /// The close's body reach as a share of the pill's, per side.
    static let narrowShare: CGFloat = 0.5
    /// The close narrows the body once it hangs no more than this below the pill; it lands once it hangs this little.
    static let narrowReach: CGFloat = 120
    static let landHang: CGFloat = 22
    /// A close with the bud out narrows once the bead is in only while the body still hangs this far below the pill.
    static let dropRoom: CGFloat = 60
    /// An open leads with its belly only when the body has more than this share of its travel still to go.
    static let leadFloor: CGFloat = 0.15
    /// Bead radii: seeded inside the body, fallen, the merge's, the close's.
    static let beadSeed: CGFloat = 18
    static let beadRadius: CGFloat = 38
    static let mergeBead: CGFloat = 36
    static let closeBead: CGFloat = 30
    /// Bud gaps: the seed's (all in, its cap on the bottom edge, so it comes out of it from nothing), the fall's, the
    /// card's at rest, the merge's sink.
    static let seedGap: CGFloat = -36
    static let fallGap: CGFloat = 36
    static let restGap: CGFloat = 16
    static let sinkGap: CGFloat = 24
    /// The card's corner in its bud.
    static let budCorner: CGFloat = 22
    /// A join's fillet radius: at least this, at most the neck's.
    static let joinTension: ClosedRange<CGFloat> = 4...12
    /// The card in its bud: its layer this far below the bud's top, and the bud this far below its layer (the body's
    /// own bottom padding), so the card sits in its bud as the list sits in the island.
    static let budInsetTop: CGFloat = 6
    static let budInsetBottom: CGFloat = 8
    /// A card whose layer has not been measured yet: its bud this tall until it is.
    static let budGuess: CGFloat = 120
    /// A contraction aims the bud's width this far inside the bead's radius, so the card becomes a bead (its top a
    /// circle, `LiquidPath.flatTop` 0) in a finite time; aimed at the radius itself it would only ever near it.
    static let beadNarrow: CGFloat = 8
    /// The spreading bud uncovers its card's parts once it is this share of its width (and past them below).
    static let budUncovers: CGFloat = 0.45
    /// A bud whose top is flat by no more than this is a bead: it rises, and it may join.
    static let beadFlat: CGFloat = 3
    /// A second card in the bud: its height.
    static let resize = Curve(response: 0.32, dampingFraction: 1)
    /// The gulp's release: critically damped, so the belly never overshoots into the clamp at its flat bottom (a
    /// wobble there would stop dead).
    static let gulpOut = Curve(response: 0.36, dampingFraction: 1)

    // MARK: Beats (seconds from the event)

    static let sagOutAt: TimeInterval = 0.090
    static let firmAt: TimeInterval = 0.140
    /// The close: the land this long after the event (the fold starts after Refined's soft lag), unless solved from the
    /// height; and no sooner than this after the narrowing starts.
    static let landAt: TimeInterval = 0.260
    static let landAfterNarrow: TimeInterval = 0.120
    /// The bud: it starts growing this long after the present, spreads no sooner than this after it and this after the
    /// pinch.
    static let budStartAt: TimeInterval = 0.016
    static let spreadAt: TimeInterval = 0.150
    static let spreadAfterPinch: TimeInterval = 0.008
    /// The merge: the card's content stays in focus this long (readable until the card is below 70 % of its size); the
    /// rise once the card is a bead (no sooner than this); the gulp's release after the bead is in.
    static let budFadeAt: TimeInterval = 0.030
    static let riseAt: TimeInterval = 0.100
    static let gulpOutAfter: TimeInterval = 0.040
    /// An open to a card: the bud starts this long after the open, once the belly has gone.
    static let openBudAt: TimeInterval = 0.140

    /// Every curve, for the tests' table checks.
    static let all: [Curve] = [sagIn, sagOut, roundIn, firm, narrow, foldHeight, land, bead, fall, budRise, spread, lipBody, lipBead,
                               contract, reach, rise, gulp, closeContract, closeRise, landRound, resize, gulpOut]
}
