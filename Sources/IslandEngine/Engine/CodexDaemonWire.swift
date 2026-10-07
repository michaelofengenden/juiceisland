import CryptoKit
import Darwin
import Foundation

/// The one connection Juice makes to Codex's shared background service (its app-server daemon, P1485 to P1509): a
/// WebSocket over the daemon's Unix control socket, `$CODEX_HOME/app-server-control/app-server-control.sock`. Codex
/// 0.158's own clients speak exactly this (openai/codex `app-server-client/src/remote.rs`: the handshake to
/// `ws://localhost/rpc`, one JSON-RPC message per text frame; `app-server-transport/src/transport/unix_socket.rs` accepts
/// it). Only text, close, ping and pong frames; client frames masked, as RFC 6455 asks. Blocking calls with timeouts, run
/// off the main thread by `CodexDaemonLink`; nothing here starts a daemon, and a socket that is not this user's is never
/// dialled. It is never the usage reader's connection: those are JuiceCore's own `codex app-server` over stdio.
final class UnixWebSocket {
    enum Failure: Error, Equatable {
        /// No socket at the path: no daemon for this home.
        case noSocket
        /// A socket file nobody listens on (the daemon is gone).
        case refused
        /// Not a socket, or not this user's.
        case notOurs
        case pathTooLong
        case handshake(String)
        case closed
        case timedOut
        case tooLarge
        case io(Int32)
    }

    /// RFC 6455's GUID for the accept key.
    static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    /// The largest message taken: `thread/read` without turns and `turn/start`'s answer are a few KB.
    static let messageLimit = 8 * 1_024 * 1_024
    static let headerLimit = 16 * 1_024
    /// The one path Juice upgrades: the daemon's JSON-RPC. Its other path, `/daemon/shutdown`, stops the daemon
    /// (`unix_socket.rs`), so it is never asked, and no caller can name another (P1495).
    static let rpcPath = "/rpc"

    private let fd: Int32
    private var pending: [UInt8] = []
    private var reader = WebSocketFrameReader(limit: UnixWebSocket.messageLimit)
    private var closed = false

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit { close() }

    /// Connects to the socket at `path` and upgrades: only a socket this user owns (`stat`, links followed), each read
    /// and write within `timeout`.
    static func open(path: String, timeout: TimeInterval, key: [UInt8] = WebSocketHandshake.randomKey()) throws -> UnixWebSocket {
        var info = stat()
        guard stat(path, &info) == 0 else { throw errno == ENOENT || errno == ENOTDIR ? Failure.noSocket : Failure.io(errno) }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw Failure.notOurs }
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.io(errno) }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let error = errno
            Darwin.close(fd)
            throw error == ECONNREFUSED || error == ENOENT ? Failure.refused : Failure.io(error)
        }
        let socket = UnixWebSocket(fd: fd)
        try socket.upgrade(key: key)
        return socket
    }

    private func upgrade(key: [UInt8]) throws {
        let encoded = Data(key).base64EncodedString()
        try write(Array(WebSocketHandshake.request(key: encoded).utf8))
        var head: [UInt8] = []
        let end: [UInt8] = [13, 10, 13, 10]
        while true {
            if let range = Self.find(end, in: head) {
                pending = Array(head[range.upperBound...])
                head = Array(head[..<range.upperBound])
                break
            }
            guard head.count < Self.headerLimit else { throw Failure.handshake("headers too long") }
            head += try readSome()
        }
        let text = String(decoding: head, as: UTF8.self)
        if let problem = WebSocketHandshake.problem(response: text, key: encoded) { throw Failure.handshake(problem) }
    }

    /// One message, as one masked text frame.
    func send(_ text: String) throws {
        guard !closed else { throw Failure.closed }
        try write(WebSocketFrame.encode(opcode: .text, payload: Array(text.utf8), mask: WebSocketFrame.randomMask()))
    }

    /// The next text message: a ping on the way is answered with its pong, a pong or a binary frame skipped, a close
    /// ends the connection.
    func receive() throws -> String {
        while true {
            guard !closed else { throw Failure.closed }
            if !pending.isEmpty {
                let bytes = pending
                pending = []
                try reader.push(bytes)
            }
            while let event = try reader.next() {
                switch event {
                case let .text(bytes): return String(decoding: bytes, as: UTF8.self)
                case let .ping(payload):
                    try write(WebSocketFrame.encode(opcode: .pong, payload: payload, mask: WebSocketFrame.randomMask()))
                case .pong, .binary: continue
                case .close:
                    closed = true
                    throw Failure.closed
                }
            }
            try reader.push(readSome())
        }
    }

    /// A close frame (1000, normal), then the socket closes. Safe to call twice.
    func close() {
        guard !closedFD else { return }
        if !closed {
            closed = true
            _ = try? write(WebSocketFrame.encode(opcode: .close, payload: [3, 232], mask: WebSocketFrame.randomMask()))
        }
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        closedFD = true
    }

    private var closedFD = false

    private func write(_ bytes: [UInt8]) throws {
        guard !closedFD else { throw Failure.closed }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if count < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN || errno == EWOULDBLOCK ? Failure.timedOut : Failure.io(errno)
            }
            offset += count
        }
    }

    private func readSome() throws -> [UInt8] {
        guard !closedFD else { throw Failure.closed }
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 { return Array(buffer[0..<count]) }
            if count == 0 { throw Failure.closed }
            if errno == EINTR { continue }
            throw errno == EAGAIN || errno == EWOULDBLOCK ? Failure.timedOut : Failure.io(errno)
        }
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return start..<start + needle.count
        }
        return nil
    }
}

/// The opening handshake (RFC 6455 §4): the request a client sends, and what makes the answer good.
enum WebSocketHandshake {
    static func randomKey() -> [UInt8] { (0..<16).map { _ in UInt8.random(in: 0...255) } }

    static func request(key: String) -> String {
        "GET \(UnixWebSocket.rpcPath) HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
    }

    /// The key the server must answer with.
    static func accept(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + UnixWebSocket.acceptGUID).utf8))).base64EncodedString()
    }

    /// nil for a good answer: 101, and the accept key for `key`; otherwise what was wrong, in a few words.
    static func problem(response: String, key: String) -> String? {
        let lines = response.components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/1.1 101") else {
            return "answered " + (lines.first.map { String($0.prefix(40)) } ?? "nothing")
        }
        let accept = lines.dropFirst().first { $0.lowercased().hasPrefix("sec-websocket-accept:") }
            .map { $0.dropFirst("sec-websocket-accept:".count).trimmingCharacters(in: .whitespaces) }
        return accept == Self.accept(for: key) ? nil : "a wrong accept key"
    }
}

/// One frame out (RFC 6455 §5.2).
enum WebSocketFrame {
    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    static func randomMask() -> [UInt8] { (0..<4).map { _ in UInt8.random(in: 0...255) } }

    /// A final frame; masked when `mask` is given (a client's always are).
    static func encode(opcode: Opcode, payload: [UInt8], mask: [UInt8]?) -> [UInt8] {
        var frame: [UInt8] = [0x80 | opcode.rawValue]
        let maskBit: UInt8 = mask == nil ? 0 : 0x80
        switch payload.count {
        case 0..<126:
            frame.append(maskBit | UInt8(payload.count))
        case 126...0xFFFF:
            frame.append(maskBit | 126)
            frame += [UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF)]
        default:
            frame.append(maskBit | 127)
            frame += (0..<8).reversed().map { UInt8(UInt64(payload.count) >> (UInt64($0) * 8) & 0xFF) }
        }
        guard let mask, mask.count == 4 else { return frame + payload }
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        return frame
    }
}

/// Reads the server's frames as they come, whole messages out: a fragmented text is joined, control frames come between.
struct WebSocketFrameReader {
    enum Event: Equatable {
        case text([UInt8])
        case binary
        case ping([UInt8])
        case pong
        case close
    }

    let limit: Int
    private var buffer: [UInt8] = []
    private var fragments: [UInt8] = []
    private var fragmentOpcode: UInt8?

    init(limit: Int) {
        self.limit = limit
    }

    mutating func push(_ bytes: [UInt8]) throws {
        buffer += bytes
        guard buffer.count <= limit + 14 + fragments.count else { throw UnixWebSocket.Failure.tooLarge }
    }

    /// The next whole message or control frame; nil until more bytes come.
    mutating func next() throws -> Event? {
        while true {
            guard buffer.count >= 2 else { return nil }
            let fin = buffer[0] & 0x80 != 0
            let opcode = buffer[0] & 0x0F
            let masked = buffer[1] & 0x80 != 0
            var length = Int(buffer[1] & 0x7F)
            var index = 2
            if length == 126 {
                guard buffer.count >= 4 else { return nil }
                length = Int(buffer[2]) << 8 | Int(buffer[3])
                index = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return nil }
                var value: UInt64 = 0
                for byte in buffer[2..<10] { value = value << 8 | UInt64(byte) }
                guard value <= UInt64(limit) else { throw UnixWebSocket.Failure.tooLarge }
                length = Int(value)
                index = 10
            }
            guard length <= limit, fragments.count + length <= limit else { throw UnixWebSocket.Failure.tooLarge }
            var mask: [UInt8] = []
            if masked {
                guard buffer.count >= index + 4 else { return nil }
                mask = Array(buffer[index..<index + 4])
                index += 4
            }
            guard buffer.count >= index + length else { return nil }
            var payload = Array(buffer[index..<index + length])
            if masked { payload = payload.enumerated().map { $0.element ^ mask[$0.offset % 4] } }
            buffer.removeFirst(index + length)
            switch opcode {
            case WebSocketFrame.Opcode.ping.rawValue: return .ping(payload)
            case WebSocketFrame.Opcode.pong.rawValue: return .pong
            case WebSocketFrame.Opcode.close.rawValue: return .close
            case WebSocketFrame.Opcode.continuation.rawValue:
                guard let started = fragmentOpcode else { throw UnixWebSocket.Failure.handshake("a stray continuation") }
                fragments += payload
                guard fin else { continue }
                fragmentOpcode = nil
                defer { fragments = [] }
                return started == WebSocketFrame.Opcode.text.rawValue ? .text(fragments) : .binary
            case WebSocketFrame.Opcode.text.rawValue, WebSocketFrame.Opcode.binary.rawValue:
                guard fin else {
                    fragmentOpcode = opcode
                    fragments = payload
                    continue
                }
                return opcode == WebSocketFrame.Opcode.text.rawValue ? .text(payload) : .binary
            default:
                continue
            }
        }
    }
}
