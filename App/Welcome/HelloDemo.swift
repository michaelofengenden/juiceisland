import Foundation
import IslandEngine
import Observation
import OpenIslandCore

/// Hello's demo on the real island (P963): one made-up Claude Code session in a made-up folder asks to run the tests.
/// The owner answers on the island (a click, or ⌃A); the tests run a moment; a chime, and the island folds the card to
/// done. A headless engine on the wall clock: no bridge, no socket, no jump, no file; the answer is recorded and goes
/// nowhere. The island shows it in place of the sessions (`LiveSessions.show`) while Hello shows, and never after.
@MainActor
@Observable
final class HelloDemo {
    enum Phase: Equatable, Sendable { case idle, asking, running, done }

    static let sessionID = "hello-demo"
    static let folder = "notes-site"
    static let command = "npm test"
    static let reply = "All 24 tests pass."
    /// How long the tests "run" after the answer.
    static let runs: Duration = .seconds(1.4)

    private(set) var phase: Phase = .idle
    @ObservationIgnored let feed: FixtureSessionFeed
    @ObservationIgnored let model: EngineSessionsModel
    @ObservationIgnored private let chime: @MainActor () -> Void
    @ObservationIgnored private let runs: Duration

    init(chime: @escaping @MainActor () -> Void, runs: Duration = HelloDemo.runs) {
        feed = FixtureSessionFeed(scenario: .empty, now: Date(), clock: { Date() })
        model = feed.makeModel()
        self.chime = chime
        self.runs = runs
    }

    /// The session starts and asks at once: the island opens on its card by itself.
    func start() {
        guard phase == .idle else { return }
        feed.engine.loadPreviewEvents(Self.askingEvents(now: Date()))
        phase = .asking
        watch()
    }

    /// The session's start and its approval, as the bridge would send them (renders draw the same card).
    static func askingEvents(now: Date) -> [AgentEvent] {
        var events = FixtureSessionFeed.start(sessionID, title: "Run the tests", project: folder, prompt: "run the tests", at: now - 20)
        events.append(FixtureSessionFeed.claudeApproval(sessionID, "Bash", useID: "toolu_hello_test", shown: command, at: now))
        return events
    }

    private func watch() {
        withObservationTracking { _ = model.waiting } onChange: { [weak self] in
            Task { @MainActor in self?.waitingChanged() }
        }
    }

    /// The card went: answered (Allow or Deny alike, the demo runs on).
    private func waitingChanged() {
        guard phase == .asking else { return }
        guard !model.waiting.contains(where: { $0.id == Self.sessionID }) else { return watch() }
        phase = .running
        feed.engine.loadPreviewEvents([.activityUpdated(SessionActivityUpdated(sessionID: Self.sessionID, summary: "Running Bash",
                                                                               phase: .running, timestamp: Date()))])
        let runs = runs
        Task { [weak self] in
            try? await Task.sleep(for: runs)
            self?.done()
        }
    }

    private func done() {
        guard phase == .running else { return }
        let now = Date()
        feed.engine.loadPreviewEvents([
            .claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: Self.sessionID, claudeMetadata: ClaudeSessionMetadata(
                lastUserPrompt: "run the tests", lastAssistantMessage: Self.reply), timestamp: now)),
            .sessionCompleted(SessionCompleted(sessionID: Self.sessionID, summary: Self.reply, timestamp: now)),
        ])
        phase = .done
        chime()
    }
}
