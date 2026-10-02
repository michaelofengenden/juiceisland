import CoreGraphics
import Foundation

/// The island's feel as Settings › Island chooses it (Motion: Original · Refined · Liquid, Hover: Calm · Quick): every value the
/// two switches change, read through the choreography's metrics as Reduce Motion is (`IslandChoreography.Metrics`), by
/// the swell (`SurfaceTargets.swell(_:)`), by the hover machine and, for the few the views draw, through
/// `IslandUIState.tuning`. The default is the island's feel before the switches (`IslandMotion`,
/// `IslandTheme.Metrics.swellGrowth`, `IslandHoverMachine.openDelay`), so every test and render keeps its meaning. A new
/// value takes effect from the next transition. The switches are the owner's A/B: once they have picked, the other feel
/// goes, and these values go back to being constants.
struct MotionTuning: Equatable, Sendable {
    var motion = MotionFeel.original
    var hover = HoverFeel.calm

    // MARK: Motion

    /// A close lets the content leave this long before the body folds.
    var foldLag = IslandMotion.foldLag
    /// The close's fold (the no-notch top bar's: `foldWide`): the height first, the width `foldWidthAfter` later.
    var fold = IslandMotion.fold
    var foldWide = IslandMotion.foldWide
    var foldWidthAfter = IslandMotion.lead
    /// The pill's glyph and count come back once the folding shape is this close to the pill (width, height).
    var pillGate = IslandMotion.pillGate
    /// How far a row or block that drifts 6 pt drifts instead, rising toward the notch as a close takes it out and
    /// coming down from there as it comes in (nil: its own 6).
    var drift: CGFloat?
    /// The open: the header group comes into focus `headerIn` after it, the first list part `rowFloor` after the height
    /// starts, each further part as the dropping edge reaches it (and, with a cap, no later than `revealCap` after the
    /// first), all on `focusIn`.
    var headerIn = IslandMotion.headerIn
    var rowFloor = IslandMotion.rowFloor
    var revealCap: TimeInterval? = IslandMotion.cap
    var focusIn = IslandMotion.focusIn
    /// List → card: a tapped row glides to the card header's place only when it is at least this far from it.
    var glideThreshold: CGFloat = 1
    /// The card body comes into focus this long after the row and the card header cross…
    var cardBody = IslandMotion.cardBody
    /// …or, when set, this long after the tap, once the edge has passed most of it where it is drawn (riding under its
    /// gliding row), whenever the two cross.
    var cardBodyFromTap: TimeInterval?
    /// The open's width and height on two springs of their own, started together (F5, `IslandMotion.splitWidth` and
    /// `splitHeight`): no lead and no job for the height. It also makes the surface two vectors to the model and the
    /// views, as the two springs need: the width (both reaches and the ear) and the height (the height and the bottom
    /// corners), each carried by a curve set on one of its own values that changes (`IslandChoreography.set`). Off: one
    /// vector, the height `IslandMotion.lead` after the width.
    var splitsSurface = false
    /// The footer comes into focus on this (nil: `focusIn`).
    var footerFocusIn: IslandMotion.Curve?
    /// The closed pill's own changes of the same size (a new lead, a count of as many digits) play on `pillIn`: Pixel's
    /// lead pulls into focus (blur 2 → 0) in place of the 0.25 s crossfade, and the count's digits roll. Off, the
    /// snapshot is written still, so the lead swaps in one frame.
    var pillFocus = false
    /// The outline's bottom corners of continuous curvature (F9, `ContinuousCorner`), in both outlines; off, circular
    /// arcs.
    var continuousCorners = false
    /// The opened island's content fades out over this many points inside the outline's sides and bottom, never its top
    /// (F6, `IslandSoftEdge`): the black stays hard, the content's edge goes soft. 0: none, the edge cuts.
    var softEdge: CGFloat = 0
    /// The pill's glyph and count ride the wings as the outline moves (F7, `WingRide`): wider than the pill, each keeps
    /// its place against its own side, so they come in with the folding wings and go out with the unfolding ones.
    var pillRides = false
    /// Motion: Liquid. Refined's feel with the liquid outline (`LiquidPath`, `LiquidMotion`): the open's belly, the close
    /// draining into the pill, a card budding out below the list and merging back.
    var liquid = false

    // MARK: Hover

    /// Pill → swell, the pointer on it.
    var swell = IslandMotion.swell
    /// How much wider (shared by the two sides) and at most how much taller the swell is than the pill.
    var swellGrowth = IslandTheme.Metrics.swellGrowth
    /// How much rounder a swollen pill's bottom corners are, and how much wider its ears (a pill with ears: the
    /// notch's, never the no-notch bar).
    var swellRadius: CGFloat = 1
    var swellEar: CGFloat = 0
    /// The rest that opens the island.
    var openDelay = IslandHoverMachine.openDelay

    init() {}

    /// Motion and Hover as Settings › Island has them (the motion research's round A).
    /// - Refined: the close folds height and width together on the tucked fold, carries its rows 8 pt toward the notch
    ///   (they come in from as high), shows the pill's glyph early (the gate 110 × 45) and lands, 30 ms after the content
    ///   starts to leave now that the edge is soft (round C: F6's 8 pt soft edge, then F1's lag 50 → 30); the open's parts
    ///   come in as one wave behind the edge, with no cap; a card's body follows the tap by 40 ms at the earliest, once the
    ///   edge has passed it, and a row 1 pt from the card header's place crosses where it is; the pill's lead and count
    ///   change softly, and ride the wings (F7); the open's width and height start together on two springs (F5), the
    ///   footer a little quicker into focus behind them; the outline's bottom corners are of continuous curvature (F9).
    /// - Quick: a swell you can see (5 pt a side, rounder, a wider ear, on a slower spring) and a 110 ms rest, so the
    ///   open starts out of a swell still moving.
    init(motion: MotionFeel, hover: HoverFeel) {
        self.motion = motion
        self.hover = hover
        // Liquid keeps Refined's timings, content choreography, soft edge, wing ride, split springs and corners.
        if motion == .refined || motion == .liquid {
            liquid = motion == .liquid
            fold = IslandMotion.tuckedFold
            foldWide = IslandMotion.tuckedFoldWide
            foldWidthAfter = 0
            pillGate = CGSize(width: 110, height: 45)
            drift = 8
            headerIn = 0.030
            rowFloor = 0.050
            revealCap = nil
            focusIn = IslandMotion.refinedFocusIn
            glideThreshold = 4
            cardBodyFromTap = 0.040
            pillFocus = true
            splitsSurface = true
            footerFocusIn = IslandMotion.footerFocusIn
            continuousCorners = true
            softEdge = IslandMotion.softEdge
            // The soft edge lets the fold start sooner: content still leaving under the rising edge fades into it
            // instead of being cut (F1's lag, kept at 50 ms while the edge was hard).
            foldLag = IslandMotion.softFoldLag
            pillRides = true
        }
        if hover == .quick {
            swell = IslandMotion.quickSwell
            swellGrowth = CGSize(width: 10, height: 2)
            swellRadius = 1.5
            swellEar = 0.5
            openDelay = 0.11
        }
    }
}
