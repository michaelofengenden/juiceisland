import Foundation
import IslandHookNotes
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Who may tell the owner a turn finished (P250-P257): only the owner's own top-level sessions. Subagents never notify
/// on their own, scripted runs are hidden unless asked for and never notify, and a turn a background task's
/// notification wakes in the owner's chat is one Done, like any. A request that waits surfaces from any of them.
/// Shapes: Claude Code 2.1.280's `CLAUDE_CODE_ENTRYPOINT` values, openai/codex `SessionSource`/`ThreadSource`/
/// `originator`, its hooks' nullable `transcript_path` and SessionStart `source`, the codex plugin's client name; texts
/// and paths are fictional.
@MainActor
struct DoneScopeTests {
    typealias F = EngineFixtures
    typealias Box = EngineFixtures.Box
    typealias R = RolloutFixtures

    // MARK: Fixtures

    /// A Claude hook's note (v2) as the superset helper sends it: `--source claude`, the entrypoint from the environment.
    private func claudeNote(_ id: String, _ event: String = "UserPromptSubmit", entrypoint: String?,
                            agentID: String? = nil) -> HookContextNote {
        HookContextNote(event: event, sessionID: id, agentPID: 900, agentID: agentID, entrypoint: entrypoint, source: "claude")
    }

    /// A Claude session of `entrypoint` with one finished turn of the owner's, its hold passed.
    private func claudeTurn(_ engine: SessionEngine, _ id: String, entrypoint: String?, clock: Box<Date>) {
        engine.ingest(note: claudeNote(id, "SessionStart", entrypoint: entrypoint))
        engine.ingest(F.started(id), ingress: .bridge)
        engine.ingest(note: claudeNote(id, entrypoint: entrypoint))
        engine.ingest(F.prompt(id), ingress: .bridge)
        engine.ingest(note: claudeNote(id, "Stop", entrypoint: entrypoint))
        engine.ingest(F.completed(id), ingress: .bridge)
        pass(engine, clock)
    }

    /// The 1.5 s hold, passed.
    private func pass(_ engine: SessionEngine, _ clock: Box<Date>) {
        clock.update { $0 = $0.addingTimeInterval(SignalPipeline.doneHold) }
        engine.flushHeldSignals()
    }

    /// Codex's hooks, as upstream's bridge applies them: a hooked session, with the rollout's path when the thread has
    /// one (nil for an ephemeral thread: `hook_transcript_path` is nil only without a rollout).
    private func codexTurn(_ engine: SessionEngine, _ id: String, transcript: String?, clock: Box<Date>) {
        engine.ingest(F.started(id, tool: .codex, transcript: transcript, title: "Codex · project"), ingress: .bridge)
        engine.ingest(F.prompt(id, "review the diff"), ingress: .bridge)
        engine.ingest(F.completed(id), ingress: .bridge)
        pass(engine, clock)
    }

    /// A Codex hook's note. Upstream's installer writes Codex's hook command with no `--source`, so the note names none;
    /// `entrypoint` is `CLAUDE_CODE_ENTRYPOINT` in the Codex process's environment (the plugin's app-server inherits a
    /// Claude session's), and a SessionStart's `source` is `startup` or `resume`.
    private func codexNote(_ id: String, _ event: String, entrypoint: String? = nil, resume: Bool = false,
                           source: String? = nil) -> HookContextNote {
        HookContextNote(event: event, sessionID: id, agentPID: 901, entrypoint: entrypoint, source: source,
                        sessionStartSource: event == "SessionStart" ? (resume ? "resume" : "startup") : nil)
    }

    /// One Codex turn over its hooks, each with its note, and the tracker's read of the rollout between the prompt and
    /// the Stop (its fold still holds the thread's first `session_meta`).
    private func codexHookedTurn(_ engine: SessionEngine, _ id: String, meta: [String: Any], entrypoint: String?, resume: Bool = false,
                                 source: String? = nil, clock: Box<Date>) {
        if resume { engine.ingest(note: codexNote(id, "SessionStart", entrypoint: entrypoint, resume: true, source: source)) }
        engine.ingest(note: codexNote(id, "UserPromptSubmit", entrypoint: entrypoint, source: source))
        engine.ingest(F.prompt(id, "keep going"), ingress: .bridge)
        engine.ingestCodexAttention(CodexAttentionUpdate(sessionID: id, events: [], state: attention(meta)))
        engine.ingest(note: codexNote(id, "Stop", entrypoint: entrypoint, source: source))
        engine.ingest(F.completed(id), ingress: .bridge)
        pass(engine, clock)
    }

    /// A persisted Codex thread its hooks report, started by `entrypoint`'s process, with its first turn.
    private func codexThread(_ engine: SessionEngine, _ id: String, meta: [String: Any], entrypoint: String?, clock: Box<Date>) {
        engine.ingest(note: codexNote(id, "SessionStart", entrypoint: entrypoint))
        engine.ingest(F.started(id, tool: .codex, transcript: "/tmp/sessions/rollout-\(id).jsonl", title: "Codex · project"), ingress: .bridge)
        engine.ingestCodexAttention(CodexAttentionUpdate(sessionID: id, events: [], state: attention(meta)))
        codexHookedTurn(engine, id, meta: meta, entrypoint: entrypoint, clock: clock)
    }

    private static let pluginMeta = meta(id: "plugin", source: "vscode", originator: "Claude Code", threadSource: "user")
    private static let execMeta = meta(id: "exec", source: "exec", originator: "codex_exec")

    /// What the tracker folds from a rollout's first line.
    private func attention(_ meta: [String: Any]) -> CodexAttention {
        var attention = CodexAttention()
        attention.apply(R.line("session_meta", meta, at: 0))
        return attention
    }

    private static let threadSpawn: [String: Any] = ["subagent": ["thread_spawn": ["parent_thread_id": "019d0000-0000-7000-8000-000000000001",
                                                                                  "depth": 1, "agent_role": "explorer"]]]

    private static func meta(id: String, source: Any, originator: String, threadSource: String? = nil) -> [String: Any] {
        var meta: [String: Any] = ["id": id, "session_id": id, "cwd": "/tmp/project", "originator": originator,
                                   "cli_version": "0.157.0", "source": source, "timestamp": R.stamp(0)]
        if let threadSource { meta["thread_source"] = threadSource }
        return meta
    }

    /// A thread upstream's Codex.app rescan found in `~/.codex/sessions` (never a hook of its own id), then its
    /// rollout's first read: its `session_meta`, and a turn that runs and finishes.
    private func rescannedThreadTurn(_ engine: SessionEngine, _ id: String, meta: [String: Any], clock: Box<Date>) {
        var thread = AgentSession(id: id, title: "Codex · project", tool: .codex, origin: .live, attachmentState: .stale,
                                  phase: .completed, summary: "Started.", updatedAt: clock.current,
                                  codexMetadata: CodexSessionMetadata(transcriptPath: "/tmp/sessions/rollout-\(id).jsonl",
                                                                      initialUserPrompt: "Map the parser's call sites"))
        thread.isCodexAppSession = true
        engine.replace(thread)
        engine.ingestCodexAttention(CodexAttentionUpdate(sessionID: id, events: [], state: attention(meta)))
        engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: "Thinking.", phase: .running,
                                                              timestamp: clock.current)), ingress: .rollout)
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: id, summary: "Found 12 call sites.", timestamp: clock.current)),
                      ingress: .rollout)
        pass(engine, clock)
    }

    private func recording(_ engine: SessionEngine) -> Box<[EngineSignal]> {
        let signals = Box<[EngineSignal]>([])
        engine.onSignal = { signal in signals.update { $0.append(signal) } }
        return signals
    }

    // MARK: The rules

    @Test
    func theRulesTellEachScopeApart() {
        for entrypoint in ["sdk-cli", "mcp", "claude-code-github-action"] {
            #expect(SessionScopeRules.claude(entrypoint: entrypoint) == .scripted)
        }
        // The Agent SDK's own entrypoints are also an editor's chat (Zed's Claude Agent over ACP sets none, so sdk-ts).
        for entrypoint in ["cli", "claude-desktop", "claude-desktop-3p", "claude-vscode", "local-agent", "sdk-ts", "sdk-py",
                           "something-new"] {
            #expect(SessionScopeRules.claude(entrypoint: entrypoint) == .owner)
        }
        #expect(SessionScopeRules.claude(entrypoint: nil) == nil)
        #expect(SessionScopeRules.claude(entrypoint: "") == nil)

        typealias Rules = SessionScopeRules
        #expect(Rules.codex(source: "subagent", threadSource: "subagent", originator: "codex_desktop") == .subagent)
        #expect(Rules.codex(source: "internal", threadSource: nil, originator: "codex_desktop") == .subagent)
        #expect(Rules.codex(source: "vscode", threadSource: "guardian_review", originator: "codex_desktop") == .subagent)
        #expect(Rules.codex(source: "vscode", threadSource: "memory_consolidation", originator: "codex_desktop") == .subagent)
        #expect(Rules.codex(source: "exec", threadSource: nil, originator: "codex_exec") == .scripted)
        #expect(Rules.codex(source: "mcp", threadSource: nil, originator: "codex_cli_rs") == .scripted)
        #expect(Rules.codex(source: "vscode", threadSource: "user", originator: "Claude Code") == .scripted)
        #expect(Rules.codex(source: "vscode", threadSource: nil, originator: "codex_sdk_ts") == .scripted)
        #expect(Rules.codex(source: "vscode", threadSource: "user", originator: "codex_desktop") == .owner)
        #expect(Rules.codex(source: "cli", threadSource: nil, originator: "codex_cli_rs") == .owner)
        #expect(Rules.codex(source: "vscode", threadSource: nil, originator: "codex_vscode") == .owner)
        #expect(Rules.codex(source: nil, threadSource: nil, originator: nil) == nil)
    }

    /// The tracker's fold reads the scope from the thread's first `session_meta`, in each shape Codex writes it; a
    /// fork's copied history (a later `session_meta`) never changes it.
    @Test
    func theFoldReadsTheScopeFromTheFirstSessionMeta() {
        #expect(attention(Self.meta(id: "c1", source: Self.threadSpawn, originator: "codex_desktop", threadSource: "subagent")).scope == .subagent)
        #expect(attention(Self.meta(id: "c1", source: ["subagent": "review"], originator: "codex_desktop")).scope == .subagent)
        #expect(attention(Self.meta(id: "c1", source: ["internal": "guardian"], originator: "codex_desktop")).scope == .subagent)
        #expect(attention(Self.meta(id: "c1", source: "exec", originator: "codex_exec")).scope == .scripted)
        #expect(attention(Self.meta(id: "c1", source: "vscode", originator: "Claude Code", threadSource: "user")).scope == .scripted)
        #expect(attention(Self.meta(id: "c1", source: "vscode", originator: "codex_desktop", threadSource: "user")).scope == .owner)
        #expect(CodexAttention().scope == nil)

        var forked = attention(Self.meta(id: "c2", source: "cli", originator: "codex_cli_rs"))
        forked.apply(R.line("session_meta", Self.meta(id: "c1", source: Self.threadSpawn, originator: "codex_desktop"), at: 1))
        #expect(forked.scope == .owner)
    }

    // MARK: Claude

    /// P251: `claude -p` (a research harness's runs) and `claude mcp serve`. Hidden from the lists and silent; Show
    /// scripted runs lists them, and they still never notify.
    @Test
    func aHeadlessClaudeRunIsHiddenAndSilent() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        for (id, entrypoint) in [("p1", "sdk-cli"), ("p2", "sdk-cli"), ("p3", "mcp")] {
            claudeTurn(engine, id, entrypoint: entrypoint, clock: clock)
        }
        #expect(signals.current.isEmpty)
        #expect(engine.rows.isEmpty && engine.overflow.isEmpty)
        #expect(engine.scope(of: engine.state.session(id: "p1")!) == .scripted)

        engine.showsScriptedRuns = true
        #expect(Set(engine.rows.map(\.id)) == ["p1", "p2", "p3"])
        engine.ingest(F.prompt("p1", "again"), ingress: .bridge)
        engine.ingest(F.completed("p1"), ingress: .bridge)
        pass(engine, clock)
        #expect(signals.current.isEmpty)
    }

    /// Every surface the owner sits at keeps its Done: the terminal, the Claude app, an editor, the desktop's local agent,
    /// and a session no note speaks for (a helper not yet updated).
    @Test
    func theOwnersClaudeSurfacesStillNotify() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        let surfaces: [(String, String?)] = [("t", "cli"), ("d", "claude-desktop"), ("v", "claude-vscode"), ("l", "local-agent"), ("n", nil)]
        for (id, entrypoint) in surfaces { claudeTurn(engine, id, entrypoint: entrypoint, clock: clock) }
        #expect(signals.current == surfaces.map { .done(sessionID: $0.0) })
        #expect(Set(engine.rows.map(\.id)) == Set(surfaces.map(\.0)))
    }

    /// P256: an editor's chat built on the Agent SDK is the owner's. Zed's Claude Agent (the ACP adapter) runs the SDK
    /// with the owner's settings, so their hooks fire, and sets no `CLAUDE_CODE_ENTRYPOINT`: the SDK names it `sdk-ts`
    /// (`sdk-py` from Python). Two prompts, two Dones, one row.
    @Test
    func anEditorsAgentSDKChatIsTheOwners() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        claudeTurn(engine, "zed", entrypoint: "sdk-ts", clock: clock)
        engine.ingest(note: claudeNote("zed", entrypoint: "sdk-ts"))
        engine.ingest(F.prompt("zed", "and the tests"), ingress: .bridge)
        engine.ingest(note: claudeNote("zed", "Stop", entrypoint: "sdk-ts"))
        engine.ingest(F.completed("zed"), ingress: .bridge)
        pass(engine, clock)
        claudeTurn(engine, "py", entrypoint: "sdk-py", clock: clock)
        #expect(signals.current == [.done(sessionID: "zed"), .done(sessionID: "zed"), .done(sessionID: "py")])
        #expect(Set(engine.rows.map(\.id)) == ["zed", "py"])
        #expect(engine.scope(of: engine.state.session(id: "zed")!) == .owner)
    }

    /// A subagent's note names the subagent (Claude sets `agent_id`): it never makes its parent a scripted run.
    @Test
    func aSubagentsNoteNeverRetagsItsParent() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        engine.ingest(note: claudeNote("s1", "SessionStart", entrypoint: "cli"))
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.prompt("s1"), ingress: .bridge)
        engine.ingest(note: claudeNote("s1", "PreToolUse", entrypoint: "sdk-cli", agentID: "a1"))
        engine.ingest(F.completed("s1"), ingress: .bridge)
        pass(engine, clock)
        #expect(signals.current == [.done(sessionID: "s1")])
    }

    /// The same session later driven by `claude -p --resume` is a scripted run while it is; back in the terminal it is
    /// the owner's again.
    @Test
    func theLatestRootNoteSaysWhoRunsTheSession() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        claudeTurn(engine, "s1", entrypoint: "sdk-cli", clock: clock)
        #expect(engine.rows.isEmpty)
        engine.ingest(note: claudeNote("s1", entrypoint: "cli"))
        engine.ingest(F.prompt("s1", "and the docs"), ingress: .bridge)
        engine.ingest(F.completed("s1"), ingress: .bridge)
        pass(engine, clock)
        #expect(signals.current == [.done(sessionID: "s1")])
        #expect(engine.rows.map(\.id) == ["s1"])
    }

    /// P253: a background task's notification wakes the owner's idle chat, and the turn it starts is where the task's
    /// result arrives: the moment the owner waits on. Its Stop is one Done, like any turn (P155); the row runs, then
    /// shows its last message.
    @Test
    func aBackgroundTasksResultIsOneDone() throws {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        claudeTurn(engine, "s1", entrypoint: "cli", clock: clock)
        #expect(signals.current == [.done(sessionID: "s1")])

        clock.update { $0 = $0.addingTimeInterval(60) }
        engine.ingest(F.prompt("s1", "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>"), ingress: .bridge)
        #expect(engine.rows.first?.phase == .running)
        engine.ingest(F.running("s1"), ingress: .bridge)
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "3 failures: parser, lexer, docs.", timestamp: clock.current)),
                      ingress: .bridge)
        pass(engine, clock)
        #expect(signals.current == [.done(sessionID: "s1"), .done(sessionID: "s1")])
        let row = try #require(engine.rows.first)
        #expect(row.phase == .completed && row.summary == "3 failures: parser, lexer, docs.")
    }

    /// A notification that lands while the owner's Done is still held goes on with that turn: the held Done is
    /// dropped and the turn's end gives one, so a result that comes at once is heard once, with its text.
    @Test
    func aNotificationDuringTheHoldGivesOneDoneAtItsEnd() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.prompt("s1"), ingress: .bridge)
        engine.ingest(F.completed("s1"), ingress: .bridge)
        clock.update { $0 = $0.addingTimeInterval(0.5) }
        engine.ingest(F.prompt("s1", "<task-notification>\n<task-id>b1</task-id>"), ingress: .bridge)
        pass(engine, clock)
        #expect(signals.current.isEmpty)
        engine.ingest(F.completed("s1"), ingress: .bridge)
        pass(engine, clock)
        #expect(signals.current == [.done(sessionID: "s1")])
    }

    /// Every wake-up is a turn of the owner's chat, wherever it lands: injected mid-turn it goes on with that turn (one
    /// Done at its end), and on an idle chat a teammate's message or a second notification in the same turn is one
    /// Done at that turn's end.
    @Test
    func aWakeUpIsATurnOfTheOwnersChat() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        let wake = "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>"
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.prompt("s1"), ingress: .bridge)
        engine.ingest(F.prompt("s1", wake), ingress: .bridge)
        engine.ingest(F.completed("s1"), ingress: .bridge)
        pass(engine, clock)
        #expect(signals.current == [.done(sessionID: "s1")])

        engine.ingest(F.prompt("s1", wake), ingress: .bridge)
        engine.ingest(F.prompt("s1", "<teammate-message teammate_id=\"worker\">done</teammate-message>"), ingress: .bridge)
        engine.ingest(F.completed("s1"), ingress: .bridge)
        pass(engine, clock)
        #expect(signals.current == [.done(sessionID: "s1"), .done(sessionID: "s1")])
    }

    /// Subagents finishing are activity on the parent (the bridge's SubagentStop), never a Done; a subagent's own
    /// transcript is never a session that notifies (P250).
    @Test
    func claudeSubagentsNeverNotifyOnTheirOwn() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.prompt("s1"), ingress: .bridge)
        for agent in ["Explore", "worker", "reviewer"] {
            engine.ingest(F.running("s1", summary: "Started \(agent) subagent."), ingress: .bridge)
            engine.ingest(F.running("s1", summary: "Finished \(agent) subagent."), ingress: .bridge)
            pass(engine, clock)
        }
        engine.ingest(F.started("child", transcript: "/tmp/projects/p/s1/subagents/agent-a1.jsonl"), ingress: .bridge)
        engine.ingest(F.prompt("child", "look around"), ingress: .bridge)
        engine.ingest(F.completed("child"), ingress: .bridge)
        pass(engine, clock)
        #expect(signals.current.isEmpty)
        engine.ingest(F.completed("s1"), ingress: .bridge)
        pass(engine, clock)
        #expect(signals.current == [.done(sessionID: "s1")])
    }

    /// A request from a scripted run still surfaces and sounds where the book puts it (a Codex task's approval is shown
    /// read-only); once it is over the run is hidden again, and its turn end is still no Done. A headless Claude run's
    /// request is not shown at all, as the book decided (its SDK host answers it).
    @Test
    func aScriptedRunThatWaitsStillSurfaces() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        engine.ingest(F.started("task", tool: .codex, transcript: nil, title: "Codex · project"), ingress: .bridge)
        engine.ingest(F.prompt("task", "fix the flaky test"), ingress: .bridge)
        #expect(engine.rows.isEmpty)
        engine.ingest(F.permission("task", toolUseID: "call_1"), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(engine.rows.map(\.id) == ["task"])
        #expect(engine.needsYouCount == 1)
        #expect(signals.current == [.needsYou(sessionID: "task")])
        engine.ingest(F.completed("task"), ingress: .bridge)
        pass(engine, clock)
        #expect(engine.rows.isEmpty)
        #expect(signals.current == [.needsYou(sessionID: "task")])

        engine.ingest(note: claudeNote("p1", "SessionStart", entrypoint: "sdk-cli"))
        engine.ingest(F.started("p1"), ingress: .bridge)
        engine.ingest(F.prompt("p1"), ingress: .bridge)
        engine.ingest(F.permission("p1"), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(engine.rows.isEmpty)
    }

    // MARK: Codex

    /// P252: a Codex thread its hooks report with no rollout is ephemeral: the codex plugin's Codex Companion Tasks, a
    /// `codex exec --ephemeral`. Hidden and silent; a thread with a rollout is the owner's until its rollout says
    /// otherwise.
    @Test
    func anEphemeralCodexThreadIsAScriptedRun() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        codexTurn(engine, "task", transcript: nil, clock: clock)
        #expect(signals.current.isEmpty)
        #expect(engine.rows.isEmpty)
        codexTurn(engine, "tui", transcript: "/tmp/sessions/rollout-tui.jsonl", clock: clock)
        #expect(signals.current == [.done(sessionID: "tui")])
        #expect(engine.rows.map(\.id) == ["tui"])
    }

    /// A persisted plugin task ("Claude Code" is the plugin's app-server client) and `codex exec` are scripted by their
    /// rollout's `session_meta`, which the tracker hands on with its first read.
    @Test
    func aPersistedPluginOrExecThreadIsScriptedByItsRollout() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        let runs: [(String, [String: Any])] = [
            ("plugin", Self.meta(id: "plugin", source: "vscode", originator: "Claude Code", threadSource: "user")),
            ("exec", Self.meta(id: "exec", source: "exec", originator: "codex_exec")),
        ]
        for (id, meta) in runs {
            engine.ingest(F.started(id, tool: .codex, transcript: "/tmp/sessions/rollout-\(id).jsonl"), ingress: .bridge)
            engine.ingestCodexAttention(CodexAttentionUpdate(sessionID: id, events: [], state: attention(meta)))
            engine.ingest(F.prompt(id, "review the diff"), ingress: .bridge)
            engine.ingest(F.completed(id), ingress: .bridge)
            pass(engine, clock)
        }
        #expect(signals.current.isEmpty)
        #expect(engine.rows.isEmpty)
    }

    /// The Codex app's children: a thread another thread spawned, and an auto-review thread. Their rollouts come in
    /// through the rescan with a Done of their own today; now none (their rows are the threads branch's).
    @Test
    func aCodexChildThreadNeverNotifies() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        engine.ingest(F.started("root", tool: .codex, transcript: "/tmp/sessions/rollout-root.jsonl"), ingress: .bridge)
        engine.ingest(F.prompt("root", "fan out"), ingress: .bridge)
        for n in 1...5 {
            rescannedThreadTurn(engine, "child\(n)", meta: Self.meta(id: "child\(n)", source: Self.threadSpawn,
                                                                     originator: "codex_desktop", threadSource: "subagent"), clock: clock)
        }
        rescannedThreadTurn(engine, "review", meta: Self.meta(id: "review", source: ["subagent": ["other": "guardian"]],
                                                                originator: "codex_desktop", threadSource: "guardian_review"), clock: clock)
        #expect(signals.current.isEmpty)
        // The owner's own app thread, found the same way, keeps its Done.
        rescannedThreadTurn(engine, "mine", meta: Self.meta(id: "mine", source: "vscode", originator: "codex_desktop", threadSource: "user"),
                            clock: clock)
        #expect(signals.current == [.done(sessionID: "mine")])
    }

    /// P257: the owner takes up a plugin task (`/codex:transfer`, or its printed `codex resume <id>`) in Terminal.
    /// Codex writes no new `session_meta` on resume, so the rollout still says "Claude Code"; the resume's SessionStart
    /// comes from a process outside Claude (no `CLAUDE_CODE_ENTRYPOINT`), and from then on the chat is the owner's:
    /// listed, one Done per turn, whatever the tracker reads again.
    @Test
    func theOwnersResumeOfAPluginThreadIsTheirs() throws {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        codexThread(engine, "plugin", meta: Self.pluginMeta, entrypoint: "cli", clock: clock)
        #expect(signals.current.isEmpty && engine.rows.isEmpty)

        codexHookedTurn(engine, "plugin", meta: Self.pluginMeta, entrypoint: nil, resume: true, clock: clock)
        codexHookedTurn(engine, "plugin", meta: Self.pluginMeta, entrypoint: nil, clock: clock)
        #expect(signals.current == [.done(sessionID: "plugin"), .done(sessionID: "plugin")])
        #expect(engine.rows.map(\.id) == ["plugin"])
        #expect(engine.scope(of: try #require(engine.state.session(id: "plugin"))) == .owner)
    }

    /// The same for `codex resume <exec-id>`: a harness's `codex exec` outside Claude has no entrypoint either, so only
    /// a resume says the owner took it up. A harness's `codex exec` stays a scripted run.
    @Test
    func theOwnersResumeOfAnExecThreadIsTheirs() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        codexThread(engine, "exec", meta: Self.execMeta, entrypoint: nil, clock: clock)
        codexHookedTurn(engine, "exec", meta: Self.execMeta, entrypoint: nil, clock: clock)
        #expect(signals.current.isEmpty && engine.rows.isEmpty)

        codexHookedTurn(engine, "exec", meta: Self.execMeta, entrypoint: nil, resume: true, source: "codex", clock: clock)
        #expect(signals.current == [.done(sessionID: "exec")])
        #expect(engine.rows.map(\.id) == ["exec"])
    }

    /// The plugin resuming its own task runs under Claude (`/codex:rescue --resume`): still a scripted run. Neither a
    /// resume nor any hook ever makes a child thread the owner's.
    @Test
    func aResumeUnderClaudeOrOfAChildChangesNothing() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        codexThread(engine, "plugin", meta: Self.pluginMeta, entrypoint: "cli", clock: clock)
        codexHookedTurn(engine, "plugin", meta: Self.pluginMeta, entrypoint: "cli", resume: true, clock: clock)
        let child = Self.meta(id: "child", source: Self.threadSpawn, originator: "codex_desktop", threadSource: "subagent")
        codexThread(engine, "child", meta: child, entrypoint: nil, clock: clock)
        codexHookedTurn(engine, "child", meta: child, entrypoint: nil, resume: true, clock: clock)
        #expect(signals.current.isEmpty)
        #expect(engine.rows.map(\.id) == ["child"] && engine.scopes["child"] == .subagent)
        #expect(engine.scopes["plugin"] == .scripted)
    }

    /// After a relaunch the resume is gone, but the plugin's app-server always runs under Claude: any hook of the
    /// thread from a process outside it (the owner's Codex, the Codex app) is not the plugin's, whichever of the note
    /// and the rollout's read comes first. A `codex exec` outside Claude says nothing that way.
    @Test
    func aHookOutsideClaudeEndsOnlyThePluginsClaim() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        let signals = recording(engine)
        engine.ingest(F.started("plugin", tool: .codex, transcript: "/tmp/sessions/rollout-plugin.jsonl", title: "Codex · project"),
                      ingress: .bridge)
        codexHookedTurn(engine, "plugin", meta: Self.pluginMeta, entrypoint: nil, clock: clock)
        codexThread(engine, "exec", meta: Self.execMeta, entrypoint: nil, clock: clock)
        #expect(signals.current == [.done(sessionID: "plugin")])
        #expect(engine.rows.map(\.id) == ["plugin"])
    }

    /// What is known of a session goes with it.
    @Test
    func aScopeIsForgottenWithItsSession() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        claudeTurn(engine, "p1", entrypoint: "sdk-cli", clock: clock)
        #expect(engine.scopes["p1"] == .scripted)
        #expect(engine.bookkeptSessionIDs.contains("p1"))
        engine.forgetSession("p1")
        #expect(engine.scopes["p1"] == nil)
    }
}
