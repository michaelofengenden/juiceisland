import Darwin
import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing

/// A scratch stream listener in a short temp folder, standing in for the engine's request broker. It never binds a
/// hook socket or the app's own sockets (P164).
final class ScratchBroker: @unchecked Sendable {
    let folder: URL
    let url: URL
    let fd: Int32
    private let lock = NSLock()
    private var received: [Data] = []
    private var clients: [Int32] = []

    /// `replies` runs for each request line and returns the lines to write back, with a pause before each.
    init(replies: @escaping @Sendable (Data) -> [(pause: TimeInterval, line: Data?)] = { _ in [] }) throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jib-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("r.sock")
        precondition(url.path.hasPrefix(NSTemporaryDirectory()), "scratch sockets only")
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(HookNoteSocket.address(for: url))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(fd, 8) == 0)
        let listener = fd
        Thread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                self?.lock.withLock { self?.clients.append(client) }
                Thread { [weak self] in self?.serve(client, replies: replies) }.start()
            }
        }.start()
    }

    private func serve(_ client: Int32, replies: @Sendable (Data) -> [(pause: TimeInterval, line: Data?)]) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !buffer.contains(UInt8(ascii: "\n")) {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
        }
        let line = Data(buffer.prefix { $0 != UInt8(ascii: "\n") })
        lock.withLock { received.append(line) }
        for reply in replies(line) {
            if reply.pause > 0 { Thread.sleep(forTimeInterval: reply.pause) }
            guard let data = reply.line else {
                close(client)
                return
            }
            _ = data.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        }
    }

    var lines: [Data] { lock.withLock { received } }

    deinit {
        close(fd)
        lock.withLock { clients.forEach { close($0) } }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The helper's side of the request broker: no broker runs upstream's helper (C16), a hung or refusing one fails open
/// silent within the ack time, and only a decision after a hold is printed, through upstream's own encoders.
@Suite(.serialized)
struct HookBrokerClientTests {
    static let claudeInput = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"git push"},"permission_mode":"default","cwd":"/tmp/p"}"#.utf8)

    static func line(source: String = "claude") -> Data {
        HookRequestLine(source: source, input: claudeInput, digest: "abc", entrypoint: "cli", agentPID: 77, hasTerminal: true).encoded()!
    }

    @Test
    func noSocketRunsUpstream() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jib-none-\(UUID().uuidString.prefix(6)).sock")
        #expect(HookBrokerClient.run(Self.line(), to: url, source: "claude") == .noBroker)
    }

    @Test
    func aSocketNobodyListensOnRunsUpstream() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jib-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("s.sock")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(HookNoteSocket.address(for: url))
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        #expect(HookBrokerClient.run(Self.line(), to: url, source: "claude") == .noBroker)
    }

    @Test
    func aReleaseIsSilentAndTheLineArrivesWhole() throws {
        let broker = try ScratchBroker { _ in [(0, HookRequestReply.hold(false).encoded())] }
        let started = Date()
        #expect(HookBrokerClient.run(Self.line(), to: broker.url, source: "claude") == .silent)
        #expect(Date().timeIntervalSince(started) < 1)
        let decoded = try #require(broker.lines.first.flatMap(HookRequestLine.decode))
        #expect(decoded.line.source == "claude" && decoded.line.entrypoint == "cli" && decoded.line.agentPID == 77)
        #expect(decoded.line.hasTerminal && decoded.line.digest == "abc")
        #expect(decoded.object["tool_name"] as? String == "Bash")
    }

    @Test
    func aBrokerThatNeverAnswersFailsOpenWithinTheAckTime() throws {
        let broker = try ScratchBroker { _ in [(3, nil)] }
        let started = Date()
        #expect(HookBrokerClient.run(Self.line(), to: broker.url, source: "claude", ackTimeout: 0.3) == .silent)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    @Test
    func aHoldThatEndsWithNoDecisionIsSilent() throws {
        let broker = try ScratchBroker { _ in [(0, HookRequestReply.hold(true).encoded()), (0.1, nil)] }
        #expect(HookBrokerClient.run(Self.line(), to: broker.url, source: "claude") == .silent)
    }

    @Test
    func aHoldPastItsCapIsSilent() throws {
        let broker = try ScratchBroker { _ in [(0, HookRequestReply.hold(true).encoded()), (2, nil)] }
        #expect(HookBrokerClient.run(Self.line(), to: broker.url, source: "claude", holdCap: 0.3) == .silent)
    }

    /// The owner's Allow: the helper prints exactly what upstream's helper prints for the same bridge response.
    @Test
    func aDecisionIsPrintedThroughUpstreamsEncoder() throws {
        let input: ClaudeHookJSONValue = .object(["command": .string("git push")])
        let response = BridgeResponse.claudeHookDirective(.permissionRequest(.allow(updatedInput: input)))
        let broker = try ScratchBroker { _ in [(0, HookRequestReply.hold(true).encoded()), (0.05, HookRequestReply.decision(response).encoded())] }
        let expected = try #require(try ClaudeHookOutputEncoder.standardOutput(for: response))
        #expect(HookBrokerClient.run(Self.line(), to: broker.url, source: "claude") == .output(expected))
        let object = try #require(JSONSerialization.jsonObject(with: expected) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(specific["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        #expect((decision["updatedInput"] as? [String: Any])?["command"] as? String == "git push")
    }

    @Test
    func aCodexDecisionUsesCodexsEncoder() throws {
        let response = BridgeResponse.codexHookDirective(.permissionRequest(.deny(message: "No")))
        let broker = try ScratchBroker { _ in [(0, HookRequestReply.hold(true).encoded()), (0, HookRequestReply.decision(response).encoded())] }
        let expected = try #require(try CodexHookOutputEncoder.standardOutput(for: response))
        #expect(HookBrokerClient.run(Self.line(source: "codex"), to: broker.url, source: "codex") == .output(expected))
    }

    @Test
    func repliesRoundTrip() {
        #expect(HookRequestReply.decode(HookRequestReply.hold(true).encoded().dropLast()) == .hold(true))
        #expect(HookRequestReply.decode(HookRequestReply.hold(false).encoded().dropLast()) == .hold(false))
        let response = BridgeResponse.claudeHookDirective(.permissionRequest(.deny(message: "x", interrupt: true)))
        #expect(HookRequestReply.decode(HookRequestReply.decision(response).encoded().dropLast()) == .decision(response))
        #expect(HookRequestReply.decode(Data("nonsense".utf8)) == nil)
    }

    @Test
    func anInputThatIsNotAnObjectOrTooLargeMakesNoLine() {
        #expect(HookRequestLine(source: "claude", input: Data("[1]".utf8)).encoded() == nil)
        let huge = Data(#"{"a":""#.utf8) + Data(repeating: UInt8(ascii: "x"), count: HookRequestLine.inputLimit) + Data(#""}"#.utf8)
        #expect(HookRequestLine(source: "claude", input: huge).encoded() == nil)
    }
}

/// What the prelude does with the two hooks that never reach upstream's helper.
struct HookPreludeBrokerTests {
    typealias Box = EngineFixtures.Box

    private static func io(input: Data, sent: Box<[(Data, URL)]>, brokered: Box<[(Data, URL, String)]>,
                           broker: HookBrokerClient.Outcome, fd: Int32) -> HookPrelude.IO {
        HookPrelude.IO(preparePipe: { StdinPipe.make(replacing: fd) }, readStandardInput: { input }, agentPID: { 4242 },
                       send: { data, url in sent.update { $0.append((data, url)) } },
                       broker: { line, url, source in
                           brokered.update { $0.append((line, url, source)) }
                           return broker
                       },
                       hasTerminal: { _ in true })
    }

    private static let environment = [HookNoteSocket.overrideKey: "/tmp/jin-n.sock", HookRequestSocket.overrideKey: "/tmp/jin-r.sock",
                                       "CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]

    private func run(_ input: Data, source: String?, broker: HookBrokerClient.Outcome = .silent)
        -> (HookPrelude.Outcome, sent: [(Data, URL)], brokered: [(Data, URL, String)], stdin: Data) {
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        let sent = Box<[(Data, URL)]>([]), brokered = Box<[(Data, URL, String)]>([])
        let arguments = ["OpenIslandHooks"] + (source.map { ["--source", $0] } ?? [])
        let outcome = HookPrelude.run(environment: Self.environment, arguments: arguments,
                                      io: Self.io(input: input, sent: sent, brokered: brokered, broker: broker, fd: fd))
        var stdin = Data()
        if case .forwarded = outcome {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                stdin.append(contentsOf: buffer[0..<count])
            }
        }
        return (outcome, sent.current, brokered.current, stdin)
    }

    @Test
    func aClaudePermissionRequestGoesToTheBrokerAndPrintsItsAnswer() throws {
        let output = Data("{\"x\":1}\n".utf8)
        let result = run(HookBrokerClientTests.claudeInput, source: "claude", broker: .output(output))
        guard case let .finished(note?, printed) = result.0 else {
            Issue.record("not finished: \(result.0)")
            return
        }
        #expect(printed == output)
        #expect(note.event == "PermissionRequest" && note.source == "claude" && note.entrypoint == "claude-desktop")
        #expect(result.sent.count == 1)
        let request = try #require(result.brokered.first)
        #expect(request.1.path == "/tmp/jin-r.sock" && request.2 == "claude")
        let decoded = try #require(HookRequestLine.decode(request.0.dropLast()))
        #expect(decoded.line.entrypoint == "claude-desktop" && decoded.line.agentPID == 4242 && decoded.line.hasTerminal)
        #expect(decoded.line.digest == HookInputDigest.of(["command": "git push"]))
    }

    @Test
    func aSilentBrokerEndsTheHookWithNothingPrinted() {
        let result = run(HookBrokerClientTests.claudeInput, source: "claude", broker: .silent)
        guard case let .finished(_, printed) = result.0 else {
            Issue.record("not finished: \(result.0)")
            return
        }
        #expect(printed == nil)
    }

    /// C16: an app without the broker keeps today's path.
    @Test
    func noBrokerHandsTheSameBytesToUpstream() {
        let result = run(HookBrokerClientTests.claudeInput, source: "claude", broker: .noBroker)
        #expect(result.0 == .forwarded(note: result.0.note))
        #expect(result.stdin == HookBrokerClientTests.claudeInput)
    }

    /// C5, P167: a Codex subagent's hook sends its note and never reaches upstream's bridge.
    @Test
    func aCodexSubagentHookIsKeptFromUpstream() {
        let input = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"root","agent_id":"child-1","agent_type":"worker","turn_id":"t9","transcript_path":"/tmp/child.jsonl","cwd":"/tmp/p","model":"m","permission_mode":"default","prompt":"do the child task"}"#.utf8)
        let result = run(input, source: "codex")
        #expect(result.0 == .finished(note: result.0.note, output: nil))
        #expect(result.brokered.isEmpty)
        #expect(result.0.note?.agentID == "child-1" && result.0.note?.turnID == "t9")
        // Its PermissionRequest goes to the broker (shown on the parent row, released at once), never to upstream.
        let request = Data(#"{"hook_event_name":"PermissionRequest","session_id":"root","agent_id":"child-1","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp/p","model":"m","permission_mode":"default","transcript_path":"/tmp/child.jsonl"}"#.utf8)
        let asked = run(request, source: "codex", broker: .silent)
        #expect(asked.0 == .finished(note: asked.0.note, output: nil))
        #expect(asked.brokered.count == 1)
        // With no broker, it still never reaches upstream's bridge.
        let alone = run(request, source: "codex", broker: .noBroker)
        #expect(alone.0 == .finished(note: alone.0.note, output: nil))
    }

    /// CX9, P161: upstream's bridge would hold a Codex PreToolUse as an approval; it ends with its note. Claude's is
    /// upstream's as before.
    @Test
    func aCodexPreToolUseNeverReachesUpstream() {
        let input = Data(#"{"hook_event_name":"PreToolUse","session_id":"root","turn_id":"t1","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"call_1","cwd":"/tmp/p","model":"m","permission_mode":"default"}"#.utf8)
        let result = run(input, source: "codex")
        #expect(result.0 == .finished(note: result.0.note, output: nil))
        #expect(result.brokered.isEmpty && result.0.note?.toolUseID == "call_1")
        let claude = Data(#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"toolu_1","cwd":"/tmp/p"}"#.utf8)
        #expect(run(claude, source: "claude").stdin == claude)
    }

    @Test
    func aCodexRootHookStillReachesUpstream() {
        let input = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"root","cwd":"/tmp/p","model":"m","permission_mode":"default","prompt":"hi"}"#.utf8)
        let result = run(input, source: "codex")
        #expect(result.0 == .forwarded(note: result.0.note))
        #expect(result.stdin == input)
        // Upstream's own default: no `--source` is Codex.
        #expect(run(input, source: nil).0 == .forwarded(note: run(input, source: nil).0.note))
    }

    /// P290: upstream's installer gives Codex's hooks no `--source`, and upstream's helper takes none as Codex; the note
    /// says "codex" too, so the engine's Codex checks match Codex's own notes. A named source is kept as it is.
    @Test
    func aHookWithNoSourceSendsANoteThatNamesCodex() throws {
        let input = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"root","turn_id":"t2","cwd":"/tmp/p","model":"m","permission_mode":"default","prompt":"hi"}"#.utf8)
        let result = run(input, source: nil)
        #expect(result.0.note?.source == "codex" && result.0.note?.agentSource == "codex")
        let sent = try #require(result.sent.first.flatMap { HookContextNote.decode($0.0) })
        #expect(sent.source == "codex" && sent.turnID == "t2")
        #expect(run(input, source: "codex").0.note?.source == "codex")
        #expect(run(input, source: "claude").0.note?.source == "claude" && run(input, source: "qwen").0.note?.source == "qwen")
        // Its PermissionRequest went to the broker as Codex's already; its note now says so as well.
        let request = run(Data(#"{"hook_event_name":"PermissionRequest","session_id":"root","turn_id":"t2","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp/p","model":"m","permission_mode":"default"}"#.utf8),
                          source: nil)
        #expect(request.brokered.first?.2 == "codex" && request.0.note?.source == "codex")
    }

    @Test
    func anotherSourcesPermissionRequestKeepsUpstreamsPath() {
        let result = run(HookBrokerClientTests.claudeInput, source: "qwen", broker: .output(Data("x".utf8)))
        #expect(result.brokered.isEmpty)
        #expect(result.stdin == HookBrokerClientTests.claudeInput)
    }

    @Test
    func anOversizedRequestIsSilentAndStillSendsItsNote() {
        var input = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Write","tool_input":{"content":""#.utf8)
        input.append(Data(repeating: UInt8(ascii: "a"), count: HookRequestLine.inputLimit + 10))
        input.append(Data(#""}}"#.utf8))
        let result = run(input, source: "claude", broker: .output(Data("x".utf8)))
        #expect(result.0 == .finished(note: result.0.note, output: nil))
        #expect(result.brokered.isEmpty)
        #expect(result.sent.count == 1)
    }
}

private extension HookPrelude.Outcome {
    var note: HookContextNote? {
        switch self {
        case let .forwarded(note), let .finished(note, _): note
        case .skipped, .untouched: nil
        }
    }
}
