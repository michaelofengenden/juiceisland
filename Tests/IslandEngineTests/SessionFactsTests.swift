import Foundation
import IslandHookNotes
import Testing
@testable import IslandEngine
import OpenIslandCore

/// The rows lane's engine side (P310-P312): a session's model, mode and task progress as the agents report them, when it
/// last showed a sign of life, and the peek's bounded read of a Claude transcript's tail. Fictional ids and folders.
@MainActor
struct SessionFactsTests {
    typealias Box = EngineFixtures.Box
    static let path = "/tmp/juice-island-test/projects/-tmp-project/s1.jsonl"

    private func started(_ id: String = "s1", tool: AgentTool = .claudeCode, metadata: ClaudeSessionMetadata? = nil,
                         at date: Date = EngineFixtures.now) -> [AgentEvent] {
        [.sessionStarted(SessionStarted(
            sessionID: id, title: "Claude · project", tool: tool, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: date, jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project", paneTitle: "claude",
                                                    workingDirectory: "/tmp/project"),
            claudeMetadata: metadata ?? ClaudeSessionMetadata(transcriptPath: Self.path))),
         .activityUpdated(SessionActivityUpdated(sessionID: id, summary: SignalPipeline.promptPrefix + "fix the login", phase: .running,
                                                 timestamp: date + 1))]
    }

    // MARK: Codex's rollout

    /// `turn_context.model` and `update_plan`'s steps are read beside the rollout fold; each change is one
    /// `.factsChanged` (so the tracker hands the state on, P310), the same model or plan again is none.
    @Test
    func codexsModelAndPlanComeFromItsRollout() throws {
        var attention = CodexAttention()
        attention.apply(RolloutFixtures.meta())
        attention.apply(RolloutFixtures.line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6-astra",
                                                              "approval_policy": "on-request"], at: 1))
        #expect(attention.model == "gpt-6-astra")
        #expect(attention.takeEvents().filter { $0 == .factsChanged }.count == 1)
        attention.apply(RolloutFixtures.line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6-astra",
                                                              "approval_policy": "on-request"], at: 2))
        #expect(!attention.takeEvents().contains(.factsChanged))
        let plan: [[String: String]] = [["step": "a", "status": "completed"], ["step": "b", "status": "in_progress"],
                                        ["step": "c", "status": "pending"]]
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["plan": plan]), as: UTF8.self)
        attention.apply(RolloutFixtures.item("function_call", ["name": "update_plan", "arguments": arguments, "call_id": "p1"], at: 3))
        #expect(attention.plan == TaskProgress(done: 1, total: 3))
        #expect(attention.takeEvents().contains(.factsChanged))
        // A model id too long to be a name is not kept.
        attention.apply(RolloutFixtures.line("turn_context", ["model": String(repeating: "x", count: 200)], at: 4))
        #expect(attention.model == "gpt-6-astra")
    }

    /// Through the tracker's path on the engine: the Codex row's facts are its rollout's model and plan.
    @Test
    func aCodexSessionsFactsAreItsRollouts() throws {
        let engine = SessionEngine.preview(clock: { EngineFixtures.now + 60 })
        let rollout = "/tmp/juice-island-test/sessions/rollout-c1.jsonl"
        engine.loadPreviewEvents([.sessionStarted(SessionStarted(
            sessionID: "c1", title: "Codex · project", tool: .codex, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: EngineFixtures.now, jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project", paneTitle: "codex",
                                                                  workingDirectory: "/tmp/project"),
            codexMetadata: CodexSessionMetadata(transcriptPath: rollout, lastUserPrompt: "move the settings")))])
        let plan: [[String: String]] = [["step": "a", "status": "completed"], ["step": "b", "status": "completed"],
                                        ["step": "c", "status": "pending"], ["step": "d", "status": "pending"]]
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["plan": plan]), as: UTF8.self)
        engine.loadPreviewRollout(sessionID: "c1", transcriptPath: rollout, lines: [
            RolloutFixtures.meta(id: "c1"),
            RolloutFixtures.line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6-astra", "approval_policy": "on-request"], at: 1),
            RolloutFixtures.event("user_message", ["message": "move the settings", "images": []], at: 1),
            RolloutFixtures.event("task_started", [:], at: 2),
            RolloutFixtures.item("function_call", ["name": "update_plan", "arguments": arguments, "call_id": "p1"], at: 3),
        ])
        let session = try #require(engine.state.session(id: "c1"))
        #expect(engine.facts(for: session) == SessionFacts(model: "gpt-6-astra", mode: nil, tasks: TaskProgress(done: 2, total: 4)))
    }

    // MARK: Claude's hooks and notes

    /// Claude's model and mode from its hooks (upstream's metadata), its tasks from TaskCreate/TaskUpdate; a context note's
    /// `permission_mode` (the session's own hook's) is the newer word on the mode, a subagent's note never is.
    @Test
    func claudesFactsComeFromItsHooksAndNotes() throws {
        let engine = EngineFixtures.engine()
        let metadata = ClaudeSessionMetadata(transcriptPath: Self.path, model: "claude-opus-5-5[1m]", permissionMode: .acceptEdits,
                                             activeTasks: [ClaudeTaskInfo(id: "1", title: "a", status: .completed), ClaudeTaskInfo(id: "2", title: "b")])
        for event in started(metadata: metadata) { engine.ingest(event, ingress: .bridge) }
        var session = try #require(engine.state.session(id: "s1"))
        #expect(engine.facts(for: session) == SessionFacts(model: "claude-opus-5-5[1m]", mode: "acceptEdits", tasks: TaskProgress(done: 1, total: 2)))
        engine.ingest(note: HookContextNote(event: "PreToolUse", sessionID: "s1", agentID: "agent-1", permissionMode: "bypassPermissions"))
        session = try #require(engine.state.session(id: "s1"))
        #expect(engine.facts(for: session).mode == "acceptEdits")
        engine.ingest(note: HookContextNote(event: "UserPromptSubmit", sessionID: "s1", permissionMode: "plan"))
        #expect(engine.facts(for: session).mode == "plan")
        #expect(engine.facts(for: session).tasks?.isOpen == true)
        #expect(TaskProgress(done: 2, total: 2).isOpen == false)
    }

    /// A stall is measured from the later of the session's last event and its last context note (P312).
    @Test
    func lastActivityIsTheLaterOfTheLastEventAndTheLastNote() throws {
        let clock = Box(EngineFixtures.now)
        let engine = EngineFixtures.engine(clock: clock)
        for event in started() { engine.ingest(event, ingress: .bridge) }
        let session = try #require(engine.state.session(id: "s1"))
        #expect(engine.lastActivity(for: session) == EngineFixtures.now + 1)
        clock.update { $0 = EngineFixtures.now + 300 }
        engine.ingest(note: HookContextNote(event: "PreToolUse", sessionID: "s1", toolName: "Bash"))
        #expect(engine.lastActivity(for: session) == EngineFixtures.now + 300)
    }

    // MARK: The peek's read

    /// A peek reads the tail it is given, off the main thread, and the model the tail names becomes the session's until
    /// its next start (a `/model` switch reaches no hook). Only a Claude session is read.
    @Test
    func aPeeksReadNamesTheModelUntilTheNextStart() async throws {
        let reads = Box<[String]>([])
        let engine = EngineFixtures.engine(configure: { dependencies in
            dependencies.readPeek = { path in
                reads.update { $0.append(path) }
                return SessionPeekRead(prompt: "fix the login", reply: "Looking at the redirect.", model: "claude-sonnet-4-5")
            }
        })
        for event in started(metadata: ClaudeSessionMetadata(transcriptPath: Self.path, model: "claude-opus-5-5")) {
            engine.ingest(event, ingress: .bridge)
        }
        let read = try #require(await engine.readPeek(sessionID: "s1"))
        #expect(read.reply == "Looking at the redirect.")
        #expect(reads.current == [Self.path])
        let session = try #require(engine.state.session(id: "s1"))
        #expect(engine.facts(for: session).model == "claude-sonnet-4-5")
        engine.ingest(.sessionStarted(SessionStarted(
            sessionID: "s1", title: "Claude · project", tool: .claudeCode, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: EngineFixtures.now + 5, claudeMetadata: ClaudeSessionMetadata(transcriptPath: Self.path, model: "claude-opus-5-5",
                                                                                   startupSource: .resume))), ingress: .bridge)
        #expect(engine.facts(for: try #require(engine.state.session(id: "s1"))).model == "claude-opus-5-5")
        // A Codex session has no peek read: its rollout keeps its metadata current.
        for event in started("c1", tool: .codex, metadata: nil) { engine.ingest(event, ingress: .bridge) }
        #expect(await engine.readPeek(sessionID: "c1") == nil)
        #expect(reads.current.count == 1)
    }
}

/// `SessionPeekReader` (P311): one bounded read of a Claude transcript's tail, folded as the launch scan folds it.
struct SessionPeekReaderTests {
    static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func user(_ text: String, extra: [String: Any] = [:]) -> String {
        line(["type": "user", "message": ["role": "user", "content": text]].merging(extra) { $1 })
    }

    static func assistant(_ text: String, model: String = "claude-opus-5-5") -> String {
        line(["type": "assistant", "message": ["role": "assistant", "model": model, "content": [["type": "text", "text": text]]]])
    }

    static func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> String {
        line(["type": "assistant", "message": ["role": "assistant", "model": "claude-opus-5-5",
                                               "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
    }

    /// A reply counts only after the last prompt; machine text is never a prompt, Claude Code's own synthetic replies
    /// never a reply; a tool still waiting on its result is the tool.
    @Test
    func theTailIsFoldedAsTheLaunchFoldsIt() {
        let lines = [
            Self.user("first question"),
            Self.assistant("An earlier answer."),
            Self.user("fix the login redirect"),
            Self.user("<task-notification>done</task-notification>", extra: ["origin": ["kind": "task-notification"]]),
            Self.user("Caveat: meta", extra: ["isMeta": true]),
            Self.assistant("Looking at the redirect first."),
            Self.assistant("No response requested.", model: "<synthetic>"),
            Self.toolUse("toolu_1", "Bash", ["command": "npm test"]),
        ]
        let peek = SessionPeekReader.fold(Data(lines.joined(separator: "\n").utf8), cut: false)
        #expect(peek.prompt == "fix the login redirect")
        #expect(peek.reply == "Looking at the redirect first.")
        #expect(peek.tool == "Bash")
        #expect(peek.model == "claude-opus-5-5")
        // A turn that has said nothing yet shows no earlier turn's reply as its own.
        let fresh = SessionPeekReader.fold(Data((lines + [Self.user("now the logout")]).joined(separator: "\n").utf8), cut: false)
        #expect(fresh.prompt == "now the logout")
        #expect(fresh.reply == nil)
    }

    /// A prompt the owner sends again ("continue", "yes") starts its turn afresh: the turn before's reply is never the
    /// new turn's, and the new turn's reply counts even when it says the same words.
    @Test
    func aRepeatedPromptStartsItsTurnAfresh() {
        let turn = [Self.user("continue"), Self.assistant("Done: 3 files changed.")]
        let again = SessionPeekReader.fold(Data((turn + [Self.user("continue")]).joined(separator: "\n").utf8), cut: false)
        #expect(again.prompt == "continue")
        #expect(again.reply == nil)
        let said = SessionPeekReader.fold(Data((turn + turn).joined(separator: "\n").utf8), cut: false)
        #expect(said.reply == "Done: 3 files changed.")
    }

    /// The read is the window and one byte, whatever the file's size, and skips the line the window cuts; a path outside
    /// a `projects` folder, or not a `.jsonl`, is never opened.
    @Test
    func theReadIsBoundedAndSkipsACutLine() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("juice-peek-\(UUID().uuidString)/projects/-tmp-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let file = folder.appendingPathComponent("s1.jsonl")
        var text = ""
        let filler = Self.assistant(String(repeating: "filler ", count: 200))
        while text.utf8.count < 1_000_000 { text += filler + "\n" }
        text += Self.user("fix the login redirect") + "\n" + Self.assistant("Looking at the redirect first.") + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let read = try #require(SessionPeekReader.read(path: file.path))
        #expect(read.bytes == SessionPeekReader.window + 1)
        #expect(read.peek.prompt == "fix the login redirect")
        #expect(read.peek.reply == "Looking at the redirect first.")
        let outside = folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("notes.jsonl")
        try text.write(to: outside, atomically: true, encoding: .utf8)
        #expect(SessionPeekReader.read(path: outside.path) == nil)
    }
}
