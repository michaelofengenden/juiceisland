import SwiftUI

/// The closed pill's lead as a reminder comes (P410): it swells twice and brightens, then rests, in 0.9 s, played once
/// for each new `trigger` (`FollowUps.pulse`) and never at rest: a keyframe animation runs only while it plays, and the
/// first value the view is drawn with plays nothing. Under Reduce Motion it dims twice in place instead of moving.
/// Renders draw one moment of it (`phase`).
struct NudgePulse: ViewModifier {
    var trigger: Int
    var reduceMotion: Bool
    /// Renders: the pulse at this moment (seconds into it); nil plays it live.
    var phase: TimeInterval? = nil

    struct Values: Equatable {
        var scale: CGFloat = 1
        var glow: Double = 0
        var opacity: Double = 1
    }

    static let duration: TimeInterval = 0.9
    /// The largest the lead grows: a Liquid or Sand lead, 25 pt in its 35 pt wing over the edge line, stays on the black
    /// and clear of the line (P304's margins).
    static let peak: CGFloat = 1.15

    @KeyframesBuilder<Values>
    static func swell() -> some Keyframes<Values> {
        KeyframeTrack(\.scale) {
            CubicKeyframe(peak, duration: 0.16)
            CubicKeyframe(0.97, duration: 0.2)
            CubicKeyframe(1.08, duration: 0.18)
            CubicKeyframe(1, duration: 0.36)
        }
        KeyframeTrack(\.glow) {
            LinearKeyframe(0.35, duration: 0.16)
            LinearKeyframe(0.05, duration: 0.2)
            LinearKeyframe(0.22, duration: 0.18)
            LinearKeyframe(0, duration: 0.36)
        }
    }

    @KeyframesBuilder<Values>
    static func dim() -> some Keyframes<Values> {
        KeyframeTrack(\.opacity) {
            LinearKeyframe(0.3, duration: 0.2)
            LinearKeyframe(1, duration: 0.2)
            LinearKeyframe(0.3, duration: 0.2)
            LinearKeyframe(1, duration: 0.3)
        }
    }

    /// The pulse at `time` seconds into it.
    static func value(at time: TimeInterval, reduceMotion: Bool) -> Values {
        reduceMotion ? KeyframeTimeline(initialValue: Values()) { dim() }.value(time: time)
            : KeyframeTimeline(initialValue: Values()) { swell() }.value(time: time)
    }

    func body(content: Content) -> some View {
        if let phase {
            Self.apply(content, Self.value(at: phase, reduceMotion: reduceMotion))
        } else if reduceMotion {
            content.keyframeAnimator(initialValue: Values(), trigger: trigger) { view, values in
                Self.apply(view, values)
            } keyframes: { _ in
                Self.dim()
            }
        } else {
            content.keyframeAnimator(initialValue: Values(), trigger: trigger) { view, values in
                Self.apply(view, values)
            } keyframes: { _ in
                Self.swell()
            }
        }
    }

    nonisolated private static func apply<V: View>(_ view: V, _ values: Values) -> some View {
        view.scaleEffect(values.scale).brightness(values.glow).opacity(values.opacity)
    }
}
