import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// What the Codex threads review found (P216 to P219): a desktop chat's liveness at launch, `/review`, a subagent's
/// question past its watch, a lapsed watch at rest, and a subagent the book has not seen.
@Suite(.serialized)
@MainActor
struct CodexThreadLifeTests {
    typealias T = CodexThreadFixtures
    typealias F = RolloutFixtures
    typealias E = EngineFixtures

    // MARK: A desktop chat found at launch (P216)

    /// ChatGPT (or the Mac) stopped during a turn, so Codex wrote no turn end: the launch must not make such a chat a
    /// Codex app thread, which lives for as long as the app runs and would be a running row for good.
    @Test
    func aDesktopChatLeftMidTurnStaysHidden() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let now = Date()
        T.write(T.chat(T.chatA, prompt: "Old task from this morning", running: true), id: T.chatA, in: root, minutesAgo: 20 * 60, now: now)
        T.write(T.chat(T.chatB, prompt: "Another old task", running: true), id: T.chatB, in: root, minutesAgo: 20, now: now)
        let records = CodexRolloutScanner(rootURL: root).discoverRecentSessions(now: now)
        #expect(Set(records.map(\.sessionID)) == [T.chatA, T.chatB])
        #expect(records.allSatisfy { !$0.session.isCodexAppSession })
        let engine = E.engine(clock: E.Box(now))
        engine.state = SessionState(sessions: records.map(\.session))
        let monitoring = ProcessMonitoringCoordinator()
        monitoring.stateAccessor = { engine.state }
        #expect(monitoring.sessionIDsWithAliveProcesses(activeProcesses: [], isCodexAppRunning: true).isEmpty)
        CodexThreadsTests.markAppAlive(engine)
        #expect(engine.rows.isEmpty)
    }

    /// A desktop chat written in the app's staleness window, or one whose subagent runs, is the app's thread.
    @Test
    func aDesktopChatIsTheAppsWhenItWasJustWrittenOrItsSubagentRuns() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let now = Date()
        T.write(T.chat(T.chatA, prompt: "Continue MarathonTrainingLog", running: true), id: T.chatA, in: root, minutesAgo: 25, now: now)
        T.write(T.subagent(T.subagentID(1), parent: T.chatA, running: true), id: T.subagentID(1), in: root, minutesAgo: 20, now: now)
        T.write(T.chat(T.chatB, prompt: "Review paper for inconsistencies", running: true), id: T.chatB, in: root, minutesAgo: 9, now: now)
        // A finished subagent, and a running one that has been quiet past the limit, keep no chat alive.
        let chatC = "019e0f00-0000-7000-8000-00000000000c"
        T.write(T.chat(chatC, prompt: "Summarise the logs", running: true), id: chatC, in: root, minutesAgo: 50, now: now)
        T.write(T.subagent(T.subagentID(2), parent: chatC, running: false), id: T.subagentID(2), in: root, minutesAgo: 2, now: now)
        T.write(T.subagent(T.subagentID(3), parent: chatC, running: true), id: T.subagentID(3), in: root, minutesAgo: 45, now: now)
        let records = CodexRolloutScanner(rootURL: root).discoverRecentSessions(now: now)
        let flagged = Set(records.filter(\.session.isCodexAppSession).map(\.sessionID))
        #expect(flagged == [T.chatA, T.chatB])
        // A CLI chat is never the app's, however fresh.
        let cli = F.sessionsFolder()
        defer { F.remove(cli) }
        T.write(T.chat(T.chatA, prompt: "fix the flaky test", running: true, originator: "codex_cli_rs"), id: T.chatA, in: cli, minutesAgo: 0, now: now)
        #expect(CodexRolloutScanner(rootURL: cli).discoverRecentSessions(now: now).first?.session.isCodexAppSession == false)
    }

    // MARK: /review (P217)

    /// `/review` or `codex review` as a chat's first action: Codex writes the chat's rollout only when the review ends,
    /// so while it runs the review's thread is the only rollout, and it is a row, as before; when it ends, the chat's
    /// rollout holds only Codex's own text, so the review's row stays and says Done.
    @Test
    func aReviewAsAChatsFirstActionIsARowUntilItIsDone() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let now = Date()
        let lines = T.reviewThread(parent: T.chatA, running: true)
        let url = T.write(lines, id: T.reviewID, in: root, minutesAgo: 0.5, now: now)
        let scanner = CodexRolloutScanner(rootURL: root)
        let records = scanner.discoverRecentSessions(now: now)
        #expect(records.map(\.sessionID) == [T.reviewID])
        let engine = E.engine(clock: E.Box(now))
        engine.takeCodexChildren(scanner.lastScanChildren)
        engine.takeDiscoveredState(SessionState(sessions: records.map(\.session)))
        // The tracker reads its rollout and says what it is.
        let kind = try #require(CodexThreadKind.of(line: lines[0]))
        engine.takeCodexThreadKind(sessionID: T.reviewID, threadID: T.reviewID, kind: kind)
        CodexThreadsTests.markAppAlive(engine)
        #expect(engine.rows.map(\.id) == [T.reviewID])
        #expect(engine.rows.first?.phase == .running)
        // It stands for the owner's chat: its Done is the owner's (P250), though its rollout names a child.
        var attention = CodexAttention()
        attention.apply(lines[0])
        engine.ingestCodexAttention(CodexAttentionUpdate(sessionID: T.reviewID, events: attention.takeEvents(), state: attention))
        #expect(engine.scope(of: try #require(engine.state.session(id: T.reviewID))) == .owner)
        #expect(engine.notifiesOfTurnEnd(T.reviewID))

        // The review ends, and Codex writes the chat's rollout.
        F.append(F.text(Array(F.turn(prompt: T.codeReviewPrompt, reply: T.reviewOutput, from: 40).suffix(6))), to: url)
        F.setModified(url, to: now)
        T.write([T.meta(id: T.chatA, source: "vscode", threadSource: "user"), T.enteredReview(at: 38)] + T.reviewEnd(at: 60),
                id: T.chatA, in: root, minutesAgo: 0, now: now)
        let later = scanner.discoverRecentSessions(now: now)
        #expect(later.map(\.sessionID).contains(T.chatA))
        engine.takeCodexChildren(scanner.lastScanChildren)
        let known = Set(engine.state.sessions.map(\.id))
        engine.takeDiscoveredState(SessionState(sessions: engine.state.sessions + later.filter { !known.contains($0.sessionID) }.map(\.session)))
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: T.reviewID, summary: T.reviewOutput, timestamp: now)), ingress: .rollout)
        CodexThreadsTests.markAppAlive(engine)
        #expect(engine.rows.map(\.id) == [T.reviewID])
        #expect(engine.rows.first?.phase == .completed)
    }

    /// The app's Review in an existing chat: the chat's rollout says only that it entered review mode, never that a
    /// turn started, yet its row runs while the review runs; the review's own thread is folded into it.
    @Test(arguments: [false, true])
    func anInlineReviewRunsOnItsChatsRow(paginated: Bool) throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let now = Date()
        T.write(T.chat(T.chatA, prompt: "Continue MarathonTrainingLog", running: false) + [T.enteredReview(paginated: paginated, at: 30)],
                id: T.chatA, in: root, minutesAgo: 1, now: now)
        T.write(T.reviewThread(parent: T.chatA, running: true), id: T.reviewID, in: root, minutesAgo: 0.5, now: now)
        let scanner = CodexRolloutScanner(rootURL: root)
        let records = scanner.discoverRecentSessions(now: now)
        #expect(records.map(\.sessionID) == [T.chatA])
        #expect(records.first?.phase == .running)
        #expect(records.first?.session.isCodexAppSession == true)
        let review = try #require(scanner.lastScanChildren.first)
        #expect(scanner.lastScanChildren.count == 1)
        #expect(review.isReview && review.isRunning && review.id == T.reviewID)

        // On the island: the chat's row says Reviewing; the review is never a count, a watch or a row.
        let engine = E.engine(clock: E.Box(now))
        engine.takeCodexChildren(scanner.lastScanChildren)
        engine.takeDiscoveredState(SessionState(sessions: records.map(\.session)))
        CodexThreadsTests.markAppAlive(engine)
        #expect(engine.rows.map(\.id) == [T.chatA])
        let chat = try #require(engine.state.session(id: T.chatA))
        #expect(engine.statusWord(for: chat) == .reviewing)
        #expect(engine.runningSubagents(for: T.chatA) == 0)
        #expect(engine.codexThreads.watched(now: now).isEmpty)
        // A session a hook or an old store made of the review folds into the chat, a row the lists show.
        engine.ingest(E.started(T.reviewID, tool: .codex, transcript: "/tmp/review.jsonl"), ingress: .bridge)
        engine.takeCodexThreadKind(sessionID: T.reviewID, threadID: T.reviewID, kind: .review(CodexSubagent(id: T.reviewID, parentID: T.chatA)))
        #expect(engine.state.session(id: T.reviewID) == nil)
    }

    /// The chat's row says Reviewing for the whole review, whatever the review does meanwhile, and Done at its end.
    @Test
    func aReviewingChatSaysSoUntilItsTurnEnds() throws {
        let clock = E.Box(E.now)
        let engine = E.engine(clock: clock)
        engine.ingest(E.started(T.chatA, tool: .codex, transcript: "/tmp/a.jsonl"), ingress: .bridge)
        engine.ingest(E.prompt(T.chatA, "Continue MarathonTrainingLog"), ingress: .bridge)
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: T.chatA, summary: "Done.", timestamp: clock.current)), ingress: .rollout)
        engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: T.chatA, summary: StatusWord.reviewingSummary, phase: .running,
                                                              timestamp: clock.current)), ingress: .rollout)
        #expect(engine.statusWord(for: try #require(engine.state.session(id: T.chatA))) == .reviewing)
        engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: T.chatA, summary: "Thinking.", phase: .running,
                                                              timestamp: clock.current)), ingress: .rollout)
        #expect(engine.statusWord(for: try #require(engine.state.session(id: T.chatA))) == .reviewing)
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: T.chatA, summary: "No issues found.", timestamp: clock.current)),
                      ingress: .rollout)
        #expect(engine.statusWord(for: try #require(engine.state.session(id: T.chatA))) == .done)
        #expect(engine.reviewingSessionIDs.isEmpty)
        // The next turn is the owner's own.
        engine.ingest(.activityUpdated(SessionActivityUpdated(sessionID: T.chatA, summary: StatusWord.reviewingSummary, phase: .running,
                                                              timestamp: clock.current)), ingress: .rollout)
        engine.ingest(E.prompt(T.chatA, "Fix what the review found"), ingress: .bridge)
        #expect(engine.statusWord(for: try #require(engine.state.session(id: T.chatA))) != .reviewing)
    }

    /// The tracker reads a review as its chat's turn: running from its entered-review-mode line, Done at its end.
    @Test(arguments: [false, true])
    func theTrackerReadsAReviewAsItsChatsTurn(paginated: Bool) throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = T.write(T.chat(T.chatA, prompt: "Continue MarathonTrainingLog", running: false), id: T.chatA, in: root, minutesAgo: 0)
        let tracker = CodexRolloutTracker(pollInterval: 3_600)
        let events = E.Box<[AgentEvent]>([])
        tracker.eventHandler = { event in events.update { $0.append(event) } }
        tracker.sync(targets: [CodexRolloutWatchTarget(sessionID: T.chatA, transcriptPath: url.path)])
        tracker.waitUntilIdle()
        events.update { $0 = [] }
        F.append(F.text([T.enteredReview(paginated: paginated, at: 30)]), to: url)
        tracker.pollNow(sessionID: T.chatA)
        tracker.waitUntilIdle()
        #expect(events.current.contains { if case let .activityUpdated(update) = $0 { update.phase == .running } else { false } })
        F.append(F.text(T.reviewEnd(at: 60)), to: url)
        tracker.pollNow(sessionID: T.chatA)
        tracker.waitUntilIdle()
        tracker.stop()
        #expect(events.current.contains { if case .sessionCompleted = $0 { true } else { false } })
    }

    // MARK: A subagent's question past its watch (P218)

    /// A subagent whose question waits is watched however long it is quiet: its answer and its turn end still close
    /// the question on its chat's row.
    @Test
    func aSubagentsOpenQuestionKeepsItWatchedPastTheQuietLimit() async throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let clock = E.Box(Date())
        let engine = E.engine(clock: clock)
        let ask = F.item("function_call", ["name": "request_user_input", "call_id": "q1",
                                           "arguments": #"{"questions":[{"question":"Which section first?","header":"S","options":[{"label":"2"},{"label":"3"}]}]}"#], at: 50)
        let url = T.write(T.subagent(T.subagentID(1), parent: T.chatA, running: true) + [ask], id: T.subagentID(1), in: root, minutesAgo: 0)
        engine.ingest(E.started(T.chatA, tool: .codex, transcript: "/tmp/a.jsonl"), ingress: .bridge)
        engine.ingest(E.prompt(T.chatA, "Continue MarathonTrainingLog"), ingress: .bridge)
        engine.takeCodexChildren([CodexChildThread(id: T.subagentID(1), parentID: T.chatA, rootID: T.chatA, name: "Hubble",
                                                   isRunning: true, updatedAt: clock.current, transcriptPath: url.path)])
        defer { engine.subagentRollouts?.stop() }
        try await Self.settle(engine) { engine.attentionHead(for: T.chatA) != nil }
        #expect(engine.attentionHead(for: T.chatA)?.kind == .question)

        // Quiet for 35 minutes (waiting on the owner), then any upkeep re-syncs the watch.
        clock.update { $0 = $0.addingTimeInterval(35 * 60) }
        engine.syncSubagentRollouts()
        engine.subagentRollouts?.waitUntilIdle()
        F.append(F.text([F.item("function_call_output", ["call_id": "q1", "output": "2"], at: 2_200),
                         F.event("task_complete", ["last_agent_message": "done"], at: 2_201)]), to: url)
        engine.subagentRollouts?.pollNow(sessionID: T.subagentID(1))
        try await Self.settle(engine) { engine.attentionHead(for: T.chatA) == nil }
        #expect(engine.attentionHead(for: T.chatA) == nil)
    }

    /// A scan that finds a subagent finished closes the question it read from its rollout.
    @Test
    func aScanThatFindsASubagentFinishedClosesItsQuestion() throws {
        let scene = AttentionScene()
        scene.begin(T.chatA, tool: .codex, prompt: "Continue MarathonTrainingLog")
        var child = CodexChildThread(id: T.subagentID(1), parentID: T.chatA, rootID: T.chatA, name: "Hubble", isRunning: true,
                                     updatedAt: scene.clock.current, transcriptPath: "")
        scene.engine.takeCodexChildren([child])
        var attention = CodexAttention()
        attention.apply(F.item("function_call", ["name": "request_user_input", "call_id": "q1",
                                                 "arguments": #"{"questions":[{"question":"Which section first?","header":"S","options":[{"label":"2"}]}]}"#], at: 50))
        scene.engine.ingestSubagentAttention(CodexAttentionUpdate(sessionID: child.id, events: attention.takeEvents(), state: attention))
        #expect(scene.head(T.chatA)?.kind == .question)
        child.isRunning = false
        child.updatedAt = scene.clock.current.addingTimeInterval(60)
        scene.engine.takeCodexChildren([child])
        #expect(scene.head(T.chatA) == nil)
    }

    // MARK: A lapsed watch at rest (P218)

    /// A watched subagent that goes quiet past the limit with no event (its CLI chat was killed, no Codex app rescan)
    /// stops being watched when it lapses, and nothing is scheduled after: nothing polls at rest.
    @Test
    func aLapsedSubagentStopsBeingWatchedWithNoEvent() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let clock = E.Box(Date())
        let scheduled = E.Box<[E.ScheduledCheck]>([])
        let engine = E.engine(clock: clock, scheduled: scheduled)
        let url = T.write(T.subagent(T.subagentID(1), parent: T.chatA, running: true), id: T.subagentID(1), in: root, minutesAgo: 0)
        engine.ingest(E.started(T.chatA, tool: .codex, transcript: "/tmp/a.jsonl"), ingress: .bridge)
        engine.takeCodexChildren([CodexChildThread(id: T.subagentID(1), parentID: T.chatA, rootID: T.chatA, name: "Hubble",
                                                   isRunning: true, updatedAt: clock.current, transcriptPath: url.path)])
        defer { engine.subagentRollouts?.stop() }
        engine.subagentRollouts?.waitUntilIdle()
        #expect(engine.subagentRollouts?.attentionState(sessionID: T.subagentID(1)) != nil)
        E.runScheduledChecks(scheduled, clock: clock, for: 31 * 60)
        engine.subagentRollouts?.waitUntilIdle()
        #expect(engine.runningSubagents(for: T.chatA) == 0)
        #expect(engine.subagentRollouts?.attentionState(sessionID: T.subagentID(1)) == nil)
        #expect(scheduled.current.isEmpty)
    }

    // MARK: A subagent the book has not seen (P219)

    /// A subagent spawned after the last scan asks: the hook says only `default`, which is never shown as its name.
    @Test(arguments: ["default", ""])
    func aSubagentTheBookHasNotSeenIsNeverNamedDefault(type: String) async throws {
        let scene = AttentionScene()
        scene.begin(T.chatA, tool: .codex, prompt: "Continue MarathonTrainingLog")
        scene.hook(AttentionScene.codex("PermissionRequest", session: T.chatA, agent: T.subagentID(7),
                                        transcript: "/tmp/juice-attention/sessions/rollout-\(T.subagentID(7)).jsonl",
                                        extra: ["agent_type": type]), source: "codex")
        await scene.settle { scene.engine.openRequests.count == 1 }
        scene.at(9)
        let head = try #require(scene.head(T.chatA))
        #expect(head.agentID == T.subagentID(7))
        #expect(head.agentType == nil)
        // A subagent the book knows by no name is not `default` either.
        scene.engine.takeCodexChildren([CodexChildThread(id: T.subagentID(8), parentID: T.chatA, rootID: T.chatA, isRunning: true,
                                                         updatedAt: scene.clock.current, transcriptPath: "")])
        #expect(scene.engine.codexRequester(sessionID: T.chatA, agentID: T.subagentID(8), agentType: "default")?.agentType == nil)
        #expect(scene.engine.codexRequester(sessionID: T.chatA, agentID: T.subagentID(8), agentType: "explorer")?.agentType == "explorer")
    }

    // MARK: Helpers

    /// Lets the subagents' tracker and the main actor run until `done`, for at most 2 s.
    static func settle(_ engine: SessionEngine, until done: () -> Bool) async throws {
        for _ in 0..<200 {
            engine.subagentRollouts?.waitUntilIdle()
            await Task.yield()
            if done() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
