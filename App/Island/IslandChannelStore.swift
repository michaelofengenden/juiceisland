import Observation
import SwiftUI

/// How a channel last moved: on one of the island's springs, or snapped. A snap is a true snap, `.linear(duration: 0)`:
/// the next frame is exactly the new value, and a spring still in flight on the channel ends there. A write with no
/// animation at all (a transaction that disables animations) would not end it: the value's target jumps and the spring's
/// displacement keeps playing out on top of it, so the views and the model (`ShadowValue.retarget(nil)`, a hard snap)
/// disagree for as long as it rings (the motion research's proto-swiftui §4.4, P230).
enum ChannelMotion: Equatable, Sendable {
    case snap
    case spring(IslandMotion.Curve)

    init(_ curve: IslandMotion.Curve?) {
        self = curve.map(ChannelMotion.spring) ?? .snap
    }

    /// What the channel's effect animates on, scoped where it is drawn (`.animation(_:body:)`).
    var animation: Animation {
        switch self {
        case .snap: .linear(duration: 0)
        case let .spring(curve): curve.animation
        }
    }
}

/// One content channel as the views read it (E5): its value and the curve it moves on, in a box of its own, so a write
/// re-evaluates only the small modifier that draws that channel (`ChannelFocus`, `ChannelOffset`, the pill's), which
/// scopes the curve to its own effect. Written only by `IslandUIState.apply`, from the director's one plain transaction
/// per batch.
@MainActor
@Observable
final class ChannelBox {
    private(set) var value: Double
    private(set) var motion = ChannelMotion.snap

    init(_ value: Double) {
        self.value = value
    }

    /// `value` on `motion`; one that changes nothing is not written, so nothing redraws (a spring on its way there keeps
    /// its own curve, as SwiftUI keeps an animation whose value did not change).
    func write(_ value: Double, _ motion: ChannelMotion) {
        guard value != self.value else { return }
        if self.motion != motion { self.motion = motion }
        self.value = value
    }
}

/// The one black surface, in one box: SwiftUI's outline draws it as two animatable vectors (`SurfaceClip`), the width
/// (both reaches and the ear, which follows the shoulders) and the height (the height and the bottom corners), each on
/// the curve that last changed one of its own values (`Channel.surfaceWidth`, `surfaceHeight`): Motion: Refined's open
/// moves them on two springs started together (F5), and with one curve for both they move as the one vector did. A
/// write that leaves a vector where it is keeps that vector's curve, as SwiftUI keeps an animation whose value did not
/// change. With Core Animation's outline it is written all the same and no view reads it.
@MainActor
@Observable
final class SurfaceBox {
    private(set) var value = SurfaceGeometry.zero
    /// The curve the width last moved on.
    private(set) var widthMotion = ChannelMotion.snap
    /// The curve the height last moved on.
    private(set) var heightMotion = ChannelMotion.snap

    func write(_ value: SurfaceGeometry, _ motion: ChannelMotion) {
        guard value != self.value else { return }
        let old = self.value
        if value.left != old.left || value.right != old.right || value.ear != old.ear, widthMotion != motion {
            widthMotion = motion
        }
        if value.height != old.height || value.radius != old.radius || value.meniscus != old.meniscus, heightMotion != motion {
            heightMotion = motion
        }
        self.value = value
    }
}

/// Every channel the island's views draw, a box each (E5): the surface, the header group's focus, the pill's focus and
/// arrival, the edge line's lift, the card body's ride, each part's focus and each row's glide. Neither the root nor the
/// closed pill reads one in its body: the modifiers that draw them do. A part's or a glide's box is made the first time
/// it is read or written and kept (a view may hold it: a box dropped under a view that still observes it would take
/// that view's next write elsewhere), two small boxes per session the island has shown; `channels` lists only what is
/// not 0, as the views' maps did.
@MainActor
final class IslandChannelStore {
    let surface = SurfaceBox()
    let header = ChannelBox(0)
    let pill = ChannelBox(1)
    let pillArrive = ChannelBox(1)
    let rimLift = ChannelBox(0)
    let cardRide = ChannelBox(0)
    /// Core Animation's outline: the header's brand glyph and gear (`Channel.shoulders`, `ShoulderAmount`).
    let shoulders = ChannelBox(0)
    private var parts: [PartID: ChannelBox] = [:]
    private var glides: [String: ChannelBox] = [:]

    func part(_ id: PartID) -> ChannelBox {
        if let box = parts[id] { return box }
        let box = ChannelBox(0)
        parts[id] = box
        return box
    }

    func glide(_ id: String) -> ChannelBox {
        if let box = glides[id] { return box }
        let box = ChannelBox(0)
        glides[id] = box
        return box
    }

    /// `values` on `motion`, in the current transaction: the surface's five as one write.
    func write(_ values: [Channel: Double], _ motion: ChannelMotion) {
        var geometry = surface.value
        for (channel, value) in values {
            let v = CGFloat(value)
            switch channel {
            case .left: geometry.left = v
            case .right: geometry.right = v
            case .height: geometry.height = v
            case .ear: geometry.ear = v
            case .radius: geometry.radius = v
            case .rimLift: rimLift.write(value, motion)
            case .pill: pill.write(value, motion)
            case .pillArrive: pillArrive.write(value, motion)
            case .header: header.write(value, motion)
            case let .part(id): part(id).write(value, motion)
            case let .glide(id): glide(id).write(value, motion)
            case .cardRide: cardRide.write(value, motion)
            case .shoulders: shoulders.write(value, motion)
            // Motion: Liquid's values are the outline's, played from the model's plan (`LiquidBox`), never a box's.
            case .liquid: break
            }
        }
        surface.write(geometry, motion)
    }

    /// What the views hold now (tests, and `IslandMotionDirector.snap`'s clearing of what a fresh model does not know).
    var channels: IslandChannels {
        IslandChannels(pill: pill.value, pillArrive: pillArrive.value, header: header.value, rimLift: CGFloat(rimLift.value),
                       cardRide: CGFloat(cardRide.value), shoulders: shoulders.value,
                       parts: parts.compactMapValues { $0.value == 0 ? nil : $0.value },
                       glides: glides.compactMapValues { $0.value == 0 ? nil : CGFloat($0.value) })
    }
}

/// A content group's focus from its box (`FocusReveal`), on the curve the box moves on and nothing else's.
struct ChannelFocus: ViewModifier {
    let box: ChannelBox
    var blur: CGFloat
    var drift: CGFloat

    func body(content: Content) -> some View {
        let p = box.value
        content.animation(box.motion.animation) { $0.modifier(FocusReveal(p: p, blur: blur, drift: drift)) }
    }
}

/// A render offset from its box: a row's glide, the card body's ride under its row, the edge line's lift (`y`); the
/// pill's glyph and count sliding out from behind the notch (`x`, `scale × (1 − value)`). nil: none.
struct ChannelOffset: ViewModifier {
    let box: ChannelBox?
    var axis = Axis.vertical
    var sign: CGFloat = 1
    /// The offset is `scale × (1 − value)` (the pill's arrival slide), not the value.
    var inverse: CGFloat?

    func body(content: Content) -> some View {
        let v = CGFloat(box?.value ?? 0)
        let d = sign * (inverse.map { $0 * (1 - v) } ?? v)
        content.animation(box?.motion.animation) { $0.modifier(ScopedOffset(x: axis == .horizontal ? d : 0, y: axis == .vertical ? d : 0)) }
    }
}

/// A render offset SwiftUI moves as this effect's own value, so a curve scoped to it with `.animation(_:body:)` moves
/// it: the built-in `offset` in such a scope does not animate at all (it jumps to its new place in one frame; measured
/// headless on macOS 26, where opacity, blur, a clip's shape and an `Animatable` modifier all animate, P232). A geometry
/// effect: each frame SwiftUI asks it for its translation and runs no body (round B's `Animatable` modifier ran one a
/// frame for every glide, ride, slide and drift in motion, round C, P301). A translation, as `offset` is, so a still
/// frame draws exactly as `offset` does.
nonisolated struct ScopedOffset: GeometryEffect {
    var x: CGFloat = 0
    var y: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(x, y) }
        set { (x, y) = (newValue.first, newValue.second) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: x, y: y))
    }
}

/// The island's black canvas clipped by the surface (SwiftUI's outline), read from the surface's box here so the root
/// reads no channel (E5): the width on the curve it last moved on, the height on its own (`SurfaceClip`, F5). With Core
/// Animation's outline (`clips` false) it reads nothing of the box and clips nothing: the render server masks the canvas
/// with the model's plan. The same modifiers either way, so switching the outline keeps every view below it.
struct IslandSurfaceClip: ViewModifier {
    let surface: SurfaceBox
    var clips = true
    /// Continuous bottom corners (Motion: Refined, F9).
    var continuous = false
    var probe: OutlineProbe?
    /// Motion: Liquid: the plan it plays or its still values (`LiquidBox`), reaching the clip's own shape as a value each
    /// frame (`LiquidClock`).
    var liquid: LiquidBox? = nil

    func body(content: Content) -> some View {
        let geometry = clips ? surface.value : .zero
        let width = clips ? surface.widthMotion.animation : nil, height = clips ? surface.heightMotion.animation : nil
        let box = clips ? liquid : nil
        content.animation(box?.clock) {
            $0.modifier(LiquidClock(pulse: Double(box?.pulse ?? 0), frame: box?.frame,
                                    clip: SurfaceClip(geometry: geometry, clips: clips, continuous: continuous, height: height, probe: probe),
                                    width: width))
        }
    }
}

extension View {
    /// Strings no transaction animates (E5, apple T10): a part's content in the live island, so a session update that
    /// lands in an animated transaction (the rows' re-sort, Show all, the strip) swaps a title, a status or an age at
    /// once, never crossfading two strings. Only the strings: `.transaction { $0.animation = nil }` here would stop the
    /// part's own place from animating too, since SwiftUI moves each leaf with the transaction it sees (measured: a row
    /// re-sorted on the list's glide jumped to its new place), so a line would part from its row mid-glide (P233).
    func stillText() -> some View {
        contentTransition(.identity)
    }
}
