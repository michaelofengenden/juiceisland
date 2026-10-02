import SwiftUI

/// A content group coming into focus as the surface uncovers it, and leaving the same way: one value `p` (0 hidden, 1
/// shown) drives its opacity, a soft blur and a small drift toward the notch, all linear in `p`, so the three stay in
/// step. Nothing is ever scaled. `p` moves on a critically damped spring, so the blur never goes negative. The group is
/// composited first, so a row blurs as one layer. The drift is a `ScopedOffset`, so it moves on a curve scoped to this
/// effect too (`ChannelFocus`), where the built-in offset would jump (P232).
struct FocusReveal: ViewModifier {
    var p: Double
    var blur: CGFloat
    var drift: CGFloat

    func body(content: Content) -> some View {
        content
            .compositingGroup()
            .opacity(p)
            .blur(radius: max(0, 1 - p) * blur)
            .modifier(ScopedOffset(y: -(1 - p) * drift))
    }
}

extension View {
    /// `FocusReveal` at `p`; nil (a standalone render, the window) leaves the view exactly as it is.
    @ViewBuilder func focusReveal(_ p: Double?, blur: CGFloat, drift: CGFloat = 0) -> some View {
        if let p {
            modifier(FocusReveal(p: p, blur: blur, drift: drift))
        } else {
            self
        }
    }
}

/// The live island's channels read where they are drawn: a part's focus and its glide (a row) or its ride under the
/// gliding row (the card's body), or the header group's focus, each from its own box (`IslandChannelStore`) in a small
/// modifier of its own that scopes the box's curve to its own effect (`ChannelFocus`, `ChannelOffset`), so a channel
/// that moves re-evaluates that modifier and nothing else (E5): when the island's views took the channels as a value,
/// every step of the choreography re-evaluated the whole list or card under them, about 4 ms a step (P102), and when
/// they read one struct of every channel, a write to any of them re-evaluated all of these.
struct IslandChannelReveal: ViewModifier {
    enum Motion: Equatable {
        case none
        /// The row's glide (`Channel.glide`).
        case glide(String)
        /// The card body's ride under its row (`Channel.cardRide`).
        case ride
    }

    let ui: IslandUIState
    /// nil: the header group (blur 4, no drift).
    var part: PartID?
    var motion: Motion = .none

    func body(content: Content) -> some View {
        let live = ui.live, reduce = ui.reduceMotion
        let offset: ChannelBox? = switch motion {
        case .none: nil
        case let .glide(id): live.glide(id)
        case .ride: live.cardRide
        }
        content
            .modifier(ChannelFocus(box: part.map(live.part) ?? live.header, blur: reduce ? 0 : part?.blur ?? 4,
                                   drift: reduce ? 0 : Self.drift(part, tuning: ui.tuning)))
            .modifier(ChannelOffset(box: offset))
    }

    /// How far `part` drifts toward the notch as it leaves and away from it as it comes in (nil: the header group, which
    /// does not): its own drift, or `MotionTuning.drift` for a row or block that drifts 6 pt. The same both ways, so a
    /// part's drift never changes under it while it moves.
    static func drift(_ part: PartID?, tuning: MotionTuning) -> CGFloat {
        guard let part else { return 0 }
        guard let drift = tuning.drift, part.drift == 6 else { return part.drift }
        return drift
    }
}

/// `ShoulderGate` on the live surface's width, read here from the surface's box and moved on the width's own curve, so
/// the header's views never take it as a value (under Reduce Motion the shoulders are simply out). With Core Animation's
/// outline no view reads the surface: the gate is the model's channel (`Channel.shoulders`), turned as the width crosses
/// it, read from its own box (`ShoulderAmount`), with no gate body a frame.
struct IslandShoulderGate: ViewModifier {
    let ui: IslandUIState
    var outward: CGFloat
    @Environment(\.outlineProbe) private var probe
    @Environment(\.islandSize) private var size

    func body(content: Content) -> some View {
        if ui.outline == .coreAnimation, !ui.reduceMotion {
            content.modifier(ShoulderAmount(box: ui.live.shoulders, outward: outward))
        } else {
            let surface = ui.live.surface
            let width = ui.reduceMotion ? size.outer : surface.value.width
            content.animation(surface.widthMotion.animation) {
                $0.modifier(ShoulderGate(width: width, outward: outward, gate: size.shoulderGate, probe: probe))
            }
        }
    }
}

/// The shoulder gate as an amount the model moves (Core Animation's outline), from its box on its own curve: opacity and
/// the outward drift (a `ScopedOffset`, which a scoped curve moves, P232).
struct ShoulderAmount: ViewModifier {
    let box: ChannelBox
    var outward: CGFloat

    func body(content: Content) -> some View {
        let amount = box.value
        content.animation(box.motion.animation) {
            $0.opacity(amount).modifier(ScopedOffset(x: outward * ShoulderGate.drift * (1 - amount)))
        }
    }
}

extension AnyTransition {
    /// A part inserted or removed while the island is open: it comes into focus (or leaves it) as `FocusReveal` does,
    /// on the transaction's curve; under Reduce Motion only its opacity changes.
    static func focus(blur: CGFloat = 6, drift: CGFloat = 6, reduceMotion: Bool = false) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: FocusReveal(p: 0, blur: blur, drift: drift),
                                            identity: FocusReveal(p: 1, blur: blur, drift: drift))
    }
}

/// The header's brand glyph (left) and gear (right) ride out with the island's shoulders: fed the surface's live width
/// in the same transaction as the shape, SwiftUI interpolates it with the shape's own curve, and they show as the width
/// crosses the island's gate (`IslandSize.shoulderGate`), drifting 6 pt outward into place. The only per-frame body in
/// the island, on two tiny views. Renders pass no island (fully shown).
nonisolated struct ShoulderGate: ViewModifier, Animatable {
    var width: CGFloat
    /// -1: the brand glyph (left), +1: the gear (right).
    var outward: CGFloat
    /// The span the width crosses (`IslandSize.shoulderGate`).
    var gate = IslandSize.standard.shoulderGate
    /// A test's count of the bodies run (`OutlineProbe`); nil in the app.
    var probe: OutlineProbe? = nil

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    static let drift: CGFloat = 6

    /// 0 below the gate, 1 above it, smooth between.
    static func amount(width: CGFloat, gate: ClosedRange<CGFloat> = IslandSize.standard.shoulderGate) -> Double {
        smoothstep(Double((width - gate.lowerBound) / (gate.upperBound - gate.lowerBound)))
    }

    func body(content: Content) -> some View {
        probe?.gate()
        let g = Self.amount(width: width, gate: gate)
        return content.opacity(g).offset(x: outward * Self.drift * (1 - g))
    }
}

extension View {
    /// `ShoulderGate` on the live island's surface (`IslandShoulderGate`); nil leaves the view as it is.
    @ViewBuilder func shoulderGate(_ ui: IslandUIState?, outward: CGFloat) -> some View {
        if let ui {
            modifier(IslandShoulderGate(ui: ui, outward: outward))
        } else {
            self
        }
    }
}

/// 0 at or below 0, 1 at or above 1, and a smooth S between.
nonisolated func smoothstep(_ v: Double) -> Double {
    let v = min(max(v, 0), 1)
    return v * v * (3 - 2 * v)
}
