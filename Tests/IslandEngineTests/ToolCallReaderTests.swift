import Foundation
@testable import IslandEngine
@testable import OpenIslandCore
import Testing

/// The tool call a waiting approval is about, read from its Claude transcript (`ToolCallReader`), and the engine's
/// reads around it. Transcripts are fixtures written to a temporary `projects` folder; nothing else is opened.
@Suite(.serialized)
struct ToolCallReaderTests {
    static let push: ClaudeHookJSONValue = .object(["command": .string("git push -u origin window-mode"),
                                                    "description": .string("Push the branch")])

    /// A transcript's assistant line holding one `tool_use`, as Claude Code writes it (compact JSON).
    static func toolUseLine(id: String, name: String, input: ClaudeHookJSONValue) -> String {
        line(["type": .string("assistant"), "message": .object([
            "role": .string("assistant"),
            "content": .array([.object(["type": .string("tool_use"), "id": .string(id), "name": .string(name), "input": input])]),
        ])])
    }

    static func toolResultLine(id: String) -> String {
        line(["type": .string("user"), "message": .object([
            "role": .string("user"),
            "content": .array([.object(["type": .string("tool_result"), "tool_use_id": .string(id), "content": .string("ok")])]),
        ])])
    }

    static func textLine(_ text: String) -> String {
        line(["type": .string("assistant"), "message": .object([
            "role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ])])
    }

    static func line(_ object: [String: ClaudeHookJSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(ClaudeHookJSONValue.object(object)), as: UTF8.self)
    }

    /// A transcript at `<temp>/projects/-tmp-project/<uuid>.jsonl`.
    static func transcript(_ lines: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-island-toolcalls-\(UUID().uuidString)/projects/-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    static func query(_ url: URL?, id: String?, tool: String = "Bash", preview: String = "") -> ToolCallQuery {
        ToolCallQuery(transcriptPath: url?.path, toolUseID: id, toolName: tool, preview: preview)
    }

    // MARK: Upstream's preview

    /// Hook payloads as Claude sends them, decoded by upstream: our preview is upstream's `affectedPath`, so a call
    /// with no id is matched as upstream showed it.
    @Test func thePreviewIsUpstreamsAffectedPath() throws {
        let inputs: [(String, ClaudeHookJSONValue)] = [
            ("Bash", Self.push),
            ("Bash", .object(["command": .string("git commit -m \"$(cat <<'EOF'\nA long message\n\nwith a body that runs well past the 110 characters upstream keeps of it\nEOF\n)\"")])),
            ("Edit", .object(["file_path": .string("/tmp/project/a.swift"), "old_string": .string("a"), "new_string": .string("b")])),
            ("Write", .object(["file_path": .string("/tmp/project/b.md"), "content": .string("# B\n")])),
            ("WebFetch", .object(["url": .string("https://example.com/docs"), "prompt": .string("Summarise it")])),
            ("Grep", .object(["pattern": .string("TODO"), "path": .string("/tmp/project/App")])),
            ("ExitPlanMode", .object(["plan": .string("1. One\n2. Two")])),
            ("mcp__docs__search", .object(["query": .array([.string("a"), .number(2)]), "limit": .number(5), "strict": .boolean(true)])),
            ("Task", .object(["description": .string("Look around"), "prompt": .string("Find the card views"), "subagent_type": .string("general")])),
        ]
        for (tool, input) in inputs {
            let payload = try Self.claudePayload(tool: tool, input: input)
            #expect(ToolCallPreview.affectedPath(of: input) == payload.permissionAffectedPath, "\(tool)")
        }
    }

    static func claudePayload(tool: String, input: ClaudeHookJSONValue, id: String? = "toolu_x") throws -> ClaudeHookPayload {
        var object: [String: ClaudeHookJSONValue] = [
            "hook_event_name": .string("PermissionRequest"), "session_id": .string("s1"), "cwd": .string("/tmp/project"),
            "transcript_path": .string("/tmp/projects/-tmp-project/s1.jsonl"), "tool_name": .string(tool), "tool_input": input,
        ]
        if let id { object["tool_use_id"] = .string(id) }
        return try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(line(object).utf8))
    }

    // MARK: Reading

    @Test func theCallIsFoundByItsIDAmongTheLastLines() throws {
        let url = try Self.transcript((0..<50).map { Self.textLine("filler \($0)") }
            + [Self.toolUseLine(id: "toolu_1", name: "Bash", input: Self.push)] + [Self.textLine("after")])
        #expect(ToolCallReader.read(Self.query(url, id: "toolu_1")) == Self.push)
        #expect(ToolCallReader.read(Self.query(url, id: "toolu_2")) == nil)
    }

    @Test func aCallOfSeveralBlocksIsFoundByItsOwnID() throws {
        let other: ClaudeHookJSONValue = .object(["command": .string("ls")])
        let line = Self.line(["type": .string("assistant"), "message": .object(["content": .array([
            .object(["type": .string("tool_use"), "id": .string("toolu_a"), "name": .string("Bash"), "input": other]),
            .object(["type": .string("tool_use"), "id": .string("toolu_b"), "name": .string("Bash"), "input": Self.push]),
        ])])])
        let url = try Self.transcript([line])
        #expect(ToolCallReader.read(Self.query(url, id: "toolu_a")) == other)
        #expect(ToolCallReader.read(Self.query(url, id: "toolu_b")) == Self.push)
    }

    /// A Write of a large file: its line begins before the last 256 KB, so the reader reads the last 4 MB once.
    @Test func aCallBeforeTheWindowIsReadFromTheWiderWindow() throws {
        let content = String(repeating: "x", count: 300 * 1024)
        let write: ClaudeHookJSONValue = .object(["file_path": .string("/tmp/project/big.txt"), "content": .string(content)])
        let url = try Self.transcript([Self.textLine("start"), Self.toolUseLine(id: "toolu_big", name: "Write", input: write)])
        #expect(ToolCallReader.read(Self.query(url, id: "toolu_big", tool: "Write")) == write)
    }

    /// A call whose line starts on the window's first byte is read from the window itself.
    @Test func aCallStartingOnTheWindowsFirstByteIsRead() throws {
        let stub = Self.toolUseLine(id: "toolu_edge", name: "Write", input: .object(["file_path": .string("/tmp/project/a.txt"),
                                                                                       "content": .string("")]))
        let pad = ToolCallReader.window - 1 - stub.utf8.count
        let input: ClaudeHookJSONValue = .object(["file_path": .string("/tmp/project/a.txt"), "content": .string(String(repeating: "y", count: pad))])
        let line = Self.toolUseLine(id: "toolu_edge", name: "Write", input: input)
        #expect(line.utf8.count + 1 == ToolCallReader.window)
        let url = try Self.transcript([Self.textLine(String(repeating: "z", count: 40 * 1024)), line])
        #expect(ToolCallReader.read(Self.query(url, id: "toolu_edge", tool: "Write")) == input)
    }

    /// Past the wider window nothing more is read: the card keeps what the request carries.
    @Test func aCallBeyondTheWiderWindowIsNotRead() throws {
        let content = String(repeating: "x", count: 5 * 1024 * 1024)
        let write: ClaudeHookJSONValue = .object(["file_path": .string("/tmp/project/huge.txt"), "content": .string(content)])
        let url = try Self.transcript([Self.toolUseLine(id: "toolu_huge", name: "Write", input: write)])
        #expect(ToolCallReader.read(Self.query(url, id: "toolu_huge", tool: "Write")) == nil)
    }

    /// With no id (no PreToolUse hook saw the call): the newest call of the tool that upstream would show as the
    /// request does and that has no result yet. An earlier call with the same first 109 characters ran already.
    @Test func withNoIDTheWaitingCallIsTheOneWithNoResult() throws {
        let stem = "python3 scripts/publish.py --target " + String(repeating: "dashboard/", count: 10)
        let earlier: ClaudeHookJSONValue = .object(["command": .string(stem + " --dry-run")])
        let waiting: ClaudeHookJSONValue = .object(["command": .string(stem + " --execute")])
        let preview = try #require(ToolCallPreview.affectedPath(of: waiting))
        #expect(preview == ToolCallPreview.affectedPath(of: earlier) && preview.hasSuffix("…"))

        let ran = [Self.toolUseLine(id: "toolu_old", name: "Bash", input: earlier), Self.toolResultLine(id: "toolu_old")]
        let url = try Self.transcript(ran + [Self.toolUseLine(id: "toolu_new", name: "Bash", input: waiting)])
        #expect(ToolCallReader.read(Self.query(url, id: nil, preview: preview)) == waiting)

        // The waiting call not written yet: the one that ran is never taken for it.
        let lagging = try Self.transcript(ran)
        #expect(ToolCallReader.read(Self.query(lagging, id: nil, preview: preview)) == nil)
        // Another tool, or another preview, is not the call either.
        #expect(ToolCallReader.read(Self.query(url, id: nil, tool: "Edit", preview: preview)) == nil)
        #expect(ToolCallReader.read(Self.query(url, id: nil, preview: "rm -rf build")) == nil)
    }

    /// Only a `.jsonl` file under a `projects` folder, not a link, is ever opened.
    @Test func onlyATranscriptIsOpened() throws {
        let url = try Self.transcript([Self.toolUseLine(id: "toolu_1", name: "Bash", input: Self.push)])
        #expect(ToolCallReader.isTranscript(url.path))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("juice-island-toolcalls-\(UUID().uuidString).jsonl")
        try FileManager.default.copyItem(at: url, to: outside)
        #expect(!ToolCallReader.isTranscript(outside.path))
        #expect(ToolCallReader.read(Self.query(outside, id: "toolu_1")) == nil)
        let link = url.deletingLastPathComponent().appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(ToolCallReader.read(Self.query(link, id: "toolu_1")) == nil)
        let text = url.deletingPathExtension().appendingPathExtension("txt")
        try FileManager.default.copyItem(at: url, to: text)
        #expect(ToolCallReader.read(Self.query(text, id: "toolu_1")) == nil)
        #expect(!ToolCallReader.isTranscript("relative/projects/a.jsonl"))
        #expect(!ToolCallReader.isTranscript(url.deletingLastPathComponent().path + "/../x/projects/a.jsonl"))
        #expect(ToolCallReader.read(Self.query(nil, id: "toolu_1")) == nil)
    }

    // MARK: The engine

    static func claudeApproval(_ id: String, requestID: UUID = UUID(), useID: String? = "toolu_1") -> AgentEvent {
        .permissionRequested(PermissionRequested(sessionID: id, request: PermissionRequest(
            id: requestID, title: "Allow Bash", summary: "Claude Code wants to run Bash.", affectedPath: "git push -u origin window-mode",
            primaryActionTitle: "Allow Once", secondaryActionTitle: "Deny", toolName: "Bash", toolUseID: useID), timestamp: EngineFixtures.now))
    }

    @MainActor
    static func engine(reads: EngineFixtures.Box<[ToolCallQuery]>, answer: @escaping @Sendable (Int) -> ClaudeHookJSONValue?) -> SessionEngine {
        let engine = EngineFixtures.engine()
        var dependencies = engine.dependencies
        dependencies.toolCallReads = ToolCallReads(read: { query in
            var count = 0
            reads.update { $0.append(query); count = $0.count }
            return answer(count)
        }, waits: [.zero, .milliseconds(5), .milliseconds(5), .milliseconds(10)])
        return SessionEngine(configuration: engine.configuration, dependencies: dependencies)
    }

    @MainActor
    static func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// The transcript lags the hook: the engine reads again until the call is there, off the main thread, and the
    /// input goes with the approval it was read for.
    @MainActor
    @Test func anApprovalReadsItsCallUntilItIsThereAndDropsItWhenAnswered() async {
        let reads = EngineFixtures.Box<[ToolCallQuery]>([])
        let engine = Self.engine(reads: reads) { $0 >= 3 ? Self.push : nil }
        engine.ingest(EngineFixtures.started("s1", transcript: "/tmp/projects/-tmp-project/s1.jsonl"), ingress: .bridge)
        engine.ingest(EngineFixtures.prompt("s1"), ingress: .bridge)
        engine.ingest(Self.claudeApproval("s1"), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(engine.toolCallInput(for: "s1") == nil)
        await Self.settle { engine.toolCallInput(for: "s1") != nil }
        #expect(engine.toolCallInput(for: "s1") == Self.push)
        #expect(reads.current.count == 3)
        #expect(reads.current.first == ToolCallQuery(transcriptPath: "/tmp/projects/-tmp-project/s1.jsonl", toolUseID: "toolu_1",
                                                     toolName: "Bash", preview: "git push -u origin window-mode"))

        await engine.approve(sessionID: "s1", decision: .allowOnce)
        #expect(engine.toolCallInput(for: "s1") == nil)
        #expect(engine.toolCalls.isEmpty)
    }

    /// Four reads at most, the last 1 s after the request, then the card keeps what the request carries.
    @MainActor
    @Test func aCallNeverFoundIsReadFourTimes() async {
        let reads = EngineFixtures.Box<[ToolCallQuery]>([])
        let engine = Self.engine(reads: reads) { _ in nil }
        engine.ingest(EngineFixtures.started("s1", transcript: "/tmp/projects/-tmp-project/s1.jsonl"), ingress: .bridge)
        engine.ingest(Self.claudeApproval("s1"), ingress: .bridge)
        engine.passAttentionWindows()
        await Self.settle { engine.toolCallTasks.isEmpty }
        #expect(reads.current.count == 4)
        #expect(engine.toolCallInput(for: "s1") == nil)
        #expect(ToolCallReads.transcript.waits == [.zero, .milliseconds(250), .milliseconds(250), .milliseconds(500)])
    }

    /// Codex's request carries its whole command: nothing is read.
    @MainActor
    @Test func aCodexApprovalReadsNothing() async {
        let reads = EngineFixtures.Box<[ToolCallQuery]>([])
        let engine = Self.engine(reads: reads) { _ in Self.push }
        engine.ingest(EngineFixtures.started("c1", tool: .codex, transcript: "/tmp/sessions/rollout.jsonl"), ingress: .bridge)
        engine.ingest(Self.claudeApproval("c1"), ingress: .bridge)
        engine.passAttentionWindows()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(reads.current.isEmpty)
        #expect(engine.toolCallInput(for: "c1") == nil)
    }

    /// P114 with P126: an approval whose session the monitor drops with no event of its own (its process gone) takes
    /// the call read for it along at the engine's upkeep, as it does the rest of the session's bookkeeping.
    @MainActor
    @Test func aDroppedSessionsCallGoesWithItsBookkeeping() {
        let clock = EngineFixtures.Box(EngineFixtures.now)
        let base = EngineFixtures.engine(clock: clock)
        var dependencies = base.dependencies
        dependencies.toolCallReads = ToolCallReads(read: { _ in Self.push }, waits: nil)
        let engine = SessionEngine(configuration: base.configuration, dependencies: dependencies)
        let id = SessionEngine.syntheticClaudeSessionPrefix + "1"
        engine.ingest(EngineFixtures.started(id, transcript: "/tmp/projects/-tmp-project/s1.jsonl"), ingress: .bridge)
        engine.ingest(Self.claudeApproval(id), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(engine.toolCalls[id] != nil)
        for _ in 0..<2 {
            clock.update { $0 += 700 }
            engine.applyMonitoredState(SessionState())
        }
        #expect(engine.state.sessions.isEmpty)
        #expect(engine.toolCalls.isEmpty && engine.bookkeptSessionIDs.isEmpty)
    }

    /// A newer request replaces the older one's reads; what was read for the older one is never shown for it.
    @MainActor
    @Test func aNewRequestStartsAfresh() async {
        let reads = EngineFixtures.Box<[ToolCallQuery]>([])
        let engine = Self.engine(reads: reads) { _ in Self.push }
        engine.ingest(EngineFixtures.started("s1", transcript: "/tmp/projects/-tmp-project/s1.jsonl"), ingress: .bridge)
        engine.ingest(Self.claudeApproval("s1", useID: "toolu_1"), ingress: .bridge)
        engine.passAttentionWindows()
        await Self.settle { engine.toolCallInput(for: "s1") != nil }
        let second = UUID()
        engine.ingest(Self.claudeApproval("s1", requestID: second, useID: "toolu_2"), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(engine.toolCallInput(for: "s1") == nil)
        await Self.settle { engine.toolCallInput(for: "s1") != nil }
        #expect(engine.toolCalls["s1"]?.requestID == second)
        #expect(reads.current.map(\.toolUseID) == ["toolu_1", "toolu_2"])
    }
}
