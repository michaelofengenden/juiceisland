import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// The rollout tracker that replaces upstream's watcher in the coordinator (P83): upstream's events, from bounded reads
/// on its own queue. The first three cases are upstream's own watcher tests (CodexSessionTrackingTests.swift).
@Suite(.serialized)
struct CodexRolloutTrackerTests {
    typealias F = RolloutFixtures
    typealias Box = EngineFixtures.Box

    private func tracker(_ events: Box<[AgentEvent]>, initialReadLimit: Int = 128 * 1_024,
                         bootstrapLimit: Int = 4 << 20, catchUpLimit: Int = 16 << 20) -> CodexRolloutTracker {
        let tracker = CodexRolloutTracker(pollInterval: 60, initialReadLimit: initialReadLimit,
                                          initialPromptBootstrapLimit: bootstrapLimit, catchUpLimit: catchUpLimit)
        tracker.eventHandler = { event in events.update { $0.append(event) } }
        return tracker
    }

    private func target(_ url: URL, _ id: String = F.sessionID) -> CodexRolloutWatchTarget {
        CodexRolloutWatchTarget(sessionID: id, transcriptPath: url.path)
    }

    private func metadata(_ events: [AgentEvent]) -> [CodexSessionMetadata] {
        events.compactMap { if case let .sessionMetadataUpdated(update) = $0 { update.codexMetadata } else { nil } }
    }

    private func completions(_ events: [AgentEvent]) -> [String] {
        events.compactMap { if case let .sessionCompleted(done) = $0 { done.summary } else { nil } }
    }

    private func sessionID(_ event: AgentEvent) -> String? {
        switch event {
        case let .sessionMetadataUpdated(update): update.sessionID
        case let .activityUpdated(update): update.sessionID
        case let .sessionCompleted(update): update.sessionID
        default: nil
        }
    }

    private func activities(_ events: [AgentEvent]) -> [String] {
        events.compactMap { if case let .activityUpdated(activity) = $0 { activity.summary } else { nil } }
    }

    @Test
    func appendedLinesBecomeUpstreamsEvents() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try Data().write(to: url)
        let events = Box<[AgentEvent]>([])
        let tracker = tracker(events)
        defer { tracker.stop() }
        tracker.sync(targets: [target(url)])
        tracker.waitUntilIdle()

        F.append(F.text([F.event("user_message", ["message": "Inspect the README."], at: 1),
                         F.event("task_started", at: 2),
                         F.item("function_call", ["name": "exec_command", "arguments": #"{"cmd":"git status -sb"}"#], at: 3)]), to: url)
        tracker.sync(targets: [target(url)])
        tracker.waitUntilIdle()
        F.append(F.text([F.event("task_complete", ["last_agent_message": "Finished the rollout tracking slice."], at: 4)]), to: url)
        tracker.sync(targets: [target(url)])
        tracker.waitUntilIdle()

        let seen = events.current
        #expect(metadata(seen).contains { $0.lastUserPrompt == "Inspect the README." })
        #expect(metadata(seen).contains { $0.currentTool == "exec_command" && $0.currentCommandPreview == "git status -sb" })
        #expect(completions(seen) == ["Finished the rollout tracking slice."])
    }

    @Test
    func aNewWatchTakesTheFirstPromptFromTheHeadAndTheLastFromTheTail() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        let filler = { (from: Int) in
            (0..<8).map { F.event("agent_message", ["message": "Filler \($0): " + String(repeating: "segment-", count: 16)], at: from + $0) }
        }
        let lines = F.head() + [F.message("user", "first prompt", at: 5)] + filler(10)
            + [F.message("user", "late prompt", at: 30)] + filler(40) + [F.message("assistant", "the reply", at: 60)]
        try F.text(lines).write(to: url, atomically: true, encoding: .utf8)
        let events = Box<[AgentEvent]>([])
        let tracker = tracker(events, initialReadLimit: 512, bootstrapLimit: 4_096)
        defer { tracker.stop() }

        tracker.sync(targets: [target(url)])
        tracker.waitUntilIdle()

        let seen = events.current
        #expect(metadata(seen).contains { $0.initialUserPrompt == "first prompt" && $0.lastUserPrompt == "late prompt" })
        #expect(activities(seen).contains("the reply"))
    }

    @Test
    func aNewWatchFoldsOnlyItsLastWindow() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        let old = String(repeating: "old-", count: 120)
        try F.text([F.event("agent_message", ["message": old], at: 1),
                    F.event("agent_message", ["message": "Tail bootstrap kept the watcher responsive."], at: 2)])
            .write(to: url, atomically: true, encoding: .utf8)
        let events = Box<[AgentEvent]>([])
        let tracker = tracker(events, initialReadLimit: 160)
        defer { tracker.stop() }

        tracker.sync(targets: [target(url)])
        tracker.waitUntilIdle()

        #expect(activities(events.current).contains("Tail bootstrap kept the watcher responsive."))
        #expect(!activities(events.current).contains(old))
    }

    /// The owner's case in small (300 MB, a 40 MB line near the end): starting to watch it reads the first chunk, the
    /// last 4 MB and the last 128 KB, on the tracker's queue. `sync` hands the targets over and returns: it is called
    /// on the main thread at every event.
    @Test
    func aHugeRolloutStartsQuicklyWithBothPrompts() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text(F.head() + F.turn(prompt: "first prompt", reply: "first reply", from: 10)).write(to: url, atomically: true, encoding: .utf8)
        F.appendHole(255 << 20, to: url)
        F.appendLongLine(40 << 20, at: 500, to: url)
        F.append(F.text(F.turn(prompt: "last prompt", reply: "all done", from: 600)), to: url)
        let small = F.rolloutURL(in: root, id: "019d516f-71ee-7e40-bcff-000000000009", second: 9)
        let smallText = F.text([F.event("user_message", ["message": "hold"], at: 1)])
        try smallText.write(to: small, atomically: true, encoding: .utf8)
        let events = Box<[AgentEvent]>([])
        let tracker = tracker(events)
        defer { tracker.stop() }

        // The small rollout's first event holds the tracker's queue until the gate opens (5 s at most).
        let gate = DispatchSemaphore(value: 0)
        let holding = DispatchSemaphore(value: 0)
        let isFirst = Box(true)
        tracker.eventHandler = { event in
            var first = false
            isFirst.update { first = $0; $0 = false }
            if first {
                holding.signal()
                _ = gate.wait(timeout: .now() + 5)
            }
            events.update { $0.append(event) }
        }
        tracker.sync(targets: [target(small, "small")])
        #expect(holding.wait(timeout: .now() + 5) == .success)

        let started = Date()
        tracker.sync(targets: [target(small, "small"), target(url)])
        let handedOver = Date().timeIntervalSince(started)
        let readWhileHeld = tracker.bytesRead
        gate.signal()
        tracker.waitUntilIdle()
        #expect(handedOver < 0.05)
        #expect(readWhileHeld == smallText.utf8.count)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(tracker.bytesRead - smallText.utf8.count <= (4 << 20) + (128 << 10) + 64 * 1_024 + 2)

        let seen = events.current.filter { sessionID($0) == F.sessionID }
        #expect(metadata(seen).last?.initialUserPrompt == "first prompt")
        #expect(metadata(seen).last?.lastUserPrompt == "last prompt")
        #expect(completions(seen) == ["all done"])
    }

    /// More than `catchUpLimit` appended between two reads: the last window is folded onto the prompts and the reply
    /// known so far, which stand when the window holds none.
    @Test
    func aRolloutFarBehindIsCaughtUpFromItsLastWindow() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text(F.head() + F.turn(prompt: "first prompt", reply: "first reply", from: 10)).write(to: url, atomically: true, encoding: .utf8)
        let events = Box<[AgentEvent]>([])
        let tracker = tracker(events, bootstrapLimit: 256 << 10, catchUpLimit: 1 << 20)
        defer { tracker.stop() }
        tracker.sync(targets: [target(url)])
        tracker.waitUntilIdle()

        F.appendHole(2 << 20, to: url)
        F.append(F.text(F.turn(prompt: "later prompt", reply: "later reply", from: 100)), to: url)
        tracker.sync(targets: [target(url)])
        tracker.waitUntilIdle()

        let seen = events.current
        #expect(metadata(seen).last?.initialUserPrompt == "first prompt")
        #expect(metadata(seen).last?.lastUserPrompt == "later prompt")
        #expect(completions(seen).last == "later reply")

        F.appendHole(2 << 20, to: url)
        F.append(F.text([F.event("task_started", at: 200),
                         F.event("exec_command_begin", ["command": ["bash", "-lc", "make"]], at: 201)]), to: url)
        tracker.sync(targets: [target(url)])
        tracker.waitUntilIdle()

        let running = try #require(metadata(events.current).last)
        #expect(running.currentTool == "exec_command")
        #expect(running.lastUserPrompt == "later prompt")
        #expect(running.lastAssistantMessage == "later reply")
    }

    /// A catch-up limit below the bootstrap limit, which the initializer allows: a rollout that falls behind by less
    /// than the bootstrap limit is caught up from its first byte, not from before it.
    @Test
    func aCatchUpWindowLargerThanTheRolloutStartsAtItsFirstByte() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text(F.head() + F.turn(prompt: "first prompt", reply: "first reply", from: 10)).write(to: url, atomically: true, encoding: .utf8)
        let events = Box<[AgentEvent]>([])
        let tracker = tracker(events, bootstrapLimit: 1 << 20, catchUpLimit: 256 << 10)
        defer { tracker.stop() }
        tracker.sync(targets: [target(url)])
        tracker.waitUntilIdle()

        F.appendHole(512 << 10, to: url)
        F.append(F.text(F.turn(prompt: "later prompt", reply: "later reply", from: 100)), to: url)
        tracker.sync(targets: [target(url)])
        tracker.waitUntilIdle()

        let seen = events.current
        #expect(metadata(seen).last?.initialUserPrompt == "first prompt")
        #expect(metadata(seen).last?.lastUserPrompt == "later prompt")
        #expect(completions(seen).last == "later reply")
    }

    /// A rollout cut back to a new one that is still longer than the catch-up limit is caught up from its last window,
    /// with its first prompt read from its head again, not taken from the window.
    @Test
    func aRolloutCutBackTakesItsFirstPromptFromItsHead() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text(F.head() + F.turn(prompt: "first prompt", reply: "first reply", from: 10)).write(to: url, atomically: true, encoding: .utf8)
        F.appendHole(3 << 20, to: url)
        F.append(F.text(F.turn(prompt: "last prompt", reply: "all done", from: 100)), to: url)
        let events = Box<[AgentEvent]>([])
        let tracker = tracker(events, bootstrapLimit: 256 << 10, catchUpLimit: 1 << 20)
        defer { tracker.stop() }
        tracker.sync(targets: [target(url)])
        tracker.waitUntilIdle()
        #expect(metadata(events.current).last?.initialUserPrompt == "first prompt")

        try F.text(F.head() + F.turn(prompt: "new first prompt", reply: "-", from: 200)).write(to: url, atomically: false, encoding: .utf8)
        F.appendHole(2 << 20, to: url)
        F.append(F.text(F.turn(prompt: "new last prompt", reply: "new reply", from: 300)), to: url)
        tracker.sync(targets: [target(url)])
        tracker.waitUntilIdle()

        let seen = events.current
        #expect(metadata(seen).last?.initialUserPrompt == "new first prompt")
        #expect(metadata(seen).last?.lastUserPrompt == "new last prompt")
        #expect(completions(seen).last == "new reply")
    }

    /// `sync` only hands the targets over, and the newest targets win.
    @Test
    func theNewestTargetsWin() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let first = F.rolloutURL(in: root, id: "019d516f-71ee-7e40-bcff-000000000001")
        let second = F.rolloutURL(in: root, id: "019d516f-71ee-7e40-bcff-000000000002")
        try Data().write(to: first)
        try Data().write(to: second)
        let events = Box<[AgentEvent]>([])
        let tracker = tracker(events)
        defer { tracker.stop() }

        tracker.sync(targets: [target(first, "one")])
        tracker.sync(targets: [target(second, "two")])
        tracker.waitUntilIdle()
        let prompt = F.text([F.event("user_message", ["message": "hello"], at: 1)])
        F.append(prompt, to: first)
        F.append(prompt, to: second)
        tracker.sync(targets: [target(second, "two")])
        tracker.waitUntilIdle()
        let prompted = events.current.compactMap { event -> String? in
            if case let .sessionMetadataUpdated(update) = event { update.sessionID } else { nil }
        }
        #expect(Set(prompted) == ["two"])
    }

    // MARK: Attention (P160)

    private func openedQuestions(_ updates: [CodexAttentionUpdate]) -> [String] {
        updates.flatMap(\.events).compactMap { if case let .questionOpened(question) = $0 { question.callID } else { nil } }
    }

    /// A question asked in the part of a long rollout the first read skips is found by the bootstrap and announced
    /// once; one whose turn already ended is not; the reviewer read on the way is kept.
    @Test
    func theBootstrapFindsAQuestionStillOpenBeforeTheFirstWindow() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let filler = (0..<600).map { F.event("agent_reasoning", ["text": String(repeating: "r", count: 400)], at: 10 + $0 % 50) }
        let question = CodexAttentionTests.call("request_user_input_async", "call_A1", arguments: CodexAttentionTests.asyncArguments, at: 5)
        let reviewer = F.line("turn_context", ["cwd": "/tmp/project", "approval_policy": "on-request", "approvals_reviewer": "user"], at: 4)
        for (id, ended, expected) in [("019d516f-71ee-7e40-bcff-0000000000a1", false, ["call_A1"]),
                                      ("019d516f-71ee-7e40-bcff-0000000000a2", true, [])] {
            let url = F.rolloutURL(in: root, id: id, second: ended ? 2 : 1)
            let lines = [F.meta(id: id), reviewer, question, CodexAttentionTests.output("call_A1", #"{"accepted":true}"#, at: 6)]
                + (ended ? [F.event("task_complete", at: 7)] : []) + filler
            try F.text(lines).write(to: url, atomically: true, encoding: .utf8)
            let updates = Box<[CodexAttentionUpdate]>([])
            let tracker = tracker(Box([]))
            defer { tracker.stop() }
            tracker.attentionHandler = { update in updates.update { $0.append(update) } }
            tracker.sync(targets: [target(url, id)])
            tracker.waitUntilIdle()
            #expect(openedQuestions(updates.current) == expected, "\(id)")
            #expect(tracker.attentionState(sessionID: id)?.reviewer == "user")
            // Read again: nothing new is news.
            tracker.pollNow(sessionID: id)
            tracker.waitUntilIdle()
            #expect(openedQuestions(updates.current) == expected)
        }
    }

    /// Appended lines reach the handler: the question, its reply envelope, a call and its output.
    @Test
    func appendedAttentionLinesReachTheHandler() throws {
        let root = F.sessionsFolder()
        defer { F.remove(root) }
        let url = F.rolloutURL(in: root)
        try F.text([F.meta()]).write(to: url, atomically: true, encoding: .utf8)
        let updates = Box<[CodexAttentionUpdate]>([])
        let tracker = tracker(Box([]))
        defer { tracker.stop() }
        tracker.attentionHandler = { update in updates.update { $0.append(update) } }
        tracker.sync(targets: [target(url)])
        tracker.waitUntilIdle()
        F.append(F.text([CodexAttentionTests.call("request_user_input_async", "call_A1", arguments: CodexAttentionTests.asyncArguments),
                         CodexAttentionTests.call("exec_command", "call_E", arguments: #"{"cmd":"ls"}"#, at: 2)]), to: url)
        tracker.pollNow(sessionID: F.sessionID)
        tracker.waitUntilIdle()
        F.append(F.text([F.message("user", CodexAttentionTests.reply(["call_A1"]), at: 3),
                         CodexAttentionTests.output("call_E", "ok", at: 4)]), to: url)
        tracker.pollNow(sessionID: F.sessionID)
        tracker.waitUntilIdle()
        let events = updates.current.flatMap(\.events)
        #expect(openedQuestions(updates.current) == ["call_A1"])
        #expect(events.contains(.questionClosed(callID: "call_A1", byReply: true)))
        #expect(events.contains(.output(callID: "call_E")))
        #expect(updates.current.allSatisfy { $0.sessionID == F.sessionID })
    }
}
