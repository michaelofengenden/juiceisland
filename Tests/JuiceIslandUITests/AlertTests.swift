import Foundation
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// Records what would have played, and at what volume: no sound is ever made (P33: nothing plays, so no `NSSound`
/// exists, while muted).
@MainActor
final class RecordingSoundPlayer: SoundPlaying {
    private(set) var played: [String] = []
    private(set) var volumes: [Float] = []
    func play(_ name: String, volume: Float) {
        played.append(name)
        volumes.append(volume)
    }
}

/// The live engine's signals as sounds and as the island's finishes (spec §3.4, §4.5): Needs you, Done, Mute, None,
/// No alerts for focused sessions and Show Codex app threads. The engine's bridge, runtime, jumps and frontmost check are
/// stand-ins: no socket is bound, no AppleScript runs and no sound plays.
@MainActor
struct AlertTests {
    final class Probe: @unchecked Sendable {
        var frontmost = false
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
            dependencies.isSessionFrontmost = { _ in probe.frontmost }
            dependencies.frontmostBundleID = { nil }
            dependencies.now = { probe.now }
            dependencies.scheduleSignalCheck = { _, _ in }
            return SessionEngine(configuration: configuration, dependencies: dependencies)
        }, profiles: { LiveProfiles(accounts: [], discovered: []) }, sounds: player)
        live.activate()
        return live
    }

    // Events shaped as upstream's bridge sends them.
    /// A Codex thread's hooks name its rollout (one with none is an ephemeral run, which never notifies, P252).
    private static func started(_ id: String, tool: AgentTool = .claudeCode, at date: Date) -> AgentEvent {
        .sessionStarted(SessionStarted(sessionID: id, title: "Claude · project", tool: tool, origin: .live, initialPhase: .running,
                                       summary: "Started.", timestamp: date,
                                       jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "project", paneTitle: "claude",
                                                              workingDirectory: "/tmp/project", terminalTTY: "/dev/ttys003"),
                                       codexMetadata: tool == .codex ? CodexSessionMetadata(transcriptPath: "/tmp/sessions/rollout-\(id).jsonl") : nil))
    }

    private static func prompt(_ id: String, at date: Date) -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: id, summary: "Prompt: fix the tests", phase: .running, timestamp: date))
    }

    private static func permission(_ id: String, _ toolUseID: String, at date: Date) -> AgentEvent {
        .permissionRequested(PermissionRequested(sessionID: id, request: PermissionRequest(
            title: "Bash", summary: "git status", affectedPath: "/tmp/project", toolName: "Bash", toolUseID: toolUseID), timestamp: date))
    }

    private static func completed(_ id: String, at date: Date) -> AgentEvent {
        .sessionCompleted(SessionCompleted(sessionID: id, summary: "Done.", timestamp: date))
    }

    /// A turn that finishes, and the engine's 1.5 s hold passing.
    private func finish(_ id: String, _ engine: SessionEngine, _ probe: Probe) {
        engine.ingest(Self.prompt(id, at: probe.now), ingress: .bridge)
        engine.ingest(Self.completed(id, at: probe.now), ingress: .bridge)
        probe.now += SignalPipeline.doneHold
        engine.flushHeldSignals()
    }

    @Test
    func needsYouAndDonePlayTheirOwnSoundsOnceAndTheDoneReachesTheIsland() async throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        settings.suppressForFocusedSessions = false
        settings.doneSound = .system("Hero")
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        engine.ingest(Self.started("s1", at: probe.now), ingress: .bridge)
        engine.ingest(Self.permission("s1", "toolu_1", at: probe.now), ingress: .bridge)
        engine.ingest(Self.permission("s1", "toolu_1", at: probe.now), ingress: .bridge)
        // Nothing sounds until the request is confirmed (its 8 s window here), and then once.
        #expect(player.played.isEmpty)
        engine.passAttentionWindows()
        engine.passAttentionWindows()
        #expect(player.played == ["Glass"])
        #expect(live.finishSource == .engine(last: nil))
        await engine.approve(sessionID: "s1", decision: .allowOnce)
        finish("s1", engine, probe)
        #expect(player.played == ["Glass", "Hero"])
        #expect(live.finishSource == .engine(last: ReleasedFinish(sessionID: "s1", serial: 1)))
    }

    @Test
    func muteAndNonePlayNothing() throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        settings.suppressForFocusedSessions = false
        settings.soundsMuted = true
        settings.doneSound = .system("Hero")
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        engine.ingest(Self.started("s1", at: probe.now), ingress: .bridge)
        engine.ingest(Self.permission("s1", "toolu_1", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        engine.ingest(Self.started("s2", at: probe.now), ingress: .bridge)
        finish("s2", engine, probe)
        #expect(player.played.isEmpty)
        // Mute stops only the sound: the island still hears the Done.
        #expect(live.finishSource == .engine(last: ReleasedFinish(sessionID: "s2", serial: 1)))

        settings.soundsMuted = false
        settings.needsYouSound = .none
        settings.doneSound = .none
        engine.ingest(Self.permission("s1", "toolu_2", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        finish("s2", engine, probe)
        #expect(player.played.isEmpty)
    }

    /// No alerts for focused sessions: nothing for the session whose tab is in front, neither a sound nor the island's
    /// Done; the switch reaches the running engine as it changes.
    @Test
    func aFocusedSessionIsQuietWhileTheSwitchIsOn() async throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        settings.doneSound = .system("Hero")
        probe.frontmost = true
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        #expect(engine.suppressWhenFrontmost)
        engine.ingest(Self.started("s1", at: probe.now), ingress: .bridge)
        engine.ingest(Self.permission("s1", "toolu_1", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        await engine.approve(sessionID: "s1", decision: .allowOnce)
        finish("s1", engine, probe)
        try await Task.sleep(for: .milliseconds(50))
        #expect(player.played.isEmpty)
        #expect(live.finishSource == .engine(last: nil))

        settings.suppressForFocusedSessions = false
        for _ in 0..<100 where engine.suppressWhenFrontmost { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!engine.suppressWhenFrontmost)
        finish("s1", engine, probe)
        #expect(player.played == ["Hero"])
        #expect(live.finishSource == .engine(last: ReleasedFinish(sessionID: "s1", serial: 1)))
    }

    /// Show Codex app threads off: a thread's running and done rows and its Done are hidden; a thread that waits always
    /// shows, counts and sounds (spec §3.4).
    @Test
    func codexAppThreadsHideTheirRowsAndDoneButNeverWhatWaits() throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        settings.suppressForFocusedSessions = false
        settings.showCodexAppThreads = false
        settings.doneSound = .system("Hero")
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        engine.ingest(Self.started("app", tool: .codex, at: probe.now), ingress: .bridge)
        engine.ingest(Self.prompt("app", at: probe.now), ingress: .bridge)
        var thread = try #require(engine.state.session(id: "app"))
        thread.isCodexAppSession = true
        engine.replace(thread)
        #expect(live.rows.isEmpty)

        engine.ingest(Self.permission("app", "call_1", at: probe.now), ingress: .bridge)
        #expect(live.rows.map(\.id) == ["app"])
        #expect(live.needsYouCount == 1)
        #expect(player.played == ["Glass"])

        engine.state.resolvePermission(sessionID: "app", resolution: .allowOnce())
        finish("app", engine, probe)
        #expect(live.rows.isEmpty)
        #expect(player.played == ["Glass"])

        // On again: the thread's row and its next Done are back.
        settings.showCodexAppThreads = true
        #expect(live.rows.map(\.id) == ["app"])
        finish("app", engine, probe)
        #expect(player.played == ["Glass", "Hero"])
    }

    /// The owner's Codex app thread as the app's hooks make it (P665): target "Unknown", no bundle id, the app's
    /// originator in its rollout. Upstream never flags it, yet Show Codex app threads off hides its running and done
    /// rows and its Done, as it does any Codex app thread's.
    @Test
    func aHookMadeCodexAppThreadIsHiddenLikeAnyOther() throws {
        let probe = Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        settings.suppressForFocusedSessions = false
        settings.showCodexAppThreads = false
        settings.doneSound = .system("Hero")
        let live = makeLive(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        engine.ingest(.sessionStarted(SessionStarted(
            sessionID: "app", title: "Codex · project", tool: .codex, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: probe.now, jumpTarget: JumpTarget(terminalApp: "Unknown", workspaceName: "project", paneTitle: "Codex app",
                                                         workingDirectory: "/tmp/project"),
            codexMetadata: CodexSessionMetadata(transcriptPath: "/tmp/sessions/rollout-app.jsonl"))), ingress: .bridge)
        engine.ingest(Self.prompt("app", at: probe.now), ingress: .bridge)
        var attention = CodexAttention()
        attention.apply(FixtureSessionFeed.rolloutLine("session_meta", [
            "id": "app", "timestamp": FixtureSessionFeed.stamp(probe.now), "cwd": "/tmp/project", "originator": "Codex Desktop",
            "cli_version": "0.159.0", "source": "vscode"], at: probe.now))
        engine.ingestCodexAttention(CodexAttentionUpdate(sessionID: "app", events: attention.takeEvents(), state: attention))
        #expect(engine.state.session(id: "app")?.isCodexAppSession == false)
        #expect(live.rows.isEmpty)
        finish("app", engine, probe)
        #expect(live.rows.isEmpty)
        #expect(player.played.isEmpty)

        settings.showCodexAppThreads = true
        #expect(live.rows.map(\.id) == ["app"])
        #expect(live.rows.first?.host == "Codex.app")
    }

    // MARK: The island

    private static func row(_ id: String, _ bucket: SessionBucket, status: StatusWord = .working) -> SessionRow {
        SessionRow(id: id, agent: .claude, bucket: bucket, project: "project", task: "Fix the tests", status: status, detail: nil,
                   lastPrompt: nil, host: "Terminal", accountAlias: nil, updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                   isCodexApp: false, glyph: .check, glyphState: .done, hasCard: bucket == .needsYou)
    }

    /// With the live engine the island's finish is the engine's Done, heard once, only while its row shows the
    /// finished turn; a row that turned done is no finish by itself. Needs you still comes from the rows.
    @Test
    func theIslandHearsTheEnginesDoneNotTheRowDiff() {
        let before = [Self.row("a", .running), Self.row("b", .running), Self.row("c", .running)]
        let after = [Self.row("a", .needsYou), Self.row("b", .done), Self.row("c", .done, status: .interrupted)]
        #expect(IslandAttention.signals(old: before, new: after, source: .rows, seen: nil) == [.needsYou("a"), .finished("b")])
        #expect(IslandAttention.signals(old: before, new: after, source: .engine(last: nil), seen: nil) == [.needsYou("a")])

        let done = ReleasedFinish(sessionID: "b", serial: 1)
        #expect(IslandAttention.signals(old: after, new: after, source: .engine(last: done), seen: nil) == [.finished("b")])
        #expect(IslandAttention.signals(old: after, new: after, source: .engine(last: done), seen: done).isEmpty)
        // An interrupt, a row that runs again or a hidden row: nothing.
        for last in [ReleasedFinish(sessionID: "c", serial: 2), ReleasedFinish(sessionID: "gone", serial: 2)] {
            #expect(IslandAttention.signals(old: after, new: after, source: .engine(last: last), seen: done).isEmpty)
        }
        let again = [Self.row("b", .running)]
        #expect(IslandAttention.signals(old: after, new: again, source: .engine(last: ReleasedFinish(sessionID: "b", serial: 2)),
                                        seen: done).isEmpty)
    }
}
