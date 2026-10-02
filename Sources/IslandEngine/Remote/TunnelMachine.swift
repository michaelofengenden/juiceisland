import Foundation

/// Why a tunnel is down, from ssh's exit and its last error lines (`SSHCommands.failure`).
public enum TunnelFailure: Equatable, Sendable {
    /// The host asks for a password or a code, or refuses the keys: BatchMode never answers a prompt (P746).
    case needsKeyLogin
    /// The host's key is not in `known_hosts`, or changed: the owner connects once in Terminal.
    case hostKey
    /// The remote helper or its Python is gone: Set up again.
    case notSetUp
    /// The remote shell printed too much before the helper, or the helper spoke nonsense.
    case protocolError
    /// No route, no answer, a dropped connection: worth another try.
    case unreachable

    /// Only a network failure is tried again by itself, and on a network change; the others wait for a click or a wake
    /// (a host's login rules may count every failed try).
    public var retries: Bool { self == .unreachable }
}

/// One host's tunnel as a pure state machine (P747): what it is doing, and what to do next. The tunnel runtime
/// (`RemoteTunnels`) feeds it events and carries out its effects, so tests run it on a fake clock.
///
/// Backoff after a failure that may pass by itself: 2 s, 5 s, 15 s, 30 s, 1 min, 2 min, then 5 min four times (about
/// 25 minutes in all), then Offline until a click, a wake or a network change. Nothing is scheduled while connected or
/// offline: nothing ticks at rest. A wake or a network change also starts a connected tunnel over: a connection from
/// before either may be dead with nothing to say so.
public struct TunnelMachine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case connecting
        /// Up; the remote helper's version.
        case connected(helper: Int)
        /// Down, trying again at the date.
        case retrying(at: Date, after: TunnelFailure)
        /// Down until the owner or the system says otherwise.
        case offline(TunnelFailure)
    }

    public enum Event: Equatable, Sendable {
        case start
        case ready(helper: Int)
        case exited(TunnelFailure)
        /// A scheduled retry fell due (the date it was scheduled for).
        case retryDue(Date)
        /// The Mac woke: every host starts over at once, one waiting on the owner (a key login, a host key) included.
        case wake
        /// The network came back or its main interface changed: as a wake, but a host waiting on the owner stays so.
        case networkChanged
        case stop
    }

    public enum Effect: Equatable, Sendable {
        case launch
        case terminate
        case schedule(Date)
    }

    public static let delays: [TimeInterval] = [2, 5, 15, 30, 60, 120, 300, 300, 300, 300]

    public private(set) var state: State = .stopped
    /// Failures in a row since the last time the tunnel was up.
    public private(set) var failures = 0

    public init() {}

    public mutating func handle(_ event: Event, now: Date) -> [Effect] {
        switch (event, state) {
        case (.start, .stopped), (.start, .offline), (.start, .retrying):
            failures = 0
            state = .connecting
            return [.launch]
        case (.start, _):
            return []
        case let (.ready(helper), .connecting):
            failures = 0
            state = .connected(helper: helper)
            return []
        case (.ready, _):
            return []
        case let (.exited(failure), .connecting), let (.exited(failure), .connected):
            guard failure.retries else {
                failures = 0
                state = .offline(failure)
                return []
            }
            failures += 1
            guard failures <= Self.delays.count else {
                failures = 0
                state = .offline(failure)
                return []
            }
            let due = now.addingTimeInterval(Self.delays[failures - 1])
            state = .retrying(at: due, after: failure)
            return [.schedule(due)]
        case (.exited, _):
            return []
        case let (.retryDue(date), .retrying(at, _)) where date == at:
            state = .connecting
            return [.launch]
        case (.retryDue, _):
            return []
        case (.wake, .retrying), (.wake, .offline), (.wake, .connected),
             (.networkChanged, .retrying), (.networkChanged, .connected), (.networkChanged, .offline(.unreachable)):
            failures = 0
            state = .connecting
            return [.launch]
        case (.wake, _), (.networkChanged, _):
            return []
        case (.stop, .connecting), (.stop, .connected):
            state = .stopped
            failures = 0
            return [.terminate]
        case (.stop, _):
            state = .stopped
            failures = 0
            return []
        }
    }
}
