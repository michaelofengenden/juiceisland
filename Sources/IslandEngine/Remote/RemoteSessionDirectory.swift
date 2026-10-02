import Foundation

/// Which SSH host each remote session came in from, written by the tunnels' relays before a hook reaches the bridge or
/// the broker, so the engine finds it when the event does (P745). The host is the tunnel's own, never what the remote
/// says. Memory only: after a relaunch a session is the host's again from its next hook.
public final class RemoteSessionDirectory: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public var hostID: String
        /// What the rows say: the host's name as the owner added it, without a user ("gpu1").
        public var hostName: String
        /// What the owner typed or picked: an alias from `~/.ssh/config`, or `user@host`. The jump looks for it in the local
        /// ssh processes' arguments.
        public var destination: String
        public var context: RemoteContext

        public init(hostID: String, hostName: String, destination: String, context: RemoteContext = RemoteContext()) {
            self.hostID = hostID
            self.hostName = hostName
            self.destination = destination
            self.context = context
        }
    }

    /// A busy host's old sessions are dropped first; a hook of theirs records them again.
    static let limit = 512

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    public init() {}

    public func record(_ sessionID: String, _ entry: Entry) {
        lock.withLock {
            if entries.updateValue(entry, forKey: sessionID) == nil { order.append(sessionID) }
            if order.count > Self.limit {
                for gone in order.prefix(order.count - Self.limit) { entries[gone] = nil }
                order.removeFirst(order.count - Self.limit)
            }
        }
    }

    public func entry(for sessionID: String) -> Entry? { lock.withLock { entries[sessionID] } }

    public func sessions(onHost hostID: String) -> [String] {
        lock.withLock { order.filter { entries[$0]?.hostID == hostID } }
    }

    /// The host was removed: its sessions are no one's.
    public func forget(host hostID: String) {
        lock.withLock {
            order.removeAll { entries[$0]?.hostID == hostID }
            entries = entries.filter { $0.value.hostID != hostID }
        }
    }
}
