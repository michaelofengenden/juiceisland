import Foundation
@testable import IslandEngine
import Observation
import OpenIslandCore
@testable import JuiceIslandUI

/// Sessions sent to the island (P1300 to P1324), for the card's tests and renders: Claude and Codex turns in Terminal,
/// their agents named as a hook's context note names them (so each tab is known), on the demo's headless engine. Nothing
/// is typed, tucked or opened: replies go to the feed's recorder. Folders are fictional (C22).
@MainActor
enum FoldFixtures {
    enum ID {
        static let idle = "fold-idle"
        static let working = "fold-working"
        static let held = "fold-held"
        static let sending = "fold-sending"
        static let sent = "fold-sent"
        static let notSent = "fold-notsent"
        static let gone = "fold-gone"
        static let long = "fold-long"
        static let waits = "fold-waits"
        /// Working when it was sent; its window closed mid-turn (P1415).
        static let stopped = "fold-stopped"
        /// A Codex turn Codex's background service runs (P1486): its notes name the service.
        static let daemon = "fold-daemon"
        /// A Claude Code chat at its prompt whose id is a UUID, as its CLI takes it: Open in Claude offers it (P1510).
        static let app = "5d2e8f1a-7b3c-4d6e-9f0a-1b2c3d4e5f6a"
        /// An OpenCode chat at its prompt: its app lists the CLI's sessions, and the owner picks it there (P1514).
        static let openCode = "fold-opencode"
    }

    static let idleMessage = """
    Shot all 14 charts in light and dark into `site/shots`. Two had **clipped legends**; I widened their frames and shot \
    them again.

    Want me to open the PR?
    """
    static let workingMessage = "Split the retries out of the client. Running the suite 50 times now to be sure."
    static let codexMessage = "Moved the importer to the streaming parser; the 2 GB fixture now loads in 4.1 s."
    static let longMessage = (1...14).map { "\($0). Checked `site/charts/chart-\($0).svg` against its source table: the axis labels match." }
        .joined(separator: "\n")

    /// The resume lane's stand-in for a tab that is gone (route b): what it offers, nothing it runs.
    @MainActor
    @Observable
    final class Resume: ConversationResuming {
        var offer: ResumeAvailability
        var running: Set<String> = []
        var problems: [String: String] = [:]
        var answers: [String: String] = [:]
        /// What Codex's background service says of each thread (P1487).
        var service: [String: CodexDaemonStatus] = [:]
        /// What each send asked it to run with: recorded, never run.
        var continued: [(String, String)] = []
        init(offer: ResumeAvailability, service: [String: CodexDaemonStatus] = [:]) {
            self.offer = offer
            self.service = service
        }
        func availability(for sessionID: String) -> ResumeAvailability { offer }
        func isRunning(_ sessionID: String) -> Bool { running.contains(sessionID) }
        func continueConversation(_ sessionID: String, text: String) async -> SendOutcome {
            continued.append((sessionID, text))
            return .sent
        }
        func stop(_ sessionID: String) { running.remove(sessionID) }
        func openInTerminal(_ sessionID: String, continuing prompt: String?) async -> Bool { false }
        func problem(_ sessionID: String) -> String? { problems[sessionID] }
        func answer(_ sessionID: String) -> String? { answers[sessionID] }
        func keep(_ sessionID: String) {}
        func serviceStatus(_ sessionID: String) -> CodexDaemonStatus? { service[sessionID] }
    }

    /// The feed with every fixture session, `folded` sent to the island (newest last), each in its state.
    static func feed(folded: [String], now: Date = DemoClock.now, resume: Resume? = nil) -> FixtureSessionFeed {
        let feed = FixtureSessionFeed(scenario: .empty, now: now)
        let engine = feed.engine
        engine.loadPreviewEvents(events(now: now))
        // Only where it is sent: the other scenes' lists stay as they were.
        if folded.contains(ID.stopped) { engine.loadPreviewEvents(stoppedEvents(now: now)) }
        if folded.contains(ID.daemon) { engine.loadPreviewEvents(daemonEvents(now: now)) }
        if folded.contains(ID.app) { engine.loadPreviewEvents(appEvents(now: now)) }
        if folded.contains(ID.openCode) { engine.loadPreviewEvents(openCodeEvents(now: now)) }
        engine.loadPreviewAgents([ID.idle: 4301, ID.working: 4302, ID.held: 4303, ID.sending: 4304, ID.sent: 4305,
                                  ID.notSent: 4306, ID.gone: 4307, ID.long: 4308, ID.waits: 4309, ID.stopped: 4310, ID.app: 4311,
                                  ID.openCode: 4312, ID.daemon: SessionEngine.previewCodexServicePID])
        // Before the folds: a session Codex's background service runs folds once the service said it holds it.
        engine.conversationResume = resume
        engine.loadPreviewFolds(folded)
        if engine.folds[ID.held] != nil { engine.folds[ID.held]?.held = "then push the branch" }
        if engine.folds[ID.sending] != nil {
            engine.folds[ID.sending]?.send = .sending
            engine.folds[ID.sending]?.lastReply = "ship it"
        }
        if engine.folds[ID.sent] != nil { engine.folds[ID.sent]?.send = .sent }
        if engine.folds[ID.notSent] != nil {
            engine.folds[ID.notSent]?.send = .notSent
            engine.folds[ID.notSent]?.lastReply = "and tag it"
        }
        // The tab of the Codex chat closed after it was sent: its agent quit, its session ended.
        engine.loadPreviewEvents([.sessionCompleted(SessionCompleted(sessionID: ID.gone, summary: "Codex session ended.",
                                                                     timestamp: now - 30, isInterrupt: true, isSessionEnd: true))])
        // The Claude turn's window closed mid-turn after it was sent: its agent ended, and the fold said so (P1415).
        if engine.folds[ID.stopped] != nil {
            engine.loadPreviewEvents([.sessionCompleted(SessionCompleted(sessionID: ID.stopped, summary: "Claude Code session ended.",
                                                                         timestamp: now - 20, isInterrupt: true, isSessionEnd: true))])
            stop(engine, ID.stopped, now: now)
        }
        return feed
    }

    /// `id`'s agent ended mid-turn, as the fold's verdict leaves it (P1415).
    static func stop(_ engine: SessionEngine, _ id: String, windowClosed: Bool = true, now: Date = DemoClock.now) {
        engine.folds[id]?.turnOpen = false
        engine.folds[id]?.stopped = FoldStop(at: now - 20, windowClosed: windowClosed, why: .processEnded)
    }

    /// The resume as Codex's background service holds `ID.daemon`'s thread, saying `status` of it (P1487).
    static func daemonResume(_ status: CodexDaemonStatus) -> Resume {
        Resume(offer: .daemon(note: SessionResumer.serviceNote), service: [ID.daemon: status])
    }

    /// `id`'s turn ended, as its hooks say it.
    static func endTurn(_ engine: SessionEngine, _ id: String, now: Date = DemoClock.now) {
        engine.loadPreviewEvents([.sessionCompleted(SessionCompleted(sessionID: id, summary: "Streamed the 8 GB one too: 15 s.",
                                                                     timestamp: now - 60))])
        engine.folds[id]?.turnOpen = false
    }

    /// A Codex turn its background service runs, working when it was sent (P1486).
    static func daemonEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60, id = ID.daemon
        var events = FixtureSessionFeed.start(id, title: "Stream the importer", project: "MarathonTrainingLog", prompt: "stream the importer",
                                              tool: .codex, at: now - 25 * m)
        events.append(.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: id, codexMetadata: CodexSessionMetadata(
            transcriptPath: FixtureSessionFeed.demoRollout(id), lastUserPrompt: "stream the importer",
            lastAssistantMessage: codexMessage), timestamp: now - 9 * m)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: id, summary: codexMessage, timestamp: now - 9 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: FixtureSessionFeed.promptPrefix + "now the 8 GB one",
                                                              phase: .running, timestamp: now - 4 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: "Running Bash", phase: .running, timestamp: now - 3 * m)))
        return events
    }

    /// A Claude chat in Terminal at its prompt, its id a UUID (P1510).
    static func appEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60, id = ID.app
        let message = "Rewrote the welcome's copy and shot it in light and dark. Ready for a look."
        var events = FixtureSessionFeed.start(id, title: "Rewrite the welcome", project: "juice-island", prompt: "rewrite the welcome",
                                              at: now - 12 * m)
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "rewrite the welcome", lastAssistantMessage: message), timestamp: now - 2 * m)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: id, summary: message, timestamp: now - 2 * m)))
        return events
    }

    /// An OpenCode chat in Terminal at its prompt (P1514).
    static func openCodeEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60, id = ID.openCode
        let message = "Renamed the sync flags and updated their help. The CLI's tests pass."
        var events = FixtureSessionFeed.start(id, title: "Rename the sync flags", project: "notes-site", prompt: "rename the sync flags",
                                              tool: .openCode, at: now - 9 * m)
        events.append(.openCodeSessionMetadataUpdated(OpenCodeSessionMetadataUpdated(sessionID: id, openCodeMetadata: OpenCodeSessionMetadata(
            lastUserPrompt: "rename the sync flags", lastAssistantMessage: message), timestamp: now - 1 * m)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: id, summary: message, timestamp: now - 1 * m)))
        return events
    }

    /// Open in <App> on the demo engine (P1510): every app installed, the default profile, nothing run or opened (the
    /// engine is headless, and no runner, opener or list is given). `states`: where each card's hand-over stands.
    @discardableResult
    static func handoff(_ feed: FixtureSessionFeed, states: [String: HandoffState] = [:]) -> SessionHandoff {
        var dependencies = SessionHandoff.Dependencies()
        dependencies.appURL = { URL(fileURLWithPath: "/Applications/\($0.name).app") }
        dependencies.profile = { _ in NSHomeDirectory() + "/.claude" }
        let handoff = SessionHandoff(engine: feed.engine, dependencies: dependencies)
        for (id, state) in states { handoff.set(state, for: id) }
        feed.engine.appHandoff = handoff
        return handoff
    }

    /// A Claude turn in Terminal, working when it was sent.
    static func stoppedEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60, id = ID.stopped
        let message = "Split the retries out of the client; the unit tests pass. Running the whole suite next."
        var events = FixtureSessionFeed.start(id, title: "Split the upload retries", project: "juice-island",
                                              prompt: "split the upload retries", at: now - 30 * m)
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "split the upload retries", lastAssistantMessage: message), timestamp: now - 9 * m)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: id, summary: message, timestamp: now - 9 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: FixtureSessionFeed.promptPrefix + "run the whole suite",
                                                              phase: .running, timestamp: now - 4 * m)))
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "run the whole suite", lastAssistantMessage: message, currentTool: "Bash", currentToolInputPreview: "swift test"),
            timestamp: now - 3 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: "Running Bash", phase: .running, timestamp: now - 3 * m)))
        return events
    }

    static func events(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        var events: [AgentEvent] = []
        func claudeDone(_ id: String, title: String, project: String, message: String, at minutes: Double) {
            events += FixtureSessionFeed.start(id, title: title, project: project, prompt: title.lowercased(), at: now - (minutes + 10) * m)
            events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
                lastUserPrompt: title.lowercased(), lastAssistantMessage: message), timestamp: now - minutes * m)))
            events.append(.sessionCompleted(SessionCompleted(sessionID: id, summary: message, timestamp: now - minutes * m)))
        }
        func claudeWorking(_ id: String, title: String, project: String, message: String, tool: String, preview: String) {
            claudeDone(id, title: title, project: project, message: message, at: 6)
            events.append(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: FixtureSessionFeed.promptPrefix + "run it 50 times",
                                                                  phase: .running, timestamp: now - 3 * m)))
            events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
                lastUserPrompt: "run it 50 times", lastAssistantMessage: message, currentTool: tool, currentToolInputPreview: preview),
                timestamp: now - 2 * m)))
            events.append(.activityUpdated(SessionActivityUpdated(sessionID: id, summary: "Running \(tool)", phase: .running, timestamp: now - 2 * m)))
        }
        claudeDone(ID.idle, title: "Shoot the site's charts", project: "notes-site", message: idleMessage, at: 2)
        claudeWorking(ID.working, title: "Fix the flaky upload test", project: "juice-island", message: workingMessage,
                      tool: "Bash", preview: "swift test --filter Upload")
        claudeWorking(ID.held, title: "Tidy the importer", project: "MarathonTrainingLog",
                      message: "Moved the parsing into its own file; the tests pass.", tool: "Edit", preview: "Sources/Importer/Parse.swift")
        claudeDone(ID.sending, title: "Bump the version", project: "juice-island", message: "Bumped VERSION to 0.7.0 and the notes.", at: 1)
        claudeDone(ID.sent, title: "Write the release notes", project: "notes-site", message: "Wrote the notes for 0.7.0 under New, Better and Fixed.", at: 3)
        claudeDone(ID.notSent, title: "Rename the importer", project: "MarathonTrainingLog", message: "Renamed it to `StreamImporter` everywhere.", at: 5)
        claudeDone(ID.long, title: "Check every chart", project: "notes-site", message: longMessage, at: 4)
        // Codex, in Terminal, finished; its tab closes later (`feed`).
        events += FixtureSessionFeed.start(ID.gone, title: "Stream the importer", project: "MarathonTrainingLog", prompt: "stream the importer",
                                           tool: .codex, at: now - 20 * m)
        events.append(.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: ID.gone, codexMetadata: CodexSessionMetadata(
            transcriptPath: FixtureSessionFeed.demoRollout(ID.gone), lastUserPrompt: "stream the importer",
            lastAssistantMessage: codexMessage), timestamp: now - 8 * m)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: ID.gone, summary: codexMessage, timestamp: now - 8 * m)))
        return events
    }

    /// The island's environment over `feed`: Clean, the usage in the header strip, Island mode.
    static func env(_ feed: FixtureSessionFeed, configure: (AppSettings) -> Void = { _ in }) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .clean
        settings.islandUsagePlacement = .headerStrip
        settings.glyphStyle = .pixel
        settings.showAs = .island
        configure(settings)
        return AppEnvironment(settings: settings, usage: DemoUsageModel(now: feed.now), sessions: feed.makeModel())
    }
}
