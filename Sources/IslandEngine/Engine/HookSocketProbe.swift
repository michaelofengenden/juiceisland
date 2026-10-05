import Darwin
import Foundation
import OpenIslandCore

/// Whether another process listens on a hook socket path. `BridgeServer` deletes whatever file is at its paths
/// before it binds (BridgeServer.swift:104-127 at 1.2.1), so starting it while another island app listens there
/// would silently take that app's hook events. The engine probes every path its bridge will bind and refuses while
/// any has a live owner; a stale or missing file is fine, because upstream replaces it.
public enum HookSocketProbe {
    public enum Result: Equatable, Sendable {
        /// No file at the path.
        case free
        /// A socket file nobody listens on (ECONNREFUSED twice, 0.2 s apart): left over from an app that quit.
        case stale
        /// connect(2) succeeded: a live owner. The probe closes its end at once.
        case live
        /// Anything else, a timeout included. Treated as an owner: when in doubt, the bridge does not start.
        case unknown(errno: Int32)

        public var hasOwner: Bool {
            switch self {
            case .free, .stale: false
            case .live, .unknown: true
            }
        }
    }

    /// The paths a `BridgeServer` on `socketURL` binds: that socket and the legacy `/tmp` one, which every
    /// `BridgeServer` also binds. Open Island's own socket is one of them only when the bridge is on it; the app's own
    /// home socket leaves it to Open Island and to the relay (P900, P911).
    public static func paths(for socketURL: URL) -> [URL] {
        var seen: Set<String> = []
        return [socketURL, BridgeSocketLocation.legacyURL].filter { seen.insert($0.path).inserted }
    }

    /// Probes once, and once more after `recheckAfter` when the answer is ECONNREFUSED: on macOS a live listener
    /// whose backlog is full refuses too, so a path counts as stale only when both probes are refused. A listener
    /// that stays full that long (a hung owner) still reads as stale; Open Island itself is refused earlier, by the
    /// bundle-id guard.
    public static func probe(_ url: URL, timeout: TimeInterval = 0.25, recheckAfter: TimeInterval = 0.2,
                             once: (URL, TimeInterval) -> Result = HookSocketProbe.probeOnce) -> Result {
        let first = once(url, timeout)
        guard first == .stale else { return first }
        Thread.sleep(forTimeInterval: recheckAfter)
        return once(url, timeout)
    }

    /// One non-blocking connect(2), closed at once.
    public static func probeOnce(_ url: URL, timeout: TimeInterval) -> Result {
        let path = Array(url.path.utf8)
        var address = sockaddr_un()
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return .unknown(errno: ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unknown(errno: errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path)
            buffer[path.count] = 0
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 { return .live }
        var code = errno
        if code == EINPROGRESS || code == EAGAIN {
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&poller, 1, Int32(timeout * 1_000)) > 0 else { return .unknown(errno: ETIMEDOUT) }
            var length = socklen_t(MemoryLayout<Int32>.size)
            code = 0
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length)
            if code == 0 { return .live }
        }
        switch code {
        case ENOENT: return .free
        case ECONNREFUSED: return .stale
        default: return .unknown(errno: code)
        }
    }
}
