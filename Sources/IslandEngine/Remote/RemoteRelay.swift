import Darwin
import Foundation
import IslandHookNotes
import OpenIslandCore

/// One tunnel's relay (P742): each hook connection on the remote arrives as a channel of frames. Its one line is
/// routed (`RemoteRouting`), its session filed under the tunnel's host, and a local connection made to the bridge or the
/// request broker, which never know the hook came from far away. Their replies go back as `{"hold":…}` and
/// `{"stdout":…}` lines, the bytes upstream's encoders write, so the remote helper prints what it is given. A channel
/// the remote closes closes its local connection: a held request then ends as when a local helper exits. Each channel
/// is answered `{"hold":true}` the moment it opens, so the remote helper knows the Mac is there: one that hears nothing
/// within a few seconds (the Mac asleep, sshd none the wiser) ends at once (P757). Everything runs on the relay's own
/// queue; nothing waits on the main thread.
final class RemoteRelay: @unchecked Sendable {
    struct Endpoints: Sendable {
        var bridge: URL
        /// nil: no broker in this engine, and a PermissionRequest takes the bridge as upstream's helper would (C16).
        var broker: URL?
    }

    private final class Channel {
        var inbox = Data()
        var routed = false
        var source = "claude"
        var fd: Int32 = -1
        var reader: DispatchSourceRead?
        var timer: DispatchSourceTimer?
        var replies = Data()
        var brokered = false
    }

    private let endpoints: Endpoints
    private let host: RemoteSessionDirectory.Entry
    private let directory: RemoteSessionDirectory
    private let queue: DispatchQueue
    private let send: @Sendable (MuxFrame) -> Void
    private var channels: [UInt32: Channel] = [:]
    private var stopped = false

    /// `send` writes a frame to the tunnel; it is called on `queue`.
    init(endpoints: Endpoints, host: RemoteSessionDirectory.Entry, directory: RemoteSessionDirectory, queue: DispatchQueue,
         send: @escaping @Sendable (MuxFrame) -> Void) {
        self.endpoints = endpoints
        self.host = host
        self.directory = directory
        self.queue = queue
        self.send = send
    }

    /// Open channels (tests).
    var openCount: Int { queue.sync { channels.count } }

    /// A frame from the remote; call on `queue`.
    func receive(_ frame: MuxFrame) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        switch frame.kind {
        case .open:
            channels[frame.channel] = Channel()
            send(MuxFrame(.data, frame.channel, HookRequestReply.hold(true).encoded()))
        case .data:
            guard let channel = channels[frame.channel], !channel.routed else { return }
            channel.inbox.append(frame.body)
            if let newline = channel.inbox.firstIndex(of: UInt8(ascii: "\n")) {
                channel.routed = true
                start(frame.channel, channel, line: Data(channel.inbox[channel.inbox.startIndex..<newline]))
                channel.inbox = Data()
            } else if channel.inbox.count > RemoteHookLine.lineLimit {
                end(frame.channel, tellRemote: true)
            }
        case .close:
            end(frame.channel, tellRemote: false)
        case .hello, .tmux:
            break
        }
    }

    /// The tunnel ended: every local connection closes, and a held request ends with no decision.
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        stopped = true
        for id in Array(channels.keys) { end(id, tellRemote: false) }
    }

    // MARK: Routing

    private func start(_ id: UInt32, _ channel: Channel, line: Data) {
        guard let hook = RemoteHookLine.decode(line) else { return end(id, tellRemote: true) }
        channel.source = hook.source
        let route = RemoteRouting.route(hook)
        if case .end = route { return end(id, tellRemote: true) }
        if let sessionID = hook.sessionID {
            var entry = host
            entry.context = hook.context
            directory.record(sessionID, entry)
        }
        switch route {
        case .end:
            end(id, tellRemote: true)
        case let .bridge(command, timeout):
            toBridge(id, channel, command, timeout: timeout)
        case let .broker(request, fallback):
            guard let broker = endpoints.broker, let data = request.encoded() else {
                return toBridge(id, channel, fallback, timeout: RemoteRouting.permissionTimeout(source: hook.source))
            }
            switch Self.connect(broker) {
            case let .connected(fd):
                channel.brokered = true
                open(id, channel, fd: fd, line: data, timeout: nil)
            case .noListener:
                toBridge(id, channel, fallback, timeout: RemoteRouting.permissionTimeout(source: hook.source))
            case .failed:
                end(id, tellRemote: true)
            }
        }
    }

    private func toBridge(_ id: UInt32, _ channel: Channel, _ command: BridgeCommand, timeout: TimeInterval) {
        guard let line = try? BridgeCodec.encodeLine(.command(command)), case let .connected(fd) = Self.connect(endpoints.bridge) else {
            return end(id, tellRemote: true)
        }
        open(id, channel, fd: fd, line: line, timeout: timeout)
    }

    private func open(_ id: UInt32, _ channel: Channel, fd: Int32, line: Data, timeout: TimeInterval?) {
        channel.fd = fd
        guard Self.write(line, to: fd) else { return end(id, tellRemote: true) }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readLocal(id) }
        reader.setCancelHandler { close(fd) }
        channel.reader = reader
        reader.resume()
        if let timeout {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in self?.end(id, tellRemote: true) }
            channel.timer = timer
            timer.resume()
        }
    }

    private func readLocal(_ id: UInt32) {
        guard let channel = channels[id], channel.fd >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        let count = read(channel.fd, &chunk, chunk.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else { return end(id, tellRemote: true) }
        channel.replies.append(contentsOf: chunk[0..<count])
        guard channel.replies.count <= MuxDecoder.bodyLimit else { return end(id, tellRemote: true) }
        channel.brokered ? brokerReplies(id, channel) : bridgeReplies(id, channel)
    }

    /// The broker's `{"hold":…}` goes on as it is; its decision becomes what the helper prints.
    private func brokerReplies(_ id: UInt32, _ channel: Channel) {
        while let newline = channel.replies.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(channel.replies[channel.replies.startIndex..<newline])
            channel.replies = Data(channel.replies[channel.replies.index(after: newline)...])
            switch HookRequestReply.decode(line) {
            case let .hold(hold)?:
                send(MuxFrame(.data, id, HookRequestReply.hold(hold).encoded()))
                if !hold { return end(id, tellRemote: true) }
            case let .decision(response)?:
                if let text = RemoteRouting.standardOutput(for: response, source: channel.source) {
                    send(MuxFrame(.data, id, RemoteRouting.stdoutLine(text)))
                }
                return end(id, tellRemote: true)
            case nil:
                return end(id, tellRemote: true)
            }
        }
    }

    private func bridgeReplies(_ id: UInt32, _ channel: Channel) {
        guard let messages = try? BridgeCodec.decodeLines(from: &channel.replies) else { return end(id, tellRemote: true) }
        for message in messages {
            guard case let .response(response) = message else { continue }
            if let text = RemoteRouting.standardOutput(for: response, source: channel.source) {
                send(MuxFrame(.data, id, RemoteRouting.stdoutLine(text)))
            }
            return end(id, tellRemote: true)
        }
    }

    private func end(_ id: UInt32, tellRemote: Bool) {
        guard let channel = channels.removeValue(forKey: id) else { return }
        channel.timer?.cancel()
        if let reader = channel.reader {
            reader.cancel()
        } else if channel.fd >= 0 {
            close(channel.fd)
        }
        if tellRemote, !stopped { send(MuxFrame(.close, id)) }
    }

    // MARK: Local sockets

    enum Connection: Equatable {
        case connected(Int32)
        /// No socket file, or nobody listening on it.
        case noListener
        case failed
    }

    static func connect(_ url: URL) -> Connection {
        guard var address = HookNoteSocket.address(for: url) else { return .failed }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            close(fd)
            return code == ENOENT || code == ECONNREFUSED ? .noListener : .failed
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return .connected(fd)
    }

    static func write(_ data: Data, to fd: Int32, timeout: TimeInterval = 2) -> Bool {
        var offset = 0
        let deadline = Date().addingTimeInterval(timeout)
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EAGAIN || errno == EINTR, Date() < deadline {
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&poller, 1, 100)
            } else {
                return false
            }
        }
        return true
    }
}
