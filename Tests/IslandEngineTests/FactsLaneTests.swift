import Foundation
import IslandHookNotes
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Wave 6's facts lane, the engine side (P440-P446): a tool call still in flight, a fork that leaves its parent open and a
/// rewind that keeps its row, the reasoning effort beside the model, a subagent's own labels, the labels kept across a
/// relaunch, and Claude Code's recap. Fictional ids, folders and texts; fixtures shaped from the public docs and source.
@MainActor
struct FactsLaneTests {
    typealias Box = EngineFixtures.Box
    typealias F = ClaudeFixtures
    typealias R = RolloutFixtures
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

    private func note(_ event: String, _ id: String = "s1", call: String? = nil, agent: String? = nil, pid: Int32? = nil,
                      source: String? = nil, effort: String? = nil, mode: String? = nil) -> HookContextNote {
        HookContextNote(event: event, sessionID: id, agentPID: pid, toolUseID: call, toolName: call == nil ? nil : "Bash", agentID: agent,
                        permissionMode: mode, source: "claude", sessionStartSource: source, effort: effort)
    }

    // MARK: P440 A tool call in flight

    /// The book: a call starts at its PreToolUse and ends at its own end; parallel calls each; the main turn's end ends the
    /// main agent's calls, never a background subagent's, whose SubagentStop ends them; a start or an end of the session
    /// ends every call.
    @Test
    func theBookFollowsEachCallByItsID() {
        var book = ToolFlightBook()
        let t0 = EngineFixtures.now
        book.record(note("PreToolUse", call: "a"), at: t0)
        book.record(note("PreToolUse", call: "b"), at: t0 + 5)
        book.record(note("PreToolUse", call: "a"), at: t0 + 9)
        #expect(book.inFlightSince("s1") == t0)
        book.record(note("PostToolUse", call: "a"), at: t0 + 10)
        #expect(book.inFlightSince("s1") == t0 + 5)
        book.record(note("PostToolUseFailure", call: "b"), at: t0 + 11)
        #expect(book.inFlightSince("s1") == nil)
        #expect(book.noted.contains("s1"))
        book.record(note("PreToolUse", call: "c"), at: t0 + 20)
        book.record(note("PreToolUse", call: "w1", agent: "worker"), at: t0 + 21)
        book.record(note("Stop"), at: t0 + 22)
        #expect(book.inFlightSince("s1") == t0 + 21)
        book.record(note("SubagentStop", agent: "worker"), at: t0 + 23)
        #expect(book.inFlightSince("s1") == nil)
        book.record(note("PreToolUse", call: "d"), at: t0 + 30)
        book.record(note("SessionStart", source: "compact"), at: t0 + 31)
        #expect(book.inFlightSince("s1") == nil)
        for index in 0..<(ToolFlightBook.perSessionLimit + 5) {
            book.record(note("PreToolUse", call: "p\(index)"), at: t0 + 100 + TimeInterval(index))
        }
        #expect(book.flights["s1"]?.count == ToolFlightBook.perSessionLimit)
        #expect(book.inFlightSince("s1") == t0 + 105)
        book.forget("s1")
        #expect(book.inFlightSince("s1") == nil && !book.noted.contains("s1"))
    }

    /// Through the engine: the notes' calls; for a session no note named a call of, upstream's own "Running …" with a
    /// current tool, which its end ("… finished.") takes back; a finished session has nothing in flight.
    @Test
    func aSessionsCallInFlightComesFromItsNotesElseItsSummary() throws {
        let clock = Box(EngineFixtures.now)
        let engine = EngineFixtures.engine(clock: clock)
        for event in started() { engine.ingest(event, ingress: .bridge) }
        func session(_ id: String = "s1") throws -> AgentSession { try #require(engine.state.session(id: id)) }
        #expect(engine.toolInFlightSince(for: try session()) == nil)
        // No note named a call yet: the bridge's PreToolUse summary and its current tool.
        clock.update { $0 = EngineFixtures.now + 60 }
        engine.ingest(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(
            sessionID: "s1", claudeMetadata: ClaudeSessionMetadata(transcriptPath: Self.path, currentTool: "Bash"), timestamp: clock.current)),
                      ingress: .bridge)
        engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: "s1", summary: "Running Bash: swift build", phase: .running,
                                                              timestamp: clock.current)), ingress: .bridge)
        #expect(engine.toolInFlightSince(for: try session()) != nil)
        engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: "s1", summary: "Bash finished.", phase: .running,
                                                              timestamp: clock.current + 1)), ingress: .bridge)
        #expect(engine.toolInFlightSince(for: try session()) == nil)
        // Once a note named a call, the notes alone say: a later "Running …" with no call open is not in flight.
        clock.update { $0 = EngineFixtures.now + 120 }
        engine.ingest(note: note("PreToolUse", call: "toolu_1"))
        #expect(engine.toolInFlightSince(for: try session()) == EngineFixtures.now + 120)
        engine.ingest(note: note("PostToolUse", call: "toolu_1"))
        engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: "s1", summary: "Running Bash", phase: .running,
                                                              timestamp: clock.current)), ingress: .bridge)
        #expect(engine.toolInFlightSince(for: try session()) == nil)
        engine.ingest(note: note("PreToolUse", call: "toolu_2"))
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "Done", timestamp: clock.current + 5)), ingress: .bridge)
        #expect(engine.toolInFlightSince(for: try session()) == nil)
    }

    /// A call refused at Claude's own prompt fires no hook but writes its result, which closes its request: the call is
    /// over with it.
    @Test
    func aCallRefusedAtItsPromptIsNoLongerInFlight() throws {
        let engine = EngineFixtures.engine()
        for event in started() { engine.ingest(event, ingress: .bridge) }
        engine.ingest(note: note("PreToolUse", call: "toolu_1"))
        engine.ingest(note: note("PreToolUse", call: "toolu_2"))
        engine.ingest(EngineFixtures.permission("s1", toolUseID: "toolu_1"), ingress: .bridge)
        let request = try #require(engine.attention.all.first { $0.toolUseID == "toolu_1" })
        engine.closeRequest(request.id, cause: .transcript)
        #expect(engine.toolFlights.flights["s1"].map { Set($0.keys) } == ["toolu_2"])
    }

    // MARK: P441 Rewind and fork

    /// A rewind keeps the session's id and fires no hook; the prompt sent again after it is a new turn of the same row.
    /// Nothing duplicates: one row, one session.
    @Test
    func aRewindKeepsOneRow() throws {
        let clock = Box(EngineFixtures.now)
        let engine = EngineFixtures.engine(clock: clock)
        for event in started() { engine.ingest(event, ingress: .bridge) }
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "Done", timestamp: EngineFixtures.now + 30)), ingress: .bridge)
        let turn = engine.signals.turn(for: "s1")
        // Esc Esc, Restore conversation: nothing reaches the engine. The prompt comes back into the input and is sent again.
        clock.update { $0 = EngineFixtures.now + 90 }
        engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: "s1", summary: SignalPipeline.promptPrefix + "fix the login",
                                                              phase: .running, timestamp: clock.current)), ingress: .bridge)
        #expect(engine.rows.map(\.id) == ["s1"])
        #expect(engine.state.sessions.count == 1)
        #expect(engine.signals.turn(for: "s1") == turn + 1)
    }

    /// Lets the engine's detached reads land: true once `done` holds (at most about a second).
    private func settle(_ done: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    /// `/branch`: the fork's SessionStart (`source: "fork"`) comes from the process that ran the parent, which gets no
    /// SessionEnd, and the fork's transcript names the parent (`forkedFrom`): the parent ends and the fork is the one row.
    /// The parent's next prompt (resumed elsewhere) brings it back. A fork from another process, one that names no parent,
    /// and a plain start from the same process end nothing.
    @Test
    func aForkEndsTheParentItsProcessLeft() async throws {
        let clock = Box(EngineFixtures.now)
        let reads = Box<[String]>([])
        // Each fork's transcript names its parent, by the fork's own path.
        let parents = ["fork": "parent", "fork2": "other", "mate": "other"]
        func path(_ id: String) -> String { "/tmp/juice-island-test/projects/-tmp-project/\(id).jsonl" }
        let engine = EngineFixtures.engine(clock: clock, configure: { dependencies in
            dependencies.readForkParent = { path in
                reads.update { $0.append(path) }
                return parents.first { "/tmp/juice-island-test/projects/-tmp-project/\($0.key).jsonl" == path }?.value
            }
        })
        func start(_ id: String, at date: Date = EngineFixtures.now) {
            for event in started(id, metadata: ClaudeSessionMetadata(transcriptPath: path(id)), at: date) { engine.ingest(event, ingress: .bridge) }
        }
        start("parent")
        start("other")
        engine.ingest(note: note("SessionStart", "parent", pid: 4242, source: "startup"))
        engine.ingest(note: note("SessionStart", "other", pid: 5151, source: "startup"))
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: "parent", summary: "Done", timestamp: EngineFixtures.now + 10)), ingress: .bridge)
        #expect(reads.current.isEmpty)
        // The fork: its note first (the helper sends it before the bridge's event), then its start and prompt.
        clock.update { $0 = EngineFixtures.now + 60 }
        engine.ingest(note: note("SessionStart", "fork", pid: 4242, source: "fork"))
        start("fork", at: clock.current)
        #expect(await settle { engine.state.session(id: "parent")?.isSessionEnded == true })
        #expect(reads.current == [path("fork")])
        #expect(Set(engine.rows.map(\.id)) == ["fork", "other"])
        #expect(engine.forkEndedCount == 1)
        // The parent resumed in another process: its prompt brings it back.
        clock.update { $0 = EngineFixtures.now + 120 }
        engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: "parent", summary: SignalPipeline.promptPrefix + "go on here",
                                                              phase: .running, timestamp: clock.current)), ingress: .bridge)
        #expect(Set(engine.rows.map(\.id)) == ["fork", "other", "parent"])
        // A fork from another process that names "other", one from its process that names nobody, and a plain start
        // from its process whose transcript would name it: "other" stays, and the plain start reads nothing.
        engine.ingest(note: note("SessionStart", "fork2", pid: 7777, source: "fork"))
        start("fork2", at: clock.current)
        engine.ingest(note: note("SessionStart", "fork3", pid: 5151, source: "fork"))
        start("fork3", at: clock.current)
        engine.ingest(note: note("SessionStart", "mate", pid: 5151, source: "startup"))
        start("mate", at: clock.current)
        #expect(await settle { reads.current.count == 3 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(!reads.current.contains(path("mate")))
        #expect(engine.state.session(id: "other")?.isSessionEnded == false)
        #expect(engine.forkEndedCount == 1)
    }

    @Test
    func aForkNeverEndsAParentThatWaitsOnTheOwner() async throws {
        let reads = Box(0)
        let engine = EngineFixtures.engine(configure: { dependencies in
            dependencies.readForkParent = { _ in
                reads.update { $0 += 1 }
                return "parent"
            }
        })
        for event in started("parent") { engine.ingest(event, ingress: .bridge) }
        engine.ingest(note: note("SessionStart", "parent", pid: 4242, source: "startup"))
        engine.loadPreviewEvents([.questionAsked(QuestionAsked(sessionID: "parent", prompt: QuestionPrompt(title: "Which?", options: ["A", "B"]),
                                                               timestamp: EngineFixtures.now + 5))])
        #expect(engine.needsAttention(try #require(engine.state.session(id: "parent"))))
        engine.ingest(note: note("SessionStart", "fork", pid: 4242, source: "fork"))
        for event in started("fork") { engine.ingest(event, ingress: .bridge) }
        #expect(await settle { reads.current == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.state.session(id: "parent")?.isSessionEnded == false)
    }

    /// The fork's transcript head: the first line that names a parent, never a line the window cuts.
    @Test
    func theForksTranscriptNamesItsParent() {
        let copied = SessionPeekReaderTests.line(["type": "user", "sessionId": "c1", "forkedFrom": ["sessionId": "p1", "messageUuid": "m1"],
                                                  "message": ["role": "user", "content": "plan it"]])
        let own = SessionPeekReaderTests.line(["type": "user", "sessionId": "c1", "message": ["role": "user", "content": "go"]])
        #expect(ForkParentReader.parent(in: Data((own + "\n" + copied + "\n").utf8)) == "p1")
        #expect(ForkParentReader.parent(in: Data((own + "\n").utf8)) == nil)
        #expect(ForkParentReader.parent(in: Data(copied.utf8)) == nil)
        #expect(ForkParentReader.read(path: "/tmp/juice-island-test/not-a-transcript.jsonl") == nil)
    }

    /// At launch: a rewound transcript (a new timeline appended to the same file, the same session id) is one session with
    /// the current timeline's prompt; a fork's transcript (its copied lines carry `forkedFrom`) takes its parent's place
    /// when the parent was last written with the fork; a parent written well after is a conversation of its own.
    @Test
    func theLaunchScanKeepsOneSessionPerConversation() throws {
        let root = F.projectsFolder()
        defer { R.remove(root) }
        // A rewind: the turn after "first" was rewound, and "first, again" sent in its place.
        F.write(F.turn(prompt: "first", reply: "one", from: 0) + F.turn(prompt: "rewound away", reply: "gone", from: 10)
                + F.turn(prompt: "first, again", reply: "two", from: 20), to: F.transcriptURL(in: root, id: "r1"), id: "r1")
        // A fork of p1: its copied lines name p1 as their session and carry `forkedFrom`; then its own turn.
        let parentLines = F.turn(prompt: "plan it", reply: "planned", from: 0)
        F.write(parentLines, to: F.transcriptURL(in: root, id: "p1"), id: "p1")
        let copied = parentLines.map { line -> String in
            var object = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            object["sessionId"] = "p1"
            object["forkedFrom"] = ["sessionId": "p1", "messageUuid": "m-1"]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        F.write(copied + F.turn(prompt: "try the other way", reply: "tried", from: 30).map { $0.replacingOccurrences(of: F.sessionID, with: "c1") },
                to: F.transcriptURL(in: root, id: "c1"), id: "c1")
        let now = Date()
        let times = [("p1", now.addingTimeInterval(-600)), ("c1", now.addingTimeInterval(-590)), ("r1", now.addingTimeInterval(-500))]
        for (id, time) in times {
            try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: F.transcriptURL(in: root, id: id).path)
        }
        // `/branch`: the fork's file begins as the parent's last line (the `/branch` line) is written.
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-600)], ofItemAtPath: F.transcriptURL(in: root, id: "c1").path)
        let found = ClaudeTranscriptScanner(rootURL: root).discoverRecentSessions(now: now)
        #expect(Set(found.map(\.id)) == ["r1", "c1"])
        #expect(found.first { $0.id == "r1" }?.claudeMetadata?.lastUserPrompt == "first, again")
        #expect(found.first { $0.id == "c1" }?.claudeMetadata?.lastUserPrompt == "try the other way")
        // The parent resumed and written to later: both stay.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: F.transcriptURL(in: root, id: "p1").path)
        let later = ClaudeTranscriptScanner(rootURL: root).discoverRecentSessions(now: now)
        #expect(Set(later.map(\.id)) == ["r1", "c1", "p1"])
    }

    /// A parent forked from another terminal (`claude --continue --fork-session`) while it stayed open and idle: nothing
    /// was written to it at the fork, so it is a conversation of its own and the launch scan keeps it (P498).
    @Test
    func theLaunchScanKeepsAParentForkedFromElsewhere() throws {
        let root = F.projectsFolder()
        defer { R.remove(root) }
        let parentLines = F.turn(prompt: "plan it", reply: "planned", from: 0)
        F.write(parentLines, to: F.transcriptURL(in: root, id: "p1"), id: "p1")
        let copied = parentLines.map { line -> String in
            var object = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            object["sessionId"] = "p1"
            object["forkedFrom"] = ["sessionId": "p1", "messageUuid": "m-1"]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        F.write(copied + F.turn(prompt: "try the other way", reply: "tried", from: 30).map { $0.replacingOccurrences(of: F.sessionID, with: "c1") },
                to: F.transcriptURL(in: root, id: "c1"), id: "c1")
        let now = Date()
        let parent = F.transcriptURL(in: root, id: "p1").path, fork = F.transcriptURL(in: root, id: "c1").path
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3_000)], ofItemAtPath: parent)
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-600), .modificationDate: now.addingTimeInterval(-590)],
                                              ofItemAtPath: fork)
        let found = ClaudeTranscriptScanner(rootURL: root).discoverRecentSessions(now: now)
        #expect(Set(found.map(\.id)) == ["p1", "c1"])
    }

    // MARK: P443 Effort, P444 a subagent's own labels

    /// Claude's effort from its hooks' `effort.level` (the note's), never a subagent's note; else a peek's read of its
    /// transcript. Codex's from its rollout's `turn_context.effort`, which a turn with none clears.
    @Test
    func theEffortIsTheSessionsOwn() throws {
        let object: [String: Any] = ["hook_event_name": "PreToolUse", "session_id": "s1", "tool_use_id": "t1", "effort": ["level": "xhigh"]]
        #expect(HookContextNote.make(object: object, environment: [:], agentPID: nil)?.effort == "xhigh")
        var tooLong = object
        tooLong["effort"] = ["level": String(repeating: "x", count: 40)]
        #expect(HookContextNote.make(object: tooLong, environment: [:], agentPID: nil)?.effort == nil)

        let engine = EngineFixtures.engine()
        for event in started(metadata: ClaudeSessionMetadata(transcriptPath: Self.path, model: "claude-opus-5-5")) {
            engine.ingest(event, ingress: .bridge)
        }
        let session = try #require(engine.state.session(id: "s1"))
        #expect(engine.facts(for: session).effort == nil)
        engine.ingest(note: note("PreToolUse", call: "t1", agent: "agent-1", effort: "low"))
        #expect(engine.facts(for: session).effort == nil)
        engine.ingest(note: note("PreToolUse", call: "t2", effort: "high"))
        #expect(engine.facts(for: session).effort == "high")
        // A note with no effort (a prompt, a notification) keeps the last one.
        engine.ingest(note: note("UserPromptSubmit"))
        #expect(engine.facts(for: session).effort == "high")

        var attention = CodexAttention()
        attention.apply(R.meta())
        attention.apply(R.line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6-astra", "effort": "medium"], at: 1))
        #expect(attention.effort == "medium")
        #expect(attention.takeEvents().filter { $0 == .factsChanged }.count == 2)
        attention.apply(R.line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6-astra", "effort": "medium"], at: 2))
        #expect(!attention.takeEvents().contains(.factsChanged))
        attention.apply(R.line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6-astra"], at: 3))
        #expect(attention.effort == nil)
    }

    /// The transcript's effort is each reply's own (`effort` beside its message); a subagent's line written into its
    /// parent's transcript (`isSidechain`) names the subagent's model and effort, never the session's.
    @Test
    func aSubagentsLinesNeverNameTheSessionsModelOrEffort() {
        let own = SessionPeekReaderTests.line(["type": "assistant", "effort": "xhigh",
                                               "message": ["role": "assistant", "model": "claude-opus-5-5",
                                                           "content": [["type": "text", "text": "Working on it."]]]])
        let sidechain = SessionPeekReaderTests.line(["type": "assistant", "effort": "low", "isSidechain": true,
                                                     "message": ["role": "assistant", "model": "claude-haiku-4-5",
                                                                 "content": [["type": "text", "text": "Found 3 files."]]]])
        let peek = SessionPeekReader.fold(Data([SessionPeekReaderTests.user("look"), own, sidechain].joined(separator: "\n").utf8), cut: false)
        #expect(peek.model == "claude-opus-5-5")
        #expect(peek.effort == "xhigh")
    }

    /// A Codex subagent's rollout (a `thread_spawn` child) is never its chat's: the chat keeps its own model and effort.
    @Test
    func aCodexSubagentsModelIsNeverItsChats() throws {
        let engine = SessionEngine.preview(clock: { EngineFixtures.now + 60 })
        let rollout = "/tmp/juice-island-test/sessions/rollout-c1.jsonl"
        engine.loadPreviewEvents([.sessionStarted(SessionStarted(
            sessionID: "c1", title: "Codex · project", tool: .codex, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: EngineFixtures.now, jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project", paneTitle: "codex",
                                                                  workingDirectory: "/tmp/project"),
            codexMetadata: CodexSessionMetadata(transcriptPath: rollout, lastUserPrompt: "move the settings")))])
        engine.loadPreviewRollout(sessionID: "c1", transcriptPath: rollout, lines: [
            R.meta(id: "c1"),
            R.line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6-astra", "effort": "high"], at: 1),
        ])
        let child = "/tmp/juice-island-test/sessions/rollout-k1.jsonl"
        let spawned = CodexThreadFixtures.subagent("k1", parent: "c1", running: true)
        engine.loadPreviewRollout(sessionID: "k1", transcriptPath: child, lines: [spawned[0],
            R.line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6-mini", "effort": "low"], at: 31)] + spawned.dropFirst())
        let session = try #require(engine.state.session(id: "c1"))
        #expect(engine.facts(for: session).model == "gpt-6-astra")
        #expect(engine.facts(for: session).effort == "high")
        #expect(engine.state.session(id: "k1") == nil)
    }

    // MARK: P445 Labels across a relaunch

    /// The model, effort and mode are written when they change, as labels only (no title, prompt or path), and a second
    /// engine on the same file shows them on the restored session until its agent says them again.
    @Test
    func theLabelsOutliveARelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("juice-labels-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionLabelStore(url: folder.appendingPathComponent(SessionLabelStore.fileName))
        func engine() -> SessionEngine {
            var configuration = SessionEngine.Configuration.headless
            configuration.sessionLabels = store
            var dependencies = SessionEngine.Dependencies()
            dependencies.now = { EngineFixtures.now }
            dependencies.readPeek = nil
            dependencies.watchTranscript = { _, _, _ in nil }
            return SessionEngine(configuration: configuration, dependencies: dependencies)
        }
        let first = engine()
        try first.start()
        for event in started(metadata: ClaudeSessionMetadata(transcriptPath: Self.path, lastUserPrompt: "fix the login",
                                                              model: "claude-opus-5-5[1m]")) {
            first.ingest(event, ingress: .bridge)
        }
        first.ingest(note: note("PreToolUse", call: "t1", effort: "xhigh", mode: "plan"))
        store.flush()
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.contains("claude-opus-5-5[1m]") && text.contains("xhigh") && text.contains("plan"))
        #expect(!text.contains("fix the login") && !text.contains("project") && !text.contains("/tmp"))

        let second = engine()
        try second.start()
        // Restored with no model, mode or effort of its own yet.
        second.ingest(.sessionStarted(SessionStarted(
            sessionID: "s1", title: "Claude · project", tool: .claudeCode, origin: .live, initialPhase: .completed, summary: "Done.",
            timestamp: EngineFixtures.now, claudeMetadata: ClaudeSessionMetadata(transcriptPath: Self.path))), ingress: .bridge)
        let restored = try #require(second.state.session(id: "s1"))
        #expect(second.facts(for: restored) == SessionFacts(model: "claude-opus-5-5[1m]", mode: "plan", effort: "xhigh"))
        // What the agent says now wins.
        second.ingest(note: note("UserPromptSubmit", effort: "high", mode: "acceptEdits"))
        #expect(second.facts(for: restored).effort == "high" && second.facts(for: restored).mode == "acceptEdits")
        // A headless engine with no file keeps nothing.
        let none = EngineFixtures.engine()
        for event in started() { none.ingest(event, ingress: .bridge) }
        #expect(none.labelBook.labels.isEmpty)
    }

    /// Codex's latest turn says its effort, and a turn with none says there is none: the kept label never brings back an
    /// effort Codex has cleared, in the row's facts or in the file. Before the rollout's first read after a relaunch, the
    /// kept effort shows (P497).
    @Test
    func aKeptEffortNeverOutlivesCodexClearingIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("juice-labels-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionLabelStore(url: folder.appendingPathComponent(SessionLabelStore.fileName))
        func engine() throws -> SessionEngine {
            var configuration = SessionEngine.Configuration.headless
            configuration.sessionLabels = store
            var dependencies = SessionEngine.Dependencies()
            dependencies.now = { EngineFixtures.now }
            dependencies.readPeek = nil
            dependencies.watchTranscript = { _, _, _ in nil }
            let engine = SessionEngine(configuration: configuration, dependencies: dependencies)
            try engine.start()
            engine.ingest(.sessionStarted(SessionStarted(
                sessionID: "c1", title: "Codex · project", tool: .codex, origin: .live, initialPhase: .running, summary: "Started.",
                timestamp: EngineFixtures.now, jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project", paneTitle: "codex",
                                                                      workingDirectory: "/tmp/project"))), ingress: .bridge)
            return engine
        }
        func read(_ engine: SessionEngine, _ attention: inout CodexAttention, _ lines: [String]) {
            for line in lines { attention.apply(line) }
            engine.ingestCodexAttention(CodexAttentionUpdate(sessionID: "c1", events: attention.takeEvents(), state: attention))
        }
        let first = try engine()
        var rollout = CodexAttention()
        read(first, &rollout, [R.meta(id: "c1"), R.line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6-astra", "effort": "high"], at: 1)])
        let session = try #require(first.state.session(id: "c1"))
        #expect(first.facts(for: session).effort == "high" && first.labelBook.labels(for: "c1")?.effort == "high")
        read(first, &rollout, [R.line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6-mini"], at: 2)])
        #expect(first.facts(for: session).effort == nil && first.facts(for: session).model == "gpt-6-mini")
        #expect(first.labelBook.labels(for: "c1")?.effort == nil)

        // Relaunched: the kept effort until the rollout is read, then what it says.
        read(first, &rollout, [R.line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6-astra", "effort": "xhigh"], at: 3)])
        store.flush()
        let second = try engine()
        let restored = try #require(second.state.session(id: "c1"))
        #expect(second.facts(for: restored).effort == "xhigh")
        var again = CodexAttention()
        read(second, &again, [R.meta(id: "c1"), R.line("turn_context", ["cwd": "/tmp/project", "model": "gpt-6-astra"], at: 4)])
        #expect(second.facts(for: restored).effort == nil && second.labelBook.labels(for: "c1")?.effort == nil)
    }

    /// The book: bounded in count and age, a label no source says keeps the kept one, and nothing that is no label.
    @Test
    func theLabelBookIsBounded() {
        let now = EngineFixtures.now
        var book = SessionLabelBook(labels: ["old": SessionLabels(model: "m", at: now - SessionLabelBook.lifetime - 1),
                                             "new": SessionLabels(model: "m", at: now)], now: now)
        #expect(book.labels(for: "old") == nil && book.labels(for: "new") != nil)
        let took = book.take("a", model: "claude-opus-5-5", mode: nil, effort: nil, at: now)
        let again = book.take("a", model: nil, mode: nil, effort: nil, at: now + 1)
        let text = book.take("b", model: "fix the login redirect please", mode: nil, effort: nil, at: now)
        #expect(took && !again && !text)
        #expect(book.labels(for: "a")?.model == "claude-opus-5-5")
        for index in 0..<(SessionLabelBook.limit + 10) {
            book.take("s\(index)", model: "claude-opus-5-5", mode: nil, effort: nil, at: now + TimeInterval(index))
        }
        #expect(book.labels.count == SessionLabelBook.limit)
        #expect(book.labels(for: "s0") == nil && book.labels(for: "s\(SessionLabelBook.limit + 9)") != nil)
    }

    // MARK: P446 Claude Code's recap

    /// The recap (`system` `away_summary`) stands while nothing was prompted or replied after it, collapsed and cut at 400
    /// characters; it is no prompt and no reply.
    @Test
    func theRecapIsTheLatestAwaySummary() {
        func recap(_ text: String) -> String {
            SessionPeekReaderTests.line(["type": "system", "subtype": "away_summary", "content": text, "isMeta": false])
        }
        let turn = [SessionPeekReaderTests.user("fix the login"), SessionPeekReaderTests.assistant("Fixed the redirect.")]
        let peek = SessionPeekReader.fold(Data((turn + [recap("We fixed the login\nredirect; the tests are next.")]).joined(separator: "\n").utf8),
                                          cut: false)
        #expect(peek.recap == "We fixed the login redirect; the tests are next.")
        #expect(peek.prompt == "fix the login" && peek.reply == "Fixed the redirect.")
        let prompted = SessionPeekReader.fold(Data((turn + [recap("Old recap."), SessionPeekReaderTests.user("now the tests")])
            .joined(separator: "\n").utf8), cut: false)
        #expect(prompted.recap == nil)
        let replied = SessionPeekReader.fold(Data((turn + [recap("Old recap."), SessionPeekReaderTests.assistant("More work.")])
            .joined(separator: "\n").utf8), cut: false)
        #expect(replied.recap == nil)
        let long = SessionPeekReader.fold(Data((turn + [recap(String(repeating: "word ", count: 200))]).joined(separator: "\n").utf8), cut: false)
        #expect(long.recap?.count == ClaudeTranscriptFold.recapLimit)
        #expect(long.recap?.hasSuffix("…") == true)
    }
}
