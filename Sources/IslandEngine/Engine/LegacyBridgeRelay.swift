import Darwin
import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore

/// Keeps the hooks installed before Juice had its own helper working (P911). Those hooks still run Open Island's
/// helper path, whose upstream half dials Open Island's socket (`OpenIsland/bridge.sock`), and Juice's OpenCode plugin
/// of revision 1 dials it too. While nobody else holds that socket (Open Island is not running) the engine listens
/// there and passes each connection, byte for byte both ways, to its own bridge, so those hooks reach the app exactly
/// as before. It is a relay and nothing more: no bridge state of its own, no reading of what passes.
///
/// It never takes the path from a live owner: the engine probes it first, and stops relaying when another app binds it
/// (Open Island launched: its hooks are its own again). It unlinks only its own socket file, when it stops.
final class LegacyBridgeRelay: @unchecked Sendable {
    let path: URL
    let target: URL
    private let listener: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "juice-island.legacy-relay")
    /// The socket file as bound, so `stop` unlinks only its own.
    let identity: SocketIdentity?
    private let lock = NSLock()
    private var stopped = false
    private(set) var relayed = 0

    /// Binds `path` (a stale file there is replaced, as upstream's bridge replaces its own) and starts relaying.
    init(path: URL, target: URL) throws {
        self.path = path
        self.target = target
        guard var address = HookNoteSocket.address(for: path) else { throw BridgeTransportError.socketPathTooLong }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeTransportError.systemCallFailed("socket", errno) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw BridgeTransportError.systemCallFailed("bind", code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd
        identity = SocketIdentity.of(path)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { stop() }

    /// Stops taking connections; the ones in flight run to their end. The socket file goes only while it is still ours.
    func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        source.cancel()
        if let identity, SocketIdentity.of(path) == identity { unlink(path.path) }
    }

    private func acceptAll() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            guard let upstream = connectTarget() else {
                close(client)
                continue
            }
            lock.withLock { relayed += 1 }
            for fd in [client, upstream] {
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            }
            let pair = Pair(client: client, upstream: upstream)
            Self.pump(from: client, to: upstream, pair: pair)
            Self.pump(from: upstream, to: client, pair: pair)
        }
    }

    private func connectTarget() -> Int32? {
        guard var address = HookNoteSocket.address(for: target) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Both descriptors of one relayed connection, closed once both directions have ended.
    private final class Pair: @unchecked Sendable {
        let client: Int32
        let upstream: Int32
        private let lock = NSLock()
        private var open = 2

        init(client: Int32, upstream: Int32) {
            self.client = client
            self.upstream = upstream
        }

        func directionEnded() {
            let last = lock.withLock { () -> Bool in
                open -= 1
                return open == 0
            }
            if last {
                close(client)
                close(upstream)
            }
        }
    }

    /// Copies one direction until its end, then half-closes the other side so its reader sees the end too.
    private static func pump(from source: Int32, to destination: Int32, pair: Pair) {
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            reading: while true {
                let count = read(source, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                var offset = 0
                while offset < count {
                    let written = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + offset, count - offset) }
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { break reading }
                    offset += written
                }
            }
            shutdown(destination, SHUT_WR)
            shutdown(source, SHUT_RD)
            pair.directionEnded()
        }
        thread.name = "LegacyBridgeRelay.pump"
        thread.start()
    }
}

/// Whether anything of Juice's still dials Open Island's socket (P911, P932): a Claude or Codex profile whose hooks
/// Juice wrote before its own helper and has not moved yet (`ProfileHookInspector.oldEntryCount`), or Juice's OpenCode
/// plugin of revision 1 under Open Island's file name. Open Island's own hooks and plugin are Open Island's: they never
/// make Juice listen on its socket. Reads each profile's hook file and the plugin's first line only.
enum LegacyBridgeUse {
    static func wanted(home: String = NSHomeDirectory(), targets: [ProfileHookTarget],
                       intents: ProfileHookIntentStore = ProfileHookIntentStore(),
                       managedHelperURL: URL = HookHome.current.helperURL) -> Bool {
        let plugin = OpenCodePluginInstaller(configDirectory: OpenCodePluginInstaller.defaultConfigDirectory(home: home))
        if case let .ours(revision) = plugin.readLegacyFile(), revision < 2 { return true }
        return targets.contains { target in
            ProfileHookInspector.oldEntryCount(for: target, intent: intents.intent(for: target.id), managedHelperURL: managedHelperURL) > 0
        }
    }
}
