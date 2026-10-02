import Darwin
import Foundation
import IslandHookNotes
import OpenIslandCore

/// What the engine needs from its request broker: `HookRequestBroker` in the app, a stand-in in tests.
protocol HookRequestReceiving: AnyObject, Sendable {
    /// The owner's click: sends the decision over the request's own connection, then ends it. False when the
    /// connection is already gone (the agent moved on).
    @discardableResult func answer(_ id: String, _ response: BridgeResponse) -> Bool
    /// Ends a held request with no decision: the agent's own prompt, reviewer or rule decides.
    func release(_ id: String)
    func stop()
}

/// The broker's reply to one request, decided from the request alone before anything else is read.
struct BrokerHold: Equatable, Sendable {
    /// The connection stays open so an island click can answer.
    var held: Bool
    /// A hold the broker ends by itself this long after its reply, on its own queue, whatever the main thread does: a
    /// Claude subagent's, whose own prompt waits on the hook (P350). nil: until the engine or the helper ends it.
    var bound: TimeInterval? = nil

    static let released = BrokerHold(held: false)
}

/// One request as the broker took it: the line, the parsed input, whether it was held (and for how long at most), and
/// when it came.
struct BrokeredRequest: Sendable {
    var id: String
    var line: HookRequestLine
    /// The hook's input. `[String: Any]` is not Sendable; it is only read after the hand-over, on the main actor.
    nonisolated(unsafe) var object: [String: Any]
    var held: Bool
    var at: Date
    /// A hold the broker ends by itself (`BrokerHold.bound`): a subagent's, held for the island (P350).
    var bound: TimeInterval? = nil
}

enum HookRequestBrokerError: Error, Equatable, LocalizedError {
    case inUse(path: String)
    case pathTooLong(path: String)
    case socketFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .inUse: "Another app receives hook requests"
        case .pathTooLong: "The hook-request socket path is too long"
        case let .socketFailed(code): "Could not open the hook-request socket (\(String(cString: strerror(code))))"
        }
    }
}

/// The engine's request broker (the needs-you design §3.4): a stream socket in the app's own support folder, one
/// connection per PermissionRequest from the superset helper. It reads the request line, replies `{"hold":…}` at once
/// from the engine's `Holds` (`AttentionPolicy.brokerHold`) on its own queue (never waiting for the main thread), and then hands the request to
/// the engine. A held connection stays open until the owner's click (`answer`), a release, the helper ending (the
/// agent killed it or moved on), its bound passing (a subagent's, P350), or the app stopping; every ending but a click
/// is "no decision". Owner-only (0600); never a hook socket; a live listener already on the path is never taken over.
final class HookRequestBroker: HookRequestReceiving, @unchecked Sendable {
    typealias Holds = @Sendable (HookRequestLine, [String: Any]) -> BrokerHold

    private let url: URL
    private let holds: Holds
    private let onRequest: @Sendable (BrokeredRequest) -> Void
    private let onEnded: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "HookRequestBroker")
    private var listener: DispatchSourceRead?
    private var boundInode: ino_t?
    /// Held connections by request id, with the source that notices the helper ending.
    private var held: [String: (fd: Int32, source: DispatchSourceRead)] = [:]
    /// Connections whose request line has not fully arrived.
    private var reading: [Int32: (buffer: Data, source: DispatchSourceRead)] = [:]
    static let lineLimit = HookRequestLine.inputLimit + 4_096

    init(url: URL, holds: @escaping Holds = { AttentionPolicy.brokerHold($0, $1, answersSubagents: false) },
         now: @escaping @Sendable () -> Date = { Date() },
         onRequest: @escaping @Sendable (BrokeredRequest) -> Void, onEnded: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.holds = holds
        self.now = now
        self.onRequest = onRequest
        self.onEnded = onEnded
    }

    func start() throws {
        guard var address = HookNoteSocket.address(for: url) else { throw HookRequestBrokerError.pathTooLong(path: url.path) }
        if Self.hasListener(at: url) { throw HookRequestBrokerError.inUse(path: url.path) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK else { throw HookRequestBrokerError.inUse(path: url.path) }
            unlink(url.path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookRequestBrokerError.socketFailed(errno: errno) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw HookRequestBrokerError.socketFailed(errno: code)
        }
        chmod(url.path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var info = stat()
        let inode: ino_t? = stat(url.path, &info) == 0 ? info.st_ino : nil
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        queue.sync {
            listener = source
            boundInode = inode
        }
        source.resume()
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            // The helpers see the end of the connection and exit silent: each agent keeps its own prompt.
            for (_, connection) in held { connection.source.cancel() }
            held = [:]
            for (_, connection) in reading { connection.source.cancel() }
            reading = [:]
            var info = stat()
            if let boundInode, stat(url.path, &info) == 0, info.st_ino == boundInode { unlink(url.path) }
            boundInode = nil
        }
    }

    /// The decision is upstream's bridge response; the helper prints it through upstream's own encoders.
    @discardableResult
    func answer(_ id: String, _ response: BridgeResponse) -> Bool {
        queue.sync {
            guard let connection = held.removeValue(forKey: id) else { return false }
            let written = write(HookRequestReply.decision(response).encoded(), to: connection.fd)
            connection.source.cancel()
            return written
        }
    }

    func release(_ id: String) {
        queue.sync {
            held.removeValue(forKey: id)?.source.cancel()
        }
    }

    /// Held requests (tests, Diagnostics).
    var heldCount: Int { queue.sync { held.count } }

    // MARK: Connections

    private func acceptAll(_ listenerFD: Int32) {
        while true {
            let client = accept(listenerFD, nil, nil)
            guard client >= 0 else { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            source.setEventHandler { [weak self] in self?.readLine(client) }
            source.setCancelHandler { close(client) }
            reading[client] = (Data(), source)
            source.resume()
        }
    }

    private func readLine(_ fd: Int32) {
        guard var connection = reading[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                connection.buffer.append(contentsOf: chunk[0..<count])
                if connection.buffer.count > Self.lineLimit { return drop(fd) }
                if connection.buffer.contains(UInt8(ascii: "\n")) { break }
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR {
                reading[fd] = connection
                return
            }
            return drop(fd)
        }
        // The reading source closes `fd` when it is cancelled; the connection lives on as its own descriptor.
        let kept = dup(fd)
        reading[fd] = nil
        connection.source.cancel()
        guard kept >= 0 else { return }
        let lineData = Data(connection.buffer.prefix { $0 != UInt8(ascii: "\n") })
        guard let (line, object) = HookRequestLine.decode(lineData) else {
            // Not a request: released, nothing held.
            _ = write(HookRequestReply.hold(false).encoded(), to: kept)
            close(kept)
            return
        }
        let hold = holds(line, object)
        let id = UUID().uuidString
        guard write(HookRequestReply.hold(hold.held).encoded(), to: kept) else {
            close(kept)
            return
        }
        if hold.held {
            let watch = DispatchSource.makeReadSource(fileDescriptor: kept, queue: queue)
            watch.setEventHandler { [weak self] in self?.noticeEnd(id, kept) }
            watch.setCancelHandler { close(kept) }
            held[id] = (kept, watch)
            watch.resume()
            if let bound = hold.bound {
                queue.asyncAfter(deadline: .now() + bound) { [weak self] in self?.boundPassed(id) }
            }
        } else {
            close(kept)
        }
        onRequest(BrokeredRequest(id: id, line: line, object: object, held: hold.held, at: now(), bound: hold.held ? hold.bound : nil))
    }

    /// A bounded hold still open at its bound (the engine's own end is sooner, so only a main thread stuck past it gets
    /// here): the connection ends with no decision, the helper exits silent and the agent shows its own prompt. The engine
    /// hears of it when it next acts on the request (`answer` finds it gone), never as the helper's end.
    private func boundPassed(_ id: String) {
        held.removeValue(forKey: id)?.source.cancel()
    }

    private func drop(_ fd: Int32) {
        reading.removeValue(forKey: fd)?.source.cancel()
    }

    /// Anything readable on a held connection is its end (the helper sends nothing after its line).
    private func noticeEnd(_ id: String, _ fd: Int32) {
        var byte: UInt8 = 0
        let count = read(fd, &byte, 1)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard let connection = held.removeValue(forKey: id) else { return }
        connection.source.cancel()
        onEnded(id)
    }

    private func write(_ data: Data, to fd: Int32) -> Bool {
        var offset = 0
        let deadline = Date().addingTimeInterval(1)
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EAGAIN || errno == EINTR, Date() < deadline {
                usleep(1_000)
            } else {
                return false
            }
        }
        return true
    }

    /// Whether a live process listens on the path.
    static func hasListener(at url: URL) -> Bool {
        guard var address = HookNoteSocket.address(for: url) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return connected == 0
    }
}
