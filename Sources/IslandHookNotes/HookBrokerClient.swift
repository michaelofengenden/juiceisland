import Darwin
import Foundation
import OpenIslandCore

/// The helper's side of the request broker (a PermissionRequest from Claude or Codex). The helper holds no policy:
/// whether a request is held, and what is printed, is the engine's reply.
///
/// - No broker socket at all (no file, or nobody listening): `.noBroker`, and the helper runs upstream's helper as it
///   always did, so an app without the broker (a rollback, or a helper updated ahead of the app) keeps today's cards
///   (C16).
/// - A connect slower than `connectTimeout`, no `{"hold":…}` within `ackTimeout`, `{"hold":false}`, the end of the
///   connection, or anything unreadable: `.silent`. The helper exits 0 and prints nothing: the agent's own prompt,
///   reviewer or rule decides (fail open).
/// - `{"decision":…}` after a hold: `.output`, the bytes upstream's encoder writes for that response.
/// - A hold with no decision by `holdCap`: `.silent`.
public enum HookBrokerClient {
    public enum Outcome: Equatable, Sendable {
        case noBroker
        case silent
        case output(Data)
    }

    public static let connectTimeout: TimeInterval = 0.5
    public static let ackTimeout: TimeInterval = 2
    /// Below the registered 86,400 s (Claude) and 3,600 s (Codex) hook timeouts, so the helper always ends first.
    public static let claudeHoldCap: TimeInterval = 23 * 3_600
    public static let codexHoldCap: TimeInterval = 55 * 60

    public static func holdCap(source: String) -> TimeInterval { source == "codex" ? codexHoldCap : claudeHoldCap }

    public static func run(_ line: Data, to url: URL, source: String, connectTimeout: TimeInterval = connectTimeout,
                           ackTimeout: TimeInterval = ackTimeout, holdCap: TimeInterval? = nil) -> Outcome {
        guard var address = HookNoteSocket.address(for: url) else { return .noBroker }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .silent }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            switch errno {
            case ENOENT, ECONNREFUSED, ENOTSOCK, EPROTOTYPE: return .noBroker
            case EINPROGRESS, EAGAIN, EINTR:
                guard wait(fd, for: Int16(POLLOUT), timeout: connectTimeout) else { return .silent }
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                if error == ECONNREFUSED || error == ENOENT { return .noBroker }
                guard error == 0 else { return .silent }
            default:
                return .silent
            }
        }
        guard write(line, to: fd, timeout: ackTimeout) else { return .silent }

        var reader = LineReader(fd: fd)
        guard let ack = reader.next(timeout: ackTimeout).flatMap(HookRequestReply.decode), ack == .hold(true) else { return .silent }
        guard let reply = reader.next(timeout: holdCap ?? Self.holdCap(source: source)).flatMap(HookRequestReply.decode),
              case let .decision(response) = reply else { return .silent }
        let output = source == "codex" ? try? CodexHookOutputEncoder.standardOutput(for: response)
            : try? ClaudeHookOutputEncoder.standardOutput(for: response)
        return output.flatMap { $0 }.map(Outcome.output) ?? .silent
    }

    static func wait(_ fd: Int32, for events: Int16, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return false }
            var poller = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&poller, 1, Int32(min(left, 3_600) * 1_000))
            if result > 0 { return true }
            if result < 0, errno != EINTR { return false }
        }
    }

    static func write(_ data: Data, to fd: Int32, timeout: TimeInterval) -> Bool {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                guard wait(fd, for: Int16(POLLOUT), timeout: timeout) else { return false }
            } else {
                return false
            }
        }
        return true
    }

    /// Newline-separated lines from a non-blocking socket.
    struct LineReader {
        let fd: Int32
        var buffer = Data()
        static let lineLimit = 1 << 20

        init(fd: Int32) { self.fd = fd }

        /// The next line (without its newline), or nil at the end of the connection, after `timeout`, or when a line
        /// grows past `lineLimit`.
        mutating func next(timeout: TimeInterval) -> Data? {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    return Data(line)
                }
                guard buffer.count <= Self.lineLimit else { return nil }
                let left = deadline.timeIntervalSinceNow
                guard left > 0, HookBrokerClient.wait(fd, for: Int16(POLLIN), timeout: left) else { return nil }
                var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
                let count = read(fd, &chunk, chunk.count)
                if count > 0 {
                    buffer.append(contentsOf: chunk[0..<count])
                } else if count < 0, errno == EAGAIN || errno == EINTR {
                    continue
                } else {
                    return nil
                }
            }
        }
    }
}
