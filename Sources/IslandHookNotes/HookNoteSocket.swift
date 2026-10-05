import Darwin
import Foundation

/// Where context notes go: a datagram socket in the app's own support folder, owned by the engine. It is not one of
/// the hook sockets (`bridge.sock`, `/tmp/open-island-<uid>.sock`). A helper in a `HookHome` sends to its home's
/// (`HookHome.notesURL`); the default here is where the private app has always listened, which a helper at Open
/// Island's path still sends to.
public enum HookNoteSocket {
    public static let folderName = "Juice Island"
    public static let fileName = "hook-notes.sock"
    /// Lets a test point one helper process at a scratch socket, as upstream's `OPEN_ISLAND_SOCKET_PATH` does for the
    /// bridge. The helper reads it for its own use; it is never forwarded.
    public static let overrideKey = "JUICE_ISLAND_HOOK_NOTES_SOCKET"

    /// `~/Library/Application Support/Juice Island/hook-notes.sock`, with the home folder from the user database, so
    /// the app and a helper started by any agent agree even when the agent's `HOME` differs.
    public static var defaultURL: URL {
        URL(fileURLWithPath: homeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// The helper's socket: the override when set, else its home's (a helper installed at `<home>/bin/JuiceHooks`,
    /// P900), else the default, where a helper at Open Island's path has always sent its notes.
    public static func helperURL(environment: [String: String], home: HookHome? = nil) -> URL {
        if let path = environment[overrideKey], !path.isEmpty { return URL(fileURLWithPath: path) }
        return home?.notesURL ?? defaultURL
    }

    static func homeDirectory() -> String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir { return String(cString: directory) }
        return NSHomeDirectory()
    }

    /// A `sockaddr_un` for the path, or nil when the path does not fit (104 bytes on macOS, with its terminator).
    public static func address(for url: URL) -> sockaddr_un? {
        let path = Array(url.path.utf8)
        var address = sockaddr_un()
        guard !path.isEmpty, path.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path)
            buffer[path.count] = 0
        }
        return address
    }
}

/// Sends one note and forgets it. It never waits for an answer and never blocks: a non-blocking datagram either goes
/// into the receiver's buffer at once or is dropped (no receiver, a full buffer, a path too long). A hook is never
/// slowed or broken by a missing or hung Juice Island.
public enum HookNoteSender {
    public enum Result: Equatable, Sendable {
        case sent
        /// Nothing listens: no socket file, or a stale one (the app is not running).
        case noReceiver
        /// The receiver's buffer is full, or the note is too big.
        case dropped
        case failed(errno: Int32)
    }

    @discardableResult
    public static func send(_ data: Data, to url: URL) -> Result {
        guard var address = HookNoteSocket.address(for: url) else { return .failed(errno: ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return .failed(errno: errno) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, MSG_DONTWAIT, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        if sent == data.count { return .sent }
        let code = errno
        switch code {
        case ENOENT, ECONNREFUSED, ENOTSOCK, EPROTOTYPE: return .noReceiver
        case EAGAIN, ENOBUFS, EMSGSIZE: return .dropped
        default: return .failed(errno: code)
        }
    }
}
