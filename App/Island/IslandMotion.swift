import Foundation
import SwiftUI

/// How the island moves: every curve is a SwiftUI spring built from one `Spring` value, so the choreography model
/// (`IslandChoreography`) and the renderer run the same maths. Only growth may overshoot (unfold, emerge, swell, bounce
/// at most 0.12). Everything that fades, blurs or glides is critically damped, so a blur is never negative, and so is
/// every shrink but Motion: Refined's tucked fold, whose bounce of 0.05 lets it land rather than creep: a shrink may dip
/// inside the pill or the notch by `undershoot` of its travel at most (the tucked fold dips 7.06 × 10⁻⁵ of it: 0.014 pt
/// from the reference island, 0.05 from a 700 pt one, 0.1 from the tallest Show all a 1,440 pt display allows, a fifth
/// of a pixel at 2×).
/// No `.delay`, `PhaseAnimator` or `KeyframeAnimator`: every later step is a job in the model, so it can be cancelled.
/// The "Wide" curves are for the no-notch top bar, whose morph to the island travels about twice as far.
enum IslandMotion {
    struct Curve: Hashable, Sendable {
        let response: Double
        let dampingFraction: Double

        /// The spring in the model's time (`slowdown` stretches the model's clock instead, so both stay in step).
        var spring: Spring { Spring(response: response, dampingRatio: dampingFraction) }
        /// The spring SwiftUI runs, in real time, so `slowdown` stretches it.
        var animation: Animation { .spring(Spring(response: response * IslandMotion.slowdown, dampingRatio: dampingFraction)) }
        /// SwiftUI's bounce: 0 for a critically damped curve.
        var bounce: Double { max(0, 1 - dampingFraction) }

        /// The spring's displacement from its target and its velocity `time` after it had `x0` and `v0`, in closed form:
        /// SwiftUI's `Spring(response:dampingRatio:)` (unit mass, stiffness (2π/response)², damping 4π·ζ/response), as
        /// `spring.value` and `spring.velocity` give it to 10⁻⁹ of the travel (`MotionEngineTests.theClosedFormIsSwiftUIsSpring`),
        /// about ten times cheaper: the model asks for thousands of these per event (a fit's scan, an edge's time, a plan).
        /// `time` in the model's clock (`spring` is too).
        func state(_ x0: Double, velocity v0: Double, time t: Double) -> (x: Double, v: Double) {
            let w = 2 * Double.pi / response, z = dampingFraction
            if abs(z - 1) < 1e-12 {
                let b = v0 + w * x0, e = exp(-w * t)
                return ((x0 + b * t) * e, (b - w * (x0 + b * t)) * e)
            }
            if z < 1 {
                let wd = w * (1 - z * z).squareRoot(), zw = z * w
                let b = (v0 + zw * x0) / wd, e = exp(-zw * t), c = cos(wd * t), s = sin(wd * t)
                let x = e * (x0 * c + b * s)
                return (x, e * ((b * wd - zw * x0) * c - (x0 * wd + zw * b) * s))
            }
            let r = w * (z * z - 1).squareRoot(), r1 = -z * w + r, r2 = -z * w - r
            let c2 = (v0 - r1 * x0) / (r2 - r1), c1 = x0 - c2
            let e1 = exp(r1 * t), e2 = exp(r2 * t)
            return (c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)
        }
    }

    /// Surface growth: pill → island, a taller card or list.
    static let unfold = Curve(response: 0.48, dampingFraction: 0.88)
    /// The top bar → island (about 430 pt of travel in place of 220).
    static let unfoldWide = Curve(response: 0.56, dampingFraction: 0.88)
    /// Surface shrink: island → pill, a shorter card or list.
    static let fold = Curve(response: 0.40, dampingFraction: 1)
    static let foldWide = Curve(response: 0.46, dampingFraction: 1)
    /// The pointer left less than `IslandHoverMachine.abortWindow` after the open: straight back, no grace.
    static let abort = Curve(response: 0.30, dampingFraction: 1)
    static let abortWide = Curve(response: 0.34, dampingFraction: 1)
    /// Idle → pill: a first session's wings slide out from behind the notch.
    static let emerge = Curve(response: 0.44, dampingFraction: 0.90)
    /// Pill → idle: the last session tucks them back.
    static let tuck = Curve(response: 0.34, dampingFraction: 1)
    /// Pill → swell, the pointer on it.
    static let swell = Curve(response: 0.30, dampingFraction: 0.88)
    /// Swell → pill (critically damped: 0.30/0.88 would undershoot the pill by 0.02 pt).
    static let unswell = Curve(response: 0.30, dampingFraction: 1)
    /// The pill's width changes: the count, the Glance dot, the glyph style, the edge line.
    static let resize = Curve(response: 0.32, dampingFraction: 1)
    /// Rows moving: a card's row rising to the header, a re-sort.
    static let glide = Curve(response: 0.32, dampingFraction: 1)
    /// Content into focus.
    static let focusIn = Curve(response: 0.28, dampingFraction: 1)
    /// Motion: Refined. The close's fold, height and width together: today's stiffness, landing on a whisper of bounce
    /// instead of creeping the last points home.
    static let tuckedFold = Curve(response: 0.40, dampingFraction: 0.95)
    static let tuckedFoldWide = Curve(response: 0.46, dampingFraction: 0.95)
    /// Motion: Refined. Content into focus a little closer behind the edge.
    static let refinedFocusIn = Curve(response: 0.26, dampingFraction: 1)
    /// Hover: Quick. The swell, still moving outward when the rest opens the island.
    static let quickSwell = Curve(response: 0.34, dampingFraction: 0.88)
    /// Motion: Refined (F5). The open's width (both reaches and the ear, which follows the shoulders) and its height (the
    /// height, the bottom corners and the edge line's lift) on two springs of their own, started together: the width a
    /// little quicker, so the lead widens as it moves instead of a fixed step, with no job to run late. The top bar's travel
    /// about twice as far, on `unfoldWide`'s stiffness scaled as these scale `unfold`'s.
    static let splitWidth = Curve(response: 0.42, dampingFraction: 0.90)
    static let splitHeight = Curve(response: 0.46, dampingFraction: 0.88)
    static let splitWidthWide = Curve(response: 0.49, dampingFraction: 0.90)
    static let splitHeightWide = Curve(response: 0.54, dampingFraction: 0.88)
    /// Motion: Refined with F5. The footer, the open's last and dimmest part, comes into focus quicker than the rows, so
    /// the open's last detail does not trail the edge.
    static let footerFocusIn = Curve(response: 0.22, dampingFraction: 1)
    /// Content out.
    static let focusOut = Curve(response: 0.16, dampingFraction: 1)
    /// The pill's glyph and count back after a close.
    static let pillIn = Curve(response: 0.26, dampingFraction: 1)
    /// The pill's glyph and count out from behind the notch.
    static let slide = Curve(response: 0.34, dampingFraction: 1)
    /// Every opacity change under Reduce Motion.
    static let reduced = Curve(response: 0.20, dampingFraction: 1)

    /// Every curve, for the tests' table checks.
    static let all: [Curve] = [unfold, unfoldWide, fold, foldWide, abort, abortWide, emerge, tuck, swell, unswell, resize, glide,
                               focusIn, focusOut, pillIn, slide, reduced, tuckedFold, tuckedFoldWide, refinedFocusIn, quickSwell,
                               splitWidth, splitHeight, splitWidthWide, splitHeightWide, footerFocusIn]
    /// The curves a surface grows on (the only ones that may overshoot) and the ones it shrinks on (critically damped, or
    /// the tucked fold's `undershoot`).
    static let growths: [Curve] = [unfold, unfoldWide, emerge, swell, quickSwell, splitWidth, splitHeight, splitWidthWide, splitHeightWide]
    static let shrinks: [Curve] = [fold, foldWide, abort, abortWide, tuck, unswell, tuckedFold, tuckedFoldWide]
    /// The most a shrink may dip inside its target, as a share of its travel (a spring undershoots a fixed share of it:
    /// the tucked fold's e^(−0.95π/√(1 − 0.95²)) is 7.06 × 10⁻⁵), so no number of points bounds it.
    static let undershoot = 7.1e-5

    /// Debug builds only: `defaults write <bundle id> IslandMotionSlowdown 4` plays everything at a quarter of the speed,
    /// for review. Always 1 in a release build.
    static let slowdown: Double = {
        #if DEBUG
        let value = UserDefaults.standard.double(forKey: "IslandMotionSlowdown")
        return value >= 1 ? min(value, 10) : 1
        #else
        return 1
        #endif
    }()

    /// A whisper of extra ear while the shoulders move fast (spec §5.11): 0 until the owner has seen it.
    static let meniscus: CGFloat = 0

    // MARK: Timings (seconds from each trigger)

    /// Growth sets the width this long before the height; a shrink sets the height first.
    static let lead: TimeInterval = 0.030
    /// A close lets the content leave this long before the body folds.
    static let foldLag: TimeInterval = 0.050
    /// Motion: Refined. The same with the soft edge (F6 then F1): the content still leaving fades into the rising edge.
    static let softFoldLag: TimeInterval = 0.030
    /// Motion: Refined. How far inside the outline's sides and bottom the opened island's content fades out (F6): the
    /// island's side padding is 10 pt and its bottom padding 8, so at rest the fade touches no content.
    static let softEdge: CGFloat = 8
    /// The header group comes into focus.
    static let headerIn: TimeInterval = 0.040
    /// The first list part (row 1, or the usage block) comes into focus.
    static let rowFloor: TimeInterval = 0.060
    /// Parts flip at least this far apart…
    static let minStep: TimeInterval = 0.020
    /// …and no later than this after the first.
    static let cap: TimeInterval = 0.100
    /// A part flips when the dropping edge is this far into it.
    static let edgeDepth: CGFloat = 0.25
    /// A first session: the glyph and count slide out this long after the wings start.
    static let arriveContent: TimeInterval = 0.080
    /// The last session: the wings tuck this long after the glyph and count start to leave.
    static let departLag: TimeInterval = 0.080
    /// The card: the row and the card header cross-focus when the row's glide is this far along…
    static let glideCross: Double = 0.60
    /// …or this long after the tap when the row does not glide.
    static let crossWithoutGlide: TimeInterval = 0.040
    /// The card body follows the cross-focus.
    static let cardBody: TimeInterval = 0.030
    /// Card → list: the list parts under the row's home come in…
    static let listBelow: TimeInterval = 0.060
    /// …the row glides home…
    static let glideBack: TimeInterval = 0.050
    /// …and parts its path crosses wait until it overlaps them by less than this, and no longer than `aboveCap`.
    static let aboveOverlap: CGFloat = 12
    static let aboveCap: TimeInterval = 0.200
    /// A shorter list or card folds this long after its parts start to leave.
    static let shrinkLag: TimeInterval = 0.060
    /// How long after a list change is written its content still counts as that change's (E6): the measurement comes
    /// back a turn later.
    static let listWindow: TimeInterval = 0.100
    /// A part leaving with a list change (the footer, the usage block) is taken away once its focus is down to this:
    /// SwiftUI draws a view it takes away at about half its brightness for the first frame of its removal (P309), which
    /// must be out of sight.
    static let swapFocus: Double = 0.1
    /// A part whose focus is above this shows: it turns back from where it is (a row lifts, a reopen re-aims it).
    static let shown: Double = 0.05
    /// A part that has left (`focusOut`) is gone this long after it started: its glide resets, and its layer can go (once
    /// the island has settled instead, while anything still moves, E4).
    static let goneAfter: TimeInterval = 0.300
    /// Reduce Motion: the outline snaps once the content has faded (below 1 % on `reduced`, so nothing shows where the
    /// edge jumps), and the new content comes in after.
    static let reducedSwap: TimeInterval = 0.215
    static let reducedOpenSnap: TimeInterval = 0.100
    static let reducedIn: TimeInterval = 0.120
    /// The pill's glyph returns once the folding shape is this close to the pill (width, height).
    static let pillGate = CGSize(width: 77, height: 27)
    /// A shape fits a frame when it is inside it by this much.
    static let fitTolerance: CGFloat = 0.5
    /// The panel shrinks one frame after the model says the shape fits, so a frame drawn late is never cut.
    static let frameAhead: TimeInterval = 1.0 / 60
    /// The model looks this far ahead for a fit, a gate or an edge.
    static let horizon: TimeInterval = 1.5
    /// Core Animation's outline: the shoulders' gate takes this long when the width's far crossing is not in sight.
    static let shouldersSpan: TimeInterval = 0.074
    /// A card that just came in takes no click and no card key this long, while it comes into focus (P138).
    static let cardSettle: TimeInterval = 0.250
    /// A card has come in and the island rests on it this long after it was presented (the widest unfold included):
    /// the next card that waits is built beside it from then on (P133).
    static let cardRest: TimeInterval = 0.800
}

extension IslandMotion {
    /// How long after the strip's unfold is written the usage block starts to come in: once the rows it pushes down
    /// have cleared all but the edge's depth of it, on `curve` (`IslandChoreography.swap`, `.strip(true)`).
    static func stripBlockArrival(curve: Curve) -> TimeInterval {
        let rows = ShadowValue(from: 0, velocity: 0, target: 1, start: 0, curve: curve)
        return firstTime { rows.value(at: $0) >= Double(1 - edgeDepth) }
    }

    /// How long the header's pairs stay when the strip unfolds before they leave on `focusOut`: half gone as the block
    /// starts to come in, so usage never leaves the island while the rows slide down, and never shows twice at full.
    static let stripPairHold: TimeInterval = {
        let pair = ShadowValue(from: 1, velocity: 0, target: 0, start: 0, curve: focusOut)
        return max(0, stripBlockArrival(curve: unfold) - firstTime { pair.value(at: $0) <= 0.5 })
    }()

    /// The first moment, in 1 ms steps up to `horizon`, at which `condition` holds; `horizon` if none.
    static func firstTime(_ condition: (TimeInterval) -> Bool) -> TimeInterval {
        var s: TimeInterval = 0
        while s <= horizon {
            if condition(s) { return s }
            s += 0.001
        }
        return horizon
    }
}
