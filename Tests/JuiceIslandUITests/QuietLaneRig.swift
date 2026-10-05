import Foundation
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// The live engine behind `LiveSessions`, as `AlertTests` builds it, for the quiet lane's sound tests (P421, P422, P425,
/// P426): no socket is bound, no AppleScript runs and no sound plays (a `RecordingSoundPlayer` records what would have).
/// Sessions start in folders of the test's choosing, so mute rules have something to match.
@MainActor
enum QuietLaneRig {
    final class Probe: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var away = false
    }

    private final class StubBridge: EngineBridge, @unchecked Sendable {
        func updateStateSnapshot(_ snapshot: SessionState) {}
        func stop() {}
    }

    /// `scene`: the quiet scenes the app would read (P1005, P1006); none unless a test gives some.
    static func live(_ probe: Probe, settings: AppSettings, player: RecordingSoundPlayer,
                     scene: @escaping @MainActor () -> QuietScene = { .none }) -> LiveSessions {
        settings.liveSessions = true
        settings.suppressForFocusedSessions = false
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
            return SessionEngine(configuration: configuration, dependencies: dependencies)
        }, profiles: { LiveProfiles(accounts: [], discovered: []) }, sounds: player, away: { probe.away }, scene: scene)
        live.activate()
        return live
    }

    // Events shaped as upstream's bridge sends them.
    static func started(_ id: String, folder: String, at date: Date) -> AgentEvent {
        let name = URL(fileURLWithPath: folder).lastPathComponent
        return .sessionStarted(SessionStarted(sessionID: id, title: "Claude · \(name)", tool: .claudeCode, origin: .live, initialPhase: .running,
                                              summary: "Started.", timestamp: date,
                                              jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: name, paneTitle: "claude",
                                                                     workingDirectory: folder, terminalTTY: "/dev/ttys003")))
    }

    static func prompt(_ id: String, _ text: String, at date: Date) -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: id, summary: "Prompt: \(text)", phase: .running, timestamp: date))
    }

    static func permission(_ id: String, _ toolUseID: String, tool: String = "Bash", at date: Date) -> AgentEvent {
        .permissionRequested(PermissionRequested(sessionID: id, request: PermissionRequest(
            title: tool, summary: "git status", affectedPath: "/tmp/project", toolName: tool, toolUseID: toolUseID), timestamp: date))
    }

    static func question(_ id: String, at date: Date) -> AgentEvent {
        .questionAsked(QuestionAsked(sessionID: id, prompt: QuestionPrompt(title: "Which branch?", questions: [
            QuestionPromptItem(question: "Which branch should I push?", header: "Branch", options: [
                QuestionOption(label: "main", description: "The default branch."),
                QuestionOption(label: "dev", description: "The work in progress."),
            ]),
        ]), timestamp: date))
    }

    static func completed(_ id: String, at date: Date) -> AgentEvent {
        .sessionCompleted(SessionCompleted(sessionID: id, summary: "Done.", timestamp: date))
    }

    /// A session in `folder` that has had its first prompt.
    static func start(_ id: String, folder: String, prompt text: String = "fix the tests", _ engine: SessionEngine, _ probe: Probe) {
        engine.ingest(started(id, folder: folder, at: probe.now), ingress: .bridge)
        engine.ingest(prompt(id, text, at: probe.now), ingress: .bridge)
    }

    /// A turn that finishes, and the engine's 1.5 s hold passing.
    static func finish(_ id: String, _ engine: SessionEngine, _ probe: Probe) {
        engine.ingest(prompt(id, "go on", at: probe.now), ingress: .bridge)
        engine.ingest(completed(id, at: probe.now), ingress: .bridge)
        probe.now += SignalPipeline.doneHold
        engine.flushHeldSignals()
    }
}
