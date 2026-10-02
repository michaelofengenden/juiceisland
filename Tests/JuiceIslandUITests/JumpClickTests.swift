import Foundation
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// Row clicks: Live runs the engine's jump (its runner stood in here: no osascript, no `open`) off the main thread
/// and notes an outcome that missed the exact tab; Demo never jumps and notes "Demo session".
@MainActor
struct JumpClickTests {
    typealias ID = FixtureSessionFeed.ID

    /// Every runner call, and whether it ran on the main thread.
    final class RunnerLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(name: String, onMain: Bool)] = []
        func note(_ name: String) { lock.withLock { calls.append((name, Thread.isMainThread)) } }
        var names: [String] { lock.withLock { calls.map(\.name) } }
        var ranOnMain: Bool { lock.withLock { calls.contains { $0.onMain } } }
    }

    private nonisolated static let denied: JumpRunner.AppleScript = { _, _ in
        throw JumpRunnerError.appleScriptFailed("execution error: Not authorized to send Apple events to Terminal. (-1743)")
    }

    /// A headless engine over the prototype's sessions (fixture events, no bridge, no runtime) and a live model on it.
    private func makeLive(_ log: RunnerLog, appleScript: @escaping JumpRunner.AppleScript = { _, _ in "matched" },
                          noteLifetime: Duration = JumpNote.lifetime) -> (model: EngineSessionsModel, engine: SessionEngine) {
        var runner = JumpRunner()
        runner.appURL = { _ in log.note("appURL"); return URL(fileURLWithPath: "/Applications/Stub.app") }
        runner.isAppRunning = { _ in log.note("isAppRunning"); return true }
        runner.appleScript = { script, timeout in
            log.note("appleScript")
            return try appleScript(script, timeout)
        }
        runner.open = { _, _ in log.note("open") }
        runner.command = { _, _, _ in log.note("command"); return false }
        var dependencies = SessionEngine.Dependencies()
        dependencies.jumpRunner = runner
        dependencies.sendCommand = { _ in }
        dependencies.isSessionFrontmost = { _ in false }
        dependencies.updateProcessRoots = { _ in }
        dependencies.isOtherIslandRunning = { false }
        dependencies.socketHasOwner = { _ in false }
        dependencies.startBridge = { _ in throw CocoaError(.featureUnsupported) }
        dependencies.startRuntime = { _ in }
        dependencies.scheduleSignalCheck = { _, _ in }
        let now = DemoClock.now
        dependencies.now = { now }
        var configuration = SessionEngine.Configuration.headless
        configuration.socketURL = FileManager.default.temporaryDirectory.appendingPathComponent("juice-island-jump-\(UUID().uuidString).sock")
        configuration.suppressWhenFrontmost = false
        configuration.excludedWorkingDirectories = []
        let engine = SessionEngine(configuration: configuration, dependencies: dependencies)
        engine.loadPreviewEvents(FixtureSessionFeed.events(.prototype, now: now))
        return (EngineSessionsModel(engine: engine, clock: { now }, jumps: .live, noteLifetime: noteLifetime), engine)
    }

    private func outcome(_ result: JumpResult, _ failure: JumpFailure? = nil, host: String = "Terminal") -> JumpOutcome {
        JumpOutcome(id: UUID(), sessionID: "s1", host: host, startedAt: DemoClock.now, duration: 0, result: result,
                    failure: failure, message: "", steps: [])
    }

    @Test
    func liveClickJumpsOnceToTheRowsSession() async throws {
        let log = RunnerLog()
        let (model, engine) = makeLive(log)
        let task = try #require(model.startJump(ID.running))
        // A second click while the first jump runs waits for it.
        #expect(model.startJump(ID.running) == nil)
        await task.value
        #expect(engine.recentJumps.map(\.sessionID) == [ID.running])
        #expect(engine.recentJumps.first?.result == .matched)
        #expect(log.names.filter { $0 == "appleScript" }.count == 1)
        // An exact jump leaves no note.
        #expect(model.jumpNote == nil)
    }

    @Test
    func demoClickNeverJumpsAndSaysSo() {
        let feed = FixtureSessionFeed(scenario: .prototype)
        let model = feed.makeModel()
        #expect(model.startJump(ID.running) == nil)
        model.jump(ID.codexRunning)
        #expect(feed.engine.recentJumps.isEmpty)
        #expect(model.jumpNote?.sessionID == ID.codexRunning)
        #expect(model.jumpNote?.text == "Demo session")
    }

    @Test
    func theJumpNeverRunsOnTheMainThread() async throws {
        let log = RunnerLog()
        // Denied automation: upstream's script runs on the runner's worker, the fallback on the caller's thread.
        let (model, engine) = makeLive(log, appleScript: Self.denied)
        let task = try #require(model.startJump(ID.running))
        await task.value
        #expect(log.names.contains("appleScript"))
        #expect(log.names.contains("open"))
        #expect(!log.ranOnMain)
        #expect(engine.recentJumps.first?.result == .fallbackActivated)
        #expect(model.jumpNote?.sessionID == ID.running)
        #expect(model.jumpNote?.text == "Allow Juice Island to control Terminal in System Settings › Privacy & Security › Automation")
    }

    @Test
    func controlGTakesTheSamePathForTheSessionItTargets() async throws {
        let log = RunnerLog()
        let (model, engine) = makeLive(log)
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: DemoClock.now), sessions: model)
        let target = try #require(model.needsYou.first?.id)
        #expect(SessionListLayout.jumpTargetID(model.rows) == target)
        #expect(WindowKeyRouter.perform(.jumpToNeedsYou, env: env))
        for _ in 0..<200 where engine.recentJumps.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.requestedJumps == [target])
        #expect(engine.recentJumps.map(\.sessionID) == [target])
    }

    @Test
    func aNoteClearsItself() async throws {
        let (model, _) = makeLive(RunnerLog(), appleScript: Self.denied, noteLifetime: .milliseconds(50))
        let task = try #require(model.startJump(ID.running))
        await task.value
        #expect(model.jumpNote != nil)
        for _ in 0..<200 where model.jumpNote != nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.jumpNote == nil)
    }

    @Test
    func eachOutcomeHasItsNote() {
        #expect(JumpNote.text(for: outcome(.matched)) == nil)
        #expect(JumpNote.text(for: outcome(.noTarget)) == "No terminal known for this session yet")
        #expect(JumpNote.text(for: outcome(.activatedOnly, host: "iTerm")) == "Brought iTerm forward, but not the session's own tab")
        #expect(JumpNote.text(for: outcome(.fallbackActivated, .automationDenied))
            == "Allow Juice Island to control Terminal in System Settings › Privacy & Security › Automation")
        #expect(JumpNote.text(for: outcome(.failed, .automationDenied, host: "Ghostty"))
            == "Allow Juice Island to control Ghostty in System Settings › Privacy & Security › Automation")
        #expect(JumpNote.text(for: outcome(.fallbackActivated, .timedOut)) == "Terminal did not answer in time · brought Terminal forward")
        #expect(JumpNote.text(for: outcome(.fallbackActivated, .scriptFailed)) == "Could not find the session's tab in Terminal · brought Terminal forward")
        #expect(JumpNote.text(for: outcome(.failed, .unknownHost, host: "Hyper")) == "Juice Island can't jump into Hyper yet")
        #expect(JumpNote.text(for: outcome(.failed, .openFailed, host: "Codex.app")) == "Could not open Codex.app")
        #expect(JumpNote.text(for: outcome(.failed, .timedOut)) == "Terminal did not answer in time")
        #expect(JumpNote.text(for: outcome(.failed)) == "Could not jump to Terminal")
    }
}
