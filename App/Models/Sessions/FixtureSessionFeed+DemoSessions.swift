import Foundation
import IslandEngine
import OpenIslandCore

/// Diagnostics' Demo sessions (P967) and the README's shots: six made-up sessions in two made-up folders, through the
/// paths live ones take. Claude asks to run a command (a hook input handed to the request broker, so its card answers),
/// Claude asks one question with three options, Claude edits a file, Codex runs a command, Codex is done, and Copilot CLI
/// runs (its mark, from its hooks' note). `DemoSessionsPlayer` plays the same events on the wall clock.
extension FixtureSessionFeed {
    /// The sessions' ids, so a render or a test can open the approval's or the question's card.
    enum DemoSessionsID {
        static let approval = "show-approval"
        static let question = "show-question"
        static let edit = "show-edit"
        static let codexRun = "show-codex-run"
        static let codexDone = "show-codex-done"
        static let copilot = "show-copilot"
        static let all = [approval, question, edit, codexRun, codexDone, copilot]
    }

    /// The only folders the scenario names: made-up words, no project of anyone's (P842, P855).
    static let demoSessionsFolders: Set<String> = ["notes-site", "field-notes"]

    /// The approval's command.
    static let demoSessionsCommand = "mkdir -p site/shots/light site/shots/dark"

    static func demoSessionsEvents(now: Date) -> [AgentEvent] {
        let m: TimeInterval = 60
        typealias ID = DemoSessionsID
        var events = start(ID.codexDone, title: "Draft the release notes", project: "notes-site", prompt: "draft the release notes",
                           tool: .codex, at: now - 40 * m)
        events.append(.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: ID.codexDone, codexMetadata: CodexSessionMetadata(
            transcriptPath: demoRollout(ID.codexDone), lastUserPrompt: "draft the release notes",
            lastAssistantMessage: "Drafted the notes in docs/release-notes.md."), timestamp: now - 9 * m)))
        events.append(.sessionCompleted(SessionCompleted(sessionID: ID.codexDone, summary: "Drafted the notes.", timestamp: now - 9 * m)))

        events += start(ID.edit, title: "Tighten the card spacing", project: "field-notes", prompt: "tighten the cards", at: now - 18 * m)
        events.append(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: ID.edit, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: "tighten the cards", currentTool: "Edit", currentToolInputPreview: "Sources/Cards/CardView.swift"),
            timestamp: now - 2 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: ID.edit, summary: "Running Edit", phase: .running, timestamp: now - 2 * m)))

        events += start(ID.codexRun, title: "Resize the site's images", project: "notes-site", prompt: "resize the images", tool: .codex,
                        at: now - 12 * m)
        events.append(.sessionMetadataUpdated(SessionMetadataUpdated(sessionID: ID.codexRun, codexMetadata: CodexSessionMetadata(
            transcriptPath: demoRollout(ID.codexRun), lastUserPrompt: "resize the images", currentTool: "exec_command",
            currentCommandPreview: "sips -Z 512 *.png"), timestamp: now - 1 * m)))
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: ID.codexRun, summary: "Running exec_command", phase: .running,
                                                              timestamp: now - 1 * m)))

        // Copilot CLI's hooks reach the bridge under a Claude-format fork's word; its note names it (P908, P913).
        events += start(ID.copilot, title: "Check the broken links", project: "field-notes", prompt: "check the links", tool: .codebuddy,
                        at: now - 7 * m)
        events.append(.activityUpdated(SessionActivityUpdated(sessionID: ID.copilot, summary: "Running bash", phase: .running,
                                                              timestamp: now - 1 * m)))

        events += start(ID.question, title: "Pick the chart style", project: "field-notes", prompt: "chart the visits", at: now - 6 * m)
        events.append(.questionAsked(QuestionAsked(sessionID: ID.question, prompt: claudeQuestions([
            QuestionPromptItem(question: "Which chart should the visits use?", header: "Chart", options: [
                QuestionOption(label: "Bars", description: "One bar a week."),
                QuestionOption(label: "Line", description: "A line through the weeks."),
                QuestionOption(label: "Table", description: "The numbers alone."),
            ]),
        ]), timestamp: now - 3 * m)))

        events += start(ID.approval, title: "Shoot the site's charts", project: "notes-site", prompt: "shoot the charts", at: now - 5 * m)
        return events
    }

    /// The approval, as the superset helper hands a Claude PermissionRequest to the broker (answerable), and Copilot's
    /// note.
    static func loadDemoSessions(into engine: SessionEngine) {
        engine.loadPreviewNote(event: "SessionStart", sessionID: DemoSessionsID.copilot, source: "copilot")
        engine.loadPreviewHookRequest(claudeRequest(DemoSessionsID.approval, tool: "Bash", useID: "toolu_show_mkdir", input: [
            "command": demoSessionsCommand, "description": "Make the folders for the shots"]), source: "claude", entrypoint: "cli")
    }
}

/// Diagnostics' Demo sessions on the wall clock (P967): the scenario's events, timed from the moment the switch went on,
/// on a headless engine (no bridge, no socket, no jump, no sound). Its cards' answers are recorded and go nowhere.
@MainActor
enum DemoSessionsPlayer {
    static func makeFeed(now: Date = Date()) -> FixtureSessionFeed {
        FixtureSessionFeed(scenario: .demoSessions, now: now, clock: { Date() })
    }
}
