import Darwin
import Foundation
import IslandHookNotes

/// What the engine needs from its context-note receiver: `HookNoteListener` in the app, a stand-in in tests.
protocol HookNoteReceiving: AnyObject, Sendable {
    func stop()
}

enum HookNoteListenerError: Error, Equatable, LocalizedError {
    /// Another process receives on the path (a second copy of the app).
    case inUse(path: String)
    case pathTooLong(path: String)
    case socketFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .inUse: "Another app receives hook notes"
        case .pathTooLong: "The hook-note socket path is too long"
        case let .socketFailed(code): "Could not open the hook-note socket (\(String(cString: strerror(code))))"
        }
    }
}

/// The engine's second socket (spec §3.8): a datagram socket in the app's own support folder that receives the
/// superset helper's context notes. Owner-only (0600); a folder it creates is owner-only (0700), and an existing
/// folder keeps its mode (inside `~/Library`, which is 0700). It never touches the hook sockets.
/// Each datagram is one note; anything that does not decode as one is dropped.
final class HookNoteListener: HookNoteReceiving, @unchecked Sendable {
    private let url: URL
    private let handler: @Sendable (HookContextNote) -> Void
    private let queue = DispatchQueue(label: "HookNoteListener")
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var boundInode: ino_t?
    /// Room for hundreds of queued notes.
    static let receiveBufferSize: Int32 = 256 * 1_024

    init(url: URL, handler: @escaping @Sendable (HookContextNote) -> Void) {
        self.url = url
        self.handler = handler
    }

    /// Binds, unless another process already receives there. A file nobody receives on is left over from a run that
    /// ended and is replaced.
    func start() throws {
        guard var address = HookNoteSocket.address(for: url) else { throw HookNoteListenerError.pathTooLong(path: url.path) }
        if Self.hasReceiver(at: url) { throw HookNoteListenerError.inUse(path: url.path) }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            // Only a socket file is ever replaced; anything else at the path is left alone.
            guard existing.st_mode & S_IFMT == S_IFSOCK else { throw HookNoteListenerError.inUse(path: url.path) }
            unlink(url.path)
        }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw HookNoteListenerError.socketFailed(errno: errno) }
        // A datagram socket gets 4 KiB by default (net.local.dgram.recvspace), a handful of notes: a burst of hooks
        // while this queue is busy would drop the rest, a StopFailure among them. The senders never wait either way.
        var bufferSize = Self.receiveBufferSize
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw HookNoteListenerError.socketFailed(errno: code)
        }
        chmod(url.path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var info = stat()
        let inode: ino_t? = stat(url.path, &info) == 0 ? info.st_ino : nil

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let handler = self.handler
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: HookContextNote.maximumSize + 1)
            while true {
                let count = recv(fd, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                if let note = HookContextNote.decode(Data(buffer[0..<count])) { handler(note) }
            }
        }
        source.setCancelHandler { close(fd) }
        lock.withLock {
            self.source = source
            self.boundInode = inode
        }
        source.resume()
    }

    /// Stops receiving and removes the socket file, if it is still the one this listener bound.
    func stop() {
        let (source, inode) = lock.withLock {
            defer {
                self.source = nil
                self.boundInode = nil
            }
            return (self.source, self.boundInode)
        }
        guard let source else { return }
        source.cancel()
        var info = stat()
        if let inode, stat(url.path, &info) == 0, info.st_ino == inode { unlink(url.path) }
    }

    /// Whether a live process receives on the path: connect(2) on a datagram socket succeeds only then.
    static func hasReceiver(at url: URL) -> Bool {
        guard var address = HookNoteSocket.address(for: url) else { return false }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return connected == 0
    }
}
