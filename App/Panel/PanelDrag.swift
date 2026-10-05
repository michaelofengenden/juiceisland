import CoreGraphics

/// The unlocked desktop panel's own drag, as a desktop widget's (P1200 to P1203). Unlocked used to mean only
/// `isMovableByWindowBackground`, which leaves the move to AppKit's and the window server's background drag; for this
/// window (non-activating, never key, stationary, at the desktop's level, all of it a SwiftUI hosting view with hover
/// targets and right-click menus) that drag never started, though the hosting view says a press may move the window at
/// every point. So the window drags itself, the way AppKit's header describes for a window that does its own dragging
/// (`NSWindow.isMovable`): its `sendEvent` holds a press on the panel, and once the pointer has moved more than
/// `threshold` the press is a drag that moves the window with the pointer; a press that never moves that far is handed
/// to the content as the click it was, at its release.
///
/// Positions are the pointer's in screen points, so a step never depends on where the window was when the event was made.
/// It holds no clock and starts nothing: the window feeds it the press, each step and the release.
struct PanelDrag<Press> {
    enum Phase {
        case idle
        /// The button is down on the panel and the pointer has not yet gone past the threshold: the press is held.
        case pressed(Press, at: CGPoint, origin: CGPoint)
        /// A drag: the window's origin follows the pointer from where the press began.
        case moving(at: CGPoint, origin: CGPoint)
    }

    /// What a release leaves to do.
    enum Release {
        /// The press never moved: give the content the press, then the release, as one click.
        case click(Press)
        /// The panel was dragged: the content never saw the press, and the move is the owner's.
        case drop
        /// Nothing was held (the press began elsewhere, or locked).
        case none
    }

    private(set) var phase = Phase.idle

    var isHolding: Bool { if case .idle = phase { false } else { true } }
    var isMoving: Bool { if case .moving = phase { true } else { false } }

    /// The button went down at `point` with the window's origin at `origin`. A press still held (its release never came)
    /// is dropped.
    mutating func press(_ press: Press, at point: CGPoint, origin: CGPoint) {
        phase = .pressed(press, at: point, origin: origin)
    }

    /// The pointer moved to `point` with the button down: the window's new origin once this is a drag, nil while the
    /// press is still within the threshold or nothing is held.
    mutating func drag(to point: CGPoint) -> CGPoint? {
        switch phase {
        case .idle:
            return nil
        case let .pressed(_, start, origin):
            guard hypot(point.x - start.x, point.y - start.y) > PanelDragRule.threshold else { return nil }
            phase = .moving(at: start, origin: origin)
            return PanelDragRule.origin(origin, from: start, to: point)
        case let .moving(start, origin):
            return PanelDragRule.origin(origin, from: start, to: point)
        }
    }

    /// The button came up.
    mutating func release() -> Release {
        defer { phase = .idle }
        switch phase {
        case .idle: return .none
        case let .pressed(press, _, _): return .click(press)
        case .moving: return .drop
        }
    }

    /// Lock position came on while a press was held: forget it. A drag already under way stays where it is.
    mutating func cancel() { phase = .idle }
}

/// `PanelDrag`'s numbers.
enum PanelDragRule {
    /// How far the pointer moves, in points, before a press is a drag: more than a hand's tremor on a click (AppKit
    /// starts its own drags at about 3), little enough that the panel answers at once.
    static let threshold: CGFloat = 4

    /// The window's origin with the pointer gone from `start` to `point`: the point the owner grabbed stays under the
    /// pointer, the few points before the threshold included.
    static func origin(_ origin: CGPoint, from start: CGPoint, to point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y)
    }
}
