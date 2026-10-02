import AppKit
import Foundation

/// A timer on the main queue that fires at its deadline: a `DispatchSourceTimer` with the `.strict` flag and no leeway.
/// `Task.sleep` and a plain main-queue timer are given a leeway of about 4 to 5 ms even on a quiet thread (the motion
/// research: a command-line probe's p50 was 4.2 ms late, a strict source's 0.1 ms), which stretched the choreography's
/// staged steps, the hover's rest and the pointer poll (60 a second that ran near 47). It still waits for whatever turn
/// the main thread is in. It stops when cancelled or released.
final class StrictTimer: IslandTimerToken, @unchecked Sendable {
    /// No coalescing with other timers, and no leeway (the tests pin both).
    static var flags: DispatchSource.TimerFlags { .strict }
    static var leeway: DispatchTimeInterval { .nanoseconds(0) }

    private let source: DispatchSourceTimer

    /// Fires once at `deadline` (the uptime clock `ProcessInfo.systemUptime` reads), then every `interval` if given.
    init(at deadline: DispatchTime, every interval: TimeInterval? = nil, _ fire: @escaping @MainActor @Sendable () -> Void) {
        source = DispatchSource.makeTimerSource(flags: Self.flags, queue: .main)
        let repeating: DispatchTimeInterval = interval.map { .nanoseconds(Int(($0 * 1e9).rounded())) } ?? .never
        source.schedule(deadline: deadline, repeating: repeating, leeway: Self.leeway)
        source.setEventHandler { MainActor.assumeIsolated { fire() } }
        source.resume()
    }

    /// Fires `seconds` from now (real time), then every `interval` if given.
    convenience init(after seconds: TimeInterval, every interval: TimeInterval? = nil, _ fire: @escaping @MainActor @Sendable () -> Void) {
        self.init(at: .now() + max(0, seconds), every: interval, fire)
    }

    /// Real time `seconds` of uptime as a dispatch deadline.
    static func deadline(uptime seconds: TimeInterval) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: UInt64(max(0, seconds) * 1e9))
    }

    func cancel() { source.cancel() }

    deinit { source.cancel() }
}

/// A timer that can be called off.
protocol IslandTimerToken: AnyObject {
    func cancel()
}

/// The choreography's clock: the model's time, and a timer for its next job. The app's (`StrictJobClock`) is real time
/// on a strict timer; tests drive a fake one to check that each job is asked for at its own time and runs at it.
@MainActor
protocol IslandJobClock: AnyObject {
    /// The model's time now (`IslandMotionDirector.now`: real time, slowed by `IslandMotion.slowdown` in a debug build).
    var now: TimeInterval { get }
    /// Calls `fire` once, at model time `due`.
    func schedule(at due: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> any IslandTimerToken
}

/// The app's job clock: a strict main-queue timer set for the job's own moment on the uptime clock.
@MainActor
final class StrictJobClock: IslandJobClock {
    var now: TimeInterval { IslandMotionDirector.now }

    func schedule(at due: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> any IslandTimerToken {
        StrictTimer(at: StrictTimer.deadline(uptime: due * IslandMotion.slowdown), fire)
    }
}

/// One pointer sample as the island reads it: a tracking-area move at the place and time it happened, so samples that a
/// busy main thread handles in a bunch keep their real spacing and read at their real speed (a sample timed when it was
/// handled read a slow move as fast, which suppressed the swell or restarted the rest); the poll at its own place and
/// time.
struct PointerSample: Equatable, Sendable {
    var location: CGPoint
    var time: TimeInterval

    /// A move: its own place on the screen as the window server saw it, never its place in the window (worked out
    /// against the panel's frame when the move was routed, so a snap of the panel before it is handled, the swell's,
    /// the open's or the fit's, would put it off by the snap), and its timestamp (uptime seconds, the clock
    /// `ProcessInfo.systemUptime` reads). An entry or an exit, which AppKit makes up from the tracking area with a
    /// place worked out against the frame as it is when read, is the pointer `now`.
    @MainActor init(event: NSEvent, now: @MainActor () -> PointerSample = PointerSample.now) {
        guard event.type != .mouseEntered, event.type != .mouseExited, let routed = event.cgEvent else {
            self = now()
            return
        }
        location = routed.unflippedLocation
        time = event.timestamp
    }

    init(location: CGPoint, time: TimeInterval) {
        self.location = location
        self.time = time
    }

    /// The pointer now, for the poll.
    @MainActor static func now() -> PointerSample {
        PointerSample(location: NSEvent.mouseLocation, time: ProcessInfo.processInfo.systemUptime)
    }
}
