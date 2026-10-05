import Foundation
import Testing
@testable import IslandEngine
import JuiceCore
import OpenIslandCore

/// Holds every frontmost check until the test opens it.
private actor FocusGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

@MainActor
struct SessionEngineTests {
    private typealias F = EngineFixtures

    @Test
    func sessionsAreTaggedWithTheirProfileAlias() {
        let engine = F.engine()
        let work = Account(provider: .claude, folder: "/Users/test/.claude-work", alias: "Work")
        engine.setProfiles(accounts: [work], discovered: [])
        engine.ingest(F.started("s1", transcript: "/Users/test/.claude-work/projects/-tmp-project/s1.jsonl"), ingress: .bridge)
        engine.ingest(F.started("s2", transcript: "/tmp/other/s2.jsonl"), ingress: .bridge)
        #expect(engine.accountTag(for: "s1")?.alias == "Work")
        #expect(engine.accountTag(for: "s1")?.accountID == work.id)
        #expect(engine.accountTag(for: "s2") == nil)
        #expect(engine.lastHookEventAt["claude:/Users/test/.claude-work"] == F.now)
    }

    @Test
    func tagsFollowAnAliasChange() {
        let engine = F.engine()
        engine.setProfiles(accounts: [Account(provider: .claude, folder: "/Users/test/.claude-work", alias: "Work")], discovered: [])
        engine.ingest(F.started("s1", transcript: "/Users/test/.claude-work/projects/-x/s1.jsonl"), ingress: .bridge)
        engine.setProfiles(accounts: [Account(provider: .claude, folder: "/Users/test/.claude-work", alias: "Office")], discovered: [])
        #expect(engine.accountTag(for: "s1")?.alias == "Office")
    }

    @Test
    func juiceReadsAreDroppedAndCounted() {
        let engine = F.engine()
        engine.ingest(F.started("probe", cwd: "/tmp/juice-test-cli"), ingress: .bridge)
        engine.ingest(F.running("probe"), ingress: .bridge)
        engine.ingest(F.completed("probe"), ingress: .bridge)
        #expect(engine.state.sessions.isEmpty)
        #expect(engine.filteredJuiceReadCount == 1)
    }

    @Test
    func anInterruptedTurnSaysInterruptedUntilWorkResumes() throws {
        let engine = F.engine()
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.completed("s1", interrupted: true), ingress: .bridge)
        let session = try #require(engine.state.session(id: "s1"))
        #expect(engine.statusWord(for: session) == .interrupted)
        engine.ingest(F.running("s1"), ingress: .bridge)
        engine.ingest(F.completed("s1"), ingress: .bridge)
        #expect(engine.statusWord(for: try #require(engine.state.session(id: "s1"))) == .done)
    }

    @Test
    func alwaysAllowSendsClaudesOwnRuleNeverAMode() async throws {
        let sent = F.Box<[BridgeCommand]>([])
        let engine = F.engine(sent: sent)
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.permission("s1"), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(engine.alwaysAllowLabel(for: "s1")?.contains("git push") == true)
        #expect(engine.needsYouCount == 1)
        #expect(engine.nextNeedsYou?.id == "s1")

        await engine.approve(sessionID: "s1", decision: .alwaysAllow)
        #expect(sent.current == [.resolvePermission(sessionID: "s1", resolution: .allowOnce(updatedPermissions: [F.gitPushRule]))])
        #expect(engine.state.session(id: "s1")?.phase == .running)
    }

    @Test
    func denySendsOurMessage() async {
        let sent = F.Box<[BridgeCommand]>([])
        let engine = F.engine(sent: sent)
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.permission("s1"), ingress: .bridge)
        engine.passAttentionWindows()
        await engine.approve(sessionID: "s1", decision: .deny)
        #expect(sent.current == [.resolvePermission(sessionID: "s1", resolution: .deny(message: ApprovalChoices.denyMessage, interrupt: false))])
    }

    @Test
    func aLateClickSendsNothing() async {
        let sent = F.Box<[BridgeCommand]>([])
        let engine = F.engine(sent: sent)
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.permission("s1"), ingress: .bridge)
        engine.passAttentionWindows()
        await engine.approve(sessionID: "s1", decision: .allowOnce)
        await engine.approve(sessionID: "s1", decision: .deny)
        await engine.answer(sessionID: "s1", response: QuestionPromptResponse(rawAnswer: "yes"))
        #expect(sent.current == [.resolvePermission(sessionID: "s1", resolution: .allowOnce())])
    }

    @Test
    func signalsNeedsYouAndDoneButNotAnInterrupt() {
        let clock = F.Box(F.now)
        let engine = F.engine(clock: clock)
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.permission("s1"), ingress: .bridge)
        // Nothing sounds for a request not yet confirmed; its 8 s window confirms it.
        #expect(signals.isEmpty)
        engine.passAttentionWindows()
        engine.ingest(F.started("s2"), ingress: .bridge)
        engine.ingest(F.prompt("s2"), ingress: .bridge)
        engine.ingest(F.completed("s2"), ingress: .bridge)
        engine.ingest(F.completed("s2"), ingress: .bridge)
        engine.ingest(F.started("s3"), ingress: .bridge)
        engine.ingest(F.completed("s3", interrupted: true), ingress: .bridge)
        #expect(signals == [.needsYou(sessionID: "s1")])
        clock.update { $0 = $0.addingTimeInterval(SignalPipeline.doneHold) }
        engine.flushHeldSignals()
        #expect(signals == [.needsYou(sessionID: "s1"), .done(sessionID: "s2")])
    }

    @Test
    func aSessionInTheFrontmostTabStaysQuiet() async throws {
        let engine = F.engine(frontmost: true, suppress: true)
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.permission("s1"), ingress: .bridge)
        try await Task.sleep(for: .milliseconds(50))
        #expect(signals.isEmpty)
        #expect(await engine.jumpToNextNeedsYou() == nil)
    }

    /// Copilot CLI and Devin (as CodeBuddy's) and Qwen Code wait on the bridge with no prompt of their own: their
    /// approval sounds whatever tab is in front. A Claude approval shows Claude's own prompt too, and stays quiet (P931).
    @Test
    func anApprovalTheAgentWaitsOnAloneSoundsWhileItsTabIsInFront() async throws {
        let engine = F.engine(frontmost: true, suppress: true)
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        for (id, tool) in [("cp-1", AgentTool.codebuddy), ("qw-1", .qwenCode)] {
            engine.ingest(F.started(id, tool: tool), ingress: .bridge)
            engine.ingest(F.permission(id), ingress: .bridge)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(signals == [.needsYou(sessionID: "cp-1"), .needsYou(sessionID: "qw-1")])
        #expect(engine.attentionHead(for: "cp-1")?.waitsOnIslandAlone == true)
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.permission("s1"), ingress: .bridge)
        engine.passAttentionWindows()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!signals.contains(.needsYou(sessionID: "s1")))
        #expect(engine.attentionHead(for: "s1")?.waitsOnIslandAlone == false)
    }

    /// No alerts for focused sessions is the owner's switch: the app turns it off and on while the engine runs.
    @Test
    func theFocusSwitchTakesEffectWhileTheEngineRuns() async throws {
        let engine = F.engine(frontmost: true, suppress: true)
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.permission("s1", toolUseID: "toolu_A"), ingress: .bridge)
        engine.passAttentionWindows()
        try await Task.sleep(for: .milliseconds(50))
        #expect(signals.isEmpty)
        engine.suppressWhenFrontmost = false
        await engine.approve(sessionID: "s1", decision: .allowOnce)
        engine.ingest(F.permission("s1", toolUseID: "toolu_B"), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(signals == [.needsYou(sessionID: "s1")])
    }

    /// A Codex app thread has no tab (spec §3.4): its approval asks whatever is in front, since the app shows no prompt
    /// of its own while our hook holds it; its Done is quiet only while the Codex app is in front.
    @Test
    func aCodexAppThreadAlwaysAsksAndIsQuietOnlyForItsDoneWhileTheAppIsInFront() throws {
        let clock = F.Box(F.now)
        let front = F.Box<String?>("com.openai.codex")
        let engine = F.engine(frontmost: true, suppress: true, clock: clock, frontmostApp: front)
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        // An app thread's hooks name its rollout; one with none would be an ephemeral run, which never notifies (P252).
        engine.ingest(F.started("app", tool: .codex, transcript: "/tmp/sessions/rollout-app.jsonl"), ingress: .bridge)
        var thread = try #require(engine.state.session(id: "app"))
        thread.isCodexAppSession = true
        engine.replace(thread)
        engine.ingest(F.permission("app"), ingress: .bridge)
        #expect(signals == [.needsYou(sessionID: "app")])
        for (app, heard) in [("com.openai.codex", false), ("com.apple.Terminal", true)] {
            front.update { $0 = app }
            engine.ingest(F.prompt("app"), ingress: .bridge)
            engine.ingest(F.completed("app"), ingress: .bridge)
            clock.update { $0 = $0.addingTimeInterval(SignalPipeline.doneHold) }
            engine.flushHeldSignals()
            #expect(signals.contains(.done(sessionID: "app")) == heard, "\(app)")
        }
    }

    @Test
    func rowsPutWhatNeedsYouFirstAndLeaveSubagentsOut() {
        let engine = F.engine()
        engine.ingest(F.started("run", at: F.now), ingress: .bridge)
        engine.ingest(F.prompt("run", at: F.now), ingress: .bridge)
        engine.ingest(F.started("ask", at: F.now.addingTimeInterval(-600)), ingress: .bridge)
        engine.ingest(F.permission("ask", at: F.now.addingTimeInterval(-600)), ingress: .bridge)
        engine.passAttentionWindows()
        engine.ingest(F.started("sub", transcript: "/tmp/project/abc/subagents/agent-1.jsonl"), ingress: .bridge)
        engine.ingest(F.prompt("sub"), ingress: .bridge)
        #expect(engine.rows.map(\.id) == ["ask", "run"])
        #expect(engine.runningCount == 1)
    }

    @Test
    func aRunningSessionIsTimedFromItsToolOrTurnNotItsLastUpdate() {
        let engine = F.engine()
        let t0 = F.now
        func tool(_ name: String?, at date: Date) -> AgentEvent {
            .claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: "s1", claudeMetadata: ClaudeSessionMetadata(
                lastUserPrompt: "fix the tests", currentTool: name), timestamp: date))
        }
        func since() -> Date? { engine.state.session(id: "s1").flatMap(engine.activeSince(for:)) }
        engine.ingest(F.started("s1", at: t0), ingress: .bridge)
        engine.ingest(F.prompt("s1", at: t0 + 5), ingress: .bridge)
        #expect(since() == t0 + 5)
        engine.ingest(tool("Bash", at: t0 + 60), ingress: .bridge)
        engine.ingest(F.running("s1", summary: "Running Bash", at: t0 + 60), ingress: .bridge)
        #expect(since() == t0 + 60)
        // Progress from the same tool moves the last update, not the tool's start.
        engine.ingest(tool("Bash", at: t0 + 5_000), ingress: .bridge)
        engine.ingest(F.running("s1", summary: "Running Bash", at: t0 + 5_000), ingress: .bridge)
        #expect(engine.state.session(id: "s1")?.updatedAt == t0 + 5_000)
        #expect(since() == t0 + 60)
        // Another tool starts its own clock; with none, the turn's start counts.
        engine.ingest(tool("Edit", at: t0 + 5_100), ingress: .bridge)
        #expect(since() == t0 + 5_100)
        engine.ingest(tool(nil, at: t0 + 5_200), ingress: .bridge)
        engine.ingest(F.running("s1", summary: "Thinking.", at: t0 + 5_200), ingress: .bridge)
        #expect(since() == t0 + 5)
        // A finished turn has no clock; the next prompt starts a new one.
        engine.ingest(F.completed("s1", at: t0 + 6_000), ingress: .bridge)
        #expect(since() == nil)
        engine.ingest(F.prompt("s1", at: t0 + 7_000), ingress: .bridge)
        #expect(since() == t0 + 7_000)
    }

    @Test
    func jumpsAreRecordedNewestFirstAndCapped() async {
        var dependencies = SessionEngine.Dependencies()
        dependencies.jumpRunner.appURL = { _ in URL(fileURLWithPath: "/Applications/Stub.app") }
        dependencies.jumpRunner.isAppRunning = { _ in true }
        dependencies.jumpRunner.appleScript = { _, _ in "matched" }
        dependencies.jumpRunner.open = { _, _ in }
        dependencies.jumpRunner.command = { _, _, _ in false }
        dependencies.updateProcessRoots = { _ in }
        let engine = SessionEngine(configuration: .headless, dependencies: dependencies)
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.started("s2"), ingress: .bridge)
        for _ in 0..<(SessionEngine.recentJumpLimit + 2) { await engine.jump(sessionID: "s1") }
        await engine.jump(sessionID: "s2")
        #expect(engine.recentJumps.count == SessionEngine.recentJumpLimit)
        #expect(engine.recentJumps.map(\.sessionID).prefix(2) == ["s2", "s1"])
        #expect(engine.recentJumps.first?.result == .matched)
        #expect(await engine.jump(sessionID: "missing").result == .noTarget)
    }

    /// P11 and P14: a session is tracked from its start but shown only after a prompt, an approval or a question;
    /// every list and count reads the surfaced list.
    @Test
    func aSessionWithoutAPromptIsTrackedButNeverShown() {
        let engine = F.engine()
        engine.ingest(F.started("quiet"), ingress: .bridge)
        engine.ingest(F.sessionEnd("quiet"), ingress: .bridge)
        engine.ingest(F.started("idle"), ingress: .bridge)
        engine.ingest(F.started("asked"), ingress: .bridge)
        engine.ingest(F.prompt("asked"), ingress: .bridge)
        #expect(engine.state.sessions.count == 3)
        #expect(engine.surfacedSessions.map(\.id) == ["asked"])
        #expect(engine.rows.map(\.id) == ["asked"])
        #expect(engine.overflow.isEmpty)
        #expect(engine.runningCount == 1)
        #expect(engine.needsYouCount == 0)

        engine.ingest(F.question("idle"), ingress: .bridge)
        #expect(engine.needsYouCount == 0)
        engine.passAttentionWindows()
        #expect(engine.needsYouCount == 1)
        let found = AgentSession(id: "found", title: "Claude · project", tool: .claudeCode, phase: .completed, summary: "Done.",
                                 updatedAt: F.now, claudeMetadata: ClaudeSessionMetadata(initialUserPrompt: "refactor the parser"))
        engine.state = SessionState(sessions: engine.state.sessions + [found])
        #expect(Set(engine.surfacedSessions.map(\.id)) == ["asked", "idle", "found"])
    }

    /// P3: compaction and resume keep a working row running, titled and quiet.
    @Test
    func compactionAndResumeKeepTheRowRunningWithItsTitleAndNoAlert() throws {
        for source in [ClaudeSessionStartSource.compact, .resume] {
            let clock = F.Box(F.now)
            let engine = F.engine(clock: clock)
            var signals: [EngineSignal] = []
            engine.onSignal = { signals.append($0) }
            engine.ingest(F.started("s1", title: "Fix the tests"), ingress: .bridge)
            var phases: [SessionPhase] = []
            let restart = F.started("s1", source: source, title: "Claude · project", phase: .completed)
            for event in [F.prompt("s1"), F.running("s1"), F.compacting("s1"), restart, F.running("s1")] {
                engine.ingest(event, ingress: .bridge)
                let session = try #require(engine.state.session(id: "s1"))
                phases.append(session.phase)
                if event == restart { #expect(engine.statusWord(for: session) == .compacting) }
            }
            #expect(phases == Array(repeating: .running, count: 5))
            #expect(engine.state.session(id: "s1")?.title == "Fix the tests")
            // "Compacting" lasts through compaction's own SessionStart and ends at the next activity.
            #expect(engine.statusWord(for: try #require(engine.state.session(id: "s1"))) == .working)
            clock.update { $0 = $0.addingTimeInterval(5) }
            engine.flushHeldSignals()
            #expect(signals.isEmpty)
        }
    }

    /// P5: [SessionEnd, late Stop] brings no row back and no second Done.
    @Test
    func aLateStopAfterSessionEndBringsNoRowBack() {
        let clock = F.Box(F.now)
        let engine = F.engine(clock: clock)
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.prompt("s1"), ingress: .bridge)
        engine.ingest(F.completed("s1"), ingress: .bridge)
        clock.update { $0 = $0.addingTimeInterval(2) }
        engine.flushHeldSignals()
        engine.ingest(F.sessionEnd("s1"), ingress: .bridge)
        engine.ingest(F.started("s1", source: nil, phase: .completed), ingress: .bridge)
        engine.ingest(F.completed("s1"), ingress: .bridge)
        clock.update { $0 = $0.addingTimeInterval(2) }
        engine.flushHeldSignals()
        #expect(engine.rows.isEmpty)
        #expect(engine.state.session(id: "s1")?.isSessionEnded == true)
        #expect(signals == [.done(sessionID: "s1")])
    }

    /// P7: a monitor pass cannot end a session that waits on you; an idle one ends on its third miss.
    @Test
    func pollingKeepsAWaitingSessionAndEndsAnIdleOneOnItsThirdMiss() {
        let clock = F.Box(F.now)
        let engine = F.engine(clock: clock)
        engine.ingest(F.started("wait"), ingress: .bridge)
        engine.ingest(F.permission("wait"), ingress: .bridge)
        engine.passAttentionWindows()
        engine.ingest(F.started("idle"), ingress: .bridge)
        engine.ingest(F.prompt("idle"), ingress: .bridge)
        clock.update { $0 = $0.addingTimeInterval(11 * 60) }
        for pass in 1...3 {
            var local = engine.state
            local.markProcessLiveness(aliveSessionIDs: [])
            local.removeInvisibleSessions()
            engine.applyMonitoredState(local)
            #expect((engine.state.session(id: "idle") != nil) == (pass < 3))
        }
        #expect(engine.state.session(id: "wait")?.phase == .waitingForApproval)
        #expect(engine.needsYouCount == 1)
        engine.ingest(F.started("idle", source: nil, phase: .completed), ingress: .bridge)
        engine.ingest(F.completed("idle"), ingress: .bridge)
        #expect(engine.state.session(id: "idle") == nil)
    }

    /// The hold is one scheduled check, and that check delivers the Done.
    @Test
    func theHeldDoneIsDeliveredByItsScheduledCheck() {
        let clock = F.Box(F.now)
        let checks = F.Box<[TimeInterval]>([])
        let engine = F.engine(clock: clock, checks: checks)
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.prompt("s1"), ingress: .bridge)
        engine.ingest(F.completed("s1"), ingress: .bridge)
        engine.ingest(F.completed("s1"), ingress: .rollout)
        #expect(checks.current == [SignalPipeline.doneHold])
        #expect(signals.isEmpty)
        clock.update { $0 = $0.addingTimeInterval(SignalPipeline.doneHold) }
        engine.flushHeldSignals()
        engine.flushHeldSignals()
        #expect(signals == [.done(sessionID: "s1")])
    }

    /// Two sessions finish 0.5 s apart: each held Done has its own check, so both go out, in order, and no due time
    /// is checked twice.
    @Test
    func twoDonesHeldAtOnceAreBothDelivered() {
        let clock = F.Box(F.now)
        let checks = F.Box<[TimeInterval]>([])
        let scheduled = F.Box<[F.ScheduledCheck]>([])
        let engine = F.engine(clock: clock, checks: checks, scheduled: scheduled)
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        for id in ["s1", "s2"] {
            engine.ingest(F.started(id), ingress: .bridge)
            engine.ingest(F.prompt(id), ingress: .bridge)
        }
        engine.ingest(F.completed("s1"), ingress: .bridge)
        clock.update { $0 = $0.addingTimeInterval(0.5) }
        engine.ingest(F.completed("s2"), ingress: .bridge)
        F.runScheduledChecks(scheduled, clock: clock, for: 60)
        #expect(signals == [.done(sessionID: "s1"), .done(sessionID: "s2")])
        #expect(checks.current == [SignalPipeline.doneHold, SignalPipeline.doneHold])
        #expect(scheduled.current.isEmpty)
    }

    /// P5: the frontmost check waits. An approval answered and followed by another while it waits lets out one
    /// alert, the new request's; the old alert never goes out under the new request.
    @Test
    func anAlertIsCheckedAgainstItsKeyAfterTheFocusCheck() async throws {
        let gate = FocusGate()
        let engine = F.engine(suppress: true, isFrontmost: { _ in
            await gate.wait()
            return false
        })
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.prompt("s1"), ingress: .bridge)
        engine.ingest(F.permission("s1", toolUseID: "toolu_A"), ingress: .bridge)
        engine.passAttentionWindows()
        await engine.approve(sessionID: "s1", decision: .allowOnce)
        engine.ingest(F.permission("s1", toolUseID: "toolu_B"), ingress: .bridge)
        engine.passAttentionWindows()
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(signals == [.needsYou(sessionID: "s1")])
    }

    /// The same prompt twice is two turns, over the bridge and in a rollout-only session: two Dones for each.
    @Test
    func aRepeatedPromptStartsANewTurnOnEitherPath() {
        let clock = F.Box(F.now)
        let engine = F.engine(clock: clock)
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        engine.ingest(F.started("hooked", tool: .codex, transcript: "/tmp/sessions/rollout-hooked.jsonl"), ingress: .bridge)
        engine.ingest(F.started("rollout", tool: .codex, phase: .completed), ingress: .rollout)
        for _ in 1...2 {
            engine.ingest(F.prompt("hooked", "run the tests"), ingress: .bridge)
            for event in F.rolloutPrompt("rollout", "run the tests") { engine.ingest(event, ingress: .rollout) }
            engine.ingest(F.running("rollout"), ingress: .rollout)
            engine.ingest(F.completed("hooked"), ingress: .bridge)
            engine.ingest(F.completed("rollout"), ingress: .rollout)
            clock.update { $0 = $0.addingTimeInterval(2) }
            engine.flushHeldSignals()
        }
        #expect(signals.filter { $0 == .done(sessionID: "hooked") }.count == 2)
        #expect(signals.filter { $0 == .done(sessionID: "rollout") }.count == 2)
        #expect(engine.signals.turn(for: "hooked") == 2)
        #expect(engine.signals.turn(for: "rollout") == 2)
    }

    /// P2 from upstream's real summary: a PermissionDenied is activity ("Denied · Bash") and never a Done; the Stop
    /// that ends the turn is.
    @Test
    func aDeniedToolIsActivityAndNeverADone() throws {
        let clock = F.Box(F.now)
        let engine = F.engine(clock: clock)
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(F.prompt("s1"), ingress: .bridge)
        for event in F.permissionDenied("s1", tool: "Bash") { engine.ingest(event, ingress: .bridge) }
        clock.update { $0 = $0.addingTimeInterval(5) }
        engine.flushHeldSignals()
        let denied = try #require(engine.state.session(id: "s1"))
        #expect(denied.phase == .running)
        #expect(engine.statusWord(for: denied) == .denied(tool: "Bash"))
        #expect(engine.runningCount == 1)
        #expect(signals.isEmpty)

        engine.ingest(F.completed("s1"), ingress: .bridge)
        clock.update { $0 = $0.addingTimeInterval(2) }
        engine.flushHeldSignals()
        #expect(signals == [.done(sessionID: "s1")])
        #expect(engine.statusWord(for: try #require(engine.state.session(id: "s1"))) == .done)
    }
}
