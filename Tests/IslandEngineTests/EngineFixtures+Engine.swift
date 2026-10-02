import Foundation
@testable import IslandEngine
import OpenIslandCore

extension EngineFixtures {
    /// A check the engine asked for: when it falls due on the test's clock, and what it runs.
    struct ScheduledCheck: Sendable {
        let at: Date
        let run: @MainActor @Sendable () -> Void
    }

    /// A headless engine: commands go to `sent` (while `failing` holds, each send fails as an unreachable bridge
    /// would, and nothing is recorded), replies to `replies` (never a terminal), the clock is `clock`, and held Done
    /// signals wait for the test to call `flushHeldSignals()` or `runScheduledChecks` (every requested check is
    /// recorded in `checks` and `scheduled`). `isFrontmost` replaces the frontmost check, which is `frontmost` otherwise;
    /// `frontmostApp` is the frontmost app's bundle id (none by default). `atPrompt` says whether an agent's pid is at
    /// its terminal's controls (every one is, by default; no process is looked at).
    @MainActor
    static func engine(sent: Box<[BridgeCommand]> = Box([]), failing: Box<Bool> = Box(false), frontmost: Bool = false,
                       suppress: Bool = false, excluded: [String] = ["/tmp/juice-test-cli"], clock: Box<Date> = Box(now),
                       checks: Box<[TimeInterval]> = Box([]), scheduled: Box<[ScheduledCheck]> = Box([]),
                       isFrontmost: (@Sendable (AgentSession) async -> Bool)? = nil,
                       frontmostApp: Box<String?> = Box(nil),
                       replies: @escaping @Sendable (ReplyRoute, String) -> Bool = { _, _ in false },
                       atPrompt: @escaping @Sendable (Int32) -> Bool = { _ in true },
                       configure: ((inout SessionEngine.Dependencies) -> Void)? = nil) -> SessionEngine {
        var configuration = SessionEngine.Configuration.headless
        configuration.suppressWhenFrontmost = suppress
        configuration.excludedWorkingDirectories = excluded
        var dependencies = SessionEngine.Dependencies()
        dependencies.sendCommand = { command in
            if failing.current { throw CocoaError(.featureUnsupported) }
            sent.update { $0.append(command) }
        }
        dependencies.sendReply = replies
        dependencies.agentAtPrompt = atPrompt
        // The pids in the tests' notes are made up: no real process's terminal is looked up.
        dependencies.ttyForPID = { _ in nil }
        dependencies.appForPID = { _ in nil }
        dependencies.isSessionFrontmost = isFrontmost ?? { _ in frontmost }
        dependencies.frontmostBundleID = { frontmostApp.current }
        dependencies.updateProcessRoots = { _ in }
        dependencies.isOtherIslandRunning = { false }
        dependencies.now = { clock.current }
        dependencies.scheduleSignalCheck = { delay, check in
            checks.update { $0.append(delay) }
            scheduled.update { $0.append(ScheduledCheck(at: clock.current.addingTimeInterval(delay), run: check)) }
        }
        // A request's 8 s window is a scheduled check like the others (not counted in `checks`).
        dependencies.scheduleAttentionCheck = { delay, check in
            scheduled.update { $0.append(ScheduledCheck(at: clock.current.addingTimeInterval(delay), run: check)) }
        }
        // So is a watched Codex subagent's lapse (P218).
        dependencies.scheduleSubagentCheck = { delay, check in
            scheduled.update { $0.append(ScheduledCheck(at: clock.current.addingTimeInterval(delay), run: check)) }
        }
        // No transcript is watched and no rollout's tail is read unless a test says so.
        dependencies.watchTranscript = { _, _, _ in nil }
        dependencies.readCodexSettings = { _ in nil }
        // No peek reads a transcript either (P311).
        dependencies.readPeek = nil
        dependencies.processExists = { _ in true }
        // No fork's transcript is read either (P441).
        dependencies.readForkParent = { _ in nil }
        configure?(&dependencies)
        return SessionEngine(configuration: configuration, dependencies: dependencies)
    }

    /// What the real scheduler does, on the test's clock: runs every scheduled check in time order, including the
    /// checks those checks schedule, up to `seconds` from now.
    @MainActor
    static func runScheduledChecks(_ scheduled: Box<[ScheduledCheck]>, clock: Box<Date>, for seconds: TimeInterval) {
        let end = clock.current.addingTimeInterval(seconds)
        while let next = scheduled.current.enumerated().filter({ $0.element.at <= end })
            .min(by: { $0.element.at < $1.element.at }) {
            scheduled.update { $0.remove(at: next.offset) }
            clock.update { $0 = max($0, next.element.at) }
            next.element.run()
        }
        clock.update { $0 = max($0, end) }
    }
}

extension SessionEngine {
    /// Every pending request's 8 s window, passed now with no notice from its agent (for tests that are not about the
    /// window): each is confirmed, as a request the agent sends no notice for would be.
    func passAttentionWindows() {
        for request in openRequests where request.state == .pending { attentionWindowElapsed(request.id) }
    }
}
