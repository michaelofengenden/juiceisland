import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Title lines as Claude Code writes them (`saveAiGeneratedTitle`, `saveCustomTitle`, `saveAgentName`, the legacy
/// `summary`) and `session_index.jsonl` lines as Codex writes them (`SessionIndexEntry`). Ids and titles are fictional.
enum TitleFixtures {
    /// `"type"` first, as the CLI writes it.
    static func claude(_ type: String, _ field: String, _ text: String, id: String = ClaudeFixtures.sessionID) -> String {
        #"{"type":"\#(type)","\#(field)":\#(json(text)),"sessionId":"\#(id)"}"#
    }

    static func json(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    static func ai(_ text: String, id: String = ClaudeFixtures.sessionID) -> String { claude("ai-title", "aiTitle", text, id: id) }
    static func custom(_ text: String, id: String = ClaudeFixtures.sessionID) -> String { claude("custom-title", "customTitle", text, id: id) }
    static func agentName(_ text: String, id: String = ClaudeFixtures.sessionID) -> String { claude("agent-name", "agentName", text, id: id) }

    static func index(_ id: String, _ name: String, at second: Int = 0) -> String {
        let object: [String: Any] = ["id": id, "thread_name": name, "updated_at": RolloutFixtures.stamp(second)]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func fold(_ lines: [String]) -> ClaudeTitleFold {
        var fold = ClaudeTitleFold()
        for line in lines { fold.apply(line) }
        return fold
    }
}

/// Claude's title lines: Claude's own order and last-wins per kind, a clear falls back (P202), and only title lines count.
struct ClaudeTitleFoldTests {
    typealias T = TitleFixtures

    @Test
    func claudesOwnOrderAndEachKindLastWins() {
        #expect(T.fold([]).title == nil)
        #expect(T.fold([T.ai("Fix login redirect loop")]).title == "Fix login redirect loop")
        // A title before the first prompt (`-n`) and a generated one after it: the name wins, as in Claude's picker.
        #expect(T.fold([T.custom("auth-refactor"), ClaudeFixtures.user("fix the login", at: 1), T.ai("Fix login redirect loop")]).title
            == "auth-refactor")
        // A rename, then cleared: the generated title again, never the stale name and never an empty title.
        let cleared = T.fold([T.ai("Fix login redirect loop"), T.custom("auth-refactor"), T.custom("")])
        #expect(cleared.title == "Fix login redirect loop")
        #expect(T.fold([T.custom("   ")]).title == nil)
        // `agent-name` is written with every rename; its collision variant is what Claude lists.
        #expect(T.fold([T.ai("Fix login"), T.custom("auth-refactor"), T.agentName("auth-refactor-graceful-unicorn")]).title
            == "auth-refactor-graceful-unicorn")
        #expect(T.fold([T.ai("Old"), T.ai("Plan: move the cache")]).title == "Plan: move the cache")
        // The legacy `summary` (older versions) is the last resort.
        #expect(T.fold([ClaudeFixtures.summary("Summed up")]).title == "Summed up")
        #expect(T.fold([ClaudeFixtures.summary("Summed up"), T.ai("Generated")]).title == "Generated")
        // A long name on one line, at most 200 characters.
        let long = String(repeating: "word ", count: 60)
        #expect(T.fold([T.custom(long + "\n tail")]).title?.count == ChatTitleText.limit)
    }

    /// A prompt that quotes a title line, a line holding one nested, and a line with the kind but no text are not titles.
    @Test
    func onlyTitleLinesCount() {
        let quoted = ClaudeFixtures.user(#"why does {"type":"ai-title","aiTitle":"Fake"} show?"#, at: 1)
        #expect(T.fold([quoted]).title == nil)
        #expect(T.fold([#"{"type":"user","message":{"content":[{"type":"ai-title","aiTitle":"Fake"}]}}"#]).title == nil)
        #expect(T.fold([#"{"type":"ai-title","sessionId":"x"}"#, "not json", #"{"type":"custom-title""#]).title == nil)
    }

    /// A later window's kinds replace the earlier ones', the others stay (the engine's fold over live reads).
    @Test
    func aLaterWindowMergesOverTheEarlier() {
        var fold = T.fold([T.ai("Fix login"), T.custom("auth-refactor")])
        fold.merge(T.fold([T.custom("")]))
        #expect(fold.title == "Fix login")
        fold.merge(T.fold([]))
        #expect(fold.title == "Fix login")
        fold.merge(T.fold([T.custom("renamed")]))
        #expect(fold.title == "renamed")
        // An earlier read under a later one (the launch's under a live read): only the kinds the later one has not
        // seen, so its clear stays a clear (P211).
        var live = T.fold([T.custom("")])
        live.fill(from: T.fold([T.ai("Generated"), T.custom("old-name")]))
        #expect(live.title == "Generated")
    }
}

/// The live read: the transcript's last 64 KB only, the path rule, and a line cut by the window skipped (P201).
@Suite(.serialized)
struct ClaudeTitleReaderTests {
    typealias F = ClaudeFixtures
    typealias R = RolloutFixtures
    typealias T = TitleFixtures

    @Test
    func aTitleBeforeAndAfterTheFirstPrompt() throws {
        let root = F.projectsFolder()
        defer { R.remove(root) }
        let url = F.transcriptURL(in: root)
        F.write([F.user("fix the login redirect", at: 0)], to: url)
        #expect(ClaudeTitleReader.read(path: url.path)?.fold.title == nil)
        R.append(T.ai("Fix login redirect loop") + "\n", to: url)
        R.append(F.turn(prompt: "and the tests", reply: "done", from: 10).joined(separator: "\n") + "\n", to: url)
        #expect(ClaudeTitleReader.read(path: url.path)?.fold.title == "Fix login redirect loop")
        R.append(T.custom("login-fix") + "\n", to: url)
        #expect(ClaudeTitleReader.read(path: url.path)?.fold.title == "login-fix")
        // Only a transcript: a `.jsonl` under a `projects` folder, a regular file.
        let elsewhere = root.deletingLastPathComponent().appendingPathComponent("elsewhere.jsonl")
        try T.ai("Nope").write(to: elsewhere, atomically: true, encoding: .utf8)
        #expect(ClaudeTitleReader.read(path: elsewhere.path) == nil)
        let link = root.appendingPathComponent("-tmp-project/link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(ClaudeTitleReader.read(path: link.path) == nil)
    }

    /// A title line in a line longer than the window is never read: the line is cut by the window's start. A large
    /// transcript is read as its last 64 KB and one byte, whatever its size.
    @Test
    func theReadIsBoundedAndSkipsACutLine() throws {
        let root = F.projectsFolder()
        defer { R.remove(root) }
        let url = F.transcriptURL(in: root)
        F.write([T.ai("Old title"), F.user("go", at: 0)], to: url)
        R.appendHole(4 << 20, to: url)
        // A title line itself longer than the window.
        R.append(T.ai("Inside " + String(repeating: "x", count: 70 * 1_024)) + "\n", to: url)
        let read = try #require(ClaudeTitleReader.read(path: url.path))
        #expect(read.fold.isEmpty)
        #expect(read.bytes == ClaudeTitleReader.window + 1)
        R.append(T.ai("New title") + "\n", to: url)
        let later = try #require(ClaudeTitleReader.read(path: url.path))
        #expect(later.fold.title == "New title")
        #expect(later.bytes == ClaudeTitleReader.window + 1)
    }

    /// The launch's pass keeps the title lines beside the session, never in it (P200): a large transcript's head looks
    /// past the first prompt for the generated title; the tail's re-appended lines win.
    @Test
    func theLaunchPassFoldsTitlesBesideTheSession() throws {
        let root = F.projectsFolder()
        defer { R.remove(root) }
        let url = F.transcriptURL(in: root)
        F.write([F.user("fix the login redirect", at: 0), F.toolUse("t1", at: 1), F.toolResult("t1", at: 2), T.ai("Fix login redirect loop"),
                 F.assistant("working", at: 3)], to: url)
        R.appendHole(20 << 20, to: url)
        R.append(F.turn(prompt: "last prompt", reply: "all done", from: 500).joined(separator: "\n") + "\n", to: url)
        let scanner = ClaudeTranscriptScanner(rootURL: root)
        let session = try #require(scanner.discoverRecentSessions().first)
        #expect(scanner.lastScanDiagnostics.windowedFileCount == 1)
        #expect(session.title == "Claude · project")
        #expect(scanner.lastScanTitles[session.id]?.title == "Fix login redirect loop")
        // Re-appended at an exit: the tail's name wins.
        R.append(T.custom("login-fix") + "\n", to: url)
        _ = scanner.discoverRecentSessions()
        #expect(scanner.lastScanTitles[session.id]?.title == "login-fix")
        // A transcript with no title line gives none.
        let other = F.transcriptURL(in: root, id: "b1")
        F.write([F.user("look around", at: 0, id: "b1")], to: other, id: "b1")
        _ = scanner.discoverRecentSessions()
        #expect(scanner.lastScanTitles["b1"] == nil)
    }
}

/// Codex's `session_index.jsonl`: the newest line wins, an empty name clears, a rewrite starts over, other threads'
/// lines are not kept, and reads are the last 256 KB once, then only appended bytes (P201, P202, P205).
@Suite(.serialized)
struct CodexTitleIndexTests {
    typealias T = TitleFixtures
    typealias Box = EngineFixtures.Box
    static let a = "019d516f-71ee-7e40-bcff-502fedac0928"
    static let b = "019d516f-71ee-7e40-bcff-502fedac0929"

    private func home() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("juice-island-codex-home-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func theNewestLineWinsAndAnEmptyNameClears() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(CodexTitleIndex.fileName)
        var index = CodexTitleIndex(home: home.path)
        #expect(index.refresh(ids: [Self.a]).isEmpty)
        try (T.index(Self.a, "Fix flaky auth test") + "\n" + T.index(Self.b, "Other thread") + "\n").write(to: file, atomically: false, encoding: .utf8)
        #expect(index.refresh(ids: [Self.a]) == [Self.a: "Fix flaky auth test"])
        #expect(index.names[Self.b] == nil)
        // A rename, appended: only the new bytes are read.
        let before = index.bytesRead
        let rename = T.index(Self.a, "Auth test, renamed", at: 5) + "\n"
        RolloutFixtures.append(rename, to: file)
        #expect(index.refresh(ids: [Self.a]) == [Self.a: "Auth test, renamed"])
        #expect(index.bytesRead - before == rename.utf8.count)
        // A line still being written waits for the next read.
        RolloutFixtures.append(#"{"id":"\#(Self.a)","thread_na"#, to: file)
        #expect(index.refresh(ids: [Self.a]) == [Self.a: "Auth test, renamed"])
        RolloutFixtures.append(#"me":"","updated_at":"2026-09-25T10:00:09Z"}"# + "\n", to: file)
        // Cleared: no name, never the stale one.
        #expect(index.refresh(ids: [Self.a]).isEmpty)
        // A thread asked for later is looked up from the end.
        #expect(index.refresh(ids: [Self.a, Self.b]) == [Self.b: "Other thread"])
    }

    /// `remove_thread_name_entries` rewrites the file through a rename: a new inode starts the read over, and a name
    /// it removed is gone.
    @Test
    func aRewriteStartsOver() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(CodexTitleIndex.fileName)
        try (T.index(Self.a, "First") + "\n" + T.index(Self.b, "Second") + "\n").write(to: file, atomically: false, encoding: .utf8)
        var index = CodexTitleIndex(home: home.path)
        #expect(index.refresh(ids: [Self.a, Self.b]) == [Self.a: "First", Self.b: "Second"])
        let temp = home.appendingPathComponent("session_index.jsonl.tmp")
        try (T.index(Self.b, "Second") + "\n").write(to: temp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
        #expect(index.refresh(ids: [Self.a, Self.b]) == [Self.b: "Second"])
        try FileManager.default.removeItem(at: file)
        #expect(index.refresh(ids: [Self.a, Self.b]).isEmpty)
    }

    /// The first read is the last 256 KB, however large the index.
    @Test
    func theFirstReadIsTheLastWindow() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(CodexTitleIndex.fileName)
        var text = (0..<12_000).map { n in
            #"{"id":"019d516f-0000-0000-0000-\#(String(format: "%012d", n))","thread_name":"Thread \#(n)","updated_at":"2026-09-25T10:00:00Z"}"#
        }.joined(separator: "\n") + "\n"
        text += T.index(Self.a, "Newest") + "\n"
        try text.write(to: file, atomically: false, encoding: .utf8)
        #expect(text.utf8.count > 4 * CodexTitleIndex.window)
        var index = CodexTitleIndex(home: home.path)
        #expect(index.refresh(ids: [Self.a]) == [Self.a: "Newest"])
        #expect(index.bytesRead == CodexTitleIndex.window + 1)
    }

    @Test
    func aRolloutsHome() {
        #expect(CodexTitleIndex.home(ofRollout: "/tmp/h/.codex/sessions/2026/09/25/rollout-2026-09-25T10-00-00-x.jsonl") == "/tmp/h/.codex")
        #expect(CodexTitleIndex.home(ofRollout: "/tmp/h/.codex-side/archived_sessions/rollout-x.jsonl") == "/tmp/h/.codex-side")
        #expect(CodexTitleIndex.home(ofRollout: "/tmp/h/elsewhere/rollout-x.jsonl") == nil)
    }

    /// The tracker names its watched threads on the poll it already runs, and hands on changes only.
    @Test
    func theTrackerNamesWatchedThreadsOnItsPoll() throws {
        let sessions = RolloutFixtures.sessionsFolder()
        defer { RolloutFixtures.remove(sessions) }
        let home = sessions.deletingLastPathComponent()
        let rollout = RolloutFixtures.rolloutURL(in: sessions, id: Self.a)
        try RolloutFixtures.text(RolloutFixtures.head(id: Self.a)).write(to: rollout, atomically: false, encoding: .utf8)
        let file = home.appendingPathComponent(CodexTitleIndex.fileName)
        try (T.index(Self.a, "Fix flaky auth test") + "\n").write(to: file, atomically: false, encoding: .utf8)
        let seen = Box<[[String: String?]]>([])
        let tracker = CodexRolloutTracker(pollInterval: 3_600)
        tracker.titleHandler = { names in seen.update { $0.append(names) } }
        let target = CodexRolloutWatchTarget(sessionID: Self.a, transcriptPath: rollout.path)
        tracker.sync(targets: [target])
        tracker.waitUntilIdle()
        #expect(seen.current == [[Self.a: "Fix flaky auth test"]])
        tracker.sync(targets: [target])
        tracker.waitUntilIdle()
        #expect(seen.current.count == 1)
        RolloutFixtures.append(T.index(Self.a, "") + "\n", to: file)
        tracker.sync(targets: [target])
        tracker.waitUntilIdle()
        let cleared: [String: String?] = [Self.a: nil]
        #expect(seen.current.last == cleared)
        tracker.stop()
    }
}

/// The engine keeps titles in memory only (P200), reads a Claude session's on its hooks and never on a timer (P201),
/// falls back to the first prompt when one is cleared (P202), and keeps no thread that is no session (P205).
@MainActor
@Suite(.serialized)
struct EngineChatTitleTests {
    typealias T = TitleFixtures
    typealias Box = EngineFixtures.Box
    let path = "/tmp/juice-island-titles/projects/-tmp-project/s1.jsonl"

    private func started(_ id: String = "s1", prompt: String? = nil, at date: Date = EngineFixtures.now) -> [AgentEvent] {
        var events: [AgentEvent] = [.sessionStarted(SessionStarted(
            sessionID: id, title: "Claude · project", tool: .claudeCode, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: date, jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project", paneTitle: "claude",
                                                    workingDirectory: "/tmp/project"),
            claudeMetadata: ClaudeSessionMetadata(transcriptPath: path)))]
        if let prompt {
            events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
                transcriptPath: path, initialUserPrompt: prompt, lastUserPrompt: prompt), timestamp: date + 1)))
            events.append(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: SignalPipeline.promptPrefix + prompt, phase: .running,
                                                                  timestamp: date + 1)))
        }
        return events
    }

    @Test
    func aTitleIsReadOnTheHooksThatBringOneAndKeptInMemoryOnly() async throws {
        let lines = Box<[String]>([])
        let reads = Box(0)
        let clock = Box(EngineFixtures.now)
        let engine = EngineFixtures.engine(clock: clock, configure: { dependencies in
            dependencies.readClaudeTitle = { _ in
                reads.update { $0 += 1 }
                return TitleFixtures.fold(lines.current)
            }
        })
        for event in started(prompt: "fix the login redirect") { engine.ingest(event, ingress: .bridge) }
        await engine.titleReadTask(for: "s1")?.value
        let session = try #require(engine.state.session(id: "s1"))
        #expect(engine.chatTitle(for: session) == ChatTitle(text: "fix the login redirect", source: .prompt))
        let startReads = reads.current
        #expect(startReads >= 1)
        // The generated title lands mid-turn: a tool event reads again once the gap has passed, not before.
        lines.update { $0 = [T.ai("Fix login redirect loop")] }
        let tool = AgentEvent.activityUpdated(SessionActivityUpdated(sessionID: "s1", summary: "Running Bash", phase: .running,
                                                                     timestamp: clock.current + 2))
        engine.ingest(tool, ingress: .bridge)
        await engine.titleReadTask(for: "s1")?.value
        #expect(reads.current == startReads)
        clock.update { $0 += SessionEngine.untitledReadGap + 1 }
        engine.ingest(tool, ingress: .bridge)
        await engine.titleReadTask(for: "s1")?.value
        #expect(engine.agentTitles["s1"] == "Fix login redirect loop")
        // Once titled, tool events read nothing; a turn's end does.
        let titledReads = reads.current
        clock.update { $0 += 60 }
        engine.ingest(tool, ingress: .bridge)
        #expect(engine.titleReadTask(for: "s1") == nil)
        lines.update { $0 += [T.custom("login-fix")] }
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "done", timestamp: clock.current)), ingress: .bridge)
        await engine.titleReadTask(for: "s1")?.value
        #expect(reads.current == titledReads + 1)
        #expect(engine.agentTitles["s1"] == "login-fix")
        // Cleared: back to the generated title, then the prompt once every kind is cleared (P202).
        lines.update { $0 = [T.custom("")] }
        engine.ingest(started(prompt: "and the tests").last!, ingress: .bridge)
        await engine.titleReadTask(for: "s1")?.value
        #expect(engine.agentTitles["s1"] == "Fix login redirect loop")
        lines.update { $0 = [T.ai("")] }
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "done", timestamp: clock.current)), ingress: .bridge)
        await engine.titleReadTask(for: "s1")?.value
        #expect(engine.agentTitles["s1"] == nil)
        #expect(engine.chatTitle(for: try #require(engine.state.session(id: "s1")))
            == ChatTitle(text: "fix the login redirect", source: .prompt))
        // Never in the session's own title, which upstream's registries write to disk (P200).
        #expect(engine.state.session(id: "s1")?.title == "Claude · project")
        engine.forgetSession("s1")
        #expect(engine.agentTitles["s1"] == nil && engine.claudeTitleFolds["s1"] == nil && engine.firstPrompts["s1"] == nil)
    }

    /// The launch's fold lands after a live read of the same session (the scan read the transcript first, a `/rename`
    /// and a prompt came while it ran): the live read's kinds stay, and the launch fills only the kinds it has not seen
    /// (P211).
    @Test
    func theLaunchsTitlesNeverOverwriteALaterLiveRead() async throws {
        let lines = Box<[String]>([T.custom("new-name")])
        let engine = EngineFixtures.engine(configure: { dependencies in
            dependencies.readClaudeTitle = { _ in TitleFixtures.fold(lines.current) }
        })
        for event in started(prompt: "fix the login") { engine.ingest(event, ingress: .bridge) }
        await engine.titleReadTask(for: "s1")?.value
        #expect(engine.agentTitles["s1"] == "new-name")
        engine.takeStartupTitles(claude: ["s1": T.fold([T.ai("Fix login redirect loop"), T.custom("old-name")])])
        #expect(engine.agentTitles["s1"] == "new-name")
        // The generated title the live window had not seen is kept under it: a clear falls back to it (P202).
        lines.update { $0 = [T.custom("")] }
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "done", timestamp: EngineFixtures.now + 5)), ingress: .bridge)
        await engine.titleReadTask(for: "s1")?.value
        #expect(engine.agentTitles["s1"] == "Fix login redirect loop")
        // A session no live read has titled takes the launch's fold whole.
        lines.update { $0 = [] }
        for event in started("s2") { engine.ingest(event, ingress: .bridge) }
        await engine.titleReadTask(for: "s2")?.value
        engine.takeStartupTitles(claude: ["s2": T.fold([T.custom("from-launch")])])
        #expect(engine.agentTitles["s2"] == "from-launch")
    }

    /// Triggers during a read coalesce into one more read after it.
    @Test
    func readsCoalesce() async throws {
        let reads = Box(0)
        let gate = Box(false)
        let engine = EngineFixtures.engine(configure: { dependencies in
            dependencies.readClaudeTitle = { _ in
                reads.update { $0 += 1 }
                while !gate.current { usleep(1_000) }
                return TitleFixtures.fold([TitleFixtures.ai("Titled")])
            }
        })
        for event in started(prompt: "go") { engine.ingest(event, ingress: .bridge) }
        let done = AgentEvent.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "done", timestamp: EngineFixtures.now + 5))
        for _ in 0..<5 { engine.ingest(done, ingress: .bridge) }
        gate.update { $0 = true }
        await engine.titleReadTask(for: "s1")?.value
        #expect(reads.current == 2)
        #expect(engine.agentTitles["s1"] == "Titled")
    }

    /// A slash command never titles a row; the first prompt after it does, and stays as later prompts come (P203).
    @Test
    func theFirstPromptTitlesUntilTheAgentDoes() throws {
        let engine = EngineFixtures.engine(configure: { $0.readClaudeTitle = { _ in nil } })
        for event in started(prompt: "/model") { engine.ingest(event, ingress: .bridge) }
        #expect(engine.chatTitle(for: try #require(engine.state.session(id: "s1"))) == nil)
        engine.ingest(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: "s1", claudeMetadata: ClaudeSessionMetadata(
            transcriptPath: path, initialUserPrompt: "/model", lastUserPrompt: "tighten the cards"), timestamp: EngineFixtures.now + 3)), ingress: .bridge)
        #expect(engine.chatTitle(for: try #require(engine.state.session(id: "s1"))) == ChatTitle(text: "tighten the cards", source: .prompt))
        engine.ingest(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: "s1", claudeMetadata: ClaudeSessionMetadata(
            transcriptPath: path, initialUserPrompt: "/model", lastUserPrompt: "now the footer"), timestamp: EngineFixtures.now + 9)), ingress: .bridge)
        #expect(engine.chatTitle(for: try #require(engine.state.session(id: "s1")))?.text == "tighten the cards")
        #expect(ChatTitleText.prompt("<task-notification>done</task-notification>") == nil)
        #expect(ChatTitleText.prompt("  fix\n  the   build ") == "fix the build")
    }

    /// Codex names reach only Codex sessions the engine has: its hidden titling thread, which has no rollout and no
    /// hook, is never kept, and never becomes a row (P205).
    @Test
    func codexNamesReachOnlyItsSessions() throws {
        let engine = EngineFixtures.engine()
        engine.ingest(.sessionStarted(SessionStarted(sessionID: "c1", title: "Codex · project", tool: .codex, origin: .live, initialPhase: .running,
                                                     summary: "Started.", timestamp: EngineFixtures.now)), ingress: .bridge)
        engine.takeCodexTitles(["c1": "Fix flaky auth test", "hidden-title-thread": "Should not show"])
        #expect(engine.agentTitles == ["c1": "Fix flaky auth test"])
        #expect(engine.state.session(id: "hidden-title-thread") == nil)
        engine.takeCodexTitles(["c1": String?.none])
        #expect(engine.agentTitles.isEmpty)
        #expect(engine.state.session(id: "c1")?.title == "Codex · project")
    }
}
