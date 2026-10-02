import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// The owner's report (build e1b5c2a): with "Approve for me" on, Codex's reviewer threads showed as sessions, titled
/// "The following is the Codex agent history…" with their JSON verdict as the status, and pushed the second of the
/// owner's two running Codex chats out of the list; a chat's 157 subagents could do the same (P1, P212).
@Suite(.serialized)
@MainActor
struct CodexThreadsTests {
    typealias T = CodexThreadFixtures
    typealias F = RolloutFixtures
    typealias E = EngineFixtures

    // MARK: The scan

    @Test
    func theScanKeepsTheOwnersTwoChatsAndLeavesTheReviewerAndTheSubagentsOut() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let now = Date()
        T.owner(in: root, now: now)
        let scanner = CodexRolloutScanner(rootURL: root)

        let records = scanner.discoverRecentSessions(now: now)
        let diagnostics = scanner.lastScanDiagnostics
        #expect(Set(records.map(\.sessionID)) == [T.chatA, T.chatB])
        #expect(diagnostics.candidateCount == 2 + 80 + 160)
        #expect(diagnostics.internalFileCount == 80)
        #expect(diagnostics.subagentFileCount == 160)
        #expect(diagnostics.parsedFileCount == 2)
        // Both are running, and both are the desktop app's threads, so each shows while the app runs, however quiet.
        for record in records {
            #expect(record.phase == .running)
            #expect(record.session.isCodexAppSession)
            #expect(record.jumpTarget?.codexThreadID == record.sessionID)
        }

        // The subagents: the newest 64, the three running first, each on chat A.
        let children = scanner.lastScanChildren
        #expect(children.count == 64)
        #expect(children.allSatisfy { $0.parentID == T.chatA && $0.rootID == T.chatA })
        #expect(Set(children.filter(\.isRunning).map(\.id)) == Set((157..<160).map(T.subagentID)))
        #expect(children.first { $0.id == T.subagentID(157) }?.name == "worker")
        #expect(children.first { $0.id == T.subagentID(158) }?.name == "Euclid")

        // The next pass classifies nothing again, and reads a subagent's turn ending from what was appended alone.
        let ended = F.text([F.item("function_call_output", ["call_id": "c1", "output": "ok"], at: 40),
                            F.event("task_complete", ["last_agent_message": "Section checked."], at: 41)])
        let url = root.appendingPathComponent("2026/09/24/rollout-2026-09-24T10-00-00-\(T.subagentID(159)).jsonl")
        F.append(ended, to: url)
        let handed = E.Box<[CodexChildThread]>([])
        scanner.childrenHandler = { children in handed.update { $0 = children } }
        _ = scanner.discoverRecentSessions(now: now)
        #expect(scanner.lastScanDiagnostics.classifiedFileCount == 0)
        #expect(scanner.lastScanDiagnostics.bytesRead == ended.utf8.count)
        #expect(handed.current.first { $0.id == T.subagentID(159) }?.isRunning == false)
        #expect(handed.current.filter(\.isRunning).count == 2)
    }

    /// 50 reviewer threads and one CLI chat: one session (P1's check), whichever is newer.
    @Test
    func fiftyReviewerThreadsAndOneChatGiveOneSession() {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        T.write(T.chat(T.chatA, prompt: "fix the flaky test", running: false, originator: "codex_cli_rs"), id: T.chatA, in: root, minutesAgo: 90)
        for n in 0..<50 { T.write(T.reviewer(T.reviewerID(n), parent: T.chatA, reviews: 15), id: T.reviewerID(n), in: root, minutesAgo: Double(n)) }
        let records = CodexRolloutScanner(rootURL: root).discoverRecentSessions()
        #expect(records.map(\.sessionID) == [T.chatA])
        // A CLI chat is no Codex app thread.
        #expect(records.first?.session.isCodexAppSession == false)
    }

    // MARK: The launch

    @Test
    func theLaunchShowsBothChatsAndChatACountsItsRunningSubagents() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let now = Date()
        T.owner(in: root, now: now)
        let scanner = CodexRolloutScanner(rootURL: root)
        let records = scanner.discoverRecentSessions(now: now)
        let engine = E.engine(clock: E.Box(now))
        var payload = Self.payload(discovered: records)
        // A store the old build wrote kept reviewer threads and subagents as sessions.
        let reviewerPath = root.appendingPathComponent("2026/09/24/rollout-2026-09-24T10-00-00-\(T.reviewerID(0)).jsonl").path
        let childPath = root.appendingPathComponent("2026/09/24/rollout-2026-09-24T10-00-00-\(T.subagentID(3)).jsonl").path
        payload.codexRecords = [Self.stored(T.reviewerID(0), path: reviewerPath, prompt: T.reviewPrompt, reply: T.verdict, now: now),
                                Self.stored(T.subagentID(3), path: childPath, prompt: "check section 003", reply: "Checked.", now: now)]
        let hidden = SessionEngine.dropInternalRecords(&payload)
        #expect(payload.codexRecords.isEmpty)
        #expect(payload.codexRecordsNeedPrune)
        #expect(Set(hidden.keys) == [T.reviewerID(0), T.subagentID(3)])

        engine.takeStartupCodexThreads(SessionEngine.CodexThreadsFound(children: scanner.lastScanChildren, hidden: hidden))
        // What the coordinator's merge writes, then the process monitor's pass while the app runs.
        engine.takeDiscoveredState(SessionState(sessions: payload.discoveredCodexRecords.map(\.session)))
        Self.markAppAlive(engine)
        #expect(Set(engine.rows.map(\.id)) == [T.chatA, T.chatB])
        let chatA = try #require(engine.state.session(id: T.chatA))
        #expect(engine.runningSubagents(for: T.chatA) == 3)
        #expect(engine.statusWord(for: chatA) == .subagents(3))
        // Its own command is the main agent at work, not waiting (P378): the tool, whatever its subagents do; its wait on
        // them, or a turn with no call of its own, is waiting.
        var working = chatA
        working.codexMetadata?.currentTool = "exec_command"
        working.codexMetadata?.currentCommandPreview = "cargo build"
        #expect(engine.statusWord(for: working) == .tool(name: "exec_command", detail: "cargo build"))
        for wait in ["wait_agent", nil] {
            var waiting = chatA
            waiting.codexMetadata?.currentTool = wait
            #expect(engine.statusWord(for: waiting) == .subagents(3))
        }
        #expect(engine.runningSubagents(for: T.chatB) == 0)
        // A hidden thread's later events never bring it back.
        engine.ingest(E.started(T.reviewerID(0), tool: .codex, transcript: reviewerPath), ingress: .bridge)
        engine.ingest(E.prompt(T.reviewerID(0), "look at this"), ingress: .bridge)
        #expect(engine.state.session(id: T.reviewerID(0)) == nil)
        // Nor does a rescan's write, which upstream makes straight to the state.
        var rescan = engine.state
        rescan.apply(E.started(T.subagentID(3), tool: .codex, transcript: childPath))
        engine.takeDiscoveredState(rescan)
        #expect(engine.state.session(id: T.subagentID(3)) == nil)
    }

    /// The owner's chat whose turn runs while its rollout is quiet (waiting on its subagents, which run) stays a running
    /// row: the launch makes it the desktop app's thread, since a subagent of it runs (P216), and an app thread is alive
    /// while the app runs, so the process monitor's pass keeps it so while its turn waits. A chat left mid-turn with
    /// nothing running under it is not the app's thread (`CodexThreadLifeTests.aDesktopChatLeftMidTurnStaysHidden`).
    @Test
    func aQuietChatWhoseSubagentsRunStaysARunningRow() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let now = Date()
        T.owner(in: root, now: now)
        let records = CodexRolloutScanner(rootURL: root).discoverRecentSessions(now: now)
        let engine = E.engine(clock: E.Box(now.addingTimeInterval(40 * 60)))
        engine.state = SessionState(sessions: records.map(\.session))
        let monitoring = ProcessMonitoringCoordinator()
        monitoring.stateAccessor = { engine.state }
        let alive = monitoring.sessionIDsWithAliveProcesses(activeProcesses: [], isCodexAppRunning: true)
        #expect(alive == [T.chatA, T.chatB])
        Self.markAppAlive(engine)
        engine.promptedSessionIDs.formUnion([T.chatA, T.chatB])
        #expect(engine.rows.map(\.id).contains(T.chatA))
        #expect(engine.rows.first { $0.id == T.chatA }?.phase == .running)
    }

    // MARK: The tracker

    /// A thread a hook or a restored record made a session of is taken out as soon as its rollout is read: no row, no
    /// Done, no title (P212).
    @Test
    func theTrackerReportsAReviewerInsteadOfItsEvents() async throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = T.write(T.reviewer(T.reviewerID(1), parent: T.chatA, reviews: 3), id: T.reviewerID(1), in: root, minutesAgo: 0)
        let tracker = CodexRolloutTracker(pollInterval: 3_600)
        let events = E.Box<[AgentEvent]>([])
        let attention = E.Box(0)
        let reports = E.Box<[(String, String?, CodexThreadKind)]>([])
        tracker.eventHandler = { event in events.update { $0.append(event) } }
        tracker.attentionHandler = { _ in attention.update { $0 += 1 } }
        tracker.kindHandler = { session, thread, kind in reports.update { $0.append((session, thread, kind)) } }
        tracker.sync(targets: [CodexRolloutWatchTarget(sessionID: T.reviewerID(1), transcriptPath: url.path)])
        tracker.waitUntilIdle()
        F.append(F.text([F.event("task_complete", ["last_agent_message": T.verdict], at: 90)]), to: url)
        tracker.pollNow(sessionID: T.reviewerID(1))
        tracker.waitUntilIdle()
        tracker.stop()
        #expect(events.current.isEmpty)
        #expect(attention.current == 0)
        #expect(reports.current.count == 1)
        #expect(reports.current.first?.0 == T.reviewerID(1))
        #expect(reports.current.first?.1 == T.reviewerID(1))
        #expect(reports.current.first?.2 == .reviewer)
    }

    @Test
    func aReviewerMadeASessionByAHookLeavesWithNoSignal() throws {
        let clock = E.Box(E.now)
        let engine = E.engine(clock: clock)
        var signals: [EngineSignal] = []
        engine.onSignal = { signals.append($0) }
        engine.ingest(E.started(T.reviewerID(1), tool: .codex, transcript: "/tmp/reviewer.jsonl"), ingress: .bridge)
        engine.ingest(E.prompt(T.reviewerID(1), T.reviewPrompt), ingress: .bridge)
        engine.takeCodexThreadKind(sessionID: T.reviewerID(1), threadID: T.reviewerID(1), kind: .reviewer)
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: T.reviewerID(1), summary: T.verdict, timestamp: clock.current)),
                      ingress: .rollout)
        engine.flushHeldSignals()
        #expect(engine.state.session(id: T.reviewerID(1)) == nil)
        #expect(engine.rows.isEmpty)
        #expect(signals.isEmpty)
        #expect(engine.hiddenCodexThreadCount == 1)
    }

    /// A root session whose metadata names its subagent's rollout (upstream files a child's transcript under its root,
    /// P167) is not the subagent: it stays.
    @Test
    func aRootReadThroughItsSubagentsRolloutStays() {
        let engine = E.engine()
        engine.ingest(E.started(T.chatA, tool: .codex, transcript: "/tmp/child.jsonl"), ingress: .bridge)
        engine.takeCodexThreadKind(sessionID: T.chatA, threadID: T.subagentID(1),
                                   kind: .subagent(CodexSubagent(id: T.subagentID(1), parentID: T.chatA)))
        #expect(engine.state.session(id: T.chatA) != nil)
        #expect(engine.hiddenCodexThreadCount == 0)
    }

    // MARK: Subagents on their chat's row

    @Test
    func aSubagentsApprovalWaitsOnItsChatsRowUnderItsName() async throws {
        let scene = AttentionScene()
        scene.begin(T.chatA, tool: .codex, prompt: "Continue MarathonTrainingLog")
        scene.engine.takeCodexChildren([CodexChildThread(id: T.subagentID(1), parentID: T.chatA, rootID: T.chatA, name: "Hubble",
                                                         isRunning: true, updatedAt: scene.clock.current, transcriptPath: "")])
        // codex-rs: a spawned subagent's hook carries the root's session id, its own agent id, `default` as its type
        // when it has no role, and its own rollout.
        scene.hook(AttentionScene.codex("PermissionRequest", session: T.chatA, agent: T.subagentID(1),
                                        transcript: "/tmp/juice-attention/sessions/rollout-\(T.subagentID(1)).jsonl",
                                        extra: ["agent_type": "default"]), source: "codex")
        await scene.settle { scene.engine.openRequests.count == 1 }
        scene.at(9)
        let head = try #require(scene.head(T.chatA))
        #expect(head.agentID == T.subagentID(1))
        #expect(head.agentType == "Hubble")
        #expect(scene.engine.state.session(id: T.subagentID(1)) == nil)
        #expect(scene.engine.rows.map(\.id) == [T.chatA])

        // A subagent's request whose chat the island has not seen yet starts that chat, never filing the subagent's
        // rollout under it (P167).
        scene.hook(AttentionScene.codex("PermissionRequest", session: T.chatB, agent: T.subagentID(9),
                                        transcript: "/tmp/juice-attention/sessions/rollout-\(T.subagentID(9)).jsonl"), source: "codex")
        await scene.settle { scene.engine.state.session(id: T.chatB) != nil }
        #expect(scene.engine.state.session(id: T.chatB)?.codexMetadata?.transcriptPath == nil)
    }

    /// A Codex that sends a subagent's hook under the subagent's own id: the request still waits on its chat's row.
    @Test
    func aSubagentsRequestUnderItsOwnIdGoesToItsChat() async throws {
        let scene = AttentionScene()
        scene.begin(T.chatA, tool: .codex, prompt: "Continue MarathonTrainingLog")
        scene.engine.takeCodexChildren([CodexChildThread(id: T.subagentID(2), parentID: T.subagentID(1), name: "worker",
                                                         isRunning: true, updatedAt: scene.clock.current, transcriptPath: ""),
                                        CodexChildThread(id: T.subagentID(1), parentID: T.chatA, name: "Hubble",
                                                         isRunning: true, updatedAt: scene.clock.current, transcriptPath: "")])
        scene.hook(AttentionScene.codex("PermissionRequest", session: T.subagentID(2)), source: "codex")
        await scene.settle { scene.engine.openRequests.count == 1 }
        scene.at(9)
        let head = try #require(scene.head(T.chatA))
        #expect(head.agentID == T.subagentID(2))
        #expect(head.agentType == "worker")
        #expect(scene.engine.state.session(id: T.subagentID(2)) == nil)
        // A reviewer's request is never shown.
        scene.engine.hideCodexThread(T.reviewerID(1), kind: .reviewer)
        scene.hook(AttentionScene.codex("PermissionRequest", session: T.reviewerID(1)), source: "codex")
        await scene.settle()
        #expect(scene.engine.openRequests.count == 1)
    }

    @Test
    func aSubagentsQuestionWaitsOnItsChatsRowAndItsOwnTurnEndClosesIt() throws {
        let scene = AttentionScene()
        scene.begin(T.chatA, tool: .codex, prompt: "Continue MarathonTrainingLog")
        let child = CodexChildThread(id: T.subagentID(1), parentID: T.chatA, rootID: T.chatA, name: "Hubble", isRunning: true,
                                     updatedAt: scene.clock.current, transcriptPath: "")
        scene.engine.takeCodexChildren([child])
        var attention = CodexAttention()
        let ask = F.item("function_call", ["name": "request_user_input_async", "call_id": "q1",
                                           "arguments": #"{"questions":[{"title":"Which section first?","options":["2","3"]}]}"#], at: 50)
        attention.apply(ask)
        scene.engine.ingestSubagentAttention(CodexAttentionUpdate(sessionID: child.id, events: attention.takeEvents(), state: attention))
        let head = try #require(scene.head(T.chatA))
        #expect(head.kind == .question)
        #expect(head.agentID == child.id)
        #expect(head.agentType == "Hubble")
        // The chat's own turn end does not close it (C5); the subagent's does.
        scene.rollout(T.chatA, [F.event("task_complete", ["turn_id": "t9"], at: 60)])
        #expect(scene.head(T.chatA) != nil)
        attention.apply(F.event("task_complete", ["turn_id": "t2"], at: 70))
        scene.engine.ingestSubagentAttention(CodexAttentionUpdate(sessionID: child.id, events: attention.takeEvents(), state: attention))
        #expect(scene.head(T.chatA) == nil)
    }

    @Test
    func aWatchedSubagentsTurnEndTakesItOffItsChatsCount() {
        let clock = E.Box(E.now)
        let engine = E.engine(clock: clock, configure: { $0.watchesSubagentRollouts = false })
        engine.ingest(E.started(T.chatA, tool: .codex, transcript: "/tmp/a.jsonl"), ingress: .bridge)
        engine.takeCodexChildren((1...3).map {
            CodexChildThread(id: T.subagentID($0), parentID: T.chatA, isRunning: true, updatedAt: clock.current, transcriptPath: "/tmp/c.jsonl")
        })
        #expect(engine.runningSubagents(for: T.chatA) == 3)
        engine.ingestSubagentEvent(.sessionCompleted(SessionCompleted(sessionID: T.subagentID(2), summary: "done", timestamp: clock.current)))
        #expect(engine.runningSubagents(for: T.chatA) == 2)
        // A subagent quiet for over 30 minutes (it crashed mid-turn) no longer counts.
        clock.update { $0 = $0.addingTimeInterval(31 * 60) }
        #expect(engine.runningSubagents(for: T.chatA) == 0)
    }

    // MARK: The preview

    /// The demo and renders read rollouts as the tracker does: the reviewer and the subagents never become rows.
    @Test
    func thePreviewTakesRolloutsAsTheTrackerDoes() throws {
        let engine = SessionEngine.preview(clock: { E.now })
        engine.loadPreviewEvents([E.started(T.chatA, tool: .codex, transcript: "/tmp/a.jsonl")])
        engine.loadPreviewRollout(sessionID: T.chatA, transcriptPath: "/tmp/a.jsonl",
                                  lines: T.chat(T.chatA, prompt: "Continue MarathonTrainingLog", running: true))
        engine.loadPreviewRollout(sessionID: T.reviewerID(1), transcriptPath: "/tmp/r.jsonl", lines: T.reviewer(T.reviewerID(1), parent: T.chatA))
        engine.loadPreviewRollout(sessionID: T.subagentID(1), transcriptPath: "/tmp/s.jsonl",
                                  lines: T.subagent(T.subagentID(1), parent: T.chatA, running: true, from: 0))
        #expect(engine.state.sessions.map(\.id) == [T.chatA])
        #expect(engine.hiddenCodexThreadCount == 2)
    }

    // MARK: Helpers

    static func payload(discovered: [CodexTrackedSessionRecord]) -> SessionDiscoveryCoordinator.StartupDiscoveryPayload {
        SessionDiscoveryCoordinator.StartupDiscoveryPayload(
            codexRecords: [], codexRecordsNeedPrune: false, claudeRecords: [], claudeRecordsNeedPrune: false, openCodeRecords: [],
            openCodeRecordsNeedPrune: false, cursorRecords: [], cursorRecordsNeedPrune: false, piRecords: [], piRecordsNeedPrune: false,
            discoveredCodexRecords: discovered, discoveredClaudeSessions: [], hooksBinaryURL: nil)
    }

    static func stored(_ id: String, path: String, prompt: String, reply: String, now: Date) -> CodexTrackedSessionRecord {
        CodexTrackedSessionRecord(sessionID: id, title: "Codex · harborlog", origin: .live, summary: reply, phase: .completed,
                                  updatedAt: now, jumpTarget: JumpTarget(terminalApp: "Codex.app", workspaceName: "harborlog",
                                                                         paneTitle: "Codex · harborlog", codexThreadID: id),
                                  codexMetadata: CodexSessionMetadata(transcriptPath: path, initialUserPrompt: prompt,
                                                                      lastUserPrompt: prompt, lastAssistantMessage: reply))
    }

    /// The process monitor's pass while the Codex app runs: its threads are alive.
    static func markAppAlive(_ engine: SessionEngine) {
        engine.state = SessionState(sessions: engine.state.sessions.map { session in
            var session = session
            if session.isCodexAppSession { session.isProcessAlive = true }
            return session
        })
    }
}
