import Foundation
import Observation

/// The usage surfaces' hover timing (Juice `HoverController`): 350 ms of rest before the first label shows, 100 ms to
/// move from one shown label to the next, and a 100 ms grace on leaving so battery → battery never blinks.
/// Pure: `point(at:)` and `leave(_:)` say how long to wait, `settle(_:)` says whether the wait still counts.
struct HoverDwell: Equatable, Sendable {
    static let show: Duration = .milliseconds(350)
    static let move: Duration = .milliseconds(100)
    static let grace: Duration = .milliseconds(100)

    /// Where the pointer (or keyboard focus) rests now; nil once it left every target.
    private(set) var resting: HoverTargetID?
    /// The label on screen.
    private(set) var shown: HoverTargetID?

    init(shown: HoverTargetID? = nil) {
        self.shown = shown
        resting = shown
    }

    /// The pointer arrived on `target` (nil: left everything). Returns the wait before `settle(target)`, or nil when
    /// nothing will change (the same target again, or leaving while nothing is shown).
    mutating func point(at target: HoverTargetID?) -> Duration? {
        guard target != resting else { return nil }
        resting = target
        guard target != nil else { return shown == nil ? nil : Self.grace }
        if target == shown { return .zero }
        return shown == nil ? Self.show : Self.move
    }

    /// The pointer left `target`. An exit that arrives after the next target's enter is stale and ignored.
    mutating func leave(_ target: HoverTargetID) -> Duration? {
        guard target == resting else { return nil }
        return point(at: nil)
    }

    /// The wait for `target` ran out: it shows (or, for nil, the label hides) only if the pointer still rests there.
    mutating func settle(_ target: HoverTargetID?) -> Bool {
        guard target == resting, target != shown else { return false }
        shown = target
        return true
    }
}

/// One surface's hover state, driven by `HoverDwell` with real sleeps. Renders pass `shown` to freeze a label.
@MainActor
@Observable
final class UsageHoverModel {
    private(set) var shown: HoverTargetID?
    @ObservationIgnored private var dwell: HoverDwell
    @ObservationIgnored private var wait: Task<Void, Never>?

    init(shown: HoverTargetID? = nil) {
        self.shown = shown
        dwell = HoverDwell(shown: shown)
    }

    func enter(_ target: HoverTargetID) { schedule(dwell.point(at: target), for: target) }

    func leave(_ target: HoverTargetID) { schedule(dwell.leave(target), for: nil) }

    /// Clears at once (a popover opened, the surface went away).
    func reset() {
        wait?.cancel()
        dwell = HoverDwell()
        shown = nil
    }

    private func schedule(_ delay: Duration?, for target: HoverTargetID?) {
        guard let delay else { return }
        wait?.cancel()
        wait = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            if self.dwell.settle(target) { self.shown = target }
        }
    }
}
