import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Live work for the peek (P720 to P723): Codex's reasoning summary and plan steps from its rollout, Claude's task list
/// from its hooks and its `TodoWrite` list from its transcript's tail, every text bounded, nothing kept but in memory.
@MainActor
@Suite(.serialized)
struct SessionWorkTests {
    typealias F = RolloutFixtures
    typealias Box = EngineFixtures.Box

    static func plan(_ steps: [(String, String)]) -> String {
        let plan = steps.map { ["step": $0.0, "status": $0.1] }
        let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: ["plan": plan], options: [.sortedKeys]), as: UTF8.self)
        return F.item("function_call", ["name": "update_plan", "arguments": arguments, "call_id": "p1"], at: 3)
    }

    // MARK: The summary's words

    /// Codex's summary: its bold first line is the title, the rest the text, whitespace collapsed, each bounded.
    @Test
    func aSummaryIsItsTitleAndItsText() {
        #expect(SessionWork.thinking("**Checking the keys**\n\nThe store reads   both.") ==
                SessionWork.Thinking(title: "Checking the keys", text: "The store reads both."))
        #expect(SessionWork.thinking("**Only a title**") == SessionWork.Thinking(title: "Only a title", text: nil))
        #expect(SessionWork.thinking("No title, **some** bold.") == SessionWork.Thinking(title: nil, text: "No title, some bold."))
        #expect(SessionWork.thinking("  \n ") == nil)
        #expect(SessionWork.thinking(nil) == nil)
        let long = SessionWork.thinking("**" + String(repeating: "t", count: 300) + "**" + String(repeating: "w ", count: 400))
        #expect(long?.title?.count == SessionWork.titleLimit)
        #expect(long?.text?.count ?? 0 <= SessionWork.thinkingLimit)
        #expect(long?.text?.hasSuffix("…") == true)
    }

    /// Statuses as every agent writes them; a step with no text goes; at most `stepLimit` steps of `stepTextLimit`.
    @Test
    func stepsAreBounded() {
        #expect(SessionWork.state("completed") == .done)
        #expect(SessionWork.state("in_progress") == .current)
        #expect(SessionWork.state("pending") == .pending)
        #expect(SessionWork.state("blocked") == .pending)
        let many = (0..<200).map { ["step": "step \($0) " + String(repeating: "x", count: 400), "status": "pending"] }
        let steps = SessionWork.steps(plan: many + [["status": "pending"]]) ?? []
        #expect(steps.count == SessionWork.stepLimit)
        #expect(steps.allSatisfy { $0.text.count <= SessionWork.stepTextLimit })
        #expect(SessionWork.steps(plan: "not a plan") == nil)
        #expect(SessionWork(steps: [.init("a", .done)]).hasOpenSteps == false)
        #expect(SessionWork(steps: [.init("a", .done), .init("b", .pending)]).hasOpenSteps)
    }

    // MARK: Codex's rollout

    /// The fold: a summary (the event or the reasoning item's own `summary_text`) is what Codex thinks until its next
    /// message or turn; a plan's steps stay until the next plan.
    @Test
    func theFoldFollowsTheTurn() {
        var fold = CodexWorkFold()
        fold.apply(F.event("task_started", at: 1))
        fold.apply(Self.plan([("Find the reads", "completed"), ("Add the store", "in_progress"), ("Move the reads", "pending")]))
        #expect(fold.work.steps == [.init("Find the reads", .done), .init("Add the store", .current), .init("Move the reads", .pending)])
        fold.apply(F.event("agent_reasoning", ["text": "**Reading the store**\n\nIt keeps two caches."], at: 4))
        #expect(fold.work.thinking == SessionWork.Thinking(title: "Reading the store", text: "It keeps two caches."))
        // The reasoning item says the same; one with no summary says nothing.
        fold.apply(F.item("reasoning", ["summary": [], "encrypted_content": "e30="], at: 5))
        #expect(fold.work.thinking?.title == "Reading the store")
        fold.apply(F.item("reasoning", ["summary": [["type": "summary_text", "text": "**Next file**"]], "encrypted_content": "e30="], at: 6))
        #expect(fold.work.thinking == SessionWork.Thinking(title: "Next file", text: nil))
        // A message is newer than the thought: the thought goes, the plan stays.
        fold.apply(F.message("assistant", "Moved the reads.", at: 7))
        #expect(fold.work.thinking == nil)
        fold.apply(F.event("agent_reasoning", ["text": "**Running the tests**"], at: 8))
        fold.apply(F.event("task_complete", ["last_agent_message": "Done."], at: 9))
        #expect(fold.work.thinking == nil)
        #expect(fold.work.steps.count == 3)
        // Lines with none of its markers are never parsed; a raw-content line is not a summary.
        fold.apply(F.event("agent_reasoning_raw_content", ["text": "raw chain"], at: 10))
        #expect(fold.work.thinking == nil)
        #expect(CodexWorkFold.mayMatter(F.event("token_count", at: 11)) == false)
    }

    /// The tracker hands a chat's work on when a read changed it, and only then; the bootstrap of a long rollout reads
    /// the plan before its first window.
    @Test
    func theTrackerHandsWorkOnWhenItChanges() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text([F.meta(), F.event("task_started", at: 1)]).write(to: url, atomically: true, encoding: .utf8)
        let handed = Box<[SessionWork]>([])
        let tracker = CodexRolloutTracker(pollInterval: 60)
        defer { tracker.stop() }
        tracker.workHandler = { id, work in
            #expect(id == F.sessionID)
            handed.update { $0.append(work) }
        }
        tracker.sync(targets: [CodexRolloutWatchTarget(sessionID: F.sessionID, transcriptPath: url.path)])
        tracker.waitUntilIdle()
        #expect(handed.current.isEmpty)
        F.append(F.text([Self.plan([("a", "completed"), ("b", "pending")]),
                         F.event("agent_reasoning", ["text": "**Thinking about b**"], at: 4)]), to: url)
        tracker.pollNow(sessionID: F.sessionID)
        tracker.waitUntilIdle()
        #expect(handed.current.count == 1)
        #expect(handed.current.last?.thinking?.title == "Thinking about b")
        // A read that changes nothing of it hands nothing on.
        F.append(F.text([F.event("token_count", at: 5)]), to: url)
        tracker.pollNow(sessionID: F.sessionID)
        tracker.waitUntilIdle()
        #expect(handed.current.count == 1)
        F.append(F.text([F.event("agent_message", ["message": "b is next."], at: 6)]), to: url)
        tracker.pollNow(sessionID: F.sessionID)
        tracker.waitUntilIdle()
        #expect(handed.current.count == 2)
        #expect(handed.current.last?.thinking == nil)
        #expect(handed.current.last?.steps.count == 2)
    }

    @Test
    func aLongRolloutsPlanIsReadBeforeItsFirstWindow() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        let filler = (0..<300).map { F.event("token_count", ["info": ["note": String(repeating: "f", count: 600)]], at: 10 + $0 % 50) }
        try F.text([F.meta(), F.event("task_started", at: 1), Self.plan([("a", "in_progress"), ("b", "pending")])] + filler)
            .write(to: url, atomically: true, encoding: .utf8)
        let handed = Box<[SessionWork]>([])
        let tracker = CodexRolloutTracker(pollInterval: 60, initialReadLimit: 64 * 1_024)
        defer { tracker.stop() }
        tracker.workHandler = { _, work in handed.update { $0.append(work) } }
        tracker.sync(targets: [CodexRolloutWatchTarget(sessionID: F.sessionID, transcriptPath: url.path)])
        tracker.waitUntilIdle()
        #expect(handed.current.last?.steps == [.init("a", .current), .init("b", .pending)])
    }

    /// Through the engine: a Codex chat's work is its rollout's; it goes with the session; no row reads it.
    @Test
    func aCodexChatsWorkIsItsRollouts() throws {
        let engine = SessionEngine.preview(clock: { EngineFixtures.now + 60 })
        let rollout = "/tmp/juice-island-test/sessions/rollout-c1.jsonl"
        engine.loadPreviewEvents([.sessionStarted(SessionStarted(
            sessionID: "c1", title: "Codex · project", tool: .codex, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: EngineFixtures.now, jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project", paneTitle: "codex",
                                                                  workingDirectory: "/tmp/project"),
            codexMetadata: CodexSessionMetadata(transcriptPath: rollout, lastUserPrompt: "move the settings")))])
        engine.loadPreviewRollout(sessionID: "c1", transcriptPath: rollout, lines: [
            F.meta(id: "c1"),
            F.event("task_started", at: 2),
            Self.plan([("a", "completed"), ("b", "in_progress")]),
            F.event("agent_reasoning", ["text": "**Weighing b**\n\nTwo ways."], at: 4),
        ])
        let work = try #require(engine.work(for: "c1"))
        #expect(work.thinking == SessionWork.Thinking(title: "Weighing b", text: "Two ways."))
        #expect(work.steps == [.init("a", .done), .init("b", .current)])
        engine.takeCodexWork("gone", work)
        #expect(engine.codexWork["gone"] == nil)
        engine.forgetAttention("c1")
        #expect(engine.work(for: "c1") == nil)
    }

    // MARK: Claude

    /// Claude's task list from its hooks (`TaskCreate`, `TaskUpdate`), as the row's "2/5" counts it.
    @Test
    func claudesWorkIsItsTaskList() throws {
        let engine = EngineFixtures.engine()
        let metadata = ClaudeSessionMetadata(transcriptPath: "/tmp/juice-island-test/projects/p/s1.jsonl", activeTasks: [
            ClaudeTaskInfo(id: "1", title: "Read the index", status: .completed),
            ClaudeTaskInfo(id: "2", title: "Pick the tokenizer", status: .inProgress),
            ClaudeTaskInfo(id: "3", title: "Write the plan"),
        ])
        engine.ingest(.sessionStarted(SessionStarted(sessionID: "s1", title: "Claude", tool: .claudeCode, origin: .live,
                                                     initialPhase: .running, summary: "Started.", timestamp: EngineFixtures.now,
                                                     claudeMetadata: metadata)), ingress: .bridge)
        #expect(engine.work(for: "s1")?.steps == [.init("Read the index", .done), .init("Pick the tokenizer", .current),
                                                   .init("Write the plan", .pending)])
        #expect(engine.work(for: "s1")?.thinking == nil)
        #expect(engine.work(for: "nobody") == nil)
    }

    /// The peek's tail read takes the latest `TodoWrite` list, bounded; a later empty list clears it; a line that only
    /// names the tool in its text is no call.
    @Test
    func theTailsLatestTodoListIsRead() {
        typealias T = SessionPeekReaderTests
        let first = T.toolUse("t1", "TodoWrite", ["todos": [["content": "Old step", "status": "pending", "activeForm": "Doing it"]]])
        let second = T.toolUse("t2", "TodoWrite", ["todos": [
            ["content": "Read the redirect", "status": "completed", "activeForm": "Reading"],
            ["content": "Fix the guard", "status": "in_progress", "activeForm": "Fixing the guard"],
            ["content": "Add a test", "status": "pending", "activeForm": "Adding a test"],
        ]])
        let lines = [T.user("fix the login redirect"), first, T.assistant("Mentions TodoWrite in passing."), second]
        let peek = SessionPeekReader.fold(Data(lines.joined(separator: "\n").utf8), cut: false)
        #expect(peek.todos == [.init("Read the redirect", .done), .init("Fix the guard", .current), .init("Add a test", .pending)])
        let cleared = SessionPeekReader.fold(Data((lines + [T.toolUse("t3", "TodoWrite", ["todos": []])]).joined(separator: "\n").utf8), cut: false)
        #expect(cleared.todos == [])
        let none = SessionPeekReader.fold(Data([T.user("hi"), T.assistant("Hello.")].joined(separator: "\n").utf8), cut: false)
        #expect(none.todos == nil)
    }
}
