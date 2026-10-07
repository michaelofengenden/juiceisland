import Darwin
import Foundation
import IslandHookNotes
import Testing
@testable import IslandEngine

/// The live link to Codex's shared daemon (P1485 to P1509) against a stand-in daemon on a socket in a temporary folder:
/// the WebSocket upgrade and frames Codex 0.158's control socket speaks (`app-server-transport/src/transport/
/// unix_socket.rs`), and its JSON-RPC as Codex's own schema gives it (`app-server-protocol/schema/json/v2`:
/// `ThreadReadResponse`, `ThreadStatus`, `TurnStartParams`, `TurnStartResponse`, `TurnInterruptParams`). Never the
/// owner's daemon or home: every socket here is the test's own.
@Suite(.serialized)
struct CodexDaemonLinkTests {
    static let thread = "019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b"

    /// A stand-in daemon: a listener at `<home>/app-server-control/app-server-control.sock`, one connection at a time.
    /// Each connection's upgrade is answered as tungstenite answers it; each text message is recorded, and `script`
    /// says what to send back for it (any notifications or requests of the daemon's first, then the answer).
    final class StandInDaemon: @unchecked Sendable {
        let home: String
        let path: String
        private let fd: Int32
        private var listening = true
        private let lock = NSLock()
        private var messages: [[String: Any]] = []
        private var upgrades: [String] = []
        let script: @Sendable ([String: Any]) -> [String]

        init(answers: Bool = true, script: @escaping @Sendable ([String: Any]) -> [String] = StandInDaemon.standard()) throws {
            home = "/tmp/ji-cd-\(UUID().uuidString.prefix(8))"
            try FileManager.default.createDirectory(atPath: home + "/app-server-control", withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            path = CodexDaemonLink.socketPath(home: home)
            self.script = script
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = try #require(HookNoteSocket.address(for: URL(fileURLWithPath: path)))
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            #expect(bound == 0 && listen(fd, 8) == 0)
            let listener = fd
            Thread { [weak self] in
                while true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    guard let self else { close(client); return }
                    if answers { self.serve(client) } else { Thread.sleep(forTimeInterval: 2) }
                    close(client)
                }
            }.start()
        }

        /// What the client sent, every connection, in order.
        var received: [[String: Any]] { lock.withLock { messages } }
        var requests: [String] { lock.withLock { upgrades } }

        func stop() {
            stopListeningOnly()
            try? FileManager.default.removeItem(atPath: home)
        }

        /// The socket file stays, nobody listens: a daemon that went away.
        func stopListeningOnly() {
            let open: Bool = lock.withLock {
                defer { listening = false }
                return listening
            }
            guard open else { return }
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }

        private func serve(_ client: Int32) {
            var head: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4_096)
            var rest: [UInt8] = []
            while true {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { return }
                head += buffer[0..<count]
                if let range = UnixWebSocket.find([13, 10, 13, 10], in: head) {
                    rest = Array(head[range.upperBound...])
                    head = Array(head[..<range.upperBound])
                    break
                }
            }
            let request = String(decoding: head, as: UTF8.self)
            lock.withLock { upgrades.append(request) }
            let key = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
                .dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) ?? ""
            let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
                + "Sec-WebSocket-Accept: \(WebSocketHandshake.accept(for: key))\r\n\r\n"
            _ = Array(response.utf8).withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            var reader = WebSocketFrameReader(limit: 1 << 20)
            try? reader.push(rest)
            while true {
                while let event = try? reader.next() {
                    switch event {
                    case let .text(bytes):
                        guard let object = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any] else { continue }
                        lock.withLock { messages.append(object) }
                        for answer in script(object) {
                            let frame = WebSocketFrame.encode(opcode: .text, payload: Array(answer.utf8), mask: nil)
                            _ = frame.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                        }
                    case .close: return
                    default: continue
                    }
                }
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { return }
                try? reader.push(Array(buffer[0..<count]))
            }
        }

        static func answer(_ object: [String: Any], _ result: String) -> String {
            "{\"id\":\(object["id"] as? Int ?? -1),\"result\":\(result)}"
        }

        static func error(_ object: [String: Any], _ message: String) -> String {
            "{\"id\":\(object["id"] as? Int ?? -1),\"error\":{\"code\":-32600,\"message\":\"\(message)\"}}"
        }

        /// The thread as `thread/read` gives it (`ThreadReadResponse`), its status `status`.
        static func thread(status: String) -> String {
            """
            {"thread":{"id":"\(CodexDaemonLinkTests.thread)","sessionId":"\(CodexDaemonLinkTests.thread)","preview":"stream the importer",\
            "ephemeral":false,"modelProvider":"openai","createdAt":1791273600,"updatedAt":1791273900,"status":\(status),\
            "cwd":"/tmp/ji-resume/project","cliVersion":"0.158.0","source":"cli","turns":[]}}
            """
        }

        /// The daemon's own answers: initialize, then each method as the test's fixtures say.
        static func standard(read: String = thread(status: #"{"type":"idle"}"#),
                             turn: String = #"{"turn":{"id":"019a2b3d-turn","items":[],"itemsView":"notLoaded","status":"inProgress"}}"#)
            -> @Sendable ([String: Any]) -> [String] {
            { object in
                switch object["method"] as? String {
                case "initialize":
                    [answer(object, #"{"userAgent":"codex_app_server_daemon/0.158.0 (Mac OS 26.0; arm64)","codexHome":"/tmp/x","platformFamily":"unix","platformOs":"macos"}"#)]
                case "thread/read": [answer(object, read)]
                case "turn/start": [answer(object, turn)]
                case "turn/interrupt": [answer(object, "{}")]
                default: []
                }
            }
        }
    }

    // MARK: Reading the thread

    @Test
    func statusReadsTheThreadsStatusAndSkipsWhatComesBetween() async throws {
        let daemon = try StandInDaemon(script: { object in
            switch object["method"] as? String {
            case "thread/read":
                // A notification and a request of the daemon's own come first: neither is the answer, and the request
                // is never answered (it could be another client's to answer).
                [#"{"method":"thread/status/changed","params":{"threadId":"x","status":{"type":"active","activeFlags":[]}}}"#,
                 #"{"id":0,"method":"item/commandExecution/requestApproval","params":{"threadId":"x","turnId":"t","itemId":"i"}}"#,
                 #"{"id":7,"result":{"thread":{"status":{"type":"idle"}}}}"#,
                 StandInDaemon.answer(object, StandInDaemon.thread(status: #"{"type":"active","activeFlags":["waitingOnApproval"]}"#))]
            default: StandInDaemon.standard()(object)
            }
        })
        defer { daemon.stop() }
        let status = await CodexDaemonLink().status(of: Self.thread, home: daemon.home)
        #expect(status == .active(waitsOnYou: true))
        let methods = daemon.received.map { $0["method"] as? String ?? "answer:\($0["id"] ?? "")" }
        #expect(methods == ["initialize", "initialized", "thread/read"])
        let initialize = try #require(daemon.received.first?["params"] as? [String: Any])
        let client = try #require(initialize["clientInfo"] as? [String: Any])
        // The one name Codex keeps from rewriting the daemon's originator and User-Agent for every session (P1489).
        #expect(client["name"] as? String == "codex_app_server_daemon" && client["title"] as? String == "Juice Island")
        #expect(initialize["capabilities"] == nil)
        let read = try #require(daemon.received.last?["params"] as? [String: Any])
        #expect(read["threadId"] as? String == Self.thread && read["includeTurns"] as? Bool == false)
        // The upgrade Codex's own client sends.
        let upgrade = try #require(daemon.requests.first)
        #expect(upgrade.hasPrefix("GET /rpc HTTP/1.1\r\n") && upgrade.contains("Upgrade: websocket") && upgrade.contains("Sec-WebSocket-Version: 13"))
    }

    @Test
    func eachStatusReadsAsTheProtocolSaysIt() async throws {
        let cases: [(String?, String?, CodexDaemonStatus)] = [
            (#"{"type":"idle"}"#, nil, .idle),
            (#"{"type":"systemError"}"#, nil, .idle),
            (#"{"type":"notLoaded"}"#, nil, .notHeld),
            (#"{"type":"active","activeFlags":[]}"#, nil, .active(waitsOnYou: false)),
            (#"{"type":"active","activeFlags":["waitingOnUserInput"]}"#, nil, .active(waitsOnYou: true)),
            (nil, "thread not loaded: \(Self.thread)", .notHeld),
            (nil, "invalid thread id: nope", .failed("invalid thread id: nope")),
        ]
        for (status, error, expected) in cases {
            let daemon = try StandInDaemon(script: { object in
                guard object["method"] as? String == "thread/read" else { return StandInDaemon.standard()(object) }
                if let error { return [StandInDaemon.error(object, error)] }
                return [StandInDaemon.answer(object, StandInDaemon.thread(status: status ?? "{}"))]
            })
            #expect(await CodexDaemonLink().status(of: Self.thread, home: daemon.home) == expected, "\(status ?? error ?? "")")
            daemon.stop()
        }
    }

    // MARK: A turn, and its end

    /// The owner's text goes inside the JSON-RPC message (P1325): a leading "-" and quotes stay text.
    @Test
    func startTurnSendsTheTextInTheMessageAndAnswersTheTurnsID() async throws {
        let daemon = try StandInDaemon()
        defer { daemon.stop() }
        let text = "-rf the build folder, then say \"done\"\nand stop"
        let started = await CodexDaemonLink().startTurn(on: Self.thread, home: daemon.home, text: text)
        #expect(started == .started(turnID: "019a2b3d-turn"))
        let params = try #require(daemon.received.last?["params"] as? [String: Any])
        #expect(daemon.received.last?["method"] as? String == "turn/start")
        #expect(params["threadId"] as? String == Self.thread)
        let input = try #require(params["input"] as? [[String: Any]])
        #expect(input.count == 1 && input[0]["type"] as? String == "text" && input[0]["text"] as? String == text)
        #expect((input[0]["text_elements"] as? [Any])?.isEmpty == true)
        // Nothing else of the thread's is set: its own model, approvals and sandbox stay.
        #expect(Set(params.keys) == ["threadId", "input"])
    }

    @Test
    func aTurnOnAThreadTheDaemonLetGoSaysSo() async throws {
        let daemon = try StandInDaemon(script: { object in
            object["method"] as? String == "turn/start" ? [StandInDaemon.error(object, "thread not found: \(CodexDaemonLinkTests.thread)")]
                : StandInDaemon.standard()(object)
        })
        defer { daemon.stop() }
        #expect(await CodexDaemonLink().startTurn(on: Self.thread, home: daemon.home, text: "go on") == .notHeld)
    }

    @Test
    func interruptNamesTheTurn() async throws {
        let daemon = try StandInDaemon()
        defer { daemon.stop() }
        #expect(await CodexDaemonLink().interrupt(turn: "019a2b3d-turn", on: Self.thread, home: daemon.home))
        let params = try #require(daemon.received.last?["params"] as? [String: Any])
        #expect(daemon.received.last?["method"] as? String == "turn/interrupt")
        #expect(params["threadId"] as? String == Self.thread && params["turnId"] as? String == "019a2b3d-turn")
    }

    // MARK: No daemon, or one that is not this user's to reach

    @Test
    func noSocketAStaleOneOrNotASocketIsNoDaemonOrAProblemNeverAStart() async throws {
        let empty = "/tmp/ji-cd-\(UUID().uuidString.prefix(8))"
        #expect(await CodexDaemonLink().status(of: Self.thread, home: empty) == .noDaemon)
        #expect(await CodexDaemonLink().startTurn(on: Self.thread, home: empty, text: "go on") == .noDaemon)
        // A socket file nobody listens on: the daemon is gone.
        let stale = try StandInDaemon()
        stale.stopListeningOnly()
        #expect(await CodexDaemonLink().status(of: Self.thread, home: stale.home) == .noDaemon)
        stale.stop()
        // A plain file where the socket should be is never dialled.
        let odd = "/tmp/ji-cd-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: odd + "/app-server-control", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: CodexDaemonLink.socketPath(home: odd), contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: odd) }
        #expect(await CodexDaemonLink().status(of: Self.thread, home: odd) == .failed("its socket is not this user's"))
    }

    @Test
    func aDaemonThatNeverAnswersIsAProblemWithinItsTimeout() async throws {
        let daemon = try StandInDaemon(answers: false)
        defer { daemon.stop() }
        var link = CodexDaemonLink()
        link.timeout = 0.3
        #expect(await link.status(of: Self.thread, home: daemon.home) == .failed("it did not answer"))
    }

    // MARK: The frames and the upgrade (RFC 6455)

    @Test
    func framesRoundTripAtEveryLengthMaskedOrNot() throws {
        for count in [0, 1, 125, 126, 127, 65_535, 65_536, 70_000] {
            let payload = (0..<count).map { UInt8(truncatingIfNeeded: $0 * 7) }
            for mask in [nil, [UInt8](arrayLiteral: 1, 2, 3, 4)] {
                var reader = WebSocketFrameReader(limit: 1 << 20)
                let frame = WebSocketFrame.encode(opcode: .text, payload: payload, mask: mask)
                if let mask { #expect(frame[1] & 0x80 != 0 && frame.count == payload.count + 6 + (count < 126 ? 0 : count <= 65_535 ? 2 : 8) && Array(frame.suffix(count + 4).prefix(4)) == mask) }
                // Byte by byte for the short ones: nothing comes out until the frame is whole.
                if count < 200 {
                    for byte in frame.dropLast() {
                        try reader.push([byte])
                        #expect(try reader.next() == nil)
                    }
                    try reader.push([frame.last!])
                } else {
                    try reader.push(frame)
                }
                #expect(try reader.next() == .text(payload))
            }
        }
    }

    @Test
    func aFragmentedTextIsJoinedAndAControlFrameBetweenComesOut() throws {
        var reader = WebSocketFrameReader(limit: 1 << 20)
        var first = WebSocketFrame.encode(opcode: .text, payload: Array("{\"id\":".utf8), mask: nil)
        first[0] = WebSocketFrame.Opcode.text.rawValue
        let ping = WebSocketFrame.encode(opcode: .ping, payload: [9], mask: nil)
        let last = WebSocketFrame.encode(opcode: .continuation, payload: Array("1}".utf8), mask: nil)
        try reader.push(first + ping + last + WebSocketFrame.encode(opcode: .close, payload: [3, 232], mask: nil))
        #expect(try reader.next() == .ping([9]))
        #expect(try reader.next() == .text(Array("{\"id\":1}".utf8)))
        #expect(try reader.next() == .close)
        #expect(try reader.next() == nil)
    }

    @Test
    func aMessageOverTheLimitIsRefused() throws {
        var reader = WebSocketFrameReader(limit: 1_000)
        try reader.push(Array(WebSocketFrame.encode(opcode: .text, payload: [UInt8](repeating: 65, count: 2_000), mask: nil).prefix(10)))
        #expect(throws: UnixWebSocket.Failure.tooLarge) { try reader.next() }
    }

    @Test
    func theUpgradesAcceptKeyIsRFC6455s() {
        // RFC 6455 §1.3's own example.
        #expect(WebSocketHandshake.accept(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let good = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
        #expect(WebSocketHandshake.problem(response: good, key: key) == nil)
        #expect(WebSocketHandshake.problem(response: "HTTP/1.1 403 Forbidden\r\n\r\n", key: key) == "answered HTTP/1.1 403 Forbidden")
        #expect(WebSocketHandshake.problem(response: good.replacingOccurrences(of: "s3pP", with: "AAAA"), key: key) == "a wrong accept key")
        #expect(WebSocketHandshake.request(key: key)
            == "GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n")
    }
}
