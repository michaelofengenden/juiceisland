import Foundation
import IslandHookNotes
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// The owner's question of 2026-09-26: "when it notifies me an agent is done, it's not really any of my live sessions,
/// are those subagents?" (P250-P257). Through the live model, its sounds and the island's finish: only the owner's own
/// top-level sessions give the Done card and the Done sound, and count in the pill. The engine's bridge,
/// runtime and frontmost check are stand-ins; no socket is bound and no sound plays. Shapes as in `DoneScopeTests`.
@MainActor
struct DoneScopeUITests {
    final class Probe: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private final class StubBridge: EngineBridge, @unchecked Sendable {
        func updateStateSnapshot(_ snapshot: SessionState) {}
        func stop() {}
    }

    private func makeLive(_ probe: Probe, settings: AppSettings, player: RecordingSoundPlayer) -> LiveSessions {
        settings.liveSessions = true
        let live = LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .prototype).makeModel() }, engine: {
            var configuration = SessionEngine.Configuration.headless
            configuration.startBridge = true
            configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
            var dependencies = SessionEngine.Dependencies()
            dependencies.isOtherIslandRunning = { false }
            dependencies.socketHasOwner = { _ in false }
            dependencies.startBridge = { _ in StubBridge() }
            dependencies.startRuntime = { _ in }
            dependencies.updateProcessRoots = { _ in }
            dependencies.isSessionFrontmost = { _ in false }
            dependencies.frontmostBundleID = { nil }
            dependencies.now = { probe.now }
            dependencies.scheduleSignalCheck = { _, _ in }
            dependencies.readCodexSettings = { _ in nil }
            return SessionEngine(configuration: configuration, dependencies: dependencies)
        }, profiles: { LiveProfiles(accounts: [], discovered: []) }, sounds: player)
        live.activate()
        return live
    }

    // MARK: What the bridge, the notes and the tracker send

    private static func note(_ id: String, _ event: String, entrypoint: String?, agentID: String? = nil) -> HookContextNote {
        HookContextNote(event: event, sessionID: id, agentPID: 900, agentID: agentID, entrypoint: entrypoint, source: "claude")
    }

    private static func started(_ id: String, tool: AgentTool = .claudeCode, transcript: String? = nil, at date: Date) -> AgentEvent {
        .sessionStarted(SessionStarted(sessionID: id, title: tool == .codex ? "Codex · project" : "Claude · project", tool: tool,
                                       origin: .live, initialPhase: .running, summary: "Started.", timestamp: date,
                                       jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project", paneTitle: "agent",
                                                              workingDirectory: "/tmp/project", terminalTTY: "/dev/ttys003"),
                                       codexMetadata: tool == .codex ? CodexSessionMetadata(transcriptPath: transcript) : nil,
                                       claudeMetadata: tool == .claudeCode ? ClaudeSessionMetadata(transcriptPath: transcript) : nil))
    }

    private static func activity(_ id: String, _ summary: String, at date: Date) -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: id, summary: summary, phase: .running, timestamp: date))
    }

    private static func completed(_ id: String, _ summary: String = "Done.", at date: Date) -> AgentEvent {
        .sessionCompleted(SessionCompleted(sessionID: id, summary: summary, timestamp: date))
    }

    /// A Claude session with its surface's entrypoint, prompted.
    private func claude(_ engine: SessionEngine, _ id: String, entrypoint: String, prompt: String, _ probe: Probe) {
        engine.ingest(note: Self.note(id, "SessionStart", entrypoint: entrypoint))
        engine.ingest(Self.started(id, at: probe.now), ingress: .bridge)
        engine.ingest(note: Self.note(id, "UserPromptSubmit", entrypoint: entrypoint))
        engine.ingest(Self.activity(id, "Prompt: \(prompt)", at: probe.now), ingress: .bridge)
    }

    private func end(_ engine: SessionEngine, _ id: String, _ probe: Probe) {
        engine.ingest(Self.completed(id, at: probe.now), ingress: .bridge)
    }

    private func pass(_ engine: SessionEngine, _ probe: Probe) {
        probe.now += SignalPipeline.doneHold
        engine.flushHeldSignals()
    }

    private static let spawned: [String: Any] = ["subagent": ["thread_spawn": ["parent_thread_id": "root", "depth": 1]]]

    /// A Codex app thread the rescan found (no hook of its own id): its rollout's first read, then a turn it finishes.
    private func rescannedThread(_ engine: SessionEngine, _ id: String, source: Any, threadSource: String, _ probe: Probe) {
        var thread = AgentSession(id: id, title: "Codex · project", tool: .codex, origin: .live, phase: .completed, summary: "Started.",
                                  updatedAt: probe.now, codexMetadata: CodexSessionMetadata(
                                      transcriptPath: "/tmp/sessions/rollout-\(id).jsonl", initialUserPrompt: "Map the parser"))
        thread.isCodexAppSession = true
        engine.replace(thread)
        var fold = CodexAttention()
        fold.apply(RolloutLines.line("session_meta", ["id": id, "cwd": "/tmp/project", "originator": "codex_desktop", "source": source,
                                                      "thread_source": threadSource], at: 0))
        engine.ingestCodexAttention(CodexAttentionUpdate(sessionID: id, events: [], state: fold))
        engine.ingest(Self.activity(id, "Thinking.", at: probe.now), ingress: .rollout)
        engine.ingest(Self.completed(id, "Found them.", at: probe.now), ingress: .rollout)
    }

    // MARK: The owner's evening, replayed

    /// Several subagents, scripted runs, plugin tasks and the Codex app's children all finish: nothing. Then a
    /// background task's result wakes the owner's other chat, and the chat they wait on finishes: one Done card and one
    /// Done sound each, only for the owner's own chats.
    @Test
    func onlyTheOwnersChatsGiveADoneCardAndSound() throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        settings.suppressForFocusedSessions = false
        settings.doneSound = .system("Hero")
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)

        // Before: the owner's other chat finished its own turn (heard), and the chat they wait on runs.
        claude(engine, "other", entrypoint: "claude-desktop", prompt: "summarise the paper", probe)
        end(engine, "other", probe)
        pass(engine, probe)
        claude(engine, "chat", entrypoint: "cli", prompt: "fix the parser", probe)
        // The owner's Codex thread that fans out: hooked, with its rollout.
        engine.ingest(Self.started("root", tool: .codex, transcript: "/tmp/sessions/rollout-root.jsonl", at: probe.now), ingress: .bridge)
        engine.ingest(Self.activity("root", "Prompt: fan out over the parser", at: probe.now), ingress: .bridge)
        #expect(player.played == ["Hero"])
        let heard = live.finishSource

        probe.now += 60
        // The chat's subagents start and finish (SubagentStart/Stop are the parent's running activity).
        for agent in ["Explore", "worker", "reviewer"] {
            engine.ingest(Self.activity("chat", "Started \(agent) subagent.", at: probe.now), ingress: .bridge)
            engine.ingest(note: Self.note("chat", "PreToolUse", entrypoint: "cli", agentID: "a-\(agent)"))
            engine.ingest(Self.activity("chat", "Finished \(agent) subagent.", at: probe.now), ingress: .bridge)
        }
        // A research harness's `claude -p` runs, and Claude as another agent's MCP tool.
        for (id, entrypoint) in [("run1", "sdk-cli"), ("run2", "sdk-cli"), ("run3", "sdk-cli"), ("tool", "mcp")] {
            claude(engine, id, entrypoint: entrypoint, prompt: "score attempt \(id)", probe)
            end(engine, id, probe)
        }
        // The codex plugin's Codex Companion Task (ephemeral: its hooks name no rollout) and a `codex exec`.
        engine.ingest(Self.started("companion", tool: .codex, at: probe.now), ingress: .bridge)
        engine.ingest(Self.activity("companion", "Prompt: investigate the flaky test", at: probe.now), ingress: .bridge)
        end(engine, "companion", probe)
        engine.ingest(Self.started("exec", tool: .codex, transcript: "/tmp/sessions/rollout-exec.jsonl", at: probe.now), ingress: .bridge)
        var exec = CodexAttention()
        exec.apply(RolloutLines.line("session_meta", ["id": "exec", "cwd": "/tmp/project", "originator": "codex_exec", "source": "exec"], at: 0))
        engine.ingestCodexAttention(CodexAttentionUpdate(sessionID: "exec", events: [], state: exec))
        engine.ingest(Self.activity("exec", "Prompt: run the benchmark", at: probe.now), ingress: .bridge)
        end(engine, "exec", probe)
        // The Codex app's children: five spawned threads and an auto-review thread.
        for n in 1...5 { rescannedThread(engine, "child\(n)", source: Self.spawned, threadSource: "subagent", probe) }
        rescannedThread(engine, "review", source: ["subagent": ["other": "guardian"]], threadSource: "guardian_review", probe)
        pass(engine, probe)
        #expect(player.played == ["Hero"])
        #expect(live.finishSource == heard)

        // A background task finishes in the other chat: the turn its notification wakes carries the result (P253).
        engine.ingest(Self.activity("other", "Prompt: <task-notification>\n<task-id>b1</task-id>\n<status>completed</status>",
                                    at: probe.now), ingress: .bridge)
        end(engine, "other", probe)
        pass(engine, probe)
        #expect(player.played == ["Hero", "Hero"])
        let woke = try #require({ if case let .engine(last) = live.finishSource { last } else { nil } }())
        #expect(woke.sessionID == "other")
        let before = live.rows

        // The chat the owner waits on finishes.
        end(engine, "chat", probe)
        pass(engine, probe)
        #expect(player.played == ["Hero", "Hero", "Hero"])
        let finish = try #require({ if case let .engine(last) = live.finishSource { last } else { nil } }())
        #expect(finish.sessionID == "chat")
        let signals = IslandAttention.signals(old: before, new: live.rows, source: live.finishSource, seen: woke)
        #expect(signals == [.finished("chat")])
        let response = IslandAttention.respond(to: signals, rows: live.rows, finish: .card, cardInUse: false)
        #expect(response.card == "chat" && response.brief)

        // No scripted run is a row; the children's rows (the threads branch folds them) never count.
        let ids = Set(live.rows.map(\.id))
        #expect(ids.isDisjoint(with: ["run1", "run2", "run3", "tool", "companion", "exec"]))
        #expect(live.rows.filter { !$0.isQuiet }.map(\.id).sorted() == ["chat", "other", "root"].sorted())
        #expect(PillSummary.make(rows: live.rows, countMode: .active, now: probe.now).count == 3)
        let layout = IslandListLayout.make(rows: live.rows, style: .clean, showAll: false, now: probe.now, visible: 3)
        #expect(layout.footer == .earlier)
    }

    /// Show scripted runs lists them; they never count in the pill, lead it or give a Done. A running one the rows
    /// hide is one more in the footer, never "Earlier" (P254). Off again, they go.
    @Test
    func scriptedRunsShowOnlyWhenAskedAndNeverCountInThePill() async throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        settings.suppressForFocusedSessions = false
        settings.doneSound = .system("Hero")
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        #expect(!engine.showsScriptedRuns)
        claude(engine, "chat", entrypoint: "cli", prompt: "fix the parser", probe)
        claude(engine, "run", entrypoint: "sdk-cli", prompt: "score attempt 7", probe)
        #expect(live.rows.map(\.id) == ["chat"])

        settings.showScriptedRuns = true
        for _ in 0..<100 where !engine.showsScriptedRuns { try await Task.sleep(for: .milliseconds(5)) }
        #expect(Set(live.rows.map(\.id)) == ["chat", "run"])
        let run = try #require(live.row(id: "run"))
        #expect(run.isQuiet && !SessionActivity.isActive(run, now: probe.now))
        #expect(PillSummary.make(rows: live.rows, countMode: .active, now: probe.now).count == 1)
        let pill = PillContent.make(rows: live.rows, settings: settings, glance: false, recentlyFinished: nil, now: probe.now,
                                    notch: IslandTheme.Metrics.referenceNotch, menuBar: IslandTheme.Metrics.referenceMenuBar)
        #expect(pill.count == 1 && pill.lead?.agent == .claude)
        let layout = IslandListLayout.make(rows: SessionListLayout.displayOrder(live.rows, now: probe.now), style: .clean,
                                           showAll: false, now: probe.now, visible: 1)
        #expect(layout.shown.map(\.id) == ["chat"] && layout.footer == .more(1) && layout.footerMarks == [.running(.claude)])
        #expect(IslandFooterLabel.underCard("chat", rows: live.rows, now: probe.now) == .more(1))
        end(engine, "run", probe)
        pass(engine, probe)
        #expect(player.played.isEmpty)
        let finished = IslandListLayout.make(rows: live.rows, style: .clean, showAll: false, now: probe.now, visible: 1)
        #expect(finished.footer == .earlier)

        settings.showScriptedRuns = false
        for _ in 0..<100 where engine.showsScriptedRuns { try await Task.sleep(for: .milliseconds(5)) }
        #expect(live.rows.map(\.id) == ["chat"])
    }

    /// A scripted run that waits on the owner sounds Needs you and shows, as any request does; its turn's end is still
    /// no Done. The switch's subtitle says only what a scripted run is.
    @Test
    func aScriptedRunThatWaitsSoundsNeedsYouButNeverDone() throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        settings.suppressForFocusedSessions = false
        settings.doneSound = .system("Hero")
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        engine.ingest(Self.started("companion", tool: .codex, at: probe.now), ingress: .bridge)
        engine.ingest(Self.activity("companion", "Prompt: fix the flaky test", at: probe.now), ingress: .bridge)
        engine.ingest(.permissionRequested(PermissionRequested(sessionID: "companion", request: PermissionRequest(
            title: "Bash", summary: "git status", affectedPath: "/tmp/project", toolName: "Bash", toolUseID: "call_1"),
            timestamp: probe.now)), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(player.played == ["Glass"])
        #expect(live.rows.map(\.id) == ["companion"])
        end(engine, "companion", probe)
        pass(engine, probe)
        #expect(player.played == ["Glass"])
        #expect(IslandPaneText.scriptedRuns == "Headless and plugin runs.")
    }
}
