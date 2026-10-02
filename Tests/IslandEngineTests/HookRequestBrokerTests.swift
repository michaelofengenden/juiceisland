import Darwin
import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// The engine's request broker against the helper's real client, on a scratch socket in a short temp folder (never a
/// hook socket or the app's own, P164): the hold reply from the request alone, a click's decision, a release, the
/// helper ending, stopping, and a live listener never taken over.
@Suite(.serialized)
struct HookRequestBrokerTests {
    typealias Box = EngineFixtures.Box

    final class Harness: @unchecked Sendable {
        let folder: URL
        let url: URL
        let requests = Box<[BrokeredRequest]>([])
        let ended = Box<[String]>([])
        let broker: HookRequestBroker

        init(holds: HookRequestBroker.Holds? = nil) throws {
            folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jir-\(UUID().uuidString.prefix(8))", isDirectory: true)
            url = folder.appendingPathComponent("q.sock")
            precondition(url.path.hasPrefix(NSTemporaryDirectory()), "scratch sockets only")
            let requests = requests, ended = ended
            if let holds {
                broker = HookRequestBroker(url: url, holds: holds, onRequest: { request in requests.update { $0.append(request) } },
                                           onEnded: { id in ended.update { $0.append(id) } })
            } else {
                broker = HookRequestBroker(url: url, onRequest: { request in requests.update { $0.append(request) } },
                                           onEnded: { id in ended.update { $0.append(id) } })
            }
            try broker.start()
        }

        func waitFor(_ condition: () -> Bool) {
            for _ in 0..<300 where !condition() { usleep(10_000) }
        }

        deinit {
            broker.stop()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    static func line(source: String = "claude", entrypoint: String? = "cli", agent: String? = nil) -> Data {
        var object: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "Bash",
                                     "tool_input": ["command": "git push"], "permission_mode": "default", "cwd": "/tmp/p"]
        if let agent { object["agent_id"] = agent }
        let input = try! JSONSerialization.data(withJSONObject: object)
        return HookRequestLine(source: source, input: input, digest: "d", entrypoint: entrypoint, agentPID: 77, hasTerminal: true).encoded()!
    }

    /// Runs the helper's client off the test's thread and returns its outcome when it ends.
    static func client(_ line: Data, _ url: URL, source: String = "claude") -> Task<HookBrokerClient.Outcome, Never> {
        Task.detached { HookBrokerClient.run(line, to: url, source: source, ackTimeout: 2) }
    }

    @Test
    func aHeldRequestPrintsTheClicksDecision() async throws {
        let h = try Harness()
        let running = Self.client(Self.line(), h.url)
        h.waitFor { !h.requests.current.isEmpty }
        let request = try #require(h.requests.current.first)
        #expect(request.held && request.line.source == "claude" && request.object["tool_name"] as? String == "Bash")
        #expect(h.broker.heldCount == 1)
        let allow = BridgeResponse.claudeHookDirective(.permissionRequest(.allow(updatedInput: .object(["command": .string("git push")]))))
        #expect(h.broker.answer(request.id, allow))
        guard case let .output(data) = await running.value else {
            Issue.record("no decision printed")
            return
        }
        let printed = String(decoding: data, as: UTF8.self)
        #expect(printed.contains(#""behavior":"allow""#) && printed.contains("git push"))
        // A second click finds nothing to answer.
        #expect(!h.broker.answer(request.id, allow))
        #expect(h.broker.heldCount == 0 && h.ended.current.isEmpty)
    }

    @Test
    func codexASubagentAndAHeadlessRunAreReleasedAtOnce() async throws {
        let h = try Harness()
        for (line, source) in [(Self.line(source: "codex", entrypoint: nil), "codex"), (Self.line(agent: "w1"), "claude"),
                               (Self.line(entrypoint: "sdk-cli"), "claude")] {
            let started = Date()
            #expect(await Self.client(line, h.url, source: source).value == .silent)
            #expect(Date().timeIntervalSince(started) < 1)
        }
        h.waitFor { h.requests.current.count == 3 }
        #expect(h.requests.current.map(\.held) == [false, false, false])
        #expect(h.broker.heldCount == 0)
    }

    @Test
    func aReleaseEndsTheHelperSilent() async throws {
        let h = try Harness()
        let running = Self.client(Self.line(), h.url)
        h.waitFor { !h.requests.current.isEmpty }
        h.broker.release(try #require(h.requests.current.first?.id))
        #expect(await running.value == .silent)
        #expect(h.ended.current.isEmpty)
    }

    /// The helper killed (Claude answered at its own prompt, a timeout): the broker says the request ended.
    @Test
    func aHelperThatGoesAwayEndsItsRequest() throws {
        let h = try Harness()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(HookNoteSocket.address(for: h.url))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(connected == 0)
        var line = Self.line()
        line.append(UInt8(ascii: "\n"))
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var reply = [UInt8](repeating: 0, count: 64)
        let count = read(fd, &reply, reply.count)
        #expect(String(decoding: reply[0..<max(0, count)], as: UTF8.self).contains(#""hold":true"#))
        close(fd)
        h.waitFor { !h.ended.current.isEmpty }
        #expect(h.ended.current == h.requests.current.map(\.id))
        #expect(h.broker.heldCount == 0)
    }

    @Test
    func aLineThatIsNotARequestHoldsNothing() async throws {
        let h = try Harness()
        #expect(await Self.client(Data("not json".utf8), h.url).value == .silent)
        #expect(h.requests.current.isEmpty)
    }

    /// Stopping (the app quits) ends every held helper silent, and removes only its own socket file.
    @Test
    func stoppingEndsEveryHeldHelperSilent() async throws {
        let h = try Harness()
        let first = Self.client(Self.line(), h.url), second = Self.client(Self.line(), h.url)
        h.waitFor { h.requests.current.count == 2 }
        #expect(h.broker.heldCount == 2)
        h.broker.stop()
        #expect(await first.value == .silent)
        #expect(await second.value == .silent)
        #expect(!FileManager.default.fileExists(atPath: h.url.path))
    }

    /// P350: a subagent's request held for the island has a bound the broker keeps by itself, on its own queue: a click
    /// before it still answers, and at it the helper ends silent (Claude builds its own prompt) with no end reported,
    /// whatever the main thread does. A main-thread hold has none. With the switch off, a subagent's is released.
    @Test
    func aSubagentsHoldEndsAtItsBoundWhateverTheMainThreadDoes() async throws {
        let on = EngineFixtures.Box(true)
        let h = try Harness(holds: { line, object in
            AttentionPolicy.brokerHold(line, object, answersSubagents: on.current, backstop: 0.6)
        })
        // Answered before the bound: the decision is printed.
        let answered = Self.client(Self.line(agent: "wf-a"), h.url)
        h.waitFor { h.requests.current.count == 1 }
        let first = try #require(h.requests.current.first)
        #expect(first.held && first.bound == 0.6)
        let deny = BridgeResponse.claudeHookDirective(.permissionRequest(.deny(message: "not the shots folder", interrupt: false)))
        #expect(h.broker.answer(first.id, deny))
        guard case let .output(data) = await answered.value else {
            Issue.record("no decision printed")
            return
        }
        #expect(String(decoding: data, as: UTF8.self).contains("not the shots folder"))
        // Left alone: the broker ends it at its bound, silent, and reports no end (the engine reads it as its own end).
        let started = Date()
        let left = Self.client(Self.line(agent: "wf-b"), h.url)
        #expect(await left.value == .silent)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.55 && elapsed < 5, "\(elapsed)")
        #expect(h.broker.heldCount == 0 && h.ended.current.isEmpty)
        let second = try #require(h.requests.current.last)
        #expect(!h.broker.answer(second.id, deny))
        // The main thread's hold has no bound.
        let main = Self.client(Self.line(), h.url)
        h.waitFor { h.requests.current.count == 3 }
        #expect(h.requests.current.last?.held == true && h.requests.current.last?.bound == nil)
        try await Task.sleep(for: .milliseconds(900))
        #expect(h.broker.heldCount == 1)
        h.broker.release(try #require(h.requests.current.last?.id))
        #expect(await main.value == .silent)
        // Off: handed back at once.
        on.update { $0 = false }
        #expect(await Self.client(Self.line(agent: "wf-c"), h.url).value == .silent)
        h.waitFor { h.requests.current.count == 4 }
        #expect(h.requests.current.last?.held == false && h.requests.current.last?.bound == nil)
    }

    /// A second broker on the same path is refused while the first listens; the socket is the owner's only.
    @Test
    func aLiveListenerIsNeverTakenOver() throws {
        let h = try Harness()
        let other = HookRequestBroker(url: h.url, onRequest: { _ in }, onEnded: { _ in })
        #expect(throws: HookRequestBrokerError.inUse(path: h.url.path)) { try other.start() }
        var info = stat()
        #expect(stat(h.url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        // A plain file where the socket goes is not removed.
        let file = h.folder.appendingPathComponent("f.sock")
        try Data("x".utf8).write(to: file)
        let onFile = HookRequestBroker(url: file, onRequest: { _ in }, onEnded: { _ in })
        #expect(throws: HookRequestBrokerError.inUse(path: file.path)) { try onFile.start() }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
