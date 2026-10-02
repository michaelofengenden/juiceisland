import Darwin
import Foundation
import IslandHookNotes
import Testing
@testable import IslandEngine
import OpenIslandCore

/// The context notes in the engine: merged per session, laid over upstream's jump targets, and StopFailure as a
/// failed turn that needs you (spec §3.4, §3.8). Headless engines; no socket unless a test binds a scratch one.
@MainActor
struct HookNoteEngineTests {
    typealias F = EngineFixtures
    typealias Box = EngineFixtures.Box

    private func note(_ id: String, _ event: String, iterm: String? = nil, tmux: String? = nil, pane: String? = nil,
                      pid: Int32? = nil, host: String? = nil, stopHookActive: Bool? = nil) -> HookContextNote {
        // Claude's, as the helper sends them: `--source claude` (a version-2 note with none is Codex's, P290).
        HookContextNote(event: event, sessionID: id, stopHookActive: stopHookActive, itermSessionID: iterm, tmux: tmux,
                        tmuxPane: pane, agentPID: pid, hostBundleID: host, source: "claude")
    }

    /// A session with a prompt, so it is surfaced and has turn 1.
    private func prompted(_ engine: SessionEngine, _ id: String = "s1") {
        engine.ingest(F.started(id), ingress: .bridge)
        engine.ingest(F.prompt(id), ingress: .bridge)
    }

    // MARK: Contexts

    @Test
    func notesMergeIntoTheSessionsContext() throws {
        let engine = F.engine()
        engine.ingest(note: note("s1", "SessionStart", iterm: "w0t1p2:UUID-A", pid: 900, host: "com.googlecode.iterm2"))
        engine.ingest(note: note("s1", "PreToolUse"))
        engine.ingest(note: note("s1", "Stop", stopHookActive: true))
        let context = try #require(engine.hookContext(for: "s1"))
        #expect(context.itermSessionID == "UUID-A")
        #expect(context.agentPID == 900)
        #expect(context.hostBundleID == "com.googlecode.iterm2")
        #expect(context.lastEvent == "Stop")
        #expect(context.stopHookActive == true)
        engine.ingest(note: note("s1", "Stop", stopHookActive: false))
        #expect(engine.hookContext(for: "s1")?.stopHookActive == false)
    }

    /// The session resumed by another agent process outside tmux: the old pane is no longer its target.
    @Test
    func aNoteFromANewAgentProcessReplacesTheOldHandles() throws {
        var dependencies = SessionEngine.Dependencies()
        dependencies.updateProcessRoots = { _ in }
        dependencies.ttyForPID = { $0 == 901 ? "/dev/ttys045" : nil }
        let engine = SessionEngine(configuration: .headless, dependencies: dependencies)
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(note: note("s1", "SessionStart", iterm: "w0t0p1:OLD", tmux: "/private/tmp/tmux-501/default,1,0", pane: "%3",
                                 pid: 900, host: "com.googlecode.iterm2"))
        engine.ingest(note: note("s1", "UserPromptSubmit", pid: 901, host: "com.apple.Terminal"))
        let context = try #require(engine.hookContext(for: "s1"))
        #expect(context.tmuxPane == nil && context.tmuxSocketPath == nil && context.itermSessionID == nil)
        #expect(context.agentPID == 901 && context.hostBundleID == "com.apple.Terminal")
        let session = try #require(engine.state.session(id: "s1"))
        let target = try #require(engine.effectiveJumpTarget(for: session))
        #expect(target.tmuxTarget == nil)
        #expect(target.terminalTTY == "/dev/ttys045")
        // The same process's later notes still merge.
        engine.ingest(note: note("s1", "PreToolUse"))
        #expect(engine.hookContext(for: "s1")?.agentPID == 901)
        #expect(engine.hookContext(for: "s1")?.hostBundleID == "com.apple.Terminal")
    }

    /// A dismissed session's notes go when its tombstone expires, so they never build up over a long run.
    @Test
    func anExpiredSessionsNotesAreForgotten() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        prompted(engine)
        engine.ingest(note: note("s1", "StopFailure", pid: 900))
        engine.dismiss(sessionID: "s1")
        #expect(engine.hookContext(for: "s1") != nil)
        clock.update { $0 += 11 * 60 }
        engine.ingest(F.started("s2"), ingress: .bridge)
        #expect(engine.hookContext(for: "s1") == nil)
        #expect(engine.hookNotes.pendingFailures["s1"] == nil)
    }

    @Test
    func tmuxHandlesComeFromTheTMUXVariable() {
        #expect(HookContext.tmuxSocketPath("/private/tmp/tmux-501/default,4242,0") == "/private/tmp/tmux-501/default")
        #expect(HookContext.tmuxSocketPath("/tmp/a,b/sock,1,2") == "/tmp/a,b/sock")
        #expect(HookContext.tmuxSocketPath("garbage") == nil)
        #expect(HookContext.itermUUID("w0t1p2:ABC") == "ABC")
        #expect(HookContext.itermUUID("ABC") == "ABC")
        #expect(HookContext.itermUUID("w0t1p2:") == nil)
    }

    /// P17: iTerm's own session id replaces the focused-split id upstream captured; the tty comes from the agent (P18).
    @Test
    func theJumpTargetGetsTheExactHandles() throws {
        var dependencies = SessionEngine.Dependencies()
        dependencies.updateProcessRoots = { _ in }
        dependencies.ttyForPID = { $0 == 900 ? "/dev/ttys044" : nil }
        let engine = SessionEngine(configuration: .headless, dependencies: dependencies)
        engine.ingest(.sessionStarted(SessionStarted(
            sessionID: "s1", title: "Claude · project", tool: .claudeCode, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: F.now, jumpTarget: JumpTarget(terminalApp: "iTerm", workspaceName: "project", paneTitle: "claude",
                                                     terminalSessionID: "FOCUSED-SPLIT", terminalTTY: "/dev/ttys001"))), ingress: .bridge)
        engine.ingest(note: note("s1", "PreToolUse", iterm: "w0t0p1:OWN-SPLIT", pid: 900, host: "com.googlecode.iterm2"))
        let session = try #require(engine.state.session(id: "s1"))
        let target = try #require(engine.effectiveJumpTarget(for: session))
        #expect(target.terminalSessionID == "OWN-SPLIT")
        #expect(target.terminalTTY == "/dev/ttys044")
        // Upstream's own target is left as it was.
        #expect(session.jumpTarget?.terminalSessionID == "FOCUSED-SPLIT")
        #expect(engine.jumpContext(for: "s1") == JumpContext(hostBundleID: "com.googlecode.iterm2", itermSessionID: "OWN-SPLIT", agentPID: 900))
    }

    /// An ITERM_SESSION_ID leaked into another terminal's environment is not used there.
    @Test
    func anITermIDIsUsedOnlyForITerm() throws {
        let engine = F.engine()
        prompted(engine)
        engine.ingest(note: note("s1", "PreToolUse", iterm: "w0t0p1:LEAKED", host: "com.apple.Terminal"))
        let session = try #require(engine.state.session(id: "s1"))
        let target = try #require(engine.effectiveJumpTarget(for: session))
        #expect(target.terminalSessionID == nil)
        #expect(target.terminalTTY == "/dev/ttys003")
    }

    @Test
    func aTmuxPaneBecomesTheTargetAndItsTTYIsNotTheTabs() throws {
        var dependencies = SessionEngine.Dependencies()
        dependencies.updateProcessRoots = { _ in }
        dependencies.ttyForPID = { _ in "/dev/ttys099" }
        let engine = SessionEngine(configuration: .headless, dependencies: dependencies)
        engine.ingest(F.started("s1"), ingress: .bridge)
        engine.ingest(note: note("s1", "PreToolUse", tmux: "/private/tmp/tmux-501/default,1,0", pane: "%3", pid: 5))
        let session = try #require(engine.state.session(id: "s1"))
        let target = try #require(engine.effectiveJumpTarget(for: session))
        #expect(target.tmuxTarget == "%3")
        #expect(target.tmuxSocketPath == "/private/tmp/tmux-501/default")
        #expect(target.terminalTTY == "/dev/ttys003")
    }

    /// A session upstream has no target for still jumps when its notes named the host.
    @Test
    func aNoteAloneGivesATarget() throws {
        let engine = F.engine()
        engine.ingest(.sessionStarted(SessionStarted(sessionID: "s9", title: "Claude · project", tool: .claudeCode, origin: .live,
                                                     initialPhase: .running, summary: "Started.", timestamp: F.now)), ingress: .bridge)
        let session = try #require(engine.state.session(id: "s9"))
        #expect(engine.effectiveJumpTarget(for: session) == nil)
        // A note that names no host and no pane still leaves nothing to jump to.
        engine.ingest(note: note("s9", "SessionStart", pid: 77))
        #expect(engine.effectiveJumpTarget(for: session) == nil)
        engine.ingest(note: note("s9", "PreToolUse", host: "com.mitchellh.ghostty"))
        let target = try #require(engine.effectiveJumpTarget(for: session))
        #expect(target.terminalApp == "Ghostty")
    }

    /// The frontmost check sees the exact handles, so a background split does not mute its alert (P17).
    @Test
    func theFrontmostCheckSeesTheExactHandles() async throws {
        let seen = Box<[String?]>([])
        let engine = F.engine(suppress: true, isFrontmost: { session in
            seen.update { $0.append(session.jumpTarget?.terminalSessionID) }
            return false
        })
        engine.ingest(.sessionStarted(SessionStarted(
            sessionID: "s1", title: "Claude · project", tool: .claudeCode, origin: .live, initialPhase: .running, summary: "Started.",
            timestamp: F.now, jumpTarget: JumpTarget(terminalApp: "iTerm", workspaceName: "project", paneTitle: "claude",
                                                     terminalSessionID: "FOCUSED-SPLIT"))), ingress: .bridge)
        engine.ingest(note: note("s1", "PermissionRequest", iterm: "w0t0p1:OWN-SPLIT", host: "com.googlecode.iterm2"))
        engine.ingest(F.permission("s1"), ingress: .bridge)
        // Claude's own notice that it waits confirms the request; the alert's frontmost check follows.
        engine.ingest(note: HookContextNote(event: "Notification", sessionID: "s1", notificationType: "permission_prompt", source: "claude"))
        for _ in 0..<100 where seen.current.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(seen.current == ["OWN-SPLIT"])
    }

    // MARK: StopFailure

    @Test
    func aStopFailureNoteBeforeItsStopIsATurnFailedThatNeedsYou() {
        let signals = Box<[EngineSignal]>([])
        let checks = Box<[TimeInterval]>([])
        let scheduled = Box<[F.ScheduledCheck]>([])
        let clock = Box(F.now)
        let engine = F.engine(clock: clock, checks: checks, scheduled: scheduled)
        engine.onSignal = { signal in signals.update { $0.append(signal) } }
        prompted(engine)
        engine.ingest(note: note("s1", "StopFailure"))
        engine.ingest(F.completed("s1"), ingress: .bridge)
        #expect(signals.current == [.needsYou(sessionID: "s1")])
        F.runScheduledChecks(scheduled, clock: clock, for: 5)
        // The held Done was dropped.
        #expect(signals.current == [.needsYou(sessionID: "s1")])
        let session = engine.state.session(id: "s1")!
        #expect(engine.hasFailedTurn(session))
        #expect(engine.statusWord(for: session) == .failed)
        #expect(engine.needsYouCount == 1)
        #expect(engine.nextNeedsYou?.id == "s1")
    }

    @Test
    func aStopFailureNoteAfterItsStopStillFailsTheTurn() {
        let signals = Box<[EngineSignal]>([])
        let clock = Box(F.now)
        let scheduled = Box<[F.ScheduledCheck]>([])
        let engine = F.engine(clock: clock, scheduled: scheduled)
        engine.onSignal = { signal in signals.update { $0.append(signal) } }
        prompted(engine)
        engine.ingest(F.completed("s1"), ingress: .bridge)
        clock.update { $0 += 0.2 }
        engine.ingest(note: note("s1", "StopFailure"))
        F.runScheduledChecks(scheduled, clock: clock, for: 5)
        #expect(signals.current == [.needsYou(sessionID: "s1")])
        #expect(engine.needsYouCount == 1)
    }

    /// A normal Stop is never a failure, whatever its text, and a note for another event changes nothing.
    @Test
    func aNormalStopIsNeverAFailure() {
        let signals = Box<[EngineSignal]>([])
        let clock = Box(F.now)
        let scheduled = Box<[F.ScheduledCheck]>([])
        let engine = F.engine(clock: clock, scheduled: scheduled)
        engine.onSignal = { signal in signals.update { $0.append(signal) } }
        prompted(engine)
        engine.ingest(note: note("s1", "Stop"))
        engine.ingest(.sessionCompleted(SessionCompleted(sessionID: "s1", summary: "rate_limit", timestamp: F.now)), ingress: .bridge)
        F.runScheduledChecks(scheduled, clock: clock, for: 5)
        #expect(signals.current == [.done(sessionID: "s1")])
        #expect(engine.needsYouCount == 0)
        #expect(engine.statusWord(for: engine.state.session(id: "s1")!) == .done)
    }

    /// A StopFailure note whose Stop never came does not turn a later turn's Stop into a failure.
    @Test
    func aStaleFailureNoteIsForgottenAtTheNextPrompt() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        prompted(engine)
        engine.ingest(note: note("s1", "StopFailure"))
        engine.ingest(F.prompt("s1", "again"), ingress: .bridge)
        engine.ingest(F.completed("s1"), ingress: .bridge)
        #expect(engine.needsYouCount == 0)
        clock.update { $0 += 60 }
        prompted(engine, "s2")
        engine.ingest(note: note("s2", "StopFailure"))
        clock.update { $0 += HookNoteBook.failureWindow + 1 }
        engine.ingest(F.completed("s2"), ingress: .bridge)
        #expect(engine.needsYouCount == 0)
    }

    /// A failed turn needs you until a new prompt, a dismiss or a jump to the session.
    @Test
    func aFailedTurnIsClearedByAPromptADismissOrAJump() async {
        let engine = F.engine()
        for id in ["a", "b", "c"] {
            prompted(engine, id)
            engine.ingest(note: note(id, "StopFailure"))
            engine.ingest(F.completed(id), ingress: .bridge)
        }
        #expect(engine.needsYouCount == 3)
        engine.ingest(F.prompt("a", "retry"), ingress: .bridge)
        #expect(engine.needsYouCount == 2)
        engine.dismiss(sessionID: "b")
        #expect(engine.needsYouCount == 1)
        _ = await engine.jump(sessionID: "c")
        #expect(engine.needsYouCount == 0)
        #expect(engine.failedTurns.isEmpty)
    }

    /// "Jump to what needs you" finds the failed session's tab already in front: the owner sees it, so it is cleared.
    @Test
    func aFailedTurnWhoseTabIsInFrontIsSeen() async {
        let engine = F.engine(frontmost: true)
        prompted(engine)
        engine.ingest(note: note("s1", "StopFailure"))
        engine.ingest(F.completed("s1"), ingress: .bridge)
        #expect(engine.nextNeedsYou?.id == "s1")
        #expect(await engine.jumpToNextNeedsYou() == nil)
        #expect(engine.needsYouCount == 0)
    }

    /// A failed turn ranks with the sessions that wait on you, not with the finished ones.
    @Test
    func aFailedTurnRanksAsAttention() {
        let clock = Box(F.now)
        let engine = F.engine(clock: clock)
        prompted(engine, "done")
        engine.ingest(F.completed("done", at: F.now + 5), ingress: .bridge)
        prompted(engine, "failed")
        engine.ingest(note: note("failed", "StopFailure"))
        engine.ingest(F.completed("failed", at: F.now), ingress: .bridge)
        #expect(engine.rows.first?.id == "failed")
    }

    /// P7 with a failed turn: a process-monitor pass that loses the session cannot end it while it needs you.
    @Test
    func aFailedTurnSurvivesTheProcessMonitor() {
        let engine = F.engine()
        prompted(engine)
        engine.ingest(note: note("s1", "StopFailure"))
        engine.ingest(F.completed("s1"), ingress: .bridge)
        let without = SessionState(sessions: engine.state.sessions.filter { $0.id != "s1" })
        for _ in 0..<5 { engine.applyMonitoredState(without) }
        #expect(engine.state.session(id: "s1") != nil)
        #expect(engine.needsYouCount == 1)
    }

    // MARK: The second socket

    private final class FakeReceiver: HookNoteReceiving, @unchecked Sendable {
        let lock = NSLock()
        var stopped = false
        func stop() { lock.withLock { stopped = true } }
    }

    private final class FakeBridge: EngineBridge, @unchecked Sendable {
        func updateStateSnapshot(_ snapshot: SessionState) {}
        func stop() {}
    }

    private func liveEngine(notesURL: URL?, starts: Box<[URL]>, handler: Box<(@Sendable (HookContextNote) -> Void)?>,
                            fail: Bool = false) -> (SessionEngine, FakeReceiver) {
        var configuration = SessionEngine.Configuration.headless
        configuration.startBridge = true
        configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
        configuration.hookNotesSocketURL = notesURL
        let receiver = FakeReceiver()
        var dependencies = SessionEngine.Dependencies()
        dependencies.isOtherIslandRunning = { false }
        dependencies.socketHasOwner = { _ in false }
        dependencies.startBridge = { _ in FakeBridge() }
        dependencies.startRuntime = { _ in }
        dependencies.updateProcessRoots = { _ in }
        dependencies.startHookNotes = { url, deliver in
            starts.update { $0.append(url) }
            if fail { throw HookNoteListenerError.inUse(path: url.path) }
            handler.update { $0 = deliver }
            return receiver
        }
        return (SessionEngine(configuration: configuration, dependencies: dependencies), receiver)
    }

    @Test
    func theNoteSocketStartsAndStopsWithTheBridge() async throws {
        let starts = Box<[URL]>([])
        let handler = Box<(@Sendable (HookContextNote) -> Void)?>(nil)
        let url = URL(fileURLWithPath: "/tmp/jin-\(UUID().uuidString.prefix(8)).sock")
        let (engine, receiver) = liveEngine(notesURL: url, starts: starts, handler: handler)
        try engine.start()
        #expect(starts.current == [url])
        try engine.start()
        #expect(starts.current == [url])
        handler.current?(note("s1", "PreToolUse", pane: "%1"))
        for _ in 0..<100 where engine.hookContext(for: "s1") == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.hookContext(for: "s1")?.tmuxPane == "%1")
        engine.stop()
        #expect(receiver.lock.withLock { receiver.stopped })
    }

    @Test
    func aNoteSocketThatCannotStartLeavesTheBridgeRunning() throws {
        let starts = Box<[URL]>([])
        let handler = Box<(@Sendable (HookContextNote) -> Void)?>(nil)
        let (engine, _) = liveEngine(notesURL: URL(fileURLWithPath: "/tmp/jin-x.sock"), starts: starts, handler: handler, fail: true)
        try engine.start()
        #expect(engine.bridgeServer != nil)
        #expect(engine.hookNotesProblem == "Another app receives hook notes")
        engine.stop()
    }

    /// Headless engines, the demo and every test built on `.headless` never open the note socket.
    @Test
    func headlessEnginesHaveNoNoteSocket() {
        #expect(SessionEngine.Configuration.headless.hookNotesSocketURL == nil)
        #expect(SessionEngine.Configuration().hookNotesSocketURL == nil)
        #expect(SessionEngine.Configuration.live.hookNotesSocketURL == HookNoteSocket.defaultURL)
        let starts = Box<[URL]>([])
        let handler = Box<(@Sendable (HookContextNote) -> Void)?>(nil)
        let (engine, _) = liveEngine(notesURL: nil, starts: starts, handler: handler)
        try? engine.start()
        #expect(starts.current.isEmpty)
        engine.stop()
    }

    /// The real listener on a scratch path: it receives what the helper's sender sends, refuses a second listener on
    /// the same path, and removes its file when it stops.
    @Test
    func theListenerReceivesNotesOnAScratchSocket() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jin-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("n.sock")
        let received = Box<[HookContextNote]>([])
        let listener = HookNoteListener(url: url) { note in received.update { $0.append(note) } }
        try listener.start()
        #expect(throws: HookNoteListenerError.inUse(path: url.path)) {
            try HookNoteListener(url: url) { _ in }.start()
        }
        let sent = note("s1", "Stop", pane: "%2")
        #expect(HookNoteSender.send(try #require(sent.encoded()), to: url) == .sent)
        #expect(HookNoteSender.send(Data("not a note".utf8), to: url) == .sent)
        for _ in 0..<200 where received.current.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(received.current == [sent])
        var info = stat()
        #expect(stat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        listener.stop()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // A stale file (bound once, nobody receives now) is replaced.
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        var address = try #require(HookNoteSocket.address(for: url))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        close(fd)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let again = HookNoteListener(url: url) { _ in }
        try again.start()
        again.stop()
    }

    /// A burst of hooks (parallel tool calls in several sessions) while the listener is busy: every note waits in
    /// the socket's buffer instead of being dropped (macOS gives a datagram socket 4 KiB, a handful of notes).
    @Test
    func aBurstOfNotesWaitsForABusyListener() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jin-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("n.sock")
        let received = Box<[HookContextNote]>([])
        let busy = DispatchSemaphore(value: 0)
        let listener = HookNoteListener(url: url) { note in
            if received.current.isEmpty { busy.wait() }
            received.update { $0.append(note) }
        }
        try listener.start()
        defer { listener.stop() }
        let burst = (0..<100).map { note("session-\($0)", "PreToolUse", iterm: "w0t0p0:\(UUID().uuidString)",
                                         tmux: "/private/tmp/tmux-501/default,4242,0", pane: "%\($0)", pid: 4_000 + Int32($0),
                                         host: "com.googlecode.iterm2") }
        let results = try burst.map { HookNoteSender.send(try #require($0.encoded()), to: url) }
        busy.signal()
        #expect(results.allSatisfy { $0 == .sent })
        for _ in 0..<300 where received.current.count < burst.count { try await Task.sleep(for: .milliseconds(10)) }
        #expect(received.current.count == burst.count)
    }
}
