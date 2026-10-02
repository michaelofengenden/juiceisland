import Darwin
import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// One tunnel's relay against a stand-in bridge and the real request broker, on scratch sockets in a short temp folder
/// (never a hook socket or the app's own, P164): a remote hook reaches the bridge with nothing of the remote's files or
/// terminals, a PermissionRequest is held by the broker and answered with the bytes upstream's encoder writes, the
/// remote going away ends the hold, and with no broker the bridge takes it, as upstream's helper would (C16).
@Suite(.serialized)
struct RemoteRelayTests {
    typealias Box = EngineFixtures.Box

    /// Accepts connections, records each command, and answers as upstream's bridge: its hello, then a response.
    final class BridgeStandIn: @unchecked Sendable {
        let commands = Box<[BridgeCommand]>([])
        private let fd: Int32

        init(url: URL) throws {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard var address = HookNoteSocket.address(for: url) else { throw CocoaError(.fileWriteUnknown) }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(fd, 8) == 0 else { throw CocoaError(.fileWriteUnknown) }
            let listener = fd, commands = commands
            Thread {
                while true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    Thread {
                        defer { close(client) }
                        if let hello = try? BridgeCodec.encodeLine(.hello(BridgeHello())) { _ = RemoteRelay.write(hello, to: client) }
                        var buffer = Data()
                        var chunk = [UInt8](repeating: 0, count: 65_536)
                        while true {
                            let count = read(client, &chunk, chunk.count)
                            guard count > 0 else { return }
                            buffer.append(contentsOf: chunk[0..<count])
                            guard let envelopes = try? BridgeCodec.decodeLines(from: &buffer) else { return }
                            for case let .command(command) in envelopes {
                                commands.update { $0.append(command) }
                                var response = BridgeResponse.acknowledged
                                if case let .processClaudeHook(payload) = command, payload.hookEventName == .permissionRequest {
                                    response = .claudeHookDirective(.permissionRequest(.allow(updatedInput: nil)))
                                }
                                if let line = try? BridgeCodec.encodeLine(.response(response)) { _ = RemoteRelay.write(line, to: client) }
                            }
                        }
                    }.start()
                }
            }.start()
        }

        func stop() {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    final class Harness: @unchecked Sendable {
        let folder: URL
        let bridge: BridgeStandIn
        let broker: HookRequestBroker?
        let requests = Box<[BrokeredRequest]>([])
        let ended = Box<[String]>([])
        let frames = Box<[MuxFrame]>([])
        let directory = RemoteSessionDirectory()
        let queue = DispatchQueue(label: "RemoteRelayTests")
        let relay: RemoteRelay

        init(broker withBroker: Bool = true) throws {
            folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jrr-\(UUID().uuidString.prefix(8))", isDirectory: true)
            precondition(folder.path.hasPrefix(NSTemporaryDirectory()), "scratch sockets only")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bridgeURL = folder.appendingPathComponent("b.sock"), brokerURL = folder.appendingPathComponent("r.sock")
            bridge = try BridgeStandIn(url: bridgeURL)
            let requests = requests, ended = ended
            if withBroker {
                let broker = HookRequestBroker(url: brokerURL, onRequest: { request in requests.update { $0.append(request) } },
                                               onEnded: { id in ended.update { $0.append(id) } })
                try broker.start()
                self.broker = broker
            } else {
                broker = nil
            }
            let frames = frames
            relay = RemoteRelay(endpoints: RemoteRelay.Endpoints(bridge: bridgeURL, broker: brokerURL),
                                host: RemoteSessionDirectory.Entry(hostID: "h1", hostName: "gpu1", destination: "me@gpu1"),
                                directory: directory, queue: queue) { frame in frames.update { $0.append(frame) } }
        }

        func send(_ frame: MuxFrame) {
            let relay = relay
            queue.async { relay.receive(frame) }
        }

        func hook(_ channel: UInt32, _ input: [String: Any], source: String = "claude", ctx: [String: Any] = [:]) {
            let object: [String: Any] = ["jr": 1, "v": 1, "source": source, "input": input, "tty": true, "entrypoint": "cli", "ctx": ctx]
            let line = try! JSONSerialization.data(withJSONObject: object) + Data("\n".utf8)
            send(MuxFrame(.open, channel))
            // In two pieces, as a socket may deliver it.
            send(MuxFrame(.data, channel, line.prefix(10)))
            send(MuxFrame(.data, channel, line.dropFirst(10)))
        }

        func waitFor(_ condition: () -> Bool) {
            for _ in 0..<300 where !condition() { usleep(10_000) }
        }

        func sent(_ channel: UInt32) -> [MuxFrame] { frames.current.filter { $0.channel == channel } }

        deinit {
            let relay = relay
            queue.sync { relay.stop() }
            broker?.stop()
            bridge.stop()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    nonisolated(unsafe) static let stop: [String: Any] = ["hook_event_name": "Stop", "session_id": "r1", "cwd": "/home/me/train",
                                      "transcript_path": "/home/me/.claude/projects/p/r1.jsonl", "terminal_tty": "/dev/pts/2"]
    nonisolated(unsafe) static let permission: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "r1", "cwd": "/home/me/train",
                                            "tool_name": "Bash", "tool_input": ["command": "nvidia-smi"], "permission_mode": "default"]

    /// The hold the remote helper hears the moment its channel opens: the Mac is there.
    static func ack(_ channel: UInt32) -> MuxFrame { MuxFrame(.data, channel, Data("{\"hold\":true}\n".utf8)) }

    /// S1: every channel is answered the moment it opens, before its line: a remote helper that hears nothing within a
    /// few seconds knows the Mac is asleep or gone, and ends.
    @Test func everyChannelIsAnsweredTheMomentItOpens() throws {
        let h = try Harness()
        h.send(MuxFrame(.open, 9))
        h.waitFor { !h.sent(9).isEmpty }
        #expect(h.sent(9) == [Self.ack(9)])
        #expect(h.bridge.commands.current.isEmpty && h.requests.current.isEmpty)
    }

    @Test func aRemoteHookReachesTheBridgeFiledUnderTheTunnelsHost() throws {
        let h = try Harness()
        h.hook(1, Self.stop, ctx: ["pane": "%4", "tmux": "/tmp/tmux-1000/default,9,0"])
        h.waitFor { h.sent(1).contains { $0.kind == .close } }
        #expect(h.sent(1) == [Self.ack(1), MuxFrame(.close, 1)])
        guard case let .processClaudeHook(payload)? = h.bridge.commands.current.first else {
            Issue.record("nothing reached the bridge")
            return
        }
        #expect(payload.sessionID == "r1" && payload.remote == true && payload.transcriptPath == nil && payload.terminalTTY == nil)
        let entry = try #require(h.directory.entry(for: "r1"))
        #expect(entry.hostID == "h1" && entry.hostName == "gpu1" && entry.context.tmuxPane == "%4")
        #expect(h.relay.openCount == 0)
    }

    @Test func aHeldRequestIsAnsweredWithWhatUpstreamsEncoderPrints() throws {
        let h = try Harness()
        h.hook(2, Self.permission)
        h.waitFor { !h.requests.current.isEmpty }
        let request = try #require(h.requests.current.first)
        #expect(request.held && request.line.agentPID == nil && request.line.entrypoint == "cli" && request.line.hasTerminal)
        h.waitFor { !h.sent(2).isEmpty }
        #expect(h.sent(2).first == MuxFrame(.data, 2, Data("{\"hold\":true}\n".utf8)))
        let allow = BridgeResponse.claudeHookDirective(.permissionRequest(.allow(updatedInput: .object(["command": .string("nvidia-smi")]))))
        #expect(h.broker?.answer(request.id, allow) == true)
        h.waitFor { h.sent(2).contains { $0.kind == .close } }
        let printed = try #require(h.sent(2).first { $0.kind == .data && $0.body.starts(with: Data("{\"stdout\"".utf8)) })
        let text = try #require((try JSONSerialization.jsonObject(with: printed.body) as? [String: String])?["stdout"])
        #expect(text.data(using: .utf8) == (try ClaudeHookOutputEncoder.standardOutput(for: allow)))
        #expect(h.bridge.commands.current.isEmpty)
    }

    @Test func theRemoteGoingAwayEndsTheHeldRequest() throws {
        let h = try Harness()
        h.hook(3, Self.permission)
        h.waitFor { !h.requests.current.isEmpty }
        h.send(MuxFrame(.close, 3))
        h.waitFor { !h.ended.current.isEmpty }
        #expect(h.ended.current == [h.requests.current.first?.id])
        #expect(h.broker?.heldCount == 0)
    }

    @Test func withNoBrokerTheBridgeTakesTheRequest() throws {
        let h = try Harness(broker: false)
        h.hook(4, Self.permission)
        h.waitFor { h.sent(4).contains { $0.kind == .close } }
        guard case let .processClaudeHook(payload)? = h.bridge.commands.current.first else {
            Issue.record("the bridge did not take it")
            return
        }
        #expect(payload.hookEventName == .permissionRequest && payload.remote == true)
        let printed = h.sent(4).first { $0.kind == .data && $0.body.starts(with: Data("{\"stdout\"".utf8)) }
            .map { String(decoding: $0.body, as: UTF8.self) } ?? ""
        #expect(printed.contains(#"\"behavior\":\"allow\""#) || printed.contains("allow"))
    }

    @Test func whatIsNotAHookLineEndsAtOnceAndReachesNothing() throws {
        let h = try Harness()
        h.send(MuxFrame(.open, 5))
        h.send(MuxFrame(.data, 5, Data(#"{"type":"command","command":{"type":"registerClient","role":"observer"}}"#.utf8) + Data([0x0A])))
        h.hook(6, Self.permission, source: "gemini")
        h.waitFor { h.sent(5).contains { $0.kind == .close } && h.sent(6).contains { $0.kind == .close } }
        #expect(h.sent(5) == [Self.ack(5), MuxFrame(.close, 5)] && h.sent(6) == [Self.ack(6), MuxFrame(.close, 6)])
        usleep(50_000)
        #expect(h.bridge.commands.current.isEmpty && h.requests.current.isEmpty && h.directory.entry(for: "r1") == nil)
    }
}
